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
  export CEL_PI_AGENT_DIR="$T/pi"
  unset CEL_GATEWAY_STUB
  cat >"$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Claude Code 2.1.299'
EOF
  chmod +x "$T/bin/claude"
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
  */v1/models)
    if [ -n "\${GW_MODELS:-}" ]; then printf '%s\n' "\$GW_MODELS"; else
    printf '%s\n' '{"data":[{"id":"gpt-5.5","context_length":272000,"max_output_tokens":8192},{"id":"claude-sonnet-4-6","context_length":200000,"max_output_tokens":64000},{"id":"claude-opus-5-5","context_length":1000000,"max_output_tokens":128000},{"id":"claude-opus-4-8","context_length":1000000,"max_output_tokens":128000},{"id":"claude-custom-unknown","context_length":200000,"max_output_tokens":64000}]}'; fi ;;
  */v0/management/auth-files/fields)
    prev=""; for a in "\$@"; do [ "\$prev" = -d ] && printf '%s\n' "\$a" >> "$T/curl.body"; prev="\$a"; done
    cat >/dev/null
    printf '{"status":"ok"}' ;;
  *) exit 7 ;;
esac
EOF
  chmod +x "$T/bin/cli-proxy-api" "$T/bin/omp" "$T/bin/herdr" "$T/bin/curl"
  PATH="$T/bin:$PATH"
}
_gw_teardown() {
  rm -rf "$T"
  unset CEL_CONFIG_FILE CEL_GATEWAY_STATE CEL_PI_AGENT_DIR CEL_SERVICES_D CEL_SERVICES_STATE
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

# THE MANAGEMENT API IS ON FOR LOOPBACK ONLY (CEL-80). CEL-60 left it out,
# which left the web panel CLIProxyAPI serves at /management.html unable to
# read or change anything. Keys checked against CLIProxyAPI 7.3.14's own
# config struct, and again against 8.0.29's (CEL-135): `remote-management.{allow-remote, secret-key,
# disable-control-panel}`.
test_gateway_config_enables_management_for_loopback_only() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local f; f="$(gateway_config_file)"
  assert_eq "$(yq -r '.["remote-management"]["allow-remote"]' "$f")" false
  assert_eq "$(yq -r '.["remote-management"]["disable-control-panel"]' "$f")" false
  local k; k="$(gateway_state_dir)/management-key"
  assert_eq "$(stat -c %a "$k")" 600
  assert_eq "$(yq -r '.["remote-management"]["secret-key"]' "$f")" "$(cat "$k")"
  # minted once: a second install keeps the key the panel was opened with
  local before; before="$(cat "$k")"
  cmd_gateway install --no-start >/dev/null
  assert_eq "$(cat "$k")" "$before"
  _gw_teardown

}
test_gateway_config_derives_claude_user_agent_from_installed_version() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  assert_eq "$(yq -r '.["claude-header-defaults"]["user-agent"]' "$(gateway_config_file)")" \
    "claude-cli/2.1.299 (external, cli)"
  _gw_teardown
}

# The panel is a loopback page; the tunnel line is how a laptop reaches it,
# because it must never be exposed on the tailnet.
test_gateway_panel_prints_the_url_and_the_tunnel_never_the_key() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local p out; p="$(gateway_port)"
  out="$(cmd_gateway panel)"
  assert_contains "$out" "http://127.0.0.1:$p/management.html"
  assert_contains "$out" "ssh -L $p:127.0.0.1:$p"
  assert_eq "$(cmd_gateway panel --json | jq -r '.url')" "http://127.0.0.1:$p/management.html"
  assert_contains "$(cmd_gateway panel --json | jq -r '.ssh')" "ssh -L $p:127.0.0.1:$p"
  local key; key="$(cat "$(gateway_state_dir)/management-key")"
  case "$out$(cmd_gateway install --no-start 2>&1)" in *"$key"*)
    echo "the management key reached stdout"; _gw_teardown; return 1 ;; esac
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
  assert_eq "$(jq -r '.providers["ompgw-claude"].baseUrl' "$f")" "http://127.0.0.1:$(gateway_port)"
  assert_eq "$(jq -r '.providers["ompgw-claude"].api' "$f")" anthropic-messages
  assert_eq "$(jq -r '.providers["ompgw-claude"].models[0].id' "$f")" "claude-sonnet-4-6"
  assert_eq "$(jq -r '.providers["ompgw-claude"].headers["x-session-id"]' "$f")" '$CEL_SESSION_ID'
  # The api-key is a VARIABLE NAME: pi expands it in the pane, so no secret
  # is ever in this file.
  assert_eq "$(jq -r '.providers.ompgw.apiKey' "$f")" '$OMP_GATEWAY_TOKEN'
  local key; key="$(cat "$(gateway_state_dir)/api-key")"
  ! grep -q "$key" "$f" || { echo "the api-key was written into models.json"; _gw_teardown; return 1; }
  _gw_teardown
}
test_pi_models_claude_provider_key_matches_profile_model_id() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  gateway_pi_models_write "$T/pi/models.json"
  local f="$T/pi/models.json" model_id provider_id
  model_id="ompgw-claude/$(jq -r '.providers["ompgw-claude"].models[0].id' "$f")"
  provider_id="$(gateway_pi_provider_for_model "claude-sonnet-4-6")/claude-sonnet-4-6"
  assert_eq "$provider_id" "$model_id"
  assert_eq "$(jq -r '.providers["ompgw-claude"].apiKey' "$f")" '$OMP_GATEWAY_TOKEN'
  _gw_teardown
}

test_pi_models_use_canonical_opus_thinking_capabilities_only() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  gateway_pi_models_write "$T/pi/models.json"
  local f="$T/pi/models.json"
  local opus55='.providers["ompgw-claude"].models[] | select(.id == "claude-opus-5-5")'
  local other_opus='.providers["ompgw-claude"].models[] | select(.id == "claude-opus-4-8")'
  local unknown='.providers["ompgw-claude"].models[] | select(.id == "claude-custom-unknown")'
  assert_eq "$(jq -r "$opus55 | .reasoning" "$f")" true
  assert_eq "$(jq -c "$opus55 | .thinkingLevelMap" "$f")" \
    '{"off":null,"minimal":null,"low":"low","medium":"medium","high":"high","xhigh":"xhigh","max":"max"}'
  assert_eq "$(jq -r "$opus55 | .compat.forceAdaptiveThinking" "$f")" true
  assert_eq "$(jq -r "$opus55 | .compat.supportsMidConvoEffort" "$f")" true
  assert_eq "$(jq -r "$opus55 | .compat.supportsMidConvoSystemMessages" "$f")" true
  assert_eq "$(jq -r "$opus55 | .compat.supportsMidConvoToolChanges" "$f")" true
  assert_eq "$(jq -r "$opus55 | .compat.supportsTemperature" "$f")" false
  assert_eq "$(jq -r "$opus55 | .compat.supportsStrictTools" "$f")" true
  assert_eq "$(jq -r "$other_opus | has(\"reasoning\")" "$f")" false
  assert_eq "$(jq -r "$unknown | has(\"reasoning\")" "$f")" false
  assert_eq "$(jq -r '.providers.ompgw.models[] | select(.id == "gpt-5.5") | has("reasoning")' "$f")" false
  _gw_teardown
}

# The live gateway publishes bare ids (no context_length/max_output_tokens),
# so the generic 128000/8192 fallback must never win for a 5.5 Claude model:
# Opus and Sonnet 5.5 carry their native window, output, input and adaptive
# thinking. Unknown claude ids stay on the generic fallback.
test_pi_models_project_native_5_5_capabilities_from_bare_ids() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  export GW_MODELS='{"data":[{"id":"claude-sonnet-5-5"},{"id":"claude-opus-5-5"},{"id":"claude-custom-unknown"}]}'
  gateway_pi_models_write "$T/pi/models.json"
  local f="$T/pi/models.json" m
  for m in claude-sonnet-5-5 claude-opus-5-5; do
    local q=".providers[\"ompgw-claude\"].models[] | select(.id == \"$m\")"
    assert_eq "$(jq -r "$q | .contextWindow" "$f")" 1000000
    assert_eq "$(jq -r "$q | .maxTokens" "$f")" 128000
    assert_eq "$(jq -r "$q | .reasoning" "$f")" true
    assert_eq "$(jq -c "$q | .input" "$f")" '["text","image"]'
    assert_eq "$(jq -r "$q | .thinkingLevelMap.medium" "$f")" medium
    assert_eq "$(jq -r "$q | .compat.forceAdaptiveThinking" "$f")" true
  done
  local u='.providers["ompgw-claude"].models[] | select(.id == "claude-custom-unknown")'
  assert_eq "$(jq -r "$u | .contextWindow" "$f")" 128000
  assert_eq "$(jq -r "$u | has(\"reasoning\")" "$f")" false
  unset GW_MODELS
  _gw_teardown
}

test_pi_models_provider_helper_recognises_claude_slash_model() {
  assert_eq "$(gateway_pi_provider_for_model "claude/claude-sonnet-4-6")" ompgw-claude
}

# --- the omp provider (CEL-136) -------------------------------------------

# A vault with a PERSONAL claude account the omp orchestrator must never use,
# two pool accounts, and a personal codex account. The email is matched in the
# filename AND in the JSON, case-insensitively, so a file whose name lost the
# address still cannot slip into the omp pool.
_gw_omp_vault() { # <dir>
  local d="$1"
  mkdir -p "$d"; chmod 700 "$d"
  printf '{"type":"claude","email":"Me@Personal.invalid","access_token":"%s"}' "$GW_FIXTURE_SECRET" \
    >"$d/claude-11111111-me@personal.invalid.json"
  printf '{"type":"claude","email":"pool-a@example.invalid","access_token":"%s"}' "$GW_FIXTURE_SECRET" \
    >"$d/claude-22222222-pool-a@example.invalid.json"
  printf '{"type":"claude","account":{"email_address":"me@personal.invalid"},"access_token":"%s"}' "$GW_FIXTURE_SECRET" \
    >"$d/claude-33333333-renamed.json"
  printf '{"type":"claude","email":"pool-b@example.invalid","prefix":"omp","access_token":"%s"}' "$GW_FIXTURE_SECRET" \
    >"$d/claude-44444444-pool-b@example.invalid.json"
  printf '{"type":"codex","email":"me@personal.invalid","access_token":"%s"}' "$GW_FIXTURE_SECRET" \
    >"$d/codex-55555555-me@personal.invalid-plus.json"
  chmod 600 "$d"/*.json
}

# The catalog omp itself resolved for its built-in anthropic provider: the
# thinking MODE lives only here (`omp models --json` flattens it to levels),
# and a guessed mode is how pi earned its thinking.type.disabled 400s.
_gw_omp_catalog() { # <file>
  cat >"$1" <<'EOF'
[{"id":"claude-sonnet-4-6","name":"Claude Sonnet 4.6","reasoning":true,"input":["text","image"],
  "contextWindow":1000000,"maxTokens":128000,
  "thinking":{"mode":"anthropic-adaptive","efforts":["low","medium","high"],"prefixBinding":true},
  "compat":{"officialEndpoint":true},"baseUrl":"https://api.anthropic.com/v1"}]
EOF
}

# THE EXCLUSION FAILS CLOSED. With no excluded identity configured the pool
# would be every claude account in the vault, personal included - the exact
# widening the orchestrator was moved off its direct creds to avoid.
test_gateway_omp_scope_refuses_without_an_exclusion() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_omp_vault "$(gateway_auth_dir)"
  assert_fails gateway_omp_scope_plan
  _gw_teardown
}

# The owner can include the personal account deliberately: only the literal
# `gateway.omp_include_all: true` lifts the empty-exclusion refusal. Absent or
# malformed values (yes, 1, True-ish typos) stay closed.
test_gateway_omp_scope_opt_in_must_be_explicit_true() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_omp_vault "$(gateway_auth_dir)"
  local v
  for v in yes 1 on '""' maybe; do
    cel_config_set gateway omp_include_all "$v"
    assert_fails gateway_omp_scope_plan
    assert_fails gateway_omp_scope_check
  done
  _gw_teardown
}

test_gateway_omp_scope_opt_in_includes_every_claude_account() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_omp_vault "$(gateway_auth_dir)"
  cel_config_set gateway omp_include_all true
  local plan; plan="$(gateway_omp_scope_plan)"
  assert_eq "$(jq -r '[.[] | select(.excluded)] | length' <<<"$plan")" 0
  assert_eq "$(jq -r '[.[] | select(.action == "add")] | map(.file) | join(",")' <<<"$plan")" \
    "claude-11111111-me@personal.invalid.json,claude-22222222-pool-a@example.invalid.json,claude-33333333-renamed.json"
  ! jq -e '.[] | select(.file | startswith("codex"))' <<<"$plan" >/dev/null \
    || { echo "codex reached the omp plan"; _gw_teardown; return 1; }
  gateway_omp_scope_check >/dev/null || { echo "opt-in check failed"; _gw_teardown; return 1; }
  gateway_omp_scope_apply >/dev/null || { echo "opt-in apply failed"; _gw_teardown; return 1; }
  assert_eq "$(grep -c 'auth-files/fields' "$T/curl.argv")" 3
  _gw_teardown
}

# Exclusions still win over the opt-in: it only permits an EMPTY list.
test_gateway_omp_scope_opt_in_keeps_configured_exclusions() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_omp_vault "$(gateway_auth_dir)"
  cel_config_set gateway omp_include_all true
  cel_config_set gateway omp_exclude "pool-a@example.invalid"
  local plan; plan="$(gateway_omp_scope_plan)"
  assert_eq "$(jq -r '[.[] | select(.excluded)] | map(.file) | join(",")' <<<"$plan")" \
    "claude-22222222-pool-a@example.invalid.json"
  local f; f="$(gateway_auth_dir)/claude-22222222-pool-a@example.invalid.json"
  jq '.prefix = "omp"' "$f" >"$f.t" && mv "$f.t" "$f"
  assert_fails gateway_omp_scope_check
  _gw_teardown
}

# The plan names pool accounts only: personal-by-filename and
# personal-by-JSON-only are both out, and codex is not in the omp pool at all.
test_gateway_omp_scope_plan_excludes_the_personal_account_by_name_and_by_content() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_omp_vault "$(gateway_auth_dir)"
  cel_config_set gateway omp_exclude "me@personal.invalid"
  local plan; plan="$(gateway_omp_scope_plan)"
  assert_eq "$(jq -r '[.[] | select(.action == "add")] | map(.file) | join(",")' <<<"$plan")" \
    "claude-22222222-pool-a@example.invalid.json"
  assert_eq "$(jq -r '[.[] | select(.action == "keep")] | map(.file) | join(",")' <<<"$plan")" \
    "claude-44444444-pool-b@example.invalid.json"
  assert_eq "$(jq -r '[.[] | select(.excluded)] | length' <<<"$plan")" 2
  ! jq -e '.[] | select(.file | startswith("codex"))' <<<"$plan" >/dev/null \
    || { echo "codex reached the omp plan"; _gw_teardown; return 1; }
  ! grep -q "$GW_FIXTURE_SECRET" <<<"$plan" || { echo "a token reached the plan"; _gw_teardown; return 1; }
  _gw_teardown
}

# An excluded account that already carries the prefix is in the omp pool NOW,
# so the check fails and apply takes it out.
test_gateway_omp_scope_check_fails_when_an_excluded_account_is_prefixed() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_omp_vault "$(gateway_auth_dir)"
  cel_config_set gateway omp_exclude "me@personal.invalid"
  gateway_omp_scope_check >/dev/null || { echo "clean vault failed the check"; _gw_teardown; return 1; }
  assert_eq "$(gateway_omp_scoped_count)" 1
  local f; f="$(gateway_auth_dir)/claude-33333333-renamed.json"
  jq '.prefix = "omp"' "$f" >"$f.t" && mv "$f.t" "$f"
  assert_fails gateway_omp_scope_check
  assert_eq "$(jq -r '[.[] | select(.action == "remove")] | map(.file) | join(",")' <<<"$(gateway_omp_scope_plan)")" \
    "claude-33333333-renamed.json"
  _gw_teardown
}

# APPLY GOES THROUGH THE RUNNING GATEWAY, never a second writer on the vault:
# CLIProxyAPI rewrites these files itself on every token refresh, and its
# management PATCH serialises with that. The management key rides stdin.
test_gateway_omp_scope_apply_patches_only_pool_accounts_through_management() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_omp_vault "$(gateway_auth_dir)"
  cel_config_set gateway omp_exclude "me@personal.invalid"
  gateway_omp_scope_apply >/dev/null || { echo "apply failed"; _gw_teardown; return 1; }
  local argv; argv="$(cat "$T/curl.argv")"
  assert_contains "$argv" "/v0/management/auth-files/fields"
  assert_eq "$(grep -c 'auth-files/fields' "$T/curl.argv")" 1
  assert_contains "$(cat "$T/curl.body")" '"name":"claude-22222222-pool-a@example.invalid.json"'
  assert_contains "$(cat "$T/curl.body")" '"prefix":"omp"'
  ! grep -q 'personal' "$T/curl.body" || { echo "apply touched the personal account"; _gw_teardown; return 1; }
  local mk; mk="$(cat "$(gateway_state_dir)/management-key")"
  ! grep -qF "$mk" "$T/curl.argv" || { echo "the management key reached argv"; _gw_teardown; return 1; }
  _gw_teardown
}

# omp's models.yml: the gateway's PREFIXED claude ids only, metadata copied
# from omp's own catalog (allowed keys only), key and session as ENV NAMES.
test_gateway_omp_models_yml_carries_prefixed_ids_and_no_secret() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  export GW_MODELS='{"data":[{"id":"claude-sonnet-4-6"},{"id":"omp/claude-sonnet-4-6"},{"id":"omp/claude-unknown-9"},{"id":"gpt-5.5"}]}'
  _gw_omp_catalog "$T/cat.json"
  mkdir -p "$T/omp"
  printf 'providers:\n  mine:\n    baseUrl: https://example.invalid\n    apiKey: MINE\n' >"$T/omp/models.yml"
  gateway_omp_models_write "$T/omp/models.yml" "$T/cat.json" || { echo "write failed"; _gw_teardown; return 1; }
  local f="$T/omp/models.yml" p='.providers.celgw'
  assert_eq "$(yq -r '.providers.mine.baseUrl' "$f")" "https://example.invalid"
  assert_eq "$(yq -r "$p.baseUrl" "$f")" "http://127.0.0.1:$(gateway_port)"
  assert_eq "$(yq -r "$p.api" "$f")" anthropic-messages
  assert_eq "$(yq -r "$p.apiKey" "$f")" OMP_GATEWAY_TOKEN
  assert_eq "$(yq -r "$p.headers[\"x-session-id\"]" "$f")" CEL_SESSION_ID
  # No model substitution: the unknown id has no omp metadata and is dropped,
  # the plain id and the codex id are other clients' and never listed.
  assert_eq "$(yq -r "[$p.models[].id] | join(\",\")" "$f")" "omp/claude-sonnet-4-6"
  assert_eq "$(yq -r "$p.models[0].thinking.mode" "$f")" anthropic-adaptive
  assert_eq "$(yq -r "$p.models[0].thinking | has(\"prefixBinding\")" "$f")" false
  assert_eq "$(yq -r "$p.models[0] | has(\"compat\")" "$f")" false
  assert_eq "$(yq -r "$p.models[0].contextWindow" "$f")" 1000000
  local key; key="$(cat "$(gateway_state_dir)/api-key")"
  ! grep -qF "$key" "$f" || { echo "the api-key was written into models.yml"; _gw_teardown; return 1; }
  unset GW_MODELS
  _gw_teardown
}

# The pi contract is unchanged: omp-scoped ids are omp's, and must not leak
# into pi's openai-completions block as `omp/claude-*` models.
test_pi_models_skip_the_omp_scoped_ids() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  export GW_MODELS='{"data":[{"id":"gpt-5.5"},{"id":"claude-sonnet-4-6"},{"id":"omp/claude-sonnet-4-6"}]}'
  gateway_pi_models_write "$T/pi/models.json"
  assert_eq "$(jq -r '[.providers[].models[].id] | join(",")' "$T/pi/models.json")" "gpt-5.5,claude-sonnet-4-6"
  unset GW_MODELS
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

# --- the pinned release ---------------------------------------------------

# THE PIN HAS A FLOOR (CEL-135). 7.3.14 benches a Claude credential until the
# MONTHLY BILLING RESET when one 429 carries an overage claim (upstream
# #6465, fixed in 8.0.22) - on a scratch copy of this box's config, a fake
# upstream sending one such 429 with Retry-After: 3 was never chosen again in
# 60s under 7.3.14 and served again after 20s under 8.0.29. 8.0.17/8.0.25
# fix two more cooldown faults of the same family (#6415, #6545). A pin
# rolled back below 8.0.22 brings that back, so it goes red here.
test_gateway_pinned_release_is_at_least_8_0_22() {
  local v; v="$(yq -r '.base_tools["cli-proxy-api"].version' "$CEL_ROOT/agents.yaml")"
  assert_eq "$(printf '%s\n8.0.22\n' "$v" | sort -V | head -1)" "8.0.22"
}

# Both assets are the same release as the version, and every digest is a
# sha256 - a bumped version over a stale URL would install the old binary.
test_gateway_pinned_assets_match_the_version() {
  local e; e="$(yq -c '.base_tools["cli-proxy-api"]' "$CEL_ROOT/agents.yaml")"
  local v; v="$(jq -r '.version' <<<"$e")"
  local arch
  for arch in x64 arm64; do
    assert_contains "$(jq -r ".assets.$arch.url" <<<"$e")" "/download/v$v/CLIProxyAPI_${v}_linux_"
    assert_eq "$(jq -r ".assets.$arch.member" <<<"$e")" cli-proxy-api
    [[ "$(jq -r ".assets.$arch.sha256" <<<"$e")" =~ ^[0-9a-f]{64}$ ]] \
      || { echo "$arch sha256 is not a digest"; return 1; }
  done
}

# AH-261018: the pi models.json writer runs at EVERY gateway launch (workers and
# reviewers) against one file live sessions already read. A launch must add
# missing ids only, never rewrite an existing model entry, never delete one,
# and must not touch the file at all when nothing would change.
test_pi_models_launch_write_never_rewrites_existing_entries_and_skips_a_noop() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  local f="$T/pi/models.json"
  gateway_pi_models_write "$f"
  jq '.providers["ompgw-claude"].models[0].contextWindow = 555
      | .providers["ompgw-claude"].models += [{"id":"claude-retired-1","contextWindow":7}]' "$f" >"$T/x" && mv "$T/x" "$f"
  local stamp; stamp="$(stat -c %i%Y "$f")"; sleep 1.1
  gateway_pi_models_write "$f"
  assert_eq "$(jq '.providers["ompgw-claude"].models[0].contextWindow' "$f")" 555
  assert_eq "$(jq -r '[.providers["ompgw-claude"].models[].id] | index("claude-retired-1") != null' "$f")" true
  assert_eq "$(stat -c %i%Y "$f")" "$stamp"
  # a newly published id is ADDED, existing entries untouched
  export GW_MODELS='{"data":[{"id":"claude-sonnet-4-6","context_length":200000},{"id":"claude-new-9","context_length":9}]}'
  gateway_pi_models_write "$f"
  assert_eq "$(jq -r '[.providers["ompgw-claude"].models[].id] | index("claude-new-9") != null' "$f")" true
  assert_eq "$(jq '.providers["ompgw-claude"].models[] | select(.id=="claude-sonnet-4-6") | .contextWindow' "$f")" 555
  # an explicit refresh lets the catalog win
  GATEWAY_PI_WRITE=refresh gateway_pi_models_write "$f"
  assert_eq "$(jq '.providers["ompgw-claude"].models[] | select(.id=="claude-sonnet-4-6") | .contextWindow' "$f")" 200000
  unset GW_MODELS
  _gw_teardown
}

# AH-261018 review F2/F3: the omp writer is as non-destructive as the pi one,
# and concurrent publication into the shared files loses no update and keeps the
# symlink and mode of an existing file.
test_omp_launch_write_keeps_existing_entries_and_unpublished_ids() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  export GW_MODELS='{"data":[{"id":"claude-sonnet-4-6"},{"id":"omp/claude-sonnet-4-6"}]}'
  _gw_omp_catalog "$T/cat.json"; mkdir -p "$T/omp"
  local f="$T/omp/models.yml"
  gateway_omp_models_write "$f" "$T/cat.json" || { _gw_teardown; return 1; }
  yq -y '.providers.celgw.models |= map(.contextWindow = 555) | .providers.celgw.models += [{"id":"omp/claude-retired","contextWindow":7}]
         | .providers.mine = {"apiKey":"MINE"}' "$f" >"$T/x" && mv "$T/x" "$f"
  local stamp; stamp="$(stat -c %i%Y "$f")"; sleep 1.1
  gateway_omp_models_write "$f" "$T/cat.json"
  assert_eq "$(yq -r '.providers.celgw.models[] | select(.id=="omp/claude-sonnet-4-6") | .contextWindow' "$f")" 555
  assert_eq "$(yq -r '[.providers.celgw.models[].id] | index("omp/claude-retired") != null' "$f")" true
  assert_eq "$(yq -r '.providers.mine.apiKey' "$f")" MINE
  assert_eq "$(stat -c %i%Y "$f")" "$stamp"
  GATEWAY_PI_WRITE=refresh gateway_omp_models_write "$f" "$T/cat.json"
  assert_eq "$(yq -r '.providers.celgw.models[] | select(.id=="omp/claude-sonnet-4-6") | .contextWindow' "$f")" 1000000
  unset GW_MODELS
  _gw_teardown
}

test_concurrent_publication_loses_no_update_and_keeps_link_and_mode() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  mkdir -p "$T/real" "$T/omp"
  printf '{"providers":{}}' >"$T/real/models.json"; chmod 640 "$T/real/models.json"
  rm -f "$T/pi/models.json"; ln -s "$T/real/models.json" "$T/pi/models.json"
  printf 'providers: {}\n' >"$T/real/models.yml"; chmod 640 "$T/real/models.yml"
  ln -s "$T/real/models.yml" "$T/omp/models.yml"
  printf '[{"id":"claude-sonnet-4-6","name":"S","contextWindow":1,"maxTokens":1}' >"$T/cat.json"
  local n; for n in 1 2 3 4 5 6; do printf ',{"id":"claude-w%s","name":"S","contextWindow":1,"maxTokens":1}' "$n" >>"$T/cat.json"; done; printf ']' >>"$T/cat.json"
  local pids="" p rc=0
  for n in 1 2 3 4 5 6; do
    ( export GW_MODELS="{\"data\":[{\"id\":\"claude-w$n\"},{\"id\":\"omp/claude-w$n\"}]}"
      gateway_pi_models_write "$T/pi/models.json"; gateway_omp_models_write "$T/omp/models.yml" "$T/cat.json" ) &
    pids="$pids $!"
  done
  ( export GW_MODELS='{"data":[{"id":"claude-w7"}]}'; GATEWAY_PI_WRITE=refresh gateway_pi_models_write "$T/pi/models.json" ) &
  pids="$pids $!"
  for p in $pids; do wait "$p" || rc=1; done
  assert_eq "$rc" 0
  for n in 1 2 3 4 5 6 7; do
    jq -e --arg id "claude-w$n" '[.providers["ompgw-claude"].models[].id] | index($id) != null' "$T/real/models.json" >/dev/null \
      || { echo "pi lost claude-w$n"; _gw_teardown; return 1; }
  done
  for n in 1 2 3 4 5 6; do
    yq -e --arg id "omp/claude-w$n" '[.providers.celgw.models[].id] | index($id) != null' "$T/real/models.yml" >/dev/null \
      || { echo "omp lost claude-w$n"; _gw_teardown; return 1; }
  done
  [ -L "$T/pi/models.json" ] && [ -L "$T/omp/models.yml" ] || { echo "a symlink was replaced"; _gw_teardown; return 1; }
  assert_eq "$(stat -c %a "$T/real/models.json")" 640
  assert_eq "$(stat -c %a "$T/real/models.yml")" 640
  jq -e . "$T/real/models.json" >/dev/null || { echo "torn models.json"; _gw_teardown; return 1; }
  _gw_teardown
}

# review: provider-level owner fields survive a launch in both files; refresh restores plane values.
test_launch_write_keeps_owner_provider_fields_and_refresh_restores_them() {
  _gw_setup
  cmd_gateway install --no-start >/dev/null
  _gw_omp_catalog "$T/cat.json"; mkdir -p "$T/omp"
  export GW_MODELS='{"data":[{"id":"claude-sonnet-4-6"},{"id":"omp/claude-sonnet-4-6"}]}'
  gateway_pi_models_write "$T/pi/models.json"; gateway_omp_models_write "$T/omp/models.yml" "$T/cat.json"
  jq '.providers["ompgw-claude"].headers["x-extra"] = "owner" | .providers["ompgw-claude"].compat = {"k":1} | .providers["ompgw-claude"].baseUrl = "http://owner.invalid"' "$T/pi/models.json" >"$T/x" && mv "$T/x" "$T/pi/models.json"
  yq -y '.providers.celgw.headers["x-extra"] = "owner" | .providers.celgw.compat = {"k":1}' "$T/omp/models.yml" >"$T/x" && mv "$T/x" "$T/omp/models.yml"
  gateway_pi_models_write "$T/pi/models.json"; gateway_omp_models_write "$T/omp/models.yml" "$T/cat.json"
  assert_eq "$(jq -r '.providers["ompgw-claude"].headers["x-extra"]' "$T/pi/models.json")" owner
  assert_eq "$(jq -r '.providers["ompgw-claude"].baseUrl' "$T/pi/models.json")" "http://owner.invalid"
  assert_eq "$(yq -r '.providers.celgw.headers["x-extra"]' "$T/omp/models.yml")" owner
  assert_eq "$(yq -r '.providers.celgw.compat.k' "$T/omp/models.yml")" 1
  GATEWAY_PI_WRITE=refresh gateway_pi_models_write "$T/pi/models.json"
  assert_eq "$(jq -r '.providers["ompgw-claude"].baseUrl' "$T/pi/models.json")" "http://127.0.0.1:$(gateway_port)"
  assert_eq "$(jq -r '.providers["ompgw-claude"].compat.k' "$T/pi/models.json")" 1
  unset GW_MODELS
  _gw_teardown
}
