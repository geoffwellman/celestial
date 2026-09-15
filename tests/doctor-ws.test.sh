# shellcheck shell=bash
# check_workspaces walks every registered workspace and audits it against
# workspace.yaml, its repos and its gitignore. Warnings (local-only, uncloned
# repos, missing gate binaries, stale delegations) never fail the pass - only
# c_err findings do.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/registry.sh"
source "$CEL_ROOT/lib/workspace.sh"
source "$CEL_ROOT/lib/manifest.sh"
source "$CEL_ROOT/lib/doctor.sh"

# A well-formed, local-only workspace registered as "alpha" in a tmp registry.
# Each test breaks one property from here, so the happy path is proven once.
_doctor_ws_setup() {
  T="$(mktemp -d)"
  CEL_REGISTRY="$T/registry.yaml"
  mkdir -p "$T/alpha/repos/widget"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/alpha/workspace.yaml"
  printf 'repos/\nspikes/\n.cel/\n' > "$T/alpha/.gitignore"
  git -C "$T/alpha/repos/widget" init -q
  registry_add alpha "$T/alpha" ""
}

test_check_workspaces_passes_and_warns_local_only() {
  _doctor_ws_setup
  local out rc=0
  out="$(check_workspaces)" || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$out" "alpha is local-only"
  rm -rf "$T"
}

test_check_workspaces_fails_when_gitignore_missing_a_line() {
  _doctor_ws_setup
  printf 'repos/\n.cel/\n' > "$T/alpha/.gitignore"
  assert_fails check_workspaces
  rm -rf "$T"
}

test_check_workspaces_fails_for_dangling_skill_symlink() {
  _doctor_ws_setup
  mkdir -p "$T/alpha/repos/widget/.claude/skills"
  ln -s "$T/alpha/does-not-exist" "$T/alpha/repos/widget/.claude/skills/ghost"
  assert_fails check_workspaces
  rm -rf "$T"
}

test_check_workspaces_fails_for_unregistered_runtime_bin() {
  _doctor_ws_setup
  local tmp; tmp="$(mktemp)"
  yq -y '.runtime.worker = "no-such-agent"' "$T/alpha/workspace.yaml" > "$tmp" \
    && mv "$tmp" "$T/alpha/workspace.yaml"
  assert_fails check_workspaces
  rm -rf "$T"
}

test_check_workspaces_errs_on_missing_registered_path() {
  T="$(mktemp -d)"
  CEL_REGISTRY="$T/registry.yaml"
  registry_add ghost "$T/nowhere" ""
  assert_fails check_workspaces
  rm -rf "$T"
}
