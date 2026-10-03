### Fixed
- The omp/pi inbox hook now reaches an orchestrator or root with an explicit identity (`CEL_INBOX_ME`) in every registered workspace - watch, unread count and drain - still filtered to that one recipient, so mail sent to an orchestrator from another workspace no longer sits unread for days. Workers keep single-workspace scoping; `CEL_INBOX_ALL_WS=0` opts out.
- A dead inbox watcher is restarted by the hook (backoff, never after shutdown, no orphans) and the mail that arrived while it was down wakes the session once. A wake withheld for an active turn or a non-empty composer is retried until the session is idle with an empty composer, and a wake whose turn never reports `agent_end` no longer blocks later wakes.

### Changed
- `cel inbox read|count|watch|open --all-workspaces --workspace <w>` includes `<w>` in the sweep when the registry does not list it (previously `--workspace` was ignored there).
