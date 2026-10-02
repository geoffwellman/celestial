// omp / pi extension: celestial inbox delivery without touching the composer.
//
// omp has neither claude's Monitor nor its UserPromptSubmit hook, so routine
// mail to an omp orchestrator used to arrive only as `herdr agent prompt`,
// which typed into the composer over the human's draft (CEL-65). This hook
// is the omp equivalent of both halves:
//   - session_start: run `cel inbox watch --parent <pid>` in its own process
//     group; each line becomes ctx.ui.notify - out of band, composer untouched.
//     The watch never moves the cursor.
//   - before_agent_start: `cel inbox read` (advances this reader's cursor) and
//     inject what it returns as a context message - delivered exactly once,
//     like tools/hooks/inbox-drain.sh.
//   - session_shutdown: kill the watcher's whole group (tail | jq | while),
//     so no tail outlives the session; --parent is the backstop.
// Recipient and workspace come from the launch context: `cel` derives the
// reader from cwd/CEL_ROLE, and CEL_WORKSPACE names the mailbox when set.
// Fails open everywhere: an inbox problem must never take the agent down.
// @ts-nocheck
import { execFileSync, spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

function celRoot(): string {
  if (process.env.CEL_ROOT) return process.env.CEL_ROOT;
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
}
function celBin(): string { return path.join(celRoot(), "bin", "cel"); }
// CEL_INBOX_WS/CEL_INBOX_ME are exported by `cel run` for root and orchestrators;
// CEL_WORKSPACE is a directory, so it is never passed as a mailbox name.
//
// An EXPLICIT identity (CEL_INBOX_ME, which `cel run` sets only for root and
// orchestrators) is reached in every registered workspace: mail to
// celestial-orch from a vhs worker sat for days because this hook watched,
// counted and drained plane alone. Still filtered to that one recipient, so
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
// CEL-76: wake an idle orchestrator (nobody at the keyboard) for new mail.
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
let lastCtx = null;
function takeMail(ctx): string {
  const fresh = drain(ctx);
  const all = [pending, fresh].filter(Boolean).join("\n");
  pending = "";
  owed = false;
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

// WATCHER RECOVERY. A watcher that dies (killed, OOM, a `cel` upgrade under
// it) used to leave watcher=null for the rest of the session: standout-orch
// sat on 4 unread with no watch process at all. The hook owns the lifecycle,
// so it restarts it - one at a time, backoff doubling to 60s and reset once a
// watcher has lived a minute, never after shutdown - and then counts what
// arrived while nobody was tailing, through the same coalesced wake.
let restartTimer = null;
let restartDelay = 0;
let watcherStarted = 0;
function scheduleRestart(ctx): void {
  if (stopped || restartTimer) return;
  const base = envMs("CEL_INBOX_RESTART_MS", 2000);
  if (Date.now() - watcherStarted > 60000) restartDelay = 0;
  restartDelay = restartDelay ? Math.min(restartDelay * 2, 60000) : base;
  restartTimer = setTimeout(() => {
    restartTimer = null;
    if (stopped || watcher) return;
    startWatcher(ctx);
    wakeForBacklog(ctx);
  }, restartDelay);
  try { restartTimer.unref(); } catch {}
}

function stopWatcher(): void {
  if (wakeTimer) { clearTimeout(wakeTimer); wakeTimer = null; }
  if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  if (restartTimer) { clearTimeout(restartTimer); restartTimer = null; }
  const w = watcher; watcher = null;
  if (!w || !w.pid) return;
  try { process.kill(-w.pid, "SIGTERM"); } catch { try { w.kill("SIGTERM"); } catch {} }
}

function startWatcher(ctx): void {
  const w0 = watcher; watcher = null;
  if (w0 && w0.pid) { try { process.kill(-w0.pid, "SIGTERM"); } catch {} }
  if (stopped) return;
  try {
    const w = spawn("bash", [celBin(), "inbox", "watch", ...wsArgs(), "--parent", String(process.pid)], {
      cwd: (ctx && ctx.cwd) || process.cwd(),
      detached: true, // own process group, so shutdown can kill the pipeline
      stdio: ["ignore", "pipe", "ignore"],
      env: { ...process.env, CEL_INBOX_NOTIFY: process.env.CEL_INBOX_NOTIFY ?? "0" },
    });
    w.unref();
    w.on("error", () => {});
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

// CEL-85: the watcher tails from the end, so mail already waiting when the
// session starts never produced a line - an orchestrator restarted onto an
// 85-message backlog sat on it until a human typed. Count it (the count does
// not move the cursor), say so out of band, and arm the SAME coalesced wake
// new mail uses: its idle/empty-composer rules decide, nothing else delivers.
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

function drain(ctx): string {
  try {
    return execFileSync("bash", [celBin(), "inbox", "read", ...wsArgs()], {
      cwd: (ctx && ctx.cwd) || process.cwd(),
      encoding: "utf8", timeout: 15000, stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch { return ""; }
}

export default function celestialInbox(pi): void {
  if (process.env.CEL_INBOX_HOOK === "0") return;
  api = pi;
  pi.on("agent_end", () => { waking = false; if (owed && lastCtx) scheduleWake(lastCtx); });
  pi.on("session_start", (_e, ctx) => { stopped = false; lastCtx = ctx; startWatcher(ctx); wakeForBacklog(ctx); });
  pi.on("before_agent_start", (_e, ctx) => {
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
  pi.on("session_shutdown", () => { stopped = true; stopWatcher(); });
  process.once("exit", () => { stopped = true; stopWatcher(); });
}
