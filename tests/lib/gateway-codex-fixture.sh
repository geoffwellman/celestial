# shellcheck shell=bash
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
