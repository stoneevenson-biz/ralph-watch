#!/usr/bin/env node
/**
 * lane-adapter-driver.mjs — spawn a LaneAdapter session for one spec.
 *
 * Usage:
 *   node lane-adapter-driver.mjs \
 *     --cwd   <worktree-path>           \
 *     --spec  <path-to-current-spec.md> \
 *     --fpr   <path-to-.fpr-dir>        \
 *     [--relay-path <path-to-dist/lane-adapter.js>]
 *
 * Exits 0 when .fpr/last-spec-status is written (done/failed/blocked-needs-approval).
 * Exits 1 on timeout or spawn error.
 *
 * DRYRUN=1: print resolved args and exit 0 without spawning (for test_lane_no_skip.sh).
 */
import { createRequire } from "node:module";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve, join, dirname } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const { values: args } = parseArgs({
  options: {
    cwd:        { type: "string" },
    spec:       { type: "string" },
    fpr:        { type: "string" },
    model:      { type: "string" },
    "relay-path": { type: "string" },
  },
  allowPositionals: false,
  strict: false,
});

const cwd       = args.cwd   ?? process.cwd();
const specPath  = args.spec  ?? join(cwd, ".fpr", "current-spec.md");
const fprDir    = args.fpr   ?? join(cwd, ".fpr");
// Force Sonnet on interactive (Pool-1) lanes to stretch the free weekly quota (ADR-0003).
const model     = args.model ?? "claude-sonnet-4-6";

// Resolve the LaneAdapter module: explicit --relay-path, else look for the conpty-relay dist
// relative to this script's location or via a sibling prototypes/ path.
function resolveRelayPath() {
  if (args["relay-path"]) return resolve(args["relay-path"]);
  // Relative to this file: ../../ralph-os-p2-lane-adapter/... or installed package
  const candidates = [
    join(__dirname, "../../ralph-os-p2-lane-adapter/prototypes/conpty-relay/dist/lane-adapter.js"),
    join(__dirname, "../conpty-relay/dist/lane-adapter.js"),
    join(cwd, "node_modules/@ralph-os/conpty-relay/dist/lane-adapter.js"),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  return null;
}

const relayPath = resolveRelayPath();

if (process.env.DRYRUN === "1") {
  // Print the resolved launch info so shell tests can grep it.
  console.log(`LANE-ADAPTER-DRIVER cwd=${cwd} spec=${specPath} fpr=${fprDir} model=${model} relay=${relayPath ?? "(not found)"}`);
  console.log(`LAUNCH: LaneAdapter(cwd=${cwd}) — plain claude --model ${model}, no --dangerously-skip-permissions, no -p`);
  process.exit(0);
}

if (!relayPath) {
  console.error("lane-adapter-driver: could not find dist/lane-adapter.js — build conpty-relay first");
  process.exit(1);
}

const { LaneAdapter } = await import(relayPath);

const adapter = new LaneAdapter({ cwd, fprDir, extraArgs: ["--model", model] });
adapter.on("log", (msg) => console.error(`[lane-adapter] ${msg}`));
adapter.on("exit", (code) => {
  console.error(`[lane-adapter] claude exited code=${code}`);
});

const POLL_TIMEOUT = parseInt(process.env.FPR_POLL_TIMEOUT ?? "1800", 10) * 1000;
const t0 = Date.now();

try {
  await adapter.start();
} catch (err) {
  console.error(`lane-adapter-driver: start failed: ${err.message}`);
  process.exit(1);
}

// Feed the spec as the first prompt
let specBody = "";
try {
  const raw = readFileSync(specPath, "utf8");
  // Strip YAML frontmatter
  const match = raw.match(/^---[\s\S]*?---\n([\s\S]*)$/);
  specBody = match ? match[1].trim() : raw.trim();
} catch {
  specBody = "(no spec found)";
}

// Type the spec content and submit
adapter.write(specBody + "\n");

// Poll .fpr/last-spec-status until written or timeout
await new Promise((resolve) => {
  const statusPath = join(fprDir, "last-spec-status");
  const tick = () => {
    if (existsSync(statusPath)) return resolve();
    if (Date.now() - t0 > POLL_TIMEOUT) {
      writeFileSync(statusPath, "timeout", "utf8");
      return resolve();
    }
    setTimeout(tick, 5000);
  };
  setTimeout(tick, 5000);
});

adapter.stop();
process.exit(0);
