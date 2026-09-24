# shellcheck shell=bash
# Reads agents.yaml. Every field access goes through here so the schema is
# described in exactly one place.
[ -n "${_CEL_MANIFEST_LIB:-}" ] && return 0
_CEL_MANIFEST_LIB=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Overridable so tests can point at a fixture.
CEL_MANIFEST="${CEL_MANIFEST:-$CEL_ROOT/agents.yaml}"

# Values are passed with --arg rather than interpolated into the jq program:
# a key containing a dot or a quote would otherwise change the query's meaning.
agent_names() { yq -r '.agents | keys_unsorted[]' "$CEL_MANIFEST"; }

agent_get() {
  yq -r --arg a "$1" --arg k "$2" '.agents[$a][$k] // "" | tostring' "$CEL_MANIFEST"
}

agent_injection() {
  yq -r --arg a "$1" --arg k "$2" '.agents[$a].role_injection[$k] // "" | tostring' "$CEL_MANIFEST"
}

# One arg per line; empty output when the agent declares none.
agent_launch_args() {
  yq -r --arg a "$1" '.agents[$a].launch_args // [] | .[]' "$CEL_MANIFEST"
}

# Expanded absolute path, or empty. Never "$HOME" for an unset value.
agent_skills_dir() {
  local d; d="$(agent_get "$1" skills_dir)"
  [ -z "$d" ] && return 0
  expand "$d"
}

agent_agents_dir() {
  local d; d="$(agent_get "$1" agents_dir)"
  [ -z "$d" ] && return 0
  expand "$d"
}

# How this runtime takes a model id, or empty if it cannot be pointed at one.
agent_model_flag() { agent_get "$1" model_flag; }

# One field of the runtime's `thinking:` block ("" when the runtime has none).
agent_thinking() { # <runtime> <strategy|flag|key>
  yq -r --arg a "$1" --arg k "$2" '.agents[$a].thinking[$k] // "" | tostring' "$CEL_MANIFEST"
}

# The levels this runtime accepts, one per line, weakest first.
agent_thinking_levels() {
  yq -r --arg a "$1" '.agents[$a].thinking.levels // [] | .[]' "$CEL_MANIFEST"
}

# The runtime's read-only-orchestrator hook: flag and file, or "" for a
# runtime that has none (claude's is a global settings hook, not a launch arg).
agent_guard_hook() { # <runtime> <flag|file>
  yq -r --arg a "$1" --arg k "$2" '.agents[$a].guard_hook[$k] // "" | tostring' "$CEL_MANIFEST"
}

agent_inbox_hook() { # <runtime> <flag|file>
  yq -r --arg a "$1" --arg k "$2" '.agents[$a].inbox_hook[$k] // "" | tostring' "$CEL_MANIFEST"
}

provider_get() { # <provider> <key>
  yq -r --arg p "$1" --arg k "$2" '.providers[$p][$k] // "" | tostring' "$CEL_MANIFEST"
}

manifest_default() { # <key>
  yq -r --arg k "$1" '.defaults[$k] // "" | tostring' "$CEL_MANIFEST"
}

generated_skill_names() { yq -r '.generated_skills // {} | keys_unsorted[]' "$CEL_MANIFEST"; }

generated_skill_get() {
  yq -r --arg n "$1" --arg k "$2" '.generated_skills[$n][$k] // "" | tostring' "$CEL_MANIFEST"
}
