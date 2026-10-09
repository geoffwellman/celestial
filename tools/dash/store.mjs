// CEL-116: PARSE ONCE, KEEP WARM. A dashboard refresh asked eleven feeds at
// once and each one re-read and re-parsed whole inbox files (one was 5 MB)
// and ledgers, several times over - on a loaded box that was seconds per
// card. Here a file is parsed once and kept, keyed by path, and looked at
// again only when its size, mtime or inode moves. Inboxes are append-only, so
// growth reads only the appended tail; a shrink, a new inode or a changed
// head (a ring rewritten in place) is a full reload.
import { statSync, openSync, readSync, closeSync, readFileSync } from 'node:fs';

const HEAD = 64;
const sig = (f) => { try { const s = statSync(f); return { size: s.size, mtime: s.mtimeMs, ino: s.ino }; } catch { return null; } };
const readRange = (f, from, len) => {
  const buf = Buffer.alloc(len);
  const fd = openSync(f, 'r');
  try { let n = 0; while (n < len) { const r = readSync(fd, buf, n, len - n, from + n); if (!r) break; n += r; } return buf.subarray(0, n); } finally { closeSync(fd); }
};
const parseLines = (text) => {
  const out = [];
  for (const l of text.split('\n')) { if (!l) continue; try { const v = JSON.parse(l); if (v) out.push(v); } catch { /* a torn line */ } }
  return out;
};

export const createStore = () => {
  const jl = new Map();
  const js = new Map();
  const same = (e, s) => e && e.ino === s.ino && e.size === s.size && e.mtime === s.mtime;
  // rows of a JSONL file; the returned array is shared - callers must not mutate it
  const jsonl = (f) => {
    const s = sig(f);
    if (!s) { jl.delete(f); return []; }
    const e = jl.get(f);
    if (same(e, s)) return e.rows;
    try {
      if (e && e.ino === s.ino && s.size > e.size && e.head.equals(readRange(f, 0, Math.min(HEAD, e.size)))) {
        // the tail only; a line still being written waits in `partial`
        const text = e.partial + readRange(f, e.size, s.size - e.size).toString('utf8');
        const cut = text.lastIndexOf('\n') + 1;
        const rows = e.rows.concat(parseLines(text.slice(0, cut)));
        jl.set(f, { ...s, head: e.head.length >= HEAD ? e.head : readRange(f, 0, Math.min(HEAD, s.size)), rows, partial: text.slice(cut) });
        return rows;
      }
      const buf = readFileSync(f);
      const text = buf.toString('utf8');
      const cut = text.lastIndexOf('\n') + 1;
      // a final line with no newline yet is one still being written
      const rows = parseLines(text.slice(0, cut));
      jl.set(f, { ...s, size: buf.length, head: buf.subarray(0, Math.min(HEAD, buf.length)), rows, partial: text.slice(cut) });
      return rows;
    } catch { jl.delete(f); return []; }
  };
  // a whole-JSON file (a ledger); null when missing or unparsable
  const json = (f) => {
    const s = sig(f);
    if (!s) { js.delete(f); return null; }
    const e = js.get(f);
    if (same(e, s)) return e.v;
    let v = null;
    try { v = JSON.parse(readFileSync(f, 'utf8')); } catch { v = null; }
    js.set(f, { ...s, v });
    return v;
  };
  return { jsonl, json };
};

// one per process: the classic page and v2 read the same files
export const store = createStore();
