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
