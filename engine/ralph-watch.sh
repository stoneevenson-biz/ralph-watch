#!/usr/bin/env bash
# ralph-watch.sh — the Ralph loop monitor you actually WANT to stare at.
#
# One per repo. Flicker-free live TUI: state header, animated slice progress bar,
# per-slice checklist (✓ shipped / ▶ building / ⛔ blocked / ○ queued), velocity
# panel (slice pace + ETA, iteration cadence sparkline, commit rate, live spend),
# recent-commit ticker, and a celebration banner on convergence. When the loop
# hits BLOCKED/FAILED, this terminal becomes a Claude grill (unchanged behavior),
# then returns to monitoring.
#
# Usage: ralph-watch.sh <repo-dir>          POLL=2 refresh seconds
# Windows git-bash friendly. No tmux, no jq. Poll-based on .ralph/status.json.
# Library mode (for tests): RALPH_WATCH_LIB=1 . ralph-watch.sh  → helpers only.
set -uo pipefail

# ---------- ANSI + glyphs ----------------------------------------------------
C_R=$'\033[0m'; C_B=$'\033[1m'; C_D=$'\033[2m'
C_GRN=$'\033[32m'; C_CYN=$'\033[36m'; C_YLW=$'\033[33m'; C_RED=$'\033[31m'; C_MAG=$'\033[35m'
SPINF=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
RAMP=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")

clr() { printf '\033[H\033[2J' 2>/dev/null || true; }
bar() { printf '─%.0s' $(seq 1 54); echo; }
sep() { printf '%s' "$C_D"; printf '━%.0s' $(seq 1 60); printf '%s\n' "$C_R"; }

# ---------- pure helpers (unit-tested) ---------------------------------------
fmt_dur() { # seconds -> "45s" | "4m 12s" | "1h 03m"
  local s="${1:-0}"
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm %ss' "$((s/60))" "$((s%60))"
  else printf '%dh %02dm' "$((s/3600))" "$(( (s%3600)/60 ))"; fi
}
rel_age() { # seconds -> compact "45s" | "4m" | "2h" | "3d"
  local s="${1:-0}"
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' "$((s/60))"
  elif [ "$s" -lt 86400 ]; then printf '%sh' "$((s/3600))"
  else printf '%sd' "$((s/86400))"; fi
}
mkbar() { # done total width -> "███░░░" (total=0 safe)
  local done_n="${1:-0}" total="${2:-0}" w="${3:-30}" f=0 i out=""
  [ "$total" -gt 0 ] && f=$(( done_n * w / total ))
  [ "$f" -gt "$w" ] && f="$w"
  for ((i=0; i<f; i++)); do out+="█"; done
  for ((i=f; i<w; i++)); do out+="░"; done
  printf '%s' "$out"
}
sparkline() { # "10 80 40" -> "▁█▃" (scaled to max)
  local vals=($1) max=0 v idx out=""
  for v in "${vals[@]}"; do [ "$v" -gt "$max" ] && max="$v"; done
  [ "$max" -eq 0 ] && max=1
  for v in "${vals[@]}"; do idx=$(( v * 7 / max )); out+="${RAMP[$idx]}"; done
  printf '%s' "$out"
}
avg_gap() { # "ts1 ts2 ts3" (ascending epochs) -> mean gap seconds (0 if <2)
  local ts=($1) n sum=0 i
  n="${#ts[@]}"
  [ "$n" -lt 2 ] && { printf '0'; return; }
  for ((i=1; i<n; i++)); do sum=$(( sum + ts[i] - ts[i-1] )); done
  printf '%s' "$(( sum / (n-1) ))"
}

# ---------- data readers (cwd = repo) ----------------------------------------
sj() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" .ralph/status.json 2>/dev/null; }
fm() { # fm <file> <key> -> frontmatter scalar
  awk -v k="$2" '
    /^---[[:space:]]*$/ {n++; next}
    n==1 && $0 ~ "^"k":" { sub("^"k":[[:space:]]*",""); gsub(/[[:space:]]+$/,""); print; exit }
  ' "$1" 2>/dev/null
}
collect_slices() { # -> lines "status|phase|lane|name" (status normalized done|todo)
  local f st ph ln
  for f in specs/*.md; do
    [ -e "$f" ] || return 0
    case "$f" in *README*|*readme*) continue ;; esac
    [ -n "$(fm "$f" parent)" ] || continue
    st="$(fm "$f" status)"; ph="$(fm "$f" phase)"; ln="$(fm "$f" lane)"
    [ -z "$ph" ] && ph=1; [ -z "$ln" ] && ln=core
    case "$st" in done|completed|shipped) st=done ;; *) st=todo ;; esac
    printf '%s|%s|%s|%s\n' "$st" "$ph" "$ln" "$(basename "$f" .md)"
  done
}
count_done_total() { # -> "done total"
  local d=0 t=0 st rest
  while IFS='|' read -r st rest; do
    [ -z "$st" ] && continue
    t=$((t+1)); [ "$st" = "done" ] && d=$((d+1))
  done < <(collect_slices)
  printf '%s %s' "$d" "$t"
}
progress_ts() { # epochs of baseline + every done-count increment
  awk '
    { ts=""; d=""
      if (match($0, /"ts":[0-9]+/))   ts=substr($0, RSTART+5, RLENGTH-5)
      if (match($0, /"done":[0-9]+/)) d=substr($0, RSTART+7, RLENGTH-7)
      if (ts=="") next
      if (NR==1) { print ts; prev=d; next }
      if (d+0 > prev+0) print ts
      prev=d
    }' .ralph/progress.jsonl 2>/dev/null
}
iter_durations() { # seconds per finished iteration, main repo + lane worktrees
  local repo="${1:-$(basename "$(pwd)")}" f
  for f in .ralph/events.jsonl ../"$repo"-p*-*/.ralph/events.jsonl; do
    [ -f "$f" ] || continue
    awk '
      /"ev":"iter_start"/ { if (match($0,/"ts":[0-9]+/)) s=substr($0,RSTART+5,RLENGTH-5); next }
      /"ev":"iter_end"/   { if (s!="" && match($0,/"ts":[0-9]+/)) { print substr($0,RSTART+5,RLENGTH-5)-s; s="" } }
    ' "$f"
  done
}
spend_total() { # summed total_cost_usd from the spend ledger, "%.2f" (empty if none)
  awk '
    { if (match($0, /"total_cost_usd":[[:space:]]*[0-9.]+/)) {
        v=substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*/, "", v); s+=v } }
    END { if (s > 0) printf "%.2f", s }' .ralph/spend-ledger.jsonl 2>/dev/null
}
record_progress() { # append a progress point whenever the done-count changes
  [ -d .ralph ] || return 0
  local dt d t last
  dt="$(count_done_total)"; d="${dt%% *}"; t="${dt##* }"
  [ "$t" = "0" ] && return 0
  last="$(tail -1 .ralph/progress.jsonl 2>/dev/null | sed -n 's/.*"done":\([0-9]*\).*/\1/p')"
  [ "$d" = "${last:-__none__}" ] && return 0
  printf '{"ts":%s,"done":%s,"total":%s}\n' "$(date +%s)" "$d" "$t" >> .ralph/progress.jsonl
}

# ---------- the frame ---------------------------------------------------------
render_frame() {
  local now repo state phase detail
  now="$(date +%s)"
  repo="${REPO:-$(basename "$(pwd)")}"
  state="$(sj state)"; phase="$(sj phase)"; detail="$(sj detail)"
  [ -z "$state" ] && state="starting"

  local icon col
  case "$state" in
    running) icon="▶ RUNNING";   col="$C_CYN" ;;
    held)    icon="⏸ IN REVIEW"; col="$C_YLW" ;;
    blocked) icon="⛔ BLOCKED";   col="$C_RED" ;;
    failed)  icon="✖ FAILED";    col="$C_RED" ;;
    done)    icon="✔ COMPLETE";  col="$C_GRN" ;;
    *)       icon="… $state";    col="$C_D" ;;
  esac
  local sp="${SPINF[$(( ${TICK:-0} % 10 ))]}"

  # slices
  local rows total=0 done_n=0 st ph ln nm
  rows="$(collect_slices)"
  while IFS='|' read -r st ph ln nm; do
    [ -z "$st" ] && continue
    total=$((total+1)); [ "$st" = "done" ] && done_n=$((done_n+1))
  done <<< "$rows"
  local pct=0; [ "$total" -gt 0 ] && pct=$(( done_n * 100 / total ))

  # elapsed since first progress point
  local t0 elapsed=""
  t0="$(head -1 .ralph/progress.jsonl 2>/dev/null | sed -n 's/.*"ts":\([0-9]*\).*/\1/p')"
  [ -n "$t0" ] && elapsed="$(fmt_dur $(( now - t0 )))"

  # ── header ──
  sep
  printf '  %s⚡ RALPH ▸ %s%s   %s%s%s%s\n' "$C_B" "$repo" "$C_R" "$col" "$icon" "$C_R" "${phase:+$C_D · phase $phase$C_R}"
  printf '  %s%s%s%s %s%s\n' "$C_D" "${detail:-…}" "${elapsed:+ · up $elapsed}" "$C_R" "$col" "$sp$C_R"
  sep

  # ── done celebration ──
  if [ "$state" = "done" ]; then
    printf '\n  %s%s🎉  ALL PHASES COMPLETE — SHIPPED  🎉%s\n' "$C_B" "$C_GRN" "$C_R"
    local fin_spend; fin_spend="$(spend_total)"
    printf '  %s%s/%s slices green%s%s%s\n\n' "$C_GRN" "$done_n" "$total" "$C_R" "${elapsed:+$C_D · total $elapsed$C_R}" "${fin_spend:+$C_D · \$$fin_spend$C_R}"
  fi

  # ── progress bar + checklist ──
  if [ "$total" -gt 0 ]; then
    printf '\n  %s%s%s  %s%s/%s slices · %s%%%s\n\n' "$C_GRN" "$(mkbar "$done_n" "$total" 36)" "$C_R" "$C_B" "$done_n" "$total" "$pct" "$C_R"
    local shown_done=0 collapse=0
    [ "$total" -gt 12 ] && collapse=1
    [ "$collapse" = "1" ] && [ "$done_n" -gt 0 ] && printf '  %s✓ %s shipped%s\n' "$C_GRN" "$done_n" "$C_R"
    while IFS='|' read -r st ph ln nm; do
      [ -z "$st" ] && continue
      local wt="../${repo}-p${ph}-${ln}"
      if [ "$st" = "done" ]; then
        [ "$collapse" = "1" ] && continue
        printf '  %s✓%s %s%-32.32s done%s\n' "$C_GRN" "$C_R" "$C_D" "$nm" "$C_R"
      elif [ -f "$wt/BLOCKERS.md" ]; then
        printf '  %s⛔ %-32.32s BLOCKED — needs you%s\n' "$C_RED" "$nm" "$C_R"
      elif [ -d "$wt" ]; then
        printf '  %s▶%s %s%-32.32s%s %s%s building (p%s/%s)%s\n' "$C_CYN" "$C_R" "$C_B" "$nm" "$C_R" "$C_CYN" "$sp" "$ph" "$ln" "$C_R"
      else
        printf '  %s○ %-32.32s queued (p%s/%s)%s\n' "$C_D" "$nm" "$ph" "$ln" "$C_R"
      fi
    done <<< "$rows"

    # ── velocity ──
    printf '\n  %sVELOCITY%s\n' "$C_B" "$C_R"
    local pts_flat gap remaining eta_str=""
    pts_flat="$(progress_ts | tr '\n' ' ')"
    gap="$(avg_gap "$pts_flat")"
    remaining=$(( total - done_n ))
    if [ "$state" != "done" ]; then
      if [ "$gap" -gt 0 ] && [ "$remaining" -gt 0 ]; then
        local eta_s eta_clock
        eta_s=$(( remaining * gap ))
        eta_clock="$(date -d "@$(( now + eta_s ))" +%H:%M 2>/dev/null || true)"
        eta_str="ETA ~$(fmt_dur "$eta_s")${eta_clock:+ ($eta_clock)}"
        printf '  %s▸%s pace    1 slice / %s · %s%s%s\n' "$C_MAG" "$C_R" "$(fmt_dur "$gap")" "$C_B" "$eta_str" "$C_R"
      else
        printf '  %s▸%s pace    warming up · ETA —\n' "$C_MAG" "$C_R"
      fi
    fi
    local durs v n_it=0 sum_it=0
    durs="$(iter_durations "$repo" | tail -12 | tr '\n' ' ')"
    if [ -n "${durs// /}" ]; then
      for v in $durs; do n_it=$((n_it+1)); sum_it=$((sum_it+v)); done
      printf '  %s▸%s iters   avg %s/iteration  %s%s%s\n' "$C_MAG" "$C_R" "$(fmt_dur $(( sum_it / n_it )))" "$C_CYN" "$(sparkline "$durs")" "$C_R"
    fi
    local nci lastct
    nci="$(git log --all --since='60 minutes ago' --oneline 2>/dev/null | wc -l | tr -d ' ')"
    lastct="$(git log --all -1 --pretty=%ct 2>/dev/null | tr -d ' ')"
    if [ -n "$lastct" ]; then
      printf '  %s▸%s commits %s in last hour · last %s ago\n' "$C_MAG" "$C_R" "${nci:-0}" "$(rel_age $(( now - lastct )))"
    fi
    local sp_total; sp_total="$(spend_total)"
    [ -n "$sp_total" ] && printf '  %s▸%s spend   %s$%s%s this run\n' "$C_MAG" "$C_R" "$C_YLW" "$sp_total" "$C_R"
  fi

  # ── blocked panel ──
  if [ "$state" = "blocked" ] || [ "$state" = "failed" ]; then
    local bk; bk="$(sj blocker)"
    printf '\n  %s⛔ NEEDS YOU%s %s%s%s\n' "$C_RED" "$C_R" "$C_D" "${detail:-}" "$C_R"
    [ -n "$bk" ] && [ -f "$bk" ] && sed -n '1,6p' "$bk" 2>/dev/null | sed "s/^/  $(printf '%s' "$C_RED")│$(printf '%s' "$C_R") /"
  fi

  # ── recent commits ──
  printf '\n  %sRECENT%s\n' "$C_B" "$C_R"
  local ct h s have=0
  while IFS='|' read -r ct h s; do
    [ -z "$ct" ] && continue
    have=1
    printf '  %s%-4s%s %s%s%s %.44s\n' "$C_D" "$(rel_age $(( now - ct )))" "$C_R" "$C_YLW" "$h" "$C_R" "$s"
  done < <(git log --all -5 --pretty='%ct|%h|%s' 2>/dev/null)
  [ "$have" = "0" ] && printf '  %s(no commits yet)%s\n' "$C_D" "$C_R"

  sep
  case "$state" in
    done)    printf '  %sloop finished — Ctrl-C to close%s\n' "$C_GRN" "$C_R" ;;
    blocked|failed) printf '  %s⚠ launching Claude grill to resolve…%s\n' "$C_RED" "$C_R" ;;
    *)       printf '  %swatching · refresh %ss · Ctrl-C quits%s\n' "$C_D" "${POLL:-2}" "$C_R" ;;
  esac
}

# ---------- library gate (tests source up to here) ----------------------------
if [ -n "${RALPH_WATCH_LIB:-}" ]; then return 0 2>/dev/null || exit 0; fi

DIR="${1:-.}"; cd "$DIR" || { echo "no such dir: $DIR"; exit 2; }
REPO="$(basename "$(pwd)")"
POLL="${POLL:-2}"   # seconds between refreshes

# Launch Claude IN THIS TERMINAL to grill Stone on the blocker, then return to monitoring.
grill_on_blocker() {
  local blocker="$1" state="$2"
  clr; bar; printf "  ⛔ %s · %s — Claude needs a decision from you\n" "$REPO" "$state"; bar; echo
  # Gather RICH context up front so Claude grills from full knowledge, not a thin blocker line.
  local blocked_specs; blocked_specs="$(grep -lE '^status:[[:space:]]*(blocked|draft)|## Blocked' specs/*.md 2>/dev/null | head -5)"
  local ctx="You are resolving a BLOCKER in a Ralph autonomous build loop, repo '$REPO' (state: $state).
The loop CANNOT proceed until you extract the missing decision from Stone and write it to disk.
This is a /grill-me-style session: relentless, ONE question at a time, until you genuinely have what the loop needs.

=== BLOCKER ===
$(cat "$blocker" 2>/dev/null || echo "$blocker")

=== BLOCKERS.md ===
$(cat BLOCKERS.md 2>/dev/null | head -60 || echo "(none)")

=== BLOCKED/UNFINISHED SLICE SPECS ===
$(for s in $blocked_specs; do echo "----- $s -----"; cat "$s"; echo; done)

=== CONTEXT.md (domain glossary — use these terms) ===
$(cat CONTEXT.md 2>/dev/null | head -80 || echo "(none)")

=== .memory/ (gotchas already learned here) ===
$(cat .memory/MEMORY.md 2>/dev/null | head -40 || echo "(none)")

=== last commits ===
$(git log -5 --pretty='%h %s' 2>/dev/null)

=== HOW TO GRILL (from /grill-me) ===
- ONE question at a time. Wait for the answer. Then the next. Never dump a list of questions.
- For each question, state your RECOMMENDED answer + why — make it easy for Stone to confirm or correct.
- Be willing to disagree. If Stone's answer is vague, contradicts CONTEXT.md, contradicts an AC, or
  doesn't actually unblock the build, PUSH BACK and ask again. A grill that just accepts is worthless.
- Walk the decision tree depth-first: resolving one answer may surface the next thing you must ask.
- Keep going until you can state, concretely, what the loop will now build differently. If you can't
  state that, you don't have enough yet — ask more.
- Use CONTEXT.md domain terms. Stay terse elsewhere, but questions to Stone must be crisp and clear.

=== WHEN YOU GENUINELY HAVE WHAT YOU NEED ===
1. SHARPEN THE SPEC: edit the blocked slice spec — add the decision / rewrite the fuzzy AC that caused
   the block as a concrete behavioral AC + verify command. Clear its '## Blocked' note and set
   'status: draft' so the loop rebuilds it.
2. LOG for the feedback loop:
   node ~/.claude/ralph/pipeline-log.mjs lane_failed repo=$REPO cause=blocked prevention=\"<one line: what the PRD/AC should have specified so this never blocks again>\"
   and append a short Q&A note to .memory/ (a <slug>.md + MEMORY.md pointer).
3. Tell Stone: the loop will pick up the sharpened spec on its next iteration. Then exit.

Start now with your FIRST question to Stone."
  if command -v claude >/dev/null 2>&1; then
    claude "$ctx" || true
  else
    echo "claude CLI not found — blocker needs manual resolution. Detail:"; cat "$blocker" 2>/dev/null
    echo; read -r -p "Press Enter when you've resolved it on disk to resume monitoring… " _
  fi
  clr; printf "  resolved — back to watching %s\n" "$REPO"; sleep 2
}

[ -d .ralph ] || echo "no .ralph/ in $(pwd) yet — waiting for the loop to start…"
printf '\033[?25l\033[2J'                      # hide cursor + one full clear
trap 'printf "\033[?25h\033[0m\n"' EXIT        # always restore cursor/colors

GRILLED_FOR=""   # don't re-grill the same blocker every poll
TICK=0
while :; do
  TICK=$((TICK+1))
  record_progress
  FRAMEBUF="$(render_frame)"
  printf '\033[H%s\n\033[0J' "$FRAMEBUF"       # home + draw + erase remainder = zero flicker
  state="$(sj state)"; blocker="$(sj blocker)"
  if { [ "$state" = "blocked" ] || [ "$state" = "failed" ]; } && [ -n "$blocker" ] && [ "$blocker" != "$GRILLED_FOR" ]; then
    printf '\033[?25h'                         # cursor back for the interactive grill
    grill_on_blocker "$blocker" "$state"
    GRILLED_FOR="$blocker"
    printf '\033[?25l\033[2J'
  fi
  sleep "$POLL"
done
