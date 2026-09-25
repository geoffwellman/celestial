#!/usr/bin/env node
// CEL-75: the FLEET panel under load. At a load average of 32 on a 16-thread
// box `cel fleet --json` took 67-116 s against the console's 20 s timeout, and
// the panel showed nothing but `! Command failed` on every refresh - the board
// was lost exactly when the box was busiest. A console that has read the fleet
// once keeps drawing that read, and says how old it is.
import assert from 'node:assert/strict';
import { fleet, fleetSession } from './state.mjs';
import { fleetTable } from './views.mjs';

const t = async (name, fn) => { await fn(); process.stdout.write(`  ok ${name}\n`); };

const GOOD = JSON.stringify({ workspaces: [{ name: 'alpha', root: { unread: 0, open: 0 }, units: [] }] });
const runner = (answers) => async (cmd, args) => {
  if (args[0] === 'afk') return { ok: false, out: '', err: '' };
  return answers.shift();
};
const TIMEOUT = { ok: false, out: '', err: 'Command failed: cel fleet --json', timedOut: true };

await t('with no good read the error is shown', async () => {
  const doc = await fleet(runner([TIMEOUT]));
  assert.match(fleetTable(doc).join('\n'), /! Command failed/);
});

await t('after one good read a failure still draws the good document, marked stale', async () => {
  const run = runner([{ ok: true, out: GOOD, err: '' }, TIMEOUT]);
  await fleet(run);
  const doc = await fleet(run);
  const out = fleetTable(doc).join('\n');
  assert.match(out, /alpha/);
  assert.doesNotMatch(out, /! Command failed/);
  assert.match(out, /stale, as of \d\d:\d\d \(fleet refresh timed out after 20s\)/);
});

// CEL-79: the last good read belongs to ONE console session. It was module
// global, so a second session in the same process drew the first one's board
// as its own "stale" read - a board it had never seen.
await t('a second session does not inherit another session\'s last good read', async () => {
  const a = fleetSession();
  const b = fleetSession();
  await fleet(runner([{ ok: true, out: GOOD, err: '' }]), a);
  const doc = await fleet(runner([TIMEOUT]), b);
  assert.match(fleetTable(doc).join('\n'), /! Command failed/);
  assert.equal(doc.stale, undefined);
});
