#!/usr/bin/env node
// Pure tests for the depth views and for the rule that the console never puts
// raw JSON in front of an operator.
//
// The renderers are pure functions over data the console already has, for the
// same reason the mouse parser is: "the unit view lost the PR column" is not
// something anyone will notice by looking at a terminal, and a view nobody can
// assert is a view that rots.
import assert from 'node:assert/strict';
import {
  renderOutput, unitView, workerView, memHuman, sortWorkers,
  subsEdge, subsLevel, quotaView,
  ago, boardGroups, boardLine, prLine, ticketView, prView,
  timelineLine, timelineView, digestLine,
} from './views.mjs';

const t = (name, fn) => { fn(); process.stdout.write(`  ok ${name}\n`); };

const WORKERS = [
  {
    id: 'ABC-49-slug', ticket: 'ABC-49', repo: 'widget', branch: 'ABC-49-slug',
    shape: 'ship', state: 'running', live: 'idle', quiet_secs: 812,
    verdict: 'stalled', severity: 'warn', ahead: '3', rss_mb: 370,
    pr: 'https://example.invalid/widget/pull/12', alias: 'widget/ABC-49-slug', pane: 'w3:p1',
  },
  {
    id: 'ABC-50-other', ticket: 'ABC-50', repo: 'gadget', branch: 'ABC-50-other',
    shape: 'ship', state: 'running', live: 'working', quiet_secs: 10,
    verdict: '', severity: '', ahead: '0', pr: '', rss_mb: 1536,
    alias: 'gadget/ABC-50-other', pane: 'w3:p2',
  },
];

const UNIT = {
  ws: 'alpha',
  name: 'bundle',
  orch: 'LIVE',
  pane: 'w1:p0',
  workers: 2,
  cap: 4,
  stalled: 1,
  unlanded: 0,
  rss_mb: 1906,
  orch_rss_mb: 430,
  declared: true,
  repos: ['widget', 'gadget'],
  workers_list: WORKERS,
};

t('the unit view carries the orchestrator, every worker and the mail', () => {
  const text = unitView({
    unit: UNIT,
    items: [{ id: 'd1', ws: 'alpha', ts: '2026-09-20T10:11:12+00:00', kind: 'decision', from: 'bundle-orch', message: 'ship gadget or hold?' }],
    tail: [{ ws: 'alpha', ts: '2026-09-20T09:00:00+00:00', kind: 'status', from: 'bundle-orch', message: 'first line' }],
  });
  assert.match(text, /UNIT bundle/);
  assert.match(text, /widget, gadget/);
  assert.match(text, /ORCHESTRATOR/);
  assert.match(text, /bundle-orch/);
  assert.match(text, /w1:p0/);
  assert.match(text, /2\/4/);                       // used slots of the cap
  assert.match(text, /\[focus\]/);
  assert.match(text, /\[message\]/);
  assert.match(text, /WORKERS/);
  assert.match(text, /ABC-49\b/);
  assert.match(text, /ABC-49 +slug/);
  assert.match(text, /13m/);                        // 812s quiet, in minutes
  assert.match(text, /stalled/);
  assert.match(text, /#12/);                        // the PR number, not the URL
  assert.match(text, /ABC-50 +other/);
  assert.match(text, /WAITING/);
  assert.match(text, /ship gadget or hold\?/);
  assert.match(text, /RECENT MAIL/);
  assert.match(text, /first line/);
});

t('a unit with no workers says so rather than printing a blank block', () => {
  const text = unitView({ unit: { ...UNIT, workers: 0, workers_list: [] }, items: [], tail: [] });
  assert.match(text, /no workers/);
  assert.match(text, /nothing open/);
});

t('the worker view is the facts line and the diagnosis under it', () => {
  const text = workerView({
    worker: WORKERS[0],
    ws: 'alpha',
    why: 'ABC-49-slug (ABC-49, widget) - running, agent idle, stalled (warn)\nquiet for 13m\nnext: prompt it to commit and push, or collect',
  });
  assert.match(text, /WORKER ABC-49-slug/);
  assert.match(text, /ABC-49/);
  assert.match(text, /widget/);
  assert.match(text, /idle/);
  assert.match(text, /13m/);
  assert.match(text, /next: prompt it to commit and push/);
  for (const b of ['[prompt]', '[focus]', '[collect]', '[release]', '[why again]']) {
    assert.ok(text.includes(b), `missing button ${b}`);
  }
});

// --- section 4: no raw JSON, ever ------------------------------------------

t('herdr agent focus becomes one line', () => {
  const out = renderOutput('herdr agent focus bundle-orch', 'focused session=cel window w1:p0\n');
  assert.equal(out.trim(), 'focused bundle-orch (w1:p0)');
});

t('herdr agent get becomes key: value lines', () => {
  const out = renderOutput('herdr agent get bundle-orch --json',
    '{"name":"bundle-orch","state":"running","pane":"w1:p0","cwd":"/home/op/ws/alpha"}');
  assert.match(out, /^name: bundle-orch$/m);
  assert.match(out, /^state: running$/m);
  assert.match(out, /^pane: w1:p0$/m);
  assert.match(out, /^cwd: \/home\/op\/ws\/alpha$/m);
  assert.ok(!out.includes('{'), 'braces survived into the rendering');
});

t('cel fleet --json becomes the fleet table', () => {
  const doc = { workspaces: [{ name: 'alpha', root: { unread: 1, open: 1 }, units: [{ ...UNIT }] }] };
  const out = renderOutput('cel fleet --json', JSON.stringify(doc));
  assert.match(out, /alpha/);
  assert.match(out, /bundle/);
  assert.match(out, /orch LIVE/);
  assert.ok(!out.includes('"workspaces"'), 'the raw document survived');
});

t('cel-fanout status --json becomes the worker table', () => {
  const out = renderOutput('cel-fanout status --json --workspace alpha',
    WORKERS.map((w) => JSON.stringify(w)).join('\n'));
  assert.match(out, /ABC-49 +slug/);
  assert.match(out, /ABC-50 +other/);
  assert.match(out, /stalled/);
  assert.ok(!out.includes('"ticket"'), 'the raw rows survived');
});

t('cel inbox open --json becomes the waiting table', () => {
  const out = renderOutput('cel inbox open --for root --workspace alpha --json',
    '{"id":"d1","ts":"2026-09-20T10:11:12+00:00","kind":"decision","from":"bundle-orch","message":"ship gadget or hold?"}');
  assert.match(out, /d1/);
  assert.match(out, /decision/);
  assert.match(out, /ship gadget or hold\?/);
  assert.ok(!out.includes('"kind"'), 'the raw row survived');
});

t('any other JSON becomes key: value lines, nested indented, arrays numbered', () => {
  const out = renderOutput('cel quota --json',
    '{"provider":"alpha","limits":{"daily":100,"used":7},"agents":["one","two"]}');
  assert.match(out, /^provider: alpha$/m);
  assert.match(out, /^limits:$/m);
  assert.match(out, /^ {2}daily: 100$/m);
  assert.match(out, /^ {2}used: 7$/m);
  assert.match(out, /^agents:$/m);
  assert.match(out, /^ {2}1\. one$/m);
  assert.match(out, /^ {2}2\. two$/m);
});

t('text that is not JSON is left exactly as it came', () => {
  const raw = 'alpha   bundle   orch LIVE   workers 1/4\n';
  assert.equal(renderOutput('cel fleet', raw), raw);
});

// --- CEL-22: memory --------------------------------------------------------

t('megabytes read the way an operator says them', () => {
  assert.equal(memHuman(370), '370M');
  assert.equal(memHuman(7065), '6.9G');
  assert.equal(memHuman(24576), '24G');
  // absent is not zero: an older cel on PATH carries no box block, and
  // "mem NaN" on the status edge is worse than no number at all
  assert.equal(memHuman(undefined), '');
  assert.equal(memHuman(null), '');
});

t('the unit view carries a footprint per worker', () => {
  const text = unitView({ unit: UNIT, items: [], tail: [] });
  assert.match(text, /370M/);
  assert.match(text, /1\.5G/);
});

t('the worker view names what it is holding', () => {
  const text = workerView({ worker: WORKERS[0], ws: 'alpha', why: 'quiet for 13m' });
  assert.match(text, /370M/);
});

t('the fleet table carries a unit\u2019s memory beside its counts', () => {
  const doc = { workspaces: [{ name: 'alpha', root: { unread: 1, open: 1 }, units: [{ ...UNIT }] }] };
  const out = renderOutput('cel fleet --json', JSON.stringify(doc));
  assert.match(out, /unlanded 0 {3}mem 1\.9G/);
});

// `s` IS A TOGGLE, so both orders have to be an order someone asked for.
// Biggest first: the question the sort answers is "which one do I collect".
t('the memory sort puts the biggest tree first and leaves the default order alone', () => {
  assert.deepEqual(sortWorkers(WORKERS, false).map((w) => w.id), ['ABC-49-slug', 'ABC-50-other']);
  assert.deepEqual(sortWorkers(WORKERS, true).map((w) => w.id), ['ABC-50-other', 'ABC-49-slug']);
  // and it does not reorder the caller's array under it
  assert.equal(WORKERS[0].id, 'ABC-49-slug');
  // a worker with no number sorts last rather than above a measured one
  const mixed = [{ id: 'a' }, { id: 'b', rss_mb: 10 }];
  assert.deepEqual(sortWorkers(mixed, true).map((w) => w.id), ['b', 'a']);
});


// --- CEL-25: the board, the PRs, the digest and the timeline ---------------
//
// An operator steers by the ticket board and the pull requests, and neither
// was on screen: the console showed the fleet's own state and nothing about
// the work it exists to move. These are the rows, and they are pure so a
// column that goes missing goes missing in a test.

const NOW = Date.parse('2026-09-20T12:00:00Z');

const TICKETS = [
  { identifier: 'ABC-48', title: 'the kerning is wrong on the header', state: 'Todo', assignee: '', updatedAt: '2026-09-20T09:00:00Z', url: 'https://linear.invalid/ABC-48' },
  { identifier: 'ABC-49', title: 'ship the gadget bundle', state: 'In Progress', assignee: 'Sam', updatedAt: '2026-09-20T10:00:00Z', url: 'https://linear.invalid/ABC-49' },
  { identifier: 'ABC-50', title: 'retire the old widget', state: 'In Progress', assignee: '', updatedAt: '2026-09-20T11:55:00Z', url: 'https://linear.invalid/ABC-50' },
  { identifier: 'ABC-47', title: 'done this morning', state: 'Done', assignee: 'Sam', updatedAt: '2026-09-20T08:00:00Z', url: 'https://linear.invalid/ABC-47' },
];

const PRS = [
  { repo: 'widget', number: 12, title: 'ship the gadget bundle', headRefName: 'ABC-49-slug', isDraft: false, reviewDecision: 'APPROVED', statusCheckRollup: [{ conclusion: 'SUCCESS' }, { conclusion: 'SUCCESS' }], updatedAt: '2026-09-20T10:00:00Z' },
  { repo: 'gadget', number: 13, title: 'retire the old widget', headRefName: 'ABC-50-other', isDraft: true, reviewDecision: '', statusCheckRollup: [{ conclusion: 'FAILURE' }], updatedAt: '2026-09-20T11:00:00Z' },
];

t('an age reads the way an operator says it', () => {
  assert.equal(ago('2026-09-20T11:58:00Z', NOW), '2m');
  assert.equal(ago('2026-09-20T10:00:00Z', NOW), '2h');
  assert.equal(ago('2026-09-17T10:00:00Z', NOW), '3d');
  assert.equal(ago('', NOW), '-');
});

t('the board groups by state in the order the board gave them', () => {
  const groups = boardGroups(TICKETS);
  assert.deepEqual(groups.map((g) => g.state), ['Todo', 'In Progress', 'Done']);
  assert.deepEqual(groups[1].rows.map((r) => r.identifier), ['ABC-49', 'ABC-50']);
});

t('a board row names the ticket, its state, who is on it and how old it is', () => {
  const line = boardLine(TICKETS[1], { id: 'ABC-49-slug', alias: 'widget/ABC-49-slug' }, NOW);
  assert.match(line, /ABC-49/);
  assert.match(line, /In Progress/);
  assert.match(line, /@widget\/ABC-49-slug/);
  assert.match(line, /\b2h\b/);
  assert.match(line, /ship the gadget bundle/);
  // no worker on it yet: the column says so rather than claiming an alias
  assert.match(boardLine(TICKETS[0], null, NOW), /ABC-48/);
});

t('a PR row carries the review decision, the checks and the branch', () => {
  const line = prLine(PRS[0], NOW);
  assert.match(line, /#12/);
  assert.match(line, /ABC-49-slug/);
  assert.match(line, /review APPROVED/);
  assert.match(line, /ci \u2713/);
  assert.match(line, /\b2h\b/);
  assert.match(line, /ship the gadget bundle/);
  const red = prLine(PRS[1], NOW);
  assert.match(red, /ci \u2717/);
  assert.match(red, /draft/);
});

t('the ticket detail shows the description head, the last comments and the worker', () => {
  const text = ticketView({
    ticket: { ...TICKETS[1], description: 'first paragraph of the description\nand more', comments: [
      { user: 'Sam', body: 'older note', createdAt: '2026-09-19T10:00:00Z' },
      { user: 'Pat', body: 'newer note', createdAt: '2026-09-20T09:00:00Z' },
    ] },
    worker: { id: 'ABC-49-slug', ticket: 'ABC-49', state: 'running', live: 'idle', quiet_secs: 812 },
    ws: 'alpha',
  });
  assert.match(text, /TICKET ABC-49/);
  assert.match(text, /In Progress/);
  assert.match(text, /first paragraph of the description/);
  assert.match(text, /older note/);
  assert.match(text, /newer note/);
  assert.match(text, /ABC-49-slug/);
  for (const b of ['[start]', '[move]', '[open]']) assert.ok(text.includes(b), `missing ${b}`);
});

t('the PR detail lists the checks by name and the review state', () => {
  const text = prView({
    pr: { ...PRS[0], statusCheckRollup: [{ name: 'gate', conclusion: 'SUCCESS' }, { name: 'lint', conclusion: 'FAILURE' }] },
    worker: { id: 'ABC-49-slug', ticket: 'ABC-49', state: 'finished', live: '-', quiet_secs: 60 },
    ws: 'alpha',
  });
  assert.match(text, /PR #12/);
  assert.match(text, /ABC-49-slug/);
  assert.match(text, /gate/);
  assert.match(text, /lint/);
  assert.match(text, /APPROVED/);
  for (const b of ['[land]', '[open]', '[review]']) assert.ok(text.includes(b), `missing ${b}`);
});

t('the digest says what happened since the operator last looked', () => {
  const line = digestLine({
    since: '2026-09-20T09:41:00Z',
    mail: [
      { kind: 'status', from: 'bundle-orch', message: 'a long line that goes on and on and on past sixty characters for sure' },
      { kind: 'status', from: 'bundle-orch', message: 'ABC-49 pushed' },
      { kind: 'status', from: 'bundle-orch', message: 'ABC-50 delegated' },
    ],
    merged: 2,
    waiting: 1,
  });
  assert.match(line, /^since 09:41: /);
  assert.match(line, /3 status from bundle-orch/);
  assert.match(line, /ABC-50 delegated/);
  assert.match(line, /2 PRs merged/);
  assert.match(line, /1 decision waiting/);
  // nothing at all is said plainly, not as three zeroes
  assert.match(digestLine({ since: '2026-09-20T09:41:00Z', mail: [], merged: 0, waiting: 0 }), /nothing new/);
});

t('the timeline is one line per event, newest last', () => {
  const events = [
    { ts: '2026-09-20T12:47:00Z', ws: 'alpha', kind: 'merged', what: '#2008 ABC-105' },
    { ts: '2026-09-20T09:00:00Z', ws: 'alpha', kind: 'status', what: 'bundle-orch: first line' },
  ];
  assert.match(timelineLine(events[0]), /merged/);
  assert.match(timelineLine(events[0]), /#2008 ABC-105/);
  assert.match(timelineLine(events[0]), /alpha/);
  const text = timelineView(events);
  assert.match(text, /TIMELINE/);
  // newest LAST: the eye lands at the bottom, where the newest thing is
  assert.ok(text.indexOf('first line') < text.indexOf('#2008'), 'the timeline is upside down');
});

t('the unit view lays out the board and the PRs with the rest', () => {
  const text = unitView({
    unit: UNIT,
    items: [],
    tail: [],
    board: TICKETS,
    prs: PRS,
    digest: 'since 09:41: nothing new',
    now: NOW,
  });
  assert.match(text, /BOARD/);
  assert.match(text, /In Progress/);
  assert.match(text, /ABC-49/);
  assert.match(text, /PRS/);
  assert.match(text, /#12/);
  assert.match(text, /review APPROVED/);
  assert.match(text, /since 09:41/);
  // the order the spec fixes: orchestrator, workers, board, PRs, waiting, mail
  const at = (s) => text.indexOf(s);
  assert.ok(at('ORCHESTRATOR') < at('WORKERS'), 'orchestrator is not first');
  assert.ok(at('WORKERS') < at('BOARD'), 'the board is above the workers');
  assert.ok(at('BOARD') < at('PRS'), 'the PRs are above the board');
  assert.ok(at('PRS') < at('WAITING'), 'waiting is above the PRs');
  assert.ok(at('WAITING') < at('RECENT MAIL'), 'the mail is above waiting');
});

// --- QUOTA: the subscriptions behind the box, direct and through the gateway
// One row per ACCOUNT, because that is the thing that runs out. A gateway
// account's windows are the same shape a direct subscription's are; only
// `source` says which door it came through.
const GATEWAY = {
  installed: true, ready: true, port: 47411, credentials: 3,
  accounts: [
    { source: 'gateway', provider: 'openai-codex', id: 'aaaaaa', ok: true,
      windows: [{ label: '7 days', used: 100, limit: 100, used_pct: 100, state: 'exhausted' }] },
    { source: 'gateway', provider: 'opencode-go', id: 'cred-3', ok: true, windows: [] },
  ],
};

t('the quota view lists gateway accounts under their own heading', () => {
  const text = quotaView({ gateway: GATEWAY }).join('\n');
  assert.match(text, /via gateway/);
  assert.match(text, /openai-codex/);
  assert.match(text, /aaaaaa/);
  assert.match(text, /7 days 100%/);
  assert.match(text, /exhausted/);
});

// A gateway that is not installed is not an error on the QUOTA view: most
// boxes have none, and a red line about an optional door teaches people to
// ignore red lines.
t('the quota view says nothing alarming when there is no gateway', () => {
  const text = quotaView({ gateway: { installed: false, accounts: [] } }).join('\n');
  assert.match(text, /no gateway/);
  assert.doesNotMatch(text, /exhausted/);
});

t('cel gateway status --json renders as the gateway section, never as JSON', () => {
  const out = renderOutput('cel gateway status --json', JSON.stringify(GATEWAY));
  assert.match(out, /via gateway/);
  assert.doesNotMatch(out, /[{}]/);
});

process.stdout.write('views.test.mjs: all good\n');

// --- CEL-27: subscriptions -------------------------------------------------
// The fleet runs on two subscriptions and the console could not see either.
// The edge is the one row that belongs to no panel, so it carries the
// TIGHTEST window per provider - the number that decides whether delegating
// again is worth doing at all.

const SUBS = [
  { provider: 'claude', account: 'a1b2c3', windows: [{ name: '5h', used_pct: 16, resets_at: '2026-09-18T09:00:00Z' }, { name: '7d', used_pct: 41, resets_at: '2026-09-19T19:00:00Z' }], extra: { state: 'disabled', reason: 'out_of_credits' } },
  { provider: 'codex', account: 'acct-alpha-1', windows: [{ name: '5h', used_pct: 9, resets_at: '2026-09-18T07:30:00Z' }, { name: '7d', used_pct: 62, resets_at: '2026-09-21T02:00:00Z' }], extra: { state: 'enabled', reason: '' } },
];

t('the status edge shows one figure per provider', () => {
  assert.equal(subsEdge({ subscriptions: SUBS }), 'claude 16%/41% · codex 9%/62%');
});

t('no subscriptions is no edge at all, never a zero', () => {
  assert.equal(subsEdge({}), '');
  assert.equal(subsEdge({ subscriptions: [] }), '');
});

t('amber at 80, red at 100', () => {
  assert.equal(subsLevel({ subscriptions: SUBS }), 'ok');
  assert.equal(subsLevel({ subscriptions: [{ provider: 'claude', windows: [{ name: '5h', used_pct: 82 }] }] }), 'warn');
  assert.equal(subsLevel({ subscriptions: [{ provider: 'claude', windows: [{ name: '5h', used_pct: 100 }] }] }), 'bad');
});

t('the quota view is one row per account and window, with the balances under it', () => {
  const out = quotaView({ subscriptions: SUBS }).join('\n');
  assert.match(out, /SUBSCRIPTIONS/);
  assert.match(out, /claude\s+a1b2c3/);
  assert.match(out, /5h\s+16%/);
  assert.match(out, /7d\s+41%/);
  assert.match(out, /codex\s+acct-alpha-1/);
  assert.match(out, /out of credits/);
  // never a token, and never raw JSON
  assert.ok(!out.includes('{'), 'the quota view showed raw JSON');
});

t('the quota view says so when nothing is signed in', () => {
  assert.match(quotaView({}).join('\n'), /no signed-in subscriptions/);
});
