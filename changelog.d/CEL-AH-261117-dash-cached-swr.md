### Fixed
- The dashboard's upstream caches (agents, inbox, PRs, decisions and the rest) are stale-while-revalidate: past a cache's budget an ask gets the last good answer at once while one refresh runs behind it, so `/api/state` no longer waits on `cel sessions --json` every 8 s. Only the first ask waits; a failed or throwing refresh keeps the last good answer.
