### Fixed
- The dead-mise-shim check (#341) had no time limit, so a hung `mise` could hang `cel doctor`, `cel setup`, `cel update` or `cel run`. Its `mise which` and its fallback `<shim> --version` now each run under `timeout -k 1 5` (`CEL_SHIM_CHECK_SECS` overrides the 5). A timeout means "cannot tell", never "dead":
  - `cel run` warns and launches.
  - `cel setup` warns and retains the agent.
  - `cel update` warns and skips that agent's updater. Its version read and updater would only hang in the same mise.
  - `cel doctor` warns.
  - After one timeout, later checks in the same command answer straight away, so a box with many shims waits for one bound, not one per shim.
- `cel doctor`, `cel setup` and `cel update` ran the shim check from whatever directory they were started in, so a project's own mise config decided the answer. They now ask in the global mise context (`$HOME`). That is the node agents get unless a workspace's own mise config selects another, and it is where a reinstall's `npm install -g` now writes. Doctor's dead-shim message says it was checked there. `cel run` still asks from the launch's own directory, where the runtime actually starts, so a workspace that pins a node without the agent is still refused at launch.
