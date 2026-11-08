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
import { PINNED_CATALOG, nativeModel } from './model-contract.mjs';

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
    const entry = { callback, scope };
    hooks[domain].set(name, [...(hooks[domain].get(name) ?? []), entry]);
    return { async dispose() { hooks[domain].set(name, hooks[domain].get(name).filter(value => value !== entry)); disposed++; } };
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
    hook: (name, event) => {
      const entries = hooks.session.get(name);
      return (entries.find(entry => !entry.scope || entry.scope.providerID === event.model?.providerID) ?? entries[0]).callback(event);
    },
    tool: (tool, input, sessionID = 'ses_native') => hooks.tool.get('execute.before')[0].callback({ tool, input, sessionID, agent: options.agent, messageID: 'msg_tool', id: 'call_tool' }),
    shell: (command) => hooks.shell.get('create.before')[0].callback({ command, cwd: '/another/workdir', timeout: 0, shell: '/bin/bash', env: {} }),
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
    assert.equal(f.waits(), 0);
    assert.equal(f.env.GH_TOKEN, 'fixture-github');
  } finally { await f.cleanup(); }
  assert.equal(f.stopped(), true);
  assert.equal(f.streamEnded(), true);
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
  const coreDir = path.join(temp, 'core');
  const env = { ...process.env, CEL_ROOT: repo, CEL_ROLE: 'core', CEL_CORE_DIR: coreDir };
  const guarded = [];
  const f = await fixture({ env: { CEL_ROOT: repo }, deps: { run: async (bin, args) => {
    assert.equal(bin, 'bash'); guarded.push(args);
    return (await execute(bin, args, { env })).stdout;
  } } });
  try {
    await f.emit(created());
    for (const tool of ['write', 'edit']) await assert.rejects(f.tool(tool, { path: 'repos/protected/marker' }), /celestial guard/);
    await assert.rejects(f.tool('shell', { command: `touch ${temp}/repos/marker`, workdir: coreDir }), /celestial guard/);
    await assert.rejects(f.shell(`touch ${temp}/repos/marker`), /celestial guard/);
    await f.tool('shell', { command: `CEL_GUARD_ALLOW_ONCE=1 touch ${temp}/repos/marker` });
    await assert.rejects(f.tool('shell', { command: `CEL_GUARD_ALLOW_ONCE=11 touch ${temp}/repos/marker` }), /celestial guard/);
    for (const operation of ['Add File', 'Delete File', 'Update File']) {
      await assert.rejects(f.tool('patch', { patchText: `*** Begin Patch\n  *** ${operation}: repos/protected/marker\n*** End Patch` }), /celestial guard/);
    }
    await assert.rejects(f.tool('patch', { patchText: `*** Begin Patch\n*** Update File: ${coreDir}/allowed\n*** Move to: repos/protected/marker\n@@\n-old\n+new\n*** End Patch` }), /celestial guard/);
    await assert.rejects(f.tool('patch', { patchText: `*** Begin Patch\n*** Update File: repos/protected/marker\n*** Move to: ${coreDir}/allowed\n@@\n-old\n+new\n*** End Patch` }), /celestial guard/);
    await assert.rejects(f.tool('patch', { patchText: 'unclassified' }), /cannot classify/);
    await assert.rejects(f.tool('write', { filePath: 'legacy-v1-field' }), /cannot classify/);
    await f.tool('write', { path: `${coreDir}/allowed`, content: 'allowed' });
    assert.ok(guarded.some((args) => args.at(-1) === '/fixture/product/repos/protected/marker'));
  } finally { await f.cleanup(); await rm(temp, { recursive: true, force: true }); }
});

// The one-off override is the shared classifier's to honour, as in the claude
// and omp adapters: never for a team member, never for a forge review verdict
// (whose refusal names `cel solo review`), and only spelled exactly.
test('the override is decided by the shared guard: no member override, no forge verdict, comments still pass', async () => {
  const temp = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-guard-'));
  let role = 'solo';
  const f = await fixture({ env: { CEL_ROOT: repo }, deps: { run: async (bin, args) => {
    assert.equal(bin, 'bash');
    return (await execute(bin, args, { env: { ...process.env, CEL_ROOT: repo, CEL_ROLE: role } })).stdout;
  } } });
  try {
    await f.emit(created());
    for (const command of ['gh pr review 3 --approve', 'CEL_GUARD_ALLOW_ONCE=1 gh pr review 3 -a', 'gh pr review 3 --request-changes=true -b x',
      'gh api -X POST repos/o/r/pulls/3/reviews -f event=APPROVE', 'tea pr approve 3', 'tea pr r 3', 'env -u X gh pr review 3 -a',
      'CEL_GUARD_ALLOW_ONCE=1 gh api graphql -F query=@q.graphql', 'gh api -X POST repos/o/r/pulls/3/%72eviews']) {
      await assert.rejects(f.shell(command), /cel solo review/, command);
    }
    await assert.rejects(f.shell('CEL_GUARD_ALLOW_ONCE=1 gh alias set ap "pr review --approve"'), /gh alias/);
    await f.shell('gh pr review 3 --comment -b x');
    await f.shell(`CEL_GUARD_ALLOW_ONCE=1 touch ${temp}/marker`);
    role = 'member';
    await assert.rejects(f.shell(`CEL_GUARD_ALLOW_ONCE=1 touch ${temp}/marker`), /celestial guard/);
  } finally { await f.cleanup(); await rm(temp, { recursive: true, force: true }); }
});

// OpenCode hands the shared classifier the command text as it is, newlines
// included, and gets the claude and omp adapters' verdict: a command led by a
// newline is a command; a heredoc or quoted body is data.
test('a newline separates commands in the shared guard, and heredoc and quoted bodies stay data', async () => {
  const f = await fixture({ env: { CEL_ROOT: repo }, deps: { run: async (bin, args) => {
    assert.equal(bin, 'bash');
    return (await execute(bin, args, { env: { ...process.env, CEL_ROOT: repo, CEL_ROLE: 'solo' } })).stdout;
  } } });
  try {
    await f.emit(created());
    for (const command of ['true\ngh pr merge 3', "bash -c $'true\\ngh pr merge 3'", 'bash <<EOF\ngh pr merge 3\nEOF']) {
      await assert.rejects(f.shell(command), /cel solo land/, command);
    }
    await f.shell("cat > f <<'EOF'\ngh pr merge 3\nEOF");
    await f.shell('git commit -m "line1\ngh pr merge 3"');
  } finally { await f.cleanup(); }
});

test('a classifier that reports its own error (exit 2) allows as before, except a verdict-shaped command; other classifier failures still refuse', async () => {
  let failure;
  const f = await fixture({ env: { CEL_ROOT: repo }, deps: { run: async () => { throw failure; } } });
  try {
    await f.emit(created());
    failure = Object.assign(new Error('guard-classify: policy failed to load'), { code: 2 });
    await f.tool('write', { path: 'allowed', content: 'x' });
    await f.shell('ls -la');
    for (const command of ['gh pr review 3 --approve', 'gh api -X POST repos/o/r/pulls/3/%72eviews', 'gh api graphql --input q.json',
      'tea pr r 3', 'gh alias set ap x']) {
      await assert.rejects(f.shell(command), /forge review verdict/, command);
    }
    failure = Object.assign(new Error('spawn bash ENOENT'), { code: 'ENOENT' });
    await assert.rejects(f.tool('write', { path: 'allowed', content: 'x' }), /ENOENT/);
  } finally { await f.cleanup(); }
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

test('a failed count still reads, and a corrupt mailbox is said once, not on every idle tick', async () => {
  const corrupt = '[sandbox] {"state":"corrupt","reader":"widget-orch","workspace":"sandbox","file":"/inbox/sandbox.jsonl","unread":null}\n';
  let reads = 0;
  const f = await fixture({ deps: { run: async (_bin, args) => {
    if (args[0] === 'inbox' && args[1] === 'count') throw Object.assign(new Error('exit 1'), { code: 1, stdout: '0\n' });
    if (args[0] === 'inbox' && args[1] === 'read') { reads++; throw Object.assign(new Error('exit 1'), { code: 1, stdout: corrupt }); }
    return '';
  } } });
  try {
    await f.emit(created());
    await f.tick();
    assert.equal(reads, 1, 'a count that failed must not stand for an empty mailbox');
    assert.equal(f.delivered.length, 1);
    assert.match(f.delivered[0].text, /\[sandbox\] celestial inbox: mailbox \/inbox\/sandbox\.jsonl is corrupt/);
    await f.emit(status('idle'));
    await f.tick();
    assert.equal(reads, 2);
    assert.equal(f.delivered.length, 1, 'the same corrupt mailbox must not wake the agent every tick');
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

for (const type of ['session.agent.selected', 'session.model.selected']) {
  test(`native ${type} on an idle bound root fences in-flight reads without blocking later idle mail`, async () => {
    // The model case mirrors an owner switch to another scoped catalog model.
    const switched = { providerID: 'ompgw-claude', id: 'claude-advertised-fixture' };
    const modelSwitch = type === 'session.model.selected';
    const native = modelSwitch ? { model: switched } : {};
    const event = { type, data: modelSwitch
      ? { sessionID: 'ses_native', model: switched, previous: { ...model } }
      : { sessionID: 'ses_native', agent: options.agent, previous: options.agent } };
    const f = await resumeFixture({}, modelSwitch ? { options: { catalog } } : {});
    let release;
    try {
      f.setCount(0); await f.tick();
      assert.equal(f.delivered.length, 0, 'bound idle root had no mail');
      f.lineage.set('ses_native', nativeInfo('ses_native', undefined, native));
      // A selection racing an awaited native idle read still discards that read.
      let entered;
      const querying = new Promise((resolve) => { entered = resolve; });
      const get = f.context.session.get;
      f.context.session.get = (input) => new Promise((resolve) => { release = () => resolve(get(input)); entered(); });
      f.setCount(1);
      const before = f.calls.length;
      const polling = f.tick(); await querying;
      await f.emit({ id: 'evt_selected', created: 3, ...event });
      release(); await polling;
      assert.equal(f.delivered.length, 0, 'stale in-flight idle read drained mail');
      assert.ok(!f.calls.slice(before).some(([, args]) => args[0] === 'inbox'), 'stale read touched the inbox');
      f.context.session.get = get;
      // No native idle/execution event follows a selection on an idle root;
      // the next native time.busy/time.idle observation is the authority.
      await f.tick();
      assert.equal(f.delivered.length, 1, 'idle root never delivered queued mail after selection');
      assert.equal(f.delivered[0].sessionID, 'ses_native');
      assert.equal(f.delivered[0].delivery, 'steer');
      assert.equal(f.waits(), 0);
      // A selection observed while native time shows busy still delivers nothing.
      await f.emit(status('idle')); f.setCount(1);
      f.lineage.set('ses_native', nativeInfo('ses_native', undefined, { ...native, time: { created: 1, busy: 30, idle: 20 } }));
      await f.emit({ id: 'evt_selected_busy', created: 4, ...event });
      await f.tick();
      assert.equal(f.delivered.length, 1, 'native busy root drained mail after selection');
    } finally { release?.(); await f.cleanup(); }
  });
}

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

// OpenCode evicts an idle location and re-boots it on the next request: the
// fresh plugin instance must not refuse that request while its launch proof is
// still valid merely because the 3s observer has not ticked yet.
test('re-booted location admits a model request before the first observer tick from a still-valid launch proof', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-reboot-'));
  const marker = path.join(dir, 'admission');
  await writeFile(marker, JSON.stringify(admission({ sessionID: 'ses_native' })), { mode: 0o600 });
  const f = await resumeFixture({}, { env: { CEL_OPENCODE_ADMISSION_FILE: marker } });
  try {
    assert.deepEqual(f.gets, [], 'setup must not call native session APIs');
    assert.equal(f.reloads(), 0);
    const event = request({ headers: { 'X-Session-Id': 'foreign' } });
    await f.hook('model.request', event);
    assert.deepEqual(event.headers, { 'x-session-id': options.route });
    assert.ok(f.gets.includes('ses_native'), 'resumed root was not proven natively');
    assert.equal(f.reloads(), 4, 'launch gate and exact resume proof each rebuild scoped availability once');
    const providers = providerEditor(); f.transforms.provider(providers);
    assert.deepEqual([...providers.providers.keys()], ['ompgw-codex']);
    await assert.rejects(f.hook('model.request', request({ sessionID: 'ses_other', headers: {} })), /unrelated roots/);
    await f.tick();
    assert.equal(f.reloads(), 4, 'observer must reuse the request-time admission');
    assert.equal(f.delivered.length, 1);
    assert.equal(f.delivered[0].sessionID, 'ses_native');
  } finally { await f.cleanup(); await rm(dir, { recursive: true, force: true }); }
});

test('request-time and observer launch admission share one refresh', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-reboot-herdr-'));
  const marker = path.join(dir, 'admission');
  await writeFile(marker, JSON.stringify(admission({ sessionID: 'ses_native' })), { mode: 0o600 });
  const f = await fixture({ env: { CEL_SESSION_BACKEND: 'herdr', CEL_OPENCODE_ADMISSION_FILE: marker } });
  try {
    await Promise.all([f.hook('model.request', request({ headers: {} })), f.tick()]);
    assert.equal(f.reloads(), 4, 'concurrent admission proofs rebuilt availability more than once');
    assert.ok(f.gets.includes('ses_native'), 'resumed root was not proven natively');
    assert.equal(f.delivered.length, 1);
    assert.equal(f.delivered[0].sessionID, 'ses_native');
  } finally { await f.cleanup(); await rm(dir, { recursive: true, force: true }); }
});

test('request-time admission still refuses a missing or unowned launch proof', async () => {
  for (const mode of [undefined, 0o644]) {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-reboot-refusal-'));
    const marker = path.join(dir, 'admission');
    if (mode) await writeFile(marker, JSON.stringify(admission({ sessionID: 'ses_native' })), { mode });
    const f = await resumeFixture({}, { env: { CEL_OPENCODE_ADMISSION_FILE: marker } });
    try {
      await assert.rejects(f.hook('model.request', request({ headers: {} })), /launch admission is pending/);
      await assert.rejects(f.shell('printf allowed'), /launch admission is pending/);
      await f.hook('experimental.idle', { sessionID: 'ses_native', background: [] });
      assert.deepEqual(f.gets, []);
      assert.equal(f.reloads(), 0);
      assert.equal(f.delivered.length, 0);
    } finally { await f.cleanup(); await rm(dir, { recursive: true, force: true }); }
  }
});

test('re-booted location binds the owned resumed root from a native idle before the first observer tick', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-reboot-idle-'));
  const marker = path.join(dir, 'admission');
  await writeFile(marker, JSON.stringify(admission({ sessionID: 'ses_native' })), { mode: 0o600 });
  const f = await resumeFixture({}, { env: { CEL_OPENCODE_ADMISSION_FILE: marker } });
  try {
    await f.hook('experimental.idle', { sessionID: 'ses_other', background: [] });
    assert.equal(f.delivered.length, 0, 'a foreign idle must not deliver');
    await f.hook('experimental.idle', { sessionID: 'ses_native', background: [] });
    assert.equal(f.delivered.length, 1);
    assert.equal(f.delivered[0].sessionID, 'ses_native');
    assert.equal(f.waits(), 0);
    await f.tick();
    assert.equal(f.reloads(), 4);
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

const catalogSource = { providerKey: 'openai-codex:0.159.0', schemaVersion: 14, updatedAt: 1 };
const catalog = { schemaVersion: 1, sources: [{ ...catalogSource, hashVerification: 'not_verified' }], excluded: [], models: [
  { ...structuredClone(PINNED_CATALOG.models[0]), source: catalogSource, thinking: { mode: 'effort', efforts: ['low', 'medium', 'high'] } },
  { id: 'claude-advertised-fixture', name: 'Advertised fixture', providerID: 'ompgw-claude', api: 'anthropic-messages', source: { kind: 'gateway-advertised' } },
] };

test('catalog requests keep each native selection and scoped HTTP/WS affinity without losing model settings', async () => {
  const f = await fixture({ options: { catalog } });
  try {
    await f.emit(created());
    const childModel = { providerID: 'ompgw-claude', id: 'claude-advertised-fixture' };
    f.lineage.set('ses_child', nativeInfo('ses_child', 'ses_native', { model: childModel }));
    const models = modelEditor();
    const childSpec = nativeModel(catalog.models[1]);
    models.models.set(`${childModel.providerID}/${childModel.id}`, { ...childModel, ...childSpec, settings: { unrelated: true }, family: 'claude-haiku' });
    f.transforms.model(models);
    assert.deepEqual(models.get(model.providerID, model.id).settings, { reasoningEffort: 'medium', unrelated: true });
    assert.deepEqual(models.get(childModel.providerID, childModel.id).settings, { unrelated: true });
    assert.equal(models.get(childModel.providerID, childModel.id).family, undefined);
    for (const name of ['context', 'compaction', 'generate', 'title']) {
      const event = request({ sessionID: 'ses_child', model: childModel, options: { unrelated: true } });
      await f.hook(name, event);
      assert.deepEqual(event.model, childModel);
      assert.deepEqual(event.options, { unrelated: true });
    }
    for (const name of ['model.request', 'experimental.ws.handshake']) {
      const event = request({ sessionID: 'ses_child', model: childModel, headers: { Authorization: 'fixture-only' } });
      await f.hook(name, event);
      assert.deepEqual(event.headers, { Authorization: 'fixture-only', 'x-session-id': options.route });
    }
    const event = request({ sessionID: 'ses_child', model: childModel,
      request: new Request('http://fixture/v1/messages', { method: 'POST', body: 'fixture-body', headers: { authorization: 'fixture-only' } }) });
    await f.hook('http.request', event);
    assert.equal(event.request.headers.get('x-session-id'), options.route);
    assert.equal(await event.request.text(), 'fixture-body');
    await assert.rejects(f.hook('context', request({ sessionID: 'ses_child', model: { ...childModel, variant: 'medium' }, options: {} })), /fallback/);
    await assert.rejects(f.hook('context', request({ sessionID: 'ses_other', model: childModel, options: {} })), /unrelated roots/);
  } finally { await f.cleanup(); }
});

test('catalog private resume keeps actual owner-selected model and refuses selection drift', async () => {
  for (const drift of [false, true]) {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-catalog-resume-'));
    const marker = path.join(dir, 'admission');
    const selected = { providerID: 'ompgw-claude', id: 'claude-advertised-fixture' };
    await writeFile(marker, JSON.stringify(admission({ sessionID: 'ses_native', model: selected })), { mode: 0o600 });
    const f = await fixture({ options: { catalog }, env: { CEL_SESSION_BACKEND: 'herdr', CEL_OPENCODE_ADMISSION_FILE: marker } });
    f.lineage.set('ses_native', nativeInfo('ses_native', undefined, { model: drift ? model : selected }));
    try {
      await f.tick();
      if (drift) {
        assert.equal(f.delivered.length, 0);
        await assert.rejects(f.hook('context', request({ model: selected, options: {} })), /resume refused/);
      } else {
        assert.equal(f.delivered[0].sessionID, 'ses_native');
        const event = request({ model: selected, options: {} });
        await f.hook('context', event);
        assert.deepEqual(event.model, selected);
        assert.deepEqual(event.options, {});
      }
    } finally { await f.cleanup(); await rm(dir, { recursive: true, force: true }); }
  }
});
