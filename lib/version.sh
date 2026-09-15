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

cel_version_lt() { # true when $1 is older than $2
  [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] \
    && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}
