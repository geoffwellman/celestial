# shellcheck shell=bash
# RANKING WHAT IS LEFT IN A MAILBOX.
#
# This is the third of CEL-43's three fixes and deliberately the last: it runs
# over the UNREAD set only, after status stopped being mail and after a
# mailbox with no reader became a fault. Ranking a pile of 553 messages would
# have been a way of living with the pile.
#
# WHAT THE MODEL DOES, AND ONLY THAT: it supplies a LEVEL per message. Counts,
# ages, ordering, the cut and the fallback are the code's. A classifier that
# also decided how many lines to draw would be a classifier whose bad day is
# an operator's missing escalation - so below `triage.min_confidence` a
# message keeps its kind's default rank and an unreachable model degrades to
# today's ordering rather than losing anything.
#
# One request, one `score` question per message: the decisions endpoint
# evaluates every question in a request in parallel, and the messages share no
# state, so a question each is the shape that fits. `score` returns a
# probability-weighted position over ORDERED LEVEL DESCRIPTIONS, which is a
# thing a classifier can do - "rate this 0-3" is not (the same reasoning as
# tools/console/router.mjs's ATTENTION_LEVELS).
[ -n "${_CEL_TRIAGE:-}" ] && return 0
_CEL_TRIAGE=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"
# shellcheck source=lib/manifest.sh
. "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"
# shellcheck source=lib/inbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/inbox.sh"

# The levels, concrete and in order. Vague levels ("high", "medium") make a
# classifier guess at the rubric; these say what a person would DO.
TRIAGE_LEVELS='[
  "informational - a person never needs to act",
  "useful context - read when convenient",
  "needs an answer, but not today",
  "blocking work right now - answer first"
]'

# Below the floor the model is guessing, and a guess must not be able to push
# an escalation under a status line. The kind's own default stands instead -
# which IS today's ordering, so the degraded path is the old behaviour.
triage_min_confidence() {
  local v; v="$(cel_config_get triage min_confidence)"
  [ -n "$v" ] || v=0.6
  printf '%s' "$v"
}

triage_top_n() {
  local v; v="$(cel_config_get inbox top_n)"
  case "$v" in ''|*[!0-9]*) v=3 ;; esac
  printf '%s' "$v"
}

# What each kind means when nobody has scored it: a blocker is somebody
# stopped, a decision or an escalation wants an answer, status wants nothing.
triage_default_rank() { # <kind>
  case "$1" in
    blocked) printf 3 ;;
    decision|escalation) printf 2 ;;
    update) printf 1 ;;
    *) printf 0 ;;
  esac
}

# One line per scored id: `<id><TAB><rank>`. A FILE, not a process cache: the
# console redraws every ten seconds and the shell is a fresh process every
# time, so an in-memory cache would be a score per draw - a provider bill per
# operator per day. A message is scored once and never again; ids are
# immutable and so is the text behind them.
_triage_cache_file() {
  printf '%s' "${CEL_TRIAGE_CACHE:-$(_inbox_dir)/triage.cache}"
}

_triage_cached() { # <id> -> rank, or nothing
  local f; f="$(_triage_cache_file)"
  [ -f "$f" ] || return 0
  awk -F'\t' -v id="$1" '$1 == id { print $2; exit }' "$f"
}

_triage_remember() { # <id> <rank>
  local f; f="$(_triage_cache_file)"
  mkdir -p "$(dirname "$f")"
  printf '%s\t%s\n' "$1" "$2" >> "$f"
}

# Where the decisions endpoint is. The console's router block already names a
# provider, a model and a key for exactly this kind of question
# (`console.router` in config.yaml), so triage reuses it rather than asking an
# operator to configure a second one. The URL derivation is the bash twin of
# tools/console/router.mjs's decisionsUrl - two copies of an endpoint is how
# the two start disagreeing, so it is written the same way in both places and
# tested here.
triage_decisions_url() { # <provider> <api>
  [ -n "${2:-}" ] || return 0
  case "$1" in
    typesafe) printf '%s' "$2" ;;
    *) printf '%s' "$2" | sed -E 's#/v1/chat/completions/?$#/alpha/decisions#' ;;
  esac
}

# The one HTTP call. CEL_TRIAGE_POST names a command to run instead of curl -
# the seam a test drives this through, so the suite never needs a key, a
# network or anybody's credit. Body on stdin, JSON document on stdout.
_triage_post() { # <body on stdin>
  if [ -n "${CEL_TRIAGE_POST:-}" ]; then
    [ -x "${CEL_TRIAGE_POST}" ] || return 1
    "$CEL_TRIAGE_POST" || return 1
    return 0
  fi
  have curl || return 1
  local provider model key_env key api url
  provider="$(cel_config_get console.router provider)"
  [ -n "$provider" ] || provider=openrouter
  model="$(cel_config_get console.router model)"
  key_env="$(cel_config_get console.router key_env)"
  [ -n "$key_env" ] || key_env="$(cel_config_get console key_env)"
  [ -n "$key_env" ] || key_env="$(provider_get "$provider" key_env)"
  key="${key_env:+${!key_env:-}}"
  [ -n "$key" ] || key="$(cel_config_get console key)"
  [ -n "$key" ] || return 1
  api="$(provider_get "$provider" api)"
  url="$(triage_decisions_url "$provider" "$api")"
  [ -n "$url" ] || return 1
  # Ten seconds, NO RETRIES, exactly as the console's router: a ranker that
  # retries costs most on the days the provider is unwell, and the fallback is
  # already a working path.
  curl -fsS --max-time "${CEL_TRIAGE_TIMEOUT:-10}" \
    -H 'content-type: application/json' -H "authorization: Bearer $key" \
    --data-binary @- "$url" 2>/dev/null
}

# Score every message that has no cached rank, in ONE request. Reads JSON
# lines on stdin, writes nothing but the cache.
_triage_score() { # <json-lines on stdin>
  local pending body doc
  pending="$(cat)"
  [ -n "$pending" ] || return 0
  body="$(printf '%s\n' "$pending" | jq -sc --argjson levels "$TRIAGE_LEVELS" \
    --arg model "$(cel_config_get console.router model)" '
    {model: $model,
     state: {messages: map({id: .id, kind: .kind, from: .from, ts: .ts, message: .message})},
     questions: (map({key: ("m_" + .id),
                      value: {type: "score",
                              instructions: ("How much does this message need the operator right now? "
                                             + .kind + " from " + .from + ": " + .message),
                              levels: $levels}}) | from_entries)}')"
  doc="$(printf '%s' "$body" | _triage_post)" || return 1
  [ -n "$doc" ] || return 1
  # The endpoint spells an answer several ways depending on the provider in
  # front of it. Read defensively: an unreadable answer is ABSENT, and absent
  # means the kind's default stands.
  local floor; floor="$(triage_min_confidence)"
  local id rank
  while IFS=$'\t' read -r id rank; do
    [ -n "$id" ] && [ -n "$rank" ] || continue
    _triage_remember "$id" "$rank"
  done < <(printf '%s' "$doc" | jq -r --argjson floor "$floor" '
    (.answers // {}) | to_entries[]
    | .key as $k | .value as $a
    | ((if ($a | type) == "object" then ($a.value // $a.score // $a.level) else $a end) | tonumber?) as $v
    | ((if ($a | type) == "object" then ($a.confidence // $a.probability // 1) else 1 end) | tonumber?) as $c
    | select($v != null and $c != null and $c >= $floor)
    | [($k | sub("^m_"; "")), ($v | round)] | @tsv' 2>/dev/null || true)
}

# The unread mail for a reader, each item carrying a `rank`, highest first.
# THE ORDERING IS THE CODE'S: rank descending, then oldest first, so the line
# at the top is the most urgent thing that has been waiting longest.
triage_ranked() { # <ws> <who>
  local items; items="$(inbox_unread_json "$1" "$2")"
  [ -n "$items" ] || return 0
  local cached unscored id
  unscored=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    cached="$(_triage_cached "$id")"
    [ -n "$cached" ] || unscored="$unscored$id
"
  done < <(printf '%s\n' "$items" | jq -r '.id')
  if [ -n "$unscored" ]; then
    printf '%s\n' "$items" \
      | jq -c --arg ids "$unscored" '. as $m | select(($ids | split("\n")) | index($m.id))' \
      | _triage_score || true
  fi
  # One pass over the cache in jq rather than a shell loop per message: a
  # mailbox with hundreds of unread items is exactly the case this exists for.
  # The kind defaults below are triage_default_rank's, spelled in jq so the
  # whole ordering is one expression; the two are asserted equal by the suite.
  local cache raw; cache="$(_triage_cache_file)"
  raw="$(cat "$cache" 2>/dev/null || true)"
  printf '%s\n' "$items" | jq -sc --arg raw "$raw" '
    ($raw | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // null)})
      | from_entries) as $ranks
    | map(. + {rank: ($ranks[.id]
        // (if .kind == "blocked" then 3
            elif .kind == "decision" or .kind == "escalation" then 2
            elif .kind == "update" then 1 else 0 end))})
    | sort_by([(0 - .rank), .ts, .id])
    | .[]'
}

# The top `inbox.top_n`, one line each, then `and N more`. The cut is here,
# not in the model: a ranker that also decided how much to show would be able
# to hide something by scoring it low AND shortening the list.
triage_render() { # <ws> <who> [json]
  local ws="$1" who="$2" json="${3:-0}" n top ranked
  ranked="$(triage_ranked "$ws" "$who")"
  [ -n "$ranked" ] || return 0
  if [ "$json" = 1 ]; then printf '%s\n' "$ranked"; return 0; fi
  top="$(triage_top_n)"
  n="$(printf '%s\n' "$ranked" | grep -c . || true)"
  printf '%s\n' "$ranked" | head -n "$top" \
    | jq -r '"\(.rank) [\(.ts[11:16]) \(.kind) from \(.from)] \(.message)"'
  [ "${n:-0}" -gt "$top" ] && printf 'and %s more\n' "$(( n - top ))"
  return 0
}
