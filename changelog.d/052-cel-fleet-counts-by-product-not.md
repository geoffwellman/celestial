### Changed
- `cel fleet` counts by **product**, not by repo: one row per product with
  its repos named, `<product>-orch` liveness, and the worker cap
  `cel-fanout delegate` actually enforces (`products[].workers`, else
  `policy.workers`); `--json` units gain `repos` and `declared`
