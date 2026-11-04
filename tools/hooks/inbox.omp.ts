// omp / pi extension: celestial inbox delivery without touching the composer.
//
// Claude's hooks only run at turn boundaries; OMP needs this extension to
// watch mail while idle and inject unread items into the next turn, without
// ever typing into the composer's human draft.
//   - session_start: run `cel inbox watch --parent <pid>` in its own process
//     group; each line becomes ctx.ui.notify - out of band, composer untouched.
//     The watch never moves the cursor.
//   - before_agent_start: `cel inbox read` (advances this reader's cursor) and
//     inject what it returns as a context message - delivered exactly once,
//     like tools/hooks/inbox-drain.sh.
//   - session_shutdown: kill the watcher's whole group (one tail | jq | while
//     over every mailbox, and at most one per pid and reader), so no tail
//     outlives the session; --parent is the backstop.
// Recipient and workspace come from the launch context: `cel` derives the
// reader from cwd/CEL_ROLE, and CEL_WORKSPACE names the mailbox when set.
// Fails open everywhere: an inbox problem must never take the agent down.
// @ts-nocheck
import { execFileSync, spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startReviewerRetirement } from "./reviewer-retirement.mjs";

function celRoot(): string {
  if (process.env.CEL_ROOT) return process.env.CEL_ROOT;
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
}
function celBin(): string { return path.join(celRoot(), "bin", "cel"); }
// Rex hosts the runtime directly rather than through Herdr's integration.
// Report only state observed by the runtime, never guessed from screen text.
function rexNote(state, ctx): void {
  if (process.env.CEL_SESSION_BACKEND !== "rex") return;
  try {
    const native = ctx?.sessionManager?.getSessionFile?.() || "";
    execFileSync(celBin(), ["sessions", "note", String(process.pid), state, native], {
      timeout: 3000, stdio: "ignore",
    });
  } catch { /* status observation must not break the runtime or inbox */ }
}
// CEL_INBOX_WS/CEL_INBOX_ME are exported by `cel run` for root and orchestrators;
// CEL_WORKSPACE is a directory, so it is never passed as a mailbox name.
//
// An EXPLICIT identity (CEL_INBOX_ME, which `cel run` sets only for root and
// orchestrators) is reached in every registered workspace, so mail sent from
// another workspace is never stranded. Still filtered to that one recipient, so
// nobody else's mail - root's included - is read or has its cursor moved.
// --workspace rides along so a launch workspace the registry lacks stays in
// the sweep. CEL_INBOX_ALL_WS=0 restores single-workspace scope. Workers get
// no CEL_INBOX_ME and keep cwd-derived single-workspace scoping.
function wsArgs(): string[] {
  const a = [];
  const me = process.env.CEL_INBOX_ME;
  if (me && process.env.CEL_INBOX_ALL_WS !== "0") a.push("--all-workspaces");
  if (process.env.CEL_INBOX_WS) a.push("--workspace", process.env.CEL_INBOX_WS);
  if (me) a.push("--for", me);
  return a;
}
const envMs = (k, d) => { const n = Number(process.env[k]); return Number.isFinite(n) && n > 0 ? n : d; };

let watcher = null;
// Wake an idle orchestrator (nobody at the keyboard) for new mail.
// Coalesced: one timer per burst, and no second wake until agent_end.
let api = null;
let wakeTimer = null;
let waking = false;
// Mail drained for a wake whose sendMessage failed: the cursor already moved,
// so it is held here and handed to the next wake or before_agent_start.
let pending = "";
// Mail is OWED when a watcher line or a backlog count said something arrived
// that no wake or turn has delivered yet. While owed, a wake withheld for an
// active turn or a non-empty composer is retried on a slow timer - never typed
// into the draft, never a busy loop - instead of waiting for a human to type.
let owed = false;
let retryTimer = null;
let wakeSince = 0;
let stopped = false;
// A reviewer retirement in progress (prepareExit until a failed exit is
// restored) and the process exiting: states a gone watcher stays gone in.
let retiring = false;
let exiting = false;
// session_shutdown happened and nothing since proves the session went on.
// A turn that was already ending reports agent_end AFTER shutdown, so
// agent_end is no proof; a new session_start, or a new turn starting, is.
let shutDown = false;
let lastCtx = null;
let reviewerRetirement = null;
let nativeTurnActive = false;

function startRetirement(ctx): void {
  try { reviewerRetirement?.dispose(); } catch {}
  reviewerRetirement = startReviewerRetirement({
    getContext: () => lastCtx,
    getInboxDebt: () => ({ owed, pending: pending.length > 0, waking }),
    getNativeTurnActive: () => nativeTurnActive,
    // Retirement cannot turn a failed/malformed count into an empty mailbox.
    countUnread: () => {
      const value = execFileSync("bash", [celBin(), "inbox", "count", ...wsArgs()], {
        cwd: lastCtx.cwd, encoding: "utf8", timeout: 5000,
        stdio: ["ignore", "pipe", "ignore"],
      }).trim();
      if (!/^(0|[1-9][0-9]*)$/.test(value)) throw new Error("inbox_count_unknown");
      const count = Number(value);
      if (!Number.isSafeInteger(count)) throw new Error("inbox_count_unknown");
      return count;
    },
    prepareExit: () => { retiring = true; stopped = true; stopWatcher(); },
    restoreAfterFailedExit: () => {
      retiring = false;
      stopped = false;
      startWatcher(lastCtx);
      owed = true;
      scheduleWake(lastCtx);
    },
  });
}
function takeMail(ctx): string {
  const fresh = drain(ctx); // null = the drain itself failed, not "no mail"
  const all = [pending, fresh].filter(Boolean).join("\n");
  pending = "";
  if (fresh === null) { owed = true; if (!all) scheduleRetry(ctx); } else owed = false;
  return all;
}

function scheduleWake(ctx): void {
  if (stopped || wakeTimer || !api) return;
  if (waking && Date.now() - wakeSince < envMs("CEL_INBOX_WAKE_STUCK_MS", 120000)) { scheduleRetry(ctx); return; }
  // A wake whose turn never reported agent_end (rejected, dropped, aborted)
  // must not hold the gate shut forever: past the stuck window it reopens.
  waking = false;
  wakeTimer = setTimeout(() => { wakeTimer = null; tryWake(ctx); }, envMs("CEL_INBOX_WAKE_MS", 3000));
  try { wakeTimer.unref(); } catch {}
}

function scheduleRetry(ctx): void {
  if (stopped || retryTimer || !owed) return;
  retryTimer = setTimeout(() => { retryTimer = null; if (owed) scheduleWake(ctx); }, envMs("CEL_INBOX_RETRY_MS", 15000));
  try { retryTimer.unref(); } catch {}
}

function tryWake(ctx): void {
  if (stopped || waking || !api) return;
  try {
    if (!ctx || typeof ctx.isIdle !== "function" || !ctx.isIdle()) { scheduleRetry(ctx); return; }
    const draft = ctx.ui && typeof ctx.ui.getEditorText === "function" ? ctx.ui.getEditorText() : null;
    if (typeof draft !== "string") return; // no way to see the composer: notify-only
    if (draft.trim() !== "") { scheduleRetry(ctx); return; }
    const mail = takeMail(ctx); // advances the cursor: before_agent_start won't see it again
    if (!mail) return;
    waking = true; wakeSince = Date.now();
    const fail = () => { pending = [mail, pending].filter(Boolean).join("\n"); owed = true; waking = false; scheduleRetry(ctx); };
    let r;
    try {
      r = api.sendMessage({
        customType: "cel-inbox", display: true,
        content: "New messages in your celestial inbox (delivered once, woke you while idle):\n" + mail +
          "\nAct on them, or say why not.",
      }, { triggerTurn: true });
    } catch { fail(); return; }
    if (r && typeof r.then === "function") r.then(undefined, fail);
  } catch { /* fail open: notify already happened */ }
}
export function __watcherPid(): number | undefined { return watcher ? watcher.pid : undefined; }

// WATCHER RECOVERY. A watcher can die (killed, OOM, a `cel` upgrade under it),
// and without one the session sits on unread mail. The hook owns the
// lifecycle, so it restarts it - one at a time, backoff doubling to 60s and
// reset once a watcher has lived a minute, never after shutdown - and then
// counts what arrived while nobody was tailing, through the same coalesced wake.
//
// The exit event is not the only way a watcher goes: a spawn the kernel
// refuses (EAGAIN in a fork storm, EMFILE, ENOENT) emits 'error' and NEVER
// 'exit' - in node and in bun - so the old variable held a pid-less child
// forever and nothing restarted it. So liveness is the child PROCESS, and it
// is re-checked where the session is known to be alive: every agent_end, and
// a slow idle check for a session that sits without turns.
let restartTimer = null;
let restartDelay = 0;
let watcherStarted = 0;
// A pid is not an identity: once the watcher is reaped, the kernel can hand
// its pid to any other child of this process - a bash tool, say - with the
// same parent. The kernel's identity is the pair (pid, starttime: field 22
// of /proc/<pid>/stat), recorded at spawn and compared on every look.
const PROCFS = (() => { try { readFileSync("/proc/self/stat"); return true; } catch { return false; } })();
function procStat(pid) { // -> { state, ppid, start } or throws
  const s = readFileSync(`/proc/${pid}/stat`, "utf8");
  const f = s.slice(s.lastIndexOf(")") + 2).split(" ");
  return { state: f[0], ppid: f[1], start: f[19] };
}
// Still the process this hook spawned (alive or an unreaped zombie), so its
// pid - and the process group it leads - cannot belong to anyone else.
function ownsPid(w): boolean {
  if (!w || !w.pid) return false;
  if (!PROCFS) return w.exitCode == null && w.signalCode == null; // unreaped: the pid is still held
  try {
    const st = procStat(w.pid);
    return w.celStart != null && st.start === w.celStart && st.ppid === String(process.pid);
  } catch { return false; }
}
function watcherAlive(w): boolean {
  if (!w || !w.pid || w.exitCode != null || w.signalCode != null) return false;
  if (!PROCFS) {
    try { process.kill(w.pid, 0); return true; } catch (e) { return !!e && e.code === "EPERM"; }
  }
  if (!ownsPid(w)) return false;
  try { const { state } = procStat(w.pid); return state !== "Z" && state !== "X"; } catch { return false; }
}
function scheduleRestart(ctx): void {
  if (stopped || restartTimer) return;
  const base = envMs("CEL_INBOX_RESTART_MS", 2000);
  if (Date.now() - watcherStarted > 60000) restartDelay = 0;
  restartDelay = restartDelay ? Math.min(restartDelay * 2, 60000) : base;
  restartTimer = setTimeout(() => {
    restartTimer = null;
    if (stopped || watcherAlive(watcher)) return;
    startWatcher(ctx);
    wakeForBacklog(ctx);
  }, restartDelay);
  try { restartTimer.unref(); } catch {}
}
// Respawn now when no live watcher exists. A pending backoff restart is
// superseded: a turn ending is not a crash loop.
function ensureWatcher(ctx): void {
  if (stopped || retiring || exiting || !ctx || watcherAlive(watcher)) return;
  if (restartTimer) { clearTimeout(restartTimer); restartTimer = null; }
  startWatcher(ctx);
  wakeForBacklog(ctx);
}

function stopWatcher(): void {
  if (wakeTimer) { clearTimeout(wakeTimer); wakeTimer = null; }
  if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  if (restartTimer) { clearTimeout(restartTimer); restartTimer = null; }
  const w = watcher; watcher = null;
  if (!ownsPid(w)) return; // a reused pid's group is someone else's
  try { process.kill(-w.pid, "SIGTERM"); } catch { try { w.kill("SIGTERM"); } catch {} }
}

function startWatcher(ctx): void {
  const w0 = watcher; watcher = null;
  if (ownsPid(w0)) { try { process.kill(-w0.pid, "SIGTERM"); } catch {} }
  if (stopped) return;
  try {
    const w = spawn("bash", [celBin(), "inbox", "watch", ...wsArgs(), "--parent", String(process.pid)], {
      cwd: (ctx && ctx.cwd) || process.cwd(),
      detached: true, // own process group, so shutdown can kill the pipeline
      stdio: ["ignore", "pipe", "ignore"],
      env: { ...process.env, CEL_INBOX_NOTIFY: process.env.CEL_INBOX_NOTIFY ?? "0" },
    });
    // Read before this tick ends: nothing reaps it until the event loop runs,
    // so the pid is still this child's.
    if (w.pid && PROCFS) { try { w.celStart = procStat(w.pid).start; } catch {} }
    w.unref();
    // A refused spawn reports here and never through 'exit'.
    w.on("error", () => { if (watcher === w && !watcherAlive(w)) { watcher = null; scheduleRestart(ctx); } });
    w.on("exit", () => { if (watcher === w) { watcher = null; scheduleRestart(ctx); } });
    let buf = "";
    w.stdout.setEncoding("utf8");
    w.stdout.on("data", (chunk) => {
      buf += chunk;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
        if (!line) continue;
        try { ctx && ctx.ui && ctx.ui.notify(line, /INBOX (escalation|decision|blocked) /.test(line) ? "warning" : "info"); } catch {}
        owed = true;
        scheduleWake(ctx);
      }
    });
    watcher = w; watcherStarted = Date.now();
  } catch { watcher = null; scheduleRestart(ctx); }
}

// The watcher tails from the end, so mail already waiting when the session
// starts never produces a line. Count it (the count does not move the cursor),
// say so out of band, and arm the SAME coalesced wake new mail uses: its
// idle/empty-composer rules decide, nothing else delivers.
function unreadCount(ctx): number {
  try {
    const n = execFileSync("bash", [celBin(), "inbox", "count", ...wsArgs()], {
      cwd: (ctx && ctx.cwd) || process.cwd(),
      encoding: "utf8", timeout: 15000, stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return Number(n) || 0;
  } catch { return 0; }
}

function wakeForBacklog(ctx): void {
  const n = unreadCount(ctx);
  if (n <= 0) return;
  try { ctx && ctx.ui && ctx.ui.notify(`INBOX ${n} unread message(s) waiting`, "info"); } catch {}
  owed = true;
  scheduleWake(ctx);
}

// Every delivered item carries `[<id>]` so `cel drive receipt` can
// prove the message reached the conversation by matching the session file
// exactly, not fuzzily. Read as --json and rendered here; a line that is not
// an item (a sweep prefix aside) is passed through as text.
function renderItem(line: string): string {
  const m = /^(\[[^\]]+\] )?(\{.*\})$/.exec(line);
  if (!m) return line;
  let o; try { o = JSON.parse(m[2]); } catch { return line; }
  if (!o || !o.id) return ""; // an empty-mailbox report, not mail
  const ws = m[1] || "";
  if (o.kind === "update") return `[${o.id}] ${ws}\u21bb ${o.from} (\u00d7${o.count || 2}): ${o.message}`;
  return `[${o.id}] ${ws}[${String(o.ts || "").slice(11, 16)} ${o.kind} from ${o.from}] ${o.message}`;
}
function drain(ctx): string {
  try {
    const out = execFileSync("bash", [celBin(), "inbox", "read", "--json", ...wsArgs()], {
      cwd: (ctx && ctx.cwd) || process.cwd(),
      encoding: "utf8", timeout: 15000, stdio: ["ignore", "pipe", "ignore"],
    });
    return out.split("\n").map((l) => l.trim()).filter(Boolean).map(renderItem).filter(Boolean).join("\n");
  } catch { return null; }
}

// THE IN-AGENT COMMANDS (lib/here.sh). Each /cel-<verb> runs `cel here <verb>`
// - itself a thin wrapper over one `cel` command - and posts what it printed
// into the conversation without starting a turn, so the agent sees what its
// owner ran. Registered for the agents that own a product or the box (core,
// root, orchestrators, solo agents); workers and reviewers get none. The
// `cel-` prefix: omp has built-in /review and /restart.
const HERE_VERBS = {
  mode: "Show or switch this product's mode: /cel-mode [product] [solo|fleet]",
  status: "cel fleet for this product's workspace (core: the whole box)",
  inbox: "Read unread celestial mail now",
  decide: "Open owner questions (core: all; others: your own)",
  review: "Start a reviewer pane: /cel-review [repo#]<pr>",
  land: "Merge a PR through this mode's checked path: /cel-land [repo#]<pr>",
  restart: "Restart this agent on its own session once this turn ends",
};
const HERE_CORE_VERBS = { focus: "Bring a product's agent forward: /cel-focus <product>" };
// A BOUNDED CAPTURE. A land can run a noisy gate for most of an hour and all
// of it would otherwise sit in this agent's memory: the first quarter of the
// cap (how it started) and the last three quarters (how it ended) are kept,
// and the middle is counted and said to be gone.
function boundedOutput(max: number) {
  const headMax = Math.floor(max / 4), tailMax = max - headMax;
  let head = "", tail = "", dropped = 0;
  return {
    add(c: string): void {
      if (head.length < headMax) { const take = c.slice(0, headMax - head.length); head += take; c = c.slice(take.length); }
      if (!c) return;
      tail += c;
      if (tail.length > tailMax) { dropped += tail.length - tailMax; tail = tail.slice(tail.length - tailMax); }
    },
    text(): string { return dropped ? `${head}\n... (${dropped} characters of output dropped) ...\n${tail}` : head + tail; },
  };
}
function runHere(verb: string, args: string, ctx): Promise<string> {
  const { promise, resolve } = Promise.withResolvers<string>();
  const out = boundedOutput(envMs("CEL_HERE_OUTPUT_MAX", 64 * 1024));
  let child;
  try {
    child = spawn("bash", [celBin(), "here", verb, ...args.split(/\s+/).filter(Boolean)], {
      cwd: (ctx && ctx.cwd) || process.cwd(), stdio: ["ignore", "pipe", "pipe"], env: process.env,
    });
  } catch (e) { resolve(`cel here ${verb}: could not start (${e})`); return promise; }
  // land may run the local gate; everything else answers in seconds.
  const limit = verb === "land" ? envMs("CEL_HERE_LAND_MS", 45 * 60000) : envMs("CEL_HERE_MS", 120000);
  const timer = setTimeout(() => { try { child.kill("SIGTERM"); } catch {} out.add(`\n(cel here ${verb} timed out)`); }, limit);
  child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
  child.stdout.on("data", (c) => { out.add(c); });
  child.stderr.on("data", (c) => { out.add(c); });
  child.on("error", (e) => { out.add(`\n${e}`); });
  child.on("close", (code) => {
    clearTimeout(timer);
    // Colour codes are for a terminal; the conversation gets plain text.
    const text = out.text().replace(/\x1b\[[0-9;]*m/g, "").trim() || "(no output)";
    resolve(code === 0 ? text : `${text}\n(exit ${code})`);
  });
  return promise;
}
function registerHereCommands(pi): void {
  const role = process.env.CEL_ROLE || "";
  if (!["core", "root", "orchestrator", "solo"].includes(role)) return;
  if (typeof pi.registerCommand !== "function") return;
  const verbs = role === "core" ? { ...HERE_VERBS, ...HERE_CORE_VERBS } : HERE_VERBS;
  for (const [verb, description] of Object.entries(verbs)) {
    try {
      pi.registerCommand(`cel-${verb}`, {
        description,
        handler: async (args, ctx) => {
          try { ctx && ctx.ui && ctx.ui.notify(`cel here ${verb} ${args || ""}`.trim() + " ...", "info"); } catch {}
          const text = await runHere(verb, args || "", ctx);
          try {
            await pi.sendMessage({
              customType: "cel-command", display: true,
              content: `/cel-${verb}${args ? " " + args : ""} (run by the owner):\n${text}`,
            }, { triggerTurn: false });
          } catch { try { ctx && ctx.ui && ctx.ui.notify(text.slice(0, 500), "info"); } catch {} }
        },
      });
    } catch { /* fail open: a command that cannot register must not take the inbox down */ }
  }
}

export default function celestialInbox(pi): void {
  if (process.env.CEL_INBOX_HOOK === "0") return;
  api = pi;
  registerHereCommands(pi);
  // agent_end of a running session: a gone watcher comes back. Not after
  // session_shutdown - the turn that was ending when it came is not proof.
  pi.on("agent_end", (_e, ctx) => {
    lastCtx = ctx; nativeTurnActive = false; rexNote("idle", ctx); waking = false;
    if (!shutDown) ensureWatcher(ctx);
    if (owed && lastCtx) scheduleWake(lastCtx);
  });
  // A turn STARTING after session_shutdown proves the session resumed.
  const resumed = (ctx) => {
    if (!shutDown || retiring || exiting) return;
    shutDown = false; stopped = false; ensureWatcher(ctx);
  };
  pi.on("session_start", (_e, ctx) => { rexNote("idle", ctx); shutDown = false; stopped = false; nativeTurnActive = false; lastCtx = ctx; startWatcher(ctx); wakeForBacklog(ctx); startRetirement(ctx); });
  // Idle: no turn ends, so a watcher whose death was never reported is
  // found here. It never un-stops a shut-down session, and leaves a pending
  // backoff restart to run.
  const idleCheck = setInterval(() => { if (!restartTimer) ensureWatcher(lastCtx); }, envMs("CEL_INBOX_WATCH_CHECK_MS", 60000));
  try { idleCheck.unref(); } catch {}
  pi.on("session_tree", (_e, ctx) => { lastCtx = ctx; });
  pi.on("agent_start", (_e, ctx) => { lastCtx = ctx; nativeTurnActive = true; resumed(ctx); });
  pi.on("before_agent_start", (_e, ctx) => {
    nativeTurnActive = true;
    lastCtx = ctx;
    resumed(ctx);
    rexNote("working", ctx);
    const mail = takeMail(ctx);
    if (!mail) return;
    return {
      message: {
        customType: "celestial-inbox",
        display: true,
        content: "Messages waiting in your celestial inbox (delivered once):\n" + mail +
          "\nAct on them as part of this turn, or say why not.",
      },
    };
  });
  pi.on("session_shutdown", () => { reviewerRetirement?.dispose(); reviewerRetirement = null; shutDown = true; stopped = true; stopWatcher(); });
  process.once("exit", () => { exiting = true; clearInterval(idleCheck); reviewerRetirement?.dispose(); reviewerRetirement = null; stopped = true; stopWatcher(); });
}
