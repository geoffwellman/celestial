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
import { writeFileSync } from 'node:fs';
const s = createServer((req, res) => {
  let b = '';
  req.on('data', (c) => { b += c; });
  req.on('end', () => {
    writeFileSync(process.env.RSTUB_BODY_FILE, b);
    writeFileSync(process.env.RSTUB_HEADERS_FILE, JSON.stringify(req.headers));
    const code = Number(process.env.RSTUB_STATUS || '200');
    if (code !== 200) { res.writeHead(code, { 'content-type': 'text/plain' }); res.end('nope'); return; }
    const probs = process.env.RSTUB_PROBS ? JSON.parse(process.env.RSTUB_PROBS) : undefined;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ answers: { intent: {
      value: process.env.RSTUB_INTENT,
      confidence: Number(process.env.RSTUB_CONFIDENCE),
      probabilities: probs,
    } } }));
  });
});
s.listen(0, '127.0.0.1', () => { writeFileSync(process.env.RSTUB_PORT_FILE, String(s.address().port)); });
EOF
  export RSTUB_BODY_FILE="$T/rbody.json" RSTUB_HEADERS_FILE="$T/rheaders.json"
  export RSTUB_PORT_FILE="$T/rport" RSTUB_INTENT="$1" RSTUB_CONFIDENCE="$2"
  export RSTUB_PROBS="${3:-}" RSTUB_STATUS="${4:-200}"
  rm -f "$RSTUB_PORT_FILE" "$RSTUB_BODY_FILE"
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
