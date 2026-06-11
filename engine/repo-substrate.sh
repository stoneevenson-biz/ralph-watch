#!/usr/bin/env bash
# repo-substrate.sh — idempotently scaffold the per-repo substrate into the current repo:
#   AGENTS.md   (the static router/manual + Codex handshake)  — from AGENTS.router.md
#   .memory/MEMORY.md  (the dynamic gotchas index)            — from repo-memory.MEMORY.md
#
# Safe to run repeatedly: never overwrites an existing AGENTS.md or .memory/MEMORY.md.
# Called by onboard-repo (front-door) and by the executor on first run in a repo.
#
# Usage: cd <repo> && ~/.claude/ralph/repo-substrate.sh
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"
NAME="$(basename "$ROOT")"
TPL="$HOME/.claude/ralph/templates"

if [ -f AGENTS.md ]; then
  echo "AGENTS.md exists — leaving it (edit deliberately; it's the static map)."
else
  cp "$TPL/AGENTS.router.md" AGENTS.md
  echo "wrote AGENTS.md (router) — fill in Commands + module map."
fi

if [ -f .memory/MEMORY.md ]; then
  echo ".memory/MEMORY.md exists — leaving it (append-only)."
else
  mkdir -p .memory
  sed "s/<repo-name>/$NAME/" "$TPL/repo-memory.MEMORY.md" > .memory/MEMORY.md
  echo "wrote .memory/MEMORY.md (gotchas index)."
fi
echo "substrate ready for $NAME. AGENTS.md = static map; .memory/ = dynamic notes."
