#!/usr/bin/env bash
# write-lane-settings.sh — write per-worktree .claude/settings.json (ADR-0011)
# Usage: bash write-lane-settings.sh <worktree-root>
# Idempotent: overwrites each run so settings stay in sync with this script.
# Never touches ~/.claude/settings.json.
set -euo pipefail

WORKTREE="${1:?usage: write-lane-settings.sh <worktree-root>}"
WORKTREE="$(cd "$WORKTREE" && pwd)"  # resolve to absolute path

HOOK_PATH="$HOME/.claude/ralph/worktree-hook.sh"
OUT_DIR="$WORKTREE/.claude"
OUT="$OUT_DIR/settings.json"

mkdir -p "$OUT_DIR"

node - "$OUT" "$HOOK_PATH" "$WORKTREE" <<'JSEOF'
const fs = require('fs');
const [outPath, hookPath, worktreeRoot] = process.argv.slice(2);

const settings = {
  permissions: {
    defaultMode: "auto",
    deny: [
      "Bash(git push*)",
      "Bash(git remote*)",
      "WebFetch",
      "WebSearch",
      "Bash(curl*)",
      "Bash(wget*)",
      "Bash(nc*)",
      "Bash(npm publish*)",
      "Bash(pnpm publish*)",
      "Bash(gh *)",
      "Bash(ssh*)",
      "Bash(scp*)"
    ]
  },
  hooks: {
    PreToolUse: [
      {
        matcher: ".*",
        hooks: [
          {
            type: "command",
            command: `WORKTREE_ROOT=${worktreeRoot} bash ${hookPath}`
          }
        ]
      }
    ]
  }
};

fs.writeFileSync(outPath, JSON.stringify(settings, null, 2) + '\n');
console.log(`wrote ${outPath}`);
JSEOF
