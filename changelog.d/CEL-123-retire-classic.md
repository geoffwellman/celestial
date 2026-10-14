### Removed
- The classic dashboard page: `/classic` now redirects to `/`. `/api/state` stays.
- `/api/prompt`, the dashboard's one remote pane-typing endpoint.
- The redirect listeners on old per-workspace dash ports, `dash_legacy_ports` and per-workspace `dash.port` (doctor warns if a workspace.yaml still sets it). The box config `dash.port` (default 7770) is unchanged.
- Console `talk` no longer types into the orchestrator's pane: each line goes as mail via `cel drive send`. `nudge`/`p prompt` stay and are labelled as typing into the pane.
