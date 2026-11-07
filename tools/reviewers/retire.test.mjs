import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { parseNative as parseNativeAtLeaf, emptyComposer, checkoutPreserved, validateNativeResponse, validateExitCommitment, validateArchivedRole, validatedProcessEvidence, sessionTopology, selectedRound, durableRound } from './retire.mjs';

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

const capture = (draft = '', footer = `${cwd}\n1k tokens (fixture) widget-model`) => {
  const content = `Review complete.\n────────────────────\n${draft}\n────────────────────\n${footer}\n`;
  return { content, eof: true, total: Buffer.byteLength(content) };
};

test('only a complete recognized Pi blank composer is eligible', () => {
  assert.equal(typeof emptyComposer(capture(), cwd), 'string');
  refusal(() => emptyComposer(capture('Please wait'), cwd), 'unsent_composer_draft', 'protected');
  refusal(() => emptyComposer({ ...capture(), eof: false }, cwd), 'incomplete_terminal_capture');
  refusal(() => emptyComposer({ ...capture(), total: 1 }, cwd), 'incomplete_terminal_capture');
  refusal(() => emptyComposer(capture('', '/another/checkout\n1k (fixture) widget-model'), cwd), 'unknown_pi_footer');
  refusal(() => emptyComposer(capture('', `${cwd}\n1k (fixture) widget-model\nCompacting`), cwd), 'unsettled_terminal_tail', 'protected');
  const modal = capture(); modal.content = 'Unknown modal'; modal.total = Buffer.byteLength(modal.content);
  refusal(() => emptyComposer(modal, cwd), 'unknown_composer_layout');
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
