### Added
- `cel gateway panel [--json]` prints CLIProxyAPI's web panel URL (`http://127.0.0.1:<port>/management.html`) and the `ssh -L` line that reaches it from a laptop. The console proposes it on `G` (and routes "open the gateway panel"); the box dashboard's Box card links it when viewed on loopback and shows the tunnel line otherwise.
- `cel gateway install` turns CLIProxyAPI's management API on for loopback only (`remote-management.allow-remote: false`, a `secret-key` minted once into the gateway's 0600 `management-key`, `disable-control-panel: false`), so the panel can read and change the gateway.
- `cel gc` closes the panes of finished workers: a pane still in its delegation's worktree, agent `idle`/`done`, delegation `landed`/`released`/`abandoned` with its PR merged or closed and nothing dirty or unpushed. A `finished` delegation whose PR merged is reconciled to `landed` first. It reports `closed N done panes, kept M: <reasons>`, and a dry run names every kept pane and worktree with its reason.
- `tools/quota-compare.sh --gate` fails when any account or window omp reports is missing from the merged `cel quota` list.

### Fixed
- `cel quota` shows every account again: rows merge per account (provider + email) across CLIProxyAPI's vault and omp, instead of dropping omp - and with it both Codex accounts and opencode - as soon as the vault held any account.
- Claude windows are read from the usage answer's `.limits[]` (with `7d Fable` scoped windows) instead of its top-level codename keys, so no more `nimbus_quill 0% (resets Nimbus Quill)`.
- opencode reads its real auth file (`opencode-go.key`) and usage shape (`usage.rolling/weekly/monthly`) and reports beside the vault accounts.
- Provider credit (OpenRouter, DeepSeek) is read with the key of each workspace that owns it, one row per workspace, instead of "no key in this workspace" for wherever `cel quota` ran.
- The box dashboard's subscriptions card reads `cel quota --json` (falling back to the fleet cache), and other dashboards show a line linking to it.
