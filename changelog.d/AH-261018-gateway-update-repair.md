### Added
- Codex through the box gateway over the OpenAI Responses transport, for pi (`ompgw-codex`) and omp (`celgw-codex`): every Codex-family id the gateway publishes (versioned ids included) is discovered, capability metadata is only what the gateway catalog states, and an id the gateway does not publish, or a vault with no Codex account, is a veto by name.
- `cel update` now updates every installed coding agent (claude, omp, pi, codex, opencode) through its own updater and refreshes the gateway registrations on every run, even when Celestial itself is already current. It prints per-component old/new versions, reports pins (`update.hold`, pi's pinned extensions) by name, treats a failed or still-behind component as a non-success exit, is idempotent, and records previous versions for `cel update --rollback`. `--check --agents` lists installed vs latest; `--components` runs only this part. Live sessions are never restarted.
- `cel gateway refresh` re-applies the proxy config, the box service and the pi/omp model registrations.
- pi declares native session resume (`--session`), so a restart keeps the original session file.

### Fixed
- An omp that starts on a native model now also gets the gateway providers registered in its models.yml when the box has a configured gateway (a down gateway warns, a direct-only box is untouched, a required gateway fails closed).
- A pi profile naming a Codex model produced a launch id (`ompgw/codex/gpt-5.5`) that models.json never listed.
- `cel gc` retires idle runtimes whose foreground group holds the verified runtime plus its declared direct Hindsight MCP child (exact root pid/birth, pane, role and ownership checks unchanged; any other child, e.g. a preview, still vetoes); `collected`/`reported`/`salvaged` delegation rows and stale pane bindings are no longer skipped. Retirement closes the pane only - worktree, branch, session and ledger stay.
