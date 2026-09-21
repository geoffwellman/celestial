- `cel run reviewer` now opens the pane in a checkout of its own, a detached
  git worktree at the pull request's head, instead of the orchestrator's
  working copy. The reviewer's role body names the head SHA it is reading, the
  base ref it compares against, and the command that tells it the head has
  moved since the pane started.
- A reviewer's checkout is released when the reviewer is: `cel gc` removes the
  worktree as it closes the pane, and also when a recorded pane has gone by
  other means.
- `cel doctor` reports any workspace repo checkout that is behind its remote
  default branch, with the count and the command that fixes it. A checkout
  with no remote, or one that cannot be fetched, is reported as UNKNOWN rather
  than passing silently.
