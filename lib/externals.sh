# shellcheck shell=bash
# Plugins are global per tool, so overlays are additive and cannot disagree on
# either the source repository or exact commit for a shared plugin name.
[ -n "${_CEL_EXTERNALS:-}" ] && return 0
_CEL_EXTERNALS=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# externals_merge FILE... -> kind \t name \t ref \t source \t origin-file
# Buffer all rows: malformed later overlays must not emit a partial install plan.
externals_merge() {
  local f rows all=""
  for f in "$@"; do
    [ -f "$f" ] || continue
    rows="$(yq -r --arg f "$f" '
      def entries($kind):
        to_entries[] | . as $entry |
        if (.key | test("^[a-z0-9][a-z0-9-]*$")) and
          (.value | type == "object") and
          (.value | has("version") | not) and
          (.value.ref | type == "string") and
          (.value.ref | test("^[a-f0-9]{40}$")) and
          (.value.source | type == "string") and
          (.value.source | test("^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*(/[A-Za-z0-9_-][A-Za-z0-9_.-]*)*$"))
        then [$kind, .key, .value.ref, .value.source, $f] | @tsv
        else error("invalid external " + $entry.key + " in " + $f + ": require source owner/repo[/path] and exact 40-character ref; version is not a pin") end;
      (.plugins // {} | entries("plugin")),
      (.herdr_plugins // {} | entries("herdr_plugin"))' "$f")" || return
    [ -z "$rows" ] || all+="${all:+$'\n'}$rows"
  done
  [ -z "$all" ] || printf '%s\n' "$all"
  return 0
}

# Prints one line per conflict; parse failures and source changes also refuse.
externals_conflicts() {
  local rows
  rows="$(externals_merge "$@")" || return
  [ -n "$rows" ] || return 0
  awk -F'\t' '
    { key = $1 "/" $2
      if (key in ref) {
        if (ref[key] != $3 || source[key] != $4) {
          printf "%s conflict: %s at %s in %s but %s at %s in %s\n", key, source[key], ref[key], origin[key], $4, $3, $5
          bad = 1
        }
      } else { ref[key] = $3; source[key] = $4; origin[key] = $5 }
    }
    END { exit bad ? 1 : 0 }' <<< "$rows"
}

# Deduplicated rows; emits nothing on any invalid input or conflict.
externals_resolved() {
  local conflicts rows
  conflicts="$(externals_conflicts "$@")" || { printf '%s\n' "$conflicts" >&2; return 1; }
  rows="$(externals_merge "$@")" || return
  [ -n "$rows" ] || return 0
  awk -F'\t' '!seen[$1"/"$2]++' <<< "$rows"
}
