import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { reviewerRetirementPaths } from './retirement-protocol.mjs';

// Only the shell entrypoint holds the launcher's per-record flock. This module
// owns one supported Rex kill; it never signals a PID or releases a checkout.
class Refusal extends Error {
  constructor(reason, status = 'unknown') { super(reason); this.status = status; }
}
const requireProof = (condition, reason, status = 'unknown') => { if (!condition) throw new Refusal(reason, status); };
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const timestamp = value => typeof value === 'string' ? Date.parse(value) : NaN;
const uid = process.getuid();
const MAX_NATIVE = 64 * 1024 * 1024;

function noSymlinks(filename) {
  requireProof(path.isAbsolute(filename), 'non_absolute_evidence_path');
  let current = path.parse(filename).root;
  for (const part of filename.split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    requireProof(!fs.lstatSync(current).isSymbolicLink(), 'symlinked_evidence_path');
  }
}
function ownedFile(filename, limit = MAX_NATIVE, privateMode = false) {
  noSymlinks(filename);
  const fd = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const before = fs.fstatSync(fd);
    requireProof(before.isFile() && before.uid === uid && before.size <= limit, 'unsafe_evidence_file');
    requireProof((before.mode & (privateMode ? 0o077 : 0o022)) === 0, 'unsafe_evidence_permissions');
    const bytes = fs.readFileSync(fd);
    const after = fs.fstatSync(fd);
    const named = fs.lstatSync(filename);
    requireProof(before.dev === after.dev && before.ino === after.ino && before.size === after.size && before.mtimeMs === after.mtimeMs && named.ino === after.ino && named.dev === after.dev, 'evidence_changed_during_read');
    return { bytes, hash: sha(bytes), size: bytes.length, dev: before.dev, ino: before.ino };
  } finally { fs.closeSync(fd); }
}
function jsonFile(filename, privateMode = false) {
  const evidence = ownedFile(filename, MAX_NATIVE, privateMode);
  return { ...evidence, value: JSON.parse(evidence.bytes.toString('utf8')) };
}
function command(bin, args, { json = true, cwd } = {}) {
  const result = spawnSync(bin, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 15000, maxBuffer: 2 * 1024 * 1024 });
  requireProof(!result.error && result.status === 0, 'command_failed');
  return json ? JSON.parse(result.stdout) : result.stdout;
}
function selectedEnv(pid) {
  // Values outside this launch-identity allowlist never leave /proc parsing.
  const allowed = new Set(['CEL_AGENT_NAME', 'CEL_ROLE', 'CEL_ROLE_FILE', 'CEL_WORKSPACE', 'CEL_ROOT', 'CEL_REX_RECORD', 'PI_CODING_AGENT_DIR', 'CEL_WATCH_PARENT_POLL']);
  const result = {};
  for (const entry of fs.readFileSync(`/proc/${pid}/environ`, 'utf8').split('\0')) {
    const equal = entry.indexOf('=');
    const key = entry.slice(0, equal);
    if (allowed.has(key)) result[key] = entry.slice(equal + 1);
  }
  return result;
}
function processIdentity(pid) {
  const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
  const end = stat.lastIndexOf(') ');
  requireProof(end > 0, 'malformed_kernel_identity');
  const fields = stat.slice(end + 2).trim().split(/\s+/);
  const status = fs.readFileSync(`/proc/${pid}/status`, 'utf8');
  requireProof(Number(status.match(/^Uid:\s+(\d+)/m)?.[1]) === uid, 'foreign_process');
  const argv = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').filter(Boolean);
  const cwd = fs.readlinkSync(`/proc/${pid}/cwd`);
  const exe = fs.readlinkSync(`/proc/${pid}/exe`);
  const p = { pid, start: fields[19], ppid: Number(fields[1]), pgrp: Number(fields[2]), comm: stat.slice(stat.indexOf('(') + 1, end), argv, cwd, exe, env: selectedEnv(pid) };
  requireProof(/^\d+$/.test(p.start), 'malformed_kernel_identity');
  for (const fd of fs.readdirSync(`/proc/${pid}/fd`)) {
    let target;
    try { target = fs.readlinkSync(`/proc/${pid}/fd/${fd}`); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    requireProof(!target.endsWith(' (deleted)'), 'open_deleted_artifact', 'protected');
  }
  return p;
}
function liveGeneration(p) {
  try {
    const text = fs.readFileSync(`/proc/${p.pid}/stat`, 'utf8');
    const fields = text.slice(text.lastIndexOf(') ') + 2).trim().split(/\s+/);
    return fields[19] === p.start; // Zombies are not proven exited/reaped.
  } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
function descendants(root) {
  const out = [], seen = new Set(), queue = [root];
  while (queue.length) {
    const pid = queue.shift();
    requireProof(!seen.has(pid) && seen.size < 256, 'unbounded_or_changed_process_tree');
    seen.add(pid);
    const p = processIdentity(pid); out.push(p);
    const children = new Set();
    for (const tid of fs.readdirSync(`/proc/${pid}/task`)) {
      const content = fs.readFileSync(`/proc/${pid}/task/${tid}/children`, 'utf8').trim();
      if (content) for (const child of content.split(/\s+/)) children.add(Number(child));
    }
    queue.push(...[...children].sort((a, b) => a - b));
  }
  for (const p of out.slice(1)) requireProof(seen.has(p.ppid), 'reparented_process_tree');
  return out;
}
export function validatedProcessEvidence(tree, r, declared, rootPath) {
  const root = tree[0];
  const watchers = new Set(), pollSleeps = new Set();
  const sameLaunch = p => p.env.CEL_REX_RECORD === root.env.CEL_REX_RECORD && p.env.CEL_ROOT === rootPath && p.env.CEL_AGENT_NAME === r.name && p.env.CEL_ROLE === 'reviewer' && p.env.CEL_WORKSPACE === r.workspace;
  for (const p of tree.slice(1)) {
    requireProof(BigInt(p.start) >= BigInt(root.start) && sameLaunch(p), 'unowned_descendant', 'protected');
    const a = p.argv;
    const watchPrefix = ['bash', path.join(rootPath, 'bin/cel'), 'inbox', 'watch'];
    const isWatch = a.length >= 6 && path.basename(a[0] || '') === watchPrefix[0] && a.slice(1, 4).every((v, i) => v === watchPrefix[i + 1]);
    if (p.ppid === root.pid && isWatch) {
      const options = a.slice(4), pairs = new Map();
      for (let i = 0; i < options.length;) {
        const key = options[i++];
        requireProof(['--for', '--workspace', '--parent', '--all-workspaces'].includes(key) && !pairs.has(key), 'unknown_inbox_watcher', 'protected');
        const value = key === '--all-workspaces' ? true : options[i++];
        requireProof(value !== undefined, 'unknown_inbox_watcher', 'protected');
        pairs.set(key, value);
      }
      requireProof(!pairs.has('--for') || pairs.get('--for') === r.name, 'foreign_inbox_watcher', 'protected');
      requireProof(pairs.get('--parent') === String(root.pid) && p.pgrp === p.pid, 'unbound_inbox_watcher', 'protected');
      watchers.add(p.pid); continue;
    }
    // A shell function in the watcher pipeline inherits the watcher's argv;
    // its own descendants remain in that exact detached watcher process group.
    const watcher = tree.find(w => watchers.has(w.pid) && w.pgrp === p.pgrp);
    if (watcher) {
      const basename = path.basename(a[0] || '');
      const ancestor = tree.find(x => x.pid === p.ppid);
      requireProof(ancestor && ancestor.pgrp === watcher.pgrp, 'unbound_watcher_child', 'protected');
      const poll = root.env.CEL_WATCH_PARENT_POLL || '5';
      const sleep = basename === 'sleep' && a.length === 2 && a[1] === poll && /^(?:[1-9]|[1-5][0-9]|60|0\.[0-9]+)$/.test(poll) && ancestor.pid !== watcher.pid && ancestor.ppid === watcher.pid && JSON.stringify(ancestor.argv) === JSON.stringify(watcher.argv) && !tree.some(child => child.ppid === p.pid);
      const tail = basename === 'tail' && a.length >= 5 && a[1] === '-n' && a[2] === '0' && a[3] === '-F' && a.slice(4).every(filename => path.isAbsolute(filename) && filename.endsWith('.jsonl'));
      const jq = ['jq', 'jaq'].includes(basename) && a.length === 10 && a[1] === '-nRr' && a[2] === '--unbuffered' && a[3] === '--arg' && a[4] === 'who' && a[5] === r.name && a[6] === '--arg' && a[7] === 'dir' && path.isAbsolute(a[8]) && a[8].endsWith('/') && fs.readFileSync(path.join(rootPath, 'lib/inbox.sh'), 'utf8').includes(`_INBOX_WATCH_JQ='${a[9]}'`);
      const shell = isWatch && JSON.stringify(a) === JSON.stringify(watcher.argv);
      requireProof(sleep || tail || jq || shell, 'unknown_watcher_child', 'protected');
      if (sleep) pollSleeps.add(p.pid);
      continue;
    }
    const mcp = p.ppid === root.pid && a.length === 2 && p.pgrp === root.pgrp && declared.some(([bin, suffix]) => {
      const expected = `${process.env.HOME}${suffix}`;
      if (path.basename(a[0]) !== bin || !fs.existsSync(expected) || !fs.existsSync(a[1])) return false;
      return fs.realpathSync(a[1]) === fs.realpathSync(expected);
    });
    requireProof(mcp, 'active_or_unknown_descendant', 'protected');
  }
  const stable = [root, ...tree.slice(1).filter(p => !pollSleeps.has(p.pid)).sort((a, b) => a.pid - b.pid)];
  return {
    processes: stable.map(p => ({ pid: p.pid, start: p.start, ppid: p.ppid, pgrp: p.pgrp, comm: p.comm, cwd: p.cwd, exe: p.exe, argvHash: sha(JSON.stringify(p.argv)) })),
    watcherGroups: tree.filter(p => watchers.has(p.pid)).map(p => ({ pgrp: p.pgrp, leader: p.pid, start: p.start })).sort((a, b) => a.pgrp - b.pgrp),
  };
}

function watcherGroupPresent(pgrp) {
  requireProof(Number.isInteger(pgrp) && pgrp > 1, 'invalid_owned_watcher_group');
  try { process.kill(-pgrp, 0); return true; } catch (error) {
    if (error.code === 'ESRCH') return false;
    if (error.code === 'EPERM') return true;
    throw error;
  }
}
function retirementProcessesPresent(evidence) {
  requireProof(Array.isArray(evidence.processes) && evidence.processes.length > 0 && Array.isArray(evidence.watcherGroups), 'incomplete_retirement_process_proof');
  return evidence.processes.some(liveGeneration) || evidence.watcherGroups.some(group => watcherGroupPresent(group.pgrp));
}

function nativeStructure(bytes, cwd) {
  requireProof(bytes.length > 0 && bytes.at(-1) === 10, 'truncated_native_history');
  const text = bytes.toString('utf8');
  requireProof(Buffer.from(text).equals(bytes), 'invalid_native_encoding');
  const entries = text.trimEnd().split('\n').map(line => JSON.parse(line));
  const header = entries.shift();
  requireProof(header?.type === 'session' && header.version === 3 && typeof header.id === 'string' && header.id.length > 0 && header.cwd === cwd, 'unsupported_native_header');
  const byId = new Map();
  for (const e of entries) {
    requireProof(object(e) && typeof e.id === 'string' && e.id.length > 0 && !byId.has(e.id) && Number.isFinite(timestamp(e.timestamp)), 'malformed_native_entry');
    requireProof(e.parentId === null || (typeof e.parentId === 'string' && byId.has(e.parentId)), 'unknown_native_branch');
    byId.set(e.id, e);
  }
  requireProof(entries.length > 0, 'empty_native_history');
  return { header, entries, byId };
}

export function parseNative(bytes, cwd, roundAt, leaf) {
  const { header, byId } = nativeStructure(bytes, cwd);
  // The persisted last append is not necessarily SessionManager's live leaf
  // after branch()/resetLeaf(). Only a native in-process attestation selects it.
  requireProof(typeof leaf === 'string' && leaf.length > 0 && byId.has(leaf), 'unattested_native_leaf', 'protected');
  const branch = [], visited = new Set();
  let current = byId.get(leaf);
  while (current) {
    requireProof(!visited.has(current.id), 'cyclic_native_branch');
    visited.add(current.id); branch.push(current);
    current = current.parentId === null ? null : byId.get(current.parentId);
  }
  branch.reverse();
  const pending = new Set(), calls = new Set();
  let lastConversation, final;
  for (const e of branch) {
    if (e.type === 'message') {
      const m = e.message;
      requireProof(object(m) && ['assistant', 'toolResult', 'user', 'system', 'bashExecution'].includes(m.role), 'unknown_native_message');
      if (m.role === 'assistant') {
        requireProof(Array.isArray(m.content), 'malformed_assistant_content');
        for (const c of m.content) {
          requireProof(object(c) && ['text', 'thinking', 'toolCall', 'image'].includes(c.type), 'unknown_assistant_content');
          if (c.type === 'toolCall') {
            requireProof(typeof c.id === 'string' && !calls.has(c.id), 'duplicate_native_tool');
            calls.add(c.id); pending.add(c.id);
          }
        }
        final = e;
      } else if (m.role === 'toolResult') {
        requireProof(typeof m.toolCallId === 'string' && pending.has(m.toolCallId), 'unmatched_native_tool_result');
        pending.delete(m.toolCallId);
      }
      if (m.role !== 'system') lastConversation = e;
    } else if (e.type === 'custom_message') {
      // Inbox and background notifications are actual work, not passive metadata.
      lastConversation = e;
    } else if (e.type === 'custom') {
      requireProof(e.customType === 'pipeline-anthropic-cache-retention' && e.data?.schema_version === 'pipeline.anthropic_cache_retention.v1' && ['default', 'short', 'long'].includes(e.data.retention), 'unknown_native_custom_state');
    } else {
      requireProof(['model_change', 'thinking_level_change', 'session_info', 'label', 'compaction', 'branch_summary', 'context_edit', 'usage'].includes(e.type), 'unknown_native_entry_type');
      if (['compaction', 'branch_summary', 'context_edit'].includes(e.type)) lastConversation = e;
    }
  }
  requireProof(pending.size === 0, 'pending_native_tools', 'protected');
  requireProof(final && lastConversation === final && final.message.stopReason === 'stop' && !final.message.content.some(c => c.type === 'toolCall'), 'native_round_not_completed', 'protected');
  requireProof(timestamp(final.timestamp) >= roundAt && timestamp(final.timestamp) <= Date.now(), 'native_stop_not_after_verdict', 'protected');
  return { id: header.id, leaf, final: final.id, finalAt: timestamp(final.timestamp) };
}

export function emptyComposer(capture, cwd) {
  requireProof(object(capture) && capture.eof === true && typeof capture.content === 'string' && Number.isInteger(capture.total) && capture.total >= 0 && capture.total <= 983040 && Buffer.byteLength(capture.content) === capture.total, 'incomplete_terminal_capture');
  const text = capture.content.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '').replace(/\r/g, '');
  const lines = text.split('\n');
  const borders = [];
  for (let i = 0; i < lines.length; i++) if (/^[─━═]{6,}\s*$/.test(lines[i].trim())) borders.push(i);
  requireProof(borders.length >= 2, 'unknown_composer_layout');
  const top = borders.at(-2), bottom = borders.at(-1);
  requireProof(bottom > top && bottom - top <= 12, 'unknown_composer_layout');
  requireProof(lines.slice(top + 1, bottom).every(line => /^\s*$/.test(line)), 'unsent_composer_draft', 'protected');
  const footer = lines.slice(bottom + 1).filter(line => line.trim());
  requireProof(footer.length >= 2 && (!cwd || footer[0].trim() === cwd || footer[0].trim() === cwd.replace(process.env.HOME || '\0', '~')) && footer.slice(1).some(line => /\([^\n()]+\)\s+\S+/.test(line)), 'unknown_pi_footer');
  requireProof(!lines.slice(bottom + 1).some(line => /working|thinking|compacting|queued|pending|retrying|running/i.test(line)), 'unsettled_terminal_tail', 'protected');
  return sha(Buffer.from(text.slice(text.lastIndexOf(lines[top]))));
}

function taskMetadata(cwd, native, pid, finalAt) {
  const base = path.join(cwd, '.pi', 'tasks');
  const root = `${native.id.replace(/[^a-zA-Z0-9_.-]+/g, '-').replace(/^-+|-+$/g, '') || 'session'}-${pid}`;
  const evidence = [];
  // Inspect the actual fixed store, including stale session/PID directories:
  // a completed shell launch response is not proof its detached task ended.
  try { fs.lstatSync(base); } catch (error) {
    if (error.code === 'ENOENT') return { root: path.join(base, root), files: evidence };
    throw error;
  }
  noSymlinks(base);
  let filesSeen = 0;
  const directories = fs.readdirSync(base, { withFileTypes: true });
  requireProof(directories.length <= 2000, 'background_store_too_large');
  for (const dir of directories) {
    requireProof(dir.isDirectory() && !dir.isSymbolicLink(), 'unknown_background_store');
    const directory = path.join(base, dir.name);
    for (const file of fs.readdirSync(directory, { withFileTypes: true })) {
      requireProof(++filesSeen <= 20000, 'background_store_too_large');
      requireProof(!file.isSymbolicLink(), 'symlinked_background_metadata');
      if (!file.name.endsWith('.json')) continue;
      // Task attestations are evidence only; task state comes from <id>.json.
      if (file.name.endsWith('.attestation.json')) continue;
      requireProof(file.isFile(), 'unknown_background_metadata');
      const filename = path.join(directory, file.name), saved = jsonFile(filename), task = saved.value;
      requireProof(object(task) && task.id === file.name.slice(0, -5) && task.cwd === cwd && typeof task.command === 'string' && typeof task.outputPath === 'string' && Number.isFinite(task.startTime) && typeof task.notified === 'boolean' && typeof task.notifyOnCompletion === 'boolean' && typeof task.triggerOnCompletion === 'boolean', 'malformed_background_metadata');
      requireProof(['completed', 'failed', 'killed'].includes(task.status) && Number.isFinite(task.endTime) && task.endTime >= task.startTime && task.endTime <= finalAt, 'pending_background_task', 'protected');
      requireProof((!task.notifyOnCompletion && !task.triggerOnCompletion) || task.notified, 'owed_background_notification', 'protected');
      if (task.pid !== undefined) requireProof(Number.isInteger(task.pid) && !fs.existsSync(`/proc/${task.pid}`), 'background_pid_still_present', 'protected');
      evidence.push({ path: filename, hash: saved.hash, size: saved.size });
    }
  }
  return { root: path.join(base, root), files: evidence };
}
function artifacts(cwd) {
  const entries = [];
  try { fs.lstatSync(cwd); } catch (error) {
    if (error.code === 'ENOENT') return { cwd, exists: false, entries };
    throw error;
  }
  const queue = [''], buffer = Buffer.allocUnsafe(65536);
  let totalBytes = 0;
  while (queue.length) {
    const rel = queue.shift(), filename = path.join(cwd, rel), stat = fs.lstatSync(filename);
    requireProof(entries.length < 20000, 'artifact_inventory_too_large');
    let hash;
    if (stat.isFile()) {
      requireProof((totalBytes += stat.size) <= 1024 * 1024 * 1024, 'artifact_byte_inventory_too_large');
      const fd = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      try {
        const digest = crypto.createHash('sha256');
        let read, bytesRead = 0;
        while ((read = fs.readSync(fd, buffer, 0, buffer.length, null)) > 0) {
          bytesRead += read;
          requireProof(bytesRead <= stat.size, 'artifact_changed_during_read');
          digest.update(buffer.subarray(0, read));
        }
        const after = fs.fstatSync(fd);
        requireProof(bytesRead === stat.size && stat.dev === after.dev && stat.ino === after.ino && stat.mtimeMs === after.mtimeMs && stat.size === after.size, 'artifact_changed_during_read');
        hash = digest.digest('hex');
      } finally { fs.closeSync(fd); }
    }
    requireProof(stat.isDirectory() || stat.isFile() || stat.isSymbolicLink(), 'unknown_checkout_artifact');
    entries.push({ path: rel, dev: stat.dev, ino: stat.ino, mode: stat.mode, size: stat.size, mtime: stat.mtimeMs, ...(hash ? { hash } : {}), ...(stat.isSymbolicLink() ? { target: fs.readlinkSync(filename) } : {}) });
    if (stat.isDirectory() && path.basename(rel) !== '.git') for (const name of fs.readdirSync(filename).sort()) queue.push(path.join(rel, name));
  }
  return { cwd, exists: true, entries };
}
export function selectedRound(ledger, selector) {
  let round;
  if (selector.kind === 'solo') {
    requireProof(object(ledger), 'unknown_solo_review_ledger');
    round = ledger[selector.key];
  } else {
    requireProof(selector.kind === 'fleet' && Array.isArray(ledger), 'unknown_fleet_review_ledger');
    const rows = ledger.filter(row => row.id === selector.id && row.repo === selector.repo && row.branch === selector.branch);
    requireProof(rows.length === 1, 'ambiguous_or_missing_own_review_round');
    round = rows[0].review;
  }
  requireProof(object(round), 'own_review_round_unavailable');
  return { round, hash: sha(JSON.stringify(round)) };
}
function currentRoundHash(proof) {
  return selectedRound(jsonFile(proof.path).value, proof.selector).hash;
}

function durableRound(r, pr) {
  const solo = path.join(r.workspace, '.cel', 'solo-reviews.json');
  const candidates = [];
  if (fs.existsSync(solo)) {
    const selector = { kind: 'solo', key: `${r.repo}#${r.pr}` }, saved = jsonFile(solo);
    if (saved.value[selector.key]) candidates.push({ path: solo, selector, ...selectedRound(saved.value, selector) });
  }
  const fleet = path.join(r.workspace, '.cel', 'delegations.json');
  if (fs.existsSync(fleet)) {
    const saved = jsonFile(fleet);
    requireProof(Array.isArray(saved.value), 'unknown_fleet_ledger');
    for (const row of saved.value) if (row.repo === r.repo && row.branch === pr.headRefName && row.review?.head_source === 'explicit') {
      requireProof(typeof row.id === 'string' && row.id.length > 0, 'unidentified_fleet_review_round');
      const selector = { kind: 'fleet', id: row.id, repo: row.repo, branch: row.branch };
      candidates.push({ path: fleet, selector, ...selectedRound(saved.value, selector) });
    }
  }
  const matches = candidates.filter(c => ['approved', 'changes'].includes(c.round.verdict) && c.round.head === pr.headRefOid && c.round.by === r.name && Number.isFinite(timestamp(c.round.at)));
  requireProof(matches.length > 0, 'no_completed_current_head_round', 'protected');
  return matches.sort((a, b) => timestamp(b.round.at) - timestamp(a.round.at))[0];
}
function saveProof(filename, value) {
  const fd = fs.openSync(filename, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
  try { fs.writeFileSync(fd, `${JSON.stringify(value, null, 2)}\n`); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  const dir = fs.openSync(path.dirname(filename), fs.constants.O_RDONLY);
  try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
}

function nativePrefixPreserved(first) {
  const native = ownedFile(first.native.path);
  requireProof(native.dev === first.native.dev && native.ino === first.native.ino && native.size >= first.native.size && sha(native.bytes.subarray(0, first.native.size)) === first.native.hash, 'native_evidence_not_preserved');
  return native.size;
}

export function validateArchivedRole(role) {
  requireProof(object(role) && role.encoding === 'base64' && typeof role.contentBase64 === 'string' && Number.isSafeInteger(role.size) && role.size >= 0 && role.size <= 1024 * 1024 && role.contentBase64.length === Math.ceil(role.size / 3) * 4, 'archived_role_evidence_unavailable');
  const bytes = Buffer.from(role.contentBase64, 'base64');
  requireProof(bytes.length === role.size && bytes.toString('base64') === role.contentBase64 && sha(bytes) === role.hash, 'archived_role_evidence_changed');
  return bytes;
}
function archivedInstructionsPreserved(evidence) {
  validateArchivedRole(evidence.role);
  requireProof(object(evidence.round?.round) && sha(JSON.stringify(evidence.round.round)) === evidence.round.hash, 'archived_verdict_evidence_changed');
}

function preservedEvidence(first, inventory) {
  const nativeLength = nativePrefixPreserved(first);
  archivedInstructionsPreserved(first);
  requireProof(JSON.stringify(artifacts(first.checkout.path)) === JSON.stringify(inventory), 'checkout_artifacts_not_preserved');
  return nativeLength;
}

function sessionPresent(rex, session) {
  const roster = rex(['ls', '--json', '--short=false']);
  requireProof(Array.isArray(roster.sessions) && roster.sessions.every(s => object(s) && typeof s.session_id === 'string'), 'unknown_rex_roster');
  return roster.sessions.some(s => s.session_id === session);
}
function sessionAbsent(rex, session) {
  requireProof(!sessionPresent(rex, session), 'rex_session_still_present');
}

export function sessionTopology(session) {
  requireProof(object(session) && typeof session.session_id === 'string' && session.session_id.length > 0 && (session.label === undefined || typeof session.label === 'string') && Array.isArray(session.windows), 'unknown_rex_session_topology');
  const windows = session.windows.map(window => {
    requireProof(typeof window.window_id === 'string' && window.window_id.length > 0 && Array.isArray(window.layers), 'unknown_rex_window_topology');
    return { id: window.window_id, layers: window.layers.map(layer => {
      requireProof(object(layer) && Array.isArray(layer.blocks), 'unknown_rex_layer_topology');
      return layer.blocks.map(block => {
        requireProof(object(block) && typeof block.block_id === 'string' && block.block_id.length > 0, 'unknown_rex_block_topology');
        return block.block_id;
      });
    }) };
  });
  return { id: session.session_id, label: session.label, windows };
}

function emptyRexContainer(rex, first) {
  const r = first.identity;
  const session = rex(['session', 'inspect', r.rex_session, '--json']);
  requireProof(JSON.stringify(sessionTopology(session)) === JSON.stringify(first.session), 'rex_container_replaced_or_extended', 'protected');
  const info = rex(['block', 'call', 'process', '{}', '-s', r.rex_session, '-b', r.rex_block]);
  requireProof(object(info) && info.error == null, 'unknown_stopped_rex_process');
  // Observed supported Rex process API omits child/foreground after exit;
  // explicit null is equivalent ONLY with the successful last_exit receipt.
  requireProof((!Object.hasOwn(info, 'child') || info.child === null) && (!Object.hasOwn(info, 'foreground') || info.foreground === null), 'rex_terminal_replacement_process', 'protected');
  requireProof(object(info.last_exit) && Number.isInteger(info.last_exit.exit_code) && info.last_exit.exit_code === 0 && info.last_exit.error == null, 'rex_successful_native_exit_unproven');
}

const PROTOCOL_TTL = 15000;
const protocolIdentity = (value, identity) => value?.name === identity.name && value.pid === identity.pid && value.pid_start === identity.pid_start && value.native_session === identity.agent_session.value;
function protocolFile(filename) {
  const evidence = ownedFile(filename, 65536, true);
  return { ...evidence, value: JSON.parse(evidence.bytes.toString('utf8')) };
}
function ownedProtocolPaths(receipt) {
  const paths = reviewerRetirementPaths(receipt);
  noSymlinks(paths.directory);
  const directory = fs.lstatSync(paths.directory);
  requireProof(directory.isDirectory() && directory.uid === uid && (directory.mode & 0o077) === 0, 'unsafe_native_retirement_protocol_directory');
  return paths;
}
function nativeCapability(receipt, identity) {
  try {
    const paths = ownedProtocolPaths(receipt), saved = protocolFile(paths.capability), capability = saved.value;
    requireProof(capability.version === 1 && capability.type === 'cel-reviewer-retirement-capability' && protocolIdentity(capability, identity) && Number.isFinite(capability.created_at) && capability.created_at <= Date.now() && Array.isArray(capability.features) && ['live_leaf', 'inbox_debt', 'graceful_shutdown'].every(feature => capability.features.includes(feature)), 'native_retirement_capability_unavailable', 'protected');
    return { path: paths.capability, hash: saved.hash, value: capability };
  } catch { throw new Refusal('native_retirement_capability_unavailable', 'protected'); }
}

export function validateNativeResponse(response, request, now = Date.now()) {
  requireProof(object(response) && response.version === 1 && response.type === 'cel-reviewer-retirement-response' && response.phase === request.phase && response.nonce === request.nonce && response.name === request.name && response.pid === request.pid && response.pid_start === request.pid_start && response.native_session === request.native_session, 'native_response_identity_mismatch');
  requireProof(Number.isFinite(response.observed_at) && response.observed_at >= request.created_at && response.observed_at <= request.expires_at && response.observed_at <= now && now <= request.expires_at, 'stale_native_retirement_response');
  if (response.status === 'protected' || response.status === 'unknown') {
    const reason = typeof response.reason === 'string' && /^[a-z][a-z0-9_]{0,100}$/.test(response.reason) ? response.reason : 'native_retirement_refused';
    throw new Refusal(reason, response.status);
  }
  requireProof(response.status === (request.phase === 'exit' ? 'exiting' : 'ready'), 'unknown_native_retirement_status');
  requireProof(typeof response.live_leaf === 'string' && response.live_leaf.length > 0 && ['is_idle', 'sdk_pending', 'native_turn_active', 'inbox_owed', 'inbox_pending', 'inbox_waking', 'composer_empty', 'exit_committed'].every(key => typeof response[key] === 'boolean'), 'incomplete_native_retirement_state');
  requireProof(response.is_idle && !response.sdk_pending && !response.native_turn_active && !response.inbox_owed && !response.inbox_pending && !response.inbox_waking && response.composer_empty, 'native_retirement_work_owed', 'protected');
  requireProof(response.exit_committed === (request.phase === 'exit') && (request.phase !== 'exit' || response.live_leaf === request.expected_leaf), 'native_exit_leaf_or_commit_changed', 'protected');
  return response;
}

export function validateExitCommitment(exit, preparedPath, prepared) {
  try {
    const inspect = prepared.handshake?.inspect, request = exit.request;
    requireProof(prepared.version === 1 && prepared.stage === 'prepared' && prepared.identity?.role === 'reviewer' && prepared.identity.agent === 'pi' && prepared.identity.backend === 'rex' && inspect?.request?.phase === 'inspect' && inspect.request.version === 1 && inspect.request.type === 'cel-reviewer-retirement-request', 'invalid_native_inspection_proof');
    requireProof(typeof inspect.request.nonce === 'string' && inspect.request.nonce.length > 0 && inspect.request.nonce.length <= 128, 'unbound_native_inspection_nonce');
    requireProof(protocolIdentity(inspect.request, prepared.identity) && protocolIdentity(inspect.response, prepared.identity) && prepared.native?.path === prepared.identity.agent_session.value, 'native_inspection_identity_mismatch');
    requireProof(exit.version === 1 && exit.stage === 'native-exit-committed' && exit.prepared === preparedPath && request?.version === 1 && request.type === 'cel-reviewer-retirement-request' && request.phase === 'exit' && request.nonce === inspect.request.nonce && protocolIdentity(request, prepared.identity), 'native_exit_proof_identity_mismatch');
    for (const entry of [inspect.request, request]) requireProof(Number.isSafeInteger(entry.created_at) && Number.isSafeInteger(entry.expires_at) && entry.expires_at > entry.created_at && entry.expires_at - entry.created_at <= 30000, 'invalid_native_exit_proof_lease');
    validateNativeResponse(inspect.response, inspect.request, inspect.response.observed_at);
    validateNativeResponse(exit.response, request, exit.response.observed_at);
    requireProof(request.expected_leaf === prepared.native.leaf && request.expected_leaf === inspect.response.live_leaf && request.created_at >= inspect.response.observed_at && exit.response.observed_at <= inspect.request.expires_at, 'native_exit_not_bound_to_ready_inspection');
    return exit;
  } catch { throw new Refusal('native_exit_commitment_unavailable'); }
}

function savedExitCommitment(preparedPath, prepared, recover = false) {
  try {
    requireProof(preparedPath.endsWith('.json'), 'invalid_prepared_proof_path');
    const filename = `${preparedPath.slice(0, -5)}.exit.json`;
    if (!fs.existsSync(filename) && recover) {
      // Native shutdown may commit before the controller journals its copy.
      // Recover only an absent copy; an existing invalid proof remains a veto.
      const paths = ownedProtocolPaths(prepared.receipt.path);
      const value = { version: 1, stage: 'native-exit-committed', prepared: preparedPath,
        request: protocolFile(paths.request).value, response: protocolFile(paths.response).value };
      validateExitCommitment(value, preparedPath, prepared);
      saveProof(filename, value);
    }
    const saved = jsonFile(filename, true);
    validateExitCommitment(saved.value, preparedPath, prepared);
    return { path: filename, hash: saved.hash };
  } catch { throw new Refusal('native_exit_commitment_unavailable'); }
}

function writeProtocol(filename, value) {
  if (fs.existsSync(filename)) protocolFile(filename);
  const temporary = `${filename}.${crypto.randomUUID()}.tmp`;
  saveProof(temporary, value);
  fs.renameSync(temporary, filename);
  const directory = fs.openSync(path.dirname(filename), fs.constants.O_RDONLY);
  try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
}

async function nativeHandshake(receipt, identity, phase, nonce, leaf) {
  const { request: requestPath, response: responsePath } = ownedProtocolPaths(receipt);
  if (phase === 'inspect' && fs.existsSync(requestPath)) {
    const prior = protocolFile(requestPath).value;
    if (prior.phase === 'exit') {
      let response;
      try { response = protocolFile(responsePath).value; } catch { /* Retain unresolved exit debt. */ }
      requireProof(response?.version === 1 && response.type === 'cel-reviewer-retirement-response' && response.phase === 'exit' && response.nonce === prior.nonce && response.name === prior.name && response.pid === prior.pid && response.pid_start === prior.pid_start && response.native_session === prior.native_session && ['protected', 'unknown'].includes(response.status) && response.exit_committed === false && Number.isFinite(response.observed_at) && response.observed_at >= prior.created_at && response.observed_at <= prior.expires_at, 'native_exit_debt_unsettled', 'protected');
    }
  }
  const now = Date.now();
  const request = { version: 1, type: 'cel-reviewer-retirement-request', phase, nonce, name: identity.name, pid: identity.pid, pid_start: identity.pid_start, native_session: identity.agent_session.value, created_at: now, expires_at: now + PROTOCOL_TTL, ...(phase === 'exit' ? { expected_leaf: leaf } : {}) };
  writeProtocol(requestPath, request);
  while (Date.now() <= request.expires_at) {
    let response;
    try { response = protocolFile(responsePath).value; } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (response?.nonce === nonce && response.phase === phase) return { request, response: validateNativeResponse(response, request) };
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Refusal('native_retirement_response_unavailable');
}

function clearSettledRequest(receipt, nonce) {
  const filename = reviewerRetirementPaths(receipt).request;
  if (!fs.existsSync(filename)) return;
  ownedProtocolPaths(receipt);
  const saved = protocolFile(filename);
  if (saved.value.nonce === nonce && saved.value.phase === 'exit') fs.unlinkSync(filename);
}

export async function retire(options) {
  const { repo, pr: number, pane, agent, dry, receipt, wsname, slug, declared = [], githubUser = '', repodir = '' } = options;
  let proofPath;
  const rex = (args, opts) => command(process.env.CEL_REX_BIN || 'rex', ['--autostart=false', ...args], opts);
  const gh = () => {
    const bin = process.env.CEL_WS_GH_BIN || 'gh';
    let token;
    if (githubUser) token = command(bin, ['auth', 'token', '--user', githubUser], { json: false }).trim();
    requireProof(!githubUser || token, 'github_account_unavailable');
    const result = spawnSync(bin, ['pr', 'view', number, '--repo', slug, '--json', 'state,headRefOid,headRefName'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 15000, maxBuffer: 1048576, env: token ? { ...process.env, GH_TOKEN: token } : process.env });
    requireProof(!result.error && result.status === 0, 'github_unavailable');
    const value = JSON.parse(result.stdout);
    requireProof(['OPEN', 'MERGED', 'CLOSED'].includes(value.state) && /^[a-f0-9]{40}$/.test(value.headRefOid) && typeof value.headRefName === 'string' && value.headRefName, 'unknown_remote_pr');
    return value;
  };
  const snapshot = inspect => {
    const saved = jsonFile(receipt, true), r = saved.value;
    const parent = fs.lstatSync(path.dirname(receipt));
    requireProof(parent.isDirectory() && parent.uid === uid && (parent.mode & 0o077) === 0, 'unsafe_receipt_directory');
    requireProof(object(r) && r.name === agent && r.repo === repo && String(r.pr) === number && r.pane_id === pane && r.pane_id === `rex/${r.rex_session}/${r.rex_block}` && r.backend === 'rex' && r.role === 'reviewer', 'receipt_identity_mismatch');
    requireProof(r.agent === 'pi', 'unsupported_native_runtime', 'protected');
    requireProof(['idle', 'done'].includes(r.agent_status), 'reviewer_not_idle', 'protected');
    requireProof(Number.isInteger(r.pid) && r.pid > 1 && typeof r.pid_start === 'string' && path.isAbsolute(r.cwd) && path.isAbsolute(r.workspace) && path.isAbsolute(r.agent_session?.value || ''), 'incomplete_runtime_receipt');
    requireProof(!repodir || path.resolve(repodir) === path.join(r.workspace, 'repos', repo), 'requested_workspace_repository_mismatch');
    // A reviewer exists for one pull request. While it is open, a new push or
    // a re-review request can still arrive: only a merged or closed PR ends it.
    const remote = gh();
    requireProof(remote.state !== 'OPEN', 'pull_request_open', 'protected');
    const tree = descendants(r.pid), root = tree[0];
    requireProof(root.start === r.pid_start && ['pi', 'pi-coding-agent'].includes(root.argv[0]) && ['node', 'pi', 'bun'].some(name => path.basename(root.exe).startsWith(name)), 'runtime_generation_mismatch');
    const env = root.env;
    requireProof(env.CEL_AGENT_NAME === agent && env.CEL_ROLE === 'reviewer' && env.CEL_REX_RECORD === receipt && env.CEL_WORKSPACE === r.workspace && env.CEL_ROOT === process.env.CEL_ROOT && env.CEL_ROLE_FILE === path.join(r.workspace, '.cel', 'reviews', `pr-${number}`, 'role-reviewer.md') && path.isAbsolute(env.PI_CODING_AGENT_DIR || ''), 'runtime_launch_identity_mismatch');
    requireProof(root.cwd === r.cwd || root.cwd === `${r.cwd} (deleted)`, 'runtime_cwd_mismatch');
    const capability = nativeCapability(receipt, r);
    if (inspect) {
      requireProof(protocolIdentity(inspect.response, r), 'native_attestation_receipt_changed', 'protected');
      validateNativeResponse(inspect.response, inspect.request);
    }
    const role = ownedFile(env.CEL_ROLE_FILE, 1024 * 1024);
    const processes = validatedProcessEvidence(tree, r, declared, env.CEL_ROOT);
    const session = rex(['session', 'inspect', r.rex_session, '--json']);
    // Only target topology participates in freshness, not global clients/revision.
    const topology = sessionTopology(session);
    requireProof(topology.id === r.rex_session && topology.windows.length === 1 && topology.windows[0].layers.length === 1 && topology.windows[0].layers[0].length === 1 && topology.windows[0].layers[0][0] === r.rex_block, 'extra_or_unknown_rex_terminals', 'protected');
    const processInfo = rex(['block', 'call', 'process', '{}', '-s', r.rex_session, '-b', r.rex_block]);
    requireProof(processInfo.child?.pid === r.pid && processInfo.foreground?.pid === r.pid, 'rex_foreground_repurposed', 'protected');
    const capture = rex(['block', 'call', 'format', '{"format":"text","trim":true,"unwrap":true,"max_bytes":983040}', '-s', r.rex_session, '-b', r.rex_block]);
    emptyComposer(capture, r.cwd);
    const round = durableRound(r, remote);
    const nativePath = r.agent_session.value;
    requireProof(nativePath.startsWith(`${env.PI_CODING_AGENT_DIR}/sessions/`), 'native_path_outside_launch_root');
    const native = ownedFile(nativePath);
    const parsed = inspect ? parseNative(native.bytes, r.cwd, timestamp(round.round.at), inspect.response.live_leaf) : { id: nativeStructure(native.bytes, r.cwd).header.id };
    const taskCutoff = inspect ? parsed.finalAt : Date.now();
    if (root.cwd.endsWith(' (deleted)')) requireProof(fs.readdirSync(`/proc/${r.pid}/cwd`).length === 0, 'deleted_cwd_contains_untracked_evidence');
    const tasks = taskMetadata(r.cwd, parsed, r.pid, taskCutoff);
    const latestProcess = rex(['block', 'call', 'process', '{}', '-s', r.rex_session, '-b', r.rex_block]);
    requireProof(latestProcess.child?.pid === r.pid && latestProcess.foreground?.pid === r.pid, 'rex_foreground_repurposed', 'protected');
    emptyComposer(rex(['block', 'call', 'format', '{"format":"text","trim":true,"unwrap":true,"max_bytes":983040}', '-s', r.rex_session, '-b', r.rex_block]), r.cwd);
    const count = command('bash', [path.join(env.CEL_ROOT, 'bin/cel'), 'inbox', 'count', '--for', agent, '--all-workspaces', '--workspace', wsname], { json: false }).trim();
    requireProof(/^\d+$/.test(count), 'unknown_mailbox_count');
    requireProof(count === '0', 'pending_reviewer_mail', 'protected');
    const evidence = { receipt: { path: receipt, hash: saved.hash, dev: saved.dev, ino: saved.ino }, identity: r, role: { path: env.CEL_ROLE_FILE, hash: role.hash, size: role.size, encoding: 'base64', contentBase64: role.bytes.toString('base64') }, native: { path: nativePath, hash: native.hash, size: native.size, dev: native.dev, ino: native.ino, ...parsed }, round, remote, tasks, session: topology, ...processes, checkout: { path: r.cwd, kernelCwd: root.cwd, deletedKernelCwd: root.cwd.endsWith(' (deleted)'), repodir } };
    evidence.mail = { alias: agent, workspace: wsname, count: 0 };
    evidence.capability = capability;
    if (inspect) evidence.handshake = { inspect };
    // Mail/API calls can take time. Reject tail, descendants, or terminal writes
    // during those observations; a launch lock is not an idle-state oracle.
    requireProof(ownedFile(receipt, MAX_NATIVE, true).hash === saved.hash && ownedFile(nativePath).hash === native.hash && liveGeneration(root), 'identity_or_native_tail_changed', 'protected');
    requireProof(currentRoundHash(round) === round.hash && JSON.stringify(taskMetadata(r.cwd, parsed, r.pid, taskCutoff)) === JSON.stringify(tasks), 'round_or_background_state_changed', 'protected');
    requireProof(JSON.stringify(validatedProcessEvidence(descendants(r.pid), r, declared, env.CEL_ROOT)) === JSON.stringify(processes), 'descendant_tree_changed', 'protected');
    requireProof(JSON.stringify(sessionTopology(rex(['session', 'inspect', r.rex_session, '--json']))) === JSON.stringify(topology), 'rex_terminal_changed', 'protected');
    return evidence;
  };
  try {
    requireProof(/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(repo) && /^[1-9][0-9]*$/.test(number) && /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(agent) && /^rex\/[^/]+\/[^/]+$/.test(pane), 'invalid_arguments');
    const proofDir = path.join(path.dirname(receipt), 'retirements');
    const completed = path.join(proofDir, `${agent}-${sha(JSON.stringify([repo, number, pane, agent]))}.retired.json`);
    let completion;
    const completedAlreadyRecorded = fs.existsSync(completed);
    if (completedAlreadyRecorded) {
      completion = jsonFile(completed, true).value;
      requireProof(completion.version === 1 && completion.stage === 'retired' && completion.processesExited === true && completion.sessionAbsent === true && completion.nativePrefixPreserved === true && (completion.artifactsPreserved === true || completion.recoveredFromPrepared === true) && path.dirname(completion.prepared) === proofDir, 'unknown_retirement_proof');
    } else if (fs.existsSync(proofDir)) {
      noSymlinks(proofDir);
      const directory = fs.lstatSync(proofDir), files = fs.readdirSync(proofDir);
      requireProof(directory.isDirectory() && directory.uid === uid && (directory.mode & 0o077) === 0 && files.length <= 10000, 'unsafe_retirement_proof_directory');
      for (const filename of files.sort()) {
        if (!filename.endsWith('.json') || filename.endsWith('.retired.json')) continue;
        const candidatePath = path.join(proofDir, filename);
        let saved;
        try { saved = jsonFile(candidatePath, true); } catch { continue; }
        const candidate = saved.value, identity = candidate.identity;
        if (candidate.version !== 1 || candidate.stage !== 'prepared' || identity?.name !== agent || identity.repo !== repo || String(identity.pr) !== number || identity.pane_id !== pane || candidate.receipt?.path !== receipt || !Array.isArray(candidate.processes) || !candidate.processes.length) continue;
        // Interrupted post-close verification must not need a second close.
        // A still-live prepared attempt is NOT retirement authority.
        if (retirementProcessesPresent(candidate)) continue;
        proofPath = candidatePath;
        let nativeExit;
        try { nativeExit = savedExitCommitment(candidatePath, candidate, !dry); } catch { continue; }
        completion = { prepared: candidatePath, preparedHash: saved.hash, recoveredFromPrepared: true, nativeExit: nativeExit.path, nativeExitHash: nativeExit.hash };
        break;
      }
    }
    if (completion) {
      const prepared = jsonFile(completion.prepared, true), original = prepared.value;
      requireProof(prepared.hash === completion.preparedHash && original.version === 1 && original.stage === 'prepared' && original.identity?.name === agent && original.identity.repo === repo && String(original.identity.pr) === number && original.identity.pane_id === pane && original.receipt.path === receipt && original.processes?.length > 0 && original.processes[0].pid === original.identity.pid && original.processes[0].start === original.identity.pid_start, 'retirement_proof_identity_mismatch');
      requireProof(!repodir || path.resolve(repodir) === path.join(original.identity.workspace, 'repos', repo), 'requested_workspace_repository_mismatch');
      proofPath = completion.prepared;
      const nativeExit = savedExitCommitment(proofPath, original, !dry);
      requireProof(completion.nativeExit === nativeExit.path && completion.nativeExitHash === nativeExit.hash, 'native_exit_commitment_changed');
      requireProof(!retirementProcessesPresent(original), 'process_survived_rex_close');
      const containerVisible = sessionPresent(rex, original.identity.rex_session);
      let nativeLengthAfter = nativePrefixPreserved(original), artifactsPreserved = false;
      archivedInstructionsPreserved(original);
      if (containerVisible) {
        requireProof(!completedAlreadyRecorded, 'completed_rex_session_reappeared', 'protected');
        // Resume only this previously accepted native EXIT's empty container.
        // No new native request, verdict, mailbox read, or live-program kill.
        requireProof(JSON.stringify(artifacts(original.checkout.path)) === JSON.stringify(original.artifacts), 'checkout_artifacts_changed', 'protected');
        nativePrefixPreserved(original);
        emptyRexContainer(rex, original);
        requireProof(!retirementProcessesPresent(original), 'native_generation_reappeared');
        if (dry) return { status: 'eligible', reason: 'admitted_empty_rex_container_debt', receipt, proof: proofPath, native: original.native.path, checkout: original.checkout.path, verdict: original.round.path };
        rex(['kill', original.identity.rex_session], { json: false });
        sessionAbsent(rex, original.identity.rex_session);
        nativeLengthAfter = preservedEvidence(original, original.artifacts);
        artifactsPreserved = true;
      }
      if (completion.recoveredFromPrepared && !dry && !fs.existsSync(completed)) {
        saveProof(completed, { version: 1, stage: 'retired', at: new Date().toISOString(), prepared: proofPath, preparedHash: prepared.hash, nativeExit: nativeExit.path, nativeExitHash: nativeExit.hash, processesExited: true, sessionAbsent: true, nativePrefixPreserved: true, artifactsPreserved, containerRemovalFinished: containerVisible, recoveredFromPrepared: true, nativeLengthAfter });
      }
      // This is settlement of an ALREADY stopped exact pane, not a new round
      // grant. New verdicts/mail/native suffixes must not strand the old row.
      let receiptState = 'absent';
      if (fs.existsSync(receipt)) {
        let current;
        try { current = jsonFile(receipt, true); } catch { receiptState = 'unreadable_retained'; }
        if (current) {
          const same = current.hash === original.receipt.hash && current.dev === original.receipt.dev && current.ino === original.receipt.ino;
          receiptState = same ? (dry ? 'original_retained_dry_run' : 'original_removed') : 'replacement_retained';
          if (same && !dry) fs.unlinkSync(receipt);
        }
      }
      if (!dry && original.handshake?.inspect?.request?.nonce) clearSettledRequest(receipt, original.handshake.inspect.request.nonce);
      return { status: 'retired', reason: containerVisible ? 'admitted_empty_rex_container_debt_retired' : completion.recoveredFromPrepared ? 'prepared_retirement_physically_reverified' : 'retirement_reverified', receipt, receiptState, proof: completion.recoveredFromPrepared && dry ? proofPath : completed, prepared: proofPath, native: original.native.path, nativePrefixPreserved: true, nativeLengthAfter, checkout: original.checkout.path, verdict: original.round.path };
    }
    requireProof(!proofPath, 'native_exit_commitment_unavailable');
    requireProof(fs.existsSync(receipt), 'receipt_and_retirement_proof_unavailable');
    requireProof(/^[^/\s]+\/[^/\s]+$/.test(slug) && wsname, 'invalid_workspace_arguments');
    const preflight = snapshot();
    const nonce = crypto.randomUUID();
    const inspect = await nativeHandshake(receipt, preflight.identity, 'inspect', nonce);
    const first = snapshot(inspect);
    requireProof(first.receipt.hash === preflight.receipt.hash && first.native.hash === preflight.native.hash && first.round.hash === preflight.round.hash && JSON.stringify(first.remote) === JSON.stringify(preflight.remote), 'identity_or_round_changed_during_native_inspection', 'protected');
    if (dry) return { status: 'eligible', reason: 'completed_settled_round', receipt, native: first.native.path, checkout: first.checkout.path, verdict: first.round.path };
    const inventory = artifacts(first.checkout.path);
    // The prepared immutable packet is durable BEFORE any irreversible close.
    if (!fs.existsSync(proofDir)) fs.mkdirSync(proofDir, { mode: 0o700 });
    noSymlinks(proofDir);
    const proofStat = fs.lstatSync(proofDir);
    requireProof(proofStat.isDirectory() && proofStat.uid === uid && (proofStat.mode & 0o077) === 0, 'unsafe_retirement_proof_directory');
    const proofStem = path.join(proofDir, `${agent}-${first.identity.pid}-${first.identity.pid_start}-${crypto.randomUUID()}`);
    proofPath = `${proofStem}.json`;
    saveProof(proofPath, { version: 1, stage: 'prepared', at: new Date().toISOString(), ...first, artifacts: inventory });
    requireProof(JSON.stringify(artifacts(first.checkout.path)) === JSON.stringify(inventory), 'checkout_artifacts_changed', 'protected');
    const fresh = snapshot(inspect);
    requireProof(JSON.stringify(fresh) === JSON.stringify(first), 'retirement_identity_or_round_changed', 'protected');
    // The native hook commits a graceful SDK shutdown only after checking its
    // actual live leaf, mailbox and in-memory SDK/inbox debt a final time.
    const exit = await nativeHandshake(receipt, first.identity, 'exit', nonce, first.native.leaf);
    const exitProof = `${proofStem}.exit.json`;
    saveProof(exitProof, { version: 1, stage: 'native-exit-committed', prepared: proofPath, ...exit });
    const deadline = Date.now() + PROTOCOL_TTL;
    while (Date.now() < deadline && retirementProcessesPresent(first)) await new Promise(resolve => setTimeout(resolve, 100));
    requireProof(!retirementProcessesPresent(first), 'native_shutdown_not_observed');
    requireProof(JSON.stringify(protocolFile(ownedProtocolPaths(receipt).response).value) === JSON.stringify(exit.response), 'native_exit_commitment_changed');
    // Only the proven empty Rex container may now be removed. No live native
    // process is ever killed by this backend, even after an exit acknowledgment.
    emptyRexContainer(rex, first);
    requireProof(!retirementProcessesPresent(first), 'native_generation_reappeared');
    rex(['kill', first.identity.rex_session], { json: false });
    sessionAbsent(rex, first.identity.rex_session);
    const nativeLengthAfter = preservedEvidence(first, inventory);
    const current = jsonFile(receipt, true);
    requireProof(current.hash === first.receipt.hash && current.dev === first.receipt.dev && current.ino === first.receipt.ino, 'receipt_rebound_during_close');
    saveProof(completed, { version: 1, stage: 'retired', at: new Date().toISOString(), prepared: proofPath, preparedHash: ownedFile(proofPath, MAX_NATIVE, true).hash, nativeExit: exitProof, nativeExitHash: ownedFile(exitProof, MAX_NATIVE, true).hash, processesExited: true, sessionAbsent: true, nativePrefixPreserved: true, nativeLengthAfter, artifactsPreserved: true });
    // No broad receipt cleanup: only this exact still-owned generation expires.
    fs.unlinkSync(receipt);
    clearSettledRequest(receipt, nonce);
    return { status: 'retired', reason: 'runtime_exited_session_absent_evidence_preserved', receipt, proof: completed, prepared: proofPath, native: first.native.path, checkout: first.checkout.path, verdict: first.round.path };
  } catch (error) {
    return { status: error instanceof Refusal ? error.status : 'unknown', reason: error instanceof Refusal ? error.message : 'unreadable_or_malformed_retirement_evidence', receipt, ...(proofPath ? { proof: proofPath } : {}) };
  }
}

export function checkoutPreserved(checkout, state) {
  try {
    requireProof(path.isAbsolute(checkout) && path.isAbsolute(state), 'invalid_preservation_lookup');
    const directory = path.join(state, 'retirements');
    noSymlinks(directory);
    const stat = fs.lstatSync(directory);
    requireProof(stat.isDirectory() && stat.uid === uid && (stat.mode & 0o077) === 0, 'unsafe_preservation_directory');
    const files = fs.readdirSync(directory);
    requireProof(files.length <= 10000, 'preservation_lookup_too_large');
    for (const filename of files) {
      if (!filename.endsWith('.json') || filename.endsWith('.retired.json')) continue;
      let packet;
      try { packet = jsonFile(path.join(directory, filename), true).value; } catch { continue; }
      const r = packet.identity;
      if (packet.version === 1 && packet.stage === 'prepared' && r?.backend === 'rex' && r.role === 'reviewer' && r.agent === 'pi' && packet.checkout?.path === checkout && r.cwd === checkout && packet.artifacts?.cwd === checkout && packet.receipt?.path === path.join(state, `${r.name}.json`)) return true;
    }
  } catch { /* An unknown lookup is not close authority. */ }
  return false;
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === '--checkout-preserved') {
    process.exitCode = checkoutPreserved(process.argv[3], process.argv[4]) ? 0 : 1;
  } else {
    const [repo, pr, pane, agent, dry, receipt, wsname, slug, helpers = '', githubUser = '', repodir = ''] = process.argv.slice(2);
    const result = await retire({ repo, pr, pane, agent, dry: dry === '1', receipt, wsname, slug, declared: helpers.split('\n').filter(Boolean).map(line => line.split('\t')), githubUser, repodir });
    process.stdout.write(`${JSON.stringify(result)}\n`);
    process.exitCode = result.status === 'retired' || (dry === '1' && result.status === 'eligible') ? 0 : result.status === 'protected' ? 3 : 2;
  }
}
