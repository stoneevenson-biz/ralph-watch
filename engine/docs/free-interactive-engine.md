# Free interactive fallback engine — design note + acceptance criteria

Lightweight spec (per `feedback_prd_vs_lightweight_tooling`: self-tooling in `~/.claude/ralph/`,
no slices/users → design-note not `/to-prd`). Decision rationale in `docs/adr/0003-*`. This file
is the **build done-gate**: each AC has a concrete verify; write the verify first, watch it fail,
then implement (ACF/TDD).

## Components to build
1. `governor.sh` — reads a Pool-2 spend ledger, returns flip decision at ≥80% of $200.
2. `ralph-interactive-lane.sh` — OUTER per-lane driver (fresh interactive pane per spec).
3. `ralph-interactive-stop-hook.sh` — INNER within-spec loop (promote from prototype).
4. 3 edits to `ralph-exec.sh` — `lane_engine()`, `build_lane()` third branch, finish-running-only.

## Coordination model: WATCH-NOT-DRIVE
The scheduler cannot drive an interactive pane (proven). The pane's only channel OUT is the
filesystem. Contract per worktree:
- `.fpr/current-spec.md` — the active spec (YAML frontmatter: iteration, max_iterations,
  completion_promise, verify, session_id + the prompt body). The inner hook reads/updates this.
- `.fpr/last-spec-status` — `done` | `failed` written by the inner hook when a spec resolves.
- The scheduler POLLS these + git + the test exit; it never expects a return value from the pane.

## Acceptance criteria (behavioral + verifiable)

### AC-1 — Interactive lane runs FREE (Pool 1)  [PROVEN — keep as regression check]
A lane tagged `engine: claude-interactive` launches an **interactive** `claude` (no `-p`) in its
worktree; `/status` shows `Claude Max account` (Pool 1), not API/metered.
- **Verify (manual):** a one-off `claude` launch in a worktree → `/status` in pane =
  "Claude Max account". (No automated seam — it's an external-process/billing fact.)
- **Verify (automated, the driver shape):** assert the launched command contains `claude` and does
  NOT contain `-p`/`--print`:
  `bash tests/test_interactive_no_print.sh` → greps the driver's launch line, fails if `-p` present.

### AC-2 — Governor flips at 80% of the credit
Given a spend ledger showing Pool-2 spend, `governor.sh decide <monthly_credit_usd>` prints
`interactive` when spend ≥ 80% of credit, else `metered`.
- **Verify:** `bash tests/test_governor.sh` — seeds a fake ledger at $161 (>80% of $200) → asserts
  `governor.sh decide 200` == `interactive`; seeds $100 → asserts `metered`; seeds exactly $160 →
  asserts `interactive` (≥ boundary). Exit 0 only if all three hold.

### AC-3 — Only NEW lanes flip; running metered lanes finish
When the flip triggers mid-run, lanes already building on `claude -p` complete on metered; only
next-scheduled lanes get `claude-interactive`.
- **Verify:** `bash tests/test_flip_scope.sh` — drive `lane_engine`/scheduler logic with 1 lane
  marked in-flight (metered) + 2 queued, ledger over threshold → assert the in-flight lane's engine
  is unchanged (`claude`) and the 2 queued resolve to `claude-interactive`. Exit 0 iff so.

### AC-4 — Free pane's done-signal reaches the scheduler via the status file
When an interactive spec passes its `verify`, the inner hook writes `.fpr/last-spec-status=done`
and the lane driver advances to the next spec (watch-not-drive).
- **Verify:** `bash tests/test_status_signal.sh` — create a temp worktree, seed `.fpr/current-spec.md`
  with `verify: "true"` (exits 0), invoke the stop-hook with a fake hook-input JSON → assert
  `.fpr/last-spec-status` == `done` and `current-spec.md` removed. Then seed `verify: "false"` →
  assert the hook emits a `{"decision":"block"}` JSON (re-feed) and increments iteration. Exit 0 iff both.

### AC-5 — Fresh context per spec (ralph rule preserved)
The outer driver starts a NEW interactive `claude` process per spec (not one long session).
- **Verify:** `bash tests/test_fresh_per_spec.sh` — run the driver in DRYRUN against a lane with 2
  specs → assert it prints/launches TWO separate `claude` invocations (one per spec), not one. Exit 0 iff 2.

## Out of scope (this build)
- remote/SSH PTY path (deferred — ADR-0003).
- Pane cleanup/process-hygiene daemon (flagged; follow-up).
- Real ccusage integration (governor reads a simple ledger first; ccusage is an optional reader).

## Done = all of AC-1(automated shape)..AC-5 verifies green + AC-1 manual Pool-1 check re-confirmed once.
