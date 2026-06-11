#!/usr/bin/env bash
# AC-1/AC-3: the ledger writer records real total_cost_usd from a `claude -p --output-format
# json` envelope so the governor has spend to read; garbage/no-cost is a no-op (never aborts).
# AC-2 is structural: only ralph.sh's metered `claude -p` calls this writer — codex and
# interactive engines never invoke it (verified by grep below).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REC="$HERE/../ledger-record.sh"
GOV="$HERE/../governor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LEDGER="$TMP/spend.jsonl"

fail() { echo "FAIL: $1" >&2; exit 1; }
spent() { FPR_LEDGER="$LEDGER" bash "$GOV" spent; }

[ -f "$REC" ] || fail "ledger-record.sh missing (RED before implementation)"
# shellcheck disable=SC1090
. "$REC"

# Case 1: a real json envelope with a cost → recorded; governor.spent reflects it.
: > "$LEDGER"
ledger_record_from_json '{"type":"result","subtype":"success","total_cost_usd":0.1234,"result":"RALPH_COMPLETE"}' "$LEDGER"
out="$(spent)"
awk -v s="$out" 'BEGIN{exit !(s+0 > 0.123 && s+0 < 0.124)}' || fail "case1: expected ~0.1234 spent, got '$out'"

# Case 2: a second run accumulates (delta sum across runs).
ledger_record_from_json '{"total_cost_usd":0.50,"result":"x"}' "$LEDGER"
out="$(spent)"
awk -v s="$out" 'BEGIN{exit !(s+0 > 0.623 && s+0 < 0.624)}' || fail "case2: expected ~0.6234 cumulative, got '$out'"

# Case 3: non-JSON garbage (text-mode output / crash) → no-op, ledger unchanged.
before="$(spent)"
ledger_record_from_json 'this is not json, RALPH_COMPLETE' "$LEDGER"
after="$(spent)"
[ "$before" = "$after" ] || fail "case3: garbage should be a no-op ($before -> $after)"

# Case 4: valid JSON but zero/missing cost → no-op (don't log $0 noise).
ledger_record_from_json '{"total_cost_usd":0,"result":"x"}' "$LEDGER"
ledger_record_from_json '{"result":"no cost field"}' "$LEDGER"
out="$(spent)"
[ "$out" = "$after" ] || fail "case4: zero/missing cost should not change ledger ($after -> $out)"

# Case 5: ledger_result_text pulls .result off the envelope (sentinel detection source).
rt="$(ledger_result_text '{"total_cost_usd":0.1,"result":"line1\nRALPH_COMPLETE"}')"
echo "$rt" | grep -q 'RALPH_COMPLETE' || fail "case5: result text should contain the sentinel, got '$rt'"
# ...and returns nothing for non-JSON, so ralph.sh falls back to RAW.
rt2="$(ledger_result_text 'plain text RALPH_COMPLETE')"
[ -z "$rt2" ] || fail "case5b: non-json should yield empty result text, got '$rt2'"

# Case 6 (AC-2 structural): the free engines must NOT touch the ledger writer.
grep -q 'ledger_record_from_json' "$HERE/../ralph.sh" || fail "case6: ralph.sh (metered) should call the writer"
if grep -q 'ledger_record_from_json' "$HERE/../codex-build-lane.sh" 2>/dev/null \
   || grep -q 'ledger_record_from_json' "$HERE/../ralph-interactive-lane.sh" 2>/dev/null; then
  fail "case6: free engines (codex / interactive) must NOT record metered spend"
fi

echo "PASS: test_ledger_writer (6 cases)"
