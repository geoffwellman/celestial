### Added
- Update awareness by **commit**, not only by tag: an `update.channel` of
  `main` or `release` in `~/.local/share/cel/config.yaml` (`cel update
  --channel`), a build string of `v0.2.0+31 (d43910c, main)` everywhere, and a
  `cel update --check`, steward item, dashboard chip and `cel doctor` line
  that say how many commits are new and what they were
