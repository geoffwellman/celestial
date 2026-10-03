# shellcheck shell=bash
# CEL-65: the omp inbox hook delivers mail out of band (ui.notify) and drains
# it into the next turn exactly once - never through the composer. Driven by a
# faithful harness of omp's hook API (pi.on + before_agent_start's
# { message } return + session_shutdown), with the real `cel inbox` behind it.
HOOK="$CEL_ROOT/tools/hooks/inbox.omp.ts"

_omp_inbox_harness() { # <inbox-dir> -> prints JSON report
  CEL_INBOX_DIR="$1" CEL_INBOX_ME=widget-orch CEL_INBOX_WS=demo CEL_ROOT="$CEL_ROOT" \
  CEL_WATCH_PARENT_POLL=1 HOOK="$HOOK" node --no-warnings - <<'JS'
const { execFileSync } = require('node:child_process');
(async () => {
  const handlers = {};
  const notes = [];
  const composer = { text: 'half-typed draft', submits: 0 };
  const pi = {
    on: (ev, fn) => { (handlers[ev] ||= []).push(fn); },
    sendUserMessage: () => { composer.submits++; },
    sendMessage: () => { composer.submits++; },
  };
  const ctx = {
    cwd: process.cwd(), hasUI: true,
    ui: {
      notify: (m, level) => notes.push({ m, level }),
      setEditorText: (t) => { composer.text = t; },
      pasteToEditor: (t) => { composer.text += t; },
    },
  };
  const fire = async (ev, e) => {
    let r; for (const fn of handlers[ev] || []) { const x = await fn({ type: ev, ...e }, ctx); if (x) r = x; } return r;
  };
  const mod = await import(process.env.HOOK);
  mod.default(pi);
  await fire('session_start', {});
  const send = (msg) => execFileSync('bash', [process.env.CEL_ROOT + '/bin/cel', 'inbox', 'send', 'widget-orch', msg, '--workspace', 'demo'], { stdio: 'ignore' });
  await new Promise((r) => setTimeout(r, 1200)); // tail -n 0 must be attached
  send('pick up WG-7 next');
  for (let i = 0; i < 50 && notes.length === 0; i++) await new Promise((r) => setTimeout(r, 100));
  const turn1 = await fire('before_agent_start', { prompt: 'hi', systemPrompt: [] });
  const turn2 = await fire('before_agent_start', { prompt: 'again', systemPrompt: [] });
  const pid = mod.__watcherPid && mod.__watcherPid();
  await fire('session_shutdown', {});
  await new Promise((r) => setTimeout(r, 500));
  let alive = false;
  if (pid) { try { process.kill(-pid, 0); alive = true; } catch {} }
  console.log(JSON.stringify({ notes, composer, turn1, turn2, pid, alive }));
  process.exit(0);
})().catch((e) => { console.log(JSON.stringify({ error: String(e && e.stack || e) })); process.exit(0); });
JS
}

test_omp_inbox_hook_notifies_drains_once_and_cleans_up() {
  command -v node >/dev/null || return 0
  local d; d="$(mktemp -d)"
  local out; out="$(_omp_inbox_harness "$d")"
  assert_eq "$(jq -r '.error // ""' <<<"$out")" ""
  # out of band: one notification naming the message, composer untouched
  assert_contains "$(jq -r '.notes[0].m' <<<"$out")" "pick up WG-7 next"
  assert_eq "$(jq -r '.composer.text' <<<"$out")" "half-typed draft"
  assert_eq "$(jq -r '.composer.submits' <<<"$out")" "0"
  # the next turn gets it as context, exactly once
  assert_contains "$(jq -r '.turn1.message.content' <<<"$out")" "pick up WG-7 next"
  assert_eq "$(jq -r '.turn2 // "none"' <<<"$out")" "none"
  # and the cursor moved: nothing is left unread for this reader
  assert_eq "$(CEL_INBOX_DIR="$d" "$CEL_ROOT/bin/cel" inbox count --for widget-orch --workspace demo)" "0"
  # shutdown took the whole watcher group with it
  [ "$(jq -r '.pid // ""' <<<"$out")" != "" ] || { echo "no watcher pid"; rm -rf "$d"; return 1; }
  assert_eq "$(jq -r '.alive' <<<"$out")" "false"
  rm -rf "$d"
}

# The guard's contract is unchanged by the inbox hook living beside it.
test_omp_guard_is_still_a_separate_fail_open_adapter() {
  ! grep -q "inbox" "$CEL_ROOT/tools/hooks/orchestrator-guard.omp.ts" || { echo "guard grew inbox logic"; return 1; }
}

# CEL-76: an idle orchestrator with an empty composer wakes itself for mail
# via pi.sendMessage({..}, {triggerTurn:true}); drafts/streaming stay notify-only.
_omp_wake_harness() { # <inbox-dir> <mode: idle|draft|streaming|burst|throws>
  CEL_INBOX_DIR="$1" MODE="$2" CEL_INBOX_ME=widget-orch CEL_INBOX_WS=demo CEL_ROOT="$CEL_ROOT" \
  CEL_WATCH_PARENT_POLL=1 CEL_INBOX_WAKE_MS=800 HOOK="$HOOK" node --no-warnings - <<'JS'
const { execFileSync } = require('node:child_process');
(async () => {
  const mode = process.env.MODE;
  const handlers = {}; const notes = []; const sent = [];
  const pi = { on: (ev, fn) => { (handlers[ev] ||= []).push(fn); },
    sendMessage: (m, o) => { sent.push({ m, o });
      if (mode === 'sendthrows' && sent.length === 1) throw new Error('boom');
      if (mode === 'sendrejects' && sent.length === 1) return Promise.reject(new Error('nope')); } };
  const ctx = { cwd: process.cwd(), hasUI: true,
    isIdle: () => { if (mode === 'throws') throw new Error('x'); return mode !== 'streaming'; },
    ui: { notify: (m, level) => notes.push({ m, level }),
      getEditorText: () => { if (mode === 'throws') throw new Error('y'); return mode === 'draft' ? 'draft' : '  '; } } };
  const fire = async (ev, e) => { let r; for (const fn of handlers[ev] || []) { const x = await fn({ type: ev, ...e }, ctx); if (x) r = x; } return r; };
  const mod = await import(process.env.HOOK);
  mod.default(pi);
  await fire('session_start', {});
  const send = (msg) => execFileSync('bash', [process.env.CEL_ROOT + '/bin/cel', 'inbox', 'send', 'widget-orch', msg, '--workspace', 'demo'], { stdio: 'ignore' });
  await new Promise((r) => setTimeout(r, 1200));
  const n = mode === 'burst' ? 3 : 1;
  for (let i = 0; i < n; i++) send('msg-' + i);
  for (let i = 0; i < 50 && notes.length < n; i++) await new Promise((r) => setTimeout(r, 100));
  await new Promise((r) => setTimeout(r, 1500)); // past the coalesce window
  const sentBefore = sent.length;
  if (mode === 'sendthrows' || mode === 'sendrejects') { send('msg-next'); await new Promise((r) => setTimeout(r, 2500)); }
  if (mode === 'burst') { send('msg-late'); await new Promise((r) => setTimeout(r, 2500)); } // turn still in flight
  const turn = await fire('before_agent_start', { prompt: 'hi', systemPrompt: [] });
  await fire('session_shutdown', {});
  console.log(JSON.stringify({ notes: notes.length, sentBefore, sent, turn: turn || null }));
  process.exit(0);
})().catch((e) => { console.log(JSON.stringify({ error: String(e && e.stack || e) })); process.exit(0); });
JS
}

_wake() { command -v node >/dev/null || return 1; local d; d="$(mktemp -d)"; _omp_wake_harness "$d" "$1"; rm -rf "$d"; }

test_omp_inbox_idle_empty_composer_wakes_once() {
  command -v node >/dev/null || return 0
  local out; out="$(_wake idle)"
  assert_eq "$(jq -r '.error // ""' <<<"$out")" ""
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "1"
  assert_eq "$(jq -r '.sent[0].o.triggerTurn' <<<"$out")" "true"
  assert_eq "$(jq -r '.sent[0].m.customType' <<<"$out")" "cel-inbox"
  assert_contains "$(jq -r '.sent[0].m.content' <<<"$out")" "msg-0"
  assert_eq "$(jq -r '.turn' <<<"$out")" "null"
}

test_omp_inbox_draft_is_notify_only() {
  command -v node >/dev/null || return 0
  local out; out="$(_wake draft)"
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "0"
  assert_eq "$(jq -r '.notes' <<<"$out")" "1"
  assert_contains "$(jq -r '.turn.message.content' <<<"$out")" "msg-0"
}

test_omp_inbox_streaming_is_notify_only() {
  command -v node >/dev/null || return 0
  local out; out="$(_wake streaming)"
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "0"
  assert_contains "$(jq -r '.turn.message.content' <<<"$out")" "msg-0"
}

test_omp_inbox_burst_coalesces_to_one_turn() {
  command -v node >/dev/null || return 0
  local out; out="$(_wake burst)"
  assert_eq "$(jq -r '.sentBefore' <<<"$out")" "1"
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "1"
  assert_contains "$(jq -r '.sent[0].m.content' <<<"$out")" "msg-2"
}

test_omp_inbox_ctx_throwing_falls_back_to_notify() {
  command -v node >/dev/null || return 0
  local out; out="$(_wake throws)"
  assert_eq "$(jq -r '.error // ""' <<<"$out")" ""
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "0"
  assert_contains "$(jq -r '.turn.message.content' <<<"$out")" "msg-0"
}

# CEL-76 review: a failed wake must not lose mail or wedge later wakes.
_assert_failed_send_keeps_mail() {
  local out; out="$(_wake "$1")"
  assert_eq "$(jq -r '.error // ""' <<<"$out")" ""
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "2"          # a later wake still happens
  assert_contains "$(jq -r '.sent[1].m.content' <<<"$out")" "msg-0" # and carries the lost mail
  assert_contains "$(jq -r '.sent[1].m.content' <<<"$out")" "msg-next"
}
test_omp_inbox_throwing_send_keeps_mail_and_rearms() { command -v node >/dev/null || return 0; _assert_failed_send_keeps_mail sendthrows; }
test_omp_inbox_rejecting_send_keeps_mail_and_rearms() { command -v node >/dev/null || return 0; _assert_failed_send_keeps_mail sendrejects; }

# CEL-85: mail that was ALREADY waiting when the session started never woke
# anyone - the watcher only reacts to new lines, so an orchestrator restarted
# onto an 85-message backlog sat on it until a human typed. session_start now
# arms the same coalesced wake new mail uses.
_omp_backlog_harness() { # <inbox-dir> <mode: idle|draft|none>
  CEL_INBOX_DIR="$1" MODE="$2" CEL_INBOX_ME=widget-orch CEL_INBOX_WS=demo CEL_ROOT="$CEL_ROOT" \
  CEL_WATCH_PARENT_POLL=1 CEL_INBOX_WAKE_MS=400 HOOK="$HOOK" node --no-warnings - <<'JS'
const { execFileSync } = require('node:child_process');
(async () => {
  const mode = process.env.MODE;
  const handlers = {}; const notes = []; const sent = [];
  const pi = { on: (ev, fn) => { (handlers[ev] ||= []).push(fn); }, sendMessage: (m, o) => { sent.push({ m, o }); } };
  const ctx = { cwd: process.cwd(), hasUI: true, isIdle: () => true,
    ui: { notify: (m, level) => notes.push({ m, level }),
      getEditorText: () => (mode === 'draft' ? 'half a thought' : '') } };
  const fire = async (ev, e) => { let r; for (const fn of handlers[ev] || []) { const x = await fn({ type: ev, ...e }, ctx); if (x) r = x; } return r; };
  const send = (msg) => execFileSync('bash', [process.env.CEL_ROOT + '/bin/cel', 'inbox', 'send', 'widget-orch', msg, '--workspace', 'demo'], { stdio: 'ignore' });
  if (mode !== 'none') { send('backlog-1'); send('backlog-2'); }
  const mod = await import(process.env.HOOK);
  mod.default(pi);
  await fire('session_start', {});
  await new Promise((r) => setTimeout(r, 2000));
  const turn = await fire('before_agent_start', { prompt: 'hi', systemPrompt: [] });
  await fire('session_shutdown', {});
  console.log(JSON.stringify({ notes, sent, turn: turn || null }));
  process.exit(0);
})().catch((e) => { console.log(JSON.stringify({ error: String(e && e.stack || e) })); process.exit(0); });
JS
}
_backlog() { local d; d="$(mktemp -d)"; _omp_backlog_harness "$d" "$1"; rm -rf "$d"; }

test_omp_inbox_backlog_at_start_wakes_idle_session_once() {
  command -v node >/dev/null || return 0
  local out; out="$(_backlog idle)"
  assert_eq "$(jq -r '.error // ""' <<<"$out")" ""
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "1"
  assert_eq "$(jq -r '.sent[0].o.triggerTurn' <<<"$out")" "true"
  assert_contains "$(jq -r '.sent[0].m.content' <<<"$out")" "backlog-1"
  assert_contains "$(jq -r '.sent[0].m.content' <<<"$out")" "backlog-2"
  assert_eq "$(jq -r '.turn' <<<"$out")" "null"
}

test_omp_inbox_backlog_with_a_draft_only_notifies() {
  command -v node >/dev/null || return 0
  local out; out="$(_backlog draft)"
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "0"
  assert_contains "$(jq -r '[.notes[].m]|join(" ")' <<<"$out")" "unread"
  assert_contains "$(jq -r '.turn.message.content' <<<"$out")" "backlog-1"
}

test_omp_inbox_no_backlog_no_wake() {
  command -v node >/dev/null || return 0
  local out; out="$(_backlog none)"
  assert_eq "$(jq -r '.error // ""' <<<"$out")" ""
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "0"
  assert_eq "$(jq -r '.notes|length' <<<"$out")" "0"
}

# CEL-inbox-delivery: an orchestrator with an explicit identity (CEL_INBOX_ME)
# is reached in EVERY registered workspace, not only the one its launch named,
# while other recipients' mail is never touched; a dead watcher is recovered
# and its downtime backlog delivered once; a wake withheld for a draft or an
# active turn is retried until it lands. One scenario harness, real `cel inbox`.
_omp_delivery_harness() { # <scenario> -> JSON report (env: D=inbox dir, REG=registry)
  CEL_INBOX_DIR="$D" CEL_REGISTRY="$REG/registry.yaml" SCENARIO="$1" \
  CEL_INBOX_ME=widget-orch CEL_INBOX_WS=alpha CEL_ROOT="$CEL_ROOT" \
  CEL_WATCH_PARENT_POLL=1 CEL_INBOX_WAKE_MS=300 CEL_INBOX_RETRY_MS=400 \
  CEL_INBOX_RESTART_MS=300 CEL_INBOX_WAKE_STUCK_MS=1500 HOOK="$HOOK" node --no-warnings - <<'JS'
const { execFileSync } = require('node:child_process');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const sc = process.env.SCENARIO;
  const handlers = {}; const notes = []; const sent = [];
  const st = { idle: true, draft: '' };
  if (sc === 'draft-then-clear') st.draft = 'half a thought';
  if (sc === 'busy-then-idle') st.idle = false;
  const pi = { on: (ev, fn) => { (handlers[ev] ||= []).push(fn); },
    sendMessage: (m, o) => { sent.push({ m, o }); } };
  const ctx = { cwd: process.cwd(), hasUI: true, isIdle: () => st.idle,
    ui: { notify: (m, level) => notes.push({ m, level }), getEditorText: () => st.draft,
      setEditorText: () => { throw new Error('composer touched'); } } };
  const fire = async (ev, e) => { let r; for (const fn of handlers[ev] || []) { const x = await fn({ type: ev, ...e }, ctx); if (x) r = x; } return r; };
  const cel = (...a) => execFileSync('bash', [process.env.CEL_ROOT + '/bin/cel', 'inbox', ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  const send = (to, msg, ws) => cel('send', to, msg, '--workspace', ws);
  const mod = await import(process.env.HOOK);
  mod.default(pi);
  await fire('session_start', {});
  await sleep(1500);
  const r = {};
  if (sc === 'cross-ws') {
    send('widget-orch', 'beta-for-me', 'beta');
    send('other-orch', 'beta-for-other', 'beta');
    send('root', 'beta-for-root', 'beta');
    await sleep(2000);
  } else if (sc === 'watcher-dies') {
    r.pid1 = mod.__watcherPid();
    process.kill(-r.pid1, 'SIGKILL');
    await sleep(50);
    send('widget-orch', 'during-downtime', 'beta');
    for (let i = 0; i < 40 && !(mod.__watcherPid() && mod.__watcherPid() !== r.pid1); i++) await sleep(100);
    r.pid2 = mod.__watcherPid();
    await sleep(2500);
    send('widget-orch', 'after-recovery', 'alpha');
    await sleep(2000);
  } else if (sc === 'draft-then-clear' || sc === 'busy-then-idle') {
    send('widget-orch', 'held-msg', 'alpha');
    await sleep(1500);
    r.sentWhileBlocked = sent.length;
    st.draft = ''; st.idle = true;
    await sleep(1500);
  } else if (sc === 'idle-backlog') {
    await sleep(2500);
  } else if (sc === 'no-agent-end') {
    send('widget-orch', 'first', 'alpha');
    await sleep(1200);           // woken; agent_end never arrives
    send('widget-orch', 'second', 'beta');
    await sleep(3000);           // past the stuck window
  }
  r.turn = (await fire('before_agent_start', { prompt: 'hi', systemPrompt: [] })) || null;
  const pid = mod.__watcherPid();
  await fire('session_shutdown', {});
  await sleep(400);
  r.alive = false; if (pid) { try { process.kill(-pid, 0); r.alive = true; } catch {} }
  r.otherUnread = cel('count', '--for', 'other-orch', '--workspace', 'beta');
  r.rootUnread = cel('count', '--for', 'root', '--workspace', 'beta');
  r.meUnread = cel('count', '--for', 'widget-orch', '--all-workspaces');
  console.log(JSON.stringify({ ...r, notes, sent }));
  process.exit(0);
})().catch((e) => { console.log(JSON.stringify({ error: String(e && e.stack || e) })); process.exit(0); });
JS
}
_delivery() {
  D="$(mktemp -d)"; REG="$(mktemp -d)"
  mkdir -p "$REG/alpha" "$REG/beta"
  printf 'workspaces:\n  alpha:\n    path: %s\n  beta:\n    path: %s\n' "$REG/alpha" "$REG/beta" > "$REG/registry.yaml"
  _omp_delivery_harness "$1"; rm -rf "$D" "$REG"
}
_sent_text() { jq -r '[.sent[].m.content]|join("\n")' <<<"$1"; }

test_omp_inbox_orch_gets_its_mail_from_another_workspace_only_its_own() {
  command -v node >/dev/null || return 0
  local out; out="$(_delivery cross-ws)"
  assert_eq "$(jq -r '.error // ""' <<<"$out")" ""
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "1"
  assert_contains "$(_sent_text "$out")" "beta-for-me"
  ! grep -q "beta-for-other\|beta-for-root" <<<"$(_sent_text "$out")" || { echo "read someone else's mail"; return 1; }
  assert_eq "$(jq -r '.otherUnread' <<<"$out")" "1"
  assert_eq "$(jq -r '.rootUnread' <<<"$out")" "1"
  assert_eq "$(jq -r '.meUnread' <<<"$out")" "0"
  assert_eq "$(jq -r '.alive' <<<"$out")" "false"
}

test_omp_inbox_dead_watcher_is_recovered_and_downtime_mail_lands_once() {
  command -v node >/dev/null || return 0
  local out; out="$(_delivery watcher-dies)"
  assert_eq "$(jq -r '.error // ""' <<<"$out")" ""
  [ "$(jq -r '.pid2 // ""' <<<"$out")" != "" ] || { echo "watcher not restarted"; return 1; }
  [ "$(jq -r '.pid1' <<<"$out")" != "$(jq -r '.pid2' <<<"$out")" ] || { echo "same pid"; return 1; }
  assert_eq "$(_sent_text "$out" | grep -c during-downtime)" "1"
  assert_eq "$(_sent_text "$out" | grep -c after-recovery)" "1"
  assert_eq "$(jq -r '.turn' <<<"$out")" "null"
  assert_eq "$(jq -r '.meUnread' <<<"$out")" "0"
  assert_eq "$(jq -r '.alive' <<<"$out")" "false"
}

_assert_held_then_delivered() {
  local out; out="$(_delivery "$1")"
  assert_eq "$(jq -r '.error // ""' <<<"$out")" ""
  assert_eq "$(jq -r '.sentWhileBlocked' <<<"$out")" "0"
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "1"
  assert_contains "$(_sent_text "$out")" "held-msg"
  assert_eq "$(jq -r '.turn' <<<"$out")" "null"
}
test_omp_inbox_wake_held_for_draft_lands_once_composer_clears() { command -v node >/dev/null || return 0; _assert_held_then_delivered draft-then-clear; }
test_omp_inbox_wake_held_for_active_turn_lands_once_idle() { command -v node >/dev/null || return 0; _assert_held_then_delivered busy-then-idle; }

test_omp_inbox_wake_without_agent_end_does_not_strand_later_mail() {
  command -v node >/dev/null || return 0
  local out; out="$(_delivery no-agent-end)"
  assert_eq "$(jq -r '.error // ""' <<<"$out")" ""
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "2"
  assert_contains "$(jq -r '.sent[1].m.content' <<<"$out")" "second"
}

# The CLI half: --workspace beside --all-workspaces adds that mailbox to the
# sweep (it used to be ignored), so a launch workspace missing from the
# registry is still read. Without --workspace nothing changes.
test_inbox_all_workspaces_with_workspace_includes_an_unregistered_one() {
  D="$(mktemp -d)"; REG="$(mktemp -d)"; mkdir -p "$REG/alpha"
  printf 'workspaces:\n  alpha:\n    path: %s\n' "$REG/alpha" > "$REG/registry.yaml"
  local c="$CEL_ROOT/bin/cel"
  CEL_INBOX_DIR="$D" CEL_REGISTRY="$REG/registry.yaml" "$c" inbox send me x1 --workspace alpha >/dev/null 2>&1
  CEL_INBOX_DIR="$D" CEL_REGISTRY="$REG/registry.yaml" "$c" inbox send me x2 --workspace loose >/dev/null 2>&1
  assert_eq "$(CEL_INBOX_DIR="$D" CEL_REGISTRY="$REG/registry.yaml" "$c" inbox count --for me --all-workspaces 2>/dev/null)" "1"
  assert_eq "$(CEL_INBOX_DIR="$D" CEL_REGISTRY="$REG/registry.yaml" "$c" inbox count --for me --all-workspaces --workspace loose 2>/dev/null)" "2"
  assert_eq "$(CEL_INBOX_DIR="$D" CEL_REGISTRY="$REG/registry.yaml" "$c" inbox count --for me --all-workspaces --workspace alpha 2>/dev/null)" "1"
  local out; out="$(CEL_INBOX_DIR="$D" CEL_REGISTRY="$REG/registry.yaml" CEL_INBOX_ME=me "$c" inbox read --all-workspaces --workspace loose 2>/dev/null)"
  assert_contains "$out" "[loose]"; assert_contains "$out" "[alpha]"
  rm -rf "$D" "$REG"
}

# Review note on PR #113: a drain that FAILS (timeout, transient error) is not
# a drain that found nothing. It must leave the mail owed so the retry timer
# delivers it, rather than waiting for the next unrelated event.
test_omp_inbox_failed_drain_keeps_mail_owed_and_retries() {
  command -v node >/dev/null || return 0
  local T; T="$(mktemp -d)"; mkdir -p "$T/root/bin"
  cat > "$T/root/bin/cel" <<SH
if [ "\$2" = read ] && [ -f "$T/fail" ]; then rm -f "$T/fail"; exit 1; fi
exec bash "$CEL_ROOT/bin/cel" "\$@"
SH
  D="$T/inbox"; REG="$T/reg"; mkdir -p "$D" "$REG/alpha" "$REG/beta"
  printf 'workspaces:\n  alpha:\n    path: %s\n  beta:\n    path: %s\n' "$REG/alpha" "$REG/beta" > "$REG/registry.yaml"
  CEL_INBOX_DIR="$D" CEL_INBOX_ME=widget-orch CEL_INBOX_WS=alpha bash "$CEL_ROOT/bin/cel" inbox send widget-orch flaky-msg --workspace alpha >/dev/null 2>&1
  touch "$T/fail"
  local out; out="$(CEL_ROOT="$T/root" _omp_delivery_harness idle-backlog)"
  rm -rf "$T"
  assert_eq "$(jq -r '.error // ""' <<<"$out")" ""
  assert_eq "$(jq -r '.sent|length' <<<"$out")" "1"
  assert_contains "$(jq -r '.sent[0].m.content' <<<"$out")" "flaky-msg"
  assert_eq "$(jq -r '.turn' <<<"$out")" "null"
}
