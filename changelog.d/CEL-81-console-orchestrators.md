### Added
- The console has an ORCHESTRATORS view (`O`): one row per root/orchestrator in every workspace with pane, status and how long in it, model, launch line (`current` / `stale (missing: …)` / `unknown (why)`), unread/open mail, and `r` to propose `cel run … --restart` (refused while `working`). Products whose mode is `auto` but have no live agent show as `missing`. The same rows are in `cel fleet --json` as `workspaces[].orchestrators`.
- `cel update --check` previews the stale orchestrators `--restart-orchestrators` would act on.

### Fixed
- Stale-orchestrator detection finds the agent process downward from its herdr pane's shell (runtime binary in the pane's cwd) instead of by environment marks, which read an unreadable ancestor (`systemd --user`) and reported an up-to-date orchestrator as missing every flag. An unresolvable process now reads `unknown` with the reason and is never restarted on a guess.
