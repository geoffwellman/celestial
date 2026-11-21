# shellcheck shell=bash
setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export CEL_MANIFEST="$(fixture agents.yaml)"
  source "$CEL_ROOT/lib/common.sh"
  source "$CEL_ROOT/lib/manifest.sh"
  source "$CEL_ROOT/lib/link.sh"
}

test_core_skills_are_linked_into_every_skills_dir() {
  setup_sandbox
  link_core_skills >/dev/null
  [ -L "$HOME/.claude/skills/linear" ] || return 1
  [ -L "$HOME/.omp/agent/skills/linear" ] || return 1
  [ -L "$HOME/.codex/skills/linear" ]  || return 1
}

test_links_are_symlinks_not_copies() {
  setup_sandbox
  link_core_skills >/dev/null
  assert_eq "$(readlink -f "$HOME/.claude/skills/review")" "$CEL_ROOT/core/skills/review"
}

test_linking_twice_is_idempotent() {
  setup_sandbox
  link_core_skills >/dev/null
  link_core_skills >/dev/null
  assert_eq "$(find "$HOME/.claude/skills" -maxdepth 1 -name linear | wc -l)" "1"
}

# A retired core skill (fanout, pr-loop) leaves a dangling link behind; the
# next link pass removes it, and leaves a user's own dangling link alone.
test_links_to_retired_core_skills_are_removed() {
  setup_sandbox
  mkdir -p "$HOME/.claude/skills"
  ln -s "$CEL_ROOT/core/skills/fanout" "$HOME/.claude/skills/fanout"
  ln -s "$SANDBOX/gone" "$HOME/.claude/skills/mine"
  link_core_skills >/dev/null 2>&1
  [ ! -L "$HOME/.claude/skills/fanout" ] || { echo "retired link kept"; return 1; }
  [ -L "$HOME/.claude/skills/mine" ] || { echo "removed a link that is not ours"; return 1; }
}

# Role bodies reference panes, worktrees and .agent/result.md. A Claude agents
# dir registers everything in it as a globally dispatchable subagent, so a role
# file there gets dispatched into a context where none of that exists.
test_roles_are_never_linked_into_an_agents_dir() {
  setup_sandbox
  link_core_agents >/dev/null
  [ ! -e "$HOME/.claude/agents/solo.md" ] || return 1
  [ ! -e "$HOME/.claude/agents/root-orchestrator.md" ] || return 1
}

test_stale_role_links_are_removed() {
  setup_sandbox
  mkdir -p "$HOME/.claude/agents"
  ln -s "$CEL_ROOT/core/roles/solo.md" "$HOME/.claude/agents/solo.md"
  unlink_stale_roles >/dev/null
  [ ! -e "$HOME/.claude/agents/solo.md" ] || return 1
}

test_unrelated_files_in_an_agents_dir_survive() {
  setup_sandbox
  mkdir -p "$HOME/.claude/agents"
  echo "mine" > "$HOME/.claude/agents/my-own-agent.md"
  unlink_stale_roles >/dev/null
  assert_eq "$(cat "$HOME/.claude/agents/my-own-agent.md")" "mine"
}

test_an_agent_without_a_skills_dir_is_skipped_not_linked_into_home() {
  setup_sandbox
  link_core_skills >/dev/null
  [ ! -e "$HOME/linear" ] || return 1
}

# omp and pi read user skills from <agent root>/skills only (omp 18.16, pi
# 1.5: ~/.omp/skills and ~/.pi/skills are never read), and Celestial launches
# them with PI_CODING_AGENT_DIR set to that root. A link anywhere else is a
# skill the agent never sees.
test_omp_and_pi_skills_dirs_are_inside_the_agent_root_they_launch_with() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home" CEL_MANIFEST="$CEL_ROOT/agents.yaml" CEL_MANIFEST_CACHE="$SANDBOX/cache"
  unset CEL_PI_AGENT_DIR CEL_OMP_AGENT_DIR
  mkdir -p "$HOME"
  source "$CEL_ROOT/lib/common.sh"
  source "$CEL_ROOT/lib/manifest.sh"
  source "$CEL_ROOT/lib/gateway.sh"
  assert_eq "$(agent_skills_dir omp)" "$(gateway_omp_dir)/skills"
  assert_eq "$(agent_skills_dir pi)" "$(gateway_pi_dir)/skills"
  rm -rf "$SANDBOX"
}

# The plane's links left in the directories omp and pi never read go; a link
# that is not the plane's stays.
test_core_skill_links_in_unread_runtime_dirs_are_removed() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home" CEL_MANIFEST="$CEL_ROOT/agents.yaml" CEL_MANIFEST_CACHE="$SANDBOX/cache"
  mkdir -p "$HOME/.pi/skills" "$HOME/.omp/skills"
  ln -s "$CEL_ROOT/core/skills/linear" "$HOME/.pi/skills/linear"
  ln -s "$CEL_ROOT/core/skills/review" "$HOME/.omp/skills/review"
  ln -s "$SANDBOX/elsewhere" "$HOME/.omp/skills/mine"
  source "$CEL_ROOT/lib/common.sh"
  source "$CEL_ROOT/lib/manifest.sh"
  source "$CEL_ROOT/lib/link.sh"
  link_core_skills >/dev/null 2>&1
  [ ! -L "$HOME/.pi/skills/linear" ] || { echo "plane link kept in ~/.pi/skills"; return 1; }
  [ ! -L "$HOME/.omp/skills/review" ] || { echo "plane link kept in ~/.omp/skills"; return 1; }
  [ -L "$HOME/.omp/skills/mine" ] || { echo "removed a link that is not the plane's"; return 1; }
  [ -L "$HOME/.pi/agent/skills/linear" ] && [ -L "$HOME/.omp/agent/skills/review" ] || { echo "not relinked"; return 1; }
  rm -rf "$SANDBOX"
}
