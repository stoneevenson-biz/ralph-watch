#!/usr/bin/env bash
# test_lane_uses_core.sh — AC-3 for PRD-ENGINE-03
# Verifies:
# 1. ralph-interactive-lane.sh invokes the LaneAdapter driver (not raw wt.exe … claude directly)
# 2. No raw "wt.exe new-tab … claude" build spawn exists in the script for the build path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LANE_SH="$SCRIPT_DIR/../ralph-interactive-lane.sh"

# ── Check 1: DRYRUN output references LAUNCH-ADAPTER (routes through driver) ──

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/specs"
cat > "$TMPDIR/specs/test-spec.md" <<'EOF'
---
id: TEST-AC3
lane: lane-adapter
verify: true
---
Fake spec.
EOF

cd "$TMPDIR"
output="$(DRYRUN=1 RALPH_LANE_RAWS="lane-adapter" bash "$LANE_SH" 2>&1)"

if ! echo "$output" | grep -q 'LAUNCH-ADAPTER'; then
  echo "FAIL: DRYRUN output missing LAUNCH-ADAPTER — lane is not routing through LaneAdapter" >&2
  echo "--- output ---"; echo "$output"; echo "--------------"
  exit 1
fi

if echo "$output" | grep -q "lane-adapter-driver"; then
  : # OK — driver referenced
else
  echo "FAIL: DRYRUN output does not reference lane-adapter-driver" >&2
  exit 1
fi

# ── Check 2: No raw wt.exe … claude spawn in the build (non-dryrun) path ──
# The wt backend now calls the driver; the raw "& '$CLAUDE_BIN' ... --dangerously-skip-permissions"
# pattern must be gone from the script body.

# The flag must not appear as a live argument (passing it to a command).
# The echo line "(plain claude, no --dangerously...)" is commentary, not a flag — exclude it.
if grep "dangerously-skip-permissions" "$LANE_SH" | grep -qv "no --dangerously-skip-permissions"; then
  echo "FAIL: ralph-interactive-lane.sh still passes --dangerously-skip-permissions as a live flag" >&2
  exit 1
fi

# The old direct wt.exe … claude pattern (powershell -Command "& '$CLAUDE_BIN' … --dangerously…")
# must not appear.
if grep -qE "& '?\\\$CLAUDE_BIN'?.*--dangerously" "$LANE_SH"; then
  echo "FAIL: ralph-interactive-lane.sh still has raw wt.exe … claude --dangerously spawn" >&2
  exit 1
fi

echo "PASS: AC-3 — lane routes through LaneAdapter driver, no raw wt.exe…claude build spawn"
exit 0
