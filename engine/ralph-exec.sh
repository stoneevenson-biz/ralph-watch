#!/usr/bin/env bash
# ralph-exec.sh — the phase/lane WORKTREE EXECUTOR.
#
# Sits ABOVE the per-lane loop engine (~/.claude/ralph/ralph.sh). Reads the
# phase + lane tags off specs/*.md and schedules the build:
#
#   * Phases run in SEQUENCE (phase N+1 starts only after phase N merges green).
#   * Within a phase, each LANE runs in its OWN git worktree, IN PARALLEL.
#   * Same-lane slices run sequentially (one worktree, the engine picks them in order).
#   * The MAIN working tree is NEVER touched — every lane builds in ../<repo>-lane-<name>.
#   * At the phase boundary, each lane's branch is merged back (green-gated), in
#     dependency order, then worktrees are removed and the next phase begins.
#
# This is what makes "just ralph the specs and it's done, in parallel, without
# clobbering my interactive session" real. Run it from the repo root, on a feature
# branch. Windows git-bash friendly (uses git worktree, no tmux/docker).
#
# Usage:   cd repo && ~/.claude/ralph/ralph-exec.sh
# Env:     MAX=40  MODEL=...  PARALLEL_CAP=4  DRYRUN=1  PHASE=2 (run only this phase)
#          NO_MERGE=1 (build lanes but stop before merge — you merge manually)
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo"; exit 1; }
cd "$REPO_ROOT"
REPO_NAME="$(basename "$REPO_ROOT")"
[ -d specs ] || { echo "no specs/ dir — run /to-prd + /to-issues first"; exit 1; }

# Ensure the per-repo substrate exists (idempotent): AGENTS.md router + .memory/ gotchas.
[ -x "$HOME/.claude/ralph/repo-substrate.sh" ] && bash "$HOME/.claude/ralph/repo-substrate.sh" >/dev/null 2>&1 || true

MAX="${MAX:-40}"
PARALLEL_CAP="${PARALLEL_CAP:-4}"          # max lanes built at once (review/CPU bottleneck)
BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
EXEC_LOG=".ralph/exec.log"
mkdir -p .ralph
: > "$EXEC_LOG"
log() { echo "$*" | tee -a "$EXEC_LOG" >&2; }   # to stderr+file, never stdout (stdout is captured by mapfile)
# L4 system-feedback emitter: append a structured event to the global pipeline log (best-effort).
plog() { command -v node >/dev/null 2>&1 && node "$HOME/.claude/ralph/pipeline-log.mjs" "$@" >/dev/null 2>&1 || true; }

# Write a clean machine-readable status the monitor renders. One line of JSON, overwritten each update.
# state ∈ running | held | blocked | failed | done.  blocker = path to the thing needing Stone, or "".
status_write() { # status_write <state> <phase> <detail> [blocker-path]
  mkdir -p .ralph
  printf '{"state":"%s","repo":"%s","phase":"%s","detail":"%s","blocker":"%s","ts":"%s"}\n' \
    "$1" "$REPO_NAME" "${2:-}" "${3:-}" "${4:-}" "$(printf '%(%Y-%m-%dT%H:%M:%S)T' -1)" > .ralph/status.json
}

# Classify WHY a lane failed from its worktree log → (cause, prevention-hint) for the feedback loop.
# This is the "why did it fail / what could've prevented it" capture. Echoes "cause|prevention".
classify_failure() { # <phase> <lane-rep>
  local wt="../${REPO_NAME}-p${1}-${2}"
  local lg="$wt/ralph.log"; [ -f "$wt/codex-lane.log" ] && lg="$wt/codex-lane.log"
  if [ ! -f "$lg" ]; then echo "unknown|no lane log found — check the worktree manually"; return; fi
  # heuristics, most-specific first
  if grep -qiE '## Blocked|BLOCKERS' "$lg"; then
    echo "blocked|lane self-reported a blocker — read BLOCKERS.md; the spec likely under-specifies or a dep is missing"
  elif grep -qiE 'same test fail|failed 3|3 (times|iterations)' "$lg"; then
    echo "stuck_test|same test failed repeatedly — AC may be wrong/untestable, or the approach is a dead end; tighten the spec's AC or split the slice"
  elif grep -qiE 'hit MAX|without converg|MAX=.* iterations' "$lg"; then
    echo "max_iter|ran out of iterations — slice too big OR AC too vague to converge; split the slice / sharpen ACs in to-issues"
  elif grep -qiE 'cannot find|not found|no such file|command not found|ENOENT' "$lg"; then
    echo "env_setup|missing command/file/dep — AGENTS.md commands wrong or env not seeded; fix AGENTS.md + add a .memory/ note"
  elif grep -qiE 'codex exec rc=|escalate to Claude' "$lg"; then
    echo "codex_gave_up|codex-built lane didn't converge — slice wasn't as mechanical as tagged; retag engine:claude in to-issues"
  else
    echo "test_red|verify never went green — implementation incomplete/incorrect; check the diff + the failing test output in the log"
  fi
}

# --- frontmatter readers (POSIX-ish; tolerate missing keys) ------------------
fm() { # fm <file> <key>  -> value of a top-level frontmatter scalar key
  awk -v k="$2" '
    /^---[[:space:]]*$/ {n++; next}
    n==1 && $0 ~ "^"k":" { sub("^"k":[[:space:]]*",""); gsub(/[[:space:]]+$/,""); print; exit }
  ' "$1"
}

# A spec is BUILDABLE this run if: status not done, type AFK (HITL is skipped).
is_buildable() {
  local f="$1" st ty
  st="$(fm "$f" status)"; ty="$(fm "$f" type)"
  case "$st" in done|completed|shipped) return 1;; esac
  case "$ty" in HITL) return 1;; esac
  # parent PRDs (no parent: key) are not built directly — only slices
  [ -n "$(fm "$f" parent)" ] || return 1
  return 0
}

# --- discover phases present among buildable slices --------------------------
mapfile -t SLICES < <(ls specs/*.md 2>/dev/null | grep -v -i 'README' || true)
declare -A PHASES_SEEN
declare -A RUNNING   # rep -> 1 while a lane is mid-build (ADR-0003: don't flip a running lane mid-run)
for f in "${SLICES[@]}"; do
  is_buildable "$f" || continue
  p="$(fm "$f" phase)"; [ -z "$p" ] && p=1
  PHASES_SEEN["$p"]=1
done
[ "${#PHASES_SEEN[@]}" -eq 0 ] && { log "no buildable AFK slices found (all done/HITL?)."; exit 0; }
mapfile -t PHASE_LIST < <(printf '%s\n' "${!PHASES_SEEN[@]}" | sort -n)
log "executor: repo=$REPO_NAME base=$BASE_BRANCH phases=[${PHASE_LIST[*]}] parallel_cap=$PARALLEL_CAP"
RUN_START_EPOCH="$(date +%s 2>/dev/null || echo 0)"
plog run_start repo="$REPO_NAME" phases="${#PHASE_LIST[@]}"
# register this loop so the ONE dashboard finds it (no per-loop terminal needed)
if command -v node >/dev/null 2>&1; then
  node -e 'const fs=require("fs"),os=require("os"),p=require("path");const f=p.join(os.homedir(),".claude","ralph","loops.json");let r={};try{r=JSON.parse(fs.readFileSync(f))}catch{}r[process.argv[1]]=process.argv[2];fs.writeFileSync(f,JSON.stringify(r,null,2))' "$REPO_NAME" "$REPO_ROOT" 2>/dev/null || true
fi
run_minutes() { local now; now="$(date +%s 2>/dev/null || echo 0)"; echo $(( (now - RUN_START_EPOCH) / 60 )); }

# --- preflight collision check: do two lanes in a phase share a file? --------
# Returns the lane->lane merges needed. files_touched is module-level (may be
# imprecise) so this is best-effort; the real guard is that lanes that DO collide
# get serialized into one worktree. We detect overlap on declared files_touched.
preflight_phase() { # preflight_phase <phase>  -> prints "lane:file" footprint lines
  local phase="$1" f p
  for f in "${SLICES[@]}"; do
    is_buildable "$f" || continue
    p="$(fm "$f" phase)"; [ -z "$p" ] && p=1
    [ "$p" = "$phase" ] || continue
    local lane; lane="$(fm "$f" lane)"; [ -z "$lane" ] && lane="core"
    # emit each files_touched entry under this lane
    awk '/^files_touched:/{inb=1;next} inb&&/^[[:space:]]+-/{sub(/^[[:space:]]+-[[:space:]]*/,"");print;next} inb&&/^[^[:space:]]/{inb=0}' "$f" \
      | while read -r path; do [ -n "$path" ] && echo "$lane|$path"; done
  done
}

# Build the lane set for a phase, merging any two lanes that share a footprint path.
lanes_for_phase() { # prints final lane names (post-collision-merge) for <phase>
  local phase="$1"
  local foot; foot="$(preflight_phase "$phase")"
  [ -z "$foot" ] && return
  # union-find over lanes that share a path
  declare -A parent
  _find(){ local x="$1"; while [ "${parent[$x]:-$x}" != "$x" ]; do x="${parent[$x]}"; done; echo "$x"; }
  # union: always point the lexicographically LARGER root at the SMALLER, so the
  # representative is deterministic (smallest lane name in the group).
  _union(){ local a b; a="$(_find "$1")"; b="$(_find "$2")"; [ "$a" = "$b" ] && return
            if [[ "$a" < "$b" ]]; then parent[$b]="$a"; else parent[$a]="$b"; fi; }
  declare -A path_owner
  while IFS='|' read -r lane path; do
    [ -z "$lane" ] && continue
    parent[$lane]="${parent[$lane]:-$lane}"
    if [ -n "${path_owner[$path]:-}" ] && [ "${path_owner[$path]}" != "$lane" ]; then
      log "  preflight: lanes '$lane' + '${path_owner[$path]}' both touch '$path' → SERIALIZING into one lane"
      plog lane_collapsed repo="$REPO_NAME" phase="$phase" lane_a="$lane" lane_b="${path_owner[$path]}" path="$path"
      _union "$lane" "${path_owner[$path]}"
    else
      path_owner[$path]="$lane"
    fi
  done <<< "$foot"
  # emit the representative (root) lane for each distinct lane, deduped + sorted
  declare -A seen
  for lane in "${!parent[@]}"; do seen["$(_find "$lane")"]=1; done
  printf '%s\n' "${!seen[@]}" | sort
}

# Which original lanes collapsed into a representative — so the engine in that
# worktree builds ALL of them (it just reads every matching spec).
LANE_GROUP_OF() { # given phase + a slice's raw lane, print the representative lane
  : # representative computed in run; for spec selection we filter by raw lane set
}

# --- list the spec files belonging to a phase + representative lane group -----
# (a lane-rep may have absorbed colliding lanes; but for status we record per-slice
#  by matching the slice's own lane against the rep — colliding lanes were unioned,
#  so we record every slice whose phase matches and whose lane unions to this rep.)
specs_in_phase_lane() { # <phase> <lane-rep>  -> prints spec file paths
  local phase="$1" rep="$2" f p lane
  for f in "${SLICES[@]}"; do
    is_buildable "$f" || continue
    p="$(fm "$f" phase)"; [ -z "$p" ] && p=1
    [ "$p" = "$phase" ] || continue
    lane="$(fm "$f" lane)"; [ -z "$lane" ] && lane="core"
    # record under this rep if the slice's lane == rep (post-union reps are the
    # smallest-named lane in a collision group; non-colliding lanes are their own rep)
    [ "$lane" = "$rep" ] && echo "$f"
  done
}

# record a Linear status transition for every slice in a lane (intent only — agent flushes)
lane_status() { # <phase> <lane-rep> <state-name>
  local phase="$1" rep="$2" state="$3" f
  command -v node >/dev/null 2>&1 || return 0
  while read -r f; do
    [ -n "$f" ] && node "$HOME/.claude/ralph/linear-status.mjs" "$f" "$state" >>"$EXEC_LOG" 2>&1 || true
  done < <(specs_in_phase_lane "$phase" "$rep")
}

# --- prepare a lane's worktree (synchronous; safe to call before backgrounding) ---
prep_lane() { # prep_lane <phase> <lane-rep> <raw-lanes-csv>
  local phase="$1" rep="$2" raws="$3"
  local wt="../${REPO_NAME}-p${phase}-${rep}"
  local br="ralph/p${phase}-${rep}"
  log "  [p$phase/$rep] worktree $wt  branch $br  (lanes: $raws)"
  lane_status "$phase" "$rep" "In Progress"   # queue: this lane's slices are now building
  [ "${DRYRUN:-}" = "1" ] && return 0
  git worktree add -b "$br" "$wt" "$BASE_BRANCH" >>"$EXEC_LOG" 2>&1 \
    || { git worktree add "$wt" "$br" >>"$EXEC_LOG" 2>&1; }
}

# --- build a lane in its worktree (BACKGROUND this from the main loop with `&`) ---
# Calls the proven per-lane engine; lane-scoped via RALPH_LANE_RAWS. Returns the
# engine's exit code (0 = converged green). MUST be backgrounded by the caller so
# $! is a real child of the main shell (do NOT wrap in $(...)).
# Does EVERY buildable slice in this phase+lane carry `engine: codex`? Then Codex builds it.
# (Any slice without engine:codex → Claude builds the whole lane; mixed lanes stay on Claude
#  to keep one engine per worktree. Default engine = claude when the tag is absent.)
# Free-fallback wiring (ADR-0003): the pure decision fn + governor live in sibling files.
. ~/.claude/ralph/lane-engine-decision.sh 2>/dev/null || true

# Shared spend ledger (ADR-0009): lanes build in worktrees (`cd ../`), but the governor reads
# the executor's ledger. Point BOTH at one ABSOLUTE path so metered lane spend is visible to the
# flip-to-free decision (a relative path would scatter into each worktree's own .ralph/).
export FPR_LEDGER="${FPR_LEDGER:-$(pwd)/.ralph/spend-ledger.jsonl}"
mkdir -p "$(dirname "$FPR_LEDGER")" 2>/dev/null || true

# Ask the governor whether NEW lanes should flip to the free interactive engine.
# Cached per-run so we don't re-sum the ledger for every lane. Off unless FPR_CREDIT_USD set.
_gov_decision=""
governor_decision() { # -> metered | interactive
  [ -n "$_gov_decision" ] && { echo "$_gov_decision"; return; }
  if [ -n "${FPR_CREDIT_USD:-}" ] && [ -x ~/.claude/ralph/governor.sh ]; then
    _gov_decision="$(FPR_LEDGER="${FPR_LEDGER:-.ralph/spend-ledger.jsonl}" ~/.claude/ralph/governor.sh decide "$FPR_CREDIT_USD" 2>/dev/null)"
  fi
  [ -n "$_gov_decision" ] || _gov_decision="metered"
  echo "$_gov_decision"
}

lane_engine() { # <phase> <lane-rep>  -> "codex" | "claude" | "claude-interactive"
  local phase="$1" rep="$2" f any=0 allcodex=1 eng base
  while read -r f; do
    [ -z "$f" ] && continue
    any=1
    eng="$(fm "$f" engine)"; [ -z "$eng" ] && eng="claude"
    [ "$eng" != "codex" ] && allcodex=0
  done < <(specs_in_phase_lane "$phase" "$rep")
  if [ "$any" = "1" ] && [ "$allcodex" = "1" ] && command -v codex >/dev/null 2>&1; then base=codex; else base=claude; fi
  # Apply the free-fallback flip. A lane already mid-build keeps its engine (RUNNING[rep]=1).
  if type lane_engine_decision >/dev/null 2>&1; then
    lane_engine_decision "$base" "$(governor_decision)" "${RUNNING[$rep]:-0}"
  else
    echo "$base"
  fi
}

build_lane() { # build_lane <phase> <lane-rep> <raw-lanes-csv>
  local phase="$1" rep="$2" raws="$3"
  local wt="../${REPO_NAME}-p${phase}-${rep}"
  local eng; eng="$(lane_engine "$phase" "$rep")"
  ( cd "$wt"
    export MAX
    export PORT_OFFSET="$((1000 + RANDOM % 8000))" RALPH_LANE="$rep" RALPH_PHASE="$phase" RALPH_LANE_RAWS="$raws"
    if [ "$eng" = "codex" ]; then
      ~/.claude/ralph/codex-build-lane.sh        # Codex builds — zero Claude tokens
    elif [ "$eng" = "claude-interactive" ]; then
      # FREE fallback (ADR-0003): interactive claude panes, Pool 1, watch-not-drive.
      # Credit ran low → build this lane free instead of burning the metered $200.
      ~/.claude/ralph/ralph-interactive-lane.sh   # interactive (Pool 1) — zero metered credit
    else
      export MODEL="${MODEL:-claude-sonnet-4-6}"
      [ -f PROMPT.md ] || ~/.claude/ralph/ralph.sh --init >/dev/null 2>&1
      ~/.claude/ralph/ralph.sh                    # Claude builds (judgment lanes, metered claude -p)
    fi
  ) >>"$EXEC_LOG" 2>&1
}

# --- merge a lane back, green-gated, in dependency order ---------------------
merge_lane() { # merge_lane <phase> <lane-rep>
  local phase="$1" rep="$2"
  local wt="../${REPO_NAME}-p${phase}-${rep}"
  local br="ralph/p${phase}-${rep}"
  if [ "${NO_MERGE:-}" = "1" ]; then
    log "  [p$phase/$rep] NO_MERGE=1 — leaving branch $br for manual review"; return 0
  fi
  # green gate already enforced by the engine (it only exits 0 on RALPH_COMPLETE+verify).
  lane_status "$phase" "$rep" "In Review"     # queue: lane built green, PR/merge pending

  # ── REVIEW GATE (Superpowers-style, cleared-context) ──────────────────────
  # Tests prove it RUNS; review proves it's RIGHT. The bash executor can't run a
  # review (needs an Agent/MCP subagent), so it ENFORCES the gate: it records a
  # review request and refuses to merge until a verdict file says PASS. The agent
  # performs the actual review (skill: review-clean) + fix loop (skill: receive-review).
  if [ "${SKIP_REVIEW:-}" != "1" ]; then
    mkdir -p .ralph/reviews
    local reqf=".ralph/reviews/p${phase}-${rep}.request"
    local verf=".ralph/reviews/p${phase}-${rep}.verdict"
    {
      echo "phase=$phase lane=$rep branch=$br"
      echo "base=$BASE_SHA_AT_PHASE_START head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo HEAD)"
      echo "specs:"; specs_in_phase_lane "$phase" "$rep" | sed 's/^/  - /'
    } > "$reqf"
    if [ "${DRYRUN:-}" = "1" ]; then
      log "  [p$phase/$rep] REVIEW REQUESTED (dry-run: skipping verdict wait) → $reqf"
    elif [ -f "$verf" ] && grep -qiE '^verdict:[[:space:]]*(pass|merge|yes)' "$verf"; then
      log "  [p$phase/$rep] review verdict: PASS → proceeding to merge"
    else
      # TOKEN-SAVER: try Codex review FIRST (separate process, zero Claude tokens).
      # Codex pass → verdict:pass written here → proceed automatically (no agent round-trip).
      # Codex fail/escalate → hold + the Claude agent reviews/fixes via /review-clean+/receive-review.
      if [ "${REVIEW_ENGINE:-codex}" = "codex" ] && command -v codex >/dev/null 2>&1; then
        log "  [p$phase/$rep] delegating review to Codex (codex review --base)…"
        bash "$HOME/.claude/ralph/codex-review-gate.sh" "$BASE_SHA_AT_PHASE_START" "$verf" "$reqf" >>"$EXEC_LOG" 2>&1 || true
      fi
      if [ -f "$verf" ] && grep -qiE '^verdict:[[:space:]]*(pass|merge|yes)' "$verf"; then
        log "  [p$phase/$rep] Codex review: PASS → proceeding to merge (0 Claude tokens). P2s → follow-up issues."
        plog review repo="$REPO_NAME" lane="$rep" phase="$phase" engine=codex verdict=pass p2="$(grep -c '\[P2\]' "$verf" 2>/dev/null || echo 0)"
      else
        plog review repo="$REPO_NAME" lane="$rep" phase="$phase" engine=codex verdict=hold
        log "  [p$phase/$rep] REVIEW GATE: held ($(grep -i '^verdict:' "$verf" 2>/dev/null || echo 'no verdict')) — Claude must review."
        log "    → Agent: read $verf (Codex findings if any) + run /review-clean on $br vs slice ACs; Critical/unmet-AC → fix in-lane (/receive-review);"
        log "      Important(unresolved)/Minor → follow-up Linear issues; then write 'verdict: pass' to $verf and re-run."
        return 2   # distinct rc: held for Claude review, not a failure
      fi
    fi
  fi

  log "  [p$phase/$rep] merging $br → $BASE_BRANCH"
  if [ "${DRYRUN:-}" = "1" ]; then
    lane_status "$phase" "$rep" "Done"        # dry-run: record the would-be Done so the lifecycle is testable
    return 0
  fi
  git merge --no-ff --no-edit "$br" >>"$EXEC_LOG" 2>&1 || {
    log "  [p$phase/$rep] MERGE CONFLICT — stopping. Resolve $br manually."; return 1; }
  git worktree remove "$wt" --force >>"$EXEC_LOG" 2>&1 || true
  git branch -d "$br" >>"$EXEC_LOG" 2>&1 || true
  lane_status "$phase" "$rep" "Done"          # queue: lane merged to base (real run, post-merge only)
}

# ============================ MAIN: phases in sequence =======================
for phase in "${PHASE_LIST[@]}"; do
  [ -n "${PHASE:-}" ] && [ "$PHASE" != "$phase" ] && continue
  log "═══ PHASE $phase ═══"
  status_write running "$phase" "building lanes"
  BASE_SHA_AT_PHASE_START="$(git rev-parse HEAD 2>/dev/null || echo HEAD)"  # review diff base
  mapfile -t REPS < <(lanes_for_phase "$phase")
  [ "${#REPS[@]}" -eq 0 ] && { log "  (no lanes in phase $phase)"; continue; }
  log "  lanes this phase: ${REPS[*]}"

  # prep all lanes (synchronous worktree setup), then background builds up to PARALLEL_CAP.
  declare -A PID_OF ENG_OF
  for rep in "${REPS[@]}"; do prep_lane "$phase" "$rep" "$rep"; done
  if [ "${DRYRUN:-}" != "1" ]; then
    running=0
    for rep in "${REPS[@]}"; do
      while [ "$running" -ge "$PARALLEL_CAP" ]; do wait -n 2>/dev/null || true; running=$((running-1)); done
      eng="$(lane_engine "$phase" "$rep")"
      log "  [p$phase/$rep] build engine: $eng$([ "$eng" = codex ] && echo ' (0 Claude tokens)')"
      ENG_OF["$rep"]="$eng"
      RUNNING["$rep"]=1                        # mark mid-build (ADR-0003 flip guard)
      build_lane "$phase" "$rep" "$rep" &      # backgrounded in the MAIN shell → real child pid
      PID_OF["$rep"]=$!; running=$((running+1))
    done
    # wait for all lanes; rc 0=green, 2=BLOCKED-needs-human (grill, not red), other=red (stop-on-red)
    fail=0; blocked=0
    for rep in "${REPS[@]}"; do
      wait "${PID_OF[$rep]}"; lrc=$?
      if [ "$lrc" = "0" ]; then
        plog lane_built repo="$REPO_NAME" lane="$rep" phase="$phase" engine="${ENG_OF[$rep]}" result=green
        continue
      fi
      if [ "$lrc" = "2" ]; then
        # agent signalled RALPH_BLOCKED — needs Stone's decision. Surface to monitor → grill.
        blocked=1
        wt="../${REPO_NAME}-p${phase}-${rep}"
        log "  [p$phase/$rep] BLOCKED — agent needs a human decision (see $wt/BLOCKERS.md)"
        plog lane_failed repo="$REPO_NAME" lane="$rep" phase="$phase" engine="${ENG_OF[$rep]}" cause=blocked prevention="agent hit an unspecified decision mid-build — sharpen the spec AC"
        status_write blocked "$phase" "lane '$rep' needs your decision" "$wt/BLOCKERS.md"
        continue
      fi
      # else: a real RED (non-zero, non-block) — classify + capture + stop-on-red
      fail=1
      cp="$(classify_failure "$phase" "$rep")"; cause="${cp%%|*}"; prevent="${cp#*|}"
      log "  [p$phase/$rep] RED — did not converge. cause=$cause"
      log "    why: $prevent"
      plog lane_built  repo="$REPO_NAME" lane="$rep" phase="$phase" engine="${ENG_OF[$rep]}" result=red
      plog lane_failed repo="$REPO_NAME" lane="$rep" phase="$phase" engine="${ENG_OF[$rep]}" cause="$cause" prevention="$prevent"
      # force the failure into the repo's .memory/ (the L3 gotcha) so the next run doesn't repeat it
      mkdir -p .memory
      slug="fail-p${phase}-${rep}-${cause}"
      if [ ! -f ".memory/${slug}.md" ]; then
        {
          echo "---"; echo "name: ${slug}"
          echo "description: lane p${phase}/${rep} failed (${cause}) — ${prevent}"
          echo "metadata:"; echo "  type: gotcha"; echo "---"; echo
          echo "Lane **${rep}** (phase ${phase}, engine ${ENG_OF[$rep]}) went RED on $(printf '%(%Y-%m-%d)T' -1)."
          echo "**Cause:** ${cause}."
          echo "**What could've prevented it:** ${prevent}"
          echo "**Next run:** read this first; if re-attempting this lane, address the prevention above before building."
        } > ".memory/${slug}.md"
        grep -q "${slug}.md" .memory/MEMORY.md 2>/dev/null || echo "- [${slug}.md](${slug}.md) — lane ${rep} failed: ${cause}" >> .memory/MEMORY.md
        log "    captured → .memory/${slug}.md (feedback loop: cause + prevention recorded)"
      fi
    done
    if [ "$blocked" = "1" ]; then
      log "phase $phase: a lane is BLOCKED on a human decision — pausing for the grill."
      log "  → Monitor will grill Stone; he sharpens the spec; re-run the executor to resume."
      plog run_end repo="$REPO_NAME" result=blocked phase="$phase" minutes="$(run_minutes)"
      exit 3   # paused for human (status.json already = blocked, with BLOCKERS path)
    fi
    if [ "$fail" = "1" ]; then
      log "phase $phase had a red lane — halting before merge (stop-on-red guardrail)."
      # surface to the monitor: a failed/blocked lane is exactly when Stone's input helps.
      status_write blocked "$phase" "lane failed ($cause) — needs your input" ".ralph/${slug:-fail}.md"
      plog run_end repo="$REPO_NAME" result=failed phase="$phase" minutes="$(run_minutes)"
      exit 1
    fi
  fi

  # merge lanes back, green only, in lane name order (deterministic).
  # merge_lane rc: 0=merged, 1=real failure (conflict) → halt, 2=HELD for review → pause.
  held=0
  for rep in "${REPS[@]}"; do
    merge_lane "$phase" "$rep"; rc=$?
    case "$rc" in
      0) : ;;
      2) held=1 ;;                       # review gate holding this lane — not a failure
      *) log "phase $phase: merge failed (rc=$rc) — halting."; exit 1 ;;
    esac
  done
  if [ "$held" = "1" ]; then
    log "═══ PHASE $phase PAUSED: lane(s) awaiting review verdict. ═══"
    log "  → Agent: review each held lane (.ralph/reviews/*.request), write 'verdict: pass' when clear, re-run the executor to resume + merge."
    status_write held "$phase" "lane(s) awaiting review verdict"
    plog run_end repo="$REPO_NAME" result=paused reason=lane_review phase="$phase" minutes="$(run_minutes)"
    exit 3   # distinct rc: paused for review (not done, not failed)
  fi
  # phase fully merged → review the COMBINED phase diff (cross-lane integration check)
  if [ "${SKIP_REVIEW:-}" != "1" ] && [ "${DRYRUN:-}" != "1" ]; then
    pverf=".ralph/reviews/phase${phase}-combined.verdict"
    preq=".ralph/reviews/phase${phase}-combined.request"
    if [ -f "$pverf" ] && grep -qiE '^verdict:[[:space:]]*(pass|merge|yes)' "$pverf"; then
      log "  phase $phase combined-diff review: PASS"
    else
      mkdir -p .ralph/reviews
      echo "phase=$phase combined base=$BASE_SHA_AT_PHASE_START head=$(git rev-parse HEAD)" > "$preq"
      # token-saver: Codex reviews the combined phase diff first
      if [ "${REVIEW_ENGINE:-codex}" = "codex" ] && command -v codex >/dev/null 2>&1; then
        log "  phase $phase: delegating combined-diff review to Codex…"
        bash "$HOME/.claude/ralph/codex-review-gate.sh" "$BASE_SHA_AT_PHASE_START" "$pverf" "$preq" >>"$EXEC_LOG" 2>&1 || true
      fi
      if [ -f "$pverf" ] && grep -qiE '^verdict:[[:space:]]*(pass|merge|yes)' "$pverf"; then
        log "  phase $phase combined-diff review: PASS (Codex, 0 Claude tokens) → releasing next phase."
      else
        log "  → Agent: review the COMBINED phase $phase diff (cross-lane integration) via /review-clean (Codex held: $(grep -i '^verdict:' "$pverf" 2>/dev/null || echo none)); write 'verdict: pass' to $pverf to release the next phase."
        log "═══ PHASE $phase merged but combined-review PENDING ═══"
        status_write held "$phase" "combined-phase review pending"
        plog run_end repo="$REPO_NAME" result=paused reason=phase_review phase="$phase" minutes="$(run_minutes)"
        exit 3
      fi
    fi
  fi
  log "═══ PHASE $phase complete + merged + reviewed ═══"
done
log "ALL PHASES COMPLETE. Combined diff on $BASE_BRANCH."
log "  → FINAL GATE: run /review-clean on the FULL feature diff, then /qa-plan for the human pass."
status_write done "" "all phases complete + reviewed"
plog run_end repo="$REPO_NAME" result=done phases="${#PHASE_LIST[@]}" minutes="$(run_minutes)"
if [ -f .ralph/linear-queue.jsonl ] && [ "${NO_MERGE:-}" != "1" ]; then
  n="$(wc -l < .ralph/linear-queue.jsonl 2>/dev/null | tr -d ' ')"
  log "LINEAR FLUSH PENDING: $n status transitions queued in .ralph/linear-queue.jsonl."
  log "  → The agent must now flush them to Linear via MCP (save_issue per intent), then truncate the queue."
  log "  → See the ralph skill 'Linear flush' section. Scripts can't write Linear (guardrail); the agent does."
fi
exit 0
