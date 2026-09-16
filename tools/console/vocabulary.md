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
| `cel-fanout status\|collect\|release --workspace <w>` | what is in flight, what is finished, what to let go |
| `cel run orchestrator --product <p> --workspace <w>` | start a line of work |
| `cel-linear …` | tickets |
| `herdr agent focus <name>` | when the operator says "take me to …" |
