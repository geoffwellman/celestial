# shellcheck shell=bash
# The dashboard's REVERSE PROXY. The owner drives this box from a laptop over
# the tailnet, and every dev server and every `try` preview listens on
# 127.0.0.1 - unreachable from there. The dash already binds the tailnet IP,
# so it forwards /svc/<port>/… to loopback, and only for ports that belong to
# a service or a preview this workspace knows about.
#
# Everything here runs against a fixture root: a stub `cel` that answers
# `services --json`, and a python server standing in for the dev server.
source "$CEL_ROOT/lib/common.sh"

_dash_free_port() {
  python3 - <<'EOF'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
EOF
}

_dash_boot() { # <allowed-port>
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/ws" "$T/inbox"
  # the port this workspace admits is baked into the stub at write time
  cat >"$T/bin/cel" <<EOF
#!/usr/bin/env bash
case "\$1" in
  services) printf '[{"name":"builder","port":$1,"state":"up","kind":"declared"}]\n' ;;
  *) printf '{}\n' ;;
esac
EOF
  chmod +x "$T/bin/cel"
  cat >"$T/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '{"result":{"agents":[],"workspaces":[],"panes":[]}}'
EOF
  cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]'
EOF
  chmod +x "$T/bin/herdr" "$T/bin/gh"
  mkdir -p "$T/root/bin" "$T/root/tools"
  cp -r "$CEL_ROOT/tools/dash" "$T/root/tools/dash"
  cp "$CEL_ROOT/tools/http-security.mjs" "$T/root/tools/http-security.mjs"
  cp "$T/bin/cel" "$T/root/bin/cel"
  DASH_PORT="$(_dash_free_port)"
  CEL_DASH_CONFIG="{\"name\":\"alpha\",\"wsdir\":\"$T/ws\",\"host\":\"127.0.0.1\",\"port\":$DASH_PORT,\"repos\":[],\"services\":[]}" \
  CEL_ROOT="$T/root" CEL_INBOX_DIR="$T/inbox" PATH="$T/bin:$PATH" \
    node "$T/root/tools/dash/server.mjs" >"$T/dash.log" 2>&1 &
  DASH_PID=$!
  local i
  for i in $(seq 1 30); do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$DASH_PORT/api/state" && break
    sleep 0.3
  done
  TOKEN="$(curl -sf "http://127.0.0.1:$DASH_PORT/api/session" | jq -r .csrfToken)"
}

_dash_shutdown() {
  [ -n "${DASH_PID:-}" ] && kill "$DASH_PID" 2>/dev/null
  [ -n "${UP_PID:-}" ] && kill "$UP_PID" 2>/dev/null
  rm -rf "$T"
}

# The body and the upstream's own headers arrive intact: a proxy that rewrote
# either would break exactly the dev servers it exists to carry.
test_dash_proxies_a_known_service_port() {
  local up; up="$(_dash_free_port)"
  _dash_boot "$up"
  local d; d="$(mktemp -d)"
  printf 'hello from the builder' > "$d/x.txt"
  ( cd "$d" && exec python3 -m http.server "$up" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  UP_PID=$!
  local i; for i in $(seq 1 20); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$up/x.txt" && break; sleep 0.3; done
  local out; out="$(curl -sf -H "x-cel-csrf: $TOKEN" "http://127.0.0.1:$DASH_PORT/svc/$up/x.txt" -D "$d/hdr")"
  assert_contains "$out" "hello from the builder"
  assert_contains "$(tr 'A-Z' 'a-z' < "$d/hdr")" "content-type: text/plain"
  rm -rf "$d"
  _dash_shutdown
}

# Only declared ports. A tailnet neighbour must not be able to browse this
# box's loopback by guessing numbers.
test_dash_refuses_an_unknown_port() {
  local up; up="$(_dash_free_port)"
  _dash_boot "$up"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "x-cel-csrf: $TOKEN" \
    "http://127.0.0.1:$DASH_PORT/svc/9111/x")"
  assert_eq "$code" 404
  _dash_shutdown
}

# ...and only with the dash's own control token, the same one its control
# endpoints require.
test_dash_proxy_refuses_a_request_without_the_control_token() {
  local up; up="$(_dash_free_port)"
  _dash_boot "$up"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DASH_PORT/svc/$up/x")"
  assert_eq "$code" 403
  _dash_shutdown
}

# HMR is the reason previews are worth reaching at all: a dev server that
# cannot upgrade is a page that never reloads. The upstream here is a raw
# socket that answers 101 and echoes, so the test proves the tunnel, not a
# WebSocket library.
test_dash_proxy_round_trips_a_websocket_upgrade() {
  local up; up="$(_dash_free_port)"
  _dash_boot "$up"
  local out
  out="$(UP="$up" DASH="$DASH_PORT" TOK="$TOKEN" node -e '
const net = require("node:net");
const up = net.createServer((s) => {
  let seen = "";
  s.on("data", (b) => {
    seen += b.toString("latin1");
    if (seen.includes("\r\n\r\n") && !s.upgraded) {
      s.upgraded = true;
      s.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n");
      const rest = seen.split("\r\n\r\n")[1];
      if (rest) s.write(rest);
    } else if (s.upgraded) s.write(b);
  });
});
up.listen(Number(process.env.UP), "127.0.0.1", () => {
  const c = net.connect(Number(process.env.DASH), "127.0.0.1", () => {
    c.write("GET /svc/" + process.env.UP + "/ws HTTP/1.1\r\nHost: 127.0.0.1:" + process.env.DASH +
      "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nx-cel-csrf: " + process.env.TOK + "\r\n\r\n");
    setTimeout(() => c.write("one-frame"), 300);
  });
  let got = "";
  c.on("data", (b) => {
    got += b.toString("latin1");
    if (got.includes("one-frame")) {
      console.log(got.split("\r\n")[0] + " echoed one-frame");
      process.exit(0);
    }
  });
  setTimeout(() => { console.log("no upgrade: " + got); process.exit(1); }, 5000);
});
')"
  assert_contains "$out" "101"
  assert_contains "$out" "echoed one-frame"
  _dash_shutdown
}
