// omp / pi extension: orchestrators are read-only over repositories.
//
// Loaded on root, product-agent and team-member launches (agents.yaml guard_hook, via
// cel run). Fires before every tool call; asks the plane's classifier
// (tools/hooks/guard-classify.sh) whether this pane's role may do this, and
// blocks with the reason when it may not. The rules live in lib/guard.sh and
// nowhere else - this file is an adapter, not a policy.
//
// Fails OPEN on any error of its own: a guard that cannot run must never take
// an agent down with it - except a team member's (CEL_ROLE=member), whose
// scope IS this guard, and a shell command that looks like a forge review
// verdict (VERDICT_SHAPED: no agent posts one, so refusing it - or a
// lookalike - while the guard is down costs little), both of which fail
// closed. The event contract is pi's
// ToolCallEvent / ToolCallEventResult ({ block, reason }).
// @ts-nocheck
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

function celRoot(): string {
  if (process.env.CEL_ROOT) return process.env.CEL_ROOT;
  // tools/hooks/<this file> -> repo root
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
}

// The same text in every adapter (orchestrator-guard.sh, tools/opencode/runtime.mjs).
const VERDICT_SHAPED = /pr\s+review\b|eviews|pullrequestreview|reviewmutation|approve\b|lgtm|reject|\bgh\s+alias\b|\btea\b|graphql/i;

function classify(mode: "command" | "path" | "read", arg: string): string {
  try {
    return execFileSync("bash", [path.join(celRoot(), "tools/hooks/guard-classify.sh"), mode, process.cwd(), arg], {
      encoding: "utf8",
      timeout: 3000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    if (process.env.CEL_ROLE === "member")
      return "deny the guard could not classify this call, and a team member's scope is the guard - nothing ran";
    if (mode === "command" && VERDICT_SHAPED.test(arg))
      return "deny the guard could not classify this call, and it looks like a forge review verdict, which no agent posts (cel solo review records one) - nothing ran. No CEL_GUARD_ALLOW_ONCE override covers this";
    return "allow";
  }
}

export default function celestialGuard(pi): void {
  // per-pane opt-out for sessions that live in a workspace dir but are not orchestrators
  if (process.env.CEL_GUARD === "0") return;
  // A team member's scope is the guard: if the classifier cannot run, its
  // call is refused rather than waved through.
  const member = process.env.CEL_ROLE === "member";
  pi.on("tool_call", (event) => {
    const input = (event && event.input) || {};
    let mode: "command" | "path" | "read";
    let arg: string;
    switch (event.toolName) {
      case "bash":
      case "powershell":
        mode = "command";
        arg = String(input.command ?? "");
        // the human-approved one-off (CEL_GUARD_ALLOW_ONCE=1 <command>) is the
        // classifier's to honour: never for a member, never for a forge verdict
        break;
      case "edit":
      case "write":
        mode = "path";
        arg = String(input.path ?? input.file_path ?? input.filePath ?? "");
        break;
      case "read":
        mode = "read";
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
          (member || verdict.includes("CEL_GUARD_ALLOW_ONCE") ? "" : " If a human has approved this exact call, prefix it: CEL_GUARD_ALLOW_ONCE=1 <command>"),
      };
    }
  });
}
