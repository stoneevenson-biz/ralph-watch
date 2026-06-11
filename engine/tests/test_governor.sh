#!/usr/bin/env bash
# AC-2: governor.sh flips at >=80% of the monthly credit.
# RED first: governor.sh does not exist yet -> this must FAIL before implementation.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GOV="$HERE/../governor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LEDGER="$TMP/spend.jsonl"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Ledger format: one JSON per run with total_cost_usd. Governor sums them.
seed() { : > "$LEDGER"; for c in "$@"; do echo "{\"total_cost_usd\": $c}" >> "$LEDGER"; done; }

# Case 1: $161 spent on a $200 credit (80.5%) -> interactive
seed 100 61
out="$(FPR_LEDGER="$LEDGER" bash "$GOV" decide 200)" || fail "governor errored (case1)"
[ "$out" = "interactive" ] || fail "case1: \$161/\$200 expected interactive, got '$out'"

# Case 2: $100 spent (50%) -> metered
seed 60 40
out="$(FPR_LEDGER="$LEDGER" bash "$GOV" decide 200)" || fail "governor errored (case2)"
[ "$out" = "metered" ] || fail "case2: \$100/\$200 expected metered, got '$out'"

# Case 3: exactly $160 (80.0% boundary, >=) -> interactive
seed 160
out="$(FPR_LEDGER="$LEDGER" bash "$GOV" decide 200)" || fail "governor errored (case3)"
[ "$out" = "interactive" ] || fail "case3: \$160/\$200 boundary expected interactive, got '$out'"

# Case 4: empty/missing ledger -> metered (nothing spent)
: > "$LEDGER"
out="$(FPR_LEDGER="$LEDGER" bash "$GOV" decide 200)" || fail "governor errored (case4)"
[ "$out" = "metered" ] || fail "case4: empty ledger expected metered, got '$out'"

echo "PASS: test_governor (4 cases)"
