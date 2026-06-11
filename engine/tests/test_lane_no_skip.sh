#!/usr/bin/env bash
# test_lane_no_skip.sh — AC-1 for PRD-ENGINE-03
# Runs DRYRUN=1 on ralph-interactive-lane.sh and greps the printed launch line.
# FAIL if --dangerously-skip-permissions or -p/--print appear in the launch output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LANE_SH="$SCRIPT_DIR/../ralph-interactive-lane.sh"

# Need a temp dir with a fake spec so the lane script has something to iterate over.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/specs"
cat > "$TMPDIR/specs/test-spec.md" <<'EOF'
---
id: TEST-01
lane: test-lane
verify: true
---
Fake spec body for AC-1 test.
EOF

cd "$TMPDIR"

output="$(DRYRUN=1 RALPH_LANE_RAWS="test-lane" bash "$LANE_SH" 2>&1)"

echo "--- launch output ---"
echo "$output"
echo "---------------------"

# AC-1: must NOT contain --dangerously-skip-permissions as a real flag (word boundary match).
# Exclude the human-readable explanation line that says "no --dangerously-skip-permissions".
if echo "$output" | grep -- '--dangerously-skip-permissions' | grep -qv 'no --dangerously-skip-permissions'; then
  echo "FAIL: launch output contains --dangerously-skip-permissions as a live flag" >&2
  exit 1
fi

# AC-1: must NOT contain -p or --print as a standalone flag
if echo "$output" | grep -qE -- '(\s|=)-p(\s|$)'; then
  echo "FAIL: launch output contains -p flag" >&2
  exit 1
fi
if echo "$output" | grep -q -- '--print'; then
  echo "FAIL: launch output contains --print flag" >&2
  exit 1
fi

# Must contain LAUNCH-ADAPTER to confirm it goes through the adapter
if ! echo "$output" | grep -q 'LAUNCH-ADAPTER'; then
  echo "FAIL: launch output missing LAUNCH-ADAPTER line (not routing through LaneAdapter)" >&2
  exit 1
fi

echo "PASS: AC-1 — no --dangerously-skip-permissions or -p/--print in launch line"
exit 0
