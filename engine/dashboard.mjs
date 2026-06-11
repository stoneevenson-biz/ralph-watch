#!/usr/bin/env node
// dashboard.mjs — ONE live visual dashboard for ALL ralph loops. No per-loop terminals.
//
// Serves a single auto-refreshing HTML page: every loop = a card with emoji state, slice
// progress bar, current detail, last commits. A BLOCKED card shows the question + options +
// a "Resolve" button that writes a trigger file; you (the agent/CLI) pick it up and open ONE
// Claude grill. Reads each repo's .ralph/status.json — repos self-register in the registry.
//
// Registry: ~/.claude/ralph/loops.json  →  { "repoName": "/abs/path/to/repo", ... }
//   (the executor appends itself on start; stale entries are pruned when their dir is gone)
//
// Usage:  node ~/.claude/ralph/dashboard.mjs [port]   (default 7799)  →  open http://localhost:7799
import { createServer } from "node:http";
import { readFileSync, existsSync, writeFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { execSync } from "node:child_process";

const PORT = parseInt(process.argv[2] || "7799", 10);
const REG = join(homedir(), ".claude", "ralph", "loops.json");

function loadReg() { try { return JSON.parse(readFileSync(REG, "utf8")); } catch { return {}; } }

function statusOf(dir) {
  const sp = join(dir, ".ralph", "status.json");
  if (!existsSync(dir)) return null;                 // pruned by caller
  let s = { state: "idle", detail: "no status yet", phase: "", blocker: "" };
  if (existsSync(sp)) { try { s = JSON.parse(readFileSync(sp, "utf8")); } catch {} }
  // slice progress from specs/
  let total = 0, done = 0;
  try {
    const specs = join(dir, "specs");
    if (existsSync(specs)) for (const f of readdirSync(specs)) {
      if (!f.endsWith(".md") || /README/i.test(f)) continue;
      const t = readFileSync(join(specs, f), "utf8");
      if (!/^parent:/m.test(t)) continue;            // only slice specs
      total++;
      if (/^status:\s*(done|completed|shipped)/m.test(t)) done++;
    }
  } catch {}
  // last commit subject
  let commit = "";
  try { commit = execSync(`git -C "${dir}" log -1 --pretty=%s 2>/dev/null`, { encoding: "utf8" }).trim(); } catch {}
  // blocker question (if blocked)
  let blockerText = "";
  if ((s.state === "blocked" || s.state === "failed") && s.blocker) {
    const bp = s.blocker.startsWith("/") || /^[A-Za-z]:/.test(s.blocker) ? s.blocker : join(dir, s.blocker);
    try { blockerText = readFileSync(bp, "utf8"); } catch { blockerText = s.detail || ""; }
  }
  return { ...s, total, done, commit, blockerText };
}

const EMOJI = { running: "🔨", held: "⏸️", blocked: "⛔", failed: "❌", done: "✅", idle: "💤" };
const LABEL = { running: "BUILDING", held: "IN REVIEW", blocked: "BLOCKED — needs you", failed: "FAILED", done: "DONE", idle: "idle" };

// Per-repo lane detail: scan sibling worktrees ../<repo>-p*-<lane> for live build state.
function lanesOf(dir, name) {
  const lanes = [];
  try {
    const parent = join(dir, "..");
    for (const d of readdirSync(parent)) {
      const m = d.match(new RegExp(`^${name}-p(\\d+)-(.+)$`));
      if (!m) continue;
      const wt = join(parent, d);
      let commit = "", building = existsSync(join(wt, "BLOCKERS.md")) ? "blocked" : "building";
      try { commit = execSync(`git -C "${wt}" log -1 --pretty=%s 2>/dev/null`, { encoding: "utf8" }).trim(); } catch {}
      lanes.push({ phase: m[1], lane: m[2], state: building, commit });
    }
  } catch {}
  return lanes;
}

function snapshot() {
  const reg = loadReg();
  const out = [];
  for (const [name, dir] of Object.entries(reg)) {
    const s = statusOf(dir);
    if (s === null) continue;                          // dir gone → skip (pruned)
    out.push({ name, dir, ...s, lanes: lanesOf(dir, name) });
  }
  return out;
}

const esc = (x)=>String(x||"").replace(/</g,"&lt;");
const PAGE = (repos) => `<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="3">
<title>Ralph Loops</title>
<style>
 body{background:#0d1117;color:#e6edf3;font:15px/1.5 system-ui,Segoe UI,sans-serif;margin:0;padding:24px}
 h1{font-size:22px;margin:0 0 4px} .sub{color:#7d8590;margin:0 0 24px;font-size:13px}
 .repo{margin:0 0 28px;border:1px solid #30363d;border-radius:14px;overflow:hidden}
 .repo.blocked{border-color:#f85149} .repo.done{border-color:#3fb950} .repo.running{border-color:#58a6ff} .repo.held{border-color:#d29922}
 .rhead{display:flex;align-items:center;gap:12px;padding:14px 18px;background:#161b22;border-bottom:1px solid #30363d}
 .rname{font-size:18px;font-weight:600;font-family:ui-monospace,monospace}
 .rstate{font-size:15px} .rprog{margin-left:auto;font-size:13px;color:#7d8590}
 .rbar{height:6px;background:#21262d} .rfill{height:100%;background:linear-gradient(90deg,#58a6ff,#3fb950)}
 .lanes{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));padding:16px}
 .lane{background:#0d1117;border:1px solid #30363d;border-radius:10px;padding:12px}
 .lane.blocked{border-color:#f85149} .lane.building{border-color:#58a6ff}
 .lt{font-weight:600;display:flex;gap:6px;align-items:center} .lmeta{font-size:12px;color:#7d8590;margin-top:4px}
 .lcommit{font-family:ui-monospace,monospace;font-size:11px;color:#8b949e;margin-top:6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 .detail{padding:0 18px 4px;color:#c9d1d9} .commit{padding:0 18px 12px;font-family:ui-monospace,monospace;font-size:12px;color:#8b949e}
 .blk{margin:0 18px 14px;background:#21262d;border-radius:8px;padding:12px;font-size:13px;white-space:pre-wrap;max-height:240px;overflow:auto}
 .btn{display:inline-block;margin:0 18px 16px;background:#f85149;color:#fff;border:0;border-radius:8px;padding:9px 16px;font-size:14px;cursor:pointer;text-decoration:none}
 .empty{color:#7d8590;text-align:center;padding:60px}
</style></head><body>
<h1>🔄 Ralph Loops</h1><p class="sub">live · auto-refresh 3s · ${new Date().toLocaleTimeString()}</p>
${repos.length === 0 ? '<div class="empty">💤 no loops running.<br>start one: <code>cd repo &amp;&amp; ~/.claude/ralph/ralph-exec.sh</code></div>' :
repos.map(r => {
  const pct = r.total ? Math.round(100*r.done/r.total) : 0;
  const e = EMOJI[r.state]||"•", lab = LABEL[r.state]||r.state;
  const blocked = r.state==="blocked"||r.state==="failed";
  return `<section class="repo ${r.state}">
    <div class="rhead">
      <span class="rstate">${e}</span>
      <span class="rname">${esc(r.name)}</span>
      <span class="rstate">${lab}${r.phase?` · phase ${esc(r.phase)}`:""}</span>
      <span class="rprog">${r.total?`${r.done}/${r.total} slices · ${pct}%`:""}</span>
    </div>
    ${r.total?`<div class="rbar"><div class="rfill" style="width:${pct}%"></div></div>`:""}
    <div class="detail">${esc(r.detail)}</div>
    ${r.commit?`<div class="commit">↪ ${esc(r.commit)}</div>`:""}
    ${blocked?`<div class="blk">${esc((r.blockerText||r.detail||"").slice(0,1400))}</div>
      <a class="btn" href="/resolve?repo=${encodeURIComponent(r.name)}">⛔ Resolve — open Claude to answer</a>`:""}
    ${r.lanes && r.lanes.length?`<div class="lanes">${r.lanes.map(L=>`
      <div class="lane ${L.state}">
        <div class="lt">${L.state==="blocked"?"⛔":"🔨"} ${esc(L.lane)} <span class="lmeta">p${esc(L.phase)}</span></div>
        ${L.commit?`<div class="lcommit">↪ ${esc(L.commit)}</div>`:""}
      </div>`).join("")}</div>`:""}
  </section>`;
}).join("")}
</body></html>`;

createServer((req, res) => {
  if (req.url.startsWith("/resolve")) {
    const repo = decodeURIComponent((req.url.split("repo=")[1]||"").split("&")[0]);
    const reg = loadReg();
    if (reg[repo]) {
      // write a trigger file the agent/CLI watches → opens ONE claude grill for this repo
      writeFileSync(join(homedir(), ".claude", "ralph", "resolve-request.json"),
        JSON.stringify({ repo, dir: reg[repo], ts: new Date().toISOString() }));
    }
    res.writeHead(200, { "content-type": "text/html" });
    res.end(`<body style="background:#0d1117;color:#e6edf3;font:16px system-ui;padding:40px">
      ✅ Resolve requested for <b>${repo}</b>.<br><br>A Claude grill will open in your shell to resolve it.<br>
      <br><a href="/" style="color:#58a6ff">← back to dashboard</a></body>`);
    return;
  }
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(PAGE(snapshot()));
}).listen(PORT, () => console.log(`Ralph dashboard → http://localhost:${PORT}`));
