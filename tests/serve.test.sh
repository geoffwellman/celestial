# shellcheck shell=bash
# cel serve fixture coverage. Every systemd and process view is fixture-backed.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/serve.sh"

test_serve_adoption_never_kills_unledgered_processes() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl"
  mkdir -p "$CEL_SERVE_STATE"
  cat > "$CEL_SERVE_SYSTEMCTL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CEL_SERVE_STATE/calls"
if [[ "$*" == *list-units* ]]; then printf 'cel-serve-demo.service\n'; fi
EOF
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  CEL_SERVE_ADOPT_DATA='[]' CEL_SERVE_PROC_DATA=$'4321\t8080\t4096\t60\t/tmp/demo\tvite --port 8080'
  local out
  out="$(serve_adopt_json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].pid')" "4321"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].managed')" "false"
  assert_contains "$(cat "$CEL_SERVE_STATE/calls")" "--user list-units --type=service --state=running --plain --no-legend"
  unset CEL_SERVE_ADOPT_DATA CEL_SERVE_PROC_DATA CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL
  rm -rf "$t"
}

test_serve_stop_refuses_unledgered_pid() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state"
  mkdir -p "$CEL_SERVE_STATE"
  if (serve_stop 4321 >/dev/null 2>&1); then
    rm -rf "$t"; return 1
  fi
  rm -rf "$t"
}

test_serve_cgroup_match_respects_service_boundaries() {
  _serve_cgroup_is_ledgered_unit '/user.slice/user@1000.service/app.slice/cel-serve-preview.service/child' cel-serve-preview
  assert_fails _serve_cgroup_is_ledgered_unit '/user.slice/app.slice/cel-serve-preview-scratch.service' cel-serve-preview
  assert_fails _serve_cgroup_is_ledgered_unit '/user.slice/app.slice/cel-serve-preview.service-extra' cel-serve-preview
}

test_serve_adoption_hides_pids_owned_by_ledgered_servers() {
  local t rows
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl" CEL_SERVE_PROC_DATA=''
  mkdir -p "$CEL_SERVE_STATE"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CEL_SERVE_SYSTEMCTL"
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  printf '%s\n' '{"name":"preview","unit":"cel-serve-preview","owner":"worker","workspace":"alpha"}' > "$CEL_SERVE_STATE/preview.json"
  printf '%s\n' '{"name":"pid-4321","kind":"pid","pid":4321,"pid_start":"fixture"}' > "$CEL_SERVE_STATE/pid-4321.json"
  CEL_SERVE_ADOPT_DATA='[{"pid":4321,"memory_mb":10},{"pid":4322,"memory_mb":20},{"pid":4323,"memory_mb":30}]'
  export CEL_SERVE_ADOPT_DATA
  _serve_pid_in_ledgered_unit() { [ "$1" = 4322 ] && [ "$2" = cel-serve-preview ]; }
  rows="$(serve_adopt_json)"
  assert_eq "$(printf '%s' "$rows" | jq 'length')" "1"
  assert_eq "$(printf '%s' "$rows" | jq -r '.[0].pid')" "4323"
  unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_SERVE_PROC_DATA CEL_SERVE_ADOPT_DATA
  rm -rf "$t"
}

test_serve_explicitly_adopts_then_stops_exact_pid() {
  local t pid token listing expected_memory listed_age
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl" CEL_SERVE_PROC_DATA=''
  mkdir -p "$CEL_SERVE_STATE"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CEL_SERVE_SYSTEMCTL"
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  sleep 60 &
  pid=$!
  token="$(_serve_pid_start "$pid")"
  export CEL_SERVE_ADOPT_DATA
  CEL_SERVE_ADOPT_DATA="$(jq -cn --argjson pid "$pid" --arg token "$token" --arg cwd "$t" \
    '[{pid:$pid,pid_start:$token,port:0,memory_mb:1,age_seconds:1,worktree:$cwd,command:"sleep",managed:false}]')"
  serve_adopt "pid:$pid" worker alpha 3600 0
  assert_eq "$(serve_adopt_json | jq 'length')" "0"
  listing="$(serve_list_json)"
  expected_memory="$(awk '/^VmRSS:/{print int($2/1024)}' "/proc/$pid/status")"
  listed_age="$(printf '%s' "$listing" | jq -r '.[0].age_seconds')"
  serve_stop "$pid"
  wait "$pid" 2>/dev/null || true
  assert_eq "$(printf '%s' "$listing" | jq -r '.[0].memory_mb')" "$expected_memory"
  [ "$listed_age" -ge 1 ]
  [ ! -e "$CEL_SERVE_STATE/pid-$pid.json" ]
  unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_SERVE_PROC_DATA CEL_SERVE_ADOPT_DATA
  rm -rf "$t"
}
test_serve_does_not_reap_adopted_unit_with_unknown_worktree() {
  local t remained=0 stopped=0
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl" CEL_SERVE_PROC_DATA=''
  export CEL_SERVE_ADOPT_DATA='[{"unit":"demo","memory_mb":10,"age_seconds":1,"worktree":"","command":"server"}]'
  export CEL_SERVE_NOW=100 CEL_SERVE_IDLE_SECONDS=3600 CEL_SERVE_PRESSURE_IDLE_SECONDS=3600
  mkdir -p "$CEL_SERVE_STATE"
  printf '#!/usr/bin/env bash\ncase "$*" in *" stop "*) printf "%s\\n" "$*" >> "$CEL_SERVE_STATE/calls";; esac\n' > "$CEL_SERVE_SYSTEMCTL"
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  boxguard_pressure() { return 1; }
  cmd_inbox() { return 0; }
  serve_adopt demo worker alpha 3600 0
  serve_sweep
  [ -f "$CEL_SERVE_STATE/demo.json" ] && remained=1
  [ -f "$CEL_SERVE_STATE/calls" ] && stopped=1
  unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_SERVE_PROC_DATA CEL_SERVE_ADOPT_DATA CEL_SERVE_NOW CEL_SERVE_IDLE_SECONDS CEL_SERVE_PRESSURE_IDLE_SECONDS
  rm -rf "$t"
  [ "$remained" = 1 ] || { echo 'unknown worktree was treated as gone'; return 1; }
  [ "$stopped" = 0 ] || { echo 'unknown worktree unit was stopped'; return 1; }
}


test_serve_reaps_a_ledgered_unit_past_its_ttl() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl"
  mkdir -p "$CEL_SERVE_STATE"
  printf '%s\n' '{"name":"demo","unit":"cel-serve-demo","owner":"worker","workspace":"alpha","worktree":"/gone","started_at":100,"ttl_seconds":60,"last_request_at":0,"port":0}' > "$CEL_SERVE_STATE/demo.json"
  cat > "$CEL_SERVE_SYSTEMCTL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CEL_SERVE_STATE/calls"
EOF
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  CEL_SERVE_NOW=200
  serve_sweep
  assert_contains "$(cat "$CEL_SERVE_STATE/calls")" "stop cel-serve-demo.service"
  [ ! -e "$CEL_SERVE_STATE/demo.json" ]
  unset CEL_SERVE_NOW CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL
  rm -rf "$t"
}

test_serve_record_contains_command_metadata() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl" CEL_SERVE_SYSTEMD_RUN="$t/systemd-run"
  mkdir -p "$CEL_SERVE_STATE"
  cat > "$CEL_SERVE_SYSTEMD_RUN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CEL_SERVE_STATE/start-args"
exit 0
EOF
  chmod +x "$CEL_SERVE_SYSTEMD_RUN"
  CEL_SERVE_NOW=100 CEL_SERVE_WORKTREE="$t/tree"
  mkdir -p "$CEL_SERVE_WORKTREE"
  serve_start demo worker alpha 60 8080 -- sleep 30
  local row
  row="$(cat "$CEL_SERVE_STATE/demo.json")"
  assert_eq "$(printf '%s' "$row" | jq -r .owner)" "worker"
  assert_eq "$(printf '%s' "$row" | jq -r .workspace)" "alpha"
  assert_eq "$(printf '%s' "$row" | jq -r .worktree)" "$CEL_SERVE_WORKTREE"
  assert_eq "$(printf '%s' "$row" | jq -r .port)" "8080"
  assert_contains "$(cat "$CEL_SERVE_STATE/start-args")" "--property=MemoryAccounting=yes"
  unset CEL_SERVE_NOW CEL_SERVE_WORKTREE CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_SERVE_SYSTEMD_RUN
  rm -rf "$t"
}

test_serve_unit_stop_refuses_anything_not_in_ledger() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl"
  mkdir -p "$CEL_SERVE_STATE"
  printf '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$CEL_SERVE_STATE/calls"\n' > "$CEL_SERVE_SYSTEMCTL"
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  if serve_unit_stop cel-serve-unknown; then rm -rf "$t"; return 1; fi
  [ ! -e "$CEL_SERVE_STATE/calls" ]
  unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL
  rm -rf "$t"
}

test_serve_adopts_unit_only_after_explicit_owner_assignment() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl"
  mkdir -p "$CEL_SERVE_STATE"
  cat > "$CEL_SERVE_SYSTEMCTL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CEL_SERVE_STATE/calls"
case "$*" in
  *Description*) printf 'demo preview service\n';;
  *ExecStart*) printf '/opt/demo/start\n';;
  *MainPID*) printf '4321\n';;
esac
EOF
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  CEL_SERVE_PROC_DATA=''
  CEL_SERVE_ADOPT_DATA='[{"unit":"demo-preview","pid":4321,"memory_mb":40,"age_seconds":900,"worktree":"/tmp/demo","command":"serve"}]'
  serve_adopt demo-preview worker alpha 3600 7001
  assert_eq "$(jq -r .owner "$CEL_SERVE_STATE/demo-preview.json")" "worker"
  serve_stop demo-preview
  assert_contains "$(cat "$CEL_SERVE_STATE/calls")" "--user stop demo-preview.service"
  unset CEL_SERVE_PROC_DATA CEL_SERVE_ADOPT_DATA CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL
  rm -rf "$t"
}

# Adopting a UNIT under `set -u` (the CLI's own setting) left `pid` unbound
# and died after the ledger file was half-written.
test_serve_adopts_a_unit_under_set_u() {
  local t; t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl"
  mkdir -p "$CEL_SERVE_STATE"
  printf '#!/usr/bin/env bash\ntrue\n' > "$CEL_SERVE_SYSTEMCTL"; chmod +x "$CEL_SERVE_SYSTEMCTL"
  CEL_SERVE_PROC_DATA=''
  CEL_SERVE_ADOPT_DATA='[{"unit":"demo-preview","pid":4321,"memory_mb":40,"age_seconds":900,"worktree":"/tmp/demo","command":"serve"}]'
  ( set -u; serve_adopt demo-preview worker alpha 3600 7001 ) || { echo "unit adopt failed under set -u"; rm -rf "$t"; return 1; }
  assert_eq "$(jq -r '.kind + " " + (.pid|tostring)' "$CEL_SERVE_STATE/demo-preview.json")" "unit null"
  unset CEL_SERVE_PROC_DATA CEL_SERVE_ADOPT_DATA CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL
  rm -rf "$t"
}

# A listening process is no preview when it is a coding agent, or matches the
# box's serve.ignore list; a plain dev server still is.
test_serve_adoption_skips_agents_and_ignored_tools() {
  local t; t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl" CEL_CONFIG_FILE="$t/config.yaml"
  mkdir -p "$CEL_SERVE_STATE"
  printf '#!/usr/bin/env bash\ntrue\n' > "$CEL_SERVE_SYSTEMCTL"; chmod +x "$CEL_SERVE_SYSTEMCTL"
  printf 'serve:\n  ignore: ".hermes/, ssh-agent"\n' > "$CEL_CONFIG_FILE"
  CEL_SERVE_PROC_DATA=$'1001\t44961\t4096\t60\t/w/p\tomp --auto-approve --hook x\n1002\t0\t4096\t60\t/w\t/usr/bin/node /x/bin/pi --mode rpc\n1003\t0\t4096\t60\t/h\tpython3 -c import /home/u/.hermes/agent serve\n1004\t5173\t4096\t60\t/w/app\tnode node_modules/.bin/vite --port 5173'
  local out; out="$(serve_adopt_json)"
  assert_eq "$(printf '%s' "$out" | jq -c '[.[].pid]')" "[1004]"
  unset CEL_SERVE_PROC_DATA CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_CONFIG_FILE
  rm -rf "$t"
}
test_serve_a_pid_in_a_non_preview_service_is_not_a_candidate() {
  local t; t="$(mktemp -d)"; mkdir -p "$t/proc"
  _serve_not_a_preview_with_cgroup() { # a fake /proc/77/cgroup
    mkdir -p "$t/proc/77"; printf '0::%s\n' "$1" > "$t/proc/77/cgroup"
    CEL_SERVE_PROC_ROOT="$t/proc" _serve_not_a_preview 77 "node server.js"
  }
  _serve_not_a_preview_with_cgroup "/user.slice/user-1000.slice/user@1000.service/app.slice/hermes-gateway.service" \
    || { echo "a pid in hermes-gateway.service was a candidate"; rm -rf "$t"; return 1; }
  ! _serve_not_a_preview_with_cgroup "/user.slice/user-1000.slice/user@1000.service/app.slice/demo-preview.service" \
    || { echo "a pid in a preview service was excluded"; rm -rf "$t"; return 1; }
  ! _serve_not_a_preview_with_cgroup "/user.slice/user-1000.slice/session-4.scope" \
    || { echo "a session process was excluded"; rm -rf "$t"; return 1; }
  # a system service (a CI runner) says nothing about the process inside it
  ! _serve_not_a_preview_with_cgroup "/system.slice/actions.runner.x.service" \
    || { echo "a pid in a system service was excluded"; rm -rf "$t"; return 1; }
  rm -rf "$t"
}
# An agent's name as an ARGUMENT is not an agent: only a script host's
# argv[1] names the program.
test_serve_an_agent_name_as_an_argument_is_still_a_preview() {
  ! _serve_not_a_preview 0 "http-server /home/u/claude -p 8080" || { echo "hid http-server serving ~/claude"; return 1; }
  ! _serve_not_a_preview 0 "vite pi --port 5173" || { echo "hid vite with arg pi"; return 1; }
  _serve_not_a_preview 0 "/usr/bin/node /opt/omp/bin/omp --hook x" || { echo "missed omp under node"; return 1; }
}

test_serve_records_request_activity_for_idle_deadline() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_NOW=500
  mkdir -p "$CEL_SERVE_STATE"
  printf '%s\n' '{"name":"demo","unit":"cel-serve-demo","owner":"worker","workspace":"alpha","worktree":"/tmp","started_at":100,"ttl_seconds":3600,"last_request_at":100}' > "$CEL_SERVE_STATE/demo.json"
  serve_request demo
  assert_eq "$(jq -r .last_request_at "$CEL_SERVE_STATE/demo.json")" "500"
  unset CEL_SERVE_NOW CEL_SERVE_STATE
  rm -rf "$t"
}

test_serve_idle_timeout_stops_but_recent_request_keeps_server() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl" CEL_SERVE_NOW=600 CEL_SERVE_IDLE_SECONDS=3600
  mkdir -p "$CEL_SERVE_STATE" "$t/worktree"
  cat > "$CEL_SERVE_SYSTEMCTL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CEL_SERVE_STATE/calls"
EOF
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  printf '%s\n' "{\"name\":\"demo\",\"unit\":\"cel-serve-demo\",\"owner\":\"worker\",\"workspace\":\"alpha\",\"worktree\":\"$t/worktree\",\"started_at\":100,\"ttl_seconds\":10000,\"last_request_at\":500}" > "$CEL_SERVE_STATE/demo.json"
  serve_sweep
  [ -f "$CEL_SERVE_STATE/demo.json" ] || { rm -rf "$t"; return 1; }
  CEL_SERVE_NOW=4200 serve_sweep
  [ ! -f "$CEL_SERVE_STATE/demo.json" ]
  assert_contains "$(cat "$CEL_SERVE_STATE/calls")" "stop cel-serve-demo.service"
  unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_SERVE_NOW CEL_SERVE_IDLE_SECONDS
  rm -rf "$t"
}

test_serve_gone_worktree_stops_before_ttl() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl" CEL_SERVE_NOW=200
  mkdir -p "$CEL_SERVE_STATE"
  printf '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$CEL_SERVE_STATE/calls"\n' > "$CEL_SERVE_SYSTEMCTL"
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  printf '%s\n' '{"name":"demo","unit":"cel-serve-demo","owner":"worker","workspace":"alpha","worktree":"/nowhere/no-tree","started_at":100,"ttl_seconds":99999,"last_request_at":200}' > "$CEL_SERVE_STATE/demo.json"
  serve_sweep
  [ ! -f "$CEL_SERVE_STATE/demo.json" ]
  unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_SERVE_NOW
  rm -rf "$t"
}
