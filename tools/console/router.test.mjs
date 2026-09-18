#!/usr/bin/env node
// Pure tests for the decision router: intent -> command(s), and the slot
// filling that turns one of ten intents into a line an operator can press
// Enter on.
//
// Pure on purpose, and for a sharper reason than the other console tests. The
// router's model does NOT write the command - it picks a label - so every
// character of what lands on the command line is produced here, from the
// sentence and the fleet state. A slot filler nobody can assert is a slot
// filler that will one day put someone else's workspace in a `--workspace`.
import assert from 'node:assert/strict';
import { facts, plan, options, shellQuote } from './router.mjs';

const t = (name, fn) => { fn(); process.stdout.write(`  ok ${name}\n`); };

const DOC = {
  workspaces: [
    {
      name: 'alpha',
      root: { unread: 1, open: 1 },
      units: [
        {
          name: 'bundle',
          orch: 'LIVE',
          workers: 2,
          cap: 4,
          workers_list: [
            { id: 'ABC-49-slug', ticket: 'ABC-49', repo: 'widget', state: 'running' },
            { id: 'ABC-50-other', ticket: 'ABC-50', repo: 'gadget', state: 'running' },
          ],
        },
        { name: 'widget', orch: '-', workers: 0, cap: 4, workers_list: [] },
      ],
    },
    {
      name: 'beta',
      root: { unread: 0, open: 0 },
      units: [{ name: 'gadget', orch: '-', workers: 0, cap: 4, workers_list: [] }],
    },
  ],
};

const ITEMS = [
  { ws: 'alpha', id: '1789208557174615054', from: 'bundle-orch', kind: 'decision', message: 'ship gadget or hold?' },
];

const F = facts(DOC, ITEMS);

// --- what the model is told ------------------------------------------------

t('facts carry the workspaces, the products and their workspace, and a count', () => {
  assert.deepEqual(F.workspaces, ['alpha', 'beta']);
  assert.deepEqual(F.products, [
    { name: 'bundle', workspace: 'alpha' },
    { name: 'widget', workspace: 'alpha' },
    { name: 'gadget', workspace: 'beta' },
  ]);
  assert.deepEqual(F.tickets_seen, ['ABC-49', 'ABC-50']);
  assert.equal(F.open_items, 1);
  // The worker list is how `why` finds an id from a ticket; it never leaves
  // the box in the state, but the planner needs it.
  assert.equal(F.workers.length, 2);
  assert.deepEqual(F.workers[0], { id: 'ABC-49-slug', ticket: 'ABC-49', workspace: 'alpha', product: 'bundle' });
});

// --- every row of the INTENTS table, two sentences each ---------------------

t('fleet is the whole box, plain', () => {
  assert.deepEqual(plan('fleet', "what's blocked", F), ['cel fleet']);
  assert.deepEqual(plan('fleet', 'what is running on the box', F), ['cel fleet']);
});

t('product_status is a chain of three on the owning workspace', () => {
  const want = ['cel fleet', 'cel-fanout status --workspace alpha', 'cel inbox open --for root --workspace alpha'];
  assert.deepEqual(plan('product_status', 'what is happening with bundle', F), want);
  assert.deepEqual(plan('product_status', 'how is Gadget going', F), [
    'cel fleet', 'cel-fanout status --workspace beta', 'cel inbox open --for root --workspace beta',
  ]);
});

t('product_status with nothing named is a miss, not a guess', () => {
  assert.equal(plan('product_status', 'how is it going', F), null);
});

t('waiting is every mailbox unless one is named', () => {
  assert.deepEqual(plan('waiting', 'what is waiting on me', F), ['cel inbox open --for root --all-workspaces']);
  assert.deepEqual(plan('waiting', 'anything for me on alpha', F), ['cel inbox open --for root --workspace alpha']);
});

t('why_worker takes the worker id, from a ticket or from the id itself', () => {
  assert.deepEqual(plan('why_worker', 'why is ABC-49 stuck', F), ['cel-fanout why ABC-49-slug --workspace alpha']);
  assert.deepEqual(plan('why_worker', 'why has ABC-50-other gone quiet', F), ['cel-fanout why ABC-50-other --workspace alpha']);
});

t('why_worker about a ticket nobody is working is a miss', () => {
  assert.equal(plan('why_worker', 'why is ABC-999 stuck', F), null);
  assert.equal(plan('why_worker', 'why did the last build fail', F), null);
});

t('focus takes a product to its orchestrator and a worker to itself', () => {
  assert.deepEqual(plan('focus', 'take me to bundle', F), ['herdr agent focus bundle-orch']);
  assert.deepEqual(plan('focus', 'focus ABC-49-slug', F), ['herdr agent focus ABC-49-slug']);
  assert.equal(plan('focus', 'take me there', F), null);
});

t('message splits the addressee from the text, quoted or not', () => {
  assert.deepEqual(plan('message', 'tell bundle-orch to pick up ABC-49 next', F),
    ["cel inbox send bundle-orch 'pick up ABC-49 next' --workspace alpha"]);
  assert.deepEqual(plan('message', 'tell bundle "stop and push what you have"', F),
    ["cel inbox send bundle-orch 'stop and push what you have' --workspace alpha"]);
  // An addressee and nothing to say is a miss: an empty message is noise in
  // someone's mailbox.
  assert.equal(plan('message', 'tell bundle-orch', F), null);
  assert.equal(plan('message', 'tell them to hurry up', F), null);
});

// THE MESSAGE TEXT IS THE ONE PLACE A PERSON'S OWN WORDS REACH THE COMMAND
// LINE, and that command line is run by `bash -c`. Inside DOUBLE quotes bash
// still expands `$(...)`, `` `...` `` and `$VAR`, so the first version of this
// - which escaped only the double quote - turned `tell bundle-orch "hi $(rm
// -rf ~)"` into a proposal that deleted a home directory when the operator
// pressed Enter. The guard's console branch allows every `cel *` line without
// looking at metacharacters, so nothing downstream catches it either.
t('message text cannot break out of its argument', () => {
  const inj = plan('message', 'tell bundle-orch "hi $(rm -rf ~)"', F);
  assert.deepEqual(inj, ["cel inbox send bundle-orch 'hi $(rm -rf ~)' --workspace alpha"]);
  // Single quotes make every one of these inert; a literal single quote in the
  // text closes and reopens rather than escaping, which is the only form bash
  // accepts inside a single-quoted string.
  assert.deepEqual(plan('message', "tell bundle-orch \"don't `whoami`; rm -rf x | tee y\"", F),
    ["cel inbox send bundle-orch 'don'\\''t `whoami`; rm -rf x | tee y' --workspace alpha"]);
  for (const cmd of [...inj, ...plan('message', 'tell bundle-orch "a && b; c"', F)]) {
    // Everything after the closing quote is the console's own text: no
    // operator word may appear outside the quoted argument.
    const after = cmd.slice(cmd.lastIndexOf("'") + 1);
    assert.equal(after, ' --workspace alpha');
  }
});

t('shellQuote is single-quoting, and a quote in the text does not end it', () => {
  assert.equal(shellQuote('plain'), "'plain'");
  assert.equal(shellQuote("it's"), "'it'\\''s'");
  assert.equal(shellQuote('$(id) `id` ${x} \\'), "'$(id) `id` ${x} \\'");
  // A newline would split one proposal into two command lines, and the second
  // is a line the operator never read.
  assert.equal(shellQuote('one\ntwo\rthree'), "'one two three'");
});

t('resolve takes an id from the sentence, else the selected item', () => {
  assert.deepEqual(plan('resolve', 'resolve 1789208557174615054', F),
    ['cel inbox resolve 1789208557174615054 --workspace alpha']);
  assert.deepEqual(plan('resolve', 'resolve that one', F, { selected: ITEMS[0] }),
    ['cel inbox resolve 1789208557174615054 --workspace alpha']);
  assert.equal(plan('resolve', 'resolve that one', F), null);
});

t('clean_inbox is the read and then the sweep, on a named workspace', () => {
  assert.deepEqual(plan('clean_inbox', 'help me clean the inbox on alpha', F), [
    'cel inbox open --for root --workspace alpha',
    'cel inbox resolve --all --from steward --workspace alpha',
  ]);
  // Two workspaces on the box and none named: sweeping the wrong mailbox is
  // not recoverable, so it falls through to the chat model.
  assert.equal(plan('clean_inbox', 'clean the inbox', F), null);
});

t('try is the same id lookup as why', () => {
  assert.deepEqual(plan('try', 'try ABC-49', F), ['cel-fanout try ABC-49-slug --workspace alpha']);
  assert.deepEqual(plan('try', 'can I see ABC-50-other running', F), ['cel-fanout try ABC-50-other --workspace alpha']);
});

t('other is always a fall-through', () => {
  assert.equal(plan('other', 'anything at all', F), null);
  assert.equal(plan('not_an_intent', 'anything at all', F), null);
});

// --- below the confidence floor -------------------------------------------

t('the top three become options, each expanded where the slots allow', () => {
  const opts = options(
    { fleet: 0.42, product_status: 0.31, why_worker: 0.2, waiting: 0.07 },
    'what is happening with bundle', F,
  );
  assert.equal(opts.length, 3);
  assert.equal(opts[0].cmd, 'cel fleet');
  assert.equal(opts[0].reason, '0.42');
  // A chain is offered as one option, in the order it would run - the same
  // shape the TUI puts on the command line for a proposed chain.
  assert.equal(opts[1].cmd,
    'cel fleet ; cel-fanout status --workspace alpha ; cel inbox open --for root --workspace alpha');
  // An intent whose slots cannot be filled is still offered, as its intent
  // name: the operator learns what the router thought, which is the whole
  // point of showing three.
  assert.equal(opts[2].cmd, '');
  assert.equal(opts[2].intent, 'why_worker');
});

process.stdout.write('router: all tests passed\n');

// --- CEL-27: "how much Claude do I have left" ------------------------------
// The subscription windows are the one fact the fleet document cannot answer
// from a workspace name, so the intent takes no slots at all.
t('the quota intent is the whole subscription read', () => {
  assert.deepEqual(plan('quota', 'how much claude do i have left', facts(DOC, [])), ['cel quota']);
  assert.deepEqual(plan('quota', 'when does codex reset', facts(DOC, [])), ['cel quota']);
});
