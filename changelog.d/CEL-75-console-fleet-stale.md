### Fixed

- `cel console` keeps drawing the last good fleet document, marked stale with its time and the reason, when a refresh fails or times out under load; `cel fleet` caches its whole document for `fleet.cache_secs` (default 30, `--fresh` bypasses), and a fleet pass no longer re-asks herdr for the roster per workspace or forks twice per process to find the console.
