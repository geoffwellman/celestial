### Added
- `repos[].seed` in `workspace.yaml` - the gitignored local files every
  worktree needs to run (symlinked, or copied with `copy: true`), placed by
  `cel-fanout delegate`/`scout`/`spike` before the worker starts and named in
  its first prompt
