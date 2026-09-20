// Everything the console KNOWS, gathered by shelling out to the same CLIs an
// operator would type. No state of its own, no daemon, no cache that can be
// wrong: the dashboard learned this the hard way and the console follows it.
//
// Kept apart from the ink UI on purpose - these functions are what
// `--render-once` prints and what the tests drive, so the panels can be proved
// correct without a terminal.
import { execFile } from 'node:child_process';
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';

import { legend } from './legend.mjs';
import {
  unitLabel, unitView, workerView, fleetTable, openLine, tailLine, workersOf,
  memFree, orphansEdge, sortWorkers, subsEdge, quotaView, timelineView, servicesView,
  afkEdge, afkLogView,
} from './views.mjs';
import { boardFor, prsFor, digestFor, rankedMail, timelineFor } from './board.mjs';

export { memHuman, memFree, memLevel, sortWorkers, subsEdge, subsLevel, quotaView } from './views.mjs';

export { unitLabel, openLine, tailLine } from './views.mjs';
export { afkEdge, afkLogView } from './views.mjs';
export { servicesView, serviceLine, serviceCounts, svcUptime } from './views.mjs';
export { renderOutput } from './views.mjs';

export const CEL_ROOT = process.env.CEL_ROOT || join(homedir(), 'celestial');
export const CEL_BIN = process.env.CEL_BIN || 'cel';
// `cel-fanout` is a skill binary on PATH, not a subcommand of cel: the console
// shells out to exactly what an operator would type, and the tests point this
// at a stub rather than at the live box.
export const FANOUT_BIN = process.env.CEL_FANOUT_BIN || 'cel-fanout';
// herdr is the pane manager; the console shells out to it for the roster and
// - since CEL-36 - for the relay. An env override exists for the same reason
// as the two above: the tests must never reach the live box's panes.
export const HERDR_BIN = process.env.CEL_HERDR_BIN || 'herdr';
const INBOX_DIR = () => process.env.CEL_INBOX_DIR || join(homedir(), '.local/share/cel/inbox');

export const run = (cmd, args, timeout = 20000) =>
  new Promise((resolve) => {
    execFile(cmd, args, { timeout, maxBuffer: 8 * 1024 * 1024 }, (err, out, errOut) =>
      resolve({ ok: !err, out: String(out || ''), err: String(errOut || (err && err.message) || '') }));
  });

// THE ROSTER: the names herdr knows, which is not the same set as the fleet
// document's. A product renamed last month leaves its pane running under the
// old alias, and an operator reading that name off the board should be able
// to address it (CEL-36). Empty on any failure - a console with no roster
// still resolves every name the fleet carries.
export const roster = async () => {
  const r = await run(HERDR_BIN, ['agent', 'list'], 10000);
  if (!r.ok) return [];
  try {
    const doc = JSON.parse(r.out);
    return ((doc.result && doc.result.agents) || []).map((a) => a.name).filter(Boolean);
  } catch { return []; }
};

// AFK rides on the fleet document rather than on a sixth argument to
// `statusRow`. CEL-51's bug was a renderer that forgot to pass one of the
// arguments the edge declared, and the edge the owner asked for twice was
// absent from four views out of five; a fact carried BY THE DOCUMENT cannot be
// forgotten by a call site. Empty on any failure - a console that cannot read
// the AFK state says nothing about it, which is the honest outcome.
export const afkState = async () => {
  const r = await run(CEL_BIN, ['afk', 'status', '--json'], 10000);
  if (!r.ok) return null;
  try { return JSON.parse(r.out); } catch { return null; }
};

export const afkLog = async () => {
  const r = await run(CEL_BIN, ['afk', 'log', '--json'], 10000);
  if (!r.ok) return [];
  return r.out.split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
};

export const fleet = async () => {
  const r = await run(CEL_BIN, ['fleet', '--json']);
  const afk = await afkState();
  if (!r.ok) return { workspaces: [], afk, error: r.err.trim() || 'cel fleet failed' };
  try { return { ...JSON.parse(r.out), afk }; } catch { return { workspaces: [], afk, error: 'cel fleet returned no JSON' }; }
};

// `cel inbox open` is per workspace by design (lib/inbox.sh), so the console
// asks each mailbox in turn rather than inventing a flag in a library it does
// not own. IN TURN, NOT ONE AFTER ANOTHER: four workspaces at 0.05s each were
// a fifth of a second of a render spent waiting on calls that have nothing to
// say to one another, and this file already batches exactly this way where it
// fetches a board and its PRs together. A workspace whose call fails is
// skipped and the rest stand - which is what the `continue` did, and what a
// bare Promise.all would have thrown away.
// Oldest first: a decision that has been waiting two days belongs above one
// that arrived a minute ago.
export const openItems = async (doc) => {
  const wss = doc.workspaces || [];
  const results = await Promise.all(wss.map((ws) =>
    run(CEL_BIN, ['inbox', 'open', '--for', 'root', '--workspace', ws.name, '--json'])
      .catch(() => ({ ok: false, out: '', err: '' }))));
  const items = [];
  results.forEach((r, i) => {
    if (!r.ok) return;
    for (const line of r.out.split('\n')) {
      if (!line.trim()) continue;
      try { items.push({ ws: wss[i].name, ...JSON.parse(line) }); } catch { /* a half-written line is not an item */ }
    }
  });
  return items.sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
};

// The tail panel reads the mailboxes directly rather than parsing the output of
// `cel inbox watch`: a render-once run has no child to watch, and the file is
// the same thing the watch is tailing. The live TUI still runs the watch - that
// is what raises the desktop notification - and appends its lines on top.
// The tail is TODAY'S mail: the last 24 hours of root-addressed lines, newest
// last. The whole history is `cel inbox read`; a week of two retired
// orchestrators reporting every step to root (458 status lines on one box)
// is not a tail, it is an archive, and "▲ 194 more" was the console saying so.
export const TAIL_HOURS = Number(process.env.CEL_CONSOLE_TAIL_HOURS || 24);
export const inboxTail = (doc, n = 8) => {
  const lines = [];
  const since = Date.now() - TAIL_HOURS * 3600 * 1000;
  for (const ws of doc.workspaces || []) {
    let text;
    try { text = readFileSync(join(INBOX_DIR(), `${ws.name}.jsonl`), 'utf8'); } catch { continue; }
    // WHAT CLOSED WHAT, read in the same pass. A tail row is frequently a
    // historical record whose item is already resolved - the steward clears
    // its own blockers when the condition stops being true - and a view that
    // cannot tell offers a [resolve] that can never work.
    const closed = {};
    const records = [];
    for (const raw of text.split('\n')) {
      if (!raw.trim()) continue;
      try {
        const m = JSON.parse(raw);
        if (m.kind === 'resolution') { if (m.ref) closed[m.ref] = { ts: m.ts || '', by: m.by || '' }; continue; }
        records.push(m);
      } catch { /* likewise */ }
    }
    for (const m of records) {
      if (m.kind === 'update') continue;   // rollups: the item carries the count
      if (m.to !== 'root' && m.to !== 'all') continue;
      if ((Date.parse(m.ts) || 0) < since) continue;
      // IDENTITY SURVIVES THE TAIL. This row is a view of a real record and
      // used to arrive without the id it had just parsed, so a detail view
      // opened from the INBOX pane read `id undefined` and its [resolve] did
      // nothing, while the same item opened from WAITING resolved fine.
      lines.push({
        ws: ws.name, id: m.id || '', ts: m.ts || '', kind: m.kind, from: m.from,
        message: String(m.message || '').replace(/\n/g, ' '),
        ...(m.ref ? { ref: m.ref } : {}),
        ...(m.fp ? { fp: m.fp } : {}),
        ...(m.id && closed[m.id] ? { resolved: closed[m.id] } : {}),
      });
    }
  }
  lines.sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
  // The same sender saying the same thing again is one line with a count,
  // not a screen of it: the steward's nudges and a worker's repeated status
  // were most of what the tail showed.
  const out = [];
  for (const l of lines) {
    const p = out[out.length - 1];
    if (p && p.ws === l.ws && p.from === l.from && p.message === l.message) { p.count = (p.count || 1) + 1; p.ts = l.ts; continue; }
    out.push({ ...l, count: 1 });
  }
  return out.slice(-n);
};

// The THREAD behind one waiting item: every other message in that workspace's
// mailbox carrying the same `ref`, plus anything from the same sender within an
// hour either side. The second half is there because most mail on this box has
// no ref at all - a blocker and the status line that explains it arrive four
// minutes apart from the same agent, and showing one without the other is how
// the operator ends up opening a pane to read the rest.
export const thread = (item, span = 3600 * 1000) => {
  if (!item) return [];
  let text;
  try { text = readFileSync(join(INBOX_DIR(), `${item.ws}.jsonl`), 'utf8'); } catch { return []; }
  const centre = Date.parse(item.ts) || 0;
  const out = [];
  for (const raw of text.split('\n')) {
    if (!raw.trim()) continue;
    let m;
    try { m = JSON.parse(raw); } catch { continue; }
    if (m.id === item.id) continue;
    const sameRef = item.ref && m.ref && m.ref === item.ref;
    const near = m.from === item.from && centre
      && Math.abs((Date.parse(m.ts) || 0) - centre) <= span;
    if (!sameRef && !near) continue;
    out.push({ ws: item.ws, ...m });
  }
  return out.sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
};

// --- the command history ----------------------------------------------------
// It lives here rather than in the ink component because `--run` writes to it
// too: a history that only recorded what was typed in the TUI would depend on
// which entry point ran the command, which is not something an operator can
// see or reason about.
export const HISTORY_PATH = () => process.env.CEL_CONSOLE_HISTORY
  || join(homedir(), '.local/share/cel/console/history');
export const HISTORY_MAX = 500;

export const readHistory = () => {
  try { return readFileSync(HISTORY_PATH(), 'utf8').split('\n').filter(Boolean); } catch { return []; }
};

export const appendHistory = (line) => {
  if (!String(line || '').trim()) return;
  try {
    const path = HISTORY_PATH();
    mkdirSync(dirname(path), { recursive: true });
    appendFileSync(path, `${line}\n`);
    const all = readHistory();
    if (all.length > HISTORY_MAX * 1.5) writeFileSync(path, `${all.slice(-HISTORY_MAX).join('\n')}\n`);
  } catch { /* a console that cannot write its history is still a console */ }
};

// A UNIT IS A PRODUCT, not a repo (CEL-14) - unitLabel lives in views.mjs now,
// with the rest of the rendering, and is re-exported above so the TUI's import
// did not have to move house.

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

// A CHAIN IS CHECKED WHOLE, THEN RUN. The model may answer a sentence with a
// sequence, and the operator presses Enter once for the lot - so the allowlist
// has to have seen every line before the first one runs. Interleaving the two
// meant a refusal on line two arrived after line one had already changed the
// box, which is precisely the outcome the guard exists to prevent.
//
// Execution still stops at the first non-zero exit: passing the guard is not
// the same as succeeding, and running step three over a failed step two is how
// a typo becomes a mess someone has to reconstruct.
export const runChain = async (cmds, onStep = () => {}) => {
  const list = (cmds || []).filter((c) => String(c || '').trim());
  for (const cmd of list) {
    // eslint-disable-next-line no-await-in-loop
    const verdict = await classify(cmd);
    if (!verdict.allow) return { allow: false, denied: cmd, reason: verdict.reason, results: [] };
  }
  const results = [];
  for (let i = 0; i < list.length; i += 1) {
    onStep(list[i], i, list.length);
    // eslint-disable-next-line no-await-in-loop
    const r = await runCommand(list[i]);
    results.push({ cmd: list[i], ...r });
    if (!r.ok) return { allow: true, results, stoppedAt: i };
  }
  return { allow: true, results };
};

// The whole desk as plain text: `cel console --render-once`. It is what the
// tests assert on and what an operator pipes into a file when something is
// wrong and a full-screen UI is the last thing they want.
// STATUS AND LEGEND ARE TWO LINES. The v1 console wrote its responses over the
// key legend and never cleared them, so the operator lost their bindings to a
// message from four minutes ago. Here - and in the TUI - the transient line and
// the permanent one are separate rows that cannot overwrite each other.
// THE STATUS LINE'S RIGHT EDGE IS WHERE THE BOX ITSELF SPEAKS. It is the one
// row that belongs to no panel, and the headroom is the fact that changes what
// an operator may do next - there is no point opening a unit view to decide
// whether to delegate when the box has 800 MB left. The subscription windows
// sit beside it for exactly the same reason: a 5h window at 100% means the
// next delegation refuses, whatever the memory says.
//
// CEL-51: THE DOCUMENT AND THE WIDTH ARE BOTH REQUIRED, AND THIS FUNCTION
// REFUSES WITHOUT THE FIRST. CEL-49 landed the subscription edge here and four
// of the five renderers below called `statusRow(status, doc.box)`; JavaScript
// handed the declared third parameter `undefined`, `subsEdge(undefined)`
// answered `''`, and the edge the owner asked for twice was ABSENT from the
// services, unit, worker and timeline views - looking exactly like a box with
// no subscriptions, which is why nobody noticed. A missing document is a
// programming error and it now throws where it is written, rather than drawing
// a row that looks fine on the operator's screen.
export const statusRow = (status, box, doc, width) => {
  if (!doc) throw new TypeError('statusRow: the fleet document is required - the status edge cannot say what it was not given');
  const left = `${status}${status ? `   ${new Date().toTimeString().slice(0, 8)}` : ''}`;
  const mem = memFree(box);
  const subs = subsEdge(doc, renderWidth(width));
  // AFK first after the status: it is the one figure that changes what the
  // rest of the screen means.
  return [left, afkEdge(doc.afk), subs, mem, orphansEdge(box)].filter(Boolean).join('   ');
};

// WHAT IS RUNNING ON A PORT, asked of `cel services` rather than worked out
// here: the declared services and every `try` preview, already joined, already
// probed. One call per workspace, because that is the shape of the command.
// WHERE A TEXT RENDERER LEARNS ITS WIDTH. The ink UI has `stdout.columns` and
// hands it down; these renderers print to whatever `--render-once` was piped
// into, so the terminal says so through COLUMNS or through stdout itself. When
// NEITHER answers, the width is genuinely unknown and stays 0: `usageBar` then
// draws nothing, which is the honest outcome. A guessed 80 would draw a bar
// into a row that may be 40 wide, and a status edge that wraps costs a line of
// the desk - which is the whole reason usageBar has a minimum.
const renderWidth = (width) =>
  Math.floor(Number(width) || Number(process?.env?.COLUMNS) || process?.stdout?.columns || 0);

export const services = async (ws) => {
  const args = ['services', '--json'];
  if (ws) args.push('--workspace', ws);
  const r = await run(CEL_BIN, args, 30000);
  if (!r.ok) return [];
  try { const v = JSON.parse(r.out); return Array.isArray(v) ? v : []; } catch { return []; }
};

// One probe per workspace, all four at once and none of them able to take the
// others down: `services` already answers [] for a failure, and the catch is
// belt and braces for a call that rejects rather than resolving. The keys come
// back in the document's order however the answers arrive.
export const servicesByWorkspace = async (doc) => {
  const wss = doc.workspaces || [];
  const rows = await Promise.all(wss.map((ws) => services(ws.name).catch(() => [])));
  const by = {};
  wss.forEach((ws, i) => { by[ws.name] = rows[i]; });
  return by;
};

export const allServices = async (doc) => {
  const by = await servicesByWorkspace(doc);
  return Object.entries(by).flatMap(([ws, rows]) => rows.map((r) => ({ ...r, ws })));
};

export const renderServices = async ({ status = '' } = {}) => {
  const doc = await fleet();
  const out = servicesView(await allServices(doc));
  out.push('');
  out.push(statusRow(status, doc.box, doc));
  out.push(legend('services'));
  return out.join('\n');
};

export const renderOnce = async ({ status = '', pane = 'fleet' } = {}) => {
  const doc = await fleet();
  const out = fleetTable(doc, await servicesByWorkspace(doc));
  const items = await openItems(doc);
  out.push('', 'WAITING ON YOU');
  if (!items.length) out.push('  nothing open');
  for (const it of items) out.push(`  ${openLine(it)}`);

  out.push('', 'INBOX');
  const tail = inboxTail(doc, 8);
  if (!tail.length) out.push('  quiet');
  for (const m of tail) out.push(`  ${tailLine(m)}`);

  for (const line of afkLogView(doc.afk, doc.afk && doc.afk.on === true ? await afkLog() : [])) out.push(line);

  out.push('');
  out.push(statusRow(status, doc.box, doc));
  out.push(legend(pane));
  return out.join('\n');
};

// `cel console --render-quota`: the QUOTA view as plain text. The same lines
// the ink view draws, for the tests and for a pipe.
export const renderQuota = async () => {
  const doc = await fleet();
  const out = quotaView(doc);
  out.push('', 'API BALANCES');
  const bal = await runCommand('cel quota');
  for (const line of String(bal.out || '').split('\n')) {
    // the subscription block is already above; only the balance table below it
    if (/^\s*(PROVIDER|[a-z0-9-]+\s+[-0-9.]+)/.test(line)) out.push(`  ${line.trim()}`);
  }
  return out.join('\n');
};

// --- depth: one unit, one worker -------------------------------------------
//
// CEL-19 froze `units[].workers_list`; everything below consumes it and
// nothing here computes a verdict of its own. Two places deciding whether a
// worker is stalled is two answers to one question, and the wrong one is
// always the one nobody is looking at.

export const findUnit = (doc, name) => {
  for (const ws of doc.workspaces || []) {
    for (const u of ws.units || []) if (u.name === name) return { ...u, ws: ws.name };
    if (ws.name === name) return null;
  }
  return null;
};

// A worker is found by id across the whole box: the operator says "ABC-49-slug"
// and does not also say which workspace it is in - the console already knows.
export const findWorker = (doc, id) => {
  for (const ws of doc.workspaces || []) {
    for (const u of ws.units || []) {
      for (const w of workersOf(u)) {
        if (w.id === id || w.ticket === id) return { worker: w, unit: { ...u, ws: ws.name }, ws: ws.name };
      }
    }
  }
  return null;
};

// THE DIAGNOSIS, RUN FOR THE OPERATOR RATHER THAN SUGGESTED TO THEM. The whole
// complaint behind this ticket was a console that answered "why is this worker
// stalled" with the name of a command to go and type.
export const why = async (id, ws) => {
  const args = ['why', id];
  if (ws) args.push('--workspace', ws);
  const r = await run(FANOUT_BIN, args, 30000);
  const text = (r.out + (r.err && !r.ok ? `\n${r.err}` : '')).trimEnd();
  return text || (r.ok ? '' : `cel-fanout why failed for ${id}`);
};

export const renderUnit = async (name, { status = '', byMemory = false } = {}) => {
  const doc = await fleet();
  const unit = findUnit(doc, name);
  if (!unit) return null;
  const items = (await openItems(doc)).filter((it) => it.ws === unit.ws);
  const tail = inboxTail({ workspaces: (doc.workspaces || []).filter((w) => w.name === unit.ws) }, 10);
  // THE BOARD AND THE PRS ARE OPTIONAL PANELS. A box with no Linear key and no
  // gh is still a box with a console on it, and the two reads that cross a
  // network must never be able to take the unit view down with them: both
  // answer null when they cannot be had, and a null panel is not drawn at all.
  const repos = (unit.repos || [unit.name]);
  const [board, prs] = await Promise.all([boardFor(unit.ws), prsFor(unit.ws, repos)]);
  const digest = digestFor(unit.ws, { items, repos });
  const out = [unitView({
    unit: { ...unit, workers_list: sortWorkers(workersOf(unit), byMemory) },
    items, tail, board, prs, digest, mail: rankedMail(unit.ws),
  }), ''];
  out.push(statusRow(status, doc.box, doc));
  out.push(legend('unit'));
  return out.join('\n');
};

export const renderWorker = async (id, { status = '' } = {}) => {
  const doc = await fleet();
  const found = findWorker(doc, id);
  if (!found) return null;
  const text = await why(found.worker.id, found.ws);
  const out = [workerView({ worker: found.worker, ws: found.ws, why: text }), ''];
  out.push(statusRow(status, doc.box, doc));
  out.push(legend('worker'));
  return out.join('\n');
};

// THE TIMELINE: the box's events, newest last, from every source at once.
export const renderTimeline = async ({ status = '' } = {}) => {
  const doc = await fleet();
  const events = await timelineFor(doc);
  const out = [timelineView(events), ''];
  out.push(statusRow(status, doc.box, doc));
  out.push(legend('timeline'));
  return out.join('\n');
};

// THE STATE THE MODEL IS ASKED FROM. It is the fleet document whole - which
// since CEL-19 carries every worker, its verdict, its quiet time and its PR -
// plus the open decisions. A model given only counts can only ever answer with
// a command telling the operator to go and look, which is what it did.
export const askState = (doc, items) =>
  `fleet: ${JSON.stringify(doc)}\nopen decisions: ${JSON.stringify(items)}`;
