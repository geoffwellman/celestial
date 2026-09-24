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
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"

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
# A reply or a rebase acts for the workspace that owns the PR (CEL-70): as its
# `github.user` when it declares one, refused if that account is not logged
# in, and exactly today's call when nothing owns it or nothing is declared.
_afk_ws_gh() { # <wsdir-or-empty> <gh args...>
  local w="$1"; shift
  if [ -n "$w" ]; then CEL_WS_GH_BIN="$(_afk_gh)" ws_gh "$w" "$@"; else "$(_afk_gh)" "$@"; fi
}
_afk_wsdir_for_slug() { # <owner/name> -> wsdir, or nothing
  local n w r
  for n in $(registry_names 2>/dev/null || true); do
    w="$(registry_path "$n" 2>/dev/null)" || continue
    [ -f "$w/workspace.yaml" ] || continue
    for r in $(ws_repo_names "$w"); do
      [ "$(ws_repo_github_slug "$w" "$r" 2>/dev/null || true)" = "$1" ] && { printf '%s' "$w"; return 0; }
    done
  done
  return 0
}

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
  # A queue emptied overnight into an exhausted account helps nobody. A floor of
  # zero is no declared floor, and unknown remaining is only a refusal where a
  # floor WAS declared: "unknown never vetoes" is the plane's rule everywhere
  # else (lib/quota.sh), but a declared floor nobody can measure against is not
  # permission to spend - it is a reading this process could not take.
  local floor pct
  floor="$(jq -r '.quota_floor // 0' <<<"$e")"; pct="$(jq -r '.quota_pct // -1' <<<"$e")"
  if awk -v f="$floor" 'BEGIN { exit !(f+0 > 0) }'; then
    awk -v p="$pct" 'BEGIN { exit !(p+0 >= 0) }' \
      || { _afk_refuse dispatch "a quota floor of $floor is declared and this process could not read what is left"; return 1; }
    awk -v p="$pct" -v f="$floor" 'BEGIN { exit !(p+0 > f+0) }' \
      || { _afk_refuse dispatch "below the declared quota floor ($pct left, floor $floor)"; return 1; }
  fi
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
  # an orchestrator loose on the box. The scope AFK was armed with is the
  # authority; an act may also carry its own `own_workspace`, and either
  # disagreeing with the act's target is a refusal.
  local own tgt
  own="$(jq -r '.own_workspace // ""' <<<"$e")"; tgt="$(jq -r '.workspace // ""' <<<"$e")"
  [ -n "$own" ] || own="$(afk_state_json | jq -r '.scope // ""')"
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
  local slug="$1" pr="$2" thread="$3" e="$4" w body
  afk_post_allowed bot_thread_resolution >/dev/null || return 1
  afk_authorise resolve_thread "$e" "$slug#$pr thread $thread" >/dev/null || return 1
  w="$(_afk_wsdir_for_slug "$slug")"
  body="$(jq -r '"Fixed in \(.fixed_commit): \(.fixed_summary). Resolved by the fleet while the operator is away (cel afk, pre-authorisation 1); a reviewer confirmed the fix after that commit."' <<<"$e")"
  _afk_ws_gh "$w" api graphql -f query='mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t,body:$b}){clientMutationId}}' \
    -f t="$thread" -f b="$body" >/dev/null \
    || { c_warn "afk: the reply to $thread did not post - the thread is left open"; return 1; }
  _afk_ws_gh "$w" api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' \
    -f t="$thread" >/dev/null \
    || { c_warn "afk: replied to $thread but could not resolve it"; return 1; }
  c_ok "resolved $slug#$pr thread $thread (fixed in $(jq -r .fixed_commit <<<"$e"))"
}

# PRE-AUTHORISATION 3, AS AN ACT AND NOT AS AN OPINION. Five of the 36 hours
# CEL-59 measured were rebases: another PR merges, strict branch protection
# pushes this one behind, and the branch needs exactly `git rebase` and a push -
# no decision, no new code, and no reason for it to wait until morning. The
# evidence is DERIVED HERE from git and from the PR, never passed in: a caller
# that hands this function its own answers is a caller that can hand it the
# wrong ones. Conflicts are detected without touching the worktree, so the
# refusal costs nothing and leaves the branch exactly as the morning expects.
afk_rebase_retry() { # <worktree> [--base <ref>]
  local wt="$1"; shift
  local base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      *) die "cel afk rebase-retry: unknown argument '$1'" ;;
    esac
  done
  [ -d "$wt" ] || die "cel afk rebase-retry: no worktree at $wt"
  local branch; branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    || die "cel afk rebase-retry: $wt is not on a branch - there is nothing here to retry"
  git -C "$wt" fetch --quiet origin >/dev/null 2>&1 || true
  [ -n "$base" ] || base="$(repo_default_ref "$wt")" \
    || die "cel afk rebase-retry: cannot resolve the remote default of $wt - pass --base"

  # What GitHub thought of this PR before the rebase. No PR, or a PR that
  # already conflicts, is not "pushed behind by another merge".
  local pr mergeable state
  pr="$(_afk_ws_gh "$(ws_of_checkout "$wt" || true)" pr view "$branch" --json mergeable,state 2>/dev/null || true)"
  mergeable="$(jq -r '.mergeable // ""' <<<"${pr:-{\}}" 2>/dev/null || true)"
  state="$(jq -r '.state // ""' <<<"${pr:-{\}}" 2>/dev/null || true)"

  local behind new_work conflicts
  behind=false
  [ "$(git -C "$wt" rev-list --count "HEAD..$base" 2>/dev/null || echo 0)" -gt 0 ] && behind=true
  # Unpushed commits are work, and work is reviewed awake.
  new_work=false
  if git -C "$wt" rev-parse --verify --quiet "origin/$branch" >/dev/null 2>&1; then
    [ "$(git -C "$wt" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)" -gt 0 ] && new_work=true
  else
    new_work=true   # nothing pushed at all: there is no PR-behind to retry
  fi
  # Asked WITHOUT touching the index: a rebase started to find out whether it
  # conflicts is a rebase somebody has to abort, and an aborted rebase in a
  # worker's worktree at 03:00 is exactly the mess this must not make.
  #
  # TWO SPELLINGS, BECAUSE THE ANSWER MUST NOT DEPEND ON THE BOX. `merge-tree
  # --write-tree` (git 2.38+) reports conflicts through its exit status; older
  # git has only the three-argument form, which says so in its output instead.
  # Neither available means CONFLICTS, not clean: absence of evidence is not
  # evidence, and what follows this line is a force-push.
  conflicts=true
  if git -C "$wt" merge-tree --write-tree "$base" HEAD >/dev/null 2>&1; then
    conflicts=false
  elif git -C "$wt" merge-tree --write-tree "$base" HEAD 2>&1 | grep -q 'unknown option\|usage:'; then
    local mb mt
    mb="$(git -C "$wt" merge-base "$base" HEAD 2>/dev/null || true)"
    if [ -n "$mb" ]; then
      mt="$(git -C "$wt" merge-tree "$mb" "$base" HEAD 2>/dev/null || true)"
      case "$mt" in *'<<<<<<<'*|*'changed in both'*) conflicts=true ;; *) conflicts=false ;; esac
    fi
  fi

  local e
  e="$(jq -nc --arg b "$branch" --arg base "$base" --arg m "$mergeable" --arg st "$state" \
    --argjson behind "$behind" --argjson new_work "$new_work" --argjson conflicts "$conflicts" \
    '{was_mergeable: ($st == "OPEN" and $m != "CONFLICTING" and $m != ""),
      behind: $behind, new_work: $new_work, conflicts: $conflicts,
      branch: $b, base: $base}')"
  afk_authorise rebase_retry "$e" "$branch onto $base (no new work, no conflict)" >/dev/null || return 1

  # A REBASE NEEDS A COMMITTER, and a box with no global identity (a fresh CI
  # runner, a container) has none - which would fail here as "would not rebase"
  # and read as a conflict that is not there. Use the worktree's own identity
  # when it has one, and say who did it when it does not.
  local -a ident=()
  git -C "$wt" config user.email >/dev/null 2>&1 \
    || ident=(-c user.email=cel-afk@localhost -c user.name='cel afk')
  if ! git -C "$wt" "${ident[@]}" rebase "$base" >/dev/null 2>&1; then
    git -C "$wt" rebase --abort >/dev/null 2>&1 || true
    c_warn "afk: $branch would not rebase onto $base after all - aborted, nothing pushed, left for the morning"
    return 1
  fi
  # --force-with-lease: the branch is ours and it moved under a rebase, but if
  # something else pushed to it in the meantime this must lose, not win.
  git -C "$wt" push --force-with-lease origin "$branch" >/dev/null 2>&1 \
    || { c_warn "afk: rebased $branch onto $base but the push was refused - the retry is not done"; return 1; }
  c_ok "rebased $branch onto $base and pushed (cel afk, pre-authorisation 3)"
}

cmd_afk() {
  local sub="${1:-status}"; shift || true
  case "$sub" in
    on)
      local until_text="" reason="" scope=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --until)  until_text="$2"; shift 2 ;;
          --reason) reason="$2"; shift 2 ;;
          # Where this AFK was armed. An orchestrator asleep over one product is
          # not an orchestrator loose on the box, and without a scope there is
          # nothing for an act to be "outside".
          --scope)  scope="$2"; shift 2 ;;
          *) die "cel afk on: unknown argument '$1' (want --until <when>, --reason <text> or --scope <workspace>)" ;;
        esac
      done
      local epoch=0
      if [ -n "$until_text" ]; then
        epoch="$(_afk_parse_until "$until_text")" \
          || die "cel afk on: cannot read '--until $until_text' as a time - say +8h, 07:30 or an ISO timestamp"
      fi
      mkdir -p "$(afk_dir)"
      jq -n --arg since "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg reason "$reason" \
        --arg ut "$until_text" --argjson ue "$epoch" --arg scope "$scope" \
        '{on:true, since:$since, reason:$reason, until_text:$ut, scope:$scope,
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
    resolve-thread)
      # PRE-AUTHORISATION 1's ENTRY POINT. The evidence is named on the command
      # line because it is evidence about a review nobody here can read: which
      # commit fixed it, what it fixed, and which reviewer confirmed the fix
      # afterwards. Everything else about the act - that it is a bot thread, that
      # the verdict came after the commit, that AFK is even on - is checked by
      # the door, not by whoever typed this.
      local slug="${1:-}" pr="${2:-}" thread="${3:-}"; shift 3 2>/dev/null || \
        die "usage: cel afk resolve-thread <owner/repo> <pr> <thread-id> --commit <sha> --summary <text> --fixed-at <iso> --verdict-at <iso> [--human]"
      local commit="" summary="" fixed_at="" verdict="approved" verdict_at="" bot=true
      while [ $# -gt 0 ]; do
        case "$1" in
          --commit)     commit="$2"; shift 2 ;;
          --summary)    summary="$2"; shift 2 ;;
          --fixed-at)   fixed_at="$2"; shift 2 ;;
          --verdict)    verdict="$2"; shift 2 ;;
          --verdict-at) verdict_at="$2"; shift 2 ;;
          --human)      bot=false; shift ;;
          *) die "cel afk resolve-thread: unknown argument '$1'" ;;
        esac
      done
      afk_resolve_thread "$slug" "$pr" "$thread" \
        "$(jq -nc --argjson bot "$bot" --arg c "$commit" --arg s "$summary" \
            --arg fa "$fixed_at" --arg v "$verdict" --arg va "$verdict_at" \
            '{bot:$bot, fixed_commit:$c, fixed_summary:$s, fixed_at:$fa,
              reviewer_verdict:$v, reviewer_verdict_at:$va}')"
      ;;
    rebase-retry)
      [ $# -ge 1 ] || die "usage: cel afk rebase-retry <worktree> [--base <ref>]"
      afk_rebase_retry "$@"
      ;;
    *) die "usage: cel afk on [--until <when>] [--reason <text>] [--scope <workspace>] | off | status [--json] | log [--json] | resolve-thread ... | rebase-retry <worktree>" ;;
  esac
}
