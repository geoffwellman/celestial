import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import test from 'node:test';
import { startReviewerRetirement } from './reviewer-retirement.mjs';
import { reviewerRetirementPaths } from '../reviewers/retirement-protocol.mjs';

const sourceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function fixture(t, overrides = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cel-native-retirement-'));
  const workspace = path.join(dir, 'workspace');
  const cwd = path.join(dir, 'checkout');
  const file = path.join(dir, 'widget-pr-71-review.json');
  const native = path.join(dir, 'native.jsonl');
  const stat = fs.readFileSync(`/proc/${process.pid}/stat`, 'utf8');
  const start = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[19];
  fs.mkdirSync(workspace); fs.mkdirSync(cwd);
  fs.writeFileSync(file, JSON.stringify({ name: 'widget-pr-71-review', role: 'reviewer', agent: 'pi', backend: 'rex', workspace, cwd, repo: 'widget', pr: '71', pid: process.pid, pid_start: start, agent_status: 'idle', rex_session: 'session:fixture', rex_block: 'block:fixture', pane_id: 'rex/session:fixture/block:fixture', agent_session: { value: native } }), { mode: 0o600 });
  const f = {
    dir, file, native, start, leaf: 'completed-leaf', idle: true, sdkPending: false,
    active: false, editor: '', unread: 0, debt: { owed: false, pending: false, waking: false }, events: [],
  };
  f.protocol = reviewerRetirementPaths(file);
  const env = { CEL_ROLE: 'reviewer', CEL_SESSION_BACKEND: 'rex', CEL_AGENT_NAME: 'widget-pr-71-review', CEL_REX_RECORD: file, CEL_ROLE_FILE: path.join(workspace, '.cel', 'reviews', overrides.reviewDir || 'pr-71', overrides.roleName || 'role-reviewer.md'), ...overrides.env };
  const ctx = {
    cwd, mode: 'tui', hasUI: true,
    sessionManager: { getSessionFile: () => f.native, getLeafId: () => f.leaf },
    isIdle: () => f.idle,
    hasPendingMessages: () => f.sdkPending,
    ui: { getEditorText: () => f.editor },
    shutdown() { f.events.push('shutdown'); if (f.failShutdown) throw new Error('fixture shutdown refused'); f.onShutdown?.(); },
  };
  f.ctx = ctx;
  f.startController = () => (f.controller = startReviewerRetirement({
    env, getContext: () => ctx, getInboxDebt: () => f.debt,
    getNativeTurnActive: () => f.active,
    countUnread: () => { if (f.countFailure) throw new Error('fixture unavailable'); return f.unread; },
    prepareExit: () => { f.events.push('prepare'); },
    restoreAfterFailedExit: () => { f.events.push('restore'); },
  }));
  if (overrides.start !== false) f.startController();
  t.after(() => { f.controller?.dispose(); fs.rmSync(dir, { recursive: true, force: true }); });
  return f;
}

function request(f, phase, nonce, leaf = undefined) {
  const now = Date.now();
  const value = { version: 1, type: 'cel-reviewer-retirement-request', phase, nonce, name: 'widget-pr-71-review', pid: process.pid, pid_start: f.start, native_session: f.native, created_at: now, expires_at: now + 15000, ...(leaf !== undefined ? { expected_leaf: leaf } : {}) };
  const tmp = `${f.protocol.request}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 });
  fs.renameSync(tmp, f.protocol.request);
}

function reply(f, phase, nonce) {
  return new Promise((resolve, reject) => {
    let watcher, timer;
    const close = () => { watcher?.close(); clearTimeout(timer); };
    const check = () => {
      try {
        const value = JSON.parse(fs.readFileSync(f.protocol.response, 'utf8'));
        if (value.phase === phase && value.nonce === nonce) { close(); resolve(value); }
      } catch {}
    };
    watcher = fs.watch(f.protocol.directory, { persistent: false }, check);
    timer = setTimeout(() => { close(); reject(new Error('native retirement response deadline')); }, 5000);
    check();
  });
}

async function inspect(f, nonce = randomUUID()) {
  const waiting = reply(f, 'inspect', nonce);
  request(f, 'inspect', nonce);
  return { nonce, response: await waiting };
}
async function exit(f, nonce, leaf = f.leaf) {
  const waiting = reply(f, 'exit', nonce);
  request(f, 'exit', nonce, leaf);
  return waiting;
}

test('native permission requires its inspected live leaf before supported shutdown', async t => {
  const f = fixture(t);
  const first = await inspect(f);
  assert.equal(first.response.status, 'ready');
  assert.equal(first.response.live_leaf, 'completed-leaf');
  assert.deepEqual(f.events, []);
  const committed = await exit(f, first.nonce);
  assert.equal(committed.status, 'exiting');
  assert.equal(committed.exit_committed, true);
  assert.deepEqual(f.events, ['prepare', 'shutdown']);
});

test('zero unread does not waive drained in-memory inbox debt', async t => {
  for (const key of ['owed', 'pending', 'waking']) {
    await t.test(key, async sub => {
      const f = fixture(sub); f.debt[key] = true;
      const { response } = await inspect(f);
      assert.equal(response.status, 'protected');
      assert.equal(response[`inbox_${key}`], true);
      assert.deepEqual(f.events, []);
    });
  }
});

test('native turn admission and SDK pending work remain protected while SDK appears idle', async t => {
  for (const field of ['active', 'sdkPending']) {
    await t.test(field, async sub => {
      const f = fixture(sub); f[field] = true;
      const { response } = await inspect(f);
      assert.equal(response.status, 'protected');
      assert.deepEqual(f.events, []);
    });
  }
});

test('an in-memory selected leaf change aborts the previously inspected exit', async t => {
  const f = fixture(t); const first = await inspect(f);
  f.leaf = 'earlier-unfinished-leaf';
  const response = await exit(f, first.nonce, first.response.live_leaf);
  assert.equal(response.status, 'protected');
  assert.equal(response.live_leaf, 'earlier-unfinished-leaf');
  assert.equal(response.exit_committed, false);
  assert.deepEqual(f.events, []);
});

test('new inbox debt after inspection prevents native exit', async t => {
  const f = fixture(t); const first = await inspect(f);
  f.debt.pending = true;
  const response = await exit(f, first.nonce);
  assert.equal(response.status, 'protected');
  assert.equal(response.inbox_pending, true);
  assert.deepEqual(f.events, []);
});

test('exit cannot skip inspection or substitute a different nonce', async t => {
  const f = fixture(t);
  const uninspected = await exit(f, randomUUID());
  assert.equal(uninspected.status, 'protected');
  const first = await inspect(f);
  const substituted = await exit(f, randomUUID(), first.response.live_leaf);
  assert.equal(substituted.status, 'protected');
  assert.deepEqual(f.events, []);
});

test('unread count failures and malformed state never become empty-work permission', async t => {
  for (const mode of ['failure', 'malformed', 'missing-turn-state']) {
    await t.test(mode, async sub => {
      const f = fixture(sub);
      if (mode === 'failure') f.countFailure = true;
      if (mode === 'malformed') f.unread = '0';
      if (mode === 'missing-turn-state') f.active = undefined;
      const { response } = await inspect(f);
      assert.equal(response.status, 'unknown');
      assert.deepEqual(f.events, []);
    });
  }
});

test('native API refusal restores delivery and does not publish an exit commitment', async t => {
  const f = fixture(t); const first = await inspect(f);
  f.failShutdown = true;
  const response = await exit(f, first.nonce);
  assert.equal(response.status, 'unknown');
  assert.equal(response.exit_committed, false);
  assert.deepEqual(f.events, ['prepare', 'shutdown', 'restore']);
});

test('a normal main runtime never publishes reviewer retirement capability', t => {
  const f = fixture(t, { env: { CEL_ROLE: 'solo' } });
  assert.equal(f.controller, null);
  assert.equal(fs.existsSync(f.protocol.capability), false);
});

test('native protocol publication preserves the canonical Rex inventory across old flat readers', async t => {
  const f = fixture(t, { start: false });
  const inventory = () => JSON.parse(execFileSync('bash', ['-c', 'source "$CEL_ROOT/lib/common.sh"; source "$CEL_ROOT/lib/rex.sh"; rex_agent_list'], {
    encoding: 'utf8', env: { ...process.env, CEL_ROOT: sourceRoot, CEL_REX_STATE: f.dir },
  }));
  const before = inventory();
  assert.equal(before.result.agents[0].name, 'widget-pr-71-review');
  assert.equal(before.result.agents[0].pid, process.pid);
  f.startController();
  const { response } = await inspect(f);
  assert.equal(response.status, 'ready');
  assert.deepEqual(inventory(), before);
});

// An extra reviewer's role file is <focus>.role-reviewer.md and a QA agent's
// qa-<focus>.role-reviewer.md, beside the plain one in the PR's review dir
// (lib/run.sh): each is a reviewer of that PR, retired by the same proof. A
// role file under another PR, or of another shape, is not this reviewer's.
test('extra reviewers and QA agents are retired by the same identity proof', async t => {
  for (const roleName of ['security.role-reviewer.md', 'qa-browser.role-reviewer.md']) {
    await t.test(roleName, async sub => {
      const f = fixture(sub, { roleName });
      assert.ok(f.controller, `${roleName} was not recognised as this PR's reviewer role`);
      const { response } = await inspect(f);
      assert.equal(response.status, 'ready');
    });
  }
  for (const [reviewDir, roleName] of [['pr-72', 'qa-browser.role-reviewer.md'], ['pr-71', 'role-orchestrator.md'], ['pr-71', '../role-reviewer.md'], ['pr-71', 'qa-browser.role-reviewer.md.bak']]) {
    await t.test(`${reviewDir}/${roleName}`, sub => {
      const f = fixture(sub, { reviewDir, roleName });
      assert.equal(f.controller, null);
    });
  }
});
