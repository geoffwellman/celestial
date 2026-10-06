### Fixed
- The dashboard browser test waits up to 60 s for Chrome's debugging port (`CEL_TEST_CHROME_WAIT_MS`), retries the launch once, and shows Chrome's stderr when it still fails.
- `cel dash --restart` / `--ensure` wait for the old server to exit and the port to come free (`CEL_DASH_PORT_WAIT_S`, default 15 s) before starting, and fail loudly if the port stays held or the new server never answers.
- `cel run orchestrator` refuses to resume a session file another live process (in any pane, named or not) is already resuming, naming the pane, unless `--force`; `cel doctor` flags two live processes on one session file.
