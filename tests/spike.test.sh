# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/workspace.sh"
source "$CEL_ROOT/lib/spike.sh"

# assert_fails invokes its target in-process; a target that calls die()
# (exit 1) would kill this whole test process, not just the call. Wrap in a
# subshell so only the subshell exits and assert_fails observes it normally.
_spike_in_subshell()   { ( cmd_spike "$@" ); }
_promote_in_subshell() { ( cmd_promote "$@" ); }

# A tmp workspace: workspace.yaml like ws-alpha but with no repos yet, plus a
# skill so ws_link_skills has something to link.
_sandbox() {
  T="$(mktemp -d)"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/workspace.yaml"
  local tmp; tmp="$(mktemp)"
  yq -y '.repos = []' "$T/workspace.yaml" > "$tmp" && mv "$tmp" "$T/workspace.yaml"
  mkdir -p "$T/skills/deploy"
  printf -- '---\nname: deploy\n---\n' > "$T/skills/deploy/SKILL.md"
}

test_spike_scaffolds_inside_workspace() {
  _sandbox
  ( cd "$T" && cmd_spike widget >/dev/null )
  [ -d "$T/spikes/widget/.git" ]
  assert_contains "$(cat "$T/spikes/widget/CLAUDE.md")" "cel:policy:begin"
  [ -L "$T/spikes/widget/.claude/skills/deploy" ]
  rm -rf "$T"
}

test_spike_refuses_a_duplicate() {
  _sandbox
  ( cd "$T" && cmd_spike widget >/dev/null )
  ( cd "$T" && assert_fails _spike_in_subshell widget )
  rm -rf "$T"
}

test_spike_outside_workspace_dies() {
  ( cd /tmp && assert_fails _spike_in_subshell widget )
}

test_promote_no_remote_moves_and_registers() {
  _sandbox
  ( cd "$T" && cmd_spike widget >/dev/null )
  ( cd "$T" && printf 'WG\ntrue\n' | cmd_promote widget --no-remote >/dev/null )
  [ ! -d "$T/spikes/widget" ]
  [ -d "$T/repos/widget/.git" ]
  assert_eq "$(ws_repo_get "$T" widget prefix)" "WG"
  assert_eq "$(ws_repo_get "$T" widget gate)" "true"
  assert_eq "$(ws_repo_get "$T" widget url)" ""
  rm -rf "$T"
}

test_promote_flags_skip_the_interview() {
  _sandbox
  ( cd "$T" && cmd_spike widget >/dev/null )
  ( cd "$T" && printf '' | cmd_promote widget --no-remote --prefix X --gate 'bun test' >/dev/null )
  assert_eq "$(ws_repo_get "$T" widget prefix)" "X"
  assert_eq "$(ws_repo_get "$T" widget gate)" "bun test"
  rm -rf "$T"
}

test_promote_missing_spike_dies() {
  _sandbox
  ( cd "$T" && assert_fails _promote_in_subshell nope --no-remote )
  rm -rf "$T"
}
