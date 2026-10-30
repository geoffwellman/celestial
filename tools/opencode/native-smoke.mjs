// OWNER/PARENT-ONLY opt-in proof, never invoked by the ordinary test suite.
// Run inside an isolated network namespace with loopback enabled. A local
// Responses fixture emits deterministic SSE; no model inference or real key.
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { access, mkdtemp, mkdir, writeFile, readFile, readlink, readdir, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildConfig } from './config.mjs';

assert.equal(process.env.CEL_OPENCODE_ALLOW_NATIVE_SMOKE, '1', 'Parent must explicitly opt into this disposable native proof');
assert.notEqual(await readlink('/proc/self/ns/net'), await readlink('/proc/1/ns/net'), 'Refusing outside a separate network namespace: no non-loopback egress is permitted');
const bin = process.argv[2];
assert.ok(bin && path.isAbsolute(bin), 'Pass the exact installed OpenCode binary path');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const dir = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-native-'));
let child, fixture, childClosed, ownedStart, failure, proof, preCleanupResult, killed = false;
let log = '';
const requests = [];
const apiResponses = [];

async function groupMembers(pgid) {
  const members = [];
  for (const name of await readdir('/proc')) {
    if (!/^\d+$/.test(name)) continue;
    let text;
    try { text = await readFile(`/proc/${name}/stat`, 'utf8'); }
    catch (error) { if (error.code === 'ENOENT' || error.code === 'ESRCH') continue; throw error; }
    const fields = text.slice(text.lastIndexOf(')') + 2).trim().split(/\s+/);
    if (Number(name) === pgid && (!ownedStart || fields[19] !== ownedStart)) throw new Error(`Cannot prove disposable group ${pgid} still belongs to its original process; no group signal sent`);
    if (Number(fields[2]) === pgid && fields[0] !== 'Z' && fields[0] !== 'X') members.push(Number(name));
  }
  return members;
}
async function waitGroupEmpty(pgid, milliseconds) {
  const deadline = Date.now() + milliseconds;
  do {
    if (!(await groupMembers(pgid)).length) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  } while (Date.now() < deadline);
  return false;
}
function signalGroup(pgid, signal) {
  try { process.kill(-pgid, signal); }
  catch (error) { if (error.code !== 'ESRCH') throw error; }
}
async function stopOwnedGroup() {
  if (!child?.pid) return;
  // detached:true gives this exact disposable child its own group. First let
  // the server drain plugin disposal; then stop only its remaining group.
  if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  if (!(await waitGroupEmpty(child.pid, 3000))) {
    signalGroup(child.pid, 'SIGTERM');
    if (!(await waitGroupEmpty(child.pid, 3000))) {
      killed = true;
      signalGroup(child.pid, 'SIGKILL');
      if (!(await waitGroupEmpty(child.pid, 3000))) throw new Error(`Disposable process group ${child.pid} still has live members; retaining ${dir}`);
    }
  }
  let timer;
  try {
    await Promise.race([childClosed, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Disposable child stdio did not close after group shutdown')), 3000); })]);
  } finally { clearTimeout(timer); }
}
async function preserveFailure(error, phase) {
  console.error(`OpenCode native proof ${phase}: ${error?.stack ?? error}\nOwned artifacts retained at ${dir}`);
  try { await mkdir(dir, { recursive: true }); await writeFile(path.join(dir, `${phase}-error.txt`), String(error?.stack ?? error) + '\n'); }
  catch (writeError) { console.error(`Could not persist ${phase} error: ${writeError.message}`); }
}
async function preserveDiagnostics() {
  try {
    await mkdir(dir, { recursive: true });
    await writeFile(path.join(dir, 'server.log'), log);
    await writeFile(path.join(dir, 'fixture-requests.json'), JSON.stringify(requests, null, 2) + '\n');
    await writeFile(path.join(dir, 'api-responses.json'), JSON.stringify(apiResponses, null, 2) + '\n');
    await writeFile(path.join(dir, 'pre-cleanup-result.json'), JSON.stringify(preCleanupResult ?? null, null, 2) + '\n');
  } catch (error) { await preserveFailure(error, 'diagnostics'); }
}
try {
  const home = path.join(dir, 'home');
  const fakeRoot = path.join(dir, 'cel');
  await mkdir(path.join(fakeRoot, 'bin'), { recursive: true });
  await mkdir(path.join(dir, 'product'), { recursive: true });
  await mkdir(home, { recursive: true });
  await writeFile(path.join(fakeRoot, 'bin/cel'), '#!/bin/bash\nset -euo pipefail\ncase "$1 $2" in\n "inbox count") if [ -s "$CEL_SMOKE_MAIL" ]; then printf 1; else printf 0; fi;;\n "inbox read") cat "$CEL_SMOKE_MAIL"; rm -f "$CEL_SMOKE_MAIL";;\n "sessions note") CEL_ROOT="$CEL_SMOKE_REAL_ROOT" "$CEL_SMOKE_REAL_ROOT/bin/cel" "$@" 2>> "$CEL_SMOKE_REPORTER_LOG"; jq -c . "$CEL_REX_RECORD" >> "$CEL_SMOKE_NOTES";;\n *) exit 2;;\nesac\n', { mode: 0o700 });
  await mkdir(path.join(fakeRoot, 'tools/hooks'), { recursive: true });
  await writeFile(path.join(fakeRoot, 'tools/hooks/guard-classify.sh'), '#!/bin/bash\nset -euo pipefail\nverdict="$(CEL_ROOT="$CEL_SMOKE_REAL_ROOT" bash "$CEL_SMOKE_REAL_ROOT/tools/hooks/guard-classify.sh" "$@")"\nprintf "%s\\n" "$verdict" >> "$CEL_SMOKE_GUARD_LOG"\nprintf "%s\\n" "$verdict"\n', { mode: 0o700 });
  await writeFile(path.join(dir, 'workspace.yaml'), 'name: native-opencode-fixture\nmode: solo\nrepos: []\n');
  const probeBin = path.join(dir, 'probe-bin');
  await mkdir(probeBin);
  for (const name of ['gh', 'git']) await writeFile(path.join(probeBin, name), '#!/bin/bash\nprintf "unexpected owned probe command executed\\n" >&2\nexit 97\n', { mode: 0o700 });
  const marker = path.join(dir, 'guard-must-not-create');
  const shellQuote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
  // Solo policy permits pushes. Its real denied verb is gh pr merge; owned
  // executable stubs are safety backstops, never fake guard/protocol success.
  const guardCommand = `printf unexpected-execution > ${shellQuote(marker)}; ${shellQuote(path.join(probeBin, 'gh'))} pr merge 1; ${shellQuote(path.join(probeBin, 'git'))} push origin main`;
  let guardArmed = false, guardToolEmitted = false;
  fixture = http.createServer(async (req, res) => {
    let raw = ''; for await (const chunk of req) raw += chunk;
    if (req.url !== '/v1/responses' || req.method !== 'POST') { res.writeHead(500); res.end('unexpected fixture request'); return; }
    requests.push({ headers: req.headers, body: JSON.parse(raw) });
    const emitGuard = guardArmed && !guardToolEmitted;
    if (emitGuard) guardToolEmitted = true;
    const item = emitGuard
      ? { type: 'function_call', id: 'fc_guard', call_id: 'call_guard', name: 'bash', arguments: JSON.stringify({ command: guardCommand, description: 'Exercise real shared solo guard', timeout: 1000 }), status: 'completed' }
      : { type: 'message', id: 'msg_fixture', status: 'completed', role: 'assistant', content: [{ type: 'output_text', text: 'Local compatibility fixture.', annotations: [] }] };
    const response = { id: emitGuard ? 'resp_guard' : 'resp_fixture', object: 'response', created_at: 1, status: 'completed', model: 'gpt-6.1-sol', output: [item], usage: { input_tokens: 1, output_tokens: 2, total_tokens: 3, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } };
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
      { type: 'response.output_item.done', output_index: 0, item },
      { type: 'response.completed', response },
    ];
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const [sequence_number, event] of events.entries()) res.write(`event: ${event.type}\ndata: ${JSON.stringify({ ...event, sequence_number })}\n\n`);
    res.end();
  });
  fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
  const role = path.join(dir, 'role-orchestrator.md');
  await writeFile(role, 'Fixture role: retain exact Sol6.1/medium and native session identity.');
  const config = buildConfig({ agent: 'cel-orchestrator', roleFile: role, pluginFile: path.join(root, 'tools/hooks/celestial.opencode.mjs'), modelID: 'gpt-6.1-sol', transport: 'gateway', baseURL: `http://127.0.0.1:${fixture.address().port}/v1`, route: '{env:CEL_SESSION_ID}', limit: { context: 500000, output: 128000 } });
  config.autoupdate = false;
  config.share = 'disabled';
  config.permission = { bash: 'allow' };
  const rexState = path.join(dir, 'rex-state');
  await mkdir(rexState, { recursive: true });
  const record = path.join(rexState, 'fixture-opencode-orch.json');
  const notes = path.join(dir, 'accepted-receipts.jsonl');
  // Deliberately allowlist the environment: do not inherit ANY credential,
  // account config, plugin path, real workspace, or live mailbox identity.
  const env = { PATH: process.env.PATH, HOME: home, SHELL: '/bin/bash',
    XDG_CONFIG_HOME: path.join(dir, 'config'), XDG_DATA_HOME: path.join(dir, 'data'), XDG_CACHE_HOME: path.join(dir, 'cache'), XDG_STATE_HOME: path.join(dir, 'state'),
    OPENCODE_CONFIG_CONTENT: JSON.stringify(config), OPENCODE_DISABLE_MODELS_FETCH: '1', OPENCODE_DISABLE_AUTOUPDATE: '1', OPENCODE_DISABLE_DEFAULT_PLUGINS: '1',
    OPENCODE_DISABLE_LSP_DOWNLOAD: '1', OPENCODE_DISABLE_EXTERNAL_SKILLS: '1',
    npm_config_offline: 'true', CEL_ROOT: fakeRoot, CEL_SMOKE_REAL_ROOT: root, CEL_SESSION_BACKEND: 'rex', CEL_REX_RECORD: record, CEL_REX_STATE: rexState, CEL_ORCH_SESSIONS: path.join(dir, 'orch-sessions.json'), CEL_SMOKE_NOTES: notes, CEL_SMOKE_REPORTER_LOG: path.join(dir, 'reporter.log'), CEL_SMOKE_MAIL: path.join(dir, 'mail.jsonl'),
    CEL_SESSION_ID: 'fixture-original-account-route', OMP_GATEWAY_TOKEN: 'fixture-not-a-real-key', CEL_GUARD: '1', CEL_ROLE: 'solo', CEL_WORKSPACE: dir, CEL_AGENT_NAME: 'fixture-opencode-orch', CEL_SMOKE_GUARD_LOG: path.join(dir, 'guard.log') };
  assert.equal(execFileSync(bin, ['--version'], { env, encoding: 'utf8', timeout: 10000 }).trim(), '1.19.5');
  const helpResult = spawnSync(bin, ['--help'], { env, encoding: 'utf8', timeout: 10000 });
  assert.equal(helpResult.status, 0, 'Installed native CLI help failed');
  const nativeHelp = helpResult.stdout + helpResult.stderr;
  await writeFile(path.join(dir, 'native-help.txt'), nativeHelp);
  assert.match(nativeHelp, /(?:^|\s)--session(?:\s|,)/m, 'Installed native CLI does not advertise --session');
  async function startNativeServer(nativeID = '') {
    ownedStart = undefined;
    child = spawn(bin, ['serve', '--hostname', '127.0.0.1', '--port', '0'], { cwd: path.join(dir, 'product'), env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const server = child;
    childClosed = new Promise((resolve) => server.once('close', resolve));
    let startupLog = '';
    log += `\n[headless ${nativeID ? 'restart' : 'fresh'} pid=${server.pid}]\n`;
    const capture = (chunk) => { const text = chunk.toString(); startupLog += text; log += text; };
    server.stdout.on('data', capture); server.stderr.on('data', capture);
    server.on('error', (error) => { log += `\nChild process error: ${error.stack ?? error}\n`; });
    const stat = await readFile(`/proc/${server.pid}/stat`, 'utf8');
    const start = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[19];
    ownedStart = start;
    assert.equal(Number(stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[2]), server.pid, 'Disposable server must own its process group');
    assert.match(start, /^\d+$/);
    const receipt = { name: 'fixture-opencode-orch', agent: 'opencode', cwd: path.join(dir, 'product'), role: 'solo', workspace: dir, repo: 'fixture-opencode', pr: '', pane_id: 'rex/fixture-session/fixture-block', backend: 'rex', rex_session: 'fixture-session', rex_block: 'fixture-block', pid: server.pid, pid_start: start, agent_status: 'working', ...(nativeID ? { agent_session: { value: nativeID } } : {}) };
    await writeFile(record, JSON.stringify(receipt), { mode: 0o600 });
    const url = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`OpenCode native server did not become ready: ${startupLog}`)), 30000);
      const inspect = () => {
        const found = /http:\/\/127\.0\.0\.1:\d+/.exec(startupLog);
        if (found) { clearTimeout(timer); resolve(found[0]); }
      };
      server.stdout.on('data', inspect); server.stderr.on('data', inspect);
      inspect();
      server.once('error', (error) => { clearTimeout(timer); reject(error); });
      server.once('close', (code) => { clearTimeout(timer); reject(new Error(`OpenCode server closed ${code}: ${startupLog}`)); });
    });
    return { url, receipt };
  }
  const firstServer = await startNativeServer();
  let url = firstServer.url;
  const receipt = firstServer.receipt;
  const api = async (route, body) => {
    const response = await fetch(url + route, { method: body === undefined ? 'GET' : 'POST', headers: { 'content-type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(30000) });
    const text = await response.text();
    apiResponses.push({ route, status: response.status, text });
    assert.ok(response.ok, `${route}: ${response.status} ${text}`);
    return JSON.parse(text);
  };
  const loaded = await api('/config');
  assert.equal(loaded.agent['cel-orchestrator'].variant, 'medium');
  assert.match(loaded.agent['cel-orchestrator'].prompt, /Fixture role/);
  const session = await api('/session', { title: 'Disposable Celestial OpenCode compatibility fixture' });
  assert.match(session.id, /^ses_/);
  const result = await api(`/session/${session.id}/message`, { agent: 'cel-orchestrator', model: { providerID: 'ompgw-codex', modelID: 'gpt-6.1-sol' }, parts: [{ type: 'text', text: 'Return the deterministic local fixture response.' }] });
  assert.ok(result.info && result.parts, 'Expected actual native session message response');
  assert.ok(result.parts.some((part) => part.type === 'text' && part.text.includes('Local compatibility fixture.')));
  await writeFile(env.CEL_SMOKE_MAIL, JSON.stringify({ id: 'mail-native-smoke', from: 'root', kind: 'status', message: 'Prove native idle inbox delivery.' }) + '\n');
  let inboxDelivered = false, inboxCompleted = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    const messages = await api(`/session/${session.id}/message`);
    const inboxMessage = messages.find((message) => message.info.role === 'user' && message.parts.some((part) => part.type === 'text' && part.text.includes('[mail-native-smoke]')));
    inboxDelivered = Boolean(inboxMessage);
    inboxCompleted = Boolean(inboxMessage && messages.some((message) => message.info.role === 'assistant' && message.info.parentID === inboxMessage.info.id && message.info.time?.completed && message.parts.some((part) => part.type === 'text' && part.text.includes('Local compatibility fixture.'))));
    if (inboxCompleted) break;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  assert.ok(inboxDelivered, 'Native plugin did not deliver idle inbox mail through promptAsync');
  assert.ok(inboxCompleted, 'Native inbox-triggered turn did not settle through the loopback fixture');
  guardArmed = true;
  await api(`/session/${session.id}/message`, { agent: 'cel-orchestrator', model: { providerID: 'ompgw-codex', modelID: 'gpt-6.1-sol' }, parts: [{ type: 'text', text: 'Exercise the deterministic native shared-guard fixture.' }] });
  assert.equal(guardToolEmitted, true, 'Loopback fixture did not emit the native bash tool call');
  const guardMessages = await api(`/session/${session.id}/message`);
  const deniedTool = guardMessages.flatMap((message) => message.parts).find((part) => part.type === 'tool' && part.tool === 'bash' && part.state?.input?.command === guardCommand && part.state.status === 'error');
  assert.ok(deniedTool, 'Actual native tool-before did not reject the exact guard command');
  assert.match(deniedTool.state.error, /celestial guard:.*solo agent merges through/);
  assert.match(await readFile(env.CEL_SMOKE_GUARD_LOG, 'utf8'), /deny a solo agent merges through/);
  await assert.rejects(access(marker), { code: 'ENOENT' }, 'Denied native bash command created its marker before the refused verb');
  // TaskTool creates children with this native parentID contract. Exercise a
  // real child message in the same isolated server, not another live agent.
  const nativeChild = await api('/session', { parentID: session.id, title: 'Disposable native child lineage fixture' });
  assert.equal(nativeChild.parentID, session.id);
  const childResult = await api(`/session/${nativeChild.id}/message`, { agent: 'explore', model: { providerID: 'ompgw-codex', modelID: 'gpt-6.1-sol' }, parts: [{ type: 'text', text: 'Return the deterministic local native child fixture response.' }] });
  assert.ok(childResult.parts.some((part) => part.type === 'text' && part.text.includes('Local compatibility fixture.')), 'Same-model native child work was rejected');
  const childMessages = await api(`/session/${nativeChild.id}/message`);
  const childUsers = childMessages.filter((message) => message.info.role === 'user');
  assert.ok(childUsers.length > 0 && childUsers.every((message) => message.info.model.variant === 'medium'), 'Native child effort did not persist on model.variant');
  assert.ok(requests.length > 0, 'Native request did not reach the loopback fixture');
  for (const request of requests) {
    assert.equal(request.body.model, 'gpt-6.1-sol');
    assert.equal(request.body.reasoning.effort, 'medium');
    assert.equal(request.headers['x-session-id'], env.CEL_SESSION_ID);
    assert.equal(request.headers.authorization, 'Bearer fixture-not-a-real-key');
  }
  const messages = await api(`/session/${session.id}/message`);
  // 1.19.5 schema/src/v1/session.ts: User.model.variant; only Assistant has a
  // top-level variant. Keep a real persistence gate as well as wire-medium.
  const users = messages.filter((message) => message.info.role === 'user');
  assert.ok(users.length > 0 && users.every((message) => message.info.model.variant === 'medium'), 'Native user effort did not persist on model.variant');
  let finalReceipt;
  for (let attempt = 0; attempt < 100; attempt++) {
    finalReceipt = JSON.parse(await readFile(record, 'utf8'));
    if (finalReceipt.agent_session?.value === session.id && finalReceipt.agent_status === 'idle') break;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  assert.equal(finalReceipt.agent_session?.value, session.id);
  assert.equal(finalReceipt.agent_status, 'idle');
  // Read-only CLI store lookup in a separate native process, using the same
  // throwaway HOME/XDG storage. This is NOT an executed TUI resume claim.
  const requestsBeforeExport = requests.length;
  const exportRun = spawnSync(bin, ['export', session.id], { cwd: path.join(dir, 'product'), env, encoding: 'utf8', timeout: 30000, maxBuffer: 8 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  await writeFile(path.join(dir, 'native-export.json'), exportRun.stdout ?? '');
  await writeFile(path.join(dir, 'native-export.stderr.log'), exportRun.stderr ?? '');
  assert.ifError(exportRun.error);
  assert.equal(exportRun.status, 0, 'Actual native export CLI store lookup failed');
  const exported = JSON.parse(exportRun.stdout);
  assert.equal(exported.info.id, session.id, 'Native export resolved a different persisted session');
  assert.deepEqual(exported.messages.map((message) => message.info.id).sort(), messages.map((message) => message.info.id).sort(), 'Native CLI did not read the same persisted message IDs');
  const exportedUsers = exported.messages.filter((message) => message.info.role === 'user');
  assert.ok(exportedUsers.length > 0 && exportedUsers.every((message) => message.info.model.variant === 'medium' && message.info.model.providerID === 'ompgw-codex' && message.info.model.modelID === 'gpt-6.1-sol'), 'Actual native export lost persisted model/medium metadata');
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(requests.length, requestsBeforeExport, 'Read-only native export unexpectedly contacted the model fixture');
  const observed = (await readFile(notes, 'utf8')).trim().split('\n').map((line) => JSON.parse(line));
  const nativeNotes = observed.filter((row) => row.agent_session?.value === session.id);
  assert.ok(observed.every((row) => row.agent_session?.value === session.id), 'Native child work rebound the main Rex receipt');
  const workingIndex = nativeNotes.findIndex((row) => row.agent_status === 'working');
  assert.ok(workingIndex >= 0, 'Real Rex reporter did not accept native working state');
  assert.ok(nativeNotes.some((row, index) => index > workingIndex && row.agent_status === 'idle'), 'Real Rex reporter did not accept an idle transition after native working state');
  for (const row of nativeNotes) {
    assert.equal(row.pid, child.pid);
    assert.equal(row.pid_start, receipt.pid_start);
    assert.equal(row.cwd, receipt.cwd);
    assert.equal(row.name, receipt.name);
    assert.equal(row.agent, receipt.agent);
    assert.equal(row.role, receipt.role);
    assert.equal(row.workspace, receipt.workspace);
    assert.equal(row.pane_id, receipt.pane_id);
  }
  const registry = JSON.parse(await readFile(env.CEL_ORCH_SESSIONS, 'utf8'));
  assert.equal(registry[receipt.cwd], session.id, 'Real session reporter did not persist native continuity identity');
  const beforeUnrelatedReporter = await readFile(record, 'utf8');
  assert.throws(() => execFileSync(path.join(root, 'bin/cel'), ['sessions', 'note', String(child.pid), 'blocked', session.id], { env: { ...env, CEL_ROOT: root }, stdio: 'pipe' }), 'A sibling process must not be accepted as the runtime reporter');
  assert.equal(await readFile(record, 'utf8'), beforeUnrelatedReporter, 'Rejected sibling reporter mutated managed state');
  // This is a fresh headless server/plugin with the same native store and an
  // owned launch receipt carrying the existing ID. It is not TUI --session.
  await stopOwnedGroup();
  const restarted = await startNativeServer(session.id);
  url = restarted.url;
  await writeFile(env.CEL_SMOKE_MAIL, JSON.stringify({ id: 'mail-native-restart', from: 'root', kind: 'status', message: 'Wake the restored native session before any manual new prompt.' }) + '\n');
  const restored = await api(`/session/${session.id}`);
  assert.equal(restored.id, session.id);
  let restartMessage, restartCompleted = false, restoredMessages = [];
  for (let attempt = 0; attempt < 100; attempt++) {
    restoredMessages = await api(`/session/${session.id}/message`);
    restartMessage = restoredMessages.find((message) => message.info.role === 'user' && message.parts.some((part) => part.type === 'text' && part.text.includes('[mail-native-restart]')));
    restartCompleted = Boolean(restartMessage && restoredMessages.some((message) => message.info.role === 'assistant' && message.info.parentID === restartMessage.info.id && message.info.time?.completed && message.parts.some((part) => part.type === 'text' && part.text.includes('Local compatibility fixture.'))));
    if (restartCompleted) break;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  assert.ok(restartCompleted, 'New headless plugin failed to bootstrap idle inbox delivery on the existing native session');
  assert.equal(restartMessage.info.model.variant, 'medium');
  const restoredIDs = new Set(restoredMessages.map((message) => message.info.id));
  assert.ok(messages.every((message) => restoredIDs.has(message.info.id)), 'Headless restart did not preserve the prior native conversation');
  let restartedReceipt;
  for (let attempt = 0; attempt < 100; attempt++) {
    restartedReceipt = JSON.parse(await readFile(record, 'utf8'));
    if (restartedReceipt.agent_session?.value === session.id && restartedReceipt.agent_status === 'idle') break;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  assert.equal(restartedReceipt.pid, restarted.receipt.pid);
  assert.equal(restartedReceipt.pid_start, restarted.receipt.pid_start);
  assert.equal(restartedReceipt.agent_session?.value, session.id);
  assert.equal(restartedReceipt.agent_status, 'idle');
  const restartNotes = (await readFile(notes, 'utf8')).trim().split('\n').map((line) => JSON.parse(line)).filter((row) => row.pid === restarted.receipt.pid && row.pid_start === restarted.receipt.pid_start);
  assert.ok(restartNotes.length > 0 && restartNotes.every((row) => row.agent_session?.value === session.id), 'Headless bootstrap rebound a different native session');
  assert.ok(restartNotes.some((row) => row.agent_status === 'idle'), 'Resumed idle state was not observed by the real reporter');
  assert.ok(restartNotes.some((row) => row.agent_status === 'working'), 'Resumed inbox turn was not observed by the real reporter');
  for (const request of requests) {
    assert.equal(request.body.model, 'gpt-6.1-sol');
    assert.equal(request.body.reasoning.effort, 'medium');
    assert.equal(request.headers['x-session-id'], env.CEL_SESSION_ID);
    assert.equal(request.headers.authorization, 'Bearer fixture-not-a-real-key');
  }
  proof = { opencode: '1.19.5', nativeSession: session.id, nativeChildSession: nativeChild.id, provider: 'ompgw-codex', model: 'gpt-6.1-sol', reasoning: 'medium', persistedModelVariant: 'medium', route: 'fixture-original-account-route', providerRequests: requests.length, localFixtureOnly: true, realCredentials: false, realRexReceiptUpdates: true, reporterAncestryEnforced: true, nativeInboxDelivery: true, realSharedGuard: true, guardMarkerAbsent: true, nativeChildLineage: true, nativeExportStoreLookup: true, nativeSessionFlagAdvertised: true, headlessRestartIdleInbox: true, resumeEvidenceKind: 'owned-receipt headless restart', tuiResumeExecuted: false };
  preCleanupResult = { ok: true, result: proof };
} catch (error) {
  failure = error;
  preCleanupResult = { ok: false, error: String(error?.stack ?? error), argv: process.argv, node: process.execPath };
  // Preserve the actual protocol/assertion failure BEFORE teardown can fail.
  await preserveFailure(error, 'original');
  await preserveDiagnostics();
} finally {
  try { await stopOwnedGroup(); }
  catch (error) { failure ??= error; await preserveFailure(error, 'shutdown'); }
  try {
    if (fixture) { fixture.closeAllConnections(); await new Promise((resolve) => fixture.close(resolve)); }
  } catch (error) { failure ??= error; await preserveFailure(error, 'fixture-cleanup'); }
  if (failure) {
    await preserveDiagnostics();
  } else {
    try { await rm(dir, { recursive: true, force: true }); }
    catch (error) { failure = error; await preserveFailure(error, 'artifact-cleanup'); await preserveDiagnostics(); }
  }
}
if (failure) throw failure;
console.log(JSON.stringify({ ...proof, ownedProcessGroupStopped: true, forcedGroupKill: killed }));
