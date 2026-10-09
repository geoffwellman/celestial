### Fixed
- `cel-fanout release` now removes the worktree directory itself when herdr has none to remove (`git worktree remove` from the repo's common dir; tracked changes still need `--discard`), and a row whose directory has to stay records `worktree_left` with the reason.
- A squash-merged PR no longer makes its branch read as unpushed: commits at or before the PR's merged head, or whose patch is already in main, are landed.
- Release's herdr and git calls are time-bound (`CEL_RELEASE_TIMEOUT`, default 30s) and say what they are waiting on.
- Ledger states come from one shared list (`lib/ledger_states.sh`, now including `abandoned` and `unconfirmed`); writes outside it are refused, `cel doctor` names such rows, and gc keeps only that row's worktree as unknown instead of vetoing every worktree on the box.
