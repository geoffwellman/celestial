# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
CEL_REGISTRY="$(fixture registry.yaml)"
source "$CEL_ROOT/lib/registry.sh"

test_registry_names_lists_every_workspace() {
  assert_eq "$(registry_names | tr '\n' ' ')" "alpha beta "
}
test_registry_path_expands_tilde() {
  assert_eq "$(registry_path alpha)" "$HOME/ws/alpha"
}
test_registry_path_leaves_absolute_paths_alone() {
  assert_eq "$(registry_path beta)" "/srv/beta"
}
test_registry_path_is_empty_for_unknown() {
  assert_eq "$(registry_path nope)" ""
}
test_registry_remote_null_reads_as_empty() {
  assert_eq "$(registry_remote beta)" ""
}
test_registry_remote_reads_url() {
  assert_eq "$(registry_remote alpha)" "git@github.com:someone/ws-alpha.git"
}
test_registry_add_upserts_and_survives_reread() {
  local tmp; tmp="$(mktemp -d)"
  CEL_REGISTRY="$tmp/registry.yaml"
  registry_add gamma "~/ws/gamma" ""
  assert_eq "$(registry_remote gamma)" ""
  assert_contains "$(registry_names)" "gamma"
  registry_set_remote gamma "git@github.com:x/ws-gamma.git"
  assert_eq "$(registry_remote gamma)" "git@github.com:x/ws-gamma.git"
  rm -rf "$tmp"
}
# registry_require calls die(), which exits the current shell. assert_fails
# runs its argument as a plain function call in this same process, so a bare
# `exit` would kill the whole test invocation instead of being observed as a
# failing exit status. Route through a subshell to contain it.
_registry_require_in_subshell() { ( registry_require "$@" ); }
test_registry_require_dies_for_unknown() {
  assert_fails _registry_require_in_subshell nope
}

# The registry is machine-local: a pre-public in-repo copy migrates to
# ~/.local/share/cel exactly once, and never when the caller overrides
# CEL_REGISTRY (every test does, so the suite can never eat a real registry).
test_registry_migrates_repo_copy_once() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/root" "$T/home"
  printf 'workspaces:\n  demo:\n    path: /tmp/demo\n    remote: null\n' > "$T/root/registry.yaml"
  ( HOME="$T/home" CEL_ROOT="$T/root" _CEL_REGISTRY='' CEL_REGISTRY='' \
    bash -c 'unset _CEL_REGISTRY CEL_REGISTRY; source "'"$CEL_ROOT"'/lib/registry.sh" 2>/dev/null
             [ -f "$HOME/.local/share/cel/registry.yaml" ] && [ ! -f "$CEL_ROOT/registry.yaml" ]' )
  local rc=$?
  [ "$rc" = 0 ] || { echo "migration did not move the file"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_registry_migration_skipped_when_overridden() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/root" "$T/home"
  printf 'workspaces: {}\n' > "$T/root/registry.yaml"
  ( HOME="$T/home" CEL_ROOT="$T/root" \
    bash -c 'unset _CEL_REGISTRY; CEL_REGISTRY="'"$T"'/elsewhere.yaml"; source "'"$CEL_ROOT"'/lib/registry.sh" 2>/dev/null
             [ -f "$CEL_ROOT/registry.yaml" ] && [ ! -e "$HOME/.local/share/cel/registry.yaml" ]' )
  local rc=$?
  [ "$rc" = 0 ] || { echo "override did not suppress migration"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_registry_replacement_stays_atomic_with_foreign_tmpdir() {
  local T; T="$(mktemp -d)"
  CEL_REGISTRY="$T/state/registry.yaml"
  local TMPDIR="$T/foreign"; mkdir -p "$TMPDIR"
  [ ! -d /dev/shm ] || TMPDIR=/dev/shm
  export TMPDIR
  mv() {
    local src="${@: -2:1}" dst="${@: -1}" inode
    [ "$(dirname "$src")" = "$(dirname "$dst")" ] || { echo "cross-directory registry replacement"; return 96; }
    inode="$(stat -c '%d:%i' "$src")"
    command mv "$@" || return
    [ "$(stat -c '%d:%i' "$dst")" = "$inode" ]
  }
  registry_add demo "$T/workspace" ""
  registry_set_remote demo "git@example.invalid:sample/workspace.git"
  assert_eq "$(registry_remote demo)" "git@example.invalid:sample/workspace.git"
  rm -rf "$T"
}

test_registry_failed_rename_preserves_previous_content_and_cleans_temp() {
  local T; T="$(mktemp -d)"
  CEL_REGISTRY="$T/registry.yaml"
  registry_add demo /tmp/demo ""
  local before; before="$(cat "$CEL_REGISTRY")"
  mv() { return 1; }
  assert_fails registry_set_remote demo "git@example.invalid:sample/workspace.git"
  assert_eq "$(cat "$CEL_REGISTRY")" "$before"
  local f
  for f in "$CEL_REGISTRY".tmp.*; do
    [ ! -e "$f" ] || { echo "failed update leaked temporary file"; return 1; }
  done
  rm -rf "$T"
}

test_concurrent_registry_writers_preserve_all_workspaces() {
  local T; T="$(mktemp -d)"
  CEL_REGISTRY="$T/registry.yaml"
  registry_add first /tmp/first "" &
  local first=$!
  registry_add second /tmp/second "" &
  local second=$!
  wait "$first"; wait "$second"
  assert_eq "$(registry_names | sort | tr '\n' ' ')" "first second "
  rm -rf "$T"
}
