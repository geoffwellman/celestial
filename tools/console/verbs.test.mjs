#!/usr/bin/env node
// Pure tests for the key map: one key, on one panel, over one selection,
// produces one PROPOSAL.
//
// The verbs are the half of CEL-25 that changes the box, and every one of them
// used to be a command an operator typed from memory. A key that writes the
// wrong `--workspace` is the same accident as a router that guesses one, so
// the map lives in a pure function and is asserted here rather than reached
// only by pressing a key in a terminal nobody is running under test.
import assert from 'node:assert/strict';
import { verbFor, VERBS } from './verbs.mjs';

const t = (name, fn) => { fn(); process.stdout.write(`  ok ${name}\n`); };

const TICKET = {
  ws: 'alpha', product: 'bundle', ticket: 'ABC-49', state: 'In Progress',
  states: ['Todo', 'In Progress', 'In Review', 'Done'],
};
const PR = {
  ws: 'alpha', repo: 'widget', number: 12, branch: 'ABC-49-slug',
  id: 'ABC-49-slug', reviewDecision: 'APPROVED', ci: 'pass',
};
const WORKER = { ws: 'alpha', id: 'ABC-49-slug', alias: 'widget/ABC-49-slug' };
const ITEM = { ws: 'alpha', id: '1789208557174615054', from: 'bundle-orch' };
const ORCH = { ws: 'alpha', product: 'bundle', orch: '-' };

t('every verb the ticket names has a row', () => {
  assert.deepEqual(
    VERBS.map((v) => v.name).sort(),
    ['answer', 'land', 'move', 'nudge', 'restart', 'review', 'start'],
  );
});

t('s on a board ticket asks the orchestrator to pick it up', () => {
  const v = verbFor('board', 's', TICKET);
  assert.deepEqual(v.cmds, [
    "cel inbox send bundle-orch 'pick up ABC-49 next' --workspace alpha",
  ]);
});

t('m on a board ticket offers the team\u2019s states as numbered options', () => {
  const v = verbFor('board', 'm', TICKET);
  assert.deepEqual(v.cmds, ['cel-linear state ABC-49 ""']);
  // the cursor lands INSIDE the quotes: a proposal the operator has to
  // navigate into is a proposal they retype
  assert.equal(v.cmds[0][v.cursor - 1], '"');
  assert.deepEqual(v.options, ['Todo', 'In Progress', 'In Review', 'Done']);
});

t('l on an approved, green PR lands the delegation behind it', () => {
  const v = verbFor('prs', 'l', PR);
  assert.deepEqual(v.cmds, ['cel-fanout land ABC-49-slug --workspace alpha']);
});

t('l on a PR with no delegation says so instead of inventing an id', () => {
  const v = verbFor('prs', 'l', { ...PR, id: '' });
  assert.equal(v.cmds.length, 0);
  assert.match(v.say, /no delegation for that branch/);
});

t('l on a PR that is not approved or not green refuses', () => {
  assert.match(verbFor('prs', 'l', { ...PR, reviewDecision: 'CHANGES_REQUESTED' }).say, /approved/i);
  assert.match(verbFor('prs', 'l', { ...PR, ci: 'fail' }).say, /check/i);
});

t('v on a PR row starts a reviewer for it', () => {
  const v = verbFor('prs', 'v', PR);
  assert.deepEqual(v.cmds, ['cel run reviewer --repo widget --pr 12 --workspace alpha']);
});

t('a on a waiting item answers the sender and then closes the item', () => {
  const v = verbFor('waiting', 'a', ITEM);
  assert.deepEqual(v.cmds, [
    "cel inbox send bundle-orch '' --workspace alpha",
    'cel inbox resolve 1789208557174615054 --workspace alpha',
  ]);
  // the cursor sits between the single quotes, which is where the answer goes
  assert.equal(v.cmds[0][v.cursor - 1], "'");
});

t('n on a worker row prompts that agent', () => {
  const v = verbFor('workers', 'n', WORKER);
  assert.deepEqual(v.cmds, ["herdr agent prompt widget/ABC-49-slug ''"]);
  assert.equal(v.cmds[0][v.cursor - 1], "'");
});

t('R restarts an orchestrator that is not live, and not one that is', () => {
  const v = verbFor('orch', 'R', ORCH);
  assert.deepEqual(v.cmds, ['cel run orchestrator --product bundle --workspace alpha']);
  const live = verbFor('orch', 'R', { ...ORCH, orch: 'LIVE' });
  assert.equal(live.cmds.length, 0);
  assert.match(live.say, /already/);
});

t('a key on a panel that does not own it is nothing at all', () => {
  assert.equal(verbFor('board', 'l', TICKET), null);
  assert.equal(verbFor('prs', 's', PR), null);
  assert.equal(verbFor('board', 's', null), null);
});

process.stdout.write('verbs.test.mjs: all good\n');
