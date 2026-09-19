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

# A gate that was killed by `timeout` never reached a verdict. Recording that
# as `passed=false` sent a green branch back to a worker to fix code that was
# not broken - the plane's own suite grew past 600 s on a loaded box and the
# tail was all `ok` lines, cut off mid-run. "Ran out of time" and "the code is
# wrong" lead to opposite actions, so they must not render alike.
test_a_gate_killed_by_the_timeout_has_no_verdict() {
  _vrepo; _vcommit impl src/a.ts
  local out rc=0
  out="$("$VERIFY" "$T" --gate 'echo working; sleep 5' --gate-timeout 1)" || rc=$?
  assert_eq "$rc" 2
  assert_eq "$(_v .gate.passed)" null
  assert_eq "$(_v .gate.timed_out)" true
  assert_eq "$(_v .gate.timeout_secs)" 1
  assert_contains "$(_v .gate.tail)" "working"
  assert_contains "$(_v .gate.tail)" "killed after 1s - no verdict"
  assert_contains "$out" "gate:TIMEOUT(1s)"
  case "$out" in *gate:FAIL*) echo "a timeout rendered as FAIL"; rm -rf "$T"; return 1;; esac
  rm -rf "$T"
}
test_a_genuinely_failing_gate_still_exits_one() {
  _vrepo; _vcommit impl src/a.ts
  local rc=0
  "$VERIFY" "$T" --gate 'false' --quiet || rc=$?
  assert_eq "$rc" 1
  assert_eq "$(_v .gate.passed)" false
  assert_eq "$(_v .gate.timed_out)" false
  rm -rf "$T"
}
test_a_passing_gate_exits_zero() {
  _vrepo; _vcommit impl src/a.ts
  local rc=0
  "$VERIFY" "$T" --gate 'true' --quiet || rc=$?
  assert_eq "$rc" 0
  rm -rf "$T"
}
# The flag overrides the env var so one slow suite does not need the whole box
# reconfigured.
test_the_flag_overrides_the_env_var() {
  _vrepo; _vcommit impl src/a.ts
  local rc=0
  CEL_VERIFY_GATE_TIMEOUT=600 "$VERIFY" "$T" --gate 'sleep 5' --gate-timeout 1 --quiet || rc=$?
  assert_eq "$rc" 2
  assert_eq "$(_v .gate.timeout_secs)" 1
  rm -rf "$T"
}

# A GATE THAT IS KILLED MUST TAKE ITS CHILDREN WITH IT. The 2026-09-16 hang
# was seven test servers left running for a hundred minutes by a suite the
# verifier's timeout cut off mid-run. A single SIGTERM is not a kill: a node
# server with a shutdown handler, or anything that ignores TERM while it
# finishes, simply stays - reparented to init, still holding every descriptor
# it inherited, including the ledger lock of the collect that spawned the
# verifier. The gate therefore runs in its own process group and the timeout
# escalates to SIGKILL on that whole group.
test_a_timed_out_gate_leaves_no_background_children() {
  _vrepo; _vcommit impl src/a.ts
  local pidfile="$T/sleeper.pid" rc=0
  "$VERIFY" "$T" --gate "bash -c 'trap \"\" TERM; sleep 300' >/dev/null 2>&1 & echo \$! > '$pidfile'; sleep 30" \
    --gate-timeout 1 --quiet || rc=$?
  assert_eq "$rc" 2
  assert_eq "$(_v .gate.timed_out)" true
  local sleeper; sleeper="$(cat "$pidfile")"
  sleep 2
  local alive=0
  kill -0 "$sleeper" 2>/dev/null && { alive=1; kill -9 "$sleeper" 2>/dev/null; }
  rm -rf "$T"
  assert_eq "$alive" 0
}

# And the ordinary case is unchanged: a gate that finishes keeps its output
# and its exit code, own process group or not.
test_a_gate_in_its_own_group_still_reports_output_and_code() {
  _vrepo; _vcommit impl src/a.ts
  local rc=0
  "$VERIFY" "$T" --gate 'echo hello-from-gate; exit 3' --quiet || rc=$?
  assert_eq "$rc" 1
  assert_eq "$(_v .gate.passed)" false
  assert_contains "$(_v .gate.tail)" "hello-from-gate"
  rm -rf "$T"
}

# A GATE THAT WAITED ITS TURN IS NOT A GATE THAT TIMED OUT. The suite takes a
# box-wide lock (tests/suite-lock.test.sh), so on a busy box a verifier can sit
# for twenty minutes before its gate runs a single test. The --gate-timeout
# clock starts AFTER the lock is acquired, and the wait is recorded, so a slow
# verdict is explained rather than being read as a failure.
test_the_gate_queues_for_the_suite_lock_and_the_wait_is_not_a_timeout() {
  _vrepo; _vcommit impl src/a.ts
  local lock="$T/suite.lock"
  flock "$lock" -c 'sleep 3' &
  local holder=$!
  local i=0
  while flock -n "$lock" -c true >/dev/null 2>&1; do sleep 0.1; i=$((i + 1)); [ "$i" -lt 50 ] || break; done
  # a one-second timeout against a three-second wait: the gate itself is
  # instant, so anything but PASS here is the clock having started too early
  # -u: the suite running this test holds a lock of its own and says so; this
  # case is about a verifier that is the outermost thing on the box
  env -u CEL_SUITE_LOCK_HELD CEL_SUITE_LOCK="$lock" "$VERIFY" "$T" --gate 'true' --gate-timeout 1 --quiet
  wait "$holder" 2>/dev/null || true
  assert_eq "$(_v .gate.timed_out)" false
  assert_eq "$(_v .gate.passed)" true
  local waited; waited="$(_v .gate.waited_secs)"
  case "$waited" in
    ''|*[!0-9]*) printf 'the wait for the suite lock was not recorded: [%s]\n' "$waited"; rm -rf "$T"; return 1;;
  esac
  if [ "$waited" -lt 1 ]; then
    printf 'the wait for the suite lock was not recorded: [%s]s\n' "$waited"; rm -rf "$T"; return 1
  fi
  rm -rf "$T"
}

# Nobody holding it: no wait, and nothing about the verdict changes.
test_an_unheld_suite_lock_costs_the_gate_nothing() {
  _vrepo; _vcommit impl src/a.ts
  env -u CEL_SUITE_LOCK_HELD CEL_SUITE_LOCK="$T/suite.lock" "$VERIFY" "$T" --gate 'true' --quiet
  assert_eq "$(_v .gate.passed)" true
  assert_eq "$(_v .gate.waited_secs)" 0
  rm -rf "$T"
}

# cel-verify is usually called from INSIDE a suite (tests/fanout.test.sh runs
# collect, which runs it, which runs a gate). A lock its own caller is holding
# is a lock it must not wait for - that deadlock cancelled two CI jobs.
test_the_gate_does_not_queue_behind_a_lock_its_caller_holds() {
  _vrepo; _vcommit impl src/a.ts
  local lock="$T/suite.lock"
  ( flock 9; exec sleep 10 ) 9>>"$lock" &
  local holder=$!
  local i=0
  while flock -n "$lock" -c true >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); [ "$i" -lt 50 ] || break; done
  local rc=0
  CEL_SUITE_LOCK="$lock" CEL_SUITE_LOCK_HELD=1 timeout 20 "$VERIFY" "$T" --gate 'true' --quiet || rc=$?
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  assert_eq "$rc" 0
  assert_eq "$(_v .gate.passed)" true
  assert_eq "$(_v .gate.waited_secs)" 0
  rm -rf "$T"
}

# THE TIMEOUT WATCHDOG MUST NOT HOLD THE LOCK EITHER. On 2026-09-19 every gate
# on the box queued for eighteen minutes behind a `sleep 1800` with ppid 1:
# this verifier's watchdog sleep, orphaned when the gate finished early and the
# watchdog shell was killed, still holding the suite lock descriptor it had
# inherited. The gate's own children were already spawned with the descriptor
# closed; the watchdog was not, and a lock held by a stray sleep looks exactly
# like a lock in use.
test_the_gate_timeout_watchdog_does_not_keep_the_suite_lock() {
  _vrepo; _vcommit impl src/a.ts
  local lock="$T/suite.lock"
  env -u CEL_SUITE_LOCK_HELD CEL_SUITE_LOCK="$lock" "$VERIFY" "$T" --gate 'true' --gate-timeout 30 --quiet
  local i=0
  while ! flock -n "$lock" -c true >/dev/null 2>&1; do
    sleep 0.1; i=$((i + 1))
    [ "$i" -lt 20 ] || { echo "the suite lock outlived the verifier that took it"; rm -rf "$T"; return 1; }
  done
  rm -rf "$T"
}

# A gate that backgrounds a process does not hand it the box's suite lock: the
# gate and everything under it are inside the lock by ENVIRONMENT, never by
# descriptor.
test_a_process_the_gate_leaves_behind_does_not_hold_the_suite_lock() {
  _vrepo; _vcommit impl src/a.ts
  local lock="$T/suite.lock" pidfile="$T/sleeper.pid"
  env -u CEL_SUITE_LOCK_HELD CEL_SUITE_LOCK="$lock" "$VERIFY" "$T" \
    --gate "setsid sleep 30 >/dev/null 2>&1 & echo \$! > '$pidfile'" --gate-timeout 30 --quiet
  local sleeper; sleeper="$(cat "$pidfile")"
  local held=0
  ls -l "/proc/$sleeper/fd" 2>/dev/null | grep -q "suite.lock" && held=1
  kill -9 "$sleeper" 2>/dev/null || true
  rm -rf "$T"
  assert_eq "$held" 0
}
