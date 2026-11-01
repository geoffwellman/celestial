import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, readdir, chmod, stat, symlink, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildConfig, scopedConfigInput } from './config.mjs';
import { resolveCatalog } from './catalog.mjs';
import { validateScopedSelection } from './sync.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url)).replace(/\/$/, '');
const script = fileURLToPath(new URL('./sync.mjs', import.meta.url));
const published = ['gpt-6.1-sol', 'claude-advertised-retired', 'omp/gpt-6.1-sol', 'gpt-image-1'];
const catalog = () => resolveCatalog(published, [{ providerKey: 'openai-codex:0.159.0', schemaVersion: 14,
  authoritative: true, updatedAt: 100, models: [{ id: 'gpt-6.1-sol', name: 'Sol 6.1', api: 'openai-responses',
    contextWindow: 500000, maxTokens: 128000, input: ['text', 'image'], reasoning: true,
    thinking: { mode: 'effort', efforts: ['low', 'medium', 'high'] } }] }]);

async function child(command, args, input = '', env = process.env) {
  const p = spawn(command, args, { env, stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '', stderr = '';
  p.stdout.setEncoding('utf8'); p.stderr.setEncoding('utf8');
  p.stdout.on('data', value => { stdout += value; }); p.stderr.on('data', value => { stderr += value; });
  p.stdin.on('error', () => {}); p.stdin.end(input);
  const code = await new Promise((resolve, reject) => { p.once('error', reject); p.once('close', resolve); });
  return { code, stdout, stderr };
}

async function fixture(t) {
  const workspaceDir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-sync-'));
  t.after(() => rm(workspaceDir, { recursive: true, force: true }));
  const namespace = path.join(workspaceDir, '.cel/opencode/fixture-orch');
  await mkdir(namespace, { recursive: true, mode: 0o700 });
  await chmod(path.dirname(namespace), 0o700);
  const roleFile = path.join(namespace, 'role-orchestrator.md');
  const configFile = path.join(namespace, 'role-orchestrator.opencode.json');
  const options = { workspaceDir, agent: 'fixture-orch', pluginFile: path.join(root, 'tools/opencode/plugin'), baseURL: 'http://127.0.0.1:8317/v1' };
  const scope = { agent: 'cel-orchestrator', roleFile, pluginFile: options.pluginFile, baseURL: options.baseURL };
  await writeFile(roleFile, 'unchanged role', { mode: 0o600 });
  const config = buildConfig(scopedConfigInput(scope));
  await writeFile(configFile, `${JSON.stringify(config)}\n`, { mode: 0o600 });
  const args = ['--workspace-dir', workspaceDir, '--agent', options.agent, '--plugin-file', options.pluginFile, '--base-url', options.baseURL];
  return { options, scope, namespace, roleFile, configFile, config, args };
}

async function sync(f, extra = [], data = catalog()) {
  return child(process.execPath, [script, ...f.args, ...extra], JSON.stringify(data));
}

test('dry-run discloses only inventory and performs no publication or lock creation', async t => {
  const f = await fixture(t), before = await readFile(f.configFile), files = await readdir(f.namespace);
  const result = await sync(f, ['--dry-run']);
  assert.equal(result.code, 0, result.stderr);
  const output = JSON.parse(result.stdout);
  assert.equal(output.dryRun, true); assert.equal(output.activationRequired, true);
  assert.ok(output.models.some(row => row.id === 'claude-advertised-retired'));
  assert.ok(output.excluded.some(row => row.id === 'omp/gpt-6.1-sol'));
  for (const secret of ['apiKey', 'OMP_GATEWAY_TOKEN', 'baseURL', 'CEL_SESSION_ID', f.roleFile]) assert.ok(!result.stdout.includes(secret));
  assert.deepEqual(await readFile(f.configFile), before);
  assert.deepEqual(await readdir(f.namespace), files);
});

test('sync atomically backs up private canonical config without changing selection, references or unrelated scope', async t => {
  const f = await fixture(t), before = await readFile(f.configFile);
  const unrelated = path.join(f.options.workspaceDir, 'unrelated.json'); await writeFile(unrelated, 'private-other-scope');
  const result = await sync(f); assert.equal(result.code, 0, result.stderr);
  const output = JSON.parse(result.stdout), config = JSON.parse(await readFile(f.configFile, 'utf8'));
  assert.equal(output.activationRequired, true); assert.match(output.activation, /same-SID/);
  assert.deepEqual(config.model, f.config.model); assert.deepEqual(config.agents, f.config.agents);
  assert.deepEqual(config.providers['ompgw-codex'].settings, f.config.providers['ompgw-codex'].settings);
  assert.deepEqual(config.providers['ompgw-codex'].headers, f.config.providers['ompgw-codex'].headers);
  assert.equal(await readFile(f.roleFile, 'utf8'), 'unchanged role'); assert.equal(await readFile(unrelated, 'utf8'), 'private-other-scope');
  const backups = (await readdir(f.namespace)).filter(name => name.includes('.bak-')); assert.equal(backups.length, 1);
  assert.deepEqual(await readFile(path.join(f.namespace, backups[0])), before);
  for (const file of [f.configFile, path.join(f.namespace, backups[0])]) assert.equal((await stat(file)).mode & 0o777, 0o600);
  const repeat = await sync(f); assert.equal(repeat.code, 0, repeat.stderr); assert.equal(JSON.parse(repeat.stdout).changed, false);
});

test('missing, noncanonical, public or symlinked scoped files refuse without clobbering', async t => {
  for (const kind of ['missing', 'custom-provider', 'public', 'symlink']) {
    const f = await fixture(t);
    if (kind === 'missing') await rm(f.configFile);
    if (kind === 'custom-provider') { f.config.providers.custom = { secret: 'private-sentinel' }; await writeFile(f.configFile, JSON.stringify(f.config)); }
    if (kind === 'public') await chmod(f.configFile, 0o644);
    if (kind === 'symlink') { await rm(f.configFile); await symlink(f.roleFile, f.configFile); }
    const before = await readFile(f.roleFile);
    const result = await sync(f); assert.notEqual(result.code, 0, kind); assert.ok(!result.stderr.includes('private-sentinel'));
    assert.deepEqual(await readFile(f.roleFile), before);
    assert.ok(!(await readdir(f.namespace)).some(name => name.includes('.bak-')));
  }
});

test('catalog scope admits owner-chosen eligible native selections and rejects aliases, unknown models and variants', async t => {
  const f = await fixture(t);
  assert.equal(await validateScopedSelection(f.options, { providerID: 'ompgw-codex', id: 'gpt-6.1-sol', variant: 'high' }), false);
  assert.equal((await sync(f)).code, 0);
  assert.equal(await validateScopedSelection(f.options, { providerID: 'ompgw-codex', id: 'gpt-6.1-sol', variant: 'high' }), true);
  assert.equal(await validateScopedSelection(f.options, { providerID: 'ompgw-claude', id: 'claude-advertised-retired' }), true);
  for (const selection of [{ providerID: 'ompgw-codex', id: 'omp/gpt-6.1-sol' }, { providerID: 'ompgw-codex', id: 'unknown' },
    { providerID: 'ompgw-codex', id: 'gpt-image-1' }, { providerID: 'ompgw-codex', id: 'gpt-6.1-sol', variant: 'invented' }]) {
    assert.equal(await validateScopedSelection(f.options, selection), false);
  }
});

test('shared shell preflight reads a native root without changing its store and honors catalog selection', async t => {
  const f = await fixture(t);
  assert.equal((await sync(f)).code, 0);
  const dataHome = path.join(f.options.workspaceDir, 'native-data');
  await mkdir(path.join(dataHome, 'opencode'), { recursive: true });
  const database = path.join(dataHome, 'opencode/opencode.db');
  const setup = `import sqlite3,json,sys
c=sqlite3.connect(sys.argv[1])
c.execute('create table kv(key text primary key,value text)')
c.execute('create table session_v2(id text primary key,parent_id text,directory text,workspace_id text,agent text,model text)')
c.execute('insert into session_v2 values(?,?,?,?,?,?)',('ses_fixture',None,sys.argv[2],None,'cel-orchestrator',json.dumps({'providerID':'ompgw-claude','id':'claude-advertised-retired'})))
c.execute('insert into session_v2 values(?,?,?,?,?,?)',('ses_forbidden',None,sys.argv[2],None,'cel-orchestrator',json.dumps({'providerID':'ompgw-codex','id':'omp/gpt-6.1-sol'})))
c.commit()
c.close()
`;
  const seeded = await child('python3', ['-c', setup, database, f.options.workspaceDir]);
  assert.equal(seeded.code, 0, seeded.stderr);
  const before = await readFile(database);
  const command = 'source "$CEL_ROOT/lib/opencode.sh"; gateway_url() { printf http://127.0.0.1:8317; }; opencode_validate_session "$1" "$2" cel-orchestrator "$2"';
  const env = { ...process.env, CEL_ROOT: root, CEL_OPENCODE_CONFIG_FILE: f.configFile, XDG_DATA_HOME: dataHome, OPENCODE_DB: 'opencode.db' };
  const allowed = await child('bash', ['-c', command, 'fixture', 'ses_fixture', f.options.workspaceDir], '', env);
  assert.equal(allowed.code, 0, allowed.stderr);
  const forbidden = await child('bash', ['-c', command, 'fixture', 'ses_forbidden', f.options.workspaceDir], '', env);
  assert.notEqual(forbidden.code, 0);
  assert.deepEqual(await readFile(database), before);
});
