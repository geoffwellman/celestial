import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { buildConfig, scopedConfigInput, validateConfig } from './config.mjs';
import { PINNED_CATALOG, catalogModels, nativeVariants, nativeModel, selectionAllowed, validateNativeInventory } from './model-contract.mjs';

const source = { providerKey: 'openai-codex:0.159.0', schemaVersion: 14, updatedAt: 1 };
const anthropic = { providerKey: 'anthropic', schemaVersion: 14, updatedAt: 1 };
const sol = { ...structuredClone(PINNED_CATALOG.models[0]), thinking: { mode: 'effort', efforts: ['low', 'medium', 'high'] }, source };
const claude = { id: 'claude-fixture', name: 'Fixture Claude', providerID: 'ompgw-claude', api: 'anthropic-messages',
  contextWindow: 200000, maxTokens: 64000, input: ['text', 'image'], output: ['text'], tools: true,
  reasoning: true, thinking: { mode: 'budget', efforts: ['minimal', 'low', 'medium', 'high', 'xhigh'] }, source: anthropic };
const advertised = { id: 'claude-advertised-fixture', name: 'Advertised fixture', providerID: 'ompgw-claude', api: 'anthropic-messages', source: { kind: 'gateway-advertised' } };
const catalog = { schemaVersion: 1, models: [sol, claude, advertised], excluded: [],
  sources: [source, anthropic].map(value => ({ ...value, hashVerification: 'not_verified' })) };
const scope = { agent: 'cel-orchestrator', roleFile: '/fixture/role.md',
  pluginFile: fileURLToPath(new URL('./plugin', import.meta.url)), baseURL: 'http://127.0.0.1:8317/v1' };

test('catalog config registers exact scoped transports without selecting another default', () => {
  const legacy = buildConfig(scopedConfigInput(scope));
  const config = buildConfig(scopedConfigInput({ ...scope, catalog }));
  assert.deepEqual(config.model, legacy.model);
  assert.deepEqual(config.agents, legacy.agents);
  assert.equal(config.providers['ompgw-codex'].package, legacy.providers['ompgw-codex'].package);
  assert.equal(config.providers['ompgw-claude'].package, '@opencode/ai/providers/anthropic-compatible');
  assert.deepEqual(config.providers['ompgw-claude'].settings, legacy.providers['ompgw-codex'].settings);
  assert.equal(config.providers['ompgw-claude'].canonical, undefined);
  assert.equal(config.providers['ompgw-claude'].integrationID, undefined);
  assert.equal(validateConfig(config, scope), true);
  assert.equal(validateConfig(legacy, scope), true);
  assert.deepEqual(config.providers['ompgw-claude'].models[advertised.id], { modelID: advertised.id, name: advertised.name, type: 'chat', variants: [] });
});

test('native variants use exact efforts or native manual budgets, never sibling effort labels', () => {
  assert.deepEqual(nativeVariants(claude), [
    { id: 'high', settings: { thinking: { type: 'enabled', budgetTokens: 16000 } } },
    { id: 'max', settings: { thinking: { type: 'enabled', budgetTokens: 31999 } } },
  ]);
  assert.deepEqual(nativeVariants({ ...claude, thinking: { mode: 'anthropic-adaptive', efforts: ['low', 'high'] } }), [
    { id: 'low', settings: { thinking: { type: 'adaptive', display: 'summarized' }, effort: 'low' } },
    { id: 'high', settings: { thinking: { type: 'adaptive', display: 'summarized' }, effort: 'high' } },
  ]);
  assert.equal(nativeModel(claude).settings, undefined);
  assert.equal(selectionAllowed(catalog, { providerID: claude.providerID, id: claude.id, variant: 'max' }), true);
  assert.equal(selectionAllowed(catalog, { providerID: claude.providerID, id: claude.id, variant: 'medium' }), false);
  assert.equal(selectionAllowed(catalog, { providerID: advertised.providerID, id: advertised.id }), true);
  assert.equal(selectionAllowed(catalog, { providerID: advertised.providerID, id: advertised.id, variant: 'high' }), false);
  assert.equal(selectionAllowed(undefined, { providerID: sol.providerID, id: sol.id, variant: 'high' }), false);
});

test('advertised fallback preserves the existing selected Sol contract without inventing other caps', () => {
  const fallbackSol = { id: sol.id, name: sol.name, providerID: sol.providerID, api: sol.api, source: { kind: 'gateway-advertised' } };
  const fallback = { schemaVersion: 1, models: [fallbackSol, advertised], sources: [], excluded: [] };
  const config = buildConfig(scopedConfigInput({ ...scope, catalog: fallback }));
  assert.deepEqual(config.providers['ompgw-codex'].models[sol.id].limit, { context: 500000, output: 128000 });
  assert.deepEqual(config.providers['ompgw-codex'].models[sol.id].settings, { reasoningEffort: 'medium' });
  assert.equal(config.providers['ompgw-claude'].models[advertised.id].limit, undefined);
  assert.equal(config.providers['ompgw-claude'].models[advertised.id].capabilities, undefined);
});

test('embedded provenance cannot waive aliases, native providers, malformed capabilities or omissions', () => {
  const changes = [
    value => { value.models[0].id = 'omp/gpt-6.1-sol'; },
    value => { value.models[0].providerID = 'openai'; },
    value => { value.models[0].source.authoritative = true; },
    value => { value.models[0].source.providerKey = 'anthropic'; },
    value => { value.models[0].thinking.efforts = ['unknown']; },
    value => { value.models[0].input = ['image']; },
    value => { value.excluded.push({ id: sol.id, reason: 'policy_omission' }); },
    value => { value.models[2].id = 'gpt-image-2'; value.models[2].providerID = 'ompgw-codex'; value.models[2].api = 'openai-responses'; },
    value => { value.models[2].contextWindow = 1000000; },
  ];
  for (const change of changes) {
    const value = structuredClone(catalog); change(value);
    assert.throws(() => catalogModels(value));
  }
});

test('native inventory binds every tuple, capability and exact variant while preserving unrelated settings', () => {
  const inventory = catalog.models.map(row => ({ ...nativeModel(row), id: row.id, providerID: row.providerID, enabled: true }));
  // Actual v2.2.5 Model.Info omits the configuration-only reasoning field.
  for (const model of inventory) if (model.capabilities) delete model.capabilities.reasoning;
  inventory[0].settings.unrelated = true;
  assert.equal(validateNativeInventory(inventory, catalog), true);
  for (const change of [
    rows => rows.pop(),
    rows => { rows[1].providerID = 'anthropic'; },
    rows => { rows[1].limit.context++; },
    rows => { rows[1].variants[0].settings.thinking.budgetTokens++; },
    rows => { rows[1].capabilities.input = ['text']; },
  ]) {
    const rows = structuredClone(inventory); change(rows);
    assert.throws(() => validateNativeInventory(rows, catalog));
  }
});
