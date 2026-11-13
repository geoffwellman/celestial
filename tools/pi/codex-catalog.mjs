// Credential-blind metadata for the exact installed Pi package and OMP cache.
// This is capability enrichment, not an availability allowlist. The writer
// separately registers supported gateway-advertised chat IDs without metadata.
// Read JSON/SQLite as data only: never import provider, runtime, or auth code.
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { OMP_MODEL_CACHE_VERSIONS, cacheVersionLabel } from '../omp-model-cache.mjs';

const levels = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];
const families = [
  { provider: 'anthropic', api: 'anthropic-messages' },
  { provider: 'openai-codex', api: 'openai-codex-responses' },
];
const omitted = [];
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const json = (file) => {
  try { return JSON.parse(readFileSync(file, 'utf8')); }
  catch { throw new Error('Cannot read installed Pi package metadata as JSON'); }
};
const normalizedApi = (api) => api === 'openai-codex-responses' ? 'openai-responses' : api;
const omit = (id, reason) => omitted.push({ id, reason });

function packageRoot(cli) {
  let dir = path.dirname(realpathSync(cli));
  for (;;) {
    const manifest = path.join(dir, 'package.json');
    if (existsSync(manifest) && json(manifest).name === '@earendil-works/pi-coding-agent') return dir;
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error('Cannot locate the installed @earendil-works/pi-coding-agent package');
    dir = parent;
  }
}

// require.resolve(package) rejects import-only exports. Use its Node search
// paths to find the manifest, then read the declared import target, not code.
function importTarget(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    for (const item of value) {
      const target = importTarget(item);
      if (target) return target;
    }
  } else if (object(value)) {
    for (const [condition, target] of Object.entries(value)) {
      if (['node', 'import', 'default'].includes(condition)) {
        const resolved = importTarget(target);
        if (resolved) return resolved;
      }
    }
  }
}

function providerDataRoot(root) {
  const resolver = createRequire(path.join(root, 'package.json'));
  for (const search of resolver.resolve.paths('@earendil-works/pi-ai') ?? []) {
    const pkgRoot = path.join(search, '@earendil-works/pi-ai');
    const manifest = path.join(pkgRoot, 'package.json');
    if (!existsSync(manifest)) continue;
    const pkg = json(manifest);
    if (pkg.name !== '@earendil-works/pi-ai') throw new Error('Invalid Pi AI package identity');
    const exports = pkg.exports;
    const target = exports === undefined ? pkg.main : importTarget(object(exports) && Object.hasOwn(exports, '.') ? exports['.'] : exports);
    if (typeof target !== 'string' || !target.startsWith('./')) throw new Error('Cannot locate the Pi AI declared import entry');
    const entry = path.resolve(pkgRoot, target);
    if (!entry.startsWith(`${path.resolve(pkgRoot)}${path.sep}`)) throw new Error('Pi AI import entry escapes its package');
    return path.join(path.dirname(entry), 'providers/data');
  }
  throw new Error('Cannot locate the installed @earendil-works/pi-ai package');
}

function thinkingMap(value) {
  if (!object(value)) throw new Error('Invalid native thinking-level map');
  return Object.fromEntries(levels.filter((level) => Object.hasOwn(value, level)).map((level) => {
    const mapped = value[level];
    if (mapped !== null && typeof mapped !== 'string') throw new Error('Invalid native thinking-level mapping');
    return [level, mapped];
  }));
}

const compatBooleans = {
  'openai-responses': ['supportsDeveloperRole', 'supportsMidConvoSystemMessages', 'supportsLongCacheRetention', 'supportsStrictMode', 'supportsOpenAIGrammarTools', 'supportsAdditionalTools', 'supportsToolSearch', 'supportsExplicitPromptCacheMode', 'supportsMidConvoEffort', 'supportsMaxOutputTokens'],
  'anthropic-messages': ['supportsEagerToolInputStreaming', 'supportsLongCacheRetention', 'sendSessionAffinityHeaders', 'supportsCacheControlOnTools', 'supportsTemperature', 'forceAdaptiveThinking', 'allowEmptySignature', 'supportsStrictTools', 'supportsMidConvoEffort', 'supportsMidConvoSystemMessages', 'supportsMidConvoToolChanges'],
};
function nativeCompat(value, api) {
  if (!object(value)) throw new Error('Invalid native compatibility metadata');
  const result = {};
  for (const key of compatBooleans[api]) {
    if (!Object.hasOwn(value, key)) continue;
    if (typeof value[key] !== 'boolean') throw new Error('Invalid native compatibility flag');
    result[key] = value[key];
  }
  if (Object.hasOwn(value, 'sessionAffinityFormat')) {
    const formats = api === 'anthropic-messages' ? ['openrouter'] : ['openai', 'openai-nosession', 'openrouter'];
    if (!formats.includes(value.sessionAffinityFormat)) throw new Error('Invalid native session affinity format');
    result.sessionAffinityFormat = value.sessionAffinityFormat;
  }
  if (api === 'anthropic-messages' && Object.hasOwn(value, 'allowedFallbackModels')) {
    if (!Array.isArray(value.allowedFallbackModels)) throw new Error('Invalid native fallback model metadata');
    result.allowedFallbackModels = value.allowedFallbackModels.map((fallback) => {
      if (!object(fallback) || typeof fallback.provider !== 'string' || typeof fallback.model !== 'string' || !object(fallback.cost)) throw new Error('Invalid native fallback model');
      const rates = (cost) => Object.fromEntries(['input', 'output', 'cacheRead', 'cacheWrite'].map((key) => {
        if (!Number.isFinite(cost[key]) || cost[key] < 0) throw new Error('Invalid native fallback cost');
        return [key, cost[key]];
      }));
      const cost = rates(fallback.cost);
      if (Object.hasOwn(fallback.cost, 'tiers')) {
        if (!Array.isArray(fallback.cost.tiers)) throw new Error('Invalid native fallback tiers');
        cost.tiers = fallback.cost.tiers.map((tier) => {
          if (!object(tier) || !Number.isFinite(tier.inputTokensAbove) || tier.inputTokensAbove < 0) throw new Error('Invalid native fallback tier');
          return { ...rates(tier), inputTokensAbove: tier.inputTokensAbove };
        });
      }
      return { provider: fallback.provider, model: fallback.model, cost };
    });
  }
  return result;
}

function capabilities(model, api) {
  if (!Number.isSafeInteger(model.contextWindow) || model.contextWindow <= 0 || !Number.isSafeInteger(model.maxTokens) || model.maxTokens <= 0 || typeof model.reasoning !== 'boolean') return;
  if (!Array.isArray(model.input) || !model.input.includes('text') || model.input.some((input) => !['text', 'image'].includes(input)) || new Set(model.input).size !== model.input.length) return;
  return {
    id: model.id,
    name: typeof model.name === 'string' && model.name ? model.name : model.id,
    api: normalizedApi(api),
    contextWindow: model.contextWindow,
    maxTokens: model.maxTokens,
    reasoning: model.reasoning,
    input: [...model.input],
  };
}

function addExact(map, model, source) {
  const previous = map.get(model.id);
  if (previous && JSON.stringify(previous) !== JSON.stringify(model)) throw new Error(`Conflicting exact model metadata in ${source}: ${model.id}`);
  map.set(model.id, model);
}

function nativeModels(dataRoot, family) {
  const result = new Map();
  const data = json(path.join(dataRoot, `${family.provider}.json`));
  if (!object(data)) throw new Error('Invalid Pi provider catalog');
  for (const [api, group] of Object.entries(data)) {
    if (!object(group)) throw new Error('Invalid Pi API catalog group');
    for (const [key, model] of Object.entries(group)) {
      const id = typeof model?.id === 'string' ? model.id : key;
      if (api !== family.api || !object(model) || model.type !== 'chat' || key !== `chat:${id}`) { omit(id, 'unsupported-native-chat-entry'); continue; }
      if (model.api !== api || model.provider !== family.provider) throw new Error(`Native model source conflict: ${id}`);
      if (id.includes('/')) { omit(id, 'scoped-alias'); continue; }
      const entry = capabilities(model, api);
      if (!entry) { omit(id, 'incomplete-native-capabilities'); continue; }
      if (Object.hasOwn(model, 'thinkingLevelMap')) entry.thinkingLevelMap = thinkingMap(model.thinkingLevelMap);
      if (Object.hasOwn(model, 'compat')) entry.compat = nativeCompat(model.compat, entry.api);
      addExact(result, entry, family.provider);
    }
  }
  return result;
}

// Python is already a gateway dependency. Its URI is properly encoded, mode=ro
// never creates a DB, and query_only + a transaction retain a consistent WAL
// snapshot. Only these capability columns leave the subprocess, never auth or
// provider options contained elsewhere in the cached JSON.
function cacheRows(database) {
  const code = `import json, pathlib, sqlite3, sys
with sqlite3.connect(pathlib.Path(sys.argv[1]).resolve().as_uri() + '?mode=ro', uri=True, timeout=2) as db:
 db.execute('PRAGMA query_only = ON')
 db.execute('BEGIN')
 rows = db.execute("SELECT provider_id, version, updated_at, authoritative, models FROM model_cache WHERE provider_id = 'anthropic' OR provider_id = 'openai-codex' OR provider_id LIKE 'openai-codex:%'").fetchall()
 fields = ('id', 'name', 'provider', 'api', 'type', 'kind', 'reasoning', 'input', 'contextWindow', 'maxTokens', 'thinking')
 output = []
 for provider, version, updated, authoritative, raw in rows:
  if authoritative != 1:
   continue
  models = json.loads(raw)
  if not isinstance(models, list) or any(not isinstance(model, dict) for model in models):
   raise ValueError('Invalid authoritative model array')
  output.append({'provider': provider, 'version': version, 'updated': updated, 'models': [{key: model[key] for key in fields if key in model} for model in models]})
 print(json.dumps(output))
`;
  const child = spawnSync('python3', ['-c', code, database], { encoding: 'utf8', timeout: 5000, maxBuffer: 16 * 1024 * 1024 });
  if (child.error || child.status !== 0) throw new Error('Cannot read authoritative OMP model cache read-only');
  return JSON.parse(child.stdout);
}

function sourceVersion(provider) {
  if (provider === 'openai-codex' || provider === 'anthropic') return [0, 0, 0];
  const match = /^openai-codex:(\d+)\.(\d+)\.(\d+)$/.exec(provider);
  if (!match) throw new Error('Unsupported authoritative Codex cache source');
  const version = match.slice(1).map(Number);
  if (version.some((part) => !Number.isSafeInteger(part))) throw new Error('Invalid authoritative cache source version');
  return version;
}
function selectCache(rows, family) {
  const candidates = rows.filter((row) => row.provider === family.provider || (family.provider === 'openai-codex' && row.provider.startsWith('openai-codex:')));
  const compare = (a, b) => {
    const av = sourceVersion(a.provider), bv = sourceVersion(b.provider);
    for (let index = 0; index < av.length; index++) if (av[index] !== bv[index]) return bv[index] - av[index];
    return b.updated - a.updated;
  };
  for (const candidate of candidates) {
    sourceVersion(candidate.provider);
    if (!Number.isSafeInteger(candidate.updated) || candidate.updated < 0) throw new Error('Invalid authoritative cache timestamp');
  }
  candidates.sort(compare);
  if (!candidates.length) return;
  const selected = candidates[0];
  if (!OMP_MODEL_CACHE_VERSIONS.includes(selected.version)) {
    throw new Error(`Unsupported authoritative OMP cache schema ${cacheVersionLabel(selected.version)} for ${family.provider} (this Celestial reads ${OMP_MODEL_CACHE_VERSIONS.join(', ')})`);
  }
  if (candidates[1] && compare(selected, candidates[1]) === 0 && JSON.stringify(selected.models) !== JSON.stringify(candidates[1].models)) throw new Error(`Conflicting authoritative OMP cache sources for ${family.provider}`);
  return selected;
}

function effortMap(model, native) {
  const modes = native ? ['effort', 'anthropic-adaptive', 'budget', 'anthropic-budget-effort'] : ['effort', 'anthropic-adaptive'];
  if (!modes.includes(model.thinking?.mode) || !Array.isArray(model.thinking.efforts) || model.thinking.efforts.length === 0) return;
  const efforts = model.thinking.efforts;
  if (efforts.some((effort) => ![...levels.slice(1), 'none'].includes(effort)) || new Set(efforts).size !== efforts.length) return;
  return Object.fromEntries(levels.map((level) => {
    const mapped = native?.thinkingLevelMap?.[level];
    // Retain exact native aliases only if the authoritative exact-ID effort
    // supports their wire value. Missing/unsupported levels stay unavailable.
    if (mapped === null) return [level, null];
    if (mapped !== undefined) return [level, efforts.includes(mapped) ? mapped : null];
    if (native && (level === 'xhigh' || level === 'max')) return [level, null];
    const value = level === 'off' ? 'none' : level;
    return [level, efforts.includes(value) ? value : null];
  }));
}

function mergeModels(native, cached, family) {
  if (!cached) return [...native.values()];
  const authoritative = new Map();
  const sourceModels = new Map();
  for (const model of cached.models) {
    if (typeof model.id !== 'string' || !model.id) throw new Error('Invalid authoritative model identity');
    if (model.provider !== family.provider || model.api !== family.api) throw new Error(`Authoritative model source conflict: ${model.id}`);
    if (model.id.includes('/')) { omit(model.id, 'scoped-alias'); continue; }
    // Cache versions up to 14 mark a model's kind with `type`, 15 with `kind`.
    const kind = model.type ?? model.kind;
    if (kind !== undefined && kind !== 'chat') { omit(model.id, 'non-chat-model'); continue; }
    addExact(sourceModels, model, cached.provider);
    const entry = capabilities(model, family.api);
    if (!entry) { omit(model.id, 'incomplete-authoritative-chat-capabilities'); continue; }
    const exact = native.get(model.id);
    if (exact && Object.hasOwn(exact, 'compat')) entry.compat = exact.compat;
    if (entry.reasoning) {
      const map = effortMap(model, exact);
      if (!map) { omit(model.id, 'unsupported-exact-thinking-metadata'); continue; }
      entry.thinkingLevelMap = map;
    }
    if (!exact && family.provider === 'anthropic') {
      if (model.thinking?.mode !== 'anthropic-adaptive') {
        omit(model.id, 'no-exact-native-anthropic-wire-metadata');
        continue;
      }
      // These are the Pi adapter semantics of exact adaptive mode, not
      // capabilities copied from any neighbouring Anthropic model.
      entry.compat = { forceAdaptiveThinking: true, supportsTemperature: false };
    }
    addExact(authoritative, entry, cached.provider);
  }
  for (const id of native.keys()) if (!authoritative.has(id)) omit(id, 'absent-from-authoritative-chat-catalog');
  return [...authoritative.values()];
}

try {
  if (!process.argv[2] || process.argv.length > 4) throw new Error('Usage: codex-catalog.mjs <pi-cli> [omp-models-db]');
  const root = providerDataRoot(packageRoot(process.argv[2]));
  const database = process.argv[3] ?? path.join(homedir(), '.omp/agent/models.db');
  if (process.argv[3] && !existsSync(database)) throw new Error('The explicit OMP model cache does not exist');
  const cached = existsSync(database) ? cacheRows(database) : [];
  const models = families.flatMap((family) => mergeModels(nativeModels(root, family), selectCache(cached, family), family));
  const exact = new Map();
  for (const model of models) addExact(exact, model, 'merged providers');
  if (omitted.length) process.stderr.write(`${JSON.stringify({ omitted })}\n`);
  process.stdout.write(`${JSON.stringify([...exact.values()].sort((a, b) => a.id.localeCompare(b.id)))}\n`);
} catch (error) {
  // Do not echo arbitrary source data, paths, subprocess stderr, or credentials.
  process.stderr.write(`${JSON.stringify({ error: error.message })}\n`);
  process.exitCode = 1;
}
