#!/bin/bash
# fpr-stop-hook.sh — Free Parallel Ralph: per-worktree INNER loop (within ONE spec).
# Derived from the official ralph-loop stop-hook (session-isolation logic reused),
# but scoped to a SINGLE spec. Fresh-context-per-spec is the OUTER loop's job
# (fpr-lane-driver.sh starts a NEW interactive claude per spec) — this hook only
# keeps the current session iterating on the current spec until test-green + promise.
#
# State file (per worktree): .fpr/current-spec.md  (YAML frontmatter + the spec prompt)
# Completion: the spec's verify command exits 0 AND the model emits <promise>PROMISE</promise>.
#
# Pool 1 (free): this fires inside an INTERACTIVE claude session. It NEVER shells out to
# `claude -p`. It only blocks/injects.

set -euo pipefail
HOOK_INPUT=$(cat)
STATE=".fpr/current-spec.md"
[[ -f "$STATE" ]] || exit 0   # no active spec -> allow exit

fm() { sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE"; }
get() { fm | grep "^$1:" | sed "s/^$1: *//" | sed 's/^"\(.*\)"$/\1/'; }

ITER=$(get iteration); MAX=$(get max_iterations)
PROMISE=$(get completion_promise); VERIFY=$(get verify)
STATE_SESSION=$(get session_id || true)

# Session isolation: this hook fires in every session in the project. Only the session
# that owns this worktree's spec should act. (In practice each worktree is its own dir,
# so .fpr/current-spec.md is already per-lane — this is belt-and-suspenders.)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')
if [[ -n "$STATE_SESSION" && "$STATE_SESSION" != "$HOOK_SESSION" ]]; then exit 0; fi

[[ "$ITER" =~ ^[0-9]+$ ]] || { echo "fpr: bad iteration" >&2; rm -f "$STATE"; exit 0; }
[[ "$MAX"  =~ ^[0-9]+$ ]] || MAX=0

# Hard iteration cap (FM-7 stuck-loop guard)
if [[ $MAX -gt 0 && $ITER -ge $MAX ]]; then
  echo "fpr: max iterations ($MAX) for this spec — exiting session (lane will advance/hold)."
  rm -f "$STATE"; exit 0
fi

# THE DONE GATE: run the spec's real verify command. Exit-0 == spec done.
# (This is the load-bearing "test is the done signal, not the model's word" rule.)
if [[ -n "$VERIFY" && "$VERIFY" != "null" ]]; then
  if bash -c "$VERIFY" >/dev/null 2>&1; then
    # Verify passed. Confirm the model also emitted the promise (belt+suspenders).
    TRANSCRIPT=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""')
    LAST=""
    if [[ -f "$TRANSCRIPT" ]]; then
      LAST=$(grep '"role":"assistant"' "$TRANSCRIPT" | tail -n 100 | \
        jq -rs 'map(.message.content[]? | select(.type=="text") | .text) | last // ""' 2>/dev/null || echo "")
    fi
    PROMISE_SEEN=$(echo "$LAST" | perl -0777 -ne 'print $1 if /<promise>(.*?)<\/promise>/s' 2>/dev/null || echo "")
    echo "fpr: VERIFY PASSED for current spec (promise_seen='${PROMISE_SEEN}'). Spec done — exiting session."
    # mark done for the lane driver, then allow exit (driver starts a FRESH session for next spec)
    echo "done" > .fpr/last-spec-status
    rm -f "$STATE"
    exit 0
  fi
fi

# Not done -> increment and re-feed the SAME spec prompt (within-spec iteration).
NEXT=$((ITER + 1))
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE")
[[ -n "$PROMPT_TEXT" ]] || { echo "fpr: empty spec prompt" >&2; rm -f "$STATE"; exit 0; }
tmp="${STATE}.tmp.$$"; sed "s/^iteration: .*/iteration: $NEXT/" "$STATE" > "$tmp"; mv "$tmp" "$STATE"

jq -n --arg p "$PROMPT_TEXT" --arg m "fpr iter $NEXT | verify: ${VERIFY:-none} | promise when TRUE: <promise>${PROMISE}</promise> (do not lie to exit)" \
  '{decision:"block", reason:$p, systemMessage:$m}'
exit 0
