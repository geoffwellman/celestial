#!/usr/bin/env node
// Pure tests for the command line: the cursor, the shell chords and the
// prefix-filtered history walk. Run by tests/console.test.sh.
import assert from 'node:assert/strict';
import {
  insert, backspace, del, left, right, home, end,
  killWord, killToEnd, killLine, historyWalk, historyFilter,
} from './edit.mjs';

const t = (name, fn) => { fn(); process.stdout.write(`  ok ${name}\n`); };

t('typing inserts at the cursor, not at the end', () => {
  assert.deepEqual(insert('cel fleet', 4, 'X'), { value: 'cel Xfleet', cursor: 5 });
});

t('backspace acts before the cursor and delete acts under it', () => {
  assert.deepEqual(backspace('cel fleet', 4), { value: 'celfleet', cursor: 3 });
  assert.deepEqual(del('cel fleet', 4), { value: 'cel leet', cursor: 4 });
});

t('backspace at the start and delete at the end change nothing', () => {
  assert.deepEqual(backspace('abc', 0), { value: 'abc', cursor: 0 });
  assert.deepEqual(del('abc', 3), { value: 'abc', cursor: 3 });
});

t('the cursor cannot leave the line', () => {
  assert.equal(left('abc', 0).cursor, 0);
  assert.equal(right('abc', 3).cursor, 3);
  assert.equal(home('abc').cursor, 0);
  assert.equal(end('abc').cursor, 3);
});

t('Ctrl+W kills the word before the cursor and its whitespace', () => {
  assert.deepEqual(killWord('cel inbox open', 14), { value: 'cel inbox ', cursor: 10 });
  assert.deepEqual(killWord('cel inbox open', 9), { value: 'cel  open', cursor: 4 });
  assert.deepEqual(killWord('abc', 0), { value: 'abc', cursor: 0 });
});

t('Ctrl+K kills to the end and Ctrl+U kills the line', () => {
  assert.deepEqual(killToEnd('cel inbox open', 4), { value: 'cel ', cursor: 4 });
  assert.deepEqual(killLine(), { value: '', cursor: 0 });
});

const H = ['cel fleet', 'cel inbox open --for root', 'gh pr list', 'cel fleet --json'];

t('an empty line walks the whole history newest first', () => {
  assert.deepEqual(historyWalk(H, -1, 'up', ''), { index: 0, value: 'cel fleet --json' });
  assert.deepEqual(historyWalk(H, 0, 'up', ''), { index: 1, value: 'gh pr list' });
  assert.deepEqual(historyWalk(H, 1, 'down', ''), { index: 0, value: 'cel fleet --json' });
});

t('a typed prefix walks only the entries that start with it', () => {
  assert.deepEqual(historyWalk(H, -1, 'up', 'cel i'), { index: 0, value: 'cel inbox open --for root' });
  // Only one match: walking up again stays put rather than falling through to
  // an entry the operator did not ask for.
  assert.deepEqual(historyWalk(H, 0, 'up', 'cel i'), { index: 0, value: 'cel inbox open --for root' });
});

t('walking back down returns the line the operator was typing', () => {
  assert.deepEqual(historyWalk(H, 0, 'down', 'cel i'), { index: -1, value: 'cel i' });
});

t('a prefix nothing matches leaves the line alone', () => {
  assert.deepEqual(historyWalk(H, -1, 'up', 'zzz'), { index: -1, value: 'zzz' });
  assert.deepEqual(historyWalk([], -1, 'up', ''), { index: -1, value: '' });
});

t('the picker filters by substring, newest first, without duplicates', () => {
  assert.deepEqual(historyFilter(['cel fleet', 'gh pr list', 'cel fleet'], 'fleet'), ['cel fleet']);
  assert.deepEqual(historyFilter(H, 'inbox'), ['cel inbox open --for root']);
  assert.deepEqual(historyFilter(H, 'PR'), ['gh pr list']);
  assert.equal(historyFilter(H, '').length, 4);
});

process.stdout.write('edit.test.mjs: all good\n');
