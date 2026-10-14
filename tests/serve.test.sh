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
if [ "$1" = list-units ]; then printf 'cel-serve-demo.service\n'; fi
EOF
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  CEL_SERVE_ADOPT_DATA='[]' CEL_SERVE_PROC_DATA=$'4321\t8080\t4096\t60\t/tmp/demo\tvite --port 8080'
  local out
  out="$(serve_adopt_json)"
  assert_contains "$out" '"pid":4321'
  assert_contains "$out" '"managed":false'
  assert_eq "$(cat "$CEL_SERVE_STATE/calls")" "list-units --type=service --state=running --plain --no-legend"
  unset CEL_SERVE_ADOPT_DATA CEL_SERVE_PROC_DATA CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL
  rm -rf "$t"
}

test_serve_stop_refuses_unledgered_pid() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state"
  mkdir -p "$CEL_SERVE_STATE"
  if serve_stop 4321 >/dev/null 2>&1; then
    rm -rf "$t"; return 1
  fi
  rm -rf "$t"
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
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl"
  mkdir -p "$CEL_SERVE_STATE"
  cat > "$CEL_SERVE_SYSTEMCTL" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  start) exit 0 ;;
  show) printf '/sys/fs/cgroup/cel-serve-demo.service\n' ;;
esac
EOF
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  CEL_SERVE_NOW=100 CEL_SERVE_WORKTREE="$t/tree"
  mkdir -p "$CEL_SERVE_WORKTREE"
  serve_start demo worker alpha 60 8080 -- sleep 30
  local row
  row="$(cat "$CEL_SERVE_STATE/demo.json")"
  assert_contains "$row" '"owner":"worker"'
  assert_contains "$row" '"workspace":"alpha"'
  assert_contains "$row" "\"worktree\":\"$CEL_SERVE_WORKTREE\""
  assert_contains "$row" '"port":8080'
  unset CEL_SERVE_NOW CEL_SERVE_WORKTREE CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL
  rm -rf "$t"
}
