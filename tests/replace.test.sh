# shellcheck shell=bash
# `cel-fanout replace reserve|attach`: publish a CLEAN replacement for a
# fleet PR whose branch carried private artifacts, without force-pushing,
# without copying an approval, and without editing a ledger row by hand.
#
# The fixture is behavioural, not an echo of the source:
#  - a REAL git repository (origin + clone + linked worktree) holds the
#    original dirty branch and the clean candidate, so ancestry and blob
#    preservation are judged by git, not by a stub;
#  - a STATEFUL gh stub holds the pull requests (head, state, draft, author,
#    cross-repo) and the remote refs, and every GitHub WRITE it is asked for
#    lands in mutations.log - replace never writes to GitHub, so that file is
#    asserted empty everywhere. A merge (land) is logged apart in merges.log.
# Every refusal is asserted as non-zero, the exact message, ledger bytes
# unchanged and zero mutations.
source "$CEL_ROOT/lib/common.sh"
BIN="$CEL_ROOT/core/skills/fanout/bin/cel-fanout"

_rp_git() { git -C "$T/repos/widget" "$@"; }

# Builds origin, clone, a linked worktree on WG-1 holding the dirty branch, a
# ledger with the source row, the gh stub and a verifier stub. Sets T G OH
# (original head) TH (clean candidate head) and the identity variables.
_rp_setup() {
  T="$(mktemp -d)"; G="$T/gh"; mkdir -p "$G" "$T/.cel" "$T/inbox"
  export CEL_INBOX_DIR="$T/inbox"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  yq -y '.policy.pr_open = "ready" | .policy.merge = "self" | .github.user = "acct-b"' \
    "$T/workspace.yaml" > "$T/ws.tmp" && mv "$T/ws.tmp" "$T/workspace.yaml"
  git init -q --bare -b main "$T/origin.git"
  git clone -q "$T/origin.git" "$T/repos/widget" 2>/dev/null
  _rp_git checkout -q -b main 2>/dev/null || true
  printf 'base\n' > "$T/repos/widget/README.md"
  _rp_git add README.md && _rp_git commit -q -m base && _rp_git push -q origin main 2>/dev/null
  _rp_git fetch -q origin
  _rp_git worktree add -q -b WG-1 "$T/wt" main
  # commit 1: product + private artifacts; commit 2: more product
  mkdir -p "$T/wt/src" "$T/wt/changelog.d" "$T/wt/.agent/proof"
  printf 'test one\n' > "$T/wt/src/a.test.ts"
  printf 'a change\n' > "$T/wt/changelog.d/WG-1.md"
  printf 'private handoff\n' > "$T/wt/.agent/result.md"
  printf 'private proof\n' > "$T/wt/.agent/proof/run.log"
  git -C "$T/wt" add -f -A && git -C "$T/wt" commit -q -m "work and handoff"
  printf 'test two\n' >> "$T/wt/src/a.test.ts"
  git -C "$T/wt" add -A && git -C "$T/wt" commit -q -m "more work"
  OH="$(git -C "$T/wt" rev-parse HEAD)"
  TH="$(_rp_clean_commit "$OH" "WG-1 clean")"
  jq -n --arg wt "$T/wt" --arg oh "$OH" '[{id:"WG-1",repo:"widget",branch:"WG-1",alias:"widget-WG-1",
    herdr_ws:"wC",pane:"p1",worktree:$wt,spec:"/x/spec.md",state:"collected",created:"2026-10-17T00:00:00Z",
    profile:"p",runtime:"pi",model:"m",thinking:"low",ticket:"",provider:"x",shape:"ship",
    review:{verdict:"approved",by:"rev-1",note:"ok",at:"2026-10-17T00:00:00Z",head:$oh,head_source:"explicit"},
    verdict:{gate:true},history:[{state:"collected",at:"2026-10-17T00:00:00Z",by:"orch"}]}]' \
    > "$T/.cel/delegations.json"
  _rp_pr WG-1 "$OH" 11
  echo "$OH" > "$G/ref-WG-1"
  : > "$G/mutations.log"; : > "$G/merges.log"
  cat > "$T/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
G="$STUB_GH_DIR"
echo "$*" >> "$G/calls.log"
case "$1 $2" in
  "auth token") [ "$4" = acct-b ] && { echo tok-b; exit 0; }; exit 1;;
  "api user")   echo fleetbot; exit 0;;
  "pr view")
    b="$3"; [ -f "$G/pr-$b.json" ] || { echo "no pull requests found for branch $b" >&2; exit 1; }
    cat "$G/pr-$b.json"; exit 0;;
  "pr merge")
    echo "$*" >> "$G/merges.log"; exit 0;;
esac
if [ "$1" = api ]; then
  p="$2"
  case "$p" in
    repos/someone/widget/git/ref/heads/*)
      b="${p#repos/someone/widget/git/ref/heads/}"
      [ -n "${STUB_API_FAIL:-}" ] && { echo "gh: HTTP 502 Bad Gateway" >&2; exit 1; }
      [ -f "$G/ref-$b" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      jq -n --arg s "$(cat "$G/ref-$b")" '{object:{sha:$s}}'; exit 0;;
  esac
fi
echo "UNEXPECTED $*" >> "$G/mutations.log"
exit 1
EOF
  chmod +x "$T/gh-stub.sh"
  cat > "$T/verify-stub.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$1/.agent"
printf '{"gate":{"passed":true,"configured":true},"at":"now"}' > "$1/.agent/verdict.json"
echo "gate: pass"
EOF
  chmod +x "$T/verify-stub.sh"
  export CEL_FANOUT_GH="$T/gh-stub.sh" STUB_GH_DIR="$G" CEL_FANOUT_VERIFY="$T/verify-stub.sh"
  LEDGER_SUM="$(_rp_sum)"
}

_rp_sum() { sha256sum "$T/.cel/delegations.json" | cut -d' ' -f1; }

# <branch> <head> <number> [author] [state] [draft] [cross]
_rp_pr() {
  jq -n --arg h "$2" --argjson n "$3" --arg a "${4:-fleetbot}" --arg s "${5:-OPEN}" \
    --argjson d "${6:-false}" --argjson c "${7:-false}" \
    '{number:$n,state:$s,isDraft:$d,headRefOid:$h,baseRefName:"main",author:{login:$a},
      isCrossRepository:$c,mergeable:"MERGEABLE",reviewDecision:"",statusCheckRollup:[]}' > "$G/pr-$1.json"
}

# <orig-head> <message> [drop-regex] -> a commit on main whose tree is the
# original tree minus the private artifacts: built with plumbing in a scratch
# index so no branch or worktree is touched.
_rp_clean_commit() {
  local idx="$T/idx.$RANDOM" tree
  GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" read-tree "$1"
  GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" rm -q --cached -r --ignore-unmatch .agent
  tree="$(GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" write-tree)"
  rm -f "$idx"
  git -C "$T/repos/widget" commit-tree "$tree" -p "$(_rp_git rev-parse main)" -m "$2"
}

# a clean candidate that also changes an implementation file
_rp_tampered_commit() {
  local idx="$T/idx.$RANDOM" tree blob
  GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" read-tree "$OH"
  GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" rm -q --cached -r --ignore-unmatch .agent
  blob="$(printf 'something else\n' | git -C "$T/repos/widget" hash-object -w --stdin)"
  GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" update-index --cacheinfo "100644,$blob,src/a.test.ts"
  tree="$(GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" write-tree)"
  rm -f "$idx"
  git -C "$T/repos/widget" commit-tree "$tree" -p "$(_rp_git rev-parse main)" -m tampered
}

_rp() { # <args...> -> OUT, RC in THIS shell
  RC=0; OUT="$(cd "$T" && "$BIN" "$@" 2>&1)" || RC=$?
}
_reserve_args() { # [branch] [head]
  printf '%s\n' replace reserve WG-1 --original-head "$OH" --pr 11 --alias widget-WG-1 \
    --worktree "$T/wt" --branch "${1:-WG-1-clean}" --head "${2:-$TH}"
}
_reserve() { local -a a; mapfile -t a < <(_reserve_args "$@"); _rp "${a[@]}"; }
_attach() { _rp replace attach "${1:-WG-1-clean}" --head "${2:-$TH}"; }

# publication by the worker: the branch exists remotely and a READY PR is open
_rp_publish() { # [branch] [head] [number]
  printf '%s' "${2:-$TH}" > "$G/ref-${1:-WG-1-clean}"
  _rp_pr "${1:-WG-1-clean}" "${2:-$TH}" "${3:-12}"
}

_rp_refused() { # <needle>
  [ "$RC" -ne 0 ] || { echo "expected refusal, got success: $OUT"; return 1; }
  assert_contains "$OUT" "$1" || return 1
  assert_eq "$(cat "$G/mutations.log")" "" || return 1
  assert_eq "$(_rp_sum)" "$LEDGER_SUM"
}

_rp_row() { jq -c --arg id "$1" '.[] | select(.id == $id)' "$T/.cel/delegations.json"; }
_rp_count() { jq 'length' "$T/.cel/delegations.json"; }

test_replace_reserve_registers_a_child_and_leaves_the_original_row_intact() {
  _rp_setup
  local before; before="$(_rp_row WG-1)"
  _reserve; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_eq "$(_rp_count)" 2
  local child; child="$(_rp_row WG-1-clean)"
  assert_eq "$(printf '%s' "$child" | jq -r .replacement.stage)" reserved
  assert_eq "$(printf '%s' "$child" | jq -r .replacement.of)" WG-1
  assert_eq "$(printf '%s' "$child" | jq -r .replacement.original_head)" "$OH"
  assert_eq "$(printf '%s' "$child" | jq -r .replacement.target_head)" "$TH"
  assert_eq "$(printf '%s' "$child" | jq -r .branch)" WG-1-clean
  # the worker moves to the child; capacity is counted once because the child is the only row that runs
  assert_eq "$(printf '%s' "$child" | jq -r .alias)" widget-WG-1
  assert_eq "$(printf '%s' "$child" | jq -r .state)" running
  # nothing is carried: no review, no verdict, no gate evidence
  assert_eq "$(printf '%s' "$child" | jq -r 'has("review") or has("verdict")')" false
  # the original keeps its state, review, history, head - only a pointer was added
  assert_eq "$(_rp_row WG-1 | jq -c 'del(.replacement)')" "$before"
  assert_eq "$(_rp_row WG-1 | jq -r .replacement.child)" WG-1-clean
  assert_eq "$(cat "$G/mutations.log")" ""
  # the worker is told, by inbox, what it may now publish
  grep -rq "WG-1-clean" "$T/inbox"
  rm -rf "$T"
}

test_replace_reserve_replay_is_idempotent_and_never_duplicates() {
  _rp_setup
  _reserve; assert_eq "$RC" 0 || return 1
  local sum; sum="$(_rp_sum)"
  _reserve; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_eq "$(_rp_sum)" "$sum"
  assert_eq "$(_rp_count)" 2
  rm -rf "$T"
}

test_replace_full_lifecycle_collects_reviews_and_lands_the_replacement() {
  _rp_setup
  _reserve; assert_eq "$RC" 0 || return 1
  # before publication nothing downstream may treat the child as real
  _rp collect WG-1-clean; assert_contains "$OUT" "not attached" || { echo "$OUT"; return 1; }
  assert_eq "$RC" 1
  _rp review WG-1-clean approved --head "$TH" --by rev-2; assert_eq "$RC" 1
  assert_contains "$OUT" "not attached"
  _rp land WG-1-clean; assert_eq "$RC" 1; assert_contains "$OUT" "not attached"
  # the worker publishes; the orchestrator attaches through the same lifecycle
  _rp_publish
  _attach; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_eq "$(_rp_row WG-1-clean | jq -r .replacement.stage)" attached
  assert_eq "$(_rp_row WG-1-clean | jq -r .replacement.pr)" 12
  # the original row and its approval are untouched evidence
  assert_eq "$(_rp_row WG-1 | jq -r .review.verdict)" approved
  # the OLD approval does not carry: the child cannot land on it
  printf 'new handoff\n' > "$T/wt/.agent/result.md"
  _rp collect WG-1-clean; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_eq "$(_rp_row WG-1-clean | jq -r .state)" collected
  _rp land WG-1-clean; assert_eq "$RC" 1; assert_contains "$OUT" "not approved"
  # a review of the OLD head is refused on the child: it must name the PR head
  _rp review WG-1-clean approved --head "$OH" --by rev-2; assert_eq "$RC" 1
  assert_contains "$OUT" "not the PR's current head"
  _rp review WG-1-clean approved --head "$TH" --by rev-2; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_eq "$(_rp_row WG-1-clean | jq -r .review.head_source)" explicit
  _rp land WG-1-clean; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_eq "$(_rp_row WG-1-clean | jq -r .state)" landed
  grep -q -- "--match-head-commit $TH" "$G/merges.log"
  grep -q "pr merge 12" "$G/merges.log"
  # the original is still exactly what it was
  assert_eq "$(_rp_row WG-1 | jq -r .state)" collected
  assert_eq "$(cat "$G/mutations.log")" ""
  rm -rf "$T"
}

test_replace_attach_replay_is_idempotent() {
  _rp_setup; _reserve; _rp_publish
  _attach; assert_eq "$RC" 0 || return 1
  local sum; sum="$(_rp_sum)"
  _attach; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_eq "$(_rp_sum)" "$sum"
  rm -rf "$T"
}

test_replace_refuses_every_identity_mismatch_with_no_mutation() {
  _rp_setup
  local -a a
  # unknown source
  _rp replace reserve NOPE --original-head "$OH" --pr 11 --alias widget-WG-1 --worktree "$T/wt" --branch WG-1-clean --head "$TH"
  _rp_refused "no delegation" || return 1
  # wrong frozen original head
  _rp replace reserve WG-1 --original-head "$TH" --pr 11 --alias widget-WG-1 --worktree "$T/wt" --branch WG-1-clean --head "$TH"
  _rp_refused "original" || return 1
  # wrong PR number
  _rp replace reserve WG-1 --original-head "$OH" --pr 99 --alias widget-WG-1 --worktree "$T/wt" --branch WG-1-clean --head "$TH"
  _rp_refused "PR" || return 1
  # wrong worker alias / worktree
  _rp replace reserve WG-1 --original-head "$OH" --pr 11 --alias someone-else --worktree "$T/wt" --branch WG-1-clean --head "$TH"
  _rp_refused "alias" || return 1
  _rp replace reserve WG-1 --original-head "$OH" --pr 11 --alias widget-WG-1 --worktree "$T/elsewhere" --branch WG-1-clean --head "$TH"
  _rp_refused "worktree" || return 1
  # malformed / abbreviated SHAs
  _rp replace reserve WG-1 --original-head "${OH:0:12}" --pr 11 --alias widget-WG-1 --worktree "$T/wt" --branch WG-1-clean --head "$TH"
  _rp_refused "40" || return 1
  _rp replace reserve WG-1 --original-head "$OH" --pr 11 --alias widget-WG-1 --worktree "$T/wt" --branch WG-1-clean --head HEAD
  _rp_refused "40" || return 1
  # missing required identity
  _rp replace reserve WG-1 --original-head "$OH" --branch WG-1-clean --head "$TH"
  _rp_refused "required" || return 1
  # a target branch that is the original branch, or a target SHA git does not have
  _reserve WG-1 "$TH"; _rp_refused "different" || return 1
  _reserve WG-1-clean cccccccccccccccccccccccccccccccccccccccc; _rp_refused "commit" || return 1
  rm -rf "$T"
}

test_replace_refuses_foreign_cross_repo_merged_closed_and_moved_source_prs() {
  _rp_setup
  _rp_pr WG-1 "$OH" 11 colleague; _reserve; _rp_refused "not by this fleet" || return 1
  _rp_pr WG-1 "$OH" 11 fleetbot OPEN false true; _reserve; _rp_refused "fork" || return 1
  _rp_pr WG-1 "$OH" 11 fleetbot MERGED; _reserve; _rp_refused "MERGED" || return 1
  _rp_pr WG-1 "$OH" 11 fleetbot CLOSED; _reserve; _rp_refused "CLOSED" || return 1
  # the PR head moved away from the frozen original
  _rp_pr WG-1 "$TH" 11; _reserve; _rp_refused "moved" || return 1
  rm -f "$G/pr-WG-1.json"; _reserve; _rp_refused "PR" || return 1
  rm -rf "$T"
}

test_replace_refuses_sources_that_are_running_landed_or_already_replaced() {
  _rp_setup
  local st
  for st in running landed released abandoned orphaned; do
    jq --arg s "$st" 'map(.state = $s)' "$T/.cel/delegations.json" > "$T/l.tmp" && mv "$T/l.tmp" "$T/.cel/delegations.json"
    LEDGER_SUM="$(_rp_sum)"
    _reserve; _rp_refused "$st" || return 1
  done
  jq 'map(.state = "finished")' "$T/.cel/delegations.json" > "$T/l.tmp" && mv "$T/l.tmp" "$T/.cel/delegations.json"
  jq 'map(.shape = "scout")' "$T/.cel/delegations.json" > "$T/l.tmp" && mv "$T/l.tmp" "$T/.cel/delegations.json"
  LEDGER_SUM="$(_rp_sum)"; _reserve; _rp_refused "scout" || return 1
  rm -rf "$T"
}

test_replace_refuses_a_target_branch_that_already_exists_remotely() {
  _rp_setup
  printf 'dddddddddddddddddddddddddddddddddddddddd' > "$G/ref-WG-1-clean"
  _reserve; _rp_refused "already exists" || return 1
  rm -f "$G/ref-WG-1-clean"
  # an unreadable remote is not an absent one
  STUB_API_FAIL=1 _reserve; _rp_refused "could not" || return 1
  rm -rf "$T"
}

test_replace_permits_artifact_removal_but_refuses_changed_implementation() {
  _rp_setup
  # permitted: the happy fixture removes .agent/** and nothing else
  _reserve; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  rm -rf "$T"; _rp_setup
  local bad; bad="$(_rp_tampered_commit)"
  _reserve WG-1-clean "$bad"; _rp_refused "src/a.test.ts" || return 1
  # a file the original never had
  local idx="$T/i2" tree blob extra
  GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" read-tree "$TH"
  blob="$(printf 'new\n' | git -C "$T/repos/widget" hash-object -w --stdin)"
  GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" update-index --add --cacheinfo "100644,$blob,src/extra.ts"
  tree="$(GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" write-tree)"
  extra="$(git -C "$T/repos/widget" commit-tree "$tree" -p main -m extra)"
  _reserve WG-1-clean "$extra"; _rp_refused "src/extra.ts" || return 1
  # a dropped implementation file
  GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" read-tree "$TH"
  GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" rm -q --cached src/a.test.ts
  tree="$(GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" write-tree)"
  extra="$(git -C "$T/repos/widget" commit-tree "$tree" -p main -m dropped)"
  _reserve WG-1-clean "$extra"; _rp_refused "src/a.test.ts" || return 1
  rm -rf "$T"
}

test_replace_refuses_dirty_ancestry_even_when_the_final_tree_is_clean() {
  _rp_setup
  # original head as an ancestor of the candidate: the artifacts are in its history
  local idx="$T/i3" tree dirty
  GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" read-tree "$TH"
  tree="$(GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" write-tree)"
  dirty="$(git -C "$T/repos/widget" commit-tree "$tree" -p "$OH" -m cleanup)"
  _reserve WG-1-clean "$dirty"; _rp_refused "ancestry" || return 1
  # an intermediate commit that adds and a later one that removes an artifact
  local first second
  GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" read-tree "$OH"
  tree="$(GIT_INDEX_FILE="$idx" git -C "$T/repos/widget" write-tree)"
  first="$(git -C "$T/repos/widget" commit-tree "$tree" -p main -m dirty-first)"
  second="$(git -C "$T/repos/widget" commit-tree "$(git -C "$T/repos/widget" rev-parse "$TH^{tree}")" -p "$first" -m remove)"
  _reserve WG-1-clean "$second"; _rp_refused "private artifact" || return 1
  # a candidate that still carries an artifact in its tree
  _reserve WG-1-clean "$first"; _rp_refused ".agent" || return 1
  rm -rf "$T"
}

test_replace_two_concurrent_replacements_yield_exactly_one() {
  _rp_setup
  local th2; th2="$(_rp_clean_commit "$OH" "WG-1 clean second")"
  local -a a b
  mapfile -t a < <(_reserve_args WG-1-clean "$TH")
  mapfile -t b < <(_reserve_args WG-1-other "$th2")
  ( cd "$T" && "$BIN" "${a[@]}" >"$T/o1" 2>&1; echo $? >"$T/r1" ) &
  ( cd "$T" && "$BIN" "${b[@]}" >"$T/o2" 2>&1; echo $? >"$T/r2" ) &
  wait
  local ok; ok=$(( $(cat "$T/r1") == 0 )); ok=$(( ok + ($(cat "$T/r2") == 0) ))
  assert_eq "$ok" 1 || { cat "$T/o1" "$T/o2"; return 1; }
  assert_eq "$(_rp_count)" 2
  assert_eq "$(jq '[.[] | select(.replacement.role == "child")] | length' "$T/.cel/delegations.json")" 1
  grep -qh "already" "$T/o1" "$T/o2"
  rm -rf "$T"
}

test_replace_a_lost_response_after_the_write_resumes_with_the_same_identity() {
  _rp_setup
  CEL_REPLACE_FAULT=after-reserve _reserve
  assert_eq "$RC" 1; assert_contains "$OUT" "fault"
  # the durable write happened: the replay is the same replacement, not a second one
  assert_eq "$(_rp_count)" 2
  local sum; sum="$(_rp_sum)"
  _reserve; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_eq "$(_rp_sum)" "$sum"
  rm -rf "$T"
}

test_replace_a_failure_before_the_write_leaves_nothing_behind() {
  _rp_setup
  CEL_REPLACE_FAULT=before-reserve _reserve
  assert_eq "$RC" 1; assert_contains "$OUT" "fault"
  assert_eq "$(_rp_sum)" "$LEDGER_SUM"
  assert_eq "$(cat "$G/mutations.log")" ""
  _reserve; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  rm -rf "$T"
}

test_replace_attach_failures_at_each_stage_are_resumable() {
  _rp_setup; _reserve; _rp_publish
  local reserved_sum; reserved_sum="$(_rp_sum)"
  CEL_REPLACE_FAULT=before-attach _attach
  assert_eq "$RC" 1; assert_eq "$(_rp_sum)" "$reserved_sum"
  CEL_REPLACE_FAULT=after-attach _attach
  assert_eq "$RC" 1
  assert_eq "$(_rp_row WG-1-clean | jq -r .replacement.stage)" attached
  _attach; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_eq "$(_rp_count)" 2
  rm -rf "$T"
}

test_replace_attach_refuses_an_unpublished_draft_foreign_or_moved_target() {
  _rp_setup; _reserve
  LEDGER_SUM="$(_rp_sum)"
  _attach; _rp_refused "no PR" || return 1
  printf '%s' "$TH" > "$G/ref-WG-1-clean"
  _rp_pr WG-1-clean "$TH" 12 fleetbot OPEN true;  _attach; _rp_refused "draft" || return 1
  _rp_pr WG-1-clean "$TH" 12 colleague;           _attach; _rp_refused "not by this fleet" || return 1
  _rp_pr WG-1-clean "$TH" 12 fleetbot OPEN false true; _attach; _rp_refused "fork" || return 1
  _rp_pr WG-1-clean "$TH" 12 fleetbot MERGED;     _attach; _rp_refused "MERGED" || return 1
  # the target moved after reservation (a push beyond the validated head)
  _rp_pr WG-1-clean "$OH" 12; printf '%s' "$OH" > "$G/ref-WG-1-clean"
  _attach; _rp_refused "reserved" || return 1
  # the ref and the PR disagree
  printf '%s' "$TH" > "$G/ref-WG-1-clean"; _rp_pr WG-1-clean "$OH" 12
  _attach; _rp_refused "reserved" || return 1
  # the attach itself is fenced by the reserved head
  _rp_publish
  _rp replace attach WG-1-clean --head "$OH"; _rp_refused "reserved" || return 1
  # the frozen original moved after reservation
  _rp_pr WG-1 "$TH" 11
  _attach; _rp_refused "original" || return 1
  rm -rf "$T"
}

test_replace_attach_refuses_an_unknown_or_unreserved_row() {
  _rp_setup
  _rp replace attach WG-1 --head "$OH"; _rp_refused "replacement" || return 1
  _rp replace attach NOPE --head "$TH"; _rp_refused "no delegation" || return 1
  rm -rf "$T"
}

test_replace_is_orchestrator_only() {
  _rp_setup
  local wt="$T/worktrees"; mkdir -p "$wt/widget/WG-1"
  RC=0; OUT="$(cd "$wt/widget/WG-1" && CEL_WORKTREES="$wt" "$BIN" replace reserve WG-1 2>&1)" || RC=$?
  assert_eq "$RC" 1
  assert_contains "$OUT" "worker"
  assert_eq "$(_rp_sum)" "$LEDGER_SUM"
  rm -rf "$T"
}

test_replace_release_of_the_original_cannot_remove_the_live_replacements_worktree() {
  _rp_setup; _reserve; _rp_publish; _attach
  jq 'map(if .id == "WG-1" then .state = "landed" else . end)' "$T/.cel/delegations.json" > "$T/l.tmp" && mv "$T/l.tmp" "$T/.cel/delegations.json"
  local sum; sum="$(_rp_sum)"
  _rp release WG-1; assert_eq "$RC" 1
  assert_contains "$OUT" "WG-1-clean"
  assert_eq "$(_rp_sum)" "$sum"
  [ -d "$T/wt" ]
  rm -rf "$T"
}

test_replace_a_shared_worker_is_one_fleet_row_and_one_slot() {
  _rp_setup; _reserve; _rp_publish; _attach
  # status --json carries the lineage on both rows
  local out; out="$(cd "$T" && CEL_FANOUT_HERDR=true "$BIN" status --json 2>/dev/null)"
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.replaced_by == "WG-1-clean")] | length')" 1 || { echo "$out"; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.replaces == "WG-1")] | length')" 1
  rm -rf "$T"
}
