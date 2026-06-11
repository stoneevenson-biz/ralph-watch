#!/usr/bin/env bash
# test_lane_settings.sh — AC-1 for PRD-ENGINE-04
# Verifies write-lane-settings.sh creates correct <worktree>/.claude/settings.json
# and does NOT touch the global ~/.claude/settings.json mtime.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_DIR="$(dirname "$SCRIPT_DIR")"
WRITE_SETTINGS="$RALPH_DIR/write-lane-settings.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# ── Setup temp worktree ──────────────────────────────────────────────────────
WORKTREE=$(mktemp -d)
trap 'rm -rf "$WORKTREE"' EXIT

GLOBAL_SETTINGS="$HOME/.claude/settings.json"

# Record global mtime before
if [ -f "$GLOBAL_SETTINGS" ]; then
  BEFORE_MTIME=$(node -e "
const fs = require('fs');
const s = fs.statSync(process.argv[1]);
process.stdout.write(String(s.mtimeMs));
" "$GLOBAL_SETTINGS" 2>/dev/null || echo "0")
else
  BEFORE_MTIME="absent"
fi

# ── Run the writer ───────────────────────────────────────────────────────────
bash "$WRITE_SETTINGS" "$WORKTREE"

# ── AC-1a: file exists and is valid JSON ─────────────────────────────────────
SETTINGS_FILE="$WORKTREE/.claude/settings.json"
[ -f "$SETTINGS_FILE" ] || fail "settings.json not written to $SETTINGS_FILE"

node -e "
const fs = require('fs');
try { JSON.parse(fs.readFileSync(process.argv[1],'utf8')); }
catch(e) { console.error('invalid JSON: '+e.message); process.exit(1); }
" "$SETTINGS_FILE" || fail "settings.json is not valid JSON"
pass "settings.json exists and is valid JSON"

# ── AC-1b: defaultMode == auto ───────────────────────────────────────────────
MODE=$(node -e "
const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
process.stdout.write((d.permissions||{}).defaultMode||'');
" "$SETTINGS_FILE")
[ "$MODE" = "auto" ] || fail "defaultMode is '$MODE', expected 'auto'"
pass "defaultMode == auto"

# ── AC-1c: all required deny rules present ────────────────────────────────────
EXPECTED_DENIES=(
  "Bash(git push*)"
  "Bash(git remote*)"
  "WebFetch"
  "WebSearch"
  "Bash(curl*)"
  "Bash(wget*)"
  "Bash(nc*)"
  "Bash(npm publish*)"
  "Bash(pnpm publish*)"
  "Bash(gh *)"
  "Bash(ssh*)"
  "Bash(scp*)"
)

for rule in "${EXPECTED_DENIES[@]}"; do
  node -e "
const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const denies=(d.permissions||{}).deny||[];
const rule=process.argv[2];
if(!denies.includes(rule)){
  console.error('MISSING deny rule: '+rule);
  process.exit(1);
}
" "$SETTINGS_FILE" "$rule" || fail "deny rule missing: $rule"
done
pass "all ${#EXPECTED_DENIES[@]} deny rules present"

# ── AC-1d: PreToolUse hook referenced ─────────────────────────────────────────
HOOK_COUNT=$(node -e "
const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const hooks=(d.hooks||{}).PreToolUse||[];
process.stdout.write(String(hooks.length));
" "$SETTINGS_FILE")
[ "$HOOK_COUNT" -gt 0 ] || fail "no PreToolUse hook found in settings.json"
pass "PreToolUse hook referenced ($HOOK_COUNT entry/entries)"

# ── AC-1e: global settings.json mtime unchanged ───────────────────────────────
if [ -f "$GLOBAL_SETTINGS" ] && [ "$BEFORE_MTIME" != "absent" ]; then
  AFTER_MTIME=$(node -e "
const fs=require('fs');
process.stdout.write(String(fs.statSync(process.argv[1]).mtimeMs));
" "$GLOBAL_SETTINGS" 2>/dev/null || echo "0")
  [ "$AFTER_MTIME" = "$BEFORE_MTIME" ] || fail "global settings.json was modified (mtime changed)"
  pass "global settings.json mtime unchanged"
else
  pass "global settings.json not present or absent before — skipping mtime check"
fi

echo ""
echo "ALL AC-1 CHECKS PASSED"
