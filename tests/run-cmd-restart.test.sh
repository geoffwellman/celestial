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

# CEL-83: a restart sets the pane label again.
test_restart_relabels_the_pane() {
  orch_stub_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  _restart >/dev/null || true
  assert_contains "$(grep '^pane rename' "$HLOG")" "pane rename w1:p1 widget orchestrator"
  assert_contains "$(grep '^tab rename' "$HLOG")" "tab rename w1:t1 widget orchestrator"
  orch_stub_teardown
}

# CEL-102: two omp processes resumed ONE session file for two days - an old
# pane that had lost its herdr name, and a fresh `cel run orchestrator`. Each
# answered mail and the owner got contradicting replies. A process already
# resuming the file is refused by pane, whatever herdr thinks its name is.
_resumer() { # <pid> <pane> <session>
  mkdir -p "$PROC/$1"
  printf '%s\0' omp --resume "$3" > "$PROC/$1/cmdline"
  printf 'HERDR_PANE_ID=%s\0' "$2" > "$PROC/$1/environ"
}

test_run_orchestrator_refuses_a_session_another_pane_is_resuming() {
  orch_stub_setup omp
  printf '{"result":{"agents":[]}}\n' > "$T/roster.json"
  _run_sessions_record "$T/ws/repos/widget" "$T/old.jsonl"
  _resumer 4242 w7:p4 "$T/old.jsonl"
  local out
  if out="$( (cd "$T/ws" && cmd_run orchestrator --dry-run) 2>&1)"; then
    echo "launched over a live resumer: $out"; orch_stub_teardown; return 1
  fi
  assert_contains "$out" "w7:p4"
  assert_contains "$out" "$T/old.jsonl"
  out="$( (cd "$T/ws" && cmd_run orchestrator --dry-run --force) 2>&1)" \
    || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  assert_contains "$out" "--resume $T/old.jsonl"
  orch_stub_teardown
}

test_restart_refuses_when_a_second_pane_resumes_the_same_session() {
  orch_stub_setup omp
  local sess="$T/sessions/abc.jsonl" out
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$sess"
  _resumer 4243 w9:p2 "$sess"
  if out="$(_restart)"; then echo "restarted beside a live resumer"; orch_stub_teardown; return 1; fi
  assert_contains "$out" "w9:p2"
  orch_stub_teardown
}

test_restart_ignores_its_own_pane_resuming_the_session() {
  orch_stub_setup omp
  local sess="$T/sessions/abc.jsonl" out
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$sess"
  _resumer 4244 w1:p1 "$sess"
  out="$(_restart)" || { printf '%s\n' "$out"; orch_stub_teardown; return 1; }
  assert_contains "$(_new_cmdline)" "--resume $sess"
  orch_stub_teardown
}

test_doctor_flags_two_live_processes_on_one_session() {
  orch_stub_setup omp
  source "$CEL_ROOT/lib/doctor.sh"
  _resumer 4245 w7:p4 "$T/one.jsonl"
  _resumer 4246 w8:p1 "$T/one.jsonl"
  _resumer 4247 w8:p2 "$T/two.jsonl"
  local out rc=0; out="$(doctor_shared_session_lines 2>&1)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "$T/one.jsonl"
  assert_contains "$out" "w7:p4"
  assert_contains "$out" "w8:p1"
  ! printf '%s' "$out" | grep -q two.jsonl || { echo "flagged a single resumer"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}

# Sourcery on #128: a runtime that cannot resume starts fresh - it is no
# second resumer, so a live process on the recorded session must not block it.
test_run_orchestrator_without_resume_support_is_not_refused() {
  orch_stub_setup opencode
  printf '{"result":{"agents":[]}}\n' > "$T/roster.json"
  _run_sessions_record "$T/ws/repos/widget" "$T/old.jsonl"
  _resumer 4250 w7:p4 "$T/old.jsonl"
  local out
  out="$( (cd "$T/ws" && cmd_run orchestrator --dry-run) 2>&1)" \
    || { echo "refused a fresh launch: $out"; orch_stub_teardown; return 1; }
  assert_contains "$out" "starting fresh"
  orch_stub_teardown
}

# Sourcery on #128: something that merely mentions --resume (a grep, an
# editor) is not an agent resuming the session.
test_session_resumers_ignore_processes_that_are_not_agents() {
  orch_stub_setup omp
  mkdir -p "$PROC/4251"
  printf '%s\0' grep -- --resume "$T/old.jsonl" > "$PROC/4251/cmdline"
  printf 'HERDR_PANE_ID=w7:p4\0' > "$PROC/4251/environ"
  _resumer 4252 w8:p1 "$T/old.jsonl"
  local out; out="$(run_session_resumers)"
  ! printf '%s' "$out" | grep -q 4251 || { echo "counted grep: $out"; orch_stub_teardown; return 1; }
  assert_contains "$out" "4252"
  orch_stub_teardown
}

# Sourcery on #128: two launches racing before either agent is in /proc. The
# first claims the session; the second, inside the claim window, is refused.
test_session_claim_refuses_a_second_launch_inside_the_window() {
  orch_stub_setup omp
  export CEL_ORCH_SESSIONS="$T/sessions.json"
  _run_session_claim "$T/old.jsonl" || { echo "first claim refused"; orch_stub_teardown; return 1; }
  if _run_session_claim "$T/old.jsonl" 2>/dev/null; then echo "second claim granted"; orch_stub_teardown; return 1; fi
  _run_session_claim "$T/other.jsonl" || { echo "unrelated session refused"; orch_stub_teardown; return 1; }
  CEL_SESSION_CLAIM_SECS=0 _run_session_claim "$T/old.jsonl" || { echo "expired claim still held"; orch_stub_teardown; return 1; }
  orch_stub_teardown
}
