# ralph

A Windows-friendly **autonomous coding-loop engine** plus the live TUI monitor you actually want to stare at while it runs.

"Ralph" is the [Geoffrey Huntley](https://ghuntley.com/ralph/) pattern: run a coding agent in a loop with a **fresh context every iteration**, let it pick the next unit of work off a plan, build it test-first, commit, and repeat — stopping only when the build + tests pass and the agent signals it's done. This repo packages that pattern into a real engine: a single-loop driver, a parallel phase/lane worktree executor, a free/metered/Codex engine router, a green-gated review step, and live monitoring (terminal TUI + one web dashboard for all loops).

No tmux, no Docker, no jq. Pure **bash + git + node + the `claude` CLI**. Runs in git-bash on Windows.

> This is a working snapshot of a personal toolchain. It's published so it can be cloned and stood up on a second machine. Some design docs reference the author's own repos — they're illustrative, nothing here needs them.

## What's here

| Path | What it is |
|------|-----------|
| **[`SETUP.md`](SETUP.md)** | **Start here.** Prerequisites + step-by-step install on a fresh PC. |
| **[`ARCHITECTURE.md`](ARCHITECTURE.md)** | How a loop actually runs end-to-end: the backend, the runtime files, the control flow. |
| **[`ENGINE-FILES.md`](ENGINE-FILES.md)** | Inventory — every script, what it reads/writes, what it depends on. |
| `engine/` | The actual runnable engine (all scripts, templates, ADRs, tests). |

## 30-second tour

```bash
# 1. A single autonomous loop in any project (simplest entry point)
cd my-project
~/.claude/ralph/ralph.sh --init      # writes PROMPT.md + IMPLEMENTATION_PLAN.md
#   ...edit IMPLEMENTATION_PLAN.md to list the work...
~/.claude/ralph/ralph.sh             # loops fresh-context Claude until build+tests green

# 2. Watch any loop live (separate terminal)
~/.claude/ralph/ralph-watch.sh my-project

# 3. One web dashboard for ALL loops across all repos
node ~/.claude/ralph/dashboard.mjs          # http://localhost:7799

# 4. See it without running a real build — a ~45s simulated run
~/.claude/ralph/ralph-demo.sh
```

## The two altitudes

- **`ralph.sh`** — the per-project loop. Reads `PROMPT.md` + your plan, feeds it to a fresh headless `claude -p` each iteration, owns its own build/test gate, stops on `RALPH_COMPLETE` (verified) or `RALPH_BLOCKED` (needs a human).
- **`ralph-exec.sh`** — the executor that sits *above* the loop. Reads `phase:` / `lane:` tags off `specs/*.md`, runs phases in sequence and lanes in parallel git worktrees, green-gates a review before merging each lane back, and never touches your main working tree.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full picture.

## License

MIT
