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

# A TOKEN IN A URL IS A TOKEN IN A LOG. The proxy takes its control token as a
# query parameter because a browser cannot set a header on a plain navigation
# - and the first cut of that logged `req.url` verbatim, so clicking a service
# link wrote the dash's control token in cleartext into a log file that
# outlives the process (PR #54 review). The query form is now exchanged for a
# scoped cookie and bounced once to the same path without it, and the request
# line is redacted on its way to the log either way.
test_dash_proxy_never_logs_the_control_token() {
  local up; up="$(_dash_free_port)"
  _dash_boot "$up"
  local d; d="$(mktemp -d)"
  printf 'hello from the builder' > "$d/x.txt"
  ( cd "$d" && exec python3 -m http.server "$up" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  UP_PID=$!
  local i; for i in $(seq 1 20); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$up/x.txt" && break; sleep 0.3; done
  # the query form bounces once, hands back the cookie, and drops the token
  local hdr; hdr="$(curl -s -D - -o /dev/null "http://127.0.0.1:$DASH_PORT/svc/$up/x.txt?cel_token=$TOKEN")"
  assert_contains "$hdr" "302"
  assert_contains "$(tr 'A-Z' 'a-z' <<<"$hdr")" "location: /svc/$up/x.txt"
  case "$hdr" in *"$TOKEN"*) ;; *) echo 'the bounce did not hand back the token as a cookie'; rm -rf "$d"; _dash_shutdown; return 1;; esac
  case "$(printf '%s' "$hdr" | grep -i '^location:' || true)" in *cel_token*) echo 'the redirect target still carries the token'; rm -rf "$d"; _dash_shutdown; return 1;; esac
  # following it with the cookie alone fetches the service
  local body; body="$(curl -sf -b "cel_svc_token=$TOKEN" "http://127.0.0.1:$DASH_PORT/svc/$up/x.txt")"
  assert_contains "$body" "hello from the builder"
  # NOTHING the server logged may contain the token, and the parameter is
  # visibly redacted rather than silently dropped
  sleep 0.5
  case "$(cat "$T/dash.log")" in *"$TOKEN"*) echo 'the control token reached the log'; rm -rf "$d"; _dash_shutdown; return 1;; esac
  assert_contains "$(cat "$T/dash.log")" "cel_token=REDACTED"
  rm -rf "$d"
  _dash_shutdown
}

# --- CEL-43 section 4: box material appears four times -----------------------
# The owner, 2026-09-19: "why are there multiple cel broker and gateway
# services?" There is exactly one of each. What multiplied was the DISPLAY:
# four per-workspace dashboards on this box each rendered the same box-level
# rows inside their own services panel, and each rendered the whole
# subscriptions panel, which is box-level in its entirety. Flipping between
# tabs reads as several brokers.
#
# Two workspaces, one box service and one workspace service, so the partition
# and the single-owner rule are both visible in one fixture.
_dash_box_boot() { # <this-workspace> [box-owner]
  local me="$1" owner="${2:-}"
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/alpha" "$T/beta" "$T/inbox"
  cat >"$T/bin/cel" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  services) printf '%s\n' '[{"name":"builder","port":5173,"state":"up","kind":"declared","workspace":"alpha"},{"name":"cel-auth-broker","port":47311,"state":"healthy","kind":"box","workspace":"box"}]' ;;
  quota) printf '%s\n' '{"subscriptions":[{"provider":"claude","account":"acct-A","label":"acct-A","source":"cliproxy","windows":[{"name":"5h","scope":null,"used_pct":12,"resets_at":"2026-09-18T09:00:00Z"},{"name":"7d","scope":"Fable","used_pct":59,"resets_at":"2026-09-19T19:00:00Z"}],"extra":{"state":"enabled","reason":""}},{"provider":"codex","account":"acct-B","label":"acct-B","source":"omp","windows":[{"name":"7d","scope":null,"used_pct":3,"resets_at":null}],"extra":{"state":"enabled","reason":""}}],"balances":[]}' ;;
  gateway) [ "$2" = panel ] && printf '%s\n' '{"url":"http://127.0.0.1:47411/management.html","ssh":"ssh -L 47411:127.0.0.1:47411 box"}' ;;
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
  export CEL_REGISTRY="$T/registry.yaml"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n  beta: {path: "%s/beta"}\n' "$T" "$T" >"$CEL_REGISTRY"
  printf 'name: alpha\ndash: {port: 7770%s}\n' \
    "$([ "$owner" = alpha ] && printf ', box: true')" >"$T/alpha/workspace.yaml"
  printf 'name: beta\ndash: {port: 7771%s}\n' \
    "$([ "$owner" = beta ] && printf ', box: true')" >"$T/beta/workspace.yaml"
  mkdir -p "$T/root/bin" "$T/root/tools"
  cp -r "$CEL_ROOT/tools/dash" "$T/root/tools/dash"
  cp "$CEL_ROOT/tools/http-security.mjs" "$T/root/tools/http-security.mjs"
  cp "$T/bin/cel" "$T/root/bin/cel"
  DASH_PORT="$(_dash_free_port)"
  CEL_DASH_CONFIG="{\"name\":\"$me\",\"wsdir\":\"$T/$me\",\"host\":\"127.0.0.1\",\"port\":$DASH_PORT,\"repos\":[],\"services\":[]}" \
  CEL_ROOT="$T/root" CEL_INBOX_DIR="$T/inbox" CEL_REGISTRY="$CEL_REGISTRY" PATH="$T/bin:$PATH" \
    node "$T/root/tools/dash/server.mjs" >"$T/dash.log" 2>&1 &
  DASH_PID=$!
  local i
  for i in $(seq 1 30); do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$DASH_PORT/api/state" && break
    sleep 0.3
  done
  STATE="$(curl -sf "http://127.0.0.1:$DASH_PORT/api/state")"
}

# The designated dash: the box row is in the Box panel, never in the
# workspace's own services list, and the subscriptions come with it.
test_dash_box_panel_belongs_to_the_designated_workspace() {
  _dash_box_boot alpha
  assert_eq "$(printf '%s' "$STATE" | jq -r '.box.mine')" "true"
  assert_eq "$(printf '%s' "$STATE" | jq -r '[.boxServices[].name] | join(",")')" "cel-auth-broker"
  assert_eq "$(printf '%s' "$STATE" | jq -r '[.services[].name] | join(",")')" "builder"
  # the panel exists in the page for the dash that owns it
  assert_contains "$(curl -sf "http://127.0.0.1:$DASH_PORT/")" 'id="box"'
  _dash_shutdown
}

# Every OTHER dashboard shows one pointer line instead, naming the box dash's
# URL - and still never mixes the box row into its own services.
test_dash_without_the_box_flag_points_at_the_one_that_has_it() {
  _dash_box_boot beta
  assert_eq "$(printf '%s' "$STATE" | jq -r '.box.mine')" "false"
  assert_eq "$(printf '%s' "$STATE" | jq -r '.box.owner')" "alpha"
  assert_eq "$(printf '%s' "$STATE" | jq -r '.box.url')" "http://127.0.0.1:7770"
  assert_eq "$(printf '%s' "$STATE" | jq -r '.boxServices | length')" "0"
  assert_eq "$(printf '%s' "$STATE" | jq -r '.subscriptions | length')" "0"
  assert_eq "$(printf '%s' "$STATE" | jq -r '[.services[].name] | join(",")')" "builder"
  _dash_shutdown
}

# `dash.box: true` on the second workspace moves it: the default is the
# registry's first workspace, and a declaration beats the default.
test_dash_box_flag_moves_the_panel_to_the_workspace_that_declares_it() {
  _dash_box_boot beta beta
  assert_eq "$(printf '%s' "$STATE" | jq -r '.box.mine')" "true"
  assert_eq "$(printf '%s' "$STATE" | jq -r '.box.owner')" "beta"
  assert_eq "$(printf '%s' "$STATE" | jq -r '[.boxServices[].name] | join(",")')" "cel-auth-broker"
  _dash_shutdown
}

# THE SUBSCRIPTIONS CARD IS `cel quota --json` (CEL-80): the owner asked
# whether the quotas show on the dashboard, and the answer has to be the same
# rows `cel quota` prints - one per account, every window.
test_dash_box_card_carries_every_account_from_cel_quota() {
  _dash_box_boot alpha
  assert_eq "$(printf '%s' "$STATE" | jq -r '[.subscriptions[].account] | join(",")')" "acct-A,acct-B"
  assert_eq "$(printf '%s' "$STATE" | jq -r '[.subscriptions[0].windows[] | .name + (if .scope then " " + .scope else "" end)] | join(",")')" "5h,7d Fable"
  local page; page="$(curl -sf "http://127.0.0.1:$DASH_PORT/")"
  assert_contains "$page" 'id="subs"'
  assert_contains "$page" 'renderSubs'
  _dash_shutdown
}

# Every other dashboard: a compact line linking to the one that has the card.
test_dash_without_the_box_flag_links_to_the_subscriptions() {
  _dash_box_boot beta
  assert_eq "$(printf '%s' "$STATE" | jq -r '.subscriptions | length')" 0
  assert_contains "$(curl -sf "http://127.0.0.1:$DASH_PORT/")" 'subscriptions: on the box dashboard'
  _dash_shutdown
}

# The gateway panel is a loopback page. Viewed on loopback the card links it;
# viewed from anywhere else it shows the tunnel instead, never a link that
# would 404 off the box - or tempt someone to expose it.
test_dash_gateway_panel_link_only_on_loopback() {
  _dash_box_boot alpha
  assert_eq "$(printf '%s' "$STATE" | jq -r '.gatewayPanel.url')" "http://127.0.0.1:47411/management.html"
  assert_eq "$(printf '%s' "$STATE" | jq -r '.gatewayPanel.loopback')" true
  assert_contains "$(printf '%s' "$STATE" | jq -r '.gatewayPanel.ssh')" "ssh -L 47411:127.0.0.1:47411"
  local off; off="$(curl -sf -H 'X-Forwarded-For: 100.64.0.9' "http://127.0.0.1:$DASH_PORT/api/state" | jq -r '.gatewayPanel.loopback')"
  assert_eq "$off" true
  local page; page="$(curl -sf "http://127.0.0.1:$DASH_PORT/")"
  assert_contains "$page" 'Gateway panel'
  _dash_shutdown
}
