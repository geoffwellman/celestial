# shellcheck shell=bash
# AH-261018: Codex through the box gateway is a first-class transport, and a
# native-start omp still gets the gateway registered.
#
# Before this, the gateway writer sent every non-Claude model through
# `openai-completions` (Chat Completions) under a model id the launch line did
# not even spell the same way (`ompgw/codex/gpt-5.5` against a models.json that
# listed `gpt-5.5`), and omp's provider was Claude-only. CLIProxyAPI 8.0.29
# serves the OpenAI Responses surface (POST /v1/responses, the
# /v1/responses/compact route, and the Responses websocket upgrade on the same
# path); omp 18.11 and pi 1.2 speak `openai-responses`. These tests pin what the
# WRITERS and the ROUTER produce; the wire is proven separately, with a real
# authenticated turn, never here (no key, no network, no inference).
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/run.sh"

GWC_SECRET='gwc-fixture-secret-do-not-print'

_gwc_setup() {
  T="$(mktemp -d)"
  export HOME="$T/home"; mkdir -p "$HOME"
  mkdir -p "$T/bin" "$T/pi" "$T/omp"
  unset PI_CODING_AGENT_DIR OMP_GATEWAY_TOKEN CEL_SESSION_ID
  export CEL_CONFIG_FILE="$T/config.yaml" CEL_GATEWAY_STATE="$T/state"
  export CEL_PI_AGENT_DIR="$T/pi" CEL_OMP_AGENT_DIR="$T/omp"
  printf 'gateway:\n  port: 8317\n' >"$CEL_CONFIG_FILE"
  mkdir -p "$T/state/auth"; printf 'fixture-key\n' >"$T/state/api-key"
  printf '{"type":"codex"}' >"$T/state/auth/codex-aaaaaa11-someone@example.invalid-plus.json"
  printf '{"type":"claude","email":"p@example.invalid","prefix":"omp"}' >"$T/state/auth/claude-bbbbbb22-p@example.invalid.json"
  printf '  omp_exclude: someone-else@example.invalid\n' >>"$CEL_CONFIG_FILE"
  # The gateway's catalog: versioned Codex ids beside the plain one, a Claude
  # id, the omp-prefixed Claude id, and a Codex model with NO metadata at all.
  GWC_MODELS='{"data":[
    {"id":"gpt-5.5","context_length":272000,"max_output_tokens":128000,"thinking":{"levels":["low","medium","high"]}},
    {"id":"gpt-5.5-codex","context_length":400000,"max_output_tokens":128000},
    {"id":"gpt-5.6-2026-10-01"},
    {"id":"codex-mini-latest"},
    {"id":"claude-sonnet-4-6","context_length":200000,"max_output_tokens":64000},
    {"id":"omp/claude-sonnet-4-6"}]}'
  cat >"$T/gwstub" <<EOS
#!/usr/bin/env bash
case "\$1" in
  ready)  exit "\${GW_STUB_DOWN:-0}" ;;
  models) printf '%s\n' '$(printf '%s' "$GWC_MODELS" | jq -c .)' ;;
esac
EOS
  chmod +x "$T/gwstub"; export CEL_GATEWAY_STUB="$T/gwstub"
  cat >"$T/catalog.json" <<'EOS'
[{"id":"claude-sonnet-4-6","name":"Claude Sonnet 4.6","reasoning":true,"input":["text","image"],"contextWindow":1000000,"maxTokens":128000,
  "thinking":{"mode":"anthropic-adaptive","efforts":["low","medium","high"]}}]
EOS
}
_gwc_teardown() {
  rm -rf "$T"
  unset CEL_CONFIG_FILE CEL_GATEWAY_STATE CEL_GATEWAY_STUB CEL_PI_AGENT_DIR CEL_OMP_AGENT_DIR GWC_MODELS
}

# ---------------------------------------------------------------- pi writer

test_pi_codex_models_use_the_responses_api_not_chat_completions() {
  _gwc_setup
  gateway_pi_models_write "$T/pi/models.json" || { _gwc_teardown; return 1; }
  local f="$T/pi/models.json"
  assert_eq "$(jq -r '.providers["ompgw-codex"].api' "$f")" openai-responses
  assert_eq "$(jq -r '.providers["ompgw-codex"].baseUrl' "$f")" "http://127.0.0.1:8317/v1"
  assert_eq "$(jq -r '.providers["ompgw-codex"].headers["x-session-id"]' "$f")" '$CEL_SESSION_ID'
  assert_eq "$(jq -r '.providers["ompgw-codex"].apiKey' "$f")" '$OMP_GATEWAY_TOKEN'
  # The chat-completions block is no longer where a Codex id lives.
  assert_eq "$(jq -r '[.providers.ompgw.models[]? | .id] | map(select(test("gpt|codex"))) | length' "$f")" 0
  _gwc_teardown
}

test_pi_codex_catalog_discovers_versioned_ids_and_leaves_claude_alone() {
  _gwc_setup
  gateway_pi_models_write "$T/pi/models.json" || { _gwc_teardown; return 1; }
  local f="$T/pi/models.json"
  assert_eq "$(jq -r '[.providers["ompgw-codex"].models[].id] | sort | join(",")' "$f")" \
    "codex-mini-latest,gpt-5.5,gpt-5.5-codex,gpt-5.6-2026-10-01"
  assert_eq "$(jq -r '[.providers["ompgw-claude"].models[].id] | join(",")' "$f")" "claude-sonnet-4-6"
  assert_eq "$(jq -r '.providers["ompgw-claude"].api' "$f")" anthropic-messages
  # omp-scoped ids stay out of pi entirely
  ! grep -q 'omp/' "$f" || { echo "omp-scoped id leaked into pi"; _gwc_teardown; return 1; }
  _gwc_teardown
}

# HONEST CAPABILITY METADATA: a field is written only when the gateway's
# catalog states it. An id with no metadata gets no `reasoning`, no thinking
# map and no invented limits beyond the loader's own defaults.
test_pi_codex_metadata_is_only_what_the_catalog_states() {
  _gwc_setup
  gateway_pi_models_write "$T/pi/models.json" || { _gwc_teardown; return 1; }
  local f="$T/pi/models.json" m
  m='.providers["ompgw-codex"].models[]'
  assert_eq "$(jq -r "$m | select(.id==\"gpt-5.5\") | .contextWindow" "$f")" 272000
  assert_eq "$(jq -r "$m | select(.id==\"gpt-5.5\") | .reasoning" "$f")" true
  assert_eq "$(jq -r "$m | select(.id==\"gpt-5.5\") | .thinkingLevelMap | keys | join(\",\")" "$f")" "high,low,medium"
  assert_eq "$(jq -r "$m | select(.id==\"gpt-5.6-2026-10-01\") | has(\"reasoning\")" "$f")" false
  assert_eq "$(jq -r "$m | select(.id==\"gpt-5.6-2026-10-01\") | has(\"thinkingLevelMap\")" "$f")" false
  assert_eq "$(jq -r "$m | select(.id==\"gpt-5.6-2026-10-01\") | has(\"contextWindow\")" "$f")" false
  _gwc_teardown
}

test_pi_codex_write_keeps_the_owners_providers_and_never_writes_the_key() {
  _gwc_setup
  printf '{"providers":{"mine":{"baseUrl":"https://example.invalid/v1","models":[{"id":"m1"}]}}}' >"$T/pi/models.json"
  gateway_pi_models_write "$T/pi/models.json" || { _gwc_teardown; return 1; }
  assert_eq "$(jq -r '.providers.mine.baseUrl' "$T/pi/models.json")" "https://example.invalid/v1"
  ! grep -q "fixture-key" "$T/pi/models.json" || { echo "api key written"; _gwc_teardown; return 1; }
  _gwc_teardown
}

test_pi_provider_helper_names_the_codex_family() {
  local id
  for id in gpt-5.5 gpt-5.5-codex gpt-5.6-2026-10-01 codex-mini-latest o4-mini openai-codex/gpt-5.5 ompgw/codex/gpt-5.5; do
    assert_eq "$(gateway_pi_provider_for_model "$id")" ompgw-codex || { echo "id: $id"; return 1; }
  done
  assert_eq "$(gateway_pi_provider_for_model claude-sonnet-4-6)" ompgw-claude
  assert_eq "$(gateway_pi_provider_for_model deepseek-v4)" ompgw
}

# ---------------------------------------------------------------- omp writer

test_omp_models_register_codex_on_the_responses_api_beside_claude() {
  _gwc_setup
  gateway_omp_models_write "$T/omp/models.yml" "$T/catalog.json" || { _gwc_teardown; return 1; }
  local f="$T/omp/models.yml"
  assert_eq "$(yq -r '.providers["celgw-codex"].api' "$f")" openai-responses
  assert_eq "$(yq -r '.providers["celgw-codex"].baseUrl' "$f")" "http://127.0.0.1:8317/v1"
  assert_eq "$(yq -r '.providers["celgw-codex"].apiKey' "$f")" OMP_GATEWAY_TOKEN
  assert_eq "$(yq -r '.providers["celgw-codex"].headers["x-session-id"]' "$f")" CEL_SESSION_ID
  assert_eq "$(yq -r '[.providers["celgw-codex"].models[].id] | sort | join(",")' "$f")" \
    "codex-mini-latest,gpt-5.5,gpt-5.5-codex,gpt-5.6-2026-10-01"
  assert_eq "$(yq -r '.providers.celgw.api' "$f")" anthropic-messages
  assert_eq "$(yq -r '[.providers.celgw.models[].id] | join(",")' "$f")" "omp/claude-sonnet-4-6"
  ! grep -q "fixture-key" "$f" || { echo "api key written"; _gwc_teardown; return 1; }
  _gwc_teardown
}

# A gateway with only Codex published (no Claude pool yet) still registers Codex;
# the writer fails only when it has NOTHING to register.
test_omp_models_register_codex_when_no_claude_model_is_published() {
  _gwc_setup
  GWC_MODELS='{"data":[{"id":"gpt-5.5"}]}'
  printf '#!/usr/bin/env bash\ncase "$1" in ready) exit 0;; models) printf %%s '"'"'%s'"'"';; esac\n' "$GWC_MODELS" >"$T/gwstub"
  gateway_omp_models_write "$T/omp/models.yml" "$T/catalog.json" || { _gwc_teardown; return 1; }
  assert_eq "$(yq -r '[.providers["celgw-codex"].models[].id] | join(",")' "$T/omp/models.yml")" gpt-5.5
  assert_eq "$(yq -r '.providers | has("celgw")' "$T/omp/models.yml")" false
  printf '#!/usr/bin/env bash\ncase "$1" in ready) exit 0;; models) printf %%s '"'"'{"data":[{"id":"mistral-x"}]}'"'"';; esac\n' >"$T/gwstub"
  assert_fails gateway_omp_models_write "$T/omp/models2.yml" "$T/catalog.json"
  _gwc_teardown
}

test_omp_models_write_keeps_unrelated_providers() {
  _gwc_setup
  printf 'providers:\n  mine:\n    baseUrl: https://example.invalid\n    apiKey: MINE\n' >"$T/omp/models.yml"
  gateway_omp_models_write "$T/omp/models.yml" "$T/catalog.json" || { _gwc_teardown; return 1; }
  assert_eq "$(yq -r '.providers.mine.apiKey' "$T/omp/models.yml")" MINE
  _gwc_teardown
}

# ---------------------------------------------------------------- the router

_gwc_profile() { # <runtime> <model> -> resolves a gateway profile in $T
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/workspace.yaml"
  cat >>"$T/workspace.yaml" <<YAML
worker_profiles:
  p: { runtime: $1, model: $2, via: gateway, thinking: high }
YAML
  mkdir -p "$T/repos/widget"
  PROFILE_VETO="" PROFILE_NOTE="" PROFILE_MODEL=""
  profile_resolve "$T" p >/dev/null 2>&1
}

test_profile_pi_codex_resolves_to_the_responses_provider_with_a_model_pi_can_load() {
  _gwc_setup
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_ISOLATE PROFILE_VETO PROFILE_VIA PROFILE_GATEWAY_ACCOUNTS
  local m
  for m in codex/gpt-5.5 openai-codex/gpt-5.5 gpt-5.5 ompgw/codex/gpt-5.5; do
    _gwc_profile pi "$m"
    assert_eq "$PROFILE_MODEL" "ompgw-codex/gpt-5.5" || { echo "model: $m"; _gwc_teardown; return 1; }
    assert_eq "$PROFILE_VETO" ""
  done
  assert_eq "$PROFILE_GATEWAY_ACCOUNTS" 1
  # the launch id is exactly <provider>/<id> as models.json writes them
  gateway_pi_models_write "$T/pi/models.json"
  jq -e '.providers["ompgw-codex"].models[] | select(.id == "gpt-5.5")' "$T/pi/models.json" >/dev/null \
    || { echo "profile model not in models.json"; _gwc_teardown; return 1; }
  _gwc_teardown
}

test_profile_omp_codex_is_accepted_and_resolves_to_celgw_codex() {
  _gwc_setup
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_ISOLATE PROFILE_VETO PROFILE_VIA PROFILE_GATEWAY_ACCOUNTS
  _gwc_profile omp openai-codex/gpt-5.5-codex
  assert_eq "$PROFILE_VETO" "" || { _gwc_teardown; return 1; }
  assert_eq "$PROFILE_MODEL" "celgw-codex/gpt-5.5-codex"
  assert_eq "$PROFILE_THINKING" high
  assert_contains "$PROFILE_NOTE" "via gateway"
  _gwc_teardown
}

# no substitution: an id the gateway does not publish is a veto BY NAME, and a
# vault with no Codex account is a veto, never "use whatever is there".
test_profile_codex_is_vetoed_by_name_when_unpublished_or_without_an_account() {
  _gwc_setup
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_ISOLATE PROFILE_VETO PROFILE_VIA PROFILE_GATEWAY_ACCOUNTS rt
  for rt in pi omp; do
    _gwc_profile "$rt" gpt-9.9-unpublished
    assert_contains "$PROFILE_VETO" "gpt-9.9-unpublished" || { echo "rt: $rt"; _gwc_teardown; return 1; }
  done
  rm -f "$T"/state/auth/codex-*.json
  for rt in pi omp; do
    _gwc_profile "$rt" gpt-5.5
    assert_contains "$PROFILE_VETO" "cel gateway login codex" || { echo "rt: $rt"; _gwc_teardown; return 1; }
  done
  _gwc_teardown
}

# The Claude path is unchanged for both runtimes.
test_profile_claude_routing_is_unchanged_by_the_codex_support() {
  _gwc_setup
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_ISOLATE PROFILE_VETO PROFILE_VIA PROFILE_GATEWAY_ACCOUNTS
  _gwc_profile pi claude-sonnet-4-6
  assert_eq "$PROFILE_MODEL" "ompgw-claude/claude-sonnet-4-6"
  _gwc_profile omp anthropic/claude-sonnet-4-6
  assert_eq "$PROFILE_MODEL" "celgw/omp/claude-sonnet-4-6"
  _gwc_teardown
}

# ------------------------------------------ native start, gateway later

test_native_omp_start_registers_the_gateway_provider_beside_the_launch_env() {
  _gwc_setup
  local -a GATEWAY_ENV=(); local PROFILE_VIA=""
  # omp's own catalog is not on this box: the seam is the catalog file.
  export CEL_OMP_CATALOG_FILE="$T/catalog.json"
  _run_profile_gateway_setup omp omp-worker 0 1 sess-1 || { _gwc_teardown; return 1; }
  assert_eq "${#GATEWAY_ENV[@]}" 2
  assert_eq "$(yq -r '.providers | has("celgw-codex")' "$T/omp/models.yml")" true
  assert_eq "$(yq -r '.providers | has("celgw")' "$T/omp/models.yml")" true
  unset CEL_OMP_CATALOG_FILE
  _gwc_teardown
}

# Direct-only boxes keep working: no gateway configured => no env, no file, no error.
test_native_omp_start_on_a_direct_only_box_registers_nothing_and_succeeds() {
  _gwc_setup
  : >"$CEL_CONFIG_FILE"; rm -f "$T/state/api-key"
  local -a GATEWAY_ENV=(stale); local PROFILE_VIA=""
  _run_profile_gateway_setup omp omp-worker 0 1 || { echo "direct-only launch failed"; _gwc_teardown; return 1; }
  assert_eq "${#GATEWAY_ENV[@]}" 0
  [ ! -e "$T/omp/models.yml" ] || { echo "models.yml written without a gateway"; _gwc_teardown; return 1; }
  _gwc_teardown
}

# A configured gateway that is merely down must not strand a native start; the
# registration is skipped with a warning and the env is still given.
test_native_omp_start_survives_a_down_gateway_with_a_warning() {
  _gwc_setup
  export GW_STUB_DOWN=1
  local -a GATEWAY_ENV=(); local PROFILE_VIA="" out
  out="$(_run_profile_gateway_setup omp omp-worker 0 1 2>&1)" || { echo "native start refused: $out"; unset GW_STUB_DOWN; _gwc_teardown; return 1; }
  assert_contains "$out" "gateway"
  [ ! -e "$T/omp/models.yml" ] || { echo "wrote models.yml from a dead gateway"; unset GW_STUB_DOWN; _gwc_teardown; return 1; }
  unset GW_STUB_DOWN
  _gwc_teardown
}

# REQUIRED gateway fails closed: no registration => the launch is refused.
test_required_gateway_launch_fails_closed_when_registration_fails() {
  _gwc_setup
  printf '#!/usr/bin/env bash\ncase "$1" in ready) exit 0;; models) printf %%s '"'"'{"data":[{"id":"mistral-x"}]}'"'"';; esac\n' >"$T/gwstub"
  local PROFILE_VIA=gateway
  export CEL_OMP_CATALOG_FILE="$T/catalog.json"
  ( _run_profile_gateway_setup omp omp-worker 1 1 ) >/dev/null 2>&1 \
    && { echo "required gateway launched with nothing registered"; _gwc_teardown; return 1; }
  unset CEL_OMP_CATALOG_FILE
  _gwc_teardown
}

# Exclusion/account scope is untouched by native registration: the native-start
# path never calls the prefix applier and never reads or writes a credential.
test_native_registration_never_touches_the_vault_or_prefixes() {
  _gwc_setup
  local before; before="$(find "$T/state/auth" -type f -exec sha256sum {} + | sort)"
  local -a GATEWAY_ENV=(); local PROFILE_VIA=""
  export CEL_OMP_CATALOG_FILE="$T/catalog.json"
  gateway_omp_scope_apply() { echo "prefix apply called" >&2; return 1; }
  _run_profile_gateway_setup omp omp-worker 0 1 >/dev/null 2>&1
  unset CEL_OMP_CATALOG_FILE
  assert_eq "$(find "$T/state/auth" -type f -exec sha256sum {} + | sort)" "$before"
  _gwc_teardown
}
