# shellcheck shell=bash
# `cel gateway` - several subscriptions behind one loopback door, served by
# CLIProxyAPI.
#
# Nothing here starts a proxy, contacts an account or touches the owner's
# ~/.pi/agent/models.json: `cli-proxy-api`, `herdr`, `omp` and `curl` are stubs
# on a prepended PATH that log their argv and print canned JSON, the config
# file and the auth-dir are fixtures under mktemp, and the fixture token is
# asserted AGAINST - one api-key unlocks every subscription in the vault, so it
# must never reach stdout, a service file or models.json.
#
# THE OMP STUB IS A TRIPWIRE. CEL-60 removed omp's broker and gateway; if any
# `cel gateway` verb still shells out to omp, the argv log it writes fails the
# last test in this file rather than being discovered on a live box.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/gateway.sh"

GW_FIXTURE_SECRET='gw-fixture-secret-do-not-print'

# The auth-dir as CLIProxyAPI really writes it (SPIKE-cliproxy.report.md):
# one OAuth JSON per account, `claude-<hash>-<email>.json` and
# `codex-<hash>-<email>-<plan>.json`. The plan rides in the codex filename and
# nowhere else, which is why status reads the NAME and not only the contents.
_gw_auth_fixture() { # <dir>
  local d="$1"
  mkdir -p "$d"; chmod 700 "$d"
  cat >"$d/claude-a1b2c3d4-someone@example.invalid.json" <<EOF
{"access_token":"$GW_FIXTURE_SECRET","refresh_token":"$GW_FIXTURE_SECRET",
 "account":{"email_address":"someone@example.invalid","uuid":"aaaaaaaa-1111"}}
EOF
  cat >"$d/codex-9f8e7d6c-other@example.invalid-plus.json" <<EOF
{"access_token":"$GW_FIXTURE_SECRET",
 "account":{"email_address":"other@example.invalid"}}
EOF
  chmod 600 "$d"/*.json
}

_gw_setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/pi"
  export CEL_CONFIG_FILE="$T/config.yaml"
  export CEL_GATEWAY_STATE="$T/state"
  # services.d is a FIXTURE, always: `cel gateway install` registers a box
  # service, and a test that let it write to the real ~/.config/cel/services.d
  # left the live steward sweeping services this suite invented.
  export CEL_SERVICES_D="$T/services.d"
  export CEL_SERVICES_STATE="$T/services-state"
  export PI_CODING_AGENT_DIR="$T/pi"
  unset CEL_GATEWAY_STUB
  cat >"$T/bin/cli-proxy-api" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/cpa.argv"
exit 0
EOF
  # THE TRIPWIRE. Any omp invocation from a gateway verb lands here.
  cat >"$T/bin/omp" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/omp.argv"
exit 0
EOF
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/herdr.argv"
exit 0
EOF
  # The only HTTP this feature does: an unauthenticated GET /healthz and a
  # bearer-authenticated GET /v1/models. The stub records the whole argv so a
  # test can prove what was and was not sent.
  cat >"$T/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/curl.argv"
url=""
for a in "\$@"; do case "\$a" in http://*|https://*) url="\$a" ;; esac; done
case "\$url" in
  */healthz)   exit "\${GW_DOWN:-0}" ;;
  */v1/models) printf '%s\n' '{"data":[{"id":"gpt-5.5","context_length":272000,"max_output_tokens":8192},{"id":"claude-sonnet-4-6","context_length":200000,"max_output_tokens":64000}]}' ;;
  *) exit 7 ;;
esac
EOF
  chmod +x "$T/bin/cli-proxy-api" "$T/bin/omp" "$T/bin/herdr" "$T/bin/curl"
  PATH="$T/bin:$PATH"
}
_gw_teardown() {
  rm -rf "$T"
  unset CEL_CONFIG_FILE CEL_GATEWAY_STATE PI_CODING_AGENT_DIR CEL_SERVICES_D CEL_SERVICES_STATE
}

# --- the config file ------------------------------------------------------

# CLIProxyAPI HAS NO FLAG-ONLY MODE: the settings below exist only in the file
# `cel gateway install` writes, so each one is asserted BY KEY - an edit that
# drops a line goes red here rather than on a box that quietly serves the LAN.
test_gateway_config_binds_loopback_only() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local f; f="$(gateway_config_file)"
  assert_eq "$(yq -r '.host' "$f")" "127.0.0.1"
  assert_eq "$(yq -r '.port' "$f")" "$(gateway_port)"
  _gw_teardown
}

# THE DEFAULT IS false, AND false MEANS A WORKER SWITCHES ACCOUNT MID-TASK.
# One account for the length of a conversation is the entire point; without
# this the gateway is a worse single account than no gateway at all.
test_gateway_config_turns_session_affinity_on() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  assert_eq "$(yq -r '.routing["session-affinity"]' "$(gateway_config_file)")" "true"
  _gw_teardown
}

# ONE API-KEY UNLOCKS EVERY SUBSCRIPTION IN THE VAULT. The management API is
# left out of the file entirely, so nothing can be reached from off this box.
test_gateway_config_never_enables_remote_management() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  ! grep -Eq '^[[:space:]]*allow-remote:' "$(gateway_config_file)" \
    || { echo "the written config enables remote management"; _gw_teardown; return 1; }
  _gw_teardown
}

# The vault is not a repository file and never becomes one: a worktree gets
# committed, pushed and read by a reviewer.
test_gateway_auth_dir_is_private_and_outside_every_repo() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local d; d="$(gateway_auth_dir)"
  assert_eq "$(yq -r '.["auth-dir"]' "$(gateway_config_file)")" "$d"
  assert_eq "$(stat -c %a "$d")" 700
  case "$d" in "$CEL_ROOT"/*) echo "the auth-dir is inside the repo"; _gw_teardown; return 1 ;; esac
  # 0600 on the config, because the api-key list lives in it.
  assert_eq "$(stat -c %a "$(gateway_config_file)")" 600
  _gw_teardown
}

# --- the box service ------------------------------------------------------

# ONE SERVICE, not two. omp needed a broker AND a gateway; CLIProxyAPI is one
# process, and a second declaration would be a second thing to be down.
test_gateway_registers_exactly_one_box_service() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  assert_eq "$(ls "$T/services.d" | wc -l)" 1
  local f="$T/services.d/cel-auth-gateway.json"
  assert_contains "$(jq -r '.cmd' "$f")" "cli-proxy-api"
  assert_eq "$(jq -r '.restart' "$f")" auto
  _gw_teardown
}

# /healthz IS UNAUTHENTICATED, which is the health probe this gateway never
# had: omp's only readable route was /v1/models behind a bearer, so the check
# had to carry the key that unlocks every subscription just to say "up".
test_gateway_service_health_is_unauthenticated_healthz() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local f="$T/services.d/cel-auth-gateway.json"
  assert_contains "$(jq -r '.health' "$f")" "/healthz"
  assert_eq "$(jq -r '.health_auth // ""' "$f")" ""
  ! grep -q "$GW_FIXTURE_SECRET" "$f" \
    || { echo "the api-key is in the service file"; _gw_teardown; return 1; }
  _gw_teardown
}

test_gateway_install_is_idempotent() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local key1 out
  key1="$(cat "$(gateway_state_dir)/api-key")"
  out="$(cmd_gateway install --no-start)"
  assert_eq "$(ls "$T/services.d" | wc -l)" 1
  # The api-key is minted ONCE: a second install that rolled it would log out
  # every pi worker already launched against this gateway.
  assert_eq "$(cat "$(gateway_state_dir)/api-key")" "$key1"
  assert_contains "$out" "supervised"
  _gw_teardown
}

# --- health ---------------------------------------------------------------

test_gateway_ready_reads_healthz_without_a_bearer() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  gateway_ready || { echo "a gateway answering /healthz was reported down"; _gw_teardown; return 1; }
  assert_contains "$(cat "$T/curl.argv")" "/healthz"
  ! grep -q "Authorization" "$T/curl.argv" \
    || { echo "the health probe presented a bearer"; _gw_teardown; return 1; }
  _gw_teardown
}

test_gateway_not_ready_when_healthz_does_not_answer() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  GW_DOWN=1 assert_fails gateway_ready
  _gw_teardown
}

# --- the account table ----------------------------------------------------

# THE AUTH-DIR IS THE ACCOUNT LIST. The management API is off, so the files
# are the only evidence there is - and reading them costs no quota, which
# `omp auth-gateway check --strict` did once per status.
test_gateway_status_lists_accounts_from_the_auth_dir() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_auth_fixture "$(gateway_auth_dir)"
  local out; out="$(cmd_gateway status)"
  assert_contains "$out" "claude"
  assert_contains "$out" "codex"
  assert_contains "$out" "someone@example.invalid"
  assert_contains "$out" "other@example.invalid"
  # the plan only exists in the codex filename
  assert_contains "$out" "plus"
  _gw_teardown
}

test_gateway_status_json_is_a_subscription_row_per_account() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_auth_fixture "$(gateway_auth_dir)"
  local js; js="$(cmd_gateway status --json)"
  assert_eq "$(printf '%s' "$js" | jq -r '.accounts | length')" 2
  assert_eq "$(printf '%s' "$js" | jq -r '.accounts[0].source')" gateway
  assert_eq "$(printf '%s' "$js" | jq -r '.accounts[0].provider')" claude
  assert_eq "$(printf '%s' "$js" | jq -r '.accounts[1].provider')" codex
  assert_eq "$(printf '%s' "$js" | jq -r '.accounts[1].plan')" plus
  assert_eq "$(printf '%s' "$js" | jq -r '.ready')" true
  _gw_teardown
}

test_gateway_usable_count_is_per_provider() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_auth_fixture "$(gateway_auth_dir)"
  assert_eq "$(gateway_usable_count)" 2
  assert_eq "$(gateway_usable_count codex)" 1
  assert_eq "$(gateway_usable_count anthropic)" 0
  _gw_teardown
}

# THE RULE THE WHOLE FEATURE RESTS ON. The auth files hold live OAuth tokens
# and the config holds the api-key; a status command reads both and must print
# neither.
test_gateway_never_prints_a_secret() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_auth_fixture "$(gateway_auth_dir)"
  local out
  out="$(cmd_gateway install --no-start; cmd_gateway status; cmd_gateway status --json; gateway_doctor_line)"
  ! printf '%s' "$out" | grep -q "$GW_FIXTURE_SECRET" \
    || { echo "a token or api-key reached stdout"; _gw_teardown; return 1; }
  ! grep -q "$GW_FIXTURE_SECRET" "$CEL_CONFIG_FILE" \
    || { echo "a token was written into cel.yaml"; _gw_teardown; return 1; }
  local key; key="$(cat "$(gateway_state_dir)/api-key")"
  ! printf '%s' "$out" | grep -q "$key" \
    || { echo "the gateway api-key reached stdout"; _gw_teardown; return 1; }
  _gw_teardown
}

# --- login ----------------------------------------------------------------

# A login is an interactive OAuth dance with a browser on the other end. Off a
# TTY - a steward tick, a worker, a script - the answer is the instruction,
# not a process hanging on a terminal nobody is looking at.
test_gateway_login_off_a_tty_prints_the_instruction() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local out; out="$(cmd_gateway login claude < /dev/null)"
  assert_contains "$out" "-claude-login"
  [ ! -f "$T/cpa.argv" ] || { echo "a non-interactive login was actually run"; _gw_teardown; return 1; }
  _gw_teardown
}

# A headless box has no browser to hand the callback to, so codex gets the
# device flow instead.
test_gateway_login_codex_names_the_device_flow_without_a_browser() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local out; out="$(cmd_gateway login codex --no-browser < /dev/null)"
  assert_contains "$out" "-codex-device-login"
  assert_contains "$out" "-no-browser"
  _gw_teardown
}

# --- doctor ---------------------------------------------------------------

test_gateway_doctor_line_says_not_installed_when_it_is_not() {
  _gw_setup
  assert_contains "$(gateway_doctor_line)" "not installed"
  _gw_teardown
}

test_gateway_doctor_line_names_the_verb_for_a_provider_with_nothing_usable() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_auth_fixture "$(gateway_auth_dir)"
  local out; out="$(CEL_GATEWAY_WATCH=anthropic gateway_doctor_line)"
  assert_contains "$out" "cel gateway login anthropic"
  _gw_teardown
}

# --- the pi provider ------------------------------------------------------

# models.json is the OWNER's file: a writer that rebuilt the document from the
# gateway's model list would silently delete providers they added by hand.
test_pi_models_merge_keeps_the_owners_providers() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  cat >"$T/pi/models.json" <<'EOF'
{"providers":{"mine":{"name":"my own","baseUrl":"https://example.invalid/v1","models":[{"id":"m1"}]}}}
EOF
  gateway_pi_models_write "$T/pi/models.json"
  assert_eq "$(jq -r '.providers.mine.baseUrl' "$T/pi/models.json")" "https://example.invalid/v1"
  _gw_teardown
}

# PLAIN MODEL IDS AND THE SESSION HEADER. The ids carry no provider prefix
# (`force-model-prefix` stays false), so nothing in the plane has to cope with
# a three-segment model id; and the per-worker `x-session-id` is the ONLY
# thing affinity can pin an account by, because pi sends no session identity
# of its own.
test_pi_models_block_carries_the_session_header_and_plain_model_ids() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  gateway_pi_models_write "$T/pi/models.json"
  local f="$T/pi/models.json"
  assert_eq "$(jq -r '.providers.ompgw.baseUrl' "$f")" "http://127.0.0.1:$(gateway_port)/v1"
  assert_eq "$(jq -r '.providers.ompgw.headers["x-session-id"]' "$f")" '$CEL_SESSION_ID'
  assert_eq "$(jq -r '.providers.ompgw.api' "$f")" openai-completions
  assert_eq "$(jq -r '.providers.ompgw.models[0].id' "$f")" "gpt-5.5"
  assert_eq "$(jq -r '.providers.ompgw.models[0].contextWindow' "$f")" 272000
  # Claude models get pi's Anthropic surface, which the gateway serves at
  # /v1/messages - the same accounts, the richer protocol.
  assert_eq "$(jq -r '.providers["ompgw-claude"].api' "$f")" anthropic-messages
  assert_eq "$(jq -r '.providers["ompgw-claude"].models[0].id' "$f")" "claude-sonnet-4-6"
  assert_eq "$(jq -r '.providers["ompgw-claude"].headers["x-session-id"]' "$f")" '$CEL_SESSION_ID'
  # The api-key is a VARIABLE NAME: pi expands it in the pane, so no secret
  # is ever in this file.
  assert_eq "$(jq -r '.providers.ompgw.apiKey' "$f")" '$CEL_GATEWAY_API_KEY'
  local key; key="$(cat "$(gateway_state_dir)/api-key")"
  ! grep -q "$key" "$f" || { echo "the api-key was written into models.json"; _gw_teardown; return 1; }
  _gw_teardown
}

# --- omp is gone ----------------------------------------------------------

# CEL-60 replaced omp's broker and gateway with one CLIProxyAPI service. omp
# stays on the box as an AGENT RUNTIME, but nothing under `cel gateway` may
# call it any more - two credential vaults is the failure this ticket exists
# to end.
test_no_gateway_verb_invokes_omp() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_auth_fixture "$(gateway_auth_dir)"
  cmd_gateway status >/dev/null
  cmd_gateway status --json >/dev/null
  cmd_gateway login claude </dev/null >/dev/null
  gateway_doctor_line >/dev/null
  gateway_pi_models_write "$T/pi/models.json" >/dev/null
  [ ! -f "$T/omp.argv" ] \
    || { echo "a gateway verb still called omp: $(cat "$T/omp.argv")"; _gw_teardown; return 1; }
  ! grep -rn "omp " "$CEL_ROOT/lib/gateway.sh" | grep -vE '^\s*[0-9]+:\s*#' | grep -q . \
    || { echo "lib/gateway.sh still runs omp"; _gw_teardown; return 1; }
  _gw_teardown
}
