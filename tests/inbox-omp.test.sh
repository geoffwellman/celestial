# shellcheck shell=bash
# CEL-65: the omp inbox hook delivers mail out of band (ui.notify) and drains
# it into the next turn exactly once - never through the composer. Driven by a
# faithful harness of omp's hook API (pi.on + before_agent_start's
# { message } return + session_shutdown), with the real `cel inbox` behind it.
HOOK="$CEL_ROOT/tools/hooks/inbox.omp.ts"

_omp_inbox_harness() { # <inbox-dir> -> prints JSON report
  CEL_INBOX_DIR="$1" CEL_INBOX_ME=widget-orch CEL_WORKSPACE=demo CEL_ROOT="$CEL_ROOT" \
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
