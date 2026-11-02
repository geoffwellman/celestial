### Fixed
- `cel inbox prune` holds the mailbox lock from its read to its rewrite and rewrites the mailbox in place, so mail sent while a prune runs is no longer lost.
- `cel inbox send --fp` looks for the open item and appends under one mailbox lock, so concurrent sends of one condition roll up into one item instead of opening duplicates.
- `cel services start` fails, records nothing and closes the empty pane when herdr cannot run the command, instead of reporting a service that never started.
- `cel services stop` keeps the pane record and fails when the pane will not close (forgetting it only once herdr says the pane is gone), and `cel services restart` no longer reports success after a failed stop.
- `cel serve start` writes its ledger record before launching the unit and removes it if the launch fails, so a server is never left running unledgered.
- The YAML and agents.yaml JSON caches are keyed on file content, so an edit that keeps the size and timestamp is no longer served stale; without md5sum a YAML file is re-read rather than cached, an unchanged agents.yaml is recognised without starting a process, and a superseded agents.yaml conversion is removed.
- A workspace's service state file is updated under a lock through a private temp file, so concurrent starts and stops of different services no longer lose records.
- Service URLs with a bracketed IPv6 host, userinfo or a query yield the right port, and an unreadable port is 0 rather than part of the host.
- The pages unit escapes the `CEL_PAGES_*` values it carries, so quotes, backslashes, `%` or a newline can no longer break or inject unit directives.
