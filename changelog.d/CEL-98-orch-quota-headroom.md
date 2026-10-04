### Fixed
- Orchestrators on omp no longer stop on a spent Claude budget: `cel run root|orchestrator` passes `--config=core/omp-orchestrator.yml`, raising `retry.maxDelayMs` to 6h so the turn waits out a 5h reset in-process.
- The steward raises one root item when the orchestrators' omp Anthropic pool is at or above 85% on every live credential's 5h/7d window, or a credential is disabled, and resolves it when headroom returns.
- `cel quota` names `omp login anthropic` for a credential disabled in omp's pool instead of the gateway login.
