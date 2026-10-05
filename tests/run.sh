#!/usr/bin/env bash
# Zero-dependency test runner. Each test function runs in its own bash process,
# so a test that sets a global or exits cannot affect its neighbours.
#
#   tests/run.sh              run everything
#   tests/run.sh expand       run tests whose name contains "expand"
#   tests/run.sh --no-lock    run without queueing behind other suites
#
# A file that fails to source is reported as a failure, never skipped: a suite
# that can silently run nothing is worse than no suite at all.
set -uo pipefail

CEL_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export CEL_ROOT
# test-only seams (e.g. CEL_LIVENESS_NOW) are honoured only when this is set
export CEL_TESTING=1
# CEL-75: `cel fleet` caches its document; a suite that mutates a fixture and
# re-reads must see the change, so the cache is off unless a test turns it on.
export CEL_FLEET_CACHE_SECS=0
FILTER="" NO_LOCK=0
for arg in "$@"; do
  case "$arg" in
    --no-lock) NO_LOCK=1 ;;
    *) FILTER="$arg" ;;
  esac
done

# ONE SUITE AT A TIME ON THIS BOX. On 2026-09-18 six copies of this script ran
# at once - four workers rebasing after a merge, one fixing a review finding,
# one finishing a build. Each run is ~650 tests forking yq, node and bun; on
# six cores with sixteen agent sessions the load reached 190, swap filled, the
# steward raised memory blockers, and every suite crawled past its timeout, so
# the workers were about to retry and make it worse. The worker cap bounds how
# many workers EXIST, not how many gates RUN, and nothing anywhere said "one
# suite at a time", so nothing enforced it; three workers were interrupted by
# hand. A suite now queues instead, and says so rather than looking hung.
#
# The path is one function so a test can point it at a fixture. It is resolved
# before TMPDIR is replaced below, so the fallback names the real temporary
# directory rather than this run's private one - a lock nobody else can find
# is not a lock.
suite_lock_path() {
  if [ -n "${CEL_SUITE_LOCK:-}" ]; then printf '%s' "$CEL_SUITE_LOCK"; return 0; fi
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then
    printf '%s/cel-suite.lock' "$XDG_RUNTIME_DIR"; return 0
  fi
  printf '%s/cel-suite-%s.lock' "${TMPDIR:-/tmp}" "${UID:-0}"
}

# The lock is held by an open descriptor, so it is released by process exit:
# a killed suite frees it, with no stale-lock handling and no PID file for
# somebody to clean up afterwards. A FILTERED RUN STILL QUEUES - a filter can
# still be most of the suite, and "it's only a few tests" is what everyone says
# while the load climbs.
#
# AND IT IS HELD BY EVERY CHILD THAT INHERITS THE DESCRIPTOR. On 2026-09-19,
# hours after this lock landed, every gate on the box queued for eighteen
# minutes behind a `sleep 1800` with ppid 1 - a background process started
# somewhere under this runner, holding a copy of the lock long after the runner
# itself was gone. flock lives on the open file description, not on the
# process, and bash cannot mark a descriptor close-on-exec (`exec {fd}>` sets
# it only for the exec that never comes when the child is a fork). CEL-12 hit
# exactly this on the ledger lock and answered it with lock_spawn in
# lib/registry.sh: close the descriptor in the forked child, then exec, so no
# copy survives anywhere down the tree. This runner is zero-dependency by
# design and does not source the libraries it tests, so it carries the same
# helper rather than importing it. Every child goes through it - including the
# two shells that run before any test, which source each file to check it and
# to list its test functions, and which are children like any other.
SUITE_LOCK_FD=""
_suite_spawn() ( # <fd> <cmd> [args...] - lock_spawn, inlined
  local _fd="$1"; shift
  [ -n "$_fd" ] && exec {_fd}>&-
  exec "$@"
)
_suite_lock_take() {
  local path; path="$(suite_lock_path)"
  # --no-lock means the whole run stays out of the queue, nested gates
  # included: tests/fanout.test.sh runs collect, which runs cel-verify, which
  # would otherwise queue on the box lock from inside a run that chose not to
  # (CEL-97 measured four such tests sitting at the per-test limit).
  if [ "$NO_LOCK" -eq 1 ]; then export CEL_SUITE_LOCK_HELD=1; return 0; fi
  [ "$path" = none ] && return 0
  # RE-ENTRANT BY INHERITANCE. tests/fanout.test.sh runs `cel-fanout collect`,
  # which runs cel-verify, which runs a gate - a whole second suite, started
  # from inside a suite that is already holding this lock. On CI, where
  # XDG_RUNTIME_DIR is unset and both processes resolve the same path, that is
  # a run waiting twenty minutes for itself until the job is cancelled. A
  # process started under a held lock is ALREADY INSIDE IT and must not queue;
  # the holder says so in the environment, which children inherit for free.
  [ -n "${CEL_SUITE_LOCK_HELD:-}" ] && return 0
  command -v flock >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  exec {SUITE_LOCK_FD}>>"$path" || { SUITE_LOCK_FD=""; return 0; }
  if ! flock -n "$SUITE_LOCK_FD"; then
    # The holder wrote its pid and start time into the first line after it
    # acquired, so the waiting line can name what to go and look at instead of
    # leaving an operator to guess which of sixteen sessions is in front.
    local held pid since cwd
    held="$(sed -n 1p "$path" 2>/dev/null || true)"
    pid="${held%% *}"
    since="$(printf '%s\n' "$held" | awk '{print $2}')"
    cwd="$(printf '%s\n' "$held" | cut -s -d' ' -f3-)"
    printf 'waiting for the suite lock (held by pid %s since %s) \xe2\x80\xa6\n' "$pid" "$since"
    # A WAIT THAT HAS BECOME A PROBLEM SAYS SO, ONCE. The eighteen-minute
    # queue above looked from every pane like a hung gate; the one notice
    # above had scrolled away and nothing said anything after it. So a wait
    # past CEL_SUITE_WAIT_WARN repeats itself with the holder's directory -
    # and if the recorded pid is gone, the lock is held by something that
    # merely inherited the descriptor, which is a different problem with a
    # different fix and must not read as "somebody is running tests".
    local t0 warned=0 warn="${CEL_SUITE_WAIT_WARN:-120}"
    t0="$(date +%s)"
    until flock -w 1 "$SUITE_LOCK_FD"; do
      [ "$warned" -eq 0 ] || continue
      [ "$(( $(date +%s) - t0 ))" -ge "$warn" ] || continue
      warned=1
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        printf 'still waiting for the suite lock - held by pid %s since %s (%s)\n' "$pid" "$since" "$cwd"
      else
        printf 'still waiting for the suite lock - held by a dead pid %s - the lock leaked; see cel doctor\n' "$pid"
      fi
    done
    printf 'suite lock acquired after %ss\n' "$(( $(date +%s) - t0 ))"
  fi
  # pid, start time and CWD: on a box with sixteen agent sessions a pid alone
  # does not say which of them is in front of you.
  printf '%s %s %s\n' "$$" "$(date +%H:%M)" "$PWD" > "$path"
  # The path as well as the fact: a child that resolved it differently (a
  # different TMPDIR, say) would otherwise queue on a second lock nobody holds.
  export CEL_SUITE_LOCK="$path" CEL_SUITE_LOCK_HELD=1
}
_suite_lock_take

# Put every fixture under one per-run directory and remove it on exit or
# interruption. Individual tests can fail before their own cleanup; retaining
# whole temporary Git repositories across runs would exhaust temporary storage.
export TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/cel-tests.XXXXXX")"

# AND EVERY PROCESS A TEST STARTED GOES WITH IT. On 2026-09-16 a gate run that
# was killed mid-suite left seven test servers from tests/pages-server.test.sh
# alive for a hundred minutes, holding the descriptors they had inherited -
# including a workspace's delegation ledger lock, which blocked the whole
# fleet. Temporary files are not the only thing a killed suite leaks. So each
# test runs in its own process group and the group is killed when the test
# ends, whether it ended by passing, failing, or this runner being killed.
CURRENT_GROUP=""
_kill_current_group() {
  [ -n "$CURRENT_GROUP" ] || return 0
  kill -TERM -- "-$CURRENT_GROUP" 2>/dev/null
  CURRENT_GROUP=""
  return 0
}

# AND EVERY PROCESS THAT ESCAPED ITS GROUP. A walk of the box on 2026-09-19
# found fifty-six `/bin/sh .../bin/long-running` fixtures still up, all
# reparented to init, whose cwd was a `cel-tests.*` directory deleted nine
# days earlier: a `last-words` test starts deliberately long-lived processes
# with setsid - which is precisely a process the group kill above cannot
# reach - and the suite that started them was killed. The CWD is the handle
# (lib/memory.sh made the same argument for measuring a worker): anything
# still sitting in this run's private TMPDIR was started by this run and has
# nothing left to do, because the directory it is standing in is about to go.
_kill_tmpdir_strays() {
  case "${TMPDIR:-}" in */cel-tests.*) ;; *) return 0;; esac
  local link pid target
  for link in /proc/[0-9]*/cwd; do
    pid="${link#/proc/}"; pid="${pid%/cwd}"
    [ "$pid" = "$$" ] && continue
    target="$(readlink "$link" 2>/dev/null)" || continue
    case "$target" in "$TMPDIR"|"$TMPDIR"/*) kill -KILL "$pid" 2>/dev/null ;; esac
  done
  return 0
}
PRELUDE="set -e; source '$CEL_ROOT/tests/lib/assert.sh'"

# A TEST CANNOT HOLD THE BOX. On 2026-10-04 the suite lock was held for eighty
# minutes by one run stuck in a single new test whose `tools/dash/server.mjs`
# child never exited; two workers' suites and a land queued behind it, and
# nothing anywhere bounded a single test. Each test now has a wall limit
# (CEL_TEST_TIMEOUT seconds, generous by default - the slowest honest test is
# well under a minute) and on expiry its whole process group goes, servers
# included, and it is reported as a timeout naming the test.
TEST_TIMEOUT="${CEL_TEST_TIMEOUT:-120}"
case "$TEST_TIMEOUT" in ''|*[!0-9]*|0) TEST_TIMEOUT=120 ;; esac

# INDEPENDENT FILES RUN SIDE BY SIDE. CI's suite reached nineteen minutes
# against a twenty-minute job limit and a rerun was cancelled at the limit,
# blocking a merge. Every test already lives in its own process and its own
# mktemp fixture, so most files share nothing and can run at once; the few that
# do share something - a wall clock they measure, a box-wide process table
# they sweep - are listed in SERIAL_FILES with the reason, and run alone after
# the parallel pool has drained. CEL_TEST_JOBS=1 is the old serial runner.
if [ -z "${CEL_TEST_JOBS:-}" ]; then
  CEL_TEST_JOBS="$(nproc 2>/dev/null || echo 2)"
  [ "$CEL_TEST_JOBS" -le 6 ] || CEL_TEST_JOBS=6
fi
case "$CEL_TEST_JOBS" in ''|*[!0-9]*|0) CEL_TEST_JOBS=1 ;; esac
#   suite-lock.test.sh - asserts wall-clock overlap of two suites; load from
#                        neighbours turns "did they queue" into noise
#   orphans.test.sh    - sweeps and counts processes box-wide
#   memory.test.sh     - measures process memory and trees box-wide
SERIAL_FILES=" suite-lock.test.sh orphans.test.sh memory.test.sh "

RESULTS="$TMPDIR/.results"; mkdir -p "$RESULTS"

# One file, its tests one after another, its report written to
# $RESULTS/<n>.out and its counts to <n>.count. The report is printed by the
# main shell, in file order, so a parallel run reads exactly like a serial one.
_run_file() { # <n> <file>
  local n="$1" f="$2" base t tout out rc limit_hit wd p=0 fl=0
  local rep="$RESULTS/$n.out"
  base="$(basename "$f")"
  CURRENT_GROUP=""
  trap '_kill_current_group; exit 143' TERM INT
  : > "$rep"
  if ! err="$(_suite_spawn "$SUITE_LOCK_FD" bash -c "$PRELUDE; source '$f'" 2>&1)"; then
    printf '  \033[31mFAIL\033[0m %s (could not be sourced)\n%s\n' \
      "$base" "$(printf '%s' "$err" | sed 's/^/       /')" >> "$rep"
    printf '0 1\n' > "$RESULTS/$n.count"; return 0
  fi
  local names
  names="$(_suite_spawn "$SUITE_LOCK_FD" bash -c "$PRELUDE; source '$f'; declare -F | awk '{print \$3}' | grep '^test_'")"
  if [ -z "$names" ]; then
    printf '  \033[31mFAIL\033[0m %s (defines no test_ functions)\n' "$base" >> "$rep"
    printf '0 1\n' > "$RESULTS/$n.count"; return 0
  fi
  for t in $names; do
    if [ -n "$FILTER" ]; then case "$t" in *"$FILTER"*) ;; *) continue;; esac; fi
    tout="$RESULTS/$n.test-output"
    limit_hit="$RESULTS/$n.limit"; rm -f "$limit_hit"
    local t0; t0="$(date +%s%N)"
    # THE LOCK DESCRIPTOR IS NOT THE TEST'S TO HOLD. Every child inherits it,
    # and this runner deliberately tolerates tests that leak a process (the
    # setsid servers the group-kill above exists for). A leaked process holding
    # the suite lock is worse than a leaked process: it blocks every gate on
    # the box until it dies, long after the run that produced it finished. So
    # the descriptor is closed on the way into each test.
    ( [ -n "$SUITE_LOCK_FD" ] && exec {SUITE_LOCK_FD}>&-
      exec setsid bash -c "$PRELUDE; source '$f'; $t" ) > "$tout" 2>&1 &
    CURRENT_GROUP=$!
    # The watchdog closes the lock descriptor too: a watchdog's orphaned sleep
    # holding the lock is the 2026-09-19 outage cel-verify already answered.
    ( [ -n "$SUITE_LOCK_FD" ] && exec {SUITE_LOCK_FD}>&-
      # The watchdog is its own process group (setsid execs in place: this
      # subshell is not a group leader, so $! stays its pid) and the runner
      # kills the GROUP, so its sleep goes with it at any instant - no window
      # between fork and a trap knowing the pid (CEL-100: 385 orphaned
      # `sleep 120`s from one suite run).
      exec setsid bash -c 'sleep "$1"; kill -0 "$2" 2>/dev/null || exit 0; : > "$3"
        kill -TERM -- "-$2" 2>/dev/null; sleep 1; kill -KILL -- "-$2" 2>/dev/null' \
        _ "$TEST_TIMEOUT" "$CURRENT_GROUP" "$limit_hit" ) >/dev/null 2>&1 &
    wd=$!
    rc=0; wait "$CURRENT_GROUP" || rc=$?
    kill -- "-$wd" 2>/dev/null; wait "$wd" 2>/dev/null
    _kill_current_group
    if [ -n "${CEL_TEST_TIMES:-}" ]; then
      printf '%s %s %s\n' "$(( ($(date +%s%N) - t0) / 1000000 ))" "$base" "$t" >> "$CEL_TEST_TIMES"
    fi
    out="$(cat "$tout")"; rm -f "$tout"
    if [ -e "$limit_hit" ]; then
      rm -f "$limit_hit"
      fl=$((fl+1))
      printf '  \033[31mFAIL\033[0m %s (timed out after %ss - its process group was killed; CEL_TEST_TIMEOUT)\n%s\n' \
        "$t" "$TEST_TIMEOUT" "$(printf '%s' "$out" | sed 's/^/       /')" >> "$rep"
    elif [ "$rc" -eq 0 ]; then
      p=$((p+1)); printf '  \033[32mok\033[0m   %s\n' "$t" >> "$rep"
    else
      fl=$((fl+1))
      printf '  \033[31mFAIL\033[0m %s\n%s\n' "$t" "$(printf '%s' "$out" | sed 's/^/       /')" >> "$rep"
    fi
  done
  printf '%s %s\n' "$p" "$fl" > "$RESULTS/$n.count"
}

RUNNERS=()
_kill_runners() {
  local r; for r in "${RUNNERS[@]:-}"; do [ -n "$r" ] && kill -TERM "$r" 2>/dev/null; done
  return 0
}
trap '_kill_runners; _kill_current_group; _kill_tmpdir_strays; rm -rf "$TMPDIR"' EXIT
trap '_kill_runners; _kill_current_group; _kill_tmpdir_strays; rm -rf "$TMPDIR"; exit 130' INT TERM

FILES=() ORDER=()
for f in "$CEL_ROOT"/tests/*.test.sh; do [ -f "$f" ] && FILES+=("$f"); done
# Parallel-safe files first (their pool starts at once), serial files after.
for i in "${!FILES[@]}"; do
  case "$SERIAL_FILES" in *" $(basename "${FILES[$i]}") "*) ;; *) ORDER+=("$i") ;; esac
done
for i in "${!FILES[@]}"; do
  case "$SERIAL_FILES" in *" $(basename "${FILES[$i]}") "*) ORDER+=("$i") ;; esac
done

pass=0; fail=0
_report() { # <n> - print a finished file's report and add up its counts
  cat "$RESULTS/$1.out"
  local c; c="$(cat "$RESULTS/$1.count" 2>/dev/null || echo "0 1")"
  pass=$((pass + ${c%% *})); fail=$((fail + ${c##* }))
}

if [ "$CEL_TEST_JOBS" -le 1 ]; then
  for i in "${ORDER[@]}"; do _run_file "$i" "${FILES[$i]}"; _report "$i"; done
else
  # Launch up to CEL_TEST_JOBS runners; report each file in launch order as
  # soon as it and everything before it are done, so the log still streams.
  next=0 printed=0
  declare -A PID_OF=()
  _in_flight() { # launched and not yet finished
    local k c=0
    for ((k=printed; k<next; k++)); do [ -e "$RESULTS/${ORDER[$k]}.count" ] || c=$((c+1)); done
    printf '%s' "$c"
  }
  while [ "$printed" -lt "${#ORDER[@]}" ]; do
    while [ "$next" -lt "${#ORDER[@]}" ] && [ "$(_in_flight)" -lt "$CEL_TEST_JOBS" ]; do
      i="${ORDER[$next]}"
      # a serial file starts only when nothing else is running, and nothing
      # starts beside it
      case "$SERIAL_FILES" in *" $(basename "${FILES[$i]}") "*)
        [ "$(_in_flight)" -eq 0 ] || break
        _run_file "$i" "${FILES[$i]}" &
        PID_OF[$i]=$!; RUNNERS+=("$!"); next=$((next+1))
        break ;;
      esac
      _run_file "$i" "${FILES[$i]}" &
      PID_OF[$i]=$!; RUNNERS+=("$!"); next=$((next+1))
    done
    progressed=0
    while [ "$printed" -lt "$next" ] && [ -e "$RESULTS/${ORDER[$printed]}.count" ]; do
      i="${ORDER[$printed]}"
      wait "${PID_OF[$i]}" 2>/dev/null
      _report "$i"; printed=$((printed+1)); progressed=1
    done
    [ "$progressed" -eq 1 ] || sleep 0.2
  done
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
