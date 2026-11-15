import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { tighten, tightenReviewEvidence } from './private-evidence.mjs';

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
