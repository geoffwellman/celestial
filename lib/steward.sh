# shellcheck shell=bash
# cel steward - one proactive tick over everything the plane supervises,
# deterministic and token-free. Each tick: collect garbage, sweep every
# registered workspace's review flow and nudge the responsible orchestrator
# when it has stalled, surface blocked agents, and check the plane's own
# servers answer. Nudges are rate-limited per PR through a state file so a
# stuck orchestrator is reminded, not spammed. Keep it running:
#   while :; do cel steward; sleep 900; done   (the steward pane)
[ -n "${_CEL_STEWARD:-}" ] && return 0
_CEL_STEWARD=1
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/gc.sh
. "$(dirname "${BASH_SOURCE[0]}")/gc.sh"
# shellcheck source=lib/pages.sh
. "$(dirname "${BASH_SOURCE[0]}")/pages.sh"
# shellcheck source=lib/dash.sh
. "$(dirname "${BASH_SOURCE[0]}")/dash.sh"
# shellcheck source=lib/inbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/inbox.sh"
# shellcheck source=lib/stall.sh
. "$(dirname "${BASH_SOURCE[0]}")/stall.sh"
# shellcheck source=lib/run.sh
. "$(dirname "${BASH_SOURCE[0]}")/run.sh"
# shellcheck source=lib/memory.sh
. "$(dirname "${BASH_SOURCE[0]}")/memory.sh"
# shellcheck source=lib/services.sh
. "$(dirname "${BASH_SOURCE[0]}")/services.sh"

# Overridable so the stalled-worker sweep can be driven against a stub pane:
# the failure this sweep exists for is a specific string in a specific pane,
# and a test that cannot supply that string proves nothing.
_STEWARD_HERDR="${CEL_STEWARD_HERDR:-herdr}"
_STEWARD_STATE="${CEL_STEWARD_STATE:-$HOME/.local/share/cel/steward-state}"
# The reconcile binary, overridable so a test can watch the call without
# reading a live GitHub. Addressed by path rather than by name: the steward
# runs from a systemd timer, where `cel shellenv`'s PATH does not exist.
_STEWARD_FANOUT="${CEL_STEWARD_FANOUT:-$CEL_ROOT/core/skills/fanout/bin/cel-fanout}"
_STEWARD_WINDOW="${CEL_STEWARD_WINDOW:-14400}"   # repeat-nudge window, seconds

# True (and records the nudge) when this key has not been nudged inside the
# window. Keys carry no spaces: "owner/repo#1".
_steward_due() { # <key>
  local key="$1" now last
  now="$(date +%s)"
  mkdir -p "$(dirname "$_STEWARD_STATE")"; touch "$_STEWARD_STATE"
  last="$(awk -v k="$key" '$1==k{t=$2} END{print t+0}' "$_STEWARD_STATE")"
  [ $((now - last)) -ge "$_STEWARD_WINDOW" ] || return 1
  { awk -v k="$key" '$1!=k' "$_STEWARD_STATE"; printf '%s %s\n' "$key" "$now"; } \
    > "$_STEWARD_STATE.tmp" && mv "$_STEWARD_STATE.tmp" "$_STEWARD_STATE"
}

# THE STEWARD SAYS A THING ONCE. Measured 2026-09-17: root's mailbox held
# twenty-four open `blocked` items from the steward, all the same sentence
# about one exhausted provider, one every four hours since the 12th - because
# each reopening of the dedup window posted a FRESH item and nothing ever
# looked at what had already been said. The owner: "it's the same message over
# and over so it can be rolled up". A raise carries a condition key, so a
# repeat lands as an update on the item that is already open.
_steward_raise() { # <ws> <fp> <kind> <message>
  cmd_inbox send root "$4" --from steward --workspace "$1" --kind "$3" --fp "$2" \
    >/dev/null 2>&1 || true
}

# ...and takes it down again. The other half of the same measurement was four
# STALLED WORKER items whose panes had been gone for days: nothing resolved an
# item when its condition stopped being true, so the backlog only ever grew. A
# `cleared:` status line goes with it, because an item that vanishes silently
# leaves the operator wondering whether it was fixed or merely lost.
_steward_clear_id() { # <ws> <id> <message>
  [ -n "${2:-}" ] || return 0
  cmd_inbox resolve "$2" --by steward --workspace "$1" >/dev/null 2>&1 || true
  cmd_inbox send root "cleared: $3" --from steward --workspace "$1" --kind status \
    >/dev/null 2>&1 || true
  c_ok "$1: cleared - $3"
}

_steward_clear() { # <ws> <fp> <message>
  local id; id="$(_inbox_open_fp "$1" "$2" steward root)"
  [ -n "$id" ] || return 0
  _steward_clear_id "$1" "$id" "$3"
}

# Every pane herdr can see, one per line. Empty means herdr did not answer,
# and the caller must treat that as no evidence rather than as a dead box.
_steward_panes() {
  local ids w
  ids="$("$_STEWARD_HERDR" workspace list 2>/dev/null \
    | jq -r '.result.workspaces[]?.workspace_id // empty' 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    for w in $ids; do
      "$_STEWARD_HERDR" pane list --workspace "$w" 2>/dev/null \
        | jq -r '.result.panes[]?.pane_id // empty' 2>/dev/null || true
    done
  fi
}

# THE FOUR-DAYS-DEAD CASE. A STALLED WORKER item names the pane the operator
# would go and look at; when that pane no longer exists on the box there is
# nothing left to act on, and the item is pure noise in a mailbox someone has
# to read. Cleared once per tick, and only when herdr actually answered -
# an unreachable herdr is not evidence that every pane died.
_steward_clear_dead_panes() {
  local panes; panes="$(_steward_panes)"
  [ -n "$panes" ] || return 0
  local ws id pane
  for ws in $(registry_names); do
    while IFS=$'\t' read -r id pane; do
      [ -n "$id" ] && [ -n "$pane" ] || continue
      if printf '%s\n' "$panes" | grep -qxF "$pane"; then continue; fi
      _steward_clear_id "$ws" "$id" "pane gone"
    done < <(cmd_inbox open --for root --workspace "$ws" --json 2>/dev/null \
      | jq -r 'select(.from == "steward")
               | select(.message | startswith("STALLED WORKER"))
               | [.id, ((.message | capture("^STALLED WORKER [^(]*\\((?<p>[^)]*)\\)") | .p) // "")]
               | @tsv' 2>/dev/null || true)
  done
}

_steward_nudge() { # <agent-name> <key> <message>
  _steward_due "$2" || return 0
  if herdr agent prompt "$1" "$3" >/dev/null 2>&1; then
    c_ok "nudged $1: $3"
  else
    c_warn "wanted to nudge $1 (not reachable): $3"
  fi
}

# Sanitiser copied from cel run's alias rules so the steward addresses
# orchestrators by the same name cel run gave them.
_steward_agent_name() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-')"
  n="${n#"${n%%[a-z]*}"}"; n="${n%-}"
  printf '%.32s' "$n"
}

# Which herdr agent owns a mailbox - the inverse of lib/inbox.sh's identity.
#
#   root            -> <workspace>-root
#   <repo>-orch     -> <repo>-orch   (and <product>-orch alike: a product
#                      orchestrator's mailbox is named by the same rule, so
#                      the *-orch case below already covers it)
#   anything else   -> A WORKER, whose mailbox name IS its agent name: both
#                      come from the same <repo>-<branch> string through the
#                      same sanitiser (_inbox_sanitise and _run_agent_name are
#                      character-for-character identical).
#
# Workers can wait on inbox instructions too; resolving only root and
# orchestrator panes would silently leave their unread mail unattended.
_steward_mailbox_want() { # <who> <workspace-name>
  case "$1" in
    root) _steward_agent_name "$2/root" ;;
    *-orch) _steward_agent_name "${1%-orch}/orch" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Where a <name>-orch actually stands, for the cwd fallbacks below. A DECLARED
# product has its own directory under products/; an implicit one is only a
# repo. Telling them apart by reading workspace.yaml is not available here -
# identity in this plane is derived from paths, deliberately - so the
# directory's existence is the test. Both sweeps call this rather than
# spelling the choice out twice, which is how the two of them drifted before.
_steward_orch_dir() { # <wsdir> <name>
  local wsdir="$1" name="$2" p="${2%-orch}"
  [ "$p" != "$name" ] || return 0
  if [ -d "$wsdir/products/$p" ]; then printf '%s/products/%s' "$wsdir" "$p"
  else printf '%s/repos/%s' "$wsdir" "$p"; fi
}

# Starting an orchestrator is MECHANICAL, so the steward does it rather than
# root. Root started them by hand and produced duplicate panes bound to
# hand-made workspaces nobody could tell apart; a product declaring
# `orchestrator: auto` is a standing instruction to have one, which is the
# same shape as "this workspace declares a dashboard port".
#
# The launch is its own function so tests can replace it: calling `cel run`
# for real would open a pane on the live box.
_steward_launch_orch() { # <product> <workspace>
  cel run orchestrator --product "$1" --workspace "$2" >/dev/null 2>&1
}

_steward_orchestrators() { # <agents-json>
  local agents_json="$1" ws wsdir p want live
  # An empty roster means herdr did not answer, not that every orchestrator
  # died - launching one per product on a transport failure is how you get a
  # box full of duplicates, which is the incident this whole function is for.
  [ "$(printf '%s' "$agents_json" | jq -r '[.result.agents[]?] | length' 2>/dev/null || printf 0)" -gt 0 ] || return 0
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    [ -f "$wsdir/workspace.yaml" ] || continue
    for p in $(ws_product_names "$wsdir"); do
      # Only `auto`. A product whose orchestrator is started deliberately
      # (or not at all) must never be started behind the operator's back.
      [ "$(ws_product_get "$wsdir" "$p" orchestrator)" = "auto" ] || continue
      want="$(_run_agent_name "$p-orch")"
      live="$(printf '%s' "$agents_json" | jq -r --arg n "$want" \
        '[.result.agents[]? | select(.name == $n)] | length')"
      # It came back: whatever the steward raised about it is no longer true.
      [ "$live" = "0" ] || { _steward_clear "$ws" "orch-ensure-$p" "$want is back on the roster"; continue; }
      # An orchestrator that crash-loops would otherwise be relaunched every
      # tick, which is a fork bomb at five-minute cadence. Half an hour.
      _STEWARD_WINDOW=1800 _steward_due "orch-ensure-$ws-$p" || continue
      if _steward_launch_orch "$p" "$ws"; then
        c_ok "started $want - $ws/$p declares orchestrator: auto and had no live pane (retried at most every 30m)"
        _steward_clear "$ws" "orch-ensure-$p" "$want was started again"
      else
        c_err "could not start $want for $ws/$p - cel run orchestrator --product $p --workspace $ws (retried at most every 30m)"
        _steward_raise "$ws" "orch-ensure-$p" blocked \
          "steward: $ws/$p declares orchestrator: auto and $want will not start - cel run orchestrator --product $p --workspace $ws"
      fi
    done
  done
}

# THE LEDGER LEARNS WHAT THE WORLD ALREADY DID. Twenty-two of the 37 rows the
# owner found in finished/collected were PRs GitHub had merged days earlier:
# merged through the web UI, checkouts removed by hand, so nothing ever ran
# `land` or `release`. Deciding that is deterministic, so it belongs in a tick
# rather than in a human's afternoon. One `gh pr list` per repo per tick,
# which is nothing at a five-minute tick.
# A reconcile that fails is ONE sweep failing: the stalled-worker sweep after
# it is the one whose delay costs work, so this never takes the tick with it.
_steward_reconcile() {
  local ws bin="${CEL_STEWARD_FANOUT:-$_STEWARD_FANOUT}"
  for ws in $(registry_names); do
    if ! "$bin" reconcile --workspace "$ws" 2>&1; then
      c_warn "$ws: reconcile failed - run 'cel-fanout reconcile --workspace $ws' by hand"
    fi
  done
  return 0
}

_steward_review_sweep() { # <agents-json>
  local agents_json="$1" ws wsdir repo slug orch prsj
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    [ -f "$wsdir/workspace.yaml" ] || continue
    for repo in $(ws_repo_names "$wsdir"); do
      slug="$(ws_repo_get "$wsdir" "$repo" url \
              | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
      [ -n "$slug" ] || continue
      # Address the orchestrator by the alias cel run gave it; when that name
      # is not registered (started by hand), fall back to whichever agent
      # pane lives in the repo checkout.
      # THE PRODUCT'S orchestrator, not the repo's: a repo inside a declared
      # product has no pane of its own, so `widget/orch` named something that
      # never existed and every nudge about it was reported as delivered.
      local prod; prod="$(ws_product_of_repo "$wsdir" "$repo")"
      orch="$(_run_agent_name "$prod-orch")"
      local fallback
      fallback="$(printf '%s' "$agents_json" | jq -r --arg d "$(_steward_orch_dir "$wsdir" "$prod-orch")" \
        '[.result.agents[] | select(.cwd == $d)][0].pane_id // empty')"
      herdr agent get "$orch" >/dev/null 2>&1 || { [ -n "$fallback" ] && orch="$fallback"; }
      # ONLY THE FLEET'S OWN PRs. Every PR a worker opens is authored by the
      # token cel runs under, so `--author @me` is the ownership line; a
      # colleague's PR must never be nudged into "action it now".
      # Colleagues' PRs are theirs to land. This filter guards every check
      # below it, including reminders about our ticket naming convention.
      prsj="$(gh pr list --repo "$slug" --author @me \
              --json number,headRefName,reviewDecision,isDraft,statusCheckRollup,createdAt 2>/dev/null)" || continue

      # UNTICKETED PRs. Linear links a PR to its ticket purely from the branch
      # name, so a branch with no identifier can never be tracked: no status to
      # read, no attachment, nothing on the board. `cel-fanout delegate` now
      # refuses to create one, but branches opened before that - or by hand -
      # still need surfacing, so the board and the repo cannot drift apart
      # silently. A day's grace, so work in flight is not nagged immediately.
      # A DRAFT IS THE AUTHOR'S PRIVATE WORK. The review sweep below already
      # leaves drafts alone; this check nagged them anyway (owner, 2026-09-17:
      # "they are intentionally left as drafts"). The steward has no business
      # with a PR its author has not put up for anything yet.
      # Any prefix the repo answers to, current or historical - a branch named
      # before a team re-key is still ticketed and must not be nagged.
      # `tprefix` is an ALTERNATION of every prefix the repo answers to, for
      # matching; `tcanon` is the single current one, for anything a human
      # reads. Kept apart because "ABCD|ABC" is a correct regex and a nonsense
      # instruction.
      local tprefix tcanon
      tprefix="$(ws_repo_prefixes "$wsdir" "$repo" | paste -sd'|' -)"
      tcanon="$(ws_repo_get "$wsdir" "$repo" prefix)"
      if [ "$(ws_ticket "$wsdir" system)" = "linear" ] && [ -n "$tprefix" ]; then
        local unum ubranch uage
        while IFS=$'\t' read -r unum ubranch uage; do
          [ -n "$unum" ] || continue
          # An `if`, not `grep ... && continue`: under set -e the && form
          # returns non-zero exactly when the branch has NO ticket, which is
          # the case this check exists for, and would abort the tick.
          # GROUPED: without the parentheses "ABCD|ABC-[0-9]+" means "ABCD" OR
          # "ABC-<digits>", so any branch merely containing the prefix would
          # count as ticketed.
          if printf '%s' "$ubranch" | grep -qiE "(${tprefix})-[0-9]+"; then continue; fi
          [ "$(( ( $(date +%s) - $(date -d "$uage" +%s 2>/dev/null || date +%s) ) / 86400 ))" -ge 1 ] || continue
          _steward_nudge "$orch" "$slug#$unum-noticket" \
            "steward: PR #$unum on $repo ($ubranch) has no $tcanon ticket in its branch name, so Linear cannot link it and it is invisible on the board. Find or create the ticket (cel-linear search / create), comment the PR link on it, and set its state. Name future branches ${tcanon}-<n>-<slug>."
        done < <(printf '%s' "$prsj" | jq -r '.[] | select(.isDraft | not) | [.number, .headRefName, .createdAt] | @tsv')
      fi

      local num branch review failing working
      while IFS=$'\t' read -r num branch review failing; do
        [ -n "$num" ] || continue
        failing="${failing:-0}"
        # a worker actively on the branch means the loop is moving - leave it
        working="$(printf '%s' "$agents_json" | jq -r --arg d "$HOME/.herdr/worktrees/$repo/$branch" \
          '[.result.agents[] | select(.cwd == $d and .agent_status == "working")] | length')"
        if [ "$review" = "APPROVED" ]; then
          _steward_nudge "$orch" "$slug#$num-approved" \
            "steward: PR #$num on $repo is APPROVED - action it now (merge per policy, or surface for the human)."
        elif [ "$review" = "CHANGES_REQUESTED" ] && [ "$working" = "0" ]; then
          _steward_nudge "$orch" "$slug#$num-changes" \
            "steward: PR #$num on $repo has changes requested and nobody working on $branch - restart the review loop (worker fixes, then reviewer re-reviews)."
        elif [ "$failing" -gt 0 ] && [ "$working" = "0" ]; then
          _steward_nudge "$orch" "$slug#$num-red" \
            "steward: PR #$num on $repo has FAILING checks and nobody on $branch - a red gate is a finding, get a worker on it."
        fi
      done < <(printf '%s' "$prsj" | jq -r '.[] | select(.isDraft | not) |
        [.number, .headRefName,
         (if (.reviewDecision // "") == "" then "NONE" else .reviewDecision end),
         ([.statusCheckRollup[]? | select((.conclusion // .state) as $s | $s == "FAILURE" or $s == "ERROR")] | length)]
        | @tsv')
    done
  done
}

# TICKETS THAT ARE READY TO BUILD. Moving a ticket into the trigger state
# (workspace.yaml `tickets.trigger_state`, default "Ready") is how a human
# starts work from the board. The steward notices, and tells root through the
# INBOX rather than typing into its pane. Rate-limited per ticket, and only
# when no branch already carries the ticket id - a started ticket is not a
# request to start it again.
# STALLED WORKERS. Every other watcher here asks an agent to report; this one
# asks the box. A worker whose provider stream died sends no mail, keeps its
# pane on a retry prompt, and reads as `idle` - the same word herdr uses for a
# healthy worker between turns. The detection lives in lib/stall.sh as pure
# functions so transport failures can be replayed in tests. This sweep walks
# delegations still marked `running`, reads each pane's tail, and asks for
# a verdict.
_steward_stalled_workers() { # <agents-json>
  local agents_json="$1" ws wsdir led
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")"; [ -d "$wsdir" ] || continue
    led="$wsdir/.cel/delegations.json"
    [ -f "$led" ] || continue
    local row
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      local id pane wt ticket branch live text quiet verdict risk sev state
      id="$(printf '%s' "$row" | jq -r '.id')"
      state="$(printf '%s' "$row" | jq -r '.state // ""')"
      pane="$(printf '%s' "$row" | jq -r '.pane // ""')"
      wt="$(printf '%s' "$row" | jq -r '.worktree // ""')"
      ticket="$(printf '%s' "$row" | jq -r '.ticket // ""')"
      branch="$(printf '%s' "$row" | jq -r '.branch // ""')"

      # A row that has LEFT `running` - collected, released, finished - is no
      # longer stalled by definition, and its blocker must go with it.
      if [ "$state" != running ]; then
        _steward_clear "$ws" "stall-$id" "delegation $id is no longer running ($state)"
        continue
      fi

      live="$(printf '%s' "$agents_json" | jq -r --arg p "$pane" \
        '[.result.agents[]? | select(.pane_id == $p) | .agent_status][0] // ""')"
      # A pane with no agent is only "vanished" if we could actually see the
      # roster; herdr being unreachable is not evidence that anyone died, and
      # this file already learned that lesson once.
      text=""
      if [ -n "$pane" ] && [ -n "$live" ]; then
        text="$("$_STEWARD_HERDR" pane read "$pane" --source detection --lines 40 2>/dev/null || true)"
      fi
      quiet="$(stall_quiet_secs "$wt")"
      local wrote=0; [ -f "$wt/.agent/result.md" ] || [ -f "$wt/.agent/report.md" ] && wrote=1
      verdict="$(stall_verdict "$live" "$text" "$quiet" "$wrote")"
      # Working again: the sweep has already computed that, so it is also the
      # moment to resolve what it raised.
      if [ -z "$verdict" ]; then
        _steward_clear "$ws" "stall-$id" "$ws/$id is working again"
        continue
      fi

      risk="$(stall_work_at_risk "$wt")"
      sev="$(stall_severity "$verdict" "$risk")"
      local msg; msg="$(stall_message "$verdict" "$ticket" "$pane" "$quiet" \
        "$(stall_branch_pushed "$wt")" "$risk" "$branch")"

      # Loud means the work itself is at stake, so it goes to root's mailbox as
      # a BLOCKED item - the kind the inbox refuses to let anyone bury - and it
      # repeats. A stalled worker whose work is already pushed is a warning.
      if [ "$sev" = loud ]; then
        _STEWARD_WINDOW=1800 _steward_due "stall-$ws-$id" \
          && _steward_raise "$ws" "stall-$id" blocked "$msg"
        c_err "$ws/$id: $msg"
      else
        _steward_due "stall-$ws-$id" && c_warn "$ws/$id: $msg"
      fi
    done < <(jq -c '.[]' "$led" 2>/dev/null || true)
  done
}

# Which mailbox should a ready ticket go to? Its prefix names a repo, the repo
# names a product, and that product's orchestrator can take the work without
# the hop through root - the hop where most of it used to be lost, forwarded
# by mail nobody drained. Ambiguity (two products answering to one prefix) or
# a product whose orchestrator is not on the roster falls back to root, which
# is where every ready ticket went before.
_steward_ready_ticket_dest() { # <wsdir> <ticket-id> <agents-json>
  local wsdir="$1" id="$2" agents_json="$3" repo pfx prods
  pfx="${id%-*}"
  [ -n "$pfx" ] && [ "$pfx" != "$id" ] || { printf root; return 0; }
  prods=""
  for repo in $(ws_repo_names "$wsdir"); do
    if ws_repo_prefixes "$wsdir" "$repo" | grep -qix -- "$pfx"; then
      prods="$prods$(ws_product_of_repo "$wsdir" "$repo")"$'\n'
    fi
  done
  prods="$(printf '%s' "$prods" | sed '/^$/d' | sort -u)"
  case "$prods" in ""|*$'\n'*) printf root; return 0;; esac
  local live
  live="$(printf '%s' "$agents_json" | jq -r --arg n "$(_run_agent_name "$prods-orch")" \
    '[.result.agents[]? | select(.name == $n)] | length' 2>/dev/null || printf 0)"
  [ "$live" = "0" ] && { printf root; return 0; }
  printf '%s-orch' "$prods"
}

_steward_ready_tickets() { # [agents-json]
  local agents_json="${1:-}"
  local ws wsdir trigger teams key ids id title repo found
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    [ "$(ws_ticket "$wsdir" system)" = "linear" ] || continue
    (
    trigger="$(yq -r '.tickets.trigger_state // "Ready"' "$wsdir/workspace.yaml" 2>/dev/null)"
    # Each workspace starts from the caller's environment, never the previous
    # workspace's overrides. Scope the full credential-dependent sweep so
    # env.local cannot change subsequent workspaces or the parent shell.
    eval "$(ws_env_exports "$wsdir" 2>/dev/null)" >/dev/null 2>&1 || true
    [ -n "${LINEAR_API_KEY:-}" ] || exit 0
    teams="$(yq -r '[.repos[].linear_team // empty] | unique | .[]' "$wsdir/workspace.yaml" 2>/dev/null)"
    [ -n "$teams" ] || exit 0
    for key in $teams; do
      # curl reads sensitive headers from stdin, not the process argument list.
      ids="$(printf 'Authorization: %s\n' "$LINEAR_API_KEY" |
        curl -sf -m 15 -X POST https://api.linear.app/graphql \
        -H @- -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg k "$key" --arg st "$trigger" '{query: "query($k: String!, $st: String!) { issues(filter: {team: {key: {eq: $k}}, state: {name: {eq: $st}}}, first: 20) { nodes { identifier title } } }", variables: {k: $k, st: $st}}')" \
        2>/dev/null | jq -r '.data.issues.nodes[]? | "\(.identifier)\t\(.title)"')" || continue
      [ -n "$ids" ] || continue
      while IFS=$'\t' read -r id title; do
        [ -n "$id" ] || continue
        # already being worked? any branch or worktree naming the ticket
        # The id must END at a separator. A bare `^ABC-1` prefix also matches
        # abc-18-*, so once ticket 18 had a worktree, ticket 1 would look like
        # it was already being worked and be skipped in silence - forever, with
        # no output saying why. Exactly the failure mode this whole sweep
        # exists to prevent, so the boundary is spelled out.
        found=0
        for repo in $(ws_repo_names "$wsdir"); do
          # The ticket NUMBER is stable across a team re-key, the prefix is
          # not. Build every prefix form of this id (ABCD-3 and ABC-3) so a
          # branch cut before the rename still counts as "someone is on it" -
          # otherwise every in-flight ticket looks unstarted and gets handed to
          # root again, and root delegates a second worker onto live work.
          local alt; alt="$(ws_repo_prefixes "$wsdir" "$repo" \
            | sed "s|\$|-${id##*-}|" | paste -sd'|' -)"
          [ -n "$alt" ] || alt="$id"
          [ -d "$HOME/.herdr/worktrees/$repo" ] && \
            ls "$HOME/.herdr/worktrees/$repo" 2>/dev/null | grep -qiE "^(${alt})([-_.]|$)" && found=1
          git -C "$wsdir/repos/$repo" ls-remote --heads origin 2>/dev/null \
            | grep -qiE "refs/heads/(.*/)?(${alt})([-_./]|$)" && found=1
          [ "$found" = 1 ] && break
        done
        [ "$found" = 1 ] && continue
        _steward_due "ready-$id" || continue
        # NEVER offer to move it back. The trigger state is the HUMAN'S signal
        # that they want this built; an agent reversing it erases the request
        # with nobody informed. This message used to end "(or move it back if
        # it is not ready)" and root duly filed two tickets the owner had just
        # moved into Todo straight back to Backlog, silently and without a
        # comment. If it genuinely cannot be started, say so ON the ticket and
        # leave the state for the human to change.
        local dest; dest="$(_steward_ready_ticket_dest "$wsdir" "$id" "$agents_json")"
        cmd_inbox send "$dest" \
          "steward: $id is in '$trigger' with no branch anywhere - $title. The owner moved it there to say BUILD THIS: plan it and delegate to the owning repo orchestrator. DO NOT change its state out of '$trigger' yourself - if it cannot be started, comment on the ticket saying exactly what is missing and leave the state alone for the owner to decide." \
          --from steward --workspace "$ws" --kind status >/dev/null 2>&1 \
          && c_ok "ready ticket $id handed to $dest's inbox"
      done <<< "$ids"
    done
    ) || true
  done
}

# PROVIDER CREDIT, checked every tick and named when it is gone.
# Delegation vetoes an exhausted provider; this sweep makes the balance
# visible before someone attempts another delegation.
# Keys come from each workspace's env, so a provider is checked once per
# workspace that can reach it; the balance is cached, so this is cheap.
# Does any profile in the workspace route to this provider? worker_profiles
# and the review profile are the routes; role_profiles only name them.
_steward_provider_used() { # <wsdir> <provider> -> 0 yes, 1 no
  command -v profile_provider >/dev/null 2>&1 || . "$CEL_ROOT/lib/profiles.sh"
  local m
  for m in $(yq -r '[(.worker_profiles // {} | .[]? | .model // empty), (.review.model // empty)] | .[]' "$1/workspace.yaml" 2>/dev/null); do
    [ "$(profile_provider "$m" 2>/dev/null)" = "$2" ] && return 0
  done
  return 1
}

_steward_quota() {
  # shellcheck source=lib/quota.sh
  . "$CEL_ROOT/lib/quota.sh"
  local ws wsdir p r floor seen=""
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    for p in $(yq -r '.providers | to_entries[] | select(.value.balance != null) | .key' "$CEL_MANIFEST" 2>/dev/null); do
      r="$(quota_remaining "$p" "$wsdir" 2>/dev/null || printf unknown)"
      [ "$r" = unknown ] && continue
      # A dry account nobody routes to vetoes nothing. Measured 2026-09-17:
      # every workspace on the box carried a "deepseek credit is -0.24"
      # blocker for a direct deepseek account no profile used - the deepseek
      # models all go through openrouter - because the key was in the
      # environment and the balance check ran for every provider with one.
      # The blocker is about routes, so it needs a route to exist.
      if ! _steward_provider_used "$wsdir" "$p"; then
        _steward_clear "$ws" "quota-dry-$p" "$p is dry but no profile in $ws routes to it - nothing is vetoed"
        continue
      fi
      # two workspaces on the same key are one account: say it once per tick
      local fp; fp="$(_quota_key "$p" "$wsdir" | sha256sum | cut -c1-12)"
      case " $seen " in *" $p.$fp "*) continue;; esac
      seen="$seen $p.$fp"
      floor="$(provider_balance "$p" floor)"
      if quota_vetoed "$p" "$r"; then
        c_err "$ws: $p has $(printf '%.2f' "$r") $(provider_balance "$p" unit) left (floor $floor) - workers routed there are VETOED until it is topped up: $(provider_get "$p" console)"
        _steward_due "quota-dry-$ws-$p" && _steward_raise "$ws" "quota-dry-$p" blocked \
          "steward: $p credit is $(printf '%.2f' "$r") (floor $floor). Profiles routed there are vetoed; delegations on them will refuse. Top up or repoint the profile." || true
      else
        # Back above the floor: the blocker the steward raised is no longer
        # true, so the steward takes it down rather than leaving a human to
        # work out whether a four-day-old item still applies.
        _steward_clear "$ws" "quota-dry-$p" "$p credit is $(printf '%.2f' "$r") (floor $floor) - back above the floor, routes to it are live again"
        if awk -v r="$r" -v f="$floor" 'BEGIN { exit !(r+0 < 3*f+0) }'; then
          c_warn "$ws: $p is down to $(printf '%.2f' "$r") $(provider_balance "$p" unit) (floor $floor) - running low"
        fi
      fi
    done
  done
}

# THE SUBSCRIPTIONS, once per account per tick.
#
# The two windows the fleet actually runs on are invisible until they stop it:
# a Claude or Codex five-hour window at 100% refuses every worker on that
# account and says nothing anywhere an operator looks. So a window over the
# warning threshold is a rolled-up `status` and a spent one is a `blocked`,
# both keyed per account so a condition that persists lands as an update on
# the item that is already open rather than as a fresh one every tick.
#
# A SUBSCRIPTION IS THE BOX'S, NOT A WORKSPACE'S. There is one Claude account
# behind every workspace on this machine, so the item goes to the first
# registered workspace's root mailbox - saying it once per box is the whole
# point, and saying it per workspace would be the twenty-four-item pile this
# rollup exists to prevent.
_steward_subscriptions() {
  # shellcheck source=lib/quota.sh
  . "$CEL_ROOT/lib/quota.sh"
  local ws; ws="$(registry_names | head -n1)"
  [ -n "$ws" ] || return 0
  local warn="${CEL_SUB_WARN_PCT:-80}"
  local p a t doc worst wname resets state
  while IFS=$'\t' read -r p a t; do
    [ -n "$p" ] || continue
    doc="$(subscription_usage "$p" "$t" "$a" 2>/dev/null || true)"
    [ -n "$doc" ] || continue
    # ONE LINE PER ACCOUNT, so the tightest window speaks for it: two lines
    # about one account is the same fact twice, and the operator acts on the
    # shorter reset either way.
    IFS=$'\t' read -r worst wname resets state <<< "$(printf '%s' "$doc" | jq -r '
      ((.windows // []) | sort_by(-(.used_pct // 0)) | first) as $w
      | [(($w.used_pct // -1)), ($w.name // ""), ($w.resets_at // ""), (.extra.state // "")]
      | @tsv' 2>/dev/null || true)"
    case "$worst" in ''|-1) continue ;; esac

    local pct; pct="$(printf '%.0f' "$worst" 2>/dev/null || printf 0)"
    if [ "$pct" -ge 100 ]; then
      c_err "$p $a: $wname window is spent (100%) - workers on that account are VETOED until it resets at $(sub_reset_human "$resets")"
      _steward_due "sub-$p-$a" && _steward_raise "$ws" "sub-$p-$a" blocked \
        "steward: the $p subscription $a has spent its $wname window (100%). Delegations routed there will refuse until it resets at $(sub_reset_human "$resets")." || true
    elif [ "$pct" -ge "$warn" ]; then
      c_warn "$p $a: $wname window at $pct% (resets $(sub_reset_human "$resets"))"
      _steward_due "sub-$p-$a" && _steward_raise "$ws" "sub-$p-$a" status \
        "steward: the $p subscription $a is at $pct% of its $wname window, resetting at $(sub_reset_human "$resets"). Work routed there will start refusing at 100%." || true
    else
      # Back under the threshold: the steward takes its own item down rather
      # than leaving someone to work out whether a day-old warning still holds.
      _steward_clear "$ws" "sub-$p-$a" "$p $a is back to $pct% of its $wname window - routes to it are clear"
    fi
  done < <(_subscription_accounts)
}

_steward_servers() {
  local ws wsdir port
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    port="$(_wsy "$wsdir" '.dash.port')"
    [ -n "$port" ] || continue
    # SUBSHELL, not a bare call. cmd_dash reports missing prerequisites with
    # die(), and die() is `exit 1` - which `||` cannot catch, because an exit
    # is not a non-zero return. A single missing tool therefore terminated the
    # whole tick here, silently skipping everything after it: ready tickets,
    # the share sweep, the update check. Observed under systemd, where node is
    # absent from PATH - the tick looked like it ran, printed most of its
    # output, and simply never reached the part that picks up work.
    ( cmd_dash --workspace "$ws" --ensure ) >/dev/null 2>&1 \
      || c_err "dash for $ws (port $port) is down and would not start - cel dash --workspace $ws --ensure"
  done
  # Expired public shares are swept, not merely refused: a token dir left on
  # disk is a document sitting in an internet-reachable root.
  local pubroot; pubroot="$(_pages_public_root)"
  if [ -d "$pubroot" ]; then
    local d m exp n=0
    for d in "$pubroot"/*/; do
      d="${d%/}"; m="$d/.share.json"
      [ -f "$m" ] || continue
      exp="$(jq -r '.expires // empty' "$m" 2>/dev/null)"
      [ -n "$exp" ] || continue
      if [ "$(date -u -d "$exp" +%s 2>/dev/null || printf 9999999999)" -lt "$(date -u +%s)" ]; then
        rm -rf "$d" && n=$((n+1))
      fi
    done
    [ "$n" -gt 0 ] && c_ok "swept $n expired public share(s)"
  fi

  # The pages servers are box services with no owning pane, so warning about
  # them was useless - the steward brings them back instead.
  cmd_pages --ensure >/dev/null 2>&1 || c_err "pages server is down and would not start - cel pages --ensure"
  cmd_pages --public --ensure >/dev/null 2>&1 || c_err "public pages server is down and would not start - cel pages --public --ensure"
}

# ORPHANED TEST SERVERS HAVE NO OWNER TO NOTICE THEM. On 2026-09-16 seven
# `node tools/pages/server.mjs` processes, booted by a repo's suite inside a
# gate run that was killed mid-flight, stayed alive for a hundred minutes
# parented to init - and because they had inherited the ledger lock of the
# collect that started the gate, every delegation command on that workspace
# blocked behind them. Nobody was looking: a server in a worktree is not a
# pane, not an agent and not a box service, so no sweep on this box named it.
# This one does. Age comes from the listing rather than being read again here
# so the sweep can be tested without a real server.
_steward_server_procs() { # "<pid> <age-seconds> <port> <cwd>" per pages/dash server
  local pid cmd cwd age port
  for pid in $(pgrep -u "$(id -u)" -f 'tools/(pages|dash)/server\.mjs' 2>/dev/null || true); do
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
    case "$cmd" in *tools/pages/server.mjs*|*tools/dash/server.mjs*) ;; *) continue;; esac
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" || continue
    age="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')" || continue
    [ -n "$cwd" ] && [[ "$age" =~ ^[0-9]+$ ]] || continue
    port="$(printf '%s' "$cmd" | grep -oE '(--port|PORT=)[ =]?[0-9]+' | grep -oE '[0-9]+$' | head -n1 || true)"
    printf '%s %s %s %s\n' "$pid" "$age" "${port:-?}" "$cwd"
  done
}

_steward_orphan_servers() { # <agents-json>
  local agents="$1" root pid age port cwd live
  root="${CEL_WORKTREE_ROOT:-$HOME/.herdr/worktrees}"
  while read -r pid age port cwd; do
    [ -n "${pid:-}" ] || continue
    # Only worktrees. The servers under CEL_ROOT are this box's own services,
    # kept alive on purpose by _steward_servers, and are never touched here.
    case "$cwd" in "$root"/*) ;; *) continue;; esac
    # A worktree with a live agent still owns its servers, whatever their age:
    # a worker running its own suite is the normal case, not an orphan.
    live="$(printf '%s' "$agents" | jq -r --arg d "$cwd" \
      '[.result.agents[]? | select((.cwd // "") == $d or (($d + "/") | startswith((.cwd // "\u0000") + "/")))] | length' 2>/dev/null || printf 0)"
    [ "${live:-0}" -eq 0 ] || continue
    if [ "$age" -ge 3600 ]; then
      if kill -TERM "$pid" 2>/dev/null; then
        c_warn "reaped orphaned test server pid $pid (port $port, $((age / 60))m old) in $cwd - its worktree has no agent"
      else
        c_warn "orphaned test server pid $pid (port $port) in $cwd would not die - kill it by hand"
      fi
    else
      c_warn "orphaned test server pid $pid (port $port, $((age / 60))m old) in $cwd - its worktree has no agent"
    fi
  done < <(_steward_server_procs)
}

# MEMORY: THE STEWARD SAYS SOMETHING BEFORE THE BOX DOES.
#
# The owner, 2026-09-18: "how are we monitoring memory for the workers and can
# that be visualised in the console too?" Nothing was. The box has 24 GB and
# sits at 17 GB used with agents up; a runaway test server or a forgotten
# session was invisible until the kernel picked something to kill, and what it
# picks is never what anyone would have chosen. Two warnings, and NO KILLING:
# the steward reports, the orchestrator decides. A sweep that reaped a worker
# mid-gate would destroy the work it was measuring, and the one number it has
# is an attribution by cwd, not proof of who is at fault.
_STEWARD_MEM_WORKER_WARN_MB="${CEL_MEM_WORKER_WARN_MB:-2048}"

# Every tree the steward knows about, largest first, as `name<TAB>mb`. One
# /proc walk for the whole sweep, as in lib/fleet.sh: the snapshot is what
# keeps this cheap enough to run every five minutes.
#
# ONLY `running` DELEGATIONS. A collected or released row's worktree is gone
# or going, so naming it as one of the largest trees points an operator at
# something nobody can act on - the same rule the fleet's worker list learned.
_steward_mem_trees() { # -> name<TAB>mb, biggest first
  local ws wsdir p d id wt mb
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    [ -f "$wsdir/workspace.yaml" ] || continue
    for p in $(ws_product_names "$wsdir" 2>/dev/null); do
      d="$(_steward_orch_dir "$wsdir" "$p-orch")"
      [ -n "$d" ] && [ -d "$d" ] || continue
      mb="$(mem_tree_rss_mb "$d")"
      [ "${mb:-0}" -gt 0 ] && printf '%s-orch\t%s\n' "$p" "$mb"
    done
    [ -f "$wsdir/.cel/delegations.json" ] || continue
    while IFS=$'\t' read -r id wt; do
      [ -n "$id" ] && [ -n "$wt" ] && [ -d "$wt" ] || continue
      mb="$(mem_tree_rss_mb "$wt")"
      [ "${mb:-0}" -gt 0 ] && printf '%s\t%s\n' "$id" "$mb"
    done < <(jq -r '.[]? | select((.state // "") == "running")
                    | [(.id // ""), (.worktree // "")] | @tsv' \
      "$wsdir/.cel/delegations.json" 2>/dev/null || true)
  done | sort -t"$(printf '\t')" -k2,2nr
}

# Which product owns a delegation, so the warning goes to the orchestrator that
# can act on it rather than to root, who would only forward it.
_steward_mem_owner() { # <wsdir> <repo>
  printf '%s-orch' "$(ws_product_of_repo "$1" "$2")"
}

_steward_memory() {
  local total avail used
  read -r total avail used <<<"$(mem_box)"
  # A box that cannot be measured is not a box in crisis. mem_box prints zeroes
  # for an unreadable meminfo, and a sweep that treated "could not ask" as 0 MB
  # available would raise a blocker every tick on a perfectly healthy box.
  [ "${total:-0}" -gt 0 ] || return 0
  mem_tree_snapshot

  local availpct=$(( avail * 100 / total )) ws
  # HYSTERESIS, 10% to raise and 15% to clear. A single threshold on a box
  # hovering at it posts and resolves the same item every tick, which is the
  # rolled-up version of the noise this file already fixed once.
  if [ "$availpct" -lt 10 ]; then
    local trees top="" name mb n=0
    trees="$(_steward_mem_trees)"
    while IFS=$'\t' read -r name mb; do
      [ -n "$name" ] || continue
      top="$top${top:+, }$name $(mem_human "$mb")"
      n=$((n + 1)); [ "$n" -ge 3 ] && break
    done <<<"$trees"
    local msg
    msg="steward: box memory low: $(mem_human "$avail") of $(mem_human "$total") available - the largest trees: ${top:-none this sweep can see}. Collect or let something go; nothing here has been killed."
    c_err "$msg"
    # The box is one box, but root's mailbox is per workspace - as with a
    # provider account shared by two workspaces, the condition key makes it one
    # rolled-up item in each rather than a fresh one every tick.
    for ws in $(registry_names); do _steward_raise "$ws" mem-box blocked "$msg"; done
  elif [ "$availpct" -ge 15 ]; then
    for ws in $(registry_names); do
      _steward_clear "$ws" mem-box "box memory is back to $(mem_human "$avail") of $(mem_human "$total") available"
    done
  fi

  # AND ONE WORKER THAT IS THE PROBLEM ON ITS OWN. A pi worker is ~340 MB
  # resident; a tree over 2 GB is a test server nobody stopped or a run that
  # went wrong, and its own orchestrator is the thing that can collect it.
  local wsdir id repo wt mb who
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    [ -f "$wsdir/.cel/delegations.json" ] || continue
    while IFS=$'\t' read -r id repo wt; do
      [ -n "$id" ] && [ -n "$wt" ] && [ -d "$wt" ] || continue
      mb="$(mem_tree_rss_mb "$wt")"
      [ "${mb:-0}" -ge "$_STEWARD_MEM_WORKER_WARN_MB" ] || continue
      who="$(_steward_mem_owner "$wsdir" "$repo")"
      c_warn "$ws/$id is holding $(mem_human "$mb") in $wt - told $who"
      _steward_due "mem-worker-$ws-$id" || continue
      cmd_inbox send "$who" \
        "steward: worker $id is holding $(mem_human "$mb") of memory (threshold $(mem_human "$_STEWARD_MEM_WORKER_WARN_MB")) in $wt. Nothing has been stopped - check whether it left a test server or a preview running, and collect it if it is done." \
        --from steward --workspace "$ws" --kind status --fp "mem-worker-$id" >/dev/null 2>&1 || true
    done < <(jq -r '.[]? | select((.state // "") == "running")
                    | [(.id // ""), (.repo // ""), (.worktree // "")] | @tsv' \
      "$wsdir/.cel/delegations.json" 2>/dev/null || true)
  done
  mem_tree_snapshot_clear
}

_STEWARD_UNIT="cel-steward"
_steward_unit_dir() { printf '%s' "${CEL_SYSTEMD_DIR:-$HOME/.config/systemd/user}"; }

# `cel steward --install` - the thing that actually makes the steward proactive.
#
# Every trigger the steward owns (a Linear ticket moved into the workspace's
# trigger state, a stalled review, a mailbox nobody is draining, a dashboard
# that fell over) is documented as "the steward notices", and none of it
# happens unless something runs a tick. `cel --help` said "run it on a loop"
# and nothing in the plane established that loop, so trigger_state was a
# promise with no machinery: tickets sat in Todo indefinitely.
#
# A systemd USER TIMER rather than a herdr pane running `while true`, because
# the steward's whole job is to be running when nobody is watching. A pane
# loop dies with the herdr session and takes the watcher with it silently -
# which is exactly how this gap went unnoticed. The timer survives logout and
# reboot, and `journalctl --user -u cel-steward` keeps the history.
_steward_install() { # [--interval MIN] [--remove]
  local mins=5 remove=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) mins="$2"; shift 2 ;;
      --remove)   remove=1; shift ;;
      *) die "cel steward --install: unknown argument '$1'" ;;
    esac
  done
  have systemctl || die "cel steward --install: systemd --user is required (on a box without it, run 'cel steward' from cron or a supervised loop)"
  local d; d="$(_steward_unit_dir)"; mkdir -p "$d"

  if [ "$remove" -eq 1 ]; then
    systemctl --user disable --now "$_STEWARD_UNIT.timer" >/dev/null 2>&1 || true
    rm -f "$d/$_STEWARD_UNIT.service" "$d/$_STEWARD_UNIT.timer"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    c_ok "removed the $_STEWARD_UNIT timer"
    return 0
  fi

  printf '%s' "[Unit]
Description=celestial steward - one proactive tick over the fleet
After=default.target

[Service]
Type=oneshot
# A login shell, because the tick needs the per-workspace env that carries
# LINEAR_API_KEY. But a NON-INTERACTIVE login shell does not activate mise, so
# node and bun are missing from PATH and every server check fails - the shim
# directory is prepended explicitly rather than relying on shell rc files that
# only run for interactive sessions.
ExecStart=/bin/bash -lc 'export PATH=\"\$HOME/.local/share/mise/shims:\$HOME/.local/bin:\$PATH\"; exec \"$CEL_ROOT/bin/cel\" steward'
TimeoutStartSec=600
" > "$d/$_STEWARD_UNIT.service"

  printf '%s' "[Unit]
Description=run the celestial steward every ${mins}m

[Timer]
OnBootSec=2min
OnUnitActiveSec=${mins}min
# A tick missed while the box was asleep runs on wake rather than being
# skipped - a ticket moved to the trigger state overnight is still waiting.
Persistent=true
AccuracySec=30s

[Install]
WantedBy=timers.target
" > "$d/$_STEWARD_UNIT.timer"

  systemctl --user daemon-reload || die "cel steward --install: systemctl daemon-reload failed"
  systemctl --user enable --now "$_STEWARD_UNIT.timer" \
    || die "cel steward --install: could not enable $_STEWARD_UNIT.timer"
  c_ok "steward timer installed - every ${mins}m (systemctl --user list-timers | grep $_STEWARD_UNIT)"
  # Without lingering the timer stops when the last session closes, which
  # would reproduce the pane-loop failure this exists to avoid.
  if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
    c_warn "user lingering is off - the timer stops when you log out. Enable with: sudo loginctl enable-linger $USER"
  fi
}

# Is this box behind its latest release? The steward is the only thing that
# asks on its own, so it is also the only thing that can tell the dashboard:
# the marker file it writes here is what the dash build chip reads per request,
# hours after the dashboard booted. Removing it when current matters as much as
# writing it - a stale chip would nag about an update that already landed.
_steward_update_check() {
  # shellcheck source=lib/version.sh
  . "$(dirname "${BASH_SOURCE[0]}")/version.sh"
  # shellcheck source=lib/config.sh
  . "$(dirname "${BASH_SOURCE[0]}")/config.sh"
  local v latest dir chan
  dir="${CEL_UPDATE_DIR:-$HOME/.local/share/cel/update}"
  chan="$(cel_config_get update channel)"
  case "$chan" in main) ;; *) chan=release ;; esac

  # On the main channel the tag never moves, so "a new release is out" never
  # fires and the box hears nothing for thirty-odd merges. What it needs to
  # hear is the distance and the sha its build came from.
  if [ "$chan" = main ]; then
    local n ws
    git -C "$CEL_ROOT" fetch -q origin main 2>/dev/null || true
    n="$(cel_commits_behind_main)"
    if [ "$n" -gt 0 ] 2>/dev/null; then
      mkdir -p "$dir"
      printf 'main+%s %s\n' "$n" "$(cel_build_sha)" >"$dir/available"
      c_warn "$n new commits on celestial main since $(cel_build_line) - run: cel update --check"
      # A STATUS line, and exactly one: nobody has to ANSWER "there are new
      # commits" - the console reads it and the operator runs the command when
      # they feel like it. A decision or a blocker would sit in root's open
      # list waiting on a human who owes it nothing. The once-a-day window
      # around this check is what keeps it to one line.
      for ws in $(registry_names 2>/dev/null); do
        _steward_raise "$ws" cel-update status \
          "steward: $n new commits on celestial main since your build ($(cel_build_sha)) - cel update --check lists them, cel update takes them"
      done
    else
      rm -f "$dir/available"
      for ws in $(registry_names 2>/dev/null); do
        _steward_clear "$ws" cel-update "celestial is level with main again"
      done
    fi
    return 0
  fi

  v="$(cel_version)"; latest="$(cel_latest_remote_version)"
  if [ -n "$latest" ] && cel_version_lt "$v" "$latest"; then
    mkdir -p "$dir"
    printf '%s\n' "$latest" >"$dir/available"
    c_warn "celestial v$latest is out (installed v$v) - run: cel update"
  else
    rm -f "$dir/available"
  fi
  return 0
}

# `| sed -n 1p`, NEVER `| head -1`, on anything that can be long. bin/cel runs
# under `set -euo pipefail`: when `head` closes the pipe after one line the
# producer takes SIGPIPE, the pipeline's status is 141, and `set -e` ends the
# tick right there - silently. The stale-mailbox sweep did exactly that once
# the product workspace's mailbox passed a pipe buffer in size: 55 failed
# ticks in a day, "Main process exited, status=2", no message. sed reads to
# the end and exits 0.
cmd_steward() { # [--no-gc] [--install [--interval MIN] [--remove]]
  local do_gc=1
  if [ "${1:-}" = "--install" ]; then shift; _steward_install "$@"; return $?; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-gc) do_gc=0; shift ;;
      *) die "cel steward: unknown argument '$1' (want --no-gc or --install)" ;;
    esac
  done
  have herdr || die "cel steward: herdr is not on PATH"
  have jq    || die "cel steward: jq is not on PATH"
  have gh    || die "cel steward: gh is not on PATH"
  c_hd "steward tick $(date '+%F %T')"

  # Under memory pressure the reap window collapses: idle agents are the
  # reclaimable mass on this box, and 2h idle is finished work, not a pause.
  local reap="${CEL_STEWARD_REAP_HOURS:-12}" avail
  avail="$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || printf 9999999)"
  if [ "$avail" -lt 2097152 ]; then
    c_warn "memory pressure: $((avail / 1024))MB available - reap window drops to 2h"
    reap=2
  fi
  [ "$do_gc" -eq 1 ] && cmd_gc --reap "$reap"

  local agents_json
  agents_json="$(herdr agent list 2>/dev/null || printf '{"result":{"agents":[]}}')"

  _steward_review_sweep "$agents_json"
  # And then the ledger closes what the world already closed - after the
  # review sweep, because a PR it nudged about this tick may be the very one
  # that has just been merged.
  _steward_reconcile
  # Before the inbox sweeps: a dead worker is the one failure no inbox watcher
  # can see, and the one whose delay can cost the work rather than just time.
  _steward_stalled_workers "$agents_json"
  # An item naming a pane that no longer exists cannot be acted on by anyone.
  _steward_clear_dead_panes

  # blocked agents are the human's queue - name them every tick, no dedup
  printf '%s' "$agents_json" | jq -r \
    '.result.agents[] | select(.agent_status == "blocked") | "\(.pane_id) \(.cwd)"' \
    | while read -r pane cwd; do c_warn "BLOCKED agent in $pane ($cwd) - needs input"; done

  # STALE INBOX MAIL IS THE ONE CASE THAT JUSTIFIES TYPING AT A PANE.
  # Fresh mail is delivered by the recipient's monitor or the prompt hook, so
  # early warnings would be noise. But mail unread for half an hour means
  # BOTH paths are dead - a monitor that died with its session, and a human
  # who has not spoken to that pane - and warning about it in the steward's
  # own pane (which nobody reads either) is how root sat 68 messages behind
  # for six hours. So the steward nudges the recipient itself, once an hour,
  # naming what it is sitting on.
  local ws wsdir who n oldest age pane
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    local f; f="$(_inbox_file "$ws")"
    [ -s "$f" ] || continue
    for who in $(jq -r '.to' "$f" 2>/dev/null | sort -u); do
      case "$who" in *:*) continue;; esac   # pane-addressed, not a mailbox
      n="$(cmd_inbox count --for "$who" --workspace "$ws" 2>/dev/null || printf 0)"
      [ "${n:-0}" -gt 0 ] || continue
      # age of the OLDEST unread, not the newest: that is how long the
      # recipient has actually been behind
      local cur; cur="$(cat "$(_inbox_cursor "$ws" "$who")" 2>/dev/null || printf '')"
      oldest="$(jq -r --arg w "$who" --arg last "$cur" \
        'select(.to == $w) | select($last == "" or (.id > $last)) | .ts' "$f" 2>/dev/null | sed -n 1p)"
      [ -n "$oldest" ] || continue
      age=$(( $(date +%s) - $(date -d "$oldest" +%s 2>/dev/null || date +%s) ))
      [ "$age" -ge 1800 ] || continue

      # where does that recipient live? root is the workspace root, an orch is
      # its repo checkout - the same derivation cel inbox uses in reverse
      local target="" want=""
      want="$(_steward_mailbox_want "$who" "$(ws_name "$wsdir")")"
      if [ "$who" = root ]; then
        target="$wsdir"
      else
        target="$(_steward_orch_dir "$wsdir" "$who")"
        # A WORKER gets no `target`: splitting <repo>-<branch> back apart is
        # guesswork the moment a repo name contains a hyphen, and this file
        # already learned that nudging the wrong pane is worse than nudging
        # none, because it reports success. Its name match is exact anyway.
      fi
      # NAME FIRST, cwd only as a fallback. Matching on cwd alone picks the
      # first agent sitting in that directory, and a workspace root routinely
      # holds more than one - a personal assistant pane, a scratch session -
      # so root's nudges were landing on whichever happened to be first in the
      # list. A watcher that nudges the wrong pane is worse than no watcher,
      # because it reports success: observed with root 9 hours behind while
      # every tick claimed it had been told.
      pane=""
      [ -n "$want" ] && pane="$(printf '%s' "$agents_json" | jq -r --arg n "$want" \
        '[.result.agents[] | select(.name == $n)][0].pane_id // empty')"
      [ -n "$pane" ] || { [ -n "$target" ] && pane="$(printf '%s' "$agents_json" \
        | jq -r --arg d "$target" '[.result.agents[] | select(.cwd == $d)][0].pane_id // empty')"; }

      if [ -n "$pane" ] && _steward_due "inbox-stale-$ws-$who"; then
        herdr agent prompt "$pane" \
          "steward: $n unread in your celestial inbox, oldest untouched $((age / 60))m. Run 'cel inbox read' now and act on the escalations first. If your runtime has a background-task tool (claude: Monitor), also re-arm 'cel inbox watch' so the next one reaches you without this nudge." \
          >/dev/null 2>&1 \
          && c_warn "$ws/$who: $n unread ($((age / 60))m) - nudged $pane to re-arm and drain"
      else
        c_warn "$ws/$who: $n unread, oldest $((age / 60))m$([ -z "$pane" ] && printf ' (no pane to nudge)')"
      fi
    done
  done

  # OPEN DECISIONS are checked separately from unread mail, and NOT gated on
  # it: a decision the recipient has already `read` and moved past has zero
  # unread but is still unanswered - that is the buried-question case, and the
  # unread check above cannot see it by construction. After an hour the
  # recipient's pane is told the decision text itself; after two, root hears
  # that a subordinate is sitting on one (root's own open decisions are the
  # human's to notice, so those only warn here).
  for ws in $(registry_names); do
    local f2; f2="$(_inbox_file "$ws")"
    [ -f "$f2" ] || continue
    for who in $(jq -r 'select(.kind == "decision" or .kind == "blocked") | .to' "$f2" 2>/dev/null | sort -u); do
      case "$who" in *:*|all) continue;; esac
      local open oldest2 age2 n2
      open="$(cmd_inbox open --for "$who" --workspace "$ws" --json 2>/dev/null || true)"
      [ -n "$open" ] || continue
      n2="$(printf '%s\n' "$open" | wc -l | tr -d ' ')"
      oldest2="$(printf '%s\n' "$open" | jq -r '.ts' | sort | sed -n 1p)"
      age2=$(( $(date +%s) - $(date -d "$oldest2" +%s 2>/dev/null || date +%s) ))
      [ "$age2" -ge 3600 ] || continue
      local text2; text2="$(printf '%s\n' "$open" | jq -r '"[\(.id)] \(.kind) from \(.from): \(.message)"' | head -3)"
      local pane2="" want2 target2=""
      if [ "$who" = root ]; then
        want2="$(_steward_agent_name "$(registry_name_of_dir "$(registry_path "$ws")" 2>/dev/null || printf '%s' "$ws")/root")"; target2="$(registry_path "$ws")"
      else
        local repo2="${who%-orch}"
        [ "$repo2" != "$who" ] && { want2="$(_steward_agent_name "$repo2/orch")"; target2="$(_steward_orch_dir "$(registry_path "$ws")" "$who")"; }
      fi
      [ -n "$want2" ] && pane2="$(printf '%s' "$agents_json" | jq -r --arg n "$want2" '[.result.agents[] | select(.name == $n)][0].pane_id // empty')"
      [ -n "$pane2" ] || { [ -n "$target2" ] && pane2="$(printf '%s' "$agents_json" | jq -r --arg d "$target2" '[.result.agents[] | select(.cwd == $d)][0].pane_id // empty')"; }
      if [ -n "$pane2" ] && _steward_due "decision-open-$ws-$who"; then
        herdr agent prompt "$pane2" \
          "steward: you have $n2 UNRESOLVED decision(s)/blocker(s), oldest $((age2 / 60))m - reading them did not resolve them. Answer or act, then 'cel inbox resolve <id>'. Open now:
$text2" >/dev/null 2>&1 \
          && c_warn "$ws/$who: $n2 open decision(s) ($((age2 / 60))m) - nudged $pane2 to resolve"
      else
        c_warn "$ws/$who: $n2 open decision(s), oldest $((age2 / 60))m$([ -z "$pane2" ] && printf ' (no pane to nudge)')"
      fi
      if [ "$who" != root ] && [ "$age2" -ge 7200 ] && _steward_due "decision-open-root-$ws-$who"; then
        cmd_inbox send root "steward: $who has $n2 decision(s)/blocker(s) unresolved for $((age2 / 3600))h - it may be stuck on them. Oldest: ${text2%%$'\n'*}" \
          --from steward --workspace "$ws" --kind status >/dev/null 2>&1 || true
      fi
    done
  done

  # page feedback whose publishing pane is gone queues here; it stays a
  # warning every tick until someone drains the log
  local fblog n
  for fblog in "$(_pages_root)/.meta/feedback.log" "$(_pages_public_root)/.meta/feedback.log"; do
    [ -s "$fblog" ] || continue
    n="$(wc -l < "$fblog" | tr -d ' ')"
    c_warn "$n undelivered page feedback item(s) in $fblog - deliver or clear"
  done

  # Once a day: is the plane itself behind its latest release? The steward
  # is the thing the human actually reads, so the update notice lives here
  # too, not only in doctor.
  if _STEWARD_WINDOW=86400 _steward_due "cel-update-check"; then
    _steward_update_check
  fi

  _steward_ready_tickets "$agents_json"
  _steward_quota
  _steward_subscriptions
  # Before the server sweeps: a box at 5% available is why the next thing in
  # this tick fails to start, and reading that warning after three failures is
  # reading it in the wrong order.
  _steward_memory
  _steward_services
  _steward_servers
  _steward_orphan_servers "$agents_json"
  _steward_orchestrators "$agents_json"
  c_ok "tick complete"
}

# ── declared services (CEL-26) ───────────────────────────────────────────────
#
# A service with a `health:` path is the only thing on this box that can be
# asked, rather than guessed at, whether it is working - so it is asked, once
# per tick. ONE down tick is a restart, a deploy, a laptop lid; TWO CONSECUTIVE
# down ticks is a service that is not coming back on its own, and that is the
# point at which root hears about it. The count lives beside the nudge state
# because it is the same kind of fact: what was true last time this ran.
# RESOLVED PER CALL, never captured at source time. The suite points
# CEL_STEWARD_STATE at a fixture AFTER sourcing this file, and a path frozen
# when the library loaded meant every test counted down-ticks in the real
# box's state file - which is both a lie and a write to the live box.
_steward_svc_state() {
  printf '%s' "${CEL_STEWARD_SVC_STATE:-${CEL_STEWARD_STATE:-$_STEWARD_STATE}.services}"
}

_steward_svc_read() { # <key> -> "<down-count> <restarted>"
  local f; f="$(_steward_svc_state)"
  awk -v k="$1" '$1 == k { c = $2; r = $3 } END { printf "%d %d", c + 0, r + 0 }' "$f" 2>/dev/null \
    || printf '0 0'
}

_steward_svc_write() { # <key> <down-count> <restarted>
  local f; f="$(_steward_svc_state)"
  mkdir -p "$(dirname "$f")"; touch "$f"
  { awk -v k="$1" '$1 != k' "$f"; printf '%s %s %s\n' "$1" "$2" "$3"; } \
    > "$f.tmp" && mv "$f.tmp" "$f"
}

_steward_services() {
  local ws wsdir e name url health restart port key count restarted state msg last note
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    [ -f "$wsdir/workspace.yaml" ] || continue
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      health="$(printf '%s' "$e" | jq -r '.health // ""')"
      # No health path, no opinion. A port that is merely open is not evidence
      # a service works, and raising a blocker on a guess is how a watcher
      # earns the right to be ignored.
      [ -n "$health" ] || continue
      name="$(printf '%s' "$e" | jq -r '.name')"
      url="$(printf '%s' "$e" | jq -r '.url')"
      restart="$(printf '%s' "$e" | jq -r '.restart // ""')"
      port="$(svc_port_of_url "$url")"
      key="$ws/$name"
      read -r count restarted <<<"$(_steward_svc_read "$key")"
      if svc_listening "$port" && svc_health_ok "$port" "$health"; then
        _steward_svc_write "$key" 0 0
        [ "${count:-0}" -ge 2 ] && _steward_clear "$ws" "service-$ws-$name" \
          "$name is answering on :$port again"
        continue
      fi
      count=$((count + 1))
      note=""
      if [ "$count" -ge 2 ] && [ "$restart" = auto ] && [ "${restarted:-0}" -eq 0 ]; then
        # ONE restart per condition, not one per tick. A service that dies on
        # start would otherwise be restarted every five minutes forever, and
        # the blocker would never say anything a human could act on.
        ( svc_restart "$wsdir" "$name" ) >/dev/null 2>&1 || true
        restarted=1
        note=" I restarted it once (restart: auto) and it did not come back."
      fi
      _steward_svc_write "$key" "$count" "$restarted"
      [ "$count" -ge 2 ] || { c_warn "$ws: $name did not answer on :$port (first miss)"; continue; }
      last="$(svc_last_log_line "$wsdir" "$name" 2>/dev/null || true)"
      msg="steward: service $name ($ws) is down - nothing answered $health on :$port for two consecutive ticks.${note} Last line of its pane: ${last:-nothing to read}. Start it with 'cel services start $name --workspace $ws' or read it with 'cel services logs $name --workspace $ws'."
      c_err "$msg"
      _steward_raise "$ws" "service-$ws-$name" blocked "$msg"
    done < <(_svc_declared "$wsdir")
  done
}
