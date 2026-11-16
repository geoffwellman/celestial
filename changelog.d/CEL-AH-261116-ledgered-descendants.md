### Fixed
- `cel serve adopt`, the steward's unledgered-server report and `cel doctor` no longer list a registered server's own children as new unledgered servers: a process whose ancestor chain reaches a server registered by pid (same pid and start time) is covered, as is anything inside a registered unit's cgroup. A reused pid covers nothing.
