### Added
- The console never shows raw JSON: `cel fleet --json`, `cel-fanout status
  --json`, `cel inbox open --json`, `herdr agent focus` and `herdr agent get`
  are rendered as the tables and lines the panels use, anything else that
  parses as JSON as `key: value`, and `r` toggles `[raw]`
