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
import React, { createElement as h, useState, useEffect, useRef, useCallback } from 'react';
import { render, Box, Text, useInput, useApp, useStdout } from 'ink';
import { spawn } from 'node:child_process';
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';

import { C, orchColour, kindColour } from './theme.mjs';
import {
  CEL_BIN, fleet, fleetRows, openItems, inboxTail, tailLine, runCommand, run,
} from './state.mjs';
import { translate, NoTranslator, translatorLabel } from './translate.mjs';

const HISTORY = process.env.CEL_CONSOLE_HISTORY
  || join(homedir(), '.local/share/cel/console/history');
const HISTORY_MAX = 500;

const readHistory = () => {
  try { return readFileSync(HISTORY, 'utf8').split('\n').filter(Boolean); } catch { return []; }
};
const appendHistory = (line) => {
  try {
    mkdirSync(dirname(HISTORY), { recursive: true });
    appendFileSync(HISTORY, `${line}\n`);
    const all = readHistory();
    if (all.length > HISTORY_MAX * 1.5) writeFileSync(HISTORY, `${all.slice(-HISTORY_MAX).join('\n')}\n`);
  } catch { /* a console that cannot write its history is still a console */ }
};

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
  const hits = frag
    ? all.filter((w) => w.startsWith(frag) || w.startsWith(value))
    : [];
  if (!hits.length) {
    const whole = all.filter((w) => w.startsWith(value));
    return whole.length ? { value: whole[0], hits: whole } : { value, hits: [] };
  }
  const first = hits[0];
  return { value: first.startsWith(value) ? first : head + first, hits };
};

const Panel = ({ title, right, children }) =>
  h(Box, { flexDirection: 'column', borderStyle: 'round', borderColor: C.line, paddingX: 1 },
    h(Box, null,
      h(Text, { color: C.accent, bold: true }, title),
      h(Box, { flexGrow: 1 }),
      right ? h(Text, { color: C.dim }, right) : null),
    children);

const FleetPanel = ({ doc, rows, sel }) =>
  h(Panel, { title: 'FLEET', right: doc.error ? doc.error : `${rows.filter((r) => r.kind === 'unit').length} units` },
    rows.length === 0 ? h(Text, { color: C.dim }, '  no workspaces registered') : null,
    ...rows.map((r, i) => {
      const on = i === sel;
      if (r.kind === 'ws') {
        return h(Text, { key: `w${r.ws}`, color: C.ink, bold: true, inverse: on },
          `${r.ws}  `,
          h(Text, { color: C.dim }, `(${r.units} repos)  root mail: ${r.root.unread} unread, `),
          h(Text, { color: r.root.open ? C.accent : C.dim }, `${r.root.open} open`));
      }
      return h(Text, { key: `u${r.ws}/${r.name}`, inverse: on },
        h(Text, { color: C.dim }, '  '),
        h(Text, { color: C.ink }, r.name.padEnd(14)),
        h(Text, { color: orchColour(r.orch) }, `orch ${String(r.orch).padEnd(8)}`),
        h(Text, { color: C.dim }, 'workers '),
        h(Text, { color: r.workers ? C.ink : C.dim }, `${r.workers}/${r.cap}   `),
        h(Text, { color: r.stalled ? C.bad : C.dim }, `stalled ${r.stalled}   `),
        h(Text, { color: r.unlanded ? C.warn : C.dim }, `unlanded ${r.unlanded}`));
    }));

const OpenPanel = ({ items, sel, detail }) =>
  h(Panel, { title: 'WAITING ON YOU', right: items.length ? `${items.length} open` : '' },
    items.length === 0 ? h(Text, { color: C.dim }, 'nothing open') : null,
    ...items.map((it, i) => h(Text, { key: it.id, inverse: i === sel, wrap: 'truncate-end' },
      h(Text, { color: C.accent }, `[${it.id}] `),
      h(Text, { color: C.dim }, `${String(it.ts).slice(0, 16)} ${it.ws} `),
      h(Text, { color: kindColour(it.kind) }, `${it.kind} `),
      h(Text, { color: C.dim }, `from ${it.from}: `),
      h(Text, { color: C.ink }, it.message))),
    detail ? h(Box, { marginTop: 1, flexDirection: 'column' },
      h(Text, { color: C.accent }, `[${detail.id}] ${detail.ws} ${detail.kind} from ${detail.from}`),
      h(Text, { color: C.ink }, detail.message),
      h(Text, { color: C.dim }, 'r resolves it - any other key closes this')) : null);

const TailPanel = ({ lines }) =>
  h(Panel, { title: 'INBOX' },
    lines.length === 0 ? h(Text, { color: C.dim }, 'quiet') : null,
    ...lines.map((m, i) => h(Text, { key: `${m.ts}${i}`, wrap: 'truncate-end' },
      h(Text, { color: C.dim }, `[${m.ws}] `),
      h(Text, { color: kindColour(m.kind) }, `${m.kind} `),
      h(Text, { color: C.dim }, `${m.from}: `),
      h(Text, { color: C.ink }, m.message))));

const App = ({ refresh }) => {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [doc, setDoc] = useState({ workspaces: [] });
  const [items, setItems] = useState([]);
  const [tail, setTail] = useState([]);
  const [sel, setSel] = useState(0);
  const [pane, setPane] = useState('fleet');      // which panel the selection moves in
  const [detail, setDetail] = useState(null);
  const [value, setValue] = useState('');
  const [proposed, setProposed] = useState('');
  const [output, setOutput] = useState('');
  const [status, setStatus] = useState('');
  const [busy, setBusy] = useState(false);
  const [at, setAt] = useState('');
  const history = useRef(readHistory());
  const hIndex = useRef(-1);
  const rows = fleetRows(doc);

  const reload = useCallback(async () => {
    const d = await fleet();
    setDoc(d);
    setItems(await openItems(d));
    setTail((prev) => {
      const seeded = inboxTail(d, 8);
      return prev.length > seeded.length ? prev.slice(-8) : seeded;
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
        setTail((prev) => [...prev, item].slice(-8));
      }
    });
    child.on('error', () => setStatus('cel inbox watch could not start - mail will still refresh'));
    return () => child.kill();
  }, [stdout]);

  const execute = useCallback(async (cmd) => {
    setBusy(true);
    setStatus(`running: ${cmd}`);
    const r = await runCommand(cmd);
    setBusy(false);
    if (!r.allow) {
      setOutput(`refused: ${r.reason}`);
      setStatus('refused by the console allowlist');
      return;
    }
    setOutput(r.out || '(no output)');
    setStatus(r.ok ? 'done' : 'command exited non-zero');
    appendHistory(cmd);
    history.current = [...history.current, cmd];
    reload();
  }, [reload]);

  const submit = useCallback(async () => {
    const text = value.trim();
    if (!text) return;
    if (/^(q|quit|exit)$/.test(text)) { exit(); return; }
    // A PROPOSED command runs on the SECOND Enter and not before. The model
    // never executes anything: it writes a line, the operator reads it, and
    // the keystroke that runs it is theirs.
    if (proposed && text === proposed) { setProposed(''); setValue(''); await execute(text); return; }
    if (/^(cel|cel-fanout|cel-linear|gh|herdr)(\s|$)/.test(text)) {
      setValue('');
      await execute(text);
      return;
    }
    setBusy(true);
    setStatus(`asking ${translatorLabel()}…`);
    try {
      const state = `fleet: ${JSON.stringify(doc)}\nopen decisions: ${JSON.stringify(items)}`;
      const { cmd, raw } = await translate({ sentence: text, state });
      setBusy(false);
      if (!cmd) {
        const said = raw && raw !== '?' ? ` (model said: ${raw.replace(/\s+/g, ' ').slice(0, 70)})` : '';
        setStatus(`no command for that - rephrase, or type the command${said}`);
        return;
      }
      setProposed(cmd);
      setValue(cmd);
      setStatus('proposed - Enter runs it, Esc discards it');
    } catch (e) {
      setBusy(false);
      setStatus(e instanceof NoTranslator ? e.message : `model: ${e.message}`);
    }
  }, [value, proposed, doc, items, execute]);

  useInput((input, key) => {
    if (key.escape) {
      if (detail) { setDetail(null); return; }
      setProposed(''); setValue(''); setStatus('discarded');
      return;
    }
    if (key.return) { if (detail) { setDetail(null); return; } submit(); return; }
    if (key.tab) {
      const { value: v, hits } = complete(value, doc);
      setValue(v);
      if (hits.length > 1) setStatus(hits.slice(0, 8).join('  '));
      return;
    }
    // Selection moves on Shift+arrows (or Ctrl+N / Ctrl+P); plain arrows are
    // history, as in a shell.
    if ((key.upArrow || key.downArrow) && key.shift) {
      const list = pane === 'fleet' ? rows : items;
      setSel((s) => key.upArrow ? Math.max(0, s - 1) : Math.min(list.length - 1, s + 1));
      return;
    }
    if (key.upArrow || key.downArrow) {
      const h2 = history.current;
      if (!h2.length) return;
      hIndex.current = key.upArrow
        ? Math.min(h2.length - 1, hIndex.current + 1)
        : Math.max(-1, hIndex.current - 1);
      setValue(hIndex.current < 0 ? '' : h2[h2.length - 1 - hIndex.current]);
      return;
    }
    if (key.backspace || key.delete) { setValue((v) => v.slice(0, -1)); return; }

    // Every action is a Ctrl chord. The first cut bound bare letters (j, k,
    // f, o, r, w, q, i) "only on an empty command line" - which is exactly
    // where the first letter of every sentence lands: "what's blocked" flipped
    // the panel and lost its w, "quit" exited, "resolve 12" resolved the
    // selected row instead. A letter typed into a console must always be a
    // letter typed.
    if (key.ctrl) {
      const list = pane === 'fleet' ? rows : items;
      switch (input) {
        case 'c': exit(); return;
        case 'u': setValue(''); setProposed(''); return;
        case 'n': setSel((s) => Math.min(list.length - 1, s + 1)); return;
        case 'p': setSel((s) => Math.max(0, s - 1)); return;
        case 't': setPane((p) => (p === 'fleet' ? 'open' : 'fleet')); setSel(0); return;
        case 'f': {
          const r = rows[sel];
          if (pane === 'fleet' && r && r.kind === 'unit') execute(`herdr agent focus ${r.name}-orch`);
          else setStatus('Ctrl+F focuses the selected unit on the fleet panel (Ctrl+T switches panel)');
          return;
        }
        case 'o': {
          const r = rows[sel];
          if (pane !== 'fleet' || !r) { setStatus('Ctrl+O opens the selected workspace dashboard on the fleet panel'); return; }
          (async () => {
            const out = await run(CEL_BIN, ['dash', '--ensure', '--workspace', r.ws]);
            const url = /(https?:\/\/\S+)/.exec(out.out + out.err);
            if (url) { spawn('xdg-open', [url[1]], { stdio: 'ignore', detached: true }).unref(); setStatus(`opened ${url[1]}`); }
            else setStatus('no dashboard URL - try cel dash --ensure');
          })();
          return;
        }
        case 'r': {
          const it = detail || (pane === 'open' ? items[sel] : null);
          if (it) { setDetail(null); execute(`cel inbox resolve ${it.id} --workspace ${it.ws}`); }
          else setStatus('Ctrl+R resolves the selected item on the waiting panel');
          return;
        }
        case 'e': if (pane === 'open') setDetail(items[sel] || null); else setStatus('Ctrl+E shows the selected item on the waiting panel'); return;
        default: return;
      }
    }
    if (input && !key.meta) setValue((v) => v + input);
  });

  const width = stdout?.columns || 80;
  const outLines = output ? output.split('\n').slice(-Math.max(3, Math.min(14, (stdout?.rows || 30) - 22))) : [];

  return h(Box, { flexDirection: 'column', width },
    h(FleetPanel, { doc, rows, sel: pane === 'fleet' ? sel : -1 }),
    h(OpenPanel, { items, sel: pane === 'open' ? sel : -1, detail }),
    h(TailPanel, { lines: tail }),
    outLines.length
      ? h(Panel, { title: 'OUTPUT' }, ...outLines.map((l, i) => h(Text, { key: i, wrap: 'truncate-end' }, l)))
      : null,
    h(Box, null,
      h(Text, { color: proposed ? C.accent : C.ok }, proposed ? '? ' : '> '),
      h(Text, { color: proposed ? C.accent : C.ink }, value || ''),
      h(Text, { color: C.dim }, '▏')),
    h(Box, null,
      h(Text, { color: C.dim },
        `${busy ? '… ' : ''}${status || '⇧↑/↓ select · ^T panel · ^F focus · ^O dashboard · ^E detail · ^R resolve · ^U clear · quit: ^C or type quit'}`),
      h(Box, { flexGrow: 1 }),
      h(Text, { color: C.dim }, `${translatorLabel()} · ${at}`)));
};

export const start = async (opts) => {
  const app = render(h(App, { refresh: opts.refresh || 10 }), { exitOnCtrlC: true });
  await app.waitUntilExit();
};
