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

# =========================================================== round 1 review
# THE DOOR HAS TO BE REACHED FROM A REAL ACT. Everything above proves
# `afk_authorise` refuses when it is called; PR #82's review found that the two
# mutating call sites recorded the act AFTER doing it and never went through the
# door at all, and that two of the four pre-authorisations had no caller
# anywhere outside this file. A refusal that only exists in a unit test is the
# gap this ticket is about. So: the fanout binary is driven end to end against
# stubs, and the assertion is on what the stub was NOT asked to do.
BIN="$CEL_ROOT/core/skills/fanout/bin/cel-fanout"

_afk_fanout_setup() {
  T="$(mktemp -d)"
  export CEL_AFK_STATE="$T/afk"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  yq -y '.policy.merge = "self"' "$T/workspace.yaml" > "$T/ws.tmp" && mv "$T/ws.tmp" "$T/workspace.yaml"
  mkdir -p "$T/repos/widget"; git -C "$T/repos/widget" init -q
  STUB_WT="$T/widget-worker"; mkdir -p "$STUB_WT"
  git -C "$STUB_WT" init -q
  git -C "$STUB_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$STUB_WT" update-ref refs/remotes/origin/main HEAD
  git -C "$STUB_WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  STUB_REPO="$(git -C "$T/repos/widget" rev-parse --show-toplevel)"
  STUB_LOG="$T/stub.log"; : > "$STUB_LOG"
  cat > "$T/herdr-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$STUB_LOG"
case "$1 $2" in
  "worktree create") echo '{"result":{"workspace_id":"wZ","pane_id":"wZ:p1","checkout_path":"'"$STUB_WT"'"}}';;
  "workspace list")  echo '{"result":{"workspaces":[{"workspace_id":"wY","worktree":{"repo_root":"'"$STUB_REPO"'","is_linked_worktree":false}}]}}';;
  "pane split")      echo '{"result":{"pane":{"pane_id":"wZ:p9"}}}';;
  "agent list")      echo '{"result":{"agents":[{"pane_id":"wZ:p1","agent_status":"idle"}]}}';;
  *) echo '{}';;
esac
EOF
  chmod +x "$T/herdr-stub.sh"
  export CEL_FANOUT_HERDR="$T/herdr-stub.sh" STUB_LOG STUB_WT STUB_REPO
  GH_LOG="$T/gh.log"; : > "$GH_LOG"
  cat > "$T/gh-stub.sh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "api user") echo fleetbot;;
  "pr view")  echo '{"number":7,"author":{"login":"fleetbot"},"reviewDecision":"APPROVED","isDraft":false,"mergeable":"MERGEABLE","state":"OPEN","statusCheckRollup":[{"conclusion":"SUCCESS"}]}';;
  "pr merge") exit 0;;
  *) echo '{}';;
esac
EOF
  chmod +x "$T/gh-stub.sh"; export CEL_FANOUT_GH="$T/gh-stub.sh" CEL_AFK_GH="$T/gh-stub.sh" GH_LOG
  cat > "$T/verify-stub.sh" <<'EOF'
#!/usr/bin/env bash
wt="$1"; mkdir -p "$wt/.agent"
printf '{"at":"x","gate":{"configured":true,"passed":true},"tests":{"red_then_green":true},"diff":{"files":1},"checks":{"state":"SUCCESS"},"review":{"decision":"APPROVED"}}' > "$wt/.agent/verdict.json"
echo "verdict gate:PASS"
EOF
  chmod +x "$T/verify-stub.sh"; export CEL_FANOUT_VERIFY="$T/verify-stub.sh"
  # A spec that says where its finding came from, which is what
  # pre-authorisation 4 is about.
  printf 'Finding-from: reviewer widget-pr-7-review\n\n> the retry path has no test\n\ndo the thing\n' > "$T/spec.md"
  printf 'do the thing\n' > "$T/bare-spec.md"
}
_afk_fanout_teardown() {
  rm -rf "$T"
  unset CEL_AFK_STATE CEL_FANOUT_HERDR CEL_FANOUT_GH CEL_FANOUT_VERIFY CEL_AFK_GH
}

# THE LANDING GOES THROUGH THE DOOR BEFORE IT MERGES. AFK armed over another
# workspace is AFK that authorises nothing here - and the proof is that `gh pr
# merge` was never called, not that a message was printed afterwards.
test_land_while_afk_is_scoped_elsewhere_refuses_before_merging() {
  _afk_fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-LAND "$T/spec.md") > /dev/null
  cmd_afk on --until '+8h' --scope beta >/dev/null
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )" && {
    echo "landed under an AFK armed over another workspace"; _afk_fanout_teardown; return 1; }
  assert_contains "$out" "another orchestrator's workspace"
  ! grep -q "^pr merge" "$GH_LOG" || {
    echo "it merged and refused afterwards - the door is downstream of the act"; _afk_fanout_teardown; return 1; }
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" running
  _afk_fanout_teardown
}

# ...and when it does authorise, the act is recorded with the pre-authorisation
# that covered it, from the real landing rather than from a hand-built object.
test_land_while_afk_is_on_passes_the_door_and_is_recorded() {
  _afk_fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-LAND "$T/spec.md") > /dev/null
  cmd_afk on --until '+8h' --scope alpha >/dev/null
  (cd "$T" && "$BIN" land WG-LAND) > /dev/null || { _afk_fanout_teardown; return 1; }
  grep -q "^pr merge 7" "$GH_LOG" || { echo "did not merge"; _afk_fanout_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr '[.[] | select(.act == "land")] | length')" 1
  assert_contains "$(afk_log_json | jq -sr '.[-1].authorisation')" "pre-authorisation 2"
  assert_contains "$(afk_log_json | jq -sr '.[-1].detail')" "#7"
  _afk_fanout_teardown
}

# ---------------------------------------------------------- round 2 review
# WHOSE PR IS THIS. `land` proves the author against the fleet's own GitHub
# identity on every path - the guard sits above the split between a GitHub
# approval and the ledger verdict - so a colleague's PR never reaches the AFK
# door at all. That is asserted here rather than argued: AFK on, an approved
# green PR opened by someone else, and NOTHING merges and nothing is recorded
# as an autonomous act. The evidence object derives `author` from the same two
# values that guard rather than stating it, so the two cannot drift apart.
_afk_fanout_foreign_author() {
  cat > "$T/gh-stub.sh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "api user") echo fleetbot;;
  "pr view")  echo '{"number":7,"author":{"login":"someone-else"},"reviewDecision":"APPROVED","isDraft":false,"mergeable":"MERGEABLE","state":"OPEN","statusCheckRollup":[{"conclusion":"SUCCESS"}]}';;
  "pr merge") exit 0;;
  *) echo '{}';;
esac
EOF
  chmod +x "$T/gh-stub.sh"
}

test_land_while_afk_is_on_never_merges_a_colleagues_pr() {
  _afk_fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-LAND "$T/spec.md") > /dev/null
  cmd_afk on --until '+8h' --scope alpha >/dev/null
  _afk_fanout_foreign_author
  : > "$GH_LOG"
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )" && {
    echo "landed a PR this fleet did not open"; _afk_fanout_teardown; return 1; }
  assert_contains "$out" "theirs to land"
  ! grep -q "^pr merge" "$GH_LOG" || { echo "it merged a colleague's PR"; _afk_fanout_teardown; return 1; }
  # ...and no autonomous act is recorded for something that never happened.
  assert_eq "$(afk_log_json | jq -sr '[.[] | select(.act == "land")] | length')" 0
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" running
  _afk_fanout_teardown
}

# AND THE DOOR ITSELF STILL REFUSES IT. The guard above is the first wall; this
# is the second, and it is the one that would still be standing if the first
# ever moved - which is the only reason the evidence carries an author field at
# all. `unknown` is what the derivation yields when the fleet's identity cannot
# be read: an account this process could not name is not this fleet.
test_the_door_refuses_a_landing_whose_author_is_not_the_fleet() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_authorise land "$(_ev_land '{"author":"someone-else"}')" 2>&1)" \
    "not this fleet's PR"
  assert_contains "$(afk_authorise land "$(_ev_land '{"author":"unknown"}')" 2>&1)" \
    "not this fleet's PR"
  assert_eq "$(afk_log_json | jq -sr 'length')" 0
  _afk_teardown
}

# A SPEC THAT NAMES NO FINDING IS NOT DISPATCHED OVERNIGHT. Pre-authorisation 4
# is "a follow-up a reviewer or scout documented", and the refusal has to land
# before a worktree, a pane or an agent exists - a worker spawned at 04:00 and
# then disowned is worse than one never started.
test_dispatch_while_afk_is_on_refuses_a_spec_with_no_written_finding() {
  _afk_fanout_setup
  cmd_afk on --until '+8h' --scope alpha >/dev/null
  local out; out="$( (cd "$T" && "$BIN" delegate widget WG-NEW "$T/bare-spec.md") 2>&1 )" && {
    echo "dispatched a spec with no finding behind it"; _afk_fanout_teardown; return 1; }
  assert_contains "$out" "no reviewer or scout finding"
  ! grep -q "^worktree create" "$STUB_LOG" || {
    echo "a worktree was created before the door was asked"; _afk_fanout_teardown; return 1; }
  [ ! -s "$T/.cel/delegations.json" ] || assert_eq "$(jq -r 'length' "$T/.cel/delegations.json")" 0
  _afk_fanout_teardown
}

test_dispatch_while_afk_is_on_proceeds_from_a_documented_finding() {
  _afk_fanout_setup
  cmd_afk on --until '+8h' --scope alpha >/dev/null
  (cd "$T" && "$BIN" delegate widget WG-NEW "$T/spec.md") > /dev/null || { _afk_fanout_teardown; return 1; }
  grep -q "^worktree create" "$STUB_LOG" || { echo "nothing was dispatched"; _afk_fanout_teardown; return 1; }
  assert_contains "$(afk_log_json | jq -sr '.[-1].authorisation')" "pre-authorisation 4"
  assert_contains "$(afk_log_json | jq -sr '.[-1].detail')" "widget/WG-NEW"
  _afk_fanout_teardown
}

# AND AFK OFF CHANGES NOTHING ABOUT ORDINARY WORK. The convention this adds to
# specs is read only while AFK is on; an operator at the keyboard delegates the
# same specs they always did.
test_afk_off_leaves_an_ordinary_dispatch_and_landing_alone() {
  _afk_fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-LAND "$T/bare-spec.md") > /dev/null \
    || { echo "AFK off blocked an ordinary dispatch"; _afk_fanout_teardown; return 1; }
  (cd "$T" && "$BIN" land WG-LAND) > /dev/null || { _afk_fanout_teardown; return 1; }
  grep -q "^pr merge 7" "$GH_LOG" || { echo "AFK off blocked an ordinary landing"; _afk_fanout_teardown; return 1; }
  assert_eq "$(afk_log_json | jq -sr 'length')" 0
  _afk_fanout_teardown
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

test_afk_rebase_retry_refuses_while_afk_is_off() {
  _afk_git_fixture 0 0
  local out; out="$(cmd_afk rebase-retry "$T/wt" --base origin/main 2>&1)" && { _afk_teardown; return 1; }
  assert_contains "$out" "AFK is off"
  _afk_teardown
}

# ============================================================ CEL-78
# ORDERED WORK DOES NOT STOP WHEN THE OWNER STEPS AWAY. A spec already written
# under .cel/specs/ before AFK went on is work somebody ordered awake.
test_afk_ordered_spec_written_before_afk_is_authorised_and_logged() {
  _afk_setup
  mkdir -p "$T/ws/.cel/specs"; printf 'x\n' > "$T/ws/.cel/specs/CEL-1.md"
  touch -d '-1 hour' "$T/ws/.cel/specs/CEL-1.md"
  cmd_afk on --until '+8h' >/dev/null
  afk_spec_ordered "$T/ws/.cel/specs/CEL-1.md" || { _afk_teardown; return 1; }
  local out; out="$(afk_authorise ordered_work "$(afk_ordered_evidence "$T/ws/.cel/specs/CEL-1.md" 1 4)" 2>&1)" \
    || { echo "$out"; _afk_teardown; return 1; }
  assert_contains "$out" "pre-authorisation 5"
  assert_contains "$(afk_log_json | jq -r .detail)" "CEL-1.md"
  assert_contains "$(afk_log_json | jq -r .detail)" "mtime"
  _afk_teardown
}

test_afk_spec_written_after_afk_with_no_finding_is_refused() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  mkdir -p "$T/ws/.cel/specs"; printf 'x\n' > "$T/ws/.cel/specs/CEL-2.md"
  touch -d '+1 minute' "$T/ws/.cel/specs/CEL-2.md"
  assert_fails afk_spec_ordered "$T/ws/.cel/specs/CEL-2.md"
  assert_contains "$(afk_authorise ordered_work "$(afk_ordered_evidence "$T/ws/.cel/specs/CEL-2.md" 1 4)" 2>&1)" \
    "written after AFK went on"
  assert_contains "$(afk_authorise dispatch "$(_ev_dispatch '{"source":"none"}')" 2>&1)" \
    "no reviewer or scout finding"
  # Outside .cel/specs is not ordered work either.
  printf 'x\n' > "$T/loose.md"; touch -d '-1 hour' "$T/loose.md"
  assert_fails afk_spec_ordered "$T/loose.md"
  _afk_teardown
}

test_afk_release_needs_a_recorded_allowance() {
  _afk_setup
  cmd_afk on --until '+8h' >/dev/null
  assert_contains "$(afk_authorise release '{"product":"widget","version":"0.3.0"}' 2>&1)" \
    "no owner instruction"
  cmd_afk on --until '+8h' --allow release:widget@0.3.0 >/dev/null
  afk_authorise release '{"product":"widget","version":"0.3.0"}' >/dev/null || { _afk_teardown; return 1; }
  assert_contains "$(afk_authorise release '{"product":"widget","version":"0.4.0"}' 2>&1)" \
    "no owner instruction"
  assert_eq "$(afk_log_json | jq -sr '[.[] | select(.act=="release")] | length')" 1
  _afk_teardown
}

test_afk_on_lists_what_keeps_moving() {
  _afk_setup
  local out; out="$(cmd_afk on --until '+8h' --allow release:widget@0.3.0 2>&1)"
  assert_contains "$out" "pre-authorisation 1"
  assert_contains "$out" "pre-authorisation 5"
  assert_contains "$out" "release:widget@0.3.0"
  _afk_teardown
}
