### Added
- **The work item** — the thing being made, not the machines making it.
  `cel work` is the board: every item grouped by stage (`building`, `review`,
  `landing`, `merged`, `released`, `ready`, `backlog`) with who holds it, its
  age and the next action a person would take; `cel work <key>` renders one
  item and its whole event list; `cel history` is the vertical timeline —
  ticket, worktree, PR, mail, reviewer and AFK events grouped per item and
  drawn with a spine. `--json` of each is the frozen shape the console and the
  dashboard render.

### Changed
- The delegation ledger records **every** state transition as
  `history: [{state, at, by}]` — a row carried one timestamp, so nothing said
  when work was collected, landed or released and no timeline could draw it.
  Rows written before this read back a synthesised history and are never
  rewritten on disk.
