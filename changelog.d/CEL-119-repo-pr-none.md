### Added
- Per-repo `pr: none` in workspace.yaml (overrides `policy.pr` for that repo; `required|none`, validated). Workers on such a repo rebase onto origin/main and push to main fast-forward only, never force, with no PR; the policy block says so, and `cel-fanout collect` records the row as `landed` once its commits are on main so `release` takes the worktree without `--discard`.
