#!/usr/bin/env bash
# worktree-hook.sh — PreToolUse boundary hook for lane worktrees (ADR-0011)
# Called by Claude Code with tool JSON on stdin.
# WORKTREE_ROOT must be set in the environment (write-lane-settings.sh embeds it).
# Exit 0 = ALLOW, exit 2 = DENY (Claude Code PreToolUse convention).
set -uo pipefail

INPUT=$(cat)

# Parse tool_name via node
TOOL_NAME=$(node -e "
try {
  const d = JSON.parse(process.argv[1]);
  process.stdout.write(d.tool_name || '');
} catch(e) { process.stdout.write(''); }
" "$INPUT" 2>/dev/null || echo "")

# Resolve WORKTREE_ROOT to canonical absolute path
WORKTREE_ROOT="${WORKTREE_ROOT:-}"
if [ -z "$WORKTREE_ROOT" ]; then
  exit 0  # Not in a lane context — allow everything
fi
WORKTREE_ROOT="$(cd "$WORKTREE_ROOT" 2>/dev/null && pwd)" || exit 0

deny() {
  echo "DENY: $1" >&2
  exit 2
}

is_secret_path() {
  local path="$1"
  local basename
  basename="$(basename "$path")"

  # .env and .env.* variants
  [[ "$basename" == ".env" ]] && return 0
  [[ "$basename" == .env.* ]] && return 0
  # ~/.ssh/
  [[ "$path" == "$HOME/.ssh/"* ]] && return 0
  # credentials files
  [[ "$basename" == *credentials* ]] && return 0
  # pem / private key
  [[ "$basename" == *.pem ]] && return 0
  [[ "$basename" == id_rsa* ]] && return 0
  [[ "$basename" == id_ed25519* ]] && return 0
  return 1
}

resolve_path() {
  local path="$1"
  if [ -e "$path" ]; then
    # On Windows/Git-Bash, use pwd approach
    local dir base
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    (cd "$dir" 2>/dev/null && echo "$(pwd)/$base") 2>/dev/null || echo "$path"
  else
    local parent base
    parent="$(dirname "$path")"
    base="$(basename "$path")"
    if [ -d "$parent" ]; then
      echo "$(cd "$parent" && pwd)/$base"
    else
      echo "$path"
    fi
  fi
}

is_outside_worktree() {
  local path="$1"
  local resolved
  resolved="$(resolve_path "$path")"

  case "$resolved" in
    "$WORKTREE_ROOT"/*) return 1 ;;  # inside worktree → NOT outside
    "$WORKTREE_ROOT")   return 1 ;;  # IS the root → inside
    *)                  return 0 ;;  # outside
  esac
}

# Extract a field from tool_input via node
get_field() {
  local json="$1"
  local field="$2"
  node -e "
try {
  const d = JSON.parse(process.argv[1]);
  const v = (d.tool_input || {})[process.argv[2]] || '';
  process.stdout.write(String(v));
} catch(e) { process.stdout.write(''); }
" "$json" "$field" 2>/dev/null || echo ""
}

# ── Read / Write / Edit / MultiEdit ──────────────────────────────────────────
case "$TOOL_NAME" in
  Read|Write|Edit|MultiEdit|NotebookEdit)
    FILE_PATH="$(get_field "$INPUT" "file_path")"

    if [ -n "$FILE_PATH" ]; then
      is_secret_path "$FILE_PATH" && deny "secret-path blocked: $FILE_PATH"
      is_outside_worktree "$FILE_PATH" && deny "path escapes worktree: $FILE_PATH"
    fi
    exit 0
    ;;
esac

# ── Bash: check rm and secret reads ──────────────────────────────────────────
if [ "$TOOL_NAME" = "Bash" ]; then
  CMD="$(get_field "$INPUT" "command")"

  # Check rm targets
  if echo "$CMD" | grep -qE '\brm\b'; then
    # Extract tokens after `rm` (skip flags)
    while IFS= read -r token; do
      [[ "$token" == -* ]] && continue
      [ -z "$token" ] && continue
      is_outside_worktree "$token" && deny "rm escapes worktree: $token"
    done < <(echo "$CMD" | sed 's/^.*\brm\b//' | tr ' ' '\n')
  fi

  # Check for secret-path reads via shell utilities
  if echo "$CMD" | grep -qE '\b(cat|head|tail|less|more|bat)\b'; then
    while IFS= read -r token; do
      [[ "$token" == -* ]] && continue
      [ -z "$token" ] && continue
      is_secret_path "$token" && deny "secret-path read blocked: $token"
    done < <(echo "$CMD" | sed -E 's/^.*\b(cat|head|tail|less|more|bat)\b//' | tr ' ' '\n')
  fi
fi

# Default: allow
exit 0
