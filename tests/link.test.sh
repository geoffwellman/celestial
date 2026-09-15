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
  [ -L "$HOME/.claude/skills/fanout" ] || return 1
  [ -L "$HOME/.omp/skills/fanout" ]    || return 1
  [ -L "$HOME/.codex/skills/fanout" ]  || return 1
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
  assert_eq "$(find "$HOME/.claude/skills" -maxdepth 1 -name fanout | wc -l)" "1"
}

# Role bodies reference panes, worktrees and .agent/result.md. A Claude agents
# dir registers everything in it as a globally dispatchable subagent, so a role
# file there gets dispatched into a context where none of that exists.
test_roles_are_never_linked_into_an_agents_dir() {
  setup_sandbox
  link_core_agents >/dev/null
  [ ! -e "$HOME/.claude/agents/worker.md" ] || return 1
  [ ! -e "$HOME/.claude/agents/root-orchestrator.md" ] || return 1
}

test_stale_role_links_are_removed() {
  setup_sandbox
  mkdir -p "$HOME/.claude/agents"
  ln -s "$CEL_ROOT/core/roles/worker.md" "$HOME/.claude/agents/worker.md"
  unlink_stale_roles >/dev/null
  [ ! -e "$HOME/.claude/agents/worker.md" ] || return 1
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
  [ ! -e "$HOME/fanout" ] || return 1
}
