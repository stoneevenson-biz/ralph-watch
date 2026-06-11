#!/usr/bin/env bash
# codex-build-lane.sh — BUILD a lane's slices with Codex instead of the Claude ralph loop.
# Token-saver lever: mechanical/clear-IO slices (tagged `engine: codex`) get built by
# `codex exec` (separate process, zero Claude tokens). Claude builds only judgment lanes.
#
# Runs INSIDE the lane's worktree (the worktree IS the write-sandbox boundary). Loops like
# ralph.sh: pick an unchecked slice → build it → run the verify gate → commit → repeat until
# all the lane's slices pass the test gate, then emit RALPH_COMPLETE (so the executor treats it
# identically to a Claude-built lane: same test gate, same review gate downstream).
#
# Called by the executor's build_lane when the lane's slices are `engine: codex`.
# Usage (run from inside the worktree): RALPH_LANE_RAWS="api" codex-build-lane.sh
# Env: MAX (iter cap), VERIFY (test cmd, auto-detected if unset), RALPH_LANE_RAWS (lane filter)
set -uo pipefail

command -v codex >/dev/null 2>&1 || { echo "codex CLI not found — cannot codex-build this lane"; exit 1; }
[ -d specs ] || { echo "no specs/ in $(pwd)"; exit 1; }
MAX="${MAX:-40}"
LANES="${RALPH_LANE_RAWS:-}"
LOG="codex-lane.log"; : > "$LOG"

# Reuse ralph.sh's verify auto-detection by sourcing nothing — inline a minimal version.
if [ -z "${VERIFY:-}" ]; then
  if [ -f package.json ]; then PM="npm"; [ -f pnpm-lock.yaml ] && PM="pnpm"; [ -f yarn.lock ] && PM="yarn"; VERIFY="$PM run build 2>/dev/null; $PM test"
  elif [ -f pyproject.toml ] || [ -f pytest.ini ]; then PY="python"; [ -x .venv/Scripts/python ] && PY=".venv/Scripts/python"; [ -x .venv/bin/python ] && PY=".venv/bin/python"; VERIFY="$PY -m pytest -q"
  else VERIFY="true"; echo "WARN: no test harness — codex lane has no real done-gate" | tee -a "$LOG"; fi
fi
verify() { bash -c "$VERIFY" >>"$LOG" 2>&1; }

# Which spec files belong to this lane (and aren't done)?
lane_specs() {
  for f in specs/*.md; do
    [ -e "$f" ] || continue
    case "$f" in *README*) continue;; esac
    local st lane; st="$(awk '/^---/{n++;next} n==1&&/^status:/{sub(/^status:[[:space:]]*/,"");print;exit}' "$f")"
    case "$st" in done|completed|shipped) continue;; esac
    lane="$(awk '/^---/{n++;next} n==1&&/^lane:/{sub(/^lane:[[:space:]]*/,"");print;exit}' "$f")"; [ -z "$lane" ] && lane="core"
    if [ -n "$LANES" ]; then case " $LANES " in *" $lane "*) echo "$f";; esac; else echo "$f"; fi
  done
}

BOUNDARY="IMPORTANT: Do NOT read or modify anything under ~/.claude/, .claude/skills/, or agents/ — those belong to a different AI system. Work ONLY in this repository's source. Build the slice described, test-first: write the failing test, make it pass. Do not weaken or delete tests. Make one atomic, working change. Read AGENTS.md for build/test commands and the module map, and .memory/ for known gotchas."

for i in $(seq 1 "$MAX"); do
  echo "===== codex-lane iter $i/$MAX =====" | tee -a "$LOG"
  mapfile -t TODO < <(lane_specs)
  [ "${#TODO[@]}" -eq 0 ] && { echo "no unfinished slices in lane(s) [$LANES] — done" | tee -a "$LOG"; }
  # Build the FIRST unfinished slice this iteration (one atomic slice per iter, like ralph).
  if [ "${#TODO[@]}" -gt 0 ]; then
    SPEC="${TODO[0]}"
    PROMPT="$BOUNDARY

Build the slice specified in this file (its Acceptance Criteria are the done-gate):

$(cat "$SPEC")

When done: implement it, write/maintain its tests, ensure the repo's test command passes. Make the change and stop."
    echo "building $SPEC via codex exec…" | tee -a "$LOG"
    timeout 600 codex exec "$PROMPT" -C "$(pwd)" -s workspace-write --full-auto \
      -c 'model_reasoning_effort="medium"' < /dev/null >>"$LOG" 2>&1 || echo "codex exec rc=$?" | tee -a "$LOG"
    # mark the slice status done ONLY if the verify gate passes (the real done-signal, not codex's say-so)
    if verify; then
      sed -i 's/^status:.*/status: done/' "$SPEC" 2>/dev/null || true
      git add -A >>"$LOG" 2>&1 || true
      git commit -q -m "feat($(basename "$SPEC" .md)): codex-built slice" >>"$LOG" 2>&1 || true
      echo "slice $SPEC verified GREEN + committed" | tee -a "$LOG"
    else
      echo "slice $SPEC built but verify RED — leaving unmarked, will retry next iter" | tee -a "$LOG"
    fi
  fi
  # all lane slices done AND full verify green → signal completion (same sentinel as ralph.sh)
  if [ -z "$(lane_specs)" ] && verify; then
    echo "RALPH_COMPLETE" | tee -a "$LOG"
    exit 0
  fi
done
echo "codex-lane hit MAX=$MAX without converging — escalate to Claude (review $LOG)" | tee -a "$LOG"
exit 1
