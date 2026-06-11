# Setup — standing Ralph up on a fresh PC

Goal: get loops running on a second machine exactly as they do on the first. The engine is just files plus a few CLIs on PATH — there is no installer and no per-repo config to remember.

## 1. Prerequisites

Install these and make sure each is on PATH (in git-bash, `command -v <name>` should print a path):

| Tool | Why | Notes |
|------|-----|-------|
| **Git for Windows** (git-bash) | The engine is bash; loops use `git worktree`. | bash lives at `C:\Program Files\Git\bin\bash.exe` (or `D:\Git\bin\bash.exe`). The launcher auto-detects it. |
| **Node.js** (LTS) | `dashboard.mjs`, `pipeline-log.mjs`, `linear-status.mjs`, JSON parsing. | `node -v` |
| **Claude Code CLI** (`claude`) | The agent that actually writes code in the loop. | Must be **logged in** — run `claude` once interactively and authenticate. The loop calls `claude -p`. |
| **Codex CLI** (`codex`) — *optional* | Token-saver: builds/reviews mechanical lanes with zero Claude tokens. | If absent, everything falls back to Claude automatically. No error. |

That's the whole dependency list. No tmux, no Docker, no jq, no Python (unless your *project* uses it for its tests).

## 2. Install the engine

Clone this repo and copy the engine into the canonical location every script expects: `~/.claude/ralph/`.

```bash
git clone https://github.com/stoneevenson-biz/ralph-watch.git
mkdir -p ~/.claude/ralph
cp -r ralph-watch/engine/* ~/.claude/ralph/
chmod +x ~/.claude/ralph/*.sh ~/.claude/ralph/*.mjs   # harmless on Windows; needed on *nix
```

> **Why `~/.claude/ralph/`?** Every script references its siblings by that absolute path (`~/.claude/ralph/ralph.sh`, etc.). Keep them together there and everything resolves. `~` in git-bash is your Windows user home (`C:\Users\<you>`).

Verify the install:

```bash
bash ~/.claude/ralph/tests/all.sh     # runs the engine's own unit tests
~/.claude/ralph/ralph-demo.sh         # ~45s simulated loop so you can see the monitor render
```

If the tests pass and the demo animates a build to a 🎉 banner, the engine is healthy.

## 3. Run your first real loop

```bash
cd /path/to/your-project          # must be a git repo with a test command
~/.claude/ralph/ralph.sh --init   # creates PROMPT.md + IMPLEMENTATION_PLAN.md
$EDITOR IMPLEMENTATION_PLAN.md    # list the atomic, testable units of work
~/.claude/ralph/ralph.sh          # go
```

In another terminal, watch it:

```bash
~/.claude/ralph/ralph-watch.sh /path/to/your-project
```

The loop auto-detects your verify command (`pnpm build && pnpm test`, `npm test`, `pytest`, …). Override it explicitly if needed:

```bash
MAX=40 MODEL=claude-sonnet-4-6 VERIFY="pnpm test" ~/.claude/ralph/ralph.sh
```

## 4. (Optional) The parallel executor + dashboard

For multi-phase, multi-lane builds driven by `specs/*.md` (see ARCHITECTURE.md → "The executor"):

```bash
cd /path/to/repo-with-specs
~/.claude/ralph/ralph-exec.sh            # phases in sequence, lanes in parallel worktrees
```

Launch loop + monitor windows together from PowerShell:

```powershell
~\.claude\ralph\ralph-launch.ps1 -Repos "C:\path\repoA","C:\path\repoB"
```

One web dashboard for everything:

```bash
node ~/.claude/ralph/dashboard.mjs       # http://localhost:7799, auto-refresh 3s
```

## 5. Things that are PC-specific (do NOT copy from the other machine)

These are runtime state, not engine, and are intentionally **not** in this repo. They regenerate on the new PC:

- `~/.claude/ralph/loops.json` — the live registry of which repos have loops (absolute local paths). Each executor run re-registers itself.
- `~/.claude/ralph/pipeline-events.jsonl` — the cross-run feedback log. Starts empty; accrues as you build.
- `~/.claude/ralph/resolve-request.json` — a transient dashboard→shell trigger file.
- Per-repo `.ralph/`, `.fpr/`, `.memory/` directories — created on demand inside each project.

## 6. Optional integrations (off by default)

- **Codex engine/review** — install the `codex` CLI; tag slices `engine: codex` to route them. Without it, Claude handles everything.
- **Free interactive fallback** — set `FPR_CREDIT_USD=<budget>` to let the governor flip new lanes to the free interactive engine when metered credit runs low (ADR-0003). Off unless that env var is set.
- **Linear tracking** — `linear-status.mjs` only *queues* status-change intents to `.ralph/linear-queue.jsonl`; an agent flushes them via MCP. No API keys live in any script, so nothing to copy/configure for the engine to run.
