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
  # The suite that runs THIS test is itself holding a lock and says so in the
  # environment. Here that inheritance is exactly what is being tested, so the
  # fixture runner starts as an outermost run would.
  unset CEL_SUITE_LOCK_HELD
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
  # The holder outlives the test and is killed by it. It was `sleep 10`, and
  # on a box at load 37 the two runs below took longer than that: the holder
  # was gone, the second run proved nothing, and the final `kill` of a dead pid
  # failed under set -e - a silent FAIL with no message, on clean main (CEL-97).
  ( flock 9; exec sleep 600 ) 9>>"$CEL_SUITE_LOCK" &
  local holder=$!
  _await_held "$CEL_SUITE_LOCK" || { echo "the fixture holder never took the lock"; kill "$holder" 2>/dev/null; rm -rf "$T"; return 1; }
  local out; out="$(bash "$T/tests/run.sh" --no-lock 2>&1)"
  assert_contains "$out" "1 passed, 0 failed"
  case "$out" in *"waiting for the suite lock"*) echo "--no-lock still queued"; kill "$holder" 2>/dev/null; rm -rf "$T"; return 1;; esac
  # and so does the environment spelling of the same thing
  _await_held "$CEL_SUITE_LOCK" 1 || { echo "the lock was released before the second run - it would prove nothing"; kill "$holder" 2>/dev/null; rm -rf "$T"; return 1; }
  out="$(CEL_SUITE_LOCK=none bash "$T/tests/run.sh" 2>&1)"
  assert_contains "$out" "1 passed, 0 failed"
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
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

# A LEAKED PROCESS MUST NOT LEAK THE LOCK WITH IT. This runner already tolerates
# tests that leave a setsid process behind - that is why it kills process
# groups - but such a process inherits every descriptor, and one of them is now
# the box's suite lock. Held by an orphan, it blocks every gate on the box long
# after the run that produced it has finished, which is exactly the outage this
# ticket set out to prevent.
test_a_leaked_test_process_does_not_keep_the_lock() {
  _suite_fixture
  rm -f "$T/tests/slow.test.sh"
  printf 'test_leaks_a_process() { setsid sleep 30 >/dev/null 2>&1 & }\n' > "$T/tests/leak.test.sh"
  bash "$T/tests/run.sh" >/dev/null 2>&1
  _await_free "$CEL_SUITE_LOCK" 20 || { echo "an orphan kept the suite lock"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A LOCK ON A DESCRIPTOR IS HELD BY EVERY CHILD THAT INHERITS IT. On
# 2026-09-19, hours after the lock landed, every gate on the box queued behind
# it for eighteen minutes and the holder was a `sleep 1800` with ppid 1: a
# background process that had inherited the runner's lock descriptor and kept
# the lock alive long after the runner was gone. This is CEL-12's ledger-lock
# bug in a second place - bash cannot mark a descriptor close-on-exec, so every
# child the runner starts must be spawned with the descriptor closed. The
# runner starts children before it ever reaches a test: it sources each file to
# check it, and again to list its test functions.
test_a_process_leaked_before_the_tests_run_does_not_keep_the_lock() {
  _suite_fixture
  rm -f "$T/tests/slow.test.sh"
  # backgrounded at SOURCE time, so it is a child of the runner's own
  # source-check and function-listing shells, not of any test
  printf 'setsid sleep 30 >/dev/null 2>&1 &\ntest_nothing() { :; }\n' > "$T/tests/src.test.sh"
  bash "$T/tests/run.sh" >/dev/null 2>&1
  _await_free "$CEL_SUITE_LOCK" 20 || { echo "a process the runner started kept the suite lock"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The first line names the holder well enough to go and look: pid, the time it
# started, and the directory it is running in. Sixteen agent sessions on a box
# is too many for "pid 972217" on its own to mean anything.
test_the_lock_file_names_its_holders_pid_time_and_cwd() {
  _suite_fixture
  ( cd "$T" && bash "$T/tests/run.sh" > "$T/out" 2>&1 ) &
  local p=$!
  _await_held "$CEL_SUITE_LOCK" || { kill "$p" 2>/dev/null; rm -rf "$T"; return 1; }
  sleep 0.3
  local first; first="$(sed -n 1p "$CEL_SUITE_LOCK")"
  case "$first" in
    [0-9]*" "[0-9][0-9]:[0-9][0-9]" "/*) ;;
    *) printf 'lock file first line is not "<pid> <HH:MM> <cwd>": [%s]\n' "$first"; kill "$p" 2>/dev/null; rm -rf "$T"; return 1;;
  esac
  assert_contains "$first" "$T"
  wait "$p" 2>/dev/null || true
  rm -rf "$T"
}

# A wait that has gone on long enough to be a problem says who to go and ask.
# The one-line "waiting" notice is printed once at the start and then the run
# is silent; after CEL_SUITE_WAIT_WARN seconds it says it again, with the
# holder's directory, so an operator does not have to read the lock file.
test_a_long_wait_names_the_live_holder() {
  _suite_fixture
  ( flock 9; printf '%s 03:04 /tmp/a-checkout\n' "$BASHPID" > "$CEL_SUITE_LOCK"; exec sleep 4 ) 9>>"$CEL_SUITE_LOCK" &
  local holder=$!
  _await_held "$CEL_SUITE_LOCK" || { kill "$holder" 2>/dev/null; rm -rf "$T"; return 1; }
  local out; out="$(CEL_SUITE_WAIT_WARN=1 bash "$T/tests/run.sh" 2>&1)"
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  assert_contains "$out" "still waiting for the suite lock - held by pid"
  assert_contains "$out" "since 03:04 (/tmp/a-checkout)"
  rm -rf "$T"
}

# And when the pid in the file is gone, the lock is held by something that
# inherited the descriptor - the 2026-09-19 outage exactly. Saying "leaked"
# rather than naming a process that no longer exists is the difference between
# an operator waiting and an operator fixing it.
test_a_long_wait_says_when_the_recorded_holder_is_dead() {
  _suite_fixture
  ( flock 9; printf '4194303 03:04 /tmp/a-checkout\n' > "$CEL_SUITE_LOCK"; exec sleep 4 ) 9>>"$CEL_SUITE_LOCK" &
  local holder=$!
  _await_held "$CEL_SUITE_LOCK" || { kill "$holder" 2>/dev/null; rm -rf "$T"; return 1; }
  local out; out="$(CEL_SUITE_WAIT_WARN=1 bash "$T/tests/run.sh" 2>&1)"
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  assert_contains "$out" "still waiting for the suite lock - held by a dead pid 4194303 - the lock leaked; see cel doctor"
  rm -rf "$T"
}

# `cel doctor` is where a box-wide problem gets named, and a leaked suite lock
# is box-wide: it blocks every gate on the box. It is a leak when the recorded
# holder is gone, or is running somewhere that is not a checkout - a suite runs
# from inside one, a `sleep` that inherited the descriptor does not.
test_doctor_names_a_leaked_suite_lock_and_nothing_else() {
  source "$CEL_ROOT/lib/doctor.sh"
  T="$(mktemp -d)"
  export CEL_SUITE_LOCK="$T/suite.lock"
  : > "$CEL_SUITE_LOCK"
  assert_eq "$(doctor_suite_lock_line)" ""

  ( flock 9; exec sleep 5 ) 9>>"$CEL_SUITE_LOCK" &
  local holder=$!
  _await_held "$CEL_SUITE_LOCK" || { kill "$holder" 2>/dev/null; rm -rf "$T"; return 1; }
  printf '4194303 03:04 /tmp/a-checkout\n' > "$CEL_SUITE_LOCK"
  local line; line="$(doctor_suite_lock_line)"
  assert_contains "$line" "suite lock leaked (pid 4194303"
  assert_contains "$line" "cel gc --orphans"
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true

  # a live runner, in a checkout, holding it for as long as its suite takes:
  # that is the lock working, and doctor says nothing about it
  ( cd "$CEL_ROOT" && flock 9 && printf '%s 03:04 %s\n' "$BASHPID" "$CEL_ROOT" > "$CEL_SUITE_LOCK" && exec sleep 5 ) 9>>"$CEL_SUITE_LOCK" &
  holder=$!
  _await_held "$CEL_SUITE_LOCK" || { kill "$holder" 2>/dev/null; rm -rf "$T"; return 1; }
  sleep 0.2
  assert_eq "$(doctor_suite_lock_line)" ""
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  unset CEL_SUITE_LOCK
  rm -rf "$T"
}

# ---- CEL-97: one test cannot hold the box ------------------------------------
# On 2026-10-04 the suite lock was held for eighty minutes by one run stuck in
# a single test whose server child never exited; two workers' suites and a land
# queued behind it. Each test now has a wall limit, and its whole process group
# - the servers it started included - goes when the limit does.
test_a_test_past_its_wall_limit_is_a_timeout_and_its_children_go() {
  _suite_fixture
  rm -f "$T/tests/slow.test.sh"
  cat > "$T/tests/hang.test.sh" <<EOF
test_a_hangs() { sleep 300 & echo \$! > "$T/child.pid"; sleep 300; }
test_b_runs_after() { :; }
EOF
  local out rc=0 t0; t0="$(date +%s)"
  out="$(CEL_TEST_TIMEOUT=2 bash "$T/tests/run.sh" --no-lock 2>&1)" || rc=$?
  [ "$(( $(date +%s) - t0 ))" -lt 30 ] || { echo "the limit did not bound the test"; rm -rf "$T"; return 1; }
  [ "$rc" -ne 0 ] || { echo "a timed-out test passed the suite"; rm -rf "$T"; return 1; }
  assert_contains "$out" "test_a_hangs"
  assert_contains "$out" "timed out after 2s"
  assert_contains "$out" "test_b_runs_after"
  assert_contains "$out" "1 passed, 1 failed"
  local pid; pid="$(cat "$T/child.pid")"
  sleep 0.5
  ! kill -0 "$pid" 2>/dev/null || { echo "the hung test's child survived"; kill "$pid"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Files run in parallel must reach the same verdicts as one after another.
test_a_parallel_run_reports_the_same_results_as_a_serial_one() {
  _suite_fixture
  rm -f "$T/tests/slow.test.sh"
  local n
  for n in 1 2 3 4 5; do
    printf 'test_f%s_passes() { sleep 0.2; }\ntest_f%s_fails() { false; }\n' "$n" "$n" > "$T/tests/f$n.test.sh"
  done
  local serial parallel
  serial="$(CEL_TEST_JOBS=1 bash "$T/tests/run.sh" --no-lock 2>&1 | grep -E 'ok|FAIL|passed' | sort)"
  parallel="$(CEL_TEST_JOBS=4 bash "$T/tests/run.sh" --no-lock 2>&1 | grep -E 'ok|FAIL|passed' | sort)"
  assert_contains "$serial" "5 passed, 5 failed"
  assert_eq "$parallel" "$serial"
  rm -rf "$T"
}

# ---- CEL-100: the watchdog does not outlive its test --------------------------
# On 2026-10-04 one worker's suite left 385 `sleep 120` processes on PID 1: the
# watchdog's bash was killed when its test finished, its sleep was not. A run
# with a unique limit is the marker - after it, no sleep of that length remains.
test_quick_tests_leave_no_watchdog_sleep_behind() {
  _suite_fixture
  rm -f "$T/tests/slow.test.sh"
  # Many instant tests across parallel files: a test that ends before its
  # watchdog has even started is the race CI hit on a3f687d.
  local f i
  for f in 1 2 3 4; do
    for i in $(seq 1 15); do printf 'test_q%s_%s() { :; }\n' "$f" "$i"; done > "$T/tests/quick$f.test.sh"
  done
  local limit=4917 out
  out="$(CEL_TEST_JOBS=4 CEL_TEST_TIMEOUT=$limit bash "$T/tests/run.sh" --no-lock 2>&1)" || true
  assert_contains "$out" "60 passed"
  # Bounded: a group already signalled may take a moment to be reaped.
  i=0; while pgrep -fx "sleep $limit" >/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i+1)); done
  local left; left="$(pgrep -fx "sleep $limit" | wc -l)"
  pkill -fx "sleep $limit" 2>/dev/null || true
  assert_eq "$left" "0"
  rm -rf "$T"
}
