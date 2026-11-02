# shellcheck shell=bash
# After `cel update`, orchestrators still running an older launch line
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

# The once-per-build marker is written only when something was stale, so an
# orchestrator that goes stale LATER in the same build is still reported.
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

# A wrapped runtime (OpenCode's launcher passes `-- <opencode> <flags>`) is
# compared on the wrapped flags; the separator itself is not an extra flag.
test_launch_diff_ignores_a_wrapper_separator_but_not_wrapped_flags() {
  local T; T="$(mktemp -d)"
  printf '%s\0' opencode --standalone --auto --session ses_X > "$T/expected"
  printf '%s\0' node /plane/tools/opencode/launch.mjs -- /home/u/.local/bin/opencode --standalone --auto --session ses_X > "$T/actual"
  assert_eq "$(run_launch_diff "$T/expected" "$T/actual")" ""
  printf '%s\0' node /plane/tools/opencode/launch.mjs -- /home/u/.local/bin/opencode --standalone --session ses_X > "$T/actual"
  assert_eq "$(run_launch_diff "$T/expected" "$T/actual")" "missing: --auto"
  rm -rf "$T"
}

# The restart call is an argv, not a re-split string.
test_restart_orchestrators_passes_the_restart_as_an_argv() {
  orch_stub_setup omp
  orch_stub_proc 100 widget-orch "$T/ws" omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  eval "_real_$(declare -f cmd_run)"
  cmd_run() { case " $* " in *" --restart "*) printf '%s|' "$@" > "$T/argv" ;; *) _real_cmd_run "$@" ;; esac; }
  _update_stale_orchestrators 1 >/dev/null
  assert_eq "$(cat "$T/argv")" "orchestrator|--product|widget|--workspace|alpha|--restart|"
  orch_stub_teardown
}

# The process is found downward from the pane's shell. An unreadable ANCESTOR
# of the pane (systemd --user) is never consulted: reading it reports an
# orchestrator that has every flag as missing them all.
test_stale_detection_finds_the_omp_process_below_an_unreadable_ancestor() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  local -a argv; mapfile -t argv < <(_current_argv)
  orch_stub_proc 100 widget-orch "$T/ws" "${argv[@]}"
  # the shell's parent is a process this user cannot read, marked like ours
  printf 'Name:\tbash\nPPid:\t7\n' > "$PROC/50/status"
  mkdir -p "$PROC/7"; printf 'omp\0' > "$PROC/7/cmdline"
  printf 'CEL_WORKSPACE=%s\0CEL_INBOX_ME=widget-orch\0' "$T/ws" > "$PROC/7/environ"
  printf 'PPid:\t1\n' > "$PROC/7/status"; chmod 000 "$PROC/7/cmdline" "$PROC/7/environ"
  local rows; rows="$(run_orchestrator_rows)"
  assert_contains "$rows" "widget-orch	alpha	w1:p1	idle"
  assert_contains "$rows" "	current	"
  orch_stub_teardown
}

test_a_missing_model_on_both_sides_reads_as_current() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  local -a argv; mapfile -t argv < <(_current_argv)
  printf '%s\n' "${argv[@]}" | grep -qx -- --model && { echo "fixture launch line has a model"; orch_stub_teardown; return 1; }
  orch_stub_proc 100 widget-orch "$T/ws" "${argv[@]}"
  assert_contains "$(run_orchestrator_rows)" "	current	"
  orch_stub_teardown
}

test_an_unresolvable_process_reads_unknown_not_missing() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  # the only omp is outside the pane's shell tree
  orch_stub_proc 100 widget-orch "$T/ws" omp
  printf 'PPid:\t1\n' > "$PROC/100/status"
  local rows out
  rows="$(run_orchestrator_rows)"
  assert_contains "$rows" "	unknown	"
  out="$(_update_stale_orchestrators 0)"
  assert_contains "$out" "widget-orch (alpha) launch line unknown"
  ! printf '%s' "$out" | grep -q "missing:" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

test_update_check_previews_the_stale_list() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_proc 100 widget-orch "$T/ws" omp
  _update_check_version() { return 0; }
  local out; out="$(_update_check)"
  assert_contains "$out" "widget-orch (alpha) runs an older launch line"
  assert_contains "$out" "--restart-orchestrators"
  [ ! -f "$T/started" ] || { echo "check restarted something"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

# herdr brings an orchestrator back as a bare `omp --resume=<file>` -
# no inbox hook and no CEL_ env, so the env-keyed lookup above cannot even
# see it. It is found from the pane's shell downward and reported stripped.
test_stripped_orchestrator_is_found_from_the_pane_shell() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_bare_proc 100 omp "--resume=$T/s.jsonl"
  local out; out="$(run_stripped_orchestrators)"
  assert_contains "$out" "widget-orch	alpha	widget	w1:p1	idle	stripped	cel run orchestrator --product widget --workspace alpha --restart"
  orch_stub_bare_proc 100 omp --hook "$CEL_ROOT/tools/hooks/inbox.omp.ts" "--resume=$T/s.jsonl"
  assert_contains "$(run_stripped_orchestrators)" "	ok	"
  orch_stub_teardown
}

test_doctor_fails_a_stripped_orchestrator_and_names_the_command() {
  source "$CEL_ROOT/lib/doctor.sh"
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_bare_proc 100 omp "--resume=$T/s.jsonl"
  local out rc=0
  out="$(doctor_inbox_hook_lines)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "✗"
  assert_contains "$out" "widget-orch (alpha) is running without its inbox hook"
  assert_contains "$out" "cel run orchestrator --product widget --workspace alpha --restart"
  orch_stub_teardown
}

# The pane's orchestrator is the omp nearest the shell, not the NEWEST omp
# under it, which may be one the orchestrator spawned itself; taking that one
# would call a full launch line stale, missing every item.
test_cel87_full_launch_line_is_not_listed_beside_an_unrelated_process() {
  orch_stub_setup omp
  orch_stub_roster alpha-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  local -a argv; mapfile -t argv < <(_current_argv)
  orch_stub_proc 100 alpha-orch "$T/ws" "${argv[@]}"
  # an omp the orchestrator started, in its tree and its cwd, newer pid
  orch_stub_bare_proc 200 omp --print "a task"
  printf 'Name:\tomp\nPPid:\t100\n' > "$PROC/200/status"
  # an omp in the same cwd outside the pane's tree
  orch_stub_bare_proc 300 omp
  printf 'Name:\tomp\nPPid:\t1\n' > "$PROC/300/status"
  local out; out="$(_update_stale_orchestrators 0)"
  assert_eq "$out" ""
  orch_stub_teardown
}

test_cel87_missing_inbox_hook_is_named_exactly() {
  orch_stub_setup omp
  orch_stub_roster alpha-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  local -a argv keep=(); mapfile -t argv < <(_current_argv)
  local i
  for ((i = 0; i < ${#argv[@]}; i++)); do
    if [ "${argv[$i]}" = --hook ] && [[ "${argv[$((i+1))]}" == *inbox.omp.ts ]]; then i=$((i+1)); continue; fi
    keep+=("${argv[$i]}")
  done
  orch_stub_proc 100 alpha-orch "$T/ws" "${keep[@]}"
  orch_stub_bare_proc 200 omp
  printf 'Name:\tomp\nPPid:\t100\n' > "$PROC/200/status"
  local out; out="$(_update_stale_orchestrators 0)"
  assert_contains "$out" "alpha-orch (alpha) runs an older launch line (missing: inbox hook; read from pid 100) - "
  orch_stub_teardown
}

test_cel87_trailing_dry_run_output_does_not_blank_the_verdict() {
  orch_stub_setup omp
  orch_stub_roster alpha-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  local -a argv; mapfile -t argv < <(_current_argv)
  orch_stub_proc 100 alpha-orch "$T/ws" "${argv[@]}"
  eval "_real_$(declare -f cmd_run)"
  cmd_run() { _real_cmd_run "$@"; local rc=$?; printf 'note: something after the launch line\n'; return "$rc"; }
  assert_contains "$(run_orchestrator_rows)" "	current	"
  orch_stub_teardown
}

# omp's own helpers are also named omp (a js-eval worker, a daemon broker) and
# carry no inbox hook. doctor and the steward's repair read them through the
# same lookup, so they must not make a healthy orchestrator read as stripped.
test_cel87_omp_helper_children_do_not_read_as_stripped() {
  orch_stub_setup omp
  orch_stub_roster alpha-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_bare_proc 100 omp --hook "$CEL_ROOT/tools/hooks/inbox.omp.ts" "--resume=$T/s.jsonl"
  orch_stub_bare_proc 210 omp __omp_worker_js_eval_process
  orch_stub_bare_proc 220 omp __omp_worker_daemon_broker
  printf 'Name:\tomp\nPPid:\t100\n' > "$PROC/210/status"
  printf 'Name:\tomp\nPPid:\t210\n' > "$PROC/220/status"
  assert_contains "$(run_stripped_orchestrators)" "alpha-orch	alpha	widget	w1:p1	idle	ok	"
  orch_stub_teardown
}

# A helper is never the orchestrator. When the real omp does not match (its cwd
# moved, or it is not under the pane's shell), the lookup fails and the verdict
# is unknown - never stale, never current, never every flag missing.
test_a_helper_alone_reads_unknown_not_missing_every_flag() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  local -a argv; mapfile -t argv < <(_current_argv)
  ORCH_STUB_CWD="$T/ws" orch_stub_proc 100 widget-orch "$T/ws" "${argv[@]}"
  orch_stub_bare_proc 210 omp __omp_worker_js_eval_process
  local rows out
  rows="$(run_orchestrator_rows)"
  assert_contains "$rows" "	unknown	"
  out="$(_update_stale_orchestrators 0)"
  ! printf '%s' "$out" | grep -q "missing:" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

test_a_real_orchestrator_beside_a_helper_reads_current() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  local -a argv; mapfile -t argv < <(_current_argv)
  orch_stub_proc 100 widget-orch "$T/ws" "${argv[@]}"
  orch_stub_bare_proc 210 omp __omp_worker_js_eval_process
  assert_contains "$(run_orchestrator_rows)" "	current	"
  orch_stub_teardown
}

# The stale detail names the process it read, so an alert can be traced.
test_a_stale_launch_names_the_pid_it_read() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_proc 100 widget-orch "$T/ws" omp --hook "$CEL_ROOT/tools/hooks/orchestrator-guard.omp.ts"
  orch_stub_bare_proc 210 omp __omp_worker_js_eval_process
  local out; out="$(_update_stale_orchestrators 0)"
  assert_contains "$out" "inbox hook"
  assert_contains "$out" "; read from pid 100)"
  orch_stub_teardown
}
