# shellcheck shell=bash
# OpenCode compatibility is launch-scoped. The caller chooses an evidenced
# account route and writes a product/agent config; global OpenCode state stays put.
[ -n "${_CEL_OPENCODE:-}" ] && return 0
_CEL_OPENCODE=1

opencode_validate_config() { # tag rolefile configfile [expected-baseURL]; read-only
  local tag="$1" rolefile="$2" configfile="$3" base="${4:-}"
  [[ "$tag" =~ ^[a-zA-Z0-9_-]+$ && "$rolefile" = /* && "$configfile" = /* ]] || { printf 'OpenCode requires an explicit tag and absolute scoped paths\n' >&2; return 1; }
  if [ -z "$base" ]; then
    declare -F gateway_url >/dev/null || { printf 'OpenCode validation requires the canonical gateway URL\n' >&2; return 1; }
    base="$(gateway_url)/v1" || return 1
  fi
  node "$CEL_ROOT/tools/opencode/config.mjs" --validate "$configfile" "cel-$tag" "$rolefile" "$CEL_ROOT/tools/hooks/celestial.opencode.mjs" "$base"
}

opencode_agent_args() { # tag body dry rolefile configfile [expected-baseURL] -> AGENT_ARGS, AGENT_ROLE_FILE
  local tag="$1" body="$2" dry="$3" rolefile="$4" configfile="$5"
  [[ "$tag" =~ ^[a-zA-Z0-9_-]+$ ]] || { printf 'invalid OpenCode role tag\n' >&2; return 1; }
  [[ "$rolefile" = /* && "$configfile" = /* ]] || { printf 'OpenCode requires scoped absolute role/config paths\n' >&2; return 1; }
  if [ "$dry" -eq 0 ]; then
    # Config generation is the parent's product-scoped operation, not a side
    # effect of launch. Refuse before changing a role if it was not prepared.
    opencode_validate_config "$tag" "$rolefile" "$configfile" "${6:-}" || return 1
    mkdir -p "$(dirname "$rolefile")" || return 1
    (umask 077; printf '%s\n' "$body" > "$rolefile") || return 1
  fi
  AGENT_ARGS=(--agent "cel-$tag")
  AGENT_ROLE_FILE="$rolefile"
  CEL_OPENCODE_CONFIG_FILE="$configfile"
}

opencode_launch_guard() { # configfile -> guard before the shared env prefix
  local file="$1" quoted
  [[ "$file" = /* ]] || return 1
  printf -v quoted '%q' "$file"
  printf '_cel_opencode_config="$(cat -- %s)" && [ -n "$_cel_opencode_config" ] && ' "$quoted"
}

opencode_launch_env() { # append to the shared env prefix, after its guard
  # CONTENT merges after global/project configuration; CONFIG alone does not.
  # The private config contains env references, not credential values.
  printf 'OPENCODE_CONFIG_CONTENT="$_cel_opencode_config" '
}

opencode_write_config() { # destination; reads buildConfig input JSON on stdin
  local file="$1" tmp
  [[ "$file" = /* ]] || return 1
  mkdir -p "$(dirname "$file")" || return 1
  tmp="$(mktemp "$(dirname "$file")/.opencode-config.XXXXXX")" || return 1
  if ! node "$CEL_ROOT/tools/opencode/config.mjs" > "$tmp"; then rm -f "$tmp"; return 1; fi
  chmod 600 "$tmp" && mv "$tmp" "$file"
}
