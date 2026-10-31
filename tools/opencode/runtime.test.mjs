import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, writeFile, readFile, rm, chmod, symlink, link } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';
import plugin from './plugin/index.mjs';
import { createPlugin } from './runtime.mjs';

const execute = promisify(execFile);
const repo = fileURLToPath(new URL('../../', import.meta.url));
const options = { agent: 'cel-orchestrator', providerID: 'ompgw-codex', modelID: 'gpt-6.1-sol', transport: 'gateway', route: 'existing-route' };
const model = { providerID: options.providerID, id: options.modelID, variant: 'medium' };
const location = { directory: '/fixture/product', project: { id: 'fixture', directory: '/fixture/product', canonical: '/fixture/product' } };
const admission = (changes = {}) => ({ directory: location.directory, agent: options.agent, model: { ...model }, ...changes });
const nativeInfo = (id = 'ses_native', parentID, changes = {}) => ({
  id, parentID, agent: parentID ? 'explore' : options.agent, model: { ...model },
  location: { directory: location.directory }, time: { created: 1, updated: 20, busy: 10, idle: 20 }, ...changes,
});
// Native schema/event.ts envelopes carry data, never the removed v1 properties.
const created = (native = nativeInfo()) => ({ id: 'evt_created', created: 1, type: 'session.created',
  durable: { aggregateID: native.id, seq: 0, version: 1 }, data: {
    sessionID: native.id, projectID: location.project.id, location: native.location, parentID: native.parentID,
    agent: native.agent, model: native.model, slug: 'fixture', version: '2.2.5',
  } });
const status = (type, sessionID = 'ses_native') => ({ id: 'evt_status', created: 2, type: 'session.status', data: { sessionID, status: { type } } });
const request = (changes = {}) => ({ sessionID: 'ses_native', agent: options.agent, model: { ...model }, kind: 'primary', ...changes });

async function rexRecord(overrides = {}) {
  const stat = await readFile(`/proc/${process.pid}/stat`, 'utf8');
  return { name: 'fixture-opencode-orch', agent: 'opencode', backend: 'rex', cwd: location.directory,
    pid: process.pid, pid_start: stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[19], ...overrides };
}
function eventStream() {
  let waiting, previous, ended = false;
  const queued = [];
  return {
    push(value) {
      return new Promise((ack) => {
        if (ended) { ack(); return; }
        if (waiting) { const resolve = waiting; waiting = undefined; previous = ack; resolve({ value, done: false }); }
        else queued.push({ value, ack });
      });
    },
    subscribe({ signal }) {
      function close() {
        ended = true;
        previous?.(); previous = undefined;
        for (const item of queued.splice(0)) item.ack();
        waiting?.({ done: true }); waiting = undefined;
      }
      signal.addEventListener('abort', close, { once: true });
      return { [Symbol.asyncIterator]() { return {
        next() {
          previous?.(); previous = undefined;
          if (ended) return Promise.resolve({ done: true });
          const item = queued.shift();
          if (item) { previous = item.ack; return Promise.resolve({ value: item.value, done: false }); }
          return new Promise((resolve) => { waiting = resolve; });
        },
        async return() { close(); return { done: true }; },
      }; } };
    },
    ended: () => ended,
  };
}
async function fixture(overrides = {}) {
  let tick, stopped = false, count = 1, fail = false, disposed = 0, waitCalls = 0, reloads = 0;
  const calls = [], delivered = [], gets = [], hooks = { session: new Map(), tool: new Map(), shell: new Map() };
  const transforms = {}, stream = eventStream();
  const lineage = new Map([['ses_native', nativeInfo()], ['ses_other', nativeInfo('ses_other')]]);
  const registration = () => ({ async dispose() { disposed++; } });
  const register = (domain) => async (name, callback, scope) => {
    hooks[domain].set(name, { callback, scope });
    return { async dispose() { hooks[domain].delete(name); disposed++; } };
  };
  const context = {
    options: { ...options, ...overrides.options }, location: overrides.location ?? location,
    provider: { async transform(callback) { transforms.provider = callback; return registration(); }, async reload() { reloads++; } },
    model: { async transform(callback) { transforms.model = callback; return registration(); }, async reload() { reloads++; } },
    session: {
      hook: register('session'),
      async get({ sessionID }) {
        gets.push(sessionID);
        if (!lineage.has(sessionID)) throw new Error('Native session not found');
        return structuredClone(lineage.get(sessionID));
      },
      async synthetic(input) {
        delivered.push(input);
        if (fail) throw new Error('Native admission refused');
        return { id: `msg_${delivered.length}`, sessionID: input.sessionID, type: 'synthetic', delivery: input.delivery };
      },
      async wait() { waitCalls++; throw new Error('Never wait in an idle hook or observer'); },
    },
    tool: { hook: register('tool') }, shell: { hook: register('shell') }, event: { subscribe: stream.subscribe },
  };
  const env = { CEL_ROOT: '/fixture/cel', CEL_INBOX_ME: 'widget-orch', CEL_INBOX_WS: 'sandbox',
    OMP_GATEWAY_TOKEN: 'fixture-only', GH_TOKEN: 'fixture-github', ...overrides.env };
  const cleanup = await createPlugin(context, {
    env, clock: { setInterval(fn) { tick = fn; return { unref() {} }; }, clearInterval() { stopped = true; } },
    run: async (bin, args) => {
      calls.push([bin, args]);
      if (args[0] === 'inbox' && args[1] === 'count') return String(count);
      if (args[0] === 'inbox' && args[1] === 'read') { count = 0; return '[sandbox] {"id":"mail-1","from":"root","kind":"status","message":"native delivery"}\n'; }
      if (bin === 'bash') return args.at(-1).includes('forbidden') ? 'deny protected repository' : 'allow';
      return '';
    }, ...overrides.deps,
  });
  return {
    context, cleanup, env, calls, delivered, gets, hooks, transforms, lineage,
    emit: (event) => stream.push(event), tick: () => tick(), setCount(value) { count = value; }, setFail(value) { fail = value; },
    hook: (name, event) => hooks.session.get(name).callback(event),
    tool: (tool, input, sessionID = 'ses_native') => hooks.tool.get('execute.before').callback({ tool, input, sessionID, agent: options.agent, messageID: 'msg_tool', id: 'call_tool' }),
    shell: (command) => hooks.shell.get('create.before').callback({ command, cwd: '/another/workdir', timeout: 0, shell: '/bin/bash', env: {} }),
    stopped: () => stopped, disposed: () => disposed, streamEnded: stream.ended, waits: () => waitCalls, reloads: () => reloads,
  };
}
function providerEditor() {
  const providers = new Map(['ompgw-codex', 'openai', 'anthropic'].map((id) => [id, { provider: { id }, models: new Map() }]));
  return { list: () => [...providers.values()], get: (id) => providers.get(id), remove: (id) => providers.delete(id), providers };
}
function modelEditor() {
  const models = new Map([
    ['ompgw-codex/gpt-6.1-sol', { ...model, settings: { reasoningEffort: 'high', unrelated: true }, enabled: true,
      variants: [{ id: 'high', settings: { reasoningEffort: 'high' } }, { id: 'medium', settings: { unrelated: true } }] }],
    ['ompgw-codex/gpt-other', { id: 'gpt-other', providerID: 'ompgw-codex', variants: [] }],
    ['openai/gpt-6.1-sol', { id: model.id, providerID: 'openai', variants: [] }],
  ]);
  let selected;
  return { list: () => [...models.values()], get: (p, m) => models.get(`${p}/${m}`), remove: (p, m) => models.delete(`${p}/${m}`),
    update: (p, m, change) => change(models.get(`${p}/${m}`)), default: { set: (p, m) => { selected = `${p}/${m}`; } }, models, selected: () => selected };
}
async function resumeFixture(changes = {}, overrides = {}) {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-resume-'));
  const record = path.join(dir, 'record.json');
  await writeFile(record, JSON.stringify(await rexRecord({ agent_session: { value: 'ses_native' }, ...changes })));
  const f = await fixture({ ...overrides, env: { CEL_SESSION_BACKEND: 'rex', CEL_REX_RECORD: record, CEL_AGENT_NAME: 'fixture-opencode-orch', ...overrides.env } });
  return { ...f, record, cleanup: async () => { await f.cleanup(); await rm(dir, { recursive: true, force: true }); } };
}

test('entrypoint is the v2 definition and setup registers native domains without session calls', async () => {
  assert.equal(plugin.id, 'celestial');
  assert.equal(typeof plugin.setup, 'function');
  const f = await fixture();
  try {
    assert.equal(typeof f.cleanup, 'function');
    assert.deepEqual(f.gets, []);
    assert.deepEqual([...f.hooks.session.keys()], ['context', 'compaction', 'generate', 'title', 'model.request', 'http.request', 'experimental.ws.handshake', 'experimental.idle']);
    assert.deepEqual([...f.hooks.tool.keys()], ['execute.before']);
    assert.deepEqual([...f.hooks.shell.keys()], ['create.before']);
    assert.equal(f.waits(), 0);
    assert.equal(f.env.GH_TOKEN, 'fixture-github');
  } finally { await f.cleanup(); }
  assert.equal(f.stopped(), true);
  assert.equal(f.streamEnded(), true);
  assert.equal(f.disposed(), 12);
});

test('native availability removes unrelated providers/models and pins Sol base plus medium variant', async () => {
  const f = await fixture();
  try {
    const providers = providerEditor(), models = modelEditor();
    f.transforms.provider(providers); f.transforms.model(models);
    assert.deepEqual([...providers.providers.keys()], ['ompgw-codex']);
    assert.deepEqual([...models.models.keys()], ['ompgw-codex/gpt-6.1-sol']);
    const sol = models.get(model.providerID, model.id);
    assert.deepEqual(sol.settings, { reasoningEffort: 'medium', unrelated: true });
    assert.deepEqual(sol.variants, [{ id: 'medium', settings: { unrelated: true, reasoningEffort: 'medium' } }]);
    assert.equal(models.selected(), 'ompgw-codex/gpt-6.1-sol');
  } finally { await f.cleanup(); }
});

test('missing gateway token or route removes even the exact provider and model before requests', async () => {
  for (const overrides of [{ env: { OMP_GATEWAY_TOKEN: '' } }, { env: { OMP_GATEWAY_TOKEN: '  ' } }, { options: { route: '' } }]) {
    const f = await fixture(overrides);
    try {
      const providers = providerEditor(), models = modelEditor();
      f.transforms.provider(providers); f.transforms.model(models);
      assert.equal(providers.providers.size, 0); assert.equal(models.models.size, 0); assert.equal(models.selected(), undefined);
      await f.emit(created());
      await assert.rejects(f.hook('model.request', request({ headers: {} })), /auth\/route/);
      await f.tick();
      assert.equal(f.delivered.length, 0);
      assert.ok(!f.calls.some(([, args]) => args[0] === 'inbox'));
    } finally { await f.cleanup(); }
  }
});

test('all primary and auxiliary requests keep exact Sol and medium without rewriting native identity', async () => {
  const f = await fixture();
  try {
    await f.emit(created());
    for (const name of ['context', 'compaction', 'generate', 'title']) {
      const event = request({ options: { reasoningEffort: 'high', unrelated: true }, system: [], messages: [] });
      await f.hook(name, event);
      assert.deepEqual(event.options, { reasoningEffort: 'medium', unrelated: true });
      assert.deepEqual(event.model, model);
      for (const bad of [{ ...model, providerID: 'openai' }, { ...model, id: 'other' }, { ...model, variant: 'high' }]) {
        await assert.rejects(f.hook(name, request({ model: bad, options: {} })), /fallback/);
      }
    }
    const noVariant = request({ model: { id: model.id, providerID: model.providerID }, options: {} });
    await f.hook('title', noVariant);
    assert.equal(noVariant.options.reasoningEffort, 'medium', 'base settings cover native no-variant auxiliary requests');
  } finally { await f.cleanup(); }
});

test('HTTP and WS affinity are pinned at native final boundaries without changing authorization/body/global fetch', async () => {
  const f = await fixture(), originalFetch = globalThis.fetch;
  try {
    await f.emit(created());
    for (const name of ['model.request', 'experimental.ws.handshake']) {
      const event = request({ headers: { 'X-Session-Id': 'native-alias', 'x-session-id': 'native-value', Authorization: 'fixture-auth' }, url: 'ws://fixture/v1/responses' });
      await f.hook(name, event);
      assert.deepEqual(event.headers, { Authorization: 'fixture-auth', 'x-session-id': options.route });
      assert.deepEqual(f.hooks.session.get(name).scope, { providerID: model.providerID });
    }
    const body = JSON.stringify({ model: model.id, reasoning: { effort: 'medium' }, input: [] });
    const event = request({ request: new Request('http://fixture/v1/responses', { method: 'POST', body,
      headers: { 'X-Session-Id': 'ses_native', authorization: 'fixture-auth', 'content-type': 'application/json' } }) });
    await f.hook('http.request', event);
    assert.equal(event.request.headers.get('x-session-id'), options.route);
    assert.equal(event.request.headers.get('authorization'), 'fixture-auth');
    assert.equal(await event.request.text(), body);
    assert.equal(globalThis.fetch, originalFetch);
    for (const name of ['model.request', 'http.request', 'experimental.ws.handshake']) {
      await assert.rejects(f.hook(name, request({ model: { ...model, variant: 'low' } })), /fallback/);
    }
  } finally { await f.cleanup(); }
});

test('fresh root requires exact agent, model, medium and location, not first idle or first request', async () => {
  const f = await fixture();
  try {
    await f.emit(status('idle', 'ses_other'));
    await f.hook('experimental.idle', { sessionID: 'ses_other', background: [] });
    await assert.rejects(f.hook('context', request({ options: {} })), /not bound/);
    await f.emit(created());
    await f.emit(created(nativeInfo('ses_other')));
    await assert.rejects(f.hook('context', request({ sessionID: 'ses_other', options: {} })), /unrelated roots/);
    await f.hook('context', request({ options: {} }));
  } finally { await f.cleanup(); }
  for (const changes of [{ agent: 'foreign' }, { parentID: undefined, model: undefined }, { model: { ...model, variant: 'high' } },
    { location: { directory: '/foreign' } }, { location: { directory: location.directory, workspaceID: 'foreign' } }]) {
    const bad = await fixture();
    try {
      await bad.emit(created(nativeInfo('ses_native', undefined, changes)));
      await bad.emit(created());
      await assert.rejects(bad.hook('context', request({ options: {} })), /refused|role|location|fallback/);
      await bad.tick();
      assert.equal(bad.delivered.length, 0);
    } finally { await bad.cleanup(); }
  }
});

test('child and grandchild tools/model work keep the same root mailbox and never rebind from child idle', async () => {
  const f = await resumeFixture();
  try {
    await f.tick();
    f.lineage.set('ses_child', nativeInfo('ses_child', 'ses_native'));
    f.lineage.set('ses_grandchild', nativeInfo('ses_grandchild', 'ses_child'));
    const initialNotes = f.calls.filter(([, args]) => args[0] === 'sessions').length;
    for (const id of ['ses_child', 'ses_grandchild']) {
      await f.emit(created(f.lineage.get(id)));
      await f.hook('context', request({ sessionID: id, agent: 'explore', options: {} }));
      await f.tool('write', { path: 'allowed' }, id);
      await f.hook('experimental.idle', { sessionID: id, background: [] });
      await f.emit(status('idle', id));
    }
    assert.equal(f.calls.filter(([, args]) => args[0] === 'sessions').length, initialNotes);
    assert.ok(f.calls.filter(([, args]) => args[0] === 'sessions').every(([, args]) => args[4] === 'ses_native'));
    assert.equal(f.delivered.length, 1);
    assert.equal(f.delivered[0].sessionID, 'ses_native');
  } finally { await f.cleanup(); }
});

test('unknown ancestry, cycles, foreign roots/locations and changed child variants refuse even guarded tools', async () => {
  const f = await fixture();
  try {
    await f.emit(created());
    f.lineage.set('ses_foreign', nativeInfo('ses_foreign', 'ses_other'));
    f.lineage.set('ses_cycleA', nativeInfo('ses_cycleA', 'ses_cycleB'));
    f.lineage.set('ses_cycleB', nativeInfo('ses_cycleB', 'ses_cycleA'));
    f.lineage.set('ses_wrong', nativeInfo('ses_wrong', 'ses_native', { model: { ...model, variant: 'high' } }));
    f.lineage.set('ses_away', nativeInfo('ses_away', 'ses_native', { location: { directory: '/foreign' } }));
    for (const id of ['ses_unknown', 'ses_other', 'ses_foreign', 'ses_cycleA', 'ses_wrong', 'ses_away']) {
      await assert.rejects(f.hook('context', request({ sessionID: id, options: {} })), /ancestry|unrelated roots|fallback|location/);
      await assert.rejects(f.tool('write', { path: 'allowed' }, id), /ancestry|unrelated roots|fallback|location/);
    }
    assert.ok(!f.calls.some(([bin]) => bin === 'bash'), 'unproven lineage reached mutation guard');
  } finally { await f.cleanup(); }
});

test('v2 shell/write/edit/patch inputs reach the real shared guard, including relative paths and move sources/destinations', async () => {
  const temp = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-guard-'));
  const consoleDir = path.join(temp, 'console');
  const env = { ...process.env, CEL_ROOT: repo, CEL_ROLE: 'console', CEL_CONSOLE_DIR: consoleDir };
  const guarded = [];
  const f = await fixture({ env: { CEL_ROOT: repo }, deps: { run: async (bin, args) => {
    assert.equal(bin, 'bash'); guarded.push(args);
    return (await execute(bin, args, { env })).stdout;
  } } });
  try {
    await f.emit(created());
    for (const tool of ['write', 'edit']) await assert.rejects(f.tool(tool, { path: 'repos/protected/marker' }), /celestial guard/);
    await assert.rejects(f.tool('shell', { command: `touch ${temp}/marker`, workdir: consoleDir }), /celestial guard/);
    await assert.rejects(f.shell(`touch ${temp}/marker`), /celestial guard/);
    await f.tool('shell', { command: `CEL_GUARD_ALLOW_ONCE=1 touch ${temp}/marker` });
    await assert.rejects(f.tool('shell', { command: `CEL_GUARD_ALLOW_ONCE=11 touch ${temp}/marker` }), /celestial guard/);
    for (const operation of ['Add File', 'Delete File', 'Update File']) {
      await assert.rejects(f.tool('patch', { patchText: `*** Begin Patch\n  *** ${operation}: repos/protected/marker\n*** End Patch` }), /celestial guard/);
    }
    await assert.rejects(f.tool('patch', { patchText: `*** Begin Patch\n*** Update File: ${consoleDir}/allowed\n*** Move to: repos/protected/marker\n@@\n-old\n+new\n*** End Patch` }), /celestial guard/);
    await assert.rejects(f.tool('patch', { patchText: `*** Begin Patch\n*** Update File: repos/protected/marker\n*** Move to: ${consoleDir}/allowed\n@@\n-old\n+new\n*** End Patch` }), /celestial guard/);
    await assert.rejects(f.tool('patch', { patchText: 'unclassified' }), /cannot classify/);
    await assert.rejects(f.tool('write', { filePath: 'legacy-v1-field' }), /cannot classify/);
    await f.tool('write', { path: `${consoleDir}/allowed`, content: 'allowed' });
    assert.ok(guarded.some((args) => args.at(-1) === '/fixture/product/repos/protected/marker'));
  } finally { await f.cleanup(); await rm(temp, { recursive: true, force: true }); }
});

test('recurring observer delivers already-idle later mail and retains failed admission debt without re-reading', async () => {
  const f = await fixture();
  try {
    await f.emit(created());
    f.setCount(0); await f.tick();
    assert.equal(f.delivered.length, 0);
    f.setCount(2); f.setFail(true); await f.tick();
    assert.equal(f.delivered.length, 1);
    f.setFail(false); await Promise.all([f.tick(), f.tick()]);
    assert.equal(f.delivered.length, 2);
    assert.equal(f.delivered[1].delivery, 'steer');
    assert.match(f.delivered[1].text, /\[mail-1\] \[sandbox\].*native delivery/);
    assert.equal(f.calls.filter(([, args]) => args[0] === 'inbox' && args[1] === 'read').length, 1);
    f.setCount(1);
    await f.tick();
    assert.equal(f.delivered.length, 2, 'accepted synthetic work must not be overridden by stale persisted idle');
    await f.emit(status('idle'));
    await f.tick();
    assert.equal(f.delivered.length, 3);
    assert.equal(f.waits(), 0);
    assert.ok(f.calls.every(([, args]) => !args.includes('prompt') && !args.includes('send-text')));
  } finally { await f.cleanup(); }
});

test('native idle hook admits steer in the current execution, never waits and never adopts other roots', async () => {
  const f = await fixture();
  try {
    await f.emit(created());
    await f.emit(status('busy'));
    await f.hook('experimental.idle', { sessionID: 'ses_other', background: [] });
    assert.equal(f.delivered.length, 0);
    await f.hook('experimental.idle', { sessionID: 'ses_native', background: [] });
    assert.equal(f.delivered.length, 1);
    assert.equal(f.delivered[0].sessionID, 'ses_native');
    assert.equal(f.waits(), 0);
  } finally { await f.cleanup(); }
});

test('missing or unencoded idle timestamps and native busy state never count as idle', async () => {
  const f = await fixture();
  try {
    await f.emit(created());
    for (const time of [{}, { busy: 30, idle: 20 }, { busy: 10, idle: '20' }, { busy: 10, idle: { epochMillis: 20 } }, { busy: '10', idle: 20 }]) {
      f.lineage.set('ses_native', nativeInfo('ses_native', undefined, { time }));
      await f.tick();
    }
    assert.equal(f.delivered.length, 0);
    assert.ok(!f.calls.some(([, args]) => args[0] === 'inbox'));
    f.lineage.set('ses_native', nativeInfo());
    await f.emit(status('busy'));
    await f.tick();
    assert.equal(f.delivered.length, 0, 'persisted idle cannot override a known busy event');
    await f.emit(status('idle')); await f.tick();
    assert.equal(f.delivered.length, 1);
  } finally { await f.cleanup(); }
});

test('busy events during awaited native idle observations fence stale responses', async () => {
  const f = await fixture();
  let release;
  try {
    await f.emit(created());
    let entered;
    const querying = new Promise((resolve) => { entered = resolve; });
    f.context.session.get = () => new Promise((resolve) => { release = resolve; entered(); });
    const polling = f.tick(); await querying;
    await f.emit(status('busy'));
    release(nativeInfo()); await polling;
    assert.equal(f.delivered.length, 0);
    assert.ok(!f.calls.some(([, args]) => args[0] === 'inbox'));
  } finally { release?.(nativeInfo()); await f.cleanup(); }
});

test('owned receipt restores completed-idle mail after setup without any new session event', async () => {
  const f = await resumeFixture();
  try {
    const pendingProviders = providerEditor(); f.transforms.provider(pendingProviders);
    assert.equal(pendingProviders.providers.size, 0, 'unverified resume exposed the gateway provider');
    assert.equal(f.reloads(), 0);
    assert.equal(f.gets.length, 0, 'setup reentered the native session store');
    await f.emit(created(nativeInfo('ses_other')));
    await f.tick();
    assert.equal(f.reloads(), 2);
    const verifiedProviders = providerEditor(); f.transforms.provider(verifiedProviders);
    assert.deepEqual([...verifiedProviders.providers.keys()], ['ompgw-codex']);
    assert.equal(f.delivered.length, 1);
    assert.equal(f.delivered[0].sessionID, 'ses_native');
    assert.ok(f.calls.filter(([, args]) => args[0] === 'sessions').every(([, args]) => args[4] === 'ses_native'));
    assert.equal(JSON.parse(await readFile(f.record, 'utf8')).agent_session.value, 'ses_native');
  } finally { await f.cleanup(); }
});

test('resume boot observes explicit busy then completed idle and rejects missing or changed native candidates', async () => {
  const f = await resumeFixture();
  try {
    f.lineage.set('ses_native', nativeInfo('ses_native', undefined, { time: { created: 1, busy: 30, idle: 20 } }));
    await f.tick(); assert.equal(f.delivered.length, 0);
    f.lineage.set('ses_native', nativeInfo());
    await f.tick(); assert.equal(f.delivered.length, 1);
  } finally { await f.cleanup(); }
  for (const replacement of [null, nativeInfo('ses_other'), nativeInfo('ses_native', 'ses_other'),
    nativeInfo('ses_native', undefined, { location: { directory: '/foreign' } }), nativeInfo('ses_native', undefined, { agent: 'foreign' }),
    nativeInfo('ses_native', undefined, { model: undefined }), nativeInfo('ses_native', undefined, { model: { ...model, variant: 'high' } })]) {
    const bad = await resumeFixture();
    try {
      if (replacement) bad.lineage.set('ses_native', replacement); else bad.lineage.delete('ses_native');
      await bad.tick(); await bad.emit(created(nativeInfo('ses_other')));
      await assert.rejects(bad.hook('context', request({ options: {} })), /native resume refused/);
      assert.equal(bad.delivered.length, 0);
      assert.ok(!bad.calls.some(([, args]) => args[0] === 'inbox'));
      const providers = providerEditor(); bad.transforms.provider(providers); assert.equal(providers.providers.size, 0);
    } finally { await bad.cleanup(); }
  }
});

test('PID birth, reporter ancestry, role/cwd and native receipt identity remain mandatory', async () => {
  for (const changes of [{ agent: 'pi' }, { backend: 'herdr' }, { name: 'foreign' }, { cwd: '/foreign' },
    { pid_start: '0' }, { pid: 2147483647 }, { agent_session: { value: '/tmp/omp.jsonl' } },
    { agent_session: { value: '12345678-1234-1234-1234-123456789abc' } }]) {
    const f = await resumeFixture(changes);
    try {
      await f.emit(created()); await f.tick();
      await assert.rejects(f.hook('context', request({ options: {} })), /native resume refused|auth\/route/);
      assert.equal(f.delivered.length, 0);
      assert.ok(!f.calls.some(([, args]) => args[0] === 'inbox'));
    } finally { await f.cleanup(); }
  }
  const stat = await readFile(`/proc/${process.ppid}/stat`, 'utf8');
  const f = await resumeFixture({ pid: process.ppid, pid_start: stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[19] });
  try {
    await f.tick();
    assert.equal(f.delivered.length, 1, 'proven server ancestor was refused');
    assert.ok(f.calls.filter(([, args]) => args[0] === 'sessions').every(([, args]) => args[2] === String(process.ppid)));
  } finally { await f.cleanup(); }
});

test('cleanup cancels event subscription, joins accepted reporters and prevents later writes', async () => {
  const f = await resumeFixture();
  let release, entered;
  const held = new Promise((resolve) => { release = resolve; });
  const reporting = new Promise((resolve) => { entered = resolve; });
  // Replace the reporter via a fresh fixture while retaining a valid receipt.
  const g = await fixture({ env: { CEL_SESSION_BACKEND: 'rex', CEL_REX_RECORD: f.record }, deps: {
    run: async () => { entered(); await held; return ''; },
  } });
  try {
    const polling = g.tick(); await reporting;
    let closed = false;
    const closing = g.cleanup().then(() => { closed = true; });
    await Promise.resolve(); assert.equal(closed, false);
    release(); await Promise.all([polling, closing]);
    await g.emit(status('busy')); await g.tick();
    assert.equal(g.delivered.length, 0);
    assert.equal(g.streamEnded(), true);
    assert.equal(g.stopped(), true);
  } finally { release(); await g.cleanup(); await f.cleanup(); }
});

test('cleanup joins in-flight native reads without waiting on its own idle execution', async () => {
  const f = await fixture();
  let release;
  try {
    await f.emit(created());
    let entered;
    const querying = new Promise((resolve) => { entered = resolve; });
    f.context.session.get = () => new Promise((resolve) => { release = resolve; entered(); });
    const polling = f.tick(); await querying;
    let closed = false;
    const closing = f.cleanup().then(() => { closed = true; });
    await Promise.resolve(); assert.equal(closed, false);
    release(nativeInfo()); await Promise.all([polling, closing]);
    assert.equal(f.delivered.length, 0);
    assert.ok(!f.calls.some(([, args]) => args[0] === 'inbox'));
    assert.equal(f.waits(), 0);
  } finally { release?.(nativeInfo()); await f.cleanup(); }
});

test('pending resume lookup is single-flight and cannot be displaced by a foreign creation', async () => {
  const f = await resumeFixture();
  let release;
  try {
    let entered, lookups = 0;
    const querying = new Promise((resolve) => { entered = resolve; });
    f.context.session.get = async () => {
      lookups++;
      if (lookups === 1) { entered(); return new Promise((resolve) => { release = resolve; }); }
      return nativeInfo();
    };
    const polling = f.tick(); await querying;
    const second = f.tick();
    const requesting = f.hook('context', request({ options: {} }));
    await f.emit(created(nativeInfo('ses_other')));
    assert.equal(lookups, 1);
    const providers = providerEditor(); f.transforms.provider(providers);
    assert.equal(providers.providers.size, 0);
    release(nativeInfo());
    await Promise.all([polling, second, requesting]);
    assert.equal(f.reloads(), 2);
    assert.equal(f.delivered.length, 1);
    assert.equal(f.delivered[0].sessionID, 'ses_native');
  } finally { release?.(nativeInfo()); await f.cleanup(); }
});

test('busy transition after inbox drain preserves exact raw debt for a later idle without re-reading', async () => {
  let f, reads = 0;
  const raw = '[sandbox] {"id":"mail-good","kind":"status","from":"root","message":"keep me"}\nmalformed {record\n';
  f = await fixture({ deps: { run: async (_bin, args) => {
    if (args[0] === 'inbox' && args[1] === 'count') return '1';
    if (args[0] === 'inbox' && args[1] === 'read') { reads++; await f.emit(status('busy')); return raw; }
    return '';
  } } });
  try {
    await f.emit(created()); await f.tick();
    assert.equal(f.delivered.length, 0);
    assert.equal(reads, 1);
    await f.emit(status('idle')); await f.tick();
    assert.equal(f.delivered.length, 1);
    assert.match(f.delivered[0].text, /keep me/);
    assert.match(f.delivered[0].text, /malformed \{record/);
    assert.equal(reads, 1);
  } finally { await f.cleanup(); }
});

test('cleanup joins an in-flight idle-hook synthetic admission and shares one closing promise', async () => {
  const f = await fixture();
  let release, entered;
  const held = new Promise((resolve) => { release = resolve; });
  const admitting = new Promise((resolve) => { entered = resolve; });
  f.context.session.synthetic = async (input) => {
    f.delivered.push(input); entered(); await held;
    return { id: 'msg_accepted', sessionID: input.sessionID, type: 'synthetic' };
  };
  try {
    await f.emit(created());
    const idle = f.hook('experimental.idle', { sessionID: 'ses_native', background: [] });
    await admitting;
    const closing = f.cleanup();
    assert.equal(f.cleanup(), closing);
    let closed = false; closing.then(() => { closed = true; });
    await Promise.resolve(); assert.equal(closed, false);
    release(); await Promise.all([idle, closing]);
    assert.equal(closed, true);
    assert.equal(f.delivered.length, 1);
    assert.equal(f.waits(), 0);
  } finally { release(); await f.cleanup(); }
});

test('canonical launch marker holds native bootstrap, provider availability, inbox and mutation sinks', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-admission-'));
  const marker = path.join(dir, 'admission');
  const f = await resumeFixture({}, { env: { CEL_OPENCODE_ADMISSION_FILE: marker } });
  try {
    await f.tick();
    assert.deepEqual(f.gets, []);
    assert.equal(f.reloads(), 0);
    assert.equal(f.delivered.length, 0);
    assert.ok(!f.calls.some(([, args]) => args[0] === 'inbox'));
    const providers = providerEditor(), models = modelEditor();
    f.transforms.provider(providers); f.transforms.model(models);
    assert.equal(providers.providers.size, 0); assert.equal(models.models.size, 0);
    await assert.rejects(f.hook('context', request({ options: {} })), /launch admission is pending/);
    await assert.rejects(f.tool('write', { path: 'allowed' }), /launch admission is pending/);
    await assert.rejects(f.shell('printf allowed'), /launch admission is pending/);
    await writeFile(marker, 'not admitted\n', { mode: 0o600 }); await f.tick();
    assert.deepEqual(f.gets, []);
    await writeFile(marker, JSON.stringify(admission({ sessionID: 'ses_native' }))); await f.tick();
    assert.equal(f.reloads(), 4, 'launch gate and exact resume proof each rebuild scoped availability');
    assert.equal(f.delivered.length, 1);
    assert.equal(f.delivered[0].sessionID, 'ses_native');
    const ready = providerEditor(); f.transforms.provider(ready);
    assert.deepEqual([...ready.providers.keys()], ['ompgw-codex']);
  } finally { await f.cleanup(); await rm(dir, { recursive: true, force: true }); }
});

test('private Herdr handoff restores an existing root without created events or first-request adoption', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-herdr-'));
  const marker = path.join(dir, 'admission');
  const f = await fixture({ env: { CEL_SESSION_BACKEND: 'herdr', CEL_OPENCODE_ADMISSION_FILE: marker } });
  try {
    await f.tick(); assert.deepEqual(f.gets, []);
    await assert.rejects(f.hook('context', request({ options: {} })), /auth\/route/);
    await writeFile(marker, JSON.stringify(admission({ sessionID: 'ses_native' })), { mode: 0o600 });
    await f.tick();
    assert.equal(f.delivered.length, 1);
    assert.equal(f.delivered[0].sessionID, 'ses_native');
    await f.hook('context', request({ options: {} }));
    await assert.rejects(f.hook('context', request({ sessionID: 'ses_other', options: {} })), /unrelated roots/);
    assert.ok(!f.calls.some(([, args]) => args[0] === 'sessions'), 'Herdr handoff wrote a Rex receipt');
  } finally { await f.cleanup(); await rm(dir, { recursive: true, force: true }); }
});

test('handoff refuses symlinks, shared modes/hardlinks, identity mismatches and unproven native candidates', async () => {
  const cases = [
    { mode: 0o644 }, { parentMode: 0o755 }, { symlink: true }, { hardlink: true },
    { handoff: admission({ directory: '/foreign' }) }, { handoff: admission({ agent: 'foreign' }) },
    { handoff: admission({ model: { ...model, variant: 'high' } }) },
    { handoff: admission({ sessionID: 'not-native' }) },
    { handoff: admission({ sessionID: 'ses_unknown' }), nativeRefusal: true },
    { handoff: admission({ sessionID: 'ses_native' }), native: nativeInfo('ses_native', 'ses_other'), nativeRefusal: true },
    { handoff: admission({ sessionID: 'ses_native' }), native: nativeInfo('ses_native', undefined, { location: { directory: '/foreign' } }), nativeRefusal: true },
  ];
  for (const candidate of cases) {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-handoff-refusal-'));
    const marker = path.join(dir, 'admission');
    const source = path.join(dir, 'source');
    await writeFile(source, JSON.stringify(candidate.handoff ?? admission({ sessionID: 'ses_native' })), { mode: candidate.mode ?? 0o600 });
    if (candidate.symlink) await symlink(source, marker);
    else if (candidate.hardlink) await link(source, marker);
    else { await writeFile(marker, await readFile(source), { mode: candidate.mode ?? 0o600 }); }
    if (candidate.parentMode) await chmod(dir, candidate.parentMode);
    const f = await fixture({ env: { CEL_SESSION_BACKEND: 'herdr', CEL_OPENCODE_ADMISSION_FILE: marker } });
    try {
      if (candidate.native) f.lineage.set('ses_native', candidate.native);
      await f.tick();
      assert.equal(f.delivered.length, 0);
      assert.ok(!f.calls.some(([, args]) => args[0] === 'inbox'));
      if (!candidate.nativeRefusal) assert.deepEqual(f.gets, [], 'unowned or mismatched handoff reached native APIs');
      const providers = providerEditor(); f.transforms.provider(providers);
      assert.equal(providers.providers.size, 0);
    } finally { await f.cleanup(); await chmod(dir, 0o700); await rm(dir, { recursive: true, force: true }); }
  }
});

test('Rex receipt and private handoff must nominate the same existing native ID', async () => {
  for (const handoff of [admission(), admission({ sessionID: 'ses_other' })]) {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-rex-handoff-'));
    const marker = path.join(dir, 'admission');
    await writeFile(marker, JSON.stringify(handoff), { mode: 0o600 });
    const f = await resumeFixture({}, { env: { CEL_OPENCODE_ADMISSION_FILE: marker } });
    try {
      await f.tick();
      assert.deepEqual(f.gets, []);
      assert.equal(f.delivered.length, 0);
    } finally { await f.cleanup(); await rm(dir, { recursive: true, force: true }); }
  }
});

test('fresh launch handoff cannot adopt a root created before native-inventory admission', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-fresh-handoff-'));
  const marker = path.join(dir, 'admission');
  const f = await fixture({ env: { CEL_SESSION_BACKEND: 'herdr', CEL_OPENCODE_ADMISSION_FILE: marker } });
  try {
    await f.emit(created(nativeInfo('ses_other')));
    await writeFile(marker, JSON.stringify(admission()), { mode: 0o600 });
    await f.tick();
    assert.equal(f.delivered.length, 0);
    assert.deepEqual(f.gets, []);
    await assert.rejects(f.hook('context', request({ options: {} })), /not bound/);
    await f.emit(created());
    await f.hook('context', request({ options: {} }));
    await f.tick();
    assert.equal(f.delivered[0].sessionID, 'ses_native');
  } finally { await f.cleanup(); await rm(dir, { recursive: true, force: true }); }
});
