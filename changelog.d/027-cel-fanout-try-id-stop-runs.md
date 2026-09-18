### Added
- `cel-fanout try <id> [--stop]` - runs a ticket's branch from its own worktree
  on a free block of ten ports (`repos[].preview`, `CEL_TRY_PORT_BASE`) in a
  pane of its own, prints the url, and is stopped by `--stop` or by `release`;
  `cel-fanout status` gains a `TRY` column
