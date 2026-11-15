import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { tighten, tightenReviewEvidence, tightenTaskMetadata } from './private-evidence.mjs';

const mode = file => (fs.lstatSync(file).mode & 0o777).toString(8);
function workspace() {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), 'cel-private-evidence-'));
  const pr = path.join(ws, '.cel', 'reviews', 'pr-7');
  fs.mkdirSync(path.join(pr, 'qa-browser.shots'), { recursive: true });
  fs.writeFileSync(path.join(pr, 'role-reviewer.md'), 'role\n');
  fs.writeFileSync(path.join(pr, 'qa-browser.shots', 'login-abc.png'), 'png');
  for (const dir of [path.join(ws, '.cel', 'reviews'), pr, path.join(pr, 'qa-browser.shots')]) fs.chmodSync(dir, 0o775);
  for (const file of [path.join(pr, 'role-reviewer.md'), path.join(pr, 'qa-browser.shots', 'login-abc.png')]) fs.chmodSync(file, 0o664);
  return { ws, pr };
}

test('group-writable evidence of this user under .cel/reviews is made 0700/0600 and said', () => {
  const { ws, pr } = workspace();
  const lines = [];
  const results = tightenReviewEvidence(ws, 7, { log: line => lines.push(line) });
  assert.equal(mode(path.join(ws, '.cel', 'reviews')), '700');
  assert.equal(mode(pr), '700');
  assert.equal(mode(path.join(pr, 'role-reviewer.md')), '600');
  assert.equal(mode(path.join(pr, 'qa-browser.shots')), '700');
  assert.equal(mode(path.join(pr, 'qa-browser.shots', 'login-abc.png')), '600');
  assert.ok(results.every(r => r.status === 'tightened'));
  assert.ok(lines.some(line => line.includes(`tightened review evidence ${pr} from 0775 to 0700`)));
  // already private: nothing changes, nothing said
  lines.length = 0;
  assert.ok(tightenReviewEvidence(ws, 7, { log: line => lines.push(line) }).every(r => r.status === 'private'));
  assert.deepEqual(lines, []);
  fs.rmSync(ws, { recursive: true, force: true });
});

test('evidence owned by another user is left as it is', () => {
  const { ws, pr } = workspace();
  const lines = [];
  const other = process.getuid() + 1;
  assert.equal(tighten(path.join(ws, '.cel', 'reviews'), pr, { uid: other, log: line => lines.push(line) }), 'not_owned');
  assert.equal(mode(pr), '775');
  assert.ok(lines.some(line => line.includes(`left ${pr} as it is: owned by uid`)));
  fs.rmSync(ws, { recursive: true, force: true });
});

test('a symlink - the target itself or any directory on its path - is never followed', () => {
  const { ws, pr } = workspace();
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'cel-private-outside-'));
  fs.writeFileSync(path.join(outside, 'secret.md'), 'x'); fs.chmodSync(path.join(outside, 'secret.md'), 0o664);
  fs.chmodSync(outside, 0o775);
  fs.symlinkSync(path.join(outside, 'secret.md'), path.join(pr, 'linked.role-reviewer.md'));
  const log = () => {};
  tightenReviewEvidence(ws, 7, { log });
  assert.equal(mode(path.join(outside, 'secret.md')), '664');
  // the whole pr directory a symlink
  const ws2 = fs.mkdtempSync(path.join(os.tmpdir(), 'cel-private-evidence-'));
  fs.mkdirSync(path.join(ws2, '.cel', 'reviews'), { recursive: true });
  fs.symlinkSync(outside, path.join(ws2, '.cel', 'reviews', 'pr-7'));
  const results = tightenReviewEvidence(ws2, 7, { log });
  assert.equal(results.find(r => r.path.endsWith('pr-7')).status, 'symlink');
  assert.equal(mode(outside), '775');
  // a symlinked .cel/reviews: nothing under it is touched
  const ws3 = fs.mkdtempSync(path.join(os.tmpdir(), 'cel-private-evidence-'));
  fs.mkdirSync(path.join(ws3, '.cel'));
  fs.symlinkSync(path.join(ws, '.cel', 'reviews'), path.join(ws3, '.cel', 'reviews'));
  fs.chmodSync(pr, 0o775);
  tightenReviewEvidence(ws3, 7, { log });
  assert.equal(mode(pr), '775');
  for (const dir of [ws, ws2, ws3, outside]) fs.rmSync(dir, { recursive: true, force: true });
});

test('nothing outside the root, and no malformed request, is touched', () => {
  const { ws, pr } = workspace();
  assert.equal(tighten(path.join(ws, '.cel', 'reviews'), ws, { log: () => {} }), 'outside_root');
  assert.equal(tighten(path.join(pr, '..', '..'), path.join(pr, '..', '..', '..'), { log: () => {} }), 'outside_root');
  assert.deepEqual(tightenReviewEvidence(ws, '7/../../x', { log: () => {} }), []);
  assert.deepEqual(tightenReviewEvidence('relative', 7, { log: () => {} }), []);
  assert.equal(mode(pr), '775');
  fs.rmSync(ws, { recursive: true, force: true });
});

// A directory on the path swapped for a symlink (here, already in place when
// tighten is called, as a same-user swap between a check and an open would
// leave it): every component is opened O_NOFOLLOW, so the call refuses and
// nothing outside the root changes.
test('a symlink swapped in for an intermediate directory is refused, never followed', () => {
  const { ws, pr } = workspace();
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'cel-private-outside-'));
  fs.mkdirSync(path.join(outside, 'qa-browser.shots'));
  fs.writeFileSync(path.join(outside, 'qa-browser.shots', 'login-abc.png'), 'x');
  fs.chmodSync(path.join(outside, 'qa-browser.shots', 'login-abc.png'), 0o664);
  fs.chmodSync(path.join(outside, 'qa-browser.shots'), 0o775);
  fs.rmSync(path.join(pr, 'qa-browser.shots'), { recursive: true });
  fs.symlinkSync(path.join(outside, 'qa-browser.shots'), path.join(pr, 'qa-browser.shots'));
  const lines = [];
  const root = path.join(ws, '.cel', 'reviews');
  assert.equal(tighten(root, path.join(pr, 'qa-browser.shots', 'login-abc.png'), { log: line => lines.push(line) }), 'symlink');
  assert.equal(mode(path.join(outside, 'qa-browser.shots', 'login-abc.png')), '664');
  assert.equal(mode(path.join(outside, 'qa-browser.shots')), '775');
  assert.ok(lines.some(line => line.includes('a symlink (or a non-directory) is in its path')));
  // and the whole pr directory swapped
  const moved = `${pr}.real`;
  fs.renameSync(pr, moved); fs.symlinkSync(moved, pr);
  assert.equal(tighten(root, path.join(pr, 'role-reviewer.md'), { log: () => {} }), 'symlink');
  assert.equal(mode(path.join(moved, 'role-reviewer.md')), '664');
  for (const dir of [ws, outside]) fs.rmSync(dir, { recursive: true, force: true });
});

test('a hard-linked file is left as it is and said', () => {
  const { ws, pr } = workspace();
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'cel-private-outside-'));
  fs.writeFileSync(path.join(outside, 'other.md'), 'x'); fs.chmodSync(path.join(outside, 'other.md'), 0o664);
  fs.linkSync(path.join(outside, 'other.md'), path.join(pr, 'linked.role-reviewer.md'));
  const lines = [];
  const results = tightenReviewEvidence(ws, 7, { log: line => lines.push(line) });
  assert.equal(results.find(r => r.path.endsWith('linked.role-reviewer.md')).status, 'hardlinked');
  assert.equal(mode(path.join(outside, 'other.md')), '664');
  assert.equal(mode(path.join(pr, 'role-reviewer.md')), '600');
  assert.ok(lines.some(line => line.includes('a hard link (2 names)')));
  for (const dir of [ws, outside]) fs.rmSync(dir, { recursive: true, force: true });
});

test("a checkout's Pi task metadata is tightened under .pi/tasks only", () => {
  const checkout = fs.mkdtempSync(path.join(os.tmpdir(), 'cel-private-checkout-'));
  const store = path.join(checkout, '.pi', 'tasks', 'session-42');
  fs.mkdirSync(store, { recursive: true });
  fs.writeFileSync(path.join(store, 'build.json'), '{}');
  fs.writeFileSync(path.join(checkout, 'README.md'), 'x');
  for (const dir of [path.join(checkout, '.pi'), path.join(checkout, '.pi', 'tasks'), store]) fs.chmodSync(dir, 0o775);
  for (const file of [path.join(store, 'build.json'), path.join(checkout, 'README.md')]) fs.chmodSync(file, 0o664);
  const results = tightenTaskMetadata(checkout, { log: () => {} });
  assert.ok(results.length === 3 && results.every(r => r.status === 'tightened'));
  assert.equal(mode(path.join(checkout, '.pi', 'tasks')), '700');
  assert.equal(mode(store), '700');
  assert.equal(mode(path.join(store, 'build.json')), '600');
  assert.equal(mode(path.join(checkout, '.pi')), '775');
  assert.equal(mode(path.join(checkout, 'README.md')), '664');
  assert.deepEqual(tightenTaskMetadata(path.join(checkout, 'none'), { log: () => {} }), [{ path: path.join(checkout, 'none', '.pi', 'tasks'), status: 'absent' }]);
  fs.rmSync(checkout, { recursive: true, force: true });
});
