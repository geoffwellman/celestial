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

# A PER-BOX ROLE ROUTE, WITHOUT A SHARED-FILE EDIT. workspace.yaml is one file
# in the workspace's own repo, read the same way by everyone who clones it.
# Under a per-login box - one person, one set of provider credentials - that
# is a problem for exactly the two things nobody launches by hand: root and
# the orchestrators only ever get a model from role_profiles, so a login
# without the credential the shared file names has no way to run either,
# short of an uncommitted local edit that collides with every sync.
#
# workspace.local.yaml, gitignored, sits beside workspace.yaml and is allowed
# to do two things and nothing else: override role_profiles (workspace-level,
# and per products[]/repos[] entry, matched by name) and add worker_profiles.
# It cannot add a repo, change policy, or touch anything a teammate reading
# workspace.yaml would need to know to understand what ships. Local wins,
# nothing else is merged.
_ws_effective_json() { # <wsdir> -> path of the cached, locally-overridden JSON
  local wsdir="$1" base="$1/workspace.yaml" localf="$1/workspace.local.yaml"
  [ -f "$localf" ] || { _yaml_json "$base"; return; }
  local basej localj
  basej="$(_yaml_json "$base")" || return 1
  # A hand-written per-box file with no schema and no CI: a parse error here
  # must not take the shared workspace.yaml down with it. Warn and fall back
  # to base alone, so a typo costs the override, not the whole box's routing.
  # _ws_effective_json's stdout IS its return value (a path), captured by
  # every caller via command substitution - c_warn must go to stderr here or
  # the warning text lands IN the path and every subsequent read breaks too.
  localj="$(_yaml_json "$localf")" || {
    c_warn "$wsdir/workspace.local.yaml is not valid YAML - ignoring it, using workspace.yaml alone" >&2
    printf '%s' "$basej"; return 0
  }
  # The merge's cache identity is borrowed from the two inputs' own cache
  # keys (already device+inode+mtime+size+path, see _yaml_json) rather than
  # restated here, so it can't drift from that scheme.
  local dir key out
  dir="${CEL_YAML_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cel/yaml-json}"
  key="merged-$(basename "$basej" .json)-$(basename "$localj" .json)"
  out="$dir/$key.json"
  if [ ! -s "$out" ]; then
    mkdir -p "$dir"
    jq -s '
      .[0] as $b | .[1] as $l |
      ($l.role_profiles // {}) as $lrp |
      ($l.products // []) as $lprod |
      ($l.repos // []) as $lrepo |
      def local_role_profiles($name; $list):
        first($list[] | select(.name == $name) | .role_profiles // {}) // {};
      $b
      # role_profiles values are scalars (a role name -> a profile name), so
      # `*` degrades to right-wins per key: local overrides one role and
      # leaves the rest of the base binding untouched.
      | .role_profiles = (($b.role_profiles // {}) * $lrp)
      # worker_profiles values are OBJECTS. `*` would field-merge a same-named
      # profile instead of replacing it, so a local override could inherit
      # the base profile'"'"'s `via: gateway`, `fallback:` or `thinking:` - the
      # exact shared-credential route this file exists to let a login avoid.
      # `+` replaces the whole profile body when the name collides.
      | .worker_profiles = (($b.worker_profiles // {}) + ($l.worker_profiles // {}))
      | .products = (($b.products // []) | map(
          . as $p | local_role_profiles($p.name; $lprod) as $o |
          if ($o | length) > 0 then $p + {role_profiles: (($p.role_profiles // {}) * $o)} else $p end))
      | .repos = (($b.repos // []) | map(
          . as $r | local_role_profiles($r.name; $lrepo) as $o |
          if ($o | length) > 0 then $r + {role_profiles: (($r.role_profiles // {}) * $o)} else $r end))
    ' "$basej" "$localj" > "$out.tmp.$$" 2>/dev/null && mv -f "$out.tmp.$$" "$out" || { rm -f "$out.tmp.$$"; return 1; }
  fi
  printf '%s' "$out"
}
_yqr_ws() { # <jq args...> <wsdir>   - _yqr, but over the merged local view
  local -a args=("$@"); local wsdir="${args[-1]}"; unset 'args[-1]'
  local j; j="$(_ws_effective_json "$wsdir")" || return 1
  jq "${args[@]}" "$j"
}
