#!/usr/bin/env node
// `cel drive list|tail|receipt` (CEL-120). `send` lives in lib/drive.sh: it is
// `cel inbox send` and nothing else, so the delivery rules stay in the omp
// inbox hook - the only code that can see isIdle() and the composer.
//
// Who is running comes from `herdr agent list` + `herdr pane list`, never
// `cel fleet`: the console's cold fleet read timed out at 20 s under load and
// a chat view cannot wait on the whole fleet to show one conversation.
import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { Tailer, Normaliser, parseLines, sessionPath } from "./transcript.mjs";

const die = (m, rc = 1) => { process.stderr.write(`cel drive: ${m}\n`); process.exit(rc); };
const herdr = (...args) => new Promise((res) => {
  execFile("herdr", args, { timeout: 5000, maxBuffer: 64 << 20 }, (err, out) => {
    if (err) return res(null);
    try { res(JSON.parse(out)); } catch { res(null); }
  });
});

// CEL_DRIVE_WS: "name<TAB>path" lines from the registry, passed in by
// lib/drive.sh so this process does not parse YAML.
function workspaces() {
  return (process.env.CEL_DRIVE_WS || "").split("\n").map((l) => l.split("\t")).filter((p) => p[0] && p[1])
    .map(([name, p]) => ({ name, path: p.replace(/\/+$/, "") })).sort((a, b) => b.path.length - a.path.length);
}
function placeOf(cwd, wss) {
  if (!cwd) return { workspace: null, product: null };
  const w = wss.find((x) => cwd === x.path || cwd.startsWith(x.path + "/"));
  if (!w) return { workspace: null, product: null };
  const rest = cwd.slice(w.path.length).split("/").filter(Boolean);
  const i = rest.findIndex((s) => s === "repos" || s === "products");
  return { workspace: w.name, product: i >= 0 && rest[i + 1] ? rest[i + 1] : null };
}
// Orchestrators today; workers join in phase 2.
const isOrch = (n) => typeof n === "string" && (/-orch$/.test(n) || n === "root");

async function list() {
  const [agents, panes] = await Promise.all([herdr("agent", "list"), herdr("pane", "list")]);
  const arr = agents && agents.result && Array.isArray(agents.result.agents) ? agents.result.agents : null;
  if (!arr) return null;
  const byPane = new Map(((panes && panes.result && panes.result.panes) || []).map((p) => [p.pane_id, p]));
  const wss = workspaces();
  return arr.filter((a) => isOrch(a.name)).map((a) => {
    const p = byPane.get(a.pane_id) || {};
    return {
      name: a.name, pane: a.pane_id, runtime: a.agent || p.agent || null,
      status: a.agent_status || p.agent_status || null,
      session: sessionPath(a.agent_session || p.agent_session, a.cwd || p.cwd),
      cwd: a.cwd || p.cwd || null, label: p.label || null, ...placeOf(a.cwd || p.cwd, wss),
    };
  });
}
async function find(name) {
  const all = await list();
  if (!all) die("herdr did not answer `agent list` - unknown, not empty", 3);
  const o = all.find((x) => x.name === name);
  if (!o) die(`no orchestrator named '${name}' (cel drive list)`, 2);
  return o;
}

function fmt(e) {
  const t = e.ts ? String(e.ts).slice(11, 16) + " " : "";
  switch (e.kind) {
    case "user": return `${t}> ${e.text}`;
    case "assistant": return `${t}${e.text}`;
    case "thinking": return `${t}… (thinking)`;
    case "tool": return `${t}  ${e.tool.isError ? "✗" : "·"} ${e.tool.summary}`;
    case "system": return `${t}[${e.source || "system"}] ${e.text}`;
    case "compaction": return `${t}──── compacted ────\n${e.text}`;
    default: return `${t}${e.text || ""}`;
  }
}

async function tail(args) {
  const name = args.find((a) => !a.startsWith("--") && args[args.indexOf(a) - 1] !== "--since");
  if (!name) die("usage: cel drive tail <orch> [--json] [--follow] [--since <entry-id>]");
  const json = args.includes("--json"), follow = args.includes("--follow");
  const si = args.indexOf("--since"); let since = si >= 0 ? args[si + 1] : null;
  const emit = (e) => process.stdout.write((json ? JSON.stringify(e) : fmt(e)) + "\n");
  let o = await find(name);
  if (!o.session) die(`${name}: herdr names no session file`, 3);
  let t = new Tailer(o.session);
  const first = parseLines(t.poll(), o.runtime);
  let start = 0;
  if (since) { const i = first.map((e) => e.id).lastIndexOf(since); start = i >= 0 ? i + 1 : 0; }
  for (const e of first.slice(start)) emit(e);
  if (!follow) return;
  let n = new Normaliser(o.runtime);
  for (const e of first) if (e.kind === "tool") n.calls.set(e.id, e);
  const ms = Number(process.env.CEL_DRIVE_POLL_MS) || 1000;
  let tick = 0;
  for (;;) {
    await new Promise((r) => setTimeout(r, ms));
    // re-resolve the session every few ticks: a restart or /new swaps the file
    if (++tick % 2 === 0) {
      const all = await list().catch(() => null);
      const now = all && all.find((x) => x.name === name);
      if (now && now.session && now.session !== o.session) {
        o = now; t = new Tailer(o.session); n = new Normaliser(o.runtime);
        emit({ id: null, parentId: null, ts: new Date().toISOString(), kind: "system", source: "drive", text: `session changed: ${o.session}`, fold: false });
        for (const e of parseLines(t.poll(), o.runtime)) emit(e);
        continue;
      }
    }
    const lines = t.poll();
    if (t.reset) { n = new Normaliser(o.runtime); for (const e of parseLines(lines, o.runtime)) emit(e); continue; }
    for (const e of n.push(lines)) emit(e);
  }
}

// queued -> delivered (the recipient's cursor is at or past the id) ->
// in-conversation (the hook's `[<id>]` is in a delivered inbox message in
// the session file). Read-only: nothing here touches the agent.
async function receipt(args) {
  const id = args.find((a) => !a.startsWith("--"));
  if (!id || !/^\d+$/.test(id)) die("usage: cel drive receipt <id> [--json]");
  const dir = process.env.CEL_INBOX_DIR || path.join(process.env.HOME, ".local/share/cel/inbox");
  let item = null, ws = null;
  for (const f of fs.existsSync(dir) ? fs.readdirSync(dir) : []) {
    if (!f.endsWith(".jsonl")) continue;
    const text = fs.readFileSync(path.join(dir, f), "utf8");
    if (!text.includes(`"${id}"`)) continue;
    for (const l of text.split("\n")) { try { const o = JSON.parse(l); if (o.id === id) { item = o; ws = f.slice(0, -6); } } catch {} }
    if (item) break;
  }
  if (!item) die(`no message ${id} in any mailbox`, 2);
  let cursor = "";
  for (const f of fs.readdirSync(dir)) {
    if (f === `${ws}.${item.to}.cursor` || (f.startsWith(`${ws}.${item.to}.`) && f.endsWith(".cursor"))) {
      const c = fs.readFileSync(path.join(dir, f), "utf8").trim();
      if (c.length > cursor.length || (c.length === cursor.length && c > cursor)) cursor = c;
    }
  }
  const delivered = cursor !== "" && (cursor.length > id.length || (cursor.length === id.length && cursor >= id));
  let inConv = false;
  if (delivered) {
    const o = await list().then((a) => a && a.find((x) => x.name === item.to)).catch(() => null);
    if (o && o.session && fs.existsSync(o.session)) {
      const text = fs.readFileSync(o.session, "utf8");
      let i = -1;
      while (!inConv && (i = text.indexOf(`[${id}]`, i + 1)) >= 0) {
        const s = text.lastIndexOf("\n", i) + 1;
        const e = text.indexOf("\n", i);
        const line = text.slice(s, e < 0 ? text.length : e);
        if (/"custom_message"/.test(line) && /"(cel-inbox|celestial-inbox)"/.test(line)) inConv = true;
      }
    }
  }
  const state = inConv ? "in-conversation" : delivered ? "delivered" : "queued";
  const r = { id, to: item.to, workspace: ws, from: item.from, kind: item.kind, state };
  process.stdout.write(args.includes("--json") ? JSON.stringify(r) + "\n" : `${id} -> ${item.to} (${ws}): ${state}\n`);
}

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === "list") {
  const all = await list();
  if (!all) die("herdr did not answer `agent list` - unknown, not empty", 3);
  if (rest.includes("--json")) process.stdout.write(JSON.stringify(all) + "\n");
  else for (const o of all) process.stdout.write(`${o.name}\t${o.status}\t${o.runtime}\t${o.workspace || "-"}\t${o.session || "-"}\n`);
} else if (cmd === "find") {
  process.stdout.write(JSON.stringify(await find(rest[0])) + "\n");
} else if (cmd === "tail") await tail(rest);
else if (cmd === "receipt") await receipt(rest);
else die(`unknown subcommand '${cmd || ""}'`);
