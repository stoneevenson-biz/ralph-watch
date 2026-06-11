---
id: ADR-0001
title: Extend dashboard.mjs (vanilla Node) instead of adopting a web framework
status: accepted
created: 2026-06-06
---

## Context
The Cockpit (COCKPIT.md) needs a server + a responsive frontend. The obvious modern path is Next/Vite/React. But the entire ralph tooling is hand-rolled, zero-build, Windows/git-bash-friendly bash + vanilla Node `.mjs`, and `dashboard.mjs` already serves the loops registry + `status.json`.

## Decision
Extend `dashboard.mjs` and ship the frontend as ONE vanilla HTML/CSS/JS app under `cockpit/` with no build step. No framework, no bundler, no node_modules for the UI.

## Consequences
- **Pro:** no toolchain, no build, starts with `node dashboard.mjs` like everything else; trivially Windows-portable; the prototypes (already vanilla) port almost directly; one process to run.
- **Con:** no component framework — state is hand-managed DOM + a body-class toggle; acceptable because the app is read-mostly with a few action endpoints, not a complex SPA.
- Revisit only if the UI grows interactive enough that hand-managed DOM becomes the bottleneck. Until then, the consistency with the rest of the tooling (no per-tool toolchain) outweighs framework ergonomics.
