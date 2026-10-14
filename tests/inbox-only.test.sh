# shellcheck shell=bash
# CEL-131: every agent-to-agent message goes through the inbox. Role and skill
# texts may name `herdr agent prompt` only for the one-time kickoff that
# launches an agent, or to say it is never used between agents.
test_role_and_skill_texts_never_prompt_between_agents() {
  local bad
  bad="$(grep -rn 'herdr agent prompt' "$CEL_ROOT/core/roles" "$CEL_ROOT/core/skills" \
    --include='*.md' \
    | grep -v 'one-time kickoff' \
    | grep -v 'is never used between agents' \
    | grep -v 'never `herdr agent prompt`' || true)"
  [ -z "$bad" ] || { printf 'agent-to-agent prompt in role/skill text:\n%s\n' "$bad"; return 1; }
}

# The steward reminds every stale mailbox by mail, never by typing into a pane.
test_steward_never_types_into_a_pane() {
  ! grep -nE '^[^#]*herdr agent prompt' "$CEL_ROOT/lib/steward.sh"
}
