import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { OMP_MODEL_CACHE_VERSIONS, cacheVersionLabel } from '../omp-model-cache.mjs';

const MAX_BYTES = 8 * 1024 * 1024;
const providerKey = /^(anthropic|openai-codex)(?::[0-9]+(?:\.[0-9]+)*(?:[-+][A-Za-z0-9.-]+)?)?$/;
const safeID = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$/;
const positive = value => Number.isSafeInteger(value) && value > 0;
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const thinkingBooleans = new Set(['supportsDisplay', 'prefixBinding']);
const modes = new Set(['effort', 'budget', 'anthropic-adaptive', 'anthropic-budget-effort']);
const efforts = new Set(['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']);

// Read the cache as data, never import a provider or its resolved configuration.
// The native materialization hash algorithm is not established here: no claim
// of hash verification is made. SQLite pins one read-only transaction instead.
const reader = String.raw`
import json, os, sqlite3, sys
from urllib.parse import quote
p = sys.argv[1]
if not os.path.isfile(p):
    print('[]')
    sys.exit(0)
c = sqlite3.connect('file:' + quote(os.path.abspath(p), safe='/') + '?mode=ro', uri=True)
c.execute('PRAGMA query_only=ON')
c.execute('BEGIN')
rows = c.execute("SELECT provider_id, version, updated_at, CASE WHEN length(models)<=8388608 THEN models ELSE NULL END FROM model_cache WHERE authoritative=1 AND (provider_id='anthropic' OR provider_id GLOB 'anthropic:*' OR provider_id='openai-codex' OR provider_id GLOB 'openai-codex:*') LIMIT 129").fetchall()
if len(rows)>128:
    raise ValueError('bounded provider inventory exceeded')
out=[]
for key, version, updated, raw in rows:
    if len(raw)>8*1024*1024:
        raise ValueError('bounded metadata exceeded')
    models=json.loads(raw)
    if not isinstance(models,list) or len(models)>4096:
        raise ValueError('invalid model inventory')
    clean=[]
    for m in models:
        if not isinstance(m,dict):
            continue
        v={k:m[k] for k in ('id','api','name','contextWindow','maxTokens','input','output','tools','reasoning','thinking','type','kind') if k in m}
        if isinstance(m.get('identity'),dict):
            v['identity']={'family':m['identity'].get('family')}
        clean.append(v)
    out.append({'providerKey':key,'schemaVersion':version,'updatedAt':updated,'authoritative':True,'models':clean})
print(json.dumps(out,separators=(',',':')))
c.rollback()
c.close()
`;

async function readSourceRecords(databasePath) {
  if (typeof databasePath !== 'string' || !databasePath) throw new Error('metadata_database_required');
  const raw = await new Promise((resolve, reject) => {
    const child = spawn('python3', ['-c', reader, databasePath], { stdio: ['ignore', 'pipe', 'ignore'] });
    const chunks = [];
    let size = 0;
    let oversized = false;
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_BYTES) { oversized = true; child.kill(); } else chunks.push(chunk);
    });
    child.once('error', () => reject(new Error('metadata_read_failed')));
    child.once('close', code => code === 0 && !oversized
      ? resolve(Buffer.concat(chunks).toString('utf8')) : reject(new Error('metadata_read_failed')));
  });
  const records = JSON.parse(raw);
  if (!Array.isArray(records)) throw new Error('metadata_read_failed');
  return records;
}

export async function loadNativeMetadata(databasePath) {
  return (await readSourceRecords(databasePath)).filter(validSource).map(sanitizeSource);
}

// Authoritative rows refused only for their schema version, named for the
// operator: "<provider> v<version>", never any of the cached model data.
function unsupportedCacheVersions(records) {
  return [...new Set(records.filter(source => record(source) && typeof source.providerKey === 'string'
    && providerKey.test(source.providerKey) && !OMP_MODEL_CACHE_VERSIONS.includes(source.schemaVersion))
    .map(source => `${source.providerKey.split(':')[0]} v${cacheVersionLabel(source.schemaVersion)}`))].sort();
}

function validSource(source) {
  return record(source) && source.authoritative === true && typeof source.providerKey === 'string'
    && providerKey.test(source.providerKey) && OMP_MODEL_CACHE_VERSIONS.includes(source.schemaVersion)
    && Number.isSafeInteger(source.updatedAt) && source.updatedAt >= 0
    && Array.isArray(source.models) && source.models.length <= 4096;
}

function sanitizeThinking(value) {
  if (!record(value) || !modes.has(value.mode) || !Array.isArray(value.efforts)
    || !value.efforts.length || value.efforts.length > efforts.size
    || new Set(value.efforts).size !== value.efforts.length || value.efforts.some(e => !efforts.has(e))) return null;
  if (Object.keys(value).some(key => !['mode', 'efforts'].includes(key)
    && (!thinkingBooleans.has(key) || typeof value[key] !== 'boolean'))) return null;
  const clean = { mode: value.mode, efforts: [...value.efforts] };
  for (const key of thinkingBooleans) if (Object.hasOwn(value, key)) clean[key] = value[key];
  return clean;
}

function sanitizeModel(model) {
  if (!record(model)) return null;
  const clean = {};
  for (const key of ['id', 'api', 'name', 'type', 'kind']) {
    if (typeof model[key] === 'string' && model[key].length <= 200 && !/[\x00-\x1f\x7f]/.test(model[key])) clean[key] = model[key];
  }
  for (const key of ['contextWindow', 'maxTokens']) if (model[key] === null || Number.isSafeInteger(model[key])) clean[key] = model[key];
  for (const key of ['reasoning', 'tools']) if (typeof model[key] === 'boolean') clean[key] = model[key];
  for (const key of ['input', 'output']) if (Array.isArray(model[key]) && model[key].length <= 2
    && model[key].every(v => ['text', 'image'].includes(v))) clean[key] = [...model[key]];
  for (const key of ['type', 'kind', 'tools', 'output']) if (Object.hasOwn(model, key) && !Object.hasOwn(clean, key)) clean[key] = null;
  if (record(model.identity) && model.identity.family === 'gpt-image') clean.identity = { family: 'gpt-image' };
  if (model.thinking !== undefined) clean.thinking = sanitizeThinking(model.thinking);
  return clean;
}

function sanitizeSource(source) {
  return { providerKey: source.providerKey, schemaVersion: source.schemaVersion, updatedAt: source.updatedAt,
    authoritative: true, models: source.models.map(sanitizeModel).filter(Boolean) };
}

function provenance(source) {
  return { providerKey: source.providerKey, updatedAt: source.updatedAt, schemaVersion: source.schemaVersion };
}

function capability(model, source) {
  // Cache versions up to 14 mark a model's kind with `type`, 15 with `kind`.
  if (Object.hasOwn(model, 'type') && model.type !== 'chat' || Object.hasOwn(model, 'kind') && model.kind !== 'chat'
    || model.identity?.family === 'gpt-image') return { reason: 'non_chat_model' };
  const claude = source.providerKey.split(':')[0] === 'anthropic';
  if (claude ? model.api !== 'anthropic-messages' : !['openai-responses', 'openai-codex-responses'].includes(model.api)) return { reason: 'unsupported_transport' };
  if (!positive(model.contextWindow) || !positive(model.maxTokens)) return { reason: 'invalid_limits' };
  if (!model.name || !Array.isArray(model.input) || !model.input.includes('text')
    || new Set(model.input).size !== model.input.length || typeof model.reasoning !== 'boolean'
    || Object.hasOwn(model, 'tools') && model.tools !== true
    || Object.hasOwn(model, 'output') && (!Array.isArray(model.output) || model.output.length !== 1 || model.output[0] !== 'text')) return { reason: 'invalid_capabilities' };
  if (model.reasoning ? !model.thinking : model.thinking != null) return { reason: 'invalid_reasoning_metadata' };
  if (model.reasoning && (claude ? model.thinking.mode === 'effort' : model.thinking.mode !== 'effort')) return { reason: 'invalid_reasoning_metadata' };
  return { id: model.id, providerID: claude ? 'ompgw-claude' : 'ompgw-codex',
    api: claude ? 'anthropic-messages' : 'openai-responses', name: model.name,
    contextWindow: model.contextWindow, maxTokens: model.maxTokens, input: model.input,
    // These two supported native chat transports lower function tools and emit
    // text by protocol; absent cache fields are not borrowed sibling metadata.
    output: ['text'], tools: true, reasoning: model.reasoning, thinking: model.thinking ?? null,
    source: provenance(source) };
}

export function resolveCatalog(published, sourceRecords) {
  const data = Array.isArray(published) ? published : published?.data;
  if (!Array.isArray(data) || data.length > 4096) throw new Error('invalid_published_catalog');
  const ids = data.map(item => typeof item === 'string' ? item : item?.id);
  if (ids.some(id => typeof id !== 'string' || !safeID.test(id))) throw new Error('invalid_published_id');
  if (!Array.isArray(sourceRecords)) throw new Error('invalid_source_records');
  const selected = [];
  for (const base of ['anthropic', 'openai-codex']) {
    const candidates = sourceRecords.filter(validSource).filter(s => s.providerKey.split(':')[0] === base).map(sanitizeSource);
    candidates.sort((a, b) => b.schemaVersion - a.schemaVersion || b.updatedAt - a.updatedAt || a.providerKey.localeCompare(b.providerKey));
    if (candidates.length) selected.push(...candidates.filter(s => s.schemaVersion === candidates[0].schemaVersion && s.updatedAt === candidates[0].updatedAt));
  }
  const models = [], excluded = [];
  for (const id of [...new Set(ids)].sort()) {
    if (id.startsWith('omp/')) { excluded.push({ id, reason: 'policy_omp_alias' }); continue; }
    if (/^(?:gpt-image|chatgpt-image|dall-e)(?:[-.]|$)/.test(id)) { excluded.push({ id, reason: 'non_chat_model' }); continue; }
    const providerID = id.startsWith('claude-') ? 'ompgw-claude'
      : /^(?:gpt-|codex(?:-|$))/.test(id) ? 'ompgw-codex' : null;
    const fallback = providerID && { id, providerID,
      api: providerID === 'ompgw-claude' ? 'anthropic-messages' : 'openai-responses',
      name: id, source: { kind: 'gateway-advertised' } };
    const matches = selected.flatMap(source => source.models.filter(m => m.id === id).map(model => capability(model, source)));
    const signatures = matches.map(({ source, ...model }) => JSON.stringify(model));
    const reason = !matches.length ? 'metadata_unavailable'
      : new Set(signatures).size !== 1 ? 'conflicting_authoritative_metadata' : matches[0].reason;
    if (!reason) models.push(matches[0]);
    else if (fallback && !matches.some(model => model.reason === 'non_chat_model')) models.push(fallback);
    else excluded.push({ id, reason });
  }
  return { schemaVersion: 1, models, excluded,
    sources: selected.map(s => ({ ...provenance(s), hashVerification: 'not_verified' })) };
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 2 || args[0] !== '--metadata-db') throw new Error('usage: catalog.mjs --metadata-db PATH');
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_BYTES) throw new Error('published_catalog_too_large');
    chunks.push(chunk);
  }
  const published = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  let records;
  try { records = await readSourceRecords(args[1]); }
  catch { process.stderr.write('Capability metadata unavailable; advertised chat models use native client defaults.\n'); records = []; }
  const unsupported = unsupportedCacheVersions(records);
  if (unsupported.length) {
    process.stderr.write(`OMP capability metadata refused: unsupported OMP model_cache schema ${unsupported.join(', ')} (this Celestial reads ${OMP_MODEL_CACHE_VERSIONS.join(', ')}); those providers' advertised chat models use native client defaults.\n`);
  }
  const catalog = resolveCatalog(published, records.filter(validSource).map(sanitizeSource));
  // A silent all-defaults catalog removed every effort variant once; say so.
  if (!catalog.sources.length) process.stderr.write('No usable OMP capability metadata (unsupported cache version?); all advertised chat models use native client defaults.\n');
  process.stdout.write(`${JSON.stringify(catalog)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    const safe = new Set(['metadata_database_required', 'metadata_read_failed', 'invalid_published_catalog', 'invalid_published_id', 'published_catalog_too_large', 'usage: catalog.mjs --metadata-db PATH']);
    process.stderr.write(`opencode catalog: ${safe.has(error.message) ? error.message : 'catalog_read_failed'}\n`);
    process.exitCode = 1;
  });
}
