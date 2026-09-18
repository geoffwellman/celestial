# shellcheck shell=bash
# The box-level config file: `~/.local/share/cel/config.yaml`, two levels deep,
# one section per subject (`console:`, `update:`). The console reads it from
# JavaScript (`tools/console/translate.mjs readConfig`); this is the bash twin,
# and the two must agree on the shape - a section, then indented scalar keys,
# nothing nested further.
#
# The file holds the console's provider key, so anything that CREATES it
# creates it 0600. A config file holding `key:` that is world-readable is an
# API key readable by every process on a box that runs other people's agents.
[ -n "${_CEL_CONFIG:-}" ] && return 0
_CEL_CONFIG=1

cel_config_file() { printf '%s' "${CEL_CONFIG_FILE:-$HOME/.local/share/cel/config.yaml}"; }

# Empty when the file, the section or the key is absent - callers pick their
# own default rather than being handed the word "null".
cel_config_get() { # <section> <key>
  local f v
  f="$(cel_config_file)"
  [ -f "$f" ] || return 0
  v="$(yq -r ".$1.$2 // \"\"" "$f" 2>/dev/null || true)"
  [ "$v" = null ] && v=""
  printf '%s' "$v"
  return 0
}

# Rewrites one key in place and leaves every other section alone: the console's
# provider and key live in this file too, and a writer that rebuilt the whole
# document from yq would drop the comments and reorder the sections of a file
# a human maintains by hand.
cel_config_set() { # <section> <key> <value>
  local f dir
  f="$(cel_config_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir"
  if [ ! -f "$f" ]; then
    (umask 077; printf '%s:\n  %s: %s\n' "$1" "$2" "$3" >"$f")
    chmod 600 "$f"
    return 0
  fi
  local tmp
  tmp="$(mktemp "$dir/.config.XXXXXX")"
  chmod 600 "$tmp"
  awk -v want="$1" -v key="$2" -v val="$3" '
    function emit() { if (!done) { printf "  %s: %s\n", key, val; done = 1 } }
    /^[A-Za-z0-9_.-]+:/ {
      if (insec && !done) emit()
      insec = (index($0, want ":") == 1)
      if (insec) seen = 1
      print; next
    }
    insec && $0 ~ ("^[ \t]+" key ":") { emit(); next }
    { print }
    END {
      if (insec && !done) emit()
      else if (!seen) { printf "%s:\n  %s: %s\n", want, key, val }
    }' "$f" >"$tmp" && mv "$tmp" "$f"
  chmod 600 "$f"
  return 0
}
