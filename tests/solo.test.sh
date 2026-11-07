# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/solo.sh"
source "$CEL_ROOT/lib/gc.sh"
# A land retires its PR's reviewer through gc.sh's shared target. These
# fixtures own no reviewer and must never read the box's roster; the real
# proof runs in gc-rex-reviewer-retirement.test.sh.
reviewer_retire_target() { printf '%s\n' '{"status":"absent","reason":"no_reviewer_for_pull_request"}'; return 4; }

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
  # the head's checks, latest run of each: `suite`, green unless the third
  # argument (or STUB_ROLLUP) says otherwise
  export STUB_HEAD="$H" STUB_ROLLUP_DEFAULT="[{\"name\":\"suite\",\"conclusion\":\"${3:-SUCCESS}\"}]"
  cat > "$T/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "api user") echo fleetbot;;
  "pr view")  echo '{"number":7,"author":{"login":"${1:-fleetbot}"},"reviewDecision":"${2:-}","isDraft":${4:-false},"mergeable":"'"\${STUB_MERGEABLE:-MERGEABLE}"'","state":"${5:-OPEN}","headRefOid":"'"\$STUB_HEAD"'","baseRefName":"main","statusCheckRollup":'"\${STUB_ROLLUP:-\$STUB_ROLLUP_DEFAULT}"'}';;
  "pr merge") [ -z "\${STUB_MERGE_FAIL:-}" ] || exit 1; exit 0;;
  *) case "\$2" in
       */protection) case "\${STUB_UNPROTECTED:-}" in
                       1) echo '{"message":"Branch not protected","status":"404"}'; echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1;;
                       err) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1;;
                     esac
                     echo '{"required_status_checks":{"contexts":["suite"]}}';;
       */rules/branches/*) [ "\${STUB_RULES:-}" != denied ] || { echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1; }
                           printf '%s' "\${STUB_RULES:-[[]]}";;
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
# The merge ends the review: the PR's reviewer is retired AFTER the merge, and
# a reviewer that has to be kept never turns a merged PR into a failed land.
test_solo_land_retires_the_prs_reviewer_after_the_merge() {
  _solo_setup
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  reviewer_retire_target() {
    { printf '%s ' "$2" "$3" "$4"; if _merged; then echo merged; else echo unmerged; fi; } >> "$T/retire.log"
    printf '%s\n' '{"status":"retired","reason":"runtime_exited_session_absent_evidence_preserved","pane":"rex/review/terminal"}'
  }
  local out; out="$(_land widget#7 2>&1)" || { echo "$out"; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/retire.log")" "widget 7 0 merged" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "retired the Rex reviewer for widget#7 (pane rex/review/terminal)" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_solo_land_succeeds_when_its_reviewer_must_be_kept() {
  local rc
  for rc in 3 2; do
    _solo_setup
    _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
    export STUB_RETIRE_RC="$rc"
    reviewer_retire_target() {
      if [ "$STUB_RETIRE_RC" = 3 ]; then printf '%s\n' '{"status":"protected","reason":"native_retirement_work_owed"}'
      else printf '%s\n' '{"status":"unknown","reason":"native_inventory_unreadable"}'; fi
      return "$STUB_RETIRE_RC"
    }
    local out; out="$(_land widget#7 2>&1)" || { echo "land failed on retirement rc $rc: $out"; rm -rf "$T"; return 1; }
    _merged || { rm -rf "$T"; return 1; }
    case "$rc" in
      3) assert_contains "$out" "kept the reviewer for widget#7: native_retirement_work_owed" ;;
      2) assert_contains "$out" "reviewer retirement for widget#7 is incomplete: native_inventory_unreadable" ;;
    esac || { rm -rf "$T"; return 1; }
    rm -rf "$T"
  done
}
test_solo_land_refused_never_retires_a_reviewer() {
  _solo_setup
  reviewer_retire_target() { : > "$T/retired"; return 0; }
  ! _land widget#7 >/dev/null 2>&1 || { rm -rf "$T"; return 1; }
  [ ! -e "$T/retired" ] || { echo "retired the reviewer of an unmerged PR"; rm -rf "$T"; return 1; }
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
  export STUB_ROLLUP='[{"name":"docs","conclusion":"SUCCESS"}]'
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
# checkout at exactly the PR head, and its result decides. The forge serves
# that head as refs/pull/7/head (a local bare `origin` here).
_solo_gate_repo() { # <gate-cmd> -> sets STUB_HEAD to a real commit in repos/widget
  local r="$T/repos/widget"
  git -C "$r" init -q && git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
  STUB_HEAD="$(git -C "$r" rev-parse HEAD)"; export STUB_HEAD STUB_UNPROTECTED=1
  git init -q --bare "$T/origin.git" && git -C "$r" remote add origin "$T/origin.git"
  git -C "$r" push -q origin "HEAD:refs/pull/7/head"
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
# The head the gate passes must be the one the forge would merge: its
# refs/pull/<n>/head is fetched and must be exactly that commit.
test_solo_land_gate_refuses_a_head_the_forge_does_not_serve() {
  _solo_setup fleetbot APPROVED; _solo_gate_repo "touch $T/gate-ran"
  local r="$T/repos/widget" moved out
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m pushed-later
  moved="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" push -q -f origin "HEAD:refs/pull/7/head"
  git -C "$r" checkout -q --detach "$STUB_HEAD"
  out="$(_land widget#7 2>&1)" && { echo "gated a head the forge does not serve"; rm -rf "$T"; return 1; }
  assert_contains "$out" "refs/pull/7/head is $moved, not $STUB_HEAD" || { rm -rf "$T"; return 1; }
  [ ! -f "$T/gate-ran" ] || { echo "ran the gate anyway"; rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
  git -C "$r" remote remove origin
  out="$(_land widget#7 2>&1)" && { echo "gated without asking the forge"; rm -rf "$T"; return 1; }
  assert_contains "$out" "could not fetch refs/pull/7/head" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
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
# A base gated only by a repository ruleset: classic protection answers
# "Branch not protected", but the ruleset requires `suite`. That check is
# required - land refuses until it is green on the head - and the branch is
# not one "nothing gates", so the local gate never runs in its place. A
# ruleset this token cannot read, or a rule requiring checks it does not
# name, is unknown: refused, local gate not run.
test_solo_land_requires_a_ruleset_check_on_a_base_classic_protection_calls_unprotected() {
  _solo_setup fleetbot APPROVED; _solo_gate_repo "touch $T/gate-ran"
  export STUB_RULES='[[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"suite"}],"strict_required_status_checks_policy":false}}]]'
  export STUB_ROLLUP='[{"name":"docs","conclusion":"SUCCESS"}]'
  local out; out="$(_land widget#7 2>&1)" && { echo "merged with the ruleset's required check absent"; unset STUB_UNPROTECTED STUB_RULES; rm -rf "$T"; return 1; }
  assert_contains "$out" "suite" || { unset STUB_UNPROTECTED STUB_RULES; rm -rf "$T"; return 1; }
  [ ! -f "$T/gate-ran" ] || { echo "took the local-gate path on a ruleset-gated base"; unset STUB_UNPROTECTED STUB_RULES; rm -rf "$T"; return 1; }
  ! _merged || { unset STUB_UNPROTECTED STUB_RULES; rm -rf "$T"; return 1; }
  local rules
  for rules in denied 'not json' '[[{"type":"workflows","parameters":{"workflows":[]}}]]'; do
    export STUB_RULES="$rules"
    out="$(_land widget#7 2>&1)" && { echo "merged on unknown rules ($rules)"; unset STUB_UNPROTECTED STUB_RULES; rm -rf "$T"; return 1; }
    assert_contains "$out" "cannot establish" || { unset STUB_UNPROTECTED STUB_RULES; rm -rf "$T"; return 1; }
    [ ! -f "$T/gate-ran" ] || { echo "ran the local gate on unknown rules ($rules)"; unset STUB_UNPROTECTED STUB_RULES; rm -rf "$T"; return 1; }
  done
  export STUB_RULES='[[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"suite"}],"strict_required_status_checks_policy":false}}]]'
  unset STUB_ROLLUP
  _land widget#7 >/dev/null 2>&1 || { echo "refused a green ruleset check"; unset STUB_UNPROTECTED STUB_RULES; rm -rf "$T"; return 1; }
  [ ! -f "$T/gate-ran" ] || { echo "ran the local gate although CI stood in"; unset STUB_UNPROTECTED STUB_RULES; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "Gate: CI (suite) on $STUB_HEAD"
  unset STUB_UNPROTECTED STUB_RULES; rm -rf "$T"
}
# The gate runs in the caller's own clean checkout at the head, never in a
# reviewer's dependency-less one, even when that one is listed first.
test_solo_land_gate_prefers_the_callers_checkout_over_a_reviewers() {
  _solo_setup fleetbot APPROVED; _solo_gate_repo true
  local r="$T/repos/widget"
  git -C "$r" worktree add -q --detach "$T/state/cel/reviews/widget-pr-7" "$STUB_HEAD"
  git -C "$r" worktree add -q --detach "$T/mine" "$STUB_HEAD"
  # the main checkout ($r) is also clean at the head and listed first
  ( cd "$T/mine" && _solo_local_gate "$T" widget 7 "$STUB_HEAD" "pwd > $T/gate-cwd" ) >/dev/null 2>&1
  assert_eq "$(cat "$T/gate-cwd")" "$(readlink -f "$T/mine")"
  # standing elsewhere: any non-reviewer checkout, never the reviewer's
  ( cd /tmp && _solo_local_gate "$T" widget 7 "$STUB_HEAD" "pwd > $T/gate-cwd" ) >/dev/null 2>&1
  case "$(cat "$T/gate-cwd")" in */cel/reviews/*) echo "gate ran in the reviewer checkout"; rm -rf "$T"; return 1;; esac
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
# A product still declared `mode: fleet` is refused with the retirement line.
test_solo_refuses_a_legacy_fleet_products_pr() {
  _solo_setup fleetbot APPROVED
  local out; out="$( ws_build_mode() { [ "$2" = lone ] && printf fleet || printf solo; }; _land lone#7 2>&1 )" \
    && { echo "landed a fleet PR"; rm -rf "$T"; return 1; }
  assert_contains "$out" "fan-out was retired on 2026-11-08" || { rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
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
  afk_admit() { printf '%s' "$2" > "$T/afk-asked"; return 1; }
  ! _land widget#7 >/dev/null 2>&1 && ! _merged || { echo "merged although AFK refused"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r .approved_via "$T/afk-asked")" "GitHub approval" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r .author "$T/afk-asked")" "solo"
  rm -rf "$T"
}
# ...and a merge AFK let through is logged with how it ended, after the merge
# was tried - not as "authorised" before it.
test_regression_solo_land_under_afk_logs_the_merge_outcome() {
  _solo_setup fleetbot APPROVED
  export CEL_AFK_STATE="$T/afk"
  cmd_afk on --until '+8h' >/dev/null
  STUB_MERGE_FAIL=1 _land widget#7 >/dev/null 2>&1 && { echo "a failed merge reported success"; rm -rf "$T"; return 1; }
  assert_eq "$(afk_log_json | jq -sr '[.[] | select(.act == "land")] | length')" 1 || { rm -rf "$T"; return 1; }
  assert_eq "$(afk_log_json | jq -sr '.[-1].outcome')" failed || { rm -rf "$T"; return 1; }
  _land widget#7 >/dev/null 2>&1 || { rm -rf "$T"; return 1; }
  assert_eq "$(afk_log_json | jq -sr '.[-1].outcome')" completed || { rm -rf "$T"; return 1; }
  assert_contains "$(afk_log_json | jq -sr '.[-1].detail')" "#7" || { rm -rf "$T"; return 1; }
  unset CEL_AFK_STATE; rm -rf "$T"
}
# The squash body lands on main; a ticket-shaped token there would fail every
# later PR's history scan, so the merge is refused before it happens.
test_solo_land_refuses_a_review_note_the_history_scan_would_reject() {
  _solo_setup
  # built at runtime so the tree scan never sees it
  local bad="ZZQ-$((6*2))"
  _review widget#7 approved --head "$H" --by r --note "see $bad" >/dev/null
  local out; out="$(_land widget#7 2>&1)" && { echo "merged a dirty body"; rm -rf "$T"; return 1; }
  assert_contains "$out" "$bad"; ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# ---- a Forgejo repo ----------------------------------------------------------
# widget served by an internal Forgejo (tests/lib/forgejo-stub.sh: spec-
# derived fixtures), its PR opened by the token's owner, `geoff`; the base's
# exact rule requires `ci / test (pull_request)`, green here unless a test
# says otherwise. gh is never asked.
_solo_forgejo() {
  source "$CEL_ROOT/tests/lib/forgejo-stub.sh"; _forgejo_stub "$T"
  yq -y '(.repos[] | select(.name == "widget")) |= (.url = "git@forgejo-ct.internal:geoff/gizmo.git" | .forge = "forgejo" | .host = "http://forgejo.internal")' \
    "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  export STUB_FJ_STATUSES='[{"id":61,"context":"ci / test (pull_request)","status":"success","target_url":"http://forgejo.internal/geoff/gizmo/actions/runs/61/jobs/0"}]'
}
_fj_merged() { grep -q '^POST http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/7/merge' "$FJ_LOG"; }
_fj_msg() { tail -n1 "$FJ_BODY_LOG" | jq -r .MergeMessageField; }

# The live case: an unprotected base (Forgejo's own 404 for the rule, no glob
# matching it), the recorded verdict for the exact head, the repo gate run in
# the clean checkout at that head - fetched as the PR's ref from the forge -
# and a squash merge pinned to it.
test_solo_land_on_forgejo_runs_the_gate_on_an_unprotected_base_and_merges_at_head() {
  _solo_setup; _solo_forgejo; _solo_gate_repo "touch $T/gate-ran"
  export STUB_FJ_HEAD="$STUB_HEAD" STUB_FJ_PROT=none
  _review widget#7 approved --head "$STUB_HEAD" --by widget-pr-7-review >/dev/null || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  local out; out="$(_land widget#7 2>&1)" || { echo "$out"; rm -rf "$T"; return 1; }
  [ -f "$T/gate-ran" ] || { echo "the repo gate did not run"; rm -rf "$T"; return 1; }
  _fj_merged || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(tail -n1 "$FJ_BODY_LOG" | jq -c '[.Do, .head_commit_id, .delete_branch_after_merge]')" "[\"squash\",\"$STUB_HEAD\",true]" || { rm -rf "$T"; return 1; }
  assert_contains "$(_fj_msg)" "Reviewed-by: widget-pr-7-review (approved)" || { rm -rf "$T"; return 1; }
  assert_contains "$(_fj_msg)" "Gate: local \`touch $T/gate-ran\` passed on $STUB_HEAD" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "landed widget#7 on geoff/gizmo" || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$GH_LOG")" "" || { echo "a Forgejo land reached gh"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A protected base: its required check, green on the head, stands in for the
# gate; red or absent refuses; protection that cannot be read is unknown and
# never opens the local path.
test_solo_land_on_forgejo_takes_ci_on_a_protected_base_and_refuses_unknown_protection() {
  _solo_setup; _solo_forgejo; _solo_gate_repo "touch $T/gate-ran"
  export STUB_FJ_HEAD="$STUB_HEAD"
  _review widget#7 approved --head "$STUB_HEAD" --by widget-pr-7-review >/dev/null || { rm -rf "$T"; return 1; }
  local out
  out="$(STUB_FJ_PROT=denied _land widget#7 2>&1)" && { echo "merged on unreadable protection"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cannot establish which checks main on widget requires" || { rm -rf "$T"; return 1; }
  out="$(STUB_FJ_STATUSES='[{"id":61,"context":"ci / test (pull_request)","status":"failure"}]' _land widget#7 2>&1)" && { echo "merged on red"; rm -rf "$T"; return 1; }
  assert_contains "$out" "1 failing check" || { rm -rf "$T"; return 1; }
  out="$(STUB_FJ_STATUSES='[{"id":62,"context":"ci / docs","status":"success"}]' _land widget#7 2>&1)" && { echo "merged without the required check"; rm -rf "$T"; return 1; }
  assert_contains "$out" "required check(s) not green on $STUB_HEAD: ci / test (pull_request)" || { rm -rf "$T"; return 1; }
  out="$(STUB_FJ_STATUSES='[{"id":63,"context":"ci / test (pull_request)","status":"pending"}]' _land widget#7 2>&1)" && { echo "merged a running check"; rm -rf "$T"; return 1; }
  assert_contains "$out" "still has check(s) running: ci / test (pull_request)" || { rm -rf "$T"; return 1; }
  [ ! -f "$T/gate-ran" ] || { echo "the local gate ran in place of a protected base's CI"; rm -rf "$T"; return 1; }
  ! _fj_merged || { rm -rf "$T"; return 1; }
  _land widget#7 >/dev/null 2>&1 || { echo "refused a green required check"; rm -rf "$T"; return 1; }
  [ ! -f "$T/gate-ran" ] || { echo "ran the local gate although CI stood in"; rm -rf "$T"; return 1; }
  assert_contains "$(_fj_msg)" "Gate: CI (ci / test (pull_request)) on $STUB_HEAD" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# Forgejo's own approval counts only for the current head; someone else's
# PR is theirs to land.
test_solo_land_on_forgejo_accepts_its_approval_of_the_head_only() {
  _solo_setup; _solo_forgejo
  local out
  out="$(STUB_FJ_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb _land widget#7 2>&1)" && { echo "merged an approval of an older head"; rm -rf "$T"; return 1; }
  assert_contains "$out" "not approved" || { rm -rf "$T"; return 1; }
  out="$(STUB_FJ_LOGIN=someone-else _land widget#7 2>&1)" && { echo "landed a colleague's PR"; rm -rf "$T"; return 1; }
  assert_contains "$out" "not this workspace's account ('geoff')" || { rm -rf "$T"; return 1; }
  ! _fj_merged || { rm -rf "$T"; return 1; }
  out="$(_land widget#7 2>&1)" || { echo "$out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "approved via Forgejo approval" || { rm -rf "$T"; return 1; }
  assert_eq "$(tail -n1 "$FJ_BODY_LOG" | jq -r .head_commit_id)" "$FJ_FIXTURE_HEAD" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# land_ci_gate itself, on Forgejo (the rule `cel solo land` relies on): the
# base's exact rule requires
# `ci / test (pull_request)`. Pending on the head is not green; green is the
# CI evidence, named; a head that moved since it was read decides nothing;
# an unprotected base tells the caller its own gate may run. No gh at all.
test_land_ci_gate_reads_a_forgejo_base_and_the_heads_statuses() {
  _solo_setup; _solo_forgejo
  local pr out
  pr="$(jq -nc --arg h "$FJ_FIXTURE_HEAD" '{number: 31, head_sha: $h, base_ref: "main"}')"
  out="$(STUB_FJ_STATUSES='[{"id":70,"context":"ci / test (pull_request)","status":"pending"}]' land_ci_gate "$T" widget "$pr")" \
    && { echo "a pending required check stood in for the gate"; rm -rf "$T"; return 1; }
  assert_contains "$out" "required check(s) not green on $FJ_FIXTURE_HEAD: ci / test (pull_request)" || { rm -rf "$T"; return 1; }
  out="$(land_ci_gate "$T" widget "$pr")" || { echo "$out"; rm -rf "$T"; return 1; }
  assert_eq "$out" "Gate: CI (ci / test (pull_request)) on $FJ_FIXTURE_HEAD" || { rm -rf "$T"; return 1; }
  out="$(STUB_FJ_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb land_ci_gate "$T" widget "$pr")" && { echo "decided on a moved head"; rm -rf "$T"; return 1; }
  assert_contains "$out" "moved to bbbbbbbbbbbb" || { rm -rf "$T"; return 1; }
  STUB_FJ_PROT=none land_ci_gate "$T" widget "$pr" >/dev/null && { echo "CI stood in for an unprotected base"; rm -rf "$T"; return 1; }
  assert_eq "$LAND_CI_UNPROTECTED" 1 || { rm -rf "$T"; return 1; }
  STUB_FJ_PROT=denied land_ci_gate "$T" widget "$pr" >/dev/null && { rm -rf "$T"; return 1; }
  assert_eq "$LAND_CI_UNPROTECTED" 0 || { echo "unknown protection opened the local gate"; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$GH_LOG")" "" || { echo "a Forgejo gate reached gh"; rm -rf "$T"; return 1; }
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

test_solo_review_checks_shared_reviewer_identity_before_writing() {
  _solo_setup
  cel_assert_reviewer_identity() { printf '%s\n' "$1" "$2" "$3" "$4" > "$T/identity-call"; return 1; }
  ! _review widget#7 changes --head "$H" --by rex-reviewer >/dev/null 2>&1 \
    || { echo 'recorded a verdict after identity refusal'; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/identity-call")" "$(printf '%s\n' rex-reviewer "$T" widget 7)"
  assert_eq "$(solo_review_get "$T" widget 7)" ''
  rm -rf "$T"
}

test_solo_review_accepts_shared_identity_without_a_herdr_pane() {
  _solo_setup
  cel_assert_reviewer_identity() { return 0; }
  ( unset HERDR_PANE_ID; CEL_SESSION_BACKEND=rex CEL_AGENT_NAME=rex-reviewer \
      _review widget#7 changes --head "$H" --by rex-reviewer ) >/dev/null
  assert_eq "$(solo_review_get "$T" widget 7 | jq -r .by)" rex-reviewer
  rm -rf "$T"
}

test_solo_rex_reviewer_cannot_record_a_verdict_for_another_target() {
  _solo_setup
  export CEL_REX_STATE="$T/rex" CEL_ROLE=reviewer
  unset CEL_SESSION_BACKEND CEL_REX_RECORD CEL_AGENT_NAME
  mkdir -p "$CEL_REX_STATE"
  jq -n --arg ws "$T" --arg start "$(_rex_pid_start "$$")" --argjson pid "$$" \
    '{name:"widget-pr-7-review",role:"reviewer",workspace:$ws,repo:"widget",pr:7,pid:$pid,pid_start:$start}' \
    > "$CEL_REX_STATE/reviewer.json"
  local ref out
  for ref in widget#8 gadget#7; do
    if out="$(_review "$ref" changes --head "$H" --by widget-pr-7-review 2>&1)"; then
      echo 'Rex reviewer recorded a verdict for another PR/repo'; rm -rf "$T"; return 1
    fi
    assert_contains "$out" 'only this PR reviewer'
  done
  assert_eq "$(solo_review_get "$T" widget 8)" ''
  assert_eq "$(solo_review_get "$T" gadget 7)" ''
  _review widget#7 changes --head "$H" --by widget-pr-7-review >/dev/null
  assert_eq "$(solo_review_get "$T" widget 7 | jq -r .by)" widget-pr-7-review
  rm -rf "$T"
}
test_solo_land_refuses_a_reviewer() {
  _solo_setup fleetbot APPROVED
  ! ( cd "$T" && CEL_ROLE=reviewer cmd_solo_land widget#7 ) >/dev/null 2>&1 || { echo "reviewer landed"; rm -rf "$T"; return 1; }
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
