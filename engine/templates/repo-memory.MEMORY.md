# Repo Memory — <repo-name>

Append-only **gotchas log** for THIS repo. One file per lesson, frontmatter + body, same format
as your global memory — just repo-scoped and committed here. Read this at the start of any
work in this repo; it'll save you from a trap someone already hit.

**What goes here (dynamic):** non-obvious things learned the hard way while working —
"the test DB needs seeding first", "this module looks dead but isn't", "lanes X and Y secretly
share the port config". **What does NOT go here (static):** build/test commands, module map,
conventions — those live in `AGENTS.md`. Map vs margin-notes: AGENTS.md is the map; this is the notes.

Each entry is `<slug>.md` with frontmatter `name` / `description` / `metadata.type` (use
`gotcha` for traps, `decision` for a local call too small for an ADR). Add a one-line pointer below.

## Index
<!-- - [slug.md](slug.md) — one-line hook -->
