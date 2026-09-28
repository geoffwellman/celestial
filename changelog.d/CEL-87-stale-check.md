### Fixed
- `cel update --check`, `--restart-orchestrators`, `cel doctor` and the steward repair no longer call a healthy orchestrator stale or stripped: the one pane lookup now takes the runtime process nearest the pane shell, not omp helper children, and the dry-run launch line is found wherever it appears.
