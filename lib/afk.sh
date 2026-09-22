# shellcheck shell=bash
# cel afk - away from keyboard: what the factory may decide while nobody is
# watching.
#
# AFK CHANGES WHO DECIDES, NEVER WHAT IS REQUIRED. Measured over 2026-09-20/22,
# the work that stopped overnight had nothing to do with code: an approved,
# green, gate-verified PR sat 36 hours because two bot-review threads needed a
# human to type a reply; five rebases on that one PR each cost a worker restart
# and a ~25 minute gate; two PRs paused on "shall I land this?" when workspace
# policy already said `merge: self`; and documented follow-up work went
# undispatched waiting for a nod. None of that is a safety property - it is an
# orchestrator waiting for permission it already had.
#
# So a PR still needs its review, its green gate and its verdict. What AFK
# removes is the pause between a decision being obvious and a human being awake
# to say so, and it removes it for exactly four acts (the owner, 2026-09-22).
# Anything else waits, and the waiting is recorded rather than silent.
[ -n "${_CEL_AFK:-}" ] && return 0
_CEL_AFK=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# SLEEPING IS A PROPERTY OF THE OPERATOR, not of one product: the state lives
# in the box's own state dir, so every workspace on this box reads one answer
# rather than four that disagree. Resolved per call, never frozen at source
# time, because the tests point it at a fixture AFTER sourcing this file.
afk_dir()   { printf '%s' "${CEL_AFK_STATE:-$HOME/.local/share/cel/afk}"; }
_afk_state(){ printf '%s/state.json' "$(afk_dir)"; }
_afk_log()  { printf '%s/log.jsonl' "$(afk_dir)"; }
# Overridable so the named GitHub exception can be watched in a test without
# reaching a real review thread.
_afk_gh()   { printf '%s' "${CEL_AFK_GH:-gh}"; }

# The four, and the words each one is recorded under. The authorisation is
# written beside every act because "the agent merged something" and "the agent
# merged something under pre-authorisation 2" are different mornings.
afk_authorisation() { # <act> -> the pre-authorisation that covers it
  case "$1" in
    resolve_thread) printf 'pre-authorisation 1 (bot review thread verified fixed and reviewer-confirmed)' ;;
    land)           printf 'pre-authorisation 2 (approved, green, gate-verified, mergeable)' ;;
    rebase_retry)   printf 'pre-authorisation 3 (pushed behind by another merge, no new work)' ;;
    dispatch)       printf 'pre-authorisation 4 (a follow-up a reviewer or scout wrote down)' ;;
    *) return 1 ;;
  esac
}

_afk_refuse() { # <act> <reason> -> always 1
  printf 'afk: %s waits - %s\n' "$1" "$2" >&2
  return 1
}

# `--until` in whatever an operator types at 1am: `+8h`, `8h`, `07:30`, an ISO
# timestamp. Anything date(1) cannot read is a refusal rather than a guess - an
# AFK whose expiry silently became "now" would be an AFK that never acts, and
# one that silently became "never" is the fortnight of unattended merges.
_afk_parse_until() { # <text> -> epoch seconds
  local t="$1" spec="$1"
  [ -n "$t" ] || return 1
  case "$t" in
    +*[hH]) spec="${t#+}"; spec="${spec%[hH]} hours" ;;
    +*[mM]) spec="${t#+}"; spec="${spec%[mM]} minutes" ;;
    [0-9]*[hH]) spec="${t%[hH]} hours" ;;
    [0-9]*[mM]) case "$t" in *:*) spec="$t" ;; *) spec="${t%[mM]} minutes" ;; esac ;;
  esac
  date -d "$spec" +%s 2>/dev/null
}

_afk_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# The state as one object, for doctor, the steward and the console. `expired`
# is computed here and nowhere else: four surfaces each deciding for themselves
# whether an hour has passed is four surfaces that can disagree at 03:00.
afk_state_json() {
  local f; f="$(_afk_state)"
  if [ ! -s "$f" ]; then printf '{"on":false,"expired":false}\n'; return 0; fi
  jq -c --argjson now "$(date +%s)" '
    . as $s
    | ($s.until_epoch // 0) as $u
    | ($s.on == true and $u > 0 and $u <= $now) as $exp
    | $s + {expired: $exp, on: ($s.on == true)}' "$f" 2>/dev/null \
    || printf '{"on":false,"expired":false}\n'
}

# ON only while the hour holds. A past `--until` means OFF, whatever the file
# says - the file is left alone on purpose so doctor and the steward can report
# that it was left on, which is the condition nobody would otherwise notice.
afk_active()  { [ "$(afk_state_json | jq -r '.on and (.expired | not)')" = true ]; }
afk_expired() { [ "$(afk_state_json | jq -r '.expired')" = true ]; }

afk_record() { # <act> <authorisation> <detail>
  mkdir -p "$(afk_dir)"
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg act "$1" \
    --arg auth "$2" --arg detail "$3" \
    '{at:$at, act:$act, authorisation:$auth, detail:$detail}' >> "$(_afk_log)"
}

afk_log_json() { cat "$(_afk_log)" 2>/dev/null || true; }

# GENERAL PERMISSION TO COMMENT IS NOT WHAT WAS GRANTED. Workspace policy
# forbids agents posting to GitHub; pre-authorisation 1 is a NAMED exception
# for bot-review threads on our own PRs while AFK, and this is the only door.
afk_post_allowed() { # <kind>
  case "$1" in
    bot_thread_resolution) return 0 ;;
    *) _afk_refuse "a GitHub post of kind '$1'" \
         "posting to GitHub is not pre-authorised; only a bot review thread's resolution is" ;;
  esac
}

# AFK NEVER TURNS ITS OWN SCOPE UP. Branch protection, repository settings and
# any policy - including this one - are the operator's, awake.
afk_policy_change_allowed() { # <what>
  _afk_refuse "a change to $1" \
    "AFK never changes policy, repository settings or its own scope - it changes who decides, not what is required"
}

# EVIDENCE, ACT BY ACT. Each refusal is named, because "refused" in a log at
# 04:00 tells the morning nothing about what to fix.
_afk_check_resolve_thread() { # <evidence-json>
  local e="$1"
  [ "$(jq -r '.bot // false' <<<"$e")" = true ] \
    || { _afk_refuse resolve_thread "only bot review threads may be resolved while AFK - a human's thread is a conversation"; return 1; }
  [ -n "$(jq -r '.fixed_commit // ""' <<<"$e")" ] \
    || { _afk_refuse resolve_thread "the finding is not fixed in any pushed commit"; return 1; }
  [ -n "$(jq -r '.fixed_summary // ""' <<<"$e")" ] \
    || { _afk_refuse resolve_thread "nothing here says WHAT was fixed, and a bare 'resolved' is not a reply"; return 1; }
  # A verdict recorded BEFORE the fix confirms the finding, not the fix. This
  # is the whole difference between a reviewer who has seen the change and a
  # reviewer who has seen the complaint.
  [ "$(jq -r '.reviewer_verdict // ""' <<<"$e")" = approved ] \
    && [ "$(jq -r '(.reviewer_verdict_at // "") > (.fixed_at // "")' <<<"$e")" = true ] \
    || { _afk_refuse resolve_thread "no reviewer confirmed the fix after the commit that made it"; return 1; }
}

_afk_check_land() { # <evidence-json>
  local e="$1" gate
  [ "$(jq -r '.review // ""' <<<"$e")" = approved ] \
    || { _afk_refuse land "no reviewer verdict of approved - AFK removes the pause, not the review"; return 1; }
  [ "$(jq -r '.checks // ""' <<<"$e")" = green ] \
    || { _afk_refuse land "a red check is a finding, not a formality"; return 1; }
  gate="$(jq -r '.gate // ""' <<<"$e")"
  case "$gate" in
    pass|ci) ;;
    fail) _afk_refuse land "the repo's gate did not pass - a worker fixes it, then land again"; return 1 ;;
    # CEL-56's fourth outcome: a gate that reported nothing did not fail and
    # did not pass, so there is nothing here to merge on and nothing to send a
    # worker after either.
    *) _afk_refuse land "the gate produced no verdict ($gate) - re-run collect and find out what is killing it"; return 1 ;;
  esac
  [ "$(jq -r '.mergeable // false' <<<"$e")" = true ] \
    || { _afk_refuse land "the PR conflicts with its base - a worker rebases it, then land again"; return 1; }
  [ "$(jq -r '.author // ""' <<<"$e")" = fleet ] \
    || { _afk_refuse land "not this fleet's PR - a colleague's PR is theirs to land"; return 1; }
}

_afk_check_rebase_retry() { # <evidence-json>
  local e="$1"
  [ "$(jq -r '.was_mergeable // false' <<<"$e")" = true ] \
    || { _afk_refuse rebase_retry "this PR was not mergeable before the merge that pushed it behind - that is work, not a retry"; return 1; }
  [ "$(jq -r '.behind // false' <<<"$e")" = true ] \
    || { _afk_refuse rebase_retry "nothing pushed this branch behind - there is no retry to make"; return 1; }
  [ "$(jq -r '.new_work // false' <<<"$e")" = false ] \
    || { _afk_refuse rebase_retry "there is new work on the branch - a rebase carrying changes nobody reviewed is not a retry"; return 1; }
  [ "$(jq -r '.conflicts // false' <<<"$e")" = false ] \
    || { _afk_refuse rebase_retry "the rebase conflicts - stop, record it, and leave it for the morning"; return 1; }
}

_afk_check_dispatch() { # <evidence-json>
  local e="$1"
  case "$(jq -r '.source // ""' <<<"$e")" in
    reviewer|scout) ;;
    *) _afk_refuse dispatch "no reviewer or scout finding behind it - AFK dispatches what was written down, not what looked like a good idea"; return 1 ;;
  esac
  [ -n "$(jq -r '.quote // ""' <<<"$e")" ] \
    || { _afk_refuse dispatch "no reviewer or scout finding is quoted in the spec"; return 1; }
  [ "$(jq -r '(.workers // 0) < (.cap // 0)' <<<"$e")" = true ] \
    || { _afk_refuse dispatch "the worker cap is full ($(jq -r '.workers // 0' <<<"$e")/$(jq -r '.cap // 0' <<<"$e"))"; return 1; }
  # A queue emptied overnight into an exhausted account helps nobody.
  [ "$(jq -r '(.quota_pct // 0) > (.quota_floor // 0)' <<<"$e")" = true ] \
    || { _afk_refuse dispatch "below the declared quota floor ($(jq -r '.quota_pct // 0' <<<"$e")% left, floor $(jq -r '.quota_floor // 0' <<<"$e")%)"; return 1; }
}

# THE ONE DOOR. Every autonomous act while AFK comes through here: the mode has
# to be on and unexpired, the act has to be one of the four, its own evidence
# has to be present, and it has to be happening where this orchestrator lives.
# Then - and only then - it is recorded.
afk_authorise() { # <act> <evidence-json> [detail]
  local act="$1" e="${2:-{\}}" detail="${3:-}" auth
  auth="$(afk_authorisation "$act")" \
    || { _afk_refuse "$act" "that is not one of the four pre-authorised acts"; return 1; }
  if ! afk_active; then
    if afk_expired; then
      _afk_refuse "$act" "AFK expired at $(afk_state_json | jq -r '.until_text // .until // "an hour that has passed"') - turn it on again, or do this awake"
      return 1
    fi
    _afk_refuse "$act" "AFK is off; this waits for the operator"
    return 1
  fi
  # NOT SOMEBODY ELSE'S PRODUCT. An orchestrator asleep in one workspace is not
  # an orchestrator loose on the box.
  local own tgt
  own="$(jq -r '.own_workspace // ""' <<<"$e")"; tgt="$(jq -r '.workspace // ""' <<<"$e")"
  if [ -n "$own" ] && [ -n "$tgt" ] && [ "$own" != "$tgt" ]; then
    _afk_refuse "$act" "'$tgt' is another orchestrator's workspace - AFK acts where it was armed"
    return 1
  fi
  "_afk_check_$act" "$e" || return 1
  [ -n "$detail" ] || detail="$(jq -rc '. | tostring' <<<"$e" 2>/dev/null || printf '%s' "$e")"
  afk_record "$act" "$auth" "$detail"
  printf '%s authorised: %s\n' "$act" "$auth"
}

# THE NAMED EXCEPTION, IN FULL. The reply states what was fixed and cites the
# commit that fixed it; only then is the thread resolved. The refusal happens
# BEFORE gh is reached - a reply posted and then withdrawn is a comment the
# author has already been mailed.
afk_resolve_thread() { # <slug> <pr-number> <thread-id> <evidence-json>
  local slug="$1" pr="$2" thread="$3" e="$4" gh body
  afk_post_allowed bot_thread_resolution >/dev/null || return 1
  afk_authorise resolve_thread "$e" "$slug#$pr thread $thread" >/dev/null || return 1
  gh="$(_afk_gh)"
  body="$(jq -r '"Fixed in \(.fixed_commit): \(.fixed_summary). Resolved by the fleet while the operator is away (cel afk, pre-authorisation 1); a reviewer confirmed the fix after that commit."' <<<"$e")"
  "$gh" api graphql -f query='mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t,body:$b}){clientMutationId}}' \
    -f t="$thread" -f b="$body" >/dev/null \
    || { c_warn "afk: the reply to $thread did not post - the thread is left open"; return 1; }
  "$gh" api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' \
    -f t="$thread" >/dev/null \
    || { c_warn "afk: replied to $thread but could not resolve it"; return 1; }
  c_ok "resolved $slug#$pr thread $thread (fixed in $(jq -r .fixed_commit <<<"$e"))"
}

cmd_afk() {
  local sub="${1:-status}"; shift || true
  case "$sub" in
    on)
      local until_text="" reason=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --until)  until_text="$2"; shift 2 ;;
          --reason) reason="$2"; shift 2 ;;
          *) die "cel afk on: unknown argument '$1' (want --until <when> or --reason <text>)" ;;
        esac
      done
      local epoch=0
      if [ -n "$until_text" ]; then
        epoch="$(_afk_parse_until "$until_text")" \
          || die "cel afk on: cannot read '--until $until_text' as a time - say +8h, 07:30 or an ISO timestamp"
      fi
      mkdir -p "$(afk_dir)"
      jq -n --arg since "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg reason "$reason" \
        --arg ut "$until_text" --argjson ue "$epoch" \
        '{on:true, since:$since, reason:$reason, until_text:$ut,
          until:(if $ue > 0 then (($ue|todate)) else "" end), until_epoch:$ue}' \
        > "$(_afk_state)"
      if [ "$epoch" -gt 0 ]; then
        c_ok "AFK is on until $(_afk_iso "$epoch")${reason:+ ($reason)}"
      else
        # An AFK with no hour on it is the one that stays on because nobody
        # turned it off. It is allowed, and it is said out loud.
        c_warn "AFK is on with NO expiry${reason:+ ($reason)} - nothing will turn it off but you: cel afk off"
      fi
      ;;
    off)
      mkdir -p "$(afk_dir)"
      printf '{"on":false,"expired":false}\n' > "$(_afk_state)"
      c_ok "AFK is off - decisions wait for you again"
      ;;
    status)
      local s; s="$(afk_state_json)"
      if [ "${1:-}" = "--json" ]; then printf '%s\n' "$s"; return 0; fi
      if [ "$(jq -r .on <<<"$s")" != true ]; then c_ok "AFK is off"; return 0; fi
      if [ "$(jq -r .expired <<<"$s")" = true ]; then
        c_warn "AFK EXPIRED at $(jq -r '.until // .until_text' <<<"$s") and is still on - cel afk off"
        return 0
      fi
      c_ok "AFK is on until $(jq -r '(.until // .until_text) | if . == "" then "no declared hour" else . end' <<<"$s")$(jq -r 'if .reason == "" then "" else " (" + .reason + ")" end' <<<"$s")"
      ;;
    log)
      if [ "${1:-}" = "--json" ]; then afk_log_json; return 0; fi
      local n; n="$(afk_log_json | wc -l)"
      if [ "$n" -eq 0 ]; then c_ok "AFK did nothing autonomous"; return 0; fi
      afk_log_json | jq -r '"  \(.at)  \(.act)  \(.detail)  [\(.authorisation)]"'
      ;;
    *) die "usage: cel afk on [--until <when>] [--reason <text>] | off | status [--json] | log [--json]" ;;
  esac
}
