### Added
- `repos[].lane: <lane>` in `workspace.yaml` declares that one solo lane owns a repo's PRs. Every per-PR steward nudge for that repo (approved and green - land it; a recorded `changes` verdict; changes requested; failing checks; no ticket in the branch name) and every reviewer's findings for its PRs go to the lane's mailbox (`<product>-<lane>`) instead of `<product>-orch`, through one resolver (`ws_repo_pr_owner`). While the lane is not running, the steward sends the nudges to the product's agent, and the first one for each PR head says which lane is down and how to start it. `workspace.local.yaml` cannot set it; the rendered policy names the lane on the repo's line; `cel doctor` warns about a value no lane can have and about a lane this box has never started.

### Fixed
- The steward's review sweep no longer asks herdr about the product agent's pane for every repo on every tick; the answer was never used.
