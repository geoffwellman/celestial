# shellcheck shell=bash
# CEL-63: restarting an orchestrator keeps its conversation. The session is
# the one herdr recorded for THAT pane - omp's --continue picks the newest
# session in the cwd, and several omp sessions share one cwd on a real box.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/run.sh"
source "$CEL_ROOT/tests/lib/orch-stub.sh"

_restart() { ( cd "$T/ws" && cmd_run orchestrator --restart "$@" ) 2>&1; }
_new_cmdline() { tr '\0' ' ' < "$PROC/9999/cmdline"; }

test_restart_idle_omp_orchestrator_resumes_herdr_session_in_same_pane() {
  orch_stub_setup omp
  local sess="$T/sessions/abc.jsonl" out
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$sess"
  orch_stub_proc 100 widget-orch "$T/ws" omp --hook "$CEL_ROOT/tools/hooks/orchestrator-guard.omp.ts"
  out="$(_restart)" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  assert_contains "$(cat "$HLOG")" "pane send-keys w1:p1"
  assert_contains "$(cat "$HLOG")" "agent start widget-orch --kind omp --pane w1:p1"
  assert_contains "$(_new_cmdline)" "--resume $sess"
  assert_contains "$(_new_cmdline)" "inbox.omp.ts"
  assert_contains "$(_new_cmdline)" "--no-prewalk"
  ! grep -q -- "--continue" "$HLOG" || { echo "used --continue"; orch_stub_teardown; return 1; }
  assert_contains "$out" "inbox hook"
  orch_stub_teardown
}

test_restart_refuses_a_working_orchestrator_and_force_proceeds() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" working "$T/s.jsonl"
  local out
  if out="$(_restart)"; then echo "restarted a working agent"; orch_stub_teardown; return 1; fi
  assert_contains "$out" "working"
  ! grep -q "send-keys" "$HLOG" || { echo "killed a turn"; orch_stub_teardown; return 1; }
  out="$(_restart --force)" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  assert_contains "$(_new_cmdline)" "--resume $T/s.jsonl"
  orch_stub_teardown
}

test_restart_with_no_session_recorded_starts_fresh_and_says_so() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle ""
  local out; out="$(_restart)" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  assert_contains "$out" "starting fresh"
  ! _new_cmdline | grep -q -- "--resume" || { echo "resumed nothing"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

test_plain_run_over_absent_orchestrator_resumes_last_recorded_session() {
  orch_stub_setup omp
  printf '{"result":{"agents":[]}}\n' > "$T/roster.json"
  _run_sessions_record "$T/ws/repos/widget" "$T/old.jsonl"
  local out
  out="$( (cd "$T/ws" && cmd_run orchestrator --dry-run) 2>&1)"
  assert_contains "$out" "--resume $T/old.jsonl"
  out="$( (cd "$T/ws" && cmd_run orchestrator --dry-run --fresh) 2>&1)"
  ! printf '%s' "$out" | grep -q -- "--resume" || { echo "--fresh resumed"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

test_workers_and_reviewers_never_resume() {
  orch_stub_setup omp
  printf '{"result":{"agents":[]}}\n' > "$T/roster.json"
  _run_sessions_record "$T/ws/repos/widget" "$T/old.jsonl"
  local out
  out="$( (cd "$T/ws" && cmd_run worker --repo widget --branch WG-1-x --dry-run) 2>&1)"
  ! printf '%s' "$out" | grep -q -- "--resume" || { echo "worker resumed"; orch_stub_teardown; return 1; }
  printf 'review:\n  runtime: omp\n  model: m\n' >> "$T/ws/workspace.yaml"
  out="$( (cd "$T/ws" && cmd_run reviewer --repo widget --pr 7 --dry-run) 2>&1)"
  ! printf '%s' "$out" | grep -q -- "--resume" || { echo "reviewer resumed"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

test_runtime_resume_args_come_from_the_manifest() {
  assert_eq "$(agent_resume omp flag)" "--resume"
  assert_eq "$(agent_resume claude flag)" "--resume"
  assert_eq "$(agent_resume opencode flag)" ""
}

# The incident: a restart chosen by cwd took the FIRST omp in the checkout -
# another session in another pane - and relaunched it as the orchestrator.
test_restart_chooses_the_named_agent_among_two_in_one_cwd() {
  orch_stub_setup omp
  orch_stub_roster_two "$T/ws/repos/widget" "" widget-orch
  local out; out="$(_restart)" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  assert_contains "$(cat "$HLOG")" "pane send-keys w2:p1"
  ! grep -q "w1:p1" "$HLOG" || { echo "touched the other pane"; orch_stub_teardown; return 1; }
  assert_contains "$(_new_cmdline)" "--resume $T/second.jsonl"
  orch_stub_teardown
}

test_restart_refuses_two_unnamed_agents_in_one_cwd_and_lists_them() {
  orch_stub_setup omp
  orch_stub_roster_two "$T/ws/repos/widget" "" ""
  local out
  if out="$(_restart)"; then echo "picked one"; orch_stub_teardown; return 1; fi
  assert_contains "$out" "w1:p1"
  assert_contains "$out" "w2:p1"
  assert_contains "$out" "second.jsonl"
  assert_contains "$out" "--pane"
  ! grep -q "send-keys" "$HLOG" || { echo "sent keys"; orch_stub_teardown; return 1; }
  # the operator names one
  out="$(_restart --pane w2:p1)" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  assert_contains "$(cat "$HLOG")" "agent start widget-orch --kind omp --pane w2:p1"
  orch_stub_teardown
}

test_restart_never_relaunches_a_pane_whose_agent_has_another_name() {
  orch_stub_setup omp
  orch_stub_roster_two "$T/ws/repos/widget" gadget-orch widget-orch
  local out
  if out="$(_restart --pane w1:p1)"; then echo "relaunched gadget-orch's pane"; orch_stub_teardown; return 1; fi
  assert_contains "$out" "gadget-orch"
  ! grep -q "send-keys" "$HLOG" || { echo "sent keys"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}
