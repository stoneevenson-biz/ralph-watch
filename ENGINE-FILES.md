# Engine file inventory

Every file under `engine/`, what it does, and what it needs. Install target on a new PC is `~/.claude/ralph/` (see [SETUP.md](SETUP.md)).

## Entry-point scripts

| File | Role | Deps |
|------|------|------|
| `ralph.sh` | **The loop.** Fresh-context `claude -p` per iteration; owns the build/test gate; stops on verified `RALPH_COMPLETE` or `RALPH_BLOCKED`. `--init` scaffolds `PROMPT.md` + `IMPLEMENTATION_PLAN.md`. | bash, git, `claude` |
| `ralph-exec.sh` | **The executor.** Reads `phase:`/`lane:` off `specs/*.md`; phases sequential, lanes parallel in git worktrees; collision preflight; review gate; green-gated merge; failure capture to `.memory/`. | bash, git, node, `claude` (+`codex` optional) |
| `ralph-delegate.sh` | Plan-loop variant routing each `IMPLEMENTATION_PLAN.md` task to `(codex)` or `(claude)` by tag. | bash, git, `claude` (+`codex`) |
| `ralph-watch.sh` | **Terminal monitor** for one loop; becomes a `claude` grill on block/fail. Polls `.ralph/`. `RALPH_WATCH_LIB=1` sources helpers only (for tests). | bash, git (`claude` for the grill) |
| `dashboard.mjs` | **Web dashboard** for all loops (default `:7799`). Reads `loops.json` registry + each repo's `.ralph/status.json`; Resolve button writes `resolve-request.json`. | node |
| `ralph-launch.ps1` | Opens loop + monitor terminals per repo; auto-detects git-bash (incl. `D:\Git`). `-WatchOnly`, `-BashExe`. | PowerShell, git-bash |
| `ralph-demo.sh` | ~45s simulated run against a TEMP fixture repo to showcase the TUI. | bash, git |

## Engine router (Claude / Codex / free interactive)

| File | Role | Deps |
|------|------|------|
| `lane-engine-decision.sh` | Pure (side-effect-free, unit-tested) fn: `(base_engine, governor_decision, already_running) → codex\|claude\|claude-interactive`. | bash |
| `governor.sh` | Free-fallback budget gate (ADR-0003): sums the spend ledger vs `FPR_CREDIT_USD`, decides `metered`\|`interactive` for **new** lanes. A gate, never an autopilot. | bash |
| `ledger-record.sh` | Sourced by `ralph.sh`: parse `total_cost_usd` from the `claude -p` JSON envelope → append to spend ledger. Also `ledger_result_text` (pull `.result`). | bash |
| `codex-build-lane.sh` | Build a lane's slices with `codex exec` instead of Claude — 0 Claude tokens. Same test gate → emits `RALPH_COMPLETE`. | bash, git, `codex` |
| `codex-review-gate.sh` | Independent review via `codex` → writes a `verdict:` file the executor reads. `[P1]` = fail. | bash, git, `codex` |
| `ralph-interactive-lane.sh` | FREE per-lane engine (ADR-0003): one fresh **interactive** `claude` per spec, watch-not-drive via a `.fpr/` status handshake. | bash, node, `claude`, Windows Terminal (`wt.exe`) for the `wt` backend |
| `ralph-interactive-stop-hook.sh` | Inner per-spec loop hook for the interactive engine: keeps the current session iterating on the current spec until test-green + promise. Never shells out to `claude -p`. | bash, `claude` (as a Stop hook) |
| `lane-adapter-driver.mjs` | Spawns a LaneAdapter session for one spec (used by the interactive engine). | node |

## Per-repo substrate + tracking

| File | Role | Deps |
|------|------|------|
| `repo-substrate.sh` | Idempotently scaffold `AGENTS.md` (static router) + `.memory/MEMORY.md` (gotchas index) into a repo. Never overwrites. | bash, git |
| `templates/AGENTS.router.md` | Template for a repo's static `AGENTS.md` (commands + module map + Codex handshake). | — |
| `templates/repo-memory.MEMORY.md` | Template for a repo's `.memory/MEMORY.md` gotchas index. | — |
| `linear-status.mjs` | **Records** a Linear status-transition *intent* to `.ralph/linear-queue.jsonl` (does NOT call Linear — an agent flushes via MCP). Resolves issue id from spec frontmatter. | node |
| `pipeline-log.mjs` | Append one structured event to the global `pipeline-events.jsonl` system-feedback log (the L4 "how well does the system build" memory). | node |

## Worktree boundary safety (ADR-0011)

| File | Role | Deps |
|------|------|------|
| `worktree-hook.sh` | PreToolUse hook for lane worktrees: deny writes/reads/`rm` that escape the worktree or hit secret paths. Exit 2 = deny. | bash, node |
| `write-lane-settings.sh` | Writes a per-worktree `.claude/settings.json` wiring the hook (embeds `WORKTREE_ROOT`). Never touches `~/.claude/settings.json`. | bash |

## Docs & tests

| Path | Contents |
|------|----------|
| `docs/free-interactive-engine.md` | Design of the free interactive fallback engine. |
| `docs/adr/0001-extend-dashboard-not-framework.md` | Why the monitor is a hand-rolled node server, not a framework. |
| `docs/adr/0002-linear-system-of-record-for-tracking.md` | Linear = system of record for tracking; `.ralph` = live layer. |
| `docs/adr/0003-free-interactive-fallback-engine.md` | The free/metered governor + interactive engine design. |
| `tests/all.sh` | Runs the whole suite. The executable spec for the engine. |
| `tests/test_*.sh` | Unit tests: watch render, status signal, governor, ledger writer, lane engine routing, flip scope, lane settings, worktree hook, interactive driver, exec integration, no-skip. |

## Not in this repo (machine-specific runtime state — regenerates locally)

`loops.json`, `pipeline-events.jsonl`, `resolve-request.json`, `*.bak`, and per-project `.ralph/` `.fpr/` `.memory/` dirs. See SETUP.md §5.
