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
  "$VERIFY" "$T" --gate 'echo boom; false' --quiet && { echo "failing gate exited 0"; rm -rf "$T" "$ART"; return 1; }
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
  case "$out" in *gate:FAIL*) echo "a timeout rendered as FAIL"; rm -rf "$T" "$ART"; return 1;; esac
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
    ''|*[!0-9]*) printf 'the wait for the suite lock was not recorded: [%s]\n' "$waited"; rm -rf "$T" "$ART"; return 1;;
  esac
  if [ "$waited" -lt 1 ]; then
    printf 'the wait for the suite lock was not recorded: [%s]s\n' "$waited"; rm -rf "$T" "$ART"; return 1
  fi
  rm -rf "$T"
}

# CEL-97: land's --gate-timeout must bound the whole wait, lock included. With
# --lock-in-timeout a lock held past the timeout is a timeout - no verdict -
# and the gate never starts.
test_lock_in_timeout_counts_the_lock_wait_against_the_gate() {
  _vrepo; _vcommit impl src/a.ts
  local lock="$T/suite.lock"
  flock "$lock" -c 'sleep 4' &
  local holder=$!
  local i=0
  while flock -n "$lock" -c true >/dev/null 2>&1; do sleep 0.1; i=$((i + 1)); [ "$i" -lt 50 ] || break; done
  local rc=0
  env -u CEL_SUITE_LOCK_HELD CEL_SUITE_LOCK="$lock" "$VERIFY" "$T" --gate "touch '$T/gate-ran'" \
    --gate-timeout 1 --lock-in-timeout --quiet || rc=$?
  wait "$holder" 2>/dev/null || true
  assert_eq "$rc" 2
  assert_eq "$(_v .gate.timed_out)" true
  assert_contains "$(_v .gate.tail)" "suite lock"
  [ ! -e "$T/gate-ran" ] || { echo "the gate ran after its time was spent waiting"; rm -rf "$T" "$ART"; return 1; }
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
    [ "$i" -lt 20 ] || { echo "the suite lock outlived the verifier that took it"; rm -rf "$T" "$ART"; return 1; }
  done
  rm -rf "$T"
}

# ---- a gate that produced NO VERDICT is not a gate that failed ---------------
# Measured on 2026-09-21: `cel-fanout land` on an approved, CI-green branch
# refused with "the repo's gate did not pass (verdict: unknown)" while the same
# suite run by hand in the same worktree passed. The verdict said
# `timed_out:false`, no output at all, and `passed:false` - so the timeout arm,
# which exists precisely so that "no verdict" does not read as "the code is
# wrong", never applied. The gate had been killed by a signal: `wait` returned
# 128+n, which fell through to the `*)` arm and was recorded as a failure.
#
# A process that died without ever reporting a status did not fail. It said
# nothing, and a worker sent to fix code that was never shown to be wrong is
# the exact confusion this file's own comments exist to prevent. Four outcomes,
# not three: pass, fail, timed out, and produced no verdict.
test_a_gate_killed_by_a_signal_has_no_verdict_rather_than_failing() {
  _vrepo; _vcommit impl src/a.ts
  local out rc=0
  # the honest reproduction: a gate that tears down its own process group, the
  # way tests/run.sh's cleanup does when the gate IS the group leader.
  out="$("$VERIFY" "$T" --gate 'kill -TERM -- -$$')" || rc=$?
  assert_eq "$rc" 3
  assert_eq "$(_v .gate.outcome)" no_verdict
  assert_eq "$(_v .gate.passed)" null
  assert_eq "$(_v .gate.code)" null
  assert_eq "$(_v .gate.timed_out)" false
  assert_contains "$(_v .gate.no_verdict_reason)" "SIGTERM"
  assert_contains "$out" "gate:NO-VERDICT"
  case "$out" in *gate:FAIL*) echo "a gate that said nothing rendered as FAIL"; rm -rf "$T" "$ART"; return 1;; esac
  rm -rf "$T"
}

# A GATE THAT PRINTED NOTHING IS ITSELF A FINDING. The verdict above stored
# `tail: ""` and moved on, so the one visible signature of the bug - a gate
# with no output and no exit code - was in the record and said nothing to
# anyone reading it.
test_a_gate_that_printed_nothing_says_so_rather_than_storing_an_empty_tail() {
  _vrepo; _vcommit impl src/a.ts
  local rc=0
  "$VERIFY" "$T" --gate 'exit 4' --quiet || rc=$?
  assert_eq "$rc" 1
  assert_eq "$(_v .gate.output_empty)" true
  assert_contains "$(_v .gate.tail)" "no output"
  "$VERIFY" "$T" --gate 'echo something' --quiet
  assert_eq "$(_v .gate.output_empty)" false
  rm -rf "$T"
}

# THE MEETING POINT THE BUG LIVED IN. The repo's real runner, under this
# verifier, as the gate: the verifier gives the gate its own session so a
# timeout can kill the whole group, and the runner kills process groups of its
# own on the way out so a killed suite leaves no servers behind (it also sweeps
# processes still standing in its temporary directory). Both protections exist
# for named incidents and both stay. What must not happen is that their meeting
# costs the run its answer: a suite that has printed "N passed, M failed" has
# answered, and that answer is now written down by the gate itself at the
# moment it exists, rather than surviving only as the exit status of a process
# that a group teardown can signal.
test_the_repos_runner_as_the_gate_always_reaches_a_verdict() {
  _vrepo; _vcommit impl src/a.ts
  mkdir -p "$T/tests/lib"
  cp "$CEL_ROOT/tests/run.sh" "$T/tests/run.sh"
  cp "$CEL_ROOT/tests/lib/assert.sh" "$T/tests/lib/assert.sh"
  # one ordinary test and one that leaks a process out of its own group, which
  # is exactly what the runner's stray sweep exists for
  cat > "$T/tests/mini.test.sh" <<'MINI'
test_one_real_thing() { assert_eq 1 1; }
test_leaves_a_stray_behind() { cd "$TMPDIR"; setsid sleep 60 >/dev/null 2>&1 & assert_eq 1 1; }
MINI
  local rc=0
  env -u CEL_SUITE_LOCK_HELD CEL_SUITE_LOCK="$T/suite.lock" \
    "$VERIFY" "$T" --gate 'bash tests/run.sh' --gate-timeout 120 --quiet || rc=$?
  assert_eq "$(_v .gate.outcome)" pass
  assert_eq "$(_v .gate.passed)" true
  assert_eq "$(_v .gate.code)" 0
  assert_eq "$rc" 0
  assert_contains "$(_v .gate.tail)" "2 passed, 0 failed"
  rm -rf "$T"
}

# A suite that was killed WHILE RUNNING has no answer, and the exit status of
# whatever ran last inside it is not one: a gate that tore its own process
# group down must not be read as the pass of its final builtin.
test_a_suite_killed_mid_run_is_no_verdict_not_a_pass() {
  _vrepo; _vcommit impl src/a.ts
  local rc=0
  "$VERIFY" "$T" --gate 'echo starting; kill -TERM -- -$$; sleep 5' --quiet || rc=$?
  assert_eq "$rc" 3
  assert_eq "$(_v .gate.outcome)" no_verdict
  assert_eq "$(_v .gate.passed)" null
  assert_contains "$(_v .gate.tail)" "starting"
  rm -rf "$T"
}

# And the three that already existed stay distinct from the fourth: a timeout
# is a timeout, not a no-verdict, because the operator's next move differs
# (more time, versus find out what killed it).
test_a_timeout_is_recorded_as_a_timeout_and_not_as_no_verdict() {
  _vrepo; _vcommit impl src/a.ts
  local rc=0
  "$VERIFY" "$T" --gate 'echo working; sleep 5' --gate-timeout 1 --quiet || rc=$?
  assert_eq "$rc" 2
  assert_eq "$(_v .gate.outcome)" timeout
  assert_eq "$(_v .gate.timed_out)" true
  rm -rf "$T"
}
test_a_passing_and_a_failing_gate_record_their_exit_code() {
  _vrepo; _vcommit impl src/a.ts
  "$VERIFY" "$T" --gate 'true' --quiet
  assert_eq "$(_v .gate.outcome)" pass
  assert_eq "$(_v .gate.code)" 0
  local rc=0
  "$VERIFY" "$T" --gate 'echo boom; exit 7' --quiet || rc=$?
  assert_eq "$rc" 1
  assert_eq "$(_v .gate.outcome)" fail
  assert_eq "$(_v .gate.code)" 7
  assert_eq "$(_v .gate.no_verdict_reason)" null
  rm -rf "$T"
}
test_no_gate_at_all_is_not_a_no_verdict() {
  _vrepo; _vcommit impl src/a.ts
  "$VERIFY" "$T" --quiet
  assert_eq "$(_v .gate.outcome)" none
  assert_eq "$(_v .gate.code)" null
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

# ------------------------------------------------ AH-261018: full gate evidence
# A downstream repository's canonical verification failed (exit 1) and the verifier kept only the
# last 12 lines and DELETED the rest: the failing test's identity was
# irretrievable. The complete output is now a private durable artifact bound to
# the attempt and the head, recorded in the verdict next to the exact exit.
_vev() { # a repo plus an isolated artifact root
  _vrepo; _vcommit impl src/a.ts
  # OUTSIDE the repo: an artifact root inside a git work tree is refused
  ART="$(mktemp -d)"; chmod 700 "$ART"; export CEL_VERIFY_ARTIFACT_DIR="$ART"
}
_vev_gate_fail() { printf 'echo "start"; echo "MARKER-FAIL: test_the_one_that_broke"; for i in $(seq 1 40); do echo "ok line $i"; done; echo "1 failed"; exit 3'; }

test_a_failed_gate_keeps_its_full_output_and_records_exit_and_artifact() {
  _vev
  local rc=0; "$VERIFY" "$T" --gate "$(_vev_gate_fail)" --quiet || rc=$?
  assert_eq "$rc" 1
  assert_eq "$(_v .gate.passed)" false; assert_eq "$(_v .gate.code)" 3; assert_eq "$(_v .gate.outcome)" fail
  local art; art="$(_v .gate.artifact)"
  [ -f "$art" ] || { echo "no artifact at [$art]"; rm -rf "$T" "$ART"; return 1; }
  grep -q "MARKER-FAIL: test_the_one_that_broke" "$art" || { echo "the failure marker is not in the artifact"; rm -rf "$T" "$ART"; return 1; }
  # the marker is NOT in the 12-line display tail - that is the whole point
  case "$(_v .gate.tail)" in *MARKER-FAIL*) echo "fixture too short"; rm -rf "$T" "$ART"; return 1;; esac
  assert_eq "$(stat -c %a "$art")" 600
  assert_eq "$(_v .gate.head)" "$(git -C "$T" rev-parse HEAD)"
  assert_eq "$(_v .gate.output_sha256)" "$(sha256sum "$art" | cut -d' ' -f1)"
  rm -rf "$T"
}

test_passing_timeout_and_no_gate_stay_distinct_and_keep_evidence() {
  _vev
  "$VERIFY" "$T" --gate 'echo all-good' --quiet
  assert_eq "$(_v .gate.outcome)" pass
  grep -q all-good "$(_v .gate.artifact)" || { echo "pass lost its output"; rm -rf "$T" "$ART"; return 1; }
  local rc=0; "$VERIFY" "$T" --gate 'echo got-this-far; sleep 30' --gate-timeout 1 --quiet || rc=$?
  assert_eq "$rc" 2; assert_eq "$(_v .gate.outcome)" timeout
  grep -q got-this-far "$(_v .gate.artifact)" || { echo "a timed-out gate lost its partial output"; rm -rf "$T" "$ART"; return 1; }
  "$VERIFY" "$T" --quiet
  assert_eq "$(_v .gate.outcome)" none; assert_eq "$(_v .gate.artifact)" null
  rm -rf "$T"
}

test_repeated_attempts_never_overwrite_earlier_evidence() {
  _vev
  "$VERIFY" "$T" --gate 'echo first-attempt; exit 1' --quiet || true
  local a1; a1="$(_v .gate.artifact)"
  "$VERIFY" "$T" --gate 'echo second-attempt; exit 2' --quiet || true
  local a2; a2="$(_v .gate.artifact)"
  [ "$a1" != "$a2" ] || { echo "two attempts share an artifact"; rm -rf "$T" "$ART"; return 1; }
  grep -q first-attempt "$a1" && grep -q second-attempt "$a2" || { echo "an attempt's evidence was lost"; rm -rf "$T" "$ART"; return 1; }
  assert_eq "$(_v .gate.attempt | grep -c .)" 1
  assert_eq "$(wc -l < "$ART/attempts.jsonl" | tr -d ' ')" 2
  rm -rf "$T"
}

# the artifact directory is private: a worktree is committed, pushed and read by a reviewer
test_the_artifact_directory_is_private_and_outside_the_worktree() {
  _vev
  "$VERIFY" "$T" --gate 'echo x' --quiet
  local art; art="$(_v .gate.artifact)"
  case "$art" in "$ART/"*) ;; *) echo "artifact outside the configured root: $art"; rm -rf "$T" "$ART"; return 1;; esac
  assert_eq "$(stat -c %a "$(dirname "$art")")" 700
  rm -rf "$T"
}


# ----------------------------- termination of the VERIFIER itself (review limit b)
_vev_wait_for() { # <file> <text>
  local i; for i in $(seq 1 100); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1
}
_vev_art_dir() { local i d; for i in $(seq 1 100); do d="$(ls -d "$ART"/*/*/ 2>/dev/null | head -1)"; [ -n "$d" ] && { printf '%s' "$d"; return 0; }; sleep 0.1; done; return 1; }
_vev_gate_cleanup() { [ -s "$T/gate.pid" ] && kill -9 -- "-$(cat "$T/gate.pid")" 2>/dev/null || true; }
_vev_gate() { printf 'echo $$ > "%s/gate.pid"; echo %s; sleep 61' "$T" "$1"; }

test_a_terminated_verifier_keeps_the_partial_output_and_records_no_verdict() {
  _vev
  "$VERIFY" "$T" --gate "$(_vev_gate partial-before-term)" --quiet & local vp=$!
  local art; art="$(_vev_art_dir)" || { echo "no artifact dir"; kill -9 $vp; rm -rf "$T" "$ART"; return 1; }
  _vev_wait_for "${art}gate.log" partial-before-term || { echo "gate output never reached the artifact"; kill -9 $vp; _vev_gate_cleanup; rm -rf "$T" "$ART"; return 1; }
  kill -TERM "$vp"; local rc=0; wait "$vp" || rc=$?
  assert_eq "$rc" 3
  assert_eq "$(_v .gate.outcome)" no_verdict
  assert_contains "$(_v .gate.no_verdict_reason)" "terminated by SIGTERM"
  grep -q partial-before-term "$(_v .gate.artifact)" || { echo "partial output lost"; _vev_gate_cleanup; rm -rf "$T" "$ART"; return 1; }
  assert_eq "$(jq -r .state "$(dirname "$(_v .gate.artifact)")/attempt.json")" completed
  assert_eq "$(wc -l < "$ART/attempts.jsonl" | tr -d ' ')" 1
  ! kill -0 -- "-$(cat "$T/gate.pid")" 2>/dev/null || { echo "the gate group survived its verifier"; _vev_gate_cleanup; rm -rf "$T" "$ART"; return 1; }
  rm -rf "$T" "$ART"
}

# SIGKILL cannot be handled: no verdict and no final index can be written. What
# MUST survive is every byte the gate had already printed, and an attempt record
# that still says it never finished - never a completed-looking verdict.
test_a_sigkilled_verifier_still_leaves_the_output_and_an_unfinished_attempt_record() {
  _vev
  "$VERIFY" "$T" --gate "$(_vev_gate bytes-before-kill)" --quiet & local vp=$!
  local art; art="$(_vev_art_dir)" || { echo "no artifact dir"; kill -9 $vp; rm -rf "$T" "$ART"; return 1; }
  _vev_wait_for "${art}gate.log" bytes-before-kill || { echo "gate output never reached the artifact"; kill -9 $vp; _vev_gate_cleanup; rm -rf "$T" "$ART"; return 1; }
  kill -9 "$vp"; wait "$vp" 2>/dev/null || true
  grep -q bytes-before-kill "${art}gate.log" || { echo "SIGKILL erased evidence"; _vev_gate_cleanup; rm -rf "$T" "$ART"; return 1; }
  assert_eq "$(jq -r .state "${art}attempt.json")" running
  [ ! -f "$T/.agent/verdict.json" ] || { echo "a SIGKILLed verifier produced a verdict"; _vev_gate_cleanup; rm -rf "$T" "$ART"; return 1; }
  _vev_gate_cleanup
  rm -rf "$T" "$ART"
}

# raw gate output must never be committable or readable by others
test_an_unsafe_artifact_root_is_refused_before_the_gate_runs() {
  _vev
  local rc=0
  CEL_VERIFY_ARTIFACT_DIR="$T/inside" "$VERIFY" "$T" --gate "touch $T/ran" --quiet 2>/dev/null || rc=$?
  assert_eq "$rc" 4
  [ ! -e "$T/ran" ] || { echo "the gate ran despite an unsafe artifact root"; rm -rf "$T" "$ART"; return 1; }
  chmod 755 "$ART"; rc=0
  "$VERIFY" "$T" --gate "touch $T/ran2" --quiet 2>/dev/null || rc=$?
  assert_eq "$rc" 4
  [ ! -e "$T/ran2" ] || { echo "the gate ran with a world-readable root"; rm -rf "$T" "$ART"; return 1; }
  chmod 700 "$ART"; "$VERIFY" "$T" --gate true --quiet
  assert_eq "$(_v .gate.outcome)" pass
  rm -rf "$T" "$ART"
}
