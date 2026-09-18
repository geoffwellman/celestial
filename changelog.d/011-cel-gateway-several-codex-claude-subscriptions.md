### Added
- **`cel gateway`** - several Codex/Claude subscriptions behind one loopback
  door. `install` registers omp's `auth-broker` and `auth-gateway` as box
  services on 127.0.0.1 (47311/47411 by default) and mints the bearer;
  `status [--json]` prints one row per account with each window's used/limit
  and state, short ids only and never the token; `login <provider>` /
  `logout <provider> <id>` are the one-line verbs for adding and dropping a
  subscription. A worker profile that says `via: gateway` launches pi at
  `ompgw/<provider>/<model>` with an `ompgw` provider merged into
  `~/.pi/agent/models.json` and `OMP_GATEWAY_TOKEN` + `CEL_SESSION_ID` set in
  the pane - the session id is what the gateway balances accounts on, because
  pi sends no session identity of its own. A gateway that is down, or a
  provider with no usable credential, vetoes the profile before a pane spawns;
  `cel doctor` carries one line about it and the QUOTA view and the dashboard
  list the accounts
