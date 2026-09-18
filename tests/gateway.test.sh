# shellcheck shell=bash
# `cel gateway` - several subscriptions behind one loopback door.
#
# Nothing here touches the box's real broker, its real gateway or the owner's
# ~/.pi/agent/models.json: `omp` is a stub on a prepended PATH that prints
# canned JSON and logs its argv, the config file is a fixture, and the one
# test that proves the HTTP path runs a throwaway python server on a port the
# kernel chose. The fixture token is asserted AGAINST: a bearer that grants
# every subscription on the box must never reach stdout, a config file or a
# launch line.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/gateway.sh"

GW_FIXTURE_TOKEN='gw-fixture-token-do-not-print'

# The account table as `omp auth-gateway check --json` really shapes it
# (verified against omp 18.1.17): credentials[], each with a report.limits[]
# carrying a window and an amount. Two codex accounts, one exhausted and one
# with room, plus an api_key credential the balancer never uses.
_gw_check_json() {
  cat <<'EOF'
{"broker":"http://127.0.0.1:47311","strict":false,"credentials":[
 {"id":1,"provider":"openai-codex","type":"oauth","ok":true,
  "email":"someone@example.invalid","accountId":"aaaaaaaa-1111-2222-3333-444444444444",
  "report":{"provider":"openai-codex","limits":[
    {"label":"7 days","window":{"id":"7d","resetsAt":1789994511000},
     "amount":{"used":100,"limit":100,"usedFraction":1,"unit":"percent"},"status":"exhausted"}]}},
 {"id":7,"provider":"openai-codex","type":"oauth","ok":true,
  "email":"other@example.invalid","accountId":"bbbbbbbb-1111-2222-3333-444444444444",
  "report":{"provider":"openai-codex","limits":[
    {"label":"7 days","window":{"id":"7d","resetsAt":1789994511000},
     "amount":{"used":12,"limit":100,"usedFraction":0.12,"unit":"percent"},"status":"ok"}]}},
 {"id":3,"provider":"opencode-go","type":"api_key","ok":true,"report":{"provider":"opencode-go","limits":[]}}]}
EOF
}

_gw_setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/pi"
  export CEL_CONFIG_FILE="$T/config.yaml"
  export CEL_GATEWAY_STATE="$T/state"
  export PI_CODING_AGENT_DIR="$T/pi"
  cat >"$T/bin/omp" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/omp.argv"
case "\$1 \$2" in
  "auth-broker token")    printf '%s\n' '$GW_FIXTURE_TOKEN' ;;
  "auth-gateway token")   printf '%s\n' '$GW_FIXTURE_TOKEN' ;;
  "auth-broker status")   printf '%s\n' '{"url":"http://127.0.0.1:47311","ok":true,"version":"18.1.17"}' ;;
  "auth-gateway status")  printf '%s\n' '{"ready":true,"reason":null,"credentialCount":5}' ;;
  "auth-gateway check")   cat "$T/check.json" ;;
  *) : ;;
esac
EOF
  chmod +x "$T/bin/omp"
  _gw_check_json > "$T/check.json"
  PATH="$T/bin:$PATH"
  # No live gateway in a test: the HTTP reads answer from this stub unless a
  # test replaces it. `ready` decides whether the door is open at all.
  cat >"$T/gwstub" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ready)  exit "${GW_STUB_DOWN:-0}" ;;
  models) printf '%s\n' '{"data":[{"id":"openai-codex/gpt-5.5","context_length":272000,"max_output_tokens":8192},{"id":"opencode-go/qwen3.8-flash","context_length":128000,"max_output_tokens":4096}]}' ;;
esac
EOF
  chmod +x "$T/gwstub"
  export CEL_GATEWAY_STUB="$T/gwstub"
}
_gw_teardown() { rm -rf "$T"; unset CEL_CONFIG_FILE CEL_GATEWAY_STUB CEL_GATEWAY_STATE PI_CODING_AGENT_DIR; }

# --- install --------------------------------------------------------------

test_gateway_install_writes_the_ports_and_both_services() {
  _gw_setup
  local out; out="$(cmd_gateway install --no-start)"
  assert_eq "$(cel_config_get gateway broker_port)" 47311
  assert_eq "$(cel_config_get gateway gateway_port)" 47411
  local specs; specs="$(gateway_service_specs)"
  assert_contains "$specs" "auth-broker serve --bind 127.0.0.1:47311"
  assert_contains "$specs" "auth-gateway serve --bind 127.0.0.1:47411"
  # health is a real read of the gateway, not a port knock: the door can be
  # listening with no usable credential behind it.
  assert_contains "$specs" "/v1/models"
  assert_contains "$out" "gateway"
  _gw_teardown
}

# LOOPBACK ONLY. The bearer grants every subscription in the vault to whatever
# can reach the port; a bind that answered the LAN would hand the box's
# accounts to the network.
test_gateway_binds_loopback_only() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local specs; specs="$(gateway_service_specs)"
  ! printf '%s' "$specs" | grep -q '0\.0\.0\.0' || { echo "gateway bound to every interface"; _gw_teardown; return 1; }
  _gw_teardown
}

# The gateway service is useless without the broker's address and bearer, so
# install puts both in its environment - by NAME here, never by value.
test_gateway_service_env_names_the_broker_without_printing_its_token() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local specs; specs="$(gateway_service_specs)"
  assert_contains "$specs" "OMP_AUTH_BROKER_URL"
  assert_contains "$specs" "OMP_AUTH_BROKER_TOKEN"
  ! printf '%s' "$specs" | grep -q "$GW_FIXTURE_TOKEN" || { echo "the broker token is in the service spec"; _gw_teardown; return 1; }
  _gw_teardown
}

# --- status ---------------------------------------------------------------

test_gateway_status_renders_the_account_table() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local out; out="$(cmd_gateway status)"
  assert_contains "$out" "broker"
  assert_contains "$out" "openai-codex"
  assert_contains "$out" "exhausted"
  assert_contains "$out" "7 days"
  _gw_teardown
}

# The QUOTA view lists gateway accounts beside the direct ones, so the JSON is
# the same row shape a subscription is - with `source: gateway` to say where
# it came from.
test_gateway_status_json_is_a_subscription_row_per_account() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local js; js="$(cmd_gateway status --json)"
  assert_eq "$(printf '%s' "$js" | jq -r '.accounts | length')" 3
  assert_eq "$(printf '%s' "$js" | jq -r '.accounts[0].source')" gateway
  assert_eq "$(printf '%s' "$js" | jq -r '.accounts[0].provider')" openai-codex
  assert_eq "$(printf '%s' "$js" | jq -r '.accounts[0].windows[0].state')" exhausted
  assert_eq "$(printf '%s' "$js" | jq -r '.accounts[0].windows[0].used_pct')" 100
  assert_eq "$(printf '%s' "$js" | jq -r '.ready')" true
  _gw_teardown
}

# SHORT IDS ONLY. The account table is read over someone's shoulder and pasted
# into tickets; the email on a subscription is personal data that no operator
# decision needs.
test_gateway_status_shows_short_ids_and_no_email() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local out; out="$(cmd_gateway status; cmd_gateway status --json)"
  ! printf '%s' "$out" | grep -q "example.invalid" || { echo "an account email reached the status output"; _gw_teardown; return 1; }
  assert_contains "$out" "aaaaaa"
  ! printf '%s' "$out" | grep -q "aaaaaaaa-1111-2222-3333-444444444444" || { echo "the full account id is noise"; _gw_teardown; return 1; }
  _gw_teardown
}

# The one rule the whole feature rests on: the bearer is never printed.
test_gateway_never_prints_the_token() {
  _gw_setup
  local out; out="$(cmd_gateway install --no-start; cmd_gateway status; cmd_gateway status --json; gateway_doctor_line)"
  ! printf '%s' "$out" | grep -q "$GW_FIXTURE_TOKEN" || { echo "the gateway token reached stdout"; _gw_teardown; return 1; }
  ! grep -rq "$GW_FIXTURE_TOKEN" "$CEL_CONFIG_FILE" || { echo "the gateway token was written to the config"; _gw_teardown; return 1; }
  _gw_teardown
}

test_gateway_usable_count_is_per_provider() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  assert_eq "$(gateway_usable_count)" 3
  assert_eq "$(gateway_usable_count openai-codex)" 2
  assert_eq "$(gateway_usable_count anthropic)" 0
  _gw_teardown
}

# --- login ----------------------------------------------------------------

# A login is an interactive OAuth dance. Off a TTY - a steward tick, a worker,
# a script - the answer is the instruction, not a hung process holding a
# terminal nobody is looking at.
test_gateway_login_off_a_tty_prints_the_instruction() {
  _gw_setup
  local out; out="$(cmd_gateway login anthropic < /dev/null)"
  assert_contains "$out" "omp auth-broker login anthropic"
  ! grep -q "auth-broker login" "$T/omp.argv" 2>/dev/null || { echo "a non-interactive login was actually run"; _gw_teardown; return 1; }
  _gw_teardown
}
test_gateway_logout_names_the_credential() {
  _gw_setup
  cmd_gateway logout anthropic 5 >/dev/null
  assert_contains "$(cat "$T/omp.argv")" "auth-broker logout anthropic"
  _gw_teardown
}

# --- doctor ---------------------------------------------------------------

# A provider with nothing usable is the whole failure mode: on this box every
# anthropic credential is disabled, so `ompgw/anthropic/...` fails with
# "Unknown model" rather than "auth expired". Doctor says the verb instead.
test_gateway_doctor_line_names_the_verb_for_a_provider_with_nothing_usable() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local out; out="$(CEL_GATEWAY_WATCH=anthropic gateway_doctor_line)"
  assert_contains "$out" "cel gateway login anthropic"
  assert_contains "$out" "gateway"
  _gw_teardown
}
test_gateway_doctor_line_says_not_installed_when_it_is_not() {
  _gw_setup
  local out; out="$(gateway_doctor_line)"
  assert_contains "$out" "not installed"
  _gw_teardown
}

# --- the pi provider ------------------------------------------------------

# models.json is the OWNER's file. Merging must add `ompgw` and leave every
# other provider exactly as it was - the first draft of this rewrote the
# document from the gateway's model list and would have dropped a hand-written
# provider block.
test_pi_models_merge_adds_ompgw_without_clobbering_a_provider() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  cat >"$T/pi/models.json" <<'EOF'
{"providers":{"mine":{"name":"my own","baseUrl":"https://example.invalid/v1","models":[{"id":"m1"}]}}}
EOF
  gateway_pi_models_write "$T/pi/models.json"
  local f="$T/pi/models.json"
  assert_eq "$(jq -r '.providers.mine.baseUrl' "$f")" "https://example.invalid/v1"
  assert_eq "$(jq -r '.providers.ompgw.baseUrl' "$f")" "http://127.0.0.1:47411/v1"
  assert_eq "$(jq -r '.providers.ompgw.apiKey' "$f")" '$OMP_GATEWAY_TOKEN'
  assert_eq "$(jq -r '.providers.ompgw.headers["x-session-id"]' "$f")" '$CEL_SESSION_ID'
  assert_eq "$(jq -r '.providers.ompgw.api' "$f")" openai-completions
  # models come from GET /v1/models, never hand-written: pi replaces the
  # provider's list wholesale and an invented context window is silently wrong.
  assert_eq "$(jq -r '.providers.ompgw.models | length' "$f")" 2
  assert_eq "$(jq -r '.providers.ompgw.models[0].contextWindow' "$f")" 272000
  ! grep -q "$GW_FIXTURE_TOKEN" "$f" || { echo "the gateway token was written into models.json"; _gw_teardown; return 1; }
  _gw_teardown
}
test_pi_models_merge_creates_the_file_when_there_is_none() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  gateway_pi_models_write "$T/pi/models.json"
  assert_eq "$(jq -r '.providers.ompgw.api' "$T/pi/models.json")" openai-completions
  _gw_teardown
}

# --- the real HTTP path ---------------------------------------------------

# Everything above rides the stub seam. This one proves the curl that the seam
# stands in for: a throwaway server on a kernel-chosen port, answering
# /v1/models exactly as the gateway does.
test_gateway_reads_models_over_http() {
  _gw_setup
  unset CEL_GATEWAY_STUB
  mkdir -p "$T/srv/v1"
  printf '%s' '{"data":[{"id":"opencode-go/qwen3.8-flash","context_length":128000,"max_output_tokens":4096}]}' > "$T/srv/v1/models"
  local port; port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$T/srv" >/dev/null 2>&1 &
  local srv=$!
  local i=0; while [ "$i" -lt 50 ] && ! curl -sf -m1 "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
  cmd_gateway install --no-start >/dev/null
  cel_config_set gateway gateway_port "$port"
  local id ready=0
  id="$(gateway_models_json | jq -r '.data[0].id')"
  gateway_ready && ready=1
  # The port goes back to the kernel HERE, not whenever this process group is
  # reaped: an ephemeral port held across the rest of the suite is a port some
  # other test wanted, and that failure reads as that test's bug.
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null || true
  assert_eq "$id" "opencode-go/qwen3.8-flash"
  [ "$ready" -eq 1 ] || { echo "a gateway answering /v1/models was reported down"; _gw_teardown; return 1; }
  _gw_teardown
}
