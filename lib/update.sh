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

# The way back is recorded THE MOMENT a version moved - success, failure and
# still-behind alike (an updater can move the version and then fail) - and
# durably: merged under a lock, written to a unique temp file and renamed, so a
# kill mid-write leaves the previous record intact, never a torn file.
_update_record_previous() { # <agent> <old version>
  local a="$1" old="$2" f tmp
  f="$(_update_dir)/agents-previous.json"
  mkdir -p "$(_update_dir)" || return 1
  (
    flock -x 9 || exit 1
    tmp="$(mktemp "$f.XXXXXX")" || exit 1
    if [ -s "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
      jq -c --arg a "$a" --arg v "$old" '.[$a] = (.[$a] // $v)' "$f" >"$tmp" || { rm -f "$tmp"; exit 1; }
    else
      jq -nc --arg a "$a" --arg v "$old" '{($a): $v}' >"$tmp" || { rm -f "$tmp"; exit 1; }
    fi
    mv -f "$tmp" "$f"
  ) 9>"$f.lock"
}

_update_agents() { # returns 1 when any component failed or is still behind
  local a bin cmd old new latest out rc=0 shown=0 held="" f
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
    local ok=1
    out="$(_update_timeout "${CEL_UPDATE_AGENT_TIMEOUT:-900}" bash -e -u -o pipefail -c "$cmd" 2>&1)" || ok=0
    new="$(_update_agent_version "$a")" || new="?"
    # a version that moved is recorded BEFORE any failure branch (F1)
    if [ "$old" != "?" ] && [ "$new" != "?" ] && [ "$old" != "$new" ]; then
      _update_record_previous "$a" "$old" || { c_err "$a: could not record previous version $old in $(_update_dir)"; rc=1; }
    fi
    if [ "$ok" -eq 0 ]; then
      c_err "$a $old: update FAILED${new:+ (now $new)} - $(printf '%s' "$out" | tail -1 | cut -c1-160)"
      rc=1; continue
    fi
    if [ "$new" = "?" ]; then
      c_err "$a: the updater succeeded but the installed version cannot be read ($bin --version)"; rc=1; continue
    fi
    latest="$(_update_agent_latest "$a")"
    if [ -n "$latest" ] && cel_version_lt "$new" "$latest"; then
      c_err "$a still $new after its updater ran, latest $latest - NOT current (an updater that exits 0 is not proof)"
      rc=1
    elif [ "$old" != "$new" ]; then
      printf '  %s %s -> %s%s\n' "$a" "$old" "$new" "${latest:+ (latest $latest)}"
    else
      if [ -n "$latest" ]; then printf '  %s %s (current)\n' "$a" "$new"
      else printf '  %s %s (updater reports nothing newer; published latest unknown)\n' "$a" "$new"; fi
    fi
  done
  [ "$shown" -eq 1 ] || printf '  no coding agent with an update command is installed\n'
  # Pins are reported by name, never folded into "current".
  f="$(agent_get pi extensions_file)"
  if [ -n "$held" ] || { have pi && [ -n "$f" ] && [ -s "$CEL_ROOT/$f" ]; }; then
    c_hd "Pinned exceptions"
    for a in $held; do printf '  %s held by update.hold - remove it from the box config to update\n' "$a"; done
    if have pi && [ -n "$f" ] && [ -s "$CEL_ROOT/$f" ]; then
      printf '  pi extensions pinned by %s (%s) - raised to the pin, never downgraded, in the Pi extensions step; bump the pin in the repo\n' \
        "$f" "$(extension_names pi 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
    fi
  fi
  return "$rc"
}

# --- pi extensions and built-in MCP (AH-261018) ----------------------------
# Pi's startup warnings had two causes, both fixed by SUPPORTED means rather
# than patching node_modules or hiding the output:
#  1. an extension release that carries its own `typebox` dependency (older
#     pi-subagents, rpiv-todo) - fixed by upgrading to the pinned release that
#     declares it a peer, through `pi install`;
#  2. pi-mcp-adapter registering /mcp over pi's built-in MCP - fixed by moving
#     the adapter-effective server definitions into pi's own mcp.json and then
#     removing the adapter with `pi remove`.
# Upgrade-only (never downgrades an extension that is ahead of its pin),
# idempotent, and a failure leaves the previous state in place and is
# reported, not hidden.

_update_pi_dir() { gateway_pi_dir; }
# pi reads PI_CODING_AGENT_DIR; cel resolves the root it manages (PR177). Every
# pi call here pins the former to the latter so the directory written is the
# directory pi reads, whatever the caller's environment carries.
_update_pi() { PI_CODING_AGENT_DIR="$(_update_pi_dir)" pi "$@"; }

_update_pkg_version() { # <npm name> -> installed version or empty
  jq -r '.version // empty' "$(_update_pi_dir)/npm/node_modules/$1/package.json" 2>/dev/null || true
}

_update_pi_extensions() {
  have pi || return 0
  local f line name want have_v rc=0 shown=0
  f="$(agent_get pi extensions_file)"
  [ -n "$f" ] && [ -s "$CEL_ROOT/$f" ] || return 0
  c_hd "Pi extensions"
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    name="${line%@*}"; want="${line##*@}"
    [[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    have_v="$(_update_pkg_version "$name")"
    if [ -n "$have_v" ] && ! cel_version_lt "$have_v" "$want"; then
      printf '  %s %s (pin %s: current)\n' "$name" "$have_v" "$want"; continue
    fi
    shown=1
    if ! _update_pi install "npm:$line" >/dev/null 2>&1; then
      c_err "$name ${have_v:-missing}: pi install npm:$line FAILED - previous version left in place"; rc=1; continue
    fi
    # (`pi install` replaces the existing spec of the same package: verified on pi
    # 1.2.0. A `pi remove` of the old spec would remove the NEW install too.)
    have_v="${have_v:-missing}"
    printf '  %s %s -> %s\n' "$name" "$have_v" "$(_update_pkg_version "$name")"
  done < "$CEL_ROOT/$f"
  [ "$shown" -eq 1 ] || true
  return "$rc"
}

# Servers the legacy adapter serves on this box, from the host config it
# imports (~/.claude.json user scope). Definitions are copied VERBATIM (command,
# args, env, headers, type, url): values are never printed, only names.
# Every user-level host config the adapter imports from (its IMPORT_PATHS and
# shared-global file, read from the installed adapter's config.ts for 2.34.0).
# Merged here; conflicting definitions of one name, an unreadable file, or a
# source we cannot convert (codex/opencode) are BLOCKERS, collected in
# UPD_MCP_BLOCK so the adapter is kept with the reason instead of losing a server.
_update_pi_mcp_files() {
  printf '%s\n' "$HOME/.config/mcp/mcp.json" "$HOME/.cursor/mcp.json" "$HOME/.claude/mcp.json" \
    "$HOME/.claude.json" "$HOME/.claude/claude_desktop_config.json" "$HOME/.windsurf/mcp.json"
}

_update_pi_mcp_sources() { # sets UPD_MCP_SRC (JSON object name -> definition) and UPD_MCP_BLOCK; NOT run in a subshell
  local f js out='{}' name a b
  for f in $(_update_pi_mcp_files); do
    [ -e "$f" ] || continue
    js="$(jq -c '(.mcpServers // {}) | with_entries(select(.value | type == "object"))' "$f" 2>/dev/null)" \
      || { UPD_MCP_BLOCK="$UPD_MCP_BLOCK; $f exists but is not readable JSON"; continue; }
    for name in $(jq -r 'keys[]' <<<"$js"); do
      a="$(jq -c --arg n "$name" '.[$n]' <<<"$out")"; b="$(jq -c --arg n "$name" '.[$n]' <<<"$js")"
      if [ "$a" != null ] && [ "$a" != "$b" ]; then
        UPD_MCP_BLOCK="$UPD_MCP_BLOCK; server $name is defined differently in two host configs ($f)"
      fi
    done
    out="$(jq -c --argjson js "$js" '$js + .' <<<"$out")"
  done
  # sources the adapter reads that this migration does not convert
  for f in "$HOME/.codex/config.toml" "$HOME/.codex/config.json"; do
    [ -e "$f" ] && grep -q 'mcp' "$f" 2>/dev/null && UPD_MCP_BLOCK="$UPD_MCP_BLOCK; $f carries MCP definitions that are not migrated"
  done
  f="$HOME/.config/opencode/opencode.json"
  if [ -e "$f" ] && jq -e '(.mcp // {}) | length > 0' "$f" >/dev/null 2>&1; then
    UPD_MCP_BLOCK="$UPD_MCP_BLOCK; $f carries MCP definitions that are not migrated"
  fi
  UPD_MCP_SRC="$out"
}

# The built-in client's server schema (pi 1.2.0 docs/mcp.md). Anything outside it
# (the adapter's directTools/toolPrefix/include/excludeTools/approveTools/lifecycle,
# top-level settings/imports/claudePlugins) has no proven built-in equivalent.
_update_pi_mcp_foreign_keys() { # <mcp.json content> -> JSON list of offending paths
  jq -c '
    ((keys - ["mcpServers", "autoEnableCodemode"]) | map("top-level " + .)) as $top
    | ([ (.mcpServers // {}) | to_entries[] | .key as $n
        | (.value | keys - ["command","args","env","cwd","url","headers","oauth","type","timeout","enabled","exposure","toolExposure","description"])[]
        | "server " + $n + " key " + . ]) as $srv
    | $top + $srv' <<<"$1"
}

_update_pi_mcp() {
  have pi || return 0
  local pkgs adapter settings mcp src cur merged tmp name missing="" pending="" rc=0
  settings="$(_update_pi_dir)/settings.json"
  adapter="$(jq -r '[.packages[]? | strings | select(startswith("npm:pi-mcp-adapter"))] | .[0] // empty' "$settings" 2>/dev/null || true)"
  [ -n "$adapter" ] || return 0
  c_hd "Pi MCP (built-in replaces pi-mcp-adapter)"
  mcp="$(_update_pi_dir)/mcp.json"
  UPD_MCP_BLOCK=""; UPD_MCP_SRC="{}"
  _update_pi_mcp_sources
  src="$UPD_MCP_SRC"
  cur='{}'; [ -s "$mcp" ] && cur="$(jq -c '.' "$mcp" 2>/dev/null)" || true
  [ -n "$cur" ] || { c_err "$mcp is not valid JSON - left untouched; adapter kept"; return 1; }
  # existing built-in entries win; only missing names are added. A migrated
  # entry without an `exposure` gets the built-in default stated explicitly
  # (codemode: reachable on demand, not declared to the model) - the closest
  # match to the adapter's single proxy tool, which also declared no per-server
  # tools.
  merged="$(jq -c --argjson src "$src" '.mcpServers = (($src | map_values(. + (if has("exposure") then {} else {exposure: "codemode"} end))) + (.mcpServers // {}))' <<<"$cur")" || { c_err "could not merge MCP definitions - adapter kept"; return 1; }
  local foreign; foreign="$(_update_pi_mcp_foreign_keys "$merged")"
  if [ "$foreign" != "[]" ]; then
    UPD_MCP_BLOCK="$UPD_MCP_BLOCK; settings with no proven built-in equivalent: $(jq -r 'join(", ")' <<<"$foreign")"
  fi
  if [ -n "$UPD_MCP_BLOCK" ]; then
    c_err "MCP migration blocked (nothing written, adapter kept):${UPD_MCP_BLOCK#;}"
    return 1
  fi
  if [ "$merged" != "$cur" ]; then
    mkdir -p "$(dirname "$mcp")"
    tmp="$(mktemp "$(dirname "$mcp")/.mcp.XXXXXX")"
    ( umask 077; printf '%s\n' "$(jq . <<<"$merged")" >"$tmp" ) && chmod 600 "$tmp" && mv "$tmp" "$mcp" \
      || { rm -f "$tmp"; c_err "could not write $mcp - adapter kept"; return 1; }
  fi
  # Proof against the OBSERVED contract (pi 1.2.0): `pi mcp list --json` prints
  # {servers:[{name,scope,source,enabled,exposure,transport,state,tools[]}],errors[]}
  # with state "connected" | "needs-auth" | ... and exits 1 when any server is
  # not connected. Presence in mcp.json is not proof: a stdio server must be
  # connected AND have discovered tools; an HTTP server that is "needs-auth" is
  # a pending sign-in (`pi mcp login <server>`), never assumed fine.
  local listed st nt; listed="$(_update_pi mcp list --json 2>/dev/null)" || true
  [ -n "$listed" ] && jq -e '.servers | type == "array"' <<<"$listed" >/dev/null 2>&1 || listed='{"servers":[]}'
  for name in $(jq -r 'keys[]' <<<"$src"); do
    jq -e --arg n "$name" '.mcpServers[$n] != null' "$mcp" >/dev/null 2>&1 || { missing="$missing $name"; continue; }
    st="$(jq -r --arg n "$name" '[.servers[] | select(.name == $n)][0].state // "absent"' <<<"$listed")"
    nt="$(jq -r --arg n "$name" '[.servers[] | select(.name == $n)][0].tools // [] | length' <<<"$listed")"
    if [ "$(jq -r --arg n "$name" '.[$n].url // empty' <<<"$src")" != "" ]; then
      [ "$st" = connected ] && [ "$nt" -gt 0 ] || pending="$pending $name($st)"
    else
      [ "$st" = connected ] && [ "$nt" -gt 0 ] || missing="$missing $name($st,$nt tools)"
    fi
  done
  if [ -n "$missing" ]; then c_err "MCP servers not migrated:$missing - adapter kept"; return 1; fi
  if [ -n "$pending" ]; then
    c_err "MCP server(s)$pending need the built-in client signed in (PI_CODING_AGENT_DIR=<root> pi mcp login <server>) - adapter kept so nothing loses access; rerun cel update afterwards"
    return 1
  fi
  if _update_pi remove "$adapter" >/dev/null 2>&1; then
    printf '  migrated: %s; removed %s\n' "$(jq -r 'keys | join(", ")' <<<"$src")" "$adapter"
    printf '  tool access changes path, not names: the adapter exposed one `mcp` proxy tool; the built-in client registers mcp__<server>__<tool> (exposure codemode) - project-level .mcp.json/.pi/mcp.json are not touched.\n'
  else
    c_err "pi remove $adapter FAILED - definitions are migrated, adapter still installed"; rc=1
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
  _update_pi_extensions || rc=1
  _update_pi_mcp || rc=1
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
    if [ "$shown" -eq 0 ]; then c_hd "Orchestrator launch evidence"; shown=1; fi
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
