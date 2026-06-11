#!/usr/bin/env bash
# ralph-demo.sh — ~45-second simulated Ralph run to showcase the watch TUI.
# Builds a throwaway fixture repo in TEMP, then animates it (a slice ships every
# ~5s: spec → done, commit lands, iteration events + spend accrue, phase advances)
# while the REAL ralph-watch.sh renders it. Ends on the celebration banner.
#
# Usage: ~/.claude/ralph/ralph-demo.sh    (Ctrl-C to quit when done)
set -uo pipefail

BASE="$HOME/AppData/Local/Temp/ralph-demo-$(date +%s)"
R="$BASE/demo-repo"
mkdir -p "$R/specs" "$R/.ralph"
cd "$R"
git init -q
git config user.email demo@demo; git config user.name demo
echo seed > seed.txt; git add seed.txt
git -c commit.gpgsign=false commit -qm "chore: scaffold demo repo"

mk() { printf -- '---\nparent: PRD\nstatus: %s\nphase: %s\nlane: %s\n---\n' "$2" "$3" "$4" > "specs/$1.md"; }
S=(01-auth-login 02-auth-session 03-crm-contacts 04-crm-notes 05-crm-search 06-billing-plans 07-ui-dashboard 08-ui-reports)
P=(1 1 1 1 2 2 2 2)
L=(core core api api api billing ui ui)
for i in "${!S[@]}"; do mk "${S[$i]}" draft "${P[$i]}" "${L[$i]}"; done
printf '{"state":"running","repo":"demo-repo","phase":"1","detail":"building lanes","blocker":"","ts":"now"}\n' > .ralph/status.json
mkdir -p "$BASE/demo-repo-p1-core"   # ▶ building marker for the first lane

# ---- background mutator: ship one slice every ~5s --------------------------
(
  sleep 4
  for i in "${!S[@]}"; do
    n="${S[$i]}"; ln="${L[$i]}"
    d=$(( 90 + (RANDOM % 130) ))                 # synthetic 90–220s iteration for the sparkline
    now=$(date +%s)
    printf '{"ev":"iter_start","i":%s,"max":40,"lane":"%s","ts":%s}\n{"ev":"iter_end","i":%s,"max":40,"lane":"%s","ts":%s}\n' \
      "$((i+1))" "$ln" "$((now-d))" "$((i+1))" "$ln" "$now" >> .ralph/events.jsonl
    printf '{"total_cost_usd": 0.%02d}\n' "$(( 30 + RANDOM % 60 ))" >> .ralph/spend-ledger.jsonl
    sed -i 's/^status: draft/status: done/' "specs/$n.md"
    echo "$n" >> shipped.txt
    git add shipped.txt "specs/$n.md" >/dev/null 2>&1
    git -c commit.gpgsign=false commit -qm "feat($n): slice green — tests pass" >/dev/null 2>&1
    rmdir "$BASE"/demo-repo-p*-* 2>/dev/null || true
    if [ $((i+1)) -lt ${#S[@]} ]; then
      nph="${P[$((i+1))]}"; nln="${L[$((i+1))]}"
      mkdir -p "$BASE/demo-repo-p${nph}-${nln}"
      printf '{"state":"running","repo":"demo-repo","phase":"%s","detail":"building lanes","blocker":"","ts":"now"}\n' "$nph" > .ralph/status.json
    fi
    sleep 5
  done
  rmdir "$BASE"/demo-repo-p*-* 2>/dev/null || true
  printf '{"state":"done","repo":"demo-repo","phase":"","detail":"all phases complete + reviewed","blocker":"","ts":"now"}\n' > .ralph/status.json
) &

exec "$HOME/.claude/ralph/ralph-watch.sh" "$R"
