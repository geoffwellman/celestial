### Added
- **The two signed-in subscriptions are visible at last.** The fleet runs on a
  Claude subscription (pi's OAuth and Claude Code) and a Codex one (ChatGPT,
  through omp), and nothing on the plane could see either: `cel quota` knew API
  balances only, so a five-hour window at 100% stopped every worker on that
  account with no message anywhere anyone looks. `cel quota` now prints one row
  per signed-in account above the balances — each window, its percentage and
  the local time it resets — and `cel quota --json` carries them under
  `subscriptions`. A token is never printed: an account is named by its
  provider plus a short stable id. Readings cache for 60 s, so the console's
  status edge (`claude 16%/41% · codex 9%/62%`, amber at 80, red at 100), its
  new `q` QUOTA view, `cel fleet --json` and the dashboard's Subscriptions card
  all read the cache instead of calling a provider on every draw. The steward
  raises one rolled-up item per account (status over `CEL_SUB_WARN_PCT`, 80;
  blocked at 100) and clears it when the window drops, and a profile routed at
  a spent 5h window is vetoed before its pane spawns, with the reset time in
  the refusal
