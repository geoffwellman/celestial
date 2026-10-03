### Added
- `cel decide ask|list|answer|drop|migrate`: one queue for every decision an orchestrator needs from the owner. A decision is a structured inbox record (title, options with tradeoffs, recommendation, context, what it blocks, asker from the caller's identity); a re-ask of the same title updates it. `list` covers every workspace, oldest first; `answer` and `drop` resolve it and mail `ANSWER to "<title>": ...` / `DROPPED` to the asker's inbox. `migrate` (dry run unless `--apply`) resolves old steward reminder items and leaves real decisions open.

### Changed
- The steward no longer files "N UNRESOLVED decision(s)" reminders; it sends at most one status line per workspace per day summarising open owner decisions. Orchestrator roles now require `cel decide ask` for any question to the owner.
