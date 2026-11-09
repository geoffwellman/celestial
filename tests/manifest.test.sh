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
  PATH="$B:$PATH"; export CEL_MANIFEST_CACHE="$B/cache"
  agent_get claude command >/dev/null
  agent_injection claude strategy >/dev/null
  agent_launch_args claude >/dev/null
  agent_names >/dev/null
  assert_eq "$(wc -l < "$B/count" | tr -d ' ')" "1"
  rm -rf "$B"
}

# ...and that one conversion is of the CURRENT text: an edit that leaves the
# manifest no newer than the cache (a restored or older mtime) is still read.
test_manifest_cache_sees_an_edit_that_keeps_size_and_mtime() {
  local B; B="$(mktemp -d)"
  local CEL_MANIFEST="$B/agents.yaml" CEL_MANIFEST_CACHE="$B/cache"
  printf 'agents:\n  claude:\n    bin: aaaa\n' > "$CEL_MANIFEST"; touch -d '2020-01-01 00:00:00' "$CEL_MANIFEST"
  assert_eq "$(agent_get claude bin)" aaaa
  printf 'agents:\n  claude:\n    bin: bbbb\n' > "$CEL_MANIFEST"; touch -d '2020-01-01 00:00:00' "$CEL_MANIFEST"
  assert_eq "$(agent_get claude bin)" bbbb
  rm -rf "$B"
}

# One conversion per CHANGE, and only the current one kept: a read that finds
# the text unchanged runs neither md5sum nor yq, and converting a new text
# removes the conversion it supersedes.
test_manifest_cache_keeps_only_the_current_conversion_and_forks_nothing_on_a_hit() {
  local B; B="$(mktemp -d)"
  local CEL_MANIFEST="$B/agents.yaml" CEL_MANIFEST_CACHE="$B/cache"
  printf 'agents:\n  claude:\n    bin: aaaa\n' > "$CEL_MANIFEST"
  assert_eq "$(agent_get claude bin)" aaaa
  printf 'agents:\n  claude:\n    bin: bbbb\n' > "$CEL_MANIFEST"
  assert_eq "$(agent_get claude bin)" bbbb
  assert_eq "$(find "$B/cache" -name '*.json' | wc -l | tr -d ' ')" 1
  md5sum() { echo md5sum >> "$B/forks"; command md5sum "$@"; }
  yq() { echo yq >> "$B/forks"; command yq "$@"; }
  assert_eq "$(agent_get claude bin)" bbbb
  unset -f md5sum yq
  [ ! -e "$B/forks" ] || { echo "a cache hit ran: $(tr '\n' ' ' < "$B/forks")"; rm -rf "$B"; return 1; }
  rm -rf "$B"
}

# Concurrent first reads each convert through a temp of their own. Subshells
# share $$, and $RANDOM can repeat (it is seeded the same here to make the
# collision certain), so neither may name the temp.
test_manifest_cache_concurrent_first_reads_all_succeed_and_leave_no_temps() {
  local B i; B="$(mktemp -d)"
  local CEL_MANIFEST="$B/agents.yaml" CEL_MANIFEST_CACHE="$B/cache"
  printf 'agents:\n  claude:\n    bin: racy\n' > "$CEL_MANIFEST"
  yq() { command yq "$@"; local rc=$?; sleep 0.3; return "$rc"; }
  for i in 1 2 3 4 5 6; do
    ( rc=0; j="$(RANDOM=7; _manifest_json 2>/dev/null)" || rc=$?
      jq -r .agents.claude.bin "$j" > "$B/out.$i" 2>/dev/null || true; printf '%s' "$rc" > "$B/rc.$i" ) &
  done
  wait
  unset -f yq
  for i in 1 2 3 4 5 6; do
    assert_eq "$(cat "$B/rc.$i"):$(cat "$B/out.$i")" "0:racy"
  done
  assert_eq "$(find "$B/cache" -name '.*' -type f | wc -l | tr -d ' ')" 0
  rm -rf "$B"
}

# AH-261018: pi resumes through its own native `--session`, so a restart keeps
# the original session file instead of starting fresh; omp keeps `--resume`.
test_manifest_declares_native_session_resume_for_pi_and_omp() {
  CEL_MANIFEST="$CEL_ROOT/agents.yaml"
  assert_eq "$(agent_resume pi flag)" "--session"
  assert_eq "$(agent_resume omp flag)" "--resume"
}

# AH-261018: every installed agent has a declared native updater, and the one
# helper child gc may accept is named by exact argv, not by a pattern.
test_manifest_declares_an_update_command_for_every_agent() {
  CEL_MANIFEST="$CEL_ROOT/agents.yaml"
  local a
  for a in $(agent_names); do
    [ -n "$(agent_update_get "$a" command)" ] || { echo "no update command for $a"; return 1; }
  done
}
test_manifest_owned_children_are_exact_argv_pairs() {
  CEL_MANIFEST="$CEL_ROOT/agents.yaml"
  assert_eq "$(agent_owned_children claude)" "$(printf 'node\t/.hindsight/coding-agents/dist/mcp-server.js')"
  assert_eq "$(agent_owned_children codex)" ""
}
