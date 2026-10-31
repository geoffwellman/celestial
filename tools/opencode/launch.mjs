// Native 2.2.5 contracts: cli/src/services/standalone.ts, server-process.ts,
// services/server-connection.ts and protocol/src/groups/{plugin,migration,session}.ts.
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { chmod, mkdtemp, realpath, rename, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { validateConfig } from './config.mjs';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const pluginDirectory = fileURLToPath(new URL('./plugin', import.meta.url));
const exited = child => child.exitCode !== null || child.signalCode !== null;

const closures = new WeakMap();
function own(child) {
  const state = { closed: false };
  child.once('close', () => { state.closed = true; });
  closures.set(child, state);
  return child;
}

async function waitClosed(child, milliseconds) {
  const deadline = Date.now() + milliseconds;
  while (!closures.get(child).closed && Date.now() < deadline) await sleep(25);
  return closures.get(child).closed;
}

async function stop(child, lease = false) {
  if (!child || closures.get(child).closed) return;
  // Native stdio EOF is the ownership lease, not a hint followed immediately
  // by a signal. Allow its finalizers to finish before bounded escalation.
  if (lease) {
    child.stdin.end();
    if (await waitClosed(child, 1000)) return;
  }
  if (!exited(child)) child.kill('SIGTERM');
  if (await waitClosed(child, 2000)) return;
  if (!exited(child)) child.kill('SIGKILL');
  if (!await waitClosed(child, 1000)) throw new Error('owned native child did not close');
}

export async function launch(binary, suppliedArgs, env = process.env) {
  const config = JSON.parse(env.OPENCODE_CONFIG_CONTENT ?? 'null');
  const directory = await realpath(process.cwd());
  if (directory !== path.resolve(process.cwd())) throw new Error('location alias');
  const agent = env.CEL_OPENCODE_AGENT;
  const roleFile = env.CEL_ROLE_FILE;
  const baseURL = config?.providers?.['ompgw-codex']?.settings?.baseURL;
  validateConfig(config, { agent, roleFile, pluginFile: pluginDirectory, baseURL });
  if (!binary || binary.startsWith('-')) throw new Error('missing executable');
  const args = [];
  let session;
  for (let i = 0; i < suppliedArgs.length; i++) {
    const arg = suppliedArgs[i];
    if (arg === '--standalone') continue;
    if (arg === '--auto') { args.push(arg); continue; }
    if (arg === '--session') {
      if (session !== undefined || !/^ses_[A-Za-z0-9]+$/.test(suppliedArgs[i + 1] ?? '')) throw new Error('native session');
      session = suppliedArgs[++i]; args.push(arg, session); continue;
    }
    if (arg === '--prompt') {
      if (typeof suppliedArgs[i + 1] !== 'string') throw new Error('prompt');
      args.push(arg, suppliedArgs[++i]); continue;
    }
    // Do not let a caller select another server/model/agent or invoke a command
    // before the compatibility guard has been admitted.
    throw new Error('unsupported native launch argument');
  }
  const privateDirectory = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-launch-'));
  await chmod(privateDirectory, 0o700);
  const admission = path.join(privateDirectory, 'admitted');
  const password = randomBytes(32).toString('base64url');
  const childEnv = { ...env, OPENCODE_PASSWORD: password, CEL_OPENCODE_ADMISSION_FILE: admission };
  delete childEnv.OPENCODE_SERVER_PASSWORD;
  let server, tui, stopping = false;
  const interrupted = () => { stopping = true; tui?.kill('SIGTERM'); server?.stdin?.end(); };
  process.on('SIGTERM', interrupted);
  process.on('SIGINT', interrupted);
  try {
    server = own(spawn(binary, ['serve', '--stdio', '--hostname', '127.0.0.1', '--port', '0'], {
      cwd: directory, env: childEnv, stdio: ['pipe', 'pipe', 'ignore'],
    }));
    let serverError;
    server.on('error', error => { serverError = error; });
    server.stdin.on('error', () => {});
    let line = '', readiness, invalid = false;
    server.stdout.setEncoding('utf8');
    // Keep draining after readiness; never forward native logs or credentials.
    server.stdout.on('data', chunk => {
      if (readiness !== undefined || invalid) return;
      line += chunk;
      if (line.length > 8192) { invalid = true; return; }
      const end = line.indexOf('\n');
      if (end !== -1) {
        try { readiness = JSON.parse(line.slice(0, end)); } catch { invalid = true; }
      }
    });
    let deadline = Date.now() + 15000;
    const live = () => {
      if (stopping || serverError || exited(server) || invalid || Date.now() >= deadline) throw new Error('private server admission');
    };
    while (readiness === undefined) { live(); await sleep(25); }
    live();
    const endpoint = new URL(readiness.url);
    if (endpoint.protocol !== 'http:' || endpoint.hostname !== '127.0.0.1' || !endpoint.port || endpoint.username || endpoint.password || endpoint.pathname !== '/' || endpoint.search || endpoint.hash) throw new Error('private endpoint');
    const headers = { authorization: `Basic ${Buffer.from(`opencode:${password}`).toString('base64')}` };
    const get = async (route, location = false) => {
      live();
      const url = new URL(route, endpoint);
      if (location) url.searchParams.set('location[directory]', directory);
      const response = await fetch(url, { headers, redirect: 'error', signal: AbortSignal.timeout(Math.max(1, Math.min(2000, deadline - Date.now()))) });
      if (!response.ok) throw new Error('native admission response');
      const body = await response.json();
      live();
      return body;
    };
    const health = await get('/api/info');
    if (health.version !== '2.2.5' || health.pid !== server.pid) throw new Error('native server identity');
    while (true) {
      const inventory = await get('/api/plugin', true);
      if (inventory.location?.directory !== directory || !Array.isArray(inventory.data)) throw new Error('native inventory location');
      const matching = inventory.data.filter(plugin => plugin.id === 'celestial' || plugin.source?.path === pluginDirectory);
      if (matching.length > 1) throw new Error('ambiguous native guard');
      if (matching.length === 1) {
        const plugin = matching[0];
        if (plugin.id !== 'celestial' || plugin.source?.type !== 'local' || plugin.source.path !== pluginDirectory || plugin.features?.server !== true || plugin.state?.status !== 'active') throw new Error('inactive native guard');
        break;
      }
      live(); await sleep(100);
    }
    const migration = await get('/api/experimental/migration/v1');
    if (migration.status !== 'completed') throw new Error('native migration incomplete');
    if (session !== undefined) {
      const native = (await get(`/api/session/${encodeURIComponent(session)}`)).data;
      if (native?.id !== session || native.parentID !== undefined || native.agent !== agent || native.location?.directory !== directory || native.model?.providerID !== 'ompgw-codex' || native.model?.id !== 'gpt-6.1-sol' || native.model?.variant !== 'medium') throw new Error('native resume identity');
    }
    live();
    const handoff = { ...(session === undefined ? {} : { sessionID: session }), directory, agent,
      model: { providerID: 'ompgw-codex', id: 'gpt-6.1-sol', variant: 'medium' } };
    const pendingAdmission = path.join(privateDirectory, 'pending');
    await writeFile(pendingAdmission, JSON.stringify(handoff) + '\n', { mode: 0o600, flag: 'wx' });
    await chmod(pendingAdmission, 0o600);
    await rename(pendingAdmission, admission);
    // The plugin observes admission after setup; wait for its provider/model
    // reload rather than attaching a TUI to a still-disabled model snapshot.
    deadline = Date.now() + 15000;
    while (true) {
      const models = await get('/api/model', true);
      if (models.location?.directory !== directory || !Array.isArray(models.data)) throw new Error('native model location');
      if (models.data.some(model => model.providerID !== 'ompgw-codex' || model.id !== 'gpt-6.1-sol')) throw new Error('unscoped native model');
      if (models.data.length > 1) throw new Error('ambiguous native model');
      if (models.data.length === 1) {
        const model = models.data[0];
        if (model.enabled !== true || model.settings?.reasoningEffort !== 'medium' || model.variants?.length !== 1 || model.variants[0].id !== 'medium' || model.variants[0].settings?.reasoningEffort !== 'medium') throw new Error('native model settings');
        break;
      }
      live(); await sleep(100);
    }
    live();
    tui = own(spawn(binary, [...args, '--server', endpoint.href], { cwd: directory, env: childEnv, stdio: 'inherit' }));
    const serverLost = () => { if (!stopping) tui?.kill('SIGTERM'); };
    server.once('close', serverLost);
    const result = await new Promise((resolve, reject) => {
      tui.once('error', reject);
      tui.once('close', (code, signal) => resolve(signal ? 1 : code ?? 1));
    });
    server.off('close', serverLost);
    return stopping ? 1 : result;
  } finally {
    stopping = true;
    let cleanupError;
    try { await stop(tui); } catch (error) { cleanupError = error; }
    try { await stop(server, true); } catch (error) { cleanupError ??= error; }
    await rm(privateDirectory, { recursive: true, force: true });
    process.off('SIGTERM', interrupted);
    process.off('SIGINT', interrupted);
    if (cleanupError) throw cleanupError;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv[2] !== '--') throw new Error('launch arguments');
    process.exitCode = await launch(process.argv[3], process.argv.slice(4));
  } catch {
    // Native/config errors may contain credentials or session content.
    console.error('OpenCode guarded private launch refused; no unguarded TUI was admitted');
    process.exitCode = 1;
  }
}
