import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const helper = fileURLToPath(new URL('../../tools/pi/codex-catalog.mjs', import.meta.url));
const piLevels = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];
const codexIds = ['gpt-5.6-luna', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-6-astra', 'gpt-6-luna', 'gpt-6-sol', 'gpt-6.1-sol', 'gpt-6.1-terra'];
const anthropicIds = ['claude-haiku-4-5', 'claude-haiku-4-5-20251001', 'claude-haiku-5-5', 'claude-opus-4-5', 'claude-opus-4-5-20251101', 'claude-opus-4-6', 'claude-opus-4-7', 'claude-opus-4-8', 'claude-opus-5', 'claude-opus-5-5', 'claude-sonnet-4-5', 'claude-sonnet-4-5-20250929', 'claude-sonnet-4-6', 'claude-sonnet-5-5'];
const model = (id, provider = 'openai-codex') => ({
  id, name: `Published ${id}`, provider,
  api: provider === 'anthropic' ? 'anthropic-messages' : 'openai-codex-responses',
  type: 'chat', reasoning: true, input: ['text', 'image'], contextWindow: 272000, maxTokens: 128000,
});
const nativeModel = (id, provider) => ({
  ...model(id, provider),
  thinkingLevelMap: { off: null, minimal: 'low', low: 'low', medium: 'medium', high: 'high', xhigh: 'xhigh', max: 'max' },
  compat: provider === 'anthropic'
    ? { forceAdaptiveThinking: true, supportsMidConvoEffort: true, supportsMidConvoToolChanges: true }
    : { supportsMidConvoSystemMessages: true, supportsAdditionalTools: true, supportsOpenAIGrammarTools: true },
  baseUrl: 'https://native.invalid/DO-NOT-COPY', headers: { Authorization: 'SECRET-NATIVE' }, apiKey: 'SECRET-NATIVE',
});
const authoritativeModel = (id, provider = 'openai-codex') => ({
  ...model(id, provider),
  contextWindow: id.startsWith('gpt-5.6') ? 1000000 : id.startsWith('gpt-6.1') ? 500000 : provider === 'anthropic' ? 1000000 : 272000,
  thinking: { mode: provider === 'anthropic' ? 'anthropic-adaptive' : 'effort', efforts: ['low', 'medium', 'high', 'xhigh', 'max'] },
  apiKey: 'SECRET-CACHE', baseUrl: 'https://cache.invalid/DO-NOT-COPY', headers: { Authorization: 'SECRET-CACHE' },
  compat: { wrongOmpOnlyFlag: true, apiKey: 'SECRET-CACHE' },
});

function fixture(t) {
  const dir = mkdtempSync(path.join(tmpdir(), 'pi-exact-catalog-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const coding = path.join(dir, 'node_modules/@earendil-works/pi-coding-agent');
  const ai = path.join(coding, 'node_modules/@earendil-works/pi-ai');
  const dataRoot = path.join(ai, 'dist/providers/data');
  mkdirSync(dataRoot, { recursive: true });
  mkdirSync(path.join(coding, 'dist/bundle'), { recursive: true });
  const cli = path.join(coding, 'dist/bundle/cli.js');
  writeFileSync(cli, "throw new Error('CLI MUST NOT EXECUTE');\n");
  writeFileSync(path.join(coding, 'package.json'), JSON.stringify({ name: '@earendil-works/pi-coding-agent', type: 'module', dependencies: { '@earendil-works/pi-ai': '1.4.0' } }));
  writeFileSync(path.join(ai, 'package.json'), JSON.stringify({ name: '@earendil-works/pi-ai', type: 'module', main: './WRONG.js', exports: { '.': { types: './dist/index.d.ts', import: './dist/index.js' } } }));
  writeFileSync(path.join(ai, 'dist/index.js'), "throw new Error('PROVIDER RUNTIME MUST NOT IMPORT');\n");
  const env = { PATH: process.env.PATH, HOME: dir, TMPDIR: dir };
  const db = path.join(dir, '.omp/agent/models.db');
  const f = {
    dir, cli, db, ai, env,
    native: {
      'openai-codex': Object.fromEntries(codexIds.filter((id) => id !== 'gpt-6.1-terra').map((id) => [`chat:${id}`, nativeModel(id, 'openai-codex')])),
      anthropic: Object.fromEntries(anthropicIds.map((id) => [`chat:${id}`, nativeModel(id, 'anthropic')])),
    },
    rows: [
      { provider: 'openai-codex:0.159.0', version: 14, updated: 200, authoritative: 1, models: codexIds.map((id) => authoritativeModel(id)) },
      { provider: 'anthropic', version: 14, updated: 200, authoritative: 1, models: anthropicIds.map((id) => authoritativeModel(id, 'anthropic')) },
    ],
    saveNative() {
      for (const provider of ['anthropic', 'openai-codex']) {
        const api = provider === 'anthropic' ? 'anthropic-messages' : 'openai-codex-responses';
        writeFileSync(path.join(dataRoot, `${provider}.json`), JSON.stringify({ [api]: f.native[provider] }));
      }
    },
    saveCache() {
      mkdirSync(path.dirname(db), { recursive: true });
      const code = `import json, sqlite3, sys
rows = json.loads(sys.stdin.read())
with sqlite3.connect(sys.argv[1]) as db:
 db.execute('CREATE TABLE IF NOT EXISTS model_cache (provider_id TEXT PRIMARY KEY, version INTEGER, updated_at INTEGER, authoritative INTEGER, models TEXT)')
 db.execute('DELETE FROM model_cache')
 db.executemany('INSERT INTO model_cache VALUES (?, ?, ?, ?, ?)', [(r['provider'], r['version'], r['updated'], r['authoritative'], json.dumps(r['models'])) for r in rows])
`;
      const result = spawnSync('python3', ['-c', code, db], { input: JSON.stringify(f.rows), encoding: 'utf8', env });
      assert.equal(result.status, 0, result.stderr);
    },
    run({ explicit = true } = {}) {
      return spawnSync(process.execPath, [helper, cli, ...(explicit ? [db] : [])], { env, encoding: 'utf8', timeout: 10000 });
    },
  };
  f.saveNative();
  f.saveCache();
  return f;
}
function success(result) {
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}
function failure(result, expected) {
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.match(JSON.parse(result.stderr).error, expected);
}
function omissions(result) {
  return result.stderr.trim() ? JSON.parse(result.stderr).omitted : [];
}

test('catalog resolves an ESM-only dependency from the actual Pi CLI without executing it', (t) => {
  const f = fixture(t);
  const result = f.run();
  const models = success(result);
  assert.equal(models.length, 22);
  assert.deepEqual(new Set(models.map((entry) => entry.api)), new Set(['anthropic-messages', 'openai-responses']));
  assert.deepEqual(models.map((entry) => entry.id), [...codexIds, ...anthropicIds].sort((a, b) => a.localeCompare(b)));
  assert.equal(result.stderr, '');
});

test('exact authoritative metadata overrides stale Pi limits, vision, and reasoning without copying OMP compat', (t) => {
  const f = fixture(t);
  const native = f.native['openai-codex']['chat:gpt-5.6-sol'];
  native.contextWindow = 128000; native.maxTokens = 8192; native.reasoning = false; native.input = ['text'];
  f.saveNative();
  const models = success(f.run());
  const sol = models.find((entry) => entry.id === 'gpt-5.6-sol');
  assert.deepEqual([sol.contextWindow, sol.maxTokens, sol.reasoning, sol.input], [1000000, 128000, true, ['text', 'image']]);
  assert.deepEqual(sol.compat, native.compat);
  assert.deepEqual(sol.thinkingLevelMap, native.thinkingLevelMap);
  for (const id of ['gpt-5.6-luna', 'gpt-5.6-terra']) assert.equal(models.find((entry) => entry.id === id).contextWindow, 1000000);
  for (const id of ['gpt-6-astra', 'gpt-6-luna', 'gpt-6-sol']) assert.equal(models.find((entry) => entry.id === id).contextWindow, 272000);
  assert.equal(models.find((entry) => entry.id === 'gpt-6.1-sol').contextWindow, 500000);
  const opus = models.find((entry) => entry.id === 'claude-opus-5-5');
  assert.equal(opus.contextWindow, 1000000);
  assert.deepEqual(opus.compat, f.native.anthropic['chat:claude-opus-5-5'].compat);
});

test('Terra absent from Pi native uses only exact OMP effort metadata, not sibling maps', (t) => {
  const f = fixture(t);
  const terra = success(f.run()).find((entry) => entry.id === 'gpt-6.1-terra');
  assert.deepEqual(terra.thinkingLevelMap, { off: null, minimal: null, low: 'low', medium: 'medium', high: 'high', xhigh: 'xhigh', max: 'max' });
  assert.equal(terra.contextWindow, 500000);
  assert.equal(terra.maxTokens, 128000);
  assert.equal(Object.hasOwn(terra, 'compat'), false);
  f.rows[0].models.find((entry) => entry.id === terra.id).thinking.efforts = ['none', 'medium'];
  f.saveCache();
  const onlyExact = success(f.run()).find((entry) => entry.id === terra.id);
  assert.deepEqual(onlyExact.thinkingLevelMap, Object.fromEntries(piLevels.map((level) => [level, level === 'off' ? 'none' : level === 'medium' ? 'medium' : null])));
});

test('image, retired, scoped aliases, and unsupported exact thinking entries are explicitly omitted', (t) => {
  const f = fixture(t);
  f.native['openai-codex']['chat:gpt-retired'] = nativeModel('gpt-retired', 'openai-codex');
  f.native['openai-codex']['image:gpt-image-2'] = { ...model('gpt-image-2'), type: 'image' };
  f.rows[0].models.push({ ...authoritativeModel('gpt-image-2'), maxTokens: null });
  f.rows[0].models.push(authoritativeModel('omp/gpt-6.1-sol'));
  f.rows[0].models.push({ ...authoritativeModel('gpt-unknown-thinking'), thinking: { mode: 'budget', efforts: ['high'] } });
  f.rows[1].models.push({ ...authoritativeModel('claude-unknown-native', 'anthropic'), thinking: { mode: 'budget', efforts: ['high'] } });
  f.saveNative(); f.saveCache();
  const result = f.run();
  const models = success(result);
  assert.equal(models.length, 22);
  const omitted = omissions(result);
  for (const id of ['gpt-retired', 'gpt-image-2', 'omp/gpt-6.1-sol', 'gpt-unknown-thinking', 'claude-unknown-native']) assert.ok(omitted.some((entry) => entry.id === id && entry.reason));
  assert.ok(!models.some((entry) => entry.id === 'gpt-6.1-sol-unpublished'));
});

test('OMP-only adaptive Anthropic uses exact efforts without sibling compatibility flags', (t) => {
  const f = fixture(t);
  f.rows[1].models.push({ ...authoritativeModel('claude-fable-new', 'anthropic'), thinking: { mode: 'anthropic-adaptive', efforts: ['medium', 'high'] } });
  f.saveCache();
  const adaptive = success(f.run()).find((entry) => entry.id === 'claude-fable-new');
  assert.equal(adaptive.contextWindow, 1000000);
  assert.deepEqual(adaptive.compat, { forceAdaptiveThinking: true, supportsTemperature: false });
  assert.deepEqual(adaptive.thinkingLevelMap, { off: null, minimal: null, low: null, medium: 'medium', high: 'high', xhigh: null, max: null });
});

test('authoritative exact efforts constrain a native map without exposing unsupported levels', (t) => {
  const f = fixture(t);
  f.rows[0].models.find((entry) => entry.id === 'gpt-6.1-sol').thinking.efforts = ['medium'];
  f.saveCache();
  const sol = success(f.run()).find((entry) => entry.id === 'gpt-6.1-sol');
  assert.deepEqual(sol.thinkingLevelMap, { off: null, minimal: null, low: null, medium: 'medium', high: null, xhigh: null, max: null });
});

test('catalog strips credentials, provider options, unknown compat fields, and malformed unknown map keys', (t) => {
  const f = fixture(t);
  const native = f.native['openai-codex']['chat:gpt-6.1-sol'];
  native.compat.apiKey = 'SECRET-COMPAT';
  native.compat.headers = { Authorization: 'SECRET-COMPAT' };
  native.thinkingLevelMap.unknown = { token: 'SECRET-UNKNOWN-MAP' };
  f.saveNative();
  const result = f.run();
  const models = success(result);
  assert.ok(!/SECRET|DO-NOT-COPY|baseUrl|apiKey|Authorization|wrongOmpOnlyFlag|unknown/.test(result.stdout + result.stderr));
  const allowed = new Set(['id', 'name', 'api', 'reasoning', 'input', 'contextWindow', 'maxTokens', 'thinkingLevelMap', 'compat']);
  for (const entry of models) assert.ok(Object.keys(entry).every((key) => allowed.has(key)));
});

test('latest versioned authoritative Codex source wins, ignoring unrelated and non-authoritative sources', (t) => {
  const f = fixture(t);
  f.rows.push({ provider: 'openai-codex:0.158.0', version: 13, updated: 999, authoritative: 1, models: [{ ...authoritativeModel('gpt-5.6-sol'), contextWindow: 1 }] });
  f.rows.push({ provider: 'openai-codex:0.160.0', version: 99, updated: 9999, authoritative: 0, models: [{ ...authoritativeModel('gpt-5.6-sol'), contextWindow: 2 }] });
  f.rows.push({ provider: 'openai', version: 14, updated: 9999, authoritative: 1, models: [{ ...authoritativeModel('gpt-5.6-sol'), contextWindow: 3 }] });
  f.saveCache();
  assert.equal(success(f.run()).find((entry) => entry.id === 'gpt-5.6-sol').contextWindow, 1000000);
  f.rows.push({ provider: 'openai-codex:0.160.0', version: 14, updated: 1, authoritative: 1, models: [{ ...authoritativeModel('gpt-5.6-sol'), contextWindow: 600000 }] });
  f.rows = f.rows.filter((row) => row.authoritative === 1);
  f.saveCache();
  assert.equal(success(f.run()).find((entry) => entry.id === 'gpt-5.6-sol').contextWindow, 600000);
});

test('unknown selected OMP cache schema refuses output rather than silently using stale native limits', (t) => {
  const f = fixture(t);
  f.rows[0].version = 15; f.saveCache();
  failure(f.run(), /Unsupported authoritative OMP cache schema/);
});

test('cache version 13 supplies the same exact capabilities as version 14', (t) => {
  const f = fixture(t);
  for (const row of f.rows) row.version = 13;
  f.saveCache();
  assert.equal(success(f.run()).find((entry) => entry.id === 'gpt-5.6-sol').contextWindow, 1000000);
});

test('source and duplicate exact-ID conflicts refuse output without leaking arbitrary model data', (t) => {
  const f = fixture(t);
  f.rows[0].models[0].provider = 'unrelated-provider'; f.saveCache();
  failure(f.run(), /Authoritative model source conflict/);
  f.rows[0].models[0].provider = 'openai-codex';
  f.rows[0].models.push({ ...authoritativeModel('gpt-6.1-sol'), contextWindow: 123456 }); f.saveCache();
  failure(f.run(), /Conflicting exact model metadata/);
  f.rows[0].models.pop(); f.saveCache();
  f.native['openai-codex']['chat:gpt-6.1-sol'].api = 'anthropic-messages'; f.saveNative();
  failure(f.run(), /Native model source conflict/);
});

test('unsupported provider cache version and incomplete exact chat capabilities never get family defaults', (t) => {
  const f = fixture(t);
  f.rows[0].models.find((entry) => entry.id === 'gpt-6.1-terra').thinking.efforts = ['made-up'];
  f.rows[0].models.find((entry) => entry.id === 'gpt-5.6-sol').maxTokens = null;
  f.saveCache();
  const result = f.run();
  const models = success(result);
  assert.ok(!models.some((entry) => ['gpt-6.1-terra', 'gpt-5.6-sol'].includes(entry.id)));
  assert.ok(omissions(result).some((entry) => entry.id === 'gpt-6.1-terra' && entry.reason === 'unsupported-exact-thinking-metadata'));
  f.rows[0].provider = 'openai-codex:unknown'; f.saveCache();
  failure(f.run(), /Unsupported authoritative Codex cache source/);
});

test('single-argument CLI reads the default cache read-only and does not rewrite it', (t) => {
  const f = fixture(t);
  const before = readFileSync(f.db);
  assert.equal(success(f.run({ explicit: false })).length, 22);
  assert.deepEqual(readFileSync(f.db), before);
});

test('missing default cache reads only native exact models; explicit missing cache is an error', (t) => {
  const f = fixture(t);
  rmSync(f.db);
  const models = success(f.run({ explicit: false }));
  assert.equal(models.length, 21);
  assert.ok(!models.some((entry) => entry.id === 'gpt-6.1-terra'));
  assert.equal(models.find((entry) => entry.id === 'gpt-5.6-sol').contextWindow, 272000);
  failure(f.run(), /explicit OMP model cache does not exist/);
});
