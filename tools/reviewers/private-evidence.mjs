import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// REVIEW EVIDENCE IS PRIVATE. retire.mjs refuses a reviewer whose evidence a
// group or other user could write (unsafe_evidence_permissions), and it stays
// that strict. A launch now creates that evidence private whatever the umask
// (lib/run.sh); evidence an earlier launch left group-writable under a umask
// of 002 is tightened here - and only here - when ALL of these hold: the path
// is the root or inside it, no component of it is a symlink, the opened inode
// is a regular file or a directory, and this user owns it. The mode change is
// group/other bits off (0775 -> 0700, 0664 -> 0600), made on the opened inode
// (fchmod), and said on stderr. Anything else is left exactly as it is, which
// retire.mjs then refuses. Nothing here relaxes, waives or replaces a check.
const MAX_ENTRIES = 10000;

function symlinkFree(filename) {
  let current = path.parse(filename).root;
  for (const part of filename.split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    if (fs.lstatSync(current).isSymbolicLink()) return false;
  }
  return true;
}

const octal = mode => (mode & 0o7777).toString(8).padStart(4, '0');

// -> 'tightened' | 'private' | 'absent' | 'outside_root' | 'symlink' | 'not_owned' | 'not_file_or_directory'
export function tighten(root, target, { uid = process.getuid(), log = line => process.stderr.write(`${line}\n`) } = {}) {
  if (!path.isAbsolute(root) || !path.isAbsolute(target)) return 'outside_root';
  root = path.resolve(root); target = path.resolve(target);
  const rel = path.relative(root, target);
  if (rel.startsWith('..') || path.isAbsolute(rel)) return 'outside_root';
  try { fs.lstatSync(target); } catch (error) { if (error.code === 'ENOENT') return 'absent'; throw error; }
  if (!symlinkFree(target)) { log(`cel: left ${target} as it is: a symlink is in its path`); return 'symlink'; }
  let fd;
  try {
    fd = fs.openSync(target, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  } catch (error) {
    if (error.code === 'ELOOP') { log(`cel: left ${target} as it is: it is a symlink`); return 'symlink'; }
    throw error;
  }
  try {
    const st = fs.fstatSync(fd);
    if (!st.isFile() && !st.isDirectory()) { log(`cel: left ${target} as it is: not a file or directory`); return 'not_file_or_directory'; }
    if (st.uid !== uid) { log(`cel: left ${target} as it is: owned by uid ${st.uid}, not this user`); return 'not_owned'; }
    if ((st.mode & 0o077) === 0) return 'private';
    const mode = st.mode & 0o700;
    fs.fchmodSync(fd, mode);
    log(`cel: tightened review evidence ${target} from ${octal(st.mode)} to ${octal(mode)} (yours, no symlink, under ${root})`);
    return 'tightened';
  } finally { fs.closeSync(fd); }
}

// <workspace>/.cel/reviews, its pr-<n> and everything in that, parents first:
// once a directory is private nobody else can swap what is inside it.
export function tightenReviewEvidence(workspace, pr, options = {}) {
  if (!path.isAbsolute(workspace) || !/^[1-9][0-9]*$/.test(String(pr))) return [];
  const root = path.join(workspace, '.cel', 'reviews');
  const results = [];
  const visit = target => {
    const status = tighten(root, target, options);
    results.push({ path: target, status });
    return status;
  };
  visit(root);
  const queue = [path.join(root, `pr-${pr}`)];
  while (queue.length && results.length < MAX_ENTRIES) {
    const target = queue.shift();
    if (!['tightened', 'private'].includes(visit(target))) continue;
    if (!fs.lstatSync(target).isDirectory()) continue;
    for (const name of fs.readdirSync(target).sort()) queue.push(path.join(target, name));
  }
  return results;
}

// The live reviewer's own launch says where Pi keeps its sessions; only a
// runtime of this receipt's exact generation, owned by this user and marked
// with this receipt, is asked.
function launchAgentDir(r, receipt, uid) {
  if (!Number.isInteger(r.pid) || r.pid <= 1 || typeof r.pid_start !== 'string') return '';
  try {
    const stat = fs.readFileSync(`/proc/${r.pid}/stat`, 'utf8');
    if (stat.slice(stat.lastIndexOf(') ') + 2).trim().split(/\s+/)[19] !== r.pid_start) return '';
    if (Number(fs.readFileSync(`/proc/${r.pid}/status`, 'utf8').match(/^Uid:\s+(\d+)/m)?.[1]) !== uid) return '';
    const env = {};
    for (const entry of fs.readFileSync(`/proc/${r.pid}/environ`, 'utf8').split('\0')) {
      const equal = entry.indexOf('=');
      const key = entry.slice(0, equal);
      if (['CEL_ROLE', 'CEL_REX_RECORD', 'PI_CODING_AGENT_DIR'].includes(key)) env[key] = entry.slice(equal + 1);
    }
    if (env.CEL_ROLE !== 'reviewer' || env.CEL_REX_RECORD !== receipt || !path.isAbsolute(env.PI_CODING_AGENT_DIR || '')) return '';
    return env.PI_CODING_AGENT_DIR;
  } catch { return ''; }
}

// Before a retirement: this receipt's review evidence and its native session
// (the session file and its own directory under <agent dir>/sessions/).
export function tightenForRetirement(receipt, options = {}) {
  const uid = options.uid ?? process.getuid();
  if (!path.isAbsolute(receipt) || !symlinkFree(receipt)) return [];
  const st = fs.lstatSync(receipt);
  if (!st.isFile() || st.uid !== uid || (st.mode & 0o077) !== 0) return [];
  const r = JSON.parse(fs.readFileSync(receipt, 'utf8'));
  if (!r || r.role !== 'reviewer' || r.backend !== 'rex' || r.agent !== 'pi' || !path.isAbsolute(r.workspace || '')) return [];
  const results = tightenReviewEvidence(r.workspace, r.pr, options);
  const native = r.agent_session?.value, dir = launchAgentDir(r, receipt, uid);
  if (dir && typeof native === 'string' && path.isAbsolute(native) && native.endsWith('.jsonl')) {
    const sessions = path.join(dir, 'sessions');
    const rel = path.relative(sessions, path.resolve(native)).split(path.sep);
    if (rel.length === 2 && rel.every(part => part && part !== '..')) {
      for (const target of [path.join(sessions, rel[0]), path.join(sessions, rel[0], rel[1])]) {
        const status = tighten(sessions, target, options);
        results.push({ path: target, status });
        if (!['tightened', 'private'].includes(status)) break;
      }
    }
  }
  return results;
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, ...args] = process.argv.slice(2);
  try {
    if (mode === 'launch' && args.length === 2) tightenReviewEvidence(args[0], args[1]);
    else if (mode === 'retirement' && args.length === 1) tightenForRetirement(args[0]);
    else { process.stderr.write('usage: private-evidence.mjs launch <workspace> <pr> | retirement <receipt>\n'); process.exitCode = 64; }
  } catch (error) {
    // Nothing was loosened: whatever stayed group-writable, retire.mjs refuses.
    process.stderr.write(`cel: could not tighten review evidence: ${error?.code || error?.message || error}\n`);
    process.exitCode = 1;
  }
}
