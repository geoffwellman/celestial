### Changed
- Agent-to-agent messages (reviewer approval, worker re-review, orchestrator revisions, steward stale-mail reminders) now go through `cel inbox send`; `herdr agent prompt` is reserved for one-time kickoff and the owner console nudge, enforced by a guard test.
- Claude workers and reviewers carry their inbox identity and drain mail into submitted turns.
- Claude workers and reviewers start an identity-scoped inbox Monitor; UserPromptSubmit drains earlier mail and Stop delivers mail arriving during a turn without typing into a pane.
