### Added
- `cel drive list|tail|send|receipt`: see every orchestrator's live conversation, normalised and redacted from its session file (omp, pi, claude; offset tailing, never a full reparse), and mail it as `owner` with a receipt that goes queued -> delivered -> in-conversation. Delivery stays in the omp inbox hook, which now tags each message with its `[id]`; nothing types into a pane.
