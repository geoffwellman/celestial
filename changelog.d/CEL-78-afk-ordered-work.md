### Fixed
- `cel afk on` no longer stops work already ordered: a delegate/scout whose spec sat under `.cel/specs/` before AFK went on is authorised (pre-authorisation 5, logged with spec path and mtime), and `cel release` under AFK is allowed for a version named with `cel afk on --allow release:<product>@<version>`. `cel afk on` now prints what keeps moving.
