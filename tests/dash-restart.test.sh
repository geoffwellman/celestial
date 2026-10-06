# shellcheck shell=bash
# CEL-102: `cel dash --restart` started the new server while the old one still
# held the port; it died with EADDRINUSE and nothing retried. Restart/ensure
# now wait (bounded) for the port to be free, then verify the new server
# answers - or say so and fail.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/dash.sh"

_dr_free_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

_dr_setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/root/bin" "$T/logs"
  # stands in for `cel dash`: an http server answering /api/state, which dies
  # (like the real one) when the port is still taken
  cat >"$T/root/bin/cel" <<'EOF'
#!/usr/bin/env bash
echo $$ >"$(dirname "$0")/../srv.pid"
while [ $# -gt 0 ]; do case "$1" in --port) port="$2"; shift 2 ;; --host) host="$2"; shift 2 ;; *) shift ;; esac; done
exec python3 -c '
import http.server,sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200);s.end_headers();s.wfile.write(b"{}")
    def log_message(*a): pass
http.server.HTTPServer((sys.argv[1],int(sys.argv[2])),H).serve_forever()' "$host" "$port"
EOF
  chmod +x "$T/root/bin/cel"
  export CEL_ROOT="$T/root" CEL_DASH_LOG_DIR="$T/logs"
  PORT="$(_dr_free_port)"
}

# a listener that does NOT speak http (the old server mid-shutdown), released
# after <secs>
_dr_hold() { # <secs>
  python3 -c '
import socket,sys,time
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",int(sys.argv[1])));s.listen(1);time.sleep(float(sys.argv[2]))' "$PORT" "$1" &
  HOLD_PID=$!
  local i; for i in $(seq 1 30); do _dash_port_free 127.0.0.1 "$PORT" || break; sleep 0.1; done
}

_dr_down() {
  [ -n "${HOLD_PID:-}" ] && kill "$HOLD_PID" 2>/dev/null || true
  [ -f "$T/root/srv.pid" ] && kill "$(cat "$T/root/srv.pid")" 2>/dev/null || true
  rm -rf "$T"
}

test_dash_ensure_waits_for_a_held_port_then_starts() {
  _dr_setup
  _dr_hold 6
  local out rc=0 t0=$SECONDS
  out="$(CEL_DASH_PORT_WAIT_S=10 _dash_ensure alpha "$PORT" 127.0.0.1 2>&1)" || rc=$?
  [ $((SECONDS - t0)) -ge 1 ] || { echo "did not wait for the held port: $out"; _dr_down; return 1; }
  assert_eq "$rc" "0"
  assert_contains "$out" "started on $PORT"
  curl -sf -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/state" || { echo "new server not answering"; _dr_down; return 1; }
  _dr_down
}

test_dash_ensure_fails_clearly_when_the_port_stays_held() {
  _dr_setup
  _dr_hold 30
  local out rc=0
  out="$(CEL_DASH_PORT_WAIT_S=1 _dash_ensure alpha "$PORT" 127.0.0.1 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected non-zero, got 0: $out"; _dr_down; return 1; }
  assert_contains "$out" "port $PORT still in use"
  _dr_down
}

# Sourcery on #128: an old dashboard that ignores SIGTERM kept answering, and
# ensure then reported it as the healthy new server. Stop escalates to KILL.
test_dash_stop_kills_a_server_that_ignores_term() {
  _dr_setup
  CEL_DASH_CONFIG="{\"port\":$PORT}" bash -c 'trap "" TERM; exec -a "node tools/dash/server.mjs" sleep 60' &
  local pid=$!
  sleep 0.3
  CEL_DASH_PORT_WAIT_S=1 _dash_stop "$PORT" >/dev/null 2>&1
  sleep 0.2
  if kill -0 "$pid" 2>/dev/null; then echo "old dashboard survived the stop"; kill -9 "$pid"; _dr_down; return 1; fi
  _dr_down
}
