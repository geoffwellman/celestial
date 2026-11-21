# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/registry.sh"
source "$CEL_ROOT/lib/gc.sh"

# REVIEWER CHECKOUTS GO WHEN THEIR PR IS LONG SETTLED. A finished reviewer's
# checkout is kept (`cel run reviewer` brings it back), so nothing removed
# them and they piled up by the hundred. `cel gc` removes one only when every
# fact holds: its PR merged or closed (asked of the repo's own forge; unreadable
# keeps it), more than CEL_REVIEW_CHECKOUT_KEEP_DAYS ago, no recorded reviewer
# of the PR, no pane, process cwd or open file in it, no retained Rex
# retirement packet citing it, and nothing of its own beyond ignored build
# output. Real linked worktrees; only the forge, the roster and the clock are
# stubbed.
_rc_fixture() { # [forge: github|forgejo]
  T="$(mktemp -d)"
  export HOME="$T/home" CEL_REVIEWERS_STATE="$T/reviewers.json" CEL_REGISTRY="$T/registry.yaml" \
    CEL_REVIEW_DIR="$T/reviews" CEL_REX_STATE="$T/rex" CEL_GC_REVIEW_CHECKOUT_STATE="$T/rc-state.json"
  unset CEL_REVIEW_CHECKOUT_KEEP_DAYS CEL_GC_REVIEW_CHECKOUT_CAP
  mkdir -p "$HOME" "$T/ws/repos/widget" "$T/reviews" "$T/ws/.cel/reviews/pr-71"
  if [ "${1:-github}" = forgejo ]; then
    printf 'name: rcws\nrepos:\n  - name: widget\n    url: git@forgejo.example:acme/widget.git\n    forge: forgejo\n    host: http://forgejo.example\n' > "$T/ws/workspace.yaml"
  else
    printf 'name: rcws\nrepos:\n  - name: widget\n    url: git@github.com:acme/widget.git\n' > "$T/ws/workspace.yaml"
  fi
  local r="$T/ws/repos/widget"
  git -C "$r" init -q
  printf 'node_modules/\n' > "$r/.gitignore"; printf 'x\n' > "$r/README"
  git -C "$r" add .gitignore README
  git -C "$r" -c user.email=t@t -c user.name=t commit -q -m base
  git -C "$r" update-ref refs/remotes/origin/main HEAD
  registry_add rcws "$T/ws" ""
  # the verdict and evidence that live elsewhere, which nothing here touches
  printf '{"widget#71":{"verdict":"approved","head":"x"}}\n' > "$T/ws/.cel/solo-reviews.json"
  printf 'notes\n' > "$T/ws/.cel/reviews/pr-71/role-reviewer.md"
  GC_PR_STATE=MERGED GC_CLOSED_DAYS=10 GC_GH="$T/gh"; : > "$GC_GH"
  RC_ROSTER='{"result":{"agents":[]}}'
  cel_agent_list() { printf '%s' "$RC_ROSTER"; }
  gh() {
    printf '%s\n' "$*" >> "$GC_GH"
    [ "$GC_PR_STATE" != UNKNOWN ] || return 1
    local at=""; [ "$GC_PR_STATE" = OPEN ] || at="$(date -u -d "-$GC_CLOSED_DAYS days" +%Y-%m-%dT%H:%M:%SZ)"
    jq -n --arg s "$GC_PR_STATE" --arg at "$at" --arg h "$(command git -C "$T/ws/repos/widget" rev-parse HEAD)" \
      '{state:$s, closedAt:(if $at == "" then null else $at end), mergedAt:(if $s == "MERGED" then $at else null end), headRefOid:$h}'
  }
}

_rc_checkout() { # <name> -> path: a detached linked worktree, as reviewer_checkout_make makes it
  local p="$T/reviews/$1"
  git -C "$T/ws/repos/widget" worktree add -q --detach "$p" HEAD
  mkdir -p "$p/node_modules/dep"; printf 'build output\n' > "$p/node_modules/dep/index.js"
  printf '%s' "$p"
}

_rc_run() { # <dry 0|1> -> output in $T/out; rc_* left set in this shell
  _gc_review_checkouts "$1" > "$T/out" 2>&1
}

_rc_gone() { # <path>: removed from disk AND from the clone's worktree list
  [ ! -e "$1" ] || { echo "$1 still on disk"; return 1; }
  ! command git -C "$T/ws/repos/widget" worktree list --porcelain | grep -qxF "worktree $1" \
    || { echo "$1 still registered as a worktree"; return 1; }
}

test_rc_removes_a_merged_checkout_closed_longer_ago_than_the_window() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  _rc_run 0
  _rc_gone "$co" || { cat "$T/out"; rm -rf "$T"; return 1; }
  assert_eq "$rc_removed" 1 || { rm -rf "$T"; return 1; }
  [ "$rc_kib" -gt 0 ] || { echo "no space counted"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GC_GH")" "pr view 71 --repo acme/widget" || { rm -rf "$T"; return 1; }
  # the verdict file and the evidence directory are untouched
  assert_eq "$(cat "$T/ws/.cel/solo-reviews.json")" '{"widget#71":{"verdict":"approved","head":"x"}}' || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/ws/.cel/reviews/pr-71/role-reviewer.md")" notes || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_rc_closed_unmerged_pr_counts_as_settled_too() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71-review-security)"
  GC_PR_STATE=CLOSED
  _rc_run 0
  _rc_gone "$co" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_rc_keeps_an_open_prs_checkout() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  GC_PR_STATE=OPEN
  _rc_run 0
  [ -d "$co" ] || { echo "an open PR's checkout was removed"; rm -rf "$T"; return 1; }
  assert_eq "$rc_removed" 0 || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "1 open-pr" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_rc_keeps_a_checkout_whose_pr_closed_inside_the_window() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  GC_CLOSED_DAYS=1
  _rc_run 0
  [ -d "$co" ] || { echo "a PR closed a day ago lost its checkout"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "1 recent" || { cat "$T/out"; rm -rf "$T"; return 1; }
  # the window is the knob: at 0 days the same checkout goes
  : > "$CEL_GC_REVIEW_CHECKOUT_STATE"
  CEL_REVIEW_CHECKOUT_KEEP_DAYS=0 _rc_run 0
  _rc_gone "$co" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_rc_keeps_a_checkout_a_process_stands_in_or_holds_a_file_open() {
  _rc_fixture
  local co p how
  for how in cwd fd; do
    co="$(_rc_checkout "widget-pr-7$([ "$how" = cwd ] && echo 1 || echo 2)")"
    if [ "$how" = cwd ]; then ( cd "$co" && exec sleep 30 ) & p=$!
    else ( cd / && exec sleep 30 < "$co/README" ) & p=$!; fi
    sleep 0.3
    _rc_run 0
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null || true
    [ -d "$co" ] || { echo "$how: removed under a live process"; cat "$T/out"; rm -rf "$T"; return 1; }
    assert_contains "$(cat "$T/out")" "1 live" || { echo "$how"; cat "$T/out"; rm -rf "$T"; return 1; }
    command git -C "$T/ws/repos/widget" worktree remove --force "$co"
  done
  rm -rf "$T"
}

test_rc_keeps_a_checkout_a_pane_stands_in_or_a_reviewer_is_recorded_for() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  RC_ROSTER="$(jq -nc --arg c "$co/src" '{result:{agents:[{pane_id:"w1:p9",name:"widget-pr-71-review",cwd:$c,agent_status:"idle"}]}}')"
  _rc_run 0
  [ -d "$co" ] || { echo "removed under a pane"; rm -rf "$T"; return 1; }
  RC_ROSTER='{"result":{"agents":[]}}'
  reviewers_record "$T/ws" widget 71 w1:p3 widget-pr-71-review "$co"
  _rc_run 0
  [ -d "$co" ] || { echo "removed under a recorded reviewer"; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$GC_GH")" "" || { echo "the forge was asked for a checkout already kept"; rm -rf "$T"; return 1; }
  # an unreadable roster proves nothing: kept
  reviewers_write '[]'; RC_ROSTER='{"oops":true}'
  _rc_run 0
  [ -d "$co" ] || { echo "removed on an unreadable roster"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_rc_keeps_a_checkout_a_retained_rex_retirement_packet_cites() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  (umask 077 && mkdir -p "$T/rex/retirements")
  jq -n --arg c "$co" --arg r "$T/rex/widget-pr-71-review.json" \
    '{version:1, stage:"prepared", identity:{backend:"rex", role:"reviewer", agent:"pi", name:"widget-pr-71-review", cwd:$c},
      checkout:{path:$c}, artifacts:{cwd:$c}, receipt:{path:$r}}' > "$T/rex/retirements/widget-pr-71-review.json"
  chmod 600 "$T/rex/retirements/widget-pr-71-review.json"
  _rc_run 0
  [ -d "$co" ] || { echo "removed a checkout a retirement packet cites"; cat "$T/out"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "1 evidence" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_rc_keeps_a_checkout_whose_pr_state_cannot_be_read() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  GC_PR_STATE=UNKNOWN
  _rc_run 0
  [ -d "$co" ] || { echo "removed on an unreadable PR"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "1 unknown" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A FORGEJO REPO'S PR IS ASKED OF FORGEJO (forge_pr_view as the workspace),
# never of gh, whose mirror numbers other PRs the same; the answer must name
# exactly this owner/name and PR.
test_rc_resolves_a_forgejo_repo_through_its_forge() {
  local url want co
  for url in http://forgejo.example/acme/widget/pulls/71 http://forgejo.example/other/widget/pulls/71; do
    _rc_fixture forgejo
    co="$(_rc_checkout widget-pr-71)"
    GC_FJ="$T/fj"; : > "$GC_FJ"; GC_FJ_URL="$url"
    forge_pr_view() {
      printf '%s\n' "$*" >> "$GC_FJ"
      jq -nc --arg u "$GC_FJ_URL" --arg at "$(date -u -d '-10 days' +%Y-%m-%dT%H:%M:%SZ)" \
        '{number:71, state:"merged", head_sha:"1111111111111111111111111111111111111111", head_ref:"feature", url:$u, merged_at:$at, closed_at:$at}'
    }
    _rc_run 0
    assert_eq "$(cat "$GC_GH")" "" || { echo "gh was asked"; rm -rf "$T"; return 1; }
    assert_eq "$(sort -u "$GC_FJ")" "$T/ws widget 71" || { rm -rf "$T"; return 1; }
    case "$url" in
      */acme/*) _rc_gone "$co" || { cat "$T/out"; rm -rf "$T"; return 1; } ;;
      *) [ -d "$co" ] || { echo "removed on another repository's PR"; rm -rf "$T"; return 1; } ;;
    esac
    rm -rf "$T"
  done
}

# NOTHING UNIQUE IS LOST. Ignored build output goes with the checkout; a file
# of its own - untracked or modified - keeps it, and the pass names it.
test_rc_keeps_and_lists_a_checkout_with_files_of_its_own() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  printf 'my notes\n' > "$co/notes.txt"
  _rc_run 0
  [ -e "$co/notes.txt" ] || { echo "an untracked file was deleted"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "$co" || { cat "$T/out"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "notes.txt" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm "$co/notes.txt"; printf 'changed\n' > "$co/README"
  _rc_run 0
  assert_eq "$(cat "$co/README")" changed || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "README" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# ONE PASS IS BOUNDED: at most CEL_GC_REVIEW_CHECKOUT_CAP checkouts are asked
# of the forge (and so removed) per pass, oldest first; the rest wait.
test_rc_one_pass_asks_and_removes_at_most_the_cap() {
  _rc_fixture
  local a b c
  a="$(_rc_checkout widget-pr-71)"; touch -d '-3 days' "$a"
  b="$(_rc_checkout widget-pr-72)"; touch -d '-2 days' "$b"
  c="$(_rc_checkout widget-pr-73)"; touch -d '-1 days' "$c"
  CEL_GC_REVIEW_CHECKOUT_CAP=2 _rc_run 0
  assert_eq "$rc_removed" 2 || { cat "$T/out"; rm -rf "$T"; return 1; }
  assert_eq "$(grep -c 'pr view' "$GC_GH")" 2 || { rm -rf "$T"; return 1; }
  _rc_gone "$a" && _rc_gone "$b" || { rm -rf "$T"; return 1; }
  [ -d "$c" ] || { echo "the newest went first"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "1 deferred" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# What the forge said is remembered so the cap is spent on news: an open PR is
# asked again after an hour, a recent close not until its window has passed.
# Removal itself never rests on the memory - it is always a fresh answer.
test_rc_remembers_open_and_recent_answers_between_passes() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  GC_PR_STATE=OPEN
  _rc_run 0; _rc_run 0
  assert_eq "$(grep -c 'pr view' "$GC_GH")" 1 || { rm -rf "$T"; return 1; }
  GC_PR_STATE=MERGED GC_CLOSED_DAYS=1
  jq '.[].at -= 7200' "$CEL_GC_REVIEW_CHECKOUT_STATE" > "$T/s" && mv "$T/s" "$CEL_GC_REVIEW_CHECKOUT_STATE"
  _rc_run 0; _rc_run 0
  assert_eq "$(grep -c 'pr view' "$GC_GH")" 2 || { rm -rf "$T"; return 1; }
  [ -d "$co" ] || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_rc_dry_run_removes_nothing_writes_nothing_and_says_what_would_go() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  _rc_run 1
  [ -d "$co" ] || { echo "a dry run removed a checkout"; rm -rf "$T"; return 1; }
  [ ! -e "$CEL_GC_REVIEW_CHECKOUT_STATE" ] || { echo "a dry run wrote state"; rm -rf "$T"; return 1; }
  assert_eq "$rc_removed" 1 || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "would remove" || { cat "$T/out"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "widget#71" || { rm -rf "$T"; return 1; }
  assert_contains "$rc_fragment" "1 review checkouts would be removed" || { echo "$rc_fragment"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A process this user owns whose open files cannot be read could be standing in
# any checkout: every checkout is kept. A zombie, or one of the fixed system
# processes gc already knows cannot be an agent, is not that.
test_rc_an_unreadable_process_keeps_every_checkout() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  pgrep() { printf '%s\n' 999001; }
  find() { printf "find: '/proc/999001/fd': Permission denied\n" >&2; return 1; }
  _gc_pid_exists() { return 0; }
  _gc_alive() { return 0; }
  _gc_comm_of() { printf pi; }
  _rc_run 0
  [ -d "$co" ] || { echo "removed while a process could not be read"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "cannot read" || { cat "$T/out"; rm -rf "$T"; return 1; }
  _gc_comm_of() { printf ssh-agent; }
  _rc_run 0
  _rc_gone "$co" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_rc_a_zombie_with_unreadable_files_does_not_keep_checkouts() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  pgrep() { printf '%s\n' 999001; }
  find() { printf "find: '/proc/999001/fd': Permission denied\n" >&2; return 1; }
  _gc_pid_exists() { return 0; }
  _gc_alive() { return 1; }
  _gc_comm_of() { printf herdr-core; }
  _rc_run 0
  _rc_gone "$co" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
