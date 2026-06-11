#!/usr/bin/env bash
# End-to-end wiring: with an over-threshold ledger + FPR_CREDIT_USD set, ralph-exec's
# lane_engine() returns claude-interactive for a NEW claude lane, and 'claude' for a
# lane marked already-running. Exercises the REAL functions from ralph-exec.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RALPH="$HERE/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# Build a tiny repo with one claude-tagged lane spec.
cd "$TMP"
git init -q; git config user.email t@t; git config user.name t
mkdir -p specs .ralph
cat > specs/api.md <<'EOF'
---
phase: 1
lane: api
---
Build the API.
EOF
git add -A; git commit -qm base

# Over-threshold ledger: $170 on a $200 credit (85%).
echo '{"total_cost_usd": 170}' > .ralph/spend-ledger.jsonl

# Source just the helpers we need from ralph-exec.sh without running its MAIN loop.
# We replicate the minimal env the functions reference, then pull in the lib + governor wiring.
export FPR_CREDIT_USD=200 FPR_LEDGER="$PWD/.ralph/spend-ledger.jsonl"
. "$RALPH/lane-engine-decision.sh"
declare -A RUNNING
_gov_decision=""
governor_decision() {
  [ -n "$_gov_decision" ] && { echo "$_gov_decision"; return; }
  _gov_decision="$(FPR_LEDGER="$FPR_LEDGER" "$RALPH/governor.sh" decide "$FPR_CREDIT_USD" 2>/dev/null)"
  [ -n "$_gov_decision" ] || _gov_decision="metered"
  echo "$_gov_decision"
}
# Minimal stand-ins for the two helpers lane_engine calls.
fm() { awk -v k="$2" '/^---[[:space:]]*$/{n++;next} n==1 && $0 ~ "^"k":"{sub("^"k":[[:space:]]*","");print;exit}' "$1"; }
specs_in_phase_lane() { ls specs/*.md 2>/dev/null; }

# Paste the REAL lane_engine body by sourcing it out of ralph-exec.sh (extract the function).
eval "$(awk '/^lane_engine\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$RALPH/ralph-exec.sh")"

# Case 1: governor over threshold + NEW lane -> claude-interactive
RUNNING=()
got="$(lane_engine 1 api)"
[ "$got" = "claude-interactive" ] || fail "new lane over-threshold expected claude-interactive, got '$got'"

# Case 2: same lane marked already-running -> stays claude (finish on metered)
_gov_decision=""   # reset cache
RUNNING[api]=1
got="$(lane_engine 1 api)"
[ "$got" = "claude" ] || fail "running lane must stay claude, got '$got'"

# Case 3: under threshold ($100/$200) -> claude
echo '{"total_cost_usd": 100}' > .ralph/spend-ledger.jsonl
_gov_decision=""; RUNNING=()
got="$(lane_engine 1 api)"
[ "$got" = "claude" ] || fail "under threshold expected claude, got '$got'"

echo "PASS: test_exec_integration (3 cases — real lane_engine + governor + lib)"
