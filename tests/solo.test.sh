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
  # argument (or STUB_ROLLUP) says otherwise; the files the PR touches are
  # STUB_FILES (gh api --paginate --slurp pages), none by default; the PR's
  # reviews are STUB_REVIEWS. Each merge's --body is appended to
  # $T/merge-body, each comment's to $T/comment-body (one line each;
  # STUB_COMMENT_FAIL refuses comments, STUB_MERGE_FAIL the merge).
  export STUB_HEAD="$H" STUB_ROLLUP_DEFAULT="[{\"name\":\"suite\",\"conclusion\":\"${3:-SUCCESS}\"}]"
  cat > "$T/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
view() { echo '{"number":7,"author":{"login":"${1:-fleetbot}"},"reviewDecision":"${2:-}","reviews":'"\${STUB_REVIEWS:-[]}"',"isDraft":${4:-false},"mergeable":"'"\${STUB_MERGEABLE:-MERGEABLE}"'","state":"${5:-OPEN}","headRefOid":"'"\$STUB_HEAD"'","baseRefName":"main","statusCheckRollup":'"\${STUB_ROLLUP:-\$STUB_ROLLUP_DEFAULT}"'}'; }
body_to() { while [ \$# -gt 1 ]; do [ "\$1" != --body ] || { printf '%s\n' "\$2" >> "\$BODY_FILE"; return; }; shift; done; }
case "\$1 \$2" in
  "api user") echo fleetbot;;
  "pr view")  view;;
  "pr list")  echo "[\$(view)]";;
  "pr merge") [ -z "\${STUB_MERGE_FAIL:-}" ] || { echo "\${STUB_MERGE_ERR:-GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)}" >&2; exit 1; }
              BODY_FILE="$T/merge-body" body_to "\$@"; exit 0;;
  "pr comment") [ -z "\${STUB_COMMENT_FAIL:-}" ] || { echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1; }
                BODY_FILE="$T/comment-body" body_to "\$@"; echo "https://github.com/someone/widget/pull/7#issuecomment-901";;
  *) case "\$2" in
       */protection) case "\${STUB_UNPROTECTED:-}" in
                       1) echo '{"message":"Branch not protected","status":"404"}'; echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1;;
                       err) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1;;
                     esac
                     echo '{"required_status_checks":{"contexts":["suite"]}}';;
       */rules/branches/*) [ "\${STUB_RULES:-}" != denied ] || { echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1; }
                           printf '%s' "\${STUB_RULES:-[[]]}";;
       */pulls/*/files) printf '%s' "\${STUB_FILES:-[[]]}";;
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

# The squash message as the forge writes it (the PR title, then the body),
# committed to a scratch repo: its trailers as git parses them, and the
# history scan main's push run applies to every commit message.
_solo_squash_trailers() { git interpret-trailers --parse <<<"Fix widget sizing (#7)"$'\n\n'"$1"; }
_solo_history_scan_accepts() { # <body>
  local r; r="$(mktemp -d)"
  git -C "$r" init -q && git -C "$r" -c user.name='Example Author' -c user.email=author@example.invalid \
    commit -q --allow-empty -m "Fix widget sizing (#7)" -m "$1" || { rm -rf "$r"; return 1; }
  python3 "$CEL_ROOT/tools/release/hygiene.py" --root "$r" --history HEAD || { rm -rf "$r"; return 1; }
  rm -rf "$r"
}
_solo_before() { # <first-line-pattern> <second-line-pattern> <log>
  local a b
  a="$(grep -n -m1 "$1" "$3" | cut -d: -f1)" b="$(grep -n -m1 "$2" "$3" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || { echo "'$1' did not come before '$2':"; cat "$3"; return 1; }
}

# WHO LANDED IT IS ON MAIN AND ON THE PR. The forge shows every land as the
# workspace's account (the owner's token); the squash message names the agent
# that ran it and the reviewer whose verdict carried it, as git trailers the
# history scan accepts, and a comment posted before the merge says the same.
test_solo_land_names_the_lander_and_reviewer_in_trailers_and_a_comment_before_the_merge() {
  _solo_setup
  _review widget#7 approved --head "$H" --by widget-pr-7-review --note "checked the sizing paths" >/dev/null
  ( export CEL_ROLE=solo CEL_INBOX_ME=widget-orch; _land widget#7 ) >/dev/null 2>&1 || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  local msg trailers
  msg="$(cat "$T/merge-body")" trailers="$(_solo_squash_trailers "$(cat "$T/merge-body")")"
  assert_eq "$trailers" "Reviewed-by: widget-pr-7-review (approved)
Landed-by: widget-orch (cel solo land)
Gate: CI (suite) on $H" || { echo "$msg"; rm -rf "$T"; return 1; }
  assert_contains "$msg" "checked the sizing paths" || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/comment-body")" "Landing as widget-orch via cel solo land (attempting): approved by widget-pr-7-review at $H, checks green." || { rm -rf "$T"; return 1; }
  _solo_before '^pr comment 7 --repo someone/widget' '^pr merge 7' "$GH_LOG" || { rm -rf "$T"; return 1; }
  _solo_history_scan_accepts "$msg" || { echo "$msg"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A forge approval names the accounts that approved; a person landing from
# their own shell (no agent role) is the account, by hand - even with an
# agent's alias in its environment: only a landing role's launch names one.
test_solo_land_by_hand_on_a_github_approval_names_its_approvers() {
  _solo_setup fleetbot APPROVED
  export STUB_REVIEWS='[{"author":{"login":"alice-example"},"state":"APPROVED","commit":{"oid":"'"$H"'"},"submittedAt":"2026-11-15T09:00:00Z"},
    {"author":{"login":"bob-example"},"state":"COMMENTED","commit":{"oid":"'"$H"'"},"submittedAt":"2026-11-15T09:05:00Z"}]'
  ( unset CEL_ROLE; export CEL_INBOX_ME=widget-orch; _land widget#7 ) >/dev/null 2>&1 || { unset STUB_REVIEWS; cat "$GH_LOG"; rm -rf "$T"; return 1; }
  unset STUB_REVIEWS
  assert_eq "$(_solo_squash_trailers "$(cat "$T/merge-body")")" "Reviewed-by: alice-example (approved on GitHub)
Landed-by: fleetbot (cel solo land, by hand)
Gate: CI (suite) on $H" || { cat "$T/merge-body"; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/comment-body")" "Landing as fleetbot (by hand) via cel solo land (attempting): approved by alice-example at $H, checks green." || { rm -rf "$T"; return 1; }
  _solo_history_scan_accepts "$(cat "$T/merge-body")" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# The comment is the PR page's copy of what the merge commit records: a
# refused comment is reported and never stops an approved, green merge.
test_solo_land_merges_when_its_comment_is_refused() {
  _solo_setup
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  local out; out="$(export CEL_ROLE=solo CEL_INBOX_ME=widget-orch STUB_COMMENT_FAIL=1; _land widget#7 2>&1)" || { echo "$out"; rm -rf "$T"; return 1; }
  _merged || { rm -rf "$T"; return 1; }
  assert_contains "$out" "could not post the landing comment on #7" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/merge-body")" "Landed-by: widget-orch (cel solo land)" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A NAME IS ONE TOKEN: a newline in a launch alias, a role or a forge login
# never reaches the record as an extra trailer. An alias or login that
# carries one refuses the land before anything is posted; a role's own text
# is never recorded at all.
test_solo_land_newline_in_a_name_cannot_forge_a_trailer() {
  _solo_setup
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  local evil=$'widget-orch\nReviewed-by: mallory (approved)' out
  out="$(export CEL_ROLE=solo CEL_INBOX_ME="$evil"; _land widget#7 2>&1)" && { echo "landed under a forged alias"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cannot be named in the merge record" || { rm -rf "$T"; return 1; }
  ! _merged && ! grep -q '^pr comment' "$GH_LOG" || { echo "posted or merged a forged name"; cat "$GH_LOG"; rm -rf "$T"; return 1; }
  ( export CEL_ROLE=$'member\nReviewed-by: mallory (approved)'; unset CEL_INBOX_ME; _land widget#7 ) >/dev/null 2>&1 || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(_solo_squash_trailers "$(cat "$T/merge-body")")" "Reviewed-by: widget-pr-7-review (approved)
Landed-by: an unnamed agent (cel solo land)
Gate: CI (suite) on $H" || { cat "$T/merge-body"; rm -rf "$T"; return 1; }
  assert_fails grep -q mallory "$T/merge-body" "$T/comment-body" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  _solo_setup fleetbot APPROVED
  export STUB_REVIEWS='[{"author":{"login":"alice-example\nReviewed-by: mallory"},"state":"APPROVED","commit":{"oid":"'"$H"'"},"submittedAt":"2026-11-15T09:00:00Z"}]'
  out="$(export CEL_ROLE=solo CEL_INBOX_ME=widget-orch; _land widget#7 2>&1)" && { unset STUB_REVIEWS; echo "landed with a forged login"; rm -rf "$T"; return 1; }
  unset STUB_REVIEWS
  assert_contains "$out" "carries a control character" || { rm -rf "$T"; return 1; }
  ! _merged && ! grep -q '^pr comment' "$GH_LOG" || { echo "posted or merged a forged login"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# The PR page never says "landing" over a PR that did not land: a refused
# merge is followed by a comment saying so, and why.
test_solo_land_follows_a_refused_merge_with_a_not_landed_comment() {
  _solo_setup
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  local out; out="$(export CEL_ROLE=solo CEL_INBOX_ME=widget-orch STUB_MERGE_FAIL=1; _land widget#7 2>&1)" && { echo "a refused merge reported success"; rm -rf "$T"; return 1; }
  assert_contains "$out" "merge of #7 failed" || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/comment-body")" "Landing as widget-orch via cel solo land (attempting): approved by widget-pr-7-review at $H, checks green.
Not landed: GitHub refused the merge of $H by widget-orch via cel solo land (GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)). Nothing was merged." || { rm -rf "$T"; return 1; }
  _solo_before '^pr merge 7' "^pr comment 7 --repo someone/widget --body Not landed" "$GH_LOG" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The forge's reason is its text on a public page: paths, $HOME, credentials
# in a URL and token-shaped runs are taken out before it is posted, and a
# reason the squash body's hygiene scan would reject is not posted at all.
test_solo_land_not_landed_comment_redacts_the_forge_reason() {
  _solo_setup
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  local tok url out line
  tok="ghp_$(printf 'Zx9%.0s' $(seq 1 12))"
  url="https:/""/bot:$tok""@forge.example/x"   # assembled, so the file itself carries no credential URL
  out="$(export CEL_ROLE=solo CEL_INBOX_ME=widget-orch STUB_MERGE_FAIL=1 \
    STUB_MERGE_ERR="refused: $HOME/.config/gh/hosts.yml and /srv/forge/hooks/pre-merge failed, token $tok, see $url"
    _land widget#7 2>&1)" && { echo "a refused merge reported success"; rm -rf "$T"; return 1; }
  line="$(tail -n1 "$T/comment-body")"
  assert_eq "$line" "Not landed: GitHub refused the merge of $H by widget-orch via cel solo land (refused: <path> and <path> failed, token <redacted> see <url>). Nothing was merged." || { rm -rf "$T"; return 1; }
  assert_fails grep -qF -e "$HOME" -e "$tok" -e /srv/forge "$T/comment-body" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  _solo_setup
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  ( export CEL_ROLE=solo CEL_INBOX_ME=widget-orch STUB_MERGE_FAIL=1 STUB_MERGE_ERR="blocked by ZQX-$((4000 + 821))"
    _land widget#7 ) >/dev/null 2>&1 && { echo "a refused merge reported success"; rm -rf "$T"; return 1; }
  assert_eq "$(tail -n1 "$T/comment-body")" "Not landed: GitHub refused the merge of $H by widget-orch via cel solo land. Nothing was merged." || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  # A key with a prefix (`access_token`, `client_secret`), an Authorization
  # header's scheme and value, and a token the 300-character cut would split.
  local case pad expect
  pad="$(printf 'w %.0s' $(seq 1 145))"
  for case in "access""_token=abc123 rejected|access_token=<redacted> rejected" \
              "client""_secret=hunter2 rejected|client_secret=<redacted> rejected" \
              "Authorization: token abc rejected|Authorization: <redacted> rejected" \
              "$pad$tok tail|"; do
    expect="${case#*|}"
    _solo_setup
    _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
    ( export CEL_ROLE=solo CEL_INBOX_ME=widget-orch STUB_MERGE_FAIL=1 STUB_MERGE_ERR="${case%%|*}"
      _land widget#7 ) >/dev/null 2>&1 && { echo "a refused merge reported success"; rm -rf "$T"; return 1; }
    line="$(tail -n1 "$T/comment-body")"
    if [ -n "$expect" ]; then
      assert_eq "$line" "Not landed: GitHub refused the merge of $H by widget-orch via cel solo land ($expect). Nothing was merged." || { rm -rf "$T"; return 1; }
    else
      assert_contains "$line" "w w <redacted>" || { rm -rf "$T"; return 1; }
      assert_fails grep -qF -e ghp_ -e Zx9 "$T/comment-body" || { rm -rf "$T"; return 1; }
    fi
    rm -rf "$T"
  done
  return 0
}

# ---- a Forgejo repo ----------------------------------------------------------
# widget served by an internal Forgejo (tests/lib/forgejo-stub.sh: recorded
# fixtures), its PR opened by the token's owner, `geoff`; the base's
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
# The same attribution on Forgejo: the comment POSTed to the PR's issue
# before the merge, the trailers in MergeMessageField, accepted by the history
# scan; a refused comment (403) is reported and the merge still goes through;
# a refused merge (409) is followed by a comment saying it did not land.
test_solo_land_on_forgejo_names_the_lander_and_reviewer_and_comments_before_the_merge() {
  _solo_setup; _solo_forgejo
  export STUB_FJ_HEAD="$STUB_HEAD"
  _review widget#7 approved --head "$STUB_HEAD" --by widget-pr-7-review >/dev/null || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  ( export CEL_ROLE=solo CEL_INBOX_ME=widget-orch; _land widget#7 ) >/dev/null 2>&1 || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  _solo_before '^POST http://forgejo.internal/api/v1/repos/geoff/gizmo/issues/7/comments' \
    '^POST http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/7/merge' "$FJ_LOG" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r 'select(.body != null) | .body' "$FJ_BODY_LOG")" \
    "Landing as widget-orch via cel solo land (attempting): approved by widget-pr-7-review at $STUB_HEAD, checks green." || { rm -rf "$T"; return 1; }
  assert_eq "$(_solo_squash_trailers "$(_fj_msg)")" "Reviewed-by: widget-pr-7-review (approved)
Landed-by: widget-orch (cel solo land)
Gate: CI (ci / test (pull_request)) on $STUB_HEAD" || { _fj_msg; rm -rf "$T"; return 1; }
  _solo_history_scan_accepts "$(_fj_msg)" || { rm -rf "$T"; return 1; }
  : > "$FJ_LOG"
  local out; out="$(export CEL_ROLE=solo CEL_INBOX_ME=widget-orch STUB_FJ_WRITE=denied; _land widget#7 2>&1)" || { echo "$out"; rm -rf "$T"; return 1; }
  _fj_merged || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_contains "$out" "could not post the landing comment on #7" || { rm -rf "$T"; return 1; }
  : > "$FJ_LOG"; : > "$FJ_BODY_LOG"
  out="$(export CEL_ROLE=solo CEL_INBOX_ME=widget-orch STUB_FJ_MERGE=conflict; _land widget#7 2>&1)" && { echo "a refused merge reported success"; rm -rf "$T"; return 1; }
  assert_eq "$(grep -oE '^POST .*/(issues/7/comments|pulls/7/merge)$' "$FJ_LOG" | sed 's|.*/||')" $'comments\nmerge\ncomments' \
    || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_contains "$(jq -r 'select(.body != null) | .body' "$FJ_BODY_LOG" | tail -n1)" \
    "Not landed: Forgejo refused the merge of $STUB_HEAD by widget-orch via cel solo land (forge pr_merge: Forgejo answered HTTP 409" || { cat "$FJ_BODY_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$GH_LOG")" "" || { echo "a Forgejo land reached gh"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# Forgejo answers mergeable:false for a PR it has not (re)computed - recorded
# live on a clean fast-forward - so it reads `unknown`, and land does not
# take unknown for a conflict: Forgejo's own merge is what refuses a real one.
test_solo_land_on_forgejo_does_not_take_mergeable_false_for_a_conflict() {
  _solo_setup; _solo_forgejo
  export STUB_FJ_HEAD="$STUB_HEAD" STUB_FJ_MERGEABLE=false
  _review widget#7 approved --head "$STUB_HEAD" --by widget-pr-7-review >/dev/null || { rm -rf "$T"; return 1; }
  local out; out="$(_land widget#7 2>&1)" || { echo "$out"; rm -rf "$T"; return 1; }
  case "$out" in *conflict*) echo "read unknown as a conflict: $out"; rm -rf "$T"; return 1 ;; esac
  _fj_merged || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
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
test_solo_reviewer_brief_names_solo_commands() {
  _solo_setup
  source "$CEL_ROOT/lib/run.sh"
  local b; b="$(_run_reviewer_solo_brief "$T" widget 7)"
  assert_contains "$b" "cel solo review widget#7"
  assert_contains "$b" "bundle-orch"
  assert_contains "$(_run_reviewer_solo_brief "$T" lone 7)" "cel solo review lone#7"
  rm -rf "$T"
}

# --- extra reviewers: review.extra ---------------------------------------------
# A security reviewer is required for anything under lib/auth/; the PR touches
# lib/auth/session.ts unless STUB_FILES says otherwise.
SEC=widget-pr-7-review-security PERF=widget-pr-7-review-performance
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
_solo_policy() {
  cat >> "$T/workspace.yaml" <<'YAML'
review:
  model: sonnet
  extra:
    - focus: security
      paths: ['lib/auth/**']
YAML
  export STUB_FILES='[[{"filename":"lib/auth/session.ts","status":"modified"},{"filename":"README.md","status":"modified"}]]'
}
# A verdict recorded from an extra reviewer's own pane: its launch line's
# role and mailbox.
_review_as() { # <alias> <focus> <verdict> <head>
  ( export CEL_ROLE=reviewer CEL_INBOX_ME="$1"; cd "$T" && cmd_solo_review widget#7 "$3" --head "$4" --by "$1" --focus "$2" )
}
test_solo_land_refuses_when_a_required_extra_review_is_missing() {
  _solo_setup; _solo_policy
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  local out; out="$(_land widget#7 2>&1)" && { echo "merged without the security review: $out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "lacks a review the workspace's policy requires" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "$SEC (focus security; review.extra: lib/auth/session.ts matches \"lib/auth/**\") has recorded no verdict" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "start it: cel run reviewer --repo widget --pr 7 --focus security" || { rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
  # a PR that touches nothing the policy names needs only its plain reviewer
  STUB_FILES='[[{"filename":"README.md"}]]' _land widget#7 >/dev/null 2>&1 && _merged || { echo "refused a PR the policy does not reach"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_solo_land_refuses_a_stale_extra_approval_and_merges_when_all_are_current() {
  _solo_setup; _solo_policy
  _review_as "$SEC" security approved "$H" >/dev/null || { echo "the security reviewer could not record"; rm -rf "$T"; return 1; }
  # the author pushes; the plain reviewer approves the new head, security does not
  export STUB_HEAD="$B"
  _review widget#7 approved --head "$B" --by widget-pr-7-review >/dev/null
  local out; out="$(_land widget#7 2>&1)" && { echo "merged on a stale security approval"; rm -rf "$T"; return 1; }
  assert_contains "$out" "$SEC (focus security; review.extra: lib/auth/session.ts matches \"lib/auth/**\") has a verdict for head aaaaaaaaaaaa, not bbbbbbbbbbbb" || { rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
  # ...and a `changes` from it at the current head says so
  _review_as "$SEC" security changes "$B" >/dev/null
  out="$(_land widget#7 2>&1)" && { rm -rf "$T"; return 1; }
  assert_contains "$out" "$SEC (focus security; review.extra: lib/auth/session.ts matches \"lib/auth/**\") asked for changes at bbbbbbbbbbbb" || { rm -rf "$T"; return 1; }
  _review_as "$SEC" security approved "$B" >/dev/null
  out="$(_land widget#7 2>&1)" || { echo "refused with every review current: $out"; rm -rf "$T"; return 1; }
  _merged || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "Reviewed-by: $SEC (approved, focus security)" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "Reviewed-by: widget-pr-7-review (approved)" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# NOT SATISFIABLE BY A REVIEWER THAT WAS NEVER STARTED: a focus verdict is
# recorded only by the process launched as that focus reviewer, under its
# alias; a verdict in its slot from anyone else is no verdict; and the
# reviewer cannot file its verdict as the plain one's.
test_solo_extra_review_is_recorded_only_by_its_own_reviewer() {
  _solo_setup; _solo_policy
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  local out
  out="$(_review widget#7 approved --head "$H" --by "$SEC" --focus security 2>&1)" && { echo "a focus verdict from no reviewer pane: $out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "a security verdict is recorded by the reviewer started for it" || { rm -rf "$T"; return 1; }
  out="$(_review_as widget-pr-7-review security approved "$H" 2>&1)" && { echo "the plain reviewer signed the security slot"; rm -rf "$T"; return 1; }
  assert_contains "$out" "the security reviewer of widget#7 is $SEC" || { rm -rf "$T"; return 1; }
  out="$( (export CEL_ROLE=reviewer CEL_INBOX_ME="$SEC"; _review widget#7 approved --head "$H" --by "$SEC") 2>&1)" && { rm -rf "$T"; return 1; }
  assert_contains "$out" "$SEC is the security reviewer - record its verdict with --focus security" || { rm -rf "$T"; return 1; }
  out="$(_review_as "$SEC" speed approved "$H" 2>&1)" && { rm -rf "$T"; return 1; }
  assert_contains "$out" "no reviewer focus 'speed'" || { rm -rf "$T"; return 1; }
  assert_eq "$(solo_review_get "$T" widget 7 review-security)" "" || { rm -rf "$T"; return 1; }
  # a hand-written verdict in the slot, signed by someone else, is not its review
  jq --arg h "$H" '."widget#7/review-security" = {verdict:"approved", by:"someone", head:$h, at:"2026-11-08T10:00:00Z"}' \
    "$T/.cel/solo-reviews.json" > "$T/v" && mv "$T/v" "$T/.cel/solo-reviews.json"
  out="$(_land widget#7 2>&1)" && { echo "merged on a verdict its reviewer never recorded"; rm -rf "$T"; return 1; }
  assert_contains "$out" "has no verdict of its own (the one on record is by someone)" || { rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A REVIEWER SIGNS ONLY AS ITSELF: a focus reviewer that leaves --focus off
# and names the plain alias does not write the plain verdict. (Herdr identity
# is the launch environment, as for the author guard.)
test_solo_review_plain_slot_takes_only_the_callers_own_alias() {
  _solo_setup; _solo_policy
  local out
  out="$( (export CEL_ROLE=reviewer CEL_INBOX_ME="$SEC"; _review widget#7 approved --head "$H" --by widget-pr-7-review) 2>&1)" \
    && { echo "a focus reviewer wrote the plain verdict"; rm -rf "$T"; return 1; }
  assert_contains "$out" "you are $SEC, not 'widget-pr-7-review'" || { rm -rf "$T"; return 1; }
  assert_eq "$(solo_review_get "$T" widget 7)" "" || { rm -rf "$T"; return 1; }
  ( export CEL_ROLE=reviewer CEL_INBOX_ME=widget-pr-7-review; _review widget#7 approved --head "$H" --by widget-pr-7-review ) >/dev/null \
    || { echo "the plain reviewer could not record its own verdict"; rm -rf "$T"; return 1; }
  assert_eq "$(solo_review_get "$T" widget 7 | jq -r .by)" widget-pr-7-review || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A required extra reviewer whose alias is cut into another reviewer's can
# never be started; land says so and what to change, instead of a start
# command that would be refused.
test_solo_land_names_an_extra_reviewer_that_can_never_start() {
  _solo_setup; _solo_policy
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  review_alias_free() { printf "the %s reviewer's name 'x' is the plain reviewer's (names are cut to 32 characters)" "$3"; return 1; }
  local out; out="$(_land widget#7 2>&1)" && { rm -rf "$T"; return 1; }
  assert_contains "$out" "can never be started, so this PR cannot land: the security reviewer's name 'x' is the plain reviewer's" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "drop security from review.extra" || { rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# THE ADVISORY REVIEWER. One started by hand (--focus) that the policy does
# not require is advisory: its approval adds nothing land needs and a stale
# verdict holds nothing up - but its `changes` at the head being merged is a
# finding at that head, and it blocks, like a red check.
test_solo_land_advisory_reviewer_blocks_only_on_changes_at_the_head() {
  _solo_setup; _solo_policy
  export STUB_FILES='[[{"filename":"README.md"}]]'   # the policy requires no extra review here
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  _review_as "$PERF" performance changes "$H" >/dev/null || { rm -rf "$T"; return 1; }
  local out; out="$(_land widget#7 2>&1)" && { echo "merged over a specialist's changes at the head"; rm -rf "$T"; return 1; }
  assert_contains "$out" "$PERF (focus performance; started by hand, not required by policy) asked for changes at aaaaaaaaaaaa" || { rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
  # a push makes that verdict stale: it no longer blocks, and is not needed
  export STUB_HEAD="$B"
  _review widget#7 approved --head "$B" --by widget-pr-7-review >/dev/null
  out="$(_land widget#7 2>&1)" || { echo "a stale advisory verdict blocked: $out"; rm -rf "$T"; return 1; }
  _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_solo_land_refuses_when_the_prs_files_cannot_be_read() {
  _solo_setup; _solo_policy
  export STUB_FILES='{"message":"Server Error"}'
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  local out; out="$(_land widget#7 2>&1)" && { echo "merged without knowing what the PR touches"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cannot read the files widget#7 touches from its forge" || { rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# THE POLICY IS workspace.yaml's: a workspace.local.yaml that drops the
# extra reviewers (workspace-wide or on the repo) changes nothing land asks.
test_solo_land_policy_cannot_be_dropped_by_a_local_override() {
  _solo_setup; _solo_policy
  printf 'review:\n  extra: []\nrepos:\n  - name: widget\n    review: { extra: [] }\n' > "$T/workspace.local.yaml"
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  local out; out="$(_land widget#7 2>&1)" && { echo "a local file dropped a required review"; rm -rf "$T"; return 1; }
  assert_contains "$out" "$SEC" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# THE STEWARD'S "land it" AGREES WITH LAND: listed (and nudged) exactly when
# land would take the reviews, on the same PR facts.
test_steward_land_nudge_agrees_with_land_on_every_required_review() {
  source "$CEL_ROOT/lib/steward.sh"
  _solo_setup; _solo_policy
  export CEL_REGISTRY="$T/registry.yaml"; registry_add demo "$T" ""
  CEL_STEWARD_STATE="$T/state" _STEWARD_STATE="$T/state"
  cmd_inbox() { printf '%s\n' "$*" >> "$T/mail"; }
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  # the security review missing: not ready, no nudge, and land refuses
  assert_eq "$(solo_ready_prs "$T" bundle)" "" || { rm -rf "$T"; return 1; }
  _steward_solo_sweep >/dev/null 2>&1
  [ ! -s "$T/mail" ] || { echo "nudged to land what land refuses: $(cat "$T/mail")"; rm -rf "$T"; return 1; }
  ! _land widget#7 >/dev/null 2>&1 || { rm -rf "$T"; return 1; }
  # an advisory `changes` at the head: the same
  _review_as "$SEC" security approved "$H" >/dev/null
  _review_as "$PERF" performance changes "$H" >/dev/null
  assert_eq "$(solo_ready_prs "$T" bundle)" "" || { rm -rf "$T"; return 1; }
  ! _land widget#7 >/dev/null 2>&1 || { rm -rf "$T"; return 1; }
  # every required review current and nothing blocking: listed, nudged, landed
  _review_as "$PERF" performance approved "$H" >/dev/null
  assert_eq "$(solo_ready_prs "$T" bundle)" "widget	7	$H" || { rm -rf "$T"; return 1; }
  _steward_solo_sweep >/dev/null 2>&1
  assert_contains "$(cat "$T/mail")" "cel solo land widget#7" || { rm -rf "$T"; return 1; }
  _land widget#7 >/dev/null 2>&1 && _merged || { echo "land refused what the steward nudged"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A review block every key of which Celestial knows - thinking included, as
# real workspaces set it - is policy, not a refusal: land and approvals answer.
test_solo_land_and_approvals_accept_a_review_block_with_thinking() {
  _solo_setup
  printf 'review:\n  runtime: pi\n  model: sonnet\n  thinking: medium\n' >> "$T/workspace.yaml"
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  assert_eq "$( cd "$T" && cmd_solo_approvals widget#7 --json | jq -r '.[0].state')" approved || { rm -rf "$T"; return 1; }
  local out; out="$(_land widget#7 2>&1)" || { echo "refused a review block with thinking: $out"; rm -rf "$T"; return 1; }
  _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  # ...while a typo beside it still refuses
  _solo_setup
  printf 'review:\n  thinking: medium\n  extras:\n    - focus: security\n      paths: [a]\n' >> "$T/workspace.yaml"
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  out="$(_land widget#7 2>&1)" && { echo "merged past a typo'd review block"; rm -rf "$T"; return 1; }
  assert_contains "$out" "unknown key(s) extras" || { rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# What a view shows is land's answer too.
test_solo_approvals_reports_each_reviewer_by_lands_rule() {
  _solo_setup; _solo_policy
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  local j; j="$( cd "$T" && cmd_solo_approvals widget#7 nowhere#3 --json)" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.[0].state' <<<"$j")" pending || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -c '[.[0].reviewers[] | [.alias, .required, .state]]' <<<"$j")" \
    "[[\"widget-pr-7-review\",true,\"approved\"],[\"$SEC\",true,\"missing\"]]" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.[1].state' <<<"$j")" "n/a" || { rm -rf "$T"; return 1; }
  _review_as "$SEC" security approved "$H" >/dev/null
  assert_eq "$( cd "$T" && cmd_solo_approvals widget#7 --json | jq -r '.[0].state')" approved || { rm -rf "$T"; return 1; }
  assert_contains "$( cd "$T" && cmd_solo_approvals widget#7)" "$SEC (security)  approved  required: review.extra: lib/auth/session.ts matches" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# ---------------------------------------------------------------- QA agents
# A QA agent (review.extra kind: qa) is required for UI paths; it records
# from its own pane (CEL_ROLE=reviewer, its alias the mailbox) with --qa,
# and evidence named with the head it ran.
QA=widget-pr-7-qa-browser
_solo_qa_policy() {
  cat >> "$T/workspace.yaml" <<'YAML'
review:
  model: sonnet
  extra:
    - kind: qa
      focus: browser
      paths: ['web/**', '**/*.tsx', '**/*.css']
YAML
  export STUB_FILES='[[{"filename":"web/Login.tsx","status":"modified"},{"filename":"README.md","status":"modified"}]]'
  export CEL_SERVE_STATE="$T/state"
}
_qa_shot() { # <file name> -> a PNG screenshot at that name in $T/shots
  mkdir -p "$T/shots"; printf '\x89PNG\r\n\x1a\nIHDR-fixture' > "$T/shots/$1"; printf '%s' "$T/shots/$1"
}
_qa_previewed() { # <head> - the browser QA agent's preview of that head is on record
  mkdir -p "$CEL_SERVE_STATE/previews"
  jq -n --arg h "$1" '{name:"preview-widget-pr7-qa-browser", repo:"widget", pr:7, qa:"browser", head:$h}' \
    > "$CEL_SERVE_STATE/previews/preview-widget-pr7-qa-browser.json"
}
_qa_as() { # <verdict> <head> [cel solo review args...]
  local v="$1" h="$2"; shift 2
  ( export CEL_ROLE=reviewer CEL_INBOX_ME="$QA"; cd "$T" && cmd_solo_review widget#7 "$v" --head "$h" --by "$QA" --qa browser "$@" )
}
test_solo_land_refuses_without_a_qa_approval_at_the_head() {
  _solo_setup; _solo_qa_policy
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  local out; out="$(_land widget#7 2>&1)" && { echo "merged with no QA: $out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "$QA (qa browser; review.extra: web/Login.tsx matches \"**/*.tsx\") has recorded no verdict - start it: cel run reviewer --repo widget --pr 7 --qa browser" || { rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
  # the steward's nudge asks the same question
  assert_eq "$(solo_ready_prs "$T" bundle)" "" || { rm -rf "$T"; return 1; }
  _qa_previewed "$H"
  _qa_as approved "$H" --evidence "$(_qa_shot "login-${H:0:12}.png")" --note "login walked" >/dev/null \
    || { echo "the QA agent could not record"; rm -rf "$T"; return 1; }
  # the author pushes: the QA approval is for the old head
  export STUB_HEAD="$B"
  _review widget#7 approved --head "$B" --by widget-pr-7-review >/dev/null
  out="$(_land widget#7 2>&1)" && { echo "merged on a stale QA approval"; rm -rf "$T"; return 1; }
  assert_contains "$out" "$QA (qa browser; review.extra: web/Login.tsx matches \"**/*.tsx\") has a verdict for head aaaaaaaaaaaa, not bbbbbbbbbbbb" || { rm -rf "$T"; return 1; }
  _qa_previewed "$B"
  _qa_as approved "$B" --evidence "$(_qa_shot "login-${B:0:12}.png")" >/dev/null || { rm -rf "$T"; return 1; }
  assert_eq "$(solo_ready_prs "$T" bundle)" "widget	7	$B" || { rm -rf "$T"; return 1; }
  out="$(_land widget#7 2>&1)" || { echo "refused with QA approved at the head: $out"; rm -rf "$T"; return 1; }
  _merged || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "Reviewed-by: $QA (approved, qa browser)" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# BLOCKED IS NOT APPROVED: a QA agent that could not run the change says so
# and why; land names it as a gap, never as a pass.
test_solo_qa_blocked_does_not_count_and_says_why() {
  _solo_setup; _solo_qa_policy
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  local out
  out="$(_qa_as blocked "$H" 2>&1)" && { echo "blocked without a reason: $out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "a blocked verdict says why - --note" || { rm -rf "$T"; return 1; }
  _qa_as blocked "$H" --note "repo declares no preview.cmd" >/dev/null || { rm -rf "$T"; return 1; }
  assert_eq "$(solo_review_get "$T" widget 7 qa-browser | jq -r .verdict)" blocked || { rm -rf "$T"; return 1; }
  out="$(_land widget#7 2>&1)" && { echo "merged on a blocked QA"; rm -rf "$T"; return 1; }
  assert_contains "$out" "$QA (qa browser; review.extra: web/Login.tsx matches \"**/*.tsx\") could not run the change at aaaaaaaaaaaa: repo declares no preview.cmd" || { rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
  assert_eq "$(cd "$T" && cmd_solo_approvals widget#7 --json | jq -c '[.[0].state, (.[0].reviewers[] | select(.kind == "qa") | [.alias, .focus, .state])]')" \
    "[\"pending\",[\"$QA\",\"browser\",\"blocked\"]]" || { rm -rf "$T"; return 1; }
  # blocked is a QA agent's word only: a code reviewer always can read the code
  out="$( (export CEL_ROLE=reviewer CEL_INBOX_ME=widget-pr-7-review; _review widget#7 blocked --head "$H" --by widget-pr-7-review --note x) 2>&1)" \
    && { echo "a code reviewer recorded blocked"; rm -rf "$T"; return 1; }
  assert_contains "$out" "blocked is a QA agent's verdict (--qa)" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A QA VERDICT CARRIES ITS EVIDENCE AND STANDS ON A RUN: approved and changes
# need this slot's preview of that head on record and at least one file -
# a regular file (no symlink), not empty, the image its name says, named with
# the head - copied (bytes, sha256, size) beside the verdict. Only the QA
# agent started for that focus records it.
test_solo_qa_verdict_needs_head_named_evidence_from_its_own_agent() {
  _solo_setup; _solo_qa_policy
  local out good
  out="$(_qa_as approved "$H" 2>&1)" && { echo "a QA approval with no evidence: $out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "a QA approved verdict needs --evidence" || { rm -rf "$T"; return 1; }
  out="$(_qa_as approved "$H" --evidence "$(_qa_shot "login-${H:0:12}.png")" 2>&1)" && { echo "approved with no preview run: $out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "no browser QA preview of widget#7 at aaaaaaaaaaaa is on record" || { rm -rf "$T"; return 1; }
  _qa_previewed "$B"
  out="$(_qa_as changes "$H" --evidence "$(_qa_shot "login-${H:0:12}.png")" 2>&1)" && { echo "a preview of another head counted: $out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "no browser QA preview of widget#7 at aaaaaaaaaaaa is on record" || { rm -rf "$T"; return 1; }
  _qa_previewed "$H"
  out="$(_qa_as changes "$H" --evidence "$(_qa_shot login.png)" 2>&1)" && { echo "evidence not named with the head: $out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "is not named with the head it shows (aaaaaaaaaaaa)" || { rm -rf "$T"; return 1; }
  out="$(_qa_as approved "$H" --evidence "$T/shots/none-${H:0:12}.png" 2>&1)" && { rm -rf "$T"; return 1; }
  assert_contains "$out" "is not a file" || { rm -rf "$T"; return 1; }
  ln -s /etc/hostname "$T/shots/link-${H:0:12}.png"
  out="$(_qa_as approved "$H" --evidence "$T/shots/link-${H:0:12}.png" 2>&1)" && { echo "a symlink was evidence"; rm -rf "$T"; return 1; }
  assert_contains "$out" "is a symlink" || { rm -rf "$T"; return 1; }
  : > "$T/shots/empty-${H:0:12}.png"
  out="$(_qa_as approved "$H" --evidence "$T/shots/empty-${H:0:12}.png" 2>&1)" && { rm -rf "$T"; return 1; }
  assert_contains "$out" "is empty" || { rm -rf "$T"; return 1; }
  printf 'not a png' > "$T/shots/fake-${H:0:12}.png"
  out="$(_qa_as approved "$H" --evidence "$T/shots/fake-${H:0:12}.png" 2>&1)" && { echo "a text file passed as a png"; rm -rf "$T"; return 1; }
  assert_contains "$out" "is not the image its name says it is" || { rm -rf "$T"; return 1; }
  out="$(_review widget#7 approved --head "$H" --by "$QA" --qa browser --evidence "$(_qa_shot "a-${H:0:12}.png")" 2>&1)" \
    && { echo "a QA verdict from no QA pane"; rm -rf "$T"; return 1; }
  assert_contains "$out" "a browser QA verdict is recorded by the QA agent started for it (cel run reviewer --repo widget --pr 7 --qa browser)" || { rm -rf "$T"; return 1; }
  out="$( (export CEL_ROLE=reviewer CEL_INBOX_ME=widget-pr-7-review-security; _review widget#7 approved --head "$H" --by widget-pr-7-review-security --focus security --evidence x) 2>&1)" \
    && { rm -rf "$T"; return 1; }
  assert_contains "$out" "--evidence is a QA agent's (--qa)" || { rm -rf "$T"; return 1; }
  out="$(_qa_as approved "$H" --focus security 2>&1)" && { rm -rf "$T"; return 1; }
  assert_contains "$out" "--focus and --qa name two different agents" || { rm -rf "$T"; return 1; }
  good="$(_qa_shot "login-${H:0:12}.png")"
  printf 'console clean\n' > "$T/shots/console-${H:0:12}.log"
  _qa_as approved "$H" --evidence "$good" --evidence "$T/shots/console-${H:0:12}.log" >/dev/null || { rm -rf "$T"; return 1; }
  local rec kept="$T/.cel/qa-evidence/widget-pr-7/qa-browser/login-${H:0:12}.png"
  rec="$(solo_review_get "$T" widget 7 qa-browser)"
  assert_eq "$(jq -r .by <<<"$rec")" "$QA" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.evidence[0].path' <<<"$rec")" "$kept" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.evidence[0].sha256' <<<"$rec")" "$(sha256sum "$good" | cut -d' ' -f1)" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.evidence[0].size' <<<"$rec")" "$(stat -c %s "$good")" || { rm -rf "$T"; return 1; }
  [ -f "$kept" ] && [ ! -L "$kept" ] || { echo "evidence not kept as a file"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.evidence | length' <<<"$rec")" 2 || { rm -rf "$T"; return 1; }
  # the plain reviewer's and a review extra's slots are untouched
  assert_eq "$(solo_review_get "$T" widget 7)$(solo_review_get "$T" widget 7 review-browser)" "" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# AN ADVISORY QA AGENT (started by hand, not required) blocks only on its
# `changes` at the head - the same rule as an advisory reviewer; its
# `blocked` is not a finding about the change and holds nothing up.
test_solo_land_advisory_qa_changes_blocks_and_blocked_does_not() {
  _solo_setup; _solo_qa_policy
  export STUB_FILES='[[{"filename":"README.md"}]]'
  _review widget#7 approved --head "$H" --by widget-pr-7-review >/dev/null
  _qa_previewed "$H"
  _qa_as changes "$H" --evidence "$(_qa_shot "submit-${H:0:12}.png")" --note "submit does nothing" >/dev/null || { rm -rf "$T"; return 1; }
  local out; out="$(_land widget#7 2>&1)" && { echo "merged over a QA finding at the head"; rm -rf "$T"; return 1; }
  assert_contains "$out" "$QA (qa browser; started by hand, not required by policy) asked for changes at aaaaaaaaaaaa" || { rm -rf "$T"; return 1; }
  ! _merged || { rm -rf "$T"; return 1; }
  _qa_as blocked "$H" --note "no browser on this box" >/dev/null || { rm -rf "$T"; return 1; }
  out="$(_land widget#7 2>&1)" || { echo "an advisory blocked held the land: $out"; rm -rf "$T"; return 1; }
  _merged || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
