# shellcheck shell=bash
# What a worker's pane is actually doing - the judgment the timers in
# lib/stall.sh cannot make. A runtime's own status can be wrong for hours, so
# the pane tail is classified by a decisions request: small state, two typed
# questions, every number computed in bash and handed over as a named field.
#
# IT REPORTS AND NOTHING ELSE: no path from an answer to a kill, release or
# re-prompt. tests/liveness.test.sh asserts this file never names the verbs
# that end a process.
#
# IT IS ALSO OPTIONAL: no router, no key, a failing or slow endpoint, or an
# answer below the confidence floor all yield no verdict, and the timers decide.
[ -n "${_CEL_LIVENESS:-}" ] && return 0
_CEL_LIVENESS=1
# shellcheck source=lib/config.sh
. "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/quota.sh
. "${BASH_SOURCE[0]%/*}/quota.sh"  # the reset time a throttled pane
                                            # cannot tell you itself

# The wait before a pause counts as news: a person asked a question takes a
# few minutes to come back, and reporting an approval prompt the moment it
# appears is how a watcher becomes noise. The pane tail is forty lines because
# that is what a person scrolls back through, and more state on a small
# question is money spent on tokens nobody reads.
: "${CEL_LIVENESS_WAIT_SECS:=900}"
: "${CEL_LIVENESS_LINES:=40}"
: "${CEL_LIVENESS_MIN_CONFIDENCE:=0.6}"
# One request, ten seconds, no retries - the router's rule (tools/console/
# router.mjs), for the same reason: a watcher that retries costs most on
# exactly the days the provider is unwell, and its fall-back already works.
: "${CEL_LIVENESS_TIMEOUT:=10}"
# How long a remembered answer is worth showing in a view. The steward sweeps
# every five minutes; three sweeps is the point past which "it was looping" is
# history rather than news.
: "${CEL_LIVENESS_CACHE_SECS:=900}"

_LIVENESS_STATE="${CEL_LIVENESS_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/liveness-state}"
_liveness_state_file() { printf '%s' "${CEL_LIVENESS_STATE:-$_LIVENESS_STATE}"; }

# --- configuration ----------------------------------------------------------

# `liveness:` in ~/.local/share/cel/config.yaml, every key optional. The model
# defaults to the router's, because a box that has already chosen a decision
# model has no reason to choose a second one.
_liveness_cfg() { # <key> <default>
  local v; v="$(cel_config_get liveness "$1")"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}
liveness_min_confidence() { _liveness_cfg min_confidence "$CEL_LIVENESS_MIN_CONFIDENCE"; }
liveness_wait_secs()      { _liveness_cfg wait_secs "$CEL_LIVENESS_WAIT_SECS"; }
liveness_lines()          { _liveness_cfg lines "$CEL_LIVENESS_LINES"; }
liveness_still_secs()     { _liveness_cfg still_secs "${CEL_LIVENESS_STILL_SECS:-300}"; }
liveness_provider()       { local v; v="$(cel_config_get console.router provider)"; printf '%s' "${v:-openrouter}"; }
liveness_model() {
  local v; v="$(cel_config_get liveness model)"
  [ -n "$v" ] || v="$(cel_config_get console.router model)"
  printf '%s' "$v"
}

# The key, read from the environment variable the provider table names - never
# from the config file's own `key:`, and never onto a command line: it goes to
# the endpoint in a header curl reads from stdin, so it is not in /proc for
# other processes to read.
liveness_key() {
  local env_name v
  env_name="$(cel_config_get console.router key_env)"
  [ -n "$env_name" ] || env_name="$(cel_config_get console key_env)"
  [ -n "$env_name" ] && v="${!env_name:-}"
  # The console's own `key:` is the fall-back, exactly as the router reads it
  # (tools/console/router.mjs routerConfig): a box that put its key in the
  # config rather than the environment has configured a router, and liveness
  # must not decide it has not.
  [ -n "${v:-}" ] || v="$(cel_config_get console key)"
  printf '%s' "${v:-}"
}

# Where the decisions live. Derived from the chat URL already in agents.yaml
# exactly as the console's router derives it (tools/console/router.mjs
# decisionsUrl): two copies of an endpoint is how the two start disagreeing.
liveness_url() {
  [ -n "${CEL_LIVENESS_URL:-}" ] && { printf '%s' "$CEL_LIVENESS_URL"; return 0; }
  local provider api
  provider="$(liveness_provider)"
  api="$(yq -r ".providers.$provider.api // \"\"" "${CEL_ROOT:-.}/agents.yaml" 2>/dev/null || true)"
  [ -n "$api" ] && [ "$api" != null ] || return 0
  [ "$provider" = typesafe ] && { printf '%s' "$api"; return 0; }
  printf '%s' "${api%/}" | sed 's|/v1/chat/completions$|/alpha/decisions|'
}

# `false` is the one config value cel_config_get cannot carry: it reduces
# `.liveness.enabled // ""` and in YAML-land false is falsy, so an explicit
# off reads back as absent. Read directly, and treat an unreadable file as
# "not set" rather than as an answer.
_liveness_enabled_raw() {
  local f; f="$(cel_config_file)"
  [ -f "$f" ] || return 0
  local v; v="$(yq -r '.liveness.enabled' "$f" 2>/dev/null || true)"
  [ "$v" = null ] && v=""
  printf '%s' "$v"
}

# On when there is somewhere to ask and something to ask with. `enabled: false`
# turns it off with the key in place; `enabled: true` cannot turn it on without
# one, because a box with no endpoint has nothing to enable.
liveness_enabled() {
  case "$(_liveness_enabled_raw | tr '[:upper:]' '[:lower:]')" in
    false|no|0) return 1 ;;
  esac
  [ -n "$(liveness_url)" ] && [ -n "$(liveness_key)" ]
}

# One line for `cel doctor`, in the voice of the rest of it.
liveness_doctor_line() {
  if liveness_enabled; then
    printf 'liveness: on, %s/%s answers (min confidence %s)' \
      "$(liveness_provider)" "$(liveness_model)" "$(liveness_min_confidence)"
  else
    printf 'liveness: off - the stall timers decide alone'
  fi
}

# --- how long the pane has looked the same ----------------------------------
#
# herdr exposes no last-output timestamp. `state_change_seq` moves when a pane
# is merely focused and resets when herdr restarts, and the worktree mtime -
# what stall.sh uses - answers a different question: a worker looping on the
# same failing test writes files constantly while making no progress at all.
# So the APPEARANCE of the pane is remembered here, keyed per worker: the same
# text twice means the clock keeps running, different text resets it.
#
# One line per worker, fields: key hash changed_at activity confidence answered_at
_liveness_row() { # <key> -> the row, or ""
  local f; f="$(_liveness_state_file)"
  [ -f "$f" ] || return 0
  awk -v k="$1" '$1 == k { row = $0 } END { if (row != "") print row }' "$f"
}

# steward, fleet and status all write this file, each for its own workers: the
# rewrite re-reads it under one lock and replaces it through a temp of its own,
# so no writer drops another's row or shares its temp. Liveness is advisory: a
# box without flock(1) writes unlocked as it always did, and a lock not had
# within CEL_LIVENESS_LOCK_WAIT seconds skips this update (returns 1).
_liveness_put() { # <key> <hash> <changed_at> <activity> <confidence> <answered_at>
  local f fd="" tmp rc=0; f="$(_liveness_state_file)"
  mkdir -p "$(dirname "$f")"; touch "$f"
  if command -v flock >/dev/null 2>&1; then
    exec {fd}>"$f.lock"
    flock -w "${CEL_LIVENESS_LOCK_WAIT:-10}" "$fd" || { exec {fd}>&-; return 1; }
  fi
  if tmp="$(mktemp "$f.XXXXXX")"; then
    { awk -v k="$1" '$1 != k' "$f"; printf '%s %s %s %s %s %s\n' "$1" "$2" "$3" "${4:--}" "${5:--}" "${6:--}"; } \
      > "$tmp" && chmod --reference="$f" "$tmp" && mv -f "$tmp" "$f" || { rc=1; rm -f "$tmp"; }
  else rc=1; fi
  [ -z "$fd" ] || exec {fd}>&-
  return "$rc"
}

# The one clock every timestamp in this file reads. CEL_LIVENESS_NOW pins it,
# but only under the test harness (CEL_TESTING=1, set by tests/run.sh) and
# only as an integer: a stray export in a real process must never freeze ages
# or stop cached answers expiring.
_liveness_now() {
  if [ "${CEL_TESTING:-}" = 1 ]; then
    case "${CEL_LIVENESS_NOW:-}" in
      ''|*[!0-9]*) ;;
      # base ten, always: bash reads `08` as a malformed octal literal
      *) printf '%s' "$(( 10#$CEL_LIVENESS_NOW ))"; return 0 ;;
    esac
  fi
  date +%s
}

# Seconds since this worker's pane text last changed. First sighting is 0 -
# "we have never seen it before" is not evidence of stillness.
liveness_output_age() { # <key> <pane-text> -> seconds
  local key="$1" text="$2" hash now row ohash changed act conf ans
  now="$(_liveness_now)"
  hash="$(printf '%s' "$text" | cksum | tr -d ' ')"
  row="$(_liveness_row "$key")"
  # shellcheck disable=SC2086
  set -- $row
  ohash="${2:-}"; changed="${3:-}"; act="${4:--}"; conf="${5:--}"; ans="${6:--}"
  if [ "$ohash" != "$hash" ] || [ -z "$changed" ]; then
    _liveness_put "$key" "$hash" "$now" "$act" "$conf" "$ans" || true
    printf 0
    return 0
  fi
  printf '%s' "$(( now - changed ))"
}

# Move a worker's clocks back, for tests that may not sleep. Every timestamp in
# the row moves together, because they are all "how long ago".
liveness_backdate() { # <key> <seconds>
  local key="$1" back="$2" row ans
  row="$(_liveness_row "$key")"
  [ -n "$row" ] || return 0
  # shellcheck disable=SC2086
  set -- $row
  ans="${6:--}"
  case "$ans" in ''|-|*[!0-9]*) ans=- ;; *) ans=$(( ans - back )) ;; esac
  _liveness_put "$key" "$2" "$(( $3 - back ))" "$4" "$5" "$ans" || true
}

# The last answer about a worker, remembered so a VIEW can carry it without
# asking again: `cel fleet` is read in a loop and a request per row is a view
# people stop running.
liveness_remember() { # <key> <activity> <confidence>
  local row hash changed
  row="$(_liveness_row "$1")"
  # shellcheck disable=SC2086
  set -- $1 $2 $3 $row
  hash="${5:-0}"; changed="${6:-$(_liveness_now)}"
  _liveness_put "$1" "$hash" "$changed" "$2" "$3" "$(_liveness_now)" || true
}

# "<activity>\t<confidence>", or nothing when there is no answer or it has
# gone stale. Stale is silence, never a stale opinion presented as current.
liveness_cached() { # <key>
  local row now
  row="$(_liveness_row "$1")"
  [ -n "$row" ] || return 0
  # shellcheck disable=SC2086
  set -- $row
  [ -n "${4:-}" ] && [ "${4:-}" != "-" ] || return 0
  now="$(_liveness_now)"
  # PRESENCE, not "> 0": an answer recorded at time 0 is still an answer. A
  # row that was never answered has no activity, which the check above refuses.
  case "${6:-}" in ''|-|*[!0-9-]*) return 0 ;; esac
  [ $(( now - ${6} )) -le "$CEL_LIVENESS_CACHE_SECS" ] || return 0
  printf '%s\t%s' "$4" "$5"
}

# --- the questions ----------------------------------------------------------
#
# Two of them, asked together in one request (every question in a decisions
# request is evaluated in parallel, so the second costs nothing). Each
# criterion describes a concrete PANE APPEARANCE rather than an abstraction:
# the classifier is literal, and "the worker is stuck" is an abstraction it
# would have to interpret, while "the same command and the same output appear
# more than once with nothing new between them" is something it can read.
liveness_questions() {
  jq -nc '{
    activity: {
      type: "choice",
      instructions: "The text above is the last lines of one agent pane. What is that pane doing right now?",
      criteria: {
        working: "new output keeps appearing and it moves on: files being read or edited, a command running, test output scrolling, a commit being made",
        waiting_on_input: "the last thing on the pane is a question, an approval prompt, a menu, or a request for a decision that the agent cannot answer itself, and nothing has happened since",
        looping: "the same command, the same error or the same block of output appears more than once with nothing new between the repeats",
        crashed: "a stack trace, a fatal runtime or transport error, a retry prompt, or a bare shell prompt where an agent should be running",
        finished: "it says its work is done - a summary, a result written, a report or a final message - and nothing has happened since",
        unclear: "the lines do not show enough to tell which of the above it is"
      }
    },
    needs_a_person: {
      type: "noul",
      instructions: "Does moving this pane forward require a human or another agent to say something to it?"
    }
  }'
}

# THE STATE: the pane tail and three observed facts, named. Nothing else - not
# the fleet, not the diff, not the ticket. A large state full of irrelevant
# detail is a documented failure mode, and the numbers are computed in bash
# precisely so the model never has to do arithmetic on them.
liveness_state() { # <pane-text> <runtime-status> <secs-since-output-changed> <ledger-state>
  jq -nc --arg pane "$1" --arg rs "$2" --argjson secs "${3:-0}" --arg ls "$4" \
    '{pane: $pane, runtime_status: $rs, seconds_since_output_changed: $secs, ledger_state: $ls}'
}

liveness_request() { # <pane-text> <runtime-status> <secs> <ledger-state>
  jq -nc --arg model "$(liveness_model)" \
    --argjson state "$(liveness_state "$1" "$2" "${3:-0}" "$4")" \
    --argjson questions "$(liveness_questions)" \
    '{model: $model, state: $state, questions: $questions}'
}

# One request per candidate: each needs its own pane text, and a decisions
# request carries one state.
#
# "<activity>\t<confidence>\t<needs_a_person>", or nothing. An endpoint that is
# down, unauthorised, slow or answering something unreadable all land here as
# the same thing - silence - because every one of them means the same to the
# caller: the timers decide alone.
liveness_ask() { # <pane-text> <runtime-status> <secs> <ledger-state>
  liveness_enabled || return 0
  local url key out
  url="$(liveness_url)"; key="$(liveness_key)"
  out="$(printf 'authorization: Bearer %s\n' "$key" \
    | curl -sf -m "$CEL_LIVENESS_TIMEOUT" -X POST "$url" \
        -H @- -H 'content-type: application/json' \
        -d "$(liveness_request "$1" "$2" "${3:-0}" "$4")" 2>/dev/null || true)"
  [ -n "$out" ] || return 0
  # Read defensively: the endpoint spells an answer three or four ways
  # depending on the question type and the provider in front of it, and an
  # unreadable field is ABSENT rather than guessed at.
  printf '%s' "$out" | jq -r '
    (.answers.activity // empty) as $a
    | (if ($a | type) == "string" then $a else ($a.value // $a.choice // $a.answer // "") end) as $v
    | (if ($a | type) == "object" then ($a.confidence // 0) else 0 end) as $c
    | (.answers.needs_a_person // 0) as $n
    | (if ($n | type) == "object" then ($n.probability // $n.value // $n.noul // 0) else $n end) as $p
    | [$v, ($c | tostring), ($p | tostring)] | @tsv' 2>/dev/null || true
}

# WHAT THE ANSWER IS ALLOWED TO SAY. Below the confidence floor the model is
# guessing and the answer is discarded outright; above it, each activity maps
# to one verdict and two of them carry a condition of their own.
liveness_verdict() { # <activity> <confidence> <secs-since-output-changed> <ledger-state>
  local act="$1" conf="${2:-0}" secs="${3:-0}" ledger="${4:-}"
  [ -n "$act" ] || return 0
  awk -v c="$conf" -v f="$(liveness_min_confidence)" 'BEGIN { exit !(c + 0 >= f + 0) }' || return 0
  case "$act" in
    # Neither waits for the three-hour quiet timer.
    looping|crashed) printf '%s' "$act" ;;
    # A normal approval pause is not news until it has lasted.
    waiting_on_input)
      [ "${secs:-0}" -ge "$(liveness_wait_secs)" ] && printf 'waiting_on_input' ;;
    # "done, but nobody collected it" - and only while the ledger disagrees.
    finished) [ "$ledger" = running ] && printf 'finished' ;;
  esac
  return 0
}

# Ask and judge in one call: "<verdict>\t<activity>\t<confidence>", or nothing.
liveness_classify() { # <pane-text> <runtime-status> <secs> <ledger-state>
  local ans act conf verdict
  ans="$(liveness_ask "$1" "$2" "${3:-0}" "$4")"
  [ -n "$ans" ] || return 0
  act="$(printf '%s' "$ans" | cut -f1)"
  conf="$(printf '%s' "$ans" | cut -f2)"
  case "$act" in
    working|waiting_on_input|looping|crashed|finished|unclear) ;;
    # A label the endpoint invented is not an answer about this worker.
    *) return 0 ;;
  esac
  verdict="$(liveness_verdict "$act" "$conf" "${3:-0}" "$4")"
  [ -n "$verdict" ] || return 0
  printf '%s\t%s\t%s' "$verdict" "$act" "$conf"
}

# --- the three silences -----------------------------------------------------
#
# Everything above asks a model what a pane is DOING. These three ask nothing:
# they are recognised from the pane text alone, with no router, no key and no
# request, and each renders exactly like an agent thinking:
#
#   - a prompt TYPED BUT UNSUBMITTED in the composer (any pane, not only
#     workers): context at 0%, text below the divider, ledger `running`;
#   - a session that accepts input and fails every turn;
#   - an account whose rate-limit window is spent, which reads as idle.
#
# They REPORT, like everything else here.

# Text a pane prints about itself rather than about the work: the status line
# is below the composer divider and would otherwise count as "the operator
# typed something".
_liveness_is_chrome() { # <line>
  printf '%s' "$1" | grep -qiE '(^|[[:space:]])(ctx|context)[[:space:]:]*[0-9]+(\.[0-9]+)?%|^[[:space:]]*[─━═_-]{6,}[[:space:]]*$|^[[:space:]]*$'
}

# A turn the AGENT took. pi and claude both mark one with a bullet; the word
# form is here for runtimes that print a role instead. Matching the MARK
# rather than any particular wording is deliberate - the composer's own echo
# of what a human typed is not a turn.
_liveness_has_turn() { # <pane-text>
  printf '%s' "$1" | grep -qE '^[[:space:]]*([⏺●✳✻✶]|(assistant|Assistant)[[:space:]:>])'
}

# Context at zero means the session has never sent anything: a pane that has
# taken one turn is already above zero, so this is the cheapest possible
# "nothing has happened here".
_liveness_context_zero() { # <pane-text>
  printf '%s' "$1" | grep -qiE '(ctx|context)[[:space:]:]*0(\.0+)?%'
}

# Something a person or a dispatcher put in the composer and left there. The
# divider is the composer's top edge; anything below it that is not the pane's
# own chrome is unsent text.
_liveness_pending_text() { # <pane-text>
  local below line
  below="$(printf '%s\n' "$1" | awk '/^[[:space:]]*[─━═]{6,}[[:space:]]*$/ { seen = 1; out = ""; next } seen { out = out $0 "\n" } END { printf "%s", out }')"
  [ -n "$below" ] || return 1
  while IFS= read -r line; do
    _liveness_is_chrome "$line" || return 0
  done <<< "$below"
  return 1
}

# The error CLASS, not the message: wording changes between failures, so what
# is matched is "a terminal error line, repeated, with no turn between the
# prompts".
_liveness_repeated_error() { # <pane-text>
  local n
  n="$(printf '%s\n' "$1" \
    | grep -iE '(^|[^a-z])(error|exception|failed|refused|diverged)([^a-z]|$)' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[0-9]+/N/g' \
    | sort | uniq -c | sort -rn | awk 'NR == 1 { print $1 }')"
  [ -n "$n" ] && [ "$n" -ge 2 ]
}

# A provider limit - and ONLY when the pane is actually stopped on it.
#
# Matching the words anywhere would flag a worker running the quota suite or
# showing a diff containing `429`. So the limit must be on a line SHAPED like
# a provider refusal (one that begins with the error), and no agent turn may
# follow it. A false `throttled` sends an orchestrator to wait out a window
# that was never spent, which is worse than silence.
_liveness_is_throttled() { # <pane-text>
  printf '%s\n' "$1" | awk '
    tolower($0) ~ /^[[:space:]]*[^[:alnum:][:space:]]{0,3}[[:space:]]*(api[ _-]?error|http[ \/][0-9]|error|err|request failed|rate[ _]limit)/ &&
    tolower($0) ~ /(rate[_ ]limit|429|too many requests|quota exceeded)/ { lim = NR }
    /^[[:space:]]*([⏺●✳✻✶]|(assistant|Assistant)[[:space:]:>])/ { turn = NR }
    END { exit !(lim > 0 && lim > turn) }'
}

# WHEN, not just "blocked": the reset time is the half an operator acts on,
# read from the windows lib/quota.sh already reads.
liveness_reset_at() { # <cel-provider> -> a human time, or nothing
  [ -n "${1:-}" ] || return 0
  local sub p a t r
  sub="$(_sub_provider_for "$1" 2>/dev/null || true)"
  [ -n "$sub" ] || return 0
  while IFS=$'\t' read -r p a t; do
    [ "$p" = "$sub" ] || continue
    r="$(subscription_usage "$p" "$t" "$a" 2>/dev/null \
         | jq -r '((.windows[]? | select(.name == "5h") | .resets_at) // "") | tostring' 2>/dev/null | head -1)"
    case "$r" in ''|null) continue ;; esac
    sub_reset_human "$r"
    return 0
  done < <(_subscription_accounts 2>/dev/null || true)
  return 0
}

# "unstarted" | "erroring" | "throttled[\t<reset>]" | nothing.
#
# Order matters: a 429 is also an error line, and "throttled" is the report
# with a remedy in it. Nothing here is mutually exclusive with the model's own
# verdict - these are facts about the pane, and the model is an opinion about
# the work.
liveness_pane_silence() { # <pane-text> [provider]
  local text="${1:-}" provider="${2:-}" reset
  [ -n "$text" ] || return 0
  if _liveness_is_throttled "$text"; then
    reset="$(liveness_reset_at "$provider")"
    [ -n "$reset" ] && printf 'throttled\t%s' "$reset" || printf 'throttled'
    return 0
  fi
  # Both of the remaining two require that the agent has taken no turn: a pane
  # with work on it after the error recovered, and a false report on a
  # recovered worker is worse than the silence it replaces.
  if ! _liveness_has_turn "$text"; then
    if _liveness_context_zero "$text" && _liveness_pending_text "$text"; then
      printf 'unstarted'; return 0
    fi
    if _liveness_repeated_error "$text"; then printf 'erroring'; return 0; fi
  fi
  return 0
}

# It says it in words, like every other verdict here.
liveness_silence_sentence() { # <silence> [reset]
  local s="${1:-}" reset="${2:-}"
  [ -n "$s" ] || return 0
  case "$s" in
    unstarted) printf 'unstarted - the prompt is sitting in the composer, never submitted; re-prompt it (the worktree and the agent are fine)' ;;
    erroring)  printf 'erroring - the session accepts prompts and fails on every turn; it needs a restart, not another prompt' ;;
    throttled)
      printf 'throttled - the provider is refusing on a rate limit'
      [ -n "$reset" ] && printf ', it resets at %s' "$reset"
      printf '; waiting is the remedy, another worker is not' ;;
    *) printf '%s' "$s" ;;
  esac
  return 0
}

# The quiet rule's own threshold, read once so the sentence can say how much
# of it was left. Its own name rather than a source of stall.sh: this file is
# about the model, and stall.sh is about the clock.
: "${CEL_STALL_QUIET_SECS_FOR_SENTENCE:=${CEL_STALL_QUIET_SECS:-10800}}"

# IT SAYS IT IN WORDS. "quiet for 38m" is a number an operator still has to
# interpret; this is the sentence they act on, and its second half - how long
# the timer would have taken - is the whole argument for the feature.
liveness_sentence() { # <verdict> <activity> <confidence> <quiet-secs>
  local verdict="$1" act="${2:-}" conf="${3:-}" secs="${4:-0}"
  [ -n "$verdict" ] || return 0
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=0
  local what
  case "$verdict" in
    looping)          what="the same command and output have repeated for $(( secs / 60 ))m" ;;
    crashed)          what="the pane is showing a crash, not an agent, and has for $(( secs / 60 ))m" ;;
    waiting_on_input) what="it has been waiting on someone to answer it for $(( secs / 60 ))m" ;;
    finished)         what="its work is done and it is idle, while the ledger still says running" ;;
    *)                what="$verdict" ;;
  esac
  local left=$(( CEL_STALL_QUIET_SECS_FOR_SENTENCE - secs ))
  printf '%s - %s (model %s)' "$verdict" "$what" "${conf:-?}"
  [ "$left" -gt 0 ] \
    && printf '; the timer would not have flagged this for another %sh' "$(( (left + 1800) / 3600 ))"
  return 0
}
