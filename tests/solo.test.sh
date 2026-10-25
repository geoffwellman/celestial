# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/solo.sh"

# A products workspace with `bundle` (widget+gadget) in solo mode and merge:
# self; `lone` stays fleet. GitHub is a stub: PR #7 on widget, head H, opened
# by this workspace's account `fleetbot`, `suite` the protected check.
H=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
_solo_setup() { # [author] [reviewDecision] [rollup-conclusion] [draft] [state]
  T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-products/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget" "$T/repos/gadget" "$T/repos/lone" "$T/.cel"
  sed -i 's/merge: humans-only/merge: self/' "$T/workspace.yaml"
  ( cd "$T" && cmd_mode bundle solo --no-restart ) >/dev/null
  GH_LOG="$T/gh.log"; : > "$GH_LOG"
  export STUB_HEAD="$H" STUB_CHECKS='{"check_runs":[{"name":"suite","conclusion":"success"}]}'
  export STUB_ROLLUP_DEFAULT="[{\"conclusion\":\"${3:-SUCCESS}\"}]"
  cat > "$T/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "api user") echo fleetbot;;
  "pr view")  echo '{"number":7,"author":{"login":"${1:-fleetbot}"},"reviewDecision":"${2:-}","isDraft":${4:-false},"mergeable":"'"\${STUB_MERGEABLE:-MERGEABLE}"'","state":"${5:-OPEN}","headRefOid":"'"\$STUB_HEAD"'","baseRefName":"main","statusCheckRollup":'"\${STUB_ROLLUP:-\$STUB_ROLLUP_DEFAULT}"'}';;
  "pr merge") exit 0;;
  *) case "\$2" in
       */protection) case "\${STUB_UNPROTECTED:-}" in
                       1) echo '{"message":"Branch not protected","status":"404"}'; echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1;;
                       err) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1;;
                     esac
                     echo '{"required_status_checks":{"contexts":["suite"]}}';;
       *check-runs)  printf '%s' "\$STUB_CHECKS";;
       *) echo '{}';;
     esac;;
esac
EOF
  chmod +x "$T/gh"; export GH="$T/gh"
}
_land() { ( cd "$T" && cmd_solo_land "$@" ); }
_review() { ( cd "$T" && cmd_solo_review "$@" ); }
_merged() { grep -q "^pr merge 7" "$GH_LOG"; }

test_solo_land_merges_an_approved_green_pr_pinned_to_its_head() {
  _solo_setup
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  _land widget#7 >/dev/null || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  grep -q "^pr merge 7 --repo someone/widget --squash --delete-branch --match-head-commit $H" "$GH_LOG" \
    || { echo "merge not pinned to the reviewed head"; cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "Reviewed-by: widget-pr-7-review (approved)"
  assert_contains "$(cat "$GH_LOG")" "Gate: CI (suite) on $H"
  rm -rf "$T"
}
test_solo_land_accepts_a_github_approval_too() {
  _solo_setup fleetbot APPROVED
  _land widget#7 >/dev/null && _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_solo_land_refuses_without_approval() {
  _solo_setup
  local out; out="$(_land widget#7 2>&1)" && { echo "merged unreviewed"; rm -rf "$T"; return 1; }
  assert_contains "$out" "not approved"
  ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# The approval covers the commit reviewed; a push after it is unreviewed code.
test_solo_land_refuses_an_approval_of_an_older_head() {
  _solo_setup
  _review widget#7 approved --head "$H" --by r >/dev/null
  export STUB_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local out; out="$(_land widget#7 2>&1)" && { echo "merged a moved head"; rm -rf "$T"; return 1; }
  assert_contains "$out" "moved since its review"
  ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_solo_land_refuses_a_changes_verdict() {
  _solo_setup
  _review widget#7 changes --head "$H" --by r >/dev/null
  ! _land widget#7 >/dev/null 2>&1 || { echo "merged on changes"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_solo_land_refuses_a_red_check() {
  _solo_setup fleetbot APPROVED FAILURE
  ! _land widget#7 >/dev/null 2>&1 && ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# Green on SOME check is not green on the one that gates the branch.
test_solo_land_refuses_when_the_protected_check_is_not_green() {
  _solo_setup fleetbot APPROVED
  export STUB_CHECKS='{"check_runs":[{"name":"docs","conclusion":"success"}]}'
  local out; out="$(_land widget#7 2>&1)" && { echo "merged without the suite"; rm -rf "$T"; return 1; }
  assert_contains "$out" "suite"
  ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A latest run still going is not green.
test_solo_land_refuses_a_check_still_running() {
  _solo_setup fleetbot APPROVED
  export STUB_ROLLUP='[{"name":"suite","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-10-25T09:00:00Z"}]'
  local out; out="$(_land widget#7 2>&1)" && { echo "merged with a running check"; unset STUB_ROLLUP; rm -rf "$T"; return 1; }
  assert_contains "$out" "still has check(s) running: suite"
  unset STUB_ROLLUP; ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A base branch that gates nothing: the repo's own gate runs in a clean
# checkout at exactly the PR head, and its result decides.
_solo_gate_repo() { # <gate-cmd> -> sets STUB_HEAD to a real commit in repos/widget
  local r="$T/repos/widget"
  git -C "$r" init -q && git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
  STUB_HEAD="$(git -C "$r" rev-parse HEAD)"; export STUB_HEAD STUB_UNPROTECTED=1
  yq -y --arg g "$1" '(.repos[] | select(.name == "widget")).gate = $g' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
}
test_solo_land_runs_the_repo_gate_when_the_base_gates_nothing() {
  _solo_setup fleetbot APPROVED; _solo_gate_repo "touch $T/gate-ran"
  _land widget#7 >/dev/null 2>&1 || { echo "refused a passing local gate"; unset STUB_UNPROTECTED; rm -rf "$T"; return 1; }
  [ -f "$T/gate-ran" ] || { echo "gate did not run"; unset STUB_UNPROTECTED; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "Gate: local"
  unset STUB_UNPROTECTED; rm -rf "$T"
}
test_solo_land_refuses_a_failing_repo_gate_or_no_checkout_at_the_head() {
  _solo_setup fleetbot APPROVED; _solo_gate_repo 'exit 3'
  local out; out="$(_land widget#7 2>&1)" && { echo "merged on a red local gate"; unset STUB_UNPROTECTED; rm -rf "$T"; return 1; }
  assert_contains "$out" "did not pass"
  ! _merged || { unset STUB_UNPROTECTED; rm -rf "$T"; return 1; }
  export STUB_HEAD=cccccccccccccccccccccccccccccccccccccccc
  out="$(_land widget#7 2>&1)" && { echo "merged with no checkout at the head"; unset STUB_UNPROTECTED; rm -rf "$T"; return 1; }
  assert_contains "$out" "no clean checkout"
  unset STUB_UNPROTECTED; rm -rf "$T"
}
# Only GitHub's "Branch not protected" opens the local path; any other failure
# to read protection is unknown and refuses. A gate that changes the tree
# proves nothing about the head.
test_solo_land_refuses_unreadable_protection_and_a_gate_that_dirties_the_tree() {
  _solo_setup fleetbot APPROVED; _solo_gate_repo "touch $T/gate-ran"
  export STUB_UNPROTECTED=err
  local out; out="$(_land widget#7 2>&1)" && { echo "merged on unreadable protection"; unset STUB_UNPROTECTED; rm -rf "$T"; return 1; }
  [ ! -f "$T/gate-ran" ] || { echo "ran the local gate on a 403"; unset STUB_UNPROTECTED; rm -rf "$T"; return 1; }
  ! _merged || { unset STUB_UNPROTECTED; rm -rf "$T"; return 1; }
  rm -rf "$T"
  _solo_setup fleetbot APPROVED; _solo_gate_repo 'touch made-by-gate'
  out="$(_land widget#7 2>&1)" && { echo "merged after the gate dirtied the tree"; unset STUB_UNPROTECTED; rm -rf "$T"; return 1; }
  assert_contains "$out" "changed files"
  unset STUB_UNPROTECTED; rm -rf "$T"
}
test_solo_land_refuses_someone_elses_pr_a_draft_and_humans_only() {
  _solo_setup someone-else APPROVED
  ! _land widget#7 >/dev/null 2>&1 || { echo "landed a colleague's PR"; rm -rf "$T"; return 1; }
  rm -rf "$T"
  _solo_setup fleetbot APPROVED SUCCESS true
  ! _land widget#7 >/dev/null 2>&1 || { echo "landed a draft"; rm -rf "$T"; return 1; }
  rm -rf "$T"
  _solo_setup fleetbot APPROVED; sed -i 's/merge: self/merge: humans-only/' "$T/workspace.yaml"
  ! _land widget#7 >/dev/null 2>&1 && ! _merged || { echo "landed under humans-only"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A fleet product's PR is a delegation: it has its own door.
test_solo_refuses_a_fleet_products_pr() {
  _solo_setup fleetbot APPROVED
  local out; out="$(_land lone#7 2>&1)" && { echo "landed a fleet PR"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cel-fanout land"
  rm -rf "$T"
}
test_solo_land_refuses_a_conflicted_pr() {
  _solo_setup fleetbot APPROVED; export STUB_MERGEABLE=CONFLICTING
  local out; out="$(_land widget#7 2>&1)" && { rm -rf "$T"; return 1; }
  assert_contains "$out" "conflicts"; ! _merged || { rm -rf "$T"; return 1; }
  unset STUB_MERGEABLE; rm -rf "$T"
}
# While AFK is on, the merge also needs AFK's authorisation; a refusal stops it.
test_solo_land_stops_when_afk_refuses() {
  _solo_setup fleetbot APPROVED
  afk_active() { return 0; }
  afk_authorise() { printf '%s' "$2" > "$T/afk-asked"; return 1; }
  ! _land widget#7 >/dev/null 2>&1 && ! _merged || { echo "merged although AFK refused"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r .approved_via "$T/afk-asked")" "GitHub approval"
  rm -rf "$T"
}
# The squash body lands on main; a ticket-shaped token there would fail every
# later PR's history scan, so the merge is refused before it happens.
test_solo_land_refuses_a_review_note_the_history_scan_would_reject() {
  _solo_setup
  # built at runtime, as in fanout.test.sh, so the tree scan never sees it
  local bad="ZZQ-$((6*2))"
  _review widget#7 approved --head "$H" --by r --note "see $bad" >/dev/null
  local out; out="$(_land widget#7 2>&1)" && { echo "merged a dirty body"; rm -rf "$T"; return 1; }
  assert_contains "$out" "$bad"; ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# The author does not approve its own work, and a reviewer or worker does not
# merge - whatever pane they run from.
test_solo_agent_cannot_review_its_own_pr() {
  _solo_setup
  ! ( cd "$T" && CEL_ROLE=solo cmd_solo_review widget#7 approved --head "$H" --by me ) >/dev/null 2>&1 \
    || { echo "the author approved itself"; rm -rf "$T"; return 1; }
  assert_eq "$(solo_review_get "$T" widget 7)" ""
  rm -rf "$T"
}
test_solo_land_refuses_reviewers_and_workers() {
  _solo_setup fleetbot APPROVED
  local r
  for r in reviewer worker; do
    ! ( cd "$T" && CEL_ROLE=$r cmd_solo_land widget#7 ) >/dev/null 2>&1 || { echo "$r landed"; rm -rf "$T"; return 1; }
  done
  ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# --- review records ----------------------------------------------------------
test_solo_review_approval_must_be_the_current_head() {
  _solo_setup
  ! _review widget#7 approved --head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --by r >/dev/null 2>&1 \
    || { echo "recorded an approval of a stale head"; rm -rf "$T"; return 1; }
  assert_eq "$(solo_review_get "$T" widget 7)" ""
  rm -rf "$T"
}
test_solo_review_refuses_abbreviated_heads_and_anonymous_verdicts() {
  _solo_setup
  ! _review widget#7 approved --head aaaaaaa --by r >/dev/null 2>&1 || { rm -rf "$T"; return 1; }
  ! _review widget#7 approved --head "$H" >/dev/null 2>&1 || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_solo_review_latest_verdict_wins_per_pr() {
  _solo_setup
  _review widget#7 approved --head "$H" --by r >/dev/null
  _review widget#7 changes --head "$H" --by r --note "found one" >/dev/null
  assert_eq "$(solo_review_get "$T" widget 7 | jq -r .verdict)" changes
  # and a bare number resolves only when the product has one repo (bundle has two)
  ! _review 7 changes --head "$H" --by r >/dev/null 2>&1 || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A corrupt verdict file is moved aside, never silently emptied: replacing it
# with {} would erase every other PR's verdict without a word.
test_solo_review_moves_a_corrupt_file_aside_and_records_nothing() {
  _solo_setup
  printf 'not json' > "$T/.cel/solo-reviews.json"
  ! _review widget#7 changes --head "$H" --by r >/dev/null 2>&1 || { rm -rf "$T"; return 1; }
  [ ! -e "$T/.cel/solo-reviews.json" ] || { echo "corrupt file still in place"; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T"/.cel/solo-reviews.json.corrupt-*)" "not json"
  rm -rf "$T"
}
# A bare number names the PR when the product has exactly one repo.
test_solo_review_bare_number_on_a_one_repo_product() {
  _solo_setup; ( cd "$T" && cmd_mode lone solo --no-restart ) >/dev/null
  ( cd "$T/repos/lone" && cmd_solo_review 7 changes --head "$H" --by r ) >/dev/null || { rm -rf "$T"; return 1; }
  assert_eq "$(solo_review_get "$T" lone 7 | jq -r .verdict)" changes
  rm -rf "$T"
}

# The reviewer of a solo PR is told the solo commands and who to report to.
test_solo_reviewer_brief_names_solo_commands_only_for_solo_products() {
  _solo_setup
  source "$CEL_ROOT/lib/run.sh"
  local b; b="$(_run_reviewer_solo_brief "$T" widget 7)"
  assert_contains "$b" "cel solo review widget#7"
  assert_contains "$b" "bundle-orch"
  assert_eq "$(_run_reviewer_solo_brief "$T" lone 7)" ""
  rm -rf "$T"
}
