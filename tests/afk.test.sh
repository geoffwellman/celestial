# shellcheck shell=bash
# `cel afk` - what the factory may decide while nobody is watching.
#
# AFK CHANGES WHO DECIDES, NEVER WHAT IS REQUIRED. The pre-authorised acts
# below each stand on their own evidence; every refusal here is one an agent
# must still make by waiting.
#
# Nothing in this file touches the live box or a real PR: `gh` and `herdr` are
# stubs on a prepended PATH that log their argv, and the state directory is a
# fixture. The stub log is asserted on directly, because "it refused" and "it
# refused AFTER posting" look identical from the exit status.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/afk.sh"

_afk_setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  export CEL_AFK_STATE="$T/afk"
  : > "$T/gh.log"
  : > "$T/herdr.log"
  cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/gh.log"
printf '{}'
EOF
  cat > "$T/bin/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/herdr.log"
printf '{"result":{"agents":[]}}'
EOF
  chmod +x "$T/bin/gh" "$T/bin/herdr"
  PATH="$T/bin:$PATH"
  export CEL_AFK_GH="$T/bin/gh"
}
_afk_teardown() { rm -rf "$T"; unset CEL_AFK_STATE CEL_AFK_GH; }

_ev_thread() { # [overrides-json]
  jq -nc --argjson o "${1:-{\}}" '{
    bot: true, fixed_commit: "abc1234", fixed_at: "2026-09-22T01:00:00Z",
    fixed_summary: "the unguarded grep now appends || true",
    reviewer_verdict: "approved", reviewer_verdict_at: "2026-09-22T02:00:00Z"
  } * $o'
}
_ev_land() {
  jq -nc --argjson o "${1:-{\}}" '{
    review: "approved", checks: "green", gate: "pass",
    mergeable: true, author: "solo", pr: 71
  } * $o'
}
_ev_rebase() {
  jq -nc --argjson o "${1:-{\}}" '{
    was_mergeable: true, behind: true, new_work: false, conflicts: false, pr: 71
  } * $o'
}

# ---------------------------------------------------------------- AFK is off
# THE REGRESSION THAT KEEPS AFK FROM BECOMING THE DEFAULT. With no AFK on,
# every one of the acts waits, exactly as it did before this file existed.
test_afk_off_every_pre_authorised_act_still_waits() {
  _afk_setup
  local act out
  for act in resolve_thread land rebase_retry; do
    out="$(afk_admit "$act" "$(_ev_land)" 2>&1)" && { _afk_teardown; return 1; }
    assert_contains "$out" "AFK is off" || { _afk_teardown; return 1; }
  done
  assert_eq "$(cat "$T/gh.log")" ""
  _afk_teardown
}

test_afk_on_and_off_round_trip_and_status_json() {
  _afk_setup
  cmd_afk on --until '+8h' --reason 'asleep' >/dev/null
  assert_eq "$(afk_state_json | jq -r .on)" true
  assert_eq "$(afk_state_json | jq -r .reason)" asleep
  afk_active || { _afk_teardown; return 1; }
  assert_contains "$(cmd_afk status)" "AFK is on"
  cmd_afk off >/dev/null
  assert_eq "$(afk_state_json | jq -r .on)" false
  assert_fails afk_active
  _afk_teardown
}

# SLEEPING IS A PROPERTY OF THE OPERATOR, not of one product: the state lives
# in the box's own state dir, so every workspace on the box reads the same
# answer rather than four that disagree.
test_afk_state_lives_in_the_box_state_dir() {
  _afk_setup
  cmd_afk on --reason 'asleep' >/dev/null
  [ -f "$CEL_AFK_STATE/state.json" ] || { _afk_teardown; return 1; }
  _afk_teardown
}

# ------------------------------------------------- the four, with evidence
test_each_pre_authorisation_fires_when_its_evidence_is_present() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  afk_admit resolve_thread "$(_ev_thread)"   || { _afk_teardown; return 1; }
  afk_admit land           "$(_ev_land)"     || { _afk_teardown; return 1; }
  afk_admit rebase_retry   "$(_ev_rebase)"   || { _afk_teardown; return 1; }
  # Admitting is not acting: nothing is logged until an act reports its end.
  assert_eq "$(afk_log_json | jq -sr 'length')" 0
  _afk_teardown
}

# ------------------------------------------------------- §3, one per refusal
test_afk_never_merges_red_unreviewed_or_unmergeable() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_admit land "$(_ev_land '{"checks":"red"}')" 2>&1)" \
    "a red check is a finding"
  assert_contains "$(afk_admit land "$(_ev_land '{"review":"none"}')" 2>&1)" \
    "no reviewer verdict"
  assert_contains "$(afk_admit land "$(_ev_land '{"mergeable":false}')" 2>&1)" \
    "conflicts"
  assert_contains "$(afk_admit land "$(_ev_land '{"author":"someone-else"}')" 2>&1)" \
    "not this product's own PR"
  _afk_teardown
}

# A GATE THAT PRODUCED NO VERDICT did not fail and did
# not pass; AFK removes the pause, not the check, so it is not a merge.
test_afk_refuses_a_landing_whose_gate_produced_no_verdict() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_admit land "$(_ev_land '{"gate":"no_verdict"}')" 2>&1)" \
    "the gate produced no verdict"
  assert_contains "$(afk_admit land "$(_ev_land '{"gate":"unknown"}')" 2>&1)" \
    "the gate produced no verdict"
  _afk_teardown
}

test_afk_never_resolves_a_thread_whose_finding_is_not_fixed_or_not_confirmed() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_admit resolve_thread "$(_ev_thread '{"fixed_commit":""}')" 2>&1)" \
    "the finding is not fixed"
  assert_contains "$(afk_admit resolve_thread "$(_ev_thread '{"reviewer_verdict":"changes"}')" 2>&1)" \
    "no reviewer confirmed the fix"
  # A verdict recorded BEFORE the fix confirms the finding, not the fix.
  assert_contains "$(afk_admit resolve_thread \
    "$(_ev_thread '{"reviewer_verdict_at":"2026-09-22T00:30:00Z"}')" 2>&1)" \
    "no reviewer confirmed the fix"
  assert_contains "$(afk_admit resolve_thread "$(_ev_thread '{"bot":false}')" 2>&1)" \
    "only bot review threads"
  _afk_teardown
}

# ASSERT NO POST WAS MADE AT ALL. The refusal that matters is the one that
# happens before `gh` is reached: a reply posted and then withdrawn is a
# comment the author already got mailed.
test_an_unfixed_finding_produces_no_post_whatsoever() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_fails afk_resolve_thread alpha/widget 71 THREAD_1 "$(_ev_thread '{"fixed_commit":""}')"
  assert_eq "$(cat "$T/gh.log")" ""
  _afk_teardown
}

# The NAMED exception, and its shape: the reply states what was fixed and cites
# the commit, because a bare "resolved" tells the next reader nothing.
test_a_verified_finding_is_replied_to_with_the_commit_then_resolved() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  afk_resolve_thread alpha/widget 71 THREAD_1 "$(_ev_thread)" >/dev/null \
    || { cat "$T/gh.log"; _afk_teardown; return 1; }
  local log; log="$(cat "$T/gh.log")"
  assert_contains "$log" "THREAD_1"
  assert_contains "$log" "abc1234"
  assert_contains "$log" "the unguarded grep now appends"
  assert_contains "$log" "resolveReviewThread"
  assert_contains "$(afk_log_json | jq -sr '.[-1].act')" "resolve_thread"
  _afk_teardown
}

# ...and nothing else. Workspace policy forbids agents posting to GitHub; this
# is one named exception and must not become general permission to comment.
test_afk_posts_nothing_to_github_beyond_thread_resolution() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  local out
  out="$(afk_post_allowed pr_comment 2>&1)" && { _afk_teardown; return 1; }
  assert_contains "$out" "posting to GitHub is not pre-authorised"
  out="$(afk_post_allowed issue 2>&1)" && { _afk_teardown; return 1; }
  afk_post_allowed bot_thread_resolution >/dev/null || { _afk_teardown; return 1; }
  _afk_teardown
}

test_afk_refuses_a_rebase_that_conflicts_or_carries_new_work() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_admit rebase_retry "$(_ev_rebase '{"conflicts":true}')" 2>&1)" \
    "the rebase conflicts"
  assert_contains "$(afk_admit rebase_retry "$(_ev_rebase '{"new_work":true}')" 2>&1)" \
    "new work"
  assert_contains "$(afk_admit rebase_retry "$(_ev_rebase '{"was_mergeable":false}')" 2>&1)" \
    "was not mergeable"
  _afk_teardown
}

# FAN-OUT WAS RETIRED: dispatching a worker and starting ordered work are no
# longer acts AFK can authorise, so the door refuses them outright.
test_afk_no_longer_authorises_dispatch_or_ordered_work() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_admit dispatch '{"source":"reviewer","quote":"x"}' 2>&1)" \
    "not one of the four pre-authorised acts" || { _afk_teardown; return 1; }
  assert_contains "$(afk_admit ordered_work '{}' 2>&1)" \
    "not one of the four pre-authorised acts" || { _afk_teardown; return 1; }
  _afk_teardown
}

# AFK never starts work somewhere it was not armed: an orchestrator asleep in
# one product is not an orchestrator loose on the box.
test_afk_refuses_an_act_in_another_orchestrators_workspace() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains \
    "$(afk_admit land "$(_ev_land '{"workspace":"beta","own_workspace":"alpha"}')" 2>&1)" \
    "another orchestrator's workspace"
  _afk_teardown
}

# ------------------------------------------------------------------ expiry
# AN AFK MODE THAT STAYS ON BECAUSE NOBODY TURNED IT OFF is how a fortnight of
# unattended merges happens. A past `--until` means off, whatever the file says.
test_an_expired_until_means_afk_is_off_and_the_act_refuses() {
  _afk_setup
  cmd_afk on --until '2020-01-01T00:00:00Z' >/dev/null
  assert_fails afk_active
  afk_expired || { _afk_teardown; return 1; }
  assert_eq "$(afk_state_json | jq -r .expired)" true
  local out; out="$(afk_admit land "$(_ev_land)" 2>&1)" && { _afk_teardown; return 1; }
  assert_contains "$out" "expired"
  assert_eq "$(afk_log_json | jq -sr 'length')" 0
  _afk_teardown
}

# ------------------------------------------------------------------- the log
# The morning question is "what did you do while I was asleep", and it has ONE
# answer to read, not four surfaces to reconstruct.
test_the_log_records_every_act_with_its_authorisation_and_survives_a_restart() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  ( afk_begin land "$(_ev_land)" "alpha/widget#71" && afk_end completed "merged" ) >/dev/null
  ( afk_begin rebase_retry "$(_ev_rebase)" "widget/WG-1" && afk_end completed ) >/dev/null
  # A restart: nothing of this process survives, only the state directory.
  local out
  out="$(bash -c '. "$CEL_ROOT/lib/common.sh"; . "$CEL_ROOT/lib/afk.sh"; cmd_afk log')"
  assert_contains "$out" "land"
  assert_contains "$out" "pre-authorisation 2"
  assert_contains "$out" "rebase_retry"
  assert_contains "$out" "pre-authorisation 3"
  _afk_teardown
}

# AN ACT ITS CALLER CARRIES OUT is admitted by afk_begin and recorded once, by
# afk_end, with how it ended. A caller that dies between the two is recorded
# anyway: `failed` when nothing of the act happened, `partial` once afk_step
# said something had.
test_regression_an_admitted_act_is_recorded_once_with_its_real_ending() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  ( afk_begin land "$(_ev_land)" "alpha/widget#71" && afk_end completed "merged" ) >/dev/null
  assert_eq "$(afk_log_json | jq -sr 'length')" 1 || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '.[-1].outcome')" completed || { _afk_teardown; return 1; }
  assert_contains "$(afk_log_json | jq -sr '.[-1].authorisation')" "pre-authorisation 2" || { _afk_teardown; return 1; }
  _afk_teardown
}
test_regression_an_act_that_exits_before_its_effect_is_recorded_failed() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  local rc=0
  ( afk_begin land "$(_ev_land)" "alpha/widget#71"; exit 1 ) >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 1 || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr 'length')" 1 || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '.[-1].outcome')" failed || { _afk_teardown; return 1; }
  _afk_teardown
}
test_regression_an_act_that_exits_half_way_is_recorded_partial() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  ( afk_begin land "$(_ev_land)" "alpha/widget#71"; afk_step "asked GitHub to merge #71"; exit 1 ) >/dev/null 2>&1 || true
  assert_eq "$(afk_log_json | jq -sr '.[-1].outcome')" partial || { _afk_teardown; return 1; }
  assert_contains "$(afk_log_json | jq -sr '.[-1].detail')" "asked GitHub to merge #71" || { _afk_teardown; return 1; }
  _afk_teardown
}
# A refusal records nothing and arms nothing; and an EXIT trap the caller
# already had still runs when the act's own is done.
test_regression_afk_begin_refusal_records_nothing_and_keeps_the_callers_exit_trap() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  ( afk_begin land "$(_ev_land '{"checks":"red"}')" "alpha/widget#71" ) >/dev/null 2>&1 \
    && { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr 'length')" 0 || { _afk_teardown; return 1; }
  ( trap 'printf ran > "$T/prev-trap"' EXIT; afk_begin land "$(_ev_land)" "alpha/widget#71"; exit 1 ) >/dev/null 2>&1 || true
  [ -f "$T/prev-trap" ] || { echo "the caller's EXIT trap was dropped"; _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '.[-1].outcome')" failed || { _afk_teardown; return 1; }
  _afk_teardown
}
# ...and that trap sees the process's real exit status, not the record's:
# a trap deciding on `$?` (lib/run.sh releases a session claim on failure)
# must not read a failed exit as success. Under `set -e` too, as cel solo land runs.
test_regression_the_callers_exit_trap_sees_the_real_exit_status() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  local rc=0
  ( trap 'printf %s "$?" > "$T/prev-rc"' EXIT; afk_begin land "$(_ev_land)" "alpha/widget#71"; exit 7 ) >/dev/null 2>&1 || rc=$?
  assert_eq "$(cat "$T/prev-rc" 2>/dev/null)" 7 || { _afk_teardown; return 1; }
  assert_eq "$rc" 7 || { _afk_teardown; return 1; }
  rm -f "$T/prev-rc"; rc=0
  ( set -e; trap 'printf %s "$?" > "$T/prev-rc"' EXIT; afk_begin land "$(_ev_land)" "alpha/widget#71"; false ) >/dev/null 2>&1 || rc=$?
  assert_eq "$(cat "$T/prev-rc" 2>/dev/null)" 1 || { _afk_teardown; return 1; }
  assert_eq "$rc" 1 || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '[.[].outcome] | join(",")')" failed,failed || { _afk_teardown; return 1; }
  _afk_teardown
}

# THE LOG SAYS WHAT HAPPENED, NOT WHAT WAS ALLOWED. An act the door let
# through is recorded once its effect was attempted, with how it ended.
_afk_gh_failing_on() { # <graphql-mutation-name>
  cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$*" in *$1*) exit 1 ;; esac
printf '{}'
EOF
  chmod +x "$T/bin/gh"
}

test_regression_a_resolved_thread_is_logged_once_as_completed() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  afk_resolve_thread alpha/widget 71 THREAD_1 "$(_ev_thread)" >/dev/null 2>&1 || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr 'length')" 1 || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '.[-1].outcome')" completed || { _afk_teardown; return 1; }
  _afk_teardown
}

test_regression_a_reply_that_did_not_post_is_logged_as_failed() {
  _afk_setup
  _afk_gh_failing_on addPullRequestReviewThreadReply
  cmd_afk on --until '+8h' >/dev/null
  assert_fails afk_resolve_thread alpha/widget 71 THREAD_1 "$(_ev_thread)" || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '.[-1].outcome')" failed || { _afk_teardown; return 1; }
  _afk_teardown
}

# Replied, then the resolve failed: the reply is out there, and the log must
# say the act stopped half way rather than that the thread was resolved.
test_regression_a_reply_posted_but_not_resolved_is_logged_as_partial() {
  _afk_setup
  _afk_gh_failing_on resolveReviewThread
  cmd_afk on --until '+8h' >/dev/null
  assert_fails afk_resolve_thread alpha/widget 71 THREAD_1 "$(_ev_thread)" || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr 'length')" 1 || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '.[-1].outcome')" partial || { _afk_teardown; return 1; }
  assert_contains "$(afk_log_json | jq -sr '.[-1].detail')" "not resolved" || { _afk_teardown; return 1; }
  assert_contains "$(bash -c '. "$CEL_ROOT/lib/common.sh"; . "$CEL_ROOT/lib/afk.sh"; cmd_afk log')" "partial" \
    || { _afk_teardown; return 1; }
  _afk_teardown
}

# AFK STATE IS REPLACED, NEVER REWRITTEN IN PLACE: a reader sees the old
# document or the new one, never an empty or half-written one.
test_regression_afk_on_and_off_replace_the_state_file_atomically() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  local i1 i2 i3
  i1="$(stat -c %i "$CEL_AFK_STATE/state.json")"
  cmd_afk off >/dev/null
  i2="$(stat -c %i "$CEL_AFK_STATE/state.json")"
  cmd_afk on --until '+8h' >/dev/null
  i3="$(stat -c %i "$CEL_AFK_STATE/state.json")"
  [ "$i1" != "$i2" ] && [ "$i2" != "$i3" ] || { echo "state.json rewritten in place ($i1 $i2 $i3)"; _afk_teardown; return 1; }
  assert_eq "$(afk_state_json | jq -r .on)" true || { _afk_teardown; return 1; }
  assert_eq "$(find "$CEL_AFK_STATE" -name '.state*' | wc -l)" 0 || { _afk_teardown; return 1; }
  _afk_teardown
}

# Concurrent autonomous acts append one whole line each: the append waits on
# the log lock.
test_regression_afk_record_waits_for_the_log_lock() {
  have flock || return 0
  _afk_setup
  mkdir -p "$CEL_AFK_STATE"
  local lock="$CEL_AFK_STATE/log.lock" holder i rc=0
  ( exec 9>>"$lock"; flock 9; exec sleep 30 ) &
  holder=$!
  for i in $(seq 1 50); do flock -n "$lock" -c true 2>/dev/null || break; sleep 0.1; done
  timeout 2 bash -c '. "$CEL_ROOT/lib/common.sh"; . "$CEL_ROOT/lib/afk.sh"; afk_record land auth detail completed' || rc=$?
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  assert_eq "$rc" 124 || { echo "the append did not wait for the lock"; _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | wc -l)" 0 || { _afk_teardown; return 1; }
  afk_record land auth detail completed || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '.[0].outcome')" completed || { _afk_teardown; return 1; }
  _afk_teardown
}

test_cel_dispatches_afk() {
  _afk_setup
  local out; out="$(CEL_AFK_STATE="$T/afk" "$CEL_ROOT/bin/cel" afk status)"
  assert_contains "$out" "AFK is off"
  assert_contains "$("$CEL_ROOT/bin/cel" help)" "cel afk"
  _afk_teardown
}

# THE DOOR REFUSES A LANDING THAT IS NOT THE PRODUCT'S OWN PR. `cel solo land`
# proves the author against the workspace's own GitHub identity before it gets
# here; this is the second wall, the one still standing if the first moved.
test_the_door_refuses_a_landing_whose_author_is_not_solo() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_admit land "$(_ev_land '{"author":"someone-else"}')" 2>&1)" \
    "not this product's own PR"
  assert_contains "$(afk_admit land "$(_ev_land '{"author":"fleet"}')" 2>&1)" \
    "not this product's own PR"
  assert_eq "$(afk_log_json | jq -sr 'length')" 0
  _afk_teardown
}

# ------------------------------------------- pre-authorisation 1's entry point
test_cel_afk_resolve_thread_refuses_without_evidence_and_posts_nothing() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_fails cmd_afk resolve-thread alpha/widget 71 THREAD_1 --summary 'x' --verdict-at '2026-09-22T02:00:00Z'
  assert_eq "$(cat "$T/gh.log")" ""
  _afk_teardown
}

test_cel_afk_resolve_thread_replies_with_the_commit_and_resolves() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  cmd_afk resolve-thread alpha/widget 71 THREAD_1 \
    --commit abc1234 --summary 'the unguarded grep now appends || true' \
    --fixed-at '2026-09-22T01:00:00Z' --verdict-at '2026-09-22T02:00:00Z' >/dev/null \
    || { cat "$T/gh.log"; _afk_teardown; return 1; }
  local log; log="$(cat "$T/gh.log")"
  assert_contains "$log" "THREAD_1"
  assert_contains "$log" "abc1234"
  assert_contains "$log" "resolveReviewThread"
  _afk_teardown
}

# ------------------------------------------- pre-authorisation 3's entry point
# A REAL REBASE, ON A REAL BRANCH, AGAINST A REAL REMOTE. The evidence is
# derived from git here rather than passed in: whoever calls this cannot tell it
# that a conflicting branch is clean.
_afk_git_fixture() { # <conflicting 0|1> <unpushed 0|1>
  _afk_setup
  local g="git -c user.email=t@t -c user.name=t"
  git init -q --bare "$T/remote.git"
  git -C "$T/remote.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$T/remote.git" "$T/wt" 2>/dev/null
  # shellcheck disable=SC2086
  (cd "$T/wt" && printf 'base\n' > f.txt && $g add -A && $g commit -qm base && git push -q origin HEAD:main)
  (cd "$T/wt" && git checkout -q -b WG-1)
  # shellcheck disable=SC2086
  (cd "$T/wt" && printf 'branch\n' > b.txt && $g add -A && $g commit -qm branch && git push -q origin WG-1)
  # another merge lands on main while this branch waits
  git clone -q "$T/remote.git" "$T/other" 2>/dev/null
  (cd "$T/other" && git checkout -q -B main origin/main)
  # shellcheck disable=SC2086
  if [ "$1" -eq 1 ]; then
    (cd "$T/other" && printf 'theirs\n' > b.txt && $g add -A && $g commit -qm theirs && git push -q origin HEAD:main)
  else
    (cd "$T/other" && printf 'other\n' > o.txt && $g add -A && $g commit -qm other && git push -q origin HEAD:main)
  fi
  # shellcheck disable=SC2086
  [ "$2" -eq 1 ] && (cd "$T/wt" && printf 'more\n' >> b.txt && $g add -A && $g commit -qm unpushed)
  (cd "$T/wt" && git fetch -q origin && git remote set-head origin -a >/dev/null 2>&1)
  cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/gh.log"
printf '{"mergeable":"MERGEABLE","state":"OPEN"}'
EOF
  chmod +x "$T/bin/gh"
}

test_afk_rebase_retry_rebases_a_branch_pushed_behind_and_pushes_it() {
  _afk_git_fixture 0 0
  cmd_afk on --until '+8h' >/dev/null
  cmd_afk rebase-retry "$T/wt" --base origin/main >/dev/null || { _afk_teardown; return 1; }
  # the branch now sits on top of the merge that pushed it behind...
  assert_eq "$(git -C "$T/wt" rev-list --count 'HEAD..origin/main')" 0
  # ...and the remote has it, which is what makes the retry a retry
  assert_eq "$(git -C "$T/wt" rev-parse HEAD)" "$(git -C "$T/wt" rev-parse origin/WG-1)"
  assert_contains "$(afk_log_json | jq -sr '.[-1].authorisation')" "pre-authorisation 3"
  _afk_teardown
}

test_afk_rebase_retry_refuses_a_conflict_and_leaves_the_branch_alone() {
  _afk_git_fixture 1 0
  cmd_afk on --until '+8h' >/dev/null
  local before; before="$(git -C "$T/wt" rev-parse HEAD)"
  local out; out="$(cmd_afk rebase-retry "$T/wt" --base origin/main 2>&1)" && { _afk_teardown; return 1; }
  assert_contains "$out" "the rebase conflicts"
  assert_eq "$(git -C "$T/wt" rev-parse HEAD)" "$before"
  assert_eq "$(git -C "$T/wt" rev-parse origin/WG-1)" "$before"
  assert_eq "$(afk_log_json | jq -sr 'length')" 0
  _afk_teardown
}

test_afk_rebase_retry_refuses_a_branch_carrying_unpushed_work() {
  _afk_git_fixture 0 1
  cmd_afk on --until '+8h' >/dev/null
  local out; out="$(cmd_afk rebase-retry "$T/wt" --base origin/main 2>&1)" && { _afk_teardown; return 1; }
  assert_contains "$out" "new work"
  assert_eq "$(afk_log_json | jq -sr 'length')" 0
  _afk_teardown
}

test_regression_afk_rebase_retry_logs_completed_once_the_push_lands() {
  _afk_git_fixture 0 0
  cmd_afk on --until '+8h' >/dev/null
  cmd_afk rebase-retry "$T/wt" --base origin/main >/dev/null 2>&1 || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr 'length')" 1 || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '.[-1].outcome')" completed || { _afk_teardown; return 1; }
  _afk_teardown
}

# Rebased here, refused there: the worktree moved but the PR did not, and the
# log says exactly that instead of "rebased and pushed".
test_regression_afk_rebase_retry_logs_partial_when_the_push_is_refused() {
  _afk_git_fixture 0 0
  git -C "$T/wt" remote set-url --push origin "$T/nowhere.git"
  cmd_afk on --until '+8h' >/dev/null
  local out; out="$(cmd_afk rebase-retry "$T/wt" --base origin/main 2>&1)" && { _afk_teardown; return 1; }
  assert_contains "$out" "push was refused" || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr 'length')" 1 || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '.[-1].outcome')" partial || { _afk_teardown; return 1; }
  _afk_teardown
}

test_afk_rebase_retry_refuses_while_afk_is_off() {
  _afk_git_fixture 0 0
  local out; out="$(cmd_afk rebase-retry "$T/wt" --base origin/main 2>&1)" && { _afk_teardown; return 1; }
  assert_contains "$out" "AFK is off"
  _afk_teardown
}

test_afk_release_needs_a_recorded_allowance() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_admit release '{"product":"widget","version":"0.3.0"}' 2>&1)" \
    "no owner instruction"
  cmd_afk on --until '+8h' --allow release:widget@0.3.0 >/dev/null
  afk_admit release '{"product":"widget","version":"0.3.0"}' || { _afk_teardown; return 1; }
  assert_contains "$(afk_admit release '{"product":"widget","version":"0.4.0"}' 2>&1)" \
    "no owner instruction"
  _afk_teardown
}

test_afk_on_lists_what_keeps_moving() {
  _afk_setup
  local out; out="$(cmd_afk on --until '+8h' --allow release:widget@0.3.0 2>&1)"
  assert_contains "$out" "pre-authorisation 1"
  assert_contains "$out" "pre-authorisation 3"
  assert_contains "$out" "release:widget@0.3.0"
  _afk_teardown
}
