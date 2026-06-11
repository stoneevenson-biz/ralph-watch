#!/usr/bin/env bash
# governor.sh — Free-fallback budget governor for ralph (ADR-0003).
# Tracks Pool-2 (metered claude -p) spend against the monthly Agent-SDK credit and
# decides when newly-scheduled lanes should flip to the FREE interactive engine.
#
# Honors Stone's Kalshi rule: this is a GATE, not an autopilot that spends silently.
# It never enables overflow billing; it only routes new lanes to the free engine.
#
# Ledger: newline-delimited JSON, one object per ralph run, each with "total_cost_usd"
# (the field `claude -p --output-format json` reports). Path via $FPR_LEDGER, default
# .ralph/spend-ledger.jsonl in the repo.
#
# Usage:
#   governor.sh spent                      -> prints total $ spent (sum of ledger)
#   governor.sh decide <monthly_credit>    -> prints "interactive" if spent >= 80% of credit, else "metered"
#   governor.sh record <cost_usd>          -> append a run's cost to the ledger
#
# Flip threshold is 80% (FPR_FLIP_PCT to override, integer percent).

set -uo pipefail

LEDGER="${FPR_LEDGER:-.ralph/spend-ledger.jsonl}"
FLIP_PCT="${FPR_FLIP_PCT:-80}"

spent() {
  [ -f "$LEDGER" ] || { echo 0; return; }
  # Sum total_cost_usd across all lines. Tolerate blank lines / missing field.
  awk '
    {
      if (match($0, /"total_cost_usd"[[:space:]]*:[[:space:]]*-?[0-9.]+/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/.*:[[:space:]]*/, "", s)
        total += s
      }
    }
    END { printf "%.4f", total+0 }
  ' "$LEDGER"
}

cmd="${1:-}"
case "$cmd" in
  spent)
    spent
    ;;
  decide)
    credit="${2:-}"
    [ -n "$credit" ] || { echo "usage: governor.sh decide <monthly_credit_usd>" >&2; exit 2; }
    sp="$(spent)"
    # threshold = credit * FLIP_PCT / 100 ; flip if sp >= threshold
    awk -v sp="$sp" -v credit="$credit" -v pct="$FLIP_PCT" '
      BEGIN {
        thresh = credit * pct / 100.0
        if (sp + 1e-9 >= thresh) print "interactive"; else print "metered"
      }'
    ;;
  record)
    cost="${2:-}"
    [ -n "$cost" ] || { echo "usage: governor.sh record <cost_usd>" >&2; exit 2; }
    mkdir -p "$(dirname "$LEDGER")"
    echo "{\"total_cost_usd\": $cost}" >> "$LEDGER"
    ;;
  *)
    echo "usage: governor.sh {spent|decide <credit>|record <cost>}" >&2
    exit 2
    ;;
esac
