# shellcheck shell=bash
# A re-run that passes supersedes the same check's earlier failure; a re-run
# that fails supersedes an earlier pass. Different checks never hide each other.
source "$CEL_ROOT/lib/common.sh"

_red() { jq "$CEL_JQ_LATEST_CHECKS"'[.statusCheckRollup // [] | latest_checks[] | select((.conclusion // .state) as $s | $s == "FAILURE" or $s == "ERROR")] | length' <<<"$1"; }

test_a_passing_rerun_supersedes_the_old_failure() {
  assert_eq "$(_red '{"statusCheckRollup":[
    {"workflowName":"Large files","name":"check","conclusion":"FAILURE","completedAt":"2026-10-25T09:00:00Z"},
    {"workflowName":"Large files","name":"check","conclusion":"SUCCESS","completedAt":"2026-10-25T09:30:00Z"},
    {"workflowName":"Builder","name":"build","conclusion":"SUCCESS","completedAt":"2026-10-25T09:31:00Z"}]}')" 0
}
test_a_failing_rerun_is_still_red() {
  assert_eq "$(_red '{"statusCheckRollup":[
    {"workflowName":"Large files","name":"check","conclusion":"SUCCESS","completedAt":"2026-10-25T09:00:00Z"},
    {"workflowName":"Large files","name":"check","conclusion":"FAILURE","completedAt":"2026-10-25T09:30:00Z"}]}')" 1
}
test_same_check_name_in_another_workflow_is_its_own_check() {
  assert_eq "$(_red '{"statusCheckRollup":[
    {"workflowName":"A","name":"test","conclusion":"FAILURE","completedAt":"2026-10-25T09:00:00Z"},
    {"workflowName":"B","name":"test","conclusion":"SUCCESS","completedAt":"2026-10-25T09:30:00Z"},
    {"context":"legacy/status","state":"ERROR"}]}')" 2
}
