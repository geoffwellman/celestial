### Fixed
- The steward no longer nudges "get a worker on it" for a PR that is waiting on an open owner decision: `cel decide ask --pr <repo>#<num>` (repeatable) links the question to the PR, shown as a link on the dashboard card; nudges resume once it is answered or withdrawn.
