#!/usr/bin/env bash
# ralph-interactive-lane.sh — FREE per-lane engine (ADR-0003). Sibling to codex-build-lane.sh.
# Runs inside a worktree (cwd). Builds this lane's specs using INTERACTIVE claude (Pool 1 = FREE),
# one FRESH session PER SPEC (honors ralph's fresh-context rule), Sonnet (stretch free quota).
#
# WATCH-NOT-DRIVE: an interactive claude TUI cannot be driven by this script. So per spec we:
#   1. seed .fpr/current-spec.md (the inner ralph-interactive-stop-hook.sh re-feeds it until green)
#   2. launch a fresh interactive claude pane in this worktree
#   3. POLL .fpr/last-spec-status until 'done'|'failed' (or timeout) — the only channel out
#   4. advance to the next spec (new pane = fresh context)
#
# Lane scoping: RALPH_LANE_RAWS (space-separated lane names) like ralph.sh. Default = all specs.
# Env: RALPH_PHASE, RALPH_LANE, MAX (per-spec iter cap), DRYRUN=1 (print plan, launch nothing),
#      FPR_MODEL (default claude-sonnet-4-6), FPR_POLL_TIMEOUT (sec/spec, default 1800),
#      FPR_BACKEND (wt|detached, default wt).

set -uo pipefail
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
MODEL="${FPR_MODEL:-claude-sonnet-4-6}"
HOOK="$(cd "$(dirname "$0")" && pwd)/ralph-interactive-stop-hook.sh"
MAXIT="${MAX:-20}"
POLL_TIMEOUT="${FPR_POLL_TIMEOUT:-1800}"
BACKEND="${FPR_BACKEND:-wt}"
PROMISE="RALPH_COMPLETE"

lane_of() { awk '/^---[[:space:]]*$/{n++;next} n==1&&/^lane:/{sub(/^lane:[[:space:]]*/,"");gsub(/[[:space:]]+$/,"");print;exit}' "$1"; }
verify_of() { awk '/^---[[:space:]]*$/{n++;next} n==1&&/^verify:/{sub(/^verify:[[:space:]]*/,"");gsub(/^"|"$/,"");print;exit}' "$1"; }

# Collect this lane's specs (phase-agnostic here; the executor scopes phase by which specs exist).
specs=()
if [ -d specs ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in *README*) continue;; esac
    if [ -n "${RALPH_LANE_RAWS:-}" ]; then
      l="$(lane_of "$f")"; [ -z "$l" ] && l="core"
      case " $RALPH_LANE_RAWS " in *" $l "*) : ;; *) continue ;; esac
    fi
    specs+=("$f")
  done < <(ls specs/*.md 2>/dev/null | grep -v -i 'README' || true)
fi

[ "${#specs[@]}" -gt 0 ] || { echo "fpr: no specs for lane ${RALPH_LANE:-?} — nothing to build"; exit 0; }

mkdir -p .fpr
rc_overall=0

for spec in "${specs[@]}"; do
  vfy="$(verify_of "$spec")"; [ -z "$vfy" ] && vfy="true"
  body="$(awk '/^---[[:space:]]*$/{n++;next} n>=2' "$spec")"
  # Seed the inner-loop state file for THIS spec.
  rm -f .fpr/last-spec-status
  cat > .fpr/current-spec.md <<EOF
---
iteration: 1
max_iterations: $MAXIT
completion_promise: "$PROMISE"
verify: "$vfy"
session_id: ""
---
$body

When the work is done AND the verify command passes, output exactly: <promise>$PROMISE</promise>
Do NOT spawn \`claude -p\`. Build only this spec.
EOF

  # Resolve the lane-adapter-driver relative to this script.
  DRIVER="$(cd "$(dirname "$0")" && pwd)/lane-adapter-driver.mjs"
  if [ "${DRYRUN:-}" = "1" ]; then
    echo "LAUNCH-SPEC spec=$spec verify='$vfy' backend=$BACKEND model=$MODEL"
    echo "LAUNCH-ADAPTER: node $DRIVER --cwd $PWD --spec .fpr/current-spec.md --fpr .fpr --model $MODEL (plain claude, no --dangerously-skip-permissions)"
    echo "done" > .fpr/last-spec-status   # simulate convergence so the loop advances in dryrun
  else
    # Fresh INTERACTIVE session via LaneAdapter (Pool 1). Spawns plain `claude`, no skip-perms.
    case "$BACKEND" in
      wt)
        wt.exe new-tab --title "${RALPH_LANE:-lane}:$(basename "$spec")" -d "$PWD" \
          powershell.exe -NoExit -Command \
          "node '$DRIVER' --cwd '$PWD' --spec '.fpr/current-spec.md' --fpr '.fpr' --model '$MODEL'" \
          >/dev/null 2>&1 || echo "fpr: wt launch failed for $spec" >&2
        ;;
      node-adapter)
        # Headless (no GUI terminal) — run the driver inline in this process.
        node "$DRIVER" --cwd "$PWD" --spec ".fpr/current-spec.md" --fpr ".fpr" --model "$MODEL" &
        ;;
      detached)
        # remote/SSH path needs a PTY (winpty/tmux) — DEFERRED per ADR-0003. Warn loudly.
        echo "fpr: BACKEND=detached needs a PTY wrapper (winpty/tmux) — not yet implemented (ADR-0003)." >&2
        ;;
    esac
    # WATCH-NOT-DRIVE: poll the status file the inner hook writes.
    waited=0
    while [ ! -f .fpr/last-spec-status ] && [ "$waited" -lt "$POLL_TIMEOUT" ]; do
      sleep 5; waited=$((waited+5))
    done
    st="$(cat .fpr/last-spec-status 2>/dev/null || echo timeout)"
    echo "fpr: spec $(basename "$spec") -> $st (waited ${waited}s)"
    [ "$st" = "done" ] || rc_overall=1
  fi
done

[ "$rc_overall" = "0" ] && echo "fpr: lane ${RALPH_LANE:-?} converged (all specs done)" || echo "fpr: lane ${RALPH_LANE:-?} had non-green specs"
exit "$rc_overall"
