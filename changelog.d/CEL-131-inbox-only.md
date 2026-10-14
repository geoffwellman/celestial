### Changed
- Agent-to-agent messages (reviewer approval, worker re-review, orchestrator revisions, steward stale-mail reminders) now go through `cel inbox send`; `herdr agent prompt` is reserved for one-time kickoff and the owner console nudge, enforced by a guard test.
