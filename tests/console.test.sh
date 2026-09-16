# shellcheck shell=bash
# `cel console` - the plane's own TUI and the small model wired into its
# command line. Every assertion here drives a NON-INTERACTIVE mode: a suite
# that needed a terminal would be a suite nobody runs, so the TUI's three
# panels are rendered once to stdout and the translator is exercised against a
# stub HTTP server rather than a provider.
source "$CEL_ROOT/lib/common.sh"

CONSOLE_MJS="$CEL_ROOT/tools/console/console.mjs"

# A miniature box: a `cel` stand-in that answers the two reads the console
# makes, plus a mailbox directory. Never the live box - the console reads root
# mail, and a test that drained it would cost someone a decision.
_console_setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/inbox"

  cat >"$T/fleet.json" <<'EOF'
{"workspaces":[
 {"name":"alpha","root":{"unread":1,"open":1},"units":[
   {"name":"widget","orch":"LIVE","workers":1,"cap":4,"stalled":0,"unlanded":0}]},
 {"name":"beta","root":{"unread":0,"open":0},"units":[
   {"name":"gadget","orch":"-","workers":0,"cap":4,"stalled":0,"unlanded":0}]}]}
EOF

  printf '%s\n' \
    '{"id":"d1","ts":"2026-09-20T10:11:12+00:00","kind":"decision","from":"widget-orch","to":"root","message":"ship gadget or hold?"}' \
    >"$T/open.alpha.json"
  : >"$T/open.beta.json"

  printf '%s\n' \
    '{"id":"m1","ts":"2026-09-20T09:00:00+00:00","kind":"status","from":"widget-orch","to":"root","message":"first line"}' \
    '{"id":"m2","ts":"2026-09-20T09:30:00+00:00","kind":"status","from":"widget-orch","to":"root","message":"second line"}' \
    >"$T/inbox/alpha.jsonl"

  cat >"$T/bin/cel" <<EOF
#!/usr/bin/env bash
case "\$1" in
  fleet) cat "$T/fleet.json" ;;
  inbox)
    ws=""
    for a in "\$@"; do [ "\$prev" = --workspace ] && ws="\$a"; prev="\$a"; done
    cat "$T/open.\$ws.json" 2>/dev/null || true ;;
  *) printf 'ran: %s\n' "\$*" ;;
esac
EOF
  chmod +x "$T/bin/cel"
  export CEL_BIN="$T/bin/cel"
  export CEL_INBOX_DIR="$T/inbox"
  export CEL_CONSOLE_CONFIG="$T/config.yaml"
}

_console_teardown() { rm -rf "$T"; }

test_console_render_once_shows_fleet_decisions_and_inbox() {
  _console_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once)"
  assert_contains "$out" 'alpha'
  assert_contains "$out" 'beta'
  assert_contains "$out" 'widget'
  assert_contains "$out" 'gadget'
  assert_contains "$out" '[d1]'
  assert_contains "$out" 'ship gadget or hold?'
  assert_contains "$out" '[alpha]'
  assert_contains "$out" 'second line'
  _console_teardown
}

# ONE POLICY, TWO SURFACES. The refusal has to be the guard's, word for word,
# or the TUI and the agent console start disagreeing about what the console
# may do - and the one that is wrong is always the one nobody tested.
test_console_refuses_a_command_outside_the_allowlist() {
  _console_setup
  local out rc=0
  out="$(node "$CONSOLE_MJS" --render-once --run 'git commit -m x' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" 'the console routes; it does not build'
  assert_contains "$out" 'delegate it'
  _console_teardown
}

test_console_runs_an_allowlisted_command() {
  _console_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once --run 'cel fleet')"
  assert_contains "$out" 'alpha'
  _console_teardown
}

# --- the translator ---------------------------------------------------------

# A provider that is a file on disk: the console must be testable without a
# key, a network or anyone's credit.
#
# The stub is started with its stdout and stderr on a FILE and killed by a
# trap as well as by hand. On 2026-09-16 a stub that inherited the suite's
# stdout held the pipe open after the test returned: `tests/run.sh console |
# tail` never saw EOF and ran for nearly two hours against a server that had
# been reparented to init. A server outliving its test is a hung suite.
_console_stub_server() { # <reply-content>
  cat >"$T/stub.mjs" <<'EOF'
import { createServer } from 'node:http';
import { writeFileSync } from 'node:fs';
const s = createServer((req, res) => {
  let b = '';
  req.on('data', (c) => { b += c; });
  req.on('end', () => {
    writeFileSync(process.env.STUB_BODY_FILE, b);
    writeFileSync(process.env.STUB_HEADERS_FILE, JSON.stringify(req.headers));
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ choices: [{ message: { content: process.env.STUB_REPLY } }] }));
  });
});
s.listen(0, '127.0.0.1', () => {
  writeFileSync(process.env.STUB_PORT_FILE, String(s.address().port));
});
EOF
  export STUB_BODY_FILE="$T/body.json" STUB_HEADERS_FILE="$T/headers.json"
  export STUB_PORT_FILE="$T/port" STUB_REPLY="$1"
  rm -f "$STUB_PORT_FILE"
  node "$T/stub.mjs" >"$T/stub.log" 2>&1 </dev/null & STUB_PID=$!
  # shellcheck disable=SC2064
  trap "kill $STUB_PID 2>/dev/null || true" EXIT INT TERM
  local i=0
  while [ ! -s "$STUB_PORT_FILE" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$STUB_PORT_FILE" ] || { echo 'stub server never listened'; return 1; }
  export CEL_CONSOLE_PROVIDER_URL="http://127.0.0.1:$(cat "$STUB_PORT_FILE")"
}

_console_stub_stop() {
  [ -n "${STUB_PID:-}" ] || return 0
  kill "$STUB_PID" 2>/dev/null || true
  wait "$STUB_PID" 2>/dev/null || true
  STUB_PID=""
  trap - EXIT INT TERM
}

_console_config() { # [extra-line]
  { printf 'console:\n  provider: openrouter\n  model: alpha/model-mini\n  key_env: OPENROUTER_API_KEY\n'
    [ -n "${1:-}" ] && printf '  %s\n' "$1"; } >"$T/config.yaml"
  chmod 600 "$T/config.yaml"
}

test_console_translate_returns_one_command() {
  _console_setup
  _console_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'cel inbox read --for root --workspace alpha'
  local out
  out="$(node "$CONSOLE_MJS" --translate 'what is waiting on me in alpha')"
  assert_eq "$out" 'cel inbox read --for root --workspace alpha'
  _console_stub_stop
  _console_teardown
}

test_console_translate_rejects_prose() {
  _console_setup
  _console_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'I think you probably want to look at the fleet first.'
  local out rc=0
  out="$(node "$CONSOLE_MJS" --translate 'muse at me' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "couldn't translate"
  _console_stub_stop
  _console_teardown
}

# THE TUI MUST BE FULLY USEFUL WITH NO LLM AT ALL. A console that refused to
# start without a provider key would make the deterministic panels - the part
# that is always right - hostage to an optional convenience.
test_console_translate_without_config_says_so() {
  _console_setup
  local out rc=0
  out="$(node "$CONSOLE_MJS" --translate 'anything' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" 'no translator configured'
  assert_contains "$out" 'console.provider'
  # The panels still render without any translator at all.
  out="$(node "$CONSOLE_MJS" --render-once)"
  assert_contains "$out" 'alpha'
  _console_teardown
}

test_console_translate_request_carries_vocabulary_and_fleet() {
  _console_setup
  _console_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'cel fleet'
  node "$CONSOLE_MJS" --translate 'how is the box' >/dev/null
  local body
  body="$(cat "$T/body.json")"
  assert_contains "$body" 'cel-fanout status'
  assert_contains "$body" 'alpha'
  assert_contains "$body" 'how is the box'
  _console_stub_stop
  _console_teardown
}

test_console_key_from_env_beats_key_in_file() {
  _console_setup
  _console_config 'key: file-key'
  export OPENROUTER_API_KEY=env-key
  _console_stub_server 'cel fleet'
  node "$CONSOLE_MJS" --translate 'how is the box' >/dev/null
  local h
  h="$(cat "$T/headers.json")"
  assert_contains "$h" 'env-key'
  case "$h" in *file-key*) echo 'file key overrode the environment'; return 1;; esac
  _console_stub_stop
  _console_teardown
}

# A config file with a key in it is a credential file. 0600 or a warning: the
# quiet version of this is a key readable by every process on a shared box.
test_console_warns_about_a_world_readable_config() {
  _console_setup
  _console_config 'key: file-key'
  unset OPENROUTER_API_KEY
  chmod 644 "$T/config.yaml"
  _console_stub_server 'cel fleet'
  local err
  err="$(node "$CONSOLE_MJS" --translate 'how is the box' 2>&1 >/dev/null)"
  assert_contains "$err" 'chmod 600'
  _console_stub_stop
  _console_teardown
}

# --- the two consoles share one vocabulary ---------------------------------

test_console_vocabulary_is_shared_by_both_consoles() {
  source "$CEL_ROOT/lib/run.sh"
  local vocab body
  vocab="$(cat "$CEL_ROOT/tools/console/vocabulary.md")"
  assert_contains "$vocab" 'cel fleet'
  body="$(_run_console_body)"
  assert_contains "$body" 'cel-fanout status'
  # The role file must no longer carry its own copy of the table, or the two
  # consoles drift the first time someone edits one of them.
  case "$(cat "$CEL_ROOT/core/roles/console.md")" in
    *'cel-fanout status'*) echo 'role file still carries its own vocabulary table'; return 1;;
  esac
}

test_run_console_without_agent_points_at_cel_console() {
  local out rc=0
  out="$(bash "$CEL_ROOT/bin/cel" run console 2>&1)" || rc=$?
  assert_eq "$rc" 2
  assert_contains "$out" 'cel console'
}

test_run_console_agent_dry_run_still_launches() {
  local out
  out="$(bash "$CEL_ROOT/bin/cel" run console --agent --dry-run 2>&1)"
  assert_contains "$out" 'herdr agent start console'
}

test_cel_console_is_in_the_help() {
  local out
  out="$(bash "$CEL_ROOT/bin/cel" help)"
  assert_contains "$out" 'cel console'
}

# --- the ink dependencies --------------------------------------------------

# The TUI is ink, so it has node_modules - the first thing on this plane that
# does. A missing install must produce ONE line naming the fix, because the
# alternative is an ERR_MODULE_NOT_FOUND stack trace in front of an operator
# who has no reason to know the console is a React app.
test_console_deps_are_detected_and_the_fix_is_named() {
  source "$CEL_ROOT/lib/console.sh"
  local D; D="$(mktemp -d)"
  assert_fails console_deps_ok "$D"
  mkdir -p "$D/node_modules/ink"
  printf '{"name":"ink"}\n' >"$D/node_modules/ink/package.json"
  console_deps_ok "$D"
  assert_contains "$(console_deps_hint)" 'npm ci --ignore-scripts'
  rm -rf "$D"
}

test_console_refuses_to_start_without_its_deps() {
  local D out rc=0
  D="$(mktemp -d)"
  out="$(CEL_CONSOLE_TOOL_DIR="$D" bash "$CEL_ROOT/bin/cel" console 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" 'npm ci --ignore-scripts'
  rm -rf "$D"
}

test_doctor_reports_missing_console_deps() {
  source "$CEL_ROOT/lib/doctor.sh"
  local D out; D="$(mktemp -d)"
  out="$(CEL_CONSOLE_TOOL_DIR="$D" check_console_deps 2>&1 || true)"
  assert_contains "$out" 'npm ci --ignore-scripts'
  rm -rf "$D"
}

# A pinned lock file is the whole point of `npm ci`: without it the console's
# dependency tree is whatever npm resolved the day someone ran setup.
test_console_dependencies_are_pinned_and_committed() {
  [ -f "$CEL_ROOT/tools/console/package.json" ] || { echo 'no package.json'; return 1; }
  [ -f "$CEL_ROOT/tools/console/package-lock.json" ] || { echo 'no package-lock.json'; return 1; }
  git -C "$CEL_ROOT" ls-files --error-unmatch tools/console/package-lock.json >/dev/null
  assert_contains "$(cat "$CEL_ROOT/tools/console/package.json")" 'ink'
  # node_modules must never be committed.
  local tracked
  tracked="$(git -C "$CEL_ROOT" ls-files tools/console/node_modules | head -1)"
  assert_eq "$tracked" ''
}
