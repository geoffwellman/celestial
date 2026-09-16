#!/usr/bin/env node
// cel console - the floor manager's desk.
//
// Celestial's OWN interface, not an agent pane pretending to be one. The three
// panels are deterministic reads (lib/fleet.sh, lib/inbox.sh) and the command
// line runs exactly what the operator typed, after lib/guard.sh has said it
// may. A small model is wired into one job and one only: turning a typed
// sentence into ONE proposed command, which the operator then presses Enter to
// run. It never executes anything itself.
//
// The interactive UI is ink and lives in ui.mjs, imported lazily: --render-once
// and --translate are what the tests drive and what a pipe wants, and neither
// should need node_modules to exist. That is also why a missing install is
// caught here with one line naming the fix rather than as a module-resolution
// stack trace in front of someone who has no reason to know the console is a
// React app.
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { renderOnce, runCommand, fleet, openItems } from './state.mjs';
import { translate, NoTranslator } from './translate.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL_DIR = process.env.CEL_CONSOLE_TOOL_DIR || HERE;
const DEPS_HINT = `cel console needs its UI dependencies: (cd ${TOOL_DIR} && npm ci --ignore-scripts) - or run cel setup`;

const usage = `usage: cel console [--refresh SECS] [--render-once] [--run "<cmd>"] [--ask "<text>"]`;

const argv = process.argv.slice(2);
const opts = { refresh: 10, renderOnce: false, run: '', translate: '' };
for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === '--render-once') opts.renderOnce = true;
  else if (a === '--refresh') { opts.refresh = Number(argv[++i]) || 10; }
  else if (a === '--run') { opts.run = argv[++i] || ''; }
  else if (a === '--ask' || a === '--translate') { opts.translate = argv[++i] || ''; }
  else if (a === '-h' || a === '--help') { process.stdout.write(`${usage}\n`); process.exit(0); }
  else { process.stderr.write(`cel console: unknown argument '${a}'\n${usage}\n`); process.exit(2); }
}

// The state the translator gets as context: the same two reads the panels show.
// A model asked "what is waiting on me in alpha" cannot answer with a workspace
// name unless it has been told which names exist - and a hallucinated
// --workspace is a command that fails in front of the operator.
const translatorState = async () => {
  const doc = await fleet();
  const items = await openItems(doc);
  return `fleet: ${JSON.stringify(doc)}\nopen decisions: ${JSON.stringify(items)}`;
};

const main = async () => {
  if (opts.translate) {
    let cmd, raw;
    try {
      ({ cmd, raw } = await translate({ sentence: opts.translate, state: await translatorState() }));
    } catch (e) {
      if (e instanceof NoTranslator) { process.stderr.write(`${e.message}\n`); process.exit(1); }
      process.stderr.write(`${e.message}\n`);
      process.exit(1);
    }
    if (!cmd) {
      const said = raw && raw !== '?' ? ` (model said: ${raw.replace(/\s+/g, ' ').slice(0, 70)})` : '';
      process.stderr.write(`no command for that - rephrase, or type the command${said}\n`);
      process.exit(1);
    }
    process.stdout.write(`${cmd}\n`);
    return;
  }

  if (opts.run) {
    const r = await runCommand(opts.run);
    if (!r.allow) {
      process.stderr.write(`refused: ${r.reason}\n`);
      if (opts.renderOnce) process.stdout.write(`${await renderOnce()}\n`);
      process.exit(1);
    }
    process.stdout.write(`${r.out}\n`);
    if (!opts.renderOnce) return;
  }

  if (opts.renderOnce) {
    process.stdout.write(`${await renderOnce()}\n`);
    return;
  }

  if (!existsSync(join(TOOL_DIR, 'node_modules', 'ink', 'package.json'))) {
    process.stderr.write(`${DEPS_HINT}\n`);
    process.exit(1);
  }
  const { start } = await import('./ui.mjs');
  await start(opts);
};

main().catch((e) => { process.stderr.write(`cel console: ${e.stack || e.message}\n`); process.exit(1); });
