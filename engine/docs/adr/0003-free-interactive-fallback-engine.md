---
id: ADR-0003
title: Free interactive engine as a FALLBACK rung for ralph when the Agent-SDK credit runs low
status: accepted
created: 2026-06-07
relates-to: [research-ralph-after-payg, ADR-0004-oauth-billing, ADR-0005-headless-kernel]
---

## Context
As of **June 15 2026**, headless `claude -p` / Agent-SDK usage on a Claude subscription draws a
**separate metered monthly credit at API rates** (Max 20x = $200), not the flat interactive quota.
Ralph's per-lane engine builds each worktree with `claude -p` → so all-day parallel ralphing now
burns that $200 credit (Pool 2). When it's exhausted, the default behavior is a **hard stop**
("Agent SDK requests stop until your credit refreshes") unless overflow is enabled — and overflow
is uncapped (violates Stone's Kalshi rule). See `research/ralph-after-payg.md`.

Stone's constraints: OAuth-plan preferred, NO runaway/uncapped bill, functionality-first. He does
NOT want a dead pipeline when the credit runs out — he wants ralph to **degrade, not stop**.

**Proven this session (2026-06-07, live on this machine):** a concurrent **interactive** `claude`
session (NOT `claude -p`), launched per git-worktree via `wt.exe` split-panes, runs on
**`Login method: Claude Max account` (Pool 1 = FREE)** — confirmed via `/status` in a pane whose
`cwd` was correctly isolated to its worktree. So there IS a free engine: interactive sessions.
Its hard limitation (also proven): an orchestrator **cannot drive an interactive TUI** — it's a
sovereign process. Coordination is **watch-not-drive** (poll worktree status files), unlike the
pipe-controllable `claude -p`.

## Decision
**Keep ONE ralph. Add a free interactive engine as a FALLBACK rung in the degrade ladder — not a
replacement, not a separate skill.** Run normal metered ralph (`claude -p`, fast, pipe-controlled,
parallel) as the primary. A **budget governor** tracks Pool-2 spend; when it crosses **80% of the
$200 monthly credit**, **newly-scheduled lanes** flip to `engine: claude-interactive`
(free, Pool 1, Sonnet) instead of stopping. **Lanes already running on metered finish undisturbed**
— only new lanes flip. The degrade ladder:

```
Opus → Sonnet → Haiku  →  [Pool-2 spend ≥ 80% of $200]  →  claude-interactive (FREE, Pool 1)  →  queue-next-cycle
        (metered claude -p, pipe-controlled)                 (interactive panes, watch-not-drive)
```

This slots into ralph's EXISTING per-lane engine dispatch (`ralph-exec.sh build_lane()`, which
already routes `codex` vs `claude`). The interactive engine is a **third case**, not new
architecture: `lane_engine()` learns to return `claude-interactive`; `build_lane()` gets a third
branch calling `ralph-interactive-lane.sh` (sibling to `codex-build-lane.sh`).

The free engine's loop respects ralph's **fresh-context-per-spec** rule via a two-level loop:
- **OUTER** = fresh interactive `claude` session per spec (new process = fresh context).
- **INNER** = a per-worktree Stop-hook (`ralph-interactive-stop-hook.sh`, ours — NOT the official
  single-context ralph-loop plugin) that re-feeds the SAME spec until its `verify` exits 0 +
  `<promise>` emitted. Within-spec accumulation is fine (mirrors `claude -p`'s internal turns).

## Consequences
- **Pro:** ralph never dies on credit exhaustion — it degrades to free and keeps shipping. The
  $200 is a soft ceiling, not a wall. Honors Kalshi rule (governor gates the flip; no silent
  overflow billing). Reuses the whole scheduler/preflight/merge/Linear machinery unchanged.
- **Con (accepted):** the free engine is **watch-not-drive** — the scheduler polls worktree status
  files (`.fpr/last-spec-status`, git log, test exit) instead of reading a pipe. It's serial-ish
  and slower than metered parallel ralph. That's fine: a fallback's job is "keep working when the
  alternative is nothing," not "match the primary."
- **Con:** interactive panes burn the **interactive 5h/weekly quota** (~4× faster with 4 lanes) and
  default to **Opus** unless forced to Sonnet — the driver MUST launch with `--model
  claude-sonnet-4-6` to stretch the free quota. Free of $, not free of rate-limit.
- **Deferred (NOT a blocker):** the Hermes/SSH "while away" path needs a PTY (interactive `claude`
  has no TTY under detached `Start-Process`). Desk path (`wt` split-pane) is the shipped fallback;
  PTY-via-winpty/tmux is a later enhancement. The fallback mostly matters at-desk anyway.
- **Process hygiene flag:** ~22 stray `claude` processes were observed during testing — a fleet
  design needs explicit pane cleanup (kill on spec-done / lane-done).

## Status of proof
- Pool-1-free interactive panes: **PROVEN** (live `/status` = Claude Max account).
- Worktree isolation: **PROVEN** (pane cwd correct).
- Watch-not-drive constraint: **PROVEN** (no orchestrator channel into a TUI).
- Governor 80%-flip + finish-running-only + status-file coordination: **TO BUILD** (ACs in
  `docs/free-interactive-engine.md`).
