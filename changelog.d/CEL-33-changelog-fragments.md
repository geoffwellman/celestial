### Changed
- A changelog entry is a **file, not a shared line**: a pull request adds
  `changelog.d/<branch>.md` (first line the category heading, the rest the
  entry) and `cel release` assembles the fragments into the version's section
  in Added / Changed / Fixed / Removed order, file-name order within, deleting
  them in the same commit and leaving `[Unreleased]` empty. Seven open PRs each
  editing the same three lines under `[Unreleased]` meant a rebase and a suite
  run per PR per merge; nothing collides now. A hand-written `[Unreleased]`
  entry still ships, and CI fails a PR that leaves that section non-empty
