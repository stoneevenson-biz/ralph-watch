#!/usr/bin/env bash
# lane-engine-decision.sh — pure decision fn for ralph-exec.sh's per-lane engine routing (ADR-0003).
# Sourced by ralph-exec.sh and unit-tested directly. No side effects.
#
# lane_engine_decision <base_engine> <governor_decision> <already_running>
#   base_engine        : codex | claude   (from lane's spec frontmatter, codex if all-codex)
#   governor_decision  : metered | interactive  (from: governor.sh decide <credit>)
#   already_running    : 1 if this lane is mid-build on metered claude -p, else 0
# Prints the engine to use: codex | claude | claude-interactive
lane_engine_decision() {
  local base="$1" gov="$2" running="${3:-0}"
  # Codex lanes are a separate (already-free) engine — never reroute them.
  [ "$base" = "codex" ] && { echo "codex"; return; }
  # Only claude lanes are subject to the free-fallback flip.
  if [ "$gov" = "interactive" ] && [ "$running" != "1" ]; then
    echo "claude-interactive"        # NEW lane at/over threshold -> free engine
  else
    echo "claude"                    # below threshold, OR already running (finish on metered)
  fi
}
