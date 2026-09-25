# shellcheck shell=bash
# CEL-63: after `cel update`, orchestrators still running an older launch line
# are named, with what they lack and the exact command that fixes them.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/update.sh"
source "$CEL_ROOT/lib/run.sh"
source "$CEL_ROOT/tests/lib/orch-stub.sh"

# The line `cel run` would launch now, as argv.
_current_argv() {
  local line
  line="$( (cmd_run orchestrator --workspace alpha --fresh --force --dry-run) 2>/dev/null \
    | sed -n 's/^herdr agent start [^ ]* --kind [^ ]* --pane <pane> -- //p')"
  # shellcheck disable=SC2086
  printf '%s\n' omp $line
}

test_update_lists_a_stale_orchestrator_with_missing_items_and_command() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_proc 100 widget-orch "$T/ws" omp --hook "$CEL_ROOT/tools/hooks/orchestrator-guard.omp.ts"
  local out; out="$(_update_stale_orchestrators 0)"
  assert_contains "$out" "widget-orch (alpha) runs an older launch line (missing: "
  assert_contains "$out" "inbox hook"
  assert_contains "$out" "--no-prewalk"
  assert_contains "$out" "- cel run orchestrator --product widget --workspace alpha --restart"
  orch_stub_teardown
}

test_update_does_not_list_a_current_orchestrator() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  local -a argv; mapfile -t argv < <(_current_argv)
  # a different role-prompt path does not make a launch line stale
  orch_stub_proc 100 widget-orch "$T/ws" "${argv[@]/role-orchestrator.md/role-orchestrator.old.md}"
  local out; out="$(_update_stale_orchestrators 0)"
  ! printf '%s' "$out" | grep -q "older launch line" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

test_restart_orchestrators_restarts_idle_and_skips_working() {
  orch_stub_setup omp
  orch_stub_proc 100 widget-orch "$T/ws" omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" working "$T/s.jsonl"
  local out; out="$(_update_stale_orchestrators 1)"
  assert_contains "$out" "skipped"
  assert_contains "$out" "working"
  [ ! -f "$T/started" ] || { echo "restarted a working one"; orch_stub_teardown; return 1; }
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  out="$(_update_stale_orchestrators 1)"
  assert_eq "$(cat "$T/started")" "widget-orch"
  assert_contains "$(tr '\0' ' ' < "$PROC/9999/cmdline")" "--resume $T/s.jsonl"
  orch_stub_teardown
}

test_doctor_lists_a_stale_orchestrator() {
  source "$CEL_ROOT/lib/doctor.sh"
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_proc 100 widget-orch "$T/ws" omp
  assert_contains "$(doctor_stale_orchestrator_lines)" "widget-orch (alpha) runs an older launch line"
  orch_stub_teardown
}

test_steward_reports_stale_orchestrators_once_per_build() {
  source "$CEL_ROOT/lib/steward.sh"
  orch_stub_setup omp
  export CEL_UPDATE_DIR="$T/upd"
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_proc 100 widget-orch "$T/ws" omp
  _steward_raise() { printf '%s|%s\n' "$1" "$4" >> "$T/raised"; }
  _steward_stale_orchestrators >/dev/null
  _steward_stale_orchestrators >/dev/null
  assert_eq "$(wc -l < "$T/raised" | tr -d ' ')" "1"
  assert_contains "$(cat "$T/raised")" "alpha|steward: after the update"
  unset CEL_UPDATE_DIR; orch_stub_teardown
}

# Sourcery on #98: the marker was written even when nothing was stale, so an
# orchestrator that went stale LATER in the same build was never reported.
test_steward_reports_an_orchestrator_that_goes_stale_later_in_the_build() {
  source "$CEL_ROOT/lib/steward.sh"
  orch_stub_setup omp
  export CEL_UPDATE_DIR="$T/upd"
  printf '{"result":{"agents":[]}}\n' > "$T/roster.json"
  _steward_raise() { printf '%s|%s\n' "$1" "$4" >> "$T/raised"; }
  _steward_stale_orchestrators >/dev/null
  [ ! -s "$T/raised" ] || { echo "raised with nothing stale"; orch_stub_teardown; return 1; }
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_proc 100 widget-orch "$T/ws" omp
  _steward_stale_orchestrators >/dev/null
  assert_contains "$(cat "$T/raised" 2>/dev/null)" "widget-orch runs an older launch line"
  unset CEL_UPDATE_DIR; orch_stub_teardown
}

# ...and a flag the current launch no longer carries is stale too.
test_update_lists_an_obsolete_flag_as_extra() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  local -a argv; mapfile -t argv < <(_current_argv)
  orch_stub_proc 100 widget-orch "$T/ws" "${argv[@]}" --retired-flag
  local out; out="$(_update_stale_orchestrators 0)"
  assert_contains "$out" "extra: --retired-flag"
  ! printf '%s' "$out" | grep -q "missing:" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

# The restart call is an argv, not a re-split string.
test_restart_orchestrators_passes_the_restart_as_an_argv() {
  orch_stub_setup omp
  orch_stub_proc 100 widget-orch "$T/ws" omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  cmd_run() { printf '%s|' "$@" > "$T/argv"; }
  _update_stale_orchestrators 1 >/dev/null
  assert_eq "$(cat "$T/argv")" "orchestrator|--product|widget|--workspace|alpha|--restart|"
  orch_stub_teardown
}
