#!/usr/bin/env bash
# AC-5 (fresh context per spec) + AC-1 (interactive, no -p) for ralph-interactive-lane.sh.
# Uses DRYRUN=1 so the driver PRINTS its launch plan instead of opening real claude panes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DRV="$HERE/../ralph-interactive-lane.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
[ -f "$DRV" ] || fail "driver not found at $DRV"

# A worktree-like dir with 2 specs in this lane (phase 1, lane 'api').
WT="$TMP/wt"; mkdir -p "$WT/specs"
cat > "$WT/specs/api-a.md" <<'EOF'
---
phase: 1
lane: api
verify: "true"
---
Build endpoint A. Emit <promise>RALPH_COMPLETE</promise> when verify passes.
EOF
cat > "$WT/specs/api-b.md" <<'EOF'
---
phase: 1
lane: api
verify: "true"
---
Build endpoint B. Emit <promise>RALPH_COMPLETE</promise> when verify passes.
EOF

OUT="$( cd "$WT" && DRYRUN=1 RALPH_PHASE=1 RALPH_LANE=api bash "$DRV" 2>&1 )" || fail "driver errored:\n$OUT"

# AC-5: fresh process PER SPEC -> two separate launch lines (one per spec).
LAUNCHES="$(echo "$OUT" | grep -c 'LAUNCH-SPEC')"
[ "$LAUNCHES" = "2" ] || fail "AC-5: expected 2 per-spec launches, got $LAUNCHES. Output:\n$OUT"

# AC-1: interactive, never headless -> launch line invokes claude WITHOUT -p/--print.
echo "$OUT" | grep -q 'claude' || fail "AC-1: no claude invocation found"
# Match -p / --print as standalone flags (surrounded by space or end), not as substrings
# of other flags like --dangerously-skip-permissions.
if echo "$OUT" | grep 'LAUNCH-SPEC' | grep -Eq -- '(^|[[:space:]])(-p|--print)([[:space:]]|$)'; then
  fail "AC-1: driver used -p/--print (would be metered Pool 2). Output:\n$OUT"
fi

# AC: model forced to sonnet (stretch free quota, per ADR-0003).
echo "$OUT" | grep 'LAUNCH-SPEC' | grep -q 'sonnet' || fail "driver should force --model sonnet for free-quota economy"

echo "PASS: test_interactive_driver (AC-5 fresh-per-spec, AC-1 no -p, sonnet)"
