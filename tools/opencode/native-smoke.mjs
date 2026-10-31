// OWNER/PARENT-ONLY. Run via native-smoke.sh: private HOME, no external network,
// actual v2 CLI/server/plugin, deterministic loopback Responses fixture only.
import assert from 'node:assert/strict';
import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { access, mkdtemp, mkdir, writeFile, readFile, readlink, readdir, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildConfig } from './config.mjs';

assert.equal(process.env.CEL_OPENCODE_ALLOW_NATIVE_SMOKE, '1', 'Parent must explicitly opt into this disposable native proof');
const hostNetwork = process.env.CEL_SMOKE_HOST_NET_FILE;
assert.ok(hostNetwork && path.isAbsolute(hostNetwork), 'Use the canonical network-isolation wrapper');
const originalNetwork = (await readFile(hostNetwork, 'utf8')).trim();
assert.match(originalNetwork, /^net:\[\d+\]$/);
assert.notEqual(await readlink('/proc/self/ns/net'), originalNetwork, 'Network namespace was not isolated');
const bin = process.argv[2];
assert.ok(bin && path.isAbsolute(bin), 'Pass the exact verified OpenCode binary path');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-native-'));
let child, fixture, childClosed, ownedStart, failure, proof, killed = false;
let log = '';
const requests = [], apiResponses = [];
const model = { providerID: 'ompgw-codex', id: 'gpt-6.1-sol', variant: 'medium' };

async function groupMembers(pgid) {
  const members = [];
  for (const name of await readdir('/proc')) {
    if (!/^\d+$/.test(name)) continue;
    let text;
    try { text = await readFile(`/proc/${name}/stat`, 'utf8'); }
    catch (error) { if (['ENOENT', 'ESRCH'].includes(error.code)) continue; throw error; }
    const fields = text.slice(text.lastIndexOf(')') + 2).trim().split(/\s+/);
    if (Number(name) === pgid && fields[19] !== ownedStart) throw new Error('Disposable process group identity changed; no signal sent');
    if (Number(fields[2]) === pgid && !['Z', 'X'].includes(fields[0])) members.push(Number(name));
  }
  return members;
}
async function waitGroupEmpty(pgid, milliseconds) {
  const deadline = Date.now() + milliseconds;
  do { if (!(await groupMembers(pgid)).length) return true; await new Promise(resolve => setTimeout(resolve, 100)); }
  while (Date.now() < deadline);
  return false;
}
function signalGroup(pgid, signal) {
  try { process.kill(-pgid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
}
async function stopOwnedGroup() {
  if (!child?.pid) return;
  if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  if (!(await waitGroupEmpty(child.pid, 3000))) {
    signalGroup(child.pid, 'SIGTERM');
    if (!(await waitGroupEmpty(child.pid, 3000))) {
      killed = true; signalGroup(child.pid, 'SIGKILL');
      if (!(await waitGroupEmpty(child.pid, 3000))) throw new Error('Disposable process group survived cleanup');
    }
  }
  let timer;
  try { await Promise.race([childClosed, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Disposable child stdio did not close')), 3000); })]); }
  finally { clearTimeout(timer); }
}
async function diagnostics(error, phase) {
  console.error(`OpenCode native proof ${phase}: ${error?.stack ?? error}\nOwned artifacts retained at ${dir}`);
  await writeFile(path.join(dir, `${phase}-error.txt`), String(error?.stack ?? error) + '\n');
  await writeFile(path.join(dir, 'server.log'), log);
  await writeFile(path.join(dir, 'fixture-requests.json'), JSON.stringify(requests, null, 2));
  await writeFile(path.join(dir, 'api-responses.json'), JSON.stringify(apiResponses, null, 2));
}
try {
  const home = path.join(dir, 'home'), fakeRoot = path.join(dir, 'cel'), product = path.join(dir, 'product');
  await mkdir(path.join(fakeRoot, 'bin'), { recursive: true });
  await mkdir(path.join(fakeRoot, 'tools/hooks'), { recursive: true });
  await mkdir(home); await mkdir(product);
  await writeFile(path.join(fakeRoot, 'bin/cel'), '#!/bin/bash\nset -euo pipefail\ncase "$1 $2" in\n "inbox count") if [ -s "$CEL_SMOKE_MAIL" ]; then printf 1; else printf 0; fi;;\n "inbox read") cat "$CEL_SMOKE_MAIL"; rm -f "$CEL_SMOKE_MAIL";;\n "sessions note") CEL_ROOT="$CEL_SMOKE_REAL_ROOT" "$CEL_SMOKE_REAL_ROOT/bin/cel" "$@" 2>> "$CEL_SMOKE_REPORTER_LOG"; jq -c . "$CEL_REX_RECORD" >> "$CEL_SMOKE_NOTES";;\n *) exit 2;;\nesac\n', { mode: 0o700 });
  await writeFile(path.join(fakeRoot, 'tools/hooks/guard-classify.sh'), '#!/bin/bash\nset -euo pipefail\nverdict="$(CEL_ROOT="$CEL_SMOKE_REAL_ROOT" bash "$CEL_SMOKE_REAL_ROOT/tools/hooks/guard-classify.sh" "$@")"\nprintf "%s\\n" "$verdict" >> "$CEL_SMOKE_GUARD_LOG"\nprintf "%s\\n" "$verdict"\n', { mode: 0o700 });
  await writeFile(path.join(dir, 'workspace.yaml'), 'name: native-opencode-fixture\nmode: solo\nrepos: []\n');
  const probeBin = path.join(dir, 'probe-bin'); await mkdir(probeBin);
  for (const name of ['gh', 'git']) await writeFile(path.join(probeBin, name), '#!/bin/bash\nprintf "unexpected owned probe command executed\\n" >&2\nexit 97\n', { mode: 0o700 });
  const marker = path.join(dir, 'guard-must-not-create');
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  const guardCommand = `printf unexpected-execution > ${quote(marker)}; ${quote(path.join(probeBin, 'gh'))} pr merge 1; ${quote(path.join(probeBin, 'git'))} push origin main`;
  let guardArmed = false, guardToolEmitted = false;
  fixture = http.createServer(async (req, res) => {
    let raw = ''; for await (const chunk of req) raw += chunk;
    if (req.url !== '/v1/responses' || req.method !== 'POST') { res.writeHead(500); res.end('unexpected fixture request'); return; }
    requests.push({ headers: req.headers, body: JSON.parse(raw) });
    const n = requests.length, emitGuard = guardArmed && !guardToolEmitted;
    if (emitGuard) guardToolEmitted = true;
    const item = emitGuard
      ? { type: 'function_call', id: `fc_guard_${n}`, call_id: `call_guard_${n}`, name: 'shell', arguments: JSON.stringify({ command: guardCommand }), status: 'completed' }
      : { type: 'message', id: `msg_fixture_${n}`, status: 'completed', role: 'assistant', content: [{ type: 'output_text', text: 'Local compatibility fixture.', annotations: [] }] };
    const response = { id: `resp_fixture_${n}`, object: 'response', created_at: 1, status: 'completed', model: 'gpt-6.1-sol', output: [item], usage: { input_tokens: 1, output_tokens: 2, total_tokens: 3, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } };
    const events = [
      { type: 'response.created', response: { ...response, status: 'in_progress', output: [] } },
      { type: 'response.output_item.added', output_index: 0, item: emitGuard ? { ...item, status: 'in_progress', arguments: '' } : { ...item, status: 'in_progress', content: [] } },
      ...(emitGuard ? [
        { type: 'response.function_call_arguments.delta', item_id: item.id, output_index: 0, delta: item.arguments },
        { type: 'response.function_call_arguments.done', item_id: item.id, output_index: 0, name: item.name, arguments: item.arguments },
      ] : [
        { type: 'response.content_part.added', item_id: item.id, output_index: 0, content_index: 0, part: { type: 'output_text', text: '', annotations: [] } },
        { type: 'response.output_text.delta', item_id: item.id, output_index: 0, content_index: 0, delta: 'Local compatibility fixture.' },
        { type: 'response.output_text.done', item_id: item.id, output_index: 0, content_index: 0, text: 'Local compatibility fixture.' },
        { type: 'response.content_part.done', item_id: item.id, output_index: 0, content_index: 0, part: item.content[0] },
      ]),
      { type: 'response.output_item.done', output_index: 0, item }, { type: 'response.completed', response },
    ];
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const [sequence_number, event] of events.entries()) res.write(`event: ${event.type}\ndata: ${JSON.stringify({ ...event, sequence_number })}\n\n`);
    res.end();
  });
  fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
  const role = path.join(dir, 'role-orchestrator.md'); await writeFile(role, 'Fixture role: retain exact Sol6.1/medium and native session identity.');
  const pluginDirectory = path.join(root, 'tools/opencode/plugin');
  const config = buildConfig({ agent: 'cel-orchestrator', roleFile: role, pluginFile: pluginDirectory, modelID: 'gpt-6.1-sol', transport: 'gateway', baseURL: `http://127.0.0.1:${fixture.address().port}/v1`, route: '{env:CEL_SESSION_ID}', limit: { context: 500000, output: 128000 } });
  config.update = 'disable'; config.share = 'disabled'; config.snapshots = false;
  config.permissions = [{ action: '*', resource: '*', effect: 'allow' }];
  const rexState = path.join(dir, 'rex-state'); await mkdir(rexState);
  const record = path.join(rexState, 'fixture-opencode-orch.json'), notes = path.join(dir, 'accepted-receipts.jsonl');
  const serverPassword = randomBytes(32).toString('base64url');
  const env = { PATH: process.env.PATH, HOME: home, SHELL: '/bin/bash', TMPDIR: dir,
    XDG_CONFIG_HOME: path.join(dir, 'config'), XDG_DATA_HOME: path.join(dir, 'data'), XDG_CACHE_HOME: path.join(dir, 'cache'), XDG_STATE_HOME: path.join(dir, 'state'),
    OPENCODE_PASSWORD: serverPassword,
    OPENCODE_CONFIG_CONTENT: JSON.stringify(config), OPENCODE_DISABLE_MODELS_FETCH: '1', OPENCODE_DISABLE_AUTOUPDATE: '1', OPENCODE_DISABLE_DEFAULT_PLUGINS: '1', npm_config_offline: 'true',
    CEL_ROOT: fakeRoot, CEL_SMOKE_REAL_ROOT: root, CEL_SESSION_BACKEND: 'rex', CEL_REX_RECORD: record, CEL_REX_STATE: rexState, CEL_ORCH_SESSIONS: path.join(dir, 'orch-sessions.json'),
    CEL_SMOKE_NOTES: notes, CEL_SMOKE_REPORTER_LOG: path.join(dir, 'reporter.log'), CEL_SMOKE_MAIL: path.join(dir, 'mail.jsonl'),
    CEL_SESSION_ID: 'fixture-original-account-route', OMP_GATEWAY_TOKEN: 'fixture-not-a-real-key', CEL_GUARD: '1', CEL_ROLE: 'solo', CEL_WORKSPACE: dir, CEL_AGENT_NAME: 'fixture-opencode-orch', CEL_SMOKE_GUARD_LOG: path.join(dir, 'guard.log') };
  assert.equal(execFileSync(bin, ['--version'], { env, encoding: 'utf8', timeout: 10000 }).trim(), 'opencode v2.2.5');
  const help = spawnSync(bin, ['--help'], { env, encoding: 'utf8', timeout: 10000 });
  assert.equal(help.status, 0); assert.match(help.stdout + help.stderr, /--session/); assert.match(help.stdout + help.stderr, /--standalone/);
  async function startNativeServer(nativeID = '') {
    ownedStart = undefined;
    child = spawn(bin, ['serve', '--hostname', '127.0.0.1', '--port', '0'], { cwd: product, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const server = child; childClosed = new Promise(resolve => server.once('close', resolve));
    let startup = ''; const capture = chunk => { const text = chunk.toString(); startup += text; log += text; };
    server.stdout.on('data', capture); server.stderr.on('data', capture);
    const stat = await readFile(`/proc/${server.pid}/stat`, 'utf8'); ownedStart = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[19];
    assert.equal(Number(stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[2]), server.pid);
    const receipt = { name: 'fixture-opencode-orch', agent: 'opencode', cwd: product, role: 'solo', workspace: dir, repo: 'fixture-opencode', pr: '', pane_id: 'rex/fixture-session/fixture-block', backend: 'rex', rex_session: 'fixture-session', rex_block: 'fixture-block', pid: server.pid, pid_start: ownedStart, agent_status: 'working', ...(nativeID ? { agent_session: { value: nativeID } } : {}) };
    await writeFile(record, JSON.stringify(receipt), { mode: 0o600 });
    const url = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Native server startup timeout: ${startup}`)), 30000);
      const inspect = () => { const match = /http:\/\/127\.0\.0\.1:\d+/.exec(startup); if (match) { clearTimeout(timer); resolve(match[0]); } };
      server.stdout.on('data', inspect); server.stderr.on('data', inspect); inspect();
      server.once('error', error => { clearTimeout(timer); reject(error); });
      server.once('close', code => { clearTimeout(timer); reject(new Error(`Native server closed ${code}: ${startup}`)); });
    });
    return { url, receipt };
  }
  const first = await startNativeServer(); let url = first.url;
  async function api(route, body, method = body === undefined ? 'GET' : 'POST') {
    const response = await fetch(url + route, { method, headers: { 'content-type': 'application/json', authorization: `Basic ${Buffer.from(`opencode:${serverPassword}`).toString('base64')}` }, ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(10000) });
    const text = await response.text(); apiResponses.push({ route, status: response.status, text });
    assert.ok(response.ok, `${route}: ${response.status} ${text}`);
    return text ? JSON.parse(text) : undefined;
  }
  async function requireNativePlugin() {
    const deadline = Date.now() + 15000;
    do {
      const inventory = await api(`/api/plugin?directory=${encodeURIComponent(product)}`);
      assert.equal(inventory.location.directory, product);
      const matches = inventory.data.filter(item => item.id === 'celestial' && item.source?.type === 'local' && item.source.path === pluginDirectory);
      assert.ok(matches.length <= 1, 'Ambiguous native plugin package');
      if (matches.length) {
        assert.equal(matches[0].features.server, true);
        assert.equal(matches[0].state.status, 'active', JSON.stringify(matches[0]));
        return;
      }
      await new Promise(resolve => setTimeout(resolve, 100));
    } while (Date.now() < deadline);
    throw new Error('Exact native plugin package did not activate');
  }
  await requireNativePlugin();
  const session = (await api('/api/session', { title: 'Disposable Celestial v2 compatibility fixture', agent: 'cel-orchestrator', model, location: { directory: product } })).data;
  assert.match(session.id, /^ses_/); assert.deepEqual(session.model, model); assert.equal(session.agent, 'cel-orchestrator');
  const messages = async id => (await api(`/api/session/${id}/message?limit=200&order=asc`)).data;
  const assistantText = message => message.type === 'assistant' && message.content?.some(part => part.type === 'text' && part.text.includes('Local compatibility fixture.'));
  async function settle(id) {
    await api(`/api/experimental/session/${id}/wait`, undefined, 'POST');
    const info = (await api(`/api/session/${id}`)).data;
    assert.equal(info.outcome, 'succeeded'); assert.ok(Number.isFinite(info.time.idle) && info.time.idle >= info.time.busy);
    return messages(id);
  }
  await api(`/api/session/${session.id}/prompt`, { text: 'Return the deterministic local fixture response.' });
  assert.ok((await settle(session.id)).some(assistantText), 'Real v2 provider response did not persist');
  async function deliverMail(id, messageID) {
    await writeFile(env.CEL_SMOKE_MAIL, JSON.stringify({ id: messageID, from: 'root', kind: 'status', message: 'Prove native idle inbox delivery.' }) + '\n');
    const deadline = Date.now() + 20000;
    do {
      const rows = await messages(id);
      const index = rows.findIndex(row => row.type === 'synthetic' && row.text.includes(`[${messageID}]`));
      if (index >= 0 && rows.slice(index + 1).some(assistantText)) return rows;
      await new Promise(resolve => setTimeout(resolve, 150));
    } while (Date.now() < deadline);
    throw new Error(`Native idle inbox did not complete ${messageID}`);
  }
  await deliverMail(session.id, 'mail-native-smoke');
  guardArmed = true;
  await api(`/api/session/${session.id}/prompt`, { text: 'Exercise the deterministic shared-guard fixture.' });
  const guarded = await settle(session.id);
  assert.equal(guardToolEmitted, true);
  const denied = guarded.flatMap(row => row.type === 'assistant' ? row.content : []).find(part => part.type === 'tool' && part.name === 'shell' && part.state?.input?.command === guardCommand && part.state.status === 'error');
  assert.ok(denied, 'Real v2 tool-before did not deny exact shell command');
  assert.match(JSON.stringify(denied.state.error), /celestial guard:.*solo agent merges through/);
  assert.match(await readFile(env.CEL_SMOKE_GUARD_LOG, 'utf8'), /deny a solo agent merges through/);
  await assert.rejects(access(marker), { code: 'ENOENT' });
  const nativeChild = (await api('/api/session', { parentID: session.id, title: 'Disposable child lineage fixture', agent: 'explore', model })).data;
  await api(`/api/session/${nativeChild.id}/prompt`, { text: 'Return the deterministic local child response.' });
  assert.ok((await settle(nativeChild.id)).some(assistantText));
  const beforeRestart = await messages(session.id);
  const persisted = (await api(`/api/session/${session.id}`)).data;
  assert.deepEqual(persisted.model, model);
  const listed = spawnSync(bin, ['models', '--server', url], { cwd: product, env, encoding: 'utf8', timeout: 15000 });
  assert.equal(listed.status, 0, listed.stderr); assert.match(listed.stdout, /ompgw-codex\/gpt-6\.1-sol/);
  const beforeExport = requests.length;
  const exported = spawnSync(bin, ['session', 'export', session.id, '--server', url], { cwd: product, env, encoding: 'utf8', timeout: 15000, maxBuffer: 8 * 1024 * 1024 });
  await writeFile(path.join(dir, 'native-export.json'), exported.stdout ?? '');
  assert.equal(exported.status, 0, exported.stderr);
  const transfer = JSON.parse(exported.stdout);
  assert.equal(transfer.info.id, session.id); assert.deepEqual(transfer.info.model, model);
  assert.deepEqual(transfer.messages.map(row => row.id).sort(), beforeRestart.map(row => row.id).sort());
  assert.equal(requests.length, beforeExport, 'Metadata/export CLI unexpectedly invoked provider');
  const observed = (await readFile(notes, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  assert.ok(observed.every(row => row.agent_session?.value === session.id), 'Child rebound main native receipt');
  assert.ok(observed.some(row => row.agent_status === 'working') && observed.some(row => row.agent_status === 'idle'));
  const registry = JSON.parse(await readFile(env.CEL_ORCH_SESSIONS, 'utf8')); assert.equal(registry[product], session.id);
  const beforeSibling = await readFile(record, 'utf8');
  assert.throws(() => execFileSync(path.join(root, 'bin/cel'), ['sessions', 'note', String(child.pid), 'blocked', session.id], { env: { ...env, CEL_ROOT: root }, stdio: 'pipe' }));
  assert.equal(await readFile(record, 'utf8'), beforeSibling);
  await stopOwnedGroup();
  const restarted = await startNativeServer(session.id); url = restarted.url;
  await requireNativePlugin();
  assert.equal((await api(`/api/session/${session.id}`)).data.id, session.id);
  const restored = await deliverMail(session.id, 'mail-native-restart');
  const restoredIDs = new Set(restored.map(row => row.id)); assert.ok(beforeRestart.every(row => restoredIDs.has(row.id)));
  const restartDeadline = Date.now() + 10000; let finalReceipt;
  do { finalReceipt = JSON.parse(await readFile(record, 'utf8')); if (finalReceipt.agent_status === 'idle') break; await new Promise(resolve => setTimeout(resolve, 100)); } while (Date.now() < restartDeadline);
  assert.equal(finalReceipt.pid, restarted.receipt.pid); assert.equal(finalReceipt.pid_start, restarted.receipt.pid_start);
  assert.equal(finalReceipt.agent_session?.value, session.id); assert.equal(finalReceipt.agent_status, 'idle');
  await stopOwnedGroup();
  for (const backend of ['rex', 'herdr']) {
  const tuiProof = spawnSync('/usr/bin/python3', ['-c', `import errno,fcntl,json,os,pty,select,signal,struct,sys,termios,time
node,launcher,binary,record,native,product,output=sys.argv[1:]
pid,terminal=pty.fork()
if pid==0:
 os.chdir(product)
 with open('/proc/self/stat') as stream: fields=stream.read().rsplit(')',1)[1].split()
 with open(record) as stream: receipt=json.load(stream)
 receipt.update(pid=os.getpid(),pid_start=fields[19],agent_status='working',agent_session={'value':native})
 with open(record,'w') as stream: json.dump(receipt,stream)
 os.execv(node,[node,launcher,'--',binary,'--standalone','--auto','--session',native])
fcntl.ioctl(terminal,termios.TIOCSWINSZ,struct.pack('HHHH',42,140,0,0))
buffer=b'';status=None;seen=False;deadline=time.monotonic()+35
try:
 while time.monotonic()<deadline:
  ready,_,_=select.select([terminal],[],[],0.1)
  if ready:
   try: chunk=os.read(terminal,65536)
   except OSError as error:
    if error.errno==errno.EIO: break
    raise
   if not chunk: break
   buffer=(buffer+chunk)[-1048576:]
   if b'Local compatibility fixture.' in buffer:
    seen=True;os.write(terminal,b'\\x03');time.sleep(.2);os.write(terminal,b'\\x03')
  done,wait=os.waitpid(pid,os.WNOHANG)
  if done: status=wait;break
 if status is None:
  done,wait=os.waitpid(pid,os.WNOHANG)
  if done: status=wait
 if status is None:
  os.kill(pid,signal.SIGTERM)
  limit=time.monotonic()+6
  while time.monotonic()<limit:
   done,wait=os.waitpid(pid,os.WNOHANG)
   if done: status=wait;break
   time.sleep(.1)
 if status is None:
  os.kill(pid,signal.SIGKILL);_,status=os.waitpid(pid,0)
  raise RuntimeError('Owned guarded TUI needed forced shutdown')
 with open(output,'wb') as stream: stream.write(buffer)
 print(json.dumps({'nativeSession':native,'nativeHistoryRendered':seen,'ownedWrapperReaped':True,'waitStatus':status}))
 if not seen: sys.exit(1)
finally: os.close(terminal)
`, process.execPath, path.join(root, 'tools/opencode/launch.mjs'), bin, record, session.id, product, path.join(dir, `native-tui-${backend}.log`)], {
    cwd: product, env: { ...env, CEL_SESSION_BACKEND: backend, OPENCODE_CONFIG_CONTENT: JSON.stringify(buildConfig({ agent: 'cel-orchestrator', roleFile: role, pluginFile: pluginDirectory, modelID: model.id, transport: 'gateway', baseURL: config.providers['ompgw-codex'].settings.baseURL, route: '{env:CEL_SESSION_ID}', limit: { context: 500000, output: 128000 } })), CEL_OPENCODE_AGENT: 'cel-orchestrator', CEL_ROLE_FILE: role, TERM: 'xterm-256color' }, encoding: 'utf8', timeout: 50000,
  });
  await writeFile(path.join(dir, `native-tui-${backend}-result.json`), tuiProof.stdout ?? '');
  await writeFile(path.join(dir, `native-tui-${backend}-error.txt`), tuiProof.stderr ?? '');
  assert.equal(tuiProof.status, 0, 'Actual guarded wrapper did not render the retained native TUI history');
  const tuiResult = JSON.parse(tuiProof.stdout);
  assert.equal(tuiResult.nativeHistoryRendered, true);
  }
  for (const request of requests) {
    assert.equal(request.body.model, model.id); assert.equal(request.body.reasoning.effort, 'medium');
    assert.equal(request.headers['x-session-id'], env.CEL_SESSION_ID); assert.equal(request.headers.authorization, 'Bearer fixture-not-a-real-key');
  }
  assert.ok(requests.some(request => JSON.stringify(request.body).includes('Fixture role: retain exact Sol6.1/medium')), 'Scoped role did not reach real provider request');
  proof = { opencode: '2.2.5', nativeSession: session.id, nativeChildSession: nativeChild.id, provider: model.providerID, model: model.id, reasoning: 'medium', persistedModelVariant: 'medium', route: env.CEL_SESSION_ID, providerRequests: requests.length, localFixtureOnly: true, realCredentials: false, realRexReceiptUpdates: true, reporterAncestryEnforced: true, nativeInboxDelivery: true, realSharedGuard: true, guardMarkerAbsent: true, nativeChildLineage: true, nativeModelListConsumer: true, nativeExportStoreLookup: true, headlessRestartIdleInbox: true, resumeEvidenceKind: 'owned-receipt same-store guarded TUI resume plus headless idle restart', tuiResumeExecuted: true };
} catch (error) { failure = error; await diagnostics(error, 'original'); }
finally {
  try { await stopOwnedGroup(); } catch (error) { failure ??= error; await diagnostics(error, 'shutdown'); }
  if (fixture) { fixture.closeAllConnections(); await new Promise(resolve => fixture.close(resolve)); }
  if (!failure) await rm(dir, { recursive: true, force: true });
}
if (failure) throw failure;
console.log(JSON.stringify({ ...proof, ownedProcessGroupStopped: true, forcedGroupKill: killed }));
