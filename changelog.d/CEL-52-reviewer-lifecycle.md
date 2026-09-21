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
- The gc pass and the report both DISCOVER reviewer panes by the name
  `cel run reviewer` gives them, so reviewers that predate the registry are
  swept and measured too; a surviving unrecorded reviewer is adopted into the
  registry. The registry is an index, not the definition of existence.
- Every read-modify-write of the reviewer registry is held under a lock on
  the file, and `cel gc` writes back a MERGE of what it established (panes
  closed or gone, live panes it adopted) rather than a stale snapshot - a
  `cel run reviewer` landing mid-sweep is no longer erased.
