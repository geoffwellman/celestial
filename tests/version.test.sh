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
