import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, chmod, readFile, readdir, rm, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadNativeMetadata, resolveCatalog } from './catalog.mjs';

const gateway = fileURLToPath(new URL('../../lib/gateway.sh', import.meta.url));
const model = (id = 'exact-chat', overrides = {}) => ({ id, name: 'Exact fixture chat', api: 'openai-codex-responses',
  contextWindow: 500000, maxTokens: 128000, input: ['text', 'image'], reasoning: true,
  thinking: { mode: 'effort', efforts: ['low', 'medium', 'high'] }, ...overrides });
const source = (models = [model()], overrides = {}) => ({ providerKey: 'openai-codex:0.159.0',
  schemaVersion: 14, updatedAt: 100, authoritative: true, models, ...overrides });

async function child(command, args, options = {}, input = '') {
  const p = spawn(command, args, { ...options, stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '', stderr = '';
  p.stdout.setEncoding('utf8'); p.stderr.setEncoding('utf8');
  p.stdout.on('data', text => { stdout += text; });
  p.stderr.on('data', text => { stderr += text; });
  p.stdin.on('error', () => {});
  p.stdin.end(input);
  const code = await new Promise((resolve, reject) => { p.once('error', reject); p.once('close', resolve); });
  return { code, stdout, stderr };
}

async function fixture(t, records = [source()]) {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-catalog-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const db = path.join(dir, 'models.db');
  const script = `import sqlite3,json,sys
c=sqlite3.connect(sys.argv[1])
c.execute('create table model_cache(provider_id text primary key, version integer, updated_at integer, authoritative integer, models text)')
for r in json.loads(sys.stdin.read()):
 c.execute('insert into model_cache values(?,?,?,?,?)',(r['providerKey'],r['schemaVersion'],r['updatedAt'],int(r['authoritative']),json.dumps(r['models'])))
c.commit()
c.close()
`;
  const result = await child('python3', ['-c', script, db], {}, JSON.stringify(records));
  assert.equal(result.code, 0, result.stderr);
  return { dir, db };
}

test('exact authoritative protocol metadata determines capabilities and omissions, not names', () => {
  const claude = model('unfamiliar-id', { api: 'anthropic-messages', thinking: { mode: 'anthropic-adaptive', efforts: ['low', 'max'], supportsDisplay: true } });
  const result = resolveCatalog({ data: [{ id: 'exact-chat' }, { id: 'unfamiliar-id' }, { id: 'unknown' }, { id: 'omp/exact-chat' }] },
    [source(), source([claude], { providerKey: 'anthropic' })]);
  assert.equal(result.schemaVersion, 1);
  assert.equal(result.models.length, 2);
  assert.deepEqual(result.models[0], { ...model(), api: 'openai-responses', providerID: 'ompgw-codex', tools: true, output: ['text'],
    source: { providerKey: 'openai-codex:0.159.0', updatedAt: 100, schemaVersion: 14 } });
  assert.equal(result.models[1].providerID, 'ompgw-claude');
  assert.deepEqual(result.models[1].thinking, claude.thinking);
  assert.deepEqual(result.excluded, [{ id: 'omp/exact-chat', reason: 'policy_omp_alias' }, { id: 'unknown', reason: 'metadata_unavailable' }]);
});

test('advertised chat access survives missing or unusable capability metadata', () => {
  const result = resolveCatalog(['gpt-new-chat', 'claude-legacy-chat', 'codex-auto-review', 'gpt-image-2', 'omp/claude-legacy-chat'],
    [source([model('gpt-new-chat', { maxTokens: null })])]);
  assert.deepEqual(result.models.map(({ id, providerID, source: provenance }) => ({ id, providerID, provenance })), [
    { id: 'claude-legacy-chat', providerID: 'ompgw-claude', provenance: { kind: 'gateway-advertised' } },
    { id: 'codex-auto-review', providerID: 'ompgw-codex', provenance: { kind: 'gateway-advertised' } },
    { id: 'gpt-new-chat', providerID: 'ompgw-codex', provenance: { kind: 'gateway-advertised' } },
  ]);
  assert.ok(result.models.every(model => !Object.hasOwn(model, 'contextWindow') && !Object.hasOwn(model, 'reasoning')));
  assert.deepEqual(result.excluded, [{ id: 'gpt-image-2', reason: 'non_chat_model' },
    { id: 'omp/claude-legacy-chat', reason: 'policy_omp_alias' }]);
});

test('newest appropriate authoritative record wins without unrelated-provider or sibling borrowing', () => {
  const result = resolveCatalog(['exact-chat', 'sibling'], [source(), source([model('exact-chat', { contextWindow: 272000 })], { providerKey: 'openai-codex', updatedAt: 99 }),
    source([model('sibling')], { providerKey: 'nanogpt', updatedAt: 999 }), source([model('sibling')], { providerKey: 'anthropic', authoritative: false })]);
  assert.equal(result.models[0].contextWindow, 500000);
  assert.deepEqual(result.excluded, [{ id: 'sibling', reason: 'metadata_unavailable' }]);
});

test('equally authoritative conflicting records refuse only affected exact IDs', () => {
  const result = resolveCatalog(['exact-chat', 'other'], [source([model(), model('other')]),
    source([model('exact-chat', { maxTokens: 64000 }), model('other')], { providerKey: 'openai-codex:0.160.0' })]);
  assert.deepEqual(result.models.map(m => m.id), ['other']);
  assert.deepEqual(result.excluded, [{ id: 'exact-chat', reason: 'conflicting_authoritative_metadata' }]);
});

for (const [label, overrides, reason] of [
  ['image identity', { identity: { family: 'gpt-image' }, maxTokens: null }, 'non_chat_model'],
  ['image type', { type: 'image' }, 'non_chat_model'],
  ['null output limit', { maxTokens: null }, 'invalid_limits'],
  ['zero context', { contextWindow: 0 }, 'invalid_limits'],
  ['wrong API', { api: 'openai-completions' }, 'unsupported_transport'],
  ['missing vision modalities', { input: undefined }, 'invalid_capabilities'],
  ['invalid output', { output: ['audio'] }, 'invalid_capabilities'],
  ['invalid tools', { tools: 'true' }, 'invalid_capabilities'],
  ['unsupported reasoning mode', { thinking: { mode: 'imagined', efforts: ['high'] } }, 'invalid_reasoning_metadata'],
  ['invalid reasoning effort', { thinking: { mode: 'effort', efforts: ['guessed'] } }, 'invalid_reasoning_metadata'],
  ['unknown thinking properties', { thinking: { mode: 'effort', efforts: ['high'], apiKey: 'private-sentinel' } }, 'invalid_reasoning_metadata'],
]) test(`refuses ${label} rather than supplying invented capabilities`, () => {
  const result = resolveCatalog(['exact-chat'], [source([model('exact-chat', overrides)])]);
  assert.deepEqual(result.excluded, [{ id: 'exact-chat', reason }]);
  assert.equal(result.models.length, 0);
  assert.ok(!JSON.stringify(result).includes('private-sentinel'));
});

test('read-only SQLite loader strips private fields and leaves cache bytes unchanged', async t => {
  const { db } = await fixture(t, [source([model('exact-chat', { baseUrl: 'private-sentinel', accountAccess: { private: true }, apiKey: 'private-sentinel' })]),
    source([model('ignored')], { providerKey: 'nanogpt' }), source([model('ignored')], { providerKey: 'anthropic', authoritative: false })]);
  const before = await readFile(db);
  const records = await loadNativeMetadata(db);
  assert.equal(records.length, 1);
  assert.ok(!JSON.stringify(records).includes('private-sentinel'));
  assert.ok(!JSON.stringify(records).includes('accountAccess'));
  assert.deepEqual(resolveCatalog(['exact-chat'], records).models.map(m => m.id), ['exact-chat']);
  assert.deepEqual(await readFile(db), before);
  assert.equal(resolveCatalog(['exact-chat'], records).sources[0].hashVerification, 'not_verified');
});

test('missing database yields explicit per-ID omission and never creates a database', async t => {
  const { dir } = await fixture(t);
  const missing = path.join(dir, 'absent.db');
  assert.deepEqual(resolveCatalog(['exact-chat'], await loadNativeMetadata(missing)).excluded, [{ id: 'exact-chat', reason: 'metadata_unavailable' }]);
  await assert.rejects(stat(missing), { code: 'ENOENT' });
});

async function gatewayFixture(t, { key = 'fixture-private-safe-key', mode = 0o600, status = 200, body } = {}) {
  const { dir, db } = await fixture(t);
  const state = path.join(dir, 'state');
  if (key !== null) { await mkdir(state); await writeFile(path.join(state, 'api-key'), key); await chmod(path.join(state, 'api-key'), mode); }
  // Both endpoints run in one private network namespace. Host health scanners
  // cannot add unrelated GET / requests; no requests are filtered from evidence.
  const httpFixture = fileURLToPath(new URL('./catalog-http-fixture.mjs', import.meta.url));
  const isolated = await child('bwrap', ['--unshare-user', '--unshare-net', '--unshare-pid',
    '--die-with-parent', '--ro-bind', '/', '/', '--bind', dir, dir,
    '--proc', '/proc', '--dev', '/dev', '--setenv', 'CEL_CATALOG_HTTP_ISOLATED', '1',
    '--', process.execPath, httpFixture, gateway, dir, db], {
    env: { PATH: process.env.PATH, HOME: dir }, cwd: dir,
  }, JSON.stringify({ status, body }));
  assert.equal(isolated.code, 0, `private network fixture failed: ${isolated.stderr}`);
  return { ...JSON.parse(isolated.stdout), dir, state };
}

test('canonical command uses only local GET /v1/models and lists all eligible/excluded IDs', async t => {
  const result = await gatewayFixture(t);
  assert.equal(result.code, 0, result.stderr);
  const catalog = JSON.parse(result.stdout);
  assert.deepEqual(catalog.models.map(m => m.id), ['exact-chat']);
  assert.deepEqual(catalog.excluded, [{ id: 'omp/exact-chat', reason: 'policy_omp_alias' }, { id: 'unknown', reason: 'metadata_unavailable' }]);
  assert.deepEqual(result.requests, [{ url: '/v1/models', auth: 'Bearer fixture-private-safe-key' }]);
  assert.ok(!`${result.stdout}${result.stderr}`.includes('fixture-private-safe-key'));
});

for (const options of [{ key: null }, { key: '' }, { key: 'unsafe\nInjected: header' }, { mode: 0o644 }]) {
  test(`missing or unsafe existing key refuses without auth repair: ${JSON.stringify(options)}`, async t => {
    const result = await gatewayFixture(t, options);
    assert.notEqual(result.code, 0);
    assert.equal(result.stdout, '');
    assert.equal(result.requests.length, 0);
    assert.match(result.stderr, /existing private gateway key unavailable or unsafe/);
    assert.ok(!result.stderr.includes('FORBIDDEN_AUTH_REPAIR'));
    if (options.key === null) assert.ok(!(await readdir(result.dir)).includes('state'));
  });
}

test('failed HTTP and malformed response never produce a partial usable catalog', async t => {
  for (const options of [{ status: 500 }, { body: '{invalid' }, { body: '{}' }]) {
    const result = await gatewayFixture(t, options);
    assert.notEqual(result.code, 0);
    assert.equal(result.stdout, '');
    assert.ok(!result.stderr.includes('fixture-private-safe-key'));
  }
});

test('unknown cache schemas and non-authoritative sources cannot authorize models', () => {
  for (const overrides of [{ schemaVersion: 15 }, { schemaVersion: '14' }, { authoritative: false }, { updatedAt: NaN }]) {
    assert.deepEqual(resolveCatalog(['exact-chat'], [source([model()], overrides)]).excluded,
      [{ id: 'exact-chat', reason: 'metadata_unavailable' }]);
  }
});

test('cache versions 13 and 14 both supply exact capabilities', () => {
  for (const schemaVersion of [13, 14]) {
    const result = resolveCatalog(['exact-chat'], [source([model()], { schemaVersion })]);
    assert.equal(result.models[0].contextWindow, 500000);
    assert.equal(result.models[0].source.schemaVersion, schemaVersion);
  }
});

test('corrupt private SQLite input reports a generic error without exposing its contents', async t => {
  const { dir } = await fixture(t);
  const db = path.join(dir, 'private-sentinel.db');
  await writeFile(db, 'private-sentinel');
  await assert.rejects(loadNativeMetadata(db), { message: 'metadata_read_failed' });
});

test('nonreasoning models preserve explicit false rather than inventing variants', () => {
  const result = resolveCatalog(['exact-chat'], [source([model('exact-chat', { reasoning: false, thinking: undefined })])]);
  assert.equal(result.models[0].reasoning, false);
  assert.equal(result.models[0].thinking, null);
});
