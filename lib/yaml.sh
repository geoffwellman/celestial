#!/usr/bin/env bash
# lib/yaml.sh - YAML read access, cached as JSON. Sourced by workspace.sh,
# registry.sh and profiles.sh; safe to source twice.

# YAML IS READ THROUGH A JSON CACHE. `yq` here is the Python wrapper and every
# call is a Python start (~130 ms); the fleet made thirty of them per run and
# the console took twelve seconds to draw. A file is converted once per
# (inode, mtime, size) and every accessor then asks jq, which is ~5 ms. The
# expressions are jq expressions already - the wrapper's language is jq's.
_yaml_json() { # <file> -> path of the cached JSON
  local f="$1" dir key
  dir="${CEL_YAML_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cel/yaml-json}"
  key="$(stat -c '%i-%Y-%s' "$f" 2>/dev/null || printf none)-$(printf '%s' "$f" | cksum | cut -d' ' -f1)"
  local out="$dir/$key.json"
  if [ ! -s "$out" ]; then
    mkdir -p "$dir"
    yq -c . "$f" > "$out.tmp.$$" 2>/dev/null && mv -f "$out.tmp.$$" "$out" || { rm -f "$out.tmp.$$"; return 1; }
  fi
  printf '%s' "$out"
}
_yqr() { # <jq args...> <file>   - the shape every read call here already has
  local -a args=("$@"); local file="${args[-1]}"; unset 'args[-1]'
  local j; j="$(_yaml_json "$file")" || return 1
  jq "${args[@]}" "$j"
}
