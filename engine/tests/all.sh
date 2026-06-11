#!/usr/bin/env bash
# Runs the free-interactive-engine AC suite (ADR-0003). Exit 0 iff all green.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
for t in "$HERE"/test_governor.sh "$HERE"/test_status_signal.sh "$HERE"/test_interactive_driver.sh "$HERE"/test_flip_scope.sh "$HERE"/test_exec_integration.sh "$HERE"/test_ledger_writer.sh "$HERE"/test_watch_render.sh; do
  if bash "$t" >/tmp/fpr_t.out 2>&1; then echo "PASS  $(basename "$t")"; pass=$((pass+1))
  else echo "FAIL  $(basename "$t")"; cat /tmp/fpr_t.out; fail=$((fail+1)); fi
done
echo "===== $pass passed, $fail failed ====="
[ "$fail" = "0" ]
