# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/guard.sh"
HOOK="$CEL_ROOT/tools/hooks/orchestrator-guard.sh"

# Read-only orchestrators. The agents that decide are not the agents that can
# change; a bad prompt produces a refusal, not an incident.

_gws() { # a workspace dir with one repo, returned in $T
  T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget/src" "$T/.cel"
}

# --- who am I --------------------------------------------------------------
test_role_worker_from_worktree_path() {
  assert_eq "$(CEL_WORKTREES=/tmp/wt guard_role_of /tmp/wt/repo/WG-1-x)" worker
}
test_role_orchestrator_from_repo_checkout() {
  _gws; assert_eq "$(guard_role_of "$T/repos/widget")" orchestrator
  assert_eq "$(guard_role_of "$T/repos/widget/src")" orchestrator; rm -rf "$T"
}
test_role_root_from_workspace_dir() {
  _gws; assert_eq "$(guard_role_of "$T")" root
  assert_eq "$(guard_role_of "$T/.cel")" root; rm -rf "$T"
}
test_role_other_outside_any_workspace() {
  assert_eq "$(guard_role_of /tmp)" other
}

# --- what may an orchestrator do -------------------------------------------
test_orchestrator_may_read() {
  assert_eq "$(guard_classify orchestrator 'git log --oneline -5')" allow
  assert_eq "$(guard_classify orchestrator 'git diff origin/main..HEAD --stat')" allow
  assert_eq "$(guard_classify orchestrator 'gh pr view 12 --json state')" allow
  assert_eq "$(guard_classify orchestrator 'gh pr list --author @me')" allow
  assert_eq "$(guard_classify orchestrator 'cat repos/widget/README.md')" allow
  assert_eq "$(guard_classify orchestrator 'git fetch origin && git pull --ff-only')" allow
}
test_orchestrator_may_use_the_mechanism() {
  assert_eq "$(guard_classify orchestrator 'cel-fanout delegate widget WG-1-x spec.md')" allow
  assert_eq "$(guard_classify orchestrator 'cel-fanout land WG-1-x')" allow
  assert_eq "$(guard_classify orchestrator 'cel-fanout release WG-1-x --discard')" allow
  assert_eq "$(guard_classify orchestrator 'cel-linear state WG-1 "In Progress"')" allow
  assert_eq "$(guard_classify orchestrator 'cel inbox send root "status"')" allow
  assert_eq "$(guard_classify orchestrator 'cd /x && cel-fanout status')" allow
}
test_orchestrator_may_comment_and_review() {
  assert_eq "$(guard_classify orchestrator 'gh pr comment 12 --body "looks right"')" allow
  assert_eq "$(guard_classify orchestrator 'gh pr review 12 --approve')" allow
}
test_orchestrator_may_write_its_own_notes() {
  assert_eq "$(guard_classify orchestrator 'cat > .cel/spec-WG-1.md <<EOF')" allow
  assert_eq "$(guard_classify orchestrator 'printf x > /tmp/ws/.cel/notes.md')" allow
  _gws; assert_eq "$(guard_classify_path orchestrator "$T/.cel/spec.md")" allow; rm -rf "$T"
}

# An orchestrator owns the STATE of its own checkout, never its authorship.
# Before this, `gh pr checkout 1393` was allowed by omission and `git checkout
# main` was denied: an orchestrator could move onto a PR branch to run it
# locally and could not move back, so its checkout drifted off main with
# nobody else standing over it. Moving between refs that already exist creates
# and discards nothing - the incidents the guard was written for are all
# authorship.
test_orchestrator_may_move_its_own_checkout() {
  local c
  for c in 'git checkout main' 'git switch main' 'git checkout origin/W-49-slug' \
           'gh pr checkout 1393' 'git branch -d W-49-slug' \
           'gh pr edit 12 --add-label builder-preview' 'gh pr edit 12 --remove-label x'; do
    assert_eq "$(guard_classify orchestrator "$c")" allow
  done
}
# Creating a branch, discarding a file, or reaching into someone else's
# checkout is not state - it is authorship, or it is another agent's business.
test_orchestrator_may_not_author_via_checkout() {
  local c
  for c in 'git checkout -b new' 'git switch -c new' 'git checkout -- apps/foo.ts' \
           'git checkout .' 'git restore x' 'git checkout main -- file' \
           'git -C ~/ws/vhs/repos/widget checkout main' \
           'git -C ~/.herdr/worktrees/widget/w-49 checkout main' \
           'git branch -D old' 'git branch -m a b' \
           'gh pr edit 12 --title x' 'gh pr edit 12 --add-label x --body y' \
           'gh pr ready 12' 'gh pr merge 12'; do
    assert_contains "$(guard_classify orchestrator "$c")" deny
  done
}
# The same table from the other two standpoints is untouched: a worker writes,
# and root's own config repo is not a product checkout.
test_checkout_table_unchanged_for_root_and_worker() {
  local c
  for c in 'git checkout main' 'git checkout -b new' 'git branch -d W-49-slug' \
           'gh pr edit 12 --title x' 'gh pr merge 12'; do
    assert_eq "$(guard_classify worker "$c")" allow
  done
  assert_eq "$(guard_classify root 'git checkout main')" allow
  assert_eq "$(guard_classify root 'git checkout -b new')" allow
  assert_contains "$(guard_classify root 'git -C repos/widget checkout main')" deny
  assert_contains "$(guard_classify root 'gh pr merge 12')" deny
  assert_contains "$(guard_classify root 'gh pr edit 12 --add-label x')" deny
}

# --- what it may not -------------------------------------------------------
test_orchestrator_may_not_mutate_git() {
  local c
  for c in 'git commit -m x' 'git push origin main' 'git merge feature' 'git rebase main' \
           'git reset --hard' 'git checkout -b new' 'git switch -c new' 'git stash' \
           'git add -A' 'git worktree remove foo' 'git branch -D old' 'git cherry-pick abc' \
           'git restore x' 'git checkout .' \
           'cd repos/widget && git commit -am fix'; do
    assert_contains "$(guard_classify orchestrator "$c")" deny
  done
}
# `git -C <dir> <verb>` puts a path between git and the verb; a naive
# substring match on "git commit" lets it through. Found by the root test,
# but it is an orchestrator-grade hole: -C is exactly how a command reaches
# into a product checkout from anywhere.
test_orchestrator_may_not_evade_with_git_options() {
  local c
  for c in 'git -C repos/widget commit -m x' 'git -C /tmp/ws/repos/widget push' \
           'git --git-dir=repos/widget/.git commit -m x' 'git -c user.name=x -C repos/widget merge f' \
           'git -C . commit -am fix'; do
    assert_contains "$(guard_classify orchestrator "$c")" deny
  done
}
# Worktree lifecycle has a checked path (cel-fanout release/delegate); the
# raw herdr command skips the checks. Seen from root on the day: --force on a
# worktree the fail-closed release had already handled.
test_orchestrator_may_not_drive_herdr_worktrees_directly() {
  assert_contains "$(guard_classify orchestrator 'herdr worktree remove --workspace w9Z --force')" deny
  assert_contains "$(guard_classify root 'sleep 5; herdr worktree remove --workspace w9Z --force 2>&1 | jq .')" deny
  assert_contains "$(guard_classify orchestrator 'herdr worktree create --workspace w1 --branch x')" deny
  assert_eq "$(guard_classify orchestrator 'cel-fanout release WG-1 --discard')" allow
  assert_eq "$(guard_classify orchestrator 'herdr workspace list')" allow
  assert_eq "$(guard_classify orchestrator 'herdr agent list')" allow
}
test_orchestrator_may_not_change_github_state() {
  local c
  for c in 'gh pr merge 12 --squash' 'gh pr close 12' 'gh pr ready 12' 'gh pr create --fill' \
           'gh pr edit 12 --title x' 'gh api -X POST repos/o/r/pulls/1/merge' 'gh api repos/o/r --method PATCH'; do
    assert_contains "$(guard_classify orchestrator "$c")" deny
  done
}
test_orchestrator_may_not_edit_repo_files_by_shell() {
  local c
  for c in 'sed -i s/a/b/ repos/widget/x.ts' 'echo x > repos/widget/x.ts' 'echo x >> /tmp/ws/repos/widget/x.ts' \
           'rm repos/widget/x.ts' 'mv repos/widget/a repos/widget/b' 'tee repos/widget/x.ts'; do
    assert_contains "$(guard_classify orchestrator "$c")" deny
  done
}
test_orchestrator_may_not_edit_repo_files_by_tool() {
  _gws
  assert_contains "$(guard_classify_path orchestrator "$T/repos/widget/src/x.ts")" deny
  assert_contains "$(guard_classify_path root "$T/repos/widget/README.md")" deny
  rm -rf "$T"
}
# Root's cwd is the WORKSPACE repo - config, not product - which root and the
# owner's assistant legitimately commit to. Product checkouts stay off-limits.
test_root_may_commit_workspace_config_but_not_products() {
  assert_eq "$(guard_classify root 'git add workspace.yaml && git commit -m tune')" allow
  assert_eq "$(guard_classify root 'git push')" allow
  assert_contains "$(guard_classify root 'cd repos/widget && git commit -m x')" deny
  assert_contains "$(guard_classify root 'git -C repos/widget push')" deny
  assert_contains "$(guard_classify root 'git -C /home/x/.herdr/worktrees/w/b commit -m x')" deny
  assert_contains "$(guard_classify root 'gh pr merge 3')" deny
  assert_eq "$(guard_classify root 'cel run orchestrator --repo widget')" allow
}
test_hook_opt_out_per_pane() {
  _gws
  CEL_GUARD=0 _hook "$T/repos/widget" Bash '{"command":"git commit -m x"}' || { echo "CEL_GUARD=0 ignored"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_workers_are_unrestricted() {
  assert_eq "$(guard_classify worker 'git commit -m x')" allow
  assert_eq "$(guard_classify worker 'git push -u origin WG-1')" allow
  assert_eq "$(guard_classify worker 'gh pr create --fill')" allow
  assert_eq "$(guard_classify_path worker /any/repos/x.ts)" allow
}

# --- the hook end to end ---------------------------------------------------
_hook() { # <cwd> <tool> <input-json> -> exit code, stderr in $HOOK_ERR
  local out
  out="$(printf '{"tool_name":"%s","cwd":"%s","tool_input":%s}' "$2" "$1" "$3" \
        | bash "$HOOK" 2>&1 >/dev/null)"; local rc=$?
  HOOK_ERR="$out"; return $rc
}
test_hook_blocks_an_orchestrator_commit_with_a_reason() {
  _gws
  _hook "$T/repos/widget" Bash '{"command":"git commit -m x"}' && { echo "hook allowed a commit"; rm -rf "$T"; return 1; }
  assert_contains "$HOOK_ERR" "celestial guard (orchestrator pane)"
  assert_contains "$HOOK_ERR" "cel-fanout delegate"
  rm -rf "$T"
}
test_hook_blocks_an_orchestrator_edit_tool_under_repos() {
  _gws
  _hook "$T/repos/widget" Edit "{\"file_path\":\"$T/repos/widget/src/x.ts\",\"old_string\":\"a\",\"new_string\":\"b\"}" \
    && { echo "hook allowed an Edit under repos/"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_hook_allows_an_orchestrator_spec_write() {
  _gws
  _hook "$T/repos/widget" Write "{\"file_path\":\"$T/.cel/spec.md\",\"content\":\"x\"}" || { echo "hook blocked a spec write: $HOOK_ERR"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_hook_lets_a_worker_through() {
  _hook "${CEL_WORKTREES:-$HOME/.herdr/worktrees}/repo/WG-1" Bash '{"command":"git push"}' || { echo "hook blocked a worker: $HOOK_ERR"; return 1; }
}
test_hook_honours_the_one_off_override() {
  _gws
  _hook "$T/repos/widget" Bash '{"command":"CEL_GUARD_ALLOW_ONCE=1 git commit -m x"}' || { echo "override ignored"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A guard that cannot parse its input must fail OPEN: a broken hook taking
# down every tool call on the box is worse than one incident.
test_hook_fails_open_on_garbage() {
  printf 'not json' | bash "$HOOK" >/dev/null 2>&1 || { echo "hook failed closed on garbage"; return 1; }
  printf '' | bash "$HOOK" >/dev/null 2>&1 || { echo "hook failed closed on empty input"; return 1; }
}

# --- a product orchestrator -------------------------------------------------
# A product orchestrator stands in <ws>/products/<p>, not in a repo
# checkout. It is an orchestrator by the same path derivation, which means the
# same refusals: it may write its own notes and specs, and it may not reach
# into a repo.
_gws_product() { _gws; mkdir -p "$T/products/x" "$T/repos/y"; }
test_role_orchestrator_from_product_dir() {
  _gws_product
  assert_eq "$(guard_role_of "$T/products/x")" orchestrator
  assert_eq "$(guard_role_of "$T/products/x/notes")" orchestrator; rm -rf "$T"
}
test_product_orchestrator_writes_its_own_dir_but_no_repo() {
  _gws_product
  assert_contains "$(guard_classify orchestrator 'git commit -m x')" deny
  assert_eq "$(guard_classify_path orchestrator "$T/products/x/spec.md")" allow
  assert_contains "$(guard_classify_path orchestrator "$T/repos/y/a.ts")" deny
  rm -rf "$T"
}

# --- the console -----------------------------------------------------------
# The console's vocabulary is an ALLOWLIST: its job is narrow, so everything
# outside it is a mistake rather than a judgement call.
_cons() { CONS="$(mktemp -d)/console"; mkdir -p "$CONS"; }

test_role_console_from_the_console_dir() {
  _cons
  assert_eq "$(CEL_CONSOLE_DIR="$CONS" guard_role_of "$CONS")" console
  assert_eq "$(CEL_CONSOLE_DIR="$CONS" guard_role_of "$CONS/notes")" console
  rm -rf "$CONS"
}
# The console's cwd is a plain directory a human could also stand in, so the
# environment can say so outright.
test_role_console_from_the_environment() {
  assert_eq "$(CEL_ROLE=console guard_role_of /tmp)" console
}
test_console_may_route() {
  assert_eq "$(guard_classify console 'cel fleet --json')" allow
  assert_eq "$(guard_classify console 'cel inbox send x "y" --workspace w')" allow
  assert_eq "$(guard_classify console 'cel-fanout status --workspace w')" allow
  assert_eq "$(guard_classify console 'gh pr view 3')" allow
  assert_eq "$(guard_classify console 'herdr agent focus a')" allow
  assert_eq "$(guard_classify console 'git log --oneline')" allow
  assert_eq "$(guard_classify console 'jq -r .x /tmp/a.json')" allow
}
test_console_may_not_build() {
  local c
  for c in 'git commit -m x' 'gh pr merge 3' 'herdr worktree remove --force' \
           'npm install' 'sed -i s/a/b/ x.ts' 'git -C repos/x status'; do
    assert_contains "$(guard_classify console "$c")" "deny the console routes; it does not build -"
  done
}
test_console_writes_only_its_own_directory() {
  _cons; _gws
  assert_eq "$(CEL_CONSOLE_DIR="$CONS" guard_classify_path console "$CONS/notes.md")" allow
  assert_contains "$(CEL_CONSOLE_DIR="$CONS" guard_classify_path console "$T/repos/x/a.ts")" deny
  assert_contains "$(CEL_CONSOLE_DIR="$CONS" guard_classify_path console "$T/products/p/spec.md")" deny
  rm -rf "$CONS" "$T"
}
