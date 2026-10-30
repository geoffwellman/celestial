import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import plugin from '../hooks/celestial.opencode.mjs';
import { createHooks } from './runtime.mjs';
import { buildConfig, scopedConfigInput, validateConfig } from './config.mjs';

const options = { agent: 'cel-orchestrator', providerID: 'ompgw-codex', modelID: 'gpt-6.1-sol', transport: 'gateway', route: 'existing-route' };
const model = { providerID: options.providerID, modelID: options.modelID };
const created = { event: { type: 'session.created', properties: { info: { id: 'ses_native' } } } };
const state = (type) => ({ event: { type: 'session.status', properties: { sessionID: 'ses_native', status: { type } } } });
async function rexRecord(overrides = {}) {
  const stat = await readFile(`/proc/${process.pid}/stat`, 'utf8');
  return { name: 'fixture-opencode-orch', agent: 'opencode', backend: 'rex', cwd: '/fixture/product', workspace: '/fixture', role: 'solo', pid: process.pid, pid_start: stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[19], ...overrides };
}
const nativeInfo = (id, parentID) => ({ id, parentID, directory: '/fixture/product', model: { providerID: model.providerID, id: model.modelID, variant: 'medium' } });
async function fixture(overrides = {}) {
  let tick, stopped = false, count = 1, status = {}, fail = false;
  const calls = [], delivered = [];
  const lineage = new Map([['ses_native', nativeInfo('ses_native')], ['ses_other', nativeInfo('ses_other')]]);
  const client = { session: {
    get: async ({ path }) => lineage.has(path.id) ? { data: lineage.get(path.id) } : { error: new Error('native session not found') },
    status: async () => ({ data: status }),
    promptAsync: async (args) => {
      delivered.push(args);
      if (fail) throw new Error('fixture transient refusal');
      return { response: { ok: true } };
    },
  } };
  const env = { CEL_ROOT: '/fixture/cel', CEL_INBOX_ME: 'widget-orch', CEL_INBOX_WS: 'sandbox', OMP_GATEWAY_TOKEN: 'fixture-only', GH_TOKEN: 'fixture-github', ...overrides.env };
  const hooks = await createHooks({ client, directory: '/fixture/product' }, options, {
    env, clock: { setInterval(fn) { tick = fn; return { unref() {} }; }, clearInterval() { stopped = true; } },
    run: async (bin, args) => {
      calls.push([bin, args]);
      if (args[0] === 'inbox' && args[1] === 'count') return String(count);
      if (args[0] === 'inbox' && args[1] === 'read') { count = 0; return '[sandbox] {"id":"mail-1","from":"root","kind":"status","message":"native delivery"}\n'; }
      if (bin === 'bash') return args.at(-1).includes('forbidden') ? 'deny protected repository' : 'allow';
      return '';
    }, ...overrides.deps,
  });
  if (!overrides.skipConfig) await hooks.config({ provider: { [options.providerID]: { options: {} } } });
  return { hooks, client, env, calls, delivered, tick: () => tick(), setSession(id, parentID) { lineage.set(id, nativeInfo(id, parentID)); }, setStatus(x) { status = x; }, setFail(x) { fail = x; }, stopped: () => stopped };
}

test('entrypoint exports a native plugin and scoped config preserves explicit Responses/model/medium metadata', () => {
  assert.equal(typeof plugin, 'function');
  const input = { agent: options.agent, roleFile: '/product/role-orchestrator.md', pluginFile: '/cel/tools/hooks/celestial.opencode.mjs', modelID: 'gpt-6.1-sol', transport: 'gateway', baseURL: 'http://127.0.0.1:8317/v1', route: '{env:CEL_SESSION_ID}', limit: { context: 500000, output: 128000 } };
  const config = buildConfig(input);
  assert.equal(config.model, 'ompgw-codex/gpt-6.1-sol');
  assert.equal(config.small_model, config.model);
  assert.deepEqual(config.enabled_providers, ['ompgw-codex']);
  const provider = config.provider['ompgw-codex'];
  assert.equal(provider.npm, '@ai-sdk/openai');
  assert.equal(provider.options.apiKey, '{env:OMP_GATEWAY_TOKEN}');
  assert.equal(provider.options.headers['x-session-id'], '{env:CEL_SESSION_ID}');
  assert.equal(config.plugin[0][1].route, '{env:CEL_SESSION_ID}');
  assert.deepEqual(provider.models['gpt-6.1-sol'].limit, input.limit);
  assert.deepEqual(provider.models['gpt-6.1-sol'].modalities, { input: ['text', 'image'], output: ['text'] });
  assert.equal(config.agent[options.agent].variant, 'medium');
  assert.equal(config.agent[options.agent].prompt, '{file:/product/role-orchestrator.md}');
  assert.throws(() => buildConfig({ ...input, modelID: 'gpt-6-sol' }), /substitution/);
  assert.throws(() => buildConfig({ ...input, limit: undefined }), /evidenced/);
  assert.throws(() => buildConfig({ ...input, route: '' }), /existing explicit/);
});

test('model and medium stay pinned, unrelated plugins/providers and GitHub identity stay intact', async () => {
  const f = await fixture();
  try {
    const config = { plugin: ['global-plugin'], provider: { existing: { options: { existing: true } }, [options.providerID]: { options: { baseURL: 'http://fixture/v1', apiKey: 'fixture-only' } } } };
    await f.hooks.config(config);
    assert.deepEqual(config.plugin, ['global-plugin']);
    assert.deepEqual(config.provider.existing, { options: { existing: true } });
    assert.equal(config.provider[options.providerID].options.baseURL, 'http://fixture/v1');
    assert.equal(config.provider[options.providerID].options.apiKey, 'fixture-only');
    const output = { options: { unrelated: true, reasoningEffort: 'high' } };
    await f.hooks['chat.params']({ model }, output);
    assert.deepEqual(output.options, { unrelated: true, reasoningEffort: 'medium' });
    assert.equal(typeof config.provider[options.providerID].options.fetch, 'function');
    assert.equal(f.env.GH_TOKEN, 'fixture-github');
    await assert.rejects(f.hooks['chat.params']({ model: { providerID: 'openai', modelID: 'gpt-6.1-sol' } }, output), /fallback/);
    await f.hooks['chat.message']({ sessionID: 'ses_native', agent: options.agent }, { message: { model, agent: options.agent } });
  } finally { await f.hooks.dispose(); }
});

test('missing gateway auth refuses rather than silently selecting native credentials', async () => {
  const f = await fixture({ env: { OMP_GATEWAY_TOKEN: '' } });
  try { await assert.rejects(f.hooks['chat.params']({ model }, { options: {} }), /absent/); }
  finally { await f.hooks.dispose(); }
});

test('backlog and later idle mail use native promptAsync, coalesce, retain failed delivery, and never use composer APIs', async () => {
  const f = await fixture();
  try {
    await f.hooks.event(created);
    f.setStatus({ ses_native: { type: 'busy' } });
    await f.tick();
    assert.equal(f.delivered.length, 0);
    f.setStatus({});
    f.setFail(true);
    await f.tick();
    assert.equal(f.delivered.length, 1);
    f.setFail(false);
    await Promise.all([f.tick(), f.tick()]);
    assert.equal(f.delivered.length, 2);
    assert.equal(f.calls.filter(([, a]) => a[0] === 'inbox' && a[1] === 'read').length, 1);
    assert.deepEqual(f.delivered[1].path, { id: 'ses_native' });
    assert.deepEqual(f.delivered[1].body.model, model);
    assert.match(f.delivered[1].body.parts[0].text, /\[mail-1\] \[sandbox\].*native delivery/);
    assert.equal(f.delivered[1].body.agent, options.agent);
    await f.hooks.event(state('idle'));
    await f.tick();
    assert.equal(f.delivered.length, 2);
    assert.ok(f.calls.every(([, a]) => !a.includes('prompt') && !a.includes('send-text')));
  } finally { await f.hooks.dispose(); }
  assert.equal(f.stopped(), true);
  await f.tick();
  assert.equal(f.delivered.length, 2);
});

test('a busy event during an awaited idle query fences the stale response', async () => {
  const f = await fixture();
  try {
    await f.hooks.event(created);
    let resolve, entered;
    const querying = new Promise((r) => { entered = r; });
    f.client.session.status = () => new Promise((r) => { resolve = r; entered(); });
    const polling = f.tick();
    await querying;
    await f.hooks.event(state('busy'));
    resolve({ data: {} });
    await polling;
    assert.equal(f.delivered.length, 0);
    assert.equal(f.calls.length, 0);
  } finally { await f.hooks.dispose(); }
});

test('Rex notes bind only a proven process and actual native session/status', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-note-'));
  const record = path.join(dir, 'record.json');
  await writeFile(record, JSON.stringify(await rexRecord()));
  const f = await fixture({ env: { CEL_SESSION_BACKEND: 'rex', CEL_REX_RECORD: record } });
  try {
    await f.hooks.event(created);
    await f.hooks.event(state('busy'));
    await f.hooks.event(state('idle'));
    const notes = f.calls.filter(([, a]) => a[0] === 'sessions').map(([, a]) => a);
    assert.deepEqual(notes, ['idle', 'working', 'idle'].map((s) => ['sessions', 'note', String(process.pid), s, 'ses_native']));
    await writeFile(record, JSON.stringify(await rexRecord({ pid: 2147483647 })));
    await f.hooks.event(state('busy'));
    assert.equal(f.calls.filter(([, a]) => a[0] === 'sessions').length, 3);
    await assert.rejects(f.hooks['chat.message']({ sessionID: 'ses_other', agent: options.agent, model }, { message: {} }), /already owns/);
  } finally { await f.hooks.dispose(); await rm(dir, { recursive: true, force: true }); }
});

test('guard covers bash, write/edit, all patch source/destination paths, and explicit one-call approval', async () => {
  const f = await fixture();
  try {
    await assert.rejects(f.hooks['tool.execute.before']({ tool: 'bash' }, { args: { command: 'forbidden' } }), /celestial guard/);
    await f.hooks['tool.execute.before']({ tool: 'bash' }, { args: { command: 'CEL_GUARD_ALLOW_ONCE=1 forbidden' } });
    await f.hooks['tool.execute.before']({ tool: 'bash' }, { args: { command: 'CEL_GUARD_ALLOW_ONCE=1' } });
    await assert.rejects(f.hooks['tool.execute.before']({ tool: 'bash' }, { args: { command: 'CEL_GUARD_ALLOW_ONCE=11 forbidden' } }), /celestial guard/);
    await assert.rejects(f.hooks['tool.execute.before']({ tool: 'bash' }, { args: { command: 'CEL_GUARD_ALLOW_ONCE=1x forbidden' } }), /celestial guard/);
    for (const tool of ['edit', 'write']) await assert.rejects(f.hooks['tool.execute.before']({ tool }, { args: { filePath: '/forbidden' } }), /protected repository/);
    await assert.rejects(f.hooks['tool.execute.before']({ tool: 'apply_patch' }, { args: { patchText: '*** Begin Patch\n*** Update File: allowed\n*** Move to: forbidden\n*** End Patch' } }), /protected repository/);
    await assert.rejects(f.hooks['tool.execute.before']({ tool: 'apply_patch' }, { args: { patchText: 'unclassified' } }), /cannot classify/);
    assert.ok(f.calls.some(([, args]) => args.includes('allowed')));
    assert.ok(f.calls.some(([, args]) => args.includes('forbidden')));
  } finally { await f.hooks.dispose(); }
});

test('dispose awaits an accepted reporter subprocess and rejects later status events', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-dispose-'));
  const record = path.join(dir, 'record.json');
  await writeFile(record, JSON.stringify(await rexRecord()));
  let release, started, calls = 0;
  const entered = new Promise((resolve) => { started = resolve; });
  const held = new Promise((resolve) => { release = resolve; });
  const f = await fixture({ env: { CEL_SESSION_BACKEND: 'rex', CEL_REX_RECORD: record }, deps: { run: async () => { calls++; started(); await held; return ''; } } });
  try {
    const event = f.hooks.event(created);
    await entered;
    let settled = false;
    const closing = f.hooks.dispose().then(() => { settled = true; });
    await Promise.resolve();
    assert.equal(settled, false, 'dispose returned while a reporter could still write');
    release();
    await Promise.all([event, closing]);
    await f.hooks.event(state('busy'));
    assert.equal(calls, 1);
    assert.equal(f.stopped(), true);
  } finally { release(); await f.hooks.dispose(); await rm(dir, { recursive: true, force: true }); }
});

test('dispose joins in-flight polling before returning and never drains mail afterwards', async () => {
  const f = await fixture();
  try {
    await f.hooks.event(created);
    let release, entered;
    const querying = new Promise((resolve) => { entered = resolve; });
    f.client.session.status = () => new Promise((resolve) => { release = resolve; entered(); });
    const polling = f.tick();
    await querying;
    let settled = false;
    const closing = f.hooks.dispose().then(() => { settled = true; });
    await Promise.resolve();
    assert.equal(settled, false);
    release({ data: {} });
    await Promise.all([polling, closing]);
    assert.equal(f.calls.length, 0);
    assert.equal(f.delivered.length, 0);
  } finally { await f.hooks.dispose(); }
});

test('scoped provider fetch overrides the exact downstream native session header without touching auth/model/body/global fetch', async () => {
  const f = await fixture();
  const globalFetch = globalThis.fetch;
  const sent = [];
  const response = new Response('local fixture');
  const upstream = async (input, init) => { sent.push({ input, init }); return response; };
  const untouchedFetch = async () => { throw new Error('unrelated provider must not run'); };
  const provider = { options: { baseURL: 'http://fixture/v1', apiKey: 'fixture-only', fetch: upstream } };
  const config = { provider: { [options.providerID]: provider, unrelated: { options: { fetch: untouchedFetch } } } };
  try {
    await f.hooks.config(config);
    const nativeID = 'ses_e74ad1bd7ffeLCnD5LK1WrQd9y';
    const body = JSON.stringify({ model: 'gpt-6.1-sol', reasoning: { effort: 'medium' } });
    const signal = new AbortController().signal;
    const headerForms = [
      { 'X-Session-Id': nativeID, 'x-session-id': nativeID, Authorization: 'Bearer fixture-only', 'x-opencode-session-id': nativeID },
      [['X-Session-Id', nativeID], ['x-session-id', nativeID], ['authorization', 'Bearer fixture-only'], ['x-opencode-session-id', nativeID]],
      new Headers({ 'X-Session-Id': nativeID, authorization: 'Bearer fixture-only', 'x-opencode-session-id': nativeID }),
    ];
    for (const headers of headerForms) {
      const init = { method: 'POST', headers, body, signal, redirect: 'manual' };
      const input = new URL('http://fixture/v1/responses');
      assert.equal(await provider.options.fetch(input, init), response);
      const actual = sent.at(-1);
      assert.equal(actual.input, input);
      assert.equal(actual.init.headers.get('x-session-id'), 'existing-route');
      assert.deepEqual([...actual.init.headers.keys()].filter((key) => key === 'x-session-id'), ['x-session-id']);
      assert.equal(actual.init.headers.get('authorization'), 'Bearer fixture-only');
      assert.equal(actual.init.headers.get('x-opencode-session-id'), nativeID);
      assert.equal(actual.init.body, body);
      assert.equal(actual.init.method, 'POST');
      assert.equal(actual.init.signal, signal);
      assert.equal(actual.init.redirect, 'manual');
      assert.equal(init.headers, headers);
      assert.ok(new Headers(headers).get('x-session-id').includes(nativeID), 'caller headers were mutated');
    }
    const request = new Request('http://fixture/v1/responses', { method: 'POST', body, headers: { 'X-Session-Id': nativeID, authorization: 'Bearer from-request', 'x-input-only': 'inherited' } });
    await provider.options.fetch(request);
    assert.equal(sent.at(-1).input, request);
    assert.equal(sent.at(-1).init.headers.get('authorization'), 'Bearer from-request');
    assert.equal(sent.at(-1).init.headers.get('x-input-only'), 'inherited');
    assert.equal(request.headers.get('x-session-id'), nativeID);
    await provider.options.fetch(request, { headers: { authorization: 'Bearer explicit-override' } });
    assert.equal(sent.at(-1).init.headers.get('authorization'), 'Bearer explicit-override');
    assert.equal(sent.at(-1).init.headers.has('x-input-only'), false, 'init.headers must replace Request headers, not resurrect them');
    assert.equal(sent.at(-1).init.headers.get('x-session-id'), 'existing-route');
    assert.equal(globalThis.fetch, globalFetch);
    assert.equal(config.provider.unrelated.options.fetch, untouchedFetch);
    assert.equal(provider.options.apiKey, 'fixture-only');
    assert.equal(provider.options.baseURL, 'http://fixture/v1');
  } finally { await f.hooks.dispose(); }
});

test('missing scoped transport refuses dispatch instead of using a provider or native fallback', async () => {
  const f = await fixture({ skipConfig: true });
  try {
    await assert.rejects(f.hooks.config({ provider: {} }), /provider\/route is absent/);
    await assert.rejects(f.hooks['chat.params']({ model }, { options: {} }), /transport was not configured/);
    await assert.rejects(f.hooks.config({ provider: { [options.providerID]: { options: { fetch: 'invalid' } } } }), /not callable/);
    await assert.rejects(f.hooks['chat.params']({ model }, { options: {} }), /transport was not configured/);
  } finally { await f.hooks.dispose(); }
});

test('native user variant persists on model.variant without discarding existing native metadata', async () => {
  const f = await fixture();
  try {
    const output = { message: { agent: options.agent, model: { ...model, variant: 'high', nativeMetadata: 'retained' } } };
    await f.hooks['chat.message']({ sessionID: 'ses_native', agent: options.agent, model }, output);
    assert.deepEqual(output.message.model, { ...model, variant: 'medium', nativeMetadata: 'retained' });
    assert.equal(Object.hasOwn(output.message, 'variant'), false, 'UserMessage must not acquire unsupported top-level variant');
  } finally { await f.hooks.dispose(); }
});

test('native child and grandchild work keep the main Rex identity, mailbox and status ownership', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-lineage-'));
  const record = path.join(dir, 'record.json');
  await writeFile(record, JSON.stringify(await rexRecord()));
  const f = await fixture({ env: { CEL_SESSION_BACKEND: 'rex', CEL_REX_RECORD: record } });
  try {
    await f.hooks.event(created);
    await f.hooks['chat.message']({ sessionID: 'ses_native', agent: options.agent, model }, { message: { model } });
    const initialNotes = f.calls.filter(([, args]) => args[0] === 'sessions').length;
    f.setSession('ses_child', 'ses_native');
    f.setSession('ses_grandchild', 'ses_child');
    for (const id of ['ses_child', 'ses_grandchild']) {
      await f.hooks.event({ event: { type: 'session.created', properties: { info: { id, parentID: id === 'ses_child' ? 'ses_native' : 'ses_child' } } } });
      const output = { message: { agent: 'explore', model: { ...model, variant: 'high', inherited: true } } };
      await f.hooks['chat.message']({ sessionID: id, agent: 'explore', model }, output);
      assert.equal(output.message.model.variant, 'medium');
      assert.equal(output.message.model.inherited, true);
      await f.hooks.event({ event: { type: 'session.status', properties: { sessionID: id, status: { type: 'idle' } } } });
      await f.hooks.event({ event: { type: 'session.error', properties: { sessionID: id } } });
    }
    assert.equal(f.calls.filter(([, args]) => args[0] === 'sessions').length, initialNotes, 'Child events or prompts overwrote the main receipt');
    await f.tick();
    assert.equal(f.delivered.length, 1);
    assert.equal(f.delivered[0].path.id, 'ses_native');
    assert.equal(f.delivered[0].body.agent, options.agent);
    assert.ok(f.calls.filter(([, args]) => args[0] === 'sessions').every(([, args]) => args[4] === 'ses_native'));
  } finally { await f.hooks.dispose(); await rm(dir, { recursive: true, force: true }); }
});

test('foreign roots, unknown ancestry, cycles and changed child models are refused', async () => {
  const f = await fixture();
  try {
    await f.hooks.event(created);
    f.setSession('ses_foreign_child', 'ses_other');
    f.setSession('ses_cycle_a', 'ses_cycle_b');
    f.setSession('ses_cycle_b', 'ses_cycle_a');
    const chat = (id, requestedModel = model) => f.hooks['chat.message']({ sessionID: id, agent: 'explore', model: requestedModel }, { message: { model: requestedModel } });
    await assert.rejects(chat('ses_other'), /unrelated roots/);
    await assert.rejects(chat('ses_foreign_child'), /unrelated roots/);
    await assert.rejects(chat('ses_unknown'), /Cannot prove native child-session ancestry/);
    await assert.rejects(chat('ses_cycle_a'), /ancestry: cycle/);
    f.setSession('ses_child', 'ses_native');
    await assert.rejects(chat('ses_child', { providerID: 'openai', modelID: 'gpt-6.1-sol' }), /fallback/);
    await f.tick();
    assert.equal(f.delivered[0].path.id, 'ses_native');
  } finally { await f.hooks.dispose(); }
});

test('same-root compaction keeps native model metadata and root ownership at medium', async () => {
  const f = await fixture();
  try {
    await f.hooks.event(created);
    const output = { message: { agent: 'compaction', model: { ...model, variant: 'high', nativeMetadata: 'compaction' } } };
    await f.hooks['chat.message']({ sessionID: 'ses_native', agent: 'compaction', model }, output);
    assert.equal(output.message.agent, 'compaction');
    assert.equal(output.message.model.variant, 'medium');
    assert.equal(output.message.model.nativeMetadata, 'compaction');
    const params = { options: { reasoningEffort: 'high' } };
    await f.hooks['chat.params']({ sessionID: 'ses_native', agent: 'compaction', model }, params);
    assert.equal(params.options.reasoningEffort, 'medium');
    await f.hooks.event(state('idle'));
    await f.tick();
    assert.equal(f.delivered[0].path.id, 'ses_native');
    assert.equal(f.delivered[0].body.agent, options.agent);
  } finally { await f.hooks.dispose(); }
});

test('scoped config validation derives the complete contract from the canonical writer', () => {
  const scope = { agent: options.agent, roleFile: '/fixture/product/role-orchestrator.md', pluginFile: '/fixture/cel/tools/hooks/celestial.opencode.mjs', baseURL: 'http://127.0.0.1:8317/v1' };
  const config = buildConfig(scopedConfigInput(scope));
  const before = JSON.stringify(config);
  assert.equal(validateConfig(config, scope), true);
  assert.equal(JSON.stringify(config), before, 'read-only validation mutated configuration');
  const cases = [
    ['wrong plugin URL', (c) => { c.plugin[0][0] = 'file:///other/celestial.opencode.mjs'; }],
    ['wrong plugin role', (c) => { c.plugin[0][1].agent = 'other-role'; }],
    ['wrong plugin provider', (c) => { c.plugin[0][1].providerID = 'openai'; }],
    ['missing transport', (c) => { delete c.plugin[0][1].transport; }],
    ['wrong route reference', (c) => { c.plugin[0][1].route = '{env:OTHER_ROUTE}'; c.provider['ompgw-codex'].options.headers['x-session-id'] = '{env:OTHER_ROUTE}'; }],
    ['wrong provider', (c) => { c.provider.openai = c.provider['ompgw-codex']; delete c.provider['ompgw-codex']; }],
    ['wrong SDK', (c) => { c.provider['ompgw-codex'].npm = '@ai-sdk/openai-compatible'; }],
    ['wrong auth reference', (c) => { c.provider['ompgw-codex'].options.apiKey = 'literal-fixture-secret'; }],
    ['wrong auth environment', (c) => { c.provider['ompgw-codex'].env = ['OPENAI_API_KEY']; }],
    ['wrong gateway URL', (c) => { c.provider['ompgw-codex'].options.baseURL = 'https://other.invalid/v1'; }],
    ['wrong wire header', (c) => { c.provider['ompgw-codex'].options.headers = { 'X-Session-Id': '{env:CEL_SESSION_ID}' }; }],
    ['extra enabled provider', (c) => { c.enabled_providers.push('openai'); }],
    ['wrong model whitelist', (c) => { c.provider['ompgw-codex'].whitelist.push('gpt-6-sol'); }],
    ['wrong model', (c) => { c.model = 'ompgw-codex/gpt-6-sol'; }],
    ['wrong medium variant', (c) => { c.agent[options.agent].variant = 'high'; }],
    ['wrong model effort', (c) => { c.provider['ompgw-codex'].models['gpt-6.1-sol'].options.reasoningEffort = 'high'; }],
    ['wrong limits', (c) => { c.provider['ompgw-codex'].models['gpt-6.1-sol'].limit.context = 1000000; }],
    ['extra plugin', (c) => { c.plugin.push('unreviewed-plugin'); }],
  ];
  for (const [name, mutate] of cases) {
    const stale = JSON.parse(before);
    mutate(stale);
    assert.throws(() => validateConfig(stale, scope), /canonical role\/provider\/transport contract/, name);
  }
});

async function resumeFixture(receiptChanges = {}) {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-resume-'));
  const record = path.join(dir, 'record.json');
  await writeFile(record, JSON.stringify(await rexRecord({ agent_session: { value: 'ses_native' }, ...receiptChanges })));
  const f = await fixture({ env: { CEL_SESSION_BACKEND: 'rex', CEL_REX_RECORD: record, CEL_AGENT_NAME: 'fixture-opencode-orch' } });
  return { ...f, record, cleanup: async () => { await f.hooks.dispose(); await rm(dir, { recursive: true, force: true }); } };
}

test('owned native resume wakes idle mail before any chat or session.created event', async () => {
  const f = await resumeFixture();
  try {
    await f.hooks.event({ event: { type: 'session.created', properties: { info: nativeInfo('ses_other') } } });
    await f.tick();
    assert.equal(f.delivered.length, 1);
    assert.equal(f.delivered[0].path.id, 'ses_native');
    assert.match(f.delivered[0].body.parts[0].text, /\[mail-1\]/);
    const notes = f.calls.filter(([, args]) => args[0] === 'sessions').map(([, args]) => args);
    assert.ok(notes.some((args) => args[3] === 'idle' && args[4] === 'ses_native'));
    assert.ok(notes.every((args) => args[4] === 'ses_native'));
  } finally { await f.cleanup(); }
});

test('owned resume observes native busy then idle without draining mail during busy', async () => {
  const f = await resumeFixture();
  try {
    f.setStatus({ ses_native: { type: 'busy' } });
    await f.tick();
    assert.equal(f.delivered.length, 0);
    assert.ok(!f.calls.some(([, args]) => args[0] === 'inbox' && args[1] === 'read'));
    f.setStatus({});
    await f.tick();
    assert.equal(f.delivered[0].path.id, 'ses_native');
    const notes = f.calls.filter(([, args]) => args[0] === 'sessions').map(([, args]) => args[3]);
    assert.equal(notes[0], 'working');
    assert.ok(notes.includes('idle'));
  } finally { await f.cleanup(); }
});

test('pending resume lookup is single-flight and foreign creation cannot win ownership', async () => {
  const f = await resumeFixture();
  let release;
  try {
    let entered, lookups = 0;
    const querying = new Promise((resolve) => { entered = resolve; });
    f.client.session.get = async () => { lookups++; entered(); return new Promise((resolve) => { release = resolve; }); };
    const polling = f.tick();
    await querying;
    await f.hooks.event({ event: { type: 'session.created', properties: { info: nativeInfo('ses_other') } } });
    const secondPoll = f.tick();
    assert.equal(lookups, 1);
    release({ data: nativeInfo('ses_native') });
    await Promise.all([polling, secondPoll]);
    assert.equal(f.delivered[0].path.id, 'ses_native');
    assert.ok(f.calls.filter(([, args]) => args[0] === 'sessions').every(([, args]) => args[4] === 'ses_native'));
  } finally { release?.({ data: nativeInfo('ses_native') }); await f.cleanup(); }
});

test('unowned or non-native resume receipts refuse rather than adopting a new root', async () => {
  for (const changes of [
    { agent: 'pi' }, { backend: 'herdr' }, { name: 'another-agent' }, { cwd: '/foreign/product' },
    { pid_start: '0' }, { pid: 2147483647 },
    { agent_session: { value: '/tmp/omp-session.jsonl' } },
    { agent_session: { value: '12345678-1234-1234-1234-123456789abc' } },
  ]) {
    const f = await resumeFixture(changes);
    try {
      await f.hooks.event({ event: { type: 'session.created', properties: { info: nativeInfo('ses_other') } } });
      await f.tick();
      await assert.rejects(f.hooks['chat.message']({ sessionID: 'ses_other', agent: options.agent, model }, { message: { model } }), /native resume refused/);
      assert.equal(f.delivered.length, 0);
      assert.ok(!f.calls.some(([, args]) => args[0] === 'inbox' && args[1] === 'read'));
    } finally { await f.cleanup(); }
  }
});

test('native resume candidate must resolve to the same-directory same-model root', async () => {
  for (const replacement of [
    { data: nativeInfo('ses_other') }, { error: new Error('missing native session') },
    { data: nativeInfo('ses_native', 'ses_other') },
    { data: { ...nativeInfo('ses_native'), directory: '/foreign/product' } },
    { data: { ...nativeInfo('ses_native'), model: { providerID: 'openai', id: 'gpt-6.1-sol' } } },
  ]) {
    const f = await resumeFixture();
    try {
      f.client.session.get = async () => replacement;
      await f.tick();
      await f.hooks.event({ event: { type: 'session.created', properties: { info: nativeInfo('ses_other') } } });
      await assert.rejects(f.hooks['chat.params']({ model }, { options: {} }), /native resume refused/);
      assert.equal(f.delivered.length, 0);
      assert.ok(!f.calls.some(([, args]) => args[0] === 'inbox' && args[1] === 'read'));
      assert.ok(f.calls.filter(([, args]) => args[0] === 'sessions').every(([, args]) => args[3] === 'blocked' && args[4] === ''));
      assert.equal(JSON.parse(await readFile(f.record, 'utf8')).agent_session.value, 'ses_native');
    } finally { await f.cleanup(); }
  }
});
