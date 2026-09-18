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

export const unitView = ({ unit, items = [], tail = [] }) => {
  const ws = unit.ws || '';
  const out = [];
  out.push(`UNIT ${unitLabel(unit)}   workspace ${ws}`);
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

export const fleetTable = (doc) => {
  const out = ['FLEET'];
  if (doc.error) out.push(`  ! ${doc.error}`);
  for (const ws of doc.workspaces || []) {
    out.push(`  ${ws.name}   (${(ws.units || []).length} products)   root mail: ${ws.root?.unread ?? 0} unread, ${ws.root?.open ?? 0} open`);
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
