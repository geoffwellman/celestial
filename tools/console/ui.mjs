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
import { render, Box, Text, useInput, useApp, useStdout, measureElement } from 'ink';
import { spawn } from 'node:child_process';

import { C, orchColour, kindColour } from './theme.mjs';
import {
  CEL_BIN, fleet, fleetRows, openItems, inboxTail, runCommand, runChain, run, thread,
  readHistory, appendHistory, unitLabel,
} from './state.mjs';
import { translate, NoTranslator, translatorLabel } from './translate.mjs';
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

const Panel = ({ title, right, innerRef, children }) =>
  h(Box, { flexDirection: 'column', borderStyle: 'round', borderColor: C.line, paddingX: 1, ref: innerRef },
    h(Box, null,
      h(Text, { color: C.accent, bold: true }, title),
      h(Box, { flexGrow: 1 }),
      right ? h(Text, { color: C.dim }, right) : null),
    children);

const FleetPanel = ({ doc, rows, sel, offset, height, innerRef }) => {
  const w = window_(rows, offset, height);
  return h(Panel, {
    title: 'FLEET',
    innerRef,
    right: doc.error ? doc.error : `${rows.filter((r) => r.kind === 'unit').length} units`,
  },
  rows.length === 0 ? h(Text, { color: C.dim }, '  no workspaces registered') : null,
  h(More, { n: w.above, up: true }),
  ...w.rows.map((r, i) => {
    const on = w.start + i === sel;
    if (r.kind === 'ws') {
      return h(Text, { key: `w${r.ws}`, color: C.ink, bold: true, inverse: on },
        `${r.ws}  `,
        h(Text, { color: C.dim }, `(${r.units} products)  root mail: ${r.root.unread} unread, `),
        h(Text, { color: r.root.open ? C.accent : C.dim }, `${r.root.open} open`));
    }
    return h(Text, { key: `u${r.ws}/${r.name}`, inverse: on },
      h(Text, { color: C.dim }, '  '),
      h(Text, { color: C.ink }, unitLabel(r).padEnd(14)),
      h(Text, { color: orchColour(r.orch) }, `orch ${String(r.orch).padEnd(8)}`),
      h(Text, { color: C.dim }, 'workers '),
      h(Text, { color: r.workers ? C.ink : C.dim }, `${r.workers}/${r.cap}   `),
      h(Text, { color: r.stalled ? C.bad : C.dim }, `stalled ${r.stalled}   `),
      h(Text, { color: r.unlanded ? C.warn : C.dim }, `unlanded ${r.unlanded}`));
  }),
  h(More, { n: w.below }));
};

const OpenPanel = ({ items, sel, offset, height, innerRef }) => {
  const w = window_(items, offset, height);
  return h(Panel, { title: 'WAITING ON YOU', innerRef, right: items.length ? `${items.length} open` : '' },
    items.length === 0 ? h(Text, { color: C.dim }, 'nothing open') : null,
    h(More, { n: w.above, up: true }),
    ...w.rows.map((it, i) => h(Text, { key: it.id, inverse: w.start + i === sel, wrap: 'truncate-end' },
      h(Text, { color: C.accent }, `[${it.id}] `),
      h(Text, { color: C.dim }, `${String(it.ts).slice(0, 16)} ${it.ws} `),
      h(Text, { color: kindColour(it.kind) }, `${it.kind} `),
      h(Text, { color: C.dim }, `from ${it.from}: `),
      h(Text, { color: C.ink }, it.message))),
    h(More, { n: w.below }));
};

// THE DETAIL VIEW IS A PLACE. It was a three-line popup inside the waiting
// panel, which meant the message was still truncated and the rest of the
// conversation was somewhere else entirely - so reading a decision meant
// leaving the console for a pane. Now it takes the room, carries the whole
// message and the thread around it, and has buttons you can click.
const DetailView = ({ item, thread: rows, innerRef }) =>
  h(Panel, { title: 'DECISION', innerRef, right: `${item.ws} · ${String(item.ts).slice(0, 16)}` },
    h(Text, null,
      h(Text, { color: C.accent }, `[${item.id}] `),
      h(Text, { color: kindColour(item.kind) }, `${item.kind} `),
      h(Text, { color: C.dim }, `from ${item.from}`)),
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
      h(Text, { color: C.ink }, '[go to]')));

const TailPanel = ({ lines, offset, height, innerRef }) => {
  const w = window_(lines, offset, height);
  return h(Panel, { title: 'INBOX', innerRef },
    lines.length === 0 ? h(Text, { color: C.dim }, 'quiet') : null,
    h(More, { n: w.above, up: true }),
    ...w.rows.map((m, i) => h(Text, { key: `${m.ts}${i}`, wrap: 'truncate-end' },
      h(Text, { color: C.dim }, `[${m.ws}] `),
      h(Text, { color: kindColour(m.kind) }, `${m.kind} `),
      h(Text, { color: C.dim }, `${m.from}: `),
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
  return h(Box, null,
    h(Text, { color: proposed ? C.accent : C.ok }, proposed ? '? ' : '> '),
    h(Text, { color: colour }, value.slice(0, c)),
    h(Text, { color: colour, inverse: true }, value.slice(c, c + 1) || ' '),
    h(Text, { color: colour }, value.slice(c + 1)));
};

const Overlay = ({ title, lines, innerRef }) =>
  h(Panel, { title, innerRef },
    ...lines.map((l, i) => h(Text, { key: i, color: C.ink, wrap: 'truncate-end' }, l || ' ')));

const App = ({ refresh, statusSecs }) => {
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
  const [picker, setPicker] = useState(null);     // {query, sel} - Ctrl+R
  const [, setTick] = useState(0);                // a resize is a re-render
  const history = useRef(readHistory());
  const hIndex = useRef(-1);
  const lastRaw = useRef('');
  const typed = useRef('');
  const lastClick = useRef({ panel: '', index: -1, at: 0 });
  const hitMap = useRef([]);
  const refs = {
    fleet: useRef(null), detail: useRef(null), waiting: useRef(null),
    inbox: useRef(null), output: useRef(null),
  };
  const rows = fleetRows(doc);
  const rowsRef = useRef(rows); rowsRef.current = rows;
  const itemsRef = useRef(items); itemsRef.current = items;

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
    setOutput(r.out || '(no output)');
    setOutOffset(0);
    say(r.ok ? 'done' : 'command exited non-zero');
    appendHistory(cmd);
    history.current = [...history.current, cmd];
    reload();
    return r.ok;
  }, [reload, say]);

  // A CHAIN IS ALLOWLISTED WHOLE BEFORE ANY OF IT RUNS (state.mjs:runChain), and
  // then stops at the first non-zero exit. The operator pressed Enter once, on
  // a proposal they were told the guard would check - so a refusal on line two
  // must not arrive after line one has already changed the box.
  const executeChain = useCallback(async (cmds) => {
    if (cmds.length === 1) { await execute(cmds[0]); return; }
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
      return;
    }
    setOutput(r.results.map((s2) => `$ ${s2.cmd}\n${s2.out || '(no output)'}`).join('\n\n') || '(no output)');
    setOutOffset(0);
    for (const s2 of r.results) appendHistory(s2.cmd);
    history.current = [...history.current, ...r.results.map((s2) => s2.cmd)];
    reload();
    say(r.stoppedAt != null
      ? `stopped at ${r.stoppedAt + 1}/${cmds.length} - it exited non-zero`
      : `done - ${cmds.length} commands`);
  }, [execute, reload, say]);

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
    say(`asking ${translatorLabel()}…`);
    const state = `fleet: ${JSON.stringify(doc)}\nopen decisions: ${JSON.stringify(items)}`;
    let cmds = [], raw = '';
    try {
      ({ cmds, raw } = await translate({ sentence: text, state }));
    } catch (e) {
      setBusy(false);
      say(e instanceof NoTranslator ? e.message : `model: ${e.message}`);
      return;
    }
    if (cmds.length) { setBusy(false); propose(cmds); return; }
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
  }, [doc, items, propose, say]);

  const openDetail = useCallback((it) => {
    if (!it) return;
    setDetail({ item: it, thread: thread(it) });
    setPane('detail');
  }, []);

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

  const submit = useCallback(async () => {
    const text = value.trim();
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
      if (pick) { setOptions([]); propose([pick.cmd]); return; }
    }
    // A PROPOSED command runs on the SECOND Enter and not before. The model
    // never executes anything: it writes a line, the operator reads it, and
    // the keystroke that runs it is theirs.
    if (proposed && text === proposed.cmds.join(' ; ')) {
      const { cmds } = proposed;
      setProposed(null);
      setLine('');
      await executeChain(cmds);
      return;
    }
    if (COMMAND.test(text)) { setLine(''); await execute(text); return; }
    await ask(text);
  }, [value, proposed, options, exit, execute, executeChain, ask, propose, setLine]);

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
    if (hit.panel === 'detail') {
      const it = detail?.item;
      if (hit.index === 0) resolveItem(it);
      else if (hit.index === 1) replyTo(it);
      else if (hit.index === 2) execute(`herdr agent focus ${it.from}`);
      return;
    }
    if (hit.index < 0) { setPane(hit.panel === 'fleet' || hit.panel === 'waiting' ? hit.panel : pane); return; }
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
      if (dbl && r && r.kind === 'unit') execute(`herdr agent focus ${r.name}-orch`);
      return;
    }
    if (hit.panel === 'waiting') {
      setPane('waiting');
      setSel(hit.index);
      if (dbl) openDetail(itemsRef.current[hit.index]);
    }
  }, [detail, options, pane, execute, openDetail, propose, replyTo, resolveItem, scroll]);

  // ink's useInput hands a mouse report through as ordinary input on some
  // terminals and swallows it on others, so stdin is read directly and ONLY
  // for the SGR sequences; everything else is left to ink, which owns the
  // keyboard.
  useEffect(() => {
    const onData = (chunk) => {
      const s = String(chunk);
      lastRaw.current = s;
      if (!hasMouse(s)) return;
      for (const ev of parseMouseAll(s)) onMouse(ev);
    };
    // Prepended so it runs before ink's own listener: useInput below reads
    // lastRaw to tell Backspace from Delete, which ink reports alike.
    process.stdin.prependListener('data', onData);
    return () => process.stdin.off('data', onData);
  }, [onMouse]);

  const list = pane === 'waiting' ? items : rows;

  useInput((input, key) => {
    // A mouse report that reached the keyboard is not text: without this it
    // types `[<0;40;12M` into the command line.
    if (hasMouse(input)) return;

    if (help) { if (key.escape || key.return || input === '\u001bOP' || key.f1) setHelp(false); return; }

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
    if (detail) {
      if (key.escape) { setDetail(null); setPane('waiting'); return; }
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
      if (pane === 'waiting' && !value.trim()) { openDetail(items[sel]); return; }
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
        case 't': setPane((p) => (p === 'fleet' ? 'waiting' : 'fleet')); setSel(0); return;
        case 'd': if (pane === 'waiting') openDetail(items[sel]); return;
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
    const fleetH = detail ? Math.min(3, fleetRowsMax) : Math.min(rows.length || 1, fleetRowsMax);
    const rest = Math.max(4, free - fleetH);
    const detailH = detail ? Math.max(4, Math.floor(rest / 2)) : 0;
    const remaining = Math.max(2, rest - detailH);
    return {
      fleet: fleetH,
      detail: detailH,
      waiting: Math.max(1, Math.ceil(remaining / 2)),
      inbox: Math.max(1, Math.floor(remaining / 2)),
      output: outputRows,
    };
  }, [screen, rows.length, detail, output, outCollapsed]);

  const outAll = output ? output.split('\n') : [];
  const outWin = window_(outAll, outOffset || Math.max(0, outAll.length - layout.output), layout.output);

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
    push('fleet', refs.fleet, Math.min(layout.fleet, rows.length), offsets.fleet > 0 ? 1 : 0);
    if (detail) push('detail', refs.detail, 0);
    // The detail view's three buttons are its "rows": resolve, reply, go to -
    // all on one line, which the click handler maps by index.
    if (detail && map.length && map[map.length - 1].panel === 'detail') {
      const d = map[map.length - 1];
      d.rows = [d.bottom - 1, d.bottom - 1, d.bottom - 1];
    }
    push('waiting', refs.waiting, Math.min(layout.waiting, items.length), offsets.waiting > 0 ? 1 : 0);
    push('inbox', refs.inbox, Math.min(layout.inbox, tail.length), offsets.inbox > 0 ? 1 : 0);
    if (layout.output) push('output', refs.output, outWin.rows.length);
    hitMap.current = map;
  });

  const pickerMatches = picker ? historyFilter(history.current, picker.query).slice(0, 12) : [];

  return h(Box, { flexDirection: 'column', width, height: screen },
    h(FleetPanel, {
      doc, rows, sel: pane === 'fleet' ? sel : -1, offset: offsets.fleet,
      height: layout.fleet, innerRef: refs.fleet,
    }),
    detail ? h(DetailView, { item: detail.item, thread: detail.thread, innerRef: refs.detail }) : null,
    h(OpenPanel, {
      items, sel: pane === 'waiting' ? sel : -1, offset: offsets.waiting,
      height: layout.waiting, innerRef: refs.waiting,
    }),
    h(TailPanel, { lines: tail, offset: offsets.inbox || Math.max(0, tail.length - layout.inbox), height: layout.inbox, innerRef: refs.inbox }),
    layout.output
      ? h(Panel, {
        title: 'OUTPUT',
        innerRef: refs.output,
        right: outAll.length > layout.output ? `${outAll.length} lines · PgUp/PgDn · ^L collapses` : '^L collapses',
      }, h(More, { n: outWin.above, up: true }),
      ...outWin.rows.map((l, i) => h(Text, { key: i, wrap: 'truncate-end' }, l || ' ')),
      h(More, { n: outWin.below }))
      : (output ? h(Text, { color: C.dim }, `OUTPUT collapsed (${outAll.length} lines) - ^L expands`) : null),
    help ? h(Overlay, { title: 'KEYS', lines: helpLines() }) : null,
    picker ? h(Overlay, {
      title: `HISTORY  ${picker.query ? `/${picker.query}` : '(type to filter)'}`,
      lines: pickerMatches.length
        ? pickerMatches.map((l, i) => `${i === picker.sel ? '>' : ' '} ${l}`)
        : ['  nothing matches'],
    }) : null,
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
      h(Text, { color: C.dim }, status ? statusAt : `${translatorLabel()} · ${at}`)),
    h(Box, null, h(Text, { color: C.dim }, legend(detail ? 'detail' : pane))));
};

export const start = async (opts) => {
  const app = render(h(App, { refresh: opts.refresh || 10, statusSecs: opts.statusSecs ?? 8 }), { exitOnCtrlC: true });
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
