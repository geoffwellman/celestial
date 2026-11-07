### Fixed
- `cel inbox resolve <id>` checks that the item is still open and appends its resolution under one mailbox lock. Resolving an item that is already closed now fails and names who closed it and when. It no longer reports success and writes a duplicate record.
- `cel inbox resolve --all` selects the open items and appends every resolution under one mailbox lock. When several resolvers run at once, each item gets exactly one resolution.
- A mailbox with a torn or malformed line is now reported as corrupt instead of empty. `cel inbox read`, `cel inbox open` and `cel inbox resolve` fail with an error naming the mailbox file, and `inbox_unread_json` does the same. A failed read never moves the cursor, and `--json` reports `state: corrupt`. In an `--all-workspaces` read, a corrupt mailbox no longer hides mail delivered from the other mailboxes.
- `cel inbox count` on a corrupt mailbox exits 1 with an error naming the file. Before, a torn first line counted as 0. Its output is still a number: the unread items before the first bad line. `--all-workspaces` keeps adding up the other mailboxes.
- The omp and OpenCode inbox hooks still read the mailbox when the count fails, so the agent is told (once per mailbox) that its mailbox is corrupt.
- `cel fleet` shows a corrupt root mailbox as `UNKNOWN`, and its JSON reports the counts as `null` with `mail.corrupt: true`. Before, it showed 0 unread. `cel doctor` names the corrupt file.
- When the root mailbox does not parse, the steward no longer clears the "nobody is reading root's mail" blocker, and it neither raises nor restarts based on that mailbox. It logs that the mailbox is corrupt.
- A `cel inbox send --fp` into a corrupt mailbox is no longer dropped. It opens a new item.
