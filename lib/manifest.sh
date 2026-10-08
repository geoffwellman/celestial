# shellcheck shell=bash
# Reads agents.yaml. Every field access goes through here so the schema is
# described in exactly one place.
[ -n "${_CEL_MANIFEST_LIB:-}" ] && return 0
_CEL_MANIFEST_LIB=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Overridable so tests can point at a fixture.
CEL_MANIFEST="${CEL_MANIFEST:-$CEL_ROOT/agents.yaml}"

# YQ ONCE, JQ AFTER (CEL-111). `yq` on this box is the pipx Python wrapper: an
# interpreter start, then a jq, for every field - and field access is the hot
# path (agent_get alone runs dozens of times per `cel run`). The manifest is
# converted to JSON once and cached beside its path; every query after that is
# a plain jq on the cache, rebuilt only when agents.yaml is newer than it.
_manifest_json() { # -> path of a JSON copy of $CEL_MANIFEST
  local d="${CEL_MANIFEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cel/manifest}"
  local key="${CEL_MANIFEST//\//%}"
  local c="$d/$key.json"
  if [ -s "$c" ] && [ "$c" -nt "$CEL_MANIFEST" ]; then printf '%s' "$c"; return 0; fi
  mkdir -p "$d" 2>/dev/null || true
  local tmp="$c.$$.$RANDOM"
  if yq -c . "$CEL_MANIFEST" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv -f "$tmp" "$c" 2>/dev/null; then
    printf '%s' "$c"; return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}
# jq on the cached JSON; straight yq when the cache cannot be written.
_mq() {
  local c
  if c="$(_manifest_json)"; then jq "$@" "$c"; else yq "$@" "$CEL_MANIFEST"; fi
}

# Values are passed with --arg rather than interpolated into the jq program:
# a key containing a dot or a quote would otherwise change the query's meaning.
agent_names() { _mq -r '.agents | keys_unsorted[]'; }

agent_get() {
  _mq -r --arg a "$1" --arg k "$2" '.agents[$a][$k] // "" | tostring'
}

agent_injection() {
  _mq -r --arg a "$1" --arg k "$2" '.agents[$a].role_injection[$k] // "" | tostring'
}

# One arg per line; empty output when the agent declares none.
agent_launch_args() {
  _mq -r --arg a "$1" '.agents[$a].launch_args // [] | .[]'
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
  _mq -r --arg a "$1" --arg k "$2" '.agents[$a].thinking[$k] // "" | tostring'
}

# The levels this runtime accepts, one per line, weakest first.
agent_thinking_levels() {
  _mq -r --arg a "$1" '.agents[$a].thinking.levels // [] | .[]'
}

# The runtime's read-only-orchestrator hook: flag and file, or "" for a
# runtime that has none (claude's is a global settings hook, not a launch arg).
agent_guard_hook() { # <runtime> <flag|file>
  _mq -r --arg a "$1" --arg k "$2" '.agents[$a].guard_hook[$k] // "" | tostring'
}

# How a runtime resumes a session (CEL-63): flag and value kind, or "".
agent_resume() { # <runtime> <flag|value>
  _mq -r --arg a "$1" --arg k "$2" '.agents[$a].resume[$k] // "" | tostring'
}

agent_inbox_hook() { # <runtime> <flag|file>
  _mq -r --arg a "$1" --arg k "$2" '.agents[$a].inbox_hook[$k] // "" | tostring'
}

provider_get() { # <provider> <key>
  _mq -r --arg p "$1" --arg k "$2" '.providers[$p][$k] // "" | tostring'
}

manifest_default() { # <key>
  _mq -r --arg k "$1" '.defaults[$k] // "" | tostring'
}

generated_skill_names() { _mq -r '.generated_skills // {} | keys_unsorted[]'; }

generated_skill_get() {
  _mq -r --arg n "$1" --arg k "$2" '.generated_skills[$n][$k] // "" | tostring'
}
