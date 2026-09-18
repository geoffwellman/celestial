# shellcheck shell=bash
# Version plumbing: VERSION file + v* git tags are the truth, GitHub Releases
# are the announcement channel. Doctor and the steward use the remote check to
# tell the human when the box is behind.
[ -n "${_CEL_VERSION:-}" ] && return 0
_CEL_VERSION=1

cel_version() { tr -d '[:space:]' < "$CEL_ROOT/VERSION"; }

# Newest release tag on origin, empty when offline - bounded and
# noninteractive so no caller ever hangs on it.
cel_latest_remote_version() {
  local -a t=(); have timeout && t=(timeout 10)
  GIT_TERMINAL_PROMPT=0 "${t[@]}" git -C "$CEL_ROOT" ls-remote --tags --refs origin 'v*' 2>/dev/null \
    | sed 's#.*refs/tags/v##' | sort -V | tail -1
}

# THE BUILD, not the release. The owner, 2026-09-18: "I don't think we should
# rely on just the version - what about commits in between new versions?" On a
# box that tracks main, VERSION alone is a lie by omission: it says v0.2.0
# while the checkout is thirty-odd merges past the tag of that name. So the
# build people quote is `v0.2.0+31 (d43910c, main)` - the nearest tag, the
# distance from it, the sha and the branch.
cel_build_tag() { # nearest reachable v* tag, without the v; VERSION when none
  local t
  t="$(git -C "$CEL_ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  if [ -n "$t" ]; then printf '%s' "${t#v}"; else cel_version; fi
}

cel_build_count() { # commits since that tag; the whole history when untagged
  local t n
  t="$(git -C "$CEL_ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  if [ -n "$t" ]; then
    n="$(git -C "$CEL_ROOT" rev-list --count "$t..HEAD" 2>/dev/null || printf 0)"
  else
    n="$(git -C "$CEL_ROOT" rev-list --count HEAD 2>/dev/null || printf 0)"
  fi
  printf '%s' "${n:-0}"
}

cel_build_sha() { git -C "$CEL_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'no-git'; }

# A detached HEAD is what `cel update` leaves on the release channel, and
# "HEAD" as a branch name tells the reader nothing.
cel_build_branch() {
  local b
  b="$(git -C "$CEL_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$b" ]; then printf 'no-git'; elif [ "$b" = HEAD ]; then printf 'detached'; else printf '%s' "$b"; fi
}

cel_build_version() { printf '%s+%s' "$(cel_build_tag)" "$(cel_build_count)"; }

cel_build_line() { printf 'v%s (%s, %s)' "$(cel_build_version)" "$(cel_build_sha)" "$(cel_build_branch)"; }

# How far this checkout is behind the branch it tracks. Caller fetches first:
# this reads refs, it does not go to the network.
cel_commits_behind_main() {
  local n
  n="$(git -C "$CEL_ROOT" rev-list --count HEAD..origin/main 2>/dev/null || printf 0)"
  printf '%s' "${n:-0}"
}

cel_version_lt() { # true when $1 is older than $2
  [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] \
    && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}
