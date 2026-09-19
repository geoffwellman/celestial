// The views that have depth, and the rule that the console never shows raw JSON.
//
// Split out of state.mjs and ui.mjs on purpose: these are pure functions from
// data to text. `--render-once --unit bundle` prints exactly what the ink
// unit view draws, the tests assert on the text, and a column that goes
// missing goes missing in a test rather than in front of an operator.
//
// The owner, 2026-09-18, after an evening with the console: "when I click on
// items in the fleet panel it gives me an output box with JSON"; "I'm unable
// to learn what's going on at anything more than surface level". Both of those
// are this file - a list you can enter, and output the console renders because
// it already knows the shape of everything it runs.

// A UNIT IS A PRODUCT, not a repo (CEL-14). A declared product names the repos
// it bundles, exactly as `cel fleet` does - without it the one row where a
// product and a repo of the same name differ is the row that looks identical.
export const unitLabel = (u) => (u && u.declared && (u.repos || []).length
  ? `${u.name} (${u.repos.join(', ')})`
  : String(u?.name || ''));

// Quiet time in the unit an operator thinks in. Seconds are noise at this
// scale: nobody decides anything differently because a worker has been silent
// for 812 seconds rather than 800.
export const quiet = (secs) => {
  const s = Math.max(0, Number(secs) || 0);
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  return `${Math.floor(m / 60)}h${String(m % 60).padStart(2, '0')}m`;
};

// The PR as a NUMBER. A full GitHub URL in a table column pushes every other
// column off the right edge, and the number is the thing anyone says out loud.
export const prNumber = (url) => {
  const m = /\/pull\/(\d+)/.exec(String(url || ''));
  return m ? `#${m[1]}` : '';
};

// MEGABYTES AS AN OPERATOR SAYS THEM: `370M`, `6.9G`, `24G`. One decimal
// under ten gigabytes because 6G and 6.9G are a gigabyte apart, none above it
// because nobody says "24.0 gigs". The same rule as lib/memory.sh's
// `mem_human`, deliberately duplicated: the console renders from the fleet
// document and shelling out to bash to format a number would cost a process
// per row.
//
// ABSENT IS NOT ZERO. An older `cel` on PATH carries no `box` block and no
// `rss_mb`, and `mem 0M` claims a measurement nobody made - so the empty
// string is the answer and the caller leaves the column out.
export const memHuman = (mb) => {
  if (mb === null || mb === undefined || mb === '' || Number.isNaN(Number(mb))) return '';
  const n = Math.max(0, Math.round(Number(mb)));
  if (n < 1024) return `${n}M`;
  const g = n / 1024;
  return g >= 10 ? `${Math.round(g)}G` : `${g.toFixed(1)}G`;
};

// The box's headroom as the status edge shows it, or nothing at all.
export const memFree = (box) => {
  const free = memHuman(box?.available_mb);
  return free ? `mem ${free} free` : '';
};

// The processes with no owner at all, when there are any. A gigabyte of
// reparented watchers, dead-worktree fixtures and shells on ptys nobody can
// reach sat unmentioned on this box for four days while the status edge
// showed the headroom they were eating; the edge names them now, with the
// command that takes them away. SILENT AT ZERO - a permanent "0 orphans" is
// a row that teaches an operator to stop reading the row.
export const orphansEdge = (box) => {
  const n = Number(box?.orphans?.count || 0);
  if (!(n > 0)) return '';
  return `${n} orphans ${memHuman(box?.orphans?.rss_mb) || '0M'} - cel gc --orphans`;
};

// How alarmed to be. Under 15% available the box is about to start refusing
// things; under 8% the kernel is minutes from choosing what dies, and what it
// picks is never what anyone would have chosen.
export const memLevel = (box) => {
  const total = Number(box?.total_mb || 0);
  const avail = Number(box?.available_mb || 0);
  if (total <= 0) return 'none';
  const pct = (avail * 100) / total;
  if (pct < 8) return 'bad';
  if (pct < 15) return 'warn';
  return 'ok';
};

// `s` in the unit view. BIGGEST FIRST, because the question the sort answers
// is "which one do I collect". A copy, never the caller's array: the TUI holds
// the fleet document across renders and sorting it in place would silently
// reorder every other view of the same workers.
// The order the eye needs: what is WRONG first (a verdict), then what is
// running, then what is finished and waiting to be collected, then what is
// collected and waiting to be landed or released. Inside a group the newest
// first. Ledger order - the order tickets happened to be delegated in over
// three weeks - told the operator nothing, and the screenshot that said so
// had twenty-six rows of it.
const STATE_RANK = { blocked: 0, running: 1, finished: 2, collected: 3 };
export const sortWorkers = (workers, byMemory = false) => {
  const list = [...(workers || [])];
  if (byMemory) {
    // An unmeasured worker sorts LAST rather than above a measured one: -1 for
    // absent would put "we do not know" at the top of a list about size.
    return list.sort((a, b) => Number(b.rss_mb ?? -1) - Number(a.rss_mb ?? -1));
  }
  const rank = (w) => (w.verdict ? -1 : (STATE_RANK[w.state] ?? 9));
  return list.sort((a, b) => rank(a) - rank(b) || String(b.created || '').localeCompare(String(a.created || '')));
};

// Column widths, shared by the TUI panel and the text view so they cannot
// drift. A cell is CUT to its width, never allowed to push its neighbours:
// one forty-four-character scout id used to shove every column off the edge.
export const WORKER_COLS = { ticket: 9, slug: 20, state: 9, live: 7, via: 18, quiet: 6, verdict: 10, ahead: 5, rss: 6 };
// What is running the ticket: the profile name when the delegation recorded
// one (`opus-pi`, `deepseek`), else runtime/model with the provider prefix
// and version tail dropped (`omp/deepseek-v4.1-flash` → `omp/deepseek`).
export const viaOf = (w) => {
  // HARNESS FIRST, always: the owner asked twice. The roster's agent kind
  // (pi, omp, claude, hermes) or the ledger's runtime, then the profile name
  // or the model with provider prefix and version tail dropped.
  const h = String(w.harness || w.runtime || '');
  // `default` is a profile NAME that says nothing; the model behind it does.
  let tail = String(w.profile || '');
  if (tail === 'default') tail = '';
  if (!tail) tail = String(w.model || '').split('/').pop().split('-').filter((x) => !/^v?\d/.test(x)).join('-');
  if (h && tail) return `${h}/${tail}`;
  return h || tail || '-';
};
export const cut = (s, n) => { s = String(s ?? ''); return s.length > n ? `${s.slice(0, Math.max(0, n - 1))}…` : s; };
// The id minus its ticket prefix: `ABC-146-gradient-px` reads as `gradient-px`
// beside the ABC-146 column; an adhoc id is shown whole.
export const slugOf = (w) => {
  const id = String(w.id || ''); const t = String(w.ticket || '');
  return t && id.toLowerCase().startsWith(`${t.toLowerCase()}-`) ? id.slice(t.length + 1) : id;
};
export const workerHeader = () => [
  'ticket'.padEnd(WORKER_COLS.ticket), 'worker'.padEnd(WORKER_COLS.slug), 'state'.padEnd(WORKER_COLS.state),
  'live'.padEnd(WORKER_COLS.live), 'via'.padEnd(WORKER_COLS.via), 'quiet'.padStart(WORKER_COLS.quiet), '  ' + 'verdict'.padEnd(WORKER_COLS.verdict),
  'ahead'.padEnd(WORKER_COLS.ahead), 'rss'.padStart(WORKER_COLS.rss), ' pr',
].join(' ');

export const workersOf = (unit) => (unit && Array.isArray(unit.workers_list) ? unit.workers_list : []);

// One worker, one line: ticket, id, state, agent, quiet, verdict, ahead, what
// it is holding, PR. The order is the order the questions arrive in - what is
// it, is it alive, how long has it been quiet, is that bad, what does it cost.
export const workerCells = (w) => ({
  ticket: cut(w.ticket || '-', WORKER_COLS.ticket).padEnd(WORKER_COLS.ticket),
  slug: cut(slugOf(w), WORKER_COLS.slug).padEnd(WORKER_COLS.slug),
  state: cut(w.state || '-', WORKER_COLS.state).padEnd(WORKER_COLS.state),
  live: cut(w.live || '-', WORKER_COLS.live).padEnd(WORKER_COLS.live),
  via: cut(viaOf(w), WORKER_COLS.via).padEnd(WORKER_COLS.via),
  quiet: quiet(w.quiet_secs).padStart(WORKER_COLS.quiet),
  verdict: `  ${cut(w.verdict || '-', WORKER_COLS.verdict).padEnd(WORKER_COLS.verdict)}`,
  ahead: String(w.ahead ?? '?').padEnd(WORKER_COLS.ahead),
  rss: (memHuman(w.rss_mb) || '-').padStart(WORKER_COLS.rss),
  pr: ` ${prNumber(w.pr) || '-'}`,
});
export const workerLine = (w) => Object.values(workerCells(w)).join(' ');

export const openLine = (it) => `[${it.id}] ${String(it.ts).slice(0, 16)} ${it.ws} ${it.kind} from ${it.from}: ${it.message}`;
export const tailLine = (m) => `[${m.ws}] ${String(m.ts).slice(0, 16)} ${m.kind} from ${m.from}: ${m.message}`;

// --- section 1: the unit view ----------------------------------------------

export const unitView = ({
  unit, items = [], tail = [], board = null, prs = null, digest = '', now = Date.now(),
}) => {
  const ws = unit.ws || '';
  const out = [];
  out.push(`UNIT ${unitLabel(unit)}   workspace ${ws}`);
  // THE DIGEST SITS UNDER THE HEADER, not in a panel of its own: it is one
  // line, and it answers the question an operator arrives with - what happened
  // while I was not looking - before they have read anything else.
  if (digest) out.push(digest);
  out.push('');
  out.push('ORCHESTRATOR');
  out.push(`  ${unit.name}-orch   ${unit.orch}   pane ${unit.pane || '-'}   slots ${unit.workers}/${unit.cap}`
    + `${memHuman(unit.orch_rss_mb) ? `   mem ${memHuman(unit.orch_rss_mb)}` : ''}`);
  out.push(`  workspace ${ws}   repos ${(unit.repos || []).join(', ') || '-'}`);
  out.push('  [focus]  [message]');
  out.push('');
  out.push('WORKERS');
  out.push(`  ${workerHeader()}`);
  const workers = workersOf(unit);
  if (!workers.length) out.push('  no workers');
  for (const w of workers) out.push(`  ${workerLine(w)}`);
  // THE BOARD AND THE PRS, between what the box is running and what is waiting
  // on the operator: the tickets are where work comes from and the pull
  // requests are where it leaves, and a console with neither could say how
  // busy the fleet was and nothing about whether it was getting anywhere.
  // `null` means the panel was not asked for; an empty list means it was asked
  // and there is nothing, which is a different sentence.
  if (board) {
    out.push('');
    out.push('BOARD');
    const groups = boardGroups(board);
    if (!groups.length) out.push('  nothing on the board');
    for (const g of groups) {
      out.push(`  ${g.state}`);
      for (const r of g.rows) out.push(`    ${boardLine(r, workerForTicket(workers, r.identifier), now)}`);
    }
  }
  if (prs) {
    out.push('');
    out.push('PRS');
    if (!prs.length) out.push('  no open pull requests');
    for (const p of prs) out.push(`  ${prLine(p, now)}`);
  }
  out.push('');
  out.push('WAITING');
  if (!items.length) out.push('  nothing open');
  for (const it of items) out.push(`  ${openLine(it)}`);
  out.push('');
  out.push('RECENT MAIL');
  if (!tail.length) out.push('  quiet');
  for (const m of tail) out.push(`  ${tailLine(m)}`);
  return out.join('\n');
};

// --- CEL-25: the board, the pull requests, the digest and the timeline ------
//
// The owner, 2026-09-18, after two days with the console: "it can be a lot
// more informative yet, and it doesn't really feel like I can steer anything
// from there". What was on screen was the FLEET'S OWN state - workers,
// decisions, mail. What an operator actually steers by - the ticket board, the
// open pull requests, what changed since they last looked - was not there at
// all, so every one of those questions meant leaving the console.

// An age the way it gets said out loud. Minutes under an hour, hours under two
// days, days after that: nobody decides anything differently because a PR was
// updated 47 hours ago rather than two days ago, and `47h` makes them do the
// arithmetic to find out.
export const ago = (iso, now = Date.now()) => {
  const t = Date.parse(iso || '');
  if (!t) return '-';
  const m = Math.max(0, Math.round((now - t) / 60000));
  if (m < 60) return `${m}m`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h}h`;
  return `${Math.round(h / 24)}d`;
};

// GROUPED IN THE ORDER THE BOARD GAVE THEM. `cel-linear board` already sorts
// by the team's workflow position, so re-deciding the order here would be the
// console and Linear disagreeing about what comes before what - and the
// console would be the one that is wrong, because the workflow is the team's.
export const boardGroups = (rows) => {
  const out = [];
  for (const r of rows || []) {
    const state = String(r.state || '-');
    let g = out.find((x) => x.state === state);
    if (!g) { g = { state, rows: [] }; out.push(g); }
    g.rows.push(r);
  }
  return out;
};

export const BOARD_COLS = { id: 9, state: 12, who: 22, age: 4, title: 44 };

// The worker on a ticket, when the fleet has one. The board says what the team
// thinks is happening; this column says what the box is actually doing about
// it, and the gap between the two is most of what an operator is looking for.
export const workerForTicket = (workers, ticket) => (workers || [])
  .find((w) => String(w.ticket || '').toUpperCase() === String(ticket || '').toUpperCase()) || null;

export const boardLine = (row, worker = null, now = Date.now()) => [
  cut(row.identifier || '-', BOARD_COLS.id).padEnd(BOARD_COLS.id),
  cut(row.state || '-', BOARD_COLS.state).padEnd(BOARD_COLS.state),
  cut(worker ? `@${worker.alias || worker.id}` : (row.assignee || '-'), BOARD_COLS.who).padEnd(BOARD_COLS.who),
  ago(row.updatedAt, now).padStart(BOARD_COLS.age),
  cut(row.title || '', BOARD_COLS.title),
].join('  ');

// GREEN, RED, OR NOT YET. A rollup entry with no conclusion is a check still
// running, and calling that green is how `land` gets pressed on a PR whose
// gate is thirty seconds away from failing.
export const ciState = (pr) => {
  const rows = Array.isArray(pr && pr.statusCheckRollup) ? pr.statusCheckRollup : [];
  if (!rows.length) return 'none';
  let pending = false;
  for (const c of rows) {
    const v = String(c.conclusion || '').toUpperCase();
    if (['FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED'].includes(v)) return 'fail';
    if (!v) pending = true;
  }
  return pending ? 'pending' : 'pass';
};
const CI_MARK = { pass: '\u2713', fail: '\u2717', pending: '\u00b7', none: '-' };

export const PR_COLS = { num: 5, branch: 24, review: 20, ci: 5, age: 4, title: 40 };

// A draft says DRAFT and nothing about review: a draft with no reviewer on it
// is not "review -", it is work its author has not offered to anyone yet.
export const reviewOf = (pr) => (pr.isDraft ? 'draft' : `review ${pr.reviewDecision || '-'}`);

export const prLine = (pr, now = Date.now()) => [
  `#${pr.number}`.padEnd(PR_COLS.num),
  cut(pr.headRefName || '-', PR_COLS.branch).padEnd(PR_COLS.branch),
  cut(reviewOf(pr), PR_COLS.review).padEnd(PR_COLS.review),
  `ci ${CI_MARK[ciState(pr)]}`.padEnd(PR_COLS.ci),
  ago(pr.updatedAt, now).padStart(PR_COLS.age),
  cut(pr.title || '', PR_COLS.title),
].join('  ');

// The worker row under a detail view, or a line saying there is none. A ticket
// the board shows with no delegation behind it is the most common reason an
// operator opens the detail at all.
const workerBlock = (worker) => (worker
  ? [`WORKER ${worker.id}`, `  ${workerHeader()}`, `  ${workerLine(worker)}`]
  : ['WORKER', '  no delegation for this one']);

export const ticketView = ({ ticket, worker = null, ws = '' }) => {
  const out = [];
  out.push(`TICKET ${ticket.identifier}   ${ticket.state || '-'}   workspace ${ws}`);
  out.push(`  ${ticket.title || ''}`);
  out.push(`  ${ticket.url || ''}`);
  out.push('');
  out.push('DESCRIPTION');
  // THE HEAD, not the whole thing. A Linear description runs to pages and the
  // panel it lands in is eight rows; the detail view is somewhere to decide
  // from, and `[open]` is one key away for the rest.
  const head = String(ticket.description || '').split('\n').filter(Boolean).slice(0, 4);
  if (!head.length) out.push('  (no description)');
  for (const l of head) out.push(`  ${cut(l, 100)}`);
  out.push('');
  out.push('LAST COMMENTS');
  const comments = (ticket.comments || []).slice(-2);
  if (!comments.length) out.push('  none');
  for (const c of comments) {
    out.push(`  ${String(c.createdAt || '').slice(0, 16)} ${c.user || '-'}: ${cut(String(c.body || '').replace(/\s+/g, ' '), 100)}`);
  }
  out.push('');
  out.push(...workerBlock(worker));
  out.push('');
  out.push('[start]  [move]  [open]');
  return out.join('\n');
};

export const prView = ({ pr, worker = null, ws = '', now = Date.now() }) => {
  const out = [];
  out.push(`PR #${pr.number} ${pr.repo || '-'}   ${pr.headRefName || '-'}   ${ago(pr.updatedAt, now)}   workspace ${ws}`);
  out.push(`  ${pr.title || ''}`);
  out.push('');
  out.push('CHECKS');
  const checks = Array.isArray(pr.statusCheckRollup) ? pr.statusCheckRollup : [];
  if (!checks.length) out.push('  none reported');
  for (const c of checks) {
    out.push(`  ${cut(c.name || c.context || '-', 30).padEnd(30)} ${c.conclusion || c.status || 'pending'}`);
  }
  out.push('');
  out.push('REVIEW');
  out.push(`  ${pr.isDraft ? 'draft - not offered for review yet' : (pr.reviewDecision || 'no decision yet')}`);
  out.push('');
  out.push(...workerBlock(worker));
  out.push('');
  out.push('[land]  [open]  [review]');
  return out.join('\n');
};

// The clock off an ISO string WITHOUT going through a local timezone. The
// digest and the timeline are read against each other and against the mail
// they were built from; rendering one in the box's zone and the other in the
// string's is how 12:47 and 13:47 end up on the same screen.
export const clock = (iso) => (/T(\d\d:\d\d)/.exec(String(iso || '')) || [])[1] || '--:--';

// SINCE YOU LAST LOOKED, in one line. A count alone ("3 status") says that
// something happened and not what, so the newest message of the biggest group
// travels with it: the operator either recognises it and moves on, or opens
// the panel it came from.
export const digestLine = ({ since, mail = [], merged = 0, waiting = 0 }) => {
  const parts = [];
  const groups = [];
  for (const m of mail) {
    const key = `${m.kind}\u0000${m.from}`;
    let g = groups.find((x) => x.key === key);
    if (!g) { g = { key, kind: m.kind, from: m.from, n: 0, last: '' }; groups.push(g); }
    g.n += 1;
    g.last = String(m.message || '').replace(/\s+/g, ' ');
  }
  groups.sort((a, b) => b.n - a.n);
  if (groups.length) {
    const g = groups[0];
    parts.push(`${g.n} ${g.kind} from ${g.from}${g.last ? ` (last: "${cut(g.last, 60)}")` : ''}`);
    const rest = groups.slice(1).reduce((n, x) => n + x.n, 0);
    if (rest) parts.push(`${rest} more`);
  }
  if (merged) parts.push(`${merged} PR${merged === 1 ? '' : 's'} merged`);
  if (waiting) parts.push(`${waiting} decision${waiting === 1 ? '' : 's'} waiting`);
  return `since ${clock(since)}: ${parts.length ? parts.join(' \u00b7 ') : 'nothing new'}`;
};

// --- the timeline ----------------------------------------------------------

export const TIMELINE_COLS = { ws: 10, kind: 10 };

export const timelineLine = (e) => [
  clock(e.ts),
  cut(e.ws || '-', TIMELINE_COLS.ws).padEnd(TIMELINE_COLS.ws),
  cut(e.kind || '-', TIMELINE_COLS.kind).padEnd(TIMELINE_COLS.kind),
  String(e.what || ''),
].join(' ');

// NEWEST LAST. Every other list in this console is newest-first because it is
// a queue you work down; the timeline is a story, and a story read upwards is
// why the operator kept scrolling to find where they had got to.
export const timelineSort = (events) => [...(events || [])]
  .sort((a, b) => String(a.ts).localeCompare(String(b.ts)));

export const timelineView = (events, sel = -1) => {
  const rows = timelineSort(events);
  const out = ['TIMELINE'];
  if (!rows.length) out.push('  nothing yet');
  rows.forEach((e, i) => out.push(`${i === sel ? '>' : ' '} ${timelineLine(e)}`));
  return out.join('\n');
};

// --- section 2: the worker view, which is the answer to "why" ---------------

export const workerFacts = (w) => `${w.id} (${w.ticket}, ${w.repo}) - ${w.state}, agent ${w.live}`
  + `${memHuman(w.rss_mb) ? `, ${memHuman(w.rss_mb)} resident` : ''}`
  + `, ${w.verdict ? `${w.verdict}${w.severity ? ` (${w.severity})` : ''}` : 'no stall'}`;

// `[try]` only where a preview exists: a button that always fails is a button
// that teaches the operator not to trust the row of them.
export const workerButtons = (preview = false) => [
  '[prompt]', '[focus]', '[collect]', '[release]',
  ...(preview ? ['[try]'] : []),
  '[why again]',
];

export const workerView = ({ worker, ws = '', why = '', preview = false }) => {
  const out = [];
  out.push(`WORKER ${workerFacts(worker)}`);
  out.push(`  quiet ${quiet(worker.quiet_secs)}   ahead ${worker.ahead ?? '?'}   branch ${worker.branch || '-'}`
    + `   PR ${prNumber(worker.pr) || 'none'}   workspace ${ws}`);
  out.push('');
  out.push('WHY');
  const body = String(why || '').trimEnd();
  if (!body) out.push('  (cel-fanout why said nothing)');
  for (const line of body ? body.split('\n') : []) out.push(`  ${line}`);
  out.push('');
  out.push(workerButtons(preview).join('  '));
  return out.join('\n');
};

// --- section 4: no raw JSON, ever ------------------------------------------

// What came back: one document, a stream of one-per-line documents, or text.
// JSONL is not a nicety here - `cel inbox open --json` is exactly that shape,
// and treating it as prose is what put braces on the screen.
export const parseJson = (text) => {
  const raw = String(text || '').trim();
  if (!raw || !/^[[{]/.test(raw)) return null;
  try { return { kind: 'doc', value: JSON.parse(raw) }; } catch { /* maybe JSONL */ }
  const lines = raw.split('\n').map((l) => l.trim()).filter(Boolean);
  const rows = [];
  for (const l of lines) {
    try { rows.push(JSON.parse(l)); } catch { return null; }
  }
  return rows.length ? { kind: 'rows', value: rows } : null;
};

// The fallback shape: key: value, nested objects indented, arrays numbered.
// Deliberately boring. An operator reading an unfamiliar command's output
// should be reading VALUES, not counting brackets to find where one ends.
export const keyValue = (value, indent = 0) => {
  const pad = ' '.repeat(indent);
  const out = [];
  if (Array.isArray(value)) {
    value.forEach((v, i) => {
      if (v && typeof v === 'object') {
        out.push(`${pad}${i + 1}.`);
        out.push(...keyValue(v, indent + 2));
      } else out.push(`${pad}${i + 1}. ${v}`);
    });
    return out;
  }
  if (value && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) {
      if (v && typeof v === 'object') {
        out.push(`${pad}${k}:`);
        out.push(...keyValue(v, indent + 2));
      } else out.push(`${pad}${k}: ${v === '' ? '-' : v}`);
    }
    return out;
  }
  out.push(`${pad}${value}`);
  return out;
};

// --- services: the ports this box is holding --------------------------------
//
// One row per service and per preview, in the shape an operator reads out
// loud: is it up, on what port, how much is it costing, how long has it been
// there, and the URL that reaches it FROM THE LAPTOP. The reach column is the
// dashboard's proxy path, because 127.0.0.1 from a laptop is the laptop.
export const svcUptime = (secs) => {
  const s = Math.max(0, Number(secs) || 0);
  if (!s) return '-';
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  return `${Math.floor(s / 3600)}h`;
};

export const serviceLine = (s) => {
  const dot = s.state === 'healthy' || s.state === 'up' ? '\u25cf' : '\u25cb';
  const cells = [
    dot,
    cut(String(s.name || ''), 16).padEnd(16),
    String(s.state || '').padEnd(8),
    `:${s.port || '-'}`.padEnd(7),
    (memHuman(s.rss_mb) || '-').padEnd(6),
    svcUptime(s.uptime_secs).padEnd(5),
    String(s.reach || s.url || ''),
  ];
  return `${cells.join(' ')}${s.ticket ? `   (${s.ticket})` : ''}${s.observe_only ? '   observe-only' : ''}`;
};

// `n up/n down` for a workspace header: the question "is anything down here"
// answered without entering the view at all. `up` counts healthy too - a
// service answering its health path is up by any reading.
export const serviceCounts = (rows) => {
  const list = Array.isArray(rows) ? rows : [];
  const up = list.filter((s) => s.state === 'up' || s.state === 'healthy').length;
  return { up, down: list.length - up, total: list.length };
};

export const servicesView = (rows = []) => {
  const out = ['SERVICES'];
  if (!rows.length) return [...out, '  nothing declared and no previews running'];
  for (const s of rows) out.push(`  ${serviceLine(s)}`);
  return out;
};

export const fleetTable = (doc, services = {}) => {
  const out = ['FLEET'];
  if (doc.error) out.push(`  ! ${doc.error}`);
  for (const ws of doc.workspaces || []) {
    const c = serviceCounts(services[ws.name]);
    out.push(`  ${ws.name}   (${(ws.units || []).length} products)   root mail: ${ws.root?.unread ?? 0} unread, ${ws.root?.open ?? 0} open`
      + (c.total ? `   services ${c.up} up/${c.down} down` : ''));
    for (const u of ws.units || []) {
      out.push(`    ${unitLabel(u).padEnd(12)} orch ${String(u.orch).padEnd(7)} workers ${u.workers}/${u.cap}   stalled ${u.stalled}   unlanded ${u.unlanded}`
        + `${memHuman(u.rss_mb) ? `   mem ${memHuman(u.rss_mb)}` : ''}`);
    }
  }
  return out;
};

export const workerTable = (rows) => {
  const out = ['WORKERS'];
  if (!rows.length) out.push('  none');
  for (const w of rows) out.push(`  ${workerLine(w)}`);
  return out;
};

export const waitingTable = (rows) => {
  const out = ['WAITING'];
  if (!rows.length) out.push('  nothing open');
  for (const it of rows) out.push(`  ${openLine({ ws: '', ...it })}`);
  return out;
};

// `herdr agent focus` prints a sentence about tmux. The operator asked for a
// pane to be focused; the answer is that it was, and which one.
const focusLine = (cmd, text) => {
  const name = (/herdr\s+agent\s+focus\s+(\S+)/.exec(cmd) || [])[1] || '';
  const doc = parseJson(text);
  const pane = doc?.kind === 'doc' ? doc.value?.pane : null;
  const found = pane || (/\b(\w+[:.]\w+(?:[:.]\w+)?|%\d+)\b/.exec(String(text).replace(/^\s*focused\s*/, '')) || [])[1] || '';
  return `focused ${name}${found ? ` (${found})` : ''}`;
};

// THE CONSOLE KNOWS THE SHAPE OF WHAT IT RUNS. Everything below is a command
// this console itself offers, so there is no excuse for showing the operator
// the wire format - and the raw text is one keypress away in the output view.
export const renderOutput = (cmd, text) => {
  const c = String(cmd || '').trim();
  if (/^herdr\s+agent\s+focus\b/.test(c)) return focusLine(c, text);
  const parsed = parseJson(text);
  if (!parsed) return String(text ?? '');
  if (/^herdr\s+agent\s+get\b/.test(c) && parsed.kind === 'doc') {
    const v = parsed.value || {};
    const known = ['name', 'state', 'pane', 'cwd'];
    const head = known.filter((k) => k in v).map((k) => `${k}: ${v[k]}`);
    const rest = Object.entries(v).filter(([k]) => !known.includes(k));
    return [...head, ...keyValue(Object.fromEntries(rest))].join('\n');
  }
  if (/^cel\s+fleet\b/.test(c) && parsed.kind === 'doc') return fleetTable(parsed.value).join('\n');
  if (/^cel-fanout\s+status\b/.test(c)) {
    const rows = parsed.kind === 'rows' ? parsed.value : [parsed.value];
    return workerTable(rows).join('\n');
  }
  if (/^cel\s+inbox\s+(open|read)\b/.test(c)) {
    const rows = parsed.kind === 'rows' ? parsed.value : [parsed.value];
    return waitingTable(rows).join('\n');
  }
  return keyValue(parsed.value).join('\n');
};

// --- CEL-27: the two subscriptions the fleet actually runs on ---------------
//
// The box does not run on API keys alone: it runs on a Claude subscription and
// a Codex one, and until this existed neither was visible anywhere on the
// plane. A five-hour window at 100% stops every worker on that account, and
// the operator found out by watching a delegation refuse.
//
// All of this is pure over `cel fleet --json`, which carries the 60 s cache.
// The console NEVER asks a provider itself: a status edge that makes a network
// call is a status edge that stalls a draw.

// The tightest window per provider, as the status edge says it:
// `claude 16%/41% · codex 9%/62%`. Two figures because they answer two
// different questions - "can I delegate now" and "can I delegate this week".
export const subsEdge = (doc) => {
  const subs = (doc && doc.subscriptions) || [];
  if (!subs.length) return '';
  const byProvider = new Map();
  for (const s of subs) {
    const p = String(s?.provider || '');
    if (!p) continue;
    const pick = (name) => {
      const hits = (s.windows || []).filter((w) => w?.name === name && w.used_pct !== null && w.used_pct !== undefined);
      // WORST ACCOUNT WINS. Two Claude logins are two accounts, and the one
      // that is nearly spent is the one that decides what happens next.
      return hits.length ? Math.max(...hits.map((w) => Number(w.used_pct) || 0)) : null;
    };
    const short = pick('5h');
    const long = pick('7d');
    if (short === null && long === null) continue;
    const prev = byProvider.get(p) || { short: null, long: null };
    byProvider.set(p, {
      short: short === null ? prev.short : Math.max(prev.short ?? 0, short),
      long: long === null ? prev.long : Math.max(prev.long ?? 0, long),
    });
  }
  const parts = [];
  for (const [p, v] of byProvider) {
    const n = (x) => (x === null || x === undefined ? '-' : `${Math.round(x)}%`);
    parts.push(`${p} ${n(v.short)}/${n(v.long)}`);
  }
  return parts.join(' · ');
};

// How alarmed to be about the edge. Amber at 80 because that is where the
// steward starts saying so; red at 100 because at 100 the work has stopped.
export const subsLevel = (doc) => {
  const subs = (doc && doc.subscriptions) || [];
  let worst = 0;
  for (const s of subs) for (const w of s?.windows || []) worst = Math.max(worst, Number(w?.used_pct) || 0);
  if (worst >= 100) return 'bad';
  if (worst >= 80) return 'warn';
  return 'ok';
};

// A reset an operator can act on: a clock time today, a day and a time beyond
// that. Local, always - nobody converts UTC in their head at the moment they
// need to, and this number exists to answer "when can I start again".
export const resetHuman = (iso) => {
  if (!iso) return '';
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return String(iso);
  const hhmm = `${String(at.getHours()).padStart(2, '0')}:${String(at.getMinutes()).padStart(2, '0')}`;
  if (at.getTime() - Date.now() < 86400e3) return hhmm;
  return `${['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][at.getDay()]} ${hhmm}`;
};

// THE CELLS A SUBSCRIPTION ROW BECOMES, and the whole of CEL-35's "one
// renderer's data, two views". The console pads them into columns and the
// dashboard puts them in a table, but the strings are built here (and by the
// marked copy in tools/dash/server.mjs, which the suite compares against this
// one): the console and the dashboard disagreeing about how many
// subscriptions this box has is the bug this function exists to prevent.
//
// One array per line: [provider, label, window, reset]. The provider and the
// label are named once per account, because a column that repeats the same
// string is a column the eye stops reading.
export const subCells = (s) => {
  const provider = String((s && s.provider) || '');
  const label = String((s && (s.label || s.account)) || '');
  const windows = ((s && s.windows) || []).filter((w) => w && w.used_pct !== null && w.used_pct !== undefined);
  if (!windows.length) {
    const reason = (s && s.extra && s.extra.reason) || 'not signed in here, or the endpoint is down';
    return [[provider, label, `unreadable: ${reason}`, '']];
  }
  const rows = windows.map((w, i) => [
    i === 0 ? provider : '',
    i === 0 ? label : '',
    `${w.name} ${Math.round(Number(w.used_pct) || 0)}%`,
    resetHuman(w.resets_at) ? `resets ${resetHuman(w.resets_at)}` : '',
  ]);
  if (s && s.extra && s.extra.state === 'disabled') {
    rows.push(['', '', `extra: ${String(s.extra.reason || 'disabled').replace(/_/g, ' ')}`, '']);
  }
  return rows;
};

// The QUOTA view: one row per account and window, direct accounts first and
// the gateway's under their own heading. NEVER raw JSON, and never a token -
// the fleet document does not carry one, and this is the screen where somebody
// would paste a screenshot.
//
// CEL-35 removed the `cel gateway status` detour this view used to take for
// the second half of its rows. The gateway's accounts arrive in the fleet
// document with everything else now, and a view that runs its own command is
// a view that can disagree with the list it is drawn beside.
export const quotaView = (doc) => {
  const out = ['SUBSCRIPTIONS'];
  const subs = (doc && doc.subscriptions) || [];
  if (!subs.length) {
    out.push('  no signed-in subscriptions - cel quota asks the providers directly');
    return out;
  }
  const groups = [['direct', subs.filter((s) => s && s.source !== 'gateway')],
    ['via gateway', subs.filter((s) => s && s.source === 'gateway')]];
  for (const [heading, rows] of groups) {
    if (!rows.length) continue;
    out.push(heading);
    for (const s of rows) {
      for (const c of subCells(s)) {
        // The label is truncated, not wrapped: a 36-character Codex account id
        // left whole pushed every window off the right of the terminal.
        out.push(`  ${c[0].padEnd(12)} ${c[1].slice(0, 24).padEnd(24)} ${c[2]}${c[3] ? `   ${c[3]}` : ''}`.trimEnd());
      }
    }
  }
  return out;
};
