### Added

- Liveness: the steward asks what a pane is DOING, not only how long it has
  been quiet. A candidate - a worker herdr calls `working` whose pane text has
  not moved in five minutes, one it calls `idle`/`done` while the ledger says
  running, or one the marker rule already caught - gets one decision request
  carrying the last 40 pane lines and three facts, and comes back as
  `working` / `waiting_on_input` / `looping` / `crashed` / `finished` with a
  confidence. `looping` and `crashed` are reported at any age instead of
  waiting out the three-hour quiet timer, `waiting_on_input` after 15 minutes,
  `finished` while the ledger still says running.
- It REPORTS. Nothing it answers can kill, release or re-prompt a worker, and
  the marker and quiet timers still stand on their own: no router, no key, a
  failing endpoint or an answer below `liveness.min_confidence` (0.6) all leave
  the box behaving exactly as it did before.
- `cel-fanout why <id>` says it in words, with how much longer the timer alone
  would have taken. `cel fleet --json` carries `activity` and
  `activity_confidence` per worker, and the console's `live` column shows both
  words when the runtime and the pane disagree (`working!loop`).
- New config block `liveness:` (`enabled`, `model`, `min_confidence`,
  `still_secs`, `wait_secs`, `lines`), defaulting on when `console.router` has
  a key. `cel doctor` says whether it is on and which model answers.
