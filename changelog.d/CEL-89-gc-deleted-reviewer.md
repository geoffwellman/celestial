### Fixed
- `cel gc` now closes an idle reviewer of a merged or closed PR even after its review folder was deleted: the pane cwd's ` (deleted)` suffix is stripped in one place (`pane_cwd`), and the PR's GitHub repo is resolved from the workspace (declared url, else origin) rather than the folder name. A reviewer kept as UNKNOWN for over 24h is reported to root once as `blocked`.
