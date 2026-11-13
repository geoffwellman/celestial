### Fixed
- `cel fleet` no longer derives a product's orchestrator mode itself: its
  orchestrator candidates ask `ws_orchestrator_mode`, so a local
  `orchestrator: manual` over a layout or default `none` reads `none` there as
  everywhere else. The `workspace.local.yaml` merge no longer carries a local
  `manual` over a committed `none` from any level (cache key `merged-v4`).
