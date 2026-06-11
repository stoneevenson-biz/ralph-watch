#!/usr/bin/env bash
# codex-review-gate.sh — run an INDEPENDENT code review via the Codex CLI and write a
# verdict file the ralph executor reads. Codex is a separate process → ZERO Claude tokens.
#
# This is the token-saving review gate: the executor calls this instead of asking the Claude
# agent to review. Codex pass → verdict:pass written → executor merges/advances automatically.
# Codex FAIL → verdict:fail + findings written → executor holds + escalates to the Claude agent
# (which fixes via /receive-review). Claude only spends tokens when there's a real problem.
#
# Pass/fail rule (from the codex skill): `[P1]` marker in output = FAIL; otherwise PASS.
#
# Usage: codex-review-gate.sh <base-sha> <verdict-file> <request-file>
#   <base-sha>      diff base (e.g. the phase-start SHA, or a lane branch point)
#   <verdict-file>  where to write the verdict (.ralph/reviews/<gate>.verdict)
#   <request-file>  the gate's request file (for context; its specs: lines name the ACs)
set -uo pipefail

BASE="${1:?base sha}"; VERF="${2:?verdict file}"; REQF="${3:-}"
mkdir -p "$(dirname "$VERF")"

# Codex absent → cannot self-review. Do NOT silently pass (that would merge unreviewed code).
# Write a verdict that tells the executor to fall back to the Claude agent review.
if ! command -v codex >/dev/null 2>&1; then
  { echo "verdict: escalate"; echo "reason: codex CLI not found — fall back to /review-clean (agent review)"; } > "$VERF"
  echo "codex not found → wrote 'escalate' verdict; agent must review."
  exit 0
fi

# Boundary instruction: keep Codex on repo code only, never touch skill defs (from codex skill).
BOUNDARY="IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, .claude/skills/, or agents/. These are skill definitions for a different AI system. Review ONLY the repository code in this diff. Flag any AC-violating, broken, insecure, or data-loss bug as [P1]. Lesser issues as [P2]."

# Append the gate's ACs/specs context if we have it (helps Codex judge against requirements).
INSTR="$BOUNDARY"
if [ -n "$REQF" ] && [ -f "$REQF" ]; then
  INSTR="$INSTR

Review the diff against these slice specs (their Acceptance Criteria are the done-gate):
$(cat "$REQF")"
fi

TMPOUT="$(mktemp)"; TMPERR="$(mktemp)"
# read-only, high reasoning, no stdin. 5.5-min cap mirrors the codex skill's wrapper.
timeout 330 codex review "$INSTR" --base "$BASE" -c 'model_reasoning_effort="high"' < /dev/null >"$TMPOUT" 2>"$TMPERR"
rc=$?

if [ "$rc" = "124" ]; then
  { echo "verdict: escalate"; echo "reason: codex review timed out — agent should review"; } > "$VERF"
  echo "codex review TIMED OUT → escalate to agent."; rm -f "$TMPOUT" "$TMPERR"; exit 0
fi

# Pass/fail: any [P1] = FAIL. Capture findings into the verdict so the Claude fixer has them.
if grep -q '\[P1\]' "$TMPOUT"; then
  {
    echo "verdict: fail"
    echo "reviewer: codex"
    echo "reason: codex found [P1] (Critical) findings — Claude must fix via /receive-review before merge"
    echo "--- findings ---"
    grep -E '\[P1\]|\[P2\]' "$TMPOUT" || true
    echo "--- full codex output ---"
    cat "$TMPOUT"
  } > "$VERF"
  echo "codex GATE: FAIL — wrote findings to $VERF (executor will hold + escalate to Claude)."
else
  {
    echo "verdict: pass"
    echo "reviewer: codex"
    echo "reason: no [P1] findings"
    P2="$(grep -c '\[P2\]' "$TMPOUT" 2>/dev/null || echo 0)"
    echo "p2_findings: $P2   # Important/Minor — file as follow-up Linear issues, do not block"
    if [ "$P2" -gt 0 ]; then echo "--- [P2] findings (follow-ups) ---"; grep -E '\[P2\]' "$TMPOUT" || true; fi
  } > "$VERF"
  echo "codex GATE: PASS → wrote $VERF (executor proceeds; $(grep -c '\[P2\]' "$TMPOUT" 2>/dev/null || echo 0) P2 follow-ups noted)."
fi
rm -f "$TMPOUT" "$TMPERR"
exit 0
