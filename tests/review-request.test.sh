# shellcheck shell=bash
# `cel-fanout request-review`: the one supported way to ask the configured
# external GitHub reviewer to look at a fleet PR, bound to an exact head.
#
# The backend is a STATEFUL gh fixture, not a forwarding mock: it holds one
# pull request (head, ref, draft/state, author), a list of reviews and a list
# of requested reviewers. A POST to requested_reviewers changes that state
# (and can be told to lie, lag, fail, or move the head), and every state
# change lands in mutations.log - so "refused with zero mutation" is asserted
# on the log and on the ledger bytes, never just on an error string.
source "$CEL_ROOT/lib/common.sh"
BIN="$CEL_ROOT/core/skills/fanout/bin/cel-fanout"

HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# <review-json> : the ledger review object ("none" = no review key at all)
_rr_setup() {
  T="$(mktemp -d)"; G="$T/gh"; mkdir -p "$G" "$T/.cel" "$T/repos/widget"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  yq -y '.policy.pr_open = "ready" | .policy.reviewer = "rev-bot" | .github.user = "acct-b"' \
    "$T/workspace.yaml" > "$T/ws.tmp" && mv "$T/ws.tmp" "$T/workspace.yaml"
  local review="${1:-}"
  [ -n "$review" ] || review='{"verdict":"approved","by":"rev-1","note":"ok","at":"2026-10-17T00:00:00Z","head":"'$HEAD_A'","head_source":"explicit"}'
  jq -n --argjson r "$review" '[{id:"WG-RR",state:"finished",repo:"widget",branch:"WG-RR",worktree:"/nonexistent/unpushed-local-head"}
    | if $r == "none" then . else .review = $r end]' > "$T/.cel/delegations.json"
  # the PR, as the REST API reports it
  jq -n --arg h "$HEAD_A" '{number:7,state:"open",draft:false,merged:false,user:{login:"fleetbot"},
    head:{sha:$h,ref:"WG-RR",repo:{full_name:"someone/widget"}},base:{ref:"main"}}' > "$G/pull.json"
  printf '%s' "$HEAD_A" > "$G/ref"
  echo '[]' > "$G/reviews.json"; : > "$G/requested"; : > "$G/mutations.log"
  cat > "$T/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
G="$STUB_GH_DIR"
echo "$*" >> "$G/calls.log"
pull() { # current REST pull, requested_reviewers from state
  jq --rawfile r "$G/requested" '.requested_reviewers = [($r | split("\n") | map(select(length>0)) | .[] | {login:.})]' "$G/pull.json"
}
case "$1 $2" in
  "auth token") [ "$4" = acct-b ] && { echo tok-b; exit 0; }; exit 1;;
  "api user")   echo fleetbot; exit 0;;
  "pr view")    [ -n "${STUB_LOOKUP_FAIL:-}" ] && exit 1
                echo '{"number":7,"reviewRequests":[]}'; exit 0;;   # gh pr view lags: always empty
esac
if [ "$1" = api ]; then
  shift
  method=GET; [ "$1" = -X ] && { method="$2"; shift 2; }
  path="$1"; shift
  case "$method $path" in
    "GET repos/someone/widget/pulls/7") [ -n "${STUB_LOOKUP_FAIL:-}" ] && exit 1; pull; exit 0;;
    "GET repos/someone/widget/git/ref/heads/WG-RR") jq -n --arg s "$(cat "$G/ref")" '{object:{sha:$s}}'; exit 0;;
    "GET repos/someone/widget/pulls/7/reviews") cat "$G/reviews.json"; exit 0;;
    "POST repos/someone/widget/pulls/7/requested_reviewers")
      who="$(printf '%s\n' "$@" | sed -n 's/^reviewers\[\]=//p')"
      echo "POST $path reviewers=$who" >> "$G/mutations.log"
      [ -n "${STUB_POST_FAIL:-}" ] && exit 1
      [ -n "${STUB_POST_LIES:-}" ] || printf '%s\n' "$who" >> "$G/requested"
      [ -n "${STUB_HEAD_MOVES:-}" ] && jq --arg h "$STUB_HEAD_MOVES" '.head.sha = $h' "$G/pull.json" > "$G/p.tmp" && mv "$G/p.tmp" "$G/pull.json"
      echo '{}'; exit 0;;
  esac
fi
# anything else that is not a plain read is a mutation this verb must never make
echo "UNEXPECTED $*" >> "$G/mutations.log"
exit 1
EOF
  chmod +x "$T/gh-stub.sh"
  export CEL_FANOUT_GH="$T/gh-stub.sh" STUB_GH_DIR="$G"
  LEDGER_SUM="$(sha256sum "$T/.cel/delegations.json" | cut -d' ' -f1)"
}

_rr() { # <args...> -> output (stdout+stderr); sets RC
  local out; out="$(cd "$T" && "$BIN" request-review "$@" 2>&1)"; RC=$?; printf '%s' "$out"
}

# every refusal: non-zero, ZERO mutation markers, ledger bytes unchanged
_rr_assert_refused() { # <needle> <output>
  [ "$RC" -ne 0 ] || { echo "expected refusal, got success: $2"; return 1; }
  assert_contains "$2" "$1" || return 1
  assert_eq "$(cat "$G/mutations.log")" "" || return 1
  assert_eq "$(sha256sum "$T/.cel/delegations.json" | cut -d' ' -f1)" "$LEDGER_SUM"
}

test_request_review_attaches_only_the_configured_reviewer() {
  _rr_setup
  local out; out="$(_rr WG-RR --head $HEAD_A)"
  assert_eq "$RC" 0 || { echo "$out"; return 1; }
  assert_eq "$(cat "$G/mutations.log")" "POST repos/someone/widget/pulls/7/requested_reviewers reviewers=rev-bot"
  assert_contains "$out" "rev-bot"
  assert_contains "$out" "$HEAD_A"
  # verified from requested_reviewers, and said so - not from gh pr view, which lags here
  assert_contains "$out" "requested_reviewers"
  # a request is not an approval, a marker or a landing: ledger byte-identical
  assert_eq "$(sha256sum "$T/.cel/delegations.json" | cut -d' ' -f1)" "$LEDGER_SUM"
  # the call ran as the workspace's account, never the box's active one
  grep -q '^auth token --user acct-b' "$G/calls.log"
  rm -rf "$T"
}

test_request_review_explicit_reviewer_may_only_select_the_configured_one() {
  _rr_setup
  local out; out="$(_rr WG-RR --head $HEAD_A --reviewer rev-bot)"
  assert_eq "$RC" 0 || { echo "$out"; return 1; }
  rm -rf "$T"; _rr_setup
  out="$(_rr WG-RR --head $HEAD_A --reviewer someone-else)"
  _rr_assert_refused "configured" "$out"
  rm -rf "$T"
}

test_request_review_refuses_without_reviewer_policy() {
  _rr_setup
  yq -y '.policy.reviewer = null' "$T/workspace.yaml" > "$T/ws.tmp" && mv "$T/ws.tmp" "$T/workspace.yaml"
  local out; out="$(_rr WG-RR --head $HEAD_A)"
  _rr_assert_refused "reviewer" "$out"
  # --reviewer cannot invent policy where none exists
  out="$(_rr WG-RR --head $HEAD_A --reviewer rev-bot)"
  _rr_assert_refused "reviewer" "$out"
  rm -rf "$T"
}

test_request_review_refuses_contradictory_policy() {
  _rr_setup
  yq -y '.policy.pr_open = "draft"' "$T/workspace.yaml" > "$T/ws.tmp" && mv "$T/ws.tmp" "$T/workspace.yaml"
  local out; out="$(_rr WG-RR --head $HEAD_A)"
  _rr_assert_refused "pr_open" "$out"
  rm -rf "$T"
}

test_request_review_refuses_a_missing_or_malformed_head() {
  local bad out
  _rr_setup
  out="$(_rr WG-RR)"; _rr_assert_refused "--head" "$out" || return 1
  for bad in aaaaaaa "${HEAD_A:0:39}" "${HEAD_A}a" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" HEAD; do
    out="$(_rr WG-RR --head "$bad")"; _rr_assert_refused "40" "$out" || return 1
  done
  rm -rf "$T"
}

test_request_review_refuses_unknown_delegation_and_wrong_workspace() {
  _rr_setup
  local out; out="$(_rr NOPE --head $HEAD_A)"; _rr_assert_refused "no delegation" "$out" || return 1
  out="$(cd "$T" && "$BIN" request-review WG-RR --head $HEAD_A --workspace no-such-ws-xyz 2>&1)"; RC=$?
  _rr_assert_refused "" "$out"
  rm -rf "$T"
}

test_request_review_refuses_missing_stale_changes_or_implicit_review_records() {
  local out
  # no review at all
  _rr_setup none; out="$(_rr WG-RR --head $HEAD_A)"; _rr_assert_refused "approved" "$out" || return 1; rm -rf "$T"
  # a changes verdict
  _rr_setup '{"verdict":"changes","by":"r","head":"'$HEAD_A'","head_source":"explicit"}'
  out="$(_rr WG-RR --head $HEAD_A)"; _rr_assert_refused "approved" "$out" || return 1; rm -rf "$T"
  # a historical record: approved, right-looking head, but implicit (no head_source)
  _rr_setup '{"verdict":"approved","by":"r","head":"'$HEAD_A'"}'
  out="$(_rr WG-RR --head $HEAD_A)"; _rr_assert_refused "explicit" "$out" || return 1; rm -rf "$T"
  # a marker that is not "explicit" is not attestation either
  _rr_setup '{"verdict":"approved","by":"r","head":"'$HEAD_A'","head_source":"local"}'
  out="$(_rr WG-RR --head $HEAD_A)"; _rr_assert_refused "explicit" "$out" || return 1; rm -rf "$T"
  # approved explicitly, but for an older head than the one requested
  _rr_setup '{"verdict":"approved","by":"r","head":"'$HEAD_B'","head_source":"explicit"}'
  out="$(_rr WG-RR --head $HEAD_A)"; _rr_assert_refused "review" "$out" || return 1; rm -rf "$T"
}

test_request_review_refuses_when_the_pr_moved_off_the_reviewed_head() {
  _rr_setup
  jq --arg h "$HEAD_B" '.head.sha = $h' "$G/pull.json" > "$G/p.tmp" && mv "$G/p.tmp" "$G/pull.json"
  local out; out="$(_rr WG-RR --head $HEAD_A)"
  _rr_assert_refused "head" "$out" || return 1
  rm -rf "$T"
}

test_request_review_refuses_when_the_remote_branch_ref_disagrees() {
  _rr_setup
  # the PR object still says A, the actual branch ref has already moved
  printf '%s' "$HEAD_B" > "$G/ref"
  local out; out="$(_rr WG-RR --head $HEAD_A)"
  _rr_assert_refused "branch" "$out" || return 1
  rm -rf "$T"
}

test_request_review_refuses_draft_closed_merged_foreign_and_wrong_branch_prs() {
  local out edit
  for edit in '.draft = true' '.state = "closed"' '.merged = true' '.user.login = "a-colleague"' \
              '.head.ref = "other-branch"' '.head.repo.full_name = "fork/widget"'; do
    _rr_setup
    jq "$edit" "$G/pull.json" > "$G/p.tmp" && mv "$G/p.tmp" "$G/pull.json"
    out="$(_rr WG-RR --head $HEAD_A)"
    _rr_assert_refused "" "$out" || { echo "no refusal for: $edit"; return 1; }
    rm -rf "$T"
  done
}

test_request_review_refuses_when_github_cannot_be_read() {
  _rr_setup
  local out; out="$(STUB_LOOKUP_FAIL=1 _rr WG-RR --head $HEAD_A)"
  _rr_assert_refused "" "$out" || return 1
  rm -rf "$T"
}

test_request_review_refuses_when_the_account_is_not_logged_in() {
  _rr_setup
  yq -y '.github.user = "not-logged-in"' "$T/workspace.yaml" > "$T/ws.tmp" && mv "$T/ws.tmp" "$T/workspace.yaml"
  local out; out="$(_rr WG-RR --head $HEAD_A)"
  _rr_assert_refused "not logged in" "$out" || return 1
  rm -rf "$T"
}

test_request_review_fails_when_the_request_did_not_attach() {
  _rr_setup
  # gh exits 0 but the reviewer never shows up in requested_reviewers
  local out; out="$(STUB_POST_LIES=1 _rr WG-RR --head $HEAD_A)"
  [ "$RC" -ne 0 ] || { echo "reported success on an unattached request: $out"; return 1; }
  assert_contains "$out" "not attached"
  rm -rf "$T"
  # and a POST that errors is a failure, not a success
  _rr_setup
  out="$(STUB_POST_FAIL=1 _rr WG-RR --head $HEAD_A)"
  [ "$RC" -ne 0 ] || { echo "reported success on a failed POST: $out"; return 1; }
  rm -rf "$T"
}

test_request_review_does_not_call_a_request_for_a_moved_head_a_success() {
  _rr_setup
  # the head advances between the checks and the attach: GitHub cannot CAS this
  local out; out="$(STUB_HEAD_MOVES=$HEAD_B _rr WG-RR --head $HEAD_A)"
  [ "$RC" -ne 0 ] || { echo "reported success though the head moved: $out"; return 1; }
  assert_contains "$out" "moved"
  assert_contains "$out" "$HEAD_B"
  assert_contains "$out" "not a review of"
  # ledger still untouched: nothing recorded, no approval carried to the new head
  assert_eq "$(sha256sum "$T/.cel/delegations.json" | cut -d' ' -f1)" "$LEDGER_SUM"
  rm -rf "$T"
}

test_request_review_is_idempotent_when_already_requested() {
  _rr_setup
  echo rev-bot > "$G/requested"
  local out; out="$(_rr WG-RR --head $HEAD_A)"
  assert_eq "$RC" 0 || { echo "$out"; return 1; }
  assert_contains "$out" "already requested"
  assert_eq "$(cat "$G/mutations.log")" ""
  rm -rf "$T"
}

test_request_review_does_not_rerequest_a_reviewer_who_reviewed_this_head() {
  _rr_setup
  jq -n --arg h "$HEAD_A" '[{user:{login:"rev-bot"},state:"COMMENTED",commit_id:$h}]' > "$G/reviews.json"
  local out; out="$(_rr WG-RR --head $HEAD_A)"
  assert_eq "$RC" 0 || { echo "$out"; return 1; }
  assert_contains "$out" "already reviewed"
  assert_eq "$(cat "$G/mutations.log")" ""
  rm -rf "$T"
}

test_request_review_treats_a_review_of_an_older_head_as_no_review_of_this_one() {
  _rr_setup
  jq -n --arg h "$HEAD_B" '[{user:{login:"rev-bot"},state:"APPROVED",commit_id:$h}]' > "$G/reviews.json"
  local out; out="$(_rr WG-RR --head $HEAD_A)"
  assert_eq "$RC" 0 || { echo "$out"; return 1; }
  assert_eq "$(cat "$G/mutations.log")" "POST repos/someone/widget/pulls/7/requested_reviewers reviewers=rev-bot"
  rm -rf "$T"
}

test_request_review_dry_run_checks_everything_and_changes_nothing() {
  _rr_setup
  local out; out="$(_rr WG-RR --head $HEAD_A --dry-run)"
  assert_eq "$RC" 0 || { echo "$out"; return 1; }
  assert_contains "$out" "dry run"
  assert_contains "$out" "would"
  case "$out" in *"attached"*"verified"*) echo "dry run claims an attachment: $out"; return 1;; esac
  assert_eq "$(cat "$G/mutations.log")" ""
  assert_eq "$(cat "$G/requested")" ""
  rm -rf "$T"
  # and a dry run still refuses what a live run refuses
  _rr_setup '{"verdict":"approved","by":"r","head":"'$HEAD_A'"}'
  out="$(_rr WG-RR --head $HEAD_A --dry-run)"
  _rr_assert_refused "explicit" "$out"
  rm -rf "$T"
}

test_request_review_makes_no_call_outside_the_reviewer_request() {
  _rr_setup
  _rr WG-RR --head $HEAD_A >/dev/null
  # no pr edit/ready/merge/close, no label/branch/ref writes: only reads plus the one POST
  ! grep -Eq '^pr (edit|ready|merge|close|reopen|create)' "$G/calls.log"
  assert_eq "$(grep -c '^api -X' "$G/calls.log")" "1"
  rm -rf "$T"
}

test_request_review_is_a_fleet_verb_workers_do_not_run() {
  grep -Eq '^  land\|release\|collect\|request-review\)' "$BIN"
}
