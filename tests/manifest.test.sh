# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
CEL_MANIFEST="$(fixture agents.yaml)"
source "$CEL_ROOT/lib/manifest.sh"

test_agent_names_lists_every_agent() {
  assert_eq "$(agent_names | tr '\n' ' ')" "claude omp codex "
}

test_agent_get_reads_a_scalar() {
  assert_eq "$(agent_get claude bin)" "claude"
}

test_agent_get_returns_empty_for_a_missing_field() {
  assert_eq "$(agent_get codex agents_dir)" ""
}

test_agent_get_returns_empty_for_a_missing_agent() {
  assert_eq "$(agent_get nosuchagent bin)" ""
}

test_agent_get_preserves_a_value_containing_a_pipe() {
  assert_contains "$(agent_get claude install)" "| bash"
}

test_agent_injection_reads_a_nested_field() {
  assert_eq "$(agent_injection claude flag)" "--append-system-prompt"
}

test_agent_injection_reads_the_strategy() {
  assert_eq "$(agent_injection codex strategy)" "prompt_arg"
}

test_agent_injection_is_empty_when_the_key_is_absent() {
  assert_eq "$(agent_injection codex flag)" ""
}

test_launch_args_one_per_line() {
  assert_eq "$(agent_launch_args claude)" "--dangerously-skip-permissions"
}

test_launch_args_empty_when_unset() {
  assert_eq "$(agent_launch_args codex)" ""
}

test_skills_dir_is_expanded() {
  assert_eq "$(agent_skills_dir claude)" "$HOME/.claude/skills"
}

test_agents_dir_is_expanded() {
  assert_eq "$(agent_agents_dir omp)" "$HOME/.omp/agent/agents"
}

# codex has no agents_dir. Returning "$HOME" for an empty value would make
# link.sh scatter role files into the home directory.
test_agents_dir_is_empty_not_home_when_unset() {
  assert_eq "$(agent_agents_dir codex)" ""
}

test_generated_skill_names() {
  assert_eq "$(generated_skill_names)" "herdr"
}

test_generated_skill_get() {
  assert_eq "$(generated_skill_get herdr command)" "herdr --skill"
}

# CEL-111: yq is the pipx Python wrapper - an interpreter start per call. The
# manifest is converted ONCE per process and every field is a jq query on it.
test_manifest_runs_yq_once_per_process() {
  local B; B="$(mktemp -d)"
  local real; real="$(command -v yq)"
  printf '#!/usr/bin/env bash\necho x >> "%s/count"\nexec "%s" "$@"\n' "$B" "$real" > "$B/yq"
  chmod +x "$B/yq"
  PATH="$B:$PATH"
  agent_get claude command >/dev/null
  agent_injection claude strategy >/dev/null
  agent_launch_args claude >/dev/null
  agent_names >/dev/null
  assert_eq "$(wc -l < "$B/count" | tr -d ' ')" "1"
  rm -rf "$B"
}
