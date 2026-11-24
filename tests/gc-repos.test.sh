# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/registry.sh"
source "$CEL_ROOT/lib/gc.sh"

# EVERY REGISTERED REPO, BY ITS CLONE'S REAL PATH, AND EVERY WORKTREE GIT
# RECORDS FOR IT, WHEREVER IT LIVES. The workspace's repos/widget is a symlink
# to a clone outside the workspace, and its worktrees sit beside that clone,
# under an owner tool's workspaces dir, in a fresh /tmp dir, and one is a
# follow-main local-* tree. A seventh record's directory is gone. Real
# linked worktrees and real /proc (this test's own session); only the forge,
# herdr and the destructive `git worktree remove` are stubbed.
_gr_fixture() {
  T="$(mktemp -d)"
  export HOME="$T/home" CEL_REGISTRY="$T/registry.yaml" CEL_GC_KEPT_STATE="$T/gc-kept.json" \
    CEL_REVIEW_DIR="$T/reviews" CEL_REVIEWERS_STATE="$T/reviewers.json" CEL_REX_STATE="$T/rex" \
    CEL_GC_REVIEW_CHECKOUT_STATE="$T/rc-state.json" XDG_STATE_HOME="$T/state"
  GR_WS="$T/workspace" GR_CLONE="$T/code/widget" GR_SIB="$T/code/widget-wt"
  GR_OWNER="$HOME/orca/workspaces/widget/Widget" GR_FM="$GR_SIB/local-0123456789ab"
  GR_TMPD="$(mktemp -d -p /tmp gc-repos.XXXXXX)"; GR_TMP="$GR_TMPD/widget-scratch"
  mkdir -p "$GR_WS/repos" "$GR_CLONE" "$GR_SIB" "$(dirname "$GR_OWNER")"
  git -C "$GR_CLONE" init -q
  git -C "$GR_CLONE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$GR_CLONE" update-ref refs/remotes/origin/main HEAD
  git -C "$GR_CLONE" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf 'name: demo\nrepos:\n  - name: widget\n    url: git@github.com:someone/widget.git\n' > "$GR_WS/workspace.yaml"
  ln -s "$GR_CLONE" "$GR_WS/repos/widget"
  registry_add demo "$GR_WS" ""
  git -C "$GR_CLONE" worktree add -q -b merged "$GR_SIB/merged"
  git -C "$GR_CLONE" worktree add -q -b open "$GR_SIB/open"
  git -C "$GR_CLONE" worktree add -q -b owned "$GR_OWNER"
  git -C "$GR_CLONE" worktree add -q --detach "$GR_FM"
  git -C "$GR_CLONE" worktree add -q -b scratch "$GR_TMP"
  git -C "$GR_CLONE" worktree add -q -b gone "$GR_SIB/gone"
  rm -rf "$GR_SIB/gone"
  GR_SINK="$T/sink"; : > "$GR_SINK"; GR_GH="$T/gh.log"; : > "$GR_GH"
  GR_PANES='{"result":{"panes":[]}}' GR_AGENTS='{"result":{"agents":[]}}'
  herdr() {
    case "$1 $2" in
      "workspace list") printf '{"result":{"workspaces":[]}}';;
      "pane list") printf '%s' "$GR_PANES";;
      "agent list") printf '%s' "$GR_AGENTS";;
      *) return 1;;
    esac
  }
  # Every PR merged at its branch's exact head, except branch `open`.
  gh() {
    printf '%s token=%s\n' "$*" "${GH_TOKEN:-}" >> "$GR_GH"
    case "$1 $2" in
      "auth token") printf 'second-account-token\n';;
      "pr list")
        local b="$4" s=MERGED
        [ "$b" = open ] && s=OPEN
        jq -n --arg s "$s" --arg h "$(command git -C "$GR_CLONE" rev-parse "refs/heads/$b")" \
          '[{state:$s,headRefOid:$h,updatedAt:"2026-01-01T00:00:00Z"}]';;
      *) return 1;;
    esac
  }
  git() {
    case " $* " in *" worktree remove "*) printf 'git remove %s\n' "${!#}" >> "$GR_SINK"; return 0;; esac
    command git "$@"
  }
  pgrep() { command pgrep -s 0 "$@"; }
}
_gr_teardown() { rm -rf "$T" "$GR_TMPD"; }
_gr_listed() { command git -C "$GR_CLONE" worktree list --porcelain | grep -qxF "worktree $1"; }

test_gc_dry_run_sweeps_every_worktree_of_a_clone_outside_the_workspace() {
  _gr_fixture
  local out="$T/out"
  cmd_gc --dry-run >"$out" 2>&1 || { cat "$out"; _gr_teardown; return 1; }
  assert_eq "$(cat "$GR_SINK")" "" || { cat "$out"; _gr_teardown; return 1; }
  assert_contains "$(cat "$out")" "would remove orphan ($GR_SIB/merged" || { cat "$out"; _gr_teardown; return 1; }
  assert_contains "$(cat "$out")" "would remove orphan ($GR_TMP" || { cat "$out"; _gr_teardown; return 1; }
  assert_contains "$(cat "$out")" "kept $GR_OWNER: owner" || { cat "$out"; _gr_teardown; return 1; }
  assert_contains "$(cat "$out")" "kept $GR_FM: follow-main owned" || { cat "$out"; _gr_teardown; return 1; }
  assert_contains "$(cat "$out")" "kept $GR_SIB/open: open-pr" || { cat "$out"; _gr_teardown; return 1; }
  assert_contains "$(cat "$out")" "would prune stale entry $GR_SIB/gone" || { cat "$out"; _gr_teardown; return 1; }
  assert_contains "$(cat "$out")" \
    "gc: demo/widget ($GR_CLONE): 6 worktrees, 2 would be removed, 1 stale entry would be pruned; kept 1 owner, 1 follow-main owned, 1 open-pr" \
    || { cat "$out"; _gr_teardown; return 1; }
  # A dry run prunes nothing either.
  _gr_listed "$GR_SIB/gone" || { echo "dry run pruned"; _gr_teardown; return 1; }
  _gr_teardown
}

test_gc_removes_landed_outside_worktrees_prunes_stale_entries_and_doctor_reports_the_repo() {
  _gr_fixture
  local out="$T/out"
  cmd_gc >"$out" 2>&1 || { cat "$out"; _gr_teardown; return 1; }
  assert_eq "$(sort "$GR_SINK")" "$(printf 'git remove %s\ngit remove %s' "$GR_SIB/merged" "$GR_TMP" | sort)" \
    || { cat "$out"; _gr_teardown; return 1; }
  ! _gr_listed "$GR_SIB/gone" || { echo "stale entry not pruned"; cat "$out"; _gr_teardown; return 1; }
  for d in "$GR_OWNER" "$GR_FM" "$GR_SIB/open"; do
    [ -d "$d" ] && _gr_listed "$d" || { echo "$d touched"; _gr_teardown; return 1; }
  done
  local line="demo/widget ($GR_CLONE): 6 worktrees, 2 removed, 1 stale entry pruned; kept 1 owner, 1 follow-main owned, 1 open-pr"
  assert_contains "$(cat "$out")" "gc: $line" || { cat "$out"; _gr_teardown; return 1; }
  # cel doctor reads the last sweep's per-repo counts; it never sweeps.
  assert_contains "$(gc_doctor_repo_lines)" "$line" || { gc_doctor_repo_lines; _gr_teardown; return 1; }
  _gr_teardown
}

# NOTHING ANOTHER CHECKOUT OR AGENT CLAIMS, and the process rules hold
# wherever the tree lives: a pane in one landed tree, a second workspace whose
# repos/<r> IS another, a lock on a third, and a live process in the /tmp one.
test_gc_keeps_outside_worktrees_something_else_claims_or_runs_in() {
  _gr_fixture
  git -C "$GR_CLONE" worktree add -q -b pinned "$GR_SIB/pinned"
  git -C "$GR_CLONE" worktree add -q -b locked "$GR_SIB/locked"
  git -C "$GR_CLONE" worktree lock "$GR_SIB/locked"
  mkdir -p "$T/other/repos"
  printf 'name: other\nrepos:\n  - name: pinned\n    url: git@github.com:someone/widget.git\n' > "$T/other/workspace.yaml"
  ln -s "$GR_SIB/pinned" "$T/other/repos/pinned"
  registry_add other "$T/other" ""
  GR_PANES="$(jq -n --arg c "$GR_SIB/merged/sub" '{result:{panes:[{pane_id:"w9:p1",cwd:$c,agent_status:"idle"}]}}')"
  ( cd "$GR_TMP" && exec sleep 30 ) & local p=$!
  local out="$T/out"
  cmd_gc >"$out" 2>&1
  kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
  assert_eq "$(cat "$GR_SINK")" "" || { cat "$out"; _gr_teardown; return 1; }
  assert_contains "$(cat "$out")" "gc: demo/widget ($GR_CLONE): 8 worktrees, 0 removed, 1 stale entry pruned; kept 1 owner, 1 follow-main owned, 3 claimed, 1 live, 1 open-pr" \
    || { cat "$out"; _gr_teardown; return 1; }
  _gr_teardown
}

# PRUNE IS ALL OR NOTHING PER CLONE, so an owner's stale record keeps every
# stale record of that clone: none is pruned.
test_gc_never_prunes_a_clone_whose_stale_records_include_an_owner_one() {
  _gr_fixture
  rm -rf "$GR_OWNER"
  local out="$T/out"
  cmd_gc >"$out" 2>&1 || { cat "$out"; _gr_teardown; return 1; }
  _gr_listed "$GR_OWNER" && _gr_listed "$GR_SIB/gone" || { echo "pruned"; cat "$out"; _gr_teardown; return 1; }
  assert_contains "$(cat "$out")" "gc: demo/widget ($GR_CLONE): 6 worktrees, 2 removed; kept 1 owner, 1 follow-main owned, 1 open-pr, 1 stale" \
    || { cat "$out"; _gr_teardown; return 1; }
  _gr_teardown
}

# The clone lives outside every workspace, so the workspace a checkout is
# asked about as is the one that registers its clone: its declared account.
test_gc_asks_about_an_outside_clone_as_its_workspaces_account() {
  _gr_fixture
  printf 'github:\n  user: second\n' >> "$GR_WS/workspace.yaml"
  cmd_gc --dry-run >"$T/out" 2>&1 || { cat "$T/out"; _gr_teardown; return 1; }
  assert_contains "$(grep '^pr list --head merged ' "$GR_GH")" "token=second-account-token" \
    || { cat "$GR_GH"; _gr_teardown; return 1; }
  _gr_teardown
}
