### Fixed
- `tests/run.sh` drops the caller's `CEL_*`/`HERDR_*` identity (inbox, role, workspace, pane) before running tests, so the suite passes from a worker pane exactly as on CI - the eight "pre-existing" inbox failures are gone.
- A `cel run orchestrator` launch that fails after claiming its session releases the claim, so an immediate retry is not refused; `--restart` of the same pane is no longer refused by its own claim, and a failed `herdr agent start` on restart is reported as a failure.
