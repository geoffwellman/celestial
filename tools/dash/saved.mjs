// THE LAST GOOD ANSWER, KEPT ACROSS A RESTART. A restarted dashboard has
// nothing in memory, and the reads behind its slow cards (gh PR lists, `cel
// quota`, `cel solo approvals`, merged-PR counts) take seconds to a minute on
// a busy box. So each good build of a page answer - the v2 snapshot per ws
// filter, /api/state per workspace - is written here, and a cold start serves
// it at once, marked stale with its age, while the fresh build runs.
//
// Only a cold start's first answers read it: nothing here is ever loaded into
// a cache an action reads (decide, restart, send all read live).
//
// NEVER WORSE THAN WHAT IT REPLACES. Each file names the upstream reads that
// had failed when it was built (`failed`: say a repo gh cannot read at all).
// A build is written only when every read failing under it failed under the
// saved one too - so a box with one repo gh never reads still saves, while a
// gh outage, a timed-out `cel quota`, a build that failed outright, never
// replaces the last good answer. A read failing for CEL_DASH_SAVED_SETTLE_MS
// straight (default an hour; a repo moved off GitHub) is how things now are,
// and stops holding saves back.
//
// Private: the directory is 0700 and every file 0600 - it holds what the
// dashboard shows, inbox text and decisions included. Atomic: a file is
// written whole under a temporary name in the same directory, flushed, and
// renamed over the old one, so a reader sees the old answer or the new one,
// never a torn one.
import { openSync, writeSync, fsyncSync, closeSync, renameSync, readFileSync, mkdirSync, chmodSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';

// a ws filter or workspace name as a file name, or nothing at all
const KEY = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

export const createSaved = (dir) => {
  const last = new Map();
  const file = (kind, key) => (KEY.test(String(key || '')) ? join(dir, `${kind}.${key}.json`) : null);
  // { at, failed, v } as last written, or null (none, unreadable, or not ours)
  const read = (kind, key) => {
    const f = file(kind, key);
    if (!f) return null;
    try {
      const d = JSON.parse(readFileSync(f, 'utf8'));
      return d && typeof d.at === 'string' && !Number.isNaN(Date.parse(d.at)) && d.v && typeof d.v === 'object' ? d : null;
    } catch { return null; }
  };
  // A warm answer is rewritten at most once per CEL_DASH_SAVE_EVERY_MS
  // (default a minute) - the restart it is for loses at most that much; the
  // first good build after a start (`force`) is written at once.
  const every = () => Number(process.env.CEL_DASH_SAVE_EVERY_MS ?? 60000);
  const due = (kind, key) => Date.now() - (last.get(`${kind}.${key}`) || 0) >= every();
  // the reads that had failed under the saved answer (none: an older file)
  const known = new Map();
  const failedUnder = (kind, key) => {
    const id = `${kind}.${key}`;
    if (!known.has(id)) { const d = read(kind, key); known.set(id, d ? new Set(Array.isArray(d.failed) ? d.failed : []) : null); }
    return known.get(id);
  };
  // per file, when each read now failing was first seen failing by this process
  const failingSince = new Map();
  const SETTLE = () => Number(process.env.CEL_DASH_SAVED_SETTLE_MS) || 3600000;
  // true when written; `failed` - the reads that had no value under this build
  const write = (kind, key, v, at, { force = false, failed = [] } = {}) => {
    const f = file(kind, key);
    if (!f) return false;
    const id = `${kind}.${key}`;
    const now = Date.now();
    const was = failingSince.get(id) || new Map();
    const since = new Map(failed.map((k) => [k, was.get(k) || now]));
    failingSince.set(id, since);
    if (!force && !due(kind, key)) return false;
    const before = failedUnder(kind, key);
    if (before && failed.some((k) => !before.has(k) && now - since.get(k) < SETTLE())) return false;
    const tmp = `${f}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
    let fd = null;
    try {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      chmodSync(dir, 0o700);
      fd = openSync(tmp, 'wx', 0o600);
      writeSync(fd, JSON.stringify({ at: new Date(at).toISOString(), failed, v }));
      fsyncSync(fd);
      closeSync(fd); fd = null;
      renameSync(tmp, f);
      last.set(id, Date.now());
      known.set(id, new Set(failed));
      return true;
    } catch {
      // a lost save costs the next restart its first paint, never this answer
      if (fd !== null) try { closeSync(fd); } catch { /* already closed */ }
      try { unlinkSync(tmp); } catch { /* never created */ }
      return false;
    }
  };
  return { read, write, due };
};
