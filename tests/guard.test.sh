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
# It may move onto a PR branch to run it locally and back to main; moving
# between refs that already exist creates
# and discards nothing; the guard exists to stop authorship.
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
           'git -C ~/ws/alpha/repos/widget checkout main' \
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
# owner legitimately commit to. Product checkouts stay off-limits.
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

# --- solo: the builder, without the factory ----------------------------------
# A solo agent stands where an orchestrator stands, so only CEL_ROLE can tell
# the two apart - and it must, or the solo agent could not write a line.
test_role_solo_from_the_launch_not_the_path() {
  _gws
  assert_eq "$(CEL_ROLE=solo guard_role_of "$T/repos/widget")" solo
  assert_eq "$(guard_role_of "$T/repos/widget")" orchestrator
  rm -rf "$T"
}
test_solo_may_build_and_ship() {
  assert_eq "$(guard_classify solo 'git commit -m x')" allow
  assert_eq "$(guard_classify solo 'git push -u origin WG-1-x')" allow
  assert_eq "$(guard_classify solo 'git worktree add ../wt -b WG-2-y origin/main')" allow
  assert_eq "$(guard_classify solo 'gh pr create --fill')" allow
  assert_eq "$(guard_classify solo 'cel run reviewer --repo widget --pr 12')" allow
  assert_eq "$(guard_classify solo 'cel mode bundle fleet')" allow
  assert_eq "$(guard_classify_path solo /ws/repos/widget/src/x.ts)" allow
}
test_solo_may_not_fan_out_or_start_agents() {
  local c
  for c in 'cel-fanout delegate widget WG-1-x spec.md' 'bash /x/bin/cel-fanout scout widget b.md' \
           'cel-fanout land WG-1-x' 'cel-fanout release WG-1-x' \
           'cel run worker --repo widget --branch WG-1-x' 'cel run orchestrator --product bundle' \
           'herdr agent start foo --kind pi'; do
    case "$(guard_classify solo "$c")" in deny*) ;; *) echo "solo allowed: $c"; return 1;; esac
  done
}
test_solo_may_not_merge_by_hand() {
  local c
  for c in 'gh pr merge 12 --squash' 'gh -R a/b pr merge 5' 'gh --repo=a/b pr merge 5' \
           'gh api -X PUT repos/a/b/pulls/5/merge' 'tea pr merge 5' 'tea pulls m 5' \
           'curl -X POST http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/31/merge' \
           '/usr/bin/curl --config - http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/31/merge -d @b.json'; do
    case "$(guard_classify solo "$c")" in deny*) ;; *) echo "solo allowed: $c"; return 1;; esac
  done
}
# `cel forge` is a door on both forges: its reads are everyone's, opening a
# PR is the builder's (worker, solo) and never an orchestrator's, and the
# same writes by hand - tea, or curl at a forge's API - stay refused.
test_cel_forge_reads_are_open_and_pr_create_is_the_builders() {
  local role c
  for role in orchestrator root core solo worker; do
    for c in 'cel forge pr view gizmo#31' 'cel forge pr checks gizmo#31 --json' 'cel forge pr reviews gizmo#31' \
             'cel forge pr list gizmo open' 'cel forge whoami gizmo' 'cel forge repo gizmo'; do
      assert_eq "$(guard_classify "$role" "$c")" allow || { echo "$role refused: $c"; return 1; }
    done
  done
  for role in solo worker; do
    assert_eq "$(guard_classify "$role" 'cel forge pr create gizmo --head WG-1-x --base main --title t --body-file b.md')" allow || return 1
  done
  for role in orchestrator root core; do
    for c in 'cel forge pr create gizmo --head WG-1-x --base main --title t --body-file b.md' \
             'cel --workspace sandbox forge pr create gizmo --head a --base main --title t --body-file b'; do
      case "$(guard_classify "$role" "$c")" in deny*) ;; *) echo "$role allowed: $c"; return 1;; esac
    done
  done
  for c in 'tea pr merge 31' 'tea pulls create --title x' 'tea pr close 31' 'tea pr approve 31' \
           'curl -X POST http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/31/merge' \
           'curl --request=PATCH http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/31' \
           'curl -XDELETE http://forgejo.internal/api/v1/repos/geoff/gizmo/branch_protections/main' \
           'curl -d @body.json http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls' \
           'curl --json {} https://api.github.com/repos/o/r/pulls'; do
    case "$(guard_classify orchestrator "$c")" in deny*) ;; *) echo "orchestrator allowed: $c"; return 1;; esac
  done
  for c in 'curl -s http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/31' 'tea pr list' 'tea pr 31'; do
    assert_eq "$(guard_classify orchestrator "$c")" allow || { echo "orchestrator refused a read: $c"; return 1; }
  done
}
# A forge write by hand is refused however the client is spelled: curl with
# a body in any form (-d@x, -dX, --data-*, -F/--form, -T/--upload-file,
# --json), a method in any form (-X POST, -XPOST, -sXPOST, --request[=]M, any
# case) or options from a file (-K/--config); `tea api` with anything but a
# plain GET; tea's write verbs with its global flags before them. Every role
# that can run the guard: orchestrators, root and core change no forge state,
# a worker uses gh / `cel forge` as before, and a solo agent changes its forge
# only through `cel forge` and `cel solo land`.
test_raw_forge_writes_are_refused_however_they_are_spelled() {
  local fj=http://forgejo.internal/api/v1/repos/o/r role c
  local -a writes=(
    "curl -d@b.json $fj/pulls" "curl -dFILE $fj/issues/3/comments" "curl -sXPOST $fj/pulls/3/merge"
    "curl -XPOST $fj/pulls/3/merge" "curl -X post $fj/pulls/3" "curl --request DELETE $fj/branch_protections/main"
    "curl --request=PATCH $fj/pulls/3" "curl --data-binary @x $fj/pulls" "curl --data-raw {} https://api.github.com/repos/o/r/pulls"
    "curl --data-urlencode a=b $fj/pulls" "curl -F f=@x $fj/releases/1/assets" "curl --form f=@x $fj/releases/1/assets"
    "curl -T x $fj/contents/a" "curl --upload-file x $fj/contents/a" "curl --json {} $fj/pulls"
    "curl -K cfg $fj/pulls/3/merge" "curl --config=cfg $fj/pulls/3/merge" "/usr/bin/curl -fsSd@x $fj/pulls"
    'tea api -X POST repos/o/r/pulls/3/merge' 'tea api -XPOST repos/o/r/pulls/3/merge'
    'tea api --method=DELETE repos/o/r/branch_protections/main' 'tea api --method PATCH repos/o/r/pulls/3'
    'tea api -f title=x repos/o/r/pulls' 'tea api --data @b.json repos/o/r/pulls'
    'tea pulls --repo o/r merge 3' 'tea --login fj pr close 3' 'tea pr --repo o/r create --title x'
    'tea -l fj pulls -r o/r m 3' 'tea branches protect main' 'tea releases delete v1'
  )
  for role in orchestrator root core worker solo; do
    for c in "${writes[@]}"; do
      case "$(guard_classify "$role" "$c")" in deny*) ;; *) echo "$role allowed: $c"; return 1;; esac
    done
  done
  # reads stay reads
  for role in orchestrator worker solo; do
    for c in "curl -s $fj/pulls/3" "curl -sSfL $fj/pulls" "curl -o out.json $fj/pulls" "curl -X GET $fj/pulls/3" \
             "curl -sI $fj/pulls/3" 'tea api repos/o/r/pulls/3' 'tea api -X GET repos/o/r/pulls/3' 'tea pr list --repo o/r' 'tea pr 31'; do
      assert_eq "$(guard_classify "$role" "$c")" allow || { echo "$role refused a read: $c"; return 1; }
    done
  done
}
# The Forgejo token is the forge's own key: no agent reads, copies or rewrites
# it, whichever role it plays and however it names the file.
test_no_agent_reads_or_writes_the_forge_token() {
  local role c
  for role in orchestrator root core worker solo other; do
    for c in 'cat ~/.config/cel/forge/forgejo.internal.token' 'less $HOME/.config/cel/forge/x.token' \
             'head -c5 ${XDG_CONFIG_HOME:-~/.config}/cel/forge/forgejo.internal.token' \
             'cp ~/.config/cel/forge/forgejo.internal.token /tmp/t' 'base64 /home/u/.config/cel/forge/*' \
             'ls ~/.config/cel/forge' 'cd ~/.config/cel/forge && cat *' "grep -r . \"\$HOME/.config/cel/forge/\""; do
      case "$(guard_classify "$role" "$c")" in deny*) ;; *) echo "$role allowed: $c"; return 1;; esac
    done
    case "$(guard_classify_read "$role" /home/u/.config/cel/forge/forgejo.internal.token)" in deny*) ;; *) echo "$role may Read the token"; return 1;; esac
    case "$(guard_classify_path "$role" /home/u/.config/cel/forge/forgejo.internal.token)" in deny*) ;; *) echo "$role may write the token"; return 1;; esac
    assert_eq "$(guard_classify_read "$role" /home/u/ws/repos/widget/lib/forge.sh)" allow || return 1
  done
  # the plane's own files are not the token
  assert_eq "$(guard_classify orchestrator 'cat lib/forge.sh tests/fixtures/forge/forgejo/pull.json')" allow
}
# ...and the hook enforces it where it runs: a claude worker or reviewer pane
# (otherwise untouched) included, the native Read tool included.
test_hook_refuses_the_forge_token_to_every_pane() {
  _gws
  local tok='/home/u/.config/cel/forge/forgejo.internal.token' cwd
  for cwd in "$T/repos/widget" "${CEL_WORKTREES:-$HOME/.herdr/worktrees}/repo/WG-1" /tmp; do
    _hook "$cwd" Bash "{\"command\":\"cat $tok\"}" && { echo "hook let $cwd cat the token"; rm -rf "$T"; return 1; }
    assert_contains "$HOOK_ERR" "forge API token" || { rm -rf "$T"; return 1; }
    _hook "$cwd" Read "{\"file_path\":\"$tok\"}" && { echo "hook let $cwd Read the token"; rm -rf "$T"; return 1; }
    _hook "$cwd" Read '{"file_path":"/tmp/notes.md"}' || { echo "hook blocked an ordinary Read in $cwd"; rm -rf "$T"; return 1; }
  done
  _hook "${CEL_WORKTREES:-$HOME/.herdr/worktrees}/repo/WG-1" Bash '{"command":"git push"}' || { echo "hook blocked a worker push"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# The solo agent lands through `cel solo land` but never records its own
# verdict; a worker does neither.
test_solo_lands_but_never_reviews_itself() {
  assert_eq "$(guard_classify solo 'cel solo land widget#7')" allow
  case "$(guard_classify solo 'cel solo review widget#7 approved --head x --by me')" in deny*) ;; *) return 1;; esac
  case "$(guard_classify worker 'cel solo land widget#7')" in deny*) ;; *) return 1;; esac
  case "$(guard_classify worker 'cel solo review widget#7 approved --head x --by me')" in deny*) ;; *) return 1;; esac
}
# The spellings that slipped past a substring match - spacing, tabs, quotes,
# options before the verb, chains, wrappers - are the SAME command.
test_factory_verbs_are_refused_however_they_are_spelled() {
  local c
  for c in 'cel-fanout  delegate x' "$(printf 'cel-fanout\tdelegate x')" '"cel-fanout" land x' \
           'cel-fanout --workspace plane delegate x' 'cel -C /ws --workspace p run worker' \
           'cel run "worker"' 'cd x && cel-fanout land y' 'bash -c "cel-fanout land y"' \
           'FOO=1 timeout 30 /home/x/bin/cel-fanout delegate a b c' 'echo $(cel-fanout land y)'; do
    case "$(guard_classify worker "$c")" in deny*) ;; *) echo "worker allowed: $c"; return 1;; esac
    case "$(guard_classify solo "$c")" in deny*) ;; *) echo "solo allowed: $c"; return 1;; esac
  done
}
# ...and text that merely MENTIONS a verb is not running it.
test_factory_verbs_in_arguments_are_not_commands() {
  local c
  for c in 'grep -n "cel-fanout land" lib/guard.sh' 'git commit -m "never cel-fanout land here"' \
           'rg "gh pr merge" docs'; do
    assert_eq "$(guard_classify solo "$c")" allow
    assert_eq "$(guard_classify worker "$c")" allow
  done
}
test_hook_lets_a_solo_pane_commit() {
  _gws
  CEL_ROLE=solo _hook "$T/repos/widget" Bash '{"command":"git commit -m x"}' \
    || { echo "solo commit blocked: $HOOK_ERR"; rm -rf "$T"; return 1; }
  rm -rf "$T"
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

# --- core: orchestrator-class, minus the product agent's factory -------------
test_role_core_from_its_dir_and_the_environment() {
  local C; C="$(mktemp -d)/core"; mkdir -p "$C/notes"
  assert_eq "$(CEL_ROLE='' CEL_CORE_DIR="$C" guard_role_of "$C/notes")" core
  assert_eq "$(CEL_ROLE=core guard_role_of /tmp)" core
  rm -rf "${C%/core}"
}
# A console agent launched before the TUI was retired still carries
# CEL_ROLE=console and stands in the old console directory. It must stay
# restricted - as core, which `cel console` now starts - never fall to `other`.
test_a_legacy_console_agent_is_guarded_as_core() {
  local D; D="$(mktemp -d)"; mkdir -p "$D/cel/console/notes"
  assert_eq "$(CEL_ROLE=console guard_role_of /tmp)" core
  assert_eq "$(CEL_ROLE='' XDG_DATA_HOME="$D" guard_role_of "$D/cel/console/notes")" core
  local role; role="$(CEL_ROLE=console guard_role_of /tmp)"
  assert_contains "$(guard_classify "$role" 'git commit -m x')" deny
  rm -rf "$D"
}
test_core_may_read_coordinate_and_switch_mode() {
  local c
  for c in 'cel fleet --json' 'cel inbox send games-orch "x" --workspace w' 'cel decide list' \
           'cel-fanout status --workspace w' 'cel mode games solo --workspace w' \
           'cel run orchestrator --product games --workspace w --restart' \
           'gh pr view 3' 'gh pr diff 3' 'git -C repos/x log --oneline' 'herdr agent focus w1:p1'; do
    assert_eq "$(guard_classify core "$c")" allow
  done
}
test_core_does_not_build_delegate_or_land() {
  local c
  for c in 'cel-fanout delegate x' 'cel-fanout land CEL-1' 'cel-fanout review CEL-1 approved' \
           'cel solo land celestial#3' 'cel run worker --repo x --branch y' 'cel run reviewer --repo x --pr 1' \
           'gh pr merge 3' 'git -C repos/x commit -m y' 'git push' 'cel learn add x' 'cel release celestial 1.0.0' \
           'herdr worktree create --cwd x' 'cel-fanout request-review CEL-1 --head abc' 'cel-fanout try CEL-1' \
           'cel-fanout some-future-verb x' 'cd /tmp && cel-fanout --workspace w land CEL-1'; do
    assert_contains "$(guard_classify core "$c")" deny
  done
}
test_core_may_read_the_ledger() {
  local c
  for c in 'cel-fanout status --workspace w' 'cel-fanout why CEL-1' 'cel-fanout wait CEL-1' \
           'cel-fanout --workspace w status'; do
    assert_eq "$(guard_classify core "$c")" allow
  done
}
test_core_writes_only_its_own_directory() {
  local C; C="$(mktemp -d)/core"
  assert_eq "$(CEL_CORE_DIR="$C" guard_classify_path core "$C/notes.md")" allow
  assert_contains "$(CEL_CORE_DIR="$C" guard_classify_path core "/home/x/ws/p/.cel/specs/a.md")" deny
  rm -rf "${C%/core}"
}
test_workers_and_solo_agents_do_not_start_core() {
  assert_contains "$(guard_classify worker 'cel core')" deny
  assert_contains "$(guard_classify solo 'cel run core')" deny
}
test_workers_do_not_run_the_owners_in_pane_commands() {
  assert_contains "$(guard_classify worker 'cel here --restart-core-when-idle')" deny
  assert_contains "$(guard_classify worker 'CEL_ROLE=core cel here mode x solo')" deny
}

# --- the bottom tier reports; it does not run the factory --------------------
# A worker whose PR had just been approved ran `cel-fanout land <its own id>`
# from its own worktree: the ledger lock was held for three minutes while the
# gate ran, the orchestrator's `status` hung on it, and only branch protection
# stopped the merge. The role file already said "never merge"; nothing enforced
# it, because every command was allowed for the worker role before any check.
test_worker_may_not_land_release_or_delegate() {
  local v
  for v in land release delegate scout spike collect reconcile; do
    assert_contains "$(guard_classify worker "cel-fanout $v ABC-1")" deny
  done
  assert_contains "$(guard_classify worker 'cel-fanout land ABC-1')" 'not yours'
  assert_contains "$(guard_classify worker '/home/x/.local/share/cel/core/skills/fanout/bin/cel-fanout land ABC-1')" deny
  assert_contains "$(guard_classify worker 'bash /home/x/core/skills/fanout/bin/cel-fanout release ABC-1')" deny
  assert_contains "$(guard_classify worker 'cel-fanout land ABC-1 --workspace alpha')" deny
  assert_contains "$(guard_classify worker 'cel-fanout -C /tmp/ws land ABC-1')" deny
}
test_worker_may_not_start_agents() {
  local r
  for r in orchestrator root console worker reviewer; do
    assert_contains "$(guard_classify worker "cel run $r --repo widget")" deny
  done
  assert_contains "$(guard_classify worker 'cel console')" 'does not start agents'
  assert_contains "$(guard_classify solo 'cel console')" deny
  assert_contains "$(guard_classify worker 'cel run worker --repo widget')" 'does not start agents'
}
test_worker_keeps_the_rest_of_its_job() {
  assert_eq "$(guard_classify worker 'cel-fanout status')" allow
  assert_eq "$(guard_classify worker 'cel-fanout try ABC-1')" allow
  assert_eq "$(guard_classify worker 'cel-fanout why ABC-1')" allow
  assert_eq "$(guard_classify worker 'cel-fanout wait')" allow
  assert_eq "$(guard_classify worker 'cel inbox send alpha-orch "done"')" allow
  assert_eq "$(guard_classify worker 'cel-verify ABC-1')" allow
  assert_eq "$(guard_classify worker 'gh pr create --fill')" allow
  assert_eq "$(guard_classify worker 'gh pr edit 3 --title x')" allow
  assert_eq "$(guard_classify worker 'gh pr ready 3')" allow
}
test_the_deny_is_the_workers_alone() {
  assert_eq "$(guard_classify orchestrator 'cel-fanout land ABC-1')" allow
  assert_eq "$(guard_classify root 'cel-fanout land ABC-1')" allow
  assert_eq "$(guard_classify other 'cel-fanout land ABC-1')" allow
  assert_eq "$(guard_classify other 'cel run worker --repo widget')" allow
}

# THE CLASSIFIER'S OWN FAILURE IS NOT `allow`. A mode it does not know or a
# policy that will not load exits 2 with the reason on stderr and no verdict,
# so the adapters can tell a broken classifier from a permitted call.
test_guard_classifier_failure_is_an_error_not_an_allow() {
  local cls="$CEL_ROOT/tools/hooks/guard-classify.sh" out rc
  rc=0; out="$(bash "$cls" bogus /tmp 'git push' 2>/dev/null)" || rc=$?
  assert_eq "mode:$rc:$out" "mode:2:"
  assert_contains "$(bash "$cls" bogus /tmp 'git push' 2>&1 >/dev/null)" 'unknown mode'
  local T; T="$(mktemp -d)"
  rc=0; out="$(CEL_ROOT="$T" bash "$cls" command /tmp 'git push' 2>/dev/null)" || rc=$?
  assert_eq "policy:$rc:$out" "policy:2:"
  rm -rf "$T"
  # a working classifier still answers both modes
  assert_eq "$(bash "$cls" command /tmp 'ls')" allow
  assert_eq "$(bash "$cls" path /tmp /tmp/x)" allow
}
