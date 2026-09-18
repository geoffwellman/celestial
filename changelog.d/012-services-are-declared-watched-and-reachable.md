### Added
- **Services are declared, watched and reachable**: `cel services` lists the
  services a workspace declares and every `cel-fanout try` preview as one
  model - state (`up`/`healthy`/`down`), port, pid, resident memory, uptime and
  the URL that reaches each one from a laptop - and
  `start|stop|restart|logs|open <name>` drives them through a herdr pane
  (a `services:` entry with only a name and a url stays valid, and is
  observe-only). The steward probes every service declaring `health:` and
  raises ONE rolled-up blocker after two consecutive down ticks, clearing it
  when the service answers again; `restart: auto` restarts it once first and
  says so. The dashboard gains a reverse proxy -
  `http://<tailnet-ip>:<dash-port>/svc/<port>/…`, WebSocket upgrades included,
  known ports only, control token required - so a loopback dev server or
  preview is reachable from the laptop at all; `cel-fanout try` prints that URL
  as its last line. The console gains a SERVICES view (`S`) and the router
  three intents (`open_service`, `service_ctl`, `service_logs`)
