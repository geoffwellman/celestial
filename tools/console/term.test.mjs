#!/usr/bin/env node
// Pure tests for the terminal modes: a fake writer and a fake process, so the
// signal paths can be proved without sending this test runner a signal.
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { enterTerminal, ENTER, LEAVE, ALT_ON, ALT_OFF } from './term.mjs';
import { MOUSE_ON, MOUSE_OFF } from './mouse.mjs';

const t = (name, fn) => { fn(); process.stdout.write(`  ok ${name}\n`); };

const harness = () => {
  const out = [];
  const proc = new EventEmitter();
  const exits = [];
  const restore = enterTerminal({
    write: (s) => out.push(s),
    proc,
    exit: (c) => exits.push(c),
    onError: () => {},
  });
  return { out, proc, exits, restore };
};

t('entering switches screen first, then the mouse on', () => {
  assert.equal(ENTER, ALT_ON + MOUSE_ON);
  assert.equal(LEAVE, MOUSE_OFF + ALT_OFF);
  const { out } = harness();
  assert.deepEqual(out, [ENTER]);
});

t('a clean restore leaves both modes, in order, exactly once', () => {
  const { out, restore } = harness();
  restore();
  assert.deepEqual(out, [ENTER, LEAVE]);
  restore();
  assert.deepEqual(out, [ENTER, LEAVE]);
});

t('SIGTERM leaves the screen and exits', () => {
  const { out, proc, exits } = harness();
  proc.emit('SIGTERM');
  assert.deepEqual(out, [ENTER, LEAVE]);
  assert.deepEqual(exits, [143]);
});

t('Ctrl+C and a hangup leave it too', () => {
  const a = harness();
  a.proc.emit('SIGINT');
  assert.deepEqual(a.out, [ENTER, LEAVE]);
  assert.deepEqual(a.exits, [130]);
  const b = harness();
  b.proc.emit('SIGHUP');
  assert.deepEqual(b.out, [ENTER, LEAVE]);
  assert.deepEqual(b.exits, [129]);
});

t('an uncaught error leaves the screen before it dies', () => {
  const { out, proc, exits } = harness();
  proc.emit('uncaughtException', new Error('boom'));
  assert.deepEqual(out, [ENTER, LEAVE]);
  assert.deepEqual(exits, [1]);
});

t('a plain exit leaves the screen', () => {
  const { out, proc } = harness();
  proc.emit('exit', 0);
  assert.deepEqual(out, [ENTER, LEAVE]);
});

t('the handlers are removed when the console unmounts', () => {
  const { proc, restore } = harness();
  restore();
  for (const sig of ['exit', 'SIGTERM', 'SIGINT', 'SIGHUP', 'uncaughtException']) {
    assert.equal(proc.listenerCount(sig), 0, `${sig} listener was left behind`);
  }
});

process.stdout.write('term.test.mjs: all good\n');
