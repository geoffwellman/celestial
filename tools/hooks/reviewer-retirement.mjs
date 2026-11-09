import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { reviewerRetirementPaths, reviewerRoleFile } from '../reviewers/retirement-protocol.mjs';

const VERSION = 1;
const MAX_JSON = 16384;
const uid = process.getuid?.();
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const requireState = (value, reason) => { if (!value) throw new Error(reason); };

function privateJson(file) {
  const stat = fs.lstatSync(file);
  requireState(stat.isFile() && !stat.isSymbolicLink() && stat.uid === uid && (stat.mode & 0o077) === 0 && stat.size <= MAX_JSON, 'private_identity_unavailable');
  const value = JSON.parse(fs.readFileSync(file, 'utf8'));
  requireState(record(value), 'private_identity_unavailable');
  return value;
}

function publish(file, value) {
  if (fs.existsSync(file)) privateJson(file);
  const tmp = `${file}.${process.pid}.${randomUUID()}.tmp`;
  let fd;
  try {
    fd = fs.openSync(tmp, 'wx', 0o600);
    fs.fchmodSync(fd, 0o600);
    fs.writeFileSync(fd, JSON.stringify(value) + '\n');
    fs.fsyncSync(fd);
    fs.closeSync(fd); fd = undefined;
    fs.renameSync(tmp, file);
    const dir = fs.openSync(path.dirname(file), 'r');
    try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    try { fs.unlinkSync(tmp); } catch {}
  }
}

function birth(pid) {
  const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
  const value = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[19];
  requireState(/^\d+$/.test(value || ''), 'kernel_identity_unavailable');
  return value;
}

// The backend cannot infer these values from a saved transcript or unread count:
// the hook owns drained retry mail and Pi can navigate its leaf in memory only.
export function startReviewerRetirement({
  env = process.env,
  pid = process.pid,
  getContext,
  getInboxDebt,
  getNativeTurnActive,
  countUnread,
  prepareExit,
  restoreAfterFailedExit,
}) {
  if (env.CEL_ROLE !== 'reviewer' || env.CEL_SESSION_BACKEND !== 'rex') return null;
  const file = env.CEL_REX_RECORD;
  if (!path.isAbsolute(file || '') || typeof getContext !== 'function' || typeof getInboxDebt !== 'function'
      || typeof getNativeTurnActive !== 'function' || typeof countUnread !== 'function' || typeof prepareExit !== 'function' || typeof restoreAfterFailedExit !== 'function') return null;
  const files = reviewerRetirementPaths(file);
  const requestFile = files.request;
  const responseFile = files.response;
  const capabilityFile = files.capability;
  let watcher, disposed = false, processing = false, processed = '', inspection = null;

  function identity(ctx) {
    const r = privateJson(file);
    requireState(r.pid === pid && r.pid_start === birth(pid) && r.name === env.CEL_AGENT_NAME
      && r.role === 'reviewer' && r.agent === 'pi' && r.backend === 'rex'
      && typeof r.workspace === 'string' && path.isAbsolute(r.workspace)
      && typeof r.name === 'string' && path.basename(file) === `${r.name}.json`
      && /^\d+$/.test(String(r.pr))
      && reviewerRoleFile(env.CEL_ROLE_FILE, r.workspace, r.pr), 'runtime_identity_mismatch');
    requireState(ctx?.mode === 'tui' && ctx.hasUI === true && ctx.cwd === r.cwd
      && typeof ctx.isIdle === 'function' && typeof ctx.hasPendingMessages === 'function'
      && typeof ctx.shutdown === 'function' && typeof ctx.sessionManager?.getLeafId === 'function'
      && typeof ctx.sessionManager?.getSessionFile === 'function' && typeof ctx.ui?.getEditorText === 'function', 'native_api_unavailable');
    const native = ctx.sessionManager.getSessionFile();
    requireState(typeof native === 'string' && path.isAbsolute(native) && native === r.agent_session?.value, 'native_session_changed');
    return { name: r.name, pid, pid_start: r.pid_start, native_session: native };
  }

  let initial;
  try { initial = identity(getContext()); } catch { return null; }

  function validRequest(value) {
    requireState(value.version === VERSION && value.type === 'cel-reviewer-retirement-request'
      && ['inspect', 'exit'].includes(value.phase) && typeof value.nonce === 'string'
      && value.nonce.length > 0 && value.nonce.length <= 128, 'invalid_retirement_request');
    for (const key of ['name', 'pid', 'pid_start', 'native_session']) requireState(value[key] === initial[key], 'request_identity_mismatch');
    const now = Date.now();
    requireState(Number.isSafeInteger(value.created_at) && Number.isSafeInteger(value.expires_at)
      && value.created_at <= now + 1000 && value.expires_at > now
      && value.expires_at > value.created_at && value.expires_at - value.created_at <= 30000, 'expired_retirement_request');
    if (value.phase === 'exit') requireState(typeof value.expected_leaf === 'string' && value.expected_leaf.length > 0, 'live_leaf_unattested');
  }

  function sample(ctx, request) {
    const current = identity(ctx);
    for (const key of Object.keys(initial)) requireState(current[key] === initial[key], 'runtime_identity_changed');
    const debt = getInboxDebt();
    requireState(record(debt) && ['owed', 'pending', 'waking'].every(key => typeof debt[key] === 'boolean'), 'inbox_debt_unknown');
    const isIdle = ctx.isIdle();
    const sdkPending = ctx.hasPendingMessages();
    const editor = ctx.ui.getEditorText();
    const leaf = ctx.sessionManager.getLeafId();
    requireState(typeof isIdle === 'boolean' && typeof sdkPending === 'boolean' && typeof editor === 'string', 'native_state_unknown');
    const nativeTurnActive = getNativeTurnActive();
    requireState(typeof nativeTurnActive === 'boolean', 'native_turn_state_unknown');
    const unread = countUnread();
    requireState(Number.isSafeInteger(unread) && unread >= 0, 'unread_count_unknown');
    validRequest(request); // count can block; never commit an expired request.
    const result = {
      live_leaf: leaf,
      is_idle: isIdle,
      sdk_pending: sdkPending,
      native_turn_active: nativeTurnActive,
      inbox_owed: debt.owed,
      inbox_pending: debt.pending,
      inbox_waking: debt.waking,
      composer_empty: editor.trim() === '',
      exit_committed: false,
    };
    let reason = '';
    if (typeof leaf !== 'string' || !leaf || leaf.length > 256) reason = 'live_leaf_unattested';
    else if (!isIdle || sdkPending || nativeTurnActive) reason = 'native_work_pending';
    else if (debt.owed || debt.pending || debt.waking) reason = 'inbox_work_owed';
    else if (unread !== 0) reason = 'mailbox_work_owed';
    else if (!result.composer_empty) reason = 'composer_not_empty';
    else if (request.phase === 'exit' && request.expected_leaf !== leaf) reason = 'live_leaf_changed';
    return { result, reason };
  }

  function respond(request, fields) {
    publish(responseFile, {
      version: VERSION, type: 'cel-reviewer-retirement-response',
      phase: request.phase, nonce: request.nonce, ...initial,
      observed_at: Date.now(), ...fields,
    });
  }

  function handleRequest() {
    if (disposed || processing) return;
    let request;
    try { request = privateJson(requestFile); validRequest(request); } catch { return; }
    const key = `${request.nonce}/${request.phase}`;
    if (key === processed) return;
    processing = true;
    let exitPrepared = false, shutdownRequested = false;
    try {
      const ctx = getContext();
      let { result, reason } = sample(ctx, request);
      if (request.phase === 'inspect') inspection = null;
      if (request.phase === 'exit' && (!inspection || inspection.nonce !== request.nonce
          || inspection.leaf !== request.expected_leaf || inspection.expires_at <= Date.now())) {
        reason ||= 'retirement_inspection_unavailable';
      }
      if (reason) {
        respond(request, { ...result, status: 'protected', reason });
      } else if (request.phase === 'inspect') {
        respond(request, { ...result, status: 'ready', reason: '' });
        inspection = { nonce: request.nonce, leaf: result.live_leaf, expires_at: request.expires_at };
      } else {
        // Synchronous native-thread handoff: no further inbox cursor reads.
        // Supported shutdown owns Pi's save/flush sequence, not process.exit().
        inspection = null; // One-use native permission, never a reusable idle stamp.
        exitPrepared = true;
        prepareExit();
        ctx.shutdown();
        shutdownRequested = true;
        respond(request, { ...result, status: 'exiting', reason: '', exit_committed: true });
      }
      processed = key;
    } catch {
      // A synchronous refusal is reversible. Once the supported shutdown has
      // accepted, never resume inbox reads while native teardown is in flight.
      if (exitPrepared && !shutdownRequested) { try { restoreAfterFailedExit(); } catch {} }
      try { respond(request, { status: 'unknown', reason: 'native_retirement_unavailable', exit_committed: shutdownRequested }); } catch {}
      processed = key;
    } finally { processing = false; }
  }

  try {
    if (!fs.existsSync(files.directory)) fs.mkdirSync(files.directory, { mode: 0o700 });
    const directory = fs.lstatSync(files.directory);
    requireState(directory.isDirectory() && !directory.isSymbolicLink() && directory.uid === uid && (directory.mode & 0o077) === 0, 'protocol_directory_unavailable');
    watcher = fs.watch(files.directory, { persistent: false }, (_event, filename) => {
      if (filename === null || String(filename) === path.basename(requestFile)) handleRequest();
    });
    watcher.on('error', () => { disposed = true; try { watcher.close(); } catch {} });
    publish(capabilityFile, {
      version: VERSION, type: 'cel-reviewer-retirement-capability', ...initial,
      created_at: Date.now(), features: ['live_leaf', 'inbox_debt', 'graceful_shutdown'],
    });
    handleRequest();
  } catch {
    try { watcher?.close(); } catch {}
    return null;
  }
  return { dispose() { disposed = true; try { watcher.close(); } catch {} } };
}
