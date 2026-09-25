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
