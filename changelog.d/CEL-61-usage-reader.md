### Changed
- **`cel quota` asks each account for its own usage, from the one vault.**
  CLIProxyAPI is now the single credential store on the box, and it cannot
  report usage — it removed usage statistics in v6.10.0 and keeps only a
  snapshot of the last response's rate-limit headers, which is empty for an
  idle account. What it does keep is each account's OAuth token, one file per
  account, so celestial now enumerates the vault and asks Anthropic and
  ChatGPT for the windows itself. One list of accounts instead of two: an
  account logged into the gateway can no longer be missing from `cel quota`.
  The rows are the shape the console's QUOTA view and the dashboard card
  already render — every account, every window, scope labels read off the
  response rather than named in code, so a scoped weekly window appears
  without a release. An expired access token is refreshed with its refresh
  token; refreshes happen **in memory**, cached at 0600 under cel's own cache,
  and the vault CLIProxyAPI serves traffic from is never written to. A
  credential that cannot be refreshed reads `needs login: cel gateway login
  <provider>` rather than `unreadable`. opencode keeps reporting from its own
  auth file, which the vault has never held.
- omp's `usage --json` path stays as the fallback until the new reader has
  proved itself: with no accounts in the vault, the output is exactly what it
  was. `tools/quota-compare.sh` prints both readers side by side, per account
  and per window, which is what says when omp's path can go.

### Removed
- The omp gateway's `/v1/usage` read and its subscription rows: CEL-60 removes
  that gateway, so they had nothing left to read.
