### Fixed
- Reviewer registry rows are keyed by workspace, repo and PR, so two workspaces with the same repo name and PR number no longer reuse, replace or drop each other's reviewer. Older rows are attributed to the workspace their recorded clone sits in, or, with no such record, only to a workspace that has the repo.
- A reviewer registry that does not parse is treated as unknown rather than empty: `cel run reviewer` refuses to start a reviewer until `cel gc` rebuilds the registry from the live roster, keeping the unreadable file aside as evidence.
- `cel gc` closes a finished solo reviewer once its approval of the PR's current head is recorded with `cel solo review`, instead of waiting for the PR to merge.

### Changed
- `cel run reviewer` warns when `review.runtime` names anything other than pi, since reviewers always run on pi for idle inbox delivery; the workspace policy text now names pi instead of the ignored field.
- The PR reviewer role states that the reviewer's checkout is its own dedicated worktree at the PR head.
