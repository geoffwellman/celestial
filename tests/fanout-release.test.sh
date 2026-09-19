# shellcheck shell=bash
# `release --all` and the container that has to outlive its children.
#
# 2026-09-19, this box: an orchestrator ran `release --all` to free memory and
# it took twelve rows in `finished` and `collected` - work awaiting collection
# or review, with open PRs. For one row it printed "left as-is: no merged PR
# (release is not a merge)" and removed the worktree anyway, and when the last
# child went herdr dropped the `<repo>/workers` container, scattering the
# surviving workers to the sidebar's top level. Three faults, one verb; these
# are the tests for all three.
source "$CEL_ROOT/lib/common.sh"
BIN="$CEL_ROOT/core/skills/fanout/bin/cel-fanout"

_relt_setup() {
  T="$(mktemp -d)"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget"
  git -C "$T/repos/widget" init -q
  STUB_WT="$T/widget-worker"
  mkdir -p "$STUB_WT"
  git -C "$STUB_WT" init -q
  git -C "$STUB_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$STUB_WT" update-ref refs/remotes/origin/main HEAD
  git -C "$STUB_WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  STUB_REPO="$(git -C "$T/repos/widget" rev-parse --show-toplevel)"
  STUB_LOG="$T/stub.log"
  : > "$STUB_LOG"
  STUB="$T/herdr-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$STUB_LOG"
_worker='{"workspace_id":"wZ","worktree":{"repo_root":"'"$STUB_REPO"'","is_linked_worktree":true}}'
_container='{"workspace_id":"wY","worktree":{"repo_root":"'"$STUB_REPO"'","is_linked_worktree":false}}'
case "$1 $2" in
  "worktree create") echo '{"result":{"workspace_id":"wZ","pane_id":"wZ:p1","checkout_path":"'"$STUB_WT"'"}}';;
  "workspace list")  if [ -n "${STUB_NO_CONTAINER:-}" ]; then echo '{"result":{"workspaces":['"$_worker"']}}';
                     else echo '{"result":{"workspaces":['"$_container","$_worker"']}}'; fi;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wC","label":"widget/workers"}}}';;
  "agent list")      echo '{"result":{"agents":[]}}';;
  *) echo '{}';;
esac
EOF
  chmod +x "$STUB"
  export CEL_FANOUT_HERDR="$STUB"
  export STUB_LOG STUB_WT STUB_REPO
  printf 'do the thing\n' > "$T/spec.md"
}

# One row of every state the ledger uses, so the scope of `--all` is a fact
# about states rather than about whichever rows happen to exist.
_relt_one_of_each() {
  _relt_setup
  local t
  for t in WG-LANDED WG-ABANDONED WG-RUNNING WG-FINISHED WG-COLLECTED WG-REPORTED; do
    (cd "$T" && "$BIN" delegate widget "$t" "$T/spec.md" >/dev/null)
  done
  jq '(.[] | select(.id=="WG-LANDED")    | .state) = "landed"
    | (.[] | select(.id=="WG-ABANDONED") | .state) = "abandoned"
    | (.[] | select(.id=="WG-FINISHED")  | .state) = "finished"
    | (.[] | select(.id=="WG-COLLECTED") | .state) = "collected"
    | (.[] | select(.id=="WG-REPORTED")  | .state) = "reported"' \
    "$T/.cel/delegations.json" > "$T/l.json" && mv "$T/l.json" "$T/.cel/delegations.json"
}

_relt_state() { jq -r --arg id "$1" '.[] | select(.id == $id) | .state' "$T/.cel/delegations.json"; }

# THE SCOPE. "Release the landed rows" is what the operator means; `finished`,
# `collected`, `reported` and `running` are somebody's open work and a bulk
# verb must never take them.
test_release_all_takes_only_landed_and_abandoned() {
  _relt_one_of_each
  local out; out="$(cd "$T" && "$BIN" release --all 2>&1)"
  assert_eq "$(_relt_state WG-LANDED)" released
  assert_eq "$(_relt_state WG-ABANDONED)" released
  assert_eq "$(_relt_state WG-RUNNING)" running
  assert_eq "$(_relt_state WG-FINISHED)" finished
  assert_eq "$(_relt_state WG-COLLECTED)" collected
  assert_eq "$(_relt_state WG-REPORTED)" reported
  assert_contains "$out" "release --all: 2 rows"
  rm -rf "$T"
}

# THE PLAN GOES FIRST. The operator who lost twelve rows had no way to see what
# the verb was about to do until it had done it.
test_release_all_prints_its_plan_naming_every_skipped_row() {
  _relt_one_of_each
  local out; out="$(cd "$T" && "$BIN" release --all --dry-run 2>&1)"
  assert_contains "$out" "WG-LANDED landed"
  assert_contains "$out" "WG-ABANDONED abandoned"
  assert_contains "$out" "skipping 4"
  local s
  for s in "WG-RUNNING running" "WG-FINISHED finished" "WG-COLLECTED collected" "WG-REPORTED reported"; do
    assert_contains "$out" "$s"
  done
  rm -rf "$T"
}

# --dry-run stops at the plan: nothing removed, no state moved.
test_release_all_dry_run_removes_nothing() {
  _relt_one_of_each
  (cd "$T" && "$BIN" release --all --dry-run) > /dev/null
  assert_eq "$(_relt_state WG-LANDED)" landed
  assert_eq "$(_relt_state WG-ABANDONED)" abandoned
  ! grep -q "^worktree remove" "$STUB_LOG" || { echo "dry-run removed a worktree"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# --merged (CEL-24) ADDS rows GitHub has already merged to the same one pass -
# it does not replace the scope with "whatever state these are in".
test_release_all_merged_adds_the_merged_pr_row() {
  _relt_one_of_each
  local gh="$T/gh-stub.sh"
  cat > "$gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") echo '[{"number":7,"headRefName":"WG-COLLECTED","state":"MERGED","mergedAt":"2026-09-19T00:00:00Z","closedAt":null}]';;
  *) echo '[]';;
esac
EOF
  chmod +x "$gh"; export CEL_FANOUT_GH="$gh"
  local out; out="$(cd "$T" && "$BIN" release --all --merged 2>&1)"
  assert_eq "$(_relt_state WG-COLLECTED)" released
  assert_eq "$(_relt_state WG-LANDED)" released
  assert_eq "$(_relt_state WG-FINISHED)" finished
  assert_contains "$out" "3 rows"
  rm -rf "$T"
}

# A "left as-is" LINE IS A PROMISE. The path that prints it must return before
# anything is removed - printing it and then removing the worktree is how one
# row's work had to be rebuilt by hand.
test_release_left_as_is_never_removes_a_worktree() {
  _relt_setup
  yq -y -i '.tickets.system = "linear"' "$T/workspace.yaml"
  (cd "$T" && "$BIN" delegate widget WG-TICKET "$T/spec.md" >/dev/null)
  jq '(.[0].ticket) = "WG-77" | (.[0].state) = "collected"' \
    "$T/.cel/delegations.json" > "$T/l.json" && mv "$T/l.json" "$T/.cel/delegations.json"
  local gh="$T/gh-stub.sh"
  printf '#!/usr/bin/env bash\necho ""\n' > "$gh"; chmod +x "$gh"
  export CEL_FANOUT_GH="$gh"
  : > "$STUB_LOG"
  local out; out="$(cd "$T" && "$BIN" release WG-TICKET 2>&1)"
  assert_contains "$out" "left as-is"
  ! grep -q "^worktree remove" "$STUB_LOG" || { echo "left as-is removed the worktree"; rm -rf "$T"; return 1; }
  assert_eq "$(_relt_state WG-TICKET)" collected
  rm -rf "$T"
}

# THE CONTAINER OUTLIVES ITS CHILDREN. herdr closes an empty container when the
# last child goes; the sidebar then has no home for the next worker and the
# survivors appear at top level. release puts it back immediately.
test_release_of_the_last_child_recreates_a_closed_container() {
  _relt_setup
  (cd "$T" && "$BIN" delegate widget WG-LAST "$T/spec.md" >/dev/null)
  : > "$STUB_LOG"
  (cd "$T" && STUB_NO_CONTAINER=1 "$BIN" release WG-LAST) > /dev/null
  assert_contains "$(cat "$STUB_LOG")" "workspace create --cwd $T/repos/widget --label widget/workers --no-focus"
  rm -rf "$T"
}

# ...and when it survived the removal, nothing is created: a second container
# for the same repo is the same scattering by another route.
test_release_leaves_a_living_container_alone() {
  _relt_setup
  (cd "$T" && "$BIN" delegate widget WG-KEEP "$T/spec.md" >/dev/null)
  : > "$STUB_LOG"
  (cd "$T" && "$BIN" release WG-KEEP) > /dev/null
  ! grep -q "^workspace create" "$STUB_LOG" || { echo "created a second container"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The next delegate nests under the container that release put back.
test_delegate_after_a_release_nests_under_the_container() {
  _relt_setup
  (cd "$T" && "$BIN" delegate widget WG-ONE "$T/spec.md" >/dev/null)
  (cd "$T" && "$BIN" release WG-ONE) > /dev/null
  : > "$STUB_LOG"
  (cd "$T" && "$BIN" delegate widget WG-TWO "$T/spec.md" >/dev/null)
  assert_contains "$(grep '^worktree create' "$STUB_LOG" | head -1)" "--workspace wY"
  rm -rf "$T"
}

# A linked worktree whose parent container is gone is DETACHED. herdr 0.9 has
# no re-parent verb, so the operator is told rather than fixed for.
test_status_shows_detached_when_the_container_is_gone() {
  _relt_setup
  (cd "$T" && "$BIN" delegate widget WG-DET "$T/spec.md" >/dev/null)
  local out; out="$(cd "$T" && STUB_NO_CONTAINER=1 "$BIN" status)"
  assert_contains "$out" "detached"
  out="$(cd "$T" && "$BIN" status)"
  case "$out" in *detached*) echo "detached with the container present"; rm -rf "$T"; return 1;; esac
  rm -rf "$T"
}

# doctor says it too: worker worktrees on the roster and no container to hold
# them is exactly the state nobody noticed for a day.
test_doctor_warns_when_the_worker_container_is_missing() {
  _relt_setup
  (cd "$T" && "$BIN" delegate widget WG-DOC "$T/spec.md" >/dev/null)
  source "$CEL_ROOT/lib/doctor.sh"
  local out; out="$(STUB_NO_CONTAINER=1 doctor_worker_containers "$T" 2>&1)"
  assert_contains "$out" "no widget/workers container"
  out="$(doctor_worker_containers "$T" 2>&1)"
  case "$out" in *"no widget/workers container"*) echo "warned with the container present"; rm -rf "$T"; return 1;; esac
  rm -rf "$T"
}
