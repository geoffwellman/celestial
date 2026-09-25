# shellcheck shell=bash
# Every box-level check `cel doctor` runs. Prints a report; `cmd_doctor`
# returns non-zero if anything is wrong.
[ -n "${_CEL_DOCTOR:-}" ] && return 0
_CEL_DOCTOR=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/manifest.sh
. "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"
# shellcheck source=lib/externals.sh
. "$(dirname "${BASH_SOURCE[0]}")/externals.sh"
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/install.sh
. "$(dirname "${BASH_SOURCE[0]}")/install.sh"   # extensions_missing
# shellcheck source=lib/run.sh
. "$(dirname "${BASH_SOURCE[0]}")/run.sh"   # _run_wsm_bin, for the layout check
# shellcheck source=lib/console.sh
. "$(dirname "${BASH_SOURCE[0]}")/console.sh"   # console_deps_ok, for the console check
# shellcheck source=lib/liveness.sh
. "$(dirname "${BASH_SOURCE[0]}")/liveness.sh"  # liveness_doctor_line
# shellcheck source=lib/gc.sh
. "$(dirname "${BASH_SOURCE[0]}")/gc.sh"   # gc_doctor_line, for the blind-GC line
# shellcheck source=lib/box.sh
. "$(dirname "${BASH_SOURCE[0]}")/box.sh"   # box_doctor_line, for the floor check
# shellcheck source=lib/orphans.sh
. "$(dirname "${BASH_SOURCE[0]}")/orphans.sh"   # orphans_doctor_line
# shellcheck source=lib/gateway.sh
. "$(dirname "${BASH_SOURCE[0]}")/gateway.sh"   # gateway_doctor_line
# shellcheck source=lib/services.sh
. "$(dirname "${BASH_SOURCE[0]}")/services.sh"   # _svc_box, for the box services line
# shellcheck source=lib/wslife.sh
. "$(dirname "${BASH_SOURCE[0]}")/wslife.sh"   # wslife_doctor_lines, for the nameless agent
# shellcheck source=lib/fleet.sh
. "$(dirname "${BASH_SOURCE[0]}")/fleet.sh"   # fleet_mail_doctor_line, for root's mailbox

# One line for the services this box runs on nobody's behalf in particular:
# how many it declares and how many are actually answering. The second half is
# the part that matters - a gateway configured in cel.yaml with nothing in
# services.d is a gateway no sweep is watching, which is exactly how the broker
# and the gateway spent a day up, unsupervised, with nothing on the box able to
# notice if they stopped.
doctor_box_services_line() {
  local rows n healthy e url health hauth port
  rows="$(_svc_box)"
  n="$(printf '%s' "$rows" | grep -c . || true)"
  healthy=0
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    url="$(printf '%s' "$e" | jq -r '.url')"
    health="$(printf '%s' "$e" | jq -r '.health // ""')"
    hauth="$(printf '%s' "$e" | jq -r '.health_auth // ""')"
    port="$(svc_port_of_url "$url")"
    svc_listening "$port" || continue
    if [ -n "$health" ] && ! svc_health_ok "$port" "$health" "$hauth"; then continue; fi
    healthy=$((healthy + 1))
  done <<< "$rows"
  printf '  box services: %s declared, %s healthy\n' "${n:-0}" "$healthy"
  if gateway_installed && ! svc_box_declared cel-auth-gateway; then
    printf '  gateway not supervised - cel gateway install\n'
  fi
  return 0
}

# HOW FAR BEHIND THE TREE YOU ARE READING IS. On 2026-09-21 the orchestrator's
# $ws/repos/celestial sat at d2da692 while main was at 81022b5 - eighteen
# commits, all day - and every conclusion drawn from it was truthful about the
# wrong tree: a branch "measured" 3x slower than a main that predated
# lib/orphans.sh, and a review of #75 declaring that code which had landed
# hours earlier did not exist. Nothing anywhere said the checkout was stale.
# This is the cheap half of CEL-55 and it would have caught all three on the
# first tick of the day.
#
# A CHECKOUT THAT CANNOT BE ASKED IS UNKNOWN. No remote, no network, a remote
# that refuses - all of them say so out loud, because silence here reads as
# "up to date", which is exactly the failure being guarded.
doctor_checkout_behind_line() { # <dir> <label> -> one line, or nothing
  local dir="$1" label="$2" br n
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
  if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    printf '%s: UNKNOWN - no origin remote, so how current it is cannot be asked\n' "$label"
    return 0
  fi
  br="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  br="${br#origin/}"
  [ -n "$br" ] || br="$(git -C "$dir" remote show origin 2>/dev/null \
    | awk '/HEAD branch:/{print $NF; exit}' || true)"
  [ -n "$br" ] && [ "$br" != "(unknown)" ] || {
    printf '%s: UNKNOWN - origin names no default branch\n' "$label"; return 0; }
  if ! git -C "$dir" fetch -q origin "$br" 2>/dev/null; then
    printf '%s: UNKNOWN - origin/%s could not be fetched (offline?), so staleness is unknown\n' "$label" "$br"
    return 0
  fi
  n="$(git -C "$dir" rev-list --count HEAD..FETCH_HEAD 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) printf '%s: UNKNOWN - HEAD and origin/%s cannot be compared\n' "$label" "$br"; return 0;; esac
  [ "$n" -gt 0 ] || return 0
  printf '%s: %s commits behind origin/%s - git -C %s pull --ff-only\n' "$label" "$n" "$br" "$dir"
}

check_roles_and_runtimes() {
  local fail=0 a ad l target strat
  c_hd "Roles and runtimes"

  # A role body in an agents dir is registered as a globally dispatchable
  # subagent in every session on this box, carrying a prompt that references
  # panes, worktrees and .agent/result.md - none of which a subagent has.
  for a in $(agent_names); do
    ad="$(agent_agents_dir "$a")"
    [ -z "$ad" ] || [ ! -d "$ad" ] && continue
    for l in "$ad"/*.md; do
      [ -L "$l" ] || continue
      target="$(readlink -f "$l" 2>/dev/null || true)"
      case "$target" in
        */core/roles/*|*/fleet-agents/agents/*)
          c_err "role body linked as a subagent: $l -> $target"; fail=1 ;;
      esac
    done
  done
  [ "$fail" = 0 ] && c_ok "no role bodies exposed as subagents"

  for a in $(agent_names); do
    strat="$(agent_injection "$a" strategy)"
    case "$strat" in
      append_flag|append_flag_file|agent_file|prompt_arg) ;;
      "") c_err "$a declares no role_injection.strategy"; fail=1 ;;
      *)  c_err "$a has an unknown role_injection.strategy: $strat"; fail=1 ;;
    esac
  done

  # Every managed worktree belongs to herdr, so doctor can find it.
  # An agent-created tree outside herdr is not supervised by the plane.
  if [ -d "$HOME/.omp/wt" ] && [ -n "$(ls -A "$HOME/.omp/wt" 2>/dev/null)" ]; then
    c_err "~/.omp/wt is not empty - a worker created its own worktree outside herdr"
    fail=1
  else
    c_ok "no omp-owned worktrees"
  fi

  return "$fail"
}

# THE WORKSPACE'S OWN GITHUB ACCOUNT (CEL-70). A declared `github.user` that
# is not logged in makes every launch and every plane call for that workspace
# refuse, so doctor says it first, with the fix. `gh auth status` lists every
# logged-in account per host; only whether ours is among them is read here -
# its output is never printed, so no token (masked or not) reaches the report.
doctor_github_account() { # <name> <wsdir>
  local n="$1" wsdir="$2" user host rc=0
  user="$(ws_github_user "$wsdir")"
  [ -n "$user" ] || return 0
  if gh auth status 2>&1 | grep -qE "account ${user}([^A-Za-z0-9-]|\$)"; then
    c_ok "$n: gh account $user logged in"
  else
    c_err "$n: $(ws_github_fix "$user")"; rc=1
  fi
  host="$(ws_github_ssh_host "$wsdir")"
  [ -n "$host" ] || return "$rc"
  # A LITERAL, standalone Host token (CEL-79): the alias used to go into a
  # regex, so its dots matched anything, and a wildcard `Host gh.*` passed for
  # an entry that names no key for this account.
  # Case-insensitive, as ssh itself matches Host patterns.
  if awk -v h="$host" 'tolower($1) == "host" {
        for (i = 2; i <= NF; i++) if (tolower($i) == tolower(h)) found = 1 }
      END { exit !found }' "$HOME/.ssh/config" 2>/dev/null; then
    c_ok "$n: ssh alias $host is in ~/.ssh/config"
  else
    c_err "$n: ssh_host '$host' has no Host entry in ~/.ssh/config - add 'Host $host' with 'HostName github.com' and 'IdentityFile <$user's key>' (and add that key to $user on GitHub)"; rc=1
  fi
  return "$rc"
}

# Per-registered-workspace audit. Warnings (local-only, uncloned
# repos, missing gate binaries, stale delegations) never fail the pass; only
# c_err findings do. Herdr/ledger checks are guarded behind `have herdr` so
# this runs on a box with no server, and behind the ledger file existing so a
# workspace that has never fanned out is never penalised for it.
# A WORKSPACE WITH WORKERS AND NO CONTAINER TO HOLD THEM. herdr shows a worker
# worktree nested under the `<repo>/workers` workspace it was cut from, and
# closes that container when its last child is released - which detached a
# whole batch of survivors to the sidebar's top level on 2026-09-19 with
# nothing saying so. `release` puts the container straight back; this is what
# notices when something else took it away. herdr is read through the same
# override the fanout tests stub, so this check is testable without a server.
doctor_worker_containers() { # <wsdir>
  local wsdir="$1" r top h ledger
  ledger="$wsdir/.cel/delegations.json"
  h="${CEL_FANOUT_HERDR:-herdr}"
  [ -f "$ledger" ] || return 0
  have "$h" || [ -x "$h" ] || return 0
  for r in $(ws_repo_names "$wsdir"); do
    jq -e --arg r "$r" '[.[] | select(.repo == $r)
      | select(.state != "released") | select((.worktree // "") != "")] | length > 0' \
      "$ledger" >/dev/null 2>&1 || continue
    top="$(git -C "$wsdir/repos/$r" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || continue
    "$h" workspace list 2>/dev/null | jq -e --arg t "$top" \
      '[.result.workspaces[]? | select(.worktree.is_linked_worktree == false)
        | select(.worktree.repo_root == $t)] | length > 0' >/dev/null 2>&1 \
      || c_warn "$r: worker worktrees on the roster but no $r/workers container - they are detached in the sidebar; the next cel-fanout delegate or release recreates it"
  done
  return 0
}

# DOCTOR USED TO JUDGE A WORKSPACE WITHOUT READING IT. Every `setup:` check ran
# in a bare login shell, so a step like `test -n "$WIDGET_KEY"` failed on a box
# that was configured correctly: the value lives in the workspace's gitignored
# env.local, and nothing had sourced it. A newcomer saw red lines against work
# they had just done properly and learned that the tool cannot be trusted -
# the worst possible lesson on day one, and the hardest to unlearn.
#
# The env is loaded the way the rest of the tree loads it (ws_env_exports),
# inside a subshell, so one workspace's values cannot reach the next workspace
# or leak back into doctor itself.
#
# A MISSING VALUE AND AN UNREADABLE ENV ARE DIFFERENT FINDINGS. Reporting the
# second as the first sends somebody off to add a key they already added.
doctor_setup_step_status() { # <wsdir> <check> -> ok | unmet | unreadable
  local wsdir="$1" check="$2" exports
  exports="$(ws_env_exports "$wsdir" 2>/dev/null)" || { printf 'unreadable'; return 0; }
  # Loadable at all? env.local is SOURCED, so an unreadable file or a syntax
  # error in it aborts under `set -e` - which is the distinction we need.
  if ! ( set -e; eval "$exports" ) >/dev/null 2>&1; then printf 'unreadable'; return 0; fi
  # bash -l so a check that looks for a BINARY still sees the login-shell PATH;
  # the workspace's exports are inherited through the environment.
  if ( eval "$exports" >/dev/null 2>&1; bash -lc "$check" ) >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'unmet'
  fi
}

# Zero or more warning lines for one workspace's declared human setup steps.
# Warn only: the walkthrough is /celestial:setup's job, doctor just surfaces
# the drift.
doctor_setup_lines() { # <wsdir> <name>
  local wsdir="$1" n="$2" s_name s_check
  [ -f "$wsdir/workspace.yaml" ] || return 0
  while IFS=$'\t' read -r s_name s_check; do
    [ -n "$s_name" ] && [ -n "$s_check" ] || continue
    case "$(doctor_setup_step_status "$wsdir" "$s_check")" in
      ok) ;;
      unreadable)
        printf "%s: setup step '%s' NOT CHECKED - this workspace's env could not be read (%s/env.local is unreadable or does not parse), so the step may well be done; fix that file and re-run\n" "$n" "$s_name" "$wsdir" ;;
      *)
        printf "%s: setup step '%s' unmet - the value it checks is missing; it belongs in %s/env.local (/celestial:setup walks through it)\n" "$n" "$s_name" "$wsdir" ;;
    esac
  done < <(yq -r '.setup[]? | [.name, .check] | @tsv' "$wsdir/workspace.yaml" 2>/dev/null)
  return 0
}

check_workspaces() {
  local fail=0 n path remote r url gate first role rt bin_
  local ledger agents id pane

  # Every managed worktree belongs to herdr. A worker-created one here is drift
  # from the same bug class check_roles_and_runtimes guards at the box level.
  if [ -d "$HOME/.omp/wt" ] && [ -n "$(ls -A "$HOME/.omp/wt" 2>/dev/null)" ]; then
    c_err "worker-created worktrees found under ~/.omp/wt (worktrees must belong to herdr)"
    fail=1
  fi

  for n in $(registry_names); do
    c_hd "Workspace: $n"
    path="$(registry_path "$n")"
    if [ -z "$path" ] || [ ! -d "$path" ]; then
      c_err "$n: registered path missing: ${path:-<empty>}"
      fail=1
      continue
    fi
    if ! yq . "$path/workspace.yaml" >/dev/null 2>&1; then
      c_err "$n: workspace.yaml does not parse"
      fail=1
      continue
    fi

    remote="$(registry_remote "$n")"
    [ -n "$remote" ] || c_warn "$n is local-only (cel ws push $n to publish)"

    # A MAILBOX WITH NO READER IS A FAULT, NOT SILENCE. `root` survived the
    # retirement of standing root agents as a name - the top, whoever is
    # listening - and a console that is not running listens to nothing.
    local mailline; mailline="$(fleet_mail_doctor_line "$n" 2>/dev/null || true)"
    [ -z "$mailline" ] || c_warn "${mailline#  }"

    doctor_github_account "$n" "$path" || fail=1

    for r in $(ws_repo_names "$path"); do
      url="$(ws_repo_get "$path" "$r" url)"
      [ -z "$url" ] || [ -d "$path/repos/$r/.git" ] \
        || c_warn "$n/$r: not cloned - run cel ws sync"
      # ...and if it IS cloned, whether what it holds is current. A reviewer
      # or a benchmark reading a stale checkout answers about the wrong tree.
      local behind
      behind="$(doctor_checkout_behind_line "$path/repos/$r" "$n/$r" 2>/dev/null || true)"
      [ -z "$behind" ] || c_warn "$behind"
      gate="$(ws_repo_get "$path" "$r" gate)"
      if [ -z "$gate" ] || [ "$gate" = null ]; then
        # Without a gate the only verification is a reviewer's prose, and
        # `cel-fanout land` has nothing to refuse on. Said every doctor run
        # until someone declares one.
        c_warn "$n/$r: no test gate declared - verification here is prose; set repos[].gate to a command that fails when the code is wrong"
      elif [ -n "$gate" ]; then
        first="${gate%% *}"
        have "$first" || c_warn "$n/$r: gate command '$first' not on PATH (repo-local bins are invisible here)"
      fi
    done

    if grep -qxF 'repos/' "$path/.gitignore" 2>/dev/null \
      && grep -qxF 'spikes/' "$path/.gitignore" 2>/dev/null \
      && grep -qxF '.cel/' "$path/.gitignore" 2>/dev/null; then
      :
    else
      c_err "$n: .gitignore must contain repos/, spikes/ and .cel/"
      fail=1
    fi

    for r in "$path"/repos/*/.claude/skills/*; do
      [ -L "$r" ] || continue
      [ -e "$r" ] && continue
      c_err "$n: dangling skill symlink: $r"
      fail=1
    done

    # A declared layout needs the workspace-manager CLI (shipped inside the
    # plugin, not on PATH by default) and the layout id to exist in the
    # plane's config - a typo here otherwise only surfaces mid `cel run root`.
    local layout_; layout_="$(ws_layout "$path")"
    if [ -n "$layout_" ]; then
      if ! _run_wsm_bin >/dev/null 2>&1; then
        c_warn "$n: layout '$layout_' declared but herdr-workspace-manager CLI not found"
      elif ! _run_layout_config "$path" "$layout_" >/dev/null; then
        c_err "$n: layout '$layout_' not defined in $path/layouts.yml or tools/herdr/layouts/config.yml"
        fail=1
      fi
    fi

    # Declared human setup steps (workspace.yaml `setup:` - tokens, logins),
    # each judged with that workspace's own env loaded. See doctor_setup_lines.
    local setupline
    while IFS= read -r setupline; do
      [ -z "$setupline" ] || c_warn "$setupline"
    done < <(doctor_setup_lines "$path" "$n")

    for role in root orchestrator worker; do
      rt="$(ws_runtime "$path" "$role")"
      bin_="$(agent_get "$rt" bin)"
      if [ -z "$bin_" ] || ! have "$bin_"; then
        c_err "$n: runtime $role='$rt' has no installed agent bin"
        fail=1
      fi
    done

    ledger="$path/.cel/delegations.json"
    if [ -f "$ledger" ] && have herdr; then
      agents="$(herdr agent list 2>/dev/null)" || agents=""
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        pane="$(jq -r --arg id "$id" '.[] | select(.id == $id) | .pane' "$ledger")"
        if [ -z "$agents" ] || ! printf '%s' "$agents" \
          | jq -e --arg p "$pane" '.result.agents[]? | select(.pane_id == $p)' >/dev/null 2>&1; then
          c_warn "stale delegation $id - cel-fanout status"
        fi
      done < <(jq -r '.[] | select(.state == "running") | .id' "$ledger" 2>/dev/null)
    fi
    doctor_worker_containers "$path"
  done

  return "$fail"
}

check_externals() {
  local base="$CEL_ROOT/externals.yaml"
  c_hd "Externals"
  [ -f "$base" ] || { c_warn "no externals.yaml"; return 0; }
  if externals_conflicts "$base"; then
    c_ok "$(externals_merge "$base" | wc -l) externals declared, no source/ref conflicts"
    return 0
  fi
  c_err "externals source/ref conflict"
  return 1
}

# The console is ink, so it has node_modules - and a box where `cel setup` ran
# before this ticket landed has a perfectly healthy plane and no console. That
# is a WARNING, not a failure: nothing else on the box depends on it, and a red
# doctor for an optional UI teaches people to ignore a red doctor.
check_console_deps() {
  local d; d="$(console_tool_dir)"
  c_hd "Console"
  if console_deps_ok "$d"; then
    c_ok "console UI deps installed (ink)"
  else
    c_warn "$(console_deps_hint "$d")"
  fi
  # WHETHER THE BOX CAN SEE WHAT ITS PANES ARE DOING (CEL-42), and which model
  # answers. Never a failure: liveness is an addition to the stall timers, and
  # a box without it watches its workers exactly as it always did.
  c_ok "$(liveness_doctor_line)"
  return 0
}

# A LEAKED SUITE LOCK IS A BOX-WIDE OUTAGE AND NOTHING ELSE SAYS SO. On
# 2026-09-19 every gate on this box queued behind the suite lock for eighteen
# minutes; the holder was a `sleep 1800` with ppid 1 that had inherited the
# runner's lock descriptor and kept the lock alive after the runner was gone.
# The lock is fixed at the source (tests/run.sh and cel-verify now spawn every
# child with the descriptor closed), but a lock is held by whatever holds it,
# and an operator staring at a queue needs to be told which of the two it is.
# Held by a live suite is normal and silent; held while the pid in the file is
# gone, or is running somewhere that is not a checkout, is a leak - a suite
# runs from inside a checkout, a stray `sleep` does not.
#
# The path is resolved the same way tests/run.sh resolves it; doctor takes no
# lock of its own, it only asks whether one can be taken.
_doctor_suite_lock_path() {
  if [ -n "${CEL_SUITE_LOCK:-}" ]; then printf '%s' "$CEL_SUITE_LOCK"; return 0; fi
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
    printf '%s/cel-suite.lock' "$XDG_RUNTIME_DIR"; return 0
  fi
  printf '%s/cel-suite-%s.lock' "${TMPDIR:-/tmp}" "${UID:-0}"
}

doctor_suite_lock_line() { # -> one line when the box's suite lock has leaked
  local path pid cwd cmd
  path="$(_doctor_suite_lock_path)"
  [ "$path" = none ] && return 0
  [ -f "$path" ] || return 0
  have flock || return 0
  # Nobody is holding it: there is nothing to report, stale contents or not.
  flock -n "$path" -c true >/dev/null 2>&1 && return 0
  pid="$(sed -n 1p "$path" 2>/dev/null | awk '{print $1}' || true)"
  case "$pid" in ''|*[!0-9]*) printf 'suite lock held with no holder recorded (%s) - kill it or run cel gc --orphans\n' "$path"; return 0;; esac
  if kill -0 "$pid" 2>/dev/null; then
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    # A checkout is where a suite runs from. Anything else holding this lock
    # inherited it rather than took it.
    [ -n "$cwd" ] && [ -e "$cwd/.git" ] && return 0
  fi
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-40)"
  [ -n "$cmd" ] || cmd="gone"
  printf 'suite lock leaked (pid %s, %s) - kill it or run cel gc --orphans\n' "$pid" "${cmd% }"
}

# AWAY FROM KEYBOARD, AND FOR HOW MUCH LONGER. An AFK mode that stays on
# because nobody turned it off is how a fortnight of unattended merges happens,
# so the one state doctor must never leave unsaid is "on, past the hour you
# gave it". Silent when AFK was never armed: a permanent "AFK off" row is a row
# that teaches an operator to stop reading the section.
doctor_afk_line() { # -> one line about AFK, or nothing
  # shellcheck source=lib/afk.sh
  . "$CEL_ROOT/lib/afk.sh"
  local s; s="$(afk_state_json)"
  [ "$(printf '%s' "$s" | jq -r '.on')" = true ] || return 0
  local until_t; until_t="$(printf '%s' "$s" | jq -r '(.until // "") | if . == "" then "no declared hour" else . end')"
  if [ "$(printf '%s' "$s" | jq -r '.expired')" = true ]; then
    printf 'AFK expired at %s and is still on - the factory reads it as off, so nothing is acting, but say so: cel afk off\n' "$until_t"
    return 0
  fi
  printf 'AFK on until %s%s - the factory may land, rebase, dispatch and resolve bot threads on its own (cel afk log)\n' \
    "$until_t" "$(printf '%s' "$s" | jq -r 'if (.reason // "") == "" then "" else " (" + .reason + ")" end')"
}

cmd_doctor() {
  local fail=0
  c_hd "celestial"
  # shellcheck source=lib/version.sh
  . "$CEL_ROOT/lib/version.sh"
  # shellcheck source=lib/config.sh
  . "$CEL_ROOT/lib/config.sh"
  local _v _latest _chan _n
  _v="$(cel_version)"; _latest="$(cel_latest_remote_version)"
  if [ -n "$_latest" ] && cel_version_lt "$_v" "$_latest"; then
    c_warn "v$_v installed, v$_latest available - run: cel update"
  else
    c_ok "v$_v$([ -z "$_latest" ] && printf ' (offline - update check skipped)')"
  fi
  # The version alone hid the distance: a box on the main channel is thirty-odd
  # merges past its tag and every surface used to call that "up to date".
  _chan="$(cel_config_get update channel)"
  case "$_chan" in main) ;; *) _chan=release ;; esac
  if [ "$_chan" = main ]; then
    _n="$(cel_commits_behind_main)"
    if [ "$_n" -gt 0 ] 2>/dev/null; then
      c_warn "build v$(cel_build_version) ($(cel_build_sha)) · channel main · $_n commits behind origin/main"
    else
      c_ok "build v$(cel_build_version) ($(cel_build_sha)) · channel main · up to date"
    fi
  else
    c_ok "build v$(cel_build_version) ($(cel_build_sha)) · release channel: newest tag v${_latest:-unknown}"
  fi

  c_hd "Base tools"
  for b in git jq yq gh node herdr cargo bun lazygit; do
    have "$b" && c_ok "$b $($b --version 2>/dev/null | head -1 | cut -c1-40)" || { c_err "$b MISSING"; fail=1; }
  done
  yq_ok || { c_err "yq is the Go build - scripts need the Python one (jq syntax)"; fail=1; }

  c_hd "Agents"
  for a in $(agent_names); do
    local bin; bin="$(agent_get "$a" bin)"
    if have "$bin"; then c_ok "$a ($($bin --version 2>/dev/null | head -1 | cut -c1-30))"
    elif [ "$(agent_get "$a" required)" = "true" ]; then c_err "$a MISSING (required)"; fail=1
    else c_warn "$a not installed (optional)"; fi
    # Declared but unloaded extensions are a silent capability gap - pi
    # without its auth extension cannot reach a Claude subscription, and looks
    # identical to pi that can until a worker fails to start.
    local missing; missing="$(extensions_missing "$a" 2>/dev/null || true)"
    if [ -n "$missing" ]; then
      c_warn "$a extensions not loaded: $(printf '%s' "$missing" | tr '\n' ' ')- run: cel setup --agents $a"
    fi
  done

  c_hd "Authentication"
  if have gh; then
    gh auth status >/dev/null 2>&1 && c_ok "gh authenticated" || { c_err "gh NOT authenticated - run: gh auth login"; fail=1; }
  fi
  if have claude; then
    if claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then c_ok "claude authenticated"
    else c_err "claude NOT logged in - run: claude setup-token"; fail=1; fi
  fi

  c_hd "Login-shell PATH"
  # The bug class that cost us hours: tools resolve in the current shell but not
  # in a fresh login shell, because a dotfile replaces PATH instead of appending.
  local sh_missing=""
  for b in $(for a in $(agent_names); do agent_get "$a" bin; done) herdr node; do
    have "$b" || continue
    "$SHELL" -l -c "command -v $b" >/dev/null 2>&1 || sh_missing="$sh_missing $b"
  done
  if [ -n "$sh_missing" ]; then
    c_err "present now but NOT in a login shell:$sh_missing"
    echo "      a dotfile is replacing PATH rather than appending. Add: eval \"\$(cel shellenv)\""
    fail=1
  else c_ok "all tools resolve in a login shell"; fi

  c_hd "herdr"
  if have herdr; then
    local cv sv
    # `|| true`: herdr status exits non-zero while the server reloads plugins,
    # and under set -e a failing substitution would kill doctor with no message
    # (seen live during the Task 9 cut-over, exit 101).
    cv="$(herdr status 2>/dev/null | awk '/^client:/{f=1} f&&/version:/{print $2; exit}' || true)"
    sv="$(herdr status 2>/dev/null | awk '/^server:/{f=1} f&&/version:/{print $2; exit}' || true)"
    if [ -n "$sv" ] && [ "$cv" != "$sv" ]; then
      c_err "herdr client $cv != server $sv - a --remote attach can downgrade one side"; fail=1
    else c_ok "herdr $cv"; fi
  fi

  c_hd "Registry"
  if [ -f "$CEL_ROOT/registry.yaml" ] && [ -f "$CEL_REGISTRY" ] && [ "$CEL_REGISTRY" != "$CEL_ROOT/registry.yaml" ]; then
    # migration deliberately refuses to overwrite an existing new-location file
    c_err "two registries: $CEL_ROOT/registry.yaml is IGNORED - merge it into $CEL_REGISTRY and delete it"
    fail=1
  elif [ -f "$CEL_REGISTRY" ]; then
    c_ok "registry: $CEL_REGISTRY"
  else
    c_warn "no registry yet ($CEL_REGISTRY) - created on first cel ws new/add"
  fi

  check_console_deps || fail=1
  # One line, never a failure: most boxes have no gateway, and a red doctor
  # for an optional door teaches people to ignore a red doctor.
  c_hd "Gateway"
  gateway_doctor_line
  doctor_box_services_line
  check_roles_and_runtimes || fail=1
  check_workspaces || fail=1
  check_externals || fail=1

  # A GC that can identify nothing is invisible otherwise: it prints the same
  # summary as one with nothing to do. This is the last sweep's reading, not a
  # sweep of its own - doctor must not take the registry lock to run.
  local gcline; gcline="$(gc_doctor_line)"
  [ -z "$gcline" ] || c_warn "$gcline"

  # One line, and only when the box-wide suite lock is held by something that
  # is not running tests - which blocks every gate on the box until it dies.
  local lockline; lockline="$(doctor_suite_lock_line)"
  [ -z "$lockline" ] || c_warn "$lockline"

  # And the processes with no owner at all. A warning, never a failure: they
  # cost memory, not correctness, and the cure is one command - which is why
  # the line names it rather than describing the problem.
  local orphline; orphline="$(orphans_doctor_line)"
  [ -z "$orphline" ] || c_warn "$orphline"

  # Who is deciding right now. An operator who thinks they are driving must not
  # be surprised by an agent acting, and one returning must not have to ask.
  local afkline; afkline="$(doctor_afk_line)"
  if [ -n "$afkline" ]; then
    case "$afkline" in *expired*) c_warn "$afkline" ;; *) c_ok "$afkline" ;; esac
  fi

  # AND THE FLOOR SPACE. The factory measured its machines and never the box
  # they stand on, so the first symptom of a full disk was a build failing.
  # A warning rather than a failure, and it names the largest reclaimable
  # class and the command that clears it: 144G of 193G was diagnosable for
  # months and nothing anywhere diagnosed it.
  local boxline; boxline="$(box_doctor_line)"
  [ -z "$boxline" ] || c_warn "$boxline"

  # A LIVE AGENT WITH NO HERDR NAME. Not a failure - the agent is working -
  # but it is invisible to everything that resolves an orchestrator by its
  # alias, so `cel fleet` reads its product as dead and the next act is a
  # second orchestrator on top of it. One line, and the cure is in it.
  local wsline
  while IFS= read -r wsline; do
    [ -z "$wsline" ] || c_warn "$wsline"
  done < <(wslife_doctor_lines 2>/dev/null || true)

  echo
  [ "$fail" = 0 ] && printf '\033[32mdoctor: OK\033[0m\n' || printf '\033[31mdoctor: problems found\033[0m\n'
  return "$fail"
}
