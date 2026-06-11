#!/usr/bin/env node
// pipeline-log.mjs — append one structured event to the SYSTEM feedback log (L4 loop).
//
// This is the memory for HOW WELL THE SYSTEM BUILDS (vs specs/tests = memory for building).
// Every loop writes signal here; /pipeline-retro reads it across runs to tell the user whether
// the pipeline itself is healthy and what to tune. Global (cross-repo) so patterns compound.
//
// Log: ~/.claude/ralph/pipeline-events.jsonl   (one JSON object per line, append-only)
//
// Usage: node pipeline-log.mjs <event-type> key=val key=val ...
//   event types (extensible):
//     run_start      repo=<name> phases=<n> lanes=<n>
//     lane_built     repo lane phase iterations=<n> result=green|red
//     lane_collapsed repo phase lanes_planned=<n> lanes_actual=<n>   (preflight serialized)
//     review         repo lane phase engine=codex|claude verdict=pass|fail p1=<n> p2=<n>
//     review_overturn repo lane phase was=codex_pass now=claude_fail  (trust signal!)
//     qa_reject      repo feature reason="<text>" upstream_gap=prd|ac|review|none
//     gotcha         repo lane note="<text>"
//     run_end        repo result=done|paused|failed held_for_review=<n> minutes=<n>
//
// Keep it dumb: this just appends. The retro skill does the analysis.

import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const [, , eventType, ...pairs] = process.argv;
if (!eventType) { console.error("usage: pipeline-log.mjs <event-type> key=val ..."); process.exit(2); }

const ev = { ts: new Date().toISOString(), event: eventType };
for (const p of pairs) {
  const i = p.indexOf("=");
  if (i < 0) continue;
  const k = p.slice(0, i);
  let v = p.slice(i + 1);
  if (/^-?\d+$/.test(v)) v = parseInt(v, 10);            // numeric coercion for metrics
  ev[k] = v;
}

const dir = join(homedir(), ".claude", "ralph");
mkdirSync(dir, { recursive: true });
appendFileSync(join(dir, "pipeline-events.jsonl"), JSON.stringify(ev) + "\n");
// silent on success (called from loops); print only if asked to debug
if (process.env.PIPELINE_LOG_DEBUG) console.log("logged:", JSON.stringify(ev));
