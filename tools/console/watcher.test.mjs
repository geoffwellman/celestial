#!/usr/bin/env node
// Pure tests for the watcher the console arms and must take with it.
//
// One `stop`, on every exit path, kills the watcher's whole process GROUP
// (its `tail`/`jq` children too); spawn, proc and kill are injected so those
// paths are proved without a terminal or a real signal.
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { startWatcher } from './watcher.mjs';

const t = (name, fn) => { fn(); process.stdout.write(`  ok ${name}\n`); };

const harness = () => {
  const proc = new EventEmitter();
  proc.pid = 4242;
  const killed = [];
  const spawned = [];
  const child = new EventEmitter();
  child.pid = 999;
  child.stdout = new EventEmitter();
  child.kill = () => killed.push(['child', 'SIGTERM']);
  const lines = [];
  const stop = startWatcher({
    bin: 'cel',
    spawn: (bin, args, opts) => { spawned.push({ bin, args, opts }); return child; },
    proc,
    kill: (pid, sig) => killed.push([pid, sig]),
    onLine: (l) => lines.push(l),
    onError: () => {},
  });
  return { proc, child, killed, spawned, lines, stop };
};

t('the watcher is told which console owns it, and is its own process group', () => {
  const { spawned } = harness();
  assert.equal(spawned.length, 1);
  assert.deepEqual(spawned[0].args,
    ['inbox', 'watch', '--for', 'root', '--all-workspaces', '--parent', '4242']);
  assert.equal(spawned[0].opts.detached, true);
});

t('a clean stop kills the group, once', () => {
  const { killed, stop } = harness();
  stop();
  assert.deepEqual(killed, [[-999, 'SIGTERM']]);
  stop();
  assert.deepEqual(killed, [[-999, 'SIGTERM']]);
});

for (const [signal, name] of [['SIGTERM', 'SIGTERM'], ['SIGINT', 'Ctrl-C'], ['SIGHUP', 'a closed pane']]) {
  t(`${name} takes the watcher with it`, () => {
    const { proc, killed } = harness();
    proc.emit(signal);
    assert.deepEqual(killed, [[-999, 'SIGTERM']]);
  });
}

t('a normal exit takes the watcher with it', () => {
  const { proc, killed } = harness();
  proc.emit('exit', 0);
  assert.deepEqual(killed, [[-999, 'SIGTERM']]);
});

t('an uncaught throw takes the watcher with it', () => {
  const { proc, killed } = harness();
  proc.emit('uncaughtException', new Error('boom'));
  assert.deepEqual(killed, [[-999, 'SIGTERM']]);
});

t('whole lines reach the caller and partial ones wait', () => {
  const { child, lines } = harness();
  child.stdout.emit('data', 'one\ntw');
  assert.deepEqual(lines, ['one']);
  child.stdout.emit('data', 'o\n');
  assert.deepEqual(lines, ['one', 'two']);
});
