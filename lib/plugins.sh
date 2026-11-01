# shellcheck shell=bash
# Optional harness plugins are separate from default/global externals.
[ -z "${_CEL_PLUGINS:-}" ] || return 0
_CEL_PLUGINS=1
. "${BASH_SOURCE[0]%/*}/externals.sh"
. "${BASH_SOURCE[0]%/*}/plugins-pi.sh"
. "${BASH_SOURCE[0]%/*}/plugins-opencode.sh"

_plugins_usage() {
  cat <<'EOS'
cel plugins - optional full-bundle harness integrations

  cel plugins list
  cel plugins install egm --runtime omp|claude|codex|pi|opencode [--dry-run]

Elephant-Goldfish Model is an opt-in skills/persona plugin, not an LLM.
Installation retains its complete agents/, skills/ and resources/ bundle.
Upstream EGM ships no Pi/OpenCode manifest; Celestial adapters install the same
full bundle natively there. No runtime is restarted.
EOS
}

_plugins_rows() { externals_resolved "$CEL_ROOT/optional-plugins.yaml"; }

_plugins_bundle() ( # name source ref -> verified full checkout path
  set -euo pipefail
  local name="$1" source="$2" ref="$3" state root bundle stage actual dirty
  state="${XDG_DATA_HOME:-$HOME/.local/share}/celestial/optional-plugins"
  root="$state/$name/$ref"
  bundle="$root/bundle"
  [[ "$source" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { c_err 'optional plugins require a full repository'; exit 1; }
  [ ! -L "$state" ] && [ ! -L "$root" ] && [ ! -L "$bundle" ] || { c_err 'optional plugin cache is symlinked'; exit 1; }
  mkdir -p "$root"
  chmod 700 "$root"
  exec 9>"$root/.install.lock"
  flock -x 9
  if [ ! -e "$bundle" ]; then
    stage="$(mktemp -d "$root/.bundle.XXXXXX")"
    trap '[ -z "${stage:-}" ] || rm -rf -- "$stage"' EXIT
    git init -q "$stage" >&2
    git -C "$stage" remote add origin "https://github.com/$source.git"
    git -C "$stage" -c core.hooksPath=/dev/null fetch -q --depth=1 origin "$ref" >&2
    git -C "$stage" -c core.hooksPath=/dev/null checkout -q --detach FETCH_HEAD >&2
    actual="$(git -C "$stage" rev-parse HEAD)"
    [ "$actual" = "$ref" ] || { c_err 'optional plugin checkout does not match its pin'; exit 1; }
    mv -- "$stage" "$bundle"
    stage=""
  fi
  actual="$(git -C "$bundle" rev-parse HEAD)"
  dirty="$(git -C "$bundle" status --porcelain --untracked-files=all)"
  [ "$actual" = "$ref" ] && [ -z "$dirty" ] || { c_err 'optional plugin cache changed; preserving it and refusing installation'; exit 1; }
  # EGM skills resolve these siblings at runtime. Never install skills alone.
  [ -f "$bundle/plugin.json" ] && [ -f "$bundle/.claude-plugin/plugin.json" ] \
    && [ -f "$bundle/.codex-plugin/plugin.json" ] && [ -d "$bundle/skills" ] \
    && [ -d "$bundle/agents" ] && [ -d "$bundle/resources/document_standards" ] \
    || { c_err 'optional plugin is missing its full runtime bundle'; exit 1; }
  jq -e --arg name "$name" '.name == $name' "$bundle/plugin.json" >/dev/null
  printf '%s\n' "$bundle"
)

_plugins_install() {
  local name="${1:-}" runtime="" dry=0 row kind ref source origin bundle root market tmp
  [ -n "$name" ] || { _plugins_usage; return 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --runtime) [ "$#" -ge 2 ] && [ -n "$2" ] || { c_err '--runtime requires a value'; return 2; }; runtime="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) c_err "unknown plugin option: $1"; return 2 ;;
    esac
  done
  case "$runtime" in omp|claude|codex|pi|opencode) ;; *) c_err 'choose a runtime: omp, claude, codex, pi or opencode'; return 2 ;; esac
  row="$(_plugins_rows)" || return
  row="$(printf '%s\n' "$row" | while IFS=$'\t' read -r kind candidate ref source origin; do
    [ "$candidate" != "$name" ] || printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$candidate" "$ref" "$source" "$origin"
  done)"
  [ -n "$row" ] || { c_err "unknown optional plugin: $name (cel plugins list)"; return 2; }
  IFS=$'\t' read -r kind name ref source origin <<< "$row"
  if [ "$dry" = 1 ]; then
    printf 'Install optional %s for %s from %s at %s (full bundle; no restart)\n' "$name" "$runtime" "$source" "$ref"
    return 0
  fi
  have "$runtime" || { c_err "$runtime is not installed; no plugin changes made"; return 1; }
  bundle="$(_plugins_bundle "$name" "$source" "$ref")" || return
    root="${bundle%/bundle}"
    market="celestial-$name-$ref"
    # A local marketplace retains the complete immutable checkout, without
    # asking a native client to resolve a moving branch or copy skills only.
    mkdir -p "$root/.claude-plugin" "$root/.agents/plugins" || return
    tmp="$(mktemp "$root/.marketplace.XXXXXX")" || return
    if ! jq -n --arg market "$market" --arg name "$name" \
      '{name:$market,owner:{name:"Celestial"},plugins:[{name:$name,source:"./bundle"}]}' > "$tmp"; then rm -f "$tmp"; return 1; fi
    mv -- "$tmp" "$root/.claude-plugin/marketplace.json" || return
    tmp="$(mktemp "$root/.marketplace.XXXXXX")" || return
    if ! jq -n --arg market "$market" --arg name "$name" \
      '{name:$market,plugins:[{name:$name,source:"./bundle",policy:{installation:"AVAILABLE",authentication:"ON_INSTALL"}}]}' > "$tmp"; then rm -f "$tmp"; return 1; fi
    mv -- "$tmp" "$root/.agents/plugins/marketplace.json" || return
    case "$runtime" in
      claude)
        claude plugin marketplace add "$root" --scope user || return
        claude plugin install --yes --scope user "$name@$market" || return ;;
      omp)
        omp plugin marketplace add "$root" || return
        omp plugin install "$name@$market" --scope user || return ;;
      codex)
        codex plugin marketplace add "$root" || return
        codex plugin add "$name@$market" || return ;;
      pi) _plugins_pi_install "$name" "$source" "$ref" "$bundle" || return ;;
      opencode) _plugins_opencode_install "$name" "$bundle" || return ;;
    esac
  c_ok "$name installed for $runtime at $ref; start a new session to load it (nothing restarted)"
}

cmd_plugins() {
  local sub="${1:-list}" kind name ref source origin rows
  [ "$#" -eq 0 ] || shift
  case "$sub" in
    list)
      [ "$#" -eq 0 ] || { _plugins_usage; return 2; }
      rows="$(_plugins_rows)" || return
      while IFS=$'\t' read -r kind name ref source origin; do
        [ -n "$name" ] || continue
        printf '%s\t%s\t%s\tomp,claude,codex,pi,opencode\n' "$name" "$source" "$ref"
      done <<< "$rows" ;;
    install) _plugins_install "$@" ;;
    help|-h|--help) _plugins_usage ;;
    *) _plugins_usage; return 2 ;;
  esac
}
