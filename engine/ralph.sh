#!/usr/bin/env bash
# ralph.sh — global fresh-context autonomous loop driver.
# Run from inside a project dir. Reads ./PROMPT.md, feeds it to headless Claude
# with a FRESH context each iteration, and stops when the build/tests pass AND
# the model emits the RALPH_COMPLETE sentinel (or MAX iterations hit).
#
# The done-gate hook is bypassed inside the loop (CLAUDE_SKIP_DONE_GATE=1) because
# THIS script owns the gate — see verify() below.
#
# Usage:   cd your-project && ~/.claude/ralph/ralph.sh
# Env:     MAX=40  VERIFY="pnpm build && pnpm test"  MODEL=claude-sonnet-4-6
#
# Requires PROMPT.md in cwd. Template written by `ralph.sh --init`.
set -uo pipefail

if [ "${1:-}" = "--init" ]; then
  [ -f PROMPT.md ] && { echo "PROMPT.md already exists"; exit 1; }
  cat > PROMPT.md <<'EOF'
# Ralph task

You are running in an autonomous loop with a FRESH context each iteration.

OUTPUT TERSE (token discipline): your narration is overhead — the artifacts (code, tests,
commits, git) are the real output. Drop articles/filler/pleasantries/hedging; fragments fine;
don't pre-explain or recap. Code/tests/commands/errors EXACT — never compress those. Full clear
prose only for: a BLOCKERS.md entry, a commit message, a `.memory/` gotcha, any destructive command.

The current work items and the last 5 commits are INJECTED below this prompt each
iteration (sections "Current work items" and "Recently done") — read them THERE,
do not waste context re-opening those files just to see the list.

1. From the injected work items, pick the FIRST unchecked / not-yet-Done item (lowest phase first).
2. Implement ONLY that item. Small, atomic, one commit. Test-FIRST (write the failing test, see it RED, then GREEN).
3. Run the full build + tests yourself. Do not claim done until they pass.
4. Mark the item done (check it off / set status) and commit.
5. If ALL items are done and the full build+tests pass, print exactly:
   RALPH_COMPLETE
   on its own line and stop.

Rules:
- Behavioral acceptance criteria first. No item is done until its test passes.
- Never delete or weaken a test to make it pass. Prove RED before GREEN.
- The "Recently done" commits are your only memory of prior iterations — use them, don't redo finished work.
- If a task needs a HUMAN DECISION you cannot make (an unspecified product rule, an ambiguous AC
  with multiple valid answers) — do NOT guess and do NOT loop. Write BLOCKERS.md stating EXACTLY
  what decision you need + the options you see, then print RALPH_BLOCKED on its own line and stop.
  A human (via the monitor) will sharpen the spec; the next iteration picks up the answer.
- If blocked on something non-human (a flaky dep), write BLOCKERS.md and move to the next item.
EOF
  [ -f IMPLEMENTATION_PLAN.md ] || cat > IMPLEMENTATION_PLAN.md <<'EOF'
# Implementation plan
- [ ] First atomic, testable unit of work
- [ ] Second unit
EOF
  echo "Wrote PROMPT.md + IMPLEMENTATION_PLAN.md. Edit them, then run: ~/.claude/ralph/ralph.sh"
  exit 0
fi

[ -f PROMPT.md ] || { echo "No PROMPT.md in $(pwd). Run: ~/.claude/ralph/ralph.sh --init"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "claude CLI not found in PATH"; exit 1; }

# Spend-ledger writer (ADR-0009 measure-first): records this metered loop's real cost so the
# governor's flip-to-free decision has data to read. No-op if the helper is missing.
. ~/.claude/ralph/ledger-record.sh 2>/dev/null || {
  ledger_record_from_json() { :; }; ledger_result_text() { :; }
}

MAX="${MAX:-40}"
MODEL="${MODEL:-claude-sonnet-4-6}"
LOG="ralph.log"
: > "$LOG"

# Structured timing events for the monitor's velocity panel (ralph-watch.sh).
# One JSONL line per event; best-effort, never aborts the loop.
mkdir -p .ralph 2>/dev/null || true
ev() { # ev <name> [iter]
  printf '{"ev":"%s","i":%s,"max":%s,"lane":"%s","ts":%s}\n' \
    "$1" "${2:-0}" "$MAX" "${RALPH_LANE:-}" "$(printf '%(%s)T' -1)" >> .ralph/events.jsonl 2>/dev/null || true
}

# Auto-detect a verify command if not provided.
if [ -z "${VERIFY:-}" ]; then
  if [ -f package.json ]; then
    PM="npm"; [ -f pnpm-lock.yaml ] && PM="pnpm"; [ -f yarn.lock ] && PM="yarn"
    VERIFY="$PM run build 2>/dev/null; $PM test"
  elif [ -f pyproject.toml ] || [ -f pytest.ini ]; then
    PY="python"; [ -x .venv/Scripts/python ] && PY=".venv/Scripts/python"; [ -x .venv/bin/python ] && PY=".venv/bin/python"
    VERIFY="$PY -m pytest -q"
  else
    VERIFY="true"; echo "WARNING: no test harness detected — loop has NO real done-gate." | tee -a "$LOG"
  fi
fi
echo "verify command: $VERIFY" | tee -a "$LOG"

verify() { bash -c "$VERIFY" >>"$LOG" 2>&1; }

# --- Context injection (Matt Pocock once.sh pattern) -------------------------
# Each iteration runs with a FRESH context (Memento principle). Inject two cheap,
# high-signal blocks so the agent knows the work list + what was just done,
# without bloating context by making it re-discover them.
#
#   ISSUES_BLOCK  = the current work items grepped from spec/issue .md files.
#   COMMITS_BLOCK = last 5 commits (minimal memory of recent progress).
#
# Both are rebuilt every iteration (issues get checked off / commits accrue).
# Toggle off with RALPH_NO_INJECT=1.

build_issues_block() {
  [ "${RALPH_NO_INJECT:-}" = "1" ] && return
  # Prefer phased spec slices (specs/*.md); fall back to IMPLEMENTATION_PLAN.md.
  local files=""
  [ -d specs ] && files="$(ls specs/*.md 2>/dev/null | grep -v -i 'README' || true)"
  [ -z "$files" ] && [ -f IMPLEMENTATION_PLAN.md ] && files="IMPLEMENTATION_PLAN.md"
  [ -z "$files" ] && return
  # Lane scoping: when run under the worktree executor, RALPH_LANE_RAWS is a
  # space-separated set of lane names this worktree owns. Build ONLY slices whose
  # `lane:` frontmatter is in that set (so parallel lanes don't all build everything).
  # No RALPH_LANE_RAWS set → build all (standalone single-loop behavior, unchanged).
  printf '\n\n## Current work items (from .md files — do NOT re-read these, they are here)\n'
  if [ -n "${RALPH_LANE_RAWS:-}" ]; then
    printf 'Build ONLY items in lane(s): %s. Ignore slices tagged other lanes.\n' "$RALPH_LANE_RAWS"
  fi
  # shellcheck disable=SC2086
  for f in $files; do
    if [ -n "${RALPH_LANE_RAWS:-}" ] && [ "$f" != "IMPLEMENTATION_PLAN.md" ]; then
      local lane; lane="$(awk '/^---[[:space:]]*$/{n++;next} n==1&&/^lane:/{sub(/^lane:[[:space:]]*/,"");gsub(/[[:space:]]+$/,"");print;exit}' "$f")"
      [ -z "$lane" ] && lane="core"
      case " $RALPH_LANE_RAWS " in *" $lane "*) : ;; *) continue ;; esac
    fi
    printf '\n### %s\n' "$f"
    cat "$f"
  done
}

build_commits_block() {
  [ "${RALPH_NO_INJECT:-}" = "1" ] && return
  git rev-parse --git-dir >/dev/null 2>&1 || return
  printf '\n\n## Recently done (last 5 commits — your only memory of prior iterations)\n'
  git log -5 --pretty=format:'- %h %s' 2>/dev/null
  printf '\n'
}

for i in $(seq 1 "$MAX"); do
  echo "===== iteration $i / $MAX  $(printf '%(%H:%M:%S)T' -1) =====" | tee -a "$LOG"
  ev iter_start "$i"
  # Rebuild the injected prompt fresh each iteration: PROMPT.md + live work items + recent commits.
  PROMPT_FULL="$(cat PROMPT.md; build_issues_block; build_commits_block)"
  # Metered Pool-2 call. --output-format json so we can record real total_cost_usd to the
  # spend ledger (the governor's flip-to-free decision reads it). stderr → log, NOT merged
  # into stdout (that would corrupt the JSON envelope).
  RAW="$(printf '%s' "$PROMPT_FULL" | CLAUDE_SKIP_DONE_GATE=1 claude -p \
        --model "$MODEL" --output-format json \
        --dangerously-skip-permissions 2>>"$LOG")"
  # Record metered spend (no-op if no parseable cost). Measure-first (ADR-0009).
  ledger_record_from_json "$RAW"
  # Sentinels live in the model's final text. Pull .result off the envelope; fall back to RAW
  # if it isn't JSON (older CLI / error) so convergence detection never silently breaks.
  OUT="$(ledger_result_text "$RAW")"; [ -n "$OUT" ] || OUT="$RAW"
  [ -n "$OUT" ] || echo "WARNING: empty model output (see stderr in $LOG)" | tee -a "$LOG"
  printf '%s\n' "$OUT" >> "$LOG"
  ev iter_end "$i"

  if printf '%s' "$OUT" | grep -q 'RALPH_COMPLETE'; then
    echo "model signalled RALPH_COMPLETE — verifying for real..." | tee -a "$LOG"
    if verify; then
      echo "CONVERGED at iteration $i. Build+tests green." | tee -a "$LOG"
      ev complete "$i"
      exit 0
    fi
    echo "model claimed done but verify FAILED — continuing." | tee -a "$LOG"
  fi

  # Block sentinel: if the agent writes BLOCKERS.md and emits RALPH_BLOCKED, stop NOW (don't
  # burn MAX iterations re-trying an unanswerable slice). Exit 2 = blocked-needs-human (distinct
  # from 1 = didn't-converge). The executor's classify_failure reads BLOCKERS.md → 'blocked'.
  if printf '%s' "$OUT" | grep -q 'RALPH_BLOCKED' || [ -f BLOCKERS.md ]; then
    echo "model signalled RALPH_BLOCKED (BLOCKERS.md present) — stopping for human input." | tee -a "$LOG"
    ev blocked "$i"
    exit 2
  fi
done
ev max_out "$MAX"
echo "Hit MAX=$MAX iterations without convergence. Review $LOG and IMPLEMENTATION_PLAN.md." | tee -a "$LOG"
exit 1
