### Fixed
- `cel serve adopt` and the steward's "unledgered preview/dev servers" report no longer list coding agents (omp, pi, claude, codex, opencode), processes inside a running user service whose name is not a preview's (e.g. `hermes-gateway`), or Celestial's own `cel-*` services (only `cel-serve-*` are servers it ran). Box config `serve.ignore` (comma-separated substrings of a command) excludes an owner's standing tools.
- `cel serve adopt <unit>` died with `pid: unbound variable` after starting to write the ledger row.
