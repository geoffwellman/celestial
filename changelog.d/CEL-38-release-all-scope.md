- `cel-fanout release --all` now takes only `landed` and `abandoned` rows;
  `--merged` adds GitHub's merged rows to the same pass. Every `--all` run
  prints its plan first, naming each skipped row with its state, and
  `--dry-run` stops there. A "left as-is" line no longer precedes a removal:
  that path returns before anything is touched.
- Releasing the last worker under a `<repo>/workers` container keeps the
  container (recreating it if herdr closed it), `cel-fanout status` reports a
  worker whose container is gone as `detached`, and `cel doctor` warns when a
  workspace has worker worktrees on the roster and no container.
- `cel-fanout collect` and `land` apply the workspace `env:` block before
  running `cel-verify`, so a declared `CEL_VERIFY_GATE_TIMEOUT` reaches the
  gate; `--gate-timeout <secs>` on either command overrides it.
