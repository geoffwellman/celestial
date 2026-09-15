// omp / pi extension: orchestrators are read-only over repositories.
//
// Loaded on root and orchestrator launches only (agents.yaml guard_hook, via
// cel run). Fires before every tool call; asks the plane's classifier
// (tools/hooks/guard-classify.sh) whether this pane's role may do this, and
// blocks with the reason when it may not. The rules live in lib/guard.sh and
// nowhere else - this file is an adapter, not a policy.
//
// Fails OPEN on any error of its own: a guard that cannot run must never take
// an agent down with it. The event contract is pi's ToolCallEvent /
// ToolCallEventResult ({ block, reason }).
// @ts-nocheck
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

function celRoot(): string {
  if (process.env.CEL_ROOT) return process.env.CEL_ROOT;
  // tools/hooks/<this file> -> repo root
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
}

function classify(mode: "command" | "path", arg: string): string {
  try {
    return execFileSync("bash", [path.join(celRoot(), "tools/hooks/guard-classify.sh"), mode, process.cwd(), arg], {
      encoding: "utf8",
      timeout: 3000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "allow";
  }
}

export default function celestialGuard(pi): void {
  // per-pane opt-out for sessions that live in a workspace dir but are not orchestrators
  if (process.env.CEL_GUARD === "0") return;
  pi.on("tool_call", (event) => {
    const input = (event && event.input) || {};
    let mode: "command" | "path";
    let arg: string;
    switch (event.toolName) {
      case "bash":
      case "powershell":
        mode = "command";
        arg = String(input.command ?? "");
        // the human-approved one-off, same spelling as the claude adapter
        if (arg.startsWith("CEL_GUARD_ALLOW_ONCE=1")) return;
        break;
      case "edit":
      case "write":
        mode = "path";
        arg = String(input.path ?? input.file_path ?? input.filePath ?? "");
        break;
      default:
        return;
    }
    const verdict = classify(mode, arg);
    if (verdict.startsWith("deny")) {
      return {
        block: true,
        reason:
          "celestial guard: " + verdict.slice(5).trim() +
          " If a human has approved this exact call, prefix it: CEL_GUARD_ALLOW_ONCE=1 <command>",
      };
    }
  });
}
