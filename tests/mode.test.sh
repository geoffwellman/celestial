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
# The data must be the original with exactly one key set.
_data_is_orig_plus() { # <section> <name> <mode>
  [ "$(yq -cS --arg k "$1" --arg n "$2" --arg m "$3" '(.[$k][] | select(.name == $n)).mode = $m' "$ORIG")" \
    = "$(yq -cS . "$T/workspace.yaml")" ]
}

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
  _data_is_orig_plus products bundle solo || { rm -rf "$T"; return 1; }
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

# The shapes a hand-kept file actually takes: a quoted name with a comment on
# its line, a blank and a comment line inside the item, an existing `mode:`
# with its own comment, a `mode:` nested under another key, the item last in
# the file and no final newline.
test_mode_edits_only_its_own_line_in_a_hand_kept_file() {
  _mws
  printf '%s\n' 'name: hand' 'kind: work' 'products:' \
    '  - name: "bundle"   # the big one' '    repos: [widget, gadget]' '' \
    '    # a note inside the item' '    preview: { mode: static }' \
    '    mode: fleet  # flipped by cel mode' 'repos:' \
    '  - { name: widget, url: x, prefix: WG, gate: t }' '  - name: gadget' '    url: x' \
    '  - name: lone' '    url: x' > "$T/workspace.yaml"
  printf '    prefix: OT' >> "$T/workspace.yaml"
  cp "$T/workspace.yaml" "$ORIG"
  _mode_write "$T" bundle solo || { echo "refused"; rm -rf "$T"; return 1; }
  assert_eq "$(_changed_lines)" 2   # one line out, one line in
  grep -qx '    mode: solo  # flipped by cel mode' "$T/workspace.yaml" || { cat "$T/workspace.yaml"; rm -rf "$T"; return 1; }
  _data_is_orig_plus products bundle solo || { rm -rf "$T"; return 1; }
  # the last item, in a file with no final newline, keeps having none
  cp "$T/workspace.yaml" "$ORIG"
  _mode_write "$T" lone solo || { rm -rf "$T"; return 1; }
  [ -n "$(tail -c1 "$T/workspace.yaml")" ] || { echo "gained a final newline"; rm -rf "$T"; return 1; }
  _data_is_orig_plus repos lone solo || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# `products:\n- name: a` - the style python-yaml writes - is a list, not a run
# of top-level keys.
test_mode_edits_an_unindented_sequence() {
  _mws
  printf '%s\n' 'name: flat' 'products:' '- name: bundle' '  repos: [widget, gadget]' \
    'repos:' '- name: widget' '  url: x' '- name: gadget' '  url: x' > "$T/workspace.yaml"
  cp "$T/workspace.yaml" "$ORIG"
  _mode_write "$T" bundle solo || { echo "refused"; rm -rf "$T"; return 1; }
  assert_eq "$(sed -n 4p "$T/workspace.yaml")" "  mode: solo"
  _data_is_orig_plus products bundle solo || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A symlinked workspace.yaml stays a symlink; the file it names is edited.
test_mode_writes_through_a_symlink() {
  _mws
  mv "$T/workspace.yaml" "$T/real.yaml"; ln -s real.yaml "$T/workspace.yaml"
  ( cd "$T" && cmd_mode bundle solo --no-restart ) >/dev/null
  [ -L "$T/workspace.yaml" ] || { echo "the link was replaced"; rm -rf "$T"; return 1; }
  assert_eq "$(ws_build_mode "$T" bundle)" solo
  rm -rf "$T"
}

# A flow-style item cannot be edited as one line; it is refused, untouched.
test_mode_refuses_a_flow_style_entry_and_leaves_the_file_alone() {
  _mws
  sed -i 's/^  - name: lone$/  - { name: lone, url: x, prefix: OT, gate: t }/' "$T/workspace.yaml"
  awk '/name: lone, url/ {print; skip=3; next} skip>0 {skip--; next} {print}' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  cp "$T/workspace.yaml" "$ORIG"
  local out; out="$( cd "$T" && _cmd_mode_in_subshell lone solo --no-restart 2>&1 )" && { rm -rf "$T"; return 1; }
  assert_contains "$out" "flow-style"
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

# --- the restart -------------------------------------------------------------
_mode_stub_roster() { # <cwd> <name> <status>
  mkdir -p "$T/bin"
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent list") printf '%s\n' '{"result":{"agents":[{"name":"$2","agent_status":"$3","pane_id":"wQ:p1","cwd":"$1"}]}}' ;;
  *) printf '{}\n' ;;
esac
EOF
  chmod +x "$T/bin/herdr"; PATH="$T/bin:$PATH"
}
_rec() { printf '%s\n' "$*" >> "$T/launched"; }

# LANES. Back to fleet is refused while a lane is live; a lane's restart
# waiter watches and relaunches the lane, never the main agent.
test_mode_refuses_fleet_while_a_lane_is_live() {
  _mws
  ( cd "$T" && cmd_mode bundle solo --no-restart ) >/dev/null
  _mode_stub_roster "$T/.cel/solo/bundle/lane-ui" bundle-ui idle
  local out; out="$( cd "$T" && _cmd_mode_in_subshell bundle fleet 2>&1 )" \
    && { echo "switched to fleet over a live lane"; rm -rf "$T"; return 1; }
  assert_contains "$out" "bundle-ui"
  assert_eq "$(ws_build_mode "$T" bundle)" solo
  rm -rf "$T"
}
test_mode_lane_waiter_relaunches_the_lane() {
  _mws
  _mode_stub_roster "$T/.cel/solo/bundle/lane-ui" bundle-ui idle
  cmd_run() { printf '%s\n' "$*" >> "$T/calls"; }
  CEL_MODE_POLL_SECS=0 _mode_restart_when_idle "$T" bundle ui >/dev/null
  assert_eq "$(cat "$T/calls")" "solo --product bundle --lane ui --restart"
  ( cd "$T" && CEL_MODE_LAUNCH=_rec _mode_schedule_restart "$T" bundle ui )
  assert_contains "$(cat "$T/launched")" "mode --restart-when-idle bundle --lane ui --workspace"
  rm -rf "$T"
}
# Lane `ui` of `bundle` and the main agent of a product named `bundle-ui`
# never share a restart unit or lock.
test_mode_lane_restart_keys_differ_from_a_lookalike_product() {
  _mws
  local units="$T/units"
  _mode_detach() { printf '%s\n' "$1" >> "$units"; }
  _mode_schedule_restart "$T" bundle ui; _mode_schedule_restart "$T" bundle-ui
  [ "$(sort -u "$units" | wc -l)" -eq 2 ] || { echo "one unit for both: $(cat "$units")"; rm -rf "$T"; return 1; }
  _mode_when_quiet() { printf '%s\n' "$1" >> "$T/locks"; }
  _mode_restart_when_idle "$T" bundle ui; _mode_restart_when_idle "$T" bundle-ui
  [ "$(sort -u "$T/locks" | wc -l)" -eq 2 ] || { echo "one lock for both: $(cat "$T/locks")"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A lane pane whose directory was deleted does not hold the product in solo.
test_mode_a_deleted_lane_does_not_block_fleet() {
  _mws
  ( cd "$T" && cmd_mode bundle solo --no-restart ) >/dev/null
  _mode_stub_roster "$T/.cel/solo/bundle/lane-ui (deleted)" bundle-ui idle
  ( cd "$T" && cmd_mode bundle fleet --no-restart ) >/dev/null 2>&1
  assert_eq "$(ws_build_mode "$T" bundle)" fleet
  rm -rf "$T"
}
# A lane's mailbox is not <product>-orch: the launch's CEL_PRODUCT names it.
test_mode_product_comes_from_the_launch_for_a_lane() {
  _mws
  assert_eq "$(cd /tmp && CEL_PRODUCT=bundle CEL_INBOX_ME=bundle-ui CEL_INBOX_WS='' _mode_product "$T")" bundle
  rm -rf "$T"
}

# The product's own agent is restarted - scheduled, never inline, so the agent
# that ran `cel mode` is not killed mid-turn - and only when asked.
test_mode_schedules_a_restart_for_the_product_agent_only_when_asked() {
  _mws; _mode_stub_roster "$T/products/bundle" bundle-orch working
  ( cd "$T" && cmd_mode bundle solo --no-restart ) >/dev/null
  [ ! -s "$T/launched" ] || { echo "restarted despite --no-restart"; rm -rf "$T"; return 1; }
  ( cd "$T" && CEL_MODE_LAUNCH=_rec cmd_mode bundle fleet ) >/dev/null
  assert_contains "$(cat "$T/launched")" "mode --restart-when-idle bundle"
  rm -rf "$T"
}
# Somebody else's pane standing in the directory is not the product's agent.
test_mode_does_not_restart_another_agent_in_the_product_dir() {
  _mws; _mode_stub_roster "$T/products/bundle" someones-shell idle
  local out; out="$( cd "$T" && CEL_MODE_LAUNCH=_rec cmd_mode bundle solo )"
  [ ! -s "$T/launched" ] || { echo "scheduled a restart of someone else's pane"; rm -rf "$T"; return 1; }
  assert_contains "$out" "not live"
  rm -rf "$T"
}

# The waiter: two idle/done polls in a row, never through a turn or a
# pending approval, and the relaunch never forces.
test_mode_waiter_restarts_after_two_quiet_polls_without_force() {
  _mws
  local seq="$T/statuses"
  printf 'working\nidle\nworking\nidle\ndone\n' > "$seq"
  _mode_agent_status() { local s; s="$(head -1 "$seq")"; sed -i 1d "$seq"; printf '%s' "$s"; }
  cmd_run() { printf '%s\n' "$*" >> "$T/calls"; }
  CEL_MODE_POLL_SECS=0 _mode_restart_when_idle "$T" bundle >/dev/null
  assert_eq "$(cat "$T/calls")" "orchestrator --product bundle --restart"
  assert_eq "$(wc -l < "$seq" | tr -d ' ')" 0
  rm -rf "$T"
}
test_mode_waiter_never_restarts_a_blocked_agent() {
  _mws
  _mode_agent_status() { printf blocked; }
  cmd_run() { echo restarted >> "$T/calls"; }
  ! CEL_MODE_POLL_SECS=1 CEL_MODE_WAIT_SECS=3 _mode_restart_when_idle "$T" bundle >/dev/null 2>&1 \
    || { echo "waiter reported success over a blocked agent"; rm -rf "$T"; return 1; }
  [ ! -s "$T/calls" ] || { echo "restarted over a pending approval"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# herdr not answering is not "the agent is gone": ask again, decide nothing.
test_mode_waiter_treats_an_unreadable_roster_as_no_answer() {
  _mws
  local seq="$T/rcs"; printf '2\n2\n0\n0\n' > "$seq"
  _mode_agent_status() { local r; r="$(head -1 "$seq")"; sed -i 1d "$seq"; printf idle; return "$r"; }
  cmd_run() { echo restarted >> "$T/calls"; }
  CEL_MODE_POLL_SECS=0 _mode_restart_when_idle "$T" bundle >/dev/null
  assert_eq "$(cat "$T/calls")" restarted
  rm -rf "$T"
}
test_mode_waiter_gives_up_when_the_agent_is_gone() {
  _mws
  _mode_agent_status() { return 1; }
  cmd_run() { echo restarted >> "$T/calls"; }
  CEL_MODE_POLL_SECS=0 _mode_restart_when_idle "$T" bundle >/dev/null 2>&1
  [ ! -s "$T/calls" ] || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# One pending restart per product: a second waiter steps aside.
test_mode_waiter_steps_aside_for_a_pending_one() {
  _mws
  exec 7>"$T/.cel/mode-restart-bundle.lock"; flock -n 7
  _mode_agent_status() { printf idle; }
  cmd_run() { echo restarted >> "$T/calls"; }
  CEL_MODE_POLL_SECS=0 _mode_restart_when_idle "$T" bundle >/dev/null 2>&1
  exec 7>&-
  [ ! -s "$T/calls" ] || { echo "two waiters both restarted"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
