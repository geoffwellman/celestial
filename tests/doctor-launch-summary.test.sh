# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/doctor.sh"
source "$CEL_ROOT/lib/run.sh"
source "$CEL_ROOT/tests/lib/orch-stub.sh"

_dls_setup() {
  orch_stub_setup "$1"
  export CEL_CONFIG_FILE="$T/no-gateway-config"
  : > "$T/severity"
  # Observe the public diagnostic severity, not its incidental wording/colors.
  c_ok() { printf 'confirmed\n' >> "$T/severity"; }
  c_warn() { printf 'unverified\n' >> "$T/severity"; }
}
_dls_down() { unset CEL_CONFIG_FILE; orch_stub_teardown; }

test_doctor_launch_summary_does_not_confirm_rewritten_pi_argv() {
  _dls_setup pi
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/native.jsonl" pi
  orch_stub_bare_proc 100 pi
  doctor_stale_orchestrator_lines
  assert_eq "$(cat "$T/severity")" unverified
  _dls_down
}

test_doctor_launch_summary_does_not_confirm_empty_inventory() {
  _dls_setup omp
  printf '{"result":{"agents":[]}}\n' > "$T/roster.json"
  doctor_stale_orchestrator_lines
  assert_eq "$(cat "$T/severity")" unverified
  _dls_down
}

test_doctor_launch_summary_confirms_a_complete_observable_launch() {
  _dls_setup omp
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/native.jsonl" omp
  _run_expected_launch "$T/plan" alpha orchestrator widget herdr >/dev/null
  local -a argv
  mapfile -d '' -t argv < "$T/plan"
  orch_stub_proc 100 widget-orch "$T/ws" "${argv[@]}"
  : > "$T/severity"
  doctor_stale_orchestrator_lines
  assert_eq "$(cat "$T/severity")" confirmed
  _dls_down
}
