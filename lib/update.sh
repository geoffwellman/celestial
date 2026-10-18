# shellcheck shell=bash
# `cel update` - the one command that rewrites the plane under a running box.
#
# Two audiences share one checkout layout and must not destroy each other's
# work: the plane's developer moves with git by hand, everyone else moves with
# this command. So update refuses outright to touch a tree that is dirty or
# off `main`, lands on the newest RELEASE TAG rather than main's tip (main is
# where the developer is working and is not a build anyone else should run),
# records where it came from so `--rollback` is real, re-applies everything
# installation touched, and finally runs doctor - an update that leaves the
# box red must say so, with the way back, rather than exit 0.
[ -n "${_CEL_UPDATE:-}" ] && return 0
_CEL_UPDATE=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/version.sh
. "${BASH_SOURCE[0]%/*}/version.sh"
# shellcheck source=lib/config.sh
. "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/link.sh
. "${BASH_SOURCE[0]%/*}/link.sh"
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"
# shellcheck source=lib/run.sh
. "${BASH_SOURCE[0]%/*}/run.sh"
# shellcheck source=lib/install.sh
. "${BASH_SOURCE[0]%/*}/install.sh"   # extension_names
# shellcheck source=lib/gateway.sh
. "${BASH_SOURCE[0]%/*}/gateway.sh"   # gateway_refresh

_update_dir() { printf '%s' "${CEL_UPDATE_DIR:-$HOME/.local/share/cel/update}"; }

# WHICH STREAM THIS BOX FOLLOWS. Everything that said "you are behind" -
# --check, the steward's daily check, the dashboard chip, doctor - compared
# the installed version to the newest release TAG, so a box tracking main sat
# thirty-odd merges past v0.2.0 and every surface said "up to date". A box on
# the `main` channel is told about COMMITS; a box on `release` keeps today's
# behaviour, which is the default because releases are what users should run.
_update_channel() {
  local c
  c="$(cel_config_get update channel)"
  case "$c" in main) printf 'main' ;; *) printf 'release' ;; esac
}

_update_set_channel() { # <main|release>
  case "$1" in
    main | release) ;;
    *) die "cel update --channel: unknown channel '$1' (want main or release)" ;;
  esac
  cel_config_set update channel "$1"
  c_ok "update channel: $1 ($(cel_config_file))"
  return 0
}

# Both channels open with the same two lines, because "what am I running" is
# the question every one of these surfaces was silently answering wrong.
_update_header() { # <newest-tag-or-empty>
  printf '  installed  v%s  %s  (%s)\n' "$(cel_build_version)" "$(cel_build_sha)" "$(cel_build_branch)"
  if [ -n "${1:-}" ]; then
    printf '  newest tag v%s\n' "$1"
  else
    printf '  newest tag none reachable\n'
  fi
}

# The `[Unreleased]` notes that exist on origin/main and not here: commit
# subjects say what was done, this says what it means for the person reading.
_update_unreleased_diff() {
  local here there
  here="$(_update_unreleased_section HEAD)"
  there="$(_update_unreleased_section origin/main)"
  [ -n "$there" ] || return 0
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$here" in *"$line"*) continue ;; esac
    printf '%s\n' "$line"
  done <<<"$there"
  return 0
}

_update_unreleased_section() { # <rev>
  git -C "$CEL_ROOT" show "$1:CHANGELOG.md" 2>/dev/null \
    | awk 'index($0, "## [Unreleased]") == 1 { p = 1; next } p && /^## \[/ { exit } p { print }' || true
}

# Read-only checks are allowed on any tree; anything that moves HEAD is not.
_update_require_pristine() {
  local branch
  if [ -n "$(git -C "$CEL_ROOT" status --porcelain 2>/dev/null)" ]; then
    die "the plane has uncommitted changes - cel update will not touch them (the plane's developer moves with git; users move with cel update)"
  fi
  branch="$(git -C "$CEL_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$branch" != main ]; then
    die "the plane is on branch '$branch', not main - cel update will not touch it (the plane's developer moves with git; users move with cel update)"
  fi
  return 0
}

# Only what you have NOT got yet. The installed version's own section is
# history, and printing it makes the notice look like noise.
_update_changelog_since() { # <installed> <available>
  local inst="$1" avail="$2" f="$CEL_ROOT/CHANGELOG.md" v
  if [ ! -f "$f" ]; then return 0; fi
  while read -r v; do
    [ -n "$v" ] || continue
    cel_version_lt "$inst" "$v" || continue
    if cel_version_lt "$avail" "$v"; then continue; fi
    awk -v want="## [$v]" '
      index($0, want) == 1 { p = 1; print; next }
      p && /^## \[/ { exit }
      p { print }' "$f"
  done < <(grep -o '^## \[[0-9][^]]*\]' "$f" | sed 's/^## \[//; s/\]$//')
}

# Everything the installation touched, in one place: the symlink layer and the
# claude settings merge (link_all -> link_claude_prefs registers the hook block
# in ~/.claude/settings.json), every workspace's scoped links, and the box
# services whose running processes still carry the old code. An old steward
# timer is rewritten by the doctor run in _update_verify (lib/steward_timer.sh).
_update_reapply() {
  c_hd "Re-applying"
  link_all
  local ws
  for ws in $(registry_names 2>/dev/null); do
    "$CEL_ROOT/bin/cel" ws sync "$ws" || c_warn "ws sync $ws failed"
  done
  # One dashboard for the box (CEL-107); its restart also stops any server a
  # workspace still runs from before, so the old ports can redirect.
  "$CEL_ROOT/bin/cel" dash --restart || c_warn "dash did not restart"
  "$CEL_ROOT/bin/cel" pages --restart || c_warn "pages did not restart"
  "$CEL_ROOT/bin/cel" pages --public --restart || c_warn "public pages did not restart"
}

# --- agents and gateway (AH-261018) ---------------------------------------
# `cel update` used to stop at "Celestial is current" and never touched the
# coding agents it launches, so a box could sit on stale claude/omp/pi/codex
# for weeks while every surface said "up to date". The components below run on
# EVERY update, whether or not the plane's own git moved, each through the
# agent's OWN installer (agents.yaml `update:`), and report what actually
# happened per component: old version, new version, and - because an updater
# that exits 0 can still leave an agent behind - the published latest. A
# failed or still-behind component is a non-success exit with the way forward;
# the command is idempotent, so the way forward is "fix the cause, rerun".
# No live session is signalled or restarted by any of it.

_update_semver() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }

_update_agent_version() { # <agent> -> X.Y.Z, or fails when not installed/readable
  local bin cmd out
  bin="$(agent_get "$1" bin)"
  [ -n "$bin" ] && have "$bin" || return 1
  cmd="$(agent_get "$1" version_cmd)"; [ -n "$cmd" ] || cmd="$bin --version"
  out="$(bash -c "$cmd" 2>/dev/null)" || return 1
  out="$(printf '%s' "$out" | _update_semver)"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# The latest STABLE published version, or empty when none is declared or the
# lookup failed (never treated as "current" - the line says "latest unknown").
_update_agent_latest() { # <agent>
  local c out
  c="$(agent_update_get "$1" latest)"
  [ -n "$c" ] || return 0
  out="$(_update_timeout 60 bash -c "$c" 2>/dev/null)" || return 0
  printf '%s' "$out" | _update_semver
}

_update_timeout() { # <secs> <cmd...>
  local secs="$1"; shift
  if have timeout; then timeout "$secs" "$@"; else "$@"; fi
}

# A pin by name: `update.hold` in the box config (comma or space separated) or
# CEL_UPDATE_HOLD. Reported, never silently called current.
_update_held() { # <agent>
  local h; h="$(cel_config_get update hold) ${CEL_UPDATE_HOLD:-}"; h="${h//,/ }"
  case " $h " in *" $1 "*) return 0 ;; esac
  return 1
}

_update_agents_check() { # read-only: installed vs latest per installed agent; 1 when any is behind
  local a inst latest rc=0 shown=0
  for a in $(agent_names); do
    [ -n "$(agent_update_get "$a" command)" ] || continue
    inst="$(_update_agent_version "$a")" || continue
    [ "$shown" -eq 1 ] || { c_hd "Agents"; shown=1; }
    latest="$(_update_agent_latest "$a")"
    if [ -z "$latest" ]; then
      printf '  %s %s (latest unknown)\n' "$a" "$inst"
    elif cel_version_lt "$inst" "$latest"; then
      printf '  %s %s (latest %s)\n' "$a" "$inst" "$latest"; rc=1
    else
      printf '  %s %s (current)\n' "$a" "$inst"
    fi
  done
  return "$rc"
}

_update_agents() { # returns 1 when any component failed or is still behind
  local a bin cmd old new latest out rc=0 shown=0 changed='{}' prev_file held="" f
  prev_file="$(_update_dir)/agents-previous.json"
  c_hd "Agents"
  for a in $(agent_names); do
    cmd="$(agent_update_get "$a" command)"
    [ -n "$cmd" ] || continue
    bin="$(agent_get "$a" bin)"
    if ! have "$bin"; then
      printf '  %s not installed - cel setup installs it\n' "$a"; continue
    fi
    shown=1
    old="$(_update_agent_version "$a")" || old="?"
    if _update_held "$a"; then
      printf '  %s %s held (update.hold) - not updated\n' "$a" "$old"
      held="$held $a"; continue
    fi
    if ! out="$(_update_timeout "${CEL_UPDATE_AGENT_TIMEOUT:-900}" bash -e -u -o pipefail -c "$cmd" 2>&1)"; then
      c_err "$a $old: update FAILED - $(printf '%s' "$out" | tail -1 | cut -c1-160)"
      rc=1; continue
    fi
    new="$(_update_agent_version "$a")" || new="?"
    if [ "$new" = "?" ]; then
      c_err "$a: the updater succeeded but the installed version cannot be read ($bin --version)"; rc=1; continue
    fi
    latest="$(_update_agent_latest "$a")"
    if [ -n "$latest" ] && cel_version_lt "$new" "$latest"; then
      c_err "$a still $new after its updater ran, latest $latest - NOT current (an updater that exits 0 is not proof)"
      rc=1
    elif [ "$old" != "$new" ]; then
      printf '  %s %s -> %s%s\n' "$a" "$old" "$new" "${latest:+ (latest $latest)}"
      changed="$(jq -c --arg a "$a" --arg v "$old" '.[$a] = $v' <<<"$changed")"
    else
      if [ -n "$latest" ]; then printf '  %s %s (current)\n' "$a" "$new"
      else printf '  %s %s (updater reports nothing newer; published latest unknown)\n' "$a" "$new"; fi
    fi
  done
  [ "$shown" -eq 1 ] || printf '  no coding agent with an update command is installed\n'
  # What to go back to: only versions that CHANGED are recorded, merged over
  # the previous record, so a no-op rerun never erases the way back.
  if [ "$changed" != '{}' ]; then
    mkdir -p "$(_update_dir)"
    if [ -s "$prev_file" ]; then jq -c --argjson c "$changed" '. + $c' "$prev_file" >"$prev_file.tmp" && mv "$prev_file.tmp" "$prev_file"
    else printf '%s\n' "$changed" >"$prev_file"; fi
  fi
  # Pins are reported by name, never folded into "current".
  f="$(agent_get pi extensions_file)"
  if [ -n "$held" ] || { have pi && [ -n "$f" ] && [ -s "$CEL_ROOT/$f" ]; }; then
    c_hd "Pinned exceptions"
    for a in $held; do printf '  %s held by update.hold - remove it from the box config to update\n' "$a"; done
    if have pi && [ -n "$f" ] && [ -s "$CEL_ROOT/$f" ]; then
      printf '  pi extensions pinned by %s (%s) - not updated here; bump the pin in the repo\n' \
        "$f" "$(extension_names pi 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
    fi
  fi
  return "$rc"
}

# Restore what an update changed, where the agent DECLARES a way (agents.yaml
# update.rollback); one that does not is named with its old version, never
# guessed at. Entries are dropped as they succeed, so a rerun resumes.
_update_agents_rollback() {
  local f a old cmd now rc=0 left
  f="$(_update_dir)/agents-previous.json"
  [ -s "$f" ] || return 0
  c_hd "Rolling agents back"
  left="$(cat "$f")"
  for a in $(jq -r 'keys[]' "$f"); do
    old="$(jq -r --arg a "$a" '.[$a]' "$f")"
    cmd="$(agent_update_get "$a" rollback)"
    if [ -z "$cmd" ]; then
      printf '  %s was %s - no declared rollback; reinstall it with its own installer\n' "$a" "$old"; continue
    fi
    if CEL_OLD_VERSION="$old" _update_timeout "${CEL_UPDATE_AGENT_TIMEOUT:-900}" bash -e -u -o pipefail -c "$cmd" >/dev/null 2>&1 \
        && now="$(_update_agent_version "$a")" && [ "$now" = "$old" ]; then
      printf '  %s -> %s\n' "$a" "$old"
      left="$(jq -c --arg a "$a" 'del(.[$a])' <<<"$left")"
    else
      c_err "$a: rollback to $old FAILED - rerun cel update --rollback"; rc=1
    fi
  done
  printf '%s\n' "$left" >"$f"
  return "$rc"
}

# Everything the update owns beyond Celestial's own git. Never short-circuited
# by "already current".
_update_components() {
  local rc=0
  _update_agents || rc=1
  c_hd "Gateway"
  if ! gateway_refresh; then
    c_err "gateway registration refresh FAILED - cel gateway status, then rerun cel update"
    rc=1
  fi
  return "$rc"
}

# A running omp/pi launched before the gateway launch environment existed has
# no gateway client key or session identity, and a process environment is
# fixed at exec: nothing here can hand it one. Reported with the supported
# recovery - the native session resume `cel run <role> --restart` performs
# when the session is idle - and never acted on.
_update_stale_gateway_env() {
  gateway_installed || return 0
  local pid comm env_ has_role has_tok item shown=0 cwd
  for pid in $(pgrep -u "$(id -u)" -x 'omp|pi' 2>/dev/null); do
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || continue
    has_role=0; has_tok=0
    while IFS= read -r -d '' item; do
      case "$item" in CEL_ROLE=*) has_role=1 ;; OMP_GATEWAY_TOKEN=*) has_tok=1 ;; esac
    done < <({ cat "/proc/$pid/environ"; } 2>/dev/null)
    [ "$has_role" -eq 1 ] && [ "$has_tok" -eq 0 ] || continue
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || printf '?')"
    if [ "$shown" -eq 0 ]; then c_hd "Sessions launched without the gateway environment"; shown=1; fi
    printf '  %s (pid %s) %s\n' "$comm" "$pid" "$cwd"
  done
  [ "$shown" -eq 0 ] || printf '  their environment is fixed at launch: the new gateway key/session cannot reach them. Nothing was restarted; when one is idle, `cel run <role> --restart` resumes its own native session with the new launch.\n'
  return 0
}

_update_finish() { # <components-rc> -> the exit code of the whole update
  if [ "$1" -ne 0 ]; then
    c_err "update incomplete: a component above did not complete. cel update is idempotent - fix the cause and rerun it, or cel update --rollback"
    return 1
  fi
  return 0
}

_update_verify() {
  c_hd "Verifying"
  "$CEL_ROOT/bin/cel" doctor
}

# An agent that was already running keeps the previous build's role prompt and
# guard hook in memory - the CLI it shells out to is new, the prompt it is
# obeying is not. Same recognition lib/gc.sh uses to avoid reaping them.
_update_stale_agents() {
  local out line pid cmd role cwd shown=0
  out="$(pgrep -af 'role-[a-z-]+\.md' 2>/dev/null)" || return 0
  if [ -z "$out" ]; then return 0; fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid="${line%% *}"
    cmd="${line#* }"
    role="$(printf '%s' "$cmd" | grep -oE 'role-[a-z-]+\.md' | head -1)"
    role="${role#role-}"; role="${role%.md}"
    [ -n "$role" ] || continue
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || printf '?')"
    if [ "$shown" -eq 0 ]; then c_hd "Agents still on the previous build"; shown=1; fi
    printf '  %-8s %s (pid %s)\n' "$role" "$cwd" "$pid"
  done <<<"$out"
  if [ "$shown" -eq 1 ]; then printf '  they run the new CLI on their next command; their role prompt and guard hook are from the previous build - restart when convenient.\n'; fi
  return 0
}

# Root and orchestrators on an older launch line (lib/run.sh). Report-only by
# default: an automatic restart could drop a draft in the owner's composer,
# which the plane cannot see. With 1, idle ones are restarted in place and
# resumed; working ones are skipped with the reason.
_update_stale_orchestrators() { # <restart 0|1>
  local rows name ws pane status since model launch detail cmd role product shown=0
  rows="$(run_orchestrator_rows)"
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r name ws pane status since model launch detail cmd role product; do
    [ -n "$name" ] || continue
    case "$launch" in stale|unknown) ;; *) continue ;; esac
    if [ "$shown" -eq 0 ]; then c_hd "Orchestrators on an older launch line"; shown=1; fi
    # An orchestrator whose process could not be read is UNKNOWN, with the
    # reason - never "missing everything", which is what CEL-63 said about
    # one that had every flag (CEL-81). It is not restarted on a guess.
    if [ "$launch" = unknown ]; then
      printf '  %s (%s) launch line unknown: %s\n' "$name" "$ws" "$detail"
      continue
    fi
    printf '  %s (%s) runs an older launch line (%s) - %s\n' "$name" "$ws" "$detail" "$cmd"
    [ "$1" -eq 1 ] || continue
    if [ "$status" = working ]; then
      c_warn "$name skipped: it is working - restart it when idle: $cmd"
      continue
    fi
    local -a argv=("$role")
    [ "$product" = "-" ] || argv+=(--product "$product")
    argv+=(--workspace "$ws" --restart)
    ( cmd_run "${argv[@]}" ) || c_warn "$name did not restart - $cmd"
  done <<<"$rows"
  return 0
}

# `--check` shows what `--restart-orchestrators` would act on, too: the owner
# could not see it before running the restart (CEL-81).
_update_check() {
  local rc=0
  _update_check_version || rc=$?
  local out; out="$(_update_stale_orchestrators 0)"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    printf '  cel update --restart-orchestrators restarts the idle stale ones in place.\n'
  fi
  return "$rc"
}

_update_check_version() { # read-only; exit 1 when behind so scripts can test it
  local inst avail chan
  chan="$(_update_channel)"
  git -C "$CEL_ROOT" fetch --tags -q 2>/dev/null || true
  if [ "$chan" = main ]; then git -C "$CEL_ROOT" fetch -q origin main 2>/dev/null || true; fi
  inst="$(cel_version)"
  avail="$(cel_latest_remote_version)"
  _update_header "$avail"

  if [ "$chan" = main ]; then
    local n
    n="$(cel_commits_behind_main)"
    if [ "$n" -gt 0 ] 2>/dev/null; then
      c_warn "main is $n commits ahead:"
      # oldest first: these read as the story of what happened since your
      # build, and newest-first makes that story unreadable
      git -C "$CEL_ROOT" log --reverse --format='  %h %s' HEAD..origin/main 2>/dev/null | sed -n '1,15p'
      local notes
      notes="$(_update_unreleased_diff)"
      if [ -n "$notes" ]; then printf '%s\n' "$notes"; fi
      return 1
    fi
    c_ok "up to date with origin/main"
    return 0
  fi

  if [ -z "$avail" ]; then
    c_warn "no release tags reachable on origin (offline?) - installed v$inst"
    return 0
  fi
  if cel_version_lt "$inst" "$avail"; then
    c_warn "installed v$inst, available v$avail"
    _update_changelog_since "$inst" "$avail"
    return 1
  fi
  c_ok "up to date at v$inst"
  return 0
}

_update_rollback() {
  local prev
  prev="$(tr -d '[:space:]' <"$(_update_dir)/previous" 2>/dev/null)" || true
  if [ -z "$prev" ] && [ ! -s "$(_update_dir)/agents-previous.json" ]; then die "no previous build recorded in $(_update_dir)/previous - nothing to roll back to"; fi
  if [ -n "$prev" ]; then
    _update_require_pristine
    git -C "$CEL_ROOT" reset --hard "$prev" -q || die "could not reset the plane to $prev"
    _update_reapply
    c_ok "rolled back to $(git -C "$CEL_ROOT" rev-parse --short HEAD) (v$(cel_version))"
  fi
  _update_agents_rollback || return 1
  return 0
}

# The components run by the code that was JUST installed when the plane moved:
# the process running this function holds the OLD code, and an update that
# brought a new component list would otherwise only take effect on the next
# run. A child `cel update --components` loads the new lib/.
_update_components_fresh() {
  if [ -x "$CEL_ROOT/bin/cel" ] && [ -z "${CEL_UPDATE_INPROC:-}" ]; then
    "$CEL_ROOT/bin/cel" update --components
  else
    _update_components
  fi
}

cmd_update() { # [--check [--agents] | --rollback | --components | --channel main|release] [--skip-agents] [--restart-orchestrators]
  local mode=update chan="" restart_orch=0 check_agents=0 skip_components=0 crc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)    mode=check; shift ;;
      --agents)   check_agents=1; shift ;;
      --components) mode=components; shift ;;
      --skip-agents) skip_components=1; shift ;;
      --rollback) mode=rollback; shift ;;
      --restart-orchestrators) restart_orch=1; shift ;;
      --channel)  mode=channel; chan="${2:-}"; [ -n "$chan" ] || die "cel update --channel: want main or release"; shift 2 ;;
      *) die "cel update: unknown argument '$1' (want --check [--agents], --components, --skip-agents, --rollback, --channel or --restart-orchestrators)" ;;
    esac
  done
  if [ "$mode" = check ]; then
    local crc=0
    _update_check || crc=$?
    if [ "$check_agents" -eq 1 ]; then _update_agents_check || crc=1; fi
    return "$crc"
  fi
  if [ "$mode" = rollback ]; then _update_rollback; return $?; fi
  if [ "$mode" = channel ]; then _update_set_channel "$chan"; return $?; fi
  if [ "$mode" = components ]; then
    _update_components || crc=$?
    _update_stale_agents
    _update_stale_gateway_env
    _update_finish "$crc"; return $?
  fi

  _update_require_pristine

  # The main channel takes main's TIP: this box asked for what landed
  # yesterday, and the same pristine check, previous-sha record, re-apply,
  # doctor and rollback path carry it.
  if [ "$(_update_channel)" = main ]; then
    git -C "$CEL_ROOT" fetch -q origin main 2>/dev/null || true
    local n before_main
    n="$(cel_commits_behind_main)"
    if [ "$n" -eq 0 ] 2>/dev/null; then
      c_ok "up to date with origin/main at $(cel_build_line)"
      # CURRENT GIT IS NOT A CURRENT BOX: agents and gateway registrations
      # are still brought up to date.
      [ "$skip_components" -eq 1 ] || _update_components || crc=$?
      _update_stale_gateway_env
      _update_stale_orchestrators "$restart_orch"
      _update_finish "$crc"; return $?
    fi
    before_main="$(git -C "$CEL_ROOT" rev-parse HEAD)"
    mkdir -p "$(_update_dir)"
    printf '%s\n' "$before_main" >"$(_update_dir)/previous"
    git -C "$CEL_ROOT" pull --ff-only -q origin main \
      || die "could not fast-forward to origin/main from $before_main - this checkout has diverged from main"
    c_ok "$n commits applied - now $(cel_build_line)"
    _update_reapply
    [ "$skip_components" -eq 1 ] || _update_components_fresh || crc=$?
    if ! _update_verify; then
      c_err "update landed but doctor is red - inspect above, or: cel update --rollback"
      return 1
    fi
    _update_stale_agents
    _update_stale_gateway_env
    _update_stale_orchestrators "$restart_orch"
    _update_finish "$crc"; return $?
  fi

  git -C "$CEL_ROOT" fetch --tags -q 2>/dev/null || true
  local inst avail before
  inst="$(cel_version)"
  avail="$(cel_latest_remote_version)"
  if [ -z "$avail" ]; then die "no release tags reachable on origin - cannot tell what to update to"; fi
  if ! cel_version_lt "$inst" "$avail"; then
    c_ok "Celestial is current at v$inst"
    [ "$skip_components" -eq 1 ] || _update_components || crc=$?
    _update_stale_gateway_env
    _update_stale_orchestrators "$restart_orch"
    _update_finish "$crc"; return $?
  fi

  before="$(git -C "$CEL_ROOT" rev-parse HEAD)"
  mkdir -p "$(_update_dir)"
  printf '%s\n' "$before" >"$(_update_dir)/previous"

  # The TAG, never origin/main: users track releases.
  git -C "$CEL_ROOT" merge --ff-only "v$avail" -q \
    || die "could not fast-forward to v$avail from $before - this checkout has diverged from the releases"
  c_ok "v$inst -> v$avail ($(git -C "$CEL_ROOT" rev-parse --short HEAD))"

  _update_reapply
  [ "$skip_components" -eq 1 ] || _update_components_fresh || crc=$?
  if ! _update_verify; then
    c_err "update landed but doctor is red - inspect above, or: cel update --rollback"
    return 1
  fi
  _update_stale_agents
  _update_stale_gateway_env
  _update_stale_orchestrators "$restart_orch"
  _update_finish "$crc"; return $?
}
