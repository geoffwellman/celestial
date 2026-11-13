### Fixed
- `cel fleet` resolves every product's orchestrator mode in one pass
  (`ws_orchestrator_modes`: one committed read, one merged-view read, one
  jq), so its process count no longer grows with the number of products.
  `ws_orchestrator_mode` is now that resolver for one product, so the rule
  still lives in one place.
