---
id: ADR-0002
title: Linear is the system of record for work tracking; the Cockpit does not rebuild a board
status: accepted
created: 2026-06-06
---

## Context
The Cockpit could render its own Kanban/slice board. But Linear is already wired into the pipeline (`to-issues` creates a Project per repo, Milestones per phase, status columns, `lane:` labels; `linear-status.mjs` writes status). Rebuilding a board in the Cockpit would duplicate Linear's UI — worse, and a second thing to keep in sync.

## Decision
Three sources of truth, each owning one layer:
- **spec-files** → truth for the BUILD (the executor reads `specs/*.md`).
- **Linear** → truth for the human VIEW of tracked work (what slices exist, where they sit).
- **`.ralph/`** → truth for the LIVE layer (which lane is on which iteration, right now).

The Cockpit FUSES Linear (tracked) + `.ralph` (live), deep-links to Linear for the full board/history, and writes Linear on resolve/advance. It builds only what Linear can't.

## Consequences
- **Pro:** no duplicated board to maintain; Linear stays the single tracking authority; the Cockpit shrinks to its unique value (live pulse, grill, plain-English, docs, ops). Resolving anywhere keeps spec + Linear consistent.
- **Con:** the Cockpit depends on the Linear API for the tracking view (handled: filesystem-only repos fall back to `.ralph`-derived state; the API read is non-blocking — a Linear outage degrades to live-only, doesn't break the Cockpit).
- The "spec-file is source of truth" rule (pipeline) and "Linear drives the Cockpit" (this) coexist because they own different layers — spec=build, Linear=view. Surface any place they're treated as the same.
