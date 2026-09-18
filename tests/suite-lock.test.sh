# shellcheck shell=bash
# ONE SUITE AT A TIME ON THIS BOX. On 2026-09-18 six copies of tests/run.sh ran
# at once - four workers rebasing after a merge, one fixing a review finding,
# one finishing a build. Each suite forks yq, node and bun several hundred
# times; on six cores the load reached 190, swap filled, and every suite
# crawled past its timeout, so the workers were about to retry and make it
# worse. The worker cap bounds how many workers exist, not how many gates run.
# These tests prove the runner queues instead.
source "$CEL_ROOT/lib/common.sh"

# A miniature suite of its own: run.sh derives CEL_ROOT from its own path, so a
# copy under a fixture directory runs only the fixture's test files. Two
# seconds of sleep is the whole suite, which is what makes "did they overlap"
# a question a wall clock can answer.
_suite_fixture() {
  T="$(mktemp -d)"
  mkdir -p "$T/tests/lib"
  cp "$CEL_ROOT/tests/run.sh" "$T/tests/run.sh"
  cp "$CEL_ROOT/tests/lib/assert.sh" "$T/tests/lib/assert.sh"
  printf 'test_slow_thing() { sleep 2; }\n' > "$T/tests/slow.test.sh"
  export CEL_SUITE_LOCK="$T/suite.lock"
}

# Block until somebody holds the fixture lock, so a test never races the
# runner's own startup and calls a slow boot "did not take the lock".
_await_held() { # <path> [tries]
  local i=0 max="${2:-100}"
  while [ "$i" -lt "$max" ]; do
    flock -n "$1" -c true >/dev/null 2>&1 || return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
_await_free() { # <path> [tries]
  local i=0 max="${2:-100}"
  while [ "$i" -lt "$max" ]; do
    if flock -n "$1" -c true >/dev/null 2>&1; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# The whole point: two suites started together take about as long as running
# them one after the other, because that is exactly what happens. The second
# one says so rather than appearing hung.
test_a_second_suite_waits_for_the_first_and_says_so() {
  _suite_fixture
  local start; start="$(date +%s)"
  bash "$T/tests/run.sh" > "$T/out1" 2>&1 &
  local p1=$!
  _await_held "$CEL_SUITE_LOCK" || { echo "the first suite never took the lock"; rm -rf "$T"; return 1; }
  bash "$T/tests/run.sh" > "$T/out2" 2>&1 &
  local p2=$!
  wait "$p1"; wait "$p2"
  local elapsed=$(( $(date +%s) - start ))

  local second; second="$(cat "$T/out2")"
  assert_contains "$second" "waiting for the suite lock (held by pid"
  assert_contains "$second" "suite lock acquired after"
  assert_contains "$second" "1 passed, 0 failed"
  assert_contains "$(cat "$T/out1")" "1 passed, 0 failed"
  # sum, not max: two two-second suites cannot both be done in two seconds
  if [ "$elapsed" -lt 4 ]; then
    printf 'the two suites overlapped: %ss for two 2s suites\n' "$elapsed"; rm -rf "$T"; return 1
  fi
  rm -rf "$T"
}

# A lone run is not told anything about a lock nobody else wants.
test_a_lone_suite_says_nothing_about_the_lock() {
  _suite_fixture
  local out; out="$(bash "$T/tests/run.sh" 2>&1)"
  assert_contains "$out" "1 passed, 0 failed"
  case "$out" in *"suite lock"*) echo "a lone run narrated the lock"; rm -rf "$T"; return 1;; esac
  rm -rf "$T"
}

# --no-lock is for the test that tests the lock, and for a human who knows what
# they are doing. It runs while somebody else holds it.
test_no_lock_runs_while_the_lock_is_held() {
  _suite_fixture
  ( flock 9; exec sleep 10 ) 9>>"$CEL_SUITE_LOCK" &
  local holder=$!
  _await_held "$CEL_SUITE_LOCK" || { kill "$holder" 2>/dev/null; rm -rf "$T"; return 1; }
  local out; out="$(bash "$T/tests/run.sh" --no-lock 2>&1)"
  assert_contains "$out" "1 passed, 0 failed"
  case "$out" in *"waiting for the suite lock"*) echo "--no-lock still queued"; kill "$holder" 2>/dev/null; rm -rf "$T"; return 1;; esac
  # and so does the environment spelling of the same thing
  out="$(CEL_SUITE_LOCK=none bash "$T/tests/run.sh" 2>&1)"
  assert_contains "$out" "1 passed, 0 failed"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  rm -rf "$T"
}

# The lock is held by a descriptor, so process death frees it. No stale-lock
# handling, no PID file to clean up after a suite somebody interrupted.
test_a_killed_suite_frees_the_lock() {
  _suite_fixture
  bash "$T/tests/run.sh" > "$T/out" 2>&1 &
  local p=$!
  _await_held "$CEL_SUITE_LOCK" || { kill "$p" 2>/dev/null; rm -rf "$T"; return 1; }
  kill -TERM "$p" 2>/dev/null
  wait "$p" 2>/dev/null || true
  _await_free "$CEL_SUITE_LOCK" || { echo "the lock outlived the suite that held it"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The waiting line can name the holder because the holder wrote its pid and
# start time into the lock file after acquiring it.
test_the_lock_file_names_its_holder() {
  _suite_fixture
  bash "$T/tests/run.sh" > "$T/out" 2>&1 &
  local p=$!
  _await_held "$CEL_SUITE_LOCK" || { kill "$p" 2>/dev/null; rm -rf "$T"; return 1; }
  sleep 0.3
  local first; first="$(sed -n 1p "$CEL_SUITE_LOCK")"
  case "$first" in
    [0-9]*" "[0-9][0-9]:[0-9][0-9]) ;;
    *) printf 'lock file first line is not "<pid> <HH:MM>": [%s]\n' "$first"; kill "$p" 2>/dev/null; rm -rf "$T"; return 1;;
  esac
  wait "$p" 2>/dev/null || true
  rm -rf "$T"
}

# A filtered run still queues: a filter can still be most of the suite, and
# "it is only a few tests" is what everyone says while the load climbs.
test_a_filtered_run_still_takes_the_lock() {
  _suite_fixture
  printf 'test_slow_thing() { sleep 2; }\n' > "$T/tests/slow.test.sh"
  bash "$T/tests/run.sh" slow_thing > "$T/out1" 2>&1 &
  local p1=$!
  _await_held "$CEL_SUITE_LOCK" || { kill "$p1" 2>/dev/null; rm -rf "$T"; return 1; }
  local out; out="$(bash "$T/tests/run.sh" slow_thing 2>&1)"
  assert_contains "$out" "waiting for the suite lock (held by pid"
  wait "$p1" 2>/dev/null || true
  rm -rf "$T"
}

# RE-ENTRANT BY INHERITANCE, or the suite deadlocks on itself. CI found this
# the honest way: tests/fanout.test.sh runs `cel-fanout collect`, which runs
# cel-verify, which runs a gate - all of it INSIDE a suite that is already
# holding the lock. Inner and outer compute the same path (no XDG_RUNTIME_DIR
# on the runner), so the suite waited twenty minutes for itself and the job was
# cancelled. Anything started under a held lock is already inside it: the
# holder exports CEL_SUITE_LOCK_HELD, and everything that would otherwise queue
# reads that and goes straight through.
test_a_suite_started_inside_a_held_lock_does_not_wait() {
  _suite_fixture
  rm -f "$T/tests/slow.test.sh"
  # a filter that matches nothing: this is about the lock, not about tests.
  # timeout, because the failure being guarded against is an infinite wait
  printf 'test_inner_run_goes_straight_through() { timeout 15 bash "%s/tests/run.sh" zzz_matches_nothing > "%s/inner.out" 2>&1; }\n' \
    "$T" "$T" > "$T/tests/inner.test.sh"
  local out; out="$(bash "$T/tests/run.sh" 2>&1)"
  assert_contains "$out" "1 passed, 0 failed"
  local inner; inner="$(cat "$T/inner.out")"
  assert_contains "$inner" "0 passed, 0 failed"
  case "$inner" in *"waiting for the suite lock"*) echo "the suite queued behind itself"; rm -rf "$T"; return 1;; esac
  rm -rf "$T"
}

# ...and the holder says so in the environment, which is the whole mechanism.
test_the_holder_exports_the_lock_it_holds() {
  _suite_fixture
  rm -f "$T/tests/slow.test.sh"
  printf 'test_env_carries_the_lock() { printf "%%s %%s\\n" "${CEL_SUITE_LOCK_HELD:-unset}" "${CEL_SUITE_LOCK:-unset}" > "%s/env.out"; }\n' \
    "$T" > "$T/tests/env.test.sh"
  bash "$T/tests/run.sh" >/dev/null 2>&1
  assert_eq "$(cat "$T/env.out")" "1 $T/suite.lock"
  rm -rf "$T"
}
