# shellcheck shell=bash
# `cel-fanout replace bind`: move a replacement child's SOURCE CHECKOUT from the
# original worker's dirty worktree to the clean candidate's worktree, without
# restarting the actor, touching the old tree, or letting old evidence approve
# the new source.
#
# The fixture is behavioural: REAL git worktrees (one carries 125 dirty and
# untracked entries, shaped like the paid-video tree it stands for), a ledger
# with a source row and an attached child, and a herdr stub that answers from a
# file and logs every call - so "the actor was never restarted or prompted" is
# an assertion about the log, not a comment. No gh, no token, no model.
source "$CEL_ROOT/lib/common.sh"
BIN="$CEL_ROOT/core/skills/fanout/bin/cel-fanout"
OLDSESS="/sessions/native-1.jsonl"

_rb_git() { git -C "$T/repos/widget" "$@"; }

_rb_agents() { # <name> <pane_id> <session> <cwd>
  jq -n --arg n "$1" --arg p "$2" --arg s "$3" --arg c "$4" \
    '{result:{agents:[{name:$n,pane_id:$p,agent:"pi",agent_status:"idle",cwd:$c,foreground_cwd:$c,agent_session:(if $s == "" then null else {kind:"path",value:$s} end)}]}}' > "$T/agents.json"
}

_rb_setup() {
  T="$(mktemp -d)"; mkdir -p "$T/.cel" "$T/inbox"
  export CEL_INBOX_DIR="$T/inbox"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  yq -y '.policy.pr_open = "ready" | .policy.merge = "self" | .github.user = "acct-b"' \
    "$T/workspace.yaml" > "$T/ws.tmp" && mv "$T/ws.tmp" "$T/workspace.yaml"
  git init -q --bare -b main "$T/origin.git"
  git clone -q "$T/origin.git" "$T/repos/widget" 2>/dev/null
  _rb_git checkout -q -b main 2>/dev/null || true
  printf 'base\n' > "$T/repos/widget/README.md"; printf 'tracked\n' > "$T/repos/widget/t.txt"
  _rb_git add -A && _rb_git commit -q -m base && _rb_git push -q origin main 2>/dev/null
  # the OLD worker tree: its own branch, one commit, then 125 dirty/untracked entries
  _rb_git worktree add -q -b WG-1 "$T/wt" main
  printf 'old work\n' > "$T/wt/old.txt"; git -C "$T/wt" add old.txt; git -C "$T/wt" commit -q -m "old work"
  OLDHEAD="$(git -C "$T/wt" rev-parse HEAD)"
  mkdir -p "$T/wt/.agent/proof" "$T/wt/media"
  local i
  for i in $(seq 1 100); do printf 'clip %s\n' "$i" > "$T/wt/media/clip-$i.bin"; done
  for i in $(seq 1 20); do printf 'proof %s\n' "$i" > "$T/wt/.agent/proof/p-$i.log"; done
  printf 'edited\n' >> "$T/wt/t.txt"; printf 'edited\n' >> "$T/wt/old.txt"
  printf 'x\n' > "$T/wt/new-a.txt"; printf 'y\n' > "$T/wt/new-b.txt"; printf 'z\n' > "$T/wt/new-c.txt"
  # the CLEAN candidate: its own branch and worktree
  _rb_git worktree add -q -b WG-1-clean "$T/wtc" main
  printf 'clean work\n' > "$T/wtc/clean.txt"; git -C "$T/wtc" add clean.txt; git -C "$T/wtc" commit -q -m "clean work"
  TH="$(git -C "$T/wtc" rev-parse HEAD)"
  jq -n --arg wt "$T/wt" --arg oh "$OLDHEAD" --arg th "$TH" '[
   {id:"WG-1",repo:"widget",branch:"WG-1",alias:"widget-WG-1",herdr_ws:"wC",pane:"p1",worktree:$wt,spec:"/x/spec.md",
    state:"collected",created:"2026-10-17T00:00:00Z",profile:"p",runtime:"pi",model:"m",thinking:"low",ticket:"",provider:"x",shape:"ship",
    review:{verdict:"approved",by:"rev-1",note:"ok",at:"2026-10-17T00:00:00Z",head:$oh,head_source:"explicit"},
    verdict:{gate:true},replacement:{role:"source",child:"WG-1-clean",at:"2026-10-18T00:00:00Z",by:"orch"},
    history:[{state:"collected",at:"2026-10-17T00:00:00Z",by:"orch"}]},
   {id:"WG-1-clean",repo:"widget",branch:"WG-1-clean",alias:"widget-WG-1",herdr_ws:"wC",pane:"p1",worktree:$wt,spec:"/x/spec.md",
    state:"running",created:"2026-10-18T00:00:00Z",profile:"p",runtime:"pi",model:"m",thinking:"low",ticket:"",provider:"x",shape:"ship",
    review:{verdict:"approved",by:"rev-1",note:"old tree",at:"2026-10-18T00:00:00Z",head:$oh,head_source:"explicit"},
    verdict:{gate:true,at:"old"},
    replacement:{role:"child",of:"WG-1",original_branch:"WG-1",original_head:$oh,original_pr:11,target_branch:"WG-1-clean",target_head:$th,
                 stage:"attached",pr:12,reserved_at:"2026-10-18T00:00:00Z",reserved_by:"orch"},
    history:[{state:"running",at:"2026-10-18T00:00:00Z",by:"orch"}]}]' > "$T/.cel/delegations.json"
  _rb_agents widget-WG-1 wC:p1 "$OLDSESS" "$T/wt"
  cat > "$T/herdr-stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$T/herdr.log"
case "$1 $2" in
  "agent list") cat "$T/agents.json" ;;
  "agent get")  exit 0 ;;
  *) echo "UNEXPECTED $*" >> "$T/herdr-bad.log"; exit 1 ;;
esac
STUB
  chmod +x "$T/herdr-stub.sh"
  cat > "$T/verify-stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$T/verify.log"
mkdir -p "$1/.agent"
printf '{"gate":{"passed":true,"configured":true},"at":"now"}' > "$1/.agent/verdict.json"
echo "gate: pass"
STUB
  chmod +x "$T/verify-stub.sh"
  : > "$T/herdr.log"; : > "$T/herdr-bad.log"; : > "$T/verify.log"
  export T CEL_FANOUT_HERDR="$T/herdr-stub.sh" CEL_FANOUT_VERIFY="$T/verify-stub.sh"
  LEDGER_SUM="$(_rb_sum)"; OLD_SUM="$(_rb_old_sum)"
}

_rb_sum() { sha256sum "$T/.cel/delegations.json" | cut -d' ' -f1; }
# Everything of the old checkout a bind could damage: every file's bytes, the
# worktree's git metadata, all refs, and the porcelain status.
_rb_old_sum() {
  { (cd "$T/wt" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
    cat "$T/wt/.git"
    (cd "$T/repos/widget/.git/worktrees/wt" && for f in HEAD index gitdir commondir; do printf '%s ' "$f"; sha256sum < "$f"; done)
    _rb_git for-each-ref refs/heads/WG-1
    GIT_OPTIONAL_LOCKS=0 git -C "$T/wt" status --porcelain=v1 -uall; } | sha256sum | cut -d' ' -f1
}
_rb_row() { jq -c --arg id "$1" '.[] | select(.id == $id)' "$T/.cel/delegations.json"; }
_rb_inbox() { find "$T/inbox" -type f 2>/dev/null | wc -l; }

_rb() { RC=0; OUT="$(cd "$T" && "$BIN" "$@" 2>&1)" || RC=$?; }
_rb_bind_args() { # [clean] [head] [alias] [pane] [from]
  printf '%s\n' replace bind WG-1-clean --from-worktree "${5:-$T/wt}" --worktree "${1:-$T/wtc}" --head "${2:-$TH}" \
    --alias "${3:-widget-WG-1}" --pane "${4:-p1}"
}
_rb_bind() { local -a a; mapfile -t a < <(_rb_bind_args "$@"); _rb "${a[@]}"; }

# a refusal: non-zero, the message, and NOTHING moved - ledger, old tree,
# inbox, no recovery record, no mutating herdr call
_rb_refused() { # <needle>
  [ "$RC" -ne 0 ] || { echo "expected refusal, got success: $OUT"; return 1; }
  assert_contains "$OUT" "$1" || return 1
  assert_eq "$(_rb_sum)" "$LEDGER_SUM" || return 1
  assert_eq "$(_rb_old_sum)" "$OLD_SUM" || return 1
  assert_eq "$(_rb_inbox)" 0 || return 1
  assert_eq "$(ls "$T/.cel/bindings" 2>/dev/null | wc -l)" 0 || return 1
  assert_eq "$(cat "$T/herdr-bad.log")" "" || return 1
  [ "$(grep -c -v '^agent list$' "$T/herdr.log")" -eq 0 ] || { echo "herdr was asked for more than agent list"; return 1; }
}

test_bind_moves_the_source_to_the_clean_checkout_and_preserves_the_dirty_old_tree() {
  _rb_setup
  assert_eq "$(GIT_OPTIONAL_LOCKS=0 git -C "$T/wt" status --porcelain=v1 -uall | wc -l)" 125 || return 1
  local refs src; refs="$(_rb_git for-each-ref)"; src="$(_rb_row WG-1)"
  _rb_bind; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  # the old tree is byte-for-byte what it was: files, git metadata, refs, status
  assert_eq "$(_rb_old_sum)" "$OLD_SUM"
  assert_eq "$(_rb_git for-each-ref)" "$refs"
  assert_eq "$(git -C "$T/wt" symbolic-ref HEAD)" refs/heads/WG-1
  # the row: same owner, same native identity, the clean checkout
  local c; c="$(_rb_row WG-1-clean)"
  assert_eq "$(printf '%s' "$c" | jq -r .worktree)" "$(realpath "$T/wtc")"
  assert_eq "$(printf '%s' "$c" | jq -r .alias)" widget-WG-1
  assert_eq "$(printf '%s' "$c" | jq -r .pane)" p1
  assert_eq "$(printf '%s' "$c" | jq -r .state)" running
  assert_eq "$(printf '%s' "$c" | jq -r .replacement.stage)" attached
  assert_eq "$(printf '%s' "$c" | jq -r .binding.actor.session)" "$OLDSESS"
  assert_eq "$(printf '%s' "$c" | jq -r .binding.actor.native_cwd)" "$T/wt"
  assert_eq "$(printf '%s' "$c" | jq -r .binding.old_tree.dirty_entries)" 125
  assert_eq "$(printf '%s' "$c" | jq -r .binding.old_tree.ref)" refs/heads/WG-1
  assert_eq "$(printf '%s' "$c" | jq -r .binding.old_tree.head)" "$OLDHEAD"
  assert_eq "$(printf '%s' "$c" | jq -r .binding.head)" "$TH"
  assert_eq "$(printf '%s' "$c" | jq -r '.history | length')" 2
  # the source row is untouched evidence
  assert_eq "$(_rb_row WG-1)" "$src"
  # the actor was identified and told, never restarted, prompted or moved
  assert_eq "$(cat "$T/herdr-bad.log")" ""
  [ "$(grep -c -v '^agent list$' "$T/herdr.log")" -eq 0 ] || { cat "$T/herdr.log"; return 1; }
  grep -rq "$(realpath "$T/wtc")" "$T/inbox"
  ls "$T/.cel/bindings"/WG-1-clean-*.pre.json >/dev/null
  rm -rf "$T"
}

test_bind_supersedes_the_old_review_and_gate_evidence() {
  _rb_setup
  _rb_bind; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  local c; c="$(_rb_row WG-1-clean)"
  assert_eq "$(printf '%s' "$c" | jq -r 'has("review") or has("verdict")')" false
  assert_eq "$(printf '%s' "$c" | jq -r .binding.superseded.review.head)" "$OLDHEAD"
  assert_eq "$(printf '%s' "$c" | jq -r .binding.superseded.verdict.gate)" true
  rm -rf "$T"
}

test_bind_makes_collect_and_the_verifier_act_on_the_clean_checkout() {
  _rb_setup
  _rb_bind; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  printf 'clean handoff\n' > "$T/wtc/.agent/result.md" 2>/dev/null || { mkdir -p "$T/wtc/.agent"; printf 'clean handoff\n' > "$T/wtc/.agent/result.md"; }
  printf 'OLD handoff\n' > "$T/wt/.agent/result.md"
  OLD_SUM="$(_rb_old_sum)"
  _rb collect WG-1-clean; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_contains "$OUT" "clean handoff"
  [ "${OUT#*OLD handoff}" = "$OUT" ] || { echo "collect read the old result"; return 1; }
  assert_eq "$(cat "$T/verify.log")" "$(realpath "$T/wtc")"
  assert_eq "$(_rb_old_sum)" "$OLD_SUM"
  assert_eq "$(_rb_row WG-1-clean | jq -r .state)" collected
  rm -rf "$T"
}

test_bind_dry_run_reports_and_records_nothing() {
  _rb_setup
  local -a a; mapfile -t a < <(_rb_bind_args); _rb "${a[@]}" --dry-run
  assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_contains "$OUT" "125 dirty entries"
  assert_eq "$(_rb_sum)" "$LEDGER_SUM"; assert_eq "$(_rb_old_sum)" "$OLD_SUM"; assert_eq "$(_rb_inbox)" 0
  rm -rf "$T"
}

test_bind_replay_is_a_noop_and_a_different_binding_is_refused() {
  _rb_setup
  _rb_bind; assert_eq "$RC" 0 || return 1
  local sum; sum="$(_rb_sum)"
  _rb_bind; assert_eq "$RC" 0; assert_contains "$OUT" "already bound"
  assert_eq "$(_rb_sum)" "$sum"
  _rb_git worktree add -q -b WG-1-clean2 "$T/wtc2" main
  _rb_bind "$T/wtc2"; assert_eq "$RC" 1; assert_contains "$OUT" "already bound"
  assert_eq "$(_rb_sum)" "$sum"
  rm -rf "$T"
}

test_bind_refuses_every_stale_or_mismatched_identity_with_no_mutation() {
  _rb_setup
  _rb_bind "$T/wtc" "$TH" other-alias;           _rb_refused "worker alias" || return 1
  _rb_bind "$T/wtc" "$TH" widget-WG-1 p9;        _rb_refused "pane of" || return 1
  _rb_bind "$T/wtc" "$TH" widget-WG-1 p1 "$T";   _rb_refused "checkout of" || return 1
  _rb_bind "$T/wtc" "$OLDHEAD";                  _rb_refused "not the head reserved" || return 1
  _rb_bind "$T/nope";                            _rb_refused "does not exist" || return 1
  _rb_bind "$T/wt";                              _rb_refused "is the old checkout" || return 1
  _rb replace bind WG-9 --from-worktree "$T/wt" --worktree "$T/wtc" --head "$TH" --alias widget-WG-1 --pane p1
  _rb_refused "no delegation" || return 1
  _rb replace bind WG-1 --from-worktree "$T/wt" --worktree "$T/wtc" --head "$TH" --alias widget-WG-1 --pane p1
  _rb_refused "not a replacement child" || return 1
  _rb replace bind WG-1-clean --worktree "$T/wtc" --head "$TH" --alias widget-WG-1 --pane p1
  _rb_refused "are all required" || return 1
  rm -rf "$T"
}

test_bind_refuses_a_clean_checkout_that_is_not_exactly_the_reserved_candidate() {
  _rb_setup
  # another worktree of the same repo on the wrong branch
  _rb_git worktree add -q -b other "$T/wto" main
  _rb_bind "$T/wto"; _rb_refused "not refs/heads/WG-1-clean" || return 1
  # a detached HEAD at the right commit is not the branch
  git -C "$T/wtc" checkout -q --detach; _rb_bind; _rb_refused "detached HEAD" || return 1
  git -C "$T/wtc" checkout -q WG-1-clean
  # an extra commit: the head is no longer the reserved one
  printf 'more\n' > "$T/wtc/more.txt"; git -C "$T/wtc" add more.txt; git -C "$T/wtc" commit -q -m more
  _rb_bind; _rb_refused "not the reserved head" || return 1
  git -C "$T/wtc" reset -q --hard "$TH"
  # a dirty clean tree, tracked or untracked
  printf 'u\n' > "$T/wtc/untracked.txt"; _rb_bind; _rb_refused "uncommitted entries" || return 1
  rm "$T/wtc/untracked.txt"; printf 'm\n' >> "$T/wtc/clean.txt"; _rb_bind; _rb_refused "uncommitted entries" || return 1
  git -C "$T/wtc" checkout -q -- clean.txt
  # a subdirectory is not a checkout root
  mkdir -p "$T/wtc/sub"; _rb_bind "$T/wtc/sub"; _rb_refused "not the root" || return 1
  # a checkout inside the old tree
  _rb_bind "$T/wt/media"; _rb_refused "inside the old one" || return 1
  # an unrelated repository is not "a clean checkout" however clean it is
  git init -q -b main "$T/stranger"; git -C "$T/stranger" commit -q --allow-empty -m s
  git -C "$T/stranger" checkout -q -b WG-1-clean
  _rb_bind "$T/stranger"; _rb_refused "same repository" || return 1
  # a checkout another live delegation owns is ambiguous
  jq --arg c "$(realpath "$T/wtc")" '. + [{id:"WG-2",repo:"widget",branch:"WG-2",alias:"widget-WG-2",pane:"p2",worktree:$c,state:"running",shape:"ship"}]' \
    "$T/.cel/delegations.json" > "$T/n" && mv "$T/n" "$T/.cel/delegations.json"
  LEDGER_SUM="$(_rb_sum)"
  _rb_bind; _rb_refused "ambiguous ownership" || return 1
  rm -rf "$T"
}

test_bind_refuses_an_unproven_or_wrong_actor() {
  _rb_setup
  _rb_agents widget-WG-1 wC:p1 "" "$T/wt";             _rb_bind; _rb_refused "no native session identity" || return 1
  _rb_agents widget-WG-1 wC:p1 "$OLDSESS" "$T";        _rb_bind; _rb_refused "not the old checkout" || return 1
  _rb_agents widget-WG-1 wC:p1 "$OLDSESS" "$T/wtc";    _rb_bind; _rb_refused "already executes in the clean checkout" || return 1
  _rb_agents widget-WG-1 wC:p7 "$OLDSESS" "$T/wt";     _rb_bind; _rb_refused "holds 0 agents" || return 1
  _rb_agents someone-else wC:p1 "$OLDSESS" "$T/wt";    _rb_bind; _rb_refused "agents named" || return 1
  echo '{"result":{"agents":[]}}' > "$T/agents.json";  _rb_bind; _rb_refused "agents named" || return 1
  jq '.result.agents += [.result.agents[0]]' "$T/agents.json" > "$T/n" && mv "$T/n" "$T/agents.json"
  _rb_bind; _rb_refused "agents named" || return 1
  rm -rf "$T"
}

test_bind_refuses_unattached_unfinished_and_indebted_rows() {
  _rb_setup
  local f
  for f in '(.[1].replacement.stage)="reserved"' '(.[1].state)="landed"' '(.[1].state)="abandoned"' '(.[1].launch)={phase:"start-failed"}' \
           '(.[0].replacement.child)="someone-else"' '(.[0].launch)={phase:"started"}'; do
    _rb_setup
    jq "$f" "$T/.cel/delegations.json" > "$T/n" && mv "$T/n" "$T/.cel/delegations.json"
    LEDGER_SUM="$(_rb_sum)"
    _rb_bind
    [ "$RC" -ne 0 ] || { echo "bound despite: $f"; return 1; }
    assert_eq "$(_rb_sum)" "$LEDGER_SUM" || { echo "$f"; return 1; }
    assert_eq "$(_rb_old_sum)" "$OLD_SUM" || return 1
    assert_eq "$(_rb_inbox)" 0 || return 1
    rm -rf "$T"
  done
}

test_bind_rejects_a_concurrent_writer_and_two_binds_yield_one() {
  _rb_setup
  # a writer holds the ledger lock: bind refuses instead of queueing behind it
  ( exec 9>"$T/.cel/delegations.lock"; flock 9; sleep 5 ) &
  local holder=$!; sleep 0.5
  _rb_bind; _rb_refused "lock is held" || { kill "$holder" 2>/dev/null; return 1; }
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  # two identical binds racing: never two bindings, never a doubled history
  local -a a
  mapfile -t a < <(_rb_bind_args)
  ( cd "$T" && "$BIN" "${a[@]}" >"$T/o1" 2>&1; echo $? >"$T/r1" ) &
  local p1=$!
  ( cd "$T" && "$BIN" "${a[@]}" >"$T/o2" 2>&1; echo $? >"$T/r2" ) &
  local p2=$!
  wait "$p1" "$p2" || true
  [ "$(cat "$T/r1")" = 0 ] || [ "$(cat "$T/r2")" = 0 ] || { cat "$T/o1" "$T/o2"; return 1; }
  assert_eq "$(jq '[.[] | select(.binding != null)] | length' "$T/.cel/delegations.json")" 1
  assert_eq "$(jq '[.[] | select(.id == "WG-1-clean") | .history[] | select(.event == "checkout-bound")] | length' "$T/.cel/delegations.json")" 1
  assert_eq "$(_rb_old_sum)" "$OLD_SUM"
  rm -rf "$T"
}

test_bind_state_that_changes_during_the_check_yields_zero_partial_mutation() {
  local case_
  for case_ in ledger actor clean old; do
    _rb_setup
    case "$case_" in
      ledger) export CEL_BIND_TEST_BEFORE_COMMIT="jq '(.[1].review.note)=\"changed\"' '$T/.cel/delegations.json' > '$T/n' && mv '$T/n' '$T/.cel/delegations.json'" ;;
      actor)  export CEL_BIND_TEST_BEFORE_COMMIT="sed -i s#native-1#native-2# '$T/agents.json'" ;;
      clean)  export CEL_BIND_TEST_BEFORE_COMMIT="printf u > '$T/wtc/late.txt'" ;;
      old)    export CEL_BIND_TEST_BEFORE_COMMIT="git -C '$T/wt' checkout -q -b late-branch" ;;
    esac
    local pre; pre="$(_rb_sum)"
    _rb_bind
    unset CEL_BIND_TEST_BEFORE_COMMIT
    [ "$RC" -ne 0 ] || { echo "$case_: bound despite a change"; return 1; }
    assert_contains "$OUT" "while it was being checked" || { echo "$case_: $OUT"; return 1; }
    assert_eq "$(jq '[.[] | select(.binding != null)] | length' "$T/.cel/delegations.json")" 0 || return 1
    [ "$case_" = ledger ] || assert_eq "$(_rb_sum)" "$pre" || return 1
    assert_eq "$(_rb_inbox)" 0 || return 1
    assert_eq "$(ls "$T/.cel/bindings" 2>/dev/null | wc -l)" 0 || return 1
    rm -rf "$T"
  done
}

test_bind_a_fault_leaves_nothing_before_the_write_and_a_resumable_binding_after_it() {
  _rb_setup
  export CEL_REPLACE_FAULT=before-bind; _rb_bind; unset CEL_REPLACE_FAULT
  _rb_refused "injected fault at before-bind" || return 1
  # a lost response after the single write: the binding is durable, a replay completes
  export CEL_REPLACE_FAULT=after-bind; _rb_bind; unset CEL_REPLACE_FAULT
  assert_eq "$RC" 1; assert_contains "$OUT" "injected fault at after-bind"
  assert_eq "$(_rb_row WG-1-clean | jq -r .binding.worktree)" "$(realpath "$T/wtc")"
  assert_eq "$(_rb_old_sum)" "$OLD_SUM"
  _rb_bind; assert_eq "$RC" 0; assert_contains "$OUT" "already bound"
  assert_eq "$(jq '[.[] | select(.binding != null)] | length' "$T/.cel/delegations.json")" 1
  # the pre-image is kept for recovery and is the unbound row
  assert_eq "$(jq -r '.worktree' "$T/.cel/bindings"/WG-1-clean-*.pre.json)" "$T/wt"
  rm -rf "$T"
}

test_bound_row_refuses_a_substituted_actor_and_a_moved_checkout_but_accepts_a_finished_actor() {
  _rb_setup
  _rb_bind; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  mkdir -p "$T/wtc/.agent"; printf 'h\n' > "$T/wtc/.agent/result.md"
  # the same name, a different native session: a restarted agent inherits nothing
  _rb_agents widget-WG-1 wC:p1 "/sessions/native-2.jsonl" "$T/wt"
  local sum; sum="$(_rb_sum)"
  _rb collect WG-1-clean; assert_eq "$RC" 1; assert_contains "$OUT" "not the actor"
  _rb land WG-1-clean;    assert_eq "$RC" 1; assert_contains "$OUT" "not the actor"
  assert_eq "$(_rb_sum)" "$sum"; assert_eq "$(cat "$T/verify.log")" ""
  # the checkout switched branch under the binding
  _rb_agents widget-WG-1 wC:p1 "$OLDSESS" "$T/wt"
  git -C "$T/wtc" checkout -q -b elsewhere
  _rb collect WG-1-clean; assert_eq "$RC" 1; assert_contains "$OUT" "no longer on refs/heads/WG-1-clean"
  git -C "$T/wtc" checkout -q WG-1-clean
  # the actor finished and left: the binding stands and collect proceeds on the clean tree
  echo '{"result":{"agents":[]}}' > "$T/agents.json"
  _rb collect WG-1-clean; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  assert_eq "$(cat "$T/verify.log")" "$(realpath "$T/wtc")"
  assert_eq "$(_rb_old_sum)" "$OLD_SUM"
  rm -rf "$T"
}

test_bind_old_checkout_stays_vetoed_for_gc_and_the_clean_one_follows_the_row() {
  _rb_setup
  source "$CEL_ROOT/lib/gc.sh"
  export CEL_REGISTRY="$T/registry.yaml"
  registry_add demo "$T" "" >/dev/null 2>&1 || true
  _rb_bind; assert_eq "$RC" 0 || { echo "$OUT"; return 1; }
  _gc_delegated_live "$T/wtc" || { echo "bound clean checkout not vetoed while running"; return 1; }
  # even once everything is finished the retained dirty tree is never removable
  jq 'map(.state = "landed")' "$T/.cel/delegations.json" > "$T/n" && mv "$T/n" "$T/.cel/delegations.json"
  _gc_delegated_live "$T/wt" || { echo "retained old checkout lost its veto"; return 1; }
  if _gc_delegated_live "$T/wtc"; then echo "landed clean checkout still vetoes"; return 1; fi
  rm -rf "$T"
}
