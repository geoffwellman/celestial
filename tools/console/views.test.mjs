#!/usr/bin/env node
// Pure tests for the depth views and for the rule that the console never puts
// raw JSON in front of an operator.
//
// The renderers are pure functions over data the console already has, for the
// same reason the mouse parser is: "the unit view lost the PR column" is not
// something anyone will notice by looking at a terminal, and a view nobody can
// assert is a view that rots.
import assert from 'node:assert/strict';
import { renderOutput, unitView, workerView } from './views.mjs';

const t = (name, fn) => { fn(); process.stdout.write(`  ok ${name}\n`); };

const WORKERS = [
  {
    id: 'ABC-49-slug', ticket: 'ABC-49', repo: 'widget', branch: 'ABC-49-slug',
    shape: 'ship', state: 'running', live: 'idle', quiet_secs: 812,
    verdict: 'stalled', severity: 'warn', ahead: '3',
    pr: 'https://example.invalid/widget/pull/12', alias: 'widget/ABC-49-slug', pane: 'w3:p1',
  },
  {
    id: 'ABC-50-other', ticket: 'ABC-50', repo: 'gadget', branch: 'ABC-50-other',
    shape: 'ship', state: 'running', live: 'working', quiet_secs: 10,
    verdict: '', severity: '', ahead: '0', pr: '', alias: 'gadget/ABC-50-other', pane: 'w3:p2',
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
  assert.match(text, /ABC-49-slug/);
  assert.match(text, /13m/);                        // 812s quiet, in minutes
  assert.match(text, /stalled/);
  assert.match(text, /#12/);                        // the PR number, not the URL
  assert.match(text, /ABC-50-other/);
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
  assert.match(out, /ABC-49-slug/);
  assert.match(out, /ABC-50-other/);
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

process.stdout.write('views.test.mjs: all good\n');
