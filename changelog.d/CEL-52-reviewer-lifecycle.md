- `cel run reviewer` now records the reviewer it starts (repo, PR, pane,
  agent) in box state, and a second call for the same PR reuses that pane
  instead of splitting another one.
- `cel gc` gained a reviewer pass: a reviewer whose pull request is merged or
  closed has its pane closed and its row dropped. An open PR's reviewer is
  left alone however old it is, a working reviewer is never closed, and a PR
  whose state cannot be read keeps its reviewer and says which one. The
  summary counts reviewers closed beside worktrees removed.
- `cel box space` reports the reviewer panes and the RSS they hold, and `cel
  doctor` names them when they are the largest reclaimable thing on the box.
