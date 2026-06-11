#!/usr/bin/env bash
# test_worktree_hook.sh — AC-2 for PRD-ENGINE-04
# Feeds fake tool-input JSON to worktree-hook.sh for 6 boundary cases.
# Hook exit 0 = ALLOW, exit 2 = DENY.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_DIR="$(dirname "$SCRIPT_DIR")"
HOOK="$RALPH_DIR/worktree-hook.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# ── Setup temp dirs ──────────────────────────────────────────────────────────
WORKTREE=$(mktemp -d)
mkdir -p "$WORKTREE/src"
touch "$WORKTREE/src/x"

OUTSIDE=$(mktemp -d)
touch "$OUTSIDE/secret.txt"

# Resolve to canonical paths (important on macOS with /var → /private/var)
WORKTREE="$(cd "$WORKTREE" && pwd)"
OUTSIDE="$(cd "$OUTSIDE" && pwd)"

trap 'rm -rf "$WORKTREE" "$OUTSIDE"' EXIT

# Helper: run hook with JSON, assert exit code
run_hook() {
  local label="$1"
  local input_json="$2"
  local expect="$3"  # "allow" or "deny"

  local actual_exit=0
  WORKTREE_ROOT="$WORKTREE" bash "$HOOK" <<< "$input_json" 2>/dev/null || actual_exit=$?

  if [ "$expect" = "allow" ]; then
    [ "$actual_exit" -eq 0 ] || fail "$label: expected ALLOW (exit 0) but got exit $actual_exit"
    pass "$label: ALLOW"
  else
    [ "$actual_exit" -eq 2 ] || fail "$label: expected DENY (exit 2) but got exit $actual_exit"
    pass "$label: DENY"
  fi
}

# ── Case 1: in-worktree rm → ALLOW ───────────────────────────────────────────
run_hook "in-worktree rm" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm $WORKTREE/src/x\"}}" \
  "allow"

# ── Case 2: out-of-worktree rm → DENY ────────────────────────────────────────
run_hook "out-of-worktree rm" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm $OUTSIDE/secret.txt\"}}" \
  "deny"

# ── Case 3: in-worktree Read → ALLOW ─────────────────────────────────────────
run_hook "in-worktree read" \
  "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$WORKTREE/src/x\"}}" \
  "allow"

# ── Case 4: .env file Read → DENY ────────────────────────────────────────────
touch "$WORKTREE/.env"
run_hook "secret .env read" \
  "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$WORKTREE/.env\"}}" \
  "deny"

# ── Case 5: in-worktree Write → ALLOW ────────────────────────────────────────
run_hook "in-worktree write" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORKTREE/src/new.ts\"}}" \
  "allow"

# ── Case 6: out-of-worktree Write → DENY ─────────────────────────────────────
run_hook "out-of-worktree write" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$OUTSIDE/evil.ts\"}}" \
  "deny"

echo ""
echo "ALL AC-2 CHECKS PASSED"
