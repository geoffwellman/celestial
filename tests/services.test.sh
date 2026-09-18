# shellcheck shell=bash
# `cel services` - one model for everything this box is running on a port:
# the services a workspace declares and the previews `cel-fanout try` starts.
#
# Nothing here touches the live box. herdr is a stub on a prepended PATH that
# logs its argv, the "service" is a python http server on a free port in a
# fixture directory, and the registry points at a temporary workspace.
source "$CEL_ROOT/lib/common.sh"

CEL="$CEL_ROOT/bin/cel"

_svc_free_port() {
  python3 - <<'EOF'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
EOF
}

_svc_setup() { # [service-yaml]
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/alpha/.cel" "$T/alpha/run"
  export CEL_REGISTRY="$T/registry.yaml"
  export CEL_SERVICES_HERDR="$T/bin/herdr"
  export PATH="$T/bin:$PATH"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
case "\$1 \$2" in
  'pane split') printf '{"result":{"pane_id":"w1:p9"}}' ;;
  'agent list') printf '{"result":{"agents":[]}}' ;;
  'pane read')  printf 'last line of the pane\n' ;;
  *) printf '{}' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
  : > "$T/calls"
}

_svc_teardown() {
  [ -n "${SVC_PID:-}" ] && kill "$SVC_PID" 2>/dev/null
  rm -rf "$T"
}

# A declared service whose port is answering reads `up`, and `healthy` when
# its `health:` path answers 200. The port, the pid and the memory of the
# process tree in its cwd all come back in one document.
test_services_json_reports_state_port_and_memory() {
  _svc_setup
  local port; port="$(_svc_free_port)"
  ( cd "$T/alpha/run" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  SVC_PID=$!
  cat >"$T/alpha/workspace.yaml" <<EOF
name: alpha
services:
  - name: builder
    url: http://127.0.0.1:$port
    cmd: python3 -m http.server $port
    cwd: $T/alpha/run
    health: /
EOF
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$port/" && break
    sleep 0.3
  done
  local out; out="$("$CEL" services --workspace alpha --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].name')" builder
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" healthy
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].port')" "$port"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].pid > 0')" true
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].rss_mb > 0')" true
  # and the human rows say the same thing
  assert_contains "$("$CEL" services --workspace alpha)" "builder"
  _svc_teardown
}

# Nothing is listening: the row is `down` rather than absent, because a
# service you declared and did not start is exactly what you want to see.
test_services_declared_but_dead_is_down() {
  _svc_setup
  local port; port="$(_svc_free_port)"
  printf 'name: alpha\nservices:\n  - {name: builder, url: "http://127.0.0.1:%s"}\n' "$port" \
    > "$T/alpha/workspace.yaml"
  local out; out="$("$CEL" services --workspace alpha --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" down
  _svc_teardown
}

# `start` runs the declared cmd in a pane and remembers it; `stop` closes that
# pane. The pane id is the only handle there is - herdr exposes no pid - so
# losing it means a service nobody can stop.
test_services_start_records_a_pane_and_stop_closes_it() {
  _svc_setup
  printf 'name: alpha\nservices:\n  - {name: builder, url: "http://127.0.0.1:4322", cmd: "python3 -m http.server 4322", cwd: "%s/alpha/run", env: {MODE: "dev x"}}\n' "$T" \
    > "$T/alpha/workspace.yaml"
  "$CEL" services start builder --workspace alpha
  assert_eq "$(jq -r '.builder.pane' "$T/alpha/.cel/services.json")" "w1:p9"
  assert_contains "$(cat "$T/calls")" "pane split"
  assert_contains "$(cat "$T/calls")" "pane run"
  # the env value has a space in it and must reach the pane as ONE variable
  assert_contains "$(cat "$T/calls")" "MODE=dev\\ x"
  assert_contains "$("$CEL" services logs builder --workspace alpha)" "last line of the pane"
  "$CEL" services stop builder --workspace alpha
  assert_contains "$(cat "$T/calls")" "pane close w1:p9"
  assert_eq "$(jq -r '.builder // "gone"' "$T/alpha/.cel/services.json")" gone
  _svc_teardown
}

# A name+url entry - the shape every workspace.yaml already has - stays valid
# and is OBSERVE-ONLY: there is nothing to start, and saying so is better than
# starting something arbitrary.
test_services_without_cmd_are_observe_only() {
  _svc_setup
  printf 'name: alpha\nservices:\n  - {name: docs, url: "http://127.0.0.1:9/"}\n' > "$T/alpha/workspace.yaml"
  local out; out="$("$CEL" services start docs --workspace alpha 2>&1)"
  assert_contains "$out" "observe-only"
  assert_eq "$(printf '%s' "$("$CEL" services --workspace alpha --json)" | jq -r '.[0].observe_only')" true
  _svc_teardown
}

# Every running preview is a service too. The ledger row is the declaration:
# its ticket names it, and its url carries the port.
test_services_include_running_try_previews() {
  _svc_setup
  printf 'name: alpha\nservices: []\n' > "$T/alpha/workspace.yaml"
  cat >"$T/alpha/.cel/delegations.json" <<EOF
[{"id":"d1","repo":"widget","branch":"ABC-49-slug","ticket":"ABC-49","worktree":"$T/alpha/run",
  "try":{"pane":"w1:p3","port":4400,"url":"http://localhost:4401","started":"2026-09-18T10:00:00+00:00"}}]
EOF
  local out; out="$("$CEL" services --workspace alpha --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].name')" "try ABC-49"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].kind')" preview
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].ticket')" "ABC-49"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].port')" 4401
  _svc_teardown
}

# `reach` is the laptop's answer. A loopback port is not reachable over the
# tailnet, so the row carries the dashboard's proxy URL when the dashboard is
# up, and nothing invented when it is not.
test_services_reach_is_the_dash_proxy_url() {
  _svc_setup
  local dash; dash="$(_svc_free_port)"
  ( cd "$T/alpha/run" && exec python3 -m http.server "$dash" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  SVC_PID=$!
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$dash/" && break; sleep 0.3; done
  printf 'name: alpha\ndash: {port: %s}\nservices:\n  - {name: docs, url: "http://127.0.0.1:4322/"}\n' "$dash" \
    > "$T/alpha/workspace.yaml"
  CEL_DASH_HOST=127.0.0.1 assert_contains \
    "$(CEL_DASH_HOST=127.0.0.1 "$CEL" services --workspace alpha --json | jq -r '.[0].reach')" \
    "/svc/4322/"
  _svc_teardown
}
