#!/usr/bin/env node
// Pure tests for the mouse: no terminal, no ink, no node_modules. Run by
// tests/console.test.sh.
import assert from 'node:assert/strict';
import { parseMouse, parseMouseAll, hitTest, MOUSE_ON, MOUSE_OFF } from './mouse.mjs';

const t = (name, fn) => { fn(); process.stdout.write(`  ok ${name}\n`); };

t('a left-button press parses', () => {
  assert.deepEqual(parseMouse('\x1b[<0;12;7M'), { button: 0, x: 12, y: 7, press: true, wheel: null });
});

t('a release is not a press', () => {
  assert.deepEqual(parseMouse('\x1b[<0;12;7m'), { button: 0, x: 12, y: 7, press: false, wheel: null });
});

t('the wheel is reported as a direction, not a button', () => {
  assert.equal(parseMouse('\x1b[<64;3;4M').wheel, 'up');
  assert.equal(parseMouse('\x1b[<65;3;4M').wheel, 'down');
  assert.equal(parseMouse('\x1b[<64;3;4M').button, -1);
});

t('a right-button press keeps its button number', () => {
  assert.equal(parseMouse('\x1b[<2;1;1M').button, 2);
});

t('anything that is not an SGR report is not an event', () => {
  assert.equal(parseMouse('hello'), null);
  assert.equal(parseMouse(''), null);
  assert.equal(parseMouse('\x1b[A'), null);
});

t('a chunk carrying four wheel reports yields four events', () => {
  const evs = parseMouseAll('\x1b[<64;1;1M\x1b[<64;1;1M\x1b[<64;1;1M\x1b[<64;1;1M');
  assert.equal(evs.length, 4);
  assert.equal(evs[3].wheel, 'up');
});

const MAP = [
  { panel: 'fleet', top: 1, bottom: 6, rows: [3, 4, 5] },
  { panel: 'waiting', top: 7, bottom: 10, rows: [9] },
];

t('a click on a measured row gives that row index', () => {
  assert.deepEqual(hitTest(MAP, 5, 3), { panel: 'fleet', index: 0 });
  assert.deepEqual(hitTest(MAP, 5, 5), { panel: 'fleet', index: 2 });
  assert.deepEqual(hitTest(MAP, 5, 9), { panel: 'waiting', index: 0 });
});

t('a click inside a panel but not on a row is the panel with no row', () => {
  assert.deepEqual(hitTest(MAP, 5, 1), { panel: 'fleet', index: -1 });
  assert.deepEqual(hitTest(MAP, 5, 7), { panel: 'waiting', index: -1 });
});

t('a click outside every panel is nothing at all', () => {
  assert.equal(hitTest(MAP, 5, 99), null);
  assert.equal(hitTest(MAP, 5, 0), null);
  assert.equal(hitTest([], 1, 1), null);
});

t('a panel with horizontal bounds ignores a click beside it', () => {
  const map = [{ panel: 'fleet', top: 1, bottom: 3, left: 10, right: 20, rows: [2] }];
  assert.deepEqual(hitTest(map, 15, 2), { panel: 'fleet', index: 0 });
  assert.equal(hitTest(map, 3, 2), null);
});

t('the enable and disable sequences are the documented pair', () => {
  assert.equal(MOUSE_ON, '\x1b[?1000h\x1b[?1006h');
  assert.equal(MOUSE_OFF, '\x1b[?1006l\x1b[?1000l');
});

process.stdout.write('mouse.test.mjs: all good\n');

// X10 encoding (hosts that answer ?1000h but not ?1006h): button 0 press at
// (5,3) is \x1b[M followed by (0+32),(5+32),(3+32); release is code 3.
{
  const { parseMouse, parseMouseAll, hasMouse, hasControl } = await import('./mouse.mjs');
  const press = '\x1b[M' + String.fromCharCode(32, 37, 35);
  const rel = '\x1b[M' + String.fromCharCode(35, 37, 35);
  const wheelDown = '\x1b[M' + String.fromCharCode(32 + 65, 37, 35);
  const eq = (a, b, what) => { if (JSON.stringify(a) !== JSON.stringify(b)) { console.error('FAIL', what, a, b); process.exit(1); } };
  eq(parseMouse(press), { button: 0, x: 5, y: 3, press: true, wheel: null }, 'x10 press');
  eq(parseMouse(rel), { button: 3, x: 5, y: 3, press: false, wheel: null }, 'x10 release');
  eq(parseMouse(wheelDown).wheel, 'down', 'x10 wheel');
  eq(parseMouseAll(press + rel).length, 2, 'x10 chunk');
  eq(hasMouse(press), true, 'x10 hasMouse');
  eq(hasControl('[M !!'), false, 'plain text is not control');
  eq(hasControl('\x1b[I'), true, 'focus event is control');
  eq(hasControl('\x1b[200~'), true, 'paste bracket is control');
  eq(hasControl('hello'), false, 'text');
  console.log('ok x10 + control');
}
