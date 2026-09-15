import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, mkdir, readFile, writeFile, rm, symlink } from 'node:fs/promises';
import { createServer } from 'node:net';
import { request } from 'node:http';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';

const root = fileURLToPath(new URL('../', import.meta.url));

// Only fixture executables are visible to either server. No real CLI, fleet,
// account or workspace is reachable when a mutation test succeeds.
const boot = async (t, kind, extraEnv = {}) => {
  const dir = await mkdtemp(join(tmpdir(), 'cel-http-'));
  const bin = join(dir, 'bin');
  await mkdir(bin);
  await mkdir(join(dir, 'pub'));
  await mkdir(join(dir, 'inbox'));
  await writeFile(join(dir, 't.html'), '<!doctype html><title>Test</title><p>plain page</p>');
  await writeFile(join(bin, 'fixture'), `#!/bin/sh
case "$1 $2" in
  'agent list') printf '{"result":{"agents":[]}}';;
  'workspace list') printf '{"result":{"workspaces":[]}}';;
  'pane list') printf '{"result":{"panes":[]}}';;
  'agent prompt'|'pane focus'|'inbox resolve'|state*) printf '%s %s\\n' "$1" "$2" >> "$CALLS"; printf ok;;
  *) printf '{}';;
esac
`, { mode: 0o700 });
  for (const name of ['herdr', 'gh', 'yq', 'cel']) await symlink('fixture', join(bin, name));
  await mkdir(join(dir, 'core/skills/linear/bin'), { recursive: true });
  await symlink(join(bin, 'fixture'), join(dir, 'core/skills/linear/bin/cel-linear'));
  const reserve = createServer();
  reserve.listen(0, '127.0.0.1');
  await once(reserve, 'listening');
  const port = reserve.address().port;
  await new Promise((resolve) => reserve.close(resolve));
  const env = {
    PATH: bin, HOME: dir, CALLS: join(dir, 'calls'), CEL_ROOT: dir,
    CEL_INBOX_DIR: join(dir, 'inbox'), CEL_EFFECTS_DIR: join(dir, 'effects'),
    CEL_PAGES_ROOT: dir, CEL_PAGES_PUBLIC_ROOT: join(dir, 'pub'),
    CEL_PAGES_PUBLIC_URL: 'https://share.example', CEL_PAGES_HOST: '127.0.0.1',
    CEL_PAGES_PORT: String(port), CEL_PAGES_FEEDBACK: kind === 'public' ? '0' : '1',
    CEL_DASH_CONFIG: JSON.stringify({ name: 'test', wsdir: dir, host: '127.0.0.1', port, repos: [], services: [] }),
    ...extraEnv,
  };
  const child = spawn(process.execPath, [join(root, `tools/${kind === 'dash' ? 'dash' : 'pages'}/server.mjs`)], {
    env, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let logs = '';
  child.stderr.on('data', (c) => { logs += c; });
  const exited = once(child, 'close');
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    await exited;
    await rm(dir, { recursive: true, force: true });
  });
  await Promise.race([
    once(child.stdout, 'data'),
    exited.then(() => { throw new Error(`server exited before readiness: ${logs}`); }),
  ]);
  const call = (path, { method = 'GET', headers = {}, body } = {}) => new Promise((resolve, reject) => {
    const req = request({ hostname: '127.0.0.1', port, path, method, headers, agent: false }, (res) => {
      let text = '';
      res.setEncoding('utf8');
      res.on('data', (part) => { text += part; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text }));
      res.on('error', reject);
    });
    req.setTimeout(10000, () => req.destroy(new Error('request timed out')));
    req.on('error', reject);
    req.end(body);
  });
  assert.equal((await call('/')).status, 200);
  return { dir, port, call, child, logs: () => logs };
};

const session = async (server) => {
  const res = await server.call('/api/session');
  assert.equal(res.status, 200);
  assert.equal(res.headers['cache-control'], 'no-store');
  assert.equal(res.headers['access-control-allow-origin'], undefined);
  return JSON.parse(res.text).csrfToken;
};
const post = (server, path, token, body, headers = {}) => server.call(path, {
  method: 'POST', body: JSON.stringify(body),
  headers: { 'content-type': 'application/json', ...(token ? { 'x-cel-csrf': token } : {}), ...headers },
});

for (const kind of ['pages', 'dash']) {
  test(`${kind}: private reads and writes refuse alien Host and missing/wrong CSRF`, { timeout: 20000 }, async (t) => {
    const s = await boot(t, kind);
    const token = await session(s);
    const paths = kind === 'pages' ? ['/api/promote', '/api/revoke', '/api/feedback'] :
      ['/api/prompt', '/api/focus', '/api/inbox-resolve', '/api/ticket-state', '/api/client-log'];
    for (const path of paths) {
      assert.equal((await post(s, path, null, {})).status, 403, path);
      const wrongToken = (token[0] === 'A' ? 'B' : 'A') + token.slice(1);
      assert.equal((await post(s, path, wrongToken, {})).status, 403, path);
      assert.equal((await post(s, path, token, {}, { host: 'attacker.example', origin: 'http://attacker.example' })).status, 403, path);
      assert.equal((await post(s, path, token, {}, { origin: 'http://attacker.example' })).status, 403, path);
      assert.equal((await post(s, path, token, {}, { origin: `https://127.0.0.1:${s.port}` })).status, 403, path);
      assert.equal((await post(s, path, token, {}, { 'sec-fetch-site': 'cross-site' })).status, 403, path);
      assert.equal((await post(s, path, token, {}, { 'content-type': 'text/plain' })).status, 403, path);
    }
    for (const path of ['/', '/api/session', kind === 'dash' ? '/api/state' : '/api/doc?name=t.html', '/t.html?raw=1']) {
      assert.equal((await s.call(path, { headers: { host: `attacker.example:${s.port}`, 'x-forwarded-host': `127.0.0.1:${s.port}` } })).status, 403, path);
    }
    assert.equal((await s.call('/', { method: 'HEAD', headers: { host: 'attacker.example' } })).status, 403);
    assert.equal((await s.call('/', { headers: { host: `localhost:${s.port}` } })).status, 200);
    assert.equal((await s.call('/', { headers: { host: `localhost:${s.port + 1}` } })).status, 403);
    assert.equal((await s.call('/api/session', { headers: { 'sec-fetch-site': 'cross-site' } })).status, 403);
    await assert.rejects(readFile(join(s.dir, 'calls')), { code: 'ENOENT' });
    await assert.rejects(readFile(join(s.dir, '.meta/promotions.log')), { code: 'ENOENT' });
    assert.ok(!s.logs().includes(token), 'server must not log its secret');
  });

  test(`${kind}: configured proxy authority and explicit automation token work`, { timeout: 20000 }, async (t) => {
    const token = 'test-only-automation-secret-0123456789';
    const prefix = kind === 'dash' ? 'CEL_DASH' : 'CEL_PAGES';
    const s = await boot(t, kind, { [`${prefix}_TRUSTED_ORIGINS`]: 'https://control.example,https://control.example:8443', [`${prefix}_CSRF_TOKEN`]: token });
    assert.equal(await session(s), token);
    for (const host of ['control.example', 'control.example:8443']) {
      assert.equal((await s.call('/', { headers: { host } })).status, 200);
      const res = await post(s, kind === 'dash' ? '/api/client-log' : '/api/feedback', token,
        { doc: 't.html', message: 'ordinary feedback' }, { host, origin: `https://${host}`, 'sec-fetch-site': 'same-origin' });
      assert.equal(res.status, kind === 'dash' ? 204 : 200);
      assert.equal((await post(s, kind === 'dash' ? '/api/client-log' : '/api/feedback', token,
        { doc: 't.html', message: 'refused feedback' }, { host, origin: `http://${host}` })).status, 403);
    }
    assert.equal((await s.call('/', { headers: { host: 'control.example:8444' } })).status, 403);
    assert.equal((await s.call('/', { headers: { host: 'another.example', forwarded: 'host=control.example' } })).status, 403);
    assert.ok(!s.logs().includes(token));
  });
}

test('dashboard: absent inbox returns complete empty state on repeated HTTP reads', { timeout: 20000 }, async (t) => {
  const s = await boot(t, 'dash');
  for (let i = 0; i < 2; i++) {
    const res = await s.call('/api/state');
    assert.equal(res.status, 200);
    const state = JSON.parse(res.text);
    assert.deepEqual(state.inbox, []);
    assert.deepEqual(state.inboxBy, []);
    assert.deepEqual(state.inboxOpen, []);
  }
  assert.equal((await s.call('/')).status, 200);
});

test('dashboard: failed async state read returns 500 and the next request survives', { timeout: 20000 }, async (t) => {
  const s = await boot(t, 'dash');
  await mkdir(join(s.dir, 'inbox/test.jsonl'));
  assert.equal((await s.call('/api/state')).status, 500);
  await rm(join(s.dir, 'inbox/test.jsonl'), { recursive: true });
  assert.equal((await s.call('/api/state')).status, 200);
  await mkdir(join(s.dir, 'effects/broken.js'), { recursive: true });
  assert.equal((await s.call('/fx/broken.js')).status, 500);
  assert.equal((await s.call('/')).status, 200);
});

test('dashboard: all control mutations accept the current browser token', { timeout: 20000 }, async (t) => {
  const s = await boot(t, 'dash');
  const html = (await s.call('/')).text;
  const token = html.match(/<meta name="cel-csrf-token" content="([^"]+)"/)[1];
  const headers = { origin: `http://127.0.0.1:${s.port}`, 'sec-fetch-site': 'same-origin' };
  for (const [path, body, status] of [
    ['/api/prompt', { target: 'w1:p1', message: 'fixture prompt' }, 200],
    ['/api/focus', { pane: 'w1:p1' }, 200],
    ['/api/inbox-resolve', { id: '1234567890123' }, 200],
    ['/api/ticket-state', { id: 'WG-1', state: 'Ready' }, 200],
    ['/api/client-log', { event: 'fixture' }, 204],
  ]) assert.equal((await post(s, path, token, body, headers)).status, status, path);
  assert.deepEqual((await readFile(join(s.dir, 'calls'), 'utf8')).trim().split('\n'),
    ['agent prompt', 'pane focus', 'inbox resolve', 'state WG-1']);
});

test('pages: stored feedback renders as text and the real chrome mutation handlers work', { timeout: 20000 }, async (t) => {
  const s = await boot(t, 'pages');
  const marker = '<img src=x onerror="globalThis.feedbackExecuted=true">';
  const quote = '<svg onload="globalThis.quoteExecuted=true"> & ordinary text';
  await mkdir(join(s.dir, '.meta'));
  await writeFile(join(s.dir, '.meta/t.html.json'), JSON.stringify({ pane: marker }));
  const token = await session(s);
  assert.equal((await post(s, '/api/feedback', token, { doc: 't.html', message: marker, quote })).status, 200);
  const receipt = JSON.parse((await s.call('/api/doc?name=t.html')).text).feedback[0];
  assert.equal(receipt.message, marker);
  assert.equal(receipt.quote, quote);
  assert.equal(receipt.pane, marker);
  const html = (await s.call('/t.html')).text;
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, { style: {}, dataset: {}, value: '', innerHTML: '', textContent: '', addEventListener() {} });
    return elements.get(id);
  };
  const pending = new Set();
  const context = {
    document: { getElementById: element, querySelector: () => ({ content: token }) },
    location: { origin: `http://127.0.0.1:${s.port}` },
    navigator: { clipboard: { writeText: async () => {} } }, window: { isSecureContext: true },
    confirm: () => true, setTimeout: () => {}, URL,
    fetch: (url, options = {}) => {
      const promise = s.call(new URL(url).pathname + new URL(url).search, options).then((res) => ({
        ok: res.status >= 200 && res.status < 300, json: async () => JSON.parse(res.text), text: async () => res.text,
      }));
      pending.add(promise);
      promise.finally(() => pending.delete(promise));
      return promise;
    },
  };
  const settle = async () => {
    do { await Promise.all([...pending]); await new Promise(setImmediate); } while (pending.size);
  };
  runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], context);
  await settle();
  assert.doesNotMatch(element('timeline').innerHTML, /<(?:img|svg|script)\b/i);
  assert.doesNotMatch(element('fbhist').innerHTML, /<(?:img|svg|script)\b/i);
  assert.ok(element('timeline').innerHTML.includes('&lt;img'));
  assert.ok(element('timeline').innerHTML.includes('&lt;svg'));
  assert.ok(element('fbhist').innerHTML.includes('&lt;img'));
  element('fbmsg').value = 'another ordinary <line> & "quote"';
  await element('fbsend').onclick();
  await settle();
  assert.equal(JSON.parse((await s.call('/api/doc?name=t.html')).text).feedback[0].message, 'another ordinary <line> & "quote"');
  element('ttl').value = '24';
  await element('visbtn').onclick();
  const shared = JSON.parse((await s.call('/api/doc?name=t.html')).text).public;
  assert.ok(shared.startsWith('https://share.example/'));
  await element('visbtn').onclick();
  assert.equal(JSON.parse((await s.call('/api/doc?name=t.html')).text).public, null);
});

test('pages: response construction errors do not crash later requests', { timeout: 20000 }, async (t) => {
  const s = await boot(t, 'pages');
  await mkdir(join(s.dir, '.versions/t.html'), { recursive: true });
  await writeFile(join(s.dir, '.versions/t.html/not-an-epoch.html'), 'old');
  assert.equal((await s.call('/api/doc?name=t.html')).status, 500);
  await rm(join(s.dir, '.versions/t.html/not-an-epoch.html'));
  assert.equal((await s.call('/api/doc?name=t.html')).status, 200);
  await mkdir(join(s.dir, 'directory.txt'));
  assert.equal((await s.call('/directory.txt')).status, 500);
  assert.equal((await s.call('/t.html?raw=1')).status, 200);
});

test('public pages: arbitrary tunnel Host can read a live token, never private APIs', { timeout: 20000 }, async (t) => {
  const s = await boot(t, 'public');
  const token = randomBytes(12).toString('hex');
  await mkdir(join(s.dir, token));
  await writeFile(join(s.dir, token, 't.html'), '<p>shared</p>');
  await writeFile(join(s.dir, token, '.share.json'), JSON.stringify({ doc: 't.html', expires: null }));
  const headers = { host: 'any-random-tunnel.example' };
  const res = await s.call(`/${token}/t.html`, { headers });
  assert.equal(res.status, 200);
  assert.equal(res.text, '<p>shared</p>');
  for (const path of ['/t.html', '/api/session', '/api/doc?name=t.html']) assert.equal((await s.call(path, { headers })).status, 404);
  assert.equal((await post(s, '/api/promote', null, { doc: 't.html' }, headers)).status, 405);
});
