// Native 2.2.5 contracts: cli/src/services/standalone.ts, server-process.ts,
// services/server-connection.ts and protocol/src/groups/{plugin,migration,session}.ts.
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { chmod, mkdtemp, realpath, rename, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { validateConfig } from './config.mjs';
import { catalogModels, selectionAllowed, validateNativeInventory, DEFAULT_SELECTION } from './model-contract.mjs';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const pluginDirectory = fileURLToPath(new URL('./plugin', import.meta.url));
const exited = child => child.exitCode !== null || child.signalCode !== null;

// EVERY REFUSAL SAYS WHICH STEP REFUSED. Native and config errors may carry
// credentials or session content, so their text is never printed; what is
// printed is a code from this file's own fixed vocabulary - the step and how
// it failed. A bare "refused" cannot tell a launch that will fail again from
// one that a retry a minute later admits.
class Refusal extends Error {
  constructor(reason) { super(reason); this.reason = reason; }
}
const refuse = reason => { throw new Refusal(reason); };
// A step whose own errors are not ours to print refuses under one code.
const step = async (reason, work) => {
  try { return await work(); } catch (error) { throw error instanceof Refusal ? error : new Refusal(reason); }
};
// Anything this file did not anticipate is named by its class alone.
const refusalReason = error => error instanceof Refusal ? error.reason
  : `unexpected_${/^[A-Za-z]{1,40}$/.test(error?.name ?? '') ? error.name : 'error'}`;

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
  if (!await waitClosed(child, 1000)) refuse('child_did_not_close');
}

// EVERYTHING DECIDABLE BEFORE A NATIVE PROCESS EXISTS: the scoped config, the
// location and the argv. `launch` runs it first; `--check` runs only it, so a
// caller about to stop a live agent can prove its relaunch line is admissible
// (lib/rex.sh rex_launch_check) without starting anything.
export async function admit(binary, suppliedArgs, env = process.env) {
  const config = await step('config_unparseable', () => JSON.parse(env.OPENCODE_CONFIG_CONTENT ?? 'null'));
  const directory = await step('location_unreadable', () => realpath(process.cwd()));
  if (directory !== path.resolve(process.cwd())) refuse('location_alias');
  const agent = env.CEL_OPENCODE_AGENT;
  const roleFile = env.CEL_ROLE_FILE;
  const baseURL = config?.providers?.['ompgw-codex']?.settings?.baseURL;
  const { catalog, allowedModels } = await step('config_contract', () => {
    validateConfig(config, { agent, roleFile, pluginFile: pluginDirectory, baseURL });
    const scoped = config.plugins[0].options.catalog;
    return { catalog: scoped, allowedModels: catalogModels(scoped) };
  });
  if (!binary || binary.startsWith('-')) refuse('missing_executable');
  const args = [];
  let session;
  for (let i = 0; i < suppliedArgs.length; i++) {
    const arg = suppliedArgs[i];
    if (arg === '--standalone') continue;
    if (arg === '--auto') { args.push(arg); continue; }
    if (arg === '--session') {
      if (session !== undefined || !/^ses_[A-Za-z0-9]+$/.test(suppliedArgs[i + 1] ?? '')) refuse('session_argument');
      session = suppliedArgs[++i]; args.push(arg, session); continue;
    }
    if (arg === '--prompt') {
      if (typeof suppliedArgs[i + 1] !== 'string') refuse('prompt_argument');
      args.push(arg, suppliedArgs[++i]); continue;
    }
    // Do not let a caller select another server/model/agent or invoke a command
    // before the compatibility guard has been admitted.
    refuse('unsupported_argument');
  }
  return { directory, agent, catalog, allowedModels, args, session };
}

export async function launch(binary, suppliedArgs, env = process.env) {
  const { directory, agent, catalog, allowedModels, args, session } = await admit(binary, suppliedArgs, env);
  let selection = { ...DEFAULT_SELECTION };
  const privateDirectory = await step('private_directory', async () => {
    const created = await mkdtemp(path.join(os.tmpdir(), 'cel-opencode-launch-'));
    await chmod(created, 0o700);
    return created;
  });
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
    // What a deadline that runs out was waiting for.
    let waiting = 'server_not_ready';
    const live = () => {
      if (stopping) refuse('interrupted');
      if (serverError) refuse('server_spawn_failed');
      if (exited(server)) refuse('server_exited');
      if (invalid) refuse('server_readiness_invalid');
      if (Date.now() >= deadline) refuse(waiting);
    };
    while (readiness === undefined) { live(); await sleep(25); }
    live();
    waiting = 'admission_timeout';
    const endpoint = await step('private_endpoint', () => new URL(readiness.url));
    if (endpoint.protocol !== 'http:' || endpoint.hostname !== '127.0.0.1' || !endpoint.port || endpoint.username || endpoint.password || endpoint.pathname !== '/' || endpoint.search || endpoint.hash) refuse('private_endpoint');
    const headers = { authorization: `Basic ${Buffer.from(`opencode:${password}`).toString('base64')}` };
    // `name` is this file's name for the route, never the route itself: the
    // session route carries the native session ID.
    const get = async (name, route, location = false) => {
      live();
      const url = new URL(route, endpoint);
      if (location) url.searchParams.set('location[directory]', directory);
      let response;
      try {
        response = await fetch(url, { headers, redirect: 'error', signal: AbortSignal.timeout(Math.max(1, Math.min(2000, deadline - Date.now()))) });
      } catch (error) {
        refuse(`${name}_request_${error?.name === 'TimeoutError' ? 'timeout' : 'failed'}`);
      }
      if (!response.ok) refuse(`${name}_response_${response.status}`);
      const body = await step(`${name}_response_body`, () => response.json());
      live();
      return body;
    };
    const health = await get('info', '/api/info');
    if (health?.version !== '2.2.5' || health.pid !== server.pid) refuse('server_identity');
    waiting = 'guard_not_loaded';
    while (true) {
      const inventory = await get('plugin', '/api/plugin', true);
      if (inventory?.location?.directory !== directory || !Array.isArray(inventory.data)) refuse('plugin_location');
      const matching = inventory.data.filter(plugin => plugin?.id === 'celestial' || plugin?.source?.path === pluginDirectory);
      if (matching.length > 1) refuse('guard_ambiguous');
      if (matching.length === 1) {
        const plugin = matching[0];
        if (plugin.id !== 'celestial' || plugin.source?.type !== 'local' || plugin.source.path !== pluginDirectory || plugin.features?.server !== true || plugin.state?.status !== 'active') refuse('guard_inactive');
        break;
      }
      live(); await sleep(100);
    }
    waiting = 'admission_timeout';
    const migration = await get('migration', '/api/experimental/migration/v1');
    if (migration?.status !== 'completed') refuse('migration_incomplete');
    if (session !== undefined) {
      const native = (await get('session', `/api/session/${encodeURIComponent(session)}`))?.data;
      if (native?.id !== session || native.parentID !== undefined || native.agent !== agent
        || native.location?.directory !== directory || native.location.workspaceID !== undefined
        || !selectionAllowed(catalog, native.model)) refuse('session_identity');
      selection = { providerID: native.model.providerID, id: native.model.id,
        ...(native.model.variant === undefined ? {} : { variant: native.model.variant }) };
    }
    live();
    const handoff = { ...(session === undefined ? {} : { sessionID: session }), directory, agent,
      model: selection };
    const pendingAdmission = path.join(privateDirectory, 'pending');
    await step('admission_write', async () => {
      await writeFile(pendingAdmission, JSON.stringify(handoff) + '\n', { mode: 0o600, flag: 'wx' });
      await chmod(pendingAdmission, 0o600);
      await rename(pendingAdmission, admission);
    });
    // The plugin observes admission after setup; wait for its provider/model
    // reload rather than attaching a TUI to a still-disabled model snapshot.
    deadline = Date.now() + 15000;
    waiting = 'models_not_admitted';
    while (true) {
      const models = await get('model', '/api/model', true);
      if (models?.location?.directory !== directory || !Array.isArray(models.data)) refuse('model_location');
      if (models.data.some(model => !allowedModels.has(`${model?.providerID}/${model?.id}`))
        || new Set(models.data.map(model => `${model.providerID}/${model.id}`)).size !== models.data.length) refuse('model_unscoped');
      if (models.data.length === allowedModels.size) {
        await step('model_contract', () => validateNativeInventory(models.data, catalog));
        break;
      }
      live(); await sleep(100);
    }
    live();
    tui = own(spawn(binary, [...args, '--server', endpoint.href], { cwd: directory, env: childEnv, stdio: 'inherit' }));
    const serverLost = () => { if (!stopping) tui?.kill('SIGTERM'); };
    server.once('close', serverLost);
    const result = await new Promise((resolve, reject) => {
      tui.once('error', () => reject(new Refusal('tui_spawn_failed')));
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
    const check = process.argv[2] === '--check';
    const [separator, binary, ...rest] = process.argv.slice(check ? 3 : 2);
    if (separator !== '--') refuse('launch_arguments');
    if (check) { await admit(binary, rest); process.exitCode = 0; }
    else process.exitCode = await launch(binary, rest);
  } catch (error) {
    // Only this file's reason code is printed: native/config error text may
    // contain credentials or session content.
    console.error(`OpenCode guarded private launch refused (reason=${refusalReason(error)}); no unguarded TUI was admitted`);
    process.exitCode = 1;
  }
}
