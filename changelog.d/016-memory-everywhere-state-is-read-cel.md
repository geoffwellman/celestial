### Added
- **Memory, everywhere state is read**: `cel fleet` carries `rss_mb` per
  worker, unit and orchestrator pane plus a `box` block, prints `mem` per
  product and the box's headroom on its head line; the console shows it per
  row with the free figure on the status edge and `s` to sort a unit's workers
  by memory; the steward raises one blocker under 10% available naming the
  largest trees and tells an orchestrator about a worker over
  `CEL_MEM_WORKER_WARN_MB` - reporting only, never killing
