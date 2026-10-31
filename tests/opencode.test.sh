# shellcheck shell=bash
source "$CEL_ROOT/lib/opencode.sh"
source "$CEL_ROOT/tests/lib/gateway-codex-fixture.sh"

test_opencode_native_plugin_regressions() {
  node --test "$CEL_ROOT/tools/opencode/runtime.test.mjs"
}

test_opencode_private_launcher_regressions() {
  node --test "$CEL_ROOT/tools/opencode/launch.test.mjs"
}

test_opencode_scoped_role_is_not_written_globally() {
  local d role config
  d="$(mktemp -d)"; role="$d/products/widget/role-orchestrator.md"; config="${role%.md}.opencode.json"
  mkdir -p "$(dirname "$role")"
  jq -n --arg role "$role" --arg plugin "$CEL_ROOT/tools/opencode/plugin" '{
    agent:"cel-orchestrator",roleFile:$role,pluginFile:$plugin,modelID:"gpt-6.1-sol",transport:"gateway",
    baseURL:"http://127.0.0.1:8317/v1",route:"{env:CEL_SESSION_ID}",limit:{context:500000,output:128000}
  }' | opencode_write_config "$config" || return 1
  opencode_agent_args orchestrator 'actual role body' 0 "$role" "$config" http://127.0.0.1:8317/v1 || return 1
  assert_eq "$AGENT_ROLE_FILE" "$role"
  assert_eq "${AGENT_ARGS[*]}" ''
  assert_eq "$(cat "$role")" 'actual role body'
  assert_eq "$(stat -c %a "$config")" 600
  assert_eq "$(stat -c %a "$role")" 600
  # Native plugin/variant, not a Pi extension flag or global agent-file write.
  assert_eq "$(jq -r '.agents["cel-orchestrator"].model.variant' "$config")" medium
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
  assert_contains "$out" '--standalone'
  assert_contains "$out" '--auto'
  assert_contains "$out" '--prompt Read the complete migration handoff'
  assert_contains "$out" "$T/handoff.md"
  case "$out" in *'--agent '*|*'--model '*|*'--extension '*|*'--thinking '*|*'--session '*|*'--resume '*) echo "invented or cross-format arguments: $out"; _gwc_teardown; return 1;; esac
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
  jq -n --arg role "$role" --arg plugin "$CEL_ROOT/tools/opencode/plugin" '{
    agent:"cel-orchestrator",roleFile:$role,pluginFile:$plugin,modelID:"gpt-6.1-sol",transport:"gateway",
    baseURL:"http://127.0.0.1:8317/v1",route:"{env:CEL_SESSION_ID}",limit:{context:500000,output:128000}
  }' | opencode_write_config "$config" || return 1
  original="$(cat "$config")"
  opencode_validate_config orchestrator "$role" "$config" http://127.0.0.1:8317/v1 || return 1
  [ ! -e "$role" ] || { echo 'read-only validator materialized a role'; return 1; }
  assert_eq "$(cat "$config")" "$original"
  printf original-role > "$role"
  for mutation in \
    '.plugins[0].package = "/wrong-plugin.mjs"' \
    '.plugins[0].options.providerID = "openai"' \
    'del(.plugins[0].options.transport)' \
    '.providers["ompgw-codex"].settings.apiKey = "literal-fixture-secret"' \
    '.plugins[0].options.route = "{env:OTHER_ROUTE}"' \
    '.providers["ompgw-codex"].headers["x-session-id"] = "wrong-route"' \
    '.providers["ompgw-codex"].env = ["OPENAI_API_KEY"]' \
    '.providers["ompgw-codex"].package = "@ai-sdk/openai"' \
    '.policies += [{action:"provider.use",resource:"*",effect:"allow"}]' \
    '.providers["ompgw-codex"].models["gpt-6.1-sol"].limit.output = 1' \
    '.providers["ompgw-codex"].models["gpt-6.1-sol"].settings.reasoningEffort = "high"' \
    '.providers["ompgw-codex"].models["gpt-6.1-sol"].variants += [{id:"high",settings:{reasoningEffort:"high"}}]' \
    '.agents["cel-orchestrator"].model.variant = "high"' \
    '.agents["cel-orchestrator"].system = "{file:/other/role.md}"' \
    '.model.model = "other-model"' \
    '.small_model = "openai/other-model"'; do
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

test_opencode_config_uses_native_v2_schema_and_exact_medium_contract() {
  node --input-type=module - "$CEL_ROOT/tools/opencode/config.mjs" <<'JS'
import assert from 'node:assert/strict';
import { fileURLToPath, pathToFileURL } from 'node:url';
const { scopedConfigInput, buildConfig, validateConfig } = await import(pathToFileURL(process.argv[2]));
const scope = { agent: 'cel-orchestrator', roleFile: '/fixture/role with spaces.md', pluginFile: fileURLToPath(new URL('./plugin', pathToFileURL(process.argv[2]))), baseURL: 'http://127.0.0.1:8317/v1' };
const input = scopedConfigInput(scope);
const config = buildConfig(input);
const model = { providerID: 'ompgw-codex', model: 'gpt-6.1-sol', variant: 'medium' };
assert.deepEqual(config.model, model);
assert.equal(config.default_agent, scope.agent);
assert.deepEqual(config.agents[scope.agent], { description: 'Celestial scoped role', mode: 'primary', model, system: `{file:${scope.roleFile}}` });
assert.deepEqual(config.plugins, [{ package: scope.pluginFile, options: { agent: scope.agent, providerID: model.providerID, modelID: model.model, transport: 'gateway', route: '{env:CEL_SESSION_ID}' } }]);
assert.deepEqual(config.policies, [
  { action: 'provider.use', resource: '*', effect: 'deny' },
  { action: 'provider.use', resource: model.providerID, effect: 'allow' },
]);
assert.deepEqual(Object.keys(config.providers), [model.providerID]);
const provider = config.providers[model.providerID];
assert.equal(provider.package, '@opencode/ai/providers/openai/responses');
assert.deepEqual(provider.settings, { baseURL: scope.baseURL, apiKey: '{env:OMP_GATEWAY_TOKEN}' });
assert.deepEqual(provider.headers, { 'x-session-id': '{env:CEL_SESSION_ID}' });
assert.deepEqual(provider.env, ['OMP_GATEWAY_TOKEN']);
assert.deepEqual(Object.keys(provider.models), [model.model]);
assert.deepEqual(provider.models[model.model], {
  modelID: model.model, name: 'Sol 6.1', limit: { context: 500000, output: 128000 },
  capabilities: { tools: true, input: ['text', 'image'], output: ['text'], reasoning: { supported: true, effort: ['medium'] } },
  settings: { reasoningEffort: 'medium' }, variants: [{ id: 'medium', settings: { reasoningEffort: 'medium' } }],
});
for (const key of ['provider', 'agent', 'plugin', 'small_model', 'enabled_providers']) assert.equal(Object.hasOwn(config, key), false);
const before = JSON.stringify(config);
assert.equal(validateConfig(config, scope), true);
assert.equal(JSON.stringify(config), before);
const authenticatedURL = new URL('http://fixture/v1');
authenticatedURL.username = 'fixture-user';
authenticatedURL.password = 'fixture-secret';
for (const patch of [
  { modelID: 'gpt-6-sol' }, { transport: 'native' }, { limit: undefined }, { route: '' },
  { agent: 'bad/agent' }, { roleFile: 'relative.md' }, { pluginFile: 'relative.mjs' },
  { pluginFile: process.argv[2] }, { pluginFile: `${scope.pluginFile}/missing` },
  { baseURL: authenticatedURL.href }, { baseURL: 'file:///fixture' }, { route: 'bad\nroute' },
]) assert.throws(() => buildConfig({ ...input, ...patch }));
JS
}

test_opencode_unscoped_launch_refuses_before_global_role_write() {
  _gwc_setup
  if (PROFILE_VIA=''; _run_agent_args opencode orchestrator body 0 "$T" >/dev/null 2>&1); then _gwc_teardown; return 1; fi
  [ ! -e "$T/.cel/role-orchestrator.md" ] || { _gwc_teardown; return 1; }
  [ ! -e "$HOME/.config/opencode/agents/cel-orchestrator.md" ] || { _gwc_teardown; return 1; }
  _gwc_teardown
}
