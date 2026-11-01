# shellcheck shell=bash
# Pi adapter for `cel plugins install <name> --runtime pi`.
#
# Pi 1.4 loads a local package directory IN PLACE: `pi install <path>` checks
# the path exists and records it in the user settings; nothing is copied. A
# directory without a package.json contributes its conventional skills/, so
# every skill loads from inside the immutable bundle, and the skills' relative
# agents/ and resources/ references resolve to that bundle's own siblings.
#
# Pi has no native subagent or persona definitions, so agents/*.md are not
# registered anywhere: the skills read them from the bundle as persona files.
[ -z "${_CEL_PLUGINS_PI:-}" ] || return 0
_CEL_PLUGINS_PI=1
# shellcheck source=lib/gateway.sh
. "${BASH_SOURCE[0]%/*}/gateway.sh"   # gateway_pi_dir, agent_roots_check

# <agent dir> <settings entry> -> the absolute path Pi resolves a local entry to
_plugins_pi_path() {
  local entry="${2#[+-]}"
  case "$entry" in
    '~') entry="$HOME" ;;
    '~/'*) entry="$HOME/${entry#'~/'}" ;;
    /*) ;;
    *) entry="$1/$entry" ;;
  esac
  realpath -m -- "$entry"
}

# <agent dir> <settings> -> kind<TAB>entry<TAB>resolved path for every resource
# reference; kind is package, filtered (object-form package) or skill. Remote
# sources resolve to an empty path.
_plugins_pi_entries() {
  local dir="$1" settings="$2" kind entry
  [ -e "$settings" ] || return 0
  jq -r '((.packages // [])[] | if type == "object" then ["filtered", (.source // "")] else ["package", .] end | @tsv),
         ((.skills // [])[] | strings | ["skill", .] | @tsv)' "$settings" |
  while IFS=$'\t' read -r kind entry; do
    case "$entry" in
      ''|'!'*) continue ;;
      npm:*|git:*|*://*|git@*) printf '%s\t%s\t\n' "$kind" "$entry" ;;
      *) printf '%s\t%s\t%s\n' "$kind" "$entry" "$(_plugins_pi_path "$dir" "$entry")" ;;
    esac
  done
}

_plugins_pi_install() { # <name> <source> <ref> <bundle>
  local name="$1" source="$2" ref="$3" bundle="$4" dir settings real skill skills="" n=0
  local kind entry path registered=0 filtered=0 conflict=""
  agent_roots_check pi || return 1
  dir="$(gateway_pi_dir)"
  settings="$dir/settings.json"
  real="$(realpath -e -- "$bundle")" || return 1
  for skill in "$real"/skills/*/SKILL.md; do
    [ -f "$skill" ] || continue
    skill="${skill%/SKILL.md}"; skills="$skills ${skill##*/}"; n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { c_err "$name bundle has no skills for Pi to load; no Pi changes made"; return 1; }
  if [ -e "$settings" ] && ! jq -e 'type == "object" and ((.packages // []) | type == "array")
      and ((.skills // []) | type == "array")' "$settings" >/dev/null 2>&1; then
    c_err "$settings is not a Pi settings object; refusing and leaving it unchanged"
    return 1
  fi
  while IFS=$'\t' read -r kind entry path; do
    if [ -z "$path" ]; then # a remote package: only the upstream repository itself collides
      case "$entry" in *"$source"*) conflict="$entry" ;; esac
      continue
    fi
    if [ "$kind" != skill ] && [ "$path" = "$real" ]; then
      registered=1; [ "$kind" = package ] || filtered=1
      continue
    fi
    case "$path/" in "$real"/*) continue ;; esac # a narrower reference into this bundle
    for skill in $skills; do
      if [ "${path##*/}" = "$skill" ] || [ -e "$path/$skill" ] || [ -e "$path/skills/$skill" ]; then conflict="$entry"; fi
    done
  done < <(_plugins_pi_entries "$dir" "$settings")
  # Pi also auto-discovers these; a same-named copy there would shadow the bundle
  for skill in $skills; do
    for path in "$dir/skills/$skill" "$HOME/.agents/skills/$skill"; do
      [ ! -e "$path" ] || conflict="$path"
    done
  done
  if [ -n "$conflict" ]; then
    c_err "Pi already loads $name skills from $conflict; refusing so one copy cannot shadow the other (remove it, then rerun). No Pi changes made"
    return 1
  fi
  if [ "$registered" = 0 ]; then
    # pinned root (never an inherited PI_CODING_AGENT_DIR) and a neutral cwd,
    # so no project .pi/settings.json takes part
    ( cd / && PI_CODING_AGENT_DIR="$dir" pi install "$real" >/dev/null ) || { c_err "pi install failed; see above"; return 1; }
    while IFS=$'\t' read -r kind entry path; do
      [ "$kind" = skill ] || [ "$path" != "$real" ] || registered=1
    done < <(_plugins_pi_entries "$dir" "$settings")
    [ "$registered" = 1 ] || { c_err "pi install did not record $real in $settings"; return 1; }
    printf 'Pi package added: %s\n' "$real"
  else
    printf 'Pi package already present: %s\n' "$real"
    [ "$filtered" = 0 ] || c_warn "its existing resource filter in $settings is kept as you set it"
  fi
  printf 'Pi settings: %s\n' "$settings"
  printf 'Pi skills (%s):%s\n' "$n" "$skills"
  printf 'Personas: Pi has no native subagents; the skills read agents/ and resources/ from the bundle, and reviews needing a fresh-context subagent stop and say so unless a Pi extension supplies one.\n'
}
