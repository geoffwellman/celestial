// Exact metadata enters through the read-only gateway/native catalog join.
// This module owns the native 2.2.5 representation, not model-name inference.
import { isDeepStrictEqual } from 'node:util';

export const DEFAULT_SELECTION = Object.freeze({ providerID: 'ompgw-codex', id: 'gpt-6.1-sol', variant: 'medium' });
export const PINNED_CATALOG = Object.freeze({ schemaVersion: 1, models: [{
  id: 'gpt-6.1-sol', providerID: 'ompgw-codex', api: 'openai-responses', name: 'Sol 6.1',
  contextWindow: 500000, maxTokens: 128000, input: ['text', 'image'], output: ['text'], tools: true,
  reasoning: true, thinking: { mode: 'effort', efforts: ['medium'] },
}], excluded: [], sources: [] });
const idPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const modes = new Set(['effort', 'anthropic-adaptive', 'budget', 'anthropic-budget-effort']);
const efforts = new Set(['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']);
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const requireValue = (value, reason) => { if (!value) throw new Error(reason); };
const keys = (value, allowed) => Object.keys(value).every(key => allowed.includes(key));
const provenance = source => object(source)
  && keys(source, ['providerKey', 'schemaVersion', 'updatedAt', 'hashVerification'])
  && typeof source.providerKey === 'string'
  && /^(anthropic|openai-codex)(?::[0-9]+(?:\.[0-9]+)*(?:[-+][A-Za-z0-9.-]+)?)?$/.test(source.providerKey)
  && source.providerKey.length <= 128 && source.schemaVersion === 14
  && Number.isSafeInteger(source.updatedAt) && source.updatedAt >= 0;

export function catalogModels(catalog = PINNED_CATALOG) {
  requireValue(object(catalog) && catalog.schemaVersion === 1
    && keys(catalog, ['schemaVersion', 'models', 'excluded', 'sources'])
    && Array.isArray(catalog.models) && catalog.models.length > 0 && catalog.models.length <= 512
    && Array.isArray(catalog.excluded) && catalog.excluded.length <= 4096
    && Array.isArray(catalog.sources) && catalog.sources.length <= 128
    && Buffer.byteLength(JSON.stringify(catalog)) <= 1024 * 1024, 'Invalid scoped model catalog');
  const legacy = catalog === PINNED_CATALOG;
  // These are bounded provenance descriptions, NOT authenticated attestations.
  // Only the command's read-only join establishes their origin. Flags in an
  // embedded document cannot waive transport, alias or capability validation.
  requireValue(catalog.sources.every(source => provenance(source) && source.hashVerification === 'not_verified'),
    'Invalid catalog source provenance');
  const sourceKeys = new Set(catalog.sources.map(source => `${source.providerKey}/${source.schemaVersion}/${source.updatedAt}`));
  requireValue(sourceKeys.size === catalog.sources.length, 'Duplicate catalog source');
  const omitted = new Set();
  for (const entry of catalog.excluded) {
    requireValue(object(entry) && keys(entry, ['id', 'reason']) && typeof entry.id === 'string'
      && entry.id.length > 0 && entry.id.length <= 200 && !/[\x00-\x1f\x7f]/.test(entry.id)
      && typeof entry.reason === 'string' && /^[a-z][a-z0-9_]{0,127}$/.test(entry.reason)
      && !omitted.has(entry.id), 'Invalid catalog omission');
    omitted.add(entry.id);
  }
  const models = new Map();
  for (const row of catalog.models) {
    requireValue(object(row) && keys(row, ['id', 'providerID', 'api', 'name', 'contextWindow', 'maxTokens', 'input', 'output', 'tools', 'reasoning', 'thinking', 'source'])
      && typeof row.id === 'string' && idPattern.test(row.id)
      && !row.id.startsWith('gpt-image-') && !row.id.startsWith('omp-')
      && !omitted.has(row.id) && typeof row.name === 'string' && row.name.length > 0 && row.name.length <= 256
      && !/[\x00-\x1f\x7f]/.test(row.name), 'Invalid exact model identity');
    const codex = row.api === 'openai-responses' && row.providerID === 'ompgw-codex';
    const claude = row.api === 'anthropic-messages' && row.providerID === 'ompgw-claude';
    requireValue(codex || claude, 'Unsupported or mismatched scoped transport');
    if (row.source?.kind === 'gateway-advertised') {
      requireValue(keys(row.source, ['kind']) && keys(row, ['id', 'providerID', 'api', 'name', 'source'])
        && (codex ? /^(?:gpt-|codex-)/.test(row.id) : row.id.startsWith('claude-')),
      'Invalid advertised chat fallback');
      const key = `${row.providerID}/${row.id}`;
      requireValue(!models.has(key), 'Duplicate scoped model');
      models.set(key, row);
      continue;
    }
    if (!legacy) requireValue(provenance(row.source)
      && keys(row.source, ['providerKey', 'schemaVersion', 'updatedAt'])
      && row.source.providerKey.split(':')[0] === (codex ? 'openai-codex' : 'anthropic')
      && sourceKeys.has(`${row.source.providerKey}/${row.source.schemaVersion}/${row.source.updatedAt}`),
    'Model source is absent or mismatched');
    requireValue(Number.isSafeInteger(row.contextWindow) && row.contextWindow > 0
      && Number.isSafeInteger(row.maxTokens) && row.maxTokens > 0
      && row.maxTokens <= row.contextWindow && row.tools === true
      && Array.isArray(row.input) && row.input.includes('text') && row.input.length <= 2
      && new Set(row.input).size === row.input.length && row.input.every(input => ['text', 'image'].includes(input))
      && isDeepStrictEqual(row.output, ['text']) && typeof row.reasoning === 'boolean',
    'Incomplete exact model capabilities');
    if (row.reasoning) {
      requireValue(object(row.thinking) && modes.has(row.thinking.mode)
        && keys(row.thinking, ['mode', 'efforts', 'supportsDisplay', 'prefixBinding'])
        && ['supportsDisplay', 'prefixBinding'].every(key => row.thinking[key] === undefined || typeof row.thinking[key] === 'boolean'),
      'Unsupported reasoning contract');
      requireValue(codex ? row.thinking.mode === 'effort' : row.thinking.mode !== 'effort', 'Reasoning transport mismatch');
      requireValue(Array.isArray(row.thinking.efforts) && row.thinking.efforts.length > 0
        && row.thinking.efforts.length <= efforts.size
        && new Set(row.thinking.efforts).size === row.thinking.efforts.length
        && row.thinking.efforts.every(effort => efforts.has(effort)), 'Unknown reasoning efforts');
      if (row.thinking.mode === 'budget') requireValue(Math.min(row.maxTokens, 32000) > 1024, 'Unsupported native thinking budget');
      if (row.thinking.mode === 'anthropic-budget-effort') requireValue(row.maxTokens > 1024, 'Unsupported native thinking budget');
    }
    else requireValue(row.thinking == null, 'Non-reasoning model has thinking metadata');
    const key = `${row.providerID}/${row.id}`;
    requireValue(!models.has(key), 'Duplicate scoped model');
    models.set(key, row);
  }
  return models;
}

export function nativeVariants(row) {
  if (row.source?.kind === 'gateway-advertised' && row.id === DEFAULT_SELECTION.id && row.providerID === DEFAULT_SELECTION.providerID) row = PINNED_CATALOG.models[0];
  if (!row.reasoning) return [];
  const mode = row.thinking.mode;
  if (mode === 'budget') {
    // Native v2.2.5 core/variant.ts budgets(), ANTHROPIC_OUTPUT_TOKEN_MAX.
    const maximum = Math.min(row.maxTokens, 32000) - 1;
    requireValue(maximum >= 1024, 'Unsupported native thinking budget');
    const high = Math.min(Math.max(1024, Math.floor((maximum + 1) / 2)), maximum);
    return [{ id: 'high', settings: { thinking: { type: 'enabled', budgetTokens: high } } },
      { id: 'max', settings: { thinking: { type: 'enabled', budgetTokens: maximum } } }];
  }
  return row.thinking.efforts.map(effort => {
    if (mode === 'effort') return { id: effort, settings: { reasoningEffort: effort } };
    const thinking = mode === 'anthropic-budget-effort'
      ? { type: 'enabled', budgetTokens: Math.min(16000, row.maxTokens - 1) }
      : { type: 'adaptive', display: 'summarized' };
    return { id: effort, settings: { thinking, effort } };
  });
}

export function nativeModel(row, selected = DEFAULT_SELECTION) {
  if (row.source?.kind === 'gateway-advertised') {
    if (row.id === DEFAULT_SELECTION.id && row.providerID === DEFAULT_SELECTION.providerID) row = PINNED_CATALOG.models[0];
    else return { modelID: row.id, name: row.name, type: 'chat', variants: [] };
  }
  const variants = nativeVariants(row);
  const model = {
    modelID: row.id, name: row.name, type: 'chat',
    capabilities: { tools: row.tools, input: [...row.input], output: [...row.output],
      reasoning: row.reasoning ? { supported: true, ...(row.thinking.mode === 'budget'
        ? { budget: { min: 1024, max: Math.min(row.maxTokens, 32000) - 1 } }
        : { effort: [...row.thinking.efforts] }) } : { supported: false } },
    limit: { context: row.contextWindow, output: row.maxTokens }, variants,
  };
  // Only retain the already selected default's base settings. Other models use
  // their native Default or an owner-selected exact variant, never Sol's effort.
  if (row.providerID === selected.providerID && row.id === selected.id && selected.variant) {
    const variant = variants.find(value => value.id === selected.variant);
    requireValue(variant, 'Selected native variant is no longer available');
    model.settings = structuredClone(variant.settings);
  }
  return model;
}

export function allowsSelection(models, selection) {
  if (!selection || typeof selection.providerID !== 'string' || typeof selection.id !== 'string') return false;
  const row = models.get(`${selection.providerID}/${selection.id}`);
  if (!row) return false;
  return selection.variant === undefined || nativeVariants(row).some(variant => variant.id === selection.variant);
}

export function selectionAllowed(catalog, selection, exactLegacy = true) {
  return allowsSelection(catalogModels(catalog), selection)
    && (catalog !== undefined || !exactLegacy || selection.variant === DEFAULT_SELECTION.variant);
}

function containsSettings(actual, expected) {
  return object(actual) && Object.entries(expected).every(([key, value]) => object(value)
    ? containsSettings(actual[key], value) : isDeepStrictEqual(actual[key], value));
}

// Validate the native consumer's complete available inventory, not a claimed
// count. Native records may have additional protocol fields and preserved
// user settings, but may not change any catalog capability or variant setting.
export function validateNativeInventory(inventory, catalog) {
  const expected = catalogModels(catalog);
  requireValue(Array.isArray(inventory) && inventory.length === expected.size, 'Incomplete native model inventory');
  const seen = new Set();
  for (const actual of inventory) {
    const key = `${actual.providerID}/${actual.id}`;
    const row = expected.get(key);
    requireValue(row && !seen.has(key), 'Unscoped or duplicate native model');
    seen.add(key);
    const spec = nativeModel(row);
    requireValue(actual.enabled === true && Array.isArray(actual.variants)
      && actual.variants.length === spec.variants.length
      && spec.variants.every(variant => {
        const matches = actual.variants.filter(candidate => candidate.id === variant.id);
        return matches.length === 1 && containsSettings(matches[0].settings, variant.settings);
      }) && (!catalog || !spec.limit || isDeepStrictEqual(actual.limit, spec.limit))
      && (!catalog || !spec.capabilities || containsSettings(actual.capabilities, spec.capabilities))
      && (!spec.settings || containsSettings(actual.settings, spec.settings)), 'Native model capability or variant mismatch');
  }
  return true;
}

export function scopedProviders(catalog, baseURL, route, selected = DEFAULT_SELECTION) {
  const models = catalogModels(catalog);
  requireValue(allowsSelection(models, selected), 'Selected model is absent from the current eligible catalog');
  const providers = {};
  for (const row of models.values()) {
    let provider = providers[row.providerID];
    if (!provider) {
      provider = providers[row.providerID] = {
        package: row.api === 'anthropic-messages' ? '@opencode/ai/providers/anthropic-compatible' : '@opencode/ai/providers/openai/responses',
        env: ['OMP_GATEWAY_TOKEN'], settings: { baseURL, apiKey: '{env:OMP_GATEWAY_TOKEN}' },
        headers: { 'x-session-id': route }, models: {},
      };
    }
    provider.models[row.id] = nativeModel(row, selected);
  }
  return providers;
}
