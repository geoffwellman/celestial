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
function wsArgs(): string[] {
  const a = [];
  if (process.env.CEL_INBOX_WS) a.push("--workspace", process.env.CEL_INBOX_WS);
  if (process.env.CEL_INBOX_ME) a.push("--for", process.env.CEL_INBOX_ME);
  return a;
}

let watcher = null;
// CEL-76: wake an idle orchestrator (nobody at the keyboard) for new mail.
// Coalesced: one timer per burst, and no second wake until agent_end.
let api = null;
let wakeTimer = null;
let waking = false;

function scheduleWake(ctx): void {
  if (wakeTimer || waking || !api) return;
  const ms = Number(process.env.CEL_INBOX_WAKE_MS ?? 3000);
  wakeTimer = setTimeout(() => { wakeTimer = null; tryWake(ctx); }, ms);
  try { wakeTimer.unref(); } catch {}
}

function tryWake(ctx): void {
  if (waking || !api) return;
  try {
    if (!ctx || typeof ctx.isIdle !== "function" || !ctx.isIdle()) return;
    const draft = ctx.ui && typeof ctx.ui.getEditorText === "function" ? ctx.ui.getEditorText() : null;
    if (typeof draft !== "string" || draft.trim() !== "") return;
    const mail = drain(ctx); // advances the cursor: before_agent_start won't see it again
    if (!mail) return;
    waking = true;
    const r = api.sendMessage({
      customType: "cel-inbox", display: true,
      content: "New messages in your celestial inbox (delivered once, woke you while idle):\n" + mail +
        "\nAct on them, or say why not.",
    }, { triggerTurn: true });
    if (r && typeof r.catch === "function") r.catch(() => { waking = false; });
  } catch { /* fail open: notify already happened */ }
}
export function __watcherPid(): number | undefined { return watcher ? watcher.pid : undefined; }

function stopWatcher(): void {
  if (wakeTimer) { clearTimeout(wakeTimer); wakeTimer = null; }
  const w = watcher; watcher = null;
  if (!w || !w.pid) return;
  try { process.kill(-w.pid, "SIGTERM"); } catch { try { w.kill("SIGTERM"); } catch {} }
}

function startWatcher(ctx): void {
  stopWatcher();
  try {
    const w = spawn("bash", [celBin(), "inbox", "watch", ...wsArgs(), "--parent", String(process.pid)], {
      cwd: (ctx && ctx.cwd) || process.cwd(),
      detached: true, // own process group, so shutdown can kill the pipeline
      stdio: ["ignore", "pipe", "ignore"],
      env: { ...process.env, CEL_INBOX_NOTIFY: process.env.CEL_INBOX_NOTIFY ?? "0" },
    });
    w.unref();
    w.on("error", () => {});
    w.on("exit", () => { if (watcher === w) watcher = null; });
    let buf = "";
    w.stdout.setEncoding("utf8");
    w.stdout.on("data", (chunk) => {
      buf += chunk;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
        if (!line) continue;
        try { ctx && ctx.ui && ctx.ui.notify(line, /INBOX (escalation|decision|blocked) /.test(line) ? "warning" : "info"); } catch {}
        scheduleWake(ctx);
      }
    });
    watcher = w;
  } catch { watcher = null; }
}

function drain(ctx): string {
  try {
    return execFileSync("bash", [celBin(), "inbox", "read", ...wsArgs()], {
      cwd: (ctx && ctx.cwd) || process.cwd(),
      encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch { return ""; }
}

export default function celestialInbox(pi): void {
  if (process.env.CEL_INBOX_HOOK === "0") return;
  api = pi;
  pi.on("agent_end", () => { waking = false; });
  pi.on("session_start", (_e, ctx) => { startWatcher(ctx); });
  pi.on("before_agent_start", (_e, ctx) => {
    const mail = drain(ctx);
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
  pi.on("session_shutdown", () => { stopWatcher(); });
  process.once("exit", stopWatcher);
}
