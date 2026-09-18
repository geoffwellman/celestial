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

import { allServices, renderOnce, renderUnit, renderWorker, renderQuota, renderTimeline, renderServices, runCommand, runChain, fleet, openItems, appendHistory, askState } from './state.mjs';
import { translate, NoTranslator } from './translate.mjs';
import { route, NoRouter } from './router.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL_DIR = process.env.CEL_CONSOLE_TOOL_DIR || HERE;
const DEPS_HINT = `cel console needs its UI dependencies: (cd ${TOOL_DIR} && npm ci --ignore-scripts) - or run cel setup`;

const usage = `usage: cel console [--refresh SECS] [--render-once] [--render-quota]
                   [--status TEXT]
                   [--status-secs N] [--run "<cmd>"] [--unit NAME] [--worker ID]
                   [--chain "<cmd>" ...] [--ask "<text>"] [--no-router]
                   [--timeline] [--services]`;

const argv = process.argv.slice(2);
const opts = { refresh: 10, renderOnce: false, renderQuota: false, run: '', translate: '', status: '', statusSecs: 8, chain: [], unit: '', worker: '', services: false, router: true, timeline: false };
for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === '--render-once') opts.renderOnce = true;
  else if (a === '--render-quota') opts.renderQuota = true;
  else if (a === '--timeline') opts.timeline = true;
  else if (a === '--services') opts.services = true;
  else if (a === '--no-router') opts.router = false;
  else if (a === '--refresh') { opts.refresh = Number(argv[++i]) || 10; }
  else if (a === '--run') { opts.run = argv[++i] || ''; }
  else if (a === '--unit') { opts.unit = argv[++i] || ''; }
  else if (a === '--worker') { opts.worker = argv[++i] || ''; }
  else if (a === '--chain') { const c = argv[++i] || ''; if (c) opts.chain.push(c); }
  else if (a === '--status') { opts.status = argv[++i] || ''; }
  else if (a === '--status-secs') { const n = Number(argv[++i]); opts.statusSecs = Number.isFinite(n) ? n : 8; }
  else if (a === '--ask' || a === '--translate') { opts.translate = argv[++i] || ''; }
  else if (a === '-h' || a === '--help') { process.stdout.write(`${usage}\n`); process.exit(0); }
  else { process.stderr.write(`cel console: unknown argument '${a}'\n${usage}\n`); process.exit(2); }
}

// The state the translator gets as context: the same two reads the panels
// show. A model asked "what is waiting on me in alpha" cannot answer with a
// workspace name unless it has been told which names exist - and a
// hallucinated --workspace is a command that fails in front of the operator.
// The router is handed the same two reads, reduced to names.

const main = async () => {
  if (opts.translate) {
    const doc = await fleet();
    const items = await openItems(doc);
    const state = askState(doc, items);

    // THE ROUTER FIRST. It answers in under a second where the chat model
    // took six, and when it cannot - not configured, down, an intent whose
    // slots do not fill - the sentence carries on to the chat model exactly
    // as it did before this existed. An operator should not be able to tell
    // which of the two answered except by the line on stderr.
    if (opts.router) {
      try {
        const r = await route({ sentence: opts.translate, doc, items, services: await allServices(doc) });
        const secs = (r.ms / 1000).toFixed(1);
        process.stderr.write(`router: ${r.intent} ${r.confidence.toFixed(2)} in ${secs}s\n`);
        if (r.cmds) {
          process.stdout.write(`${r.cmds.join('\n')}\n`);
          return;
        }
        // Below the floor the router is guessing; a guess is a menu, not a
        // command line waiting for Enter. `other` on top means it is not a
        // routing question at all, so the chat model gets it.
        if (r.intent !== 'other' && r.options.some((o) => o.cmd)) {
          process.stdout.write('no command for that - did you mean:\n');
          r.options.forEach((o, i) => {
            process.stdout.write(`${i + 1}  ${o.cmd || o.intent}   -- ${o.reason}\n`);
          });
          process.exit(1);
        }
      } catch (e) {
        if (!(e instanceof NoRouter)) process.stderr.write(`${e.message} - asking the chat model\n`);
      }
    }

    let cmds = [], raw = '', answered = '';
    try {
      ({ cmds, raw, answer: answered = '' } = await translate({ sentence: opts.translate, state }));
    } catch (e) {
      process.stderr.write(`${e.message}\n`);
      process.exit(1);
    }
    // THE ANSWER FORM. The state the model was handed already says which
    // workers are idle and what is waiting; proposing three commands to
    // rediscover it is the console making the operator do the reading.
    if (answered) {
      process.stdout.write(`${answered}\n`);
      return;
    }
    if (cmds.length) {
      // A chain prints one command per line: the caller pipes it into a shell
      // or reads it, and either way the order is the whole content.
      process.stdout.write(`${cmds.join('\n')}\n`);
      return;
    }
    // THE SECOND ASK. A miss used to end here with "no command for that",
    // which told the operator nothing; now the model is asked what the
    // sentence might have meant and the answers are offered as a numbered
    // list. Exit 1 either way: nothing was translated, and a caller testing
    // the exit status must not mistake a menu for a command.
    let options = [];
    try {
      ({ options } = await translate({ sentence: opts.translate, state, mode: 'options' }));
    } catch (e) {
      if (!(e instanceof NoTranslator)) process.stderr.write(`${e.message}\n`);
    }
    if (options.length) {
      process.stdout.write('no command for that - did you mean:\n');
      options.forEach((o, i) => {
        process.stdout.write(`${i + 1}  ${o.cmd}${o.reason ? `   -- ${o.reason}` : ''}\n`);
      });
      process.exit(1);
    }
    const said = raw && raw !== '?' ? ` (model said: ${raw.replace(/\s+/g, ' ').slice(0, 70)})` : '';
    process.stderr.write(`no command for that - rephrase, or type the command${said}\n`);
    process.exit(1);
  }

  // The same whole-chain check the TUI does, on the command line: every line is
  // put to the guard before any of them runs.
  if (opts.chain.length) {
    const r = await runChain(opts.chain);
    if (!r.allow) {
      process.stderr.write(`refused: ${r.reason}\n  the chain ran nothing - the refused line was: ${r.denied}\n`);
      process.exit(1);
    }
    for (const step of r.results) {
      process.stdout.write(`${step.out}\n`);
      appendHistory(step.cmd);
    }
    if (r.stoppedAt != null) {
      process.stderr.write(`stopped at ${r.stoppedAt + 1}/${opts.chain.length} - it exited non-zero\n`);
      process.exit(1);
    }
    return;
  }

  if (opts.run) {
    const r = await runCommand(opts.run);
    if (!r.allow) {
      process.stderr.write(`refused: ${r.reason}\n`);
      if (opts.renderOnce) process.stdout.write(`${await renderOnce({ status: `refused: ${r.reason}` })}\n`);
      process.exit(1);
    }
    appendHistory(opts.run);
    process.stdout.write(`${r.out}\n`);
    if (!opts.renderOnce) return;
  }

  if (opts.renderQuota) {
    // THE QUOTA VIEW IS A RENDER TOO, for the same reason the unit view is:
    // the subscription windows are what an operator checks before delegating,
    // and a page only the TUI can draw is a page no test can hold to account.
    process.stdout.write(`${await renderQuota()}\n`);
    return;
  }

  if (opts.renderOnce) {
    // A DRILL-DOWN IS A RENDER TOO. `--unit` and `--worker` print exactly the
    // pages the TUI draws, so the views are testable and an operator with a
    // pipe can have the depth as well.
    if (opts.services) {
      process.stdout.write(`${await renderServices({ status: opts.status })}\n`);
      return;
    }
    if (opts.worker) {
      const text = await renderWorker(opts.worker, { status: opts.status });
      if (!text) { process.stderr.write(`cel console: no worker '${opts.worker}' in the fleet\n`); process.exit(1); }
      process.stdout.write(`${text}\n`);
      return;
    }
    if (opts.timeline) {
      process.stdout.write(`${await renderTimeline({ status: opts.status })}\n`);
      return;
    }
    if (opts.unit) {
      const text = await renderUnit(opts.unit, { status: opts.status });
      if (!text) { process.stderr.write(`cel console: no unit '${opts.unit}' in the fleet\n`); process.exit(1); }
      process.stdout.write(`${text}\n`);
      return;
    }
    process.stdout.write(`${await renderOnce({ status: opts.status })}\n`);
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
