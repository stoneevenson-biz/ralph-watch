#!/usr/bin/env bash
# AC-3: when the governor flips, only NEW lanes go interactive; lanes already running on
# metered claude -p keep their engine. Tests the pure decision fn used by ralph-exec build_lane.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lane-engine-decision.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
[ -f "$LIB" ] || fail "lib not found at $LIB"
. "$LIB"

# Signature: lane_engine_decision <base_engine> <governor_decision> <already_running:0|1>
#   base_engine = what the spec tags say (codex|claude)
#   governor_decision = metered|interactive (from governor.sh decide)
#   already_running = 1 if this lane is mid-build on metered (must NOT be switched)

# 1. codex stays codex regardless (codex lanes are already free / separate engine)
[ "$(lane_engine_decision codex interactive 0)" = "codex" ] || fail "codex must stay codex"

# 2. claude + governor metered -> claude (normal, no flip)
[ "$(lane_engine_decision claude metered 0)" = "claude" ] || fail "claude+metered should stay claude"

# 3. claude + governor interactive + NEW lane (not running) -> claude-interactive (FLIP)
[ "$(lane_engine_decision claude interactive 0)" = "claude-interactive" ] || fail "new claude lane should flip to interactive at threshold"

# 4. claude + governor interactive + ALREADY RUNNING -> claude (finish on metered, do NOT switch)
[ "$(lane_engine_decision claude interactive 1)" = "claude" ] || fail "running metered lane must finish on metered, not flip mid-run"

echo "PASS: test_flip_scope (4 cases)"
