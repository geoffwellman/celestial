<!-- The console's vocabulary, in ONE file.
     Two surfaces speak it: the TUI's translator (tools/console/translate.mjs
     puts this table in its system message) and the agent console
     (core/roles/console.md includes it at render time, lib/run.sh). It was a
     table in the role file first; the moment a second consumer appeared, a
     copy would have meant the two consoles disagreeing about what the console
     can do, and the one that is wrong is always the one nobody is watching. -->

| command | when |
| --- | --- |
| `cel fleet [--json]` | every answer about state starts here; never answer from memory |
| `cel inbox read --for root --workspace <w>` | what is waiting on the operator (`--all-workspaces` for all of them at once) |
| `cel inbox open --for root --workspace <w>` | the same, unresolved only |
| `cel inbox send <who> "<msg>" --workspace <w>` | route an instruction; `<who>` is `<product>-orch` or a worker alias |
| `cel inbox resolve <id>` | close out a message the operator has answered |
| `cel inbox resolve --all --from steward --workspace <w>` | "clean the inbox", "clear the steward's blockers on <w>" |
| `cel inbox open --all-workspaces` | "everything waiting on me" |
| `cel-fanout status\|collect\|release --workspace <w>` | what is in flight, what is finished, what to let go |
| `cel-fanout why <id> --workspace <w>` | "why is <ticket> stuck", "what is <worker> doing" - the verdict, the quiet time, the pane, its mail, its PR, one next act |
| `cel-fanout status --json --workspace <w>` | the machine form: one object per delegation, every state; what this console reads |
| `cel-fanout try <id> [--stop] --workspace <w>` | run a ticket's branch locally on its own ports; "try W-49", "stop the preview of W-49" |
| `cel services [--json] --workspace <w>` | everything this box is running on a port - declared services and every `try` preview - with state, health, memory and the URL that reaches it from the laptop |
| `cel services start\|stop\|restart <name> --workspace <w>` | "start the builder", "restart the worker service"; a service that declares no `cmd` is observe-only |
| `cel services logs <name> --workspace <w>` | "what is the builder printing" - the last 60 lines of its pane |
| `cel services open <name> --workspace <w>` | "open the builder", "open the preview of ABC-49" - prints (and opens) the reachable URL |
| `cel run orchestrator --product <p> --workspace <w>` | start a line of work |
| `cel-linear …` | tickets |
| `cel-linear board [--team K] [--state a,b] [--json]` | the team's open tickets and what it finished today, grouped by state - what the console's BOARD panel reads (cached 60 s) |
| `cel inbox send <p>-orch "pick up ABC-49 next" --workspace <w>` | "start ABC-49", "get bundle going on ABC-49" - work starts through the orchestrator, never behind its back |
| `cel inbox send <from> "<text>" --workspace <w>` then `cel inbox resolve <id> --workspace <w>` | "answer that decision" - the reply and the close are one act; doing one of them is the failure mode |
| `cel-fanout land <id> --workspace <w>` | "land #12", "merge ABC-49" - the DELEGATION, not the PR: merging by hand leaves a worker holding a branch nobody collects |
| `herdr agent prompt <alias> "<text>"` | "nudge ABC-49", "remind him to push" - reaches the agent now, where mail is read when it next looks |
| `cel run orchestrator --product <p> --workspace <w>` | "restart the bundle orchestrator" - only when it is not already live |
| `cel-linear state ABC-49 "<state>"` | "move ABC-49 to In Review" - the state name comes off the board, not from memory |
| `cel run reviewer --repo <r> --pr <n> --workspace <w>` | "get a reviewer on #12" |
| `herdr agent focus <name>` | when the operator says "take me to …" |
| `cel-fanout release --all [--state finished,collected] --workspace <w>` | "clean up finished workers on <w>", "release everything that is done on <w>" |
| `cel-fanout collect --all --workspace <w>` | "collect all the finished workers on <w>" |
| `cel quota [--json]` | "how much Claude/Codex have I got left", "when does the window reset" - the signed-in subscriptions above the API balances |
| `cel-fanout reconcile --workspace <w>` | "clean up what's already merged on <w>" - lands the rows GitHub merged, names the ones closed unmerged, leaves reports alone |
| `cel gateway status [--json]` | which subscriptions are signed in and usable, and how much of each window is left - "which accounts can we use", "is codex out" |
