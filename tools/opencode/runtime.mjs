import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
const execute = promisify(execFile);

// This adapter speaks OpenCode 1.19.5's native plugin/v1 API. It never types
// into a terminal/TUI composer and never treats another harness's log as native.
export async function createHooks({ client, directory }, options, deps = {}) {
  const env = deps.env ?? process.env;
  const run = deps.run ?? (async (bin, args) => (await execute(bin, args, {
    cwd: directory, env, timeout: 15000, maxBuffer: 4 * 1024 * 1024,
  })).stdout);
  const clock = deps.clock ?? { setInterval, clearInterval };
  const root = env.CEL_ROOT;
  if (!root || !options?.agent || options.transport !== 'gateway'
      || options.modelID !== 'gpt-6.1-sol' || options.providerID !== 'ompgw-codex') {
    throw new Error('Celestial OpenCode requires a scoped role and explicit Sol6.1 account route');
  }
  const cel = path.join(root, 'bin/cel');
  const model = { providerID: options.providerID, modelID: options.modelID };
  const fullModel = `${model.providerID}/${model.modelID}`;
  let sessionID, busy = false, delivering = false, disposed = false, pending = '', generation = 0;
  let notes = Promise.resolve();
  const polls = new Set();
  let transportPinned = false;
  let resumeCandidate = '', resumeError, resumeLookup, resumePolledState, resumeRefusalNoted = false;
  const wsArgs = [];
  if (env.CEL_INBOX_ME && env.CEL_INBOX_ALL_WS !== '0') wsArgs.push('--all-workspaces');
  if (env.CEL_INBOX_WS) wsArgs.push('--workspace', env.CEL_INBOX_WS);
  if (env.CEL_INBOX_ME) wsArgs.push('--for', env.CEL_INBOX_ME);

  // TUI/server implementations may run plugins in a child. Only the exact
  // recorded Rex PID or a proven ancestor can author that receipt's state.
  function note(state) {
    if (disposed) return notes;
    const native = sessionID ?? '';
    notes = notes.then(() => noteState(state, native));
    return notes;
  }
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
  async function noteState(state, native) {
    try {
      const record = await ownedReceipt();
      if (record) await run(cel, ['sessions', 'note', String(record.pid), state, native]);
    } catch { /* an observation failure must not fabricate a known state */ }
  }
  function assertModel(input) {
    const actual = input.model;
    if (!actual || actual.providerID !== model.providerID || (actual.modelID ?? actual.id) !== model.modelID) {
      throw new Error(`Celestial retains ${fullModel}; provider/model fallback is not permitted`);
    }
  }
  async function nativeSession(id) {
    let result;
    try { result = await client.session.get({ path: { id }, query: { directory }, throwOnError: true }); }
    catch (error) { throw new Error('Cannot prove native child-session ancestry', { cause: error }); }
    if (result.error || result.data?.id !== id) throw new Error('Cannot prove native child-session ancestry');
    return result.data;
  }
  // Only a native ID captured by the owning Rex launch can bootstrap resume.
  // Do not call session.get during plugin construction: InstanceStore is still
  // initializing this plugin. The first poll/chat performs the native lookup.
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
  async function bootstrapResume() {
    if (resumeError) {
      if (!resumeRefusalNoted) { resumeRefusalNoted = true; await note('blocked'); }
      throw resumeError;
    }
    if (!resumeCandidate || sessionID) return;
    if (!resumeLookup) resumeLookup = (async () => {
      try {
        const native = await nativeSession(resumeCandidate);
        if (native.parentID || typeof native.directory !== 'string' || path.resolve(native.directory) !== path.resolve(directory)
            || (native.model && (native.model.providerID !== model.providerID || native.model.id !== model.modelID))) {
          throw new Error('Native resume candidate is not this same-model root session');
        }
        if (!disposed) sessionID = resumeCandidate;
      } catch (error) {
        resumeError = new Error('OpenCode native resume refused: candidate does not match the owned root', { cause: error });
        resumeRefusalNoted = true;
        await note('blocked');
        throw resumeError;
      }
    })();
    await resumeLookup;
  }
  async function isRootMessage(id, agent) {
    await bootstrapResume();
    if (!id) throw new Error('Celestial OpenCode role/session mismatch');
    if (id === sessionID) return true;
    if (!sessionID) {
      const native = await nativeSession(id);
      if (sessionID) return isRootMessage(id, agent);
      if (agent !== options.agent || native.parentID) throw new Error('Celestial OpenCode role/session mismatch');
      sessionID = id;
      return true;
    }
    const seen = new Set();
    let current = id;
    for (let depth = 0; depth < 64; depth++) {
      if (seen.has(current)) throw new Error('Cannot prove native child-session ancestry: cycle');
      seen.add(current);
      const native = await nativeSession(current);
      if (native.parentID === sessionID) return false;
      if (!native.parentID) throw new Error('This scoped OpenCode process already owns a native session; unrelated roots are not admitted');
      current = native.parentID;
    }
    throw new Error('Cannot prove native child-session ancestry: depth exceeded');
  }
  async function tick() {
    if (disposed || delivering) return;
    delivering = true;
    try {
      await bootstrapResume();
      if (disposed || !sessionID) return;
      // Native server state, not terminal text, is authoritative. An unknown
      // observation is not idle. Missing entry means idle in this API.
      const observed = generation;
      const status = await client.session.status({ query: { directory }, throwOnError: true });
      if (disposed || observed !== generation || status.error || !status.data || typeof status.data !== 'object') return;
      const nativeState = status.data[sessionID]?.type;
      if (nativeState !== undefined && !['idle', 'busy', 'retry'].includes(nativeState)) return;
      const observedState = nativeState === undefined || nativeState === 'idle' ? 'idle' : 'working';
      if (resumeCandidate && resumePolledState !== observedState) {
        await note(observedState);
        resumePolledState = observedState;
      }
      if (observedState !== 'idle') return;
      busy = false;
      if (!pending) {
        const count = Number((await run(cel, ['inbox', 'count', ...wsArgs])).trim());
        if (disposed || !(count > 0)) return;
        const raw = await run(cel, ['inbox', 'read', '--json', ...wsArgs]);
        pending = raw.split('\n').flatMap((line) => {
          const match = /^(\[[^\]]+\] )?(\{.*\})$/.exec(line.trim());
          if (!match) return [];
          const item = JSON.parse(match[2]);
          return item.id ? [`[${item.id}] ${match[1] ?? ''}${item.kind} from ${item.from}: ${item.message}`] : [];
        }).join('\n');
      }
      if (!pending || disposed || busy) return;
      busy = true;
      const result = await client.session.promptAsync({
        path: { id: sessionID }, query: { directory }, throwOnError: true,
        body: { agent: options.agent, model, parts: [{ type: 'text', text:
          `New messages in your celestial inbox (delivered by the native session API):\n${pending}\nAct on them, or say why not.` }] },
      });
      if (result.error || result.response?.ok === false) throw new Error('OpenCode did not accept inbox delivery');
      pending = '';
      if (busy) await note('working');
    } catch {
      busy = false;
      // A failed delivery keeps drained mail owed for the next idle poll;
      // never advance the inbox a second time just to retry the same mail.
    } finally { delivering = false; }
  }
  function poll() {
    if (disposed) return Promise.resolve();
    const task = tick();
    polls.add(task);
    task.finally(() => polls.delete(task));
    return task;
  }
  const timer = clock.setInterval(poll, 3000);
  timer.unref?.();

  async function classify(mode, arg) {
    if (env.CEL_GUARD === '0') return;
    if (mode === 'command' && /^CEL_GUARD_ALLOW_ONCE=1(?:\s|$)/.test(arg)) return;
    const verdict = (await run('bash', [path.join(root, 'tools/hooks/guard-classify.sh'), mode, directory, arg])).trim();
    if (verdict.startsWith('deny')) throw new Error(`celestial guard: ${verdict.slice(4).trim()}`);
  }
  return {
    async dispose() {
      disposed = true;
      clock.clearInterval(timer);
      await Promise.allSettled([...polls]);
      if (resumeLookup) await Promise.allSettled([resumeLookup]);
      await notes;
    },
    async config(config) {
      transportPinned = false;
      // Preserve unrelated/global plugin/provider/auth definitions. Restrict
      // selection in THIS instance only, including auxiliary title/summary work.
      config.model = fullModel;
      config.small_model = fullModel;
      config.enabled_providers = [model.providerID];
      config.default_agent = options.agent;
      const provider = config.provider?.[model.providerID];
      if (!provider || !options.route) throw new Error('Scoped gateway provider/route is absent; no transport fallback');
      provider.options ??= {};
      const upstream = provider.options.fetch ?? globalThis.fetch;
      if (typeof upstream !== 'function') throw new Error('Scoped gateway fetch is not callable');
      // OpenCode 1.19.5 adds X-Session-Id after chat.headers, and the AI SDK
      // normalizes header aliases downstream. Pin the authorized affinity key
      // at this provider's final fetch boundary, without replacing global fetch.
      // Provider.resolveSDK preserves options.fetch under its timeout wrapper.
      provider.options.fetch = (input, init) => {
        if (resumeError || (resumeCandidate && !sessionID)) throw new Error('OpenCode native resume is not verified; refusing transport dispatch');
        if (!env.OMP_GATEWAY_TOKEN) throw new Error('Gateway credential is absent; no native/provider fallback');
        const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined));
        headers.set('x-session-id', options.route);
        return upstream(input, { ...init, headers });
      };
      transportPinned = true;
    },
    async 'chat.message'(input, output) {
      assertModel({ model: input.model ?? output.message.model });
      const rootMessage = await isRootMessage(input.sessionID, input.agent ?? output.message.agent);
      // SessionV1.User stores effort on model.variant, not a top-level variant.
      // Preserve native model metadata; task/compaction inherit this object.
      output.message.model = { ...output.message.model, ...model, variant: 'medium' };
      if (!rootMessage) return;
      busy = true;
      generation++;
      await note('working');
    },
    async 'chat.params'(input, output) {
      await bootstrapResume();
      assertModel(input);
      if (!env.OMP_GATEWAY_TOKEN) throw new Error('Gateway credential is absent; no native/provider fallback');
      if (!transportPinned) throw new Error('Scoped gateway transport was not configured; refusing dispatch');
      output.options.reasoningEffort = 'medium';
    },
    async 'tool.execute.before'(input, output) {
      await bootstrapResume();
      const args = output.args ?? {};
      if (input.tool === 'bash') await classify('command', String(args.command ?? ''));
      else if (input.tool === 'edit' || input.tool === 'write') await classify('path', String(args.filePath ?? ''));
      else if (input.tool === 'apply_patch') {
        const patch = String(args.patchText ?? '');
        const paths = [...patch.matchAll(/^\*\*\* (?:Add File: |Update File: |Delete File: |Move to: )(.+)$/gm)].map((m) => m[1]);
        if (!paths.length) throw new Error('celestial guard: cannot classify patch paths');
        for (const file of paths) await classify('path', file);
      }
    },
    async event({ event }) {
      if (disposed) return;
      if (resumeError || (resumeCandidate && !sessionID)) return;
      const p = event.properties;
      if (event.type === 'session.created' && !p.info.parentID && !sessionID) {
        // A fresh launch may create its first session before its first chat.
        sessionID = p.info.id;
        await note('idle');
      } else if (event.type === 'session.status' && p.sessionID === sessionID) {
        busy = p.status.type !== 'idle';
        generation++;
        await note(busy ? 'working' : 'idle');
      } else if (event.type === 'session.error' && p.sessionID === sessionID) {
        // An error is not proof of idle; await native status before retrying.
        await note('blocked');
      }
    },
  };
}
