# shellcheck shell=bash
# CEL-109: the dashboard was started with `setsid nohup ... &` from inside the
# steward's oneshot unit; setsid leaves the session but not the cgroup, so
# systemd killed the dashboard when the tick ended. It now runs as an
# installed user unit, cel-dash.service. systemctl is a stub that logs argv
# and, on start/restart, brings up a fake server - the live manager is never
# touched.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/dash.sh"

_du_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

_du_setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/units" "$T/logs" "$T/root/bin"
  PORT="$(_du_port)"
  # the forked path would run this; if it ever does, the test sees it
  printf '#!/usr/bin/env bash\necho forked >>"%s/forked"\n' "$T" >"$T/root/bin/cel"
  chmod +x "$T/root/bin/cel"
  cat >"$T/bin/systemctl" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DU_LOG"
case "$*" in
  *start\ cel-dash.service*|*restart\ cel-dash.service*)
    python3 -c '
import http.server,sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200);s.end_headers();s.wfile.write(b"{}")
    def log_message(*a): pass
http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()' "$DU_PORT" >/dev/null 2>&1 &
    echo $! >"$DU_PID" ;;
  *is-active*) cat "$DU_ACTIVE" 2>/dev/null || echo inactive ;;
  *is-enabled*) echo enabled ;;
esac
exit 0
S
  chmod +x "$T/bin/systemctl"
  export DU_LOG="$T/log" DU_PORT="$PORT" DU_PID="$T/srv.pid" DU_ACTIVE="$T/active" \
    CEL_SYSTEMD_DIR="$T/units" CEL_DASH_LOG_DIR="$T/logs" CEL_ROOT_SAVED="$CEL_ROOT" \
    PATH="$T/bin:$PATH"
}

_du_down() {
  [ -f "$T/srv.pid" ] && kill "$(cat "$T/srv.pid")" 2>/dev/null || true
  rm -rf "$T"
}

test_dash_unit_runs_cel_dash_with_path_workdir_restart_and_log() {
  _du_setup
  local u; u="$(dash_unit_text 7770 100.64.0.9 /srv/alpha "$T/logs/dash.log")"
  assert_contains "$u" "ExecStart=$CEL_ROOT/bin/cel dash --port 7770 --host 100.64.0.9"
  assert_contains "$u" "Restart=on-failure"
  assert_contains "$u" "WorkingDirectory=/srv/alpha"
  assert_contains "$u" "Environment=\"PATH=$HOME/.local/share/mise/shims:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin\""
  # fixed, not the caller's: the steward and a shell must write the same file
  local u2; u2="$(PATH="/elsewhere:$PATH" dash_unit_text 7770 100.64.0.9 /srv/alpha "$T/logs/dash.log")"
  assert_eq "$u2" "$u"
  assert_contains "$u" "StandardOutput=append:$T/logs/dash.log"
  assert_contains "$u" "WantedBy=default.target"
  _du_down
}

test_dash_ensure_starts_the_unit_not_a_fork() {
  _du_setup
  local out rc=0
  out="$(_dash_ensure "$PORT" 127.0.0.1 2>&1)" || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$out" "started on $PORT"
  [ -f "$T/units/cel-dash.service" ] || { echo "unit not installed"; _du_down; return 1; }
  assert_contains "$(cat "$T/units/cel-dash.service")" "--port $PORT"
  assert_contains "$(cat "$DU_LOG")" "--user daemon-reload"
  assert_contains "$(cat "$DU_LOG")" "start cel-dash.service"
  [ ! -e "$T/forked" ] || { echo "ensure forked a server"; _du_down; return 1; }
  _du_down
}

test_dash_restart_restarts_the_unit_and_keeps_the_port_wait() {
  _du_setup
  # never the live registry: its legacy dash ports are the box's real servers
  export CEL_REGISTRY="$T/registry.yaml"; printf 'workspaces: {}\n' >"$CEL_REGISTRY"
  local out rc=0
  out="$(CEL_DASH_PORT_WAIT_S=2 _dash_restart "$PORT" 127.0.0.1 2>&1)" || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$(cat "$DU_LOG")" "--user stop cel-dash.service"
  assert_contains "$(cat "$DU_LOG")" "start cel-dash.service"
  [ ! -e "$T/forked" ] || { echo "restart forked a server"; _du_down; return 1; }
  _du_down
}

test_dash_doctor_names_the_unit_state() {
  _du_setup
  echo active >"$DU_ACTIVE"
  local out; out="$(dash_doctor_line)"
  assert_contains "$out" "cel-dash.service: active, enabled"
  _du_down
}

# The pages servers were started the same `setsid ... &` way from the same
# steward tick, so they died the same death. Under a user manager they run as
# transient units with their own cgroup.
test_pages_ensure_runs_in_its_own_unit_not_a_fork() {
  _du_setup
  source "$CEL_ROOT/lib/pages.sh"
  cat >"$T/bin/systemd-run" <<'S'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >>"$DU_LOG"
python3 -m http.server --bind 127.0.0.1 "$DU_PORT" >/dev/null 2>&1 &
echo $! >"$DU_PID"
S
  chmod +x "$T/bin/systemd-run"
  local out rc=0
  out="$(CEL_PAGES_PORT="$PORT" CEL_PAGES_HOST=127.0.0.1 CEL_PAGES_LOG_DIR="$T/logs" _pages_ensure 0 2>&1)" || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$(cat "$DU_LOG")" "--user --unit=cel-pages"
  assert_contains "$(cat "$DU_LOG")" "Restart=on-failure"
  [ ! -e "$T/forked" ] || { echo "pages forked a server"; _du_down; return 1; }
  _du_down
}

# A changed unit (dash.port moved) on an ACTIVE service: `start` is a no-op,
# so the old server kept the old port and every tick said "did not come up".
test_dash_ensure_restarts_an_active_unit_whose_file_changed() {
  _du_setup
  echo active >"$DU_ACTIVE"
  printf 'old unit\n' >"$T/units/cel-dash.service"
  local rc=0
  _dash_ensure "$PORT" 127.0.0.1 >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$(cat "$DU_LOG")" "--user restart cel-dash.service"
  _du_down
}
