# shellcheck shell=bash
# Reads agents.yaml. Every field access goes through here so the schema is
# described in exactly one place.
[ -n "${_CEL_MANIFEST_LIB:-}" ] && return 0
_CEL_MANIFEST_LIB=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"

# Overridable so tests can point at a fixture.
CEL_MANIFEST="${CEL_MANIFEST:-$CEL_ROOT/agents.yaml}"

# YQ ONCE, JQ AFTER. The Python `yq` wrapper costs an interpreter start plus a
# jq per field, and field access is the hot path (agent_get runs dozens of
# times per `cel run`). The manifest is converted to JSON once per CONTENT -
# a timestamp says nothing about an edit that kept or restored the mtime - and
# every query after that is a plain jq on the cache.
#
# A HIT FORKS NOTHING. Beside the JSON lives the exact text it was converted
# from, both named by that text's hash, and `<key>.current` names the hash
# last converted. A read compares the manifest to that text with builtins
# only; md5sum and yq run once per change. The pair is immutable once written,
# so a reader can never match one text and be handed another's parse. A new
# conversion removes the pairs it supersedes.
_manifest_json() { # -> path of a JSON copy of $CEL_MANIFEST
  local d="${CEL_MANIFEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cel/manifest}"
  local key="${CEL_MANIFEST//\//%}" text="" h="" seen=""
  [ -r "$CEL_MANIFEST" ] || return 1
  IFS= read -r -d '' text < "$CEL_MANIFEST" || true
  if IFS= read -r h 2>/dev/null < "$d/$key.current" && [ -s "$d/$key.$h.json" ] && [ -f "$d/$key.$h.yaml" ] \
      && { IFS= read -r -d '' seen 2>/dev/null < "$d/$key.$h.yaml" || true; } && [ "$seen" = "$text" ]; then
    printf '%s' "$d/$key.$h.json"; return 0
  fi
  mkdir -p "$d" 2>/dev/null || return 1
  # Convert the text just compared, not whatever the file holds a moment later.
  # The temps share a mktemp stem beside the cache: subshells share $$ (and
  # $RANDOM is 15 bits), so a $$-named stem is not this reader's own.
  local tmp; tmp="$(mktemp "$d/.$key.XXXXXX" 2>/dev/null)" || return 1
  printf '%s' "$text" > "$tmp.yaml" 2>/dev/null || { rm -f "$tmp" "$tmp.yaml"; return 1; }
  h="$(md5sum < "$tmp.yaml")"; h="${h%% *}"
  if [ ${#h} -ne 32 ] || ! { yq -c . "$tmp.yaml" > "$tmp.json" 2>/dev/null && [ -s "$tmp.json" ]; }; then
    rm -f "$tmp" "$tmp.yaml" "$tmp.json"; return 1
  fi
  # the JSON before its text: a matching text always has its parse beside it
  mv -f "$tmp.json" "$d/$key.$h.json" && mv -f "$tmp.yaml" "$d/$key.$h.yaml" \
    && printf '%s\n' "$h" > "$tmp.cur" && mv -f "$tmp.cur" "$d/$key.current" \
    || { rm -f "$tmp" "$tmp.yaml" "$tmp.json" "$tmp.cur"; return 1; }
  rm -f "$tmp"
  local old stale=()
  for old in "$d/$key".????????????????????????????????.json "$d/$key".????????????????????????????????.yaml "$d/$key.json"; do
    [ -e "$old" ] || continue
    case "$old" in "$d/$key.$h.json"|"$d/$key.$h.yaml") ;; *) stale+=("$old") ;; esac
  done
  [ "${#stale[@]}" -eq 0 ] || rm -f "${stale[@]}"
  printf '%s' "$d/$key.$h.json"
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

# How a runtime resumes a session: flag and value kind, or "".
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

# One field of an agent's `update:` block (command, latest, rollback), or "".
agent_update_get() { # <agent> <command|latest|rollback>
  _mq -r --arg a "$1" --arg k "$2" '.agents[$a].update[$k] // "" | tostring'
}

# The helper processes an agent legitimately keeps as DIRECT children of its
# own process (an MCP server it launched), one per line as
# `<argv0 basename><TAB><argv[1] suffix>`. Lets `cel gc` recognise a verified
# runtime that has such a child; any other child still vetoes. Empty when none.
agent_owned_children() { # <agent>
  _mq -r --arg a "$1" '.agents[$a].owned_children // [] | .[] | [(.argv0 // ""), (.argv_suffix // "")] | @tsv'
}
