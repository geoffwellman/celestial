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

# ONLY A LEDGERED SERVER MAY BE STOPPED, so the ledger row exists before the
# unit does: a unit the ledger never heard of can never be stopped by cel. A
# record that cannot be written launches nothing; a launch that fails leaves
# no record behind.
test_serve_start_ledgers_before_it_launches() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl" CEL_SERVE_SYSTEMD_RUN="$t/systemd-run"
  mkdir -p "$CEL_SERVE_STATE" "$t/bin"
  cat > "$CEL_SERVE_SYSTEMD_RUN" <<'EOF'
#!/usr/bin/env bash
if jq -e '.unit == "cel-serve-demo"' "$CEL_SERVE_STATE/demo.json" >/dev/null 2>&1; then
  echo ledgered >> "$CEL_SERVE_STATE/launches"
else
  echo unledgered >> "$CEL_SERVE_STATE/launches"
fi
[ "${SERVE_RUN_FAILS:-0}" = 0 ]
EOF
  chmod +x "$CEL_SERVE_SYSTEMD_RUN"
  CEL_SERVE_NOW=100 CEL_SERVE_WORKTREE="$t"
  # the record is in place when the unit is launched
  serve_start demo worker alpha 60 8080 -- sleep 30
  assert_eq "$(cat "$CEL_SERVE_STATE/launches")" ledgered
  rm -f "$CEL_SERVE_STATE/demo.json" "$CEL_SERVE_STATE/launches"
  # a record that cannot be written launches nothing
  printf '#!/usr/bin/env bash\nexit 1\n' > "$t/bin/jq"; chmod +x "$t/bin/jq"
  if (PATH="$t/bin:$PATH"; serve_start demo worker alpha 60 8080 -- sleep 30) >/dev/null 2>&1; then
    echo "start succeeded without a ledger record"; rm -rf "$t"; return 1
  fi
  [ ! -e "$CEL_SERVE_STATE/launches" ] || { echo "launched $(cat "$CEL_SERVE_STATE/launches") with no ledger record"; rm -rf "$t"; return 1; }
  # a launch that fails leaves no record behind
  if (SERVE_RUN_FAILS=1 serve_start demo worker alpha 60 8080 -- sleep 30) >/dev/null 2>&1; then
    echo "start succeeded when the launch failed"; rm -rf "$t"; return 1
  fi
  [ ! -e "$CEL_SERVE_STATE/demo.json" ] || { echo "a failed launch left its record"; rm -rf "$t"; return 1; }
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

# Adopting a UNIT works under `set -u` (the CLI's own setting): no unbound
# `pid`, no half-written ledger file.
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

# AN AGENT'S VERIFICATION BROWSER IS NOT A PREVIEW. A headless Chrome an agent
# harness drives (omp's broker, pi, claude, opencode) listens on a loopback
# DevTools port, so it used to be reported as an unledgered dev server every
# tick. A Chrome under an agent runtime, or one whose only listener is its
# own --remote-debugging-port, is excluded; a real dev server is reported
# whatever cgroup scope or parent it runs in.
test_serve_agent_harness_browsers_are_not_unledgered_servers() {
  local t out; t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_PROC_ROOT="$t/proc" CEL_SERVE_SYSTEMCTL="$t/systemctl"
  export CEL_CONFIG_FILE="$t/config.yaml" CEL_SERVE_ADOPT_DATA='[]' CEL_SERVE_PROC_DATA=''
  mkdir -p "$CEL_SERVE_STATE" "$CEL_SERVE_PROC_ROOT"
  printf '{}\n' > "$CEL_CONFIG_FILE"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CEL_SERVE_SYSTEMCTL"; chmod +x "$CEL_SERVE_SYSTEMCTL"
  local chrome="/home/u/.omp/puppeteer/chrome/linux-1/chrome-linux64/chrome"
  local scope="/user.slice/user-1000.slice/user@1000.service/app.slice/app-org.chromium.Chromium-%s.scope"
  _serve_fake_proc() { # <pid> <ppid> <port|-> <argv...>; port - means not listening
    local pid="$1" ppid="$2" port="$3" d; shift 3; d="$CEL_SERVE_PROC_ROOT/$pid"
    mkdir -p "$d"
    printf 'Name:\tx\nPPid:\t%s\n' "$ppid" > "$d/status"
    printf '%s\0' "$@" > "$d/cmdline"
    # shellcheck disable=SC2059
    printf "0::$scope\n" "$pid" > "$d/cgroup"
    [ "$port" = - ] || CEL_SERVE_PROC_DATA+="$pid"$'\t'"$port"$'\t4096\t60\t/w/app\t'"$*"$'\n'
  }
  _serve_fake_proc 2000 1 - omp __omp_worker_daemon_broker
  # the broker's headless Chrome on a loopback DevTools port
  _serve_fake_proc 2001 2000 41235 "$chrome" --headless=new --remote-debugging-port=0 --user-data-dir=/tmp/p
  # a Chrome two levels under claude (node script host), no DevTools flag
  _serve_fake_proc 2010 1 - /usr/bin/node /opt/claude/bin/claude
  _serve_fake_proc 2011 2010 - bash -c run
  _serve_fake_proc 2012 2011 9999 /usr/lib/chromium/chromium --headless
  # an orphaned Chrome, agent gone: only its DevTools port listens
  _serve_fake_proc 2020 1 9222 "$chrome" --headless --remote-debugging-port=9222
  # an orphaned Chrome serving something other than DevTools stays reported
  _serve_fake_proc 2021 1 8080 /usr/bin/google-chrome --remote-debugging-port=9223
  # a real dev server inside a Chromium scope, and one an agent started
  _serve_fake_proc 2030 1 5173 node node_modules/.bin/vite --port 5173
  _serve_fake_proc 2031 2000 5174 node node_modules/.bin/vite --port 5174
  out="$(serve_adopt_json)"
  assert_eq "$(printf '%s' "$out" | jq -c '[.[].pid] | sort')" '[2021,2030,2031]'
  unset CEL_SERVE_STATE CEL_SERVE_PROC_ROOT CEL_SERVE_SYSTEMCTL CEL_CONFIG_FILE CEL_SERVE_ADOPT_DATA CEL_SERVE_PROC_DATA
  rm -rf "$t"
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

# A collected unit (the server crashed and CollectMode reaped it) is stopped:
# its record is cleared. A unit that is loaded and will not stop keeps it.
test_serve_stop_of_a_collected_unit_clears_its_record_and_a_stuck_one_keeps_it() {
  local t; t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl"
  mkdir -p "$CEL_SERVE_STATE"
  printf '{"name":"gone","unit":"cel-serve-gone","kind":"unit"}' > "$CEL_SERVE_STATE/gone.json"
  printf '{"name":"stuck","unit":"cel-serve-stuck","kind":"unit"}' > "$CEL_SERVE_STATE/stuck.json"
  cat > "$CEL_SERVE_SYSTEMCTL" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *"stop cel-serve-gone"*) exit 5 ;;
  *"stop cel-serve-stuck"*) exit 1 ;;
  *"LoadState --value cel-serve-gone"*) echo not-found ;;
  *"LoadState --value cel-serve-stuck"*) echo loaded ;;
esac
EOS
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  serve_stop gone || { echo "collected unit read as a failed stop"; rm -rf "$t"; return 1; }
  [ ! -f "$CEL_SERVE_STATE/gone.json" ] || { echo "collected unit's record kept"; rm -rf "$t"; return 1; }
  if serve_stop stuck 2>/dev/null; then echo "a stuck unit read as stopped"; rm -rf "$t"; return 1; fi
  [ -f "$CEL_SERVE_STATE/stuck.json" ] || { echo "stuck unit's record dropped"; rm -rf "$t"; return 1; }
  unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL; rm -rf "$t"
}

test_serve_hermes_desktop_signature_is_not_a_preview() {
  local t pid exe out
  t="$(mktemp -d)"
  export HOME="$t/owner home" CEL_SERVE_STATE="$t/state" CEL_SERVE_PROC_ROOT="$t/proc"
  export CEL_SERVE_SYSTEMCTL="$t/systemctl" CEL_CONFIG_FILE="$t/config.yaml"
  export CEL_SERVE_ADOPT_DATA='[]' CEL_SERVE_PROC_DATA=''
  mkdir -p "$HOME" "$CEL_SERVE_STATE" "$CEL_SERVE_PROC_ROOT"
  printf '{}\n' > "$CEL_CONFIG_FILE"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CEL_SERVE_SYSTEMCTL"
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  _serve_hermes_proc() {
    local pid="$1" exe="$2"; shift 2
    mkdir -p "$CEL_SERVE_PROC_ROOT/$pid"
    ln -s "$exe" "$CEL_SERVE_PROC_ROOT/$pid/exe"
    printf '%s\0' "$@" > "$CEL_SERVE_PROC_ROOT/$pid/cmdline"
    CEL_SERVE_PROC_DATA+="$pid"$'\t5173\t4096\t60\t/tmp/fixture\tpython3 serve\n'
  }
  exe="$HOME/.hermes/tools/python/bin/python3"
  _serve_hermes_proc 5001 "$exe" "$exe" -I -c 'import hermes' serve --ssh-session-token-file "$HOME/.hermes/desktop-ssh/not-opened"
  _serve_hermes_proc 5002 "$exe" "$exe" serve
  _serve_hermes_proc 5003 /usr/bin/python3 python3 serve --ssh-session-token-file /tmp/token
  _serve_hermes_proc 5004 "$HOME/.hermes-other/python3" python3 serve --ssh-session-token-file /tmp/token
  _serve_hermes_proc 5005 "$exe" "$exe" -c 'print("--ssh-session-token-file /tmp/token")'
  _serve_hermes_proc 5006 "$exe" "$exe" serve --ssh-session-token-file=/tmp/token
  _serve_hermes_proc 5007 "$exe" "$exe" serve --ssh-session-token-file
  _serve_hermes_proc 5008 "$exe" "$exe" serve -- --ssh-session-token-file /tmp/token
  _serve_hermes_proc 5009 "$exe" "$exe" serve --ssh-session-token-file /tmp/token
  rm "$CEL_SERVE_PROC_ROOT/5009/cmdline"
  out="$(serve_adopt_json)"
  assert_eq "$(printf '%s' "$out" | jq -c '[.[].pid] | sort')" '[5002,5003,5004,5005,5007,5008,5009]'
  rm -rf "$t"
}

# PERMANENT SERVERS. One persistent user unit, shop-server, behind a fixture
# user manager: its state is a file the test rewrites (`active <pid>` or
# `gone`), every call to it is logged, its pids live in a fixture /proc and
# its memory in a fixture cgroup tree.
_SP_CG=/user.slice/user-1000.slice/user@1000.service/app.slice/shop-server.service
_sp_setup() {
  SP="$(mktemp -d)"
  export CEL_SERVE_STATE="$SP/state" CEL_SERVE_SYSTEMCTL="$SP/systemctl" CEL_SERVE_SYSTEMD_RUN="$SP/systemd-run" \
    CEL_SERVE_PROC_ROOT="$SP/proc" CEL_SERVE_CGROUP_ROOT="$SP/cgroup" CEL_SERVE_PROC_DATA='' CEL_SERVE_ADOPT_DATA='' \
    SP_UNIT="$SP/unit" SP_CALLS="$SP/calls" CEL_SERVE_NOW=1000
  mkdir -p "$CEL_SERVE_STATE" "$SP/proc" "$SP/cgroup$_SP_CG"
  printf '%s\n' 123456789 > "$SP/cgroup$_SP_CG/memory.current"   # 117 MB
  _sp_unit active 3900001
  cat > "$CEL_SERVE_SYSTEMCTL" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SP_CALLS"
read -r st pid < "$SP_UNIT"
case "$*" in
  *list-units*) [ "$st" = active ] && printf 'shop-server.service loaded active running shop live server\n' ;;
  *LoadState*) if [ "$st" = active ]; then printf 'LoadState=loaded\nActiveState=active\n'; else printf 'LoadState=not-found\nActiveState=inactive\n'; fi ;;
  *Description*) printf 'shop live server\n' ;;
  *ExecStart*) printf '{ path=/opt/shop/run ; argv[]=/opt/shop/run }\n' ;;
  *MainPID*) if [ "$st" = active ]; then printf '%s\n' "$pid"; else printf '0\n'; fi ;;
  *"-p Id -p ControlGroup"*)
    for a in "$@"; do
      case "$a" in *.service)
        printf 'Id=%s\n' "$a"
        if [ "$a" = shop-server.service ] && [ "$st" = active ]; then printf 'ControlGroup=%s\n\n' /user.slice/user-1000.slice/user@1000.service/app.slice/shop-server.service; else printf 'ControlGroup=\n\n'; fi ;;
      esac
    done ;;
  *ControlGroup*) [ "$st" != active ] || printf '%s\n' /user.slice/user-1000.slice/user@1000.service/app.slice/shop-server.service ;;
  *WorkingDirectory*) printf '/srv/shop\n' ;;
esac
exit 0
EOS
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/systemd-run-calls"\n' "$SP" > "$CEL_SERVE_SYSTEMD_RUN"
  chmod +x "$CEL_SERVE_SYSTEMCTL" "$CEL_SERVE_SYSTEMD_RUN"
  cmd_inbox() { printf '%s\n' "$*" >> "$SP/inbox"; }
  boxguard_pressure() { return 1; }
}
_sp_unit() { # active <pid> | gone - an active unit's pid sits in its cgroup
  printf '%s %s\n' "$1" "${2:-0}" > "$SP_UNIT"
  if [ "$1" = active ]; then mkdir -p "$SP/proc/$2"; printf '0::%s\n' "$_SP_CG" > "$SP/proc/$2/cgroup"; fi
}
_sp_down() {
  unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_SERVE_SYSTEMD_RUN CEL_SERVE_PROC_ROOT CEL_SERVE_CGROUP_ROOT \
    CEL_SERVE_PROC_DATA CEL_SERVE_ADOPT_DATA SP_UNIT SP_CALLS CEL_SERVE_NOW CEL_SERVE_GONE_GRACE_SECONDS
  rm -rf "$SP"
}
# Anything that would end or (re)start a unit: none of it is a sweep's to do
# to a permanent server.
_sp_acted() { grep -Eq '(^| )(stop|kill|start|restart|reset-failed)( |$)' "$SP_CALLS" 2>/dev/null || [ -e "$SP/systemd-run-calls" ]; }

test_serve_permanent_unit_outlives_any_ttl_idle_or_pressure() {
  _sp_setup
  local f="$CEL_SERVE_STATE/shop-server.json"
  cmd_serve adopt shop-server --owner shop-orch --workspace alpha --permanent --why "the shop's live app" \
    || { echo "permanent adopt refused"; _sp_down; return 1; }
  assert_eq "$(jq -c '[.permanent, .ttl_seconds, .kind, .unit, .owner, .workspace, .why]' "$f")" \
    '[true,null,"unit","shop-server","shop-orch","alpha","the shop'"'"'s live app"]' || { _sp_down; return 1; }
  # a lifetime and a forever are not both
  ( cmd_serve adopt shop-server --owner shop-orch --workspace alpha --permanent --ttl 2h ) >/dev/null 2>&1 \
    && { echo "--permanent took a --ttl"; _sp_down; return 1; }
  # ten years on, never a request, its checkout gone, the box under pressure
  jq '.worktree = "/nowhere/gone"' "$f" > "$f.t" && mv "$f.t" "$f"
  CEL_SERVE_NOW=$((1000 + 315360000)) CEL_SERVE_IDLE_SECONDS=1 serve_sweep
  boxguard_pressure() { return 0; }
  CEL_SERVE_NOW=$((1000 + 315360000)) CEL_SERVE_PRESSURE_IDLE_SECONDS=1 serve_sweep
  [ -f "$f" ] || { echo "the sweep dropped a permanent server"; _sp_down; return 1; }
  _sp_acted && { echo "the sweep acted on a permanent server: $(cat "$SP_CALLS")"; _sp_down; return 1; }
  [ ! -s "$SP/inbox" ] || { echo "the sweep mailed about a live permanent server: $(cat "$SP/inbox")"; _sp_down; return 1; }
  _sp_down
}

test_serve_permanent_server_is_listed_with_owner_port_memory() {
  _sp_setup
  cmd_serve adopt shop-server --owner shop-orch --workspace alpha --permanent --port 8090 >/dev/null || { _sp_down; return 1; }
  assert_eq "$(serve_list_json | jq -c '.[0] | [.name, .owner, .workspace, .port, .memory_mb, .permanent]')" \
    '["shop-server","shop-orch","alpha",8090,117,true]' || { _sp_down; return 1; }
  local out; out="$(cmd_serve list)"
  assert_contains "$out" "shop-server" || { _sp_down; return 1; }
  assert_contains "$out" "permanent" || { _sp_down; return 1; }
  _sp_down
}

# The steward reported it every tick as unledgered; registered, neither the
# unit nor a pid of it is - not even a new pid after the unit was recreated.
test_serve_unledgered_report_skips_a_registered_permanent_unit() {
  _sp_setup
  registry_names() { printf 'alpha\n'; }
  registry_path() { printf '%s/alpha' "$SP"; }
  ws_product_names() { printf 'shop\n'; }
  CEL_SERVE_PROC_DATA=$'3900001\t8090\t4096\t60\t/srv/shop\tnode server.js'
  assert_contains "$(serve_adopt_json | jq -r '.[].unit // empty')" "shop-server" || { _sp_down; return 1; }
  serve_adopt shop-server shop-orch alpha permanent "" "" || { _sp_down; return 1; }
  _sp_unit active 3900002
  CEL_SERVE_PROC_DATA=$'3900002\t8090\t4096\t60\t/srv/shop\tnode server.js'
  assert_eq "$(serve_adopt_json | jq -c .)" "[]" || { _sp_down; return 1; }
  _serve_unledgered_report >/dev/null 2>&1
  [ ! -s "$SP/inbox" ] || { echo "reported a registered unit: $(cat "$SP/inbox")"; _sp_down; return 1; }
  _sp_down
}

# Only its owner, or a person, ends it: another agent cannot, nor one that
# shed its role to look like a person.
test_serve_permanent_stops_only_for_its_owner_or_a_person() {
  _sp_setup
  local P="$SP/launch" f="$CEL_SERVE_STATE/shop-server.json" out
  _sp_launch() { mkdir -p "$P/$PPID"; printf '%s\0' "$@" > "$P/$PPID/environ"; printf '%s (bash) S 1 1 1' "$PPID" > "$P/$PPID/stat"; }
  serve_adopt shop-server shop-orch alpha permanent 0 "" || { _sp_down; return 1; }
  _sp_launch CEL_ROLE=solo CEL_INBOX_ME=tools-orch
  out="$(CEL_PROC_DIR="$P" CEL_ROLE=solo CEL_INBOX_ME=tools-orch serve_stop shop-server 2>&1)" \
    && { echo "another agent stopped it"; _sp_down; return 1; }
  assert_contains "$out" "only its owner or a person" || { _sp_down; return 1; }
  out="$(CEL_PROC_DIR="$P" CEL_INBOX_ME=shop-orch serve_stop shop-server 2>&1)" \
    && { echo "an agent that shed CEL_ROLE stopped it"; _sp_down; return 1; }
  [ -f "$f" ] || { echo "a refused stop dropped the record"; _sp_down; return 1; }
  _sp_acted && { echo "a refused stop acted: $(cat "$SP_CALLS")"; _sp_down; return 1; }
  _sp_launch CEL_ROLE=solo CEL_INBOX_ME=shop-orch
  ( CEL_PROC_DIR="$P" CEL_ROLE=solo CEL_INBOX_ME=shop-orch serve_stop shop-server ) || { echo "its owner was refused"; _sp_down; return 1; }
  [ ! -f "$f" ] || { echo "its owner's stop kept the record"; _sp_down; return 1; }
  assert_contains "$(cat "$SP_CALLS")" "stop shop-server.service" || { _sp_down; return 1; }
  # a person: no agent launch anywhere above
  serve_adopt shop-server shop-orch alpha permanent 0 "" || { _sp_down; return 1; }
  printf 'HOME=/h\0' > "$P/$PPID/environ"
  ( CEL_PROC_DIR="$P" serve_stop shop-server ) || { echo "a person was refused"; _sp_down; return 1; }
  [ ! -f "$f" ] || { echo "a person's stop kept the record"; _sp_down; return 1; }
  _sp_down
}

# Gone - unit collected or never coming back, pid exited - is dropped from the
# registry with one note to its owner, and nothing is restarted. A unit is
# gone only once it has stayed gone past the re-creation window.
test_serve_a_vanished_permanent_server_is_dropped_with_one_note_never_restarted() {
  _sp_setup
  export CEL_SERVE_GONE_GRACE_SECONDS=900
  local f="$CEL_SERVE_STATE/shop-server.json"
  serve_adopt shop-server shop-orch alpha permanent 0 "" || { _sp_down; return 1; }
  _sp_unit gone
  serve_sweep
  [ -f "$f" ] || { echo "dropped inside the re-creation window"; _sp_down; return 1; }
  CEL_SERVE_NOW=1950 serve_sweep
  [ ! -f "$f" ] || { echo "a unit gone past the window stayed registered"; _sp_down; return 1; }
  CEL_SERVE_NOW=2900 serve_sweep
  assert_eq "$(grep -c . "$SP/inbox")" 1 || { _sp_down; return 1; }
  assert_contains "$(cat "$SP/inbox")" "send shop-orch" || { _sp_down; return 1; }
  _sp_acted && { echo "a vanished server was acted on: $(cat "$SP_CALLS")"; _sp_down; return 1; }
  # a permanent pid that exited goes at once: a pid never comes back
  local pid; sleep 60 & pid=$!
  CEL_SERVE_ADOPT_DATA="$(jq -cn --argjson pid "$pid" --arg s "$(_serve_pid_start "$pid")" \
    '[{pid:$pid,pid_start:$s,port:0,memory_mb:1,age_seconds:1,worktree:"/srv",command:"sleep",managed:false}]')"
  serve_adopt "$pid" shop-orch alpha permanent 0 "" || { kill "$pid"; _sp_down; return 1; }
  assert_eq "$(jq -r .kind "$CEL_SERVE_STATE/pid-$pid.json")" pid || { kill "$pid"; _sp_down; return 1; }
  kill "$pid"; wait "$pid" 2>/dev/null || true
  CEL_SERVE_ADOPT_DATA='' serve_sweep
  [ ! -f "$CEL_SERVE_STATE/pid-$pid.json" ] || { echo "an exited permanent pid stayed registered"; _sp_down; return 1; }
  assert_eq "$(grep -c . "$SP/inbox")" 2 || { _sp_down; return 1; }
  _sp_down
}

# systemd recreating the unit under its name (a follow-main redeploy) is the
# same server: a new pid, a moment of absence, and the registration stays.
test_serve_a_unit_recreated_under_its_name_stays_registered() {
  _sp_setup
  export CEL_SERVE_GONE_GRACE_SECONDS=900
  local f="$CEL_SERVE_STATE/shop-server.json"
  serve_adopt shop-server shop-orch alpha permanent 0 "" || { _sp_down; return 1; }
  serve_sweep
  _sp_unit gone; CEL_SERVE_NOW=1300 serve_sweep
  _sp_unit active 3900002; CEL_SERVE_NOW=1600 serve_sweep
  CEL_SERVE_NOW=99999 serve_sweep
  [ -f "$f" ] || { echo "a recreated unit lost its registration"; _sp_down; return 1; }
  assert_eq "$(jq -r '[.unit, has("gone_since")] | @tsv' "$f")" "$(printf 'shop-server\tfalse')" || { _sp_down; return 1; }
  [ ! -s "$SP/inbox" ] || { echo "mailed about a recreated unit: $(cat "$SP/inbox")"; _sp_down; return 1; }
  CEL_SERVE_PROC_DATA=$'3900002\t8090\t4096\t60\t/srv/shop\tnode server.js'
  assert_eq "$(serve_adopt_json | jq -c .)" "[]" || { _sp_down; return 1; }
  _sp_down
}

# A pid inside a user service is that unit's: adopted permanently, the unit is
# what is registered, so its next pid is still the registered server.
test_serve_adopting_a_units_pid_permanently_registers_the_unit() {
  _sp_setup
  CEL_SERVE_PROC_DATA=$'3900001\t8090\t4096\t60\t/srv/shop\tnode server.js'
  serve_adopt 3900001 shop-orch alpha permanent "" "" || { _sp_down; return 1; }
  assert_eq "$(jq -r '[.kind, .unit, .permanent] | @tsv' "$CEL_SERVE_STATE/shop-server.json")" "$(printf 'unit\tshop-server\ttrue')" \
    || { _sp_down; return 1; }
  [ ! -e "$CEL_SERVE_STATE/pid-3900001.json" ] || { echo "registered the pid"; _sp_down; return 1; }
  _sp_down
}

# WHO MAY SHIELD A SERVER. A permanent registration is undone only by its
# owner or a person, so an agent registers only for itself - the alias its
# launch fixed - never for another owner, nor with its role shed. A person may
# register one for anyone. A unit already registered is not re-registered to
# someone else.
test_serve_permanent_adopt_by_an_agent_is_only_for_itself() {
  _sp_setup
  local P="$SP/launch" f="$CEL_SERVE_STATE/shop-server.json" out
  _sp_launch() { mkdir -p "$P/$PPID"; printf '%s\0' "$@" > "$P/$PPID/environ"; printf '%s (bash) S 1 1 1' "$PPID" > "$P/$PPID/stat"; }
  _sp_launch CEL_ROLE=solo CEL_INBOX_ME=tools-orch
  out="$(CEL_PROC_DIR="$P" CEL_ROLE=solo CEL_INBOX_ME=tools-orch serve_adopt shop-server shop-orch alpha permanent "" "" 2>&1)" \
    && { echo "an agent registered a server for another owner"; _sp_down; return 1; }
  assert_contains "$out" "only for itself" || { _sp_down; return 1; }
  out="$(CEL_PROC_DIR="$P" CEL_INBOX_ME=tools-orch serve_adopt shop-server tools-orch alpha permanent "" "" 2>&1)" \
    && { echo "an agent that shed CEL_ROLE registered a server"; _sp_down; return 1; }
  [ ! -e "$f" ] || { echo "a refused adopt left a record"; _sp_down; return 1; }
  # for itself, it may
  ( CEL_PROC_DIR="$P" CEL_ROLE=solo CEL_INBOX_ME=tools-orch serve_adopt shop-server tools-orch alpha permanent "" "" ) \
    || { echo "an agent was refused its own registration"; _sp_down; return 1; }
  assert_eq "$(jq -r .owner "$f")" tools-orch || { _sp_down; return 1; }
  # registered to tools-orch, it is not re-registered to anyone else - not even by a person
  printf 'HOME=/h\0' > "$P/$PPID/environ"
  out="$(CEL_PROC_DIR="$P" serve_adopt shop-server shop-orch alpha permanent "" "" 2>&1)" \
    && { echo "re-registered under another owner"; _sp_down; return 1; }
  assert_contains "$out" "registered to tools-orch" || { _sp_down; return 1; }
  assert_eq "$(jq -r .owner "$f")" tools-orch || { _sp_down; return 1; }
  _sp_down
}
test_serve_a_person_registers_a_permanent_server_for_anyone_and_sees_what_it_runs() {
  _sp_setup
  local P="$SP/launch" f="$CEL_SERVE_STATE/shop-server.json"
  mkdir -p "$P/$PPID"; printf 'HOME=/h\0' > "$P/$PPID/environ"; printf '%s (bash) S 1 1 1' "$PPID" > "$P/$PPID/stat"
  ( CEL_PROC_DIR="$P" serve_adopt shop-server shop-orch alpha permanent 8090 "" ) || { echo "a person was refused"; _sp_down; return 1; }
  assert_eq "$(jq -r '[.owner, .working_directory, .command] | @tsv' "$f")" \
    "$(printf 'shop-orch\t/srv/shop\t{ path=/opt/shop/run ; argv[]=/opt/shop/run }')" || { _sp_down; return 1; }
  local out; out="$(cmd_serve list)"
  assert_contains "$out" "/srv/shop" || { _sp_down; return 1; }
  assert_contains "$out" "/opt/shop/run" || { _sp_down; return 1; }
  _sp_down
}
