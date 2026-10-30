# shellcheck shell=bash
source "$CEL_ROOT/lib/opencode.sh"
source "$CEL_ROOT/tests/lib/gateway-codex-fixture.sh"

test_opencode_native_plugin_regressions() {
  node --test "$CEL_ROOT/tools/opencode/runtime.test.mjs"
}

test_opencode_scoped_role_is_not_written_globally() {
  local d role config
  d="$(mktemp -d)"; role="$d/products/widget/role-orchestrator.md"; config="${role%.md}.opencode.json"
  mkdir -p "$(dirname "$role")"
  jq -n --arg role "$role" --arg plugin "$CEL_ROOT/tools/hooks/celestial.opencode.mjs" '{
    agent:"cel-orchestrator",roleFile:$role,pluginFile:$plugin,modelID:"gpt-6.1-sol",transport:"gateway",
    baseURL:"http://127.0.0.1:8317/v1",route:"{env:CEL_SESSION_ID}",limit:{context:500000,output:128000}
  }' | opencode_write_config "$config" || return 1
  opencode_agent_args orchestrator 'actual role body' 0 "$role" "$config" http://127.0.0.1:8317/v1 || return 1
  assert_eq "$AGENT_ROLE_FILE" "$role"
  assert_eq "${AGENT_ARGS[*]}" '--agent cel-orchestrator'
  assert_eq "$(cat "$role")" 'actual role body'
  assert_eq "$(stat -c %a "$config")" 600
  assert_eq "$(stat -c %a "$role")" 600
  # Native plugin/variant, not a Pi extension flag or global agent-file write.
  assert_eq "$(jq -r '.agent["cel-orchestrator"].variant' "$config")" medium
  [ ! -e "$d/.config/opencode" ]
}

test_opencode_missing_config_refuses_before_role_mutation() {
  local d; d="$(mktemp -d)"
  printf original > "$d/role.md"
  if opencode_agent_args orchestrator replacement 0 "$d/role.md" "$d/missing.json" http://127.0.0.1:8317/v1 2>/dev/null; then return 1; fi
  assert_eq "$(cat "$d/role.md")" original
  opencode_agent_args orchestrator replacement 1 "$d/new/role.md" "$d/missing.json" http://127.0.0.1:8317/v1 || return 1
  [ ! -e "$d/new/role.md" ]
}

test_opencode_launch_guard_loads_scoped_content_and_refuses_missing_file() {
  local d guard words out
  d="$(mktemp -d)"
  printf '{"fixture":"scoped"}' > "$d/config with spaces.json"
  guard="$(opencode_launch_guard "$d/config with spaces.json")"; words="$(opencode_launch_env)"
  out="$(bash -c "$guard env $words bash -c 'printf \"%s\" \"\$OPENCODE_CONFIG_CONTENT\"'")" || return 1
  assert_eq "$out" '{"fixture":"scoped"}'
  guard="$(opencode_launch_guard "$d/missing.json")"
  if bash -c "$guard env $words touch '$d/should-not-exist'" 2>/dev/null; then return 1; fi
  [ ! -e "$d/should-not-exist" ]
}

test_opencode_canonical_fresh_handoff_pins_role_model_and_refuses_missing_scoped_config() {
  _gwc_setup
  mkdir -p "$T/repos/widget" "$T/.cel"
  cat > "$T/workspace.yaml" <<'YAML'
name: alpha
runtime: {orchestrator: opencode}
repos:
  - name: widget
    mode: solo
    role_profiles: {solo: scoped}
worker_profiles:
  scoped: {runtime: opencode, model: ompgw-codex/gpt-6.1-sol, thinking: medium, via: gateway}
YAML
  cat > "$T/gwstub" <<'SH'
#!/bin/bash
case "$1" in ready) exit 0;; models) printf '%s' '{"data":[{"id":"gpt-6.1-sol"}]}';; esac
SH
  chmod +x "$T/gwstub"
  herdr() { [ "$1 $2" = 'agent list' ] && printf '{"result":{"agents":[]}}'; }
  printf 'Do not resume the old OMP file.\n' > "$T/handoff.md"
  printf 'other product role\n' > "$T/.cel/role-orchestrator.md"
  local out
  out="$(cd "$T" && cmd_run solo --product widget --session-backend rex --fresh --handoff "$T/handoff.md" --dry-run 2>&1)" || { echo "$out"; _gwc_teardown; return 1; }
  assert_contains "$out" '--model ompgw-codex/gpt-6.1-sol'
  assert_contains "$out" '--agent cel-orchestrator'
  assert_contains "$out" '--prompt Read the complete migration handoff'
  assert_contains "$out" "$T/handoff.md"
  case "$out" in *'--extension '*|*'--thinking '*|*'--session '*|*'--resume '*) echo "invented or cross-format arguments: $out"; _gwc_teardown; return 1;; esac
  printf '#!/bin/bash\ntouch "%s/launch-attempted"\nexit 1\n' "$T" > "$T/bin/rex"
  chmod +x "$T/bin/rex"
  if (cd "$T" && CEL_REX_BIN="$T/bin/rex" cmd_run solo --product widget --session-backend rex --fresh --handoff "$T/handoff.md" >/dev/null 2>&1); then
    echo 'launched without scoped config'; _gwc_teardown; return 1
  fi
  [ ! -e "$T/launch-attempted" ] || { echo 'terminal started before scoped config admission'; _gwc_teardown; return 1; }
  assert_eq "$(cat "$T/.cel/role-orchestrator.md")" 'other product role'
  _gwc_teardown
}

test_opencode_scoped_config_validator_is_read_only_and_rejects_stale_contracts() {
  local d role config original mutation output
  d="$(mktemp -d)"; role="$d/product/role-orchestrator.md"; config="$d/product/scoped.json"
  jq -n --arg role "$role" --arg plugin "$CEL_ROOT/tools/hooks/celestial.opencode.mjs" '{
    agent:"cel-orchestrator",roleFile:$role,pluginFile:$plugin,modelID:"gpt-6.1-sol",transport:"gateway",
    baseURL:"http://127.0.0.1:8317/v1",route:"{env:CEL_SESSION_ID}",limit:{context:500000,output:128000}
  }' | opencode_write_config "$config" || return 1
  original="$(cat "$config")"
  opencode_validate_config orchestrator "$role" "$config" http://127.0.0.1:8317/v1 || return 1
  [ ! -e "$role" ] || { echo 'read-only validator materialized a role'; return 1; }
  assert_eq "$(cat "$config")" "$original"
  printf original-role > "$role"
  for mutation in \
    '.plugin[0][0] = "file:///wrong-plugin.mjs"' \
    '.plugin[0][1].providerID = "openai"' \
    'del(.plugin[0][1].transport)' \
    '.provider["ompgw-codex"].options.apiKey = "literal-fixture-secret"' \
    '.plugin[0][1].route = "{env:OTHER_ROUTE}"' \
    '.provider["ompgw-codex"].options.headers["x-session-id"] = "wrong-route"' \
    '.provider["ompgw-codex"].env = ["OPENAI_API_KEY"]' \
    '.provider["ompgw-codex"].whitelist = ["gpt-6-sol"]' \
    '.enabled_providers += ["openai"]' \
    '.provider["ompgw-codex"].models["gpt-6.1-sol"].limit.output = 1'; do
    printf '%s\n' "$original" | jq "$mutation" > "$config"
    if output="$(opencode_agent_args orchestrator replacement 0 "$role" "$config" http://127.0.0.1:8317/v1 2>&1)"; then
      echo "accepted stale scoped config: $mutation"; return 1
    fi
    assert_eq "$(cat "$role")" original-role
    case "$output" in *literal-fixture-secret*) echo 'validator echoed configuration secrets'; return 1;; esac
  done
  printf '{malformed\n' > "$config"
  if opencode_validate_config orchestrator "$role" "$config" http://127.0.0.1:8317/v1 >/dev/null 2>&1; then
    echo 'accepted malformed scoped JSON'; return 1
  fi
  assert_eq "$(cat "$role")" original-role
}
