### Fixed
- An orchestrator restarted with an explicit `--model` (and `--thinking`) to keep the model its saved session already runs no longer reads as running an older launch line. The steward, `cel update` and `cel doctor` used to report `extra: --model <id>` for it after every update, because a plain restart would take the workspace default instead. This also covers the `missing: --model <profile model>; extra: --model <kept model>` pairing.
  - The running model is read from the saved session: the later of its last `model_change` and its last assistant message's own provider/model. Helper-model `model_usage` entries are ignored.
  - A kept model needs the same ROUTE and the same id. Every gateway spelling is one route: `celgw/omp/claude-opus-5-5`, `omp/...`, `ompgw-claude/...`, `ompgw/claude/...` and `celgw-codex/...` all count as the gateway.
  - A direct provider is its own route (`anthropic/...`, `openai-codex/...`, `openrouter/...`), so a session on direct Anthropic is not kept by a gateway `--model`. A flag that names no provider (a bare id or `claude/<id>`) proves no route.
  - The `--thinking` item is exempt too when it is the session's last thinking level.
  - A `--model` the session is not running, a different thinking level, or any other extra or missing flag still alerts.
  - A cached verdict that depended on the session, including one cached before the session was recorded, is re-checked when the session changes.
- The steward's older-launch-line alert is said once per change, not once per build. An agent whose difference is unchanged is no longer raised again after each `cel update`; a new difference for that agent is raised once.
