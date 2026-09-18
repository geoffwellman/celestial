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
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/version.sh
. "$(dirname "${BASH_SOURCE[0]}")/version.sh"
# shellcheck source=lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"
# shellcheck source=lib/link.sh
. "$(dirname "${BASH_SOURCE[0]}")/link.sh"
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"

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
# services whose running processes still carry the old code. The steward timer
# needs nothing: its unit execs `cel`.
_update_reapply() {
  c_hd "Re-applying"
  link_all
  local ws port
  for ws in $(registry_names 2>/dev/null); do
    "$CEL_ROOT/bin/cel" ws sync "$ws" || c_warn "ws sync $ws failed"
  done
  for ws in $(registry_names 2>/dev/null); do
    port="$(yq -r '.dash.port // ""' "$(registry_path "$ws")/workspace.yaml" 2>/dev/null)"
    if [ -n "$port" ] && [ "$port" != null ]; then
      "$CEL_ROOT/bin/cel" dash --workspace "$ws" --restart || c_warn "dash $ws did not restart"
    fi
  done
  "$CEL_ROOT/bin/cel" pages --restart || c_warn "pages did not restart"
  "$CEL_ROOT/bin/cel" pages --public --restart || c_warn "public pages did not restart"
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

_update_check() { # read-only; exit 1 when behind so scripts can test it
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
  if [ -z "$prev" ]; then die "no previous build recorded in $(_update_dir)/previous - nothing to roll back to"; fi
  _update_require_pristine
  git -C "$CEL_ROOT" reset --hard "$prev" -q || die "could not reset the plane to $prev"
  _update_reapply
  c_ok "rolled back to $(git -C "$CEL_ROOT" rev-parse --short HEAD) (v$(cel_version))"
  return 0
}

cmd_update() { # [--check | --rollback | --channel main|release]
  local mode=update chan=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)    mode=check; shift ;;
      --rollback) mode=rollback; shift ;;
      --channel)  mode=channel; chan="${2:-}"; [ -n "$chan" ] || die "cel update --channel: want main or release"; shift 2 ;;
      *) die "cel update: unknown argument '$1' (want --check, --rollback or --channel)" ;;
    esac
  done
  if [ "$mode" = check ]; then _update_check; return $?; fi
  if [ "$mode" = rollback ]; then _update_rollback; return $?; fi
  if [ "$mode" = channel ]; then _update_set_channel "$chan"; return $?; fi

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
      return 0
    fi
    before_main="$(git -C "$CEL_ROOT" rev-parse HEAD)"
    mkdir -p "$(_update_dir)"
    printf '%s\n' "$before_main" >"$(_update_dir)/previous"
    git -C "$CEL_ROOT" pull --ff-only -q origin main \
      || die "could not fast-forward to origin/main from $before_main - this checkout has diverged from main"
    c_ok "$n commits applied - now $(cel_build_line)"
    _update_reapply
    if ! _update_verify; then
      c_err "update landed but doctor is red - inspect above, or: cel update --rollback"
      return 1
    fi
    _update_stale_agents
    return 0
  fi

  git -C "$CEL_ROOT" fetch --tags -q 2>/dev/null || true
  local inst avail before
  inst="$(cel_version)"
  avail="$(cel_latest_remote_version)"
  if [ -z "$avail" ]; then die "no release tags reachable on origin - cannot tell what to update to"; fi
  if ! cel_version_lt "$inst" "$avail"; then
    c_ok "up to date at v$inst"
    return 0
  fi

  before="$(git -C "$CEL_ROOT" rev-parse HEAD)"
  mkdir -p "$(_update_dir)"
  printf '%s\n' "$before" >"$(_update_dir)/previous"

  # The TAG, never origin/main: users track releases.
  git -C "$CEL_ROOT" merge --ff-only "v$avail" -q \
    || die "could not fast-forward to v$avail from $before - this checkout has diverged from the releases"
  c_ok "v$inst -> v$avail ($(git -C "$CEL_ROOT" rev-parse --short HEAD))"

  _update_reapply
  if ! _update_verify; then
    c_err "update landed but doctor is red - inspect above, or: cel update --rollback"
    return 1
  fi
  _update_stale_agents
  return 0
}
