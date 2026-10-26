### Fixed
- Stale-launch checks (`cel update`, doctor, steward, console) never take one of omp's own helper processes (js-eval worker, daemon broker) for the orchestrator. When the real orchestrator did not match, a helper used to be the only candidate and the alert said every flag and hook was missing; the verdict is now `unknown` instead. A stale verdict also names the pid it read.
