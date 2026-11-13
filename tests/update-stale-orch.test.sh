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
  export CEL_UPDATE_DIR="$T/upd" CEL_INBOX_DIR="$T/inbox"
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_proc 100 widget-orch "$T/ws" omp
  _steward_raise() { printf '%s|%s\n' "$1" "$4" >> "$T/raised"; }
  _steward_stale_orchestrators >/dev/null
  _steward_stale_orchestrators >/dev/null
  assert_eq "$(wc -l < "$T/raised" | tr -d ' ')" "1"
  assert_contains "$(cat "$T/raised")" "alpha|steward: after the update"
  unset CEL_UPDATE_DIR; orch_stub_teardown
}

# The report marker is written only when something was stale, so an
# orchestrator that goes stale LATER in the same build is still reported.
test_steward_reports_an_orchestrator_that_goes_stale_later_in_the_build() {
  source "$CEL_ROOT/lib/steward.sh"
  orch_stub_setup omp
  export CEL_UPDATE_DIR="$T/upd" CEL_INBOX_DIR="$T/inbox"
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

# The hook in argv is not the watcher it runs: an agent up past the grace
# with no `cel inbox watch --parent <pid>` child is DEAF, and a watcher child
# makes it ok again. No uptime (or anything unreadable) stays ok.
_deaf_fixture() { # <pid>
  orch_stub_bare_proc "$1" omp --hook "$CEL_ROOT/tools/hooks/inbox.omp.ts" "--resume=$T/s.jsonl"
  mkdir -p "$PROC/$1/task/$1"; : > "$PROC/$1/task/$1/children"
  printf '100000.00 0.00\n' > "$PROC/uptime"
}
_deaf_watcher() { # <parent-pid> <watcher-pid>
  mkdir -p "$PROC/$2"
  printf '%s\0' bash "$CEL_ROOT/bin/cel" inbox watch --parent "$1" > "$PROC/$2/cmdline"
  printf '%s ' "$2" > "$PROC/$1/task/$1/children"
}
test_hooked_orchestrator_without_a_live_watcher_reads_deaf() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  _deaf_fixture 100
  assert_contains "$(run_stripped_orchestrators)" "widget-orch	alpha	widget	w1:p1	idle	deaf	cel run orchestrator --product widget --workspace alpha --restart	-"
  _deaf_watcher 100 101
  assert_contains "$(run_stripped_orchestrators)" "	idle	ok	"
  : > "$PROC/100/task/100/children"; rm -f "$PROC/uptime"
  assert_contains "$(run_stripped_orchestrators)" "	idle	ok	"
  orch_stub_teardown
}

# A solo lane is checked like the product's main agent and restarts as a lane.
test_deaf_solo_lane_is_listed_with_its_lane_restart() {
  orch_stub_setup omp
  export ORCH_STUB_CWD="$T/ws/.cel/solo/widget/lane-disk-cleanup"
  mkdir -p "$ORCH_STUB_CWD"
  orch_stub_roster widget-disk-cleanup "$ORCH_STUB_CWD" idle "$T/s.jsonl"
  _deaf_fixture 100
  assert_contains "$(run_stripped_orchestrators)" "widget-disk-cleanup	alpha	widget	w1:p1	idle	deaf	cel run solo --product widget --lane disk-cleanup --workspace alpha --restart	disk-cleanup"
  unset ORCH_STUB_CWD
  orch_stub_teardown
}

test_doctor_fails_a_deaf_orchestrator() {
  source "$CEL_ROOT/lib/doctor.sh"
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  _deaf_fixture 100
  local out rc=0
  out="$(doctor_inbox_hook_lines)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "widget-orch (alpha) has its inbox hook but no live inbox watcher"
  assert_contains "$out" "cel run orchestrator --product widget --workspace alpha --restart"
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

# AN EXPLICIT MODEL THE SESSION ALREADY RUNS is not a launch difference: root
# restarts an orchestrator with --model (and --thinking) so it keeps the model
# its saved session runs, where a plain restart would take the workspace
# default. The running model is the later of the last model_change and the
# last assistant message's own model; a helper model's usage is never it.
_kept_session() { # <file> <thinking> [assistant provider] [assistant model]
  cat > "$1" <<EOF
{"type":"session","id":"s1","timestamp":"2026-11-01T00:00:00.000Z","cwd":"/w"}
{"type":"model_change","model":"anthropic/claude-opus-5-5","timestamp":"2026-11-01T00:00:01.000Z"}
{"type":"thinking_level_change","configured":null,"thinkingLevel":"$2","timestamp":"2026-11-01T00:00:01.000Z"}
{"type":"message","timestamp":"2026-11-01T00:00:02.000Z","message":{"role":"assistant","provider":"${3:-celgw}","model":"${4:-omp/claude-opus-5-5}","content":[]}}
{"type":"model_usage","timestamp":"2026-11-01T00:00:03.000Z","role":"typesafe","provider":"openrouter","model":"~typesafe/jev-latest"}
EOF
}
# The current launch line with its thinking level set and an explicit model.
_kept_argv() { # <model> <thinking> [extra args...]
  local -a argv; mapfile -t argv < <(_current_argv)
  local i model="$1" level="$2"; shift 2
  for ((i = 0; i < ${#argv[@]} - 1; i++)); do
    [ "${argv[$i]}" != --thinking ] || argv[i+1]="$level"
  done
  printf '%s\n' "${argv[@]}" --model "$model" "$@"
}
_kept_setup() { # <model> <thinking> [extra args...]; KEPT_PROVIDER/KEPT_MODEL: the session's
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  _kept_session "$T/s.jsonl" medium "${KEPT_PROVIDER:-celgw}" "${KEPT_MODEL:-omp/claude-opus-5-5}"
  local -a argv; mapfile -t argv < <(_kept_argv "$@")
  orch_stub_proc 100 widget-orch "$T/ws" "${argv[@]}"
}

test_a_kept_model_is_not_a_launch_difference() {
  _kept_setup celgw/omp/claude-opus-5-5 medium
  _current_argv | grep -qx -- --thinking || { echo "fixture launch line has no --thinking"; orch_stub_teardown; return 1; }
  _current_argv | grep -qx -- --model && { echo "fixture launch line has a model"; orch_stub_teardown; return 1; }
  assert_contains "$(run_orchestrator_rows)" "	current	"
  local out; out="$(_update_stale_orchestrators 0)"
  ! printf '%s' "$out" | grep -q "older launch line" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

# The same route and id in another spelling is the same model.
test_kept_model_gateway_spellings_compare_equal() {
  local m
  for m in omp/claude-opus-5-5 celgw/omp/claude-opus-5-5 ompgw/claude/claude-opus-5-5 ompgw-claude/claude-opus-5-5; do
    _kept_setup "$m" medium
    assert_contains "$(run_orchestrator_rows)" "	current	" || { orch_stub_teardown; return 1; }
    orch_stub_teardown
  done
  KEPT_PROVIDER=ompgw-claude KEPT_MODEL=claude-opus-5-5 _kept_setup celgw/omp/claude-opus-5-5 medium
  assert_contains "$(run_orchestrator_rows)" "	current	"
  orch_stub_teardown
}

test_model_route_classifies_every_spelling() {
  local s
  while IFS='|' read -r s want; do
    assert_eq "$(gateway_model_route "$s" | tr '\t' '|')" "$want" || return 1
  done <<'CASES'
celgw/omp/claude-opus-5-5|gateway|claude-opus-5-5
omp/claude-opus-5-5|gateway|claude-opus-5-5
ompgw-claude/claude-opus-5-5|gateway|claude-opus-5-5
ompgw/claude/claude-opus-5-5|gateway|claude-opus-5-5
celgw-codex/gpt-6.1-sol|gateway|gpt-6.1-sol
ompgw-codex/gpt-6.1-sol|gateway|gpt-6.1-sol
anthropic/claude-opus-5-5|anthropic|claude-opus-5-5
openai-codex/gpt-6.1-sol|openai-codex|gpt-6.1-sol
openrouter/anthropic/claude-opus-5-5|openrouter|claude-opus-5-5
claude/claude-opus-5-5|-|claude-opus-5-5
claude-opus-5-5|-|claude-opus-5-5
CASES
}

# THE SAME ID OVER ANOTHER ROUTE IS ANOTHER MODEL: a session on direct
# Anthropic is not kept by a gateway --model, nor the reverse, and a flag that
# names no provider proves no route.
test_a_kept_model_needs_the_same_route() {
  KEPT_PROVIDER=anthropic KEPT_MODEL=claude-opus-5-5 _kept_setup celgw/omp/claude-opus-5-5 medium
  assert_contains "$(run_orchestrator_rows)" ", --model celgw/omp/claude-opus-5-5;" || { orch_stub_teardown; return 1; }
  orch_stub_teardown
  _kept_setup anthropic/claude-opus-5-5 medium
  assert_contains "$(run_orchestrator_rows)" ", --model anthropic/claude-opus-5-5;" || { orch_stub_teardown; return 1; }
  orch_stub_teardown
  local m
  for m in claude-opus-5-5 claude/claude-opus-5-5; do
    _kept_setup "$m" medium
    assert_contains "$(run_orchestrator_rows)" "	stale	" || { orch_stub_teardown; return 1; }
    orch_stub_teardown
  done
}

# A PROFILE MODEL REPLACED BY THE KEPT ONE: the current line names the
# profile's --model, the agent runs an explicit one its session runs - not a
# difference (missing and extra both go). Over another route it still is.
test_a_kept_model_replacing_a_profile_model_is_not_a_difference() {
  eval "_real_$(declare -f _run_expected_launch)"
  _run_expected_launch() { _real__run_expected_launch "$@" || return; printf '%s\0' --model celgw-codex/gpt-6.1-sol >> "$1"; }
  _kept_setup celgw/omp/claude-opus-5-5 medium
  assert_contains "$(run_orchestrator_rows)" "	current	" || { orch_stub_teardown; return 1; }
  orch_stub_teardown
  KEPT_PROVIDER=anthropic KEPT_MODEL=claude-opus-5-5 _kept_setup celgw/omp/claude-opus-5-5 medium
  assert_contains "$(run_orchestrator_rows)" "missing: --thinking high, --model celgw-codex/gpt-6.1-sol; extra: --thinking medium, --model celgw/omp/claude-opus-5-5;"
  orch_stub_teardown
}

# A verdict cached before the agent's session was recorded (s:-) is not kept
# once the session appears.
test_a_cached_verdict_without_a_session_follows_its_arrival() {
  _kept_setup celgw/omp/claude-opus-5-5 medium
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle ""
  assert_contains "$(run_orchestrator_rows)" "	stale	"
  assert_contains "$(cat "$CEL_CACHE/orch-verdicts.tsv")" "	s:-"
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  assert_contains "$(run_orchestrator_rows)" "	current	"
  orch_stub_teardown
}

# Not kept, so its thinking level is compared as any flag is, too.
test_a_model_the_session_does_not_run_is_still_a_difference() {
  _kept_setup celgw/omp/claude-sonnet-5-5 medium
  local out; out="$(_update_stale_orchestrators 0)"
  assert_contains "$out" "widget-orch (alpha) runs an older launch line (missing: --thinking high; extra: --thinking medium, --model celgw/omp/claude-sonnet-5-5;"
  orch_stub_teardown
}

# A helper's model_usage entry, however late, is not the model the session runs.
test_a_helper_model_is_not_the_running_model() {
  _kept_setup '~typesafe/jev-latest' medium
  assert_contains "$(_update_stale_orchestrators 0)" ", --model \\~typesafe/jev-latest;"
  orch_stub_teardown
}

test_a_thinking_level_the_session_does_not_run_is_still_a_difference() {
  _kept_setup celgw/omp/claude-opus-5-5 low
  local out; out="$(_update_stale_orchestrators 0)"
  assert_contains "$out" "--thinking low"
  ! printf '%s' "$out" | grep -q -- "--model" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

test_another_extra_flag_beside_a_kept_model_still_alerts() {
  _kept_setup celgw/omp/claude-opus-5-5 medium --retired-flag
  local out; out="$(_update_stale_orchestrators 0)"
  assert_contains "$out" "runs an older launch line (extra: --retired-flag;"
  ! printf '%s' "$out" | grep -q -- "--model\|--thinking" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

# A cached verdict that read the session holds only while the session says the
# same: a session that switches model away from its launch line is stale.
test_a_cached_kept_verdict_follows_the_session() {
  _kept_setup celgw/omp/claude-opus-5-5 medium
  assert_contains "$(run_orchestrator_rows)" "	current	"
  printf '%s\n' '{"type":"model_change","role":"temporary","model":"celgw/omp/claude-sonnet-5-5","timestamp":"2026-11-01T00:00:04.000Z"}' >> "$T/s.jsonl"
  local rows; rows="$(run_orchestrator_rows)"
  assert_contains "$rows" "	stale	"
  assert_contains "$rows" ", --model celgw/omp/claude-opus-5-5;"
  orch_stub_teardown
}

# ONCE PER CHANGE, NOT PER BUILD: every `cel update` is a new build, and an
# unchanged difference is not said again after it. A new difference is.
test_steward_says_an_unchanged_difference_once_across_updates() {
  source "$CEL_ROOT/lib/steward.sh"
  orch_stub_setup omp
  export CEL_UPDATE_DIR="$T/upd" CEL_INBOX_DIR="$T/inbox"
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  local -a argv; mapfile -t argv < <(_current_argv)
  orch_stub_proc 100 widget-orch "$T/ws" "${argv[@]}" --retired-flag
  _steward_raise() { printf '%s|%s\n' "$1" "$4" >> "$T/raised"; }
  local b
  for b in aaaaaaa bbbbbbb ccccccc; do
    # shellcheck disable=SC2329 # read by lib/version.sh cel_build_sha
    git() { if [ "${3:-}" = rev-parse ] && [ "${4:-}" = --short ]; then printf '%s\n' "$b"; else command git "$@"; fi; }
    _steward_stale_orchestrators >/dev/null
  done
  unset -f git
  assert_eq "$(wc -l < "$T/raised" | tr -d ' ')" "1"
  assert_contains "$(cat "$T/raised")" "extra: --retired-flag"
  # a different difference from the same agent is news, said once
  orch_stub_proc 100 widget-orch "$T/ws" "${argv[@]}" --other-flag
  _steward_stale_orchestrators >/dev/null
  _steward_stale_orchestrators >/dev/null
  assert_eq "$(wc -l < "$T/raised" | tr -d ' ')" "2"
  assert_contains "$(sed -n 2p "$T/raised")" "extra: --other-flag"
  assert_eq "$(wc -l < "$CEL_UPDATE_DIR/orch-stale-reported" | tr -d ' ')" "1"
  unset CEL_UPDATE_DIR; orch_stub_teardown
}
