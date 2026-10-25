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
# gh gives a running re-run completedAt 0001-01-01; it is the latest run, so
# the check is pending - never the older green.
test_a_running_rerun_is_not_green() {
  local out; out="$(jq -r "$CEL_JQ_LATEST_CHECKS"'[.statusCheckRollup | latest_checks[] | .status] | join(",")' <<<'{"statusCheckRollup":[
    {"workflowName":"Large files","name":"check","conclusion":"SUCCESS","status":"COMPLETED","startedAt":"2026-10-25T08:58:00Z","completedAt":"2026-10-25T09:00:00Z"},
    {"workflowName":"Large files","name":"check","conclusion":"","status":"IN_PROGRESS","startedAt":"2026-10-25T09:30:00Z","completedAt":"0001-01-01T00:00:00Z"}]}')"
  assert_eq "$out" "IN_PROGRESS"
}
test_same_check_name_in_another_workflow_is_its_own_check() {
  assert_eq "$(_red '{"statusCheckRollup":[
    {"workflowName":"A","name":"test","conclusion":"FAILURE","completedAt":"2026-10-25T09:00:00Z"},
    {"workflowName":"B","name":"test","conclusion":"SUCCESS","completedAt":"2026-10-25T09:30:00Z"},
    {"context":"legacy/status","state":"ERROR"}]}')" 2
}
