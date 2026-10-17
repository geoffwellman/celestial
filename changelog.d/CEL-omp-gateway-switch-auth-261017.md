### Fixed
- An omp session that starts on a non-gateway model (e.g. Codex) now gets the gateway client key and its session identity in its launch environment when the box has a configured gateway, so switching to a celgw model in-session no longer fails with 401. Direct-only boxes and required-gateway refusals are unchanged; sessions already running need a restart to pick it up.
