import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildConfig, scopedConfigInput } from './config.mjs';

const launcher = fileURLToPath(new URL('./launch.mjs', import.meta.url));
const plugin = fileURLToPath(new URL('./plugin', import.meta.url));
const fixture = new URL('../../tests/lib/opencode-runtime-fixture.mjs', import.meta.url).href;

async function run(options = {}, args = ['--standalone', '--auto'], interrupt = false) {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-launch-test-'));
  const executable = path.join(dir, 'native-fixture');
  const events = path.join(dir, 'events.jsonl');
  const roleFile = path.join(dir, 'role.md');
  await writeFile(executable, `#!${process.execPath}\nimport(${JSON.stringify(fixture)}).then(module => module.runFixture());\n`);
  await chmod(executable, 0o700);
  await writeFile(roleFile, 'Fixture role');
  const config = buildConfig(scopedConfigInput({ agent: 'cel-orchestrator', roleFile, pluginFile: plugin, baseURL: 'http://127.0.0.1:1/v1' }));
  // An allowlisted env prevents this fixture from inheriting credentials or a
  // Rex receipt. It implements no provider endpoint and can never infer.
  const env = { PATH: process.env.PATH, HOME: dir, OPENCODE_CONFIG_CONTENT: JSON.stringify(config), CEL_OPENCODE_AGENT: 'cel-orchestrator', CEL_ROLE_FILE: roleFile, CEL_FIXTURE_EVENTS: events, CEL_FIXTURE_TUI_EXIT: '1', ...options };
  const child = spawn(process.execPath, [launcher, '--', executable, ...args], { cwd: dir, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
  child.stdout.on('data', text => { output += text; });
  child.stderr.on('data', text => { output += text; });
  const cancellation = interrupt ? setInterval(async () => {
    const text = await readFile(events, 'utf8').catch(() => '');
    if (text.includes('"event":"tui"')) child.kill('SIGTERM');
  }, 25) : undefined;
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
  clearInterval(cancellation);
  const rows = await readFile(events, 'utf8').then(text => text.trim().split('\n').filter(Boolean).map(line => JSON.parse(line)), error => error.code === 'ENOENT' ? [] : Promise.reject(error));
  for (const pid of new Set(rows.filter(row => ['serve', 'tui'].includes(row.event)).map(row => row.pid))) {
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' }, 'owned native generation survived launcher exit');
  }
  await rm(dir, { recursive: true, force: true });
  return { code, rows, output, directory: dir };
}

test('private server admission precedes TUI; transient empty plugin inventory is awaited', async () => {
  const result = await run({ CEL_FIXTURE_PLUGIN: 'delayed' }, ['--standalone', '--auto', '--prompt', 'deterministic fixture']);
  assert.equal(result.code, 0, result.output);
  const events = result.rows.map(row => row.event);
  assert.equal(result.rows[0].admission, false);
  assert.equal(events.filter(event => event === '/api/plugin').length, 2);
  assert.ok(events.indexOf('/api/model') < events.indexOf('tui'));
  const tui = result.rows.find(row => row.event === 'tui');
  assert.ok(tui.args.includes('--server'));
  assert.ok(!tui.args.includes('--standalone'));
  assert.ok(tui.args.includes('deterministic fixture'));
  assert.deepEqual(tui.handoff, { directory: result.directory, agent: 'cel-orchestrator', model: { providerID: 'ompgw-codex', id: 'gpt-6.1-sol', variant: 'medium' } });
  assert.equal(tui.mode, 0o600);
  assert.equal(tui.directoryMode, 0o700);
  assert.ok(!events.includes('server-signal'), 'stdio lease EOF should finish before signal escalation');
});

for (const mode of ['failed', 'wrong-source', 'duplicate']) {
  test(`guard ${mode} refuses before TUI and cleans owned server`, async () => {
    const result = await run({ CEL_FIXTURE_PLUGIN: mode });
    assert.notEqual(result.code, 0);
    assert.ok(!result.rows.some(row => row.event === 'tui'));
    assert.ok(!result.output.includes('fixture-secret-do-not-echo'));
  });
}

for (const mode of ['missing', 'wrong-medium']) {
  test(`native resume ${mode} refuses without creating or attaching`, async () => {
    const result = await run({ CEL_FIXTURE_SESSION: mode }, ['--standalone', '--auto', '--session', 'ses_SavedNative']);
    assert.notEqual(result.code, 0);
    assert.ok(result.rows.some(row => row.event === '/api/session/ses_SavedNative'));
    assert.ok(!result.rows.some(row => row.event === 'tui'));
    assert.ok(result.rows.every(row => !row.event.includes('prompt')));
  });
}

test('existing exact native session is read before admission and passed unchanged', async () => {
  const result = await run({}, ['--standalone', '--auto', '--session', 'ses_SavedNative']);
  assert.equal(result.code, 0, result.output);
  const events = result.rows.map(row => row.event);
  assert.ok(events.indexOf('/api/session/ses_SavedNative') < events.indexOf('tui'));
  assert.ok(result.rows.find(row => row.event === 'tui').args.includes('ses_SavedNative'));
  assert.deepEqual(result.rows.find(row => row.event === 'tui').handoff, {
    sessionID: 'ses_SavedNative', directory: result.directory, agent: 'cel-orchestrator',
    model: { providerID: 'ompgw-codex', id: 'gpt-6.1-sol', variant: 'medium' },
  });
});

test('unfinished migration never attaches or creates a session', async () => {
  const result = await run({ CEL_FIXTURE_MIGRATION: 'required' });
  assert.notEqual(result.code, 0);
  assert.ok(!result.rows.some(row => row.event === 'tui'));
});

test('native server, model and agent override flags refuse before native startup', async () => {
  for (const args of [['--server', 'http://127.0.0.1:1'], ['--model', 'other/model'], ['--agent', 'other'], ['--continue'], ['--session', 'ses_one', '--session', 'ses_two']]) {
    const result = await run({}, args);
    assert.notEqual(result.code, 0);
    assert.equal(result.rows.length, 0);
  }
});

test('terminating the owned parent stops both exact native children', async () => {
  const result = await run({ CEL_FIXTURE_TUI_EXIT: '0' }, ['--standalone', '--auto'], true);
  assert.notEqual(result.code, 0);
  assert.ok(result.rows.some(row => row.event === 'serve'));
  assert.ok(result.rows.some(row => row.event === 'tui'));
});
