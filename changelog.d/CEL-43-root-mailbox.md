### Changed
- Mail to `root` is reserved for `escalation`, `decision` and `blocked`.
  Ticket status is the ledger's job (`cel-fanout status`), and the
  orchestrator role files say so: one instruction accounted for 466 of the 553
  messages one root mailbox took in nine days. `cel inbox send root --kind
  status` warns and still sends.
- An `escalation` raises a desktop notification, as a `decision` and a
  `blocked` already did. It is by definition the kind that cannot wait.

### Added
- `cel fleet --json` carries `mail: {to_root_unread, oldest_secs, reader}` per
  workspace, `cel doctor` names a root mailbox nobody is reading, and the
  steward raises one rolled-up, self-clearing `blocked` item per workspace
  when an unread escalation is older than `CEL_ROOT_UNREAD_SECS` (3600) with
  no live reader.
- `cel inbox open --for root --ranked`, the console digest and the dashboard
  card order the unread by a decision model's level and show the top
  `inbox.top_n` (3), then `and N more`. The model supplies only the level;
  counts, ages, ordering, the cut and the per-id cache are the code's, and
  below `triage.min_confidence` (0.6) a message keeps its kind's default rank.

### Changed
- The dashboard partitions box-level material out of a workspace's own: the
  services panel lists this workspace's services, and anything tagged `box` -
  plus the subscriptions, which are box-level in their entirety - moves to a
  `Box` panel drawn on exactly one dashboard (`dash.box: true`, defaulting to
  the registry's first workspace). Every other dashboard shows one line
  naming that URL. One broker and one gateway rendered on four dashboards
  read as several; there is still no box-wide dashboard.

### Fixed
- The console's INBOX tail dropped the id of the record it had just parsed,
  so a detail view opened from that pane read `id undefined` and its
  `[resolve]` did nothing, while the same item opened from WAITING resolved
  fine. The tail carries `id` (and `ref`, `fp` and what resolved it).
- A detail view computes its actions from the item's live state: an item that
  is not open shows `[reply]` and `[go to]` only, with one line saying
  `resolved <when> by <who>` or `not an open item - this is the log`. A
  resolve now reports its outcome - `resolved <id>`, or the command's error -
  instead of failing silently.
