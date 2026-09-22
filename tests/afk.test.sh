# shellcheck shell=bash
# `cel afk` - what the factory may decide while nobody is watching.
#
# AFK CHANGES WHO DECIDES, NEVER WHAT IS REQUIRED. Measured over 2026-09-20/22:
# an approved, green, gate-verified PR sat 36 hours on two bot-review threads a
# human had to type a reply into; two more paused on "shall I land this?" when
# the workspace policy already said `merge: self`. None of that is a safety
# property - so the four acts below are pre-authorised, each on its own
# evidence, and every refusal here is one an agent used to make by waiting.
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
    mergeable: true, author: "fleet", pr: 71
  } * $o'
}
_ev_rebase() {
  jq -nc --argjson o "${1:-{\}}" '{
    was_mergeable: true, behind: true, new_work: false, conflicts: false, pr: 71
  } * $o'
}
_ev_dispatch() {
  jq -nc --argjson o "${1:-{\}}" '{
    source: "reviewer", quote: "the retry path has no test",
    workers: 2, cap: 4, quota_pct: 40, quota_floor: 20
  } * $o'
}

# ---------------------------------------------------------------- AFK is off
# THE REGRESSION THAT KEEPS AFK FROM BECOMING THE DEFAULT. With no AFK on,
# every one of the four acts waits, exactly as it did before this file existed.
test_afk_off_every_pre_authorised_act_still_waits() {
  _afk_setup
  local act out
  for act in resolve_thread land rebase_retry dispatch; do
    out="$(afk_authorise "$act" "$(_ev_land)" 2>&1)" && { _afk_teardown; return 1; }
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
  afk_authorise resolve_thread "$(_ev_thread)" >/dev/null || { _afk_teardown; return 1; }
  afk_authorise land          "$(_ev_land)"    >/dev/null || { _afk_teardown; return 1; }
  afk_authorise rebase_retry  "$(_ev_rebase)"  >/dev/null || { _afk_teardown; return 1; }
  afk_authorise dispatch      "$(_ev_dispatch)" >/dev/null || { _afk_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '[.[].act] | join(",")')" \
    "resolve_thread,land,rebase_retry,dispatch"
  _afk_teardown
}

# ------------------------------------------------------- §3, one per refusal
test_afk_never_merges_red_unreviewed_or_unmergeable() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_authorise land "$(_ev_land '{"checks":"red"}')" 2>&1)" \
    "a red check is a finding"
  assert_contains "$(afk_authorise land "$(_ev_land '{"review":"none"}')" 2>&1)" \
    "no reviewer verdict"
  assert_contains "$(afk_authorise land "$(_ev_land '{"mergeable":false}')" 2>&1)" \
    "conflicts"
  assert_contains "$(afk_authorise land "$(_ev_land '{"author":"someone-else"}')" 2>&1)" \
    "not this fleet's PR"
  _afk_teardown
}

# CEL-56'S FOURTH OUTCOME. A gate that produced no verdict did not fail and did
# not pass; AFK removes the pause, not the check, so it is not a merge.
test_afk_refuses_a_landing_whose_gate_produced_no_verdict() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_authorise land "$(_ev_land '{"gate":"no_verdict"}')" 2>&1)" \
    "the gate produced no verdict"
  assert_contains "$(afk_authorise land "$(_ev_land '{"gate":"unknown"}')" 2>&1)" \
    "the gate produced no verdict"
  _afk_teardown
}

test_afk_never_resolves_a_thread_whose_finding_is_not_fixed_or_not_confirmed() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_authorise resolve_thread "$(_ev_thread '{"fixed_commit":""}')" 2>&1)" \
    "the finding is not fixed"
  assert_contains "$(afk_authorise resolve_thread "$(_ev_thread '{"reviewer_verdict":"changes"}')" 2>&1)" \
    "no reviewer confirmed the fix"
  # A verdict recorded BEFORE the fix confirms the finding, not the fix.
  assert_contains "$(afk_authorise resolve_thread \
    "$(_ev_thread '{"reviewer_verdict_at":"2026-09-22T00:30:00Z"}')" 2>&1)" \
    "no reviewer confirmed the fix"
  assert_contains "$(afk_authorise resolve_thread "$(_ev_thread '{"bot":false}')" 2>&1)" \
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
  assert_contains "$(afk_authorise rebase_retry "$(_ev_rebase '{"conflicts":true}')" 2>&1)" \
    "the rebase conflicts"
  assert_contains "$(afk_authorise rebase_retry "$(_ev_rebase '{"new_work":true}')" 2>&1)" \
    "new work"
  assert_contains "$(afk_authorise rebase_retry "$(_ev_rebase '{"was_mergeable":false}')" 2>&1)" \
    "was not mergeable"
  _afk_teardown
}

# A QUEUE EMPTIED OVERNIGHT INTO AN EXHAUSTED ACCOUNT HELPS NOBODY.
test_afk_dispatch_needs_a_written_finding_and_respects_cap_and_quota() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_authorise dispatch "$(_ev_dispatch '{"quote":""}')" 2>&1)" \
    "no reviewer or scout finding"
  assert_contains "$(afk_authorise dispatch "$(_ev_dispatch '{"source":"orchestrator"}')" 2>&1)" \
    "no reviewer or scout finding"
  assert_contains "$(afk_authorise dispatch "$(_ev_dispatch '{"workers":4}')" 2>&1)" \
    "worker cap"
  assert_contains "$(afk_authorise dispatch "$(_ev_dispatch '{"quota_pct":10}')" 2>&1)" \
    "quota floor"
  _afk_teardown
}

# AFK never widens its own scope, and never starts work somewhere it was not
# armed: an orchestrator asleep in one product is not an orchestrator loose on
# the box.
test_afk_never_changes_policy_or_its_own_scope() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  local out
  out="$(afk_policy_change_allowed 'branch protection' 2>&1)" && { _afk_teardown; return 1; }
  assert_contains "$out" "AFK never changes policy"
  out="$(afk_policy_change_allowed 'afk scope' 2>&1)" && { _afk_teardown; return 1; }
  _afk_teardown
}

test_afk_refuses_an_act_in_another_orchestrators_workspace() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains \
    "$(afk_authorise land "$(_ev_land '{"workspace":"beta","own_workspace":"alpha"}')" 2>&1)" \
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
  local out; out="$(afk_authorise land "$(_ev_land)" 2>&1)" && { _afk_teardown; return 1; }
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
  afk_authorise land "$(_ev_land)" >/dev/null
  afk_authorise rebase_retry "$(_ev_rebase)" >/dev/null
  # A restart: nothing of this process survives, only the state directory.
  local out
  out="$(bash -c '. "$CEL_ROOT/lib/common.sh"; . "$CEL_ROOT/lib/afk.sh"; cmd_afk log')"
  assert_contains "$out" "land"
  assert_contains "$out" "pre-authorisation 2"
  assert_contains "$out" "rebase_retry"
  assert_contains "$out" "pre-authorisation 3"
  _afk_teardown
}

test_cel_dispatches_afk() {
  _afk_setup
  local out; out="$(CEL_AFK_STATE="$T/afk" "$CEL_ROOT/bin/cel" afk status)"
  assert_contains "$out" "AFK is off"
  assert_contains "$("$CEL_ROOT/bin/cel" help)" "cel afk"
  _afk_teardown
}
