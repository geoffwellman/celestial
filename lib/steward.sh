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

# Overridable so the stalled-worker sweep can be driven against a stub pane:
# the failure this sweep exists for is a specific string in a specific pane,
# and a test that cannot supply that string proves nothing.
_STEWARD_HERDR="${CEL_STEWARD_HERDR:-herdr}"
_STEWARD_STATE="${CEL_STEWARD_STATE:-$HOME/.local/share/cel/steward-state}"
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
      orch="$(_steward_agent_name "$repo/orch")"
      local fallback
      fallback="$(printf '%s' "$agents_json" | jq -r --arg d "$wsdir/repos/$repo" \
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
        done < <(printf '%s' "$prsj" | jq -r '.[] | [.number, .headRefName, .createdAt] | @tsv')
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
      local id pane wt ticket branch live text quiet verdict risk sev
      id="$(printf '%s' "$row" | jq -r '.id')"
      pane="$(printf '%s' "$row" | jq -r '.pane // ""')"
      wt="$(printf '%s' "$row" | jq -r '.worktree // ""')"
      ticket="$(printf '%s' "$row" | jq -r '.ticket // ""')"
      branch="$(printf '%s' "$row" | jq -r '.branch // ""')"

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
      [ -n "$verdict" ] || continue

      risk="$(stall_work_at_risk "$wt")"
      sev="$(stall_severity "$verdict" "$risk")"
      local msg; msg="$(stall_message "$verdict" "$ticket" "$pane" "$quiet" \
        "$(stall_branch_pushed "$wt")" "$risk" "$branch")"

      # Loud means the work itself is at stake, so it goes to root's mailbox as
      # a BLOCKED item - the kind the inbox refuses to let anyone bury - and it
      # repeats. A stalled worker whose work is already pushed is a warning.
      if [ "$sev" = loud ]; then
        _STEWARD_WINDOW=1800 _steward_due "stall-$ws-$id" \
          && cmd_inbox send root "$msg" --workspace "$ws" --kind blocked >/dev/null 2>&1
        c_err "$ws/$id: $msg"
      else
        _steward_due "stall-$ws-$id" && c_warn "$ws/$id: $msg"
      fi
    done < <(jq -c '.[] | select(.state == "running")' "$led" 2>/dev/null || true)
  done
}

_steward_ready_tickets() {
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
        cmd_inbox send root \
          "steward: $id is in '$trigger' with no branch anywhere - $title. The owner moved it there to say BUILD THIS: plan it and delegate to the owning repo orchestrator. DO NOT change its state out of '$trigger' yourself - if it cannot be started, comment on the ticket saying exactly what is missing and leave the state alone for the owner to decide." \
          --from steward --workspace "$ws" --kind status >/dev/null 2>&1 \
          && c_ok "ready ticket $id handed to root's inbox"
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
_steward_quota() {
  # shellcheck source=lib/quota.sh
  . "$CEL_ROOT/lib/quota.sh"
  local ws wsdir p r floor seen=""
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    for p in $(yq -r '.providers | to_entries[] | select(.value.balance != null) | .key' "$CEL_MANIFEST" 2>/dev/null); do
      r="$(quota_remaining "$p" "$wsdir" 2>/dev/null || printf unknown)"
      [ "$r" = unknown ] && continue
      # two workspaces on the same key are one account: say it once per tick
      local fp; fp="$(_quota_key "$p" "$wsdir" | sha256sum | cut -c1-12)"
      case " $seen " in *" $p.$fp "*) continue;; esac
      seen="$seen $p.$fp"
      floor="$(provider_balance "$p" floor)"
      if quota_vetoed "$p" "$r"; then
        c_err "$ws: $p has $(printf '%.2f' "$r") $(provider_balance "$p" unit) left (floor $floor) - workers routed there are VETOED until it is topped up: $(provider_get "$p" console)"
        _steward_due "quota-dry-$ws-$p" && cmd_inbox send root \
          "steward: $p credit is $(printf '%.2f' "$r") (floor $floor). Profiles routed there are vetoed; delegations on them will refuse. Top up or repoint the profile." \
          --from steward --workspace "$ws" --kind blocked >/dev/null 2>&1 || true
      elif awk -v r="$r" -v f="$floor" 'BEGIN { exit !(r+0 < 3*f+0) }'; then
        c_warn "$ws: $p is down to $(printf '%.2f' "$r") $(provider_balance "$p" unit) (floor $floor) - running low"
      fi
    done
  done
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
  # Before the inbox sweeps: a dead worker is the one failure no inbox watcher
  # can see, and the one whose delay can cost the work rather than just time.
  _steward_stalled_workers "$agents_json"

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
        'select(.to == $w) | select($last == "" or (.id > $last)) | .ts' "$f" 2>/dev/null | head -1)"
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
      oldest2="$(printf '%s\n' "$open" | jq -r '.ts' | sort | head -1)"
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
  # shellcheck source=lib/version.sh
  . "$CEL_ROOT/lib/version.sh"
  if _STEWARD_WINDOW=86400 _steward_due "cel-update-check"; then
    local _v _latest
    _v="$(cel_version)"; _latest="$(cel_latest_remote_version)"
    if [ -n "$_latest" ] && cel_version_lt "$_v" "$_latest"; then
      c_warn "celestial v$_latest is out (installed v$_v) - run: cel update"
    fi
  fi

  _steward_ready_tickets
  _steward_quota
  _steward_servers
  c_ok "tick complete"
}
