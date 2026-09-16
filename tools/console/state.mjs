// Everything the console KNOWS, gathered by shelling out to the same CLIs an
// operator would type. No state of its own, no daemon, no cache that can be
// wrong: the dashboard learned this the hard way and the console follows it.
//
// Kept apart from the ink UI on purpose - these functions are what
// `--render-once` prints and what the tests drive, so the panels can be proved
// correct without a terminal.
import { execFile } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

export const CEL_ROOT = process.env.CEL_ROOT || join(homedir(), 'celestial');
export const CEL_BIN = process.env.CEL_BIN || 'cel';
const INBOX_DIR = () => process.env.CEL_INBOX_DIR || join(homedir(), '.local/share/cel/inbox');

export const run = (cmd, args, timeout = 20000) =>
  new Promise((resolve) => {
    execFile(cmd, args, { timeout, maxBuffer: 8 * 1024 * 1024 }, (err, out, errOut) =>
      resolve({ ok: !err, out: String(out || ''), err: String(errOut || (err && err.message) || '') }));
  });

export const fleet = async () => {
  const r = await run(CEL_BIN, ['fleet', '--json']);
  if (!r.ok) return { workspaces: [], error: r.err.trim() || 'cel fleet failed' };
  try { return JSON.parse(r.out); } catch { return { workspaces: [], error: 'cel fleet returned no JSON' }; }
};

// `cel inbox open` is per workspace by design (lib/inbox.sh), so the console
// asks each mailbox in turn rather than inventing a flag in a library it does
// not own. Oldest first: a decision that has been waiting two days belongs
// above one that arrived a minute ago.
export const openItems = async (doc) => {
  const items = [];
  for (const ws of doc.workspaces || []) {
    const r = await run(CEL_BIN, ['inbox', 'open', '--for', 'root', '--workspace', ws.name, '--json']);
    if (!r.ok) continue;
    for (const line of r.out.split('\n')) {
      if (!line.trim()) continue;
      try { items.push({ ws: ws.name, ...JSON.parse(line) }); } catch { /* a half-written line is not an item */ }
    }
  }
  return items.sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
};

// The tail panel reads the mailboxes directly rather than parsing the output of
// `cel inbox watch`: a render-once run has no child to watch, and the file is
// the same thing the watch is tailing. The live TUI still runs the watch - that
// is what raises the desktop notification - and appends its lines on top.
export const inboxTail = (doc, n = 8) => {
  const lines = [];
  for (const ws of doc.workspaces || []) {
    let text;
    try { text = readFileSync(join(INBOX_DIR(), `${ws.name}.jsonl`), 'utf8'); } catch { continue; }
    for (const raw of text.split('\n')) {
      if (!raw.trim()) continue;
      try {
        const m = JSON.parse(raw);
        if (m.kind === 'resolution') continue;
        if (m.to !== 'root' && m.to !== 'all') continue;
        lines.push({ ws: ws.name, ts: m.ts || '', kind: m.kind, from: m.from, message: String(m.message || '').replace(/\n/g, ' ') });
      } catch { /* likewise */ }
    }
  }
  return lines.sort((a, b) => String(a.ts).localeCompare(String(b.ts))).slice(-n);
};

export const tailLine = (m) => `[${m.ws}] ${String(m.ts).slice(0, 16)} ${m.kind} from ${m.from}: ${m.message}`;
export const openLine = (it) => `[${it.id}] ${String(it.ts).slice(0, 16)} ${it.ws} ${it.kind} from ${it.from}: ${it.message}`;

// The rows the fleet panel draws, flattened so the TUI's selection is one
// index into one list rather than a pair of cursors over a nested structure.
export const fleetRows = (doc) => {
  const rows = [];
  for (const ws of doc.workspaces || []) {
    rows.push({ kind: 'ws', ws: ws.name, units: (ws.units || []).length, root: ws.root || { unread: 0, open: 0 } });
    for (const u of ws.units || []) rows.push({ kind: 'unit', ws: ws.name, ...u });
  }
  return rows;
};

// ONE POLICY, TWO SURFACES. The TUI asks lib/guard.sh what the console may run,
// exactly as the claude console's PreToolUse hook does. Re-implementing the
// allowlist in JavaScript would give the box two answers to the same question,
// and the wrong one would be whichever nobody was looking at.
export const classify = async (cmd) => {
  const r = await run('bash', [
    '-c', 'source "$CEL_ROOT/lib/guard.sh"; guard_classify console "$1"', '_', cmd,
  ], 10000);
  const verdict = r.out.trim();
  if (verdict.startsWith('deny')) return { allow: false, reason: verdict.replace(/^deny\s*/, '') };
  if (verdict === 'allow') return { allow: true, reason: '' };
  return { allow: false, reason: 'the guard gave no verdict - refusing' };
};

export const runCommand = async (cmd) => {
  const verdict = await classify(cmd);
  if (!verdict.allow) return { allow: false, reason: verdict.reason, out: '' };
  const r = await run('bash', ['-c', cmd], 120000);
  return { allow: true, reason: '', out: (r.out + (r.err ? `\n${r.err}` : '')).trimEnd(), ok: r.ok };
};

// The whole desk as plain text: `cel console --render-once`. It is what the
// tests assert on and what an operator pipes into a file when something is
// wrong and a full-screen UI is the last thing they want.
export const renderOnce = async () => {
  const doc = await fleet();
  const out = [];
  out.push('FLEET');
  if (doc.error) out.push(`  ! ${doc.error}`);
  for (const ws of doc.workspaces || []) {
    out.push(`  ${ws.name}   (${(ws.units || []).length} repos)   root mail: ${ws.root?.unread ?? 0} unread, ${ws.root?.open ?? 0} open`);
    for (const u of ws.units || []) {
      out.push(`    ${u.name.padEnd(12)} orch ${String(u.orch).padEnd(7)} workers ${u.workers}/${u.cap}   stalled ${u.stalled}   unlanded ${u.unlanded}`);
    }
  }
  const items = await openItems(doc);
  out.push('', 'WAITING ON YOU');
  if (!items.length) out.push('  nothing open');
  for (const it of items) out.push(`  ${openLine(it)}`);

  out.push('', 'INBOX');
  const tail = inboxTail(doc, 8);
  if (!tail.length) out.push('  quiet');
  for (const m of tail) out.push(`  ${tailLine(m)}`);
  return out.join('\n');
};
