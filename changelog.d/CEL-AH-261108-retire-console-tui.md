### Changed
- `cel console` now starts the box's coordinator, exactly like `cel core` (and `cel run core` / `cel run console`): it takes the same flags and resumes the same pane.
- Workers and solo agents are refused `cel console` the same way they are refused `cel core`.
- `cel doctor` shows the liveness line under its own "Liveness" heading instead of "Console".

### Removed
- The Ink terminal console (`tools/console/`), its launcher, its npm dependency install in `cel setup`, its `cel doctor` dependency check and its tests.
- The guard's `console` role, its allowlist and its notes-directory rule.
