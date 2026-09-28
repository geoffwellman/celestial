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
  CEL_MANIFEST="$CEL_ROOT/tests/fixtures/agents.yaml"
  # Doctor checks executable availability, not a real agent installation.
  mkdir -p "$T/bin"
  local bin_
  for bin_ in claude omp; do
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/$bin_"
    chmod +x "$T/bin/$bin_"
  done
  PATH="$T/bin:$PATH"
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
  [ "$rc" -eq 0 ] || printf '%s\n' "$out"
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

# --- doctor_ws_local_lines: workspace.local.yaml drift, AH-260928 ----------
#
# workspace.local.yaml is allowed to override role_profiles/worker_profiles
# and nothing else - the merge in _ws_effective_json silently drops anything
# outside that. Silent-drop is the right enforcement for the merge itself,
# but a hand-written per-box file needs a loud check somewhere, which is
# what doctor_ws_local_lines is for.

_dwl_setup() { # <wsdir var> - a bare wsdir, no registry needed
  T="$(mktemp -d)"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
}

test_doctor_ws_local_lines_is_quiet_with_no_local_file() {
  _dwl_setup
  local out; out="$(doctor_ws_local_lines "$T" alpha)"
  assert_eq "$out" ""
  rm -rf "$T"
}

test_doctor_ws_local_lines_is_quiet_for_a_well_formed_override() {
  _dwl_setup
  cat > "$T/workspace.local.yaml" <<'YAML'
role_profiles: { worker: bare }
worker_profiles:
  bare: { runtime: omp, model: some-model }
YAML
  local out; out="$(doctor_ws_local_lines "$T" alpha)"
  assert_eq "$out" ""
  rm -rf "$T"
}

test_doctor_ws_local_lines_warns_on_an_unrelated_top_level_key() {
  _dwl_setup
  cat > "$T/workspace.local.yaml" <<'YAML'
policy: { workers: 8 }
YAML
  local out; out="$(doctor_ws_local_lines "$T" alpha)" || true
  assert_contains "$out" "'policy'"
  assert_contains "$out" "silently ignored"
  rm -rf "$T"
}

test_doctor_ws_local_lines_warns_on_an_unmatched_repo_name() {
  _dwl_setup
  cat > "$T/workspace.local.yaml" <<'YAML'
repos:
  - name: gadget
    role_profiles: { worker: bare }
YAML
  local out; out="$(doctor_ws_local_lines "$T" alpha)" || true
  assert_contains "$out" "gadget"
  assert_contains "$out" "workspace.yaml does not declare"
  rm -rf "$T"
}

test_doctor_ws_local_lines_is_quiet_for_a_matched_repo_name() {
  _dwl_setup
  cat > "$T/workspace.local.yaml" <<'YAML'
repos:
  - name: widget
    role_profiles: { worker: bare }
YAML
  local out; out="$(doctor_ws_local_lines "$T" alpha)"
  assert_eq "$out" ""
  rm -rf "$T"
}

test_doctor_ws_local_lines_errs_on_a_malformed_local_file() {
  _dwl_setup
  printf 'role_profiles: [this is not a mapping\n' > "$T/workspace.local.yaml"
  local out rc=0; out="$(doctor_ws_local_lines "$T" alpha)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "does not parse"
  rm -rf "$T"
}
