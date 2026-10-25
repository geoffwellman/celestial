### Fixed
- A release with `--keep-worktree` now records `worktree_kept: true` on the row, and `cel gc` never removes a checkout any row has kept. Before, the steward's next gc sweep removed a kept checkout once it was clean and pushed, taking ignored files (reports, local data, previews) with it.
