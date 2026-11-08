### Added
- `cel gateway rotate-key` replaces the gateway client key without downtime.
  - `--stage` mints a new key and lists both keys in `config.yaml`. Once `/v1/models` answers 200 to both, new launches get the new key. The old key is kept in `api-key.previous`.
  - `--status` lists every live process still holding the old key, by agent name and pid, matched by sha256. It also shows which keys the config accepts and the restart command for each holder, with root and core last.
  - `--finish` is refused while any process holds the old key, unless `--force`. It drops the old key and checks that the old key gets 401 and the new key 200.
  - `--abort` restores the old key as the only key.
- `--stage`, `--finish` and `--abort` are for the owner only. They refuse any process carrying an agent's launch marks, or running under an agent launch, and the agent guard refuses them in every agent pane. Any agent may run `--status`. No key value is ever printed.
- `cel update`'s gateway refresh keeps both keys accepted while a rotation is in progress.
