### Changed
- CI runs the regression suite and the publication/credential scans as separate jobs with their own time limits, so a slow suite can no longer get the scans cancelled; the required "Tests and publication hygiene" check now gates on both.
- `tests/run.sh <name>.test.sh` runs every test in that one file.

### Fixed
- The nightly schedule no longer re-runs the full regression suite and scans; it runs only the every-ref publication scan.
- The GC test for removing a merged, clean solo worktree no longer depends on the rest of the machine's process table, and prints GC's own output when it fails.
- Contributor guide asks for a `changelog.d` fragment instead of direct `CHANGELOG.md` edits.
- The publish skill's recovery advice uses the managed pages service (`cel pages --ensure` / `--restart`) instead of starting an unmanaged server in a pane.
