# AGENTS.md

> **This is the repo's ROUTER + operating manual.** Every agent (Claude Code interactive,
> a Ralph lane, Codex) reads this FIRST to learn how the repo works and WHERE everything is.
> It is STATIC — written deliberately, edited rarely. Transient "we learned X the hard way"
> notes do NOT go here; they go in `.memory/` (see the index below). Map vs margin-notes:
> this is the map. Keep it current; if a command changes, fix it here.

## Project
- **Goal:** <one-sentence goal>
- **Language / stack:** <e.g. TypeScript + Next.js + Postgres>
- **Package manager:** <pnpm | npm | uv | poetry | cargo | go>

## Commands
```bash
<install command>      # install
<build command>        # build
<test command>         # TEST — this is the "done" signal for every loop
<lint command>         # lint
<typecheck command>    # typecheck
<dev command>          # run locally
```

## Where everything lives (the index — follow these, don't re-derive)
- **`CONTEXT.md`** — the glossary. What every domain word means. Read before using a domain term.
- **`docs/adr/`** — the WHY. Decision records; the reasoning behind non-obvious choices. Read the ADR for an area before changing its decision.
- **`research/`** — the EVIDENCE. Cited investigations (library choices, prior art, market). PRDs link these.
- **`specs/`** — the WHAT. PRDs (`<ID>-<slug>.md`) + slice-specs (`<ID>-NN-<slug>.md`) tagged `phase`+`lane`. The build artifacts.
- **`.memory/`** — the GOTCHAS. Append-only lessons learned in THIS repo (see "Memory" below). Read at start; it'll save you a trap.
- **Module map:** <where the main modules live — e.g. `src/ordering`, `src/billing`; the seams tests hit>

## How loops run here (phase/lane executor)
- Build is driven by `~/.claude/ralph/ralph-exec.sh`: phases sequential, lanes parallel in worktrees, merge green at phase boundary. Never edits the main working tree.
- A loop builds ONLY its lane's slices (`RALPH_LANE_RAWS`). Don't widen scope across lanes.
- The test command above is the done-gate. Never weaken a test to go green.

## Conventions
- Single source of truth — no migrations/adapters left lying around.
- Tests against real DB / services where possible; mock only at network boundaries.
- Commits: conventional commits (`feat:`, `fix:`, `chore:`). Tag green builds.
- <repo-specific git-flow mandate, if any — e.g. insurance-bot's save.sh/ship.sh>

## Delegating to Codex
Codex reads this same `AGENTS.md`. When handing a slice to Codex, it has everything above —
the commands, the module map, the conventions. Keep this file accurate so the Codex handshake works.

## Stop criteria (read every iteration)
- 3 failed approaches → STOP, write findings to the slice's spec under `## Blocked`.
- Re-reading the same file >2× in one iteration → change strategy.
- Same test fails 3× across iterations → mark the AC blocked.

## Subagent budget
- Up to **10 parallel subagents** for searches/reads. Exactly **1** for build/test (back-pressure).
- Sonnet for implementation; Opus only for planning / LLM-as-judge.

## Self-improvement (FORCED — this is a gate, not a suggestion)
- New build/test command not documented here → append it to **Commands** (this file is the map).
- **A lane that went RED, got a review FAIL, or took an unusual number of iterations MUST write a `.memory/` gotcha entry BEFORE it is allowed to mark the slice done.** This is mandatory — the repo only learns if the trap is captured the moment it's hit. A `.memory/` entry = `<slug>.md` (frontmatter `name`/`description`/`metadata.type: gotcha`) + a pointer line in `.memory/MEMORY.md`. Also emit it to the system log: `node ~/.claude/ralph/pipeline-log.mjs gotcha repo=<name> lane=<lane> note="<one line>"`.
- The point: a fresh-context agent next iteration reads `.memory/` first and doesn't re-hit the trap. Skipping the write means the next loop repeats your mistake.
