# shellcheck shell=bash
# OpenCode 2.2.5 adapter for optional plugins. Upstream EGM ships no OpenCode
# manifest, so this uses OpenCode's own global configuration:
#   - `skills` (Config.Info: additional skill paths) names the pinned bundle's
#     skills/ directory. OpenCode reports each skill's base directory as the
#     scanned path, so it stays inside the bundle and EGM's sibling agents/,
#     resources/ and ../../docs references resolve. A symlink under
#     <config>/skills would report the link's directory instead.
#   - each persona becomes a native subagent (`agents.<name>`: mode subagent,
#     system {file:<persona>}). Persona files are not linked into
#     <config>/agents: their non-native `license` key makes OpenCode read them
#     as legacy agents and forward unknown keys into the model request body.
# Global configuration loads beneath OPENCODE_CONFIG_CONTENT, which Celestial
# scoped launches use, so they discover the same entries; default_agent is
# never written.
[ -z "${_CEL_PLUGINS_OPENCODE:-}" ] || return 0
_CEL_PLUGINS_OPENCODE=1

_plugins_opencode_install() ( # name bundle -> edits OpenCode's global config
  set -euo pipefail
  local name="$1" bundle="$2" dir file target managed skills agents persona id desc root conflicts current updated tmp
  dir="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
  # OpenCode's own config writer picks the last existing of these names.
  file="$dir/opencode.jsonc"
  [ -e "$file" ] || [ ! -e "$dir/opencode.json" ] || file="$dir/opencode.json"
  target="$(readlink -f -- "$file")" || target="$file"
  managed="${bundle%/*/bundle}/"
  skills="$bundle/skills"

  agents='{}'
  for persona in "$bundle"/agents/*.md; do
    [ -f "$persona" ] || continue
    id="$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1 && sub(/^name:[ \t]*/,""){print; exit}' "$persona")"
    desc="$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1 && sub(/^description:[ \t]*/,""){print; exit}' "$persona")"
    [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] && [ -n "$desc" ] \
      || { c_err "persona ${persona##*/} lacks a name/description; no OpenCode changes made"; exit 1; }
    agents="$(jq -c --arg id "$id" --arg desc "$desc" --arg file "$persona" \
      '. + {($id): {description: $desc, mode: "subagent", system: "{file:\($file)}"}}' <<< "$agents")"
  done

  conflicts=""
  for root in "$dir/skill" "$dir/skills" "$HOME/.claude/skills" "$HOME/.agents/skills"; do
    for id in "$skills"/*/; do
      id="${id%/}"; id="${id##*/}"
      [ ! -e "$root/$id" ] && [ ! -L "$root/$id" ] || conflicts+=" $root/$id"
    done
  done
  [ -z "$conflicts" ] || { c_err "OpenCode already has skills with $name's names; refusing:$conflicts"; exit 1; }

  if [ -e "$target" ]; then
    jq -se 'length == 1 and (.[0] | type) == "object"' "$target" >/dev/null 2>&1 || {
      c_err "$file is not a plain JSON object (comments?); refusing to rewrite it"
      printf '  add manually: "skills": [%s] and these "agents": %s\n' "$(jq -Rn --arg s "$skills" '$s')" "$agents"
      exit 1
    }
    current="$(cat -- "$target")"
  else
    current='{}'
  fi

  # Entries under this plugin's own cache are ours (any pinned ref) and are
  # replaced; anything else with an EGM name is the owner's and refuses.
  local program='
    def ours_skill: type == "string" and startswith($managed) and endswith("/bundle/skills");
    def ours_agent: type == "object" and (.system | type == "string") and (.system | startswith("{file:" + $managed));
    def merge_skills: if any(.[]; . == $skills) and ([.[] | select(ours_skill and . != $skills)] | length) == 0
      then . else [.[] | select(ours_skill | not)] + [$skills] end;
    if $mode == "conflicts" then
      [($agents | keys[]) as $id
        | (.agents? // {})[$id]? as $native | (.agent? // {})[$id]? as $legacy
        | select(($native != null and ($native | ours_agent | not)) or $legacy != null)
        | $id]
    else
      (if .skills == null then .skills = [$skills]
       elif (.skills | type) == "array" then .skills |= merge_skills
       elif (.skills | type) == "object" then .skills.paths = ((.skills.paths // []) | merge_skills)
       else error("unsupported skills value") end)
      | .agents = (((.agents // {}) | with_entries(select((.value | ours_agent | not) or (.key as $id | $agents | has($id))))) + $agents)
    end'
  conflicts="$(jq -r --arg mode conflicts --arg managed "$managed" --arg skills "$skills" --argjson agents "$agents" \
    "$program | .[]" <<< "$current")" || { c_err "$file has an unsupported shape; no OpenCode changes made"; exit 1; }
  [ -z "$conflicts" ] || { c_err "$file already defines agents $(tr '\n' ' ' <<< "$conflicts")that $name would use; refusing"; exit 1; }
  updated="$(jq --arg mode install --arg managed "$managed" --arg skills "$skills" --argjson agents "$agents" \
    "$program" <<< "$current")" || { c_err "$file has an unsupported skills value; no OpenCode changes made"; exit 1; }

  if [ -e "$target" ] && jq -e --argjson a "$current" --argjson b "$updated" -n '$a == $b' >/dev/null; then
    printf 'OpenCode already lists %s skills %s and agents %s in %s\n' "$name" "$skills" "$(jq -r 'keys | join(",")' <<< "$agents")" "$file"
    exit 0
  fi
  mkdir -p "$(dirname -- "$target")"
  tmp="$(mktemp "$(dirname -- "$target")/.opencode-config.XXXXXX")"
  trap 'rm -f -- "$tmp"' EXIT
  printf '%s\n' "$updated" > "$tmp"
  if [ -e "$target" ]; then chmod --reference="$target" "$tmp"; else chmod 644 "$tmp"; fi
  mv -- "$tmp" "$target"
  printf 'OpenCode skills: %s\nOpenCode subagents: %s\nConfig: %s\n' "$skills" "$(jq -r 'keys | join(", ")' <<< "$agents")" "$file"
)
