#!/usr/bin/env bash
# lib/yaml.sh - YAML read access, cached as JSON. Sourced by workspace.sh,
# registry.sh and profiles.sh; safe to source twice.

# YAML IS READ THROUGH A JSON CACHE. `yq` here is the Python wrapper and every
# call is a Python start, while callers read many fields per run. A file is
# converted once per (content, path) and every accessor then asks jq. The
# expressions are jq expressions already - the wrapper's language is jq's.
#
# A CACHE ENTRY IS PUBLISHED THROUGH A TEMP OF ITS OWN. Subshells and process
# substitutions share $$, so "$out.tmp.$$" is one file for concurrent first
# reads: one rename wins and the rest fail. mktemp beside the entry keeps the
# rename on one filesystem, so it stays atomic. A rename that loses to another
# reader is still a read when the key is the content hash and the entry that
# won is valid JSON: it is the parse of the same text. A `nohash-` key is one
# name for every content, so there the entry standing could be an older
# text's - a lost rename fails the read instead.
# mktemp makes entries 0600 where a redirect used the umask. The cache is
# per user ($XDG_CACHE_HOME, or a private mktemp -d from cel run), never
# shared, so owner-only is the right mode.
_yaml_cache_put() { # <out> <fresh> <converter...> - converter's stdout becomes <out>
  local out="$1" fresh="$2" tmp; shift 2
  tmp="$(mktemp "$out.tmp.XXXXXX" 2>/dev/null)" || return 1
  if ! "$@" > "$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$out" 2>/dev/null && return 0
  rm -f "$tmp"
  [ -z "$fresh" ] && [ -s "$out" ] && jq -e . "$out" >/dev/null 2>&1
}
_yaml_json() { # <file> -> path of the cached JSON
  local f="$1" dir key sum fresh=""
  dir="${CEL_YAML_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cel/yaml-json}"
  # THE KEY IS THE TEXT. Inode, mtime and size do not identify it: an in-place
  # edit within one second, or a restored mtime, keeps all three. md5sum reads
  # through a symlink, so editing the target is a new key too.
  key="$(printf '%s' "$f" | cksum | cut -d' ' -f1)"
  if sum="$(md5sum -- "$f" 2>/dev/null)"; then
    key="${sum%% *}-$key"
  else
    # No content hash, no cache: a key that cannot see an edit would serve
    # the old parse forever, so the file is converted on every read.
    key="nohash-$key"; fresh=1
  fi
  local out="$dir/$key.json"
  if [ -n "$fresh" ] || [ ! -s "$out" ]; then
    mkdir -p "$dir"
    _yaml_cache_put "$out" "$fresh" yq -c . "$f" || return 1
  fi
  printf '%s' "$out"
}
_yqr() { # <jq args...> <file>   - the shape every read call here already has
  local -a args=("$@"); local file="${args[-1]}"; unset 'args[-1]'
  local j; j="$(_yaml_json "$file")" || return 1
  jq "${args[@]}" "$j"
}

# A PER-BOX ROLE ROUTE, WITHOUT A SHARED-FILE EDIT. workspace.yaml is shared by
# everyone who clones it, but root and the orchestrators only ever get a model
# from role_profiles - so a login without the credential the shared file names
# needs a local override that does not collide with every sync.
#
# workspace.local.yaml, gitignored, sits beside workspace.yaml and is allowed
# to do four things and nothing else: override role_profiles (workspace-level,
# and per products[]/repos[] entry, matched by name), add worker_profiles,
# override env: keys, and say which person this login is (`me: <people id>`,
# lib/workspace.sh ws_me). The allowed top-level keys are _WS_LOCAL_KEYS below -
# the merge, doctor and the docs all read that one list.
# It cannot add a repo, change policy, or touch anything a teammate reading
# workspace.yaml would need to know to understand what ships. Local wins,
# nothing else is merged.
_WS_LOCAL_KEYS="role_profiles worker_profiles env products repos me"
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
  # keys (already content+path, see _yaml_json) rather than restated here, so
  # it can't drift from that scheme - and, like them, an input converted
  # without a content hash is merged afresh on every read. The merge program
  # itself is part of the identity too (`v2`: me:), so a box updated to a new
  # merge never serves a result the old one wrote for the same two files.
  local dir key out fresh=""
  dir="${CEL_YAML_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cel/yaml-json}"
  key="merged-v2-$(basename "$basej" .json)-$(basename "$localj" .json)"
  out="$dir/$key.json"
  [[ "$key" == *nohash-* ]] && fresh=1
  if [ ! -s "$out" ] || [ -n "$fresh" ]; then
    mkdir -p "$dir"
    _yaml_cache_put "$out" "$fresh" jq -s '
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
      # env: is per-box (a TMPDIR on this disk, a proxy on that network), so
      # local keys win one by one. Secrets still belong in env.local.
      | .env = (($b.env // {}) + ($l.env // {}))
      | .products = (($b.products // []) | map(
          . as $p | local_role_profiles($p.name; $lprod) as $o |
          if ($o | length) > 0 then $p + {role_profiles: (($p.role_profiles // {}) * $o)} else $p end))
      | .repos = (($b.repos // []) | map(
          . as $r | local_role_profiles($r.name; $lrepo) as $o |
          if ($o | length) > 0 then $r + {role_profiles: (($r.role_profiles // {}) * $o)} else $r end))
      # me: is per login by definition. A committed one would name the same
      # person on every teammate'"'"'s box, so only the local file'"'"'s counts.
      | (if $l.me != null then .me = $l.me else del(.me) end)
    ' "$basej" "$localj" || {
      # Valid YAML of the wrong shape (`role_profiles: []`) fails the merge;
      # like a parse error, it costs the override, not the box's routing.
      c_warn "$wsdir/workspace.local.yaml does not merge (a key has the wrong type) - ignoring it, using workspace.yaml alone" >&2
      printf '%s' "$basej"; return 0
    }
  fi
  printf '%s' "$out"
}
_yqr_ws() { # <jq args...> <wsdir>   - _yqr, but over the merged local view
  local -a args=("$@"); local wsdir="${args[-1]}"; unset 'args[-1]'
  local j; j="$(_ws_effective_json "$wsdir")" || return 1
  jq "${args[@]}" "$j"
}
