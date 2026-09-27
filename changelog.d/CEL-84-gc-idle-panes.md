### Fixed
- `cel gc` now closes empty worker panes - a bare shell left in a clean checkout under `~/.herdr/worktrees/` (or a deleted one) after its agent quit - so the pane picker lists only panes in use. Services, running programs, owner shells, dirty checkouts and layout-declared panes are kept and counted by reason; `--dry-run` lists both.
