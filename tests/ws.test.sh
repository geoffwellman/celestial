# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/ws.sh"

_sandbox() { T="$(mktemp -d)"; CEL_REGISTRY="$T/registry.yaml"; }

test_ws_new_scaffolds_and_registers() {
  _sandbox
  printf '' | cmd_ws new t1 --kind hustle --org someone --merge humans-only \
    --path "$T/t1" --no-remote >/dev/null
  [ -f "$T/t1/workspace.yaml" ]
  assert_eq "$(ws_name "$T/t1")" "t1"
  assert_eq "$(ws_policy "$T/t1" merge)" "humans-only"
  assert_contains "$(cat "$T/t1/.gitignore")" "repos/"
  git -C "$T/t1" rev-parse HEAD >/dev/null
  assert_eq "$(registry_path t1)" "$T/t1"
  assert_eq "$(registry_remote t1)" ""
  rm -rf "$T"
}
test_ws_new_interviews_for_missing_answers() {
  _sandbox
  printf 't2\nhustle\nsomeone\nhumans-only\nn\n' | \
    cmd_ws new --path "$T/t2" >/dev/null
  assert_eq "$(ws_kind "$T/t2")" "hustle"
  rm -rf "$T"
}
test_ws_new_interview_empty_answers_take_defaults() {
  _sandbox
  printf 't3\n\n\n\n\n' | cmd_ws new --path "$T/t3" >/dev/null
  assert_eq "$(ws_kind "$T/t3")" "personal"
  assert_eq "$(ws_policy "$T/t3" merge)" "humans-only"
  rm -rf "$T"
}
test_ws_list_shows_local_only() {
  _sandbox
  printf '' | cmd_ws new t4 --kind hustle --org o --merge self \
    --path "$T/t4" --no-remote >/dev/null
  assert_contains "$(cmd_ws list)" "local-only"
  rm -rf "$T"
}
test_ws_sync_links_skills_and_renders_block() {
  _sandbox
  printf '' | cmd_ws new t5 --kind hustle --org o --merge self \
    --path "$T/t5" --no-remote >/dev/null
  mkdir -p "$T/t5/skills/deploy" "$T/t5/repos/widget"
  printf -- '---\nname: deploy\n---\n' > "$T/t5/skills/deploy/SKILL.md"
  git -C "$T/t5/repos/widget" init -q
  local tmpw; tmpw="$(mktemp)"
  yq -y '.repos = [{name: "widget", url: null, prefix: "WG", gate: "true"}]' \
    "$T/t5/workspace.yaml" > "$tmpw" && mv "$tmpw" "$T/t5/workspace.yaml"
  cmd_ws sync t5 >/dev/null
  [ -L "$T/t5/repos/widget/.claude/skills/deploy" ]
  assert_contains "$(cat "$T/t5/repos/widget/CLAUDE.md")" "cel:policy:begin"
  rm -rf "$T"
}
test_ws_env_command_prints_exports_and_is_silent_outside() {
  _sandbox
  printf '' | cmd_ws new t7 --kind hustle --org o --merge self \
    --path "$T/t7" --no-remote >/dev/null
  local tmpw; tmpw="$(mktemp)"
  yq -y '.env = {CLOUDFLARE_ACCOUNT_ID: "personal"}' "$T/t7/workspace.yaml" \
    > "$tmpw" && mv "$tmpw" "$T/t7/workspace.yaml"
  assert_contains "$(cmd_ws env t7)" "export CLOUDFLARE_ACCOUNT_ID='personal'"
  assert_contains "$(cat "$T/t7/.gitignore")" "env.local"
  assert_eq "$( (cd /tmp && cmd_ws env) )" ""
  rm -rf "$T"
}
# _ws_add dies via die() (exit 1) when the clone lacks workspace.yaml. Called
# directly, that exit would kill this whole test process (bash -c), not just
# fail the assertion - so run it in a subshell, per project convention for
# assert_fails targets that call die().
_ws_add_in_subshell() { ( _ws_add "$@" ); }
test_ws_add_requires_a_workspace_repo() {
  _sandbox
  local src; src="$(mktemp -d)"; git -C "$src" init -q
  git -C "$src" commit --allow-empty -qm x
  assert_fails _ws_add_in_subshell "$src" plain
  rm -rf "$T" "$src"
}
