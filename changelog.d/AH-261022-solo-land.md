### Added
- `cel solo review <repo>#<pr> approved|changes --head <sha> --by <alias>` records a reviewer's verdict on a solo product's PR (`<ws>/.cel/solo-reviews.json`), with the fleet verdict's rules: attributed, a full 40-character head, and an approval only for the PR's current head on the workspace account's own open PR. The solo agent cannot record a verdict on its own work (refused by the command and the guard); a corrupt verdict file is moved aside, never silently emptied.
- `cel solo land <repo>#<pr>` merges a solo product's PR after the same checks as `cel-fanout land`: `merge: self`, own open non-draft PR, approval of the exact head (GitHub's, or the recorded verdict), no failing check, no conflict, every protected check green on that head, and AFK authorisation when AFK is on. It merges only that head, and refuses reviewers and workers. Reviewer briefs for solo PRs name these commands and the `<product>-orch` mailbox.

### Changed
- The CI-stand-in check and the squash-body hygiene check moved from `cel-fanout` into `lib/land.sh`, shared by both land paths.
