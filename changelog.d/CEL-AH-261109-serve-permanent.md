### Added
- `cel serve adopt <unit|pid> --owner <alias> --workspace <ws> --permanent [--port N] [--why "..."]` registers an agent's standing box service (a product's live app in a persistent user unit, a preview its owner said to keep) as a permanent server: no TTL, no idle or pressure limit. The steward's `serve_sweep`, `preview_sweep` and gc's QA-preview release (through `_preview_teardown`) never stop it, the orphan reaper never lists its pid or any process in its unit, and the unledgered report skips it. `cel serve list` (new TTL column, `permanent`), the dashboard's server rows and `cel fleet` (`box.servers`, plus a `server` line under its workspace) show it with owner, port and memory.
- A permanent server stops only through `cel serve stop <name>` by a person or by the agent whose launch-verified `CEL_INBOX_ME` is its owner; another agent, or one that shed `CEL_ROLE`, is refused.
- A permanent unit is matched by name: systemd recreating it keeps the registration, and adopting a pid that runs inside a user service registers that unit. A unit gone for 15 minutes (`CEL_SERVE_GONE_GRACE_SECONDS`), or a pid that exits, is dropped from the registry with one inbox note to its owner and never restarted.

### Changed
- `cel serve adopt` without `--port` records the port it saw the server listening on (was 0), and a unit named `x.service` is recorded as `x`.
