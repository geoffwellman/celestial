# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/mode.sh"

# `bundle` is declared over widget+gadget; `lone` is an implicit product (its
# own repo). The fixture carries comments and flow-style maps on purpose: the
# owner's file must come back exactly as written, plus one line.
_mws() {
  T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-products/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget" "$T/repos/gadget" "$T/repos/lone" "$T/.cel"
  ORIG="$T/orig.yaml"; cp "$T/workspace.yaml" "$ORIG"
}
_cmd_mode_in_subshell() { ( cmd_mode "$@" ); }
_changed_lines() { diff "$ORIG" "$T/workspace.yaml" | grep -c '^[<>]'; }

test_mode_defaults_to_fleet_for_declared_and_implicit_products() {
  _mws
  assert_eq "$(ws_build_mode "$T" bundle)" fleet
  assert_eq "$(ws_build_mode "$T" lone)" fleet
  rm -rf "$T"
}

test_mode_switch_is_one_added_line_and_reads_back() {
  _mws
  ( cd "$T" && cmd_mode bundle solo --no-restart ) >/dev/null
  assert_eq "$(ws_build_mode "$T" bundle)" solo
  assert_eq "$(ws_build_mode "$T" lone)" fleet
  assert_eq "$(_changed_lines)" 1
  # every comment line of the original survives verbatim
  assert_eq "$(grep -c '^ *#' "$T/workspace.yaml")" "$(grep -c '^ *#' "$ORIG")"
  rm -rf "$T"
}

test_mode_switch_back_replaces_the_same_line() {
  _mws
  ( cd "$T" && cmd_mode bundle solo --no-restart && cmd_mode bundle fleet --no-restart ) >/dev/null
  assert_eq "$(ws_build_mode "$T" bundle)" fleet
  assert_eq "$(_changed_lines)" 1
  assert_eq "$(grep -c 'mode: ' "$T/workspace.yaml")" 1
  rm -rf "$T"
}

test_mode_on_an_implicit_product_writes_its_repo_entry() {
  _mws
  ( cd "$T" && cmd_mode lone solo --no-restart ) >/dev/null
  assert_eq "$(yq -r '.repos[] | select(.name == "lone") | .mode' "$T/workspace.yaml")" solo
  assert_eq "$(ws_build_mode "$T" bundle)" fleet
  rm -rf "$T"
}

# A flow-style item cannot be edited as one line; it is refused, untouched.
test_mode_refuses_a_flow_style_entry_and_leaves_the_file_alone() {
  _mws
  sed -i 's/^  - name: lone$/  - { name: lone, url: x, prefix: OT, gate: t }/' "$T/workspace.yaml"
  awk '/name: lone, url/ {print; skip=3; next} skip>0 {skip--; next} {print}' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  cp "$T/workspace.yaml" "$ORIG"
  ( cd "$T" && assert_fails _cmd_mode_in_subshell lone solo --no-restart )
  assert_eq "$(_changed_lines)" 0
  rm -rf "$T"
}

# Fleet work still in flight has nobody to land it once the product is solo.
test_mode_refuses_solo_while_fleet_work_is_in_flight() {
  _mws
  printf '[{"id":"WG-1-x","repo":"widget","state":"finished"},{"id":"OT-2-y","repo":"lone","state":"released"}]' \
    > "$T/.cel/delegations.json"
  local out; out="$( cd "$T" && _cmd_mode_in_subshell bundle solo --no-restart 2>&1 )" && { echo "switched"; rm -rf "$T"; return 1; }
  assert_contains "$out" "WG-1-x finished"
  assert_eq "$(ws_build_mode "$T" bundle)" fleet
  # a released row on another product blocks nothing
  ( cd "$T" && cmd_mode lone solo --no-restart ) >/dev/null
  assert_eq "$(ws_build_mode "$T" lone)" solo
  rm -rf "$T"
}

test_mode_rejects_an_unknown_product() {
  _mws; ( cd "$T" && assert_fails _cmd_mode_in_subshell nosuch solo --no-restart ); rm -rf "$T"
}

# A live agent is restarted into its new role - scheduled, never inline, so the
# agent that ran `cel mode` is not killed mid-turn.
_mode_stub_roster() { # <cwd> <status>
  mkdir -p "$T/bin"
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent list") printf '%s\n' '{"result":{"agents":[{"name":"bundle-orch","agent_status":"$2","pane_id":"wQ:p1","cwd":"$1"}]}}' ;;
  *) printf '{}\n' ;;
esac
EOF
  chmod +x "$T/bin/herdr"; PATH="$T/bin:$PATH"
}
test_mode_schedules_a_restart_for_a_live_agent_only_when_asked() {
  _mws; _mode_stub_roster "$T/products/bundle" working
  local rec="$T/launched"
  _rec() { printf '%s\n' "$*" >> "$rec"; }
  CEL_MODE_LAUNCH=_rec; export -f _rec; export rec
  ( cd "$T" && cmd_mode bundle solo --no-restart ) >/dev/null
  [ ! -s "$rec" ] || { echo "restarted despite --no-restart"; rm -rf "$T"; return 1; }
  ( cd "$T" && CEL_MODE_LAUNCH=_rec cmd_mode bundle fleet ) >/dev/null
  assert_contains "$(cat "$rec")" "mode --restart-when-idle bundle"
  rm -rf "$T"
}

# The waiter restarts only after two quiet polls, and never over a turn.
test_mode_waiter_restarts_after_two_quiet_polls() {
  _mws
  local seq="$T/statuses" calls="$T/calls"
  printf 'working\nidle\nworking\nidle\nidle\n' > "$seq"
  _run_live_agent_in_cwd() { local s; s="$(head -1 "$seq")"; sed -i 1d "$seq"; printf 'bundle-orch\twQ:p1\t%s\n' "$s"; }
  cmd_run() { printf '%s\n' "$*" >> "$calls"; }
  CEL_MODE_POLL_SECS=0 _mode_restart_when_idle "$T" bundle >/dev/null
  assert_eq "$(cat "$calls")" "orchestrator --product bundle --restart"
  assert_eq "$(wc -l < "$seq" | tr -d ' ')" 0
  rm -rf "$T"
}
test_mode_waiter_gives_up_when_the_agent_is_gone() {
  _mws
  _run_live_agent_in_cwd() { :; }
  cmd_run() { echo "should not run"; return 1; }
  CEL_MODE_POLL_SECS=0 _mode_restart_when_idle "$T" bundle >/dev/null
  rm -rf "$T"
}
