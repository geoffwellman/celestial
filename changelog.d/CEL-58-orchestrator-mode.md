### Changed

- `cel ws`: the orchestrator mode for a product is resolved in one place
  (`ws_orchestrator_mode`), and `up`, `up --dry-run`, `status` and the steward
  all read it. A workspace declaring `layout: <string>` (a herdr layout id) no
  longer implies `orchestrators: manual` by accident - a string layout, an
  object layout without the key, and no layout at all all mean the same thing.
- `products[].orchestrator` now takes precedence in EITHER direction: `auto`
  can turn an orchestrator on under a workspace that is not auto, as well as
  `manual`/`none` turning one off.
- `cel ws status` and `cel ws up --dry-run` say WHERE the effective mode came
  from - product, layout or default - and `status --json` carries it as
  `source`.
- The steward no longer reports that an orchestrator "will not start" when the
  resolved mode is manual; it says the product is set to manual and takes any
  stale fault down.
