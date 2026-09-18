### Added
- `cel fleet --json` carries `units[].workers_list`: every worker still worth
  acting on (`running`, `finished`, `collected`) - id, ticket, repo, branch,
  shape, state, live agent status, `quiet_secs`, stall `verdict` and
  `severity`, `ahead`, PR, alias, pane and
  worktree - so the `stalled` count can be read back to its rows, and
  `cel-fanout status --json` prints the same objects for one workspace
