#!/usr/bin/env node
// Pure tests for the steering half of CEL-36: the reply watch and the relay.
//
// The UI around these is ink and cannot be driven without a terminal, so
// everything that decides WHAT is said, WHICH command is run and WHICH reply
// counts lives here and is asserted without one. A watch that matched the
// wrong message would put another agent's words in the status line under an
// orchestrator's name, which is worse than showing nothing.
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  REPLY_WAIT_DEFAULT, replyWaitSecs, replyFrom, replyLine, noReplyLine,
  talkPrompt, talkRead, paneLines, talkLegend, TALK_LINES,
} from './steer.mjs';

const t = (name, fn) => { fn(); process.stdout.write(`  ok ${name}\n`); };

const T = mkdtempSync(join(tmpdir(), 'cel-steer-'));
const inbox = join(T, 'inbox');
mkdirSync(inbox, { recursive: true });

const line = (o) => `${JSON.stringify(o)}\n`;
writeFileSync(join(inbox, 'alpha.jsonl'), [
  line({ id: '1', ts: '2026-09-19T10:00:00+00:00', from: 'bundle-orch', to: 'root', kind: 'status', message: 'before the send' }),
  line({ id: '2', ts: '2026-09-19T10:05:00+00:00', from: 'widget-orch', to: 'root', kind: 'status', message: 'somebody else' }),
  line({ id: '3', ts: '2026-09-19T10:06:00+00:00', from: 'bundle-orch', to: 'ABC-49-slug', kind: 'status', message: 'not addressed to you' }),
  line({ id: '4', ts: '2026-09-19T10:07:00+00:00', from: 'bundle-orch', to: 'root', kind: 'status', message: 'picked up ABC-49\nand started it' }),
].join(''));

const since = '2026-09-19T10:01:00+00:00';

t('the reply is the addressee\u2019s next message to root, after the send', () => {
  const m = replyFrom({ ws: 'alpha', who: 'bundle-orch', since, dir: inbox });
  assert.ok(m, 'no reply found');
  assert.equal(m.id, '4');
});

// THREE WAYS TO MATCH THE WRONG THING, all of them tried by hand first: an
// older message from the right agent, a newer one from the wrong agent, and
// one addressed to a worker rather than to the operator.
t('nothing older, nothing from another agent, nothing addressed elsewhere', () => {
  assert.equal(replyFrom({ ws: 'alpha', who: 'bundle-orch', since: '2026-09-19T11:00:00+00:00', dir: inbox }), null);
  assert.equal(replyFrom({ ws: 'alpha', who: 'nobody-orch', since, dir: inbox }), null);
  assert.equal(replyFrom({ ws: 'nosuch', who: 'bundle-orch', since, dir: inbox }), null);
});

t('a message to the console counts as a reply too', () => {
  writeFileSync(join(inbox, 'beta.jsonl'),
    line({ id: '9', ts: '2026-09-19T10:09:00+00:00', from: 'gadget-orch', to: 'console', kind: 'status', message: 'on it' }));
  const m = replyFrom({ ws: 'beta', who: 'gadget-orch', since, dir: inbox });
  assert.equal(m && m.id, '9');
});

t('the status line is one line; the detail view has the rest', () => {
  assert.equal(replyLine('bundle-orch', { message: 'picked up ABC-49\nand started it' }),
    'bundle-orch: picked up ABC-49');
  assert.equal(noReplyLine('bundle-orch'),
    'bundle-orch is working; its reply will land in the inbox');
});

t('the wait is 90 s unless the config says otherwise', () => {
  assert.equal(REPLY_WAIT_DEFAULT, 90);
  const cfg = join(T, 'config.yaml');
  writeFileSync(cfg, 'console:\n  provider: openrouter\n  reply_wait: 20\n');
  assert.equal(replyWaitSecs(cfg), 20);
  assert.equal(replyWaitSecs(join(T, 'no-such.yaml')), 90);
});

// THE RELAY. Two commands, both already on the console's allowlist, and
// nothing else: `talk` is the one place the console passes a conversation
// through, so the surface it needs is exactly two verbs wide.
t('a talk line is a herdr prompt, single-quoted like every other', () => {
  assert.equal(talkPrompt('bundle-orch', 'what is left on ABC-49?'),
    "herdr agent prompt bundle-orch 'what is left on ABC-49?'");
  assert.equal(talkPrompt('bundle-orch', "don't $(rm -rf ~)"),
    "herdr agent prompt bundle-orch 'don'\\''t $(rm -rf ~)'");
  assert.equal(talkRead('bundle-orch'), 'herdr agent read bundle-orch --source recent-unwrapped');
});

t('the pane view is its last forty lines, and the legend says how to leave', () => {
  assert.equal(TALK_LINES, 40);
  const text = Array.from({ length: 60 }, (_, i) => `line ${i}`).join('\n');
  const rows = paneLines(text);
  assert.equal(rows.length, 40);
  assert.equal(rows[39], 'line 59');
  assert.deepEqual(paneLines('one\n\n'), ['one']);
  assert.equal(talkLegend('bundle-orch'), 'talking to bundle-orch - Esc to stop');
});

rmSync(T, { recursive: true, force: true });
process.stdout.write('steer: all tests passed\n');
