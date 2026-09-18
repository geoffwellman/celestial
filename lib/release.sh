# shellcheck shell=bash
# `cel release` - a thin wrapper over the release workflow, not a second
# implementation of it.
#
# The order is not a preference, it is what branch protection permits: main
# takes no direct pushes, so the version bump arrives as a PR like any other
# change, the tag can only follow its squash merge, and the GitHub Release is
# cut from the tag by the action. Everything therefore happens on GitHub; this
# command only dispatches the workflow and reports, so the laptop needs a
# browser or `gh`, never a working box.
#
# What it does do locally is refuse a version that cannot possibly be right -
# a non-semver or not-greater version dispatched by hand costs a run, a red
# check and an explanation, and the mistake is free to catch here.
[ -n "${_CEL_RELEASE:-}" ] && return 0
_CEL_RELEASE=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/version.sh
. "$(dirname "${BASH_SOURCE[0]}")/version.sh"

_release_workflow() { printf 'release.yml'; }
_release_notes() { python3 "$CEL_ROOT/tools/release/notes.py" "$@" --changelog "$CEL_ROOT/CHANGELOG.md"; }

_release_is_semver() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

# The same two refusals the action makes, made before a run is spent.
_release_require_version() { # <version>
  local v="$1" cur
  [ -n "$v" ] || die "cel release: want a version, e.g. cel release 0.3.0"
  _release_is_semver "$v" || die "cel release: '$v' is not a semver x.y.z version (no leading v)"
  cur="$(cel_version)"
  cel_version_lt "$cur" "$v" || die "cel release: $v is not greater than the current $cur"
  return 0
}

_release_dry_run() { # <version>
  local section
  section="$(_release_notes unreleased)" || die "cel release: could not read the [Unreleased] section"
  [ -n "$section" ] || die "cel release: the [Unreleased] section is empty - nothing to release"
  c_hd "celestial v$1 would ship"
  printf '%s\n' "$section"
  c_hd "the Cut job will check"
  printf '  %s\n' \
    'publication hygiene over all history (tools/release/hygiene.py --all-history)' \
    'the private vocabulary scan from the CEL_PRIVATE_PATTERNS secret' \
    'the regression suite, as every pull request does' \
    "semver: $1 greater than $(cel_version), and a non-empty [Unreleased] section"
  printf '\n  nothing was dispatched (--dry-run); the PR, tag and Release follow the run.\n'
  return 0
}

_release_status() {
  have gh || die "cel release status: gh is required"
  local pr tag
  pr="$(gh pr list --state open --search 'release: in:title' \
        --json number,title,url --jq '.[] | "#\(.number) \(.title) \(.url)"' 2>/dev/null)" || pr=""
  c_hd "Release"
  if [ -n "$pr" ]; then printf '  open PR   %s\n' "$pr"; else printf '  open PR   none\n'; fi
  tag="$(gh release list --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null)" || tag=""
  # gh is the announcement channel, git is the truth; offline, the tags this
  # clone already fetched still answer "what is the newest release".
  [ -n "$tag" ] || tag="$(git -C "$CEL_ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  if [ -n "$tag" ]; then printf '  newest    %s\n' "$tag"; else printf '  newest    no release tag\n'; fi
  printf '  installed v%s\n' "$(cel_version)"
  return 0
}

cmd_release() { # <version> [--dry-run] | status
  local version="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      status)    shift; _release_status "$@"; return $? ;;
      --dry-run) dry=1; shift ;;
      -*)        die "cel release: unknown argument '$1' (want <version> [--dry-run] or status)" ;;
      *)         [ -z "$version" ] || die "cel release: one version at a time"; version="$1"; shift ;;
    esac
  done
  _release_require_version "$version"
  if [ "$dry" -eq 1 ]; then _release_dry_run "$version"; return $?; fi

  have gh || die "cel release: gh is required to dispatch the workflow"
  gh workflow run "$(_release_workflow)" -f "version=$version" \
    || die "cel release: could not dispatch $(_release_workflow)"
  c_ok "dispatched the Cut job for v$version"
  local url
  url="$(gh run list --workflow "$(_release_workflow)" --limit 1 --json url --jq '.[0].url' 2>/dev/null)" || url=""
  if [ -n "$url" ]; then
    printf '  %s\n' "$url"
  else
    printf '  the run is queued; watch it with: gh run list --workflow %s\n' "$(_release_workflow)"
  fi
  printf '  merge the PR it opens; the tag and the GitHub Release follow on their own.\n'
  return 0
}
