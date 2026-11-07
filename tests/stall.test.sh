# shellcheck shell=bash
# Dead-worker detection: transport failures can leave a worker looking idle
# while its unpushed work needs recovery.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/stall.sh"

# Representative runtime transport failure.
_together_death() {
  printf '%s\n' \
    '  Running tests...' \
    '✘ server_error: Upstream error from Together: Stream error: h2 protocol error: error reading a body from connection' \
    '↻ F5 to Retry'
}

test_the_together_stream_error_is_a_marker() {
  local m; m="$(stall_marker "$(_together_death)")"
  [ -n "$m" ] || { echo "transport failure did not match any marker"; return 1; }
}
test_ordinary_work_is_not_a_marker() {
  assert_eq "$(stall_marker 'running 42 tests... ok. committing.')" ""
  assert_eq "$(stall_marker 'Read src/server.ts and fixed the retry loop')" ""
}
# A worker WRITING about an error is not a worker that hit one. The markers are
# shapes a runtime emits when it has stopped, and the age check below is what
# stops even a quoted one from firing on a live worker.
test_a_marker_alone_does_not_convict_a_working_agent() {
  assert_eq "$(stall_verdict working "$(_together_death)" 99999)" ""
}

# --- verdicts ---------------------------------------------------------------

# `idle` is NOT the signal: a healthy worker between turns is idle, and
# reporting on that is how a watcher becomes noise and gets ignored.
test_idle_without_a_marker_or_age_is_not_stalled() {
  assert_eq "$(stall_verdict idle 'thinking about the gate' 60)" ""
}
test_marker_plus_age_is_a_dead_worker() {
  assert_contains "$(stall_verdict idle "$(_together_death)" 3600)" "dead-"
}
# Fifteen minutes of corroboration: long enough that a retry which was going to
# succeed already has, short enough that nobody loses a morning.
test_marker_that_is_still_fresh_is_given_time_to_retry() {
  assert_eq "$(stall_verdict idle "$(_together_death)" 60)" ""
  assert_contains "$(stall_verdict idle "$(_together_death)" 900)" "dead-"
}
# A pane can also disappear entirely.
test_a_vanished_agent_is_stalled_at_any_age() {
  assert_eq "$(stall_verdict '' '' 10)" "vanished"
  assert_eq "$(stall_verdict '-' '' 10)" "vanished"
}
test_very_long_silence_is_reported_even_without_a_marker() {
  assert_eq "$(stall_verdict idle 'no marker here' 10801)" "quiet"
  assert_eq "$(stall_verdict idle 'no marker here' 3600)" ""
}
test_thresholds_are_overridable() {
  assert_eq "$(CEL_STALL_MARKER_SECS=99999 stall_verdict idle "$(_together_death)" 3600)" ""
}

# --- what is at risk --------------------------------------------------------

_srepo() { # a worktree with an origin and a branch
  T="$(mktemp -d)"
  git -C "$T" init -q -b main 2>/dev/null
  git -C "$T" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T" update-ref refs/remotes/origin/main HEAD
  git -C "$T" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$T" checkout -q -b WG-1-feature
}
test_a_clean_pushed_worktree_has_nothing_at_risk() {
  _srepo
  git -C "$T" update-ref refs/remotes/origin/WG-1-feature HEAD
  assert_eq "$(stall_work_at_risk "$T")" ""
  assert_eq "$(stall_branch_pushed "$T")" yes
  rm -rf "$T"
}
# A branch never pushed has work only in this checkout.
test_an_unpushed_branch_counts_every_commit_as_at_risk() {
  _srepo
  printf 'x\n' > "$T/a.test.ts"; git -C "$T" add -A
  git -C "$T" -c user.email=t@t -c user.name=t commit -q -m "failing test"
  assert_contains "$(stall_work_at_risk "$T")" "unpushed=1"
  assert_eq "$(stall_branch_pushed "$T")" no
  rm -rf "$T"
}
test_uncommitted_files_count_as_at_risk() {
  _srepo
  git -C "$T" update-ref refs/remotes/origin/WG-1-feature HEAD
  printf 'wrapper\n' > "$T/chrome-wrapper.ts"
  assert_contains "$(stall_work_at_risk "$T")" "dirty=1"
  rm -rf "$T"
}
# Delay costs the WORK, not just time, only when something is unlanded.
test_unpushed_work_escalates_louder() {
  assert_eq "$(stall_severity dead-x 'unpushed=2 dirty=1')" loud
  assert_eq "$(stall_severity dead-x '')" normal
  assert_eq "$(stall_severity '' 'unpushed=2 dirty=1')" ""
}

# --- the message ------------------------------------------------------------

# Recovery needs identity, location, age, and an assessment of work at risk.
test_the_escalation_carries_ticket_pane_age_and_risk() {
  local m; m="$(stall_message dead-server_error WG-12 w1:p1 54000 no 'unpushed=1 dirty=3' wg-12-feature)"
  assert_contains "$m" "WG-12"
  assert_contains "$m" "w1:p1"
  assert_contains "$m" "900m"
  assert_contains "$m" "pushed=no"
  assert_contains "$m" "unpushed=1 dirty=3"
  assert_contains "$m" "server_error"
  assert_contains "$m" "AT RISK"
}
test_a_safe_stalled_worker_says_so() {
  local m; m="$(stall_message vanished WG-24 w2:p1 4000 yes '' wg-24-feature)"
  assert_contains "$m" "GONE from the roster"
  assert_contains "$m" "safe to let go"
  ! printf '%s' "$m" | grep -q "AT RISK" || { echo "safe worker claimed work at risk"; return 1; }
}
test_an_untracked_delegation_still_names_itself() {
  assert_contains "$(stall_message vanished '' wX:p1 600 '?' '' br)" "untracked"
}

# --- quiet age --------------------------------------------------------------

# The work itself is the evidence: herdr exposes no last-activity time, so
# liveness is read from what a working agent cannot help but touch.
test_quiet_age_reads_the_newest_file_in_the_worktree() {
  T="$(mktemp -d)"
  printf 'x\n' > "$T/a"
  touch -d '2 hours ago' "$T/a"
  local q; q="$(stall_quiet_secs "$T")"
  [ "$q" -ge 7000 ] && [ "$q" -le 7400 ] || { echo "expected ~7200s, got $q"; rm -rf "$T"; return 1; }
  printf 'y\n' > "$T/b"          # a worker writing something, right now
  q="$(stall_quiet_secs "$T")"
  [ "$q" -lt 60 ] || { echo "a fresh write should reset the age, got $q"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A fetch churns .git/objects without an agent doing anything; staging and
# committing move the index and HEAD, and those are the agent.
test_quiet_age_ignores_git_object_churn() {
  T="$(mktemp -d)"; mkdir -p "$T/.git/objects"
  printf 'x\n' > "$T/a"; touch -d '3 hours ago' "$T/a"
  printf 'obj\n' > "$T/.git/objects/fresh"
  local q; q="$(stall_quiet_secs "$T")"
  [ "$q" -ge 10000 ] || { echo ".git churn counted as activity ($q)"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_quiet_age_is_empty_for_a_missing_worktree() {
  assert_eq "$(stall_quiet_secs /nonexistent/worktree)" ""
}

# A worker that wrote its result has reached the last instruction it was given.
# Of course it is idle and of course nothing has moved since - that is finished.
# Reporting it as stalled is how a watcher
# gets ignored. A completed worker with a pushed branch and an open PR
# requires no recovery.
test_a_worker_that_wrote_its_result_is_finished_not_stalled() {
  assert_eq "$(stall_verdict idle 'no marker' 99999 1)" ""
  assert_contains "$(stall_verdict idle 'no marker' 99999 0)" "quiet"
}
# ...and its report is not work at risk. result.md is written at the end and
# never committed, so counting it made every finished worker look endangered.
test_the_agents_own_report_is_not_work_at_risk() {
  _srepo
  git -C "$T" update-ref refs/remotes/origin/WG-1-feature HEAD
  mkdir -p "$T/.agent"; printf 'done\n' > "$T/.agent/result.md"
  assert_eq "$(stall_work_at_risk "$T")" ""
  printf 'real code\n' > "$T/src.ts"
  assert_contains "$(stall_work_at_risk "$T")" "dirty=1"
  rm -rf "$T"
}
