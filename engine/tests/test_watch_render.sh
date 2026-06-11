#!/usr/bin/env bash
# ACs for the ralph-watch dopamine monitor + ralph.sh event emission.
# AC-1: render_frame shows state, slice bar+counts, checklist, velocity, commits.
# AC-2: pure helpers (fmt_dur, rel_age, mkbar, sparkline, avg_gap) sourceable + correct.
# AC-3: ralph.sh appends iteration events to .ralph/events.jsonl without changing loop behavior.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../ralph-watch.sh"
RALPH="$HERE/../ralph.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# --- AC-2: pure helpers ------------------------------------------------------
RALPH_WATCH_LIB=1 . "$WATCH" || fail "watch script not sourceable as lib"
[ "$(fmt_dur 45)" = "45s" ]        || fail "fmt_dur 45 -> $(fmt_dur 45)"
[ "$(fmt_dur 252)" = "4m 12s" ]    || fail "fmt_dur 252 -> $(fmt_dur 252)"
[ "$(fmt_dur 3780)" = "1h 03m" ]   || fail "fmt_dur 3780 -> $(fmt_dur 3780)"
[ "$(rel_age 45)" = "45s" ]        || fail "rel_age 45"
[ "$(rel_age 240)" = "4m" ]        || fail "rel_age 240"
[ "$(rel_age 7200)" = "2h" ]       || fail "rel_age 7200"
[ "$(mkbar 5 10 4)" = "██░░" ]     || fail "mkbar 5 10 4 -> $(mkbar 5 10 4)"
[ "$(mkbar 0 10 4)" = "░░░░" ]     || fail "mkbar 0"
[ "$(mkbar 10 10 4)" = "████" ]    || fail "mkbar full"
[ "$(mkbar 1 0 4)" = "░░░░" ]      || fail "mkbar total=0 must not divide by zero"
[ "$(sparkline "10 80")" = "▁█" ]  || fail "sparkline 10 80 -> $(sparkline "10 80")"
[ "$(sparkline "80 80")" = "██" ]  || fail "sparkline equal"
[ "$(avg_gap "100 200 400")" = "150" ] || fail "avg_gap -> $(avg_gap "100 200 400")"
[ "$(avg_gap "100")" = "0" ]       || fail "avg_gap single ts must be 0"

# --- AC-1: render_frame from a fixture repo ----------------------------------
R="$TMP/repo"; mkdir -p "$R/specs" "$R/.ralph"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
  && echo x > f && git add f && git commit -qm "feat: first commit" )
cat > "$R/specs/01-auth.md" <<'EOF'
---
parent: PRD
status: done
phase: 1
lane: core
---
auth slice
EOF
cat > "$R/specs/02-crm.md" <<'EOF'
---
parent: PRD
status: draft
phase: 1
lane: core
---
crm slice
EOF
printf '{"state":"running","repo":"repo","phase":"1","detail":"building lanes","blocker":"","ts":"2026-06-11T10:00:00"}\n' > "$R/.ralph/status.json"
NOW="$(date +%s)"
printf '{"ts":%s,"done":0,"total":2}\n{"ts":%s,"done":1,"total":2}\n' "$((NOW-600))" "$((NOW-60))" > "$R/.ralph/progress.jsonl"
printf '{"ev":"iter_start","i":1,"max":40,"lane":"core","ts":%s}\n{"ev":"iter_end","i":1,"max":40,"lane":"core","ts":%s}\n' "$((NOW-500))" "$((NOW-380))" > "$R/.ralph/events.jsonl"
printf '{"total_cost_usd": 0.50}\n{"total_cost_usd": 0.25}\n' > "$R/.ralph/spend-ledger.jsonl"

FRAME="$(cd "$R" && RALPH_WATCH_LIB=1 . "$WATCH" && render_frame)"
PLAIN="$(printf '%s' "$FRAME" | sed $'s/\033\\[[0-9;?]*[A-Za-z]//g')"
echo "$PLAIN" | grep -q "RUNNING"             || fail "frame missing state word RUNNING"
echo "$PLAIN" | grep -q "1/2"                 || fail "frame missing slice count 1/2"
echo "$PLAIN" | grep -q "50%"                 || fail "frame missing percent"
echo "$PLAIN" | grep -q "01-auth"             || fail "frame missing done slice name"
echo "$PLAIN" | grep -q "02-crm"              || fail "frame missing pending slice name"
echo "$PLAIN" | grep -qi "velocity"           || fail "frame missing velocity section"
echo "$PLAIN" | grep -qi "eta"                || fail "frame missing ETA"
echo "$PLAIN" | grep -q "feat: first commit"  || fail "frame missing recent commit"
echo "$PLAIN" | grep -q '\$0.75'              || fail "frame missing summed spend \$0.75"

# done-state celebration banner
printf '{"state":"done","repo":"repo","phase":"","detail":"all phases complete","blocker":"","ts":"2026-06-11T11:00:00"}\n' > "$R/.ralph/status.json"
FRAME2="$(cd "$R" && RALPH_WATCH_LIB=1 . "$WATCH" && render_frame)"
printf '%s' "$FRAME2" | sed $'s/\033\\[[0-9;?]*[A-Za-z]//g' | grep -qi "complete" || fail "done frame missing celebration banner"

# --- AC-3: ralph.sh emits events.jsonl (stubbed claude, MAX=1) ---------------
B="$TMP/bin"; mkdir -p "$B"
cat > "$B/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"result":"RALPH_COMPLETE","total_cost_usd":0}'
EOF
chmod +x "$B/claude"
W="$TMP/loop"; mkdir -p "$W"
echo "task" > "$W/PROMPT.md"
( cd "$W" && PATH="$B:$PATH" MAX=1 VERIFY=true RALPH_NO_INJECT=1 bash "$RALPH" >/dev/null 2>&1 )
rc=$?
[ "$rc" = "0" ] || fail "ralph.sh stub run should converge rc=0, got $rc"
[ -f "$W/.ralph/events.jsonl" ]                       || fail "ralph.sh wrote no .ralph/events.jsonl"
grep -q '"ev":"iter_start"' "$W/.ralph/events.jsonl"  || fail "events.jsonl missing iter_start"
grep -q '"ev":"iter_end"'   "$W/.ralph/events.jsonl"  || fail "events.jsonl missing iter_end"
grep -q '"ev":"complete"'   "$W/.ralph/events.jsonl"  || fail "events.jsonl missing complete"

echo "PASS: test_watch_render (AC-1 render, AC-2 helpers, AC-3 events)"
