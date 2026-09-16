# shellcheck shell=bash
# Reads and writes the registry - the box's list of workspaces. Mirrors
# lib/manifest.sh: every field access goes through here.
#
# The registry is MACHINE-LOCAL STATE, never repo content: which workspaces
# live on this box (and where) is private to the box, and the plane repo is
# public. It therefore lives beside the other box state under
# ~/.local/share/cel, not in the checkout.
[ -n "${_CEL_REGISTRY:-}" ] && return 0
_CEL_REGISTRY=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_CEL_REGISTRY_DEFAULT="$HOME/.local/share/cel/registry.yaml"

# A LOCK MUST NOT OUTLIVE THE PROCESS THAT TOOK IT. flock lives on the open
# file description, not on the process, so any child that inherits the
# descriptor keeps the lock held after its parent is gone - and a lock held by
# a process that has nothing to do with the data looks exactly like a lock in
# use, so nothing recovers from it. On 2026-09-16 every `cel-fanout release`
# on one workspace blocked on .cel/delegations.lock for an hour and a half
# behind seven test servers a killed gate had left running on inherited
# descriptors. Bash cannot set FD_CLOEXEC, so every spawn out of a locked
# region goes through here instead: the descriptor is closed and then the
# command is exec'd, leaving no copy of the lock anywhere down the tree - not
# even in an intermediate shell, which would hold it just as effectively as
# the child. It is a SUBSHELL function on purpose: the close (and the exec)
# must happen in a forked copy, never in the caller - bash 5.3 can run a
# command substitution without forking, and a bare `exec` there would replace
# the caller outright and drop the lock. An external command is exec'd so no
# intermediate shell is left behind; a shell function or builtin cannot be
# exec'd and is called in place, which is equally safe once the descriptor is
# closed. An empty <fd> means "no lock held" and is not an error, so callers
# pass "${fd:-}" unguarded. A BACKGROUNDED spawn does not go through here:
# `&` forks a job shell that would keep its own copy of the descriptor for as
# long as the child runs, so write `cmd {fd}>&- &` and close it inline.
lock_spawn() ( # <fd>[ <fd>...] <cmd> [args...] - descriptors as ONE argument
  local _lock_fds="$1" _lock_fd _lock_kind; shift
  [ $# -gt 0 ] || return 2
  for _lock_fd in $_lock_fds; do exec {_lock_fd}>&-; done
  _lock_kind="$(type -t "$1" 2>/dev/null)" || _lock_kind=file
  case "$_lock_kind" in function|builtin|keyword) "$@" ;; *) exec "$@" ;; esac
)
CEL_REGISTRY="${CEL_REGISTRY:-$_CEL_REGISTRY_DEFAULT}"

# One-time migration from the pre-public in-repo location. Fires only when the
# caller has not overridden CEL_REGISTRY (tests always do), the new file does
# not exist yet, and the old one does. mv, not cp: the repo copy is untracked
# now, and leaving private entries on disk inside a public checkout is the
# exact failure this move exists to end. Warning rides stderr - accessors run
# inside command substitutions.
_registry_migrate() (
  [ "$CEL_REGISTRY" = "$_CEL_REGISTRY_DEFAULT" ] || return 0
  [ ! -f "$CEL_REGISTRY" ] || return 0
  [ -f "$CEL_ROOT/registry.yaml" ] || return 0
  mkdir -p "$(dirname "$CEL_REGISTRY")" || return 1
  local fd tmp
  exec {fd}>"$CEL_REGISTRY.lock" && flock "$fd" || return 1
  [ ! -e "$CEL_REGISTRY" ] || return 0
  tmp="$(mktemp "$CEL_REGISTRY.tmp.XXXXXX")" || return 1
  trap 'rm -f -- "$tmp"' EXIT
  cp "$CEL_ROOT/registry.yaml" "$tmp" && mv -f -- "$tmp" "$CEL_REGISTRY" || return 1
  rm -- "$CEL_ROOT/registry.yaml" || return 1
  c_warn "registry migrated to $CEL_REGISTRY" >&2
)
_registry_migrate

registry_names() {
  [ -f "$CEL_REGISTRY" ] || return 0
  yq -r 'if type == "object" and (.workspaces | type == "object") and all(.workspaces[]; type == "object" and (.path | type == "string" and length > 0)) then .workspaces | keys_unsorted[] else error("invalid workspace registry") end' "$CEL_REGISTRY"
}

registry_path() {
  [ -f "$CEL_REGISTRY" ] || return 0
  local p
  p="$(yq -r --arg n "$1" '.workspaces[$n].path // ""' "$CEL_REGISTRY")" || return 1
  [ -z "$p" ] && return 0
  expand "$p"
}

registry_remote() {
  [ -f "$CEL_REGISTRY" ] || return 0
  yq -r --arg n "$1" '.workspaces[$n].remote // ""' "$CEL_REGISTRY"
}

# Serialize read/modify/replace, not just the final rename: separate CLI
# invocations can register workspaces or update remotes concurrently.
_registry_update() (
  local tmp fd
  mkdir -p "$(dirname "$CEL_REGISTRY")" || return 1
  exec {fd}>"$CEL_REGISTRY.lock" && flock "$fd" || return 1
  tmp="$(mktemp "$CEL_REGISTRY.tmp.XXXXXX")" || return 1
  trap 'rm -f -- "$tmp"' EXIT
  if [ -e "$CEL_REGISTRY" ] || [ -L "$CEL_REGISTRY" ]; then
    lock_spawn "$fd" yq -y "$@" "$CEL_REGISTRY" > "$tmp" || return 1
  else
    lock_spawn "$fd" yq -y "$@" <<< 'workspaces: {}' > "$tmp" || return 1
  fi
  mv -f -- "$tmp" "$CEL_REGISTRY" || return 1
)

# Upsert. An empty remote is stored as null - legitimate local-only state.
registry_add() {
  _registry_update --arg n "$1" --arg p "$2" --arg r "$3" \
    '.workspaces[$n] = {path: $p, remote: (if $r == "" then null else $r end)}'
}

registry_set_remote() {
  _registry_update --arg n "$1" --arg r "$2" \
    '.workspaces[$n].remote = (if $r == "" then null else $r end)'
}

# Prints the expanded path or dies. The one you call at the top of a command.
registry_require() {
  local p; p="$(registry_path "$1")"
  [ -n "$p" ] || die "workspace '$1' is not in the registry (cel ws list)"
  [ -d "$p" ] || die "workspace '$1' registered at $p but nothing is there"
  printf '%s' "$p"
}
