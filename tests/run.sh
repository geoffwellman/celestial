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
  [ "$NO_LOCK" -eq 1 ] && return 0
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
trap '_kill_current_group; rm -rf "$TMPDIR"' EXIT
trap '_kill_current_group; rm -rf "$TMPDIR"; exit 130' INT TERM
PRELUDE="set -e; source '$CEL_ROOT/tests/lib/assert.sh'"
pass=0; fail=0

for f in "$CEL_ROOT"/tests/*.test.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"

  if ! err="$(_suite_spawn "$SUITE_LOCK_FD" bash -c "$PRELUDE; source '$f'" 2>&1)"; then
    fail=$((fail+1))
    printf '  \033[31mFAIL\033[0m %s (could not be sourced)\n%s\n' \
      "$base" "$(printf '%s' "$err" | sed 's/^/       /')"
    continue
  fi

  names="$(_suite_spawn "$SUITE_LOCK_FD" bash -c "$PRELUDE; source '$f'; declare -F | awk '{print \$3}' | grep '^test_'")"
  if [ -z "$names" ]; then
    fail=$((fail+1))
    printf '  \033[31mFAIL\033[0m %s (defines no test_ functions)\n' "$base"
    continue
  fi

  for t in $names; do
    if [ -n "$FILTER" ]; then case "$t" in *"$FILTER"*) ;; *) continue;; esac; fi
    tout="$TMPDIR/.test-output"
    # THE LOCK DESCRIPTOR IS NOT THE TEST'S TO HOLD. Every child inherits it,
    # and this runner deliberately tolerates tests that leak a process (the
    # setsid servers the group-kill above exists for). A leaked process holding
    # the suite lock is worse than a leaked process: it blocks every gate on
    # the box until it dies, long after the run that produced it finished. So
    # the descriptor is closed on the way into each test.
    ( [ -n "$SUITE_LOCK_FD" ] && exec {SUITE_LOCK_FD}>&-
      exec setsid bash -c "$PRELUDE; source '$f'; $t" ) > "$tout" 2>&1 &
    CURRENT_GROUP=$!
    rc=0; wait "$CURRENT_GROUP" || rc=$?
    _kill_current_group
    out="$(cat "$tout")"; rm -f "$tout"
    if [ "$rc" -eq 0 ]; then
      pass=$((pass+1)); printf '  \033[32mok\033[0m   %s\n' "$t"
    else
      fail=$((fail+1))
      printf '  \033[31mFAIL\033[0m %s\n%s\n' "$t" "$(printf '%s' "$out" | sed 's/^/       /')"
    fi
  done
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
