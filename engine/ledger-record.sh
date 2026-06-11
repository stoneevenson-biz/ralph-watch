#!/usr/bin/env bash
# ledger-record.sh — parse a `claude -p --output-format json` envelope and append its
# total_cost_usd to the spend ledger (via governor.sh record). Sourced by ralph.sh and
# unit-tested directly (same pattern as lane-engine-decision.sh). No build-aborting side
# effects: garbage / empty / no-cost / zero / negative → no-op.
#
# This is the writer the governor's flip-to-free decision READS. Without it the ledger is
# empty and governor.sh always says "metered" — see ADR-0009 (measure-first) / ADR-0003.
#
#   ledger_record_from_json <json-string> [ledger-path]
#       records total_cost_usd if it parses to a positive number; else no-op.
#   ledger_result_text <json-string>
#       prints the envelope's .result (the model's final text) — used by ralph.sh to grep
#       sentinels off a json envelope; prints nothing if the input isn't a json result.

ledger_record_from_json() {
  local json="${1:-}" ledger="${2:-${FPR_LEDGER:-.ralph/spend-ledger.jsonl}}"
  [ -n "$json" ] || return 0
  local cost
  cost="$(node -e '
    try {
      const d = JSON.parse(process.argv[1]);
      const c = d.total_cost_usd;
      if (typeof c === "number" && isFinite(c) && c > 0) process.stdout.write(String(c));
    } catch (e) {}
  ' "$json" 2>/dev/null || true)"
  [ -n "$cost" ] || return 0
  FPR_LEDGER="$ledger" ~/.claude/ralph/governor.sh record "$cost" >/dev/null 2>&1 || true
  return 0
}

ledger_result_text() {
  local json="${1:-}"
  [ -n "$json" ] || return 0
  node -e '
    try {
      const d = JSON.parse(process.argv[1]);
      if (typeof d.result === "string") process.stdout.write(d.result);
    } catch (e) {}
  ' "$json" 2>/dev/null || true
}
