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
  out="$(node "$CONSOLE_MJS" --ask 'what is waiting on me in alpha')"
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
  out="$(node "$CONSOLE_MJS" --ask 'muse at me' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" 'no command for that'
  assert_contains "$out" 'model said: I think you probably want' 
  _console_stub_stop
  _console_teardown
}

# THE TUI MUST BE FULLY USEFUL WITH NO LLM AT ALL. A console that refused to
# start without a provider key would make the deterministic panels - the part
# that is always right - hostage to an optional convenience.
test_console_translate_without_config_says_so() {
  _console_setup
  local out rc=0
  out="$(node "$CONSOLE_MJS" --ask 'anything' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" 'no model configured'
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
  node "$CONSOLE_MJS" --ask 'how is the box' >/dev/null
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
  node "$CONSOLE_MJS" --ask 'how is the box' >/dev/null
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
  err="$(node "$CONSOLE_MJS" --ask 'how is the box' 2>&1 >/dev/null)"
  assert_contains "$err" 'chmod 600'
  _console_stub_stop
  _console_teardown
}

# After a sentence's commands run, the model answers the sentence from what
# they printed - it reads output, never runs anything. The request carries the
# transcript; the reply is returned verbatim; console.answer: off disables it.
test_console_answer_reads_the_transcript() {
  _console_setup
  _console_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'bundle has one worker on ABC-1 and nothing waiting.'
  local out
  out="$(cd "$CEL_ROOT" && node --input-type=module -e "
    import { answer } from './tools/console/translate.mjs';
    const a = await answer({ sentence: 'what is happening with bundle', transcript: '\$ cel fleet\nbundle orch LIVE workers 1/4' });
    process.stdout.write(a);
  ")"
  assert_eq "$out" 'bundle has one worker on ABC-1 and nothing waiting.'
  assert_contains "$(cat "$STUB_BODY_FILE")" 'what is happening with bundle'
  assert_contains "$(cat "$STUB_BODY_FILE")" 'workers 1/4'
  _console_stub_stop
  _console_config 'answer: off'
  out="$(cd "$CEL_ROOT" && node --input-type=module -e "
    import { answer } from './tools/console/translate.mjs';
    const a = await answer({ sentence: 'x', transcript: 'y' });
    process.stdout.write(String(a));
  ")"
  assert_eq "$out" 'null'
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

# --- v2: mouse, line editing, options and chains ---------------------------

# The mouse parser and the hit map are PURE on purpose: a terminal that has to
# be driven by hand to prove a click lands on the right row is a thing nobody
# proves, and "off by one row" is the whole failure mode of a hit map.
test_console_mouse_parser_and_hit_test_are_proved() {
  node "$CEL_ROOT/tools/console/mouse.test.mjs"
}

# The command line edits like a shell, and the history walk filters by prefix.
# Both are pure functions for the same reason as the mouse: keystroke behaviour
# nobody can assert is keystroke behaviour that regresses in silence.
test_console_line_editor_and_history_walk_are_proved() {
  node "$CEL_ROOT/tools/console/edit.test.mjs"
}

# A MISS IS NOT A DEAD END. "no command for that" told the operator nothing
# they did not already know; the second ask returns candidates with reasons and
# the operator picks one, which is what a person expects of a thing that failed
# to understand them.
test_console_ask_offers_numbered_options_on_a_miss() {
  _console_setup
  _console_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'cel inbox open --for root --workspace alpha -- see what is open first
cel fleet -- the whole box at a glance
cel-fanout status --workspace alpha -- what is in flight there'
  local out rc=0
  out="$(node "$CONSOLE_MJS" --ask 'sort out alpha' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" '1  cel inbox open --for root --workspace alpha'
  assert_contains "$out" 'see what is open first'
  assert_contains "$out" '2  cel fleet'
  assert_contains "$out" '3  cel-fanout status --workspace alpha'
  _console_stub_stop
  _console_teardown
}

# One sentence can be a SEQUENCE. "clean the blockers on alpha" is a read and
# then a resolve; a translator that can only ever return one line makes the
# operator type the second half themselves.
test_console_ask_returns_a_chain_of_commands() {
  _console_setup
  _console_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'cel inbox open --for root --workspace alpha
cel inbox resolve --all --from widget-orch --workspace alpha'
  local out rc=0
  out="$(node "$CONSOLE_MJS" --ask 'clean the blockers on alpha')" || rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" 'cel inbox open --for root --workspace alpha'
  assert_contains "$out" 'cel inbox resolve --all --from widget-orch --workspace alpha'
  _console_stub_stop
  _console_teardown
}

# The response line used to overwrite the key legend and never clear, so the
# operator lost their bindings to a message from four minutes ago. Two lines,
# always: the transient one and the permanent one.
test_console_render_once_keeps_status_and_legend_apart() {
  _console_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once --status 'hello')"
  assert_contains "$out" 'hello'
  assert_contains "$out" '? help'
  local sline lline
  sline="$(printf '%s\n' "$out" | grep -n 'hello' | head -1 | cut -d: -f1)"
  lline="$(printf '%s\n' "$out" | grep -n '? help' | head -1 | cut -d: -f1)"
  [ "$sline" != "$lline" ] || { echo 'status and legend share a line'; return 1; }
  _console_teardown
}

# History is the operator's own record of what they typed. A --run that did not
# append it would make the console's history depend on which entry point ran
# the command.
test_console_run_appends_to_history() {
  _console_setup
  export CEL_CONSOLE_HISTORY="$T/history"
  node "$CONSOLE_MJS" --run 'cel fleet' >/dev/null
  assert_contains "$(cat "$T/history")" 'cel fleet'
  _console_teardown
}

# --- full screen -----------------------------------------------------------

# The console runs on the alternate screen, like htop or vim: it fills the
# terminal, nothing it draws lands in the scrollback, and quitting gives the
# operator back the screen they had. The enter/leave pairs are proved by a unit
# test because the failure mode - leaving on one exit path and not another - is
# a terminal the owner has to reset by hand.
test_console_terminal_mode_pairs_are_proved() {
  node "$CEL_ROOT/tools/console/term.test.mjs"
}

# --render-once is PLAIN STDOUT. It is what an operator pipes into a file when
# the full-screen UI is the last thing they want, and an alternate-screen
# switch in the middle of that file would be the UI following them into it.
test_console_render_once_never_switches_screens() {
  _console_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once)"
  case "$out" in *$'\033[?1049'*) echo 'render-once switched to the alternate screen'; return 1;; esac
  assert_contains "$out" 'alpha'
  _console_teardown
}

# Since CEL-14 a unit is a PRODUCT, which may carry several repos. The console
# said "(2 repos)" for two products and showed a declared product under its
# bare name, which is the one place an operator cannot tell a product from the
# repo it happens to share a name with.
test_console_counts_products_and_names_their_repos() {
  _console_setup
  cat >"$T/fleet.json" <<'EOF'
{"workspaces":[
 {"name":"alpha","root":{"unread":1,"open":1},"units":[
   {"name":"widget","orch":"LIVE","workers":1,"cap":4,"stalled":0,"unlanded":0,
    "repos":["widget-core","widget-web"],"declared":true},
   {"name":"gadget","orch":"-","workers":0,"cap":4,"stalled":0,"unlanded":0,
    "repos":["gadget"],"declared":false}]}]}
EOF
  local out
  out="$(node "$CONSOLE_MJS" --render-once)"
  assert_contains "$out" '(2 products)'
  assert_contains "$out" 'widget (widget-core, widget-web)'
  case "$out" in *'repos)'*) echo 'the head line still counts repos'; return 1;; esac
  # An undeclared unit is still just its name - a repo dressed up as a product
  # with "(gadget)" after it is noise.
  case "$out" in *'gadget (gadget)'*) echo 'an undeclared unit got a repo list'; return 1;; esac
  _console_teardown
}

# A CHAIN IS CHECKED WHOLE, THEN RUN. Validating each line as it came up meant a
# chain whose second line the guard refuses had already run its first: the
# operator pressed Enter on a proposal they were told would be checked, and got
# half of it plus a refusal. Nothing runs until every line is allowed.
test_console_chain_runs_nothing_when_a_later_line_is_denied() {
  _console_setup
  local ran="$T/ran.log"
  cat >"$T/bin/cel" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$ran"
case "\$1" in
  fleet) cat "$T/fleet.json" ;;
  inbox) cat "$T/open.alpha.json" 2>/dev/null || true ;;
  *) printf 'ran: %s\n' "\$*" ;;
esac
EOF
  chmod +x "$T/bin/cel"
  # The chain runs through `bash -c`, so the stub has to be on PATH as well as
  # in CEL_BIN - otherwise the test drives the live box.
  PATH="$T/bin:$PATH"
  local out rc=0
  out="$(node "$CONSOLE_MJS" --chain 'cel fleet' --chain 'git commit -m x' 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" 'refused'
  assert_contains "$out" 'git commit -m x'
  [ ! -s "$ran" ] || { echo "the chain ran something before it was refused: $(cat "$ran")"; return 1; }
  _console_teardown
}

test_console_chain_runs_its_lines_in_order() {
  _console_setup
  PATH="$T/bin:$PATH"
  local out
  out="$(node "$CONSOLE_MJS" --chain 'cel fleet' --chain 'cel inbox open --for root --workspace alpha')"
  assert_contains "$out" 'alpha'
  assert_contains "$out" 'ship gadget or hold?'
  _console_teardown
}

# --- CEL-20: depth ---------------------------------------------------------

# A box with WORKERS in it. CEL-19's `workers_list` is the frozen contract the
# console is written against: until it lands the shape comes from this stub,
# which is the same thing the console will read from `cel fleet --json`.
_console_depth_setup() {
  _console_setup
  cat >"$T/fleet.json" <<'EOF'
{"workspaces":[
 {"name":"alpha","root":{"unread":1,"open":1},"units":[
   {"name":"bundle","orch":"LIVE","pane":"w1:p0","workers":2,"cap":4,"stalled":1,"unlanded":0,
    "repos":["widget","gadget"],"declared":true,
    "workers_list":[
      {"id":"ABC-49-slug","ticket":"ABC-49","repo":"widget","branch":"ABC-49-slug","shape":"ship",
       "state":"running","live":"idle","quiet_secs":812,"verdict":"stalled","severity":"warn",
       "ahead":"3","pr":"https://example.invalid/widget/pull/12","alias":"widget/ABC-49-slug","pane":"w3:p1"},
      {"id":"ABC-50-other","ticket":"ABC-50","repo":"gadget","branch":"ABC-50-other","shape":"ship",
       "state":"running","live":"working","quiet_secs":10,"verdict":"","severity":"",
       "ahead":"0","pr":"","alias":"gadget/ABC-50-other","pane":"w3:p2"}]}]}]}
EOF
  printf '%s\n' \
    '{"id":"d1","ts":"2026-09-20T10:11:12+00:00","kind":"decision","from":"bundle-orch","to":"root","message":"ship gadget or hold?"}' \
    >"$T/open.alpha.json"
  printf '%s\n' \
    '{"id":"m1","ts":"2026-09-20T09:00:00+00:00","kind":"status","from":"bundle-orch","to":"root","message":"first line"}' \
    >"$T/inbox/alpha.jsonl"

  cat >"$T/bin/cel-fanout" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  why) printf '%s\n' \
        "$2 (ABC-49, widget) - running, agent idle, stalled (warn)" \
        "quiet for 13m, work at risk, branch not pushed" \
        "pane, last 25 lines:" \
        "  waiting for review" \
        "mail from it, last 5:" \
        "  asked a question" \
        "pr: open, review pending" \
        "next: prompt it to commit and push, or collect" ;;
  *) printf 'ran: %s\n' "$*" ;;
esac
EOF
  chmod +x "$T/bin/cel-fanout"
  export CEL_FANOUT_BIN="$T/bin/cel-fanout"
}

# THE UNIT VIEW IS THE ANSWER TO "what is going on with bundle". Before it, a
# fleet row said "workers 2/4 stalled 1" and every follow-up question meant
# leaving the console.
test_console_render_once_unit_shows_orchestrator_workers_and_mail() {
  _console_depth_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once --unit bundle)"
  assert_contains "$out" 'UNIT bundle'
  assert_contains "$out" 'ORCHESTRATOR'
  assert_contains "$out" 'bundle-orch'
  assert_contains "$out" 'w1:p0'
  assert_contains "$out" 'WORKERS'
  assert_contains "$out" 'ABC-49'
  assert_contains "$out" 'ticket    worker'
  assert_contains "$out" 'ABC-50'
  assert_contains "$out" '13m'
  assert_contains "$out" 'stalled'
  assert_contains "$out" '#12'
  assert_contains "$out" 'WAITING'
  assert_contains "$out" 'ship gadget or hold?'
  assert_contains "$out" 'RECENT MAIL'
  assert_contains "$out" 'first line'
  _console_teardown
}

test_console_render_once_unit_that_does_not_exist_says_so() {
  _console_depth_setup
  local out rc=0
  out="$(node "$CONSOLE_MJS" --render-once --unit nosuch 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" 'nosuch'
  _console_teardown
}

# THE WORKER VIEW IS THE ANSWER TO "why". It runs `cel-fanout why` on open and
# shows what it said, because telling the operator to go and run the command
# themselves is what the console did before and it is what they complained of.
test_console_render_once_worker_runs_why_and_shows_it() {
  _console_depth_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once --worker ABC-49-slug)"
  assert_contains "$out" 'WORKER ABC-49-slug'
  assert_contains "$out" 'ABC-49'
  assert_contains "$out" 'widget'
  assert_contains "$out" 'next: prompt it to commit and push, or collect'
  assert_contains "$out" '[prompt]'
  assert_contains "$out" '[collect]'
  assert_contains "$out" '[release]'
  assert_contains "$out" '[why again]'
  _console_teardown
}

test_console_render_once_worker_that_does_not_exist_says_so() {
  _console_depth_setup
  local out rc=0
  out="$(node "$CONSOLE_MJS" --render-once --worker ABC-99-ghost 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" 'ABC-99-ghost'
  _console_teardown
}

# NO RAW JSON, EVER. The console knows the shape of everything it runs, so an
# operator who clicked a row got a box of braces for no reason at all.
test_console_output_rendering_is_proved() {
  node "$CEL_ROOT/tools/console/views.test.mjs"
}

# THE MODEL ANSWERS FROM STATE. "which workers are idle" is in the state the
# console already sends; running three commands to re-learn it is the console
# handing the operator homework.
test_console_ask_can_answer_from_state_without_running_anything() {
  _console_depth_setup
  _console_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'ANSWER: two workers are idle'
  local out rc=0
  out="$(node "$CONSOLE_MJS" --ask 'which workers are idle')" || rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" 'two workers are idle'
  case "$out" in *'ANSWER:'*) echo 'the reply form leaked into the answer'; return 1;; esac
  _console_stub_stop
  _console_teardown
}

# The state the model is asked from must carry the workers, or every question
# about one of them comes back as a command to go and look.
test_console_ask_state_carries_the_workers_list() {
  _console_depth_setup
  _console_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'ANSWER: nothing is stalled'
  node "$CONSOLE_MJS" --ask 'which workers are idle' >/dev/null
  local body
  body="$(cat "$T/body.json")"
  assert_contains "$body" 'workers_list'
  assert_contains "$body" 'ABC-49-slug'
  assert_contains "$body" 'ship gadget or hold?'
  _console_stub_stop
  _console_teardown
}

# Every view's own actions are in its own legend, or they are bindings nobody
# can discover - which is the same as not having them.
test_console_legends_name_the_depth_views() {
  local out
  out="$(node --input-type=module -e "
    import { legend, helpLines } from '$CEL_ROOT/tools/console/legend.mjs';
    process.stdout.write([legend('unit'), legend('worker'), legend('inbox'), helpLines().join('\n')].join('\n'));
  ")"
  assert_contains "$out" 'f focus'
  assert_contains "$out" 'm message'
  assert_contains "$out" 'p prompt'
  assert_contains "$out" 'c collect'
  assert_contains "$out" 'x release'
  assert_contains "$out" 'w why'
  assert_contains "$out" 'Enter'
}

# --- CEL-22: memory --------------------------------------------------------
# "how are we monitoring memory for the workers and can that be visualised in
# the console too?" - the owner, 2026-09-18. The console reads the same
# `cel fleet --json` every other answer comes from, so the fixture carries the
# `box` block and the per-tree numbers CEL-22 added to it.
_console_memory_setup() {
  _console_depth_setup
  cat >"$T/fleet.json" <<'EOF'
{"box":{"total_mb":24576,"available_mb":7065,"used_pct":71,"agents_rss_mb":4200},
 "workspaces":[
 {"name":"alpha","root":{"unread":1,"open":1},"units":[
   {"name":"bundle","orch":"LIVE","pane":"w1:p0","workers":2,"cap":4,"stalled":1,"unlanded":0,
    "rss_mb":710,"orch_rss_mb":430,
    "repos":["widget","gadget"],"declared":true,
    "workers_list":[
      {"id":"ABC-49-slug","ticket":"ABC-49","repo":"widget","branch":"ABC-49-slug","shape":"ship",
       "state":"running","live":"idle","quiet_secs":812,"verdict":"stalled","severity":"warn",
       "ahead":"3","pr":"https://example.invalid/widget/pull/12","alias":"widget/ABC-49-slug",
       "pane":"w3:p1","rss_mb":370},
      {"id":"ABC-50-other","ticket":"ABC-50","repo":"gadget","branch":"ABC-50-other","shape":"ship",
       "state":"running","live":"working","quiet_secs":10,"verdict":"","severity":"",
       "ahead":"0","pr":"","alias":"gadget/ABC-50-other","pane":"w3:p2","rss_mb":340}]}]}]}
EOF
}

# THE FLEET ROW AND THE STATUS EDGE. A unit's footprint belongs beside its
# worker count - the two numbers an operator weighs against each other before
# delegating another one - and the box's headroom belongs where nothing else
# competes for it.
test_console_render_once_shows_memory_per_unit_and_the_boxs_headroom() {
  _console_memory_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once)"
  assert_contains "$out" 'mem 710M'
  assert_contains "$out" 'mem 6.9G free'
  _console_teardown
}

# A box with no `box` block (an older cel on PATH) must render, not crash: the
# console is the thing an operator opens when something is already wrong.
test_console_render_once_survives_a_fleet_without_memory() {
  _console_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once)"
  assert_contains "$out" 'alpha'
  case "$out" in *'mem undefined'*|*'mem NaN'*) echo 'missing memory rendered as a number'; return 1;; esac
  _console_teardown
}

test_console_render_once_unit_shows_a_footprint_per_worker() {
  _console_memory_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once --unit bundle)"
  assert_contains "$out" '370M'
  assert_contains "$out" '340M'
  _console_teardown
}

test_console_render_once_worker_facts_carry_its_footprint() {
  _console_memory_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once --worker ABC-49-slug)"
  assert_contains "$out" 'WORKER ABC-49-slug'
  assert_contains "$out" '370M'
  _console_teardown
}

# The legend is where a binding is discovered; one that is not in it is a
# binding nobody will ever press.
test_console_unit_legend_names_the_memory_sort() {
  local out
  out="$(node --input-type=module -e "
    import { legend, helpLines } from '$CEL_ROOT/tools/console/legend.mjs';
    process.stdout.write([legend('unit'), helpLines().join('\n')].join('\n'));
  ")"
  assert_contains "$out" 's mem'
}

# --- CEL-23: the decision router -------------------------------------------

# A DECISION model, not a chat one: it does not write the command line, it
# picks one label out of ten and the console fills the slots itself. The stub
# is the same pattern as the chat one - a file on disk answering HTTP - but it
# answers the decisions shape, and it runs BESIDE the chat stub so a test can
# prove which of the two was asked.
_console_router_stub() { # <intent> <confidence> [probabilities-json] [status]
  cat >"$T/rstub.mjs" <<'EOF'
import { createServer } from 'node:http';
import { writeFileSync, appendFileSync } from 'node:fs';
const s = createServer((req, res) => {
  let b = '';
  req.on('data', (c) => { b += c; });
  req.on('end', () => {
    writeFileSync(process.env.RSTUB_BODY_FILE, b);
    writeFileSync(process.env.RSTUB_HEADERS_FILE, JSON.stringify(req.headers));
    const code = Number(process.env.RSTUB_STATUS || '200');
    if (code !== 200) { res.writeHead(code, { 'content-type': 'text/plain' }); res.end('nope'); return; }
    const probs = process.env.RSTUB_PROBS ? JSON.parse(process.env.RSTUB_PROBS) : undefined;
    // CEL-41: one request carries every question, so the stub counts the
    // requests it was sent - a second call is the regression this file is
    // here to catch - and answers whatever extra questions a test wants.
    appendFileSync(process.env.RSTUB_COUNT_FILE, 'req\n');
    const extra = process.env.RSTUB_EXTRA ? JSON.parse(process.env.RSTUB_EXTRA) : {};
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ answers: { intent: {
      value: process.env.RSTUB_INTENT,
      confidence: Number(process.env.RSTUB_CONFIDENCE),
      probabilities: probs,
    }, ...extra } }));
  });
});
s.listen(0, '127.0.0.1', () => { writeFileSync(process.env.RSTUB_PORT_FILE, String(s.address().port)); });
EOF
  export RSTUB_BODY_FILE="$T/rbody.json" RSTUB_HEADERS_FILE="$T/rheaders.json"
  export RSTUB_PORT_FILE="$T/rport" RSTUB_INTENT="$1" RSTUB_CONFIDENCE="$2"
  export RSTUB_PROBS="${3:-}" RSTUB_STATUS="${4:-200}"
  export RSTUB_COUNT_FILE="$T/rcount" RSTUB_EXTRA="${RSTUB_EXTRA:-}"
  rm -f "$RSTUB_PORT_FILE" "$RSTUB_BODY_FILE" "$RSTUB_COUNT_FILE"
  : >"$RSTUB_COUNT_FILE"
  node "$T/rstub.mjs" >"$T/rstub.log" 2>&1 </dev/null & RSTUB_PID=$!
  local i=0
  while [ ! -s "$RSTUB_PORT_FILE" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$RSTUB_PORT_FILE" ] || { echo 'router stub never listened'; return 1; }
  export CEL_CONSOLE_ROUTER_URL="http://127.0.0.1:$(cat "$RSTUB_PORT_FILE")"
}

_console_router_stop() {
  [ -n "${RSTUB_PID:-}" ] || return 0
  kill "$RSTUB_PID" 2>/dev/null || true
  wait "$RSTUB_PID" 2>/dev/null || true
  RSTUB_PID=""
  unset CEL_CONSOLE_ROUTER_URL
}

_console_router_config() { # [min_confidence]
  { printf 'console:\n  provider: openrouter\n  model: alpha/model-mini\n  key_env: OPENROUTER_API_KEY\n'
    printf '  router:\n    provider: openrouter\n    model: alpha/decide-1\n'
    printf '    key_env: OPENROUTER_API_KEY\n    min_confidence: %s\n' "${1:-0.6}"; } >"$T/config.yaml"
  chmod 600 "$T/config.yaml"
}

# The router picks `product_status`; the console - not the model - turns that
# into the three commands, with the workspace that owns the product.
test_console_router_expands_an_intent_into_commands() {
  _console_depth_setup
  _console_router_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'cel fleet'
  _console_router_stub product_status 0.98
  local out err rc=0
  out="$(node "$CONSOLE_MJS" --ask 'what is happening with bundle' 2>"$T/err.txt")" || rc=$?
  err="$(cat "$T/err.txt")"
  assert_eq "$rc" 0
  assert_contains "$out" 'cel fleet'
  assert_contains "$out" 'cel-fanout status --workspace alpha'
  assert_contains "$out" 'cel inbox open --for root --workspace alpha'
  assert_contains "$err" 'router: product_status 0.98 in'
  # The chat model was never asked: that is the whole point of the router.
  [ ! -s "$T/body.json" ] || { echo 'the chat model was asked anyway'; return 1; }
  _console_router_stop
  _console_stub_stop
  _console_teardown
}

# The request carries the box's names (so the classifier knows what exists) and
# NEVER the key - a key in a body is a key in every provider's request log.
test_console_router_request_carries_the_names_and_never_the_key() {
  _console_depth_setup
  _console_router_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'cel fleet'
  _console_router_stub fleet 0.9
  node "$CONSOLE_MJS" --ask "what's blocked" >/dev/null 2>&1
  local body headers
  body="$(cat "$T/rbody.json")"
  headers="$(cat "$T/rheaders.json")"
  assert_contains "$body" 'alpha'
  assert_contains "$body" 'bundle'
  assert_contains "$body" "what's blocked"
  assert_contains "$body" 'product_status'
  assert_contains "$headers" 'test-key'
  case "$body" in *test-key*) echo 'the key was in the request body'; return 1;; esac
  _console_router_stop
  _console_stub_stop
  _console_teardown
}

# Below the floor the router is guessing, and a guess belongs in the options
# UI where the operator picks - not on the command line waiting for Enter.
test_console_router_below_the_floor_offers_three_options() {
  _console_depth_setup
  _console_router_config 0.6
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'cel fleet'
  _console_router_stub fleet 0.42 '{"fleet":0.42,"product_status":0.31,"waiting":0.2,"try":0.05}'
  local out rc=0
  out="$(node "$CONSOLE_MJS" --ask 'what is going on with bundle' 2>/dev/null)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" 'did you mean'
  assert_contains "$out" 'cel fleet'
  assert_contains "$out" 'cel-fanout status --workspace alpha'
  assert_contains "$out" '0.42'
  _console_router_stop
  _console_stub_stop
  _console_teardown
}

# A router that is down is not an outage: the sentence path it replaced is
# still there, and the operator should not be able to tell.
test_console_router_failure_falls_through_to_the_chat_model() {
  _console_depth_setup
  _console_router_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'cel fleet'
  _console_router_stub fleet 0.9 '' 500
  local out rc=0
  out="$(node "$CONSOLE_MJS" --ask "what's blocked" 2>/dev/null)" || rc=$?
  assert_eq "$rc" 0
  assert_eq "$out" 'cel fleet'
  assert_contains "$(cat "$T/body.json")" "what's blocked"
  _console_router_stop
  _console_stub_stop
  _console_teardown
}

# `--no-router` is the escape hatch: one flag and the console is exactly what
# it was before this ticket.
test_console_no_router_asks_the_chat_model_directly() {
  _console_depth_setup
  _console_router_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'cel fleet'
  _console_router_stub product_status 0.98
  local out
  out="$(node "$CONSOLE_MJS" --no-router --ask 'what is happening with bundle' 2>/dev/null)"
  assert_eq "$out" 'cel fleet'
  [ ! -s "$T/rbody.json" ] || { echo 'the router was asked despite --no-router'; return 1; }
  # And the same for the config switch.
  rm -f "$T/body.json"
  { printf 'console:\n  provider: openrouter\n  model: alpha/model-mini\n  key_env: OPENROUTER_API_KEY\n'
    printf '  router:\n    provider: openrouter\n    model: alpha/decide-1\n    enabled: false\n'; } >"$T/config.yaml"
  chmod 600 "$T/config.yaml"
  out="$(node "$CONSOLE_MJS" --ask 'what is happening with bundle' 2>/dev/null)"
  assert_eq "$out" 'cel fleet'
  [ ! -s "$T/rbody.json" ] || { echo 'the router was asked despite router.enabled: false'; return 1; }
  _console_router_stop
  _console_stub_stop
  _console_teardown
}

# The model picks a LABEL; every character of the command line is produced
# here. That is the part worth proving without a network.
test_console_router_slot_filling_is_proved() {
  node "$CEL_ROOT/tools/console/router.test.mjs"
}

# COMMAND SUBSTITUTION IN A MESSAGE. The `message` intent is the one place an
# operator's own words reach the command line, and that line is handed to
# `bash -c`. Inside DOUBLE quotes bash still runs `$(...)` and backticks, and
# the guard's console branch allows every `cel ...` line without looking at
# metacharacters - so `tell bundle-orch "hi $(touch /tmp/pwned)"` was a
# proposal that ran `touch` the moment the operator pressed Enter. The text is
# single-quoted now, and this test runs the router's own output through the
# console's real execution path to prove it.
test_console_router_message_text_cannot_run_a_command() {
  _console_depth_setup
  PATH="$T/bin:$PATH"
  local marker="$T/pwned" cmd
  cmd="$(node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import { facts, plan } from '$CEL_ROOT/tools/console/router.mjs';
    const doc = JSON.parse(readFileSync('$T/fleet.json', 'utf8'));
    process.stdout.write(plan('message', 'tell bundle-orch \"ping \$(touch $marker)\"', facts(doc, []))[0]);
  ")"
  assert_contains "$cmd" 'cel inbox send bundle-orch'
  node "$CONSOLE_MJS" --run "$cmd" >/dev/null 2>&1 || true
  [ ! -e "$marker" ] || { echo 'the message text ran a command'; return 1; }
  # And the substitution is still there, as text, for whoever reads the mail.
  assert_contains "$cmd" 'touch'
  _console_teardown
}

# --- CEL-27: the subscriptions on the status edge and in their own view ------
# Stubbed fleet JSON, because the console must never make the network call
# itself: the edge and the QUOTA view render from whatever `cel fleet --json`
# already carries, which is the 60 s cache.
_console_subs_setup() {
  _console_setup
  cat >"$T/fleet.json" <<'EOF'
{"workspaces":[
 {"name":"alpha","root":{"unread":0,"open":0},"units":[
   {"name":"widget","orch":"LIVE","workers":1,"cap":4,"stalled":0,"unlanded":0}]}],
 "subscriptions":[
  {"provider":"claude","account":"a1b2c3",
   "windows":[{"name":"5h","used_pct":16,"resets_at":"2026-09-18T09:00:00Z"},
              {"name":"7d","used_pct":41,"resets_at":"2026-09-19T19:00:00Z"}],
   "extra":{"state":"disabled","reason":"out_of_credits"}},
  {"provider":"codex","account":"acct-alpha-1",
   "windows":[{"name":"5h","used_pct":9,"resets_at":"2026-09-18T07:30:00Z"},
              {"name":"7d","used_pct":62,"resets_at":"2026-09-21T02:00:00Z"}],
   "extra":{"state":"enabled","reason":""}}]}
EOF
}

test_console_status_edge_shows_the_tightest_window_per_provider() {
  _console_subs_setup
  local out; out="$(node "$CONSOLE_MJS" --render-once)"
  assert_contains "$out" 'claude 16%/41%'
  assert_contains "$out" 'codex 9%/62%'
  _console_teardown
}

test_console_quota_view_renders_one_row_per_account_and_window() {
  _console_subs_setup
  local out; out="$(node "$CONSOLE_MJS" --render-quota)"
  assert_contains "$out" 'SUBSCRIPTIONS'
  assert_contains "$out" 'a1b2c3'
  assert_contains "$out" '5h'
  assert_contains "$out" '16%'
  assert_contains "$out" 'out of credits'
  _console_teardown
}

# --- CEL-35: the console and the dashboard draw the SAME rows ---------------
#
# They disagreed because they read different things: the console read the
# fleet document's cache-built list and the dashboard merged `cel quota` with
# `cel gateway status` itself. The owner saw Claude alone on one screen and
# everything on the other. One list now, and the cells that list becomes are
# one function - proved here by running both copies over one fixture.
test_console_and_dash_build_the_same_subscription_cells() {
  _console_setup
  cat >"$T/parity.mjs" <<'EOF'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const { subCells } = await import(process.env.VIEWS_MJS);

const src = readFileSync(process.env.SERVER_MJS, 'utf8');
const start = src.indexOf('// <cel35:sub-cells>');
const end = src.indexOf('// </cel35:sub-cells>');
assert.ok(start > 0 && end > start, 'the dash card has no marked sub-cell builder');
const body = src.slice(start, end);
// eslint-disable-next-line no-new-func
const dashCells = new Function(`${body}; return subCells;`)();

const rows = [
  { source: 'direct', provider: 'claude', account: 'pi+claude-code', label: 'pi + claude-code',
    windows: [{ name: '5h', used_pct: 16, resets_at: '2026-09-18T09:00:00Z' },
              { name: '7d', used_pct: 41, resets_at: '2026-09-19T19:00:00Z' }],
    extra: { state: 'enabled', reason: '' } },
  { source: 'direct', provider: 'codex', account: 'acct-alpha-1', label: 'acct-alpha-1',
    windows: [], extra: { state: 'unreadable', reason: 'the endpoint could not be read' } },
  { source: 'gateway', provider: 'openai-codex', account: 'aaaaaa', label: 'aaaaaa',
    windows: [{ name: '7 days', used_pct: 100, resets_at: null }], extra: { state: 'enabled', reason: '' } },
];
for (const r of rows) assert.deepEqual(dashCells(r), subCells(r), `the dash and the console differ on ${r.account}`);
process.stdout.write('parity: all good\n');
EOF
  local out
  out="$(VIEWS_MJS="$CEL_ROOT/tools/console/views.mjs" SERVER_MJS="$CEL_ROOT/tools/dash/server.mjs" \
    node "$T/parity.mjs" 2>&1)" || { printf '%s\n' "$out"; _console_teardown; return 1; }
  assert_contains "$out" 'parity: all good'
  _console_teardown
}
# --- CEL-25: the console as a control panel ---------------------------------

# The BOARD and the PRS are the two things an operator actually steers by, and
# neither was on screen: the console showed the fleet's own state and nothing
# about the work it exists to move. Both are stubbed here for the same reason
# the rest of this file stubs `cel` - a suite that asked Linear and GitHub for
# the truth would be a suite that fails when someone else merges something.
_console_panel_setup() {
  _console_depth_setup
  mkdir -p "$T/cache" "$T/state"
  export CEL_CACHE="$T/cache" CEL_CONSOLE_STATE_DIR="$T/state"

  cat >"$T/bin/cel-linear" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CEL_LINEAR_CALLS"
cat <<'JSON'
{"identifier":"ABC-48","title":"the kerning is wrong","state":"Todo","assignee":"","updatedAt":"2026-09-20T09:00:00Z","url":"https://linear.invalid/ABC-48"}
{"identifier":"ABC-49","title":"ship the gadget bundle","state":"In Progress","assignee":"Sam","updatedAt":"2026-09-20T10:00:00Z","url":"https://linear.invalid/ABC-49"}
JSON
EOF
  chmod +x "$T/bin/cel-linear"
  export CEL_LINEAR_BIN="$T/bin/cel-linear" CEL_LINEAR_CALLS="$T/linear.calls"
  : >"$CEL_LINEAR_CALLS"

  cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$*" in
  *"--state merged"*)
    cat <<'JSON'
[{"number":11,"title":"the old one","headRefName":"ABC-40-old","mergedAt":"2026-09-20T11:47:00Z","updatedAt":"2026-09-20T11:47:00Z"}]
JSON
    ;;
  *)
    cat <<'JSON'
[{"number":12,"title":"ship the gadget bundle","headRefName":"ABC-49-slug","isDraft":false,"reviewDecision":"APPROVED","statusCheckRollup":[{"name":"gate","conclusion":"SUCCESS"}],"updatedAt":"2026-09-20T10:00:00Z"}]
JSON
    ;;
esac
EOF
  chmod +x "$T/bin/gh"
  export CEL_GH_BIN="$T/bin/gh" GH_CALLS="$T/gh.calls"
  : >"$GH_CALLS"
  # `gh pr list --repo widget` is a request for a repository that does not
  # exist under whatever owner gh guesses, so the console needs owner/name. It
  # reads that from the workspace; here - and on a box where the console
  # stands outside every workspace - the map is handed to it directly.
  export CEL_CONSOLE_REPO_SLUGS='{"widget":"acme/widget","gadget":"acme/gadget"}'
  printf '2026-09-20T09:41:00Z' > "$T/state/alpha.root.console.cursor"
}

test_console_unit_view_shows_the_board_the_prs_and_the_digest() {
  _console_panel_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once --unit bundle)"
  assert_contains "$out" 'BOARD'
  assert_contains "$out" 'ABC-48'
  assert_contains "$out" 'In Progress'
  assert_contains "$out" 'ship the gadget bundle'
  assert_contains "$out" 'PRS'
  assert_contains "$out" '#12'
  assert_contains "$out" 'review APPROVED'
  assert_contains "$out" 'ci '
  assert_contains "$out" 'since 09:41'
  # ONE gh call per repo, not one per row: the refresh loop runs every ten
  # seconds and a call per PR is a rate limit waiting to happen.
  assert_eq "$(grep -c 'pr list' "$GH_CALLS")" 2
  _console_teardown
}

# The timeline is the box's own history in one column: what the mailboxes,
# the ledger and the PR caches saw, oldest first so the newest is where the
# eye lands.
test_console_timeline_merges_mail_delegations_and_prs() {
  _console_panel_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once --timeline)"
  assert_contains "$out" 'TIMELINE'
  assert_contains "$out" 'first line'
  assert_contains "$out" 'merged'
  assert_contains "$out" '#11'
  _console_teardown
}

# A key is a proposal, and a proposal that names the wrong workspace is the
# same accident as a router that guesses one.
test_console_verb_keys_are_proved() {
  node "$CEL_ROOT/tools/console/verbs.test.mjs"
}

# THE SERVICES VIEW. "is the builder up, and what is its URL from the laptop"
# is one keypress from the main screen, and this is the text that key draws -
# rendered from a stubbed `cel services --json` so the assertion is on the
# columns rather than on whatever this box happens to be running.
_console_services_setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/inbox"
  printf '{"workspaces":[{"name":"alpha","root":{"unread":0,"open":0},"units":[]}]}\n' > "$T/fleet.json"
  cat >"$T/services.json" <<'JSON'
[{"name":"builder","kind":"declared","state":"up","port":4322,"rss_mb":312,"uptime_secs":7200,
  "reach":"http://100.1.2.3:7770/svc/4322/","ticket":"","url":"http://127.0.0.1:4322","observe_only":false},
 {"name":"try ABC-49","kind":"preview","state":"healthy","port":4401,"rss_mb":120,"uptime_secs":600,
  "reach":"http://100.1.2.3:7770/svc/4401/","ticket":"ABC-49","url":"http://localhost:4401","observe_only":false},
 {"name":"docs","kind":"declared","state":"down","port":9,"rss_mb":0,"uptime_secs":0,
  "reach":"","ticket":"","url":"http://127.0.0.1:9/","observe_only":true}]
JSON
  cat >"$T/bin/cel" <<EOF
#!/usr/bin/env bash
case "\$1" in
  fleet)    cat "$T/fleet.json" ;;
  services) cat "$T/services.json" ;;
  *) printf '' ;;
esac
EOF
  chmod +x "$T/bin/cel"
  export CEL_BIN="$T/bin/cel"
  export CEL_INBOX_DIR="$T/inbox"
}

test_console_services_view_renders_one_row_per_service_and_preview() {
  _console_services_setup
  local out; out="$(node "$CONSOLE_MJS" --render-once --services)"
  assert_contains "$out" "SERVICES"
  assert_contains "$out" "builder"
  assert_contains "$out" ":4322"
  assert_contains "$out" "312M"
  assert_contains "$out" "2h"
  assert_contains "$out" "http://100.1.2.3:7770/svc/4322/"
  # a preview shows the ticket it belongs to
  assert_contains "$out" "ABC-49"
  # and a dead observe-only row still appears, because a service you declared
  # and did not start is exactly what you want to see
  assert_contains "$out" "docs"
  assert_contains "$out" "down"
  _console_teardown
}

# The workspace header answers "is anything down here" without entering the
# view at all.
test_console_fleet_header_counts_services_up_and_down() {
  _console_services_setup
  local out; out="$(node "$CONSOLE_MJS" --render-once)"
  assert_contains "$out" "services 2 up/1 down"
  _console_teardown
}

# CEL-36: reaching an orchestrator now, and seeing it answer. The watch and
# the relay are ink in the TUI and cannot be driven without a terminal, so
# what is asserted is everything that DECIDES: which message counts as the
# reply, which command a relayed line becomes, and what the operator is told
# when nothing comes back.
test_console_steering_helpers_are_proved() {
  node "$CEL_ROOT/tools/console/steer.test.mjs"
}

# ONE VOCABULARY, TWO CONSOLES (tools/console/vocabulary.md). A relay the TUI
# can do and the agent console has never heard of is the two of them
# disagreeing about what the console is, and the one that is wrong is always
# the one nobody is watching.
test_console_vocabulary_documents_the_relay_and_the_two_step() {
  local vocab="$CEL_ROOT/tools/console/vocabulary.md"
  assert_contains "$(cat "$vocab")" 'herdr agent read'
  assert_contains "$(cat "$vocab")" 'talk'
  # The role says when NOT to relay: a long design discussion belongs in the
  # pane itself, which is what `focus` is for.
  assert_contains "$(cat "$CEL_ROOT/core/roles/console.md")" 'focus'
}

# The legend is the console's only permanent instruction, and a mode with no
# way out drawn on the screen is a mode an operator force-quits out of.
test_console_talk_mode_has_a_legend_that_says_how_to_leave() {
  local out
  out="$(node -e "import('$CEL_ROOT/tools/console/legend.mjs').then(m => console.log(m.legend('talk')))")"
  assert_contains "$out" 'Esc'
  assert_contains "$out" 'relay'
}

# --- CEL-37: the console takes its watcher with it -------------------------

# THIRTEEN WATCHERS REPARENTED TO INIT, four of them days old. Every console
# that exited left `cel inbox watch` and its `tail`/`jq` children running
# against a pane that no longer existed. The lifetime is a unit test for the
# same reason the screen modes are: the failure is invisible until someone
# walks /proc a week later.
test_console_watcher_lifetime_is_proved() {
  node "$CEL_ROOT/tools/console/watcher.test.mjs"
}

# A gigabyte of orphans under `celestial-orch 1.7G` went unmentioned because
# no view had a field for it. The box line is where an operator looks at the
# box, so that is where the count goes - and only when there is one.
test_console_box_line_names_the_orphans_when_there_are_any() {
  _console_memory_setup
  local out
  python3 - "$T/fleet.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["box"]["orphans"] = {"count": 6, "rss_mb": 410}
json.dump(d, open(p, "w"))
PY
  out="$(node "$CONSOLE_MJS" --render-once)"
  assert_contains "$out" '6 orphans'
  assert_contains "$out" '410M'
  _console_teardown
}

test_console_box_line_is_silent_when_there_are_no_orphans() {
  _console_memory_setup
  local out
  out="$(node "$CONSOLE_MJS" --render-once)"
  case "$out" in *orphan*) echo 'the box line invented orphans'; return 1;; esac
  _console_teardown
}

# --- CEL-41: the console answers instead of transcribing --------------------

# MANY QUESTIONS COST NOTHING EXTRA. The decisions endpoint evaluates every
# question in one request in parallel, so the router asks for the slots, the
# danger and the answerability beside the intent rather than spending its one
# call on a single label and filling the rest with regexes. The count file is
# the assertion that matters: a second request is latency the operator pays.
test_console_router_asks_every_question_in_one_request() {
  _console_depth_setup
  _console_router_config
  export OPENROUTER_API_KEY=test-key
  _console_stub_server 'cel fleet'
  _console_router_stub product_status 0.98
  node "$CONSOLE_MJS" --ask 'what is happening with bundle' >/dev/null 2>&1
  local body
  body="$(cat "$T/rbody.json")"
  assert_contains "$body" '"intent"'
  assert_contains "$body" '"workspace"'
  assert_contains "$body" '"product"'
  assert_contains "$body" '"destructive"'
  assert_contains "$body" '"answerable"'
  assert_eq "$(wc -l <"$T/rcount" | tr -d ' ')" 1
  _console_router_stop
  _console_stub_stop
  _console_teardown
}

# The bands, the slots and the danger switch, driven through `route()` itself
# because they are decisions rather than printing: which band a confidence
# lands in, whose answer fills a workspace slot, and the one probability that
# overrides a confident intent.
test_console_router_bands_and_slots_are_proved() {
  _console_depth_setup
  _console_router_config
  export OPENROUTER_API_KEY=test-key
  RSTUB_EXTRA='{"product":{"value":"bundle","confidence":0.9},"workspace":{"value":"alpha","confidence":0.9}}' \
    _console_router_stub product_status 0.98
  cat >"$T/bands.test.mjs" <<'EOF'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const mod = await import(`${process.env.CEL_ROOT}/tools/console/router.mjs`);
const DOC = JSON.parse(readFileSync(process.env.RDOC, 'utf8'));
const ask = (sentence) => mod.route({ sentence, doc: DOC, items: [] });

// A named product beats whatever the model answered for the slots: the
// regexes read the operator's own words, the model only guesses at them.
let r = await ask('what is happening with bundle');
assert.equal(r.decision, 'run');
assert.ok(r.cmds.join(' ').includes('--workspace alpha'), r.cmds.join(' '));

// Nothing named: the model's own `product` answer fills the slot instead.
r = await ask('how is that one going');
assert.ok(r.cmds && r.cmds.join(' ').includes('--workspace alpha'), JSON.stringify(r.cmds));
EOF
  RDOC="$T/fleet.json" node "$T/bands.test.mjs" || { _console_router_stop; _console_teardown; return 1; }
  _console_router_stop

  # `unclear` is not a workspace. A model that cannot see one must not have
  # its non-answer turned into somebody else's mailbox on a command line.
  RSTUB_EXTRA='{"product":{"value":"unclear"},"workspace":{"value":"unclear"}}' \
    _console_router_stub product_status 0.98
  cat >"$T/unclear.test.mjs" <<'EOF'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const mod = await import(`${process.env.CEL_ROOT}/tools/console/router.mjs`);
const DOC = JSON.parse(readFileSync(process.env.RDOC, 'utf8'));
const r = await mod.route({ sentence: 'how is that one going', doc: DOC, items: [] });
assert.equal(r.cmds, null);
// The non-answer may be reported as the hint it was; what it must never do is
// reach a command line.
assert.ok(!JSON.stringify(r.options.map((o) => o.cmd)).includes('unclear'));
EOF
  RDOC="$T/fleet.json" node "$T/unclear.test.mjs" || { _console_router_stop; _console_teardown; return 1; }
  _console_router_stop

  # DESTRUCTIVE OVERRIDES CONFIDENCE. Sure is not the same as safe: a sweep
  # the model is 0.95 certain about still closes decisions nobody read.
  RSTUB_EXTRA='{"destructive":{"probability":0.82}}' _console_router_stub clean_inbox 0.95
  cat >"$T/danger.test.mjs" <<'EOF'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const mod = await import(`${process.env.CEL_ROOT}/tools/console/router.mjs`);
const DOC = JSON.parse(readFileSync(process.env.RDOC, 'utf8'));
const r = await mod.route({ sentence: 'clear out the alpha mailbox', doc: DOC, items: [] });
assert.equal(r.decision, 'propose');
assert.ok(r.reason.includes('clean_inbox'), r.reason);
EOF
  RDOC="$T/fleet.json" node "$T/danger.test.mjs" || { _console_router_stop; _console_teardown; return 1; }
  _console_router_stop

  # The three bands: 0.8 runs, 0.6 proposes, 0.3 asks with the top two
  # intents in the model's own probability order.
  local pair
  # The bands themselves, not the legacy floor: a config that still carries
  # `min_confidence` is read as a run threshold, which is what the older tests
  # above prove.
  { printf 'console:\n  provider: openrouter\n  model: alpha/model-mini\n  key_env: OPENROUTER_API_KEY\n'
    printf '  router:\n    provider: openrouter\n    model: alpha/decide-1\n'
    printf '    key_env: OPENROUTER_API_KEY\n    run_confidence: 0.75\n    propose_confidence: 0.5\n'; } >"$T/config.yaml"
  chmod 600 "$T/config.yaml"
  for pair in '0.8 run' '0.6 propose' '0.3 ask'; do
    # shellcheck disable=SC2086
    set -- $pair
    RSTUB_EXTRA='' _console_router_stub product_status "$1" '{"product_status":0.3,"fleet":0.28,"waiting":0.2}'
    cat >"$T/band.test.mjs" <<'EOF'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const mod = await import(`${process.env.CEL_ROOT}/tools/console/router.mjs`);
const DOC = JSON.parse(readFileSync(process.env.RDOC, 'utf8'));
const r = await mod.route({ sentence: 'what is happening with bundle', doc: DOC, items: [] });
assert.equal(r.decision, process.env.WANT, `${r.decision} for ${process.env.WANT}`);
if (r.decision === 'ask') {
  assert.equal(r.options.length, 2);
  assert.deepEqual(r.options.map((o) => o.intent), ['product_status', 'fleet']);
  assert.ok(r.reason.includes('did you mean'), r.reason);
}
EOF
    RDOC="$T/fleet.json" WANT="$2" node "$T/band.test.mjs" || { _console_router_stop; _console_teardown; return 1; }
    _console_router_stop
  done
  _console_teardown
}

# THE MODEL PICKS THE ROWS; THE CONSOLE WRITES THE LINE. Twenty-two workers
# is a wall of text that answers nothing. The choice question ranks the rows
# in one call, and every number in the sentence underneath them is counted
# here in code - jev cannot count and is not asked to (jaggedness #2, #3).
test_console_triage_picks_rows_and_the_console_counts_them() {
  T="$(mktemp -d)"
  cat >"$T/triage.test.mjs" <<'EOF'
import assert from 'node:assert/strict';
const r = await import(`${process.env.CEL_ROOT}/tools/console/router.mjs`);
const v = await import(`${process.env.CEL_ROOT}/tools/console/views.mjs`);

// 22 rows: 3 that need somebody, 14 landed, 3 running, 2 released.
const rows = [];
const mk = (n, state, extra = {}) => ({ id: `ABC-${n}-slug`, ticket: `ABC-${n}`, repo: 'widget', state, quiet_secs: 60, ...extra });
rows.push(mk(49, 'blocked', { verdict: 'stalled', quiet_secs: 2460 }));
rows.push(mk(51, 'finished', { pr: 'https://example.invalid/widget/pull/61' }));
rows.push(mk(53, 'blocked', { verdict: 'refused' }));
for (let i = 0; i < 14; i += 1) rows.push(mk(100 + i, 'landed'));
for (let i = 0; i < 3; i += 1) rows.push(mk(200 + i, 'running'));
for (let i = 0; i < 2; i += 1) rows.push(mk(300 + i, 'released'));
assert.equal(rows.length, 22);

const probs = { 'ABC-49-slug': 0.9, 'ABC-51-slug': 0.5, 'ABC-53-slug': 0.4, 'ABC-100-slug': 0.02, none: 0.01 };
const ids = r.pickRelevant(probs);
assert.deepEqual(ids, ['ABC-49-slug', 'ABC-51-slug', 'ABC-53-slug']);

const picked = ids.map((id) => rows.find((w) => w.id === id));
const lines = v.triageView({ rows, picked });
assert.equal(lines[0], '3 of 22 workers need you.');
assert.equal(lines.length, 5);
assert.ok(lines[1].includes('ABC-49'), lines[1]);
assert.ok(lines[1].includes('41m'), lines[1]);
// The summary line is COUNTED, every number of it: 19 others, and the tally
// by state as the fleet JSON has them.
const last = lines[lines.length - 1];
assert.ok(last.includes('19 others'), last);
assert.ok(last.includes('14 landed'), last);
assert.ok(last.includes('3 running normally'), last);
assert.ok(last.includes('2 released'), last);
assert.ok(last.includes('`a` shows them all'), last);

// The whole triage is a question ABOUT ROWS, one option per row plus `none`,
// and it carries no prose from the model into the sentence path at all.
const q = r.relevantQuestion('which workers need me', rows);
assert.equal(q.type, 'choice');
assert.equal(Object.keys(q.criteria).length, 23);
assert.ok('none' in q.criteria);
assert.equal(r.attentionQuestion(rows[0]).type, 'score');
// The summary is skipped entirely at `console.rows_inline` rows or fewer:
// the table is already readable and a sentence about it would be noise.
assert.equal(r.ROWS_INLINE, 6);
assert.equal(r.ATTENTION_LEVELS.length, 4);
EOF
  CEL_ROOT="$CEL_ROOT" node "$T/triage.test.mjs" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The console's own thresholds are config, defaulted in code and written down
# where an operator will look for them.
test_console_row_and_confidence_keys_are_documented() {
  local docs
  docs="$(cat "$CEL_ROOT/tools/console/vocabulary.md" "$CEL_ROOT/core/roles/console.md")"
  assert_contains "$docs" 'rows_inline'
  assert_contains "$docs" 'run_confidence'
  assert_contains "$docs" 'propose_confidence'
  assert_contains "$docs" 'summary_timeout'
}

# THE CHAT MODEL WRITES THE SENTENCE; IT DOES NOT WRITE A NUMBER (CEL-41 §5,
# the owner: "I'm not suggesting we use jev for summarisation, we can use
# deepseek for that"). Every digit in the prose must already be in the facts
# object the console computed, because "7 of 40 workers need you" is a figure
# an operator acts on and no style rule catches it.
test_console_summary_prose_never_invents_a_number() {
  _console_setup
  _console_config
  export OPENROUTER_API_KEY=test-key
  cat >"$T/sum.test.mjs" <<'EOF'
import assert from 'node:assert/strict';
const t = await import(`${process.env.CEL_ROOT}/tools/console/translate.mjs`);
const v = await import(`${process.env.CEL_ROOT}/tools/console/views.mjs`);
const facts = { question: 'who needs me', need: 3, total: 22, rows: [], others: { count: 19, tally: [['landed', 14]] } };
assert.deepEqual(v.unknownNumbers('3 of 22 workers need you; 19 others, 14 landed.', facts), []);
assert.deepEqual(v.unknownNumbers('7 of 40 workers need you.', facts), ['7', '40']);
const out = await t.summarise({ facts }).catch((e) => e);
if (process.env.WANT === 'ok') assert.equal(out, '3 of 22 workers need you.');
else {
  assert.ok(out instanceof Error, `expected the guard to refuse, got ${out}`);
  assert.ok(out.message.includes('invented a number'), out.message);
}
EOF
  _console_stub_server '3 of 22 workers need you.'
  WANT=ok node "$T/sum.test.mjs" || { _console_stub_stop; _console_teardown; return 1; }
  _console_stub_stop
  _console_stub_server '7 of 40 workers need you, roughly half the box.'
  WANT=bad node "$T/sum.test.mjs" || { _console_stub_stop; _console_teardown; return 1; }
  _console_stub_stop
  _console_teardown
}

# A TUI MUST NOT HANG WAITING FOR PROSE. The counted lines are already a
# correct answer, so a slow or unreachable chat model costs nothing: the
# template is what was drawn in the first place and it simply stays.
test_console_summary_falls_back_to_the_counted_template() {
  _console_setup
  _console_config 'summary_timeout: 0.1'
  export OPENROUTER_API_KEY=test-key
  cat >"$T/slow.test.mjs" <<'EOF'
import assert from 'node:assert/strict';
const t = await import(`${process.env.CEL_ROOT}/tools/console/translate.mjs`);
const v = await import(`${process.env.CEL_ROOT}/tools/console/views.mjs`);
assert.equal(t.summaryTimeout(process.env.CEL_CONSOLE_CONFIG), 100);
const rows = Array.from({ length: 9 }, (_, i) => ({ id: `ABC-${i}-slug`, ticket: `ABC-${i}`, state: 'landed' }));
const facts = v.triageFacts({ rows, picked: [rows[0]], question: 'who needs me' });
const err = await t.summarise({ facts }).then(() => null, (e) => e);
assert.ok(err, 'a model that never answers must not resolve');
// The fallback is a complete answer on its own - that is the whole point.
const lines = v.triageView(facts);
assert.equal(lines[0], '1 of 9 workers need you.');
assert.ok(lines[lines.length - 1].includes('8 others: 8 landed'), lines[lines.length - 1]);
EOF
  # A server that accepts the connection and never answers.
  cat >"$T/hang.mjs" <<'EOF'
import { createServer } from 'node:http';
import { writeFileSync } from 'node:fs';
const s = createServer(() => {});
s.listen(0, '127.0.0.1', () => writeFileSync(process.env.HANG_PORT, String(s.address().port)));
EOF
  export HANG_PORT="$T/hport"
  node "$T/hang.mjs" >/dev/null 2>&1 </dev/null & local hpid=$!
  local i=0
  while [ ! -s "$HANG_PORT" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  CEL_CONSOLE_PROVIDER_URL="http://127.0.0.1:$(cat "$HANG_PORT")" node "$T/slow.test.mjs" \
    || { kill "$hpid" 2>/dev/null || true; _console_teardown; return 1; }
  kill "$hpid" 2>/dev/null || true
  wait "$hpid" 2>/dev/null || true
  _console_teardown
}

# CEL-44: the vocabulary is the one place both consoles read what they may do.
# `cel ws down` stops PANES; the line that says so exists because the nearest
# words to it - "close the workspace", "clean it up" - are what an operator
# reaches for when they mean worktrees, and that is `cel-fanout release`.
test_console_vocabulary_carries_the_workspace_lifecycle_rows() {
  local v="$CEL_ROOT/tools/console/vocabulary.md"
  assert_contains "$(cat "$v")" 'cel ws up <w>'
  assert_contains "$(cat "$v")" 'cel ws down <w>'
  assert_contains "$(cat "$v")" 'cel ws reset <w>'
  assert_contains "$(cat "$v")" 'PANES, never worktrees'
}

# --- CEL-43: the digest ranks what is left ----------------------------------
# Root's mailbox is where everything shouts at once, and the console drew it
# newest-first: a status line from a minute ago sat above an escalation from
# yesterday saying a reviewer pane had died. The levels come from the model
# through lib/triage.sh's cache - the console never scores anything itself,
# it reads the cache and does the ordering and the cut in code.
test_console_digest_ranks_root_mail_and_cuts_at_the_top_three() {
  _console_panel_setup
  printf '%s\n' \
    '{"id":"r1","ts":"2026-09-20T10:00:00+00:00","kind":"status","from":"bundle-orch","to":"root","message":"nothing to do"}' \
    '{"id":"r2","ts":"2026-09-20T10:01:00+00:00","kind":"escalation","from":"bundle-orch","to":"root","message":"the reviewer pane is dead"}' \
    '{"id":"r3","ts":"2026-09-20T10:02:00+00:00","kind":"decision","from":"bundle-orch","to":"root","message":"ship the bundle or hold"}' \
    '{"id":"r4","ts":"2026-09-20T10:03:00+00:00","kind":"status","from":"bundle-orch","to":"root","message":"ABC-9 gate is green"}' \
    '{"id":"r5","ts":"2026-09-20T10:04:00+00:00","kind":"status","from":"bundle-orch","to":"root","message":"also nothing to do"}' \
    >>"$T/inbox/alpha.jsonl"
  printf '%s\n' 'r1\t0' 'r2\t3' 'r3\t2' 'r4\t1' 'r5\t0' | sed 's/\\t/\t/' >"$T/triage.cache"
  export CEL_TRIAGE_CACHE="$T/triage.cache"
  local out; out="$(node "$CONSOLE_MJS" --render-once --unit bundle)"
  assert_contains "$out" 'the reviewer pane is dead'
  assert_contains "$out" 'ship the bundle or hold'
  assert_contains "$out" 'and 2 more'
  # the ranked block itself: the escalation on top, and nothing past the cut
  local block; block="${out#*MAIL (most urgent first)}"; block="${block%%and 2 more*}"
  assert_contains "$(printf '%s' "$block" | sed -n 2p)" 'the reviewer pane is dead'
  case "$block" in *'also nothing to do'*) echo 'drew past the cut'; return 1;; esac
  _console_teardown
}

# --- CEL-43 section 5: a detail view that cannot resolve what it shows ------
# Observed by the owner on a real BLOCKED item: the header read `id undefined`
# and [resolve] did nothing. Two faults. The INBOX tail dropped the id of the
# record it had just parsed, so a detail opened from that pane had no identity
# (one opened from WAITING did, which is why it worked there); and a tail row
# can be a HISTORICAL record whose item the steward already self-cleared, yet
# the view offered a button that could never work.
test_console_tail_rows_carry_the_id_of_the_record() {
  _console_setup
  printf '%s\n' \
    '{"id":"b7","ts":"2036-09-20T10:00:00+00:00","kind":"blocked","from":"bundle-orch","to":"root","message":"memory is gone","fp":"mem-alpha"}' \
    '{"id":"b8","ts":"2036-09-20T10:05:00+00:00","kind":"update","ref":"b7","to":"root","from":"bundle-orch","message":"still gone"}' \
    '{"id":"b9","ts":"2036-09-20T10:09:00+00:00","kind":"resolution","ref":"b7","to":"root","by":"steward","message":"resolved by steward"}' \
    >"$T/inbox/alpha.jsonl"
  cat >"$T/tail.mjs" <<'EOF'
import assert from 'node:assert/strict';
const { inboxTail } = await import(process.env.STATE_MJS);
const rows = inboxTail({ workspaces: [{ name: 'alpha' }] }, 8);
assert.equal(rows.length, 1, 'the blocker is the one row');
assert.equal(rows[0].id, 'b7', 'the tail dropped the id of the record it parsed');
assert.equal(rows[0].fp, 'mem-alpha');
assert.equal(rows[0].resolved.by, 'steward', 'the tail did not see the resolution that closed it');
process.stdout.write('tail: all good\n');
EOF
  local out
  out="$(STATE_MJS="$CEL_ROOT/tools/console/state.mjs" CEL_INBOX_DIR="$T/inbox" node "$T/tail.mjs" 2>&1)" \
    || { printf '%s\n' "$out"; _console_teardown; return 1; }
  assert_contains "$out" 'tail: all good'
  _console_teardown
}

# NEVER SHOW A BUTTON THAT CANNOT WORK. What the detail view offers is
# computed from the item's live state, not from the pane it was opened in.
test_console_detail_view_offers_only_actions_that_can_work() {
  _console_setup
  cat >"$T/actions.mjs" <<'EOF'
import assert from 'node:assert/strict';
const { detailActions, detailButtons, resolveOutcome } = await import(process.env.VIEWS_MJS);

const open = { id: 'b1', ws: 'alpha', kind: 'blocked', from: 'bundle-orch', message: 'x' };
assert.deepEqual(detailActions(open, ['b1']), { resolve: true, note: '' });
assert.deepEqual(detailButtons(open, ['b1'], true), ['resolve', 'reply', 'go to', 'target']);

// resolved: no button, and it says when and by whom
const done = { ...open, resolved: { ts: '2036-09-20T10:09:00+00:00', by: 'steward' } };
const a = detailActions(done, []);
assert.equal(a.resolve, false);
assert.match(a.note, /^resolved 2036-09-20 10:09 by steward$/);
assert.deepEqual(detailButtons(done, [], false), ['reply', 'go to']);

// a tail row for something that was never an open item at all
assert.equal(detailActions({ id: 'm1', kind: 'status' }, []).note, 'not an open item - this is the log');
// and the id-less row that started this: no identity, no button
assert.equal(detailActions({ kind: 'blocked' }, []).resolve, false);

// the outcome of a resolve is REPORTED, either way
assert.equal(resolveOutcome(open, { allow: true, ok: true, out: '' }), 'resolved b1');
assert.equal(resolveOutcome(open, { allow: true, ok: false, out: 'no open decision or blocker with id b1\nmore' }),
  'could not resolve b1: no open decision or blocker with id b1');
assert.equal(resolveOutcome(open, { allow: false, reason: 'the console routes' }), 'refused: the console routes');
process.stdout.write('actions: all good\n');
EOF
  local out
  out="$(VIEWS_MJS="$CEL_ROOT/tools/console/views.mjs" node "$T/actions.mjs" 2>&1)" \
    || { printf '%s\n' "$out"; _console_teardown; return 1; }
  assert_contains "$out" 'actions: all good'
  _console_teardown
}
