# shellcheck shell=bash

test_reviewer_native_retirement_permission_transitions() {
  node --test "$CEL_ROOT/tools/hooks/reviewer-retirement.test.mjs"
}

test_reviewer_retirement_native_round_and_receipt_invariants() {
  node --test "$CEL_ROOT/tools/reviewers/retire.test.mjs"
}
