#!/usr/bin/env node
// linear-status.mjs — RECORD a Linear status-transition intent (does NOT call Linear).
//
// Same guardrail as linear-ralph-pull.mjs: raw node has no Linear creds/MCP, and ALL Linear
// writes must go through the agent (so guardrails live in one place). So this script only
// APPENDS an intent to .ralph/linear-queue.jsonl. The orchestrating agent later FLUSHES the
// queue to Linear via MCP (see ralph-exec.sh "Linear flush" + the ralph skill doc).
//
// It resolves the slice's linear_issue id from the spec frontmatter so the agent's flush has
// everything it needs (issue id + target state name) with no re-derivation.
//
// Usage: node ~/.claude/ralph/linear-status.mjs <spec-file> <state-name>
//   state-name ∈ "Todo" | "In Progress" | "In Review" | "Done" | "Backlog"
// Example: node ~/.claude/ralph/linear-status.mjs specs/F-01-ui.md "In Progress"

import { readFileSync, appendFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";

const STATE_IDS = {
  "Backlog": "e64751f6-de3a-48d8-a276-9de85050daa1",
  "Todo": "24c7e914-6bd5-48b3-a47c-832fde43c198",
  "In Progress": "9369f455-a16a-4b98-b769-bee917aa1361",
  "In Review": "25b38aa9-ab31-4d3e-964a-b46555010ee5",
  "Done": "a49bd0a2-6e66-49b3-bf84-9a9050b4fb75",
};

const [, , specFile, stateName] = process.argv;
if (!specFile || !stateName) {
  console.error('usage: linear-status.mjs <spec-file> "<state-name>"');
  process.exit(2);
}
if (!STATE_IDS[stateName]) {
  console.error(`unknown state "${stateName}". valid: ${Object.keys(STATE_IDS).join(", ")}`);
  process.exit(2);
}

function fm(text, key) {
  const m = text.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return null;
  for (const line of m[1].split("\n")) {
    const mm = line.match(/^([a-zA-Z_]+):\s*(.*)$/);
    if (mm && mm[1] === key) return mm[2].trim() || null;
  }
  return null;
}

let issueId = null, sliceId = null, lane = null;
try {
  const text = readFileSync(specFile, "utf8");
  issueId = fm(text, "linear_issue");
  sliceId = fm(text, "id");
  lane = fm(text, "lane");
} catch {
  console.error(`cannot read ${specFile}`);
  process.exit(1);
}

// No Linear mirror for this slice → nothing to queue (filesystem-only repo). Not an error.
if (!issueId) {
  console.log(`(no linear_issue in ${specFile} — Linear mirror off for this slice; skipping)`);
  process.exit(0);
}

mkdirSync(".ralph", { recursive: true });
const intent = {
  ts: new Date().toISOString(),
  sliceId,
  lane,
  spec: specFile,
  linear_issue: issueId,
  stateName,
  stateId: STATE_IDS[stateName],
};
appendFileSync(join(".ralph", "linear-queue.jsonl"), JSON.stringify(intent) + "\n");
console.log(`queued: ${sliceId} → ${stateName} (issue ${issueId})`);
