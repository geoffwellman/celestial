// The interactive console: ink (React for the terminal).
//
// Chosen over raw ANSI by the owner on 2026-09-16 for the reason the console
// exists at all - this is the surface people LOOK at. Flexbox layout means the
// panels survive a resize without a redraw routine of our own; a component
// tree means a count that changes updates in place instead of a screen being
// repainted under the operator's cursor.
//
// No JSX: that would need a build step, and a tool whose source you cannot read
// in the checkout you are debugging is a worse tool. createElement is aliased
// to `h` and the tree below reads as a layout.
//
// v2 (CEL-17) is the list of things the owner expected of a terminal UI on
// 2026-09-17 and did not get: a command line that edits like a shell, a status
// line that clears itself and never eats the legend, a mouse, a detail view
// that is a place rather than a popup, and a model that offers options instead
// of shrugging. The pure parts of all of that live in edit.mjs, mouse.mjs and
// legend.mjs so they can be proved without a terminal.
import React, {
  createElement as h, useState, useEffect, useRef, useCallback, useMemo,
} from 'react';
import { appendFileSync } from 'node:fs';
import { render, Box, Text, useInput, useApp, useStdout, measureElement } from 'ink';
import { spawn } from 'node:child_process';

import { C, orchColour, kindColour } from './theme.mjs';
import {
  CEL_BIN, fleet, fleetRows, openItems, inboxTail, runCommand, runChain, run, thread,
  readHistory, appendHistory, unitLabel, findUnit, findWorker, why as whyOf, askState,
  renderOutput,
} from './state.mjs';
import { workersOf, quiet, prNumber, workerFacts, workerButtons, memHuman, memFree, memLevel, sortWorkers, workerCells, workerHeader, subsEdge, subsLevel, quotaView } from './views.mjs';
import { translate, answer, NoTranslator, translatorLabel } from './translate.mjs';
import { route, NoRouter, routerLabel } from './router.mjs';
import {
  insert, backspace, del, left, right, home, end,
  killWord, killToEnd, killLine, historyWalk, historyFilter,
} from './edit.mjs';
import { parseMouseAll, hasMouse, hasControl, hitTest } from './mouse.mjs';
import { enterTerminal, LEAVE } from './term.mjs';
import { legend, helpLines } from './legend.mjs';

const COMMAND = /^(cel|cel-fanout|cel-linear|gh|herdr)(\s|$)/;
const DOUBLE_CLICK_MS = 400;

// What Tab completes: the vocabulary, every registered workspace and every
// orchestrator alias the fleet knows about. All three come from live state, so
// a completion never offers a workspace that was removed this morning.
const completions = (doc) => {
  const words = [
    'cel fleet', 'cel fleet --json', 'cel inbox read --for root', 'cel inbox open --for root',
    'cel inbox send', 'cel inbox resolve', 'cel dash --ensure', 'cel run orchestrator',
    'cel-fanout status', 'cel-fanout collect', 'cel-fanout release', 'cel-linear',
    'cel steward', 'cel gc', 'cel profiles', 'cel quota', 'herdr agent focus', 'gh pr list',
    '--workspace', '--json', '--all-workspaces',
  ];
  for (const ws of doc.workspaces || []) {
    words.push(`--workspace ${ws.name}`);
    for (const u of ws.units || []) words.push(`${u.name}-orch`);
  }
  return words;
};

const complete = (value, doc) => {
  const head = value.replace(/[^ ]*$/, '');
  const frag = value.slice(head.length);
  const all = completions(doc);
  const hits = frag ? all.filter((w) => w.startsWith(frag) || w.startsWith(value)) : [];
  if (!hits.length) {
    const whole = all.filter((w) => w.startsWith(value));
    return whole.length ? { value: whole[0], hits: whole } : { value, hits: [] };
  }
  const first = hits[0];
  return { value: first.startsWith(value) ? first : head + first, hits };
};

// A window onto a list, plus the "there is more" markers. Every panel scrolls
// now, because a fleet of four workspaces on a laptop screen silently lost its
// last two rows off the bottom of a box that had no indication it was clipped.
const window_ = (list, offset, height) => {
  const h2 = Math.max(1, height);
  const start = Math.max(0, Math.min(offset, Math.max(0, list.length - h2)));
  return { start, rows: list.slice(start, start + h2), above: start, below: Math.max(0, list.length - start - h2) };
};

const More = ({ n, up }) => (n > 0
  ? h(Text, { color: C.dim }, `${up ? '▲' : '▼'} ${n} more`)
  : null);

const Panel = ({ title, right, innerRef, focused, children }) =>
  h(Box, { flexDirection: 'column', borderStyle: 'round', borderColor: focused ? C.accent : C.line, paddingX: 1, ref: innerRef },
    h(Box, null,
      h(Text, { color: focused ? C.ink : C.accent, bold: true }, `${focused ? '● ' : ''}${title}`),
      h(Box, { flexGrow: 1 }),
      right ? h(Text, { color: C.dim }, right) : null),
    children);

const FleetPanel = ({ doc, rows, sel, offset, height, innerRef, focused, loaded }) => {
  const w = window_(rows, offset, height);
  const nameW = Math.max(10, Math.min(22, ...rows.filter((r) => r.kind === 'unit').map((r) => String(r.name).length)));
  return h(Panel, {
    title: 'FLEET',
    innerRef,
    focused,
    right: doc.error ? doc.error : `${rows.filter((r) => r.kind === 'unit').length} units`,
  },
  rows.length === 0 ? h(Text, { color: C.dim }, loaded ? '  no workspaces registered' : '  loading…') : null,
  h(More, { n: w.above, up: true }),
  ...w.rows.map((r, i) => {
    const on = w.start + i === sel;
    if (r.kind === 'ws') {
      return h(Text, { key: `w${r.ws}`, color: C.ink, bold: true, inverse: on, wrap: 'truncate-end' },
        `${on ? '▸ ' : ''}${r.ws}  `,
        h(Text, { color: C.dim }, `(${r.units} products)  root mail: ${r.root.unread} unread, `),
        h(Text, { color: r.root.open ? C.accent : C.dim }, `${r.root.open} open`));
    }
    const repos = r.declared && (r.repos || []).length ? `   ↳ ${r.repos.join(', ')}` : '';
    return h(Text, { key: `u${r.ws}/${r.name}`, inverse: on, wrap: 'truncate-end' },
      h(Text, { color: on ? C.ink : C.dim }, on ? '▸ ' : '  '),
      h(Text, { color: C.ink }, String(r.name).slice(0, nameW).padEnd(nameW + 1)),
      h(Text, { color: orchColour(r.orch) }, `orch ${String(r.orch).padEnd(6)}`),
      h(Text, { color: C.dim }, 'workers '),
      h(Text, { color: r.workers ? C.ink : C.dim }, `${r.workers}/${r.cap}  `),
      h(Text, { color: r.stalled ? C.bad : C.dim }, `stalled ${r.stalled}  `),
      h(Text, { color: r.unlanded ? C.warn : C.dim }, `unlanded ${r.unlanded}`),
      // What this product is holding, beside the count it is weighed against:
      // "three workers out" and "three workers out costing 1.1G" are different
      // facts when the question is whether to delegate a fourth.
      h(Text, { color: C.dim }, memHuman(r.rss_mb) ? `  mem ${memHuman(r.rss_mb)}` : ''),
      h(Text, { color: C.dim }, repos));
  }),
  h(More, { n: w.below }));
};

const OpenPanel = ({ items, sel, offset, height, innerRef, focused, loaded }) => {
  const w = window_(items, offset, height);
  return h(Panel, { title: 'WAITING ON YOU', innerRef, focused, right: items.length ? `${items.length} open · Enter opens` : '' },
    items.length === 0 ? h(Text, { color: C.dim }, loaded ? 'nothing open' : 'loading…') : null,
    h(More, { n: w.above, up: true }),
    ...w.rows.map((it, i) => {
      const on = w.start + i === sel;
      return h(Text, { key: it.id, inverse: on, wrap: 'truncate-end' },
        h(Text, { color: on ? C.ink : C.dim }, on ? '▸ ' : '  '),
        h(Text, { color: C.dim }, `${String(it.ts).slice(5, 16).replace('T', ' ')}  ${String(it.ws).padEnd(12)} `),
        h(Text, { color: kindColour(it.kind) }, `${it.kind} `),
        h(Text, { color: C.dim }, `${it.from}${it.count > 1 ? ` ×${it.count}` : ''}: `),
        h(Text, { color: C.ink }, it.message));
    }),
    h(More, { n: w.below }));
};

// THE DETAIL VIEW IS A PLACE. It was a three-line popup inside the waiting
// panel, which meant the message was still truncated and the rest of the
// conversation was somewhere else entirely - so reading a decision meant
// leaving the console for a pane. Now it takes the room, carries the whole
// message and the thread around it, and has buttons you can click.
const DetailView = ({ item, thread: rows, innerRef, target }) =>
  h(Panel, { title: `${String(item.kind || 'item').toUpperCase()} · ${item.ws}`, innerRef, focused: true, right: `${String(item.ts).slice(0, 16).replace('T', ' ')} · Esc back` },
    h(Text, null,
      h(Text, { color: C.dim }, 'from '),
      h(Text, { color: C.ink, bold: true }, String(item.from)),
      h(Text, { color: C.dim }, item.count > 1 ? `  (raised ×${item.count}, last ${String(item.last_ts || '').slice(0, 16).replace('T', ' ')})` : ''),
      h(Text, { color: C.dim }, `   id ${item.id}`)),
    h(Text, null, ' '),
    h(Text, { color: C.ink, wrap: 'wrap' }, item.message),
    rows.length ? h(Box, { flexDirection: 'column', marginTop: 1 },
      h(Text, { color: C.dim }, `thread (${rows.length})`),
      ...rows.map((m, i) => h(Text, { key: `${m.id || i}`, wrap: 'truncate-end' },
        h(Text, { color: C.dim }, `  ${String(m.ts).slice(0, 16)} ${m.from}: `),
        h(Text, { color: C.ink }, String(m.message || '').replace(/\n/g, ' '))))) : null,
    h(Box, { marginTop: 1 },
      h(Text, { color: C.ok }, '[resolve]'),
      h(Text, { color: C.dim }, '  '),
      h(Text, { color: C.accent }, '[reply]'),
      h(Text, { color: C.dim }, '  '),
      h(Text, { color: C.ink }, '[go to]'),
      // WHO SENT THIS IS A PLACE. A blocker from a worker and no way from it to
      // that worker is the message being a dead end.
      target ? h(Text, { color: C.dim }, '  ') : null,
      target ? h(Text, { color: C.accent }, target.kind === 'unit' ? '[unit]' : '[worker]') : null));

const TailPanel = ({ lines, offset, height, innerRef, focused, loaded }) => {
  const w = window_(lines, offset, height);
  return h(Panel, { title: 'INBOX', innerRef, focused },
    lines.length === 0 ? h(Text, { color: C.dim }, loaded ? 'quiet' : 'loading…') : null,
    h(More, { n: w.above, up: true }),
    ...w.rows.map((m, i) => h(Text, { key: `${m.ts}${i}`, wrap: 'truncate-end' },
      h(Text, { color: C.dim }, `[${m.ws}] `),
      h(Text, { color: kindColour(m.kind) }, `${m.kind} `),
      h(Text, { color: C.dim }, `${m.from}${m.count > 1 ? ` ×${m.count}` : ''}: `),
      h(Text, { color: C.ink }, m.message))),
    h(More, { n: w.below }));
};

// The command line, with a cursor. Inverse video on the character under it,
// and on a trailing space when the cursor is at the end - a "cursor" that is
// always a bar at the right edge is not a cursor, it is a decoration, and the
// first cut of this console shipped exactly that.
const CommandLine = ({ value, cursor, proposed }) => {
  const c = Math.max(0, Math.min(cursor, value.length));
  const colour = proposed ? C.accent : C.ink;
  if (!value) {
    return h(Box, null,
      h(Text, { color: C.ok }, '> '),
      h(Text, { color: colour, inverse: true }, ' '),
      h(Text, { color: C.dim }, ' type a command, or ask in plain words - Enter runs, ? help'));
  }
  return h(Box, null,
    h(Text, { color: proposed ? C.accent : C.ok }, proposed ? '? ' : '> '),
    h(Text, { color: colour }, value.slice(0, c)),
    h(Text, { color: colour, inverse: true }, value.slice(c, c + 1) || ' '),
    h(Text, { color: colour }, value.slice(c + 1)));
};

const Overlay = ({ title, lines, innerRef }) =>
  h(Panel, { title, innerRef },
    ...lines.map((l, i) => h(Text, { key: i, color: C.ink, wrap: 'truncate-end' }, l || ' ')));


// --- CEL-20: the unit view ---------------------------------------------------
//
// A fleet row said "workers 2/4  stalled 1" and every question after that one
// meant leaving the console. This is the page behind the row: who the
// orchestrator is, every worker it has out, what is waiting, what was said.

const verdictColour = (w) => {
  if (!w.verdict) return C.dim;
  if (w.severity === 'bad' || w.verdict === 'vanished') return C.bad;
  return C.warn;
};

const OrchPanel = ({ unit, innerRef }) =>
  h(Panel, { title: `ORCHESTRATOR · ${unit.name}-orch`, innerRef, right: `workspace ${unit.ws}` },
    h(Text, null,
      h(Text, { color: orchColour(unit.orch) }, String(unit.orch).padEnd(6)),
      h(Text, { color: C.dim }, '  pane '),
      h(Text, { color: C.ink }, String(unit.pane || '-')),
      h(Text, { color: C.dim }, '   slots '),
      h(Text, { color: C.ink }, `${unit.workers}/${unit.cap}`),
      h(Text, { color: C.dim }, memHuman(unit.orch_rss_mb) ? `   mem ${memHuman(unit.orch_rss_mb)}` : ''),
      h(Text, { color: C.dim }, `   repos ${(unit.repos || []).join(', ') || '-'}`)),
    h(Box, null,
      h(Text, { color: C.ink }, '[focus]'),
      h(Text, { color: C.dim }, '  '),
      h(Text, { color: C.accent }, '[message]')));

const WorkersPanel = ({ workers, sel, innerRef, focused, byMemory }) =>
  h(Panel, {
    title: 'WORKERS',
    innerRef,
    focused,
    right: workers.length
      ? `${workers.length} · ${byMemory ? 'by memory' : 'stalled, running, finished, collected'} · Enter says why · s sorts`
      : '',
  },
    workers.length === 0 ? h(Text, { color: C.dim }, '  no workers') : null,
    h(Text, { color: C.dim, wrap: 'truncate-end' }, `  ${workerHeader()}`),
    ...workers.map((w, i) => {
      const c = workerCells(w); const on = i === sel;
      return h(Text, { key: w.id, inverse: on, wrap: 'truncate-end' },
        h(Text, { color: on ? C.ink : C.dim }, on ? '▸ ' : '  '),
        h(Text, { color: C.ink }, `${c.ticket} `),
        h(Text, { color: C.dim }, `${c.slug} `),
        h(Text, { color: w.state === 'running' ? C.ink : C.dim }, `${c.state} `),
        h(Text, { color: w.live === 'working' ? C.ok : w.live === 'gone' ? C.dim : C.ink }, `${c.live} `),
        h(Text, { color: C.dim }, `${c.via} `),
        h(Text, { color: C.dim }, `${c.quiet} `),
        h(Text, { color: verdictColour(w) }, `${c.verdict} `),
        h(Text, { color: C.dim }, `${c.ahead} `),
        h(Text, { color: C.dim }, `${c.rss} `),
        h(Text, { color: C.accent }, c.pr));
    }));

const UnitWaiting = ({ items, innerRef }) =>
  h(Panel, { title: 'WAITING', innerRef, right: items.length ? `${items.length} open · Enter opens` : '' },
    items.length === 0 ? h(Text, { color: C.dim }, '  nothing open') : null,
    ...items.map((it) => h(Text, { key: it.id, wrap: 'truncate-end' },
      h(Text, { color: C.dim }, `  ${String(it.ts).slice(5, 16).replace('T', ' ')} `),
      h(Text, { color: kindColour(it.kind) }, `${it.kind} `),
      h(Text, { color: C.dim }, `${it.from}: `),
      h(Text, { color: C.ink }, it.message))));

const UnitMail = ({ lines, innerRef }) =>
  h(Panel, { title: 'RECENT MAIL', innerRef },
    lines.length === 0 ? h(Text, { color: C.dim }, '  quiet') : null,
    ...lines.map((m, i) => h(Text, { key: `${m.ts}${i}`, wrap: 'truncate-end' },
      h(Text, { color: C.dim }, `  ${String(m.ts).slice(5, 16).replace('T', ' ')} `),
      h(Text, { color: kindColour(m.kind) }, `${m.kind} `),
      h(Text, { color: C.dim }, `${m.from}: `),
      h(Text, { color: C.ink }, m.message))));

// --- CEL-20: the worker view, which is the answer to "why" -------------------
//
// It runs `cel-fanout why` on open. The complaint this ticket exists for was a
// console that answered "why is this one stalled" with the name of a command.

const WorkerView = ({ worker, ws, why, busy, preview, innerRef }) =>
  h(Panel, {
    title: `WORKER · ${worker.id}`, innerRef, focused: true,
    right: `${ws} · Esc back`,
  },
  h(Text, { wrap: 'truncate-end' },
    h(Text, { color: C.ink }, workerFacts(worker))),
  h(Text, { color: C.dim, wrap: 'truncate-end' },
    `quiet ${quiet(worker.quiet_secs)}   ahead ${worker.ahead ?? '?'}   branch ${worker.branch || '-'}   pane ${worker.pane || '-'}   PR ${prNumber(worker.pr) || 'none'}`),
  h(Text, null, ' '),
  busy && !why ? h(Text, { color: C.dim }, 'asking cel-fanout why…') : null,
  ...String(why || '').split('\n').map((l, i) => h(Text, {
    key: i,
    color: /^next:/.test(l) ? C.accent : C.dim,
    wrap: 'truncate-end',
  }, l || ' ')),
  h(Box, { marginTop: 1 },
    ...workerButtons(preview).flatMap((b, i) => [
      i ? h(Text, { key: `s${i}`, color: C.dim }, '  ') : null,
      h(Text, { key: b, color: b === '[release]' ? C.warn : C.ink }, b),
    ].filter(Boolean))));

const App = ({ refresh, statusSecs, noRouter = false }) => {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [doc, setDoc] = useState({ workspaces: [] });
  const [items, setItems] = useState([]);
  const [tail, setTail] = useState([]);
  const [sel, setSel] = useState(0);
  const [pane, setPane] = useState('fleet');      // which panel the selection moves in
  const [detail, setDetail] = useState(null);
  const [value, setValue] = useState('');
  const [cursor, setCursor] = useState(0);
  const [proposed, setProposed] = useState(null); // {cmds: [...]}
  const [options, setOptions] = useState([]);     // [{cmd, reason}]
  const [output, setOutput] = useState('');
  const [outOffset, setOutOffset] = useState(0);
  const [outCollapsed, setOutCollapsed] = useState(false);
  const [offsets, setOffsets] = useState({ fleet: 0, waiting: 0, inbox: 0 });
  const [status, setStatus] = useState('');
  const [statusAt, setStatusAt] = useState('');
  const [busy, setBusy] = useState(false);
  const [at, setAt] = useState('');
  const [help, setHelp] = useState(false);
  const [quota, setQuota] = useState(false);      // `q`: the subscription windows, whole
  const [picker, setPicker] = useState(null);     // {query, sel} - Ctrl+R
  const [, setTick] = useState(0);                // a resize is a re-render
  const [loaded, setLoaded] = useState(false);    // first fleet+inbox read done
  const [outView, setOutView] = useState(false);  // OUTPUT takes the screen after a command; Esc back
  const [unit, setUnit] = useState(null);         // the unit view: one product, whole
  const [wsel, setWsel] = useState(0);            // which worker row the unit view has
  const [wsort, setWsort] = useState(false);      // `s`: the workers by memory, biggest first
  const [worker, setWorker] = useState(null);     // {worker, ws, why, busy} - the answer to "why"
  const [raw, setRaw] = useState(false);          // the output view showing the text as it came
  const rawText = useRef('');                     // what the command actually printed
  const renderedRef = useRef('');                 // and the console's reading of it
  const history = useRef(readHistory());
  const hIndex = useRef(-1);
  const lastRaw = useRef('');
  const asked = useRef('');   // the sentence behind the current proposal, for the answer
  const escTimer = useRef(null);   // a lone ESC waits 40 ms for a mouse tail (see useInput)
  const escapeRef = useRef(() => {});
  const typed = useRef('');
  const lastClick = useRef({ panel: '', index: -1, at: 0 });
  const hitMap = useRef([]);
  const refs = {
    fleet: useRef(null), detail: useRef(null), waiting: useRef(null),
    inbox: useRef(null), output: useRef(null),
    unitOrch: useRef(null), unitWorkers: useRef(null),
    unitWaiting: useRef(null), unitMail: useRef(null), worker: useRef(null),
  };
  const rows = fleetRows(doc);
  const rowsRef = useRef(rows); rowsRef.current = rows;
  const itemsRef = useRef(items); itemsRef.current = items;
  const tailRef = useRef(tail); tailRef.current = tail;
  const unitRef = useRef(null); unitRef.current = unit;
  const workerRef = useRef(null); workerRef.current = worker;

  // A status message is TRANSIENT and the legend is not. The v1 console wrote
  // the response over the legend and left it there, so five minutes after a
  // command the operator was looking at a stale sentence where their key
  // bindings used to be.
  const say = useCallback((text) => {
    setStatus(text);
    setStatusAt(new Date().toTimeString().slice(0, 8));
  }, []);

  useEffect(() => {
    if (!status || !statusSecs) return undefined;
    if (/^(model:|refused|no command|stopped at|command exited)/.test(status)) return undefined;   // problems stay put
    const t = setTimeout(() => setStatus(''), statusSecs * 1000);
    return () => clearTimeout(t);
  }, [status, statusAt, statusSecs]);

  const reload = useCallback(async () => {
    const d = await fleet();
    setDoc(d);
    setItems(await openItems(d));
    setTail((prev) => {
      const seeded = inboxTail(d, 200);
      return prev.length > seeded.length ? prev.slice(-200) : seeded;
    });
    setAt(new Date().toTimeString().slice(0, 8));
    setLoaded(true);
  }, []);

  useEffect(() => {
    reload();
    const t = setInterval(reload, Math.max(2, refresh) * 1000);
    return () => clearInterval(t);
  }, [reload, refresh]);

  // THE WATCH IS THE DELIVERY PATH, not a nicety: `cel inbox watch` is what
  // raises the desktop notification for a decision or a blocker (lib/inbox.sh,
  // CEL-7). The console runs one so that mail arriving while the operator is
  // looking at another tab still reaches them; the bell below is the same
  // event, for the operator who IS looking.
  useEffect(() => {
    const child = spawn(CEL_BIN, ['inbox', 'watch', '--for', 'root', '--all-workspaces'],
      { stdio: ['ignore', 'pipe', 'ignore'] });
    let buf = '';
    child.stdout.on('data', (chunk) => {
      buf += chunk;
      const parts = buf.split('\n');
      buf = parts.pop() || '';
      for (const line of parts) {
        if (!line.trim()) continue;
        const m = /^\[([^\]]+)\]\s*INBOX\s+(\S+)\s+from\s+(\S+):\s*(.*)$/.exec(line)
          || /^INBOX\s+(\S+)\s+from\s+(\S+):\s*(.*)$/.exec(line);
        const item = m && m.length === 5
          ? { ws: m[1], kind: m[2], from: m[3], message: m[4], ts: new Date().toISOString() }
          : { ws: '?', kind: 'status', from: '-', message: line, ts: new Date().toISOString() };
        if (item.kind === 'decision' || item.kind === 'blocked') stdout.write('\u0007');
        setTail((prev) => [...prev, item].slice(-200));
      }
    });
    child.on('error', () => say('cel inbox watch could not start - mail will still refresh'));
    return () => child.kill();
  }, [stdout, say]);

  // A TERMINAL LEFT IN MOUSE MODE IS A TERMINAL NOBODY CAN COPY OUT OF, and a
  // console that drew over the operator's scrollback is a console that ate the
  // output they were reading when they opened it. Both modes go on here and
  // come off on every exit path there is - see term.mjs, which owns the pairs
  // and is unit-tested on each of those paths.
  useEffect(() => enterTerminal({
    write: (s2) => stdout.write(s2),
    onError: (e) => process.stderr.write(`cel console: ${e?.stack || e}\n`),
  }), [stdout]);

  useEffect(() => {
    const onResize = () => setTick((t) => t + 1);
    stdout.on('resize', onResize);
    return () => stdout.off('resize', onResize);
  }, [stdout]);

  const execute = useCallback(async (cmd) => {
    setBusy(true);
    say(`running: ${cmd}`);
    const r = await runCommand(cmd);
    setBusy(false);
    if (!r.allow) {
      setOutput(`refused: ${r.reason}`);
      setOutOffset(0);
      say('refused by the console allowlist');
      return false;
    }
    // NO RAW JSON, EVER (views.mjs). The console ran the command, so it knows
    // the shape of the answer; a box of braces was the console saying "here,
    // you parse it". `r` in the output view brings the text back.
    rawText.current = r.out || '(no output)';
    setRaw(false);
    renderedRef.current = renderOutput(cmd, r.out) || '(no output)';
    setOutput(renderedRef.current);
    setOutOffset(0); setOutView(true); setOutCollapsed(false);
    say(r.ok ? 'done - Esc returns to the panels' : 'command exited non-zero - Esc returns to the panels');
    appendHistory(cmd);
    history.current = [...history.current, cmd];
    reload();
    return `$ ${cmd}\n${r.out || '(no output)'}`;
  }, [reload, say]);

  // A CHAIN IS ALLOWLISTED WHOLE BEFORE ANY OF IT RUNS (state.mjs:runChain), and
  // then stops at the first non-zero exit. The operator pressed Enter once, on
  // a proposal they were told the guard would check - so a refusal on line two
  // must not arrive after line one has already changed the box.
  const executeChain = useCallback(async (cmds) => {
    if (cmds.length === 1) return execute(cmds[0]);
    setBusy(true);
    say(`checking ${cmds.length} commands…`);
    const r = await runChain(cmds, (cmd, i, n) => say(`running ${i + 1}/${n}: ${cmd}`));
    setBusy(false);
    if (!r.allow) {
      setOutput([
        `refused: ${r.reason}`,
        `the chain ran nothing - the refused line was:`,
        `  ${r.denied}`,
      ].join('\n'));
      setOutOffset(0);
      say('refused by the console allowlist - nothing ran');
      return '';
    }
    const transcript = r.results.map((s2) => `$ ${s2.cmd}\n${renderOutput(s2.cmd, s2.out) || '(no output)'}`).join('\n\n') || '(no output)';
    rawText.current = r.results.map((s2) => `$ ${s2.cmd}\n${s2.out || '(no output)'}`).join('\n\n') || '(no output)';
    setRaw(false);
    renderedRef.current = transcript;
    setOutput(transcript);
    setOutOffset(1); setOutView(true); setOutCollapsed(false);
    setOutOffset(0);
    for (const s2 of r.results) appendHistory(s2.cmd);
    history.current = [...history.current, ...r.results.map((s2) => s2.cmd)];
    reload();
    say(r.stoppedAt != null
      ? `stopped at ${r.stoppedAt + 1}/${cmds.length} - it exited non-zero`
      : `done - ${cmds.length} commands`);
    return transcript;
  }, [execute, reload, say]);

  // THE ANSWER. A sentence that became commands is still a question, and
  // "what is happening with widget" answered with a fleet table is the console
  // handing the operator homework. Once the commands have run, the model reads
  // what they printed and answers the sentence in a few lines above the raw
  // output. It reads; it never runs anything.
  const explain = useCallback(async (sentence, transcript) => {
    if (!sentence || !transcript) return;
    setBusy(true);
    say(`answering from the output (${translatorLabel()})…`);
    try {
      const a = await answer({ sentence, transcript });
      setBusy(false);
      if (!a) { say('done'); return; }
      const cols = Math.max(40, (stdout?.columns || 80) - 6);
      const wrapped = a.split('\n').flatMap((line) => {
        const words = line.split(/\s+/); const rows = []; let cur = '';
        for (const w of words) { if ((cur + ' ' + w).trim().length > cols) { rows.push(cur.trim()); cur = w; } else cur = `${cur} ${w}`; }
        rows.push(cur.trim()); return rows;
      }).join('\n');
      setOutput(`${wrapped}\n\n${'─'.repeat(40)}\n${transcript}`);
      setOutOffset(1);   // 1 = pinned to the top: the answer is the point, the transcript is under the line
      setOutView(true); setOutCollapsed(false);
      say('answered - the raw output is below the line · Esc returns to the panels');
    } catch (e) {
      setBusy(false);
      say(e instanceof NoTranslator ? 'done' : `model: ${e.message} - raw output kept`);
    }
  }, [say, stdout]);

  const setLine = useCallback((v, c) => { setValue(v); setCursor(c ?? v.length); }, []);

  const propose = useCallback((cmds) => {
    setProposed({ cmds });
    setOptions([]);
    setLine(cmds.join(' ; '), cmds.join(' ; ').length);
    setOutput(cmds.map((c, i) => `${i + 1}  ${c}`).join('\n'));
    setOutOffset(0);
    say(cmds.length > 1
      ? `proposed a chain of ${cmds.length} - Enter runs them in order, Esc discards`
      : 'proposed - Enter runs it, Esc discards it');
  }, [say, setLine]);

  const ask = useCallback(async (text) => {
    setBusy(true);
    const state = askState(doc, items);
    // THE ROUTER FIRST, when one is configured. It is a classifier: it picks
    // one of ten intents and the console fills the slots itself, which is why
    // it answers in under a second where the chat model took six. Everything
    // it cannot place goes on to the chat model below, unchanged.
    const rLabel = routerLabel();
    if (rLabel && !noRouter) {
      say(`asking ${rLabel} (router)…`);
      const started = Date.now();
      try {
        const r = await route({ sentence: text, doc, items, selected: pane === 'waiting' ? items[sel] || null : null });
        const secs = ((Date.now() - started) / 1000).toFixed(1);
        if (r.cmds) {
          setBusy(false);
          asked.current = text;
          propose(r.cmds);
          say(`proposed in ${secs} s - Enter runs it, Esc discards it`);
          return;
        }
        if (r.intent !== 'other' && r.options.some((o) => o.cmd)) {
          setBusy(false);
          const opts = r.options.filter((o) => o.cmd);
          setOptions(opts);
          setOutput([
            `not sure what you meant (${r.intent} ${r.confidence.toFixed(2)}) - did you mean:`,
            ...opts.map((o, i) => `${i + 1}  ${o.cmd.padEnd(48)} -- ${o.reason}`),
            '',
            'type 1, 2 or 3 and Enter - or click one - to put it on the command line',
          ].join('\n'));
          setOutOffset(0);
          say(`offered options in ${secs} s - pick one, nothing runs yet`);
          return;
        }
      } catch (e) {
        if (!(e instanceof NoRouter)) say(`${e.message} - asking the chat model`);
      }
    }
    say(`asking ${translatorLabel()}…`);
    let cmds = [], raw = '', answered = '';
    try {
      ({ cmds, raw, answer: answered = '' } = await translate({ sentence: text, state }));
    } catch (e) {
      setBusy(false);
      say(e instanceof NoTranslator ? e.message : `model: ${e.message}`);
      return;
    }
    // THE ANSWER. The state the model was handed already carries every worker,
    // its verdict and its quiet time; proposing three commands to rediscover
    // that is the console handing the operator homework.
    if (answered) {
      setBusy(false);
      rawText.current = answered;
      renderedRef.current = answered;
      setRaw(false);
      setOutput(answered);
      setOutOffset(1); setOutView(true); setOutCollapsed(false);
      say('answered from the fleet state - nothing ran · Esc returns to the panels');
      return;
    }
    if (cmds.length) { setBusy(false); asked.current = text; propose(cmds); return; }
    // The second ask: what might they have meant? A miss that only says "no"
    // leaves the operator exactly where they were.
    say('no command for that - asking for options…');
    let opts = [];
    try {
      ({ options: opts } = await translate({ sentence: text, state, mode: 'options' }));
    } catch { /* the miss below is the answer */ }
    setBusy(false);
    if (opts.length) {
      setOptions(opts);
      setOutput([
        'no command for that - did you mean:',
        ...opts.map((o, i) => `${i + 1}  ${o.cmd.padEnd(48)} -- ${o.reason}`),
        '',
        'type 1, 2 or 3 and Enter - or click one - to put it on the command line',
      ].join('\n'));
      setOutOffset(0);
      say('offered options - pick one, nothing runs yet');
      return;
    }
    const said = raw && raw !== '?' ? ` (model said: ${raw.replace(/\s+/g, ' ').slice(0, 70)})` : '';
    say(`no command for that - rephrase, or type the command${said}`);
  }, [doc, items, propose, say, pane, sel, noRouter]);

  const openDetail = useCallback((it) => {
    if (!it) return;
    setDetail({ item: it, thread: thread(it) });
    setPane('detail');
  }, []);

  // ENTER IS A PLACE, EVERYWHERE. A fleet row opens the unit it names, a worker
  // row opens the answer to "why", a message opens the message. The console
  // that only ever printed to an output box was a console you could read and
  // not drive.
  const openUnit = useCallback((name) => {
    const u = findUnit(doc, name);
    if (!u) { say(`no unit named ${name} in the fleet`); return; }
    setUnit(u);
    setWsel(0);
    setWorker(null);
    setPane('unit');
  }, [doc, say]);

  const openWhy = useCallback(async (w, ws) => {
    if (!w) return;
    setWorker({ worker: w, ws, why: '', busy: true });
    setPane('worker');
    const text = await whyOf(w.id, ws);
    setWorker((prev) => (prev && prev.worker.id === w.id ? { ...prev, why: text, busy: false } : prev));
  }, []);

  const openWorkerById = useCallback((id) => {
    const found = findWorker(doc, id);
    if (!found) { say(`no worker ${id} in the fleet`); return; }
    setUnit(found.unit);
    openWhy(found.worker, found.ws);
  }, [doc, openWhy, say]);

  const resolveItem = useCallback((it) => {
    if (!it) return;
    setDetail(null);
    setPane('waiting');
    execute(`cel inbox resolve ${it.id} --workspace ${it.ws}`);
  }, [execute]);

  // Reply puts the command on the line with the cursor INSIDE the quotes. A
  // reply form that lands the cursor at the end of the line is a reply form
  // where every message starts with the operator pressing left arrow twice.
  const replyTo = useCallback((it) => {
    if (!it) return;
    const head = `cel inbox send ${it.from} "`;
    setDetail(null);
    setPane('fleet');
    setProposed(null);
    setLine(`${head}" --workspace ${it.ws}`, head.length);
    say('reply - type the message, Enter sends it');
  }, [say, setLine]);

  // A message is FROM something that has a page of its own: a worker alias has
  // a worker view, `<product>-orch` has a unit view. Reading "ABC-49 is
  // blocked" and having no way from there to ABC-49 is the whole complaint.
  const senderTarget = useCallback((from) => {
    const name = String(from || '');
    const m = /^(.+)-orch$/.exec(name);
    if (m && findUnit(doc, m[1])) return { kind: 'unit', name: m[1] };
    const bare = name.includes('/') ? name.split('/').pop() : name;
    if (findWorker(doc, bare)) return { kind: 'worker', name: bare };
    return null;
  }, [doc]);

  // The same trick as reply, for every form that ends in a message the operator
  // still has to write: the cursor lands INSIDE the quotes, because a form that
  // leaves it at the end of the line is a form where every message starts with
  // two presses of the left arrow.
  const composeLine = useCallback((head, tail, what) => {
    setProposed(null);
    setLine(`${head}"${tail}`, head.length + 1);
    say(`${what} - type it, Enter sends`);
  }, [say, setLine]);

  const submitValue = useCallback(async (raw) => {
    const text = String(raw ?? '').trim();
    hIndex.current = -1;
    typed.current = '';
    if (!text) return;
    if (/^(q|quit|exit)$/.test(text)) { exit(); return; }
    if (text === 'help' || text === '?') { setLine(''); setHelp(true); return; }
    // A numbered pick after a miss: 1, 2 or 3 puts that candidate on the
    // command line. It is still a proposal - nothing runs without the next
    // Enter, which is the whole rule the model is held to.
    if (options.length && /^[123]$/.test(text)) {
      const pick = options[Number(text) - 1];
      if (pick) { setOptions([]); propose([pick.cmd]); return; }   // asked.current still holds the sentence
    }
    // A PROPOSED command runs on the SECOND Enter and not before. The model
    // never executes anything: it writes a line, the operator reads it, and
    // the keystroke that runs it is theirs.
    if (proposed && text === proposed.cmds.join(' ; ')) {
      const { cmds } = proposed;
      const sentence = asked.current;
      asked.current = '';
      setProposed(null);
      setLine('');
      const transcript = await executeChain(cmds);
      if (sentence && transcript) await explain(sentence, transcript);
      return;
    }
    if (COMMAND.test(text)) { setLine(''); asked.current = ''; await execute(text); return; }
    await ask(text);
  }, [proposed, options, exit, execute, executeChain, explain, ask, propose, setLine]);
  const submit = useCallback(() => submitValue(value), [submitValue, value]);

  const scroll = useCallback((panel, delta) => {
    if (panel === 'output') { setOutOffset((o) => Math.max(0, o + delta)); return; }
    setOffsets((o) => ({ ...o, [panel]: Math.max(0, (o[panel] || 0) + delta) }));
  }, []);

  // A click is a hit test against what was MEASURED, never against an assumed
  // row offset: panels grow a scroll indicator, the detail view appears and
  // pushes everything down, and a computed map goes one row out the moment
  // either happens.
  const onMouse = useCallback((ev) => {
    const hit = hitTest(hitMap.current, ev.x, ev.y);
    if (!hit) return;
    if (ev.wheel) { scroll(hit.panel, ev.wheel === 'up' ? -1 : 1); return; }
    if (!ev.press || ev.button !== 0) return;
    // A DOUBLE CLICK IS TWO CLICKS ON THE SAME ROW INSIDE 400 ms, and it has to
    // be known before the branches below - the depth views open on one.
    const now2 = Date.now();
    const last2 = lastClick.current;
    const dbl2 = last2.panel === hit.panel && last2.index === hit.index && now2 - last2.at < DOUBLE_CLICK_MS;
    if (hit.panel === 'detail') {
      const it = detail?.item;
      if (hit.index === 0) resolveItem(it);
      else if (hit.index === 1) replyTo(it);
      else if (hit.index === 2) execute(`herdr agent focus ${it.from}`);
      else if (hit.index === 3) {
        const t2 = senderTarget(it.from);
        setDetail(null);
        if (t2?.kind === 'unit') openUnit(t2.name);
        else if (t2?.kind === 'worker') openWorkerById(t2.name);
      }
      return;
    }
    if (hit.panel === 'unitorch') {
      if (!unitRef.current) return;
      const u = unitRef.current;
      if (hit.index === 0) execute(`herdr agent focus ${u.name}-orch`);
      else if (hit.index === 1) composeLine(`cel inbox send ${u.name}-orch `, ` --workspace ${u.ws}`, 'message');
      return;
    }
    if (hit.panel === 'unitworkers') {
      const w = (unitRef.current ? workersOf(unitRef.current) : [])[hit.index];
      setWsel(hit.index);
      if (dbl2 && w) openWhy(w, unitRef.current.ws);
      return;
    }
    if (hit.panel === 'unitwaiting' || hit.panel === 'unitmail') {
      const src = hit.panel === 'unitwaiting'
        ? itemsRef.current.filter((it) => it.ws === unitRef.current?.ws)
        : tailRef.current.filter((m) => m.ws === unitRef.current?.ws).slice(-10);
      openDetail(src[hit.index]);
      return;
    }
    if (hit.panel === 'worker') {
      const w = workerRef.current;
      if (!w) return;
      const label = workerButtons(w.preview)[hit.index];
      if (label === '[prompt]') composeLine(`herdr agent prompt ${w.worker.alias || w.worker.id} `, '', 'prompt');
      else if (label === '[focus]') execute(`herdr agent focus ${w.worker.alias || w.worker.id}`);
      else if (label === '[collect]') propose([`cel-fanout collect ${w.worker.id} --workspace ${w.ws}`]);
      else if (label === '[release]') propose([`cel-fanout release ${w.worker.id} --workspace ${w.ws}`]);
      else if (label === '[try]') propose([`cel-fanout try ${w.worker.id} --workspace ${w.ws}`]);
      else if (label === '[why again]') openWhy(w.worker, w.ws);
      return;
    }
    if (hit.index < 0) { setPane(['fleet', 'waiting', 'inbox'].includes(hit.panel) ? hit.panel : pane); return; }
    const now = Date.now();
    const last = lastClick.current;
    const dbl = last.panel === hit.panel && last.index === hit.index && now - last.at < DOUBLE_CLICK_MS;
    lastClick.current = { panel: hit.panel, index: hit.index, at: now };
    if (hit.panel === 'output' && options.length) {
      // The numbered list has a heading line, so option i is row i.
      const pick = options[hit.index - 1];
      if (pick) { setOptions([]); propose([pick.cmd]); }
      return;
    }
    if (hit.panel === 'fleet') {
      setPane('fleet');
      setSel(hit.index);
      const r = rowsRef.current[hit.index];
      if (dbl && r && r.kind === 'unit') openUnit(r.name);
      return;
    }
    if (hit.panel === 'waiting') {
      setPane('waiting');
      setSel(hit.index);
      if (dbl) openDetail(itemsRef.current[hit.index]);
      return;
    }
    // "I can't click on stuff in the inbox" - the tail was the one panel with
    // no selection and no Enter at all.
    if (hit.panel === 'inbox') {
      setPane('inbox');
      setSel(hit.index);
      if (dbl) openDetail(tailRef.current[hit.index]);
    }
  }, [detail, options, pane, execute, openDetail, openUnit, openWhy, openWorkerById,
    composeLine, senderTarget, propose, replyTo, resolveItem, scroll]);

  // ink's useInput hands a mouse report through as ordinary input on some
  // terminals and swallows it on others, so stdin is read directly and ONLY
  // for the SGR sequences; everything else is left to ink, which owns the
  // keyboard.
  useEffect(() => {
    const onData = (chunk) => {
      const s = String(chunk);
      lastRaw.current = s;
      // CEL_CONSOLE_KEYLOG=<file>: every raw stdin chunk, JSON-escaped, one per
      // line - the only honest way to learn what a terminal host really sends.
      if (process.env.CEL_CONSOLE_KEYLOG) { try { appendFileSync(process.env.CEL_CONSOLE_KEYLOG, `${JSON.stringify(s)}\n`); } catch { /* a log is not worth a crash */ } }
      if (!hasMouse(s)) return;
      for (const ev of parseMouseAll(s)) onMouse(ev);
    };
    // Prepended so it runs before ink's own listener: useInput below reads
    // lastRaw to tell Backspace from Delete, which ink reports alike.
    process.stdin.prependListener('data', onData);
    return () => process.stdin.off('data', onData);
  }, [onMouse]);

  const unitWorkers = unit ? sortWorkers(workersOf(unit), wsort) : [];
  const unitItems = unit ? items.filter((it) => it.ws === unit.ws) : [];
  const unitMail = unit ? tail.filter((m) => m.ws === unit.ws).slice(-10) : [];
  const list = pane === 'waiting' ? items : pane === 'inbox' ? tail : rows;

  useInput((input, key) => {
    // A mouse report that reached the keyboard is not text: without this it
    // types `[<0;40;12M` into the command line.
    if (hasMouse(input)) return;
    // SPLIT REPORTS. Over a remote herdr session the ESC of a mouse report
    // arrives in its own chunk and the rest - `[<0;40;12M`, or `[M` and three
    // bytes - in the next. ink sees a lone Escape (which discarded the
    // proposal) and then text (which was typed). So: a chunk shaped like a
    // report's tail is a report, ESC or not; and a lone ESC waits 40 ms to
    // see whether a tail follows before it counts as Escape.
    if (input && /^\[?(<\d+;\d+;\d+[Mm]|M[\s\S]{3})$/.test(input)) {
      if (escTimer.current) { clearTimeout(escTimer.current); escTimer.current = null; }
      const seq = `\x1b${input.startsWith('[') ? '' : '['}${input}`;
      for (const ev of parseMouseAll(seq)) onMouse(ev);
      return;
    }
    if (key.escape && !input) {
      if (escTimer.current) clearTimeout(escTimer.current);
      escTimer.current = setTimeout(() => { escTimer.current = null; escapeRef.current(); }, 40);
      return;
    }

    if (help) { if (key.escape || key.return || input === '\u001bOP' || key.f1) setHelp(false); return; }
    // THE QUOTA VIEW IS A PAGE, not a panel: it answers one question outright
    // ("what is left, and when does it come back") and Esc puts it away.
    if (quota) { if (key.escape || key.return || input === 'q') setQuota(false); return; }
    if (view === 'output' && !value) {
      const step = Math.max(1, outFullH - 2);
      if (key.escape) { setOutView(false); say('back'); return; }
      // The rendering is the console's reading of the output; `r` shows what
      // the command actually printed, because a console that hides the real
      // bytes is a console you cannot debug from.
      if (input === 'r') {
        setRaw((v) => {
          const next = !v;
          setOutput(next ? rawText.current : renderedRef.current);
          return next;
        });
        setOutOffset(1);
        return;
      }
      if (key.upArrow) { setOutOffset((o) => Math.max(1, (o === 1 ? 1 : o) - 1)); return; }
      if (key.downArrow) { setOutOffset((o) => Math.min(Math.max(1, outAll.length - outFullH + 1), (o === 1 ? 1 : o) + 1)); return; }
      if (key.pageUp) { setOutOffset((o) => Math.max(1, (o === 1 ? 1 : o) - step)); return; }
      if (key.pageDown) { setOutOffset((o) => Math.min(Math.max(1, outAll.length - outFullH + 1), (o === 1 ? 1 : o) + step)); return; }
    }

    // F1 arrives as an escape sequence rather than a key flag on most
    // terminals; both spellings are accepted.
    if (key.f1 || input === '\u001bOP' || input === '\u001b[11~') { setHelp(true); return; }

    if (picker) {
      const matches = historyFilter(history.current, picker.query);
      if (key.escape) { setPicker(null); return; }
      if (key.return) {
        const pick = matches[picker.sel];
        setPicker(null);
        if (pick) { setLine(pick); setProposed(null); }
        return;
      }
      if (key.upArrow) { setPicker((p) => ({ ...p, sel: Math.max(0, p.sel - 1) })); return; }
      if (key.downArrow) { setPicker((p) => ({ ...p, sel: Math.min(matches.length - 1, p.sel + 1) })); return; }
      if (key.backspace || key.delete) { setPicker((p) => ({ query: p.query.slice(0, -1), sel: 0 })); return; }
      if (input && !key.ctrl && !key.meta) setPicker((p) => ({ query: p.query + input, sel: 0 }));
      return;
    }

    // THE DETAIL VIEW HAS NO COMMAND LINE, so bare letters are actions here and
    // only here. Everywhere else a typed letter is a letter - the first cut of
    // this console bound bare j/k/f/o/r/w/q and "what's blocked" flipped the
    // panel and lost its w.
    // THE DEPTH VIEWS. Bare letters are actions here only while the command
    // line is EMPTY: the moment the operator has typed something they are
    // typing, not pressing keys, and a view that ate their `f` would be a view
    // they could not type a command from.
    if (worker && !detail) {
      const w = worker.worker;
      if (key.escape) { setWorker(null); setPane(unit ? 'unit' : 'fleet'); say('back'); return; }
      if (!value) {
        if (key.return) return;
        if (input === 'p') { composeLine(`herdr agent prompt ${w.alias || w.id} `, '', 'prompt'); return; }
        if (input === 'f') { execute(`herdr agent focus ${w.alias || w.id}`); return; }
        if (input === 'c') { propose([`cel-fanout collect ${w.id} --workspace ${worker.ws}`]); return; }
        if (input === 'x') { propose([`cel-fanout release ${w.id} --workspace ${worker.ws}`]); return; }
        if (input === 't') { propose([`cel-fanout try ${w.id} --workspace ${worker.ws}`]); return; }
        if (input === 'w') { openWhy(w, worker.ws); return; }
      }
    } else if (unit && pane === 'unit' && !detail) {
      if (key.escape) { setUnit(null); setPane('fleet'); say('back'); return; }
      if (key.upArrow) { setWsel((i) => Math.max(0, i - 1)); return; }
      if (key.downArrow) { setWsel((i) => Math.min(unitWorkers.length - 1, i + 1)); return; }
      if (key.return && !value.trim()) { openWhy(unitWorkers[wsel], unit.ws); return; }
      if (!value) {
        if (input === 'f') { execute(`herdr agent focus ${unit.name}-orch`); return; }
        // Clean-up from the list itself (owner, 2026-09-18): `c` collects and
        // `x` releases the SELECTED worker - as proposals, so the command is
        // on the line and Enter is the operator's. A row that is finished or
        // collected is exactly the row these are for.
        if (input === 'c' && unitWorkers[wsel]) { propose([`cel-fanout collect ${unitWorkers[wsel].id} --workspace ${unit.ws}`]); return; }
        if (input === 'x' && unitWorkers[wsel]) { propose([`cel-fanout release ${unitWorkers[wsel].id} --workspace ${unit.ws}`]); return; }
        // Shifted: the whole workspace. Finished and collected rows are the
        // ones nobody is working on; running rows are never in the set.
        // X offers the clean-up BY STATUS, with counts, through the same
        // numbered options the model's misses use: 1 finished, 2 collected,
        // 3 both. Nothing runs until the pick is on the line and Enter is hit.
        if (input === 'X') {
          const n = (st) => unitWorkers.filter((x) => x.state === st).length;
          const opts = [];
          // FIRST, when there is anything it could touch: after a merge spree
          // the operator's actual question is "clean up what is already in
          // main", and by-state alone released branches that never landed.
          // The console makes no network calls, so the count is the rows the
          // command will READ - `release --all --merged` asks GitHub which of
          // them merged, in one list per repo, and leaves the rest alone.
          const candidates = n('finished') + n('collected');
          if (candidates) opts.push({ cmd: `cel-fanout release --all --merged --workspace ${unit.ws}`, reason: `${candidates} finished/collected, merged only` });
          if (n('finished')) opts.push({ cmd: `cel-fanout release --all --state finished --workspace ${unit.ws}`, reason: `${n('finished')} finished` });
          if (n('collected')) opts.push({ cmd: `cel-fanout release --all --state collected --workspace ${unit.ws}`, reason: `${n('collected')} collected` });
          if (n('finished') && n('collected')) opts.push({ cmd: `cel-fanout release --all --workspace ${unit.ws}`, reason: `${n('finished') + n('collected')} finished + collected` });
          if (!opts.length) { say('nothing finished or collected to release here'); return; }
          setOptions(opts);
          setOutput(['release which?', ...opts.map((o, i) => `${i + 1}  ${o.cmd.padEnd(60)} -- ${o.reason}`), '', 'type the number and Enter to put it on the command line'].join('\n'));
          setOutOffset(1); setOutView(true); setOutCollapsed(false);
          say('pick a clean-up - nothing runs yet');
          return;
        }
        if (input === 'C') { propose([`cel-fanout collect --all --workspace ${unit.ws}`]); return; }
        if (input === 'm') { composeLine(`cel inbox send ${unit.name}-orch `, ` --workspace ${unit.ws}`, 'message'); return; }
        // `s` SORTS, it does not filter. The question it answers is "which of
        // these do I collect", and the selection follows the row it was on -
        // reordering under a cursor that stayed put is how an operator
        // collects the wrong worker.
        if (input === 's') {
          const on = unitWorkers[wsel];
          const next = sortWorkers(workersOf(unit), !wsort);
          setWsort((v) => !v);
          setWsel(Math.max(0, next.findIndex((x) => x.id === on?.id)));
          say(wsort ? 'workers in fleet order' : 'workers by memory, biggest first');
          return;
        }
      }
    }

    if (detail) {
      if (key.escape) { setDetail(null); setPane('waiting'); say('back'); return; }
      if (input === 'u') {
        const t2 = senderTarget(detail.item.from);
        if (t2 && t2.kind === 'unit') { setDetail(null); openUnit(t2.name); return; }
        say('that message is not from an orchestrator');
        return;
      }
      if (input === 'k') {
        const t2 = senderTarget(detail.item.from);
        if (t2 && t2.kind === 'worker') { setDetail(null); openWorkerById(t2.name); return; }
        say('that message is not from a worker');
        return;
      }
      if (input === 'r') { resolveItem(detail.item); return; }
      if (input === 'p') { replyTo(detail.item); return; }
      if (input === 'g') { setDetail(null); setPane('fleet'); execute(`herdr agent focus ${detail.item.from}`); return; }
      if (key.pageUp) { scroll('detail', -1); return; }
      if (key.pageDown) { scroll('detail', 1); return; }
      return;
    }

    if (key.escape) {
      setProposed(null); setOptions([]); setLine(''); say('discarded');
      return;
    }
    if (key.return) {
      if (!value.trim()) {
        if (pane === 'waiting') { openDetail(items[sel]); return; }
        if (pane === 'inbox') { openDetail(tail[sel]); return; }
        if (pane === 'fleet') {
          const r = rows[sel];
          if (r && r.kind === 'unit') { openUnit(r.name); return; }
          if (r && r.kind === 'ws') { say(`${r.ws}: ${r.units} products - select one to open it`); return; }
        }
      }
      submit();
      return;
    }
    if (key.tab) {
      const { value: v, hits } = complete(value, doc);
      setLine(v);
      if (hits.length > 1) say(hits.slice(0, 8).join('  '));
      return;
    }
    if (key.pageUp) { scroll('output', -5); return; }
    if (key.pageDown) { scroll('output', 5); return; }

    if (key.leftArrow) { const r = left(value, cursor); setValue(r.value); setCursor(r.cursor); return; }
    if (key.rightArrow) { const r = right(value, cursor); setValue(r.value); setCursor(r.cursor); return; }

    // Arrows move the selection - they are what anyone reaches for first,
    // and Shift+arrow never arrived through the owner's terminal host. The
    // command history is Ctrl+P / Ctrl+N (previous / next, the shell
    // spelling) and the Ctrl+R picker.
    if (key.upArrow || key.downArrow) {
      setSel((s) => (key.upArrow ? Math.max(0, s - 1) : Math.min(list.length - 1, s + 1)));
      return;
    }
    // ink names the byte Backspace sends on almost every terminal (\x7f)
    // "delete" and only \b "backspace"; the first cut forward-deleted on
    // Backspace, which at the end of a line does nothing - "I cannot
    // backspace". The raw chunk tells the two apart: Delete is \x1b[3~.
    const forwardDelete = key.delete && lastRaw.current === '\x1b[3~';
    if (key.backspace || (key.delete && !forwardDelete)) { const r = backspace(value, cursor); setValue(r.value); setCursor(r.cursor); return; }
    if (forwardDelete) { const r = del(value, cursor); setValue(r.value); setCursor(r.cursor); return; }

    if (key.ctrl) {
      switch (input) {
        case 'c': exit(); return;
        case 'a': setCursor(home(value).cursor); return;
        case 'e': setCursor(end(value).cursor); return;
        case 'w': { const r = killWord(value, cursor); setValue(r.value); setCursor(r.cursor); return; }
        case 'k': { const r = killToEnd(value, cursor); setValue(r.value); setCursor(r.cursor); return; }
        case 'u': { const r = killLine(); setValue(r.value); setCursor(r.cursor); setProposed(null); return; }
        case 'l': setOutCollapsed((v) => !v); return;
        case 'r': setPicker({ query: '', sel: 0 }); return;
        case 'p': case 'n': {
          if (hIndex.current < 0) typed.current = value;
          const r = historyWalk(history.current, hIndex.current, input === 'p' ? 'up' : 'down', typed.current);
          hIndex.current = r.index;
          setLine(r.value);
          return;
        }
        // Three panels now, not two: the inbox tail is a list you can enter.
        case 't': setPane((p) => (p === 'fleet' ? 'waiting' : p === 'waiting' ? 'inbox' : 'fleet')); setSel(0); return;
        case 'd': if (pane === 'waiting') openDetail(items[sel]); else if (pane === 'inbox') openDetail(tail[sel]); return;
        case 'f': {
          const r = rows[sel];
          if (pane === 'fleet' && r && r.kind === 'unit') execute(`herdr agent focus ${r.name}-orch`);
          else say('Ctrl+F focuses the selected unit on the fleet panel (Ctrl+T switches panel)');
          return;
        }
        case 'o': {
          const r = rows[sel];
          if (pane !== 'fleet' || !r) { say('Ctrl+O opens the selected workspace dashboard on the fleet panel'); return; }
          (async () => {
            const out = await run(CEL_BIN, ['dash', '--ensure', '--workspace', r.ws]);
            const url = /(https?:\/\/\S+)/.exec(out.out + out.err);
            if (url) { spawn('xdg-open', [url[1]], { stdio: 'ignore', detached: true }).unref(); say(`opened ${url[1]}`); }
            else say('no dashboard URL - try cel dash --ensure');
          })();
          return;
        }
        default: return;
      }
    }
    // A PASTE arrives bracketed (\x1b[200~ … \x1b[201~) from herdr and most
    // terminals; the markers are control bytes but the text between them is
    // exactly what the operator meant to type. Take the text, drop the rest.
    // A WHOLE LINE IN ONE CHUNK - a paste with a newline, or herdr's `pane run`
    // - is text followed by Enter, not a keypress ink has a name for: it came
    // through as input with a \r inside, which the control-byte rule below
    // then dropped whole. Insert the text, then submit it.
    if (input && /[\r\n]/.test(input)) {
      const first = input.replace(/\x1b\[20[01]~/g, '').split(/\r?\n|\r/)[0].replace(/[\x00-\x08\x0b-\x1f\x7f]/g, '');
      const r = insert(value, cursor, first);
      setValue(r.value); setCursor(r.cursor);
      submitValue(r.value);
      return;
    }
    if (input && input.includes('\x1b[200~')) {
      const pasted = input.replace(/\x1b\[200~([\s\S]*?)\x1b\[201~/g, '$1').replace(/[\x00-\x08\x0b-\x1f\x7f]/g, '').replace(/\r?\n/g, ' ');
      if (pasted) { const r = insert(value, cursor, pasted); setValue(r.value); setCursor(r.cursor); }
      return;
    }
    // `q` ON AN EMPTY COMMAND LINE IS THE QUOTA VIEW. Bare letters normally
    // type, so this costs the one sentence that begins with a `q` and buys
    // the question an operator asks most often before delegating: what is
    // left on the two subscriptions, and when does it come back. Anything
    // already typed still types - `q` only acts on an empty line.
    if (input === 'q' && !value && view === 'main' && !key.ctrl && !key.meta) {
      setQuota(true);
      return;
    }
    if (input && !key.meta && !hasControl(input)) { const r = insert(value, cursor, input); setValue(r.value); setCursor(r.cursor); }
  });

  const width = stdout?.columns || 80;
  const screen = stdout?.rows || 30;

  // THE LAYOUT SURVIVES A RESIZE. The fleet takes the rows it needs up to a
  // third of the screen, waiting and the tail split what is left, and the
  // command line with its two lines is subtracted first - because the one
  // thing that must never be pushed off the bottom is the thing the operator
  // types into.
  const layout = useMemo(() => {
    const chrome = 3;                       // command line + status + legend
    const frames = 3 * 3;                   // three panel borders and titles
    const outputRows = outCollapsed || !output ? 0 : Math.max(3, Math.min(12, Math.floor(screen / 4)));
    const free = Math.max(6, screen - chrome - frames - (outputRows ? outputRows + 3 : 0));
    const fleetRowsMax = Math.max(2, Math.floor(screen / 3));
    const fleetH = Math.min(rows.length || 1, fleetRowsMax);
    const rest = Math.max(4, free - fleetH);
    const remaining = rest;
    return {
      fleet: fleetH,
      detail: detail ? Math.max(6, screen - chrome - 3 - (outputRows ? outputRows + 3 : 0)) : 0,
      unitWorkers: Math.max(3, Math.floor((screen - chrome - 12) / 2)),
      full: Math.max(6, screen - chrome - 3),
      waiting: Math.max(1, Math.ceil(remaining / 2)),
      inbox: Math.max(1, Math.floor(remaining / 2)),
      output: outputRows,
    };
  }, [screen, rows.length, detail, output, outCollapsed]);

  const outAll = output ? output.split('\n') : [];
  const outWin = window_(outAll, outOffset || Math.max(0, outAll.length - layout.output), layout.output);
  const outFullH = Math.max(6, screen - 3 - 3);
  const outFull = window_(outAll, outOffset === 1 ? 0 : (outOffset || Math.max(0, outAll.length - outFullH)), outFullH);

  // The hit map is rebuilt from the RENDERED boxes after every render and on
  // every resize. `measureElement` gives heights; the tops are the running sum
  // down the single column the app is, which is the only assumption here and
  // the one ink's layout guarantees.
  useEffect(() => {
    const map = [];
    let top = 1;
    const push = (panel, ref, count, extra = 0) => {
      const el = ref.current;
      if (!el) return;
      const { height } = measureElement(el);
      if (!height) return;
      const first = top + 2 + extra;            // border row, then the title row
      map.push({
        panel,
        top,
        bottom: top + height - 1,
        rows: Array.from({ length: count }, (_, i) => first + i),
      });
      top += height;
    };
    if (view === 'main') push('fleet', refs.fleet, Math.min(layout.fleet, rows.length), offsets.fleet > 0 ? 1 : 0);
    if (detail) push('detail', refs.detail, 0);
    // The detail view's three buttons are its "rows": resolve, reply, go to -
    // all on one line, which the click handler maps by index.
    if (detail && map.length && map[map.length - 1].panel === 'detail') {
      const d = map[map.length - 1];
      d.rows = [d.bottom - 1, d.bottom - 1, d.bottom - 1];
    }
    if (view === 'unit') {
      push('unitorch', refs.unitOrch, 2);
      push('unitworkers', refs.unitWorkers, unitWorkers.length, 1);   // 1: the header row
      push('unitwaiting', refs.unitWaiting, unitItems.length);
      push('unitmail', refs.unitMail, unitMail.length);
      // The orchestrator panel's two buttons share one line, the last of it.
      const o = map.find((m2) => m2.panel === 'unitorch');
      if (o) o.rows = [o.bottom - 1, o.bottom - 1];
    }
    if (view === 'worker') {
      push('worker', refs.worker, 0);
      const wv = map[map.length - 1];
      if (wv && wv.panel === 'worker') wv.rows = workerButtons(worker?.preview).map(() => wv.bottom - 1);
    }
    if (view === 'main') push('waiting', refs.waiting, Math.min(layout.waiting, items.length), offsets.waiting > 0 ? 1 : 0);
    if (view === 'main') push('inbox', refs.inbox, Math.min(layout.inbox, tail.length), offsets.inbox > 0 ? 1 : 0);
    if (layout.output) push('output', refs.output, outWin.rows.length);
    hitMap.current = map;
  });

  const pickerMatches = picker ? historyFilter(history.current, picker.query).slice(0, 12) : [];

  // ONE VIEW AT A TIME. Help, the history picker and a decision's detail each
  // take the whole stack; appending them under three panels that already fill
  // the screen put them below the last row, where nobody ever saw them - the
  // owner's "? did nothing" was exactly that.
  const view = help ? 'help' : quota ? 'quota' : picker ? 'picker' : detail ? 'detail'
    : worker ? 'worker' : unit ? 'unit'
      : (outView && output && !outCollapsed) ? 'output' : 'main';
  escapeRef.current = () => {
    if (help) { setHelp(false); return; }
    if (quota) { setQuota(false); return; }
    if (picker) { setPicker(null); return; }
    if (detail) { setDetail(null); setPane(unit ? 'unit' : 'waiting'); say('back'); return; }
    if (worker) { setWorker(null); setPane(unit ? 'unit' : 'fleet'); say('back'); return; }
    if (unit) { setUnit(null); setPane('fleet'); say('back'); return; }
    if (view === 'output' && !value) { setOutView(false); say('back'); return; }
    const had = !!proposed || options.length > 0 || !!value;
    setProposed(null); setOptions([]); setLine('');
    if (had) say('discarded');
  };
  const stack = view === 'help'
    ? [h(Overlay, { key: 'help', title: 'KEYS  ·  Esc closes', lines: helpLines() })]
    : view === 'quota'
      ? [h(Overlay, { key: 'quota', title: 'QUOTA  ·  Esc closes', lines: quotaView(doc) })]
    : view === 'picker'
      ? [h(Overlay, {
        key: 'picker',
        title: `HISTORY  ${picker.query ? `/${picker.query}` : '(type to filter)'}  ·  Enter takes it, Esc closes`,
        lines: pickerMatches.length
          ? pickerMatches.map((l, i) => `${i === picker.sel ? '▸' : ' '} ${l}`)
          : ['  nothing matches'],
      })]
      : view === 'detail'
        ? [h(DetailView, {
          key: 'detail', item: detail.item, thread: detail.thread, innerRef: refs.detail,
          target: senderTarget(detail.item.from),
        })]
        : view === 'worker'
          ? [h(WorkerView, {
            key: 'worker', worker: worker.worker, ws: worker.ws, why: worker.why,
            busy: worker.busy, preview: !!worker.preview, innerRef: refs.worker,
          })]
          : view === 'unit'
            ? [
              h(OrchPanel, { key: 'orch', unit, innerRef: refs.unitOrch }),
              h(WorkersPanel, { key: 'workers', workers: unitWorkers, sel: wsel, innerRef: refs.unitWorkers, focused: true, byMemory: wsort }),
              h(UnitWaiting, { key: 'uwait', items: unitItems, innerRef: refs.unitWaiting }),
              h(UnitMail, { key: 'umail', lines: unitMail, innerRef: refs.unitMail }),
            ]
        : view === 'output'
          ? [h(Panel, {
            key: 'output', title: 'OUTPUT', innerRef: refs.output, focused: true,
            right: `${outAll.length} lines · ${raw ? '[raw] on' : '[raw] r'} · ↑/↓ PgUp/PgDn · Esc back`,
          }, h(More, { n: outFull.above, up: true }),
          ...outFull.rows.map((l, i) => h(Text, { key: i, wrap: 'truncate-end' }, l || ' ')),
          h(More, { n: outFull.below }))]
          : [
          h(FleetPanel, {
            key: 'fleet', doc, rows, sel: pane === 'fleet' ? sel : -1, offset: offsets.fleet,
            height: layout.fleet, innerRef: refs.fleet, focused: pane === 'fleet', loaded,
          }),
          h(OpenPanel, {
            key: 'waiting', items, sel: pane === 'waiting' ? sel : -1, offset: offsets.waiting,
            height: layout.waiting, innerRef: refs.waiting, focused: pane === 'waiting', loaded,
          }),
          h(TailPanel, { key: 'inbox', lines: tail, offset: offsets.inbox || Math.max(0, tail.length - layout.inbox), height: layout.inbox, innerRef: refs.inbox, focused: pane === 'inbox', loaded }),
        ];
  return h(Box, { flexDirection: 'column', width, height: screen },
    ...stack,
    view === 'main' && layout.output
      ? h(Panel, {
        title: 'OUTPUT',
        innerRef: refs.output,
        focused: pane === 'output',
        right: outAll.length > layout.output ? `${outAll.length} lines · PgUp/PgDn · ^L collapses` : '^L collapses',
      }, h(More, { n: outWin.above, up: true }),
      ...outWin.rows.map((l, i) => h(Text, { key: i, wrap: 'truncate-end' }, l || ' ')),
      h(More, { n: outWin.below }))
      : (output && view === 'main' ? h(Text, { color: C.dim }, `OUTPUT collapsed (${outAll.length} lines) - ^L expands`) : null),
    // THE BOTTOM THREE ROWS ARE THE OPERATOR'S. The spacer absorbs whatever
    // height the panels did not use, so the command line, the status and the
    // legend sit on the last rows of the screen rather than floating halfway
    // up it on a tall terminal.
    h(Box, { flexGrow: 1 }),
    h(CommandLine, { value, cursor, proposed: !!proposed }),
    // TWO LINES, ALWAYS. The transient one on top with the time it was set,
    // the permanent legend under it.
    h(Box, null,
      h(Text, { color: status ? C.ink : C.dim }, `${busy ? '… ' : ''}${status || ''}`),
      h(Box, { flexGrow: 1 }),
      // THE BOX ITSELF, on the one row that belongs to no panel. Dim while
      // there is headroom, warn under 15% available, bad under 8% - at which
      // point the kernel is minutes from choosing what dies, and what it picks
      // is never what anyone would have chosen.
      // ...and the two subscriptions beside it. Amber at 80, red at 100: at
      // 100 the next delegation on that account refuses, which is a harder
      // stop than any amount of free memory.
      subsEdge(doc)
        ? h(Text, {
          color: { bad: C.bad, warn: C.warn }[subsLevel(doc)] || C.dim,
        }, `${subsEdge(doc)}   `)
        : null,
      memFree(doc.box)
        ? h(Text, {
          color: { bad: C.bad, warn: C.warn }[memLevel(doc.box)] || C.dim,
        }, `${memFree(doc.box)}   `)
        : null,
      h(Text, { color: C.dim }, status ? statusAt : `${routerLabel() && !noRouter ? `${routerLabel()} · ` : ''}${translatorLabel()} · ${at}`)),
    h(Box, null, h(Text, { color: C.dim }, legend(
      view === 'detail' ? 'detail' : view === 'worker' ? 'worker' : view === 'unit' ? 'unit'
        : view === 'quota' ? 'quota' : view === 'output' ? 'output' : pane))));
};

export const start = async (opts) => {
  const app = render(h(App, { refresh: opts.refresh || 10, statusSecs: opts.statusSecs ?? 8, noRouter: opts.router === false }), { exitOnCtrlC: true });
  await app.waitUntilExit();
  // Belt and braces: the effect's own cleanup has already run by here on a
  // normal quit, and LEAVE is idempotent at the terminal's end for the two
  // sequences it carries. A console that exits into a half-restored terminal is
  // the one bug in this file an operator cannot work around.
  try { process.stdout.write(LEAVE); } catch { /* the pipe is gone */ }
  // AND THEN WE GO. Reading stdin directly for mouse reports keeps a handle on
  // the terminal that outlives the React tree, so a console that merely
  // returned from start() sat there after Ctrl+C with the screen restored and
  // no way to type at it - the worst of both. Quitting means quitting.
  process.exit(0);
};
