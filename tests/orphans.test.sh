# shellcheck shell=bash
# lib/orphans.sh - what the plane started and nobody owns any more.
#
# A REAL /proc CANNOT BE ARRANGED. lib/memory.sh measures a real child because
# the thing it proves is "a process with this cwd is that worker's"; here the
# thing to prove is a CLASSIFICATION - a watcher whose console exited, a
# fixture whose worktree was deleted nine days ago, a shell on a pty whose
# pane is gone - and none of those can be produced on a live box without
# leaving exactly the litter this file exists to remove. So the walk is
# pointed at a fixture tree through CEL_PROC, with `herdr pane list` stubbed
# for the live-pane set, and the REAP tests use real children whose pids the
# fixture then describes: the classification is fake, the kill is not.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/orphans.sh"

# One fake process. `cwd` is a symlink like the kernel's, so a deleted
# working directory is a dangling link exactly as it is on the box.
_proc_add() { # <procdir> <pid> <ppid> <name> <rss-kb> <cwd> [args...]
  local d="$1/$2"
  mkdir -p "$d"
  printf 'Name:\t%s\nPPid:\t%s\nUid:\t%s\t%s\t%s\t%s\nVmRSS:\t%s kB\n' \
    "$4" "$3" "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" "$5" >"$d/status"
  ln -sfn "$6" "$d/cwd"
  shift 6
  local a
  : >"$d/cmdline"
  for a in "$@"; do printf '%s\0' "$a" >>"$d/cmdline"; done
}

_proc_tty() { # <procdir> <pid> <tty>
  mkdir -p "$1/$2/fd"
  ln -sfn "$3" "$1/$2/fd/0"
}

# A box whose panes the plane can enumerate. Without this the shell class is
# UNKNOWN, never orphaned - see the test below that proves it.
_herdr_stub() { # <bindir> <tty...>
  local bin="$1"; shift
  mkdir -p "$bin"
  local panes="" t
  for t in "$@"; do panes="$panes${panes:+,}{\"pane_id\":\"p$RANDOM\",\"cwd\":\"/nowhere\",\"tty\":\"$t\"}"; done
  cat >"$bin/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"result":{"panes":[$panes]}}'
EOF
  chmod +x "$bin/herdr"
  PATH="$bin:$PATH"
}

# The box as the walk found it on 2026-09-19: a watcher from a console that
# exited, a fixture under a deleted worktree, a bare shell on a dead pty, a
# killed gate runner - and, beside each, the thing that looks like it and is
# not.
_orphans_fixture() { # -> sets T, P
  T="$(mktemp -d)"
  P="$T/proc"
  mkdir -p "$P" "$T/live-console" "$T/gone"
  rmdir "$T/gone"

  # a. the watcher a console armed and never killed
  _proc_add "$P" 4001 1 bash 8000 "$T" cel inbox watch --for root --all-workspaces
  # ...and the one whose console is still alive: a parent that is not init
  _proc_add "$P" 4002 4003 bash 8000 "$T" cel inbox watch --for root --all-workspaces
  _proc_add "$P" 4003 1 node 90000 "$T" node "$T/console.mjs"

  # b. the fixture whose worktree was deleted nine days ago
  _proc_add "$P" 4010 1 sh 2000 "$T/gone" /bin/sh "$T/gone/bin/long-running"
  # ...and one in a directory that still exists
  _proc_add "$P" 4011 1 sh 2000 "$T" /bin/sh "$T/bin/long-running"

  # c. the pane shell on a pty no pane owns
  _proc_add "$P" 4020 1 zsh 6000 "$T" /usr/bin/zsh
  _proc_tty "$P" 4020 /dev/pts/99
  # ...and the one on a pty that IS in the pane list
  _proc_add "$P" 4021 1 zsh 6000 "$T" /usr/bin/zsh
  _proc_tty "$P" 4021 /dev/pts/3

  # d. the gate runner whose suite was killed
  _proc_add "$P" 4030 1 bash 40000 "$T" bash tests/run.sh

  # Never ours to touch: Claude Code's own daemon, and a box service.
  _proc_add "$P" 4040 1 claude 500000 "$T" claude bg-spare
  _proc_add "$P" 4041 1 node 100000 "$T" node "$HOME/.cel/services.d/cel-pages/serve.mjs"

  _herdr_stub "$T/bin" /dev/pts/3
  export CEL_PROC="$P"
}

_class_of() { # <rows> <pid>
  printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$2 == p { print $1 }'
}

test_orphans_list_finds_one_row_per_class() {
  _orphans_fixture
  local rows; rows="$(orphans_list)"
  assert_eq "$(_class_of "$rows" 4001)" "watcher"
  assert_eq "$(_class_of "$rows" 4010)" "fixture"
  assert_eq "$(_class_of "$rows" 4020)" "shell"
  assert_eq "$(_class_of "$rows" 4030)" "runner"
  rm -rf "$T"
}

# THE EXCLUSIONS ARE THE WHOLE SAFETY ARGUMENT. Every one of these looks like
# an orphan from one field and is not, and reaping any of them costs someone
# a session, a pane, or the box's own services.
test_orphans_list_never_matches_what_still_has_an_owner() {
  _orphans_fixture
  local rows; rows="$(orphans_list)"
  assert_eq "$(_class_of "$rows" 4002)" ""   # watcher under a live console
  assert_eq "$(_class_of "$rows" 4011)" ""   # fixture whose directory exists
  assert_eq "$(_class_of "$rows" 4021)" ""   # shell on a pty a pane owns
  assert_eq "$(_class_of "$rows" 4040)" ""   # claude bg-spare
  assert_eq "$(_class_of "$rows" 4041)" ""   # a box service
  assert_eq "$(_class_of "$rows" 4003)" ""   # the console itself
  rm -rf "$T"
}

# A pane list nobody could read is not an empty pane list. Unknown must keep
# every shell: the alternative is a sweep that kills all 173 of them the first
# time herdr is restarting.
test_orphans_list_keeps_every_shell_when_the_pane_list_cannot_be_read() {
  _orphans_fixture
  cat >"$T/bin/herdr" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$T/bin/herdr"
  local rows; rows="$(PATH="$T/bin:$PATH" orphans_list)"
  assert_eq "$(_class_of "$rows" 4020)" ""
  assert_eq "$(_class_of "$rows" 4001)" "watcher"
  rm -rf "$T"
}

test_orphans_totals_count_and_megabytes() {
  _orphans_fixture
  local out; out="$(orphans_list | orphans_totals)"
  # 8000 + 2000 + 6000 + 40000 kB
  assert_eq "$out" "4 54"
  rm -rf "$T"
}

# ONE LINE, NEVER ONE PER PID. Thirteen watchers and fifty-six fixtures is a
# rolled-up sentence or it is a mailbox nobody reads.
test_orphans_reaped_line_rolls_the_classes_up() {
  local rows
  rows="$(printf 'watcher\t1\t8000\t10\t/w\tcel inbox watch\nwatcher\t2\t8000\t10\t/w\tcel inbox watch\nfixture\t3\t2000\t10\t/w\tsh\nshell\t4\t6000\t10\t/w\tzsh\n')"
  assert_eq "$(printf '%s\n' "$rows" | orphans_reaped_line)" \
    "reaped 4 orphans (2 watchers, 1 fixture, 1 shell), 23 MB"
}

# --- the kill itself, against processes that really exist -------------------

_reap_fixture() { # -> T, P; one TERM-respecting child (WPID) and one that ignores it (SPID)
  T="$(mktemp -d)"
  P="$T/proc"
  mkdir -p "$P"
  sleep 60 & WPID=$!
  bash -c 'trap "" TERM; sleep 60' & SPID=$!
  _proc_add "$P" "$WPID" 1 bash 8000 "$T" cel inbox watch --for root
  _proc_add "$P" "$SPID" 1 sh 2000 "$T/gone" /bin/sh "$T/gone/bin/long-running"
  export CEL_PROC="$P" CEL_ORPHAN_GRACE=1
}

test_orphans_reap_terminates_a_watcher_and_says_what_it_did() {
  _reap_fixture
  local out; out="$(orphans_reap)"
  assert_contains "$out" "reaped 2 orphans"
  sleep 0.2
  assert_fails kill -0 "$WPID"
  kill -9 "$SPID" 2>/dev/null || true
  rm -rf "$T"
}

# A fixture that ignores TERM is what left fifty-six of them on the box. The
# grace is real and then so is the KILL.
test_orphans_reap_kills_what_ignores_the_term_after_the_grace() {
  _reap_fixture
  orphans_reap >/dev/null
  sleep 0.3
  assert_fails kill -0 "$SPID"
  kill -9 "$WPID" 2>/dev/null || true
  rm -rf "$T"
}

test_orphans_reap_dry_run_kills_nothing_and_still_lists() {
  _reap_fixture
  local out; out="$(orphans_reap --dry-run)"
  assert_contains "$out" "would reap 2 orphans"
  kill -0 "$WPID"
  kill -0 "$SPID"
  kill -9 "$WPID" "$SPID" 2>/dev/null || true
  rm -rf "$T"
}

test_orphans_doctor_line_only_speaks_when_there_are_any() {
  _orphans_fixture
  assert_contains "$(orphans_doctor_line)" "orphans: 4 processes, 54 MB - cel gc --orphans"
  rm -rf "$T"
  T="$(mktemp -d)"; mkdir -p "$T/proc"
  assert_eq "$(CEL_PROC="$T/proc" orphans_doctor_line)" ""
  rm -rf "$T"
}

# `cel gc --orphans` is the verb an operator is told to run, so the flag is
# proved through the real dispatch rather than the library function.
test_cel_gc_orphans_dry_run_lists_without_touching_worktrees() {
  _orphans_fixture
  local out
  out="$(CEL_PROC="$P" PATH="$T/bin:$PATH" "$CEL_ROOT/bin/cel" gc --orphans --dry-run)"
  assert_contains "$out" "would reap 4 orphans"
  assert_contains "$out" "watcher"
  case "$out" in *"worktrees removed"*) echo 'the orphan sweep ran the worktree GC'; return 1;; esac
  rm -rf "$T"
}

# --- the runner stops making them ------------------------------------------

# Fifty-six `/bin/sh .../bin/long-running` fixtures were still up nine days
# after the worktree they ran in was deleted, because the suite that started
# them was killed and they had escaped their test's process group with setsid.
# The group kill cannot reach those; their CWD still can.
test_the_suite_kills_a_process_left_in_its_tmpdir() {
  local T2; T2="$(mktemp -d)"
  mkdir -p "$T2/tests/lib"
  cp "$CEL_ROOT/tests/run.sh" "$T2/tests/run.sh"
  cp "$CEL_ROOT/tests/lib/assert.sh" "$T2/tests/lib/assert.sh"
  printf 'test_leaks_a_process_in_the_tmpdir() { mkdir -p "$TMPDIR/fixture"; cd "$TMPDIR/fixture"; setsid sleep 60 >/dev/null 2>&1 & printf "%%s" "$!" > "%s/leaked.pid"; }\n' \
    "$T2" > "$T2/tests/leak.test.sh"
  CEL_SUITE_LOCK=none CEL_SUITE_LOCK_HELD="" bash "$T2/tests/run.sh" >/dev/null 2>&1
  local pid; pid="$(cat "$T2/leaked.pid")"
  sleep 0.3
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    echo "a process left in the run's TMPDIR survived the run"
    rm -rf "$T2"; return 1
  fi
  rm -rf "$T2"
}

# --- the field the views read ----------------------------------------------

# `cel fleet --json` is the console's only read of the box, so an orphan that
# is not in that document is an orphan the console cannot mention.
test_fleet_box_carries_the_orphan_count_and_size() {
  _orphans_fixture
  source "$CEL_ROOT/lib/fleet.sh"
  local out; out="$(PATH="$T/bin:$PATH" fleet_orphans_json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.count')" "4"
  assert_eq "$(printf '%s' "$out" | jq -r '.rss_mb')" "54"
  rm -rf "$T"
}

# --- the watcher's own belt and braces -------------------------------------

# Belt and braces for the console's kill: a watcher told which console owns it
# exits on its own when that pid is gone. Four of the thirteen found on the
# box were days old, which is exactly how long a missed kill lasts without
# this.
test_inbox_watch_exits_when_its_parent_is_gone() {
  local T2; T2="$(mktemp -d)"
  sleep 30 & local parent=$!
  CEL_INBOX_DIR="$T2" CEL_WATCH_PARENT_POLL=1 \
    "$CEL_ROOT/bin/cel" inbox watch --for root --workspace alpha --parent "$parent" >/dev/null 2>&1 &
  local w=$!
  sleep 0.5
  kill "$parent" 2>/dev/null
  local i=0
  while [ "$i" -lt 60 ]; do
    kill -0 "$w" 2>/dev/null || { rm -rf "$T2"; return 0; }
    sleep 0.2; i=$((i + 1))
  done
  kill -9 "$w" 2>/dev/null
  echo "the watcher outlived the parent it was told to follow"
  rm -rf "$T2"
  return 1
}

# --- box services are protected by IDENTITY, not by a hopeful substring ----

# THE FIRST CUT OF THIS PROTECTION WAS DEAD CODE. It matched the strings
# `cel-auth-gateway`, `cel-auth-broker` and `/services.d/` against the
# cmdline - and lib/gateway.sh declares those services as
# `omp auth-broker serve --bind 127.0.0.1:47311`, so not one of the three
# substrings occurs in any process on this box. The gateway survived the
# sweep by luck: its cwd happened to exist. Give it a deleted cwd, or a
# `--reap` that ever widens, and the plane kills the door to every
# subscription it owns and cannot say why.
#
# So a box service is now identified the way the box itself identifies one:
# the declaration in services.d, resolved to the pid that is actually
# listening on its port or the pid its state file records - and the whole
# tree under that pid, because a service that forks a worker did not stop
# being a service. The argv in this fixture is deliberately unrelated to
# anything the plane greps for.
_service_fixture() { # -> T, P, SVC_PID, PORT
  T="$(mktemp -d)"
  P="$T/proc"
  mkdir -p "$P" "$T/services.d" "$T/state" "$T/bin"
  export CEL_PROC="$P" CEL_SERVICES_D="$T/services.d" CEL_SERVICES_STATE="$T/state"
  _herdr_stub "$T/bin"

  # A service with an argv that says nothing about cel, omp or services.d,
  # holding a real listening socket - exactly what `omp auth-broker serve`
  # looks like to a string matcher that is looking for the wrong string.
  python3 -c '
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(60)
' "$T/port" &
  SVC_PID=$!
  local i=0
  while [ ! -s "$T/port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  PORT="$(cat "$T/port")"
  printf '{"name":"widget-vault","url":"http://127.0.0.1:%s","cmd":"widgetd serve --bind 127.0.0.1:%s"}\n' \
    "$PORT" "$PORT" > "$T/services.d/widget-vault.json"

  # And it is standing in a directory that no longer exists, which is what
  # makes it a `fixture` to every other rule in this file.
  _proc_add "$P" "$SVC_PID" 1 python3 90000 "$T/gone" python3 -c 'import socket' "$T/port"
  # ...and a worker it forked. A live child has a live parent, so the ppid-1
  # rule already keeps it; it is here so that rule is exercised beside the
  # service rather than asserted on its own.
  _proc_add "$P" 777001 "$SVC_PID" python3 4000 "$T/gone" python3 -c 'worker'
}

test_orphans_never_reaps_a_declared_box_service_listening_on_its_port() {
  _service_fixture
  local rows; rows="$(PATH="$T/bin:$PATH" orphans_list)"
  assert_eq "$(_class_of "$rows" "$SVC_PID")" ""
  kill -9 "$SVC_PID" 2>/dev/null || true
  rm -rf "$T"
}

# A service that is declared and momentarily NOT listening - restarting,
# wedged, or up on a port `ss` could not be asked about - is still a service.
# The state file is the second identity, and the only one that survives the
# service being down at the moment the sweep runs.
test_orphans_never_reaps_a_box_service_recorded_in_its_state_file() {
  _service_fixture
  # The declaration now points at a port nothing is listening on, so the only
  # identity left is the recorded pid.
  printf '{"name":"widget-vault","url":"http://127.0.0.1:1","cmd":"widgetd serve"}\n' \
    > "$T/services.d/widget-vault.json"
  printf '{"name":"widget-vault","pane":"","pid":%s,"started":"now","log":""}\n' \
    "$SVC_PID" > "$T/state/widget-vault.json"
  local rows; rows="$(PATH="$T/bin:$PATH" orphans_list)"
  assert_eq "$(_class_of "$rows" "$SVC_PID")" ""
  kill -9 "$SVC_PID" 2>/dev/null || true
  rm -rf "$T"
}

# SECOND LINE OF DEFENCE, matched against the line lib/gateway.sh actually
# declares (`omp auth-broker serve --bind 127.0.0.1:47311`) rather than
# against the service's name, which appears nowhere in any process. This is
# what stands between the sweep and the box's subscriptions on a box whose
# services.d has not been written yet.
test_orphans_never_reaps_the_auth_broker_or_gateway_by_their_real_launch_line() {
  _orphans_fixture
  _proc_add "$P" 4050 1 omp 700000 "$T/gone" omp auth-broker serve --bind 127.0.0.1:47311
  _proc_add "$P" 4051 1 omp 700000 "$T/gone" omp auth-gateway serve --bind 127.0.0.1:47411
  local rows; rows="$(orphans_list)"
  assert_eq "$(_class_of "$rows" 4050)" ""
  assert_eq "$(_class_of "$rows" 4051)" ""
  rm -rf "$T"
}
