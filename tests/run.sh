#!/usr/bin/env bash
# Zero-dependency test runner. Each test function runs in its own bash process,
# so a test that sets a global or exits cannot affect its neighbours.
#
#   tests/run.sh              run everything
#   tests/run.sh expand       run tests whose name contains "expand"
#
# A file that fails to source is reported as a failure, never skipped: a suite
# that can silently run nothing is worse than no suite at all.
set -uo pipefail

CEL_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export CEL_ROOT
FILTER="${1:-}"

# Put every fixture under one per-run directory and remove it on exit or
# interruption. Individual tests can fail before their own cleanup; retaining
# whole temporary Git repositories across runs would exhaust temporary storage.
export TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/cel-tests.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT
trap 'rm -rf "$TMPDIR"; exit 130' INT TERM
PRELUDE="set -e; source '$CEL_ROOT/tests/lib/assert.sh'"
pass=0; fail=0

for f in "$CEL_ROOT"/tests/*.test.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"

  if ! err="$(bash -c "$PRELUDE; source '$f'" 2>&1)"; then
    fail=$((fail+1))
    printf '  \033[31mFAIL\033[0m %s (could not be sourced)\n%s\n' \
      "$base" "$(printf '%s' "$err" | sed 's/^/       /')"
    continue
  fi

  names="$(bash -c "$PRELUDE; source '$f'; declare -F | awk '{print \$3}' | grep '^test_'")"
  if [ -z "$names" ]; then
    fail=$((fail+1))
    printf '  \033[31mFAIL\033[0m %s (defines no test_ functions)\n' "$base"
    continue
  fi

  for t in $names; do
    if [ -n "$FILTER" ]; then case "$t" in *"$FILTER"*) ;; *) continue;; esac; fi
    if out="$(bash -c "$PRELUDE; source '$f'; $t" 2>&1)"; then
      pass=$((pass+1)); printf '  \033[32mok\033[0m   %s\n' "$t"
    else
      fail=$((fail+1))
      printf '  \033[31mFAIL\033[0m %s\n%s\n' "$t" "$(printf '%s' "$out" | sed 's/^/       /')"
    fi
  done
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
