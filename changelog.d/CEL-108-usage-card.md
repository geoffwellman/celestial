### Changed
- Dashboard v2: one **Usage** card replaces "Usage forecast" and "Claude accounts" - a summary strip (accounts at risk, Claude accounts serving orchestrators, dry pay-as-you-go balances, funded total), each provider's accounts with a bar per window and a tick at the projected % at reset, who-uses-it tags derived from omp's pool and the gateway vault, pay-as-you-go rows merged by shared key, and per-window history in the expanded view. Fed by the new `/api/v2/usage`.
- `cel quota --json` carries `orch_pool`, `gateway`, and each balance's key fingerprint (`account`) and floor veto (`vetoed`).
- The steward sends one rolled-up inbox item (`usage-pace`) when an account is on pace to hit its cap before it resets, and resolves it when it no longer is.
