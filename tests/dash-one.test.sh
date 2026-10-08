# shellcheck shell=bash
# CEL-107: ONE DASHBOARD FOR THE BOX. `cel dash` used to start a server per
# workspace; v2 already read across every workspace, so four processes served
# one page while polling herdr and gh four times over, and the per-workspace
# restart race took one of them down. Now: one server, the old ports redirect
# to it, the steward ensures it once, doctor names it, and the classic page
# takes ?ws=<name>.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/dash.sh"

_do_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

# Two workspaces, each with the port its old per-workspace server held; no
# `dash:` in the box config, so the first workspace's port is the dashboard's.
_do_setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/alpha" "$T/beta" "$T/inbox" "$T/logs" "$T/home"
  cat >"$T/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '{"result":{"agents":[],"workspaces":[],"panes":[]}}'
EOF
  cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]'
EOF
  printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/tailscale"
  chmod +x "$T/bin/herdr" "$T/bin/gh" "$T/bin/tailscale"
  PA="$(_do_port)"; PB="$(_do_port)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_DASH_LOG_DIR="$T/logs" \
    CEL_CONFIG_FILE="$T/config.yaml" PATH="$T/bin:$PATH"
  printf 'dash:\n  host: 127.0.0.1\n' >"$CEL_CONFIG_FILE"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n  beta: {path: "%s/beta"}\n' "$T" "$T" >"$CEL_REGISTRY"
  printf 'name: alpha\ndash: {port: %s}\n' "$PA" >"$T/alpha/workspace.yaml"
  printf 'name: beta\ndash: {port: %s}\n' "$PB" >"$T/beta/workspace.yaml"
}

# every dash server started from this fixture, found by its own config
_do_servers() {
  local pid
  for pid in $(pgrep -f 'tools/dash/server\.mjs' 2>/dev/null || true); do
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -q "^CEL_DASH_CONFIG=.*$T/alpha" && printf '%s\n' "$pid"
  done
  return 0
}

_do_down() {
  local pid
  for pid in $(_do_servers); do kill "$pid" 2>/dev/null || true; done
  rm -rf "$T"
}

test_dash_one_ensure_starts_exactly_one_server_for_every_workspace() {
  _do_setup
  "$CEL_ROOT/bin/cel" dash --ensure >/dev/null 2>&1 || { echo "ensure failed: $(cat "$T"/logs/* 2>/dev/null)"; _do_down; return 1; }
  "$CEL_ROOT/bin/cel" dash --ensure >/dev/null 2>&1
  assert_eq "$(_do_servers | grep -c .)" "1"
  # on the first workspace's port, carrying both
  assert_eq "$(curl -sf "http://127.0.0.1:$PA/api/state" | jq -r '.workspaces | join(",")')" "alpha,beta"
  _do_down
}

test_dash_one_old_ports_redirect_to_the_one_dashboard() {
  _do_setup
  "$CEL_ROOT/bin/cel" dash --ensure >/dev/null 2>&1
  local i; for i in $(seq 1 20); do _dash_port_free 127.0.0.1 "$PB" || break; sleep 0.2; done
  local hdr; hdr="$(curl -s -m 3 -o /dev/null -D - "http://127.0.0.1:$PB/classic?ws=beta" | tr -d '\r')"
  assert_contains "$hdr" "302"
  assert_contains "$hdr" "location: http://127.0.0.1:$PA/classic?ws=beta"
  _do_down
}

test_dash_one_classic_shows_the_workspace_it_is_asked_for() {
  _do_setup
  "$CEL_ROOT/bin/cel" dash --ensure >/dev/null 2>&1
  assert_contains "$(curl -sf "http://127.0.0.1:$PA/classic?ws=beta")" "<title>beta"
  assert_contains "$(curl -sf "http://127.0.0.1:$PA/classic")" "<title>alpha"
  assert_eq "$(curl -sf "http://127.0.0.1:$PA/api/state?ws=beta" | jq -r .workspace)" "beta"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PA/classic?ws=nope")" "404"
  _do_down
}

test_dash_one_box_config_port_wins() {
  _do_setup
  printf 'dash:\n  host: 127.0.0.1\n  port: 4242\n' >"$CEL_CONFIG_FILE"
  assert_eq "$(dash_port)" "4242"
  rm -f "$CEL_CONFIG_FILE"
  assert_eq "$(dash_port)" "$PA"
  rm -rf "$T"
}

# The steward ensures THE dashboard, once - never one per workspace.
test_dash_one_steward_ensures_one_dashboard_not_one_per_workspace() {
  _do_setup
  source "$CEL_ROOT/lib/steward.sh"
  cmd_dash() { printf '%s\n' "$*" >>"$T/dash.calls"; }
  cmd_pages() { :; }
  _steward_servers >/dev/null 2>&1
  assert_eq "$(cat "$T/dash.calls")" "--ensure"
  rm -rf "$T"
}

test_dash_one_doctor_reports_the_single_dashboard() {
  _do_setup
  assert_contains "$(dash_doctor_line)" "dashboard: one for the box, http://127.0.0.1:$PA - DOWN"
  "$CEL_ROOT/bin/cel" dash --ensure >/dev/null 2>&1
  local out; out="$(dash_doctor_line)"
  assert_contains "$out" "dashboard: one for the box, http://127.0.0.1:$PA - up"
  _do_down
}

test_dash_one_refuses_the_old_workspace_flag() {
  local out rc=0
  out="$("$CEL_ROOT/bin/cel" dash --workspace beta --ensure 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected a refusal: $out"; return 1; }
  assert_contains "$out" "one dashboard for the box"
}
