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
# Both products still set to the retired `mode: fleet`, the one state left
# that `cel mode <p> solo` has to write over.
_mws_legacy() {
  _mws
  _mode_write "$T" bundle fleet && _mode_write "$T" lone fleet || return 1
  cp "$T/workspace.yaml" "$ORIG"
}
_cmd_mode_in_subshell() { ( cmd_mode "$@" ); }
_changed_lines() { diff "$ORIG" "$T/workspace.yaml" | grep -c '^[<>]'; }
# The data must be the original with exactly one key set.
_data_is_orig_plus() { # <section> <name> <mode>
  [ "$(yq -cS --arg k "$1" --arg n "$2" --arg m "$3" '(.[$k][] | select(.name == $n)).mode = $m' "$ORIG")" \
    = "$(yq -cS . "$T/workspace.yaml")" ]
}

test_mode_defaults_to_solo_for_declared_and_implicit_products() {
  _mws
  assert_eq "$(ws_build_mode "$T" bundle)" solo
  assert_eq "$(ws_build_mode "$T" lone)" solo
  assert_eq "$(cd "$T" && cmd_mode bundle)" "bundle: solo"
  rm -rf "$T"
}

# A product that already reads solo is left alone: nothing is written.
test_mode_solo_on_a_solo_product_writes_nothing() {
  _mws
  local out; out="$( cd "$T" && cmd_mode bundle solo --no-restart 2>&1 )"
  assert_contains "$out" "already solo"
  assert_eq "$(_changed_lines)" 0
  rm -rf "$T"
}

test_mode_switch_from_legacy_fleet_replaces_the_line_and_reads_back() {
  _mws_legacy
  assert_eq "$(ws_build_mode "$T" bundle)" fleet
  ( cd "$T" && cmd_mode bundle solo --no-restart ) >/dev/null
  assert_eq "$(ws_build_mode "$T" bundle)" solo
  assert_eq "$(ws_build_mode "$T" lone)" fleet
  assert_eq "$(_changed_lines)" 2   # one line out, one line in
  _data_is_orig_plus products bundle solo || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Fleet was retired: asking for it is refused and writes nothing, whatever
# the product reads now.
test_mode_fleet_is_refused_and_writes_nothing() {
  _mws
  local out; out="$( cd "$T" && _cmd_mode_in_subshell bundle fleet --no-restart 2>&1 )" \
    && { echo "switched to fleet"; rm -rf "$T"; return 1; }
  assert_contains "$out" "fan-out was retired on 2026-11-08: build in the product's solo agent (feature teams are coming)"
  assert_eq "$(_changed_lines)" 0
  rm -rf "$T"
  _mws_legacy
  out="$( cd "$T" && _cmd_mode_in_subshell lone fleet 2>&1 )" && { echo "accepted fleet"; rm -rf "$T"; return 1; }
  assert_contains "$out" "fan-out was retired"
  assert_eq "$(_changed_lines)" 0
  rm -rf "$T"
}

test_mode_on_an_implicit_product_writes_its_repo_entry() {
  _mws_legacy
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
  _mws_legacy
  mv "$T/workspace.yaml" "$T/real.yaml"; ln -s real.yaml "$T/workspace.yaml"
  ( cd "$T" && cmd_mode bundle solo --no-restart ) >/dev/null
  [ -L "$T/workspace.yaml" ] || { echo "the link was replaced"; rm -rf "$T"; return 1; }
  assert_eq "$(ws_build_mode "$T" bundle)" solo
  rm -rf "$T"
}

# A flow-style item cannot be edited as one line; it is refused, untouched.
test_mode_refuses_a_flow_style_entry_and_leaves_the_file_alone() {
  _mws
  sed -i 's/^  - name: lone$/  - { name: lone, url: x, prefix: OT, gate: t, mode: fleet }/' "$T/workspace.yaml"
  awk '/name: lone, url/ {print; skip=3; next} skip>0 {skip--; next} {print}' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  cp "$T/workspace.yaml" "$ORIG"
  local out; out="$( cd "$T" && _cmd_mode_in_subshell lone solo --no-restart 2>&1 )" && { rm -rf "$T"; return 1; }
  assert_contains "$out" "flow-style"
  assert_eq "$(_changed_lines)" 0
  rm -rf "$T"
}

# The owner (or another cel mode) editing workspace.yaml while this edit is
# being validated must not lose that edit: the source is checked right before
# the rename and the write is refused, untouched, when it moved.
test_mode_write_over_a_concurrent_edit_is_fail_safe() {
  _mws_legacy
  chmod() { printf '# edited meanwhile\n' >> "$T/workspace.yaml"; command chmod "$@"; }
  local out; out="$( cd "$T" && _cmd_mode_in_subshell bundle solo --no-restart 2>&1 )" \
    && { unset -f chmod; echo "overwrote a concurrent edit"; rm -rf "$T"; return 1; }
  unset -f chmod
  grep -qx '# edited meanwhile' "$T/workspace.yaml" || { echo "the concurrent edit was lost"; rm -rf "$T"; return 1; }
  assert_eq "$(ws_build_mode "$T" bundle)" fleet
  assert_contains "$out" "changed while"
  [ -z "$(find "$T" -maxdepth 1 -name 'workspace.yaml.cel-mode.*')" ] || { echo "left a temp file"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# Two cel mode writers queue on one lock; one that cannot get it writes nothing.
test_mode_write_under_another_writers_lock_is_fail_safe() {
  _mws_legacy
  local hfd; exec {hfd}>"$T/.cel/workspace.lock"; flock "$hfd"
  local out; out="$( cd "$T" && CEL_MODE_WRITE_LOCK_WAIT=1 _cmd_mode_in_subshell bundle solo --no-restart 2>&1 )" \
    && { exec {hfd}>&-; echo "wrote under another writer's lock"; rm -rf "$T"; return 1; }
  exec {hfd}>&-
  assert_eq "$(_changed_lines)" 0
  assert_contains "$out" "changed while"
  rm -rf "$T"
}
# A box with no flock(1) writes as it always did - no lock is not a conflict.
test_mode_write_with_no_flock_still_writes() {
  _mws_legacy
  source "$CEL_ROOT/tests/lib/no-flock.sh"
  local out; out="$( cd "$T" && PATH="$(no_flock_path "$T")" _cmd_mode_in_subshell bundle solo --no-restart 2>&1 )" \
    || { echo "refused without flock: $out"; rm -rf "$T"; return 1; }
  assert_eq "$(ws_build_mode "$T" bundle)" solo
  _data_is_orig_plus products bundle solo || { rm -rf "$T"; return 1; }
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

# LANES. A lane's restart waiter watches and relaunches the lane, never the
# main agent.
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
# A lane's mailbox is not <product>-orch: the launch's CEL_PRODUCT names it.
test_mode_product_comes_from_the_launch_for_a_lane() {
  _mws
  assert_eq "$(cd /tmp && CEL_PRODUCT=bundle CEL_INBOX_ME=bundle-ui CEL_INBOX_WS='' _mode_product "$T")" bundle
  rm -rf "$T"
}

# The product's own agent is restarted - scheduled, never inline, so the agent
# that ran `cel mode` is not killed mid-turn - and only when asked.
test_mode_schedules_a_restart_for_the_product_agent_only_when_asked() {
  _mws_legacy; _mode_stub_roster "$T/products/bundle" bundle-orch working
  ( cd "$T" && cmd_mode bundle solo --no-restart ) >/dev/null
  [ ! -s "$T/launched" ] || { echo "restarted despite --no-restart"; rm -rf "$T"; return 1; }
  _mode_write "$T" bundle fleet
  ( cd "$T" && CEL_MODE_LAUNCH=_rec cmd_mode bundle solo ) >/dev/null
  assert_contains "$(cat "$T/launched")" "mode --restart-when-idle bundle"
  rm -rf "$T"
}
# Somebody else's pane standing in the directory is not the product's agent.
test_mode_does_not_restart_another_agent_in_the_product_dir() {
  _mws_legacy; _mode_stub_roster "$T/products/bundle" someones-shell idle
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
