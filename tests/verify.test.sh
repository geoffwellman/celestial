# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
VERIFY="$CEL_ROOT/core/skills/verify/bin/cel-verify"

# A verdict is facts about a branch, one per dimension, written as JSON so the
# mechanism can refuse on it - not a prose review someone has to read.

_vrepo() { # a repo with origin/main and a branch; commits appended by the test
  T="$(mktemp -d)"
  git -C "$T" init -q -b main
  git -C "$T" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T" update-ref refs/remotes/origin/main HEAD
  git -C "$T" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$T" checkout -q -b WG-1-feature
}
_vcommit() { # <msg> <files...>
  local msg="$1"; shift
  local f; for f in "$@"; do mkdir -p "$T/$(dirname "$f")"; printf 'x\n' >> "$T/$f"; done
  git -C "$T" add -A; git -C "$T" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}
_v() { jq -r "$1" "$T/.agent/verdict.json"; }

test_gate_passes_and_fails_by_exit_code() {
  _vrepo; _vcommit impl src/a.ts
  "$VERIFY" "$T" --gate 'true' --quiet
  assert_eq "$(_v .gate.configured)" true; assert_eq "$(_v .gate.passed)" true
  "$VERIFY" "$T" --gate 'echo boom; false' --quiet && { echo "failing gate exited 0"; rm -rf "$T"; return 1; }
  assert_eq "$(_v .gate.passed)" false
  assert_contains "$(_v .gate.tail)" "boom"
  rm -rf "$T"
}
test_no_gate_is_recorded_as_unconfigured_not_failed() {
  _vrepo; _vcommit impl src/a.ts
  "$VERIFY" "$T" --quiet
  assert_eq "$(_v .gate.configured)" false; assert_eq "$(_v .gate.passed)" null
  rm -rf "$T"
}
# Red then green: a test-only commit before the first source commit.
test_red_then_green_is_detected_from_commit_order() {
  _vrepo
  _vcommit "failing test" src/a.test.ts
  _vcommit "make it pass" src/a.ts
  "$VERIFY" "$T" --quiet
  assert_eq "$(_v .tests.red_then_green)" true
  assert_contains "$(_v .tests.detail)" "test-only commit #1"
  rm -rf "$T"
}
test_tests_after_implementation_are_recorded_as_such() {
  _vrepo
  _vcommit impl src/a.ts
  _vcommit "add tests" src/a.test.ts
  "$VERIFY" "$T" --quiet
  assert_eq "$(_v .tests.red_then_green)" false
  rm -rf "$T"
}
test_tests_in_the_same_commit_as_code_are_not_red_then_green() {
  _vrepo
  _vcommit "impl and tests together" src/a.ts src/a.test.ts
  "$VERIFY" "$T" --quiet
  assert_eq "$(_v .tests.red_then_green)" false
  rm -rf "$T"
}
test_no_test_files_is_null_not_false() {
  _vrepo; _vcommit impl src/a.ts src/b.ts
  "$VERIFY" "$T" --quiet
  assert_eq "$(_v .tests.red_then_green)" null
  assert_eq "$(_v .diff.files)" 2
  rm -rf "$T"
}
test_summary_line_reads_as_a_verdict() {
  _vrepo; _vcommit t src/a.test.ts; _vcommit i src/a.ts
  local out; out="$("$VERIFY" "$T" --gate true)"
  assert_contains "$out" "verdict gate:PASS"
  assert_contains "$out" "red-green:yes"
  rm -rf "$T"
}
