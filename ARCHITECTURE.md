# Architecture — how a Ralph loop actually runs

This is the backend. It explains the control flow, the runtime files the pieces talk through, and why it's shaped this way.

## The core idea: fresh context every iteration

A long-lived agent session accumulates context, drifts, and gets expensive. Ralph instead runs the agent in a **loop where each iteration is a brand-new context** (the "Memento" principle). The agent's only memory between iterations is:

1. **The plan / specs** — re-injected each iteration (what's left to do).
2. **The last 5 git commits** — re-injected each iteration (what was just done).
3. **The working tree itself** — the code that already exists.

So each iteration the agent: reads the injected work list, picks the first unfinished item, builds *only* that (test-first), runs the full build+tests, commits, and the loop spins again with a clean context. It stops when everything's done and verified.

## Two altitudes

```
  ralph-exec.sh   ← EXECUTOR: phases in sequence, lanes in parallel worktrees,
       │            review gate, green-gated merge back to your branch
       │  (spawns one per lane, in its own git worktree)
       ▼
  ralph.sh        ← LOOP: fresh-context claude -p per iteration, owns the test gate,
                    stops on RALPH_COMPLETE (verified) or RALPH_BLOCKED (needs human)
```

You can run **`ralph.sh` alone** in any project (the simplest, most common case), or run **`ralph-exec.sh`** when you have a `specs/*.md` breakdown that should build in parallel.

---

## `ralph.sh` — the loop engine

Run from inside a project. Control flow per iteration (`engine/ralph.sh`):

1. **Build the prompt fresh:** `PROMPT.md` + a `## Current work items` block (the specs/plan, optionally lane-scoped) + a `## Recently done` block (last 5 commits).
2. **Call the agent:** `claude -p --model <MODEL> --output-format json --dangerously-skip-permissions`, with `CLAUDE_SKIP_DONE_GATE=1` (the loop owns its own gate, so the global done-gate hook stands down).
3. **Record spend:** parse `total_cost_usd` off the JSON envelope → append to the spend ledger (so the governor can make the flip-to-free decision; ADR-0003 / measure-first).
4. **Check sentinels** in the model's final text:
   - `RALPH_COMPLETE` → run the **real verify command**; if it passes, converged → exit 0. If verify fails, the model lied — keep looping.
   - `RALPH_BLOCKED` (or a `BLOCKERS.md` appears) → a human decision is needed → exit 2, stop. Don't burn iterations on an unanswerable slice.
5. Loop until convergence or `MAX` iterations (default 40) → exit 1.

**Verify auto-detection:** `package.json` → `pnpm/npm/yarn run build && test`; `pyproject.toml`/`pytest.ini` → `pytest`; otherwise a warning that there's no real gate. Override with `VERIFY="..."`.

**Key env:** `MAX` (iterations, 40), `MODEL` (`claude-sonnet-4-6`), `VERIFY` (test command), `RALPH_NO_INJECT=1` (skip context injection), `RALPH_LANE_RAWS` (lane scoping, set by the executor).

`ralph-delegate.sh` is a variant that routes each `IMPLEMENTATION_PLAN.md` task line to `codex` or `claude` by a `(codex)`/`(claude)` tag — cheap grunt work to Codex, judgment work to Claude.

---

## `ralph-exec.sh` — the phase/lane worktree executor

Sits above the loop. Reads `phase:` and `lane:` frontmatter off `specs/*.md` and orchestrates a parallel build **without ever touching your main working tree**:

- **Phases run in sequence** — phase N+1 starts only after phase N merges green.
- **Lanes run in parallel** — each lane builds in its own `../<repo>-p<phase>-<lane>` git worktree on branch `ralph/p<phase>-<lane>`, up to `PARALLEL_CAP` (default 4) at once.
- **Collision preflight** — if two lanes in a phase declare an overlapping `files_touched:` path, they're union-found into one worktree and serialized (so parallel lanes never clobber each other).
- **Per-lane engine routing** (`lane_engine`): all-`engine: codex` slices + `codex` on PATH → Codex builds it (0 Claude tokens); else Claude; the governor can flip new lanes to `claude-interactive` (free) when metered credit is low.
- **Review gate before merge** (Superpowers-style, cleared-context): tests prove it *runs*, review proves it's *right*. The executor records a review request and refuses to merge until a verdict file says `verdict: pass`. Codex reviews first (free); on hold, a Claude agent reviews/fixes via the `review-clean` / `receive-review` skills. A `[P1]` finding = fail.
- **Green-gated merge** — `git merge --no-ff` each lane back in deterministic order; conflict → halt; then a **combined-phase diff review** before releasing the next phase.
- **Failure capture (feedback loop):** a red lane is classified (`classify_failure` → `stuck_test`, `max_iter`, `env_setup`, …) and written to the repo's `.memory/` as a gotcha so the next run doesn't repeat it, plus a structured event to the global pipeline log.

**Exit codes:** `0` done · `1` red lane (stop-on-red) · `3` paused (a lane is blocked-needs-human, or held awaiting a review verdict).

**Key env:** `MAX`, `MODEL`, `PARALLEL_CAP`, `PHASE=N` (run one phase), `DRYRUN=1`, `NO_MERGE=1`, `SKIP_REVIEW=1`, `REVIEW_ENGINE=codex`.

---

## The runtime files everything talks through

The pieces are decoupled — they communicate via files on disk, not function calls. This is what makes "the loop runs here, the monitor watches there, the dashboard aggregates everywhere" work.

Inside each **project** repo:

| File | Writer | Reader | Purpose |
|------|--------|--------|---------|
| `PROMPT.md` | you / `--init` | `ralph.sh` | The standing instructions injected every iteration. |
| `specs/*.md` | `to-prd`/`to-issues` (or you) | exec + loop | Slice specs; frontmatter `parent/status/phase/lane/engine/verify/files_touched`. |
| `IMPLEMENTATION_PLAN.md` | you | `ralph.sh` | Fallback plan when there's no `specs/`. |
| `.ralph/status.json` | `ralph-exec.sh` | watch + dashboard | One-line machine state: `state` (running/held/blocked/failed/done), `phase`, `detail`, `blocker`. |
| `.ralph/events.jsonl` | `ralph.sh` | watch | `iter_start`/`iter_end`/`complete`/`blocked` timing events → velocity panel. |
| `.ralph/progress.jsonl` | watch | watch | Append a point each time the done-count changes → progress bar + ETA. |
| `.ralph/spend-ledger.jsonl` | `ledger-record.sh` | governor + watch | Real `total_cost_usd` per metered run → flip-to-free decision + live spend. |
| `.ralph/reviews/*.request` / `*.verdict` | exec / reviewer | exec | The review-gate handshake. |
| `.ralph/linear-queue.jsonl` | `linear-status.mjs` | the agent | Queued Linear status-change intents (flushed via MCP — scripts never write Linear). |
| `BLOCKERS.md` | the agent | watch + exec | The "I need a human decision" artifact that triggers a grill. |
| `.memory/MEMORY.md` + `*.md` | agent + exec | the agent | Per-repo gotchas (the dynamic memory; `AGENTS.md` is the static map). |

Global (cross-repo), under `~/.claude/ralph/`:

| File | Purpose |
|------|---------|
| `loops.json` | Registry: `{ "repoName": "/abs/path" }`. Executors self-register; dashboard reads it. |
| `pipeline-events.jsonl` | Append-only system-feedback log across all runs (`pipeline-log.mjs` writes it; a retro reads it). |
| `resolve-request.json` | Transient: the dashboard's "Resolve" button writes this; your shell/agent picks it up to open one grill. |

---

## Monitoring

- **`ralph-watch.sh <repo>`** — flicker-free terminal TUI for one loop: state header, animated slice progress bar, per-slice checklist (✓ shipped / ▶ building / ⛔ blocked / ○ queued), velocity panel (pace + ETA, iteration-cadence sparkline, commit rate, live spend), recent-commit ticker, 🎉 on convergence. Polls `.ralph/` every `POLL` seconds (default 2). **When the loop goes `blocked`/`failed`, this terminal becomes an interactive `claude` grill** that extracts the missing decision from you and sharpens the spec, then returns to watching.
- **`dashboard.mjs [port]`** — one web page (default `:7799`, auto-refresh 3s) showing **every** registered loop as a card with state, slice progress, lanes, and a **Resolve** button on blocked cards (writes `resolve-request.json` → your shell opens a grill). Reads each repo's `.ralph/status.json` from the registry; prunes repos whose dir is gone.
- **`ralph-launch.ps1 -Repos ...`** — opens a loop terminal + a monitor terminal per repo (auto-detects git-bash, including on `D:`). `-WatchOnly` for monitor-only.
- **`ralph-demo.sh`** — a ~45s simulated run against a throwaway fixture so you can see the TUI without a real build.

---

## The engine router (Claude / Codex / free interactive)

Three build engines, one per worktree, chosen by `lane_engine` + the governor:

- **Claude** (`ralph.sh`) — judgment lanes, metered `claude -p`. The default.
- **Codex** (`codex-build-lane.sh`, `codex-review-gate.sh`) — mechanical/clear-IO lanes tagged `engine: codex`; a separate process, **zero Claude tokens**. Reviews too. Absent `codex` CLI → silently falls back to Claude.
- **Free interactive** (`ralph-interactive-lane.sh` + `ralph-interactive-stop-hook.sh`) — Pool-1 free interactive `claude` sessions, one fresh per spec, "watch-not-drive" via a `.fpr/` status handshake. Only engaged when `FPR_CREDIT_USD` is set and the **governor** (`governor.sh`) decides metered credit is low enough to flip *new* lanes (a lane mid-build keeps its engine). The pure routing decision is `lane-engine-decision.sh` (unit-tested). See `engine/docs/free-interactive-engine.md` and ADR-0003.

---

## Safety model

- **The loop owns its gate.** No "done" without the real verify command passing — the model claiming `RALPH_COMPLETE` re-runs tests before converging.
- **Worktree isolation.** Parallel lanes build in sibling worktrees; the main tree is never touched until a green-gated, reviewed merge.
- **PreToolUse boundary hook** (`worktree-hook.sh`, written per-worktree by `write-lane-settings.sh`, ADR-0011): denies a lane agent's writes/reads/`rm` that escape its worktree or touch secret paths. Agent-on-agent safety comes from the *inner tool's own permission system*, never from screen-scraping a TUI.
- **No silent spend.** The governor is a gate that only *routes* lanes to the free engine — it never enables overflow billing.
- **No secrets in scripts.** All Linear writes are queued as intents and flushed by an agent through MCP; the engine itself holds no API keys.

See `engine/tests/all.sh` for the executable specification of all of the above — every behavior here has a unit test.
