# shellcheck shell=bash
# cel fleet - the whole box in one read.
#
# Every other view is per workspace: `cel-fanout status` needs you standing in
# one, a dashboard serves one, the steward warns about one at a time. So the
# question an operator actually asks first - "what is the state of
# everything?" - was answered by visiting each workspace in turn and holding
# the picture in their head, which is exactly the kind of bookkeeping that
# goes wrong quietly. This is that question as a single deterministic call: no
# tokens, no agent judgement, only numbers that are true at the moment of the
# read.
#
# It is a READ. It never nudges, never writes and always exits 0 (a usage
# error aside), because a view that can change the box is a view people are
# afraid to run.
[ -n "${_CEL_FLEET:-}" ] && return 0
_CEL_FLEET=1
# The field separator this file passes its own facts around with. A TAB will
# not do: tab is IFS whitespace, so `IFS=$'\t' read` silently COLLAPSES a run
# of them and an empty verdict beside an empty severity turns into one field
# and a row shifted by two. Unit Separator is not whitespace and appears in
# nothing git, jq or herdr can hand us.
_FLEET_US=$'\x1f'
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/inbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/inbox.sh"
# shellcheck source=lib/stall.sh
. "$(dirname "${BASH_SOURCE[0]}")/stall.sh"
# shellcheck source=lib/liveness.sh
. "$(dirname "${BASH_SOURCE[0]}")/liveness.sh"
# shellcheck source=lib/run.sh
. "$(dirname "${BASH_SOURCE[0]}")/run.sh"
# shellcheck source=lib/memory.sh
. "$(dirname "${BASH_SOURCE[0]}")/memory.sh"
# shellcheck source=lib/orphans.sh
. "$(dirname "${BASH_SOURCE[0]}")/orphans.sh"

# The processes with no owner at all, as one field of the box.
#
# Every view of this box reads `cel fleet --json`, so a class of process that
# is not in this document is a class no view can mention - which is how a
# gigabyte of reparented watchers, fixtures and dead pane shells sat under a
# headline that said `celestial-orch 1.7G`. Zeroes rather than an absent key:
# a console that has to ask whether the field exists gets it wrong once.
fleet_orphans_json() { # -> {count, rss_mb}
  local n mb
  read -r n mb <<<"$(orphans_list 2>/dev/null | orphans_totals)"
  printf '{"count":%d,"rss_mb":%d}' "${n:-0}" "${mb:-0}"
}

# One herdr roster for the whole run. The sweep below asks about every
# orchestrator and every running worker, and a call per question turned a
# read into a visible pause.
#
# AND IT IS A DOCUMENT OR IT IS NOTHING. herdr answering with a truncated
# document - killed mid-write, or dead between the opening brace and the rest
# of it - is not the same as herdr answering; passing those bytes on left the
# roster to fail inside whichever jq touched it first. An unreadable answer is
# an answer nobody got, which this file already has a word for: empty, every
# orchestrator `-`, and nobody convicted. The validation costs one jq per
# render, against a read that starts a hundred and forty.
#
# AND SHAPE-VALID IS NOT ANSWERED. Checking only that the bytes PARSE admits
# `{}`, `[]`, an error envelope, and any document about something other than
# agents - each of which then reads as a roster that knows about nobody, and
# so as `gone` for every worker on the box. Measured with a stub printing
# `{}`: 16 of 16 workers rendered `gone` against a healthy roster's 5 done /
# 8 gone / 1 idle / 2 working. A mute observer convicted the whole fleet.
# Only a document with `.result.agents` as an ARRAY has said anything about
# who is alive; anything else is the no-roster path, and `-`.
_fleet_roster() {
  local out
  out="$(herdr agent list 2>/dev/null)" || { printf '%s' ''; return 0; }
  [ -n "$out" ] || { printf '%s' ''; return 0; }
  printf '%s' "$out" | jq -e '
    type == "object" and (.result | type) == "object"
      and (.result.agents | type) == "array"' >/dev/null 2>&1 \
    || { printf '%s' ''; return 0; }
  printf '%s' "$out"
}

# ONE PASS OVER THE LEDGER, NOT ONE PER ROW.
#
# The ledger is read with jq, deliberately, and not by sourcing cel-fanout:
# cel-fanout is a BINARY that runs a delegation when sourced, not a library.
#
# This used to emit one JSON entry per line and leave the caller to start a jq
# per row to pull the three fields it needed out again, and another to ask the
# roster what that row's pane was doing. Five jq processes per worker, 154 on
# one render. The roster is a document like any other, so the join belongs in
# the same program: one jq per REPO answers everything the loop reads.
#
# ONLY THE STATES THAT ARE STILL SOMEBODY'S CONCERN. The first cut of this
# list took everything but `released`, and on the live box the unit view
# filled with `landed`, `salvaged` and `orphaned` rows - finished business,
# every one of them rendered as a worker with `live: gone` and no readable
# worktree. A list of things nobody can act on is a list people stop reading,
# and it buried the rows that mattered. `running` is working; `finished` and
# `collected` are waiting on a human to land them or let them go. Everything
# else is history, and history is what `cel-fanout status --json` is for -
# that view still carries every state, `released` included.
#
# An empty roster means herdr did not answer, and `-` says that about the
# OBSERVER; `gone` says it about the worker. lib/stall.sh learned the
# difference the hard way and the two must not be folded together here.
_fleet_unit_rows() { # <wsdir> <repo> <roster-json> -> entry US pane US worktree US state US live US harness US id
  local led="$1/.cel/delegations.json"
  [ -f "$led" ] || return 0
  # The roster arrives as a STRING and is parsed inside the program, not as
  # --argjson: a malformed document there fails jq before it has opened the
  # ledger, the `|| true` below swallows it, and the fleet renders with every
  # worker row missing - a box that looks idle because the pane manager
  # stuttered. `fromjson?` yields nothing rather than raising, so an
  # unreadable roster degrades to the no-roster path instead of to silence.
  #
  # PARSING IS NOT ENOUGH, and this is the second half of the same lesson:
  # `{}` and `[]` parse. A document without `.result.agents` as an array
  # cannot be searched for a pane, so it must not answer for one - it is the
  # no-roster path, `-`, a fact about the OBSERVER. (`[]` is worse than wrong:
  # `.result` on an array raises, and the `|| true` below turns that into a
  # fleet with no rows at all.) _fleet_roster screens the same shape one level
  # up; this program is called with a roster string by callers of its own and
  # does not get to assume that happened.
  jq -r --arg r "$2" --arg roster "${3:-}" --arg us "$_FLEET_US" '
    (($roster | fromjson?) // null
      | if (type == "object" and (.result | type) == "object"
             and (.result.agents | type) == "array") then . else null end) as $roster
    | def agent($p): if $roster == null then null
                   else ((($roster.result.agents? // []) | map(select(.pane_id == $p)))[0] // {}) end;
    .[]?
    | select(.repo == $r and ((.state // "") | IN("running", "unconfirmed", "finished", "collected", "blocked")))
    | . as $e
    | (.pane // "") as $p
    | agent($p) as $a
    | (if $a == null then "-" else (if ($a.agent_status // "") == "" then "gone" else $a.agent_status end) end) as $live
    | [($e | tojson), $p, (.worktree // ""), (.state // ""), $live,
       (if $a == null then "" else ($a.agent // "") end), (.id // "")]
    | join($us)' \
    "$led" 2>/dev/null || true
}

# EVERY GIT QUESTION THIS VIEW ASKS OF ONE WORKTREE, ASKED ONCE.
#
# Measured on 2026-09-20: a single render started 112 git processes, all of
# them here - 36 `symbolic-ref`, 32 `rev-parse --verify`, 24 `rev-list
# --count`, 10 `status --porcelain`, 10 `rev-parse --abbrev-ref`. Twelve per
# running row, for four numbers, and half of them asked twice because both
# `unlanded` and the row's own severity want the same at-risk answer. The work
# is trivial; the fork is not, and system time was 62% of the render.
#
# So: ONE `for-each-ref` covering every ref the questions are about (which
# branch is checked out, whether it has a remote twin, where origin/HEAD
# points), ONE `status --porcelain`, and at most two `rev-list --count` -
# reduced to one when both counts have the same base. The answer is
# remembered per worktree for the length of the read, so the second caller
# pays nothing.
#
# IT STAYS FORGIVING. Every call it replaces ended in `|| true` or a `?`, and
# a batched query that turns "could not ask" into an error would convict a
# detached HEAD, a branch the remote has never seen, or a checkout with no
# origin at all. Unknown is `?` and at-risk is empty, exactly as before.
declare -gA _FLEET_GIT_FACTS=()
_FLEET_GIT_AHEAD='?'
_FLEET_GIT_RISK=''
# It sets two variables rather than printing them, because a memo written
# inside `$(...)` is written in a subshell and thrown away - the first version
# of this cached nothing at all and asked every question twice.
_fleet_git_load() { # <worktree> -> sets _FLEET_GIT_AHEAD, _FLEET_GIT_RISK
  local wt="${1:-}"
  if [ -n "$wt" ] && [ -n "${_FLEET_GIT_FACTS[$wt]+x}" ]; then
    local memo="${_FLEET_GIT_FACTS[$wt]}"
    _FLEET_GIT_AHEAD="${memo%%"$_FLEET_US"*}"
    _FLEET_GIT_RISK="${memo#*"$_FLEET_US"}"
    return 0
  fi
  local ahead='?' risk='' br='' origin_head=''
  local refs mark name symref
  declare -A have=()
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    # %(HEAD) is this worktree's HEAD, so the checked-out branch comes out of
    # the same read as the refs - and a detached HEAD simply marks nothing,
    # which is the `symbolic-ref --quiet HEAD` test this replaces. The marker
    # is emitted as `*` or `-` rather than as git's "* or a space", because a
    # leading empty field and `read` do not survive each other.
    refs="$(git -C "$wt" for-each-ref \
      --format='%(if)%(HEAD)%(then)*%(else)-%(end) %(refname) %(symref)' \
      refs/heads refs/remotes/origin 2>/dev/null || true)"
    while read -r mark name symref; do
      [ -n "$name" ] || continue
      case "$name" in
        refs/heads/*)
          have["${name#refs/heads/}"]=1
          [ "$mark" = '*' ] && br="${name#refs/heads/}" ;;
        refs/remotes/*)
          have["${name#refs/remotes/}"]=1
          [ "$name" = refs/remotes/origin/HEAD ] && origin_head="${symref#refs/remotes/}" ;;
      esac
    done <<<"$refs"

    # The base `fleet_ahead` counts from: repo_default_ref's answer, derived
    # from the same read. A malformed origin/HEAD (a direct ref with no
    # target) is a failure there and unknown here, not a silent fall back to
    # main.
    local base=""
    if [ -n "${have[origin/HEAD]:-}" ]; then
      case "$origin_head" in origin/*) base="$origin_head" ;; esac
    elif [ -n "${have[origin/main]:-}" ]; then
      base=origin/main
    elif [ -n "${have[origin/master]:-}" ]; then
      base=origin/master
    fi

    local n=''
    if [ -n "$br" ] && [ -n "$base" ]; then
      n="$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || true)"
      [[ "$n" =~ ^[0-9]+$ ]] && ahead="$n"
    fi

    # `.agent/` is the worker's REPORT - result.md and verdict.json, written
    # at the end and never committed - so counting it made every finished
    # worker look like one holding work at risk. lib/stall.sh learned that;
    # this is the same filter, on the same output.
    local dirty unpushed=0
    dirty="$(git -C "$wt" status --porcelain 2>/dev/null | grep -v ' \.agent/' | grep -c . || true)"
    if [ -n "$br" ] && [ "$br" != HEAD ]; then
      if [ -n "${have[origin/$br]:-}" ]; then
        unpushed="$(git -C "$wt" rev-list --count "origin/$br..HEAD" 2>/dev/null || printf 0)"
      elif [ -n "${have[origin/main]:-}" ]; then
        # No remote branch AT ALL - the 404 case from the incident. Everything
        # this worktree has ever committed is unpushed, counted from
        # origin/main exactly as stall_work_at_risk counts it, and reusing the
        # number above when that is the base it already asked for.
        if [ "$base" = origin/main ] && [[ "$ahead" =~ ^[0-9]+$ ]]; then
          unpushed="$ahead"
        else
          unpushed="$(git -C "$wt" rev-list --count "origin/main..HEAD" 2>/dev/null || printf 0)"
        fi
      fi
    fi
    [ "${dirty:-0}" -gt 0 ] || [ "${unpushed:-0}" -gt 0 ] \
      && risk="$(printf 'unpushed=%s dirty=%s' "${unpushed:-0}" "${dirty:-0}")"
  fi
  [ -n "$wt" ] && _FLEET_GIT_FACTS[$wt]="$ahead$_FLEET_US$risk"
  _FLEET_GIT_AHEAD="$ahead"
  _FLEET_GIT_RISK="$risk"
}

# How many commits this worktree carries beyond the verified remote default.
# The same answer `cel-fanout status` prints in its AHEAD column, computed the
# same way: unknown stays visible as `?` rather than being flattened to zero,
# because "no commits" and "could not ask" lead an operator to opposite acts.
fleet_ahead() { # <worktree> -> count | ?
  _fleet_git_load "$1"
  printf '%s' "$_FLEET_GIT_AHEAD"
}

# EVERYTHING A ROW IS JUDGED ON, COMPUTED ONCE.
#
# The verdict, the age, the footprint and the at-risk answer were each
# computed twice - once for the row and once for the unit's counts - and the
# unit then started a jq to read two of them back out of the JSON it had just
# been handed. One call, one set of facts, and the count an operator compares
# against the list is literally the same value the list carries.
#
# THE VERDICT IS ONLY EVER PASSED ON A RUNNING ROW. A collected or finished
# worker is idle with nothing written since, by design - convicting it of
# being stalled is how a watcher earns its reputation for crying wolf, and it
# would put this list permanently out of step with the `stalled` count beside
# it. An empty `live` (herdr did not answer at all) is not evidence either.
_fleet_row_facts() { # <live> <text> <worktree> <state> <id> -> 8 lines
  local live="$1" text="$2" wt="$3" state="$4" id="$5"
  local quiet="" verdict="" severity="" risk="" activity="" aconf="" cached
  # Quiet time is a question about a RUNNING worker. Answering it for every
  # finished and collected row meant a `find` over every worktree on the box
  # on every fleet call - most of the console's start. Those rows show '-'.
  [ "$state" = running ] && quiet="$(stall_quiet_secs "$wt")"
  # The batched git query, and the only place it is asked from: both the
  # at-risk answer and the ahead count come out of it, which is why
  # stall_work_at_risk is not called here any more - it is the same four
  # processes, asked a second time.
  _fleet_git_load "$wt"
  risk="$_FLEET_GIT_RISK"
  if [ "$state" = running ] && [ "$live" != "-" ]; then
    verdict="$(stall_verdict "$live" "$text" "$quiet")"
    severity="$(stall_severity "$verdict" "$risk")"
  fi
  # -1, not 0: a worktree that cannot be read has an UNKNOWN age, and zero
  # would render as a worker that wrote something a moment ago.
  [ -n "$quiet" ] || quiet=-1
  # WHAT THE PANE IS DOING, when somebody has recently asked (CEL-42). The
  # fleet never asks itself: this view is read in a loop and a network call per
  # row is a view people stop running. It carries the steward's last answer,
  # which is why a row nobody has classified simply has neither field filled -
  # and why a stale answer is dropped rather than shown as current.
  cached="$(liveness_cached "$id")"
  if [ -n "$cached" ]; then
    activity="${cached%%	*}"
    aconf="${cached#*	}"
  fi
  # Newline-separated, not tab: see _FLEET_US above for what `read` does to a
  # run of tabs, and these fields are empty most of the time. The trailing `.`
  # is not decoration - `$(...)` eats trailing newlines, so a row whose last
  # facts are empty came back short, the caller's last `read` hit EOF and
  # returned non-zero, and under `set -e` that took `cel-fanout status --json`
  # down with it.
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n.' \
    "$quiet" "$verdict" "$severity" "$_FLEET_GIT_AHEAD" \
    "$(mem_tree_rss_mb "$wt")" "$activity" "$aconf" "$risk"
}

# ONE LEDGER ROW AS THE THING AN OPERATOR ACTUALLY ASKS ABOUT.
#
# The owner, at the console on 2026-09-18: "when I asked it why one of my
# workers was stalled it just told me to run cel fleet". The view carried a
# stalled COUNT and nothing else - no id, no verdict, no reason - so neither
# the console nor the model could answer from state they were never given.
# This is that state. `cel fleet --json` and `cel-fanout status --json` both
# render from HERE, so the two surfaces cannot describe the same worker
# differently; the shape is a contract the console is written against.
#
# The last argument is the facts above when the caller already has them (the
# fleet's own sweep does), and absent when it does not (cel-fanout calls this
# with three arguments, and must keep being able to).
fleet_worker_row() { # <ledger-entry-json> <live> <pane-text> [worktree] [state] [facts]
  local e="$1" live="${2:--}" text="${3:-}"
  [ -n "$live" ] || live="-"
  local wt="${4:-}" state="${5:-}" facts="${6:-}"
  if [ -z "$facts" ]; then
    # One jq for all three when the caller did not already have them: every jq
    # is a process, and at seven per row the fleet spent longer parsing its
    # own ledger than reading the box.
    local ewt estate id
    { read -r ewt; read -r estate; read -r id; } < <(printf '%s' "$e" |
      jq -r '[(.worktree // ""), (.state // ""), (.id // "")] | .[]')
    [ -n "$wt" ] || wt="$ewt"
    [ -n "$state" ] || state="$estate"
    facts="$(_fleet_row_facts "$live" "$text" "$wt" "$state" "$id")"
  fi
  # ...AND WHAT THE PANE IS, which needs nobody asked at all (CEL-50). A pane
  # holding an unsubmitted prompt, erroring on every turn, or refused by its
  # provider all render as a worker thinking, and all three are visible in the
  # text. Carried as its own field so a view can show `running` and the reason
  # it is not moving in the same row.
  local silence="" sreset=""
  if [ "$state" = running ] || [ "$state" = unconfirmed ]; then
    silence="$(liveness_pane_silence "$text" "$(printf '%s' "$e" | jq -r '.provider // ""')")"
    sreset="$(printf '%s' "$silence" | cut -f2 -s)"
    silence="$(printf '%s' "$silence" | cut -f1)"
  fi
  local quiet verdict severity ahead rss activity aconf
  { read -r quiet; read -r verdict; read -r severity; read -r ahead
    read -r rss; read -r activity; read -r aconf; } <<<"$facts"
  printf '%s' "$e" | jq -c \
    --arg silence "$silence" --arg silence_reset "$sreset" \
    --arg live "$live" --argjson quiet "$quiet" \
    --arg activity "$activity" --arg aconf "$aconf" \
    --arg verdict "$verdict" --arg severity "$severity" \
    --arg ahead "$ahead" \
    --argjson rss "$rss" \
    --arg harness "${FLEET_HARNESS:-}" \
    '{id: (.id // ""), ticket: (.ticket // ""), repo: (.repo // ""),
      branch: (.branch // ""), shape: (.shape // "ship"), state: (.state // ""),
      live: $live, quiet_secs: $quiet, verdict: $verdict, severity: $severity,
      ahead: $ahead, rss_mb: $rss, pr: (.pr // ""), created: (.created // ""),
      alias: (.alias // ""), pane: (.pane // ""), worktree: (.worktree // ""),
      profile: (.profile // ""), runtime: (.runtime // ""), model: (.model // ""),
      activity: $activity, activity_confidence: $aconf,
      silence: $silence, silence_reset: $silence_reset,
      harness: $harness}'
}

# MAIL TO A PANE THAT IS NOT THERE (CEL-50). A worker was sent a finding by
# inbox; the ledger showed `live: -` and nothing received it. The message was
# accepted and went nowhere, which is worse than a refusal - the sender
# believes it was delivered. Prints the sentence and returns 0 when the alias
# has no live pane.
#
# A roster nobody could read is NOT evidence that anyone died: an empty
# agents document says nothing at all, the lesson lib/stall.sh already paid
# for once.
fleet_alias_undeliverable() { # <agents-json> <alias>
  local agents="${1:-}" alias="${2:-}"
  [ -n "$agents" ] && [ -n "$alias" ] || return 1
  printf '%s' "$agents" | jq -e '.result.agents? | length > 0' >/dev/null 2>&1 || return 1
  printf '%s' "$agents" | jq -e --arg a "$alias" \
    '[.result.agents[]? | select((.name // .agent_id // "") == $a)] | length > 0' >/dev/null 2>&1 \
    && return 1
  printf '%s has no live pane - anything sent to it is filed, not delivered; start the agent before writing to it' "$alias"
  return 0
}

# The unit line. The unit is the PRODUCT: the thing one orchestrator stands
# over. A declared product names its repos after itself, because `bundle` on
# its own tells an operator nothing about which checkouts are moving; an
# implicit product IS its repo and renders byte-for-byte as it always has.
_fleet_unit_line() { # <label> <orch> <workers> <cap> <stalled> <unlanded> <mem>
  printf '  %-12s orch %-5s workers %s/%s   stalled %s   unlanded %s   mem %s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# WHERE THE ORCHESTRATOR PANE STANDS, which is the directory its memory is
# attributed to. A declared product has its own directory under products/; an
# implicit product is only a repo checkout. The same derivation lib/steward.sh
# makes for the same reason - identity in this plane comes from paths - and
# reading the wrong one reports zero for a live pane, which an operator cannot
# tell apart from an orchestrator that is not running.
_fleet_orch_dir() { # <wsdir> <product>
  if ws_product_declared "$1" "$2"; then printf '%s/products/%s' "$1" "$2"
  else printf '%s/repos/%s' "$1" "$2"; fi
}

# One unit's facts as JSON, so text and --json cannot drift apart: both
# render from this.
_fleet_unit() { # <wsdir> <product> <roster-json> -> JSON
  local wsdir="$1" product="$2" roster="$3"
  local orch="-" workers=0 stalled=0 unlanded=0 cap declared=false

  local repos=() repo
  while IFS= read -r repo; do
    [ -n "$repo" ] && repos+=("$repo")
  done < <(ws_product_repos "$wsdir" "$product")
  ws_product_declared "$wsdir" "$product" && declared=true

  # THE CAP BELONGS TO THE ORCHESTRATOR, NOT THE REPO - the same precedence
  # `cel-fanout delegate` uses when it refuses a worker. A view that counted
  # per repo would show a two-repo product as half as busy as the thing that
  # actually stops it, and the two numbers people compare must be one number.
  cap="$(ws_product_get "$wsdir" "$product" workers)"
  [ -n "$cap" ] || cap="$(ws_policy "$wsdir" workers)"
  [ -n "$cap" ] || cap=4

  # An empty roster means herdr did not answer. That is not evidence that
  # anyone died - lib/stall.sh learned that the hard way - so with no roster
  # every orchestrator reads as unknown and nothing is convicted.
  local have_roster=0
  [ -n "$roster" ] && have_roster=1

  if [ "$have_roster" = 1 ]; then
    local want status
    want="$(_run_agent_name "$product-orch")"
    status="$(printf '%s' "$roster" | jq -r --arg n "$want" \
      '[.result.agents[]? | select(.name == $n) | .agent_status // ""][0] // ""' 2>/dev/null || true)"
    if [ -n "$status" ]; then
      case "$status" in
        blocked) orch="blocked" ;;
        *)       orch="LIVE" ;;
      esac
    else
      # NO ALIAS IS NOT NO ORCHESTRATOR (CEL-44). herdr cleared a live
      # orchestrator's name when it restarted on 2026-09-18 and this view,
      # which resolves one by its alias, reported `orch -` for a product whose
      # pane was running - and the act that follows `-` is starting another one
      # on top of it. An agent alive in the product's OWN directory is that
      # product's orchestrator whatever herdr calls it, and `unnamed` is a
      # state with a cure: cel ws up <workspace>.
      local here
      here="$(printf '%s' "$roster" | jq -r --arg c "$(_fleet_orch_dir "$wsdir" "$product")" \
        '[.result.agents[]? | select((.cwd // "") == $c) | select((.agent_status // "") != "")] | length' 2>/dev/null || printf 0)"
      [ "${here:-0}" -gt 0 ] 2>/dev/null && orch="unnamed"
    fi
  fi

  local rss=0 orch_rss
  orch_rss="$(mem_tree_rss_mb "$(_fleet_orch_dir "$wsdir" "$product")")"

  local row rows=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    local entry pane wt state live harness id text
    IFS="$_FLEET_US" read -r entry pane wt state live harness id <<<"$row"

    if [ "$have_roster" = 1 ] && [ "$state" = running ] && [ -n "$pane" ] && [ "$live" != gone ]; then
      text="$(herdr pane read "$pane" --source detection --lines 40 2>/dev/null || true)"
    else
      text=""
    fi

    local facts quiet verdict severity ahead orss activity aconf risk
    facts="$(_fleet_row_facts "$live" "$text" "$wt" "$state" "$id")"
    { read -r quiet; read -r verdict; read -r severity; read -r ahead
      read -r orss; read -r activity; read -r aconf; read -r risk; } <<<"$facts"

    if [ "$state" = running ]; then
      workers=$((workers + 1))
      [ -n "$risk" ] && unlanded=$((unlanded + 1))
    fi

    rows="$rows$(FLEET_HARNESS="$harness" fleet_worker_row "$entry" "$live" "$text" "$wt" "$state" "$facts")
"
    # The unit's footprint is the sum of its workers' - every state the list
    # carries, not only `running`: a collected worker whose pane is still up
    # is still holding the memory, and hiding it is how 3 GB goes missing
    # between the row and the box.
    rss=$((rss + ${orss:-0}))
    # The count IS the list: counted from the same verdict the row carries, so
    # the two numbers an operator compares can never disagree.
    [ -n "$verdict" ] && stalled=$((stalled + 1))
  done < <(for repo in "${repos[@]}"; do _fleet_unit_rows "$wsdir" "$repo" "$roster"; done)

  # The rows are folded by the same jq that builds the unit, and the repo list
  # arrives as positional arguments: this was three processes (`jq -R`, `jq
  # -s`, `jq -n`) for a document of four numbers and a list of strings.
  printf '%s' "$rows" | jq -sc --arg name "$product" --arg orch "$orch" \
    --argjson workers "$workers" --argjson cap "$cap" \
    --argjson stalled "$stalled" --argjson unlanded "$unlanded" \
    --argjson declared "$declared" \
    --argjson rss "$rss" --argjson orch_rss "$orch_rss" \
    '{name: $name, orch: $orch, workers: $workers, cap: $cap, stalled: $stalled, unlanded: $unlanded, rss_mb: $rss, orch_rss_mb: $orch_rss, repos: $ARGS.positional, declared: $declared, workers_list: .}' \
    --args "${repos[@]}"
}

_fleet_workspace() { # <name> <roster-json> -> JSON or nothing
  local ws="$1" roster="$2" wsdir
  wsdir="$(registry_path "$ws")"
  [ -d "$wsdir" ] || return 0
  [ -f "$wsdir/workspace.yaml" ] || return 0

  local unread open units product mail
  unread="$(_inbox_count --for root --workspace "$ws" 2>/dev/null || printf 0)"
  [ -n "$unread" ] || unread=0
  open="$(_inbox_open --for root --workspace "$ws" 2>/dev/null | grep -c . || true)"
  [ -n "$open" ] || open=0
  # WHETHER ROOT'S MAIL IS GOING ANYWHERE AT ALL. Every view of this box reads
  # `cel fleet --json`, and until CEL-43 none of them could say who was alive
  # to read the mailbox everything escalates to - so 72 escalations in nine
  # days landed somewhere nobody was obliged to look.
  mail="$(inbox_mail_json "$ws" root 2>/dev/null)"
  [ -n "$mail" ] || mail='{"to_root_unread":0,"oldest_secs":0,"reader":""}'

  units=""
  for product in $(ws_product_names "$wsdir" 2>/dev/null); do
    units="$units$(_fleet_unit "$wsdir" "$product" "$roster")
"
  done

  printf '%s' "$units" | jq -sc --arg name "$ws" \
    --argjson unread "$unread" --argjson open "$open" --argjson mail "$mail" \
    '{name: $name, root: {unread: $unread, open: $open}, mail: $mail, units: .}'
}

# ONE LINE FOR A MAILBOX NOBODY READS, for `cel doctor`. It lives here rather
# than in lib/doctor.sh for the same reason gc_doctor_line and
# orphans_doctor_line do: the check belongs beside the facts it reads.
#
# Silent when someone is reading, and silent when there is nothing unread. A
# watcher that speaks every tick is a watcher people stop reading - which is
# how root got to 553 messages in the first place.
fleet_mail_doctor_line() { # <ws> -> one line, or nothing
  local mail n secs reader age
  mail="$(inbox_mail_json "$1" root 2>/dev/null)" || return 0
  [ -n "$mail" ] || return 0
  n="$(printf '%s' "$mail" | jq -r '.to_root_unread')"
  secs="$(printf '%s' "$mail" | jq -r '.oldest_secs')"
  reader="$(printf '%s' "$mail" | jq -r '.reader')"
  [ "${n:-0}" -gt 0 ] || return 0
  [ -z "$reader" ] || return 0
  if [ "${secs:-0}" -ge 3600 ]; then age="$(( secs / 3600 ))h"; else age="$(( secs / 60 ))m"; fi
  printf '  %s: root has %s unread, oldest %s, nobody reading it\n' "$1" "$n" "$age"
}

_fleet_render() { # <doc>
  local free total
  free="$(mem_human "$(printf '%s' "$1" | jq -r '.box.available_mb // 0')")"
  total="$(mem_human "$(printf '%s' "$1" | jq -r '.box.total_mb // 0')")"
  local orph orph_n
  orph_n="$(printf '%s' "$1" | jq -r '.box.orphans.count // 0')"
  orph=""
  [ "${orph_n:-0}" -gt 0 ] 2>/dev/null \
    && orph="   $orph_n orphans ($(mem_human "$(printf '%s' "$1" | jq -r '.box.orphans.rss_mb // 0')")) - cel gc --orphans"
  printf '%s' "$1" | jq -r --arg box "box $free free of $total$orph" '.workspaces[]
    | "\(.name)   (\(.units | length) products)   root mail: \(.root.unread) unread, \(.root.open) open   \($box)"
      as $head
    | [$head] + [.units[]
        | (if .declared then "\(.name) (\(.repos | join(", ")))" else .name end) as $label
        | "UNIT\t\($label)\t\(.orch)\t\(.workers)\t\(.cap)\t\(.stalled)\t\(.unlanded)\t\(.rss_mb // 0)"]
    | .[]' \
  | while IFS= read -r line; do
      case "$line" in
        UNIT*)
          IFS=$'\t' read -r _ n o w c s u m <<<"$line"
          _fleet_unit_line "$n" "$o" "$w" "$c" "$s" "$u" "$(mem_human "$m")"
          ;;
        *) printf '%s\n' "$line" ;;
      esac
    done
}

# THE SUBSCRIPTIONS, FROM THE CACHE AND ONLY FROM THE CACHE.
#
# This read is on the console's refresh loop and on the dashboard's poll. Two
# network round trips to Anthropic and ChatGPT on that path would put a
# provider's latency between an operator and every draw, and a provider having
# a bad afternoon would make the fleet view feel broken. So the field is
# whatever `subscription_usage` last wrote (it refreshes on a 60 s TTL from
# `cel quota` and from the steward's tick) and an empty list when nothing has
# asked yet - absent is absent, never a zero window.
#
# CEL-35: it is the SAME FUNCTION `cel quota --json` calls, not a second
# reading of the same directory. This field listed one row per cache file and
# the quota command folded pi's login into Claude Code's, so the console said
# five subscriptions where `cel quota` said two, and the operator had to guess
# which surface was lying.
_fleet_subscriptions() {
  # shellcheck source=lib/quota.sh
  . "$(dirname "${BASH_SOURCE[0]}")/quota.sh"
  subscription_list --cached
}

# THE WHOLE DOCUMENT, CACHED (CEL-75). On 2026-09-25, at a load average of 32
# on a 16-thread box, one read took 67-116 s (about 5 s idle), and a console
# refreshing every few seconds started read after read behind the one still
# running, which made the load that made the read slow. A copy younger than
# `fleet.cache_secs` (default 30) is served as is; `--fresh` bypasses it.
# Concurrent callers queue on one lock and take what the holder wrote rather
# than each starting a read of its own. CEL_FLEET_CACHE_SECS overrides the
# config; the suite sets it to 0 so a test that mutates a fixture sees it.
_fleet_cache_secs() {
  local v="${CEL_FLEET_CACHE_SECS:-}"
  if [ -z "$v" ]; then
    # shellcheck source=lib/config.sh
    . "$(dirname "${BASH_SOURCE[0]}")/config.sh"
    v="$(cel_config_get fleet cache_secs)"
  fi
  case "$v" in ''|*[!0-9]*) v=30 ;; esac
  printf '%s' "$v"
}

_fleet_cache_young() { # <file> <secs>
  [ -s "$1" ] || return 1
  # A young file is served only if it is still a fleet document (CEL-79): a
  # truncated or hand-edited cache printed an empty board with success.
  jq -e '.workspaces | type == "array"' "$1" >/dev/null 2>&1 || return 1
  local now m
  now="$(date +%s)"; m="$(stat -c %Y "$1" 2>/dev/null || printf 0)"
  [ $(( now - m )) -lt "$2" ]
}

_fleet_doc() { # <only> -> the JSON document
  local only="$1" roster names ws blocks=""
  roster="$(_fleet_roster)"
  # The batched git answers are remembered for the length of ONE read and no
  # longer: a console refreshing every few seconds must see a worktree that
  # has just been committed to, not the answer from the last draw.
  _FLEET_GIT_FACTS=()
  # The mailbox reader is asked of the roster this pass already holds, not of
  # a fresh `herdr agent list` per workspace (CEL-75).
  _INBOX_ROSTER_HELD="$(printf '%s' "$roster" | jq -r '.result.agents[]?.name // empty' 2>/dev/null || true)"
  [ -n "$roster" ] || _INBOX_ROSTER_HELD=""
  _INBOX_ROSTER_OK=0; [ -n "$roster" ] && _INBOX_ROSTER_OK=1
  export _INBOX_ROSTER_HELD _INBOX_ROSTER_OK
  # ONE /proc WALK FOR THE WHOLE READ. Every worker, every orchestrator and
  # the box's own total are answered from this one snapshot; a walk per
  # question made the cost of the view scale with the number of workers, which
  # is the one thing a view of the workers must not do.
  mem_tree_snapshot
  if [ -n "$only" ]; then names="$only"; else names="$(registry_names)"; fi

  for ws in $names; do
    blocks="$blocks$(_fleet_workspace "$ws" "$roster")
"
  done
  unset _INBOX_ROSTER_HELD _INBOX_ROSTER_OK

  local total avail used
  read -r total avail used <<<"$(mem_box)"
  printf '%s' "$blocks" | jq -sc \
    --argjson total "${total:-0}" --argjson avail "${avail:-0}" --argjson used "${used:-0}" \
    --argjson subs "$(_fleet_subscriptions)" \
    --argjson orphans "$(fleet_orphans_json)" \
    '{workspaces: ., subscriptions: $subs}
     | .box = {total_mb: $total, available_mb: $avail, used_pct: $used, orphans: $orphans,
               agents_rss_mb: ([.workspaces[].units[] | (.rss_mb // 0) + (.orch_rss_mb // 0)] | add // 0)}'
  mem_tree_snapshot_clear
}

cmd_fleet() {
  local json=0 only="" fresh=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --fresh) fresh=1; shift ;;
      --workspace) only="${2:-}"; shift 2 ;;
      -h|--help) printf 'usage: cel fleet [--json] [--fresh] [--workspace <name>]\n'; return 0 ;;
      *) die "cel fleet: unknown argument '$1'" ;;
    esac
  done

  local secs doc="" dir file
  secs="$(_fleet_cache_secs)"
  if [ "$secs" -gt 0 ]; then
    dir="${CEL_CACHE:-$HOME/.cache/cel}"
    mkdir -p "$dir"
    file="$dir/fleet${only:+.$only}.json"
    if [ "$fresh" -eq 0 ] && _fleet_cache_young "$file" "$secs"; then
      doc="$(cat "$file" 2>/dev/null || true)"
    fi
    # Re-validated after the read, too: the file can vanish between the age
    # check and the cat, and an empty read is not a board.
    if ! printf '%s' "$doc" | jq -e '.workspaces | type == "array"' >/dev/null 2>&1; then
      doc=""
      # The lock is held on fd 9 for the read; a caller that waited on it
      # re-checks the cache first, because the holder has just written it.
      exec 9>"$file.lock"
      flock 9
      if [ "$fresh" -eq 0 ] && _fleet_cache_young "$file" "$secs"; then
        doc="$(cat "$file" 2>/dev/null || true)"
      fi
      if ! printf '%s' "$doc" | jq -e '.workspaces | type == "array"' >/dev/null 2>&1; then
        doc="$(_fleet_doc "$only")"
        printf '%s\n' "$doc" >"$file.tmp.$$" && mv -f "$file.tmp.$$" "$file"
      fi
      exec 9>&-
    fi
  else
    doc="$(_fleet_doc "$only")"
  fi
  if [ "$json" -eq 1 ]; then printf '%s\n' "$doc"; else _fleet_render "$doc"; fi
  return 0
}
