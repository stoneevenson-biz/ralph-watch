#!/usr/bin/env bash
# ralph-delegate.sh — spec-loop with per-task CLAUDE/CODEX delegation.
#
# Reads ./IMPLEMENTATION_PLAN.md. Each task line routes by tag:
#   - [ ] (codex)  <desc>   → implemented by `codex exec`  (cheap grunt work)
#   - [ ] (claude) <desc>   → implemented by `claude -p`   (judgment work)
#   - [ ] <desc>            → defaults to claude
# After each task, runs the verify gate (tests). Checks the box [x] ONLY if green.
# Fresh process per task = context conservation. Stops when all done or MAX hit.
#
# Usage:   cd project && ~/.claude/ralph/ralph-delegate.sh
#          ~/.claude/ralph/ralph-delegate.sh --init     # scaffold a tagged plan
#          ~/.claude/ralph/ralph-delegate.sh --plan-only # show routing, run nothing
# Env:     MAX=40  VERIFY="pnpm test"  CLAUDE_MODEL=claude-sonnet-4-6
set -uo pipefail

PLAN="IMPLEMENTATION_PLAN.md"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"

if [ "${1:-}" = "--init" ]; then
  [ -f "$PLAN" ] && { echo "$PLAN already exists"; exit 1; }
  cat > "$PLAN" <<'EOF'
# Implementation plan (tagged for delegation)
# (codex)  = mechanical / well-scoped → runs on Codex (saves Claude tokens)
# (claude) = judgment / ambiguous     → runs on Claude (you watch)
# untagged = defaults to claude

- [ ] (codex) First mechanical, testable task — clear inputs/outputs
- [ ] (claude) A task needing design judgment
- [ ] (codex) Another well-scoped unit
EOF
  echo "Wrote $PLAN. Edit it (tag each task), then run: ~/.claude/ralph/ralph-delegate.sh"
  exit 0
fi

[ -f "$PLAN" ] || { echo "No $PLAN in $(pwd). Run with --init first."; exit 1; }

# --- auto-detect verify gate (same logic as ralph.sh) ---
if [ -z "${VERIFY:-}" ]; then
  if [ -f package.json ]; then
    PM="npm"; [ -f pnpm-lock.yaml ] && PM="pnpm"; [ -f yarn.lock ] && PM="yarn"
    VERIFY="$PM run build 2>/dev/null; $PM test"
  elif [ -f pyproject.toml ] || [ -f pytest.ini ]; then
    PY="python"; [ -x .venv/Scripts/python ] && PY=".venv/Scripts/python"; [ -x .venv/bin/python ] && PY=".venv/bin/python"
    VERIFY="$PY -m pytest -q"
  else
    VERIFY="true"; echo "WARNING: no test harness detected — loop has NO real done-gate."
  fi
fi

# --- smoke-test codex; fall back to claude-only if unusable (per autopilot skill) ---
CODEX_OK=0
if command -v codex >/dev/null 2>&1; then
  if printf 'reply CODEX_OK' | timeout 60 codex exec --skip-git-repo-check 2>/dev/null | grep -q CODEX_OK; then
    CODEX_OK=1
  fi
fi
[ "$CODEX_OK" = "1" ] && echo "codex: usable — delegation ON" || echo "codex: unusable — ALL tasks fall back to claude"

# --- parse the first unchecked task: returns "engine<TAB>verifycmd<TAB>description" ---
# A task may carry its OWN gate:  - [ ] (codex) {verify: bash tests/test-X.sh} do the thing
# When present, THAT command is the done-gate for this task (not the global suite).
# When absent, the global $VERIFY is used.
next_task() {
  grep -nE '^- \[ \] ' "$PLAN" | head -1 | sed -E 's/^([0-9]+):- \[ \] //' | {
    IFS= read -r line || return 1
    local engine="claude" desc="$line" vcmd=""
    case "$line" in
      \(codex\)*)  engine="codex";  desc="${line#\(codex\)}" ;;
      \(claude\)*) engine="claude"; desc="${line#\(claude\)}" ;;
    esac
    [ "$CODEX_OK" = "0" ] && engine="claude"
    desc="$(printf '%s' "$desc" | sed -E 's/^ +//')"
    # extract an optional {verify: ...} block
    case "$desc" in
      \{verify:*\}*)
        vcmd="$(printf '%s' "$desc" | sed -E 's/^\{verify:[[:space:]]*//; s/\}.*$//')"
        desc="$(printf '%s' "$desc" | sed -E 's/^\{verify:[^}]*\}[[:space:]]*//')"
        ;;
    esac
    printf '%s\t%s\t%s\n' "$engine" "$vcmd" "$desc"
  }
}

check_off_first() { # mark the first unchecked box done
  local tmp; tmp="$(mktemp)"
  awk 'done!=1 && /^- \[ \] /{sub(/^- \[ \] /,"- [x] "); done=1} {print}' "$PLAN" > "$tmp" && mv "$tmp" "$PLAN"
}

run_claude() { printf '%s\n' "$1" | claude -p --model "$CLAUDE_MODEL" --dangerously-skip-permissions 2>&1; }
run_codex()  { printf '%s\n' "$1" | timeout 1200 codex exec -s workspace-write --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check 2>&1; }

verify() { bash -c "${1:-$VERIFY}" >/tmp/ralph_verify.log 2>&1; }

if [ "${1:-}" = "--plan-only" ]; then
  echo "=== routing plan (no execution) ==="
  echo "global gate (fallback): $VERIFY"
  grep -nE '^- \[ \] ' "$PLAN" | sed -E 's/^([0-9]+):- \[ \] //' | while IFS= read -r l; do
    e="claude"; case "$l" in \(codex\)*) e="codex";; \(claude\)*) e="claude";; esac
    [ "$CODEX_OK" = "0" ] && e="claude(forced)"
    g="(global gate)"; case "$l" in *\{verify:*\}*) g="$(printf '%s' "$l" | sed -E 's/.*\{verify:[[:space:]]*//; s/\}.*//')";; esac
    printf '  [%s] gate=[%s]\n        %s\n' "$e" "$g" "$(printf '%s' "$l" | sed -E 's/\{verify:[^}]*\}[[:space:]]*//')"
  done
  exit 0
fi

MAX="${MAX:-40}"
TASK_PROMPT_PREFIX="You are one iteration of an autonomous spec-loop with FRESH context. Implement ONLY this task, fully and atomically. Run the project's tests yourself. Do not weaken tests. Task:"

for i in $(seq 1 "$MAX"); do
  # stop cleanly when no unchecked tasks remain
  grep -qE '^- \[ \] ' "$PLAN" || { echo "ALL TASKS DONE. Loop complete."; exit 0; }
  rec="$(next_task)" || { echo "no parseable task line"; break; }
  [ -z "$rec" ] && { echo "ALL TASKS DONE. Loop complete."; exit 0; }
  engine="${rec%%$'\t'*}"; rest="${rec#*$'\t'}"
  vcmd="${rest%%$'\t'*}"; desc="${rest#*$'\t'}"
  gate="${vcmd:-$VERIFY}"
  echo "===== iter $i/$MAX  →  [$engine]  $desc ====="
  echo "       gate: $gate"

  if [ "$engine" = "codex" ]; then
    run_codex "$TASK_PROMPT_PREFIX $desc

This task's done-gate is: $gate — it must exit 0 before you are done." | tail -20
  else
    run_claude "$TASK_PROMPT_PREFIX $desc

This task's done-gate is: $gate — it must exit 0 before you are done." | tail -20
  fi

  if verify "$gate"; then
    echo "  ✓ gate green — checking off."
    check_off_first
  else
    echo "  ✗ gate FAILED for: $desc"
    echo "  (task left unchecked. Review /tmp/ralph_verify.log. Stopping to avoid looping on a broken task.)"
    exit 1
  fi
done
echo "Hit MAX=$MAX. Remaining tasks unchecked in $PLAN."
