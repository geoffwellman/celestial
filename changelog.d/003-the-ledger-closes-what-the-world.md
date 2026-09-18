### Added
- **The ledger closes what the world already closed**: `cel-fanout reconcile`
  lands the rows whose PR GitHub merged, abandons the ones closed unmerged past
  `CEL_RECONCILE_GRACE_HOURS`, raises one rolled-up item per unread scout
  report and releases ship rows with no PR and no worktree - one `gh pr list`
  per repo, run every steward tick, with `release --all --merged` and a console
  `X` option for the same clean-up by hand
