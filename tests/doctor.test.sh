# shellcheck shell=bash
# `cel doctor` - the box services line.
#
# Nothing here touches the live box: CEL_SERVICES_D is a fixture directory and
# the gateway config is a fixture file.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/doctor.sh"

_doctor_setup() {
  T="$(mktemp -d)"
  export CEL_SERVICES_D="$T/services.d"
  export CEL_CONFIG_FILE="$T/config.yaml"
  mkdir -p "$CEL_SERVICES_D"
}
_doctor_teardown() { rm -rf "$T"; unset CEL_SERVICES_D CEL_CONFIG_FILE; }

# One line: how many the box declares and how many are actually answering.
test_doctor_counts_box_services() {
  _doctor_setup
  printf '{"name":"cel-auth-broker","port":47311,"health":"/"}\n' > "$CEL_SERVICES_D/cel-auth-broker.json"
  local out; out="$(doctor_box_services_line)"
  assert_contains "$out" "box services: 1 declared"
  assert_contains "$out" "healthy"
  _doctor_teardown
}

# The failure this ticket exists for: a box with a gateway in its config and
# nothing in services.d is a gateway nobody is watching, and doctor is where
# that gets said out loud.
test_doctor_says_the_gateway_is_not_supervised() {
  _doctor_setup
  cel_config_set gateway gateway_port 47411
  assert_contains "$(doctor_box_services_line)" "cel gateway install"
  printf '{"name":"cel-auth-gateway","port":47411}\n' > "$CEL_SERVICES_D/cel-auth-gateway.json"
  ! printf '%s' "$(doctor_box_services_line)" | grep -q "not supervised" \
    || { echo "doctor calls a supervised gateway unsupervised"; _doctor_teardown; return 1; }
  _doctor_teardown
}
