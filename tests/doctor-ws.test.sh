# shellcheck shell=bash
# check_workspaces walks every registered workspace and audits it against
# workspace.yaml, its repos and its gitignore. Warnings (local-only, uncloned
# repos, missing gate binaries) never fail the pass - only
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
  yq -y '.runtime.orchestrator = "no-such-agent"' "$T/alpha/workspace.yaml" > "$tmp" \
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

# --- doctor_ws_local_lines: workspace.local.yaml drift ----------------------
#
# workspace.local.yaml may set only the keys in _WS_LOCAL_KEYS (lib/yaml.sh),
# and only routing inside a product/repo entry - the merge in
# _ws_effective_json silently drops anything outside that. Silent-drop is the
# right enforcement for the merge itself, but a hand-written per-box file needs
# a loud check somewhere, which is what doctor_ws_local_lines is for.

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

# --- doctor_people_lines: people:, me: and products[].home ------------------
#
# people: is the team's list of who is who; me: in this login's
# workspace.local.yaml says which of them this login is; products[].home
# names the login that runs a product's agents. A broken declaration is an
# error (a home naming nobody refuses every login), a forge account that does
# not match me: is a warning (the forge answer can be wrong for good reasons),
# and a team workspace whose auto products have no home is warned about:
# every teammate's steward would start them.
_dpl_setup() {
  T="$(mktemp -d)"
  cat > "$T/workspace.yaml" <<'YAML'
name: acme
kind: team
layout: { orchestrators: auto }
people:
  - id: sam
    login: sam-example
    roles: [owner, approver]
    products: { atlas: [qa] }
  - id: jo
    login: jo-example
    products: { atlas: [product-lead], billing: [qa] }
products:
  - { name: atlas, repos: [atlas-web], home: sam }
repos:
  - { name: atlas-web, url: "git@github.com:acme/atlas-web.git", prefix: ATL, gate: "true" }
  - { name: billing, url: "git@github.com:acme/billing.git", prefix: BIL, gate: "true", home: jo }
YAML
  printf 'me: sam\n' > "$T/workspace.local.yaml"
  # the forge is asked through one function, so no test reaches the network
  people_forge_login() { printf '%s' "${STUB_FORGE_LOGIN-sam-example}"; }
}

test_doctor_people_lines_pass_a_well_formed_team() {
  _dpl_setup
  local out rc=0; out="$(doctor_people_lines "$T" acme 2>&1)" || rc=$?
  assert_eq "$rc" "0" || { printf '%s\n' "$out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "this login is sam"
  assert_contains "$out" "sam-example"
  ! printf '%s' "$out" | grep -q $'\033\\[3[13]m' || { echo "a well-formed team drew a warning or an error:"; printf '%s\n' "$out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_doctor_people_lines_say_nothing_without_the_keys() {
  T="$(mktemp -d)"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  local out rc=0; out="$(doctor_people_lines "$T" alpha 2>&1)" || rc=$?
  assert_eq "$rc" "0"
  assert_eq "$out" ""
  rm -rf "$T"
}

test_doctor_people_lines_err_on_a_broken_schema() {
  _dpl_setup
  yq -y '.people += [{id: "sam", login: "dup"}, {id: "Bad_Id"}, {id: "lee", login: "not a login", roles: ["boss"], products: {nowhere: ["qa"], atlas: ["chief"]}}]' \
    "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  local out rc=0; out="$(doctor_people_lines "$T" acme 2>&1)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "'sam' is declared more than once"
  assert_contains "$out" "Bad_Id"
  assert_contains "$out" "'not a login'"
  assert_contains "$out" "'boss'"
  assert_contains "$out" "'chief'"
  assert_contains "$out" "'nowhere'"
  rm -rf "$T"
}

test_doctor_people_lines_err_on_a_committed_me_and_an_unknown_me() {
  _dpl_setup
  printf 'me: sam\n' >> "$T/workspace.yaml"
  local out rc=0; out="$(doctor_people_lines "$T" acme 2>&1)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "workspace.yaml declares me:"
  sed -i '/^me: sam$/d' "$T/workspace.yaml"
  printf 'me: lee\n' > "$T/workspace.local.yaml"
  rc=0; out="$(doctor_people_lines "$T" acme 2>&1)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "me: lee"
  assert_contains "$out" "names no person"
  rm -rf "$T"
}

test_doctor_people_lines_warn_when_the_forge_account_is_someone_else() {
  _dpl_setup
  local out rc=0
  out="$(STUB_FORGE_LOGIN=jo-example doctor_people_lines "$T" acme 2>&1)" || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$out" "jo-example"
  assert_contains "$out" "sam-example"
  assert_contains "$out" $'\033[33m!'
  rc=0; out="$(STUB_FORGE_LOGIN= doctor_people_lines "$T" acme 2>&1)" || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$out" "could not tell"
  rm -rf "$T"
}

test_doctor_people_lines_err_on_a_home_naming_nobody() {
  _dpl_setup
  sed -i 's/home: sam }/home: lee }/' "$T/workspace.yaml"
  local out rc=0; out="$(doctor_people_lines "$T" acme 2>&1)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "atlas"
  assert_contains "$out" "home: lee"
  rm -rf "$T"
}

test_doctor_people_lines_warn_a_login_with_no_me_in_a_homed_workspace() {
  _dpl_setup
  rm "$T/workspace.local.yaml"
  local out rc=0; out="$(doctor_people_lines "$T" acme 2>&1)" || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$out" "no me:"
  rm -rf "$T"
}

# C1: two teammates' stewards each starting the same auto product.
test_doctor_people_lines_warn_a_team_workspace_with_auto_products_and_no_home() {
  _dpl_setup
  yq -y 'del(.products[0].home) | del(.repos[1].home)' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  local out rc=0; out="$(doctor_people_lines "$T" acme 2>&1)" || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$out" "atlas"
  assert_contains "$out" "billing"
  assert_contains "$out" "no home"
  # not on a personal workspace, and not for a manual product
  yq -y '.kind = "personal"' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  out="$(doctor_people_lines "$T" acme 2>&1)"
  ! printf '%s' "$out" | grep -q 'no home' || { printf '%s\n' "$out"; rm -rf "$T"; return 1; }
  yq -y '.kind = "team" | .layout.orchestrators = "manual"' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  out="$(doctor_people_lines "$T" acme 2>&1)"
  ! printf '%s' "$out" | grep -q 'no home' || { printf '%s\n' "$out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# check_workspaces runs it: a home naming nobody fails the pass.
test_check_workspaces_runs_the_people_lines() {
  _doctor_ws_setup
  yq -y '.products = [{name: "bundle", repos: ["widget"], home: "lee"}]' "$T/alpha/workspace.yaml" > "$T/w" \
    && mv "$T/w" "$T/alpha/workspace.yaml"
  local out; out="$(check_workspaces 2>&1)" && { printf '%s\n' "$out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "home: lee"
  rm -rf "$T"
}
