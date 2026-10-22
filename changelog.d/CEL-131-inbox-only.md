### Changed
- Agent-to-agent messages (reviewer approval, worker re-review, orchestrator revisions, steward stale-mail reminders) now go through `cel inbox send`; `herdr agent prompt` is reserved for one-time kickoff and the owner console nudge, enforced by a guard test.
- Claude workers and reviewers carry their inbox identity and drain mail into submitted turns.
- Claude launch hooks drain inbox mail at UserPromptSubmit and block Stop when messages arrive during a turn; the installed Claude runtime does not wake an idle session.
- The global Claude submit hook is installed with an absolute path and appended without replacing existing UserPromptSubmit handlers; launched sessions do not configure it twice.
