- `cel ws up|down|reset|status`: a workspace declares its shape in
  `workspace.yaml` (`layout.orchestrators`, `layout.panes`) and the plane can
  put it back. `up` reconciles - herdr workspace, declared panes in order, an
  orchestrator for every product that wants one - and is idempotent; `down`
  stops the agents it owns and closes its PANES, refusing over work that is
  neither pushed nor landed; `reset` is down-then-up; `status` is `up
  --dry-run` in table form. Nothing here removes a worktree or writes the
  delegation ledger.
- A nameless agent is a fault, not an absence: `cel ws up` renames a live
  agent in a product's own directory to its canonical alias, `cel fleet`
  reports `orch unnamed` instead of `-`, `cel doctor` names the directory, and
  `cel run orchestrator` refuses to start a second orchestrator over a live
  one (named or not) without `--force`.
- The console gains `workspace_up`, `workspace_down` and `workspace_reset`
  intents - the last two always proposed, never auto-run - and `u` / `U` on
  the unit view.
