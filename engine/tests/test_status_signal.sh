#!/usr/bin/env bash
# AC-4: the inner stop-hook writes the done-signal to .fpr/last-spec-status (watch-not-drive).
# Two cases: verify-passes -> done + spec removed ; verify-fails -> block JSON + iteration++.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../ralph-interactive-stop-hook.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$HOOK" ] || fail "hook not found at $HOOK"

# --- Case A: verify exits 0 -> spec done ---
WT="$TMP/wtA"; mkdir -p "$WT/.fpr"
cat > "$WT/.fpr/current-spec.md" <<'EOF'
---
iteration: 1
max_iterations: 5
completion_promise: "LANE_OK"
verify: "true"
session_id: "sess-A"
---
Do the thing. When verify passes, emit <promise>LANE_OK</promise>.
EOF
# transcript with the promise emitted
TR="$TMP/transcriptA.jsonl"
printf '%s\n' '{"role":"assistant","message":{"content":[{"type":"text","text":"all done <promise>LANE_OK</promise>"}]}}' > "$TR"
HOOK_INPUT="{\"session_id\":\"sess-A\",\"transcript_path\":\"$TR\"}"
( cd "$WT" && echo "$HOOK_INPUT" | bash "$HOOK" >/dev/null 2>&1 )
[ "$(cat "$WT/.fpr/last-spec-status" 2>/dev/null)" = "done" ] || fail "caseA: last-spec-status != done"
[ ! -f "$WT/.fpr/current-spec.md" ] || fail "caseA: current-spec.md should be removed when done"

# --- Case B: verify exits non-zero -> block + iteration increment ---
WT="$TMP/wtB"; mkdir -p "$WT/.fpr"
cat > "$WT/.fpr/current-spec.md" <<'EOF'
---
iteration: 1
max_iterations: 5
completion_promise: "LANE_OK"
verify: "false"
session_id: "sess-B"
---
Keep working on the thing.
EOF
TR="$TMP/transcriptB.jsonl"
printf '%s\n' '{"role":"assistant","message":{"content":[{"type":"text","text":"still working"}]}}' > "$TR"
HOOK_INPUT="{\"session_id\":\"sess-B\",\"transcript_path\":\"$TR\"}"
OUT="$( cd "$WT" && echo "$HOOK_INPUT" | bash "$HOOK" 2>/dev/null )"
echo "$OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' || fail "caseB: expected block JSON, got: $OUT"
NEWITER="$(sed -n 's/^iteration: *//p' "$WT/.fpr/current-spec.md")"
[ "$NEWITER" = "2" ] || fail "caseB: iteration should be 2, got '$NEWITER'"

echo "PASS: test_status_signal (2 cases)"
