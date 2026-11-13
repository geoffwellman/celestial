### Added
- `workspace.local.yaml` may set `products[].orchestrator: manual` to turn a
  product's agent off on this box only: over a committed `auto` (product,
  layout or default) `cel ws up` and the steward start nothing and raise
  nothing, and `ws_orchestrator_mode` reports source `workspace.local.yaml`
  so `cel ws status`, `cel fleet` and `cel doctor` agree. One way only: a
  local `auto` over a committed `manual` is ignored and `cel doctor` warns.
  The merge cache key is now `merged-v3`.
