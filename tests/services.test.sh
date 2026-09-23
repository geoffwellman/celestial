# shellcheck shell=bash
# `cel services` - one model for everything this box is running on a port:
# the services a workspace declares and the previews `cel-fanout try` starts.
#
# Nothing here touches the live box. herdr is a stub on a prepended PATH that
# logs its argv, the "service" is a python http server on a free port in a
# fixture directory, and the registry points at a temporary workspace.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/services.sh"

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
  # A service with no workspace pane is split from the box's own services
  # tab, so the stub has to be able to hand one back (CEL-62).
  'tab list')   printf '{"result":{"tabs":[]}}' ;;
  'tab create') printf '{"result":{"root_pane":{"pane_id":"w1:p1"}}}' ;;
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

# --- box services ------------------------------------------------------------
#
# A box service belongs to the box, not to a workspace: the auth broker and
# gateway run for every workspace at once, and until CEL-34 they were started
# by hand and watched by nobody. `services.d` is the seam - one JSON file per
# service, the same shape as a `services:` row.

_svc_box_setup() { # writes a fixture services.d and box state dir
  _svc_setup
  export CEL_SERVICES_D="$T/services.d"
  export CEL_SERVICES_STATE="$T/state/services"
  mkdir -p "$CEL_SERVICES_D"
}

# Outside any workspace there is still something to say: `cel services` run
# from ~ used to answer "not inside a workspace", which is the one place the
# box's own services are all there is to look at.
test_box_services_are_listed_outside_any_workspace() {
  _svc_box_setup
  printf '{"name":"cel-auth-broker","url":"http://127.0.0.1:47311","cmd":"omp auth-broker serve","health":"/"}\n' \
    > "$CEL_SERVICES_D/cel-auth-broker.json"
  local out; out="$(cd "$T" && "$CEL" services 2>&1)"
  assert_contains "$out" "box"
  assert_contains "$out" "cel-auth-broker"
  local js; js="$(cd "$T" && "$CEL" services --json)"
  assert_eq "$(printf '%s' "$js" | jq -r '.[0].workspace')" box
  _svc_teardown
}

# Inside a workspace the box rows come AFTER the workspace's own: the question
# an operator is asking there is about the workspace first.
test_box_services_follow_the_workspace_rows_inside_a_workspace() {
  _svc_box_setup
  printf 'name: alpha\nservices:\n  - {name: builder, url: "http://127.0.0.1:4322"}\n' > "$T/alpha/workspace.yaml"
  printf '{"name":"cel-auth-gateway","port":47411,"cmd":"omp auth-gateway serve"}\n' \
    > "$CEL_SERVICES_D/cel-auth-gateway.json"
  local js; js="$("$CEL" services --workspace alpha --json)"
  assert_eq "$(printf '%s' "$js" | jq -r '.[0].name')" builder
  assert_eq "$(printf '%s' "$js" | jq -r '.[0].workspace')" alpha
  assert_eq "$(printf '%s' "$js" | jq -r '.[1].name')" cel-auth-gateway
  assert_eq "$(printf '%s' "$js" | jq -r '.[1].workspace')" box
  # a bare `port:` is a url: the port is the handle everything else keys off
  assert_eq "$(printf '%s' "$js" | jq -r '.[1].port')" 47411
  assert_contains "$("$CEL" services --workspace alpha)" "box"
  _svc_teardown
}

# `env` on a box service carries the broker's bearer, which grants every
# subscription on the box. It is masked wherever the rows are rendered - the
# dash card reads this same JSON.
test_box_service_json_masks_secret_env_values() {
  _svc_box_setup
  printf '{"name":"cel-auth-gateway","port":47411,"env":{"OMP_AUTH_BROKER_TOKEN":"super-secret-value","MODE":"dev"}}\n' \
    > "$CEL_SERVICES_D/cel-auth-gateway.json"
  local js; js="$(cd "$T" && "$CEL" services --json)"
  assert_eq "$(printf '%s' "$js" | jq -r '.[0].env.OMP_AUTH_BROKER_TOKEN')" '***'
  assert_eq "$(printf '%s' "$js" | jq -r '.[0].env.MODE')" dev
  ! printf '%s' "$js" | grep -q 'super-secret-value' \
    || { echo "a secret env value reached cel services --json"; _svc_teardown; return 1; }
  _svc_teardown
}

# Starting a box service goes through exactly the same path as a workspace
# one, and its state lands under the box's own directory: a box service whose
# pane id was written into some workspace's .cel/ would be lost the moment
# that workspace was removed.
test_box_service_start_records_state_off_any_workspace() {
  _svc_box_setup
  printf '{"name":"cel-auth-broker","port":47311,"cmd":"omp auth-broker serve","cwd":"%s"}\n' "$T" \
    > "$CEL_SERVICES_D/cel-auth-broker.json"
  ( cd "$T" && "$CEL" services start cel-auth-broker )
  assert_eq "$(jq -r '.pane' "$CEL_SERVICES_STATE/cel-auth-broker.json")" "w1:p9"
  assert_contains "$(cat "$T/calls")" "pane run"
  [ ! -f "$T/alpha/.cel/services.json" ] \
    || { echo "a box service wrote its state into a workspace"; _svc_teardown; return 1; }
  ( cd "$T" && "$CEL" services stop cel-auth-broker )
  assert_contains "$(cat "$T/calls")" "pane close w1:p9"
  [ ! -f "$CEL_SERVICES_STATE/cel-auth-broker.json" ] \
    || { echo "stop left the box service state behind"; _svc_teardown; return 1; }
  _svc_teardown
}

# The steward sweep is the reason box services exist at all: tonight's broker
# and gateway ran unsupervised because no workspace declared them. Two down
# ticks raise ONE rolled-up blocker, `restart: auto` restarts once, and the
# blocker clears when the service answers again.
test_steward_sweep_watches_box_services() {
  _svc_box_setup
  source "$CEL_ROOT/lib/steward.sh"
  export CEL_INBOX_DIR="$T/inbox"
  export CEL_STEWARD_STATE="$T/steward-state"
  printf 'workspaces: {}\n' > "$CEL_REGISTRY"
  printf '{"name":"cel-auth-broker","port":47311,"cmd":"omp auth-broker serve","cwd":"%s","health":"/","restart":"auto"}\n' "$T" \
    > "$CEL_SERVICES_D/cel-auth-broker.json"
  _steward_services >/dev/null 2>&1
  assert_eq "$(_inbox_open_fp box "service-box-cel-auth-broker" steward root)" ""
  _steward_services >/dev/null 2>&1
  local id; id="$(_inbox_open_fp box "service-box-cel-auth-broker" steward root)"
  [ -n "$id" ] || { echo "two down ticks raised no blocker for a box service"; _svc_teardown; return 1; }
  assert_contains "$(cat "$T/calls")" "pane run"   # restart: auto, exactly once
  # ...and it comes back: a real server on the declared port, and the blocker
  # is resolved rather than left for someone to wonder about.
  local port; port="$(_svc_free_port)"
  printf '{"name":"cel-auth-broker","port":%s,"cmd":"omp auth-broker serve","cwd":"%s","health":"/","restart":"auto"}\n' "$port" "$T" \
    > "$CEL_SERVICES_D/cel-auth-broker.json"
  ( cd "$T" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  SVC_PID=$!
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.3; done
  _steward_services >/dev/null 2>&1
  assert_eq "$(_inbox_open_fp box "service-box-cel-auth-broker" steward root)" ""
  _svc_teardown
}

# A box service's `health:` is a whole URL, not a path - `cel gateway install`
# writes one - and the broker and the gateway both answer 401 to an
# unauthenticated read, so a health check that could not present a bearer
# called a working gateway down and the sweep would have raised a blocker
# about it every ten minutes.
test_health_accepts_a_full_url_and_a_declared_bearer() {
  _svc_box_setup
  local port; port="$(_svc_free_port)"
  mkdir -p "$T/srv/v1"; printf '{}' > "$T/srv/v1/models"
  ( exec python3 -m http.server "$port" --bind 127.0.0.1 --directory "$T/srv" >/dev/null 2>&1 ) &
  SVC_PID=$!
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$port/v1/models" && break; sleep 0.3; done
  svc_health_ok "$port" "http://127.0.0.1:$port/v1/models" \
    || { echo "a full health url was not read"; _svc_teardown; return 1; }
  # and with a bearer the declaration names by command rather than by value
  svc_health_ok "$port" "http://127.0.0.1:$port/v1/models" 'bearer $(echo fixture-token)' \
    || { echo "a declared bearer was not presented"; _svc_teardown; return 1; }
  _svc_teardown
}

# A box service defaults to $HOME as its cwd, and the memory of the process
# tree under a cwd is how every other row is measured - which for $HOME is
# every process this user has. Reporting the whole box as one service's
# footprint is worse than reporting nothing.
test_box_service_in_home_reports_no_process_tree_memory() {
  _svc_box_setup
  printf '{"name":"cel-auth-broker","port":47311}\n' > "$CEL_SERVICES_D/cel-auth-broker.json"
  local js; js="$(cd "$T" && "$CEL" services --json)"
  assert_eq "$(printf '%s' "$js" | jq -r '.[0].rss_mb')" 0
  _svc_teardown
}

# --- starting a service is a pane split, and a split needs a direction -------
#
# 2026-09-23: `cel gateway install` ended with "cel-auth-gateway: herdr pane
# split returned no pane id - nothing was started". herdr's CLI had grown a
# requirement - a split names a DIRECTION and a TARGET pane - and the
# box-level branch here passed neither, so herdr printed its usage and every
# box service on this box was unstartable. The sentence above is the second
# half of the bug: it described the symptom and hid herdr's own message.
#
# This stub is the real CLI's contract: refuse a split without a direction and
# a target, exactly as herdr does, and log argv so a test can read what was
# asked for.
_svc_strict_herdr() {
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
case "\$1 \$2" in
  'pane split')
    dir=""; target=""
    shift 2
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --direction) dir="\$2"; shift 2 ;;
        --pane) target="\$2"; shift 2 ;;
        --current) target=current; shift ;;
        --cwd|--ratio|--env) shift 2 ;;
        --no-focus|--focus) shift ;;
        -*) shift ;;
        *) target="\$1"; shift ;;
      esac
    done
    if [ -z "\$dir" ] || [ -z "\$target" ]; then
      printf 'usage: herdr pane split [<pane_id>|--pane ID|--current] --direction right|down [...]\n' >&2
      exit 2
    fi
    printf '{"result":{"pane":{"pane_id":"w1:p9"},"pane_id":"w1:p9"}}' ;;
  'tab list')   cat "$T/tabs.json" 2>/dev/null || printf '{"result":{"tabs":[]}}' ;;
  'tab create') printf '{"result":{"root_pane":{"pane_id":"w1:p1"}}}' ;;
  'pane list')  cat "$T/panes.json" 2>/dev/null || printf '{"result":{"panes":[]}}' ;;
  'agent list') cat "$T/agents.json" 2>/dev/null || printf '{"result":{"agents":[]}}' ;;
  'pane read')  printf 'last line of the pane\n' ;;
  *) printf '{}' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
}

_svc_split_args() { # the argv of the last `pane split`
  grep '^pane split' "$T/calls" | tail -1 || true
}

# A box service has no workspace pane to sit under, so it needs a home of its
# own: `cel` finds or creates a tab and splits from a pane in it. The split
# must carry a direction and a target or herdr refuses it.
test_box_service_split_names_a_direction_and_a_target() {
  _svc_box_setup
  _svc_strict_herdr
  printf '{"name":"cel-auth-gateway","port":47411,"cmd":"omp auth-gateway serve","cwd":"%s"}\n' "$T" \
    > "$CEL_SERVICES_D/cel-auth-gateway.json"
  ( cd "$T" && "$CEL" services start cel-auth-gateway )
  assert_eq "$(jq -r '.pane' "$CEL_SERVICES_STATE/cel-auth-gateway.json")" "w1:p9"
  local args; args="$(_svc_split_args)"
  assert_contains "$args" "--direction"
  assert_contains "$args" "--pane"
  _svc_teardown
}

# The steward runs from a systemd timer with no current pane and no workspace,
# and it restarts box services. Its split still has a target, because the tab
# is found or created rather than inherited from wherever someone was standing.
test_box_service_split_has_a_target_without_a_current_pane() {
  _svc_box_setup
  _svc_strict_herdr
  printf '{"result":{"tabs":[{"label":"cel services","tab_id":"w1:t7"}]}}' > "$T/tabs.json"
  printf '{"result":{"panes":[{"pane_id":"w1:p5","tab_id":"w1:t7"}]}}' > "$T/panes.json"
  printf '{"name":"cel-auth-broker","port":47311,"cmd":"omp auth-broker serve","cwd":"%s"}\n' "$T" \
    > "$CEL_SERVICES_D/cel-auth-broker.json"
  ( cd "$T" && HERDR_PANE_ID= "$CEL" services start cel-auth-broker )
  local args; args="$(_svc_split_args)"
  assert_contains "$args" "--pane w1:p5"
  assert_contains "$args" "--direction down"
  # an existing services tab is reused, not created again
  [ -z "$(grep '^tab create' "$T/calls" || true)" ] \
    || { echo "a second services tab was created over an existing one"; _svc_teardown; return 1; }
  _svc_teardown
}

# A workspace's own service still lands under that workspace's pane.
test_workspace_service_split_still_targets_the_workspace_pane() {
  _svc_setup
  _svc_strict_herdr
  printf '{"result":{"agents":[{"cwd":"%s/alpha","pane_id":"w2:p3"}]}}' "$T" > "$T/agents.json"
  printf 'name: alpha\nservices:\n  - {name: builder, cmd: "python3 -m http.server 4322", cwd: "%s/alpha/run"}\n' "$T" \
    > "$T/alpha/workspace.yaml"
  "$CEL" services start builder --workspace alpha
  local args; args="$(_svc_split_args)"
  assert_contains "$args" "--pane w2:p3"
  assert_contains "$args" "--direction down"
  _svc_teardown
}

# When herdr refuses, say what herdr said. "returned no pane id" hid a CLI
# change for a day.
test_a_refused_split_reports_herdrs_own_message() {
  _svc_box_setup
  _svc_strict_herdr
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
case "\$1 \$2" in
  'pane split') printf 'error: pane w1:p1 is too small to split\n' >&2; exit 2 ;;
  'tab create') printf '{"result":{"root_pane":{"pane_id":"w1:p1"}}}' ;;
  *) printf '{}' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
  printf '{"name":"cel-auth-gateway","port":47411,"cmd":"omp auth-gateway serve","cwd":"%s"}\n' "$T" \
    > "$CEL_SERVICES_D/cel-auth-gateway.json"
  local out; out="$(cd "$T" && "$CEL" services start cel-auth-gateway 2>&1 || true)"
  assert_contains "$out" "too small to split"
  _svc_teardown
}
