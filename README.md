# ralph-watch

A flicker-free live TUI monitor for [Ralph](https://ghuntley.com/ralph/)-style autonomous build loops — the terminal dashboard you actually want to stare at while an agent loop runs.

It polls a repo's `.ralph/` state files and renders:

- **State header** — running / in review / blocked / failed / complete, with current phase + spinner
- **Animated slice progress bar** + per-slice checklist (`✓ shipped` / `▶ building` / `⛔ blocked` / `○ queued`)
- **Velocity panel** — slice pace + ETA, per-iteration cadence sparkline, commit rate, live spend
- **Recent-commit ticker** and a 🎉 celebration banner on convergence

No tmux, no `jq`, no Node. Pure bash + `git` + `awk`/`sed`. Windows git-bash friendly.

## Usage

```bash
./ralph-watch.sh <repo-dir>     # defaults to "."
POLL=2 ./ralph-watch.sh ./my-repo   # refresh interval in seconds (default 2)
```

It reads, if present:

- `.ralph/status.json` — `{ "state", "phase", "detail", "blocker" }`
- `.ralph/progress.jsonl` — `{"ts","done","total"}` points (the script appends these as the done-count changes)
- `.ralph/events.jsonl` — `iter_start` / `iter_end` events for per-iteration timing
- `.ralph/spend-ledger.jsonl` — lines with `total_cost_usd` for live spend
- `specs/*.md` — slice specs with YAML frontmatter (`parent`, `status`, `phase`, `lane`)

When the loop reports `blocked`/`failed`, the terminal hands off to an interactive `claude` grill to resolve the blocker (if the `claude` CLI is installed), then returns to monitoring.

## License

MIT
