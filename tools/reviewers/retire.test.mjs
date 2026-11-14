import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { parseNative as parseNativeAtLeaf, emptyComposer, checkoutPreserved, validateNativeResponse, validateExitCommitment, validateArchivedRole, validatedProcessEvidence, sessionTopology, selectedRound, durableRound, githubBinary, githubEnv } from './retire.mjs';
import { INBOX_WATCH_PROGRAMS } from './inbox-watch-programs.mjs';

// These are parser/preservation fixtures, not evidence of real review quality
// or of the production Rex lifecycle (the latter requires a supported smoke).
const cwd = '/tmp/widget-review';
const parseNative = (data, directory, roundAt, leaf = 'final') => parseNativeAtLeaf(data, directory, roundAt, leaf);
const at = n => new Date(Date.parse('2025-01-01T00:00:00Z') + n * 1000).toISOString();
const header = { type: 'session', version: 3, id: 'widget-session', timestamp: at(0), cwd };
const event = (id, parentId, n, message) => ({ type: 'message', id, parentId, timestamp: at(n), message });
const assistant = (content, stopReason = 'stop') => ({ role: 'assistant', content, stopReason });
const call = id => ({ type: 'toolCall', id, name: 'bash', arguments: { command: 'true' } });
const final = (id = 'final', parent = 'result', n = 4) => event(id, parent, n, assistant([{ type: 'text', text: 'Findings recorded.' }]));
const settled = () => [
  event('user', null, 1, { role: 'user', content: 'Review widget.' }),
  event('call', 'user', 2, assistant([call('tool-1')], 'toolUse')),
  event('result', 'call', 3, { role: 'toolResult', toolCallId: 'tool-1', content: [{ type: 'text', text: 'Saved.' }], isError: false }),
  final(),
];
const bytes = entries => Buffer.from([header, ...entries].map(e => JSON.stringify(e)).join('\n') + '\n');
const refusal = (fn, reason, status) => assert.throws(fn, e => e.message === reason && (!status || e.status === status));

test('settled actual Pi tool IDs and final stop bind to the completed round', () => {
  assert.deepEqual(parseNative(bytes(settled()), cwd, Date.parse(at(3))), { id: 'widget-session', leaf: 'final', final: 'final', finalAt: Date.parse(at(4)) });
});

test('current native branch is followed rather than replaying abandoned siblings', () => {
  const entries = settled();
  entries.splice(3, 0, event('abandoned', 'user', 3, assistant([call('abandoned-tool')], 'toolUse')));
  assert.equal(parseNative(bytes(entries), cwd, Date.parse(at(3))).final, 'final');
});

test('persisted last append cannot substitute for the live attested leaf', () => {
  const entries = [...settled(), event('other-branch', 'user', 5, assistant([call('other-tool')], 'toolUse'))];
  assert.equal(parseNative(bytes(entries), cwd, 0, 'final').final, 'final');
  refusal(() => parseNativeAtLeaf(bytes(entries), cwd, 0), 'unattested_native_leaf', 'protected');
  refusal(() => parseNative(bytes(entries), cwd, 0, 'other-branch'), 'pending_native_tools', 'protected');
});

test('pending tool calls cannot self-waive with a later assistant stop', () => {
  const entries = settled();
  entries.splice(2, 1);
  entries[2].parentId = 'call';
  refusal(() => parseNative(bytes(entries), cwd, 0), 'pending_native_tools', 'protected');
});

test('unmatched and duplicate actual tool identifiers fail closed', () => {
  const unmatched = settled(); unmatched[2].message.toolCallId = 'other';
  refusal(() => parseNative(bytes(unmatched), cwd, 0), 'unmatched_native_tool_result');
  const duplicate = settled(); duplicate[1].message.content.push(call('tool-1'));
  refusal(() => parseNative(bytes(duplicate), cwd, 0), 'duplicate_native_tool');
});

test('late user/inbox/compaction work invalidates an earlier completed stop', () => {
  const tails = [
    event('late', 'final', 5, { role: 'user', content: 'Review the new head.' }),
    { type: 'custom_message', id: 'late', parentId: 'final', timestamp: at(5), customType: 'cel-inbox', content: 'New work.' },
    { type: 'compaction', id: 'late', parentId: 'final', timestamp: at(5), summary: 'Context.' },
  ];
  for (const tail of tails) refusal(() => parseNative(bytes([...settled(), tail]), cwd, 0, 'late'), 'native_round_not_completed', 'protected');
});

test('unknown background/custom metadata cannot become an empty waiver', () => {
  const tail = { type: 'custom', id: 'late', parentId: 'final', timestamp: at(5), customType: 'unknown-background-state', data: {} };
  refusal(() => parseNative(bytes([...settled(), tail]), cwd, 0, 'late'), 'unknown_native_custom_state');
});

test('old stops, interrupted stops, malformed/truncated branches, and unsupported headers remain protected or unknown', () => {
  refusal(() => parseNative(bytes(settled()), cwd, Date.parse(at(5))), 'native_stop_not_after_verdict', 'protected');
  const interrupted = settled(); interrupted.at(-1).message.stopReason = 'aborted';
  refusal(() => parseNative(bytes(interrupted), cwd, 0), 'native_round_not_completed', 'protected');
  refusal(() => parseNative(bytes(settled()).subarray(0, -1), cwd, 0), 'truncated_native_history');
  const branch = settled(); branch.at(-1).parentId = 'missing';
  refusal(() => parseNative(bytes(branch), cwd, 0), 'unknown_native_branch');
  const unsupported = bytes(settled()).toString().replace('"version":3', '"version":99');
  refusal(() => parseNative(Buffer.from(unsupported), cwd, 0), 'unsupported_native_header');
  assert.throws(() => parseNative(Buffer.from('{bad json}\n'), cwd, 0));
});

// Pi 1.5's stats line: token counters, the context usage, then the provider
// and model right-aligned (fixtures/pi-1.5.0-idle-footer.txt is a real one).
const stats = '↑12k ↓3.4k R1.2M W40k CH98.5% 23.4%/200k (auto)  (fixture-gate) widget-model • medium';
const capture = (draft = '', footer = `${cwd} (review-widget)\n${stats}`) => {
  const content = `Review complete.\n────────────────────\n${draft}\n────────────────────\n${footer}\n`;
  return { content, eof: true, total: Buffer.byteLength(content) };
};

test('only a complete recognized Pi blank composer is eligible', () => {
  assert.equal(typeof emptyComposer(capture(), cwd), 'string');
  refusal(() => emptyComposer(capture('Please wait'), cwd), 'unsent_composer_draft', 'protected');
  refusal(() => emptyComposer({ ...capture(), eof: false }, cwd), 'incomplete_terminal_capture');
  refusal(() => emptyComposer({ ...capture(), total: 1 }, cwd), 'incomplete_terminal_capture');
  refusal(() => emptyComposer(capture('', `/another/checkout (review-widget)\n${stats}`), cwd), 'unknown_pi_footer');
  refusal(() => emptyComposer(capture('', `${cwd} (review-widget)\n${stats}\nCompacting`), cwd), 'unsettled_terminal_tail', 'protected');
  const modal = capture(); modal.content = 'Unknown modal'; modal.total = Buffer.byteLength(modal.content);
  refusal(() => emptyComposer(modal, cwd), 'unknown_composer_layout');
});

// What an idle Pi 1.5.0 pane actually showed (Rex `block call format`, the
// same call retirement makes): its checkout in `~` form followed by the git
// branch, then the stats line. Only the path, branch and model are
// placeholders; the borders, counters and padding are as rendered.
test('the footer of a live idle Pi 1.5.0 pane is recognized', () => {
  const real = fs.readFileSync(new URL('./fixtures/pi-1.5.0-idle-footer.txt', import.meta.url), 'utf8');
  const live = cwdLine => {
    const content = `Review complete; verdict recorded.\n\n${real.replace('~/reviews/widget-pr-7 (review-widget)', cwdLine)}`;
    return { content, eof: true, total: Buffer.byteLength(content) };
  };
  const home = process.env.HOME;
  assert.ok(home && home !== '/');
  const checkout = path.join(home, 'reviews/widget-pr-7');
  assert.equal(typeof emptyComposer(live('~/reviews/widget-pr-7 (review-widget)'), checkout), 'string');
  // Pi prints the `~` form inside HOME; the absolute form is the same checkout.
  assert.equal(typeof emptyComposer(live(`${checkout} (review-widget)`), checkout), 'string');
  // Another checkout, a longer path sharing the prefix, a cut-off line, or
  // anything else after the branch is not this reviewer's footer.
  for (const other of ['~/reviews/widget-pr-70 (review-widget)', '~/reviews/widget-pr-7-old (review-widget)', '~/reviews/widget-pr-7/sub (review-widget)', '~/reviews/wid...', '~/reviews/widget-pr-7 (review-widget) (other)', '~/reviews/widget-pr-7 review-widget', '~/reviews/widget-pr-7 (review widget)']) {
    refusal(() => emptyComposer(live(other), checkout), 'unknown_pi_footer');
  }
});

test('every Pi 1.5 footer variant of this checkout is recognized, nothing else is', () => {
  const accepted = [
    `${cwd}\n${stats}`, // not a git checkout: no branch
    `${cwd} (detached)\n${stats}`, // Pi's word for a detached HEAD
    `${cwd} (fix/a-b(1))\n${stats}`,
    `${cwd} (review-widget) • named session\n${stats}`,
    `${cwd} (review-widget)\n↑1.2k ↓300 $0.042 (sub) ?/200k  widget-model`, // context unknown, one provider
    `${cwd} (review-widget)\n↑1.2k ↓300 1.5%/128k  widget-model • thinking off`, // auto-compaction off
    `${cwd} (review-widget)\n0.0%/1.0M (auto)  (fixture-gate) widget-model → routed-model • high`,
    `${cwd} (review-widget)\n${stats}\nci: green inbox: 0 unread`, // one extension status line
  ];
  for (const footer of accepted) assert.equal(typeof emptyComposer(capture('', footer), cwd), 'string', footer);
  const unknown = [
    `${cwd}\n1k tokens (fixture) widget-model`, // no context usage: not Pi's stats line
    `${cwd} (review-widget)`, // no stats line
    `${cwd} (review-widget)\n${stats}\nci: green\nanother line`, // more than Pi renders
    `widget-model ${cwd}\n${stats}`,
    `${cwd}-other (review-widget)\n${stats}`,
  ];
  for (const footer of unknown) refusal(() => emptyComposer(capture('', footer), cwd), 'unknown_pi_footer');
  // A status line still says when something is under way.
  refusal(() => emptyComposer(capture('', `${cwd} (review-widget)\n${stats}\ninbox: 1 pending`), cwd), 'unsettled_terminal_tail', 'protected');
  // The stats line is Pi's own shape from its start - counters, then the
  // usage - not any line with a usage-like token in it: a 2-line footer whose
  // second line is an extension status is not Pi's stats line.
  for (const status of ['build running 40%/100', 'ci: 3/4 jobs 75%/100 (auto)', 'deploy 1.0%/1.0M (auto)  queued']) {
    refusal(() => emptyComposer(capture('', `${cwd} (review-widget)\n${status}`), cwd), 'unknown_pi_footer');
  }
  // What follows the usage is provider and model: a model named `*-thinking`
  // is no busy word, and an idle reviewer on one is still retired.
  for (const model of ['(fixture-gate) kimi-k2-thinking • medium', 'qwen3-235b-a22b-thinking • thinking off', 'fixture-thinking']) {
    assert.equal(typeof emptyComposer(capture('', `${cwd} (review-widget)\n23.4%/200k (auto)  ${model}`), cwd), 'string', model);
    assert.equal(typeof emptyComposer(capture('', `${cwd} (review-widget)\n23.4%/200k (auto)  ${model}\nci: green`), cwd), 'string', model);
  }
  refusal(() => emptyComposer(capture('', `${cwd} (review-widget)\n23.4%/200k (auto)  kimi-k2-thinking\nbuild running`), cwd), 'unsettled_terminal_tail', 'protected');
});

const protocolRequest = phase => ({ version: 1, type: 'cel-reviewer-retirement-request', phase, nonce: 'fixture-nonce', name: 'widget-pr-7-review', pid: 123, pid_start: '456', native_session: '/tmp/widget-session.jsonl', created_at: 1000, expires_at: 16000, ...(phase === 'exit' ? { expected_leaf: 'final' } : {}) });
const protocolResponse = request => ({ ...request, type: 'cel-reviewer-retirement-response', observed_at: 1001, status: request.phase === 'exit' ? 'exiting' : 'ready', reason: 'settled', live_leaf: 'final', is_idle: true, sdk_pending: false, native_turn_active: false, inbox_owed: false, inbox_pending: false, inbox_waking: false, composer_empty: true, exit_committed: request.phase === 'exit' });

test('native readiness requires every real debt flag even with an empty persisted inbox', () => {
  const request = protocolRequest('inspect');
  assert.equal(validateNativeResponse(protocolResponse(request), request, 1002).status, 'ready');
  for (const flag of ['sdk_pending', 'native_turn_active', 'inbox_owed', 'inbox_pending', 'inbox_waking']) {
    refusal(() => validateNativeResponse({ ...protocolResponse(request), [flag]: true }, request, 1002), 'native_retirement_work_owed', 'protected');
  }
  for (const field of ['inbox_pending', 'native_turn_active']) {
    const missing = protocolResponse(request); delete missing[field];
    refusal(() => validateNativeResponse(missing, request, 1002), 'incomplete_native_retirement_state');
  }
});

test('native readiness is nonce, generation, phase, and freshness bound', () => {
  const request = protocolRequest('inspect');
  for (const replacement of [{ nonce: 'other' }, { pid_start: '457' }, { phase: 'exit' }, { native_session: '/tmp/other.jsonl' }]) {
    refusal(() => validateNativeResponse({ ...protocolResponse(request), ...replacement }, request, 1002), 'native_response_identity_mismatch');
  }
  refusal(() => validateNativeResponse(protocolResponse(request), request, 16001), 'stale_native_retirement_response');
  refusal(() => validateNativeResponse({ ...protocolResponse(request), observed_at: 999 }, request, 1002), 'stale_native_retirement_response');
});

test('exit commitment requires the exact same actual live leaf and no new debt', () => {
  const request = protocolRequest('exit');
  assert.equal(validateNativeResponse(protocolResponse(request), request, 1002).exit_committed, true);
  refusal(() => validateNativeResponse({ ...protocolResponse(request), live_leaf: 'new-work' }, request, 1002), 'native_exit_leaf_or_commit_changed', 'protected');
  refusal(() => validateNativeResponse({ ...protocolResponse(request), exit_committed: false }, request, 1002), 'native_exit_leaf_or_commit_changed', 'protected');
  refusal(() => validateNativeResponse({ ...protocolResponse(request), sdk_pending: true }, request, 1002), 'native_retirement_work_owed', 'protected');
  refusal(() => validateNativeResponse({ ...protocolResponse(request), native_turn_active: true }, request, 1002), 'native_retirement_work_owed', 'protected');
});

test('prepared recovery needs a saved accepted exit bound to its ready inspection', () => {
  const request = protocolRequest('inspect'), response = protocolResponse(request);
  const preparedPath = '/tmp/widget-state/retirements/attempt.json';
  const prepared = { version: 1, stage: 'prepared', identity: { name: request.name, pid: request.pid, pid_start: request.pid_start, role: 'reviewer', agent: 'pi', backend: 'rex', agent_session: { value: request.native_session } }, native: { path: request.native_session, leaf: 'final' }, handshake: { inspect: { request, response } } };
  const exitRequest = { ...protocolRequest('exit'), created_at: 1002, expires_at: 16002 };
  const exit = { version: 1, stage: 'native-exit-committed', prepared: preparedPath, request: exitRequest, response: { ...protocolResponse(exitRequest), observed_at: 1003 } };
  assert.equal(validateExitCommitment(exit, preparedPath, prepared), exit);
  for (const mutation of [
    value => { value.prepared = '/tmp/other-attempt.json'; },
    value => { value.request.nonce = 'other-attempt'; },
    value => { value.response.exit_committed = false; },
    value => { value.response.native_turn_active = true; },
    value => { delete value.response.native_turn_active; },
    value => { value.response.observed_at = 0; },
    value => { value.response.observed_at = 16001; },
    value => { value.request.expected_leaf = 'other-branch'; },
  ]) {
    const invalid = structuredClone(exit); mutation(invalid);
    refusal(() => validateExitCommitment(invalid, preparedPath, prepared), 'native_exit_commitment_unavailable');
  }
  const noInspect = structuredClone(prepared); delete noInspect.handshake;
  refusal(() => validateExitCommitment(exit, preparedPath, noInspect), 'native_exit_commitment_unavailable');
});

test('only the verified watcher poll sleep may churn without rebinding stable infrastructure', () => {
  const launch = '/tmp/widget-launch', r = { name: 'widget-pr-7-review', workspace: '/tmp/widget-workspace' };
  const env = { CEL_REX_RECORD: '/tmp/widget-state/widget-pr-7-review.json', CEL_ROOT: launch, CEL_AGENT_NAME: r.name, CEL_ROLE: 'reviewer', CEL_WORKSPACE: r.workspace };
  const proc = (pid, ppid, pgrp, argv) => ({ pid, ppid, pgrp, start: String(1000 + pid), comm: path.basename(argv[0]), cwd, exe: `/usr/bin/${path.basename(argv[0])}`, argv, env });
  const watcherArgs = ['bash', `${launch}/bin/cel`, 'inbox', 'watch', '--parent', '100'];
  const tree = [proc(100, 1, 100, ['pi']), proc(200, 100, 200, watcherArgs), proc(201, 200, 200, watcherArgs), proc(202, 200, 200, ['tail', '-n', '0', '-F', '/tmp/widget-inbox.jsonl']), proc(203, 201, 200, ['sleep', '5'])];
  const original = validatedProcessEvidence(tree, r, [], launch);
  const churned = [...tree.slice(0, -1), proc(204, 201, 200, ['sleep', '5'])];
  assert.deepEqual(validatedProcessEvidence(churned, r, [], launch), original);
  assert.deepEqual(original.processes.map(p => p.pid), [100, 200, 201, 202]);
  assert.deepEqual(original.watcherGroups, [{ pgrp: 200, leader: 200, start: '1200' }]);
  refusal(() => validatedProcessEvidence([...tree.slice(0, -1), proc(204, 201, 200, ['sleep', '60'])], r, [], launch), 'unknown_watcher_child', 'protected');
  refusal(() => validatedProcessEvidence([...tree, proc(205, 100, 100, ['sleep', '5'])], r, [], launch), 'active_or_unknown_descendant', 'protected');
  refusal(() => validatedProcessEvidence([...tree, proc(206, 201, 200, ['node', 'build.mjs'])], r, [], launch), 'unknown_watcher_child', 'protected');
  const replacedPipe = [...tree.slice(0, 3), proc(207, 200, 200, ['tail', '-n', '0', '-F', '/tmp/widget-inbox.jsonl']), tree[4]];
  assert.notDeepEqual(validatedProcessEvidence(replacedPipe, r, [], launch), original);
});

test('a watcher whose tail or shell follows the exact parent is stable infrastructure; a foreign parent is not', () => {
  const launch = '/tmp/widget-launch', r = { name: 'widget-pr-7-review', workspace: '/tmp/widget-workspace' };
  const env = { CEL_REX_RECORD: '/tmp/widget-state/widget-pr-7-review.json', CEL_ROOT: launch, CEL_AGENT_NAME: r.name, CEL_ROLE: 'reviewer', CEL_WORKSPACE: r.workspace };
  const proc = (pid, ppid, pgrp, argv) => ({ pid, ppid, pgrp, start: String(1000 + pid), comm: path.basename(argv[0]), cwd, exe: `/usr/bin/${path.basename(argv[0])}`, argv, env });
  const watcherArgs = ['bash', `${launch}/bin/cel`, 'inbox', 'watch', '--parent', '100'];
  const tree = [proc(100, 1, 100, ['pi']), proc(200, 100, 200, watcherArgs), proc(202, 200, 200, ['tail', '-n', '0', '-F', '-s', '5', '--pid=100', '/tmp/widget-inbox.jsonl']), proc(203, 200, 200, watcherArgs)];
  const evidence = validatedProcessEvidence(tree, r, [], launch);
  assert.deepEqual(evidence.processes.map(p => p.pid), [100, 200, 202, 203]);
  assert.deepEqual(evidence.watcherGroups, [{ pgrp: 200, leader: 200, start: '1200' }]);
  for (const follow of [['-s', '5', '--pid=999'], ['-s', '9', '--pid=100'], ['--pid=100']]) {
    refusal(() => validatedProcessEvidence([...tree.slice(0, 2), proc(202, 200, 200, ['tail', '-n', '0', '-F', ...follow, '/tmp/widget-inbox.jsonl']), tree[3]], r, [], launch), 'unknown_watcher_child', 'protected');
  }
  // A tail without --pid: the watcher shell polls, and its sleep churns.
  const shellFollows = [tree[0], tree[1], proc(202, 200, 200, ['tail', '-n', '0', '-F', '/tmp/widget-inbox.jsonl']), tree[3], proc(204, 200, 200, ['sleep', '5'])];
  const polled = validatedProcessEvidence(shellFollows, r, [], launch);
  assert.deepEqual(polled.processes.map(p => p.pid), [100, 200, 202, 203]);
  assert.deepEqual(validatedProcessEvidence([...shellFollows.slice(0, -1), proc(205, 200, 200, ['sleep', '5'])], r, [], launch), polled);
  refusal(() => validatedProcessEvidence([...shellFollows.slice(0, -1), proc(205, 200, 200, ['sleep', '60'])], r, [], launch), 'unknown_watcher_child', 'protected');
});

// The pre-#285 `_INBOX_WATCH_JQ`, verbatim (v0.4.0 to main before #285): a
// watcher started then still runs it after its checkout is updated.
const PRE_285_WATCH_JQ = String.raw`
    foreach inputs as $l ({ws: "", m: null};
      if ($l | startswith("==> ")) then
        {ws: ($l | ltrimstr("==> ") | rtrimstr(" <==") | ltrimstr($dir) | rtrimstr(".jsonl")), m: null}
      else .m = (($l | fromjson?) // null) end;
      select(.m | type == "object") | .ws as $ws | .m
      | select(.kind != "resolution") | select(.to == $who or .to == "all")
      | [("w:" + $ws), .kind, .from, ((.message // "") | tostring | gsub("\n"; " "))] | @tsv)`;
const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const currentWatchJq = () => {
  const match = fs.readFileSync(path.join(repoRoot, 'lib/inbox.sh'), 'utf8').match(/^_INBOX_WATCH_JQ='([^']*)'$/m);
  assert.ok(match, 'lib/inbox.sh defines _INBOX_WATCH_JQ');
  return match[1];
};

test('a watcher still running an earlier release jq program is recognised; a modified program is not', () => {
  const launch = fs.mkdtempSync(path.join(os.tmpdir(), 'widget-launch-'));
  try {
    fs.mkdirSync(path.join(launch, 'lib'));
    fs.copyFileSync(path.join(repoRoot, 'lib/inbox.sh'), path.join(launch, 'lib/inbox.sh'));
    const r = { name: 'widget-pr-7-review', workspace: '/tmp/widget-workspace' };
    const env = { CEL_REX_RECORD: '/tmp/widget-state/widget-pr-7-review.json', CEL_ROOT: launch, CEL_AGENT_NAME: r.name, CEL_ROLE: 'reviewer', CEL_WORKSPACE: r.workspace };
    const proc = (pid, ppid, pgrp, argv) => ({ pid, ppid, pgrp, start: String(1000 + pid), comm: path.basename(argv[0]), cwd, exe: `/usr/bin/${path.basename(argv[0])}`, argv, env });
    const watcherArgs = ['bash', `${launch}/bin/cel`, 'inbox', 'watch', '--parent', '100'];
    const jq = program => proc(204, 200, 200, ['jq', '-nRr', '--unbuffered', '--arg', 'who', r.name, '--arg', 'dir', '/tmp/widget-inbox/', program]);
    const tree = program => [proc(100, 1, 100, ['pi']), proc(200, 100, 200, watcherArgs), proc(202, 200, 200, ['tail', '-n', '0', '-F', '-s', '5', '--pid=100', '/tmp/widget-inbox.jsonl']), proc(203, 200, 200, watcherArgs), jq(program)];
    assert.notEqual(currentWatchJq(), PRE_285_WATCH_JQ);
    for (const program of [currentWatchJq(), PRE_285_WATCH_JQ]) {
      assert.deepEqual(validatedProcessEvidence(tree(program), r, [], launch).processes.map(p => p.pid), [100, 200, 202, 203, 204]);
    }
    for (const modified of [PRE_285_WATCH_JQ.replace('.kind != "resolution"', '.kind != "status"'), `${PRE_285_WATCH_JQ} `, PRE_285_WATCH_JQ.slice(1), `${currentWatchJq()}\n`, '.']) {
      refusal(() => validatedProcessEvidence(tree(modified), r, [], launch), 'unknown_watcher_child', 'protected');
    }
  } finally { fs.rmSync(launch, { recursive: true, force: true }); }
});

test('every inbox watch program is listed by hash: the one lib/inbox.sh runs now and the pre-#285 one', () => {
  const hash = text => createHash('sha256').update(text).digest('hex');
  // Changing _INBOX_WATCH_JQ fails here until the new program's hash is added
  // to inbox-watch-programs.mjs (beside the old one, which stays).
  assert.ok(INBOX_WATCH_PROGRAMS.has(hash(currentWatchJq())), `add ${hash(currentWatchJq())} (lib/inbox.sh _INBOX_WATCH_JQ) to tools/reviewers/inbox-watch-programs.mjs`);
  assert.ok(INBOX_WATCH_PROGRAMS.has(hash(PRE_285_WATCH_JQ)));
  for (const entry of INBOX_WATCH_PROGRAMS) assert.match(entry, /^[0-9a-f]{64}$/);
});

test('Rex UI revisions and clients do not substitute for exact terminal topology', () => {
  const session = { session_id: 'widget-session', label: 'widget-reviewer', revision: 1, clients: [], windows: [{ window_id: 'window-1', layers: [{ blocks: [{ block_id: 'block-1' }] }] }] };
  assert.deepEqual(sessionTopology({ ...session, revision: 200, clients: [{ id: 'ui-client' }] }), sessionTopology(session));
  const extra = structuredClone(session); extra.windows[0].layers[0].blocks.push({ block_id: 'block-2' });
  assert.notDeepEqual(sessionTopology(extra), sessionTopology(session));
  const replacement = structuredClone(session); replacement.windows[0].window_id = 'other-window';
  assert.notDeepEqual(sessionTopology(replacement), sessionTopology(session));
});

test('durable verdict freshness follows only the exact selected own round', () => {
  const round = { verdict: 'approved', by: 'widget-pr-7-review', head: 'a'.repeat(40), at: at(3), note: 'Saved.' };
  const soloSelector = { kind: 'solo', key: 'widget#7' };
  const ledger = { 'widget#7': round, 'widget#99': { verdict: 'changes', by: 'other-reviewer' } };
  const original = selectedRound(ledger, soloSelector);
  assert.deepEqual(selectedRound({ ...ledger, 'widget#99': { verdict: 'approved', at: at(8) } }, soloSelector), original);
  assert.notEqual(selectedRound({ ...ledger, 'widget#7': { ...round, head: 'b'.repeat(40) } }, soloSelector).hash, original.hash);
  refusal(() => selectedRound([{ id: 'WG-7', review: round }], { kind: 'fleet', id: 'WG-7' }), 'unknown_solo_review_ledger');
});

test('only an approved round of the current head retires a reviewer; a changes round keeps it for re-review', () => {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), 'widget-rounds-'));
  try {
    const head = 'a'.repeat(40), r = { workspace: ws, repo: 'widget', pr: 7, name: 'widget-pr-7-review' }, pr = { headRefOid: head };
    fs.mkdirSync(path.join(ws, '.cel'), { mode: 0o700 });
    const file = path.join(ws, '.cel', 'solo-reviews.json');
    const save = (verdict) => { fs.rmSync(file, { force: true }); fs.writeFileSync(file,
      JSON.stringify({ 'widget#7': { verdict, by: r.name, head, at: at(3) } }), { mode: 0o600 }); };
    save('changes');
    refusal(() => durableRound(r, pr), 'no_completed_current_head_round');
    save('approved');
    assert.equal(durableRound(r, pr).round.verdict, 'approved');
  } finally { fs.rmSync(ws, { recursive: true, force: true }); }
});

test('an extra reviewer is retired by its own round in its own slot, never by the plain reviewer\'s', () => {
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), 'widget-rounds-'));
  try {
    const head = 'a'.repeat(40), pr = { headRefOid: head };
    const r = { workspace: ws, repo: 'widget', pr: 7, name: 'widget-pr-7-review-security' };
    fs.mkdirSync(path.join(ws, '.cel'), { mode: 0o700 });
    const file = path.join(ws, '.cel', 'solo-reviews.json');
    const save = (ledger) => { fs.rmSync(file, { force: true }); fs.writeFileSync(file, JSON.stringify(ledger), { mode: 0o600 }); };
    const plain = { verdict: 'approved', by: 'widget-pr-7-review', head, at: at(3) };
    save({ 'widget#7': plain, 'widget#70/review-security': { verdict: 'approved', by: r.name, head, at: at(3) } });
    refusal(() => durableRound(r, pr), 'no_completed_current_head_round');
    save({ 'widget#7': plain, 'widget#7/review-security': { verdict: 'approved', by: r.name, head, at: at(4) } });
    const own = durableRound(r, pr);
    assert.equal(own.selector.key, 'widget#7/review-security');
    assert.equal(durableRound({ ...r, name: 'widget-pr-7-review' }, pr).selector.key, 'widget#7');
  } finally { fs.rmSync(ws, { recursive: true, force: true }); }
});

test('archived role bytes remain verifiable after a later round rewrites the canonical role', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'widget-role-'));
  try {
    const filename = path.join(root, 'role-reviewer.md'), bytes = Buffer.from('Review widget exactly.\nPreserve café instructions.\n');
    fs.writeFileSync(filename, bytes, { mode: 0o600 });
    const role = { path: filename, hash: createHash('sha256').update(bytes).digest('hex'), size: bytes.length, encoding: 'base64', contentBase64: bytes.toString('base64') };
    fs.writeFileSync(filename, 'Different instructions for the next round.\n');
    assert.deepEqual(validateArchivedRole(role), bytes);
    fs.unlinkSync(filename);
    assert.deepEqual(validateArchivedRole(role), bytes);
    refusal(() => validateArchivedRole({ ...role, hash: '0'.repeat(64) }), 'archived_role_evidence_changed');
    refusal(() => validateArchivedRole({ ...role, contentBase64: '!'.repeat(role.contentBase64.length) }), 'archived_role_evidence_changed');
    const missing = { ...role }; delete missing.contentBase64;
    refusal(() => validateArchivedRole(missing), 'archived_role_evidence_unavailable');
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('private prepared evidence vetoes deletion without granting retirement', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'widget-retirement-'));
  try {
    const state = path.join(root, 'state'), directory = path.join(state, 'retirements');
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    fs.chmodSync(state, 0o700);
    const packet = { version: 1, stage: 'prepared', identity: { name: 'widget-pr-7-review', backend: 'rex', role: 'reviewer', agent: 'pi', cwd }, checkout: { path: cwd }, artifacts: { cwd }, receipt: { path: path.join(state, 'widget-pr-7-review.json') } };
    const filename = path.join(directory, 'prepared.json');
    fs.writeFileSync(filename, JSON.stringify(packet), { mode: 0o600 });
    assert.equal(checkoutPreserved(cwd, state), true);
    assert.equal(checkoutPreserved('/tmp/other-review', state), false);
    fs.chmodSync(filename, 0o666);
    assert.equal(checkoutPreserved(cwd, state), false);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('the gh handed the workspace token is the one the bash side passed, never an environment variable', () => {
  const saved = process.env.CEL_WS_GH_BIN;
  process.env.CEL_WS_GH_BIN = '/tmp/planted/gh';
  try {
    // no binary passed: refused, however the environment names one
    refusal(() => githubBinary(''), 'github_binary_unavailable');
    refusal(() => githubBinary(undefined), 'github_binary_unavailable');
    assert.equal(githubBinary('/usr/bin/gh'), '/usr/bin/gh');
    // and no code path reads it from the environment
    const source = fs.readFileSync(new URL('./retire.mjs', import.meta.url), 'utf8');
    assert.equal(source.includes('process.env.CEL_WS_GH_BIN'), false);
  } finally {
    if (saved === undefined) delete process.env.CEL_WS_GH_BIN; else process.env.CEL_WS_GH_BIN = saved;
  }
});

test('gh and the git it starts run on the tool path the bash side passed, never the caller\'s PATH', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'retire-gh-path-'));
  try {
    const planted = path.join(root, 'planted'), log = path.join(root, 'planted-git.log');
    fs.mkdirSync(planted);
    fs.writeFileSync(path.join(planted, 'git'), `#!/bin/sh\necho "planted git ran with GH_TOKEN=$GH_TOKEN" >> '${log}'\n`, { mode: 0o755 });
    // a gh that does what gh does: asks git, through PATH
    const gh = path.join(root, 'gh');
    fs.writeFileSync(gh, '#!/bin/sh\necho "pager=$GH_PAGER"\ngit --version >/dev/null 2>&1 && echo "git ran"\n', { mode: 0o755 });
    const toolPath = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
    const env = githubEnv(toolPath, 'synthetic-gh-token', { ...process.env, PATH: `${planted}:${process.env.PATH}`, GH_PAGER: 'less' });
    assert.equal(env.PATH, toolPath);
    assert.equal(env.GH_TOKEN, 'synthetic-gh-token');
    const result = spawnSync(gh, [], { encoding: 'utf8', env });
    assert.match(result.stdout, /pager=cat/);
    assert.match(result.stdout, /git ran/);
    assert.equal(fs.existsSync(log), false, 'the git first on the caller\'s PATH ran with the token');
    // no tool path passed: refused rather than falling back to the caller's
    refusal(() => githubEnv('', 'synthetic-gh-token'), 'github_tool_path_unavailable');
    assert.equal(githubEnv(toolPath, '').GH_TOKEN, undefined);
    // and every gh the retirement spawns is given that environment
    const source = fs.readFileSync(new URL('./retire.mjs', import.meta.url), 'utf8');
    const ghBody = source.slice(source.indexOf('const gh = () => {'), source.indexOf('const snapshot ='));
    assert.equal((ghBody.match(/env: githubEnv\(toolPath/g) || []).length, 2);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
