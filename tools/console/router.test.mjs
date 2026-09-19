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
import { facts, plan, options, shellQuote, INTENT_NAMES, addresseeIn, steerFor } from './router.mjs';

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
  assert.deepEqual(F.workers[0], {
    id: 'ABC-49-slug', ticket: 'ABC-49', workspace: 'alpha', product: 'bundle',
    // CEL-25: the pane to prompt, the repo a PR is in, and its number
    alias: 'ABC-49-slug', repo: 'widget', pr: 0,
  });
});

// --- every row of the INTENTS table, two sentences each ---------------------

t('gateway is the account table, box-level and slotless', () => {
  assert.deepEqual(plan('gateway', 'which accounts are usable', F), ['cel gateway status']);
  assert.deepEqual(plan('gateway', 'how much codex quota is left', F), ['cel gateway status']);
});

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
  // bundle-orch's pane is LIVE in this document, so the plan is the mail AND
  // the tap on the shoulder (CEL-36); the send is always the first line.
  assert.deepEqual(plan('message', 'tell bundle-orch to pick up ABC-49 next', F), [
    "cel inbox send bundle-orch 'pick up ABC-49 next' --workspace alpha",
    "herdr agent prompt bundle-orch 'inbox: pick up ABC-49 next - run cel inbox read'",
  ]);
  assert.equal(plan('message', 'tell bundle "stop and push what you have"', F)[0],
    "cel inbox send bundle-orch 'stop and push what you have' --workspace alpha");
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
  assert.equal(inj[0], "cel inbox send bundle-orch 'hi $(rm -rf ~)' --workspace alpha");
  // Single quotes make every one of these inert; a literal single quote in the
  // text closes and reopens rather than escaping, which is the only form bash
  // accepts inside a single-quoted string.
  assert.equal(plan('message', "tell bundle-orch \"don't `whoami`; rm -rf x | tee y\"", F)[0],
    "cel inbox send bundle-orch 'don'\\''t `whoami`; rm -rf x | tee y' --workspace alpha");
  for (const cmd of [...inj, ...plan('message', 'tell bundle-orch "a && b; c"', F)]) {
    // Everything after the closing quote is the console's own text: no
    // operator word may appear outside the quoted argument. The prompt line
    // ENDS on its quote, which is the same rule with nothing after it.
    const after = cmd.slice(cmd.lastIndexOf("'") + 1);
    assert.ok(after === ' --workspace alpha' || after === '', cmd);
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


// --- CEL-25: the verbs as intents ------------------------------------------
//
// Every key on a panel is also a sentence someone will type, and a console
// that can only be steered by keys is a console you have to be looking at.
// Two sentences each, because one is an example and two is a rule.

const VDOC = {
  workspaces: [{
    name: 'alpha',
    root: { unread: 0, open: 1 },
    units: [{
      name: 'bundle',
      orch: '-',
      workers: 2,
      cap: 4,
      repos: ['widget', 'gadget'],
      workers_list: [
        { id: 'ABC-49-slug', ticket: 'ABC-49', repo: 'widget', state: 'finished', alias: 'widget/ABC-49-slug', pr: 'https://example.invalid/acme/widget/pull/12' },
        { id: 'ABC-50-other', ticket: 'ABC-50', repo: 'gadget', state: 'running', alias: 'gadget/ABC-50-other', pr: '' },
      ],
    }],
  }],
};
const VF = facts(VDOC, ITEMS);

t('the seven verbs are intents the router can choose', () => {
  for (const n of ['start_ticket', 'answer', 'land', 'nudge', 'restart_orchestrator', 'move_ticket', 'review']) {
    assert.ok(INTENT_NAMES.includes(n), `${n} is not an intent`);
  }
});

t('start_ticket tells the product\u2019s orchestrator to pick the ticket up', () => {
  assert.deepEqual(plan('start_ticket', 'start ABC-49 next', VF),
    ["cel inbox send bundle-orch 'pick up ABC-49 next' --workspace alpha"]);
  assert.deepEqual(plan('start_ticket', 'get bundle going on ABC-51', VF),
    ["cel inbox send bundle-orch 'pick up ABC-51 next' --workspace alpha"]);
  // no ticket named is a miss, not a guess at whichever one is on top
  assert.equal(plan('start_ticket', 'start something', VF), null);
});

t('answer writes to the sender of an open item and then closes it', () => {
  assert.deepEqual(plan('answer', 'answer 1789208557174615054 "hold the gadget"', VF),
    ["cel inbox send bundle-orch 'hold the gadget' --workspace alpha",
      'cel inbox resolve 1789208557174615054 --workspace alpha']);
  assert.deepEqual(plan('answer', 'tell bundle-orch "hold the gadget" and close it', VF),
    ["cel inbox send bundle-orch 'hold the gadget' --workspace alpha",
      'cel inbox resolve 1789208557174615054 --workspace alpha']);
  // NO MATCHING OPEN ITEM IS A FALL-THROUGH. Answering a decision nobody
  // asked is a message into a mailbox with no question in it.
  assert.equal(plan('answer', 'answer widget-orch "go ahead"', VF), null);
});

t('land finds the delegation behind a PR number or a ticket', () => {
  assert.deepEqual(plan('land', 'land #12', VF), ['cel-fanout land ABC-49-slug --workspace alpha']);
  assert.deepEqual(plan('land', 'merge ABC-49 please', VF), ['cel-fanout land ABC-49-slug --workspace alpha']);
  assert.equal(plan('land', 'land the other one', VF), null);
});

t('nudge prompts the worker by its herdr alias', () => {
  assert.deepEqual(plan('nudge', 'nudge ABC-49 "push what you have"', VF),
    ["herdr agent prompt widget/ABC-49-slug 'push what you have'"]);
  assert.deepEqual(plan('nudge', 'remind ABC-50-other "commit before you stop"', VF),
    ["herdr agent prompt gadget/ABC-50-other 'commit before you stop'"]);
  assert.equal(plan('nudge', 'nudge ABC-49', VF), null);
});

t('restart_orchestrator names the product and its workspace', () => {
  assert.deepEqual(plan('restart_orchestrator', 'restart the bundle orchestrator', VF),
    ['cel run orchestrator --product bundle --workspace alpha']);
  assert.deepEqual(plan('restart_orchestrator', 'bring bundle back up', VF),
    ['cel run orchestrator --product bundle --workspace alpha']);
  assert.equal(plan('restart_orchestrator', 'restart it', VF), null);
});

t('move_ticket carries the ticket and the state name', () => {
  assert.deepEqual(plan('move_ticket', 'move ABC-49 to "In Review"', VF),
    ['cel-linear state ABC-49 "In Review"']);
  assert.deepEqual(plan('move_ticket', 'put ABC-50 in "Done"', VF),
    ['cel-linear state ABC-50 "Done"']);
  assert.equal(plan('move_ticket', 'move ABC-49', VF), null);
});

t('review starts a reviewer on the repo the PR is in', () => {
  assert.deepEqual(plan('review', 'review #12', VF),
    ['cel run reviewer --repo widget --pr 12 --workspace alpha']);
  assert.deepEqual(plan('review', 'get a reviewer on ABC-49', VF),
    ['cel run reviewer --repo widget --pr 12 --workspace alpha']);
  assert.equal(plan('review', 'review the gadget work', VF), null);
});

// --- services (CEL-26) -----------------------------------------------------
//
// A service resolves by its own name, and a preview by the ticket it runs,
// because "open the preview of ABC-49" is how anyone actually says it. The
// control verb is READ, never defaulted: naming a service is not an
// instruction to stop it.
const FS = facts(DOC, [], [
  { name: 'builder', ws: 'alpha' },
  { name: 'try ABC-49', ws: 'alpha', ticket: 'ABC-49' },
]);

t('open_service resolves a service by name and a preview by its ticket', () => {
  assert.deepEqual(plan('open_service', 'open the builder', FS),
    ["cel services open 'builder' --workspace alpha"]);
  assert.deepEqual(plan('open_service', 'open the preview of ABC-49', FS),
    ["cel services open 'try ABC-49' --workspace alpha"]);
  assert.equal(plan('open_service', 'open the thing', FS), null);
});

t('service_ctl reads the verb from the sentence and never invents one', () => {
  assert.deepEqual(plan('service_ctl', 'restart the builder', FS),
    ["cel services restart 'builder' --workspace alpha"]);
  assert.deepEqual(plan('service_ctl', 'stop the builder please', FS),
    ["cel services stop 'builder' --workspace alpha"]);
  assert.equal(plan('service_ctl', 'the builder', FS), null);
});

t('service_logs asks the service what it is printing', () => {
  assert.deepEqual(plan('service_logs', 'what is the builder printing', FS),
    ["cel services logs 'builder' --workspace alpha"]);
});

// A box with no services declared can never route to one: a sentence that
// names nothing is a miss, and a miss falls through to the chat model.
t('no services means every service intent misses', () => {
  assert.equal(plan('open_service', 'open the builder', F), null);
  assert.equal(plan('service_ctl', 'restart the builder', F), null);
});


// --- CEL-27: "how much Claude do I have left" ------------------------------
// The subscription windows are the one fact the fleet document cannot answer
// from a workspace name, so the intent takes no slots at all.
t('the quota intent is the whole subscription read', () => {
  assert.deepEqual(plan('quota', 'how much claude do i have left', facts(DOC, [])), ['cel quota']);
  assert.deepEqual(plan('quota', 'when does codex reset', facts(DOC, [])), ['cel quota']);
});


// --- CEL-36: reaching an orchestrator, and seeing it answer ----------------
//
// "so we can't actually steer the orchestrators from the TUI?" (owner,
// 2026-09-19). Everything below is the resolution half of the answer: who a
// sentence is addressed to, and what reaching them costs. A wrong addressee
// is mail - or worse, a pane prompt - in a stranger's session, so every rung
// of the ladder is asserted rather than assumed.

const SDOC = {
  workspaces: [
    {
      name: 'alpha',
      root: { unread: 0, open: 0 },
      units: [{
        name: 'bundle',
        orch: 'working',
        workers: 1,
        cap: 4,
        repos: ['platform', 'widget'],
        workers_list: [{ id: 'ABC-49-slug', ticket: 'ABC-49', repo: 'platform', state: 'running', alias: 'platform/ABC-49-slug' }],
      }],
    },
    {
      name: 'beta',
      root: { unread: 0, open: 0 },
      units: [
        { name: 'gadget', orch: '-', workers: 0, cap: 4, workers_list: [] },
        { name: 'trinket', orch: '-', workers: 0, cap: 4, workers_list: [] },
      ],
    },
  ],
};
const SF = facts(SDOC, [], [], ['bundle-orch', 'alpha/root', 'oldname-orch']);

t('the addressee ladder: worker, <p>-orch, product, workspace, repo, alias', () => {
  assert.equal(addresseeIn('nudge ABC-49-slug "push"', SF).who, 'ABC-49-slug');
  assert.equal(addresseeIn('tell bundle-orch "hi"', SF).who, 'bundle-orch');
  assert.equal(addresseeIn('tell bundle "hi"', SF).who, 'bundle-orch');
  // A workspace with exactly one product IS that product's orchestrator.
  assert.equal(addresseeIn('tell alpha "hi"', SF).who, 'bundle-orch');
  // A repo inside a product reaches the product that owns it: "tell the
  // platform to ..." is how anyone actually says it.
  assert.equal(addresseeIn('tell platform "hi"', SF).who, 'bundle-orch');
  assert.equal(addresseeIn('tell platform "hi"', SF).workspace, 'alpha');
  // And a name only the roster knows - a pane whose product was renamed.
  assert.equal(addresseeIn('tell oldname-orch "hi"', SF).who, 'oldname-orch');
});

t('a workspace with two products asks which one instead of guessing', () => {
  const hit = addresseeIn('tell beta "hi"', SF);
  assert.ok(hit && hit.ask, 'beta has two products and must not resolve');
  assert.match(hit.ask, /gadget/);
  assert.match(hit.ask, /trinket/);
  assert.equal(plan('message', 'tell beta "hi"', SF), null);
});

t('message to a LIVE orchestrator is the mail AND the tap on the shoulder', () => {
  assert.deepEqual(plan('message', 'tell bundle-orch to pick up ABC-49 next', SF), [
    "cel inbox send bundle-orch 'pick up ABC-49 next' --workspace alpha",
    "herdr agent prompt bundle-orch 'inbox: pick up ABC-49 next - run cel inbox read'",
  ]);
  assert.equal(steerFor('message', 'tell bundle-orch to pick up ABC-49 next', SF).say,
    'sent to bundle-orch (pane live, prompted)');
});

t('message to an orchestrator with no live pane is mail alone, and says so', () => {
  assert.deepEqual(plan('message', 'tell gadget-orch "hold the release"', SF),
    ["cel inbox send gadget-orch 'hold the release' --workspace beta"]);
  assert.equal(steerFor('message', 'tell gadget-orch "hold the release"', SF).say,
    'sent to gadget-orch (no live pane - it reads this when it next starts; run "start gadget-orch" to wake it)');
});

// A worker is mail as it always was: the two-step is for orchestrators, whose
// panes are the thing the operator could not reach at all.
t('message to a worker is unchanged', () => {
  assert.deepEqual(plan('message', 'tell ABC-49-slug "push what you have"', SF),
    ["cel inbox send ABC-49-slug 'push what you have' --workspace alpha"]);
});

t('the prompt carries the first 80 characters of the message and no more', () => {
  const long = 'x'.repeat(200);
  const cmds = plan('message', `tell bundle-orch "${long}"`, SF);
  const head = /'inbox: (x+) - run cel inbox read'/.exec(cmds[1]);
  assert.ok(head, cmds[1]);
  assert.equal(head[1].length, 80);
});

t('nudge reaches an orchestrator as well as a worker', () => {
  assert.deepEqual(plan('nudge', 'nudge bundle-orch "push what you have"', SF),
    ["herdr agent prompt bundle-orch 'push what you have'"]);
  assert.deepEqual(plan('nudge', 'poke ABC-49 "status please"', SF),
    ["herdr agent prompt platform/ABC-49-slug 'status please'"]);
});

t('talk is an intent, and it resolves to the console\u2019s relay mode', () => {
  assert.ok(INTENT_NAMES.includes('talk'), 'talk is not an intent');
  assert.deepEqual(plan('talk', 'talk to bundle-orch', SF), ['talk bundle-orch']);
  assert.deepEqual(plan('talk', 'let me speak to platform', SF), ['talk bundle-orch']);
  assert.equal(plan('talk', 'let me speak to somebody', SF), null);
});

process.stdout.write('router: all tests passed\n');
