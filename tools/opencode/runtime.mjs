import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, open } from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { catalogModels, allowsSelection, nativeModel } from './model-contract.mjs';
const execute = promisify(execFile);

// OpenCode 2.2.5 Promise plugin API. All registrations and availability edits
// belong to this location; no global config, credentials or fetch is replaced.
export async function createPlugin(context, deps = {}) {
  const { location, options } = context;
  const directory = location?.directory;
  const env = deps.env ?? process.env;
  const run = deps.run ?? (async (bin, args) => (await execute(bin, args, {
    cwd: directory, env, timeout: 15000, maxBuffer: 4 * 1024 * 1024,
  })).stdout);
  const clock = deps.clock ?? { setInterval, clearInterval };
  const root = env.CEL_ROOT;
  if (!root || !path.isAbsolute(directory ?? '') || !options?.agent || options.transport !== 'gateway'
      || options.modelID !== 'gpt-6.1-sol' || options.providerID !== 'ompgw-codex') {
    throw new Error('Celestial OpenCode requires a scoped role and explicit Sol6.1 account route');
  }
  const cel = path.join(root, 'bin/cel');
  const model = { providerID: options.providerID, id: options.modelID, variant: 'medium' };
  const allowedModels = catalogModels(options.catalog);
  const allowedProviders = new Set([...allowedModels.values()].map(row => row.providerID));
  const nativeModels = new Map([...allowedModels].map(([key, row]) => [key, nativeModel(row)]));
  const registrations = [];
  const polls = new Set();
  const callbacks = new Set();
  const events = new AbortController();
  let sessionID, disposed = false, delivering = false, pending = '', generation = 0;
  let busyEvent = false, notes = Promise.resolve(), resumeCandidate = '', resumeSelection, resumeError, resumeLookup;
  let refusalNoted = false, observer, admissionRefresh;
  const admissionFile = env.CEL_OPENCODE_ADMISSION_FILE;
  let launchAdmitted = admissionFile === undefined;
  if (admissionFile !== undefined && !path.isAbsolute(admissionFile)) throw new Error('OpenCode launch admission path must be absolute');
  const wsArgs = [];
  if (env.CEL_INBOX_ME && env.CEL_INBOX_ALL_WS !== '0') wsArgs.push('--all-workspaces');
  if (env.CEL_INBOX_WS) wsArgs.push('--workspace', env.CEL_INBOX_WS);
  if (env.CEL_INBOX_ME) wsArgs.push('--for', env.CEL_INBOX_ME);

  function register(domain, name, callback, scope) {
    return domain.hook(name, (event) => {
      if (disposed) return;
      const task = Promise.resolve().then(() => { if (!disposed) return callback(event); });
      callbacks.add(task);
      task.then(() => callbacks.delete(task), () => callbacks.delete(task));
      return task;
    }, scope);
  }

  // A server subprocess may report only for its exact Rex PID or a proven
  // ancestor, with matching birth time. A receipt path alone proves nothing.
  async function ownedReceipt() {
    if (env.CEL_SESSION_BACKEND !== 'rex' || !env.CEL_REX_RECORD) return null;
    const record = JSON.parse(await readFile(env.CEL_REX_RECORD, 'utf8'));
    if (record.agent !== 'opencode' || record.backend !== 'rex' || !record.name
        || !Number.isSafeInteger(record.pid) || record.pid <= 1
        || typeof record.pid_start !== 'string' || !/^\d+$/.test(record.pid_start)
        || typeof record.cwd !== 'string' || path.resolve(record.cwd) !== path.resolve(directory)
        || (env.CEL_AGENT_NAME && record.name !== env.CEL_AGENT_NAME)) throw new Error('OpenCode Rex receipt identity is not owned');
    const stat = await readFile(`/proc/${record.pid}/stat`, 'utf8');
    if (stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[19] !== record.pid_start) throw new Error('OpenCode Rex receipt PID was reused');
    let pid = process.pid;
    for (let depth = 0; pid > 1 && depth < 64; depth++) {
      if (pid === record.pid) return record;
      const status = await readFile(`/proc/${pid}/status`, 'utf8');
      pid = Number(/^PPid:\s+(\d+)$/m.exec(status)?.[1] ?? 0);
    }
    throw new Error('OpenCode Rex reporter is not a descendant of the owned runtime');
  }
  function note(next) {
    if (disposed) return notes;
    const native = sessionID ?? '';
    notes = notes.then(async () => {
      try {
        const record = await ownedReceipt();
        if (record) await run(cel, ['sessions', 'note', String(record.pid), next, native]);
      } catch { /* failed observation is not evidence of a native state */ }
    });
    return notes;
  }
  function assertModel(actual, exactVariant = false) {
    if (!allowsSelection(allowedModels, actual)
        || !options.catalog && exactVariant && actual.variant !== 'medium') {
      throw new Error('Celestial scoped catalog refuses provider/model/variant fallback; pinned roles retain medium');
    }
  }
  function assertLocation(actual) {
    if (!actual || typeof actual.directory !== 'string' || path.resolve(actual.directory) !== path.resolve(directory)
        || (actual.workspaceID ?? undefined) !== (location.workspaceID ?? undefined)) {
      throw new Error('Cannot prove the exact native session location');
    }
  }
  function assertRoot(native) {
    if (native.parentID || native.agent !== options.agent) throw new Error('Celestial OpenCode root role/session mismatch');
    assertLocation(native.location);
    assertModel(native.model, true);
  }
  async function nativeSession(id) {
    let native;
    try { native = await context.session.get({ sessionID: id }); }
    catch (error) { throw new Error('Cannot prove native session ancestry', { cause: error }); }
    if (!native || native.id !== id) throw new Error('Cannot prove native session ancestry');
    assertLocation(native.location);
    assertModel(native.model, true);
    return native;
  }
  // Filesystem proof is safe during setup. Native session APIs are deferred to
  // callbacks/timers after setup; calling them here reenters InstanceStore.
  try {
    const record = await ownedReceipt();
    if (record?.agent_session !== undefined) {
      const candidate = record.agent_session?.value;
      if (typeof candidate !== 'string' || !/^ses_[A-Za-z0-9]+$/.test(candidate)) throw new Error('Invalid native OpenCode resume identity');
      resumeCandidate = candidate;
    }
  } catch (error) {
    resumeError = new Error('OpenCode native resume refused: cannot prove the owned Rex receipt', { cause: error });
  }
  // OpenCode evicts an idle location and re-boots it on the next request, so a
  // fresh instance can see a request or idle hook before its first observer
  // tick. Every admission consumer awaits this one in-flight proof. Request
  // hooks run inside the already-booted location, so the filesystem proof and
  // provider/model reload (invalidate + notify, no session lookup) cannot
  // reenter InstanceStore the way setup-time native calls would.
  async function refreshLaunchAdmission() {
    if (launchAdmitted) return true;
    admissionRefresh ??= proveLaunchAdmission().finally(() => { admissionRefresh = undefined; });
    return admissionRefresh;
  }
  async function proveLaunchAdmission() {
    let parent, file, handoff;
    try {
      // Open the owned private directory first, then its leaf through that FD.
      // Neither the handoff nor its immediate parent may be a symlink; FD
      // anchoring prevents a pathname swap between ownership proof and read.
      parent = await open(path.dirname(admissionFile), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
      const dirStat = await parent.stat();
      if (!dirStat.isDirectory() || dirStat.uid !== process.getuid() || (dirStat.mode & 0o777) !== 0o700) return false;
      file = await open(`/proc/self/fd/${parent.fd}/${path.basename(admissionFile)}`, constants.O_RDONLY | constants.O_NOFOLLOW);
      const stat = await file.stat();
      if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o600 || stat.nlink !== 1 || stat.size > 4096) return false;
      handoff = JSON.parse(await file.readFile('utf8'));
      if (!handoff || handoff.directory !== directory || handoff.agent !== options.agent || location.workspaceID !== undefined) return false;
      assertModel(handoff.model, true);
      if (handoff.sessionID !== undefined && (typeof handoff.sessionID !== 'string' || !/^ses_[A-Za-z0-9]+$/.test(handoff.sessionID))) return false;
      // Rex resumes require both its owned PID/birth receipt and this launcher
      // proof. Herdr has no Rex receipt, so only the private verified handoff
      // may nominate the candidate; a later native lookup must still prove it.
      if (resumeCandidate && handoff.sessionID !== resumeCandidate
          || env.CEL_SESSION_BACKEND === 'rex' && (handoff.sessionID ?? '') !== resumeCandidate
          || sessionID && handoff.sessionID && sessionID !== handoff.sessionID) return false;
    } catch { return false; }
    finally { await file?.close(); await parent?.close(); }
    if (disposed) return false;
    if (handoff.sessionID) resumeCandidate = handoff.sessionID;
    if (handoff.sessionID) resumeSelection = handoff.model;
    launchAdmitted = true;
    try {
      await context.provider.reload();
      await context.model.reload();
    } catch (error) { launchAdmitted = false; throw error; }
    return !disposed;
  }
  async function bootstrapResume() {
    if (!await refreshLaunchAdmission()) throw new Error('OpenCode canonical launch admission is pending');
    if (resumeError) {
      if (!refusalNoted) { refusalNoted = true; await note('blocked'); }
      throw resumeError;
    }
    if (!resumeCandidate || sessionID) return;
    if (!resumeLookup) resumeLookup = (async () => {
      try {
        const native = await nativeSession(resumeCandidate);
        if (resumeSelection && !isDeepStrictEqual(native.model, resumeSelection)) throw new Error('Native resume selection differs from the private launch proof');
        assertRoot(native);
        if (!disposed) {
          sessionID = resumeCandidate;
          // Pending resume keeps the native provider unavailable. Rebuild the
          // scoped inventory only after the exact owned root is proven.
          await context.provider.reload();
          await context.model.reload();
        }
      } catch (error) {
        resumeError = new Error('OpenCode native resume refused: candidate does not match the owned root', { cause: error });
        refusalNoted = true;
        await note('blocked');
        throw resumeError;
      }
    })();
    await resumeLookup;
  }
  async function admitSession(id) {
    await bootstrapResume();
    if (disposed || !sessionID || typeof id !== 'string') throw new Error('Celestial OpenCode root is not bound');
    const seen = new Set();
    let current = id;
    for (let depth = 0; depth < 64; depth++) {
      if (seen.has(current)) throw new Error('Cannot prove native session ancestry: cycle');
      seen.add(current);
      const native = await nativeSession(current);
      if (current === sessionID) { assertRoot(native); return id === sessionID; }
      if (!native.parentID) throw new Error('This scoped OpenCode process does not admit unrelated roots');
      current = native.parentID;
    }
    throw new Error('Cannot prove native session ancestry: depth exceeded');
  }
  function available() {
    return !disposed && launchAdmitted && !resumeError && (!resumeCandidate || Boolean(sessionID))
      && Boolean(options.route?.trim() && env.OMP_GATEWAY_TOKEN?.trim());
  }
  async function admitRequest(event) {
    // Herdr nominates its root only through the private handoff, so the proof
    // must run before deciding whether a resume is pending.
    await refreshLaunchAdmission();
    if (resumeError || resumeCandidate && !sessionID) await bootstrapResume();
    if (!available()) throw new Error('Scoped gateway auth/route is absent or resume refused; no provider fallback');
    assertModel(event.model);
    await admitSession(event.sessionID);
  }
  async function classify(mode, arg) {
    if (env.CEL_GUARD === '0') return;
    if (typeof arg !== 'string' || !arg.trim()) throw new Error(`celestial guard: cannot classify ${mode}`);
    if (mode === 'command' && /^CEL_GUARD_ALLOW_ONCE=1(?:\s|$)/.test(arg)) return;
    if (mode === 'path') arg = path.resolve(directory, arg);
    let verdict;
    // Exit 2 is the classifier reporting its own error (bad mode or policy).
    // It used to print `allow` instead, so allow here keeps OpenCode's behaviour
    // until the owner picks one fail-open/closed policy; any other failure of the
    // classifier itself still refuses.
    try { verdict = (await run('bash', [path.join(root, 'tools/hooks/guard-classify.sh'), mode, directory, arg])).trim(); }
    catch (error) { if (error?.code === 2) return; throw error; }
    if (verdict.startsWith('deny')) throw new Error(`celestial guard: ${verdict.slice(4).trim()}`);
  }
  // A MAILBOX THAT DOES NOT PARSE is said once per file in this session: its
  // mail is unknown, and saying so every idle tick would wake the agent forever.
  const corruptSaid = new Set();
  function corruptNotice(ws, file) {
    if (corruptSaid.has(file)) return '';
    corruptSaid.add(file);
    return `${ws}celestial inbox: mailbox ${file} is corrupt (a line does not parse) - its mail is unknown, not empty, and nothing was marked read. Tell the owner.`;
  }
  async function deliver() {
    if (disposed || delivering || !sessionID || !available()) return;
    delivering = true;
    const observed = generation;
    try {
      if (!pending) {
        // A count that FAILS (a corrupt mailbox exits 1 with only a floor on
        // stdout) is unknown, not empty: read anyway, and the read says why.
        let count = NaN;
        try { count = Number((await run(cel, ['inbox', 'count', ...wsArgs])).trim()); } catch { /* unknown */ }
        if (disposed || observed !== generation || (Number.isFinite(count) && !(count > 0))) return;
        let raw;
        try { raw = await run(cel, ['inbox', 'read', '--json', ...wsArgs]); }
        catch (error) {
          // A corrupt mailbox fails the read with its {state: corrupt} report
          // on stdout: an answer to deliver (once per file), not a failure.
          raw = String(error?.stdout ?? '');
          if (!/"state":"corrupt"/.test(raw)) throw error;
        }
        // Store the drained bytes before parsing. A malformed record or a
        // refused/ambiguous native admission must not lose or re-drain debt.
        pending = raw.trim();
        if (pending) {
          try {
            pending = pending.split('\n').map((line) => {
              const match = /^(\[[^\]]+\] )?(\{.*\})$/.exec(line.trim());
              if (!match) return line;
              const item = JSON.parse(match[2]);
              if (!item.id && item.state === 'corrupt') return corruptNotice(match[1] ?? '', String(item.file ?? ''));
              return item.id ? `[${item.id}] ${match[1] ?? ''}${item.kind} from ${item.from}: ${item.message}` : line;
            }).filter(Boolean).join('\n');
          } catch { /* the original drained payload remains owed */ }
        }
      }
      if (!pending || disposed || observed !== generation) return;
      const result = await context.session.synthetic({ sessionID, delivery: 'steer', text:
        `New messages in your celestial inbox (delivered by the native session API):\n${pending}\nAct on them, or say why not.` });
      if (!result || typeof result.id !== 'string') throw new Error('OpenCode did not acknowledge synthetic inbox admission');
      pending = '';
      if (!disposed) { busyEvent = true; generation++; await note('working'); }
    } catch { /* preserve drained mail; a failure is not proof that native work is idle */ }
    finally { delivering = false; }
  }
  async function tick() {
    if (disposed || delivering) return;
    try {
      if (!await refreshLaunchAdmission()) return;
      await bootstrapResume();
      if (disposed || !sessionID) return;
      const observed = generation;
      const native = await nativeSession(sessionID);
      assertRoot(native);
      if (disposed || observed !== generation) return;
      // The Promise adapter encodes DateTimeUtcFromMillis back to finite epoch
      // numbers. No idle watermark, strings or missing status are NOT idle.
      const { busy, idle } = native.time ?? {};
      const idleProof = Number.isFinite(idle) && (busy === undefined || Number.isFinite(busy) && idle >= busy);
      const busyProof = Number.isFinite(busy) && (!Number.isFinite(idle) || busy > idle);
      if (idleProof && !busyEvent) {
        await note('idle');
        if (!disposed && observed === generation && !busyEvent) await deliver();
      } else if (busyProof || busyEvent) await note('working');
    } catch { /* unresolved native state never permits draining */ }
  }
  function poll() {
    if (disposed) return Promise.resolve();
    if (observer) return observer;
    observer = tick().finally(() => { polls.delete(observer); observer = undefined; });
    polls.add(observer);
    return observer;
  }
  async function onEvent(event) {
    if (disposed) return;
    const p = event.data;
    if (event.type === 'session.created' && !p.parentID) {
      // The first created root alone may bind. Resume and later roots cannot
      // replace it, including an unrelated root whose idle event arrives first.
      if (resumeCandidate || resumeError || sessionID) return;
      if (!launchAdmitted) return;
      try {
        if (typeof p.sessionID !== 'string' || !/^ses_[A-Za-z0-9]+$/.test(p.sessionID)) throw new Error('Invalid native root identity');
        assertRoot(p);
        sessionID = p.sessionID;
      } catch (error) { resumeError = error; await note('blocked'); }
      return;
    }
    if (!sessionID || p?.sessionID !== sessionID) return;
    if (event.type === 'session.status') {
      generation++;
      busyEvent = p.status?.type !== 'idle';
      if (p.status?.type === 'idle' || ['busy', 'retry'].includes(p.status?.type)) await note(busyEvent ? 'working' : 'idle');
    } else if (event.type === 'session.execution.started') {
      busyEvent = true; generation++; await note('working');
    } else if (['session.execution.succeeded', 'session.execution.failed', 'session.execution.interrupted'].includes(event.type)) {
      busyEvent = false; generation++;
      if (event.type === 'session.execution.failed') await note('blocked');
    } else if (['session.deleted', 'session.moved'].includes(event.type)) {
      busyEvent = true; generation++;
    } else if (['session.agent.selected', 'session.model.selected'].includes(event.type)) {
      // A selection may arrive on an idle root with no later status, execution
      // or idle event. Fence in-flight observations, but leave busy/idle to
      // native time.busy/time.idle so queued mail still drains on the next poll.
      generation++;
    }
  }
  let timer, eventTask, closing;
  function cleanup() {
    if (closing) return closing;
    disposed = true;
    if (timer !== undefined) clock.clearInterval(timer);
    events.abort();
    closing = (async () => {
      await Promise.allSettled(registrations.map((registration) => registration.dispose()));
      await Promise.allSettled([...callbacks, ...polls, ...(eventTask ? [eventTask] : []), ...(resumeLookup ? [resumeLookup] : []),
        ...(admissionRefresh ? [admissionRefresh] : [])]);
      await notes;
    })();
    return closing;
  }
  try {
    registrations.push(await context.provider.transform((editor) => {
      for (const record of editor.list()) {
        if (!allowedProviders.has(record.provider.id) || !available()) editor.remove(record.provider.id);
      }
    }));
    registrations.push(await context.model.transform((editor) => {
      for (const candidate of editor.list()) {
        if (!allowedModels.has(`${candidate.providerID}/${candidate.id}`) || !available()) editor.remove(candidate.providerID, candidate.id);
      }
      if (!available()) return;
      for (const [key, spec] of nativeModels) {
        const [providerID, modelID] = key.split('/');
        if (!editor.get(providerID, modelID)) continue;
        editor.update(providerID, modelID, candidate => {
          candidate.enabled = true;
          candidate.settings = { ...candidate.settings, ...structuredClone(spec.settings ?? {}) };
          const previous = candidate.variants ?? [];
          candidate.variants = spec.variants.map(variant => ({ ...variant,
            settings: { ...previous.find(value => value.id === variant.id)?.settings, ...structuredClone(variant.settings) } }));
          if (options.catalog && spec.capabilities) candidate.capabilities = structuredClone(spec.capabilities);
          if (options.catalog && spec.limit) candidate.limit = { ...spec.limit };
          // Custom gateway models must not silently become auxiliary families.
          delete candidate.family;
        });
      }
      if (!options.catalog) editor.default.set(model.providerID, model.id);
    }));
    for (const name of ['context', 'compaction', 'generate', 'title']) {
      registrations.push(await register(context.session, name, async (event) => {
        await admitRequest(event);
        if (!options.catalog) event.options.reasoningEffort = 'medium';
      }));
    }
    for (const providerID of allowedProviders) {
      const scope = { providerID };
      registrations.push(await register(context.session, 'model.request', async (event) => {
        await admitRequest(event);
        for (const key of Object.keys(event.headers)) if (key.toLowerCase() === 'x-session-id') delete event.headers[key];
        event.headers['x-session-id'] = options.route;
      }, scope));
      registrations.push(await register(context.session, 'http.request', async (event) => {
        await admitRequest(event);
        event.request.headers.set('x-session-id', options.route);
      }, scope));
      registrations.push(await register(context.session, 'experimental.ws.handshake', async (event) => {
        await admitRequest(event);
        for (const key of Object.keys(event.headers)) if (key.toLowerCase() === 'x-session-id') delete event.headers[key];
        event.headers['x-session-id'] = options.route;
      }, scope));
    }
    registrations.push(await register(context.tool, 'execute.before', async (event) => {
      await admitSession(event.sessionID);
      const input = event.input ?? {};
      if (event.tool === 'shell') await classify('command', input.command);
      else if (event.tool === 'write' || event.tool === 'edit') await classify('path', input.path);
      else if (event.tool === 'patch') {
        const patch = typeof input.patchText === 'string' ? input.patchText : '';
        const paths = [...patch.matchAll(/^[\t ]*\*\*\* (?:Add File: |Update File: |Delete File: |Move to: )(.+)$/gm)].map((match) => match[1].trim());
        if (!paths.length) throw new Error('celestial guard: cannot classify patch paths');
        for (const file of paths) await classify('path', file);
      }
    }));
    // Covers native user-shell and direct shell creation too, not only the
    // model-facing shell tool. Classify with the owned role, not a changed cwd.
    registrations.push(await register(context.shell, 'create.before', async (event) => {
      if (!await refreshLaunchAdmission()) throw new Error('OpenCode canonical launch admission is pending');
      return classify('command', event.command);
    }));
    registrations.push(await register(context.session, 'experimental.idle', async (event) => {
      if (disposed || resumeError) return;
      // A re-booted location may report the owned resumed root idle before the
      // first observer tick; prove and bind only that exact candidate. A
      // refusal stays with the observer rather than failing the native drain.
      try {
        if (!await refreshLaunchAdmission()) return;
        if (!sessionID && resumeCandidate && event.sessionID === resumeCandidate) await bootstrapResume();
      } catch { return; }
      if (disposed || event.sessionID !== sessionID || resumeError) return;
      await admitSession(event.sessionID);
      busyEvent = false; generation++;
      await deliver();
      // Never session.wait() here: it waits for this very execution to finish.
    }));
    eventTask = (async () => {
      try {
        for await (const event of context.event.subscribe({ signal: events.signal, types: [
          'session.created', 'session.status', 'session.execution.started', 'session.execution.succeeded',
          'session.execution.failed', 'session.execution.interrupted', 'session.deleted', 'session.moved',
          'session.agent.selected', 'session.model.selected',
        ] })) {
          if (disposed) break;
          await onEvent(event);
        }
      } catch { if (!disposed) { busyEvent = true; generation++; await note('blocked'); } }
    })();
    // A recurring observer is required even if no further native idle event
    // fires (restored-idle boot and mail arriving after an earlier idle).
    // session.wait has no cancellable Promise-plugin API in 2.2.5; explicit
    // persisted idle watermarks avoid an unjoinable waiter during unload.
    timer = clock.setInterval(poll, 3000);
    timer.unref?.();
    return cleanup;
  } catch (error) {
    await cleanup();
    throw error;
  }
}
