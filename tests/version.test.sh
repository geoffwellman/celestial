# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/version.sh"

test_version_compare() {
  cel_version_lt 0.1.0 0.2.0
  cel_version_lt 0.9.0 0.10.0
  assert_fails cel_version_lt 0.2.0 0.2.0
  assert_fails cel_version_lt 1.0.0 0.9.9
  assert_fails cel_version_lt "" 1.0.0
}

# The owner, 2026-09-18: "I don't think we should rely on just the version -
# what about commits in between new versions?" A box that tracks main sits
# thirty-odd merges past the newest tag and every surface said "up to date",
# so the build string carries the distance from the tag, the sha and the
# branch - `+31` is the thing people quote at each other.
_ver_fixture() { # -> T, ROOT; CEL_ROOT points at the fake
  T="$(mktemp -d)"
  ROOT="$T/root"
  git init -q -b main "$ROOT"
  git -C "$ROOT" config user.email t@example.com
  git -C "$ROOT" config user.name tester
  printf '0.2.0\n' >"$ROOT/VERSION"
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -qm 'release 0.2.0'
  git -C "$ROOT" tag v0.2.0
  export CEL_ROOT="$ROOT"
}

test_version_build_counts_commits_since_the_tag() {
  local keep="$CEL_ROOT"
  _ver_fixture
  assert_eq "$(cel_build_version)" "0.2.0+0" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }
  assert_eq "$(cel_build_branch)" "main" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }

  printf 'later\n' >"$ROOT/AFTER"
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -qm 'after the release'
  assert_eq "$(cel_build_version)" "0.2.0+1" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }
  assert_eq "$(cel_build_sha)" "$(git -C "$ROOT" rev-parse --short HEAD)" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }
  assert_contains "$(cel_build_line)" "v0.2.0+1 (" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }
  assert_contains "$(cel_build_line)" ", main)" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }

  CEL_ROOT="$keep"
  rm -rf "$T"

  # and the command people actually run says the same thing about this box
  local out; out="$("$CEL_ROOT/bin/cel" version)"
  assert_contains "$out" "celestial v$(cel_version)+" || return 1
  assert_contains "$out" ", $(cel_build_branch))" || return 1
}
