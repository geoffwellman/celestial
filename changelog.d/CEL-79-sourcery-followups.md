### Fixed
- Liveness: a pinned clock with a leading zero (`08`) is read as base ten, and an answer recorded at time 0 is still cached.
- `cel services start` for a workspace service reports herdr's own error when `herdr agent list` refuses, instead of "no herdr pane found".
- `cel doctor` matches `github.ssh_host` as a literal, standalone `Host` token; regex characters and wildcard patterns no longer pass.
- Steward: when the ledger names a worker's worktree, only an agent there counts; the guessed path is used only for branches with no ledger row.
- `cel work`: a failed `gh` / `cel-linear` read is no longer cached as empty; the previous cache is kept.
- `cel fleet` re-validates a cached document and re-reads when it is missing or corrupt; the console keeps its last good fleet read per session.
