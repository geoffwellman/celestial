// The drive core's reader (CEL-120): turn an agent's session JSONL into the
// normalised events the dashboard and the console both draw.
//
// Why a session file and not the screen: the console's `talk` scraped
// `herdr agent read`, which is wrapped, truncated text; omp, pi and claude
// all write a structured append-only JSONL conversation, and herdr names the
// file for every pane. Reading means tailing that file - never reparsing it:
// one orchestrator's session was 13 MB after three weeks, and a poll that
// rereads it every second is the console's 20-second cold read again.
//
// Event: {id, parentId, ts, kind: user|assistant|thinking|tool|system|compaction,
//         text?, tool?: {name, summary, isError}, fold}
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// ---- redaction (owner, 2026-10-11) ------------------------------------
// A transcript carries every tool output the agent saw, including any secret
// it printed. The view masks the obvious shapes; it is a net, not a vault.
const R = "[redacted]";
const PATTERNS = [
  // JSON form, either spacing: "token":"x", "apiKey": "a b" (review of #146)
  [/"([A-Za-z0-9_-]*(?:key|token|secret|password|passwd))"(\s*:\s*)"(?:[^"\\]|\\.)*"/gi, (_m, n, sep) => `"${n}"${sep}"${R}"`],
  // NAME=value where the name says secret - env lines, query strings, flags.
  // A quoted value is masked whole, spaces and all: FOO_SECRET="a b" leaked
  // "b" when only the first word was taken.
  [/\b([A-Za-z0-9_]*(?:key|token|secret|password|passwd))\s*=\s*("[^"]*"|'[^']*'|[^\s&"',;]+)/gi, (_m, n) => `${n}=${R}`],
  [/\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/g, () => `Bearer ${R}`],
  [/\bsk-[A-Za-z0-9_-]{16,}/g, () => R],
  [/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/g, () => R],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}/g, () => R],
  [/\bxox[abposr]-[A-Za-z0-9-]{10,}/g, () => R],
  [/\bAKIA[0-9A-Z]{16}\b/g, () => R],
];
export function redact(s) {
  if (typeof s !== "string" || !s) return s;
  let out = s;
  for (const [re, fn] of PATTERNS) out = out.replace(re, fn);
  return out;
}

// ---- normalisation ----------------------------------------------------
const clip = (s, n = 80) => { s = String(s ?? "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 1) + "…" : s; };
// Redact BEFORE clipping: a secret cut in half at 80 characters no longer
// matches its pattern, and its first half leaked (review of #146).
function toolSummary(name, args) {
  let a = args;
  if (typeof a === "string") { try { a = JSON.parse(a); } catch { return `${name}: ${clip(redact(a))}`; } }
  const v = a && typeof a === "object"
    ? (a.command ?? a.cmd ?? a.path ?? a.file_path ?? a.pattern ?? a.url ?? a.query ?? JSON.stringify(a))
    : a;
  return `${name}: ${clip(redact(String(v ?? "")))}`;
}
function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((b) => b && b.type === "text").map((b) => b.text || "").join("\n");
}
const ev = (e, kind, extra) => ({ id: e.id, parentId: e.parentId ?? null, ts: e.ts ?? null, kind, fold: false, ...extra });

// Map one raw line into the shared {id, parentId, ts, raw} envelope, per runtime.
function envelope(o, runtime) {
  if (!o || typeof o !== "object") return null;
  if (runtime === "claude") {
    if (!o.uuid) return null;
    return { id: o.uuid, parentId: o.parentUuid ?? null, ts: o.timestamp ?? null, o };
  }
  if (!o.id || o.type === "session" || o.type === "title") return null;
  return { id: o.id, parentId: o.parentId ?? null, ts: o.timestamp ?? null, o };
}

// One envelope -> zero or more events. toolResults resolve against `calls`
// (toolCallId -> tool event) so a call and its result fold to one line.
function eventsOf(e, runtime, calls) {
  const o = e.o; const out = [];
  if (runtime === "claude") {
    if (o.type !== "user" && o.type !== "assistant") return out;
    const c = o.message && o.message.content;
    if (typeof c === "string") { out.push(ev(e, o.type, { text: redact(c) })); return out; }
    for (const b of c || []) {
      if (b.type === "text" && b.text) out.push(ev(e, o.type === "user" ? "user" : "assistant", { text: redact(b.text) }));
      else if (b.type === "thinking") out.push(ev(e, "thinking", { text: redact(b.thinking || ""), fold: true }));
      else if (b.type === "tool_use") { const t = ev(e, "tool", { fold: true, tool: { name: b.name, summary: redact(toolSummary(b.name, b.input)), isError: false } }); calls.set(b.id, t); out.push(t); }
      else if (b.type === "tool_result") { const t = calls.get(b.tool_use_id); if (t) t.tool.isError = !!b.is_error; }
    }
    return out;
  }
  switch (o.type) {
    case "message": {
      const m = o.message || {};
      if (m.role === "user") { const t = textOf(m.content); if (t) out.push(ev(e, "user", { text: redact(t) })); }
      else if (m.role === "assistant") {
        const c = typeof m.content === "string" ? [{ type: "text", text: m.content }] : m.content || [];
        for (const b of c) {
          if (b.type === "text" && b.text) out.push(ev(e, "assistant", { text: redact(b.text) }));
          else if (b.type === "thinking") out.push(ev(e, "thinking", { text: redact(b.thinking || ""), fold: true }));
          else if (b.type === "toolCall") { const t = ev(e, "tool", { fold: true, tool: { name: b.name, summary: redact(toolSummary(b.name, b.arguments)), isError: false } }); calls.set(b.id, t); out.push(t); }
        }
      } else if (m.role === "toolResult") {
        const t = calls.get(m.toolCallId);
        if (t) t.tool.isError = !!m.isError;
        else out.push(ev(e, "tool", { fold: true, tool: { name: m.toolName, summary: m.toolName, isError: !!m.isError } }));
      }
      return out; // developer/system messages are harness plumbing: dropped
    }
    case "custom_message":
      if (o.display) out.push(ev(e, "system", { text: redact(textOf(o.content)), source: o.customType }));
      return out;
    case "compaction":
      out.push(ev(e, "compaction", { text: redact(o.summary || ""), tokensBefore: o.tokensBefore ?? null }));
      return out;
    default: return out; // custom, model_usage, credential_pin, title*, thinking_level_change
  }
}

// A session is a TREE (every entry has id/parentId): a fork or a /tree jump
// leaves dead branches in file order. Show the last leaf's ancestor chain.
// In a cold-start window the chain stops where its parent fell off the front.
export function activeChain(envs) {
  if (!envs.length) return [];
  const by = new Map(envs.map((e) => [e.id, e]));
  const chain = []; const seen = new Set();
  for (let e = envs[envs.length - 1]; e && !seen.has(e.id); e = by.get(e.parentId)) { seen.add(e.id); chain.push(e); }
  return chain.reverse();
}

export function parseLines(lines, runtime = "omp", { chain = true } = {}) {
  const envs = [];
  for (const l of lines) {
    if (!l || !l.trim()) continue;
    let o; try { o = JSON.parse(l); } catch { continue; }
    const e = envelope(o, runtime); if (e) envs.push(e);
  }
  const calls = new Map(); const out = [];
  for (const e of chain ? activeChain(envs) : envs) out.push(...eventsOf(e, runtime, calls));
  return out;
}
export function parseText(text, runtime) { return parseLines(text.split("\n"), runtime); }

// Stateful variant for --follow: tool results that arrive in a later poll
// than their call still fold onto it.
export class Normaliser {
  constructor(runtime) { this.runtime = runtime; this.calls = new Map(); }
  push(lines) {
    const out = [];
    for (const l of lines) {
      let o; try { o = JSON.parse(l); } catch { continue; }
      const e = envelope(o, this.runtime); if (!e) continue;
      const before = new Map([...this.calls].map(([k, t]) => [k, t.tool.isError]));
      out.push(...eventsOf(e, this.runtime, this.calls));
      // a result that flipped an earlier call to failed is re-emitted as an update
      for (const [k, t] of this.calls) if (before.has(k) && before.get(k) !== t.tool.isError) out.push({ ...t, update: true });
    }
    return out;
  }
}

// ---- offset tailer ----------------------------------------------------
// Per file {inode, size, offset} plus the trailing partial line. A changed
// inode or a shrink means the file was swapped or truncated: cold start
// again and say so (`reset`). Cold start reads only the last COLD bytes and
// throws away the first, almost certainly partial, line - `tail -c 2MB | jq`
// failed on exactly that.
export const COLD_BYTES = 2_000_000;
export class Tailer {
  constructor(file, { coldBytes = COLD_BYTES } = {}) {
    this.file = file; this.coldBytes = coldBytes;
    this.ino = null; this.offset = 0; this.carry = ""; this.bytesRead = 0; this.reset = false;
  }
  #read(from, to) {
    const len = to - from; if (len <= 0) return "";
    const buf = Buffer.alloc(len);
    const fd = fs.openSync(this.file, "r");
    try { let got = 0; while (got < len) { const n = fs.readSync(fd, buf, got, len - got, from + got); if (!n) break; got += n; } this.bytesRead += got; return buf.subarray(0, got).toString("utf8"); }
    finally { fs.closeSync(fd); }
  }
  poll() {
    this.reset = false;
    let st; try { st = fs.statSync(this.file); } catch { return []; }
    let text;
    if (this.ino === null || st.ino !== this.ino || st.size < this.offset) {
      this.reset = this.ino !== null;
      const from = Math.max(0, st.size - this.coldBytes);
      text = this.#read(from, st.size);
      if (from > 0) { const i = text.indexOf("\n"); text = i >= 0 ? text.slice(i + 1) : ""; }
      this.carry = "";
    } else {
      if (st.size === this.offset) return [];
      text = this.carry + this.#read(this.offset, st.size);
    }
    this.ino = st.ino; this.offset = st.size;
    const parts = text.split("\n");
    this.carry = parts.pop() ?? "";
    return parts.filter((l) => l.trim());
  }
}

// ---- where a pane's session lives -------------------------------------
// omp/pi: herdr gives the path. claude: only an id; the file sits under the
// project dir named by the cwd with / and . turned into -.
export function sessionPath(agentSession, cwd, home = os.homedir()) {
  if (!agentSession || !agentSession.value) return null;
  if (agentSession.kind === "path") return agentSession.value;
  if (agentSession.kind === "id" && cwd) return path.join(home, ".claude", "projects", cwd.replace(/[\/.]/g, "-"), agentSession.value + ".jsonl");
  return null;
}
