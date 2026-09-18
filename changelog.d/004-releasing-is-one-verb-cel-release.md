### Added
- **Releasing is one verb**: `cel release <x.y.z>` dispatches a GitHub workflow
  that checks hygiene and the suite, bumps `VERSION`, closes `[Unreleased]` and
  opens the `release: v<x.y.z>` PR; merging it tags and publishes the GitHub
  Release from the same notes. `--dry-run` shows what would ship and
  `cel release status` the open PR and newest tag
