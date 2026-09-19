# shellcheck shell=bash
# What the pane is actually doing. The timers in lib/stall.sh answer "how long
# has it been quiet"; this answers "is that quiet healthy", which is the
# question every real failure on this box turned out to hang on.
#
# The endpoint is stubbed by replacing `curl` - the same posture as the Linear
# sweep in tests/steward.test.sh - so a test can hand the classifier any answer,
# any status code and any silence, and assert what the box does with it.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/stall.sh"
source "$CEL_ROOT/lib/liveness.sh"

_liveness_setup() { # [min_confidence]
  T="$(mktemp -d)"
  export CEL_CONFIG_FILE="$T/config.yaml"
  { printf 'console:\n  router:\n    provider: openrouter\n    model: alpha/decide-1\n'
    printf '    key_env: OPENROUTER_API_KEY\n'
    printf 'liveness:\n  min_confidence: %s\n' "${1:-0.6}"; } > "$CEL_CONFIG_FILE"
  export OPENROUTER_API_KEY=test-key
  export CEL_LIVENESS_URL="https://stub.invalid/alpha/decisions"
  export CEL_LIVENESS_STATE="$T/liveness-state"
  : > "$T/requests"
  LIVENESS_ACTIVITY=working LIVENESS_CONFIDENCE=0.9 LIVENESS_NEEDS=0.1
  LIVENESS_STATUS=200
}

# The endpoint, as a shell function. It records the body it was sent - the
# state discipline tests read it back - and answers the decisions shape.
curl() {
  local body="" url=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -H) case "$2" in @-) cat >/dev/null ;; esac; shift 2 ;;
      -d) body="$2"; shift 2 ;;
      http*) url="$1"; shift ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "$body" >> "$T/requests"
  [ "${LIVENESS_STATUS:-200}" = 200 ] || return 22   # curl -sf on an HTTP error
  jq -nc --arg a "$LIVENESS_ACTIVITY" --argjson c "$LIVENESS_CONFIDENCE" \
    --argjson n "$LIVENESS_NEEDS" \
    '{answers: {activity: {value: $a, confidence: $c}, needs_a_person: {probability: $n}}}'
}

_asked() { grep -c . "$T/requests" 2>/dev/null || printf 0; }

# --- what the model is told -------------------------------------------------

# THE STATE IS THE PANE AND THREE FACTS. A large state full of irrelevant
# detail is a documented failure mode of the classifier, and the fleet document
# is the biggest pile of irrelevant detail this box owns.
test_the_request_carries_the_pane_tail_and_the_three_facts_only() {
  _liveness_setup
  liveness_ask 'running the gate for the third time' working 640 running >/dev/null
  local body; body="$(cat "$T/requests")"
  assert_eq "$(printf '%s' "$body" | jq -r '.state.runtime_status')" working
  assert_eq "$(printf '%s' "$body" | jq -r '.state.seconds_since_output_changed')" 640
  assert_eq "$(printf '%s' "$body" | jq -r '.state.ledger_state')" running
  assert_contains "$(printf '%s' "$body" | jq -r '.state.pane')" 'running the gate'
  assert_eq "$(printf '%s' "$body" | jq -r '.state | keys | join(",")')" \
    'ledger_state,pane,runtime_status,seconds_since_output_changed'
  # the two questions, and their types
  assert_eq "$(printf '%s' "$body" | jq -r '.questions.activity.type')" choice
  assert_eq "$(printf '%s' "$body" | jq -r '.questions.needs_a_person.type')" noul
  assert_eq "$(printf '%s' "$body" | jq -r '.questions.activity.criteria | keys | sort | join(",")')" \
    'crashed,finished,looping,unclear,waiting_on_input,working'
  rm -rf "$T"
}

# The fleet document is not state the pane's own behaviour needs, and a worker
# id in the body is an invitation to answer about the wrong one.
test_the_request_never_carries_the_fleet_json() {
  _liveness_setup
  local fleet; fleet='{"workspaces":[{"name":"alpha","units":[{"name":"bundle"}]}]}'
  FLEET_JSON="$fleet" liveness_ask 'running the gate' working 640 running >/dev/null
  local body; body="$(cat "$T/requests")"
  case "$body" in *workspaces*|*bundle*) echo 'the fleet leaked into the request'; return 1;; esac
  rm -rf "$T"
}

# The key travels in a header read from stdin, never in the body and never on
# a command line other processes can read.
test_the_key_is_never_in_the_body() {
  _liveness_setup
  liveness_ask 'working away' working 100 running >/dev/null
  case "$(cat "$T/requests")" in *test-key*) echo 'the key was in the body'; return 1;; esac
  rm -rf "$T"
}

# --- the answers, and what each one is allowed to do ------------------------

test_looping_and_crashed_are_reported_at_any_age() {
  _liveness_setup
  assert_eq "$(liveness_verdict looping 0.81 30 running)" looping
  assert_eq "$(liveness_verdict crashed 0.77 5 running)" crashed
  rm -rf "$T"
}
# A normal approval pause is not news. Fifteen minutes is how long a person
# takes to come back to a question.
test_waiting_on_input_is_news_only_after_the_wait_window() {
  _liveness_setup
  assert_eq "$(liveness_verdict waiting_on_input 0.9 300 running)" ""
  assert_eq "$(liveness_verdict waiting_on_input 0.9 900 running)" waiting_on_input
  rm -rf "$T"
}
# `finished` is the "done but nobody collected it" case, and it is only that
# when the ledger still thinks the row is running.
test_finished_is_only_reported_while_the_ledger_says_running() {
  _liveness_setup
  assert_eq "$(liveness_verdict finished 0.95 60 running)" finished
  assert_eq "$(liveness_verdict finished 0.95 60 collected)" ""
  rm -rf "$T"
}
test_working_and_unclear_report_nothing() {
  _liveness_setup
  assert_eq "$(liveness_verdict working 0.99 9999 running)" ""
  assert_eq "$(liveness_verdict unclear 0.99 9999 running)" ""
  rm -rf "$T"
}
# Below the floor the model is guessing, and a guess about a worker is worse
# than the timer that was already there.
test_below_the_confidence_floor_the_timers_decide_alone() {
  _liveness_setup 0.6
  assert_eq "$(liveness_verdict looping 0.59 3600 running)" ""
  assert_eq "$(liveness_verdict looping 0.61 3600 running)" looping
  rm -rf "$T"
}

test_classify_turns_one_request_into_a_verdict() {
  _liveness_setup
  LIVENESS_ACTIVITY=looping LIVENESS_CONFIDENCE=0.81
  local out; out="$(liveness_classify 'npm test' working 2280 running)"
  assert_eq "$(printf '%s' "$out" | cut -f1)" looping
  assert_eq "$(printf '%s' "$out" | cut -f2)" looping
  assert_eq "$(printf '%s' "$out" | cut -f3)" 0.81
  assert_eq "$(_asked)" 1
  rm -rf "$T"
}

# --- the feature is optional ------------------------------------------------

# Down, unauthorised, or answering something unusable: all three are the same
# answer - nothing - and the timers behave exactly as they did before.
test_an_endpoint_that_refuses_produces_no_verdict() {
  _liveness_setup
  LIVENESS_STATUS=401
  assert_eq "$(liveness_classify 'anything' idle 9999 running)" ""
  LIVENESS_STATUS=500
  assert_eq "$(liveness_classify 'anything' idle 9999 running)" ""
  rm -rf "$T"
}
test_an_unknown_activity_is_discarded() {
  _liveness_setup
  LIVENESS_ACTIVITY=hungry LIVENESS_CONFIDENCE=0.99
  assert_eq "$(liveness_classify 'anything' idle 9999 running)" ""
  rm -rf "$T"
}
# No router key on the box is the ordinary case, and it must cost nothing:
# not a request, not a verdict, not an error.
test_with_no_key_liveness_is_off_and_asks_nobody() {
  _liveness_setup
  unset OPENROUTER_API_KEY
  assert_fails liveness_enabled
  assert_eq "$(liveness_classify 'anything' idle 9999 running)" ""
  assert_eq "$(_asked)" 0
  rm -rf "$T"
}
test_enabled_false_turns_it_off_with_a_key_present() {
  _liveness_setup
  printf 'liveness:\n  enabled: false\n' >> "$CEL_CONFIG_FILE"
  assert_fails liveness_enabled
  rm -rf "$T"
}

# --- the timers still stand on their own ------------------------------------

# The classification is an EXTRA input to stall_verdict, never a replacement:
# a box with no router behaves today exactly as it behaved yesterday.
test_the_existing_rules_are_unchanged_without_a_classification() {
  assert_eq "$(stall_verdict idle 'no marker here' 10801)" quiet
  assert_eq "$(stall_verdict idle 'no marker here' 3600)" ""
  assert_eq "$(stall_verdict '' '' 10)" vanished
  assert_contains "$(stall_verdict idle "$(printf '↻ F5 to Retry\n')" 3600)" dead-
}
# A marker with the age behind it is still a dead worker whatever the model
# says; the model fills the gap the timers leave.
test_a_classification_never_overrides_a_timer_that_fired() {
  assert_contains "$(stall_verdict idle "$(printf '↻ F5 to Retry\n')" 3600 0 looping)" dead-
  assert_eq "$(stall_verdict idle 'quiet as anything' 10801 0 looping)" quiet
}
# ...and a worker herdr calls `working` can now be reported, which is the whole
# point: three of the four real failures reported `working` throughout.
test_a_classification_reports_a_worker_the_runtime_calls_working() {
  assert_eq "$(stall_verdict working 'npm test' 60 0 looping)" looping
  assert_eq "$(stall_verdict working 'npm test' 60 0)" ""
}
# A worker that wrote its result is finished, not stalled - the CEL-22
# precedent - and nothing the model says reopens that.
test_a_worker_that_wrote_its_result_is_never_reported() {
  assert_eq "$(stall_verdict idle 'done' 99999 1 crashed)" ""
}

# --- who gets asked about ---------------------------------------------------

test_a_healthy_advancing_worker_is_never_a_candidate() {
  assert_fails stall_liveness_candidate working running 30 "" 0
}
test_the_four_shapes_are_candidates() {
  # working, but the pane text has not moved in five minutes
  stall_liveness_candidate working running 300 "" 0 || return 1
  # idle or done while the ledger still says running
  stall_liveness_candidate idle running 10 "" 0 || return 1
  stall_liveness_candidate done running 10 "" 0 || return 1
  # the marker rule already fired
  stall_liveness_candidate working running 10 'F5 to Retry' 0 || return 1
}
test_a_row_that_left_running_is_not_a_candidate() {
  assert_fails stall_liveness_candidate idle collected 9999 "" 0
}
test_a_worker_that_wrote_its_result_is_not_a_candidate() {
  assert_fails stall_liveness_candidate idle running 9999 "" 1
}
# A vanished agent is the timers' business: there is no pane left to read.
test_a_vanished_agent_is_not_a_candidate() {
  assert_fails stall_liveness_candidate '' running 9999 "" 0
  assert_fails stall_liveness_candidate gone running 9999 "" 0
}
test_the_still_window_is_configurable() {
  assert_fails env CEL_LIVENESS_STILL_SECS=600 bash -c \
    "source '$CEL_ROOT/lib/stall.sh'; stall_liveness_candidate working running 400 '' 0"
}

# --- how long the pane has looked the same ----------------------------------

# herdr exposes no last-output timestamp, so the age of a pane's APPEARANCE is
# kept here: the same text twice means the clock keeps running, different text
# resets it. Without this, "working but nothing is moving" has no number.
test_the_output_age_grows_while_the_text_is_unchanged_and_resets_when_it_moves() {
  _liveness_setup
  assert_eq "$(liveness_output_age alpha/ABC-1 'line one')" 0
  # backdate the recorded moment rather than sleeping
  liveness_backdate alpha/ABC-1 120
  assert_eq "$(liveness_output_age alpha/ABC-1 'line one')" 120
  assert_eq "$(liveness_output_age alpha/ABC-1 'line two')" 0
  rm -rf "$T"
}
test_two_workers_do_not_share_an_output_clock() {
  _liveness_setup
  liveness_output_age alpha/ABC-1 'x' >/dev/null
  liveness_backdate alpha/ABC-1 300
  assert_eq "$(liveness_output_age alpha/ABC-2 'x')" 0
  assert_eq "$(liveness_output_age alpha/ABC-1 'x')" 300
  rm -rf "$T"
}

# --- the answer, remembered for the views -----------------------------------

test_an_answer_is_remembered_for_the_fleet_and_expires() {
  _liveness_setup
  liveness_remember alpha/ABC-1 looping 0.81
  assert_eq "$(liveness_cached alpha/ABC-1)" "$(printf 'looping\t0.81')"
  liveness_backdate alpha/ABC-1 99999
  assert_eq "$(liveness_cached alpha/ABC-1)" ""
  assert_eq "$(liveness_cached alpha/NOBODY)" ""
  rm -rf "$T"
}

# --- it says it in words ----------------------------------------------------

# "quiet for 38m" is a number; "the same output has repeated for 38m and the
# timer would not have flagged this for another 2h" is the reason somebody
# acts on. The second half is why this ticket exists at all.
test_the_sentence_names_the_verdict_the_age_the_model_and_the_timer() {
  _liveness_setup
  local s; s="$(liveness_sentence looping looping 0.81 2280)"
  assert_contains "$s" 'looping'
  assert_contains "$s" '38m'
  assert_contains "$s" 'model 0.81'
  assert_contains "$s" 'the timer would not have flagged this for another 2h'
  rm -rf "$T"
}
test_the_sentence_is_empty_without_an_answer() {
  _liveness_setup
  assert_eq "$(liveness_sentence '' '' '' 60)" ""
  rm -rf "$T"
}

# --- nothing here can end a process -----------------------------------------

# The model REPORTS. There is no path from an answer to a kill, a release or a
# re-prompt, and the cheapest way to keep it that way is to say so in a test:
# lib/liveness.sh must not name the verbs that end a worker.
test_no_path_from_an_answer_to_a_kill() {
  local bad
  bad="$(grep -nE 'herdr|agent (stop|remove|terminate)|kill |cel-fanout (release|collect)|agent prompt' \
    "$CEL_ROOT/lib/liveness.sh" || true)"
  assert_eq "$bad" ""
}

# --- the console column -----------------------------------------------------

# The DISAGREEMENT is the signal: herdr saying `working` while the pane is
# looping is the exact shape every real failure took, so the live column shows
# both and agreement shows one.
test_the_live_column_shows_the_disagreement_only() {
  local out
  out="$(node --input-type=module -e "
    import { liveOf } from '$CEL_ROOT/tools/console/views.mjs';
    process.stdout.write([
      liveOf({ live: 'working', activity: 'looping' }),
      liveOf({ live: 'working', activity: 'working' }),
      liveOf({ live: 'idle', activity: 'finished' }),
      liveOf({ live: 'idle', activity: 'crashed' }),
      liveOf({ live: 'idle' }),
    ].join('|'));
  ")"
  assert_eq "$out" 'working!loop|working|idle|idle!crash|idle'
}

# --- `why` says it in words -------------------------------------------------

# The operator's question is "why is this one stuck", and "quiet for 38m" was
# never the answer. The sentence is the answer, and `why` is where it is read.
test_why_renders_the_sentence_for_a_classified_worker() {
  _liveness_setup
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  mkdir -p "$T/.cel" "$T/wt"
  printf '[{"id":"WG-WHY","repo":"widget","branch":"WG-WHY","pane":"wA:p1","alias":"widget-WG-WHY","worktree":"%s/wt","state":"running","ticket":"WG-WHY"}]\n' \
    "$T" > "$T/.cel/delegations.json"
  cat > "$T/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list") echo '{"result":{"agents":[{"pane_id":"wA:p1","agent_status":"working"}]}}' ;;
  "pane read"|"agent read") printf 'npm test\n' ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$T/herdr"
  liveness_remember WG-WHY looping 0.81
  local out
  out="$(cd "$T" && CEL_FANOUT_HERDR="$T/herdr" CEL_INBOX_DIR="$T/inbox" \
    "$CEL_ROOT/core/skills/fanout/bin/cel-fanout" why WG-WHY)"
  assert_contains "$out" 'looping'
  assert_contains "$out" 'model 0.81'
  assert_contains "$out" 'the timer would not have flagged this'
  rm -rf "$T"
}
