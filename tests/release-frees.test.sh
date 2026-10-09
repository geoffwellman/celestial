# shellcheck shell=bash
# CEL-114: release must actually free the worktree.
#
# A disk-full cleanup across four workspaces found ~135 rows `released` with
# their checkouts still on disk: herdr said it "had no worktree to remove",
# the row closed anyway, and the directory stayed. Squash merges made every
# landed row look unpushed, so orchestrators fell back to --discard. And one
# `abandoned` row - a state reconcile itself writes - made gc veto every
# worktree on the box because gc's list of states did not include it.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/ledger_states.sh"
BIN="$CEL_ROOT/core/skills/fanout/bin/cel-fanout"

_rf_setup() {
  T="$(mktemp -d)"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget"
  local r="$T/repos/widget"
  git -C "$r" init -q -b main
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$r" update-ref refs/remotes/origin/main HEAD
  git -C "$r" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  STUB_WT="$T/wt/widget-worker"
  mkdir -p "$T/wt"
  git -C "$r" worktree add -q -b WG-9-x "$STUB_WT" main
  STUB_REPO="$(git -C "$r" rev-parse --show-toplevel)"
  STUB_LOG="$T/stub.log"; : > "$STUB_LOG"
  STUB="$T/herdr-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$STUB_LOG"
case "$1 $2" in
  "worktree create") echo '{"result":{"workspace_id":"wZ","pane_id":"wZ:p1","checkout_path":"'"$STUB_WT"'"}}';;
  "worktree remove") [ -n "${STUB_SLOW:-}" ] && sleep 30; exit 1;;
  "workspace list")  echo '{"result":{"workspaces":[{"workspace_id":"wY","worktree":{"repo_root":"'"$STUB_REPO"'","is_linked_worktree":false}}]}}';;
  "agent list")      echo '{"result":{"agents":[]}}';;
  *) echo '{}';;
esac
EOF
  chmod +x "$STUB"
  export CEL_FANOUT_HERDR="$STUB" STUB_LOG STUB_WT STUB_REPO
  printf 'do the thing\n' > "$T/spec.md"
  (cd "$T" && "$BIN" delegate widget WG-9-x "$T/spec.md" >/dev/null 2>&1)
}

_rf_state() { jq -r '.[0].state' "$T/.cel/delegations.json"; }

# herdr has no record of it: release removes the linked worktree itself.
test_release_removes_the_directory_when_herdr_has_none() {
  _rf_setup
  local out; out="$(cd "$T" && "$BIN" release WG-9-x 2>&1)"
  [ ! -d "$STUB_WT" ] || { echo "worktree still on disk: $out"; rm -rf "$T"; return 1; }
  assert_eq "$(_rf_state)" released
  rm -rf "$T"
}

# Tracked changes are work: without --discard the directory stays and the
# row says why rather than claiming the worktree is gone.
test_release_discard_removes_a_dirty_linked_worktree() {
  _rf_setup
  printf 'x\n' > "$STUB_WT/f.txt"
  (cd "$T" && "$BIN" release WG-9-x --discard >/dev/null 2>&1)
  [ ! -d "$STUB_WT" ] || { echo "discard left the worktree"; rm -rf "$T"; return 1; }
  assert_eq "$(_rf_state)" released
  rm -rf "$T"
}

# A worktree release cannot remove is recorded, not silently released.
test_release_records_worktree_left_when_not_linked() {
  _rf_setup
  rm -rf "$STUB_WT"; mkdir -p "$STUB_WT"; git -C "$STUB_WT" init -q
  git -C "$STUB_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m b
  git -C "$STUB_WT" update-ref refs/remotes/origin/main HEAD
  git -C "$STUB_WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  (cd "$T" && "$BIN" release WG-9-x >/dev/null 2>&1)
  assert_contains "$(jq -r '.[0].worktree_left // ""' "$T/.cel/delegations.json")" "linked"
  rm -rf "$T"
}

# Squash merge: the branch's commits are not ancestors of main, but the PR
# merged at their head - they are landed, not unpushed.
_rf_squash() {
  _rf_setup
  git -C "$STUB_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
  HEAD_OID="$(git -C "$STUB_WT" rev-parse HEAD)"
  git -C "$STUB_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "squashed"
  git -C "$STUB_REPO" update-ref refs/remotes/origin/main main
  local gh="$T/gh-stub.sh"
  cat > "$gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *headRefOid*) echo '{"state":"MERGED","headRefOid":"$HEAD_OID","mergedAt":"2026-10-09T00:00:00Z"}';;
  *) echo '';;
esac
EOF
  chmod +x "$gh"; export CEL_FANOUT_GH="$gh"
}
test_release_treats_squash_merged_commits_as_landed() {
  _rf_squash
  local out; out="$(cd "$T" && "$BIN" release WG-9-x 2>&1)" || { echo "refused: $out"; rm -rf "$T"; return 1; }
  assert_eq "$(_rf_state)" released
  rm -rf "$T"
}
test_release_counts_commits_after_the_merged_head() {
  _rf_squash
  git -C "$STUB_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m later
  local out; out="$( (cd "$T" && "$BIN" release WG-9-x) 2>&1 )" && {
    echo "released a commit made after the merge"; rm -rf "$T"; return 1; }
  assert_contains "$out" "unpushed=1"
  rm -rf "$T"
}

# A hung herdr is bounded and named.
test_release_is_time_bound_and_names_what_it_waits_on() {
  _rf_setup
  local s e out; s="$(date +%s)"
  out="$(cd "$T" && STUB_SLOW=1 CEL_RELEASE_TIMEOUT=2 "$BIN" release WG-9-x 2>&1)"
  e="$(date +%s)"
  [ $((e - s)) -lt 20 ] || { echo "release hung $((e - s))s"; rm -rf "$T"; return 1; }
  assert_contains "$out" "herdr worktree remove"
  [ ! -d "$STUB_WT" ] || { echo "worktree still on disk"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# One list of states; abandoned is in it; anything else is refused at write.
test_ledger_states_shared_list_includes_abandoned() {
  ledger_state_valid abandoned || { echo "abandoned rejected"; return 1; }
  assert_fails ledger_state_valid bogus
}
# gc: an invalid row vetoes only its own worktree, not the box.
test_gc_invalid_row_vetoes_only_its_own_worktree() {
  T="$(mktemp -d)"
  source "$CEL_ROOT/lib/gc.sh"
  mkdir -p "$T/ws/.cel" "$T/a" "$T/b"
  printf '[{"id":"X","state":"weird","worktree":"%s"},{"id":"Y","state":"landed","worktree":"%s"}]' \
    "$T/a" "$T/b" > "$T/ws/.cel/delegations.json"
  export CEL_REGISTRY="$T/registry.yaml"
  registry_add demo "$T/ws" "" >/dev/null 2>&1 || true
  _gc_delegated_live "$T/a" || { echo "invalid row's worktree not vetoed"; rm -rf "$T"; return 1; }
  if _gc_delegated_live "$T/b"; then echo "invalid row vetoed another worktree"; rm -rf "$T"; return 1; fi
  rm -rf "$T"
}

# doctor names the row.
test_doctor_names_a_row_with_an_invalid_state() {
  T="$(mktemp -d)"
  source "$CEL_ROOT/lib/doctor.sh"
  mkdir -p "$T/.cel"
  printf '[{"id":"X-1","state":"weird","worktree":"/x"}]' > "$T/.cel/delegations.json"
  local out; out="$(doctor_ledger_states "$T" demo 2>&1)" || true
  assert_contains "$out" "X-1"
  assert_contains "$out" "weird"
  rm -rf "$T"
}
