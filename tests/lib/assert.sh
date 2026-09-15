# shellcheck shell=bash
assert_eq() {
  [ "$1" = "$2" ] && return 0
  printf 'assert_eq failed\n  actual:   [%s]\n  expected: [%s]\n' "$1" "$2" >&2
  return 1
}

assert_contains() {
  case "$1" in *"$2"*) return 0;; esac
  printf 'assert_contains failed\n  haystack: [%s]\n  needle:   [%s]\n' "$1" "$2" >&2
  return 1
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    printf 'assert_fails: expected non-zero exit from: %s\n' "$*" >&2
    return 1
  fi
  return 0
}

fixture() { printf '%s' "$CEL_ROOT/tests/fixtures/$1"; }
