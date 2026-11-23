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
  # GC_CLOSED_RAW, when set, is the closedAt the forge states verbatim;
  # GC_GH_NUMBER/GC_GH_URL override the PR it names; GC_GH_SIDE runs while
  # the forge is being asked - something changing between the pass's first
  # look and the removal.
  unset GC_CLOSED_RAW GC_GH_NUMBER GC_GH_URL GC_GH_SIDE
  RC_ROSTER='{"result":{"agents":[]}}'
  cel_agent_list() { printf '%s' "$RC_ROSTER"; }
  # /proc is real, but only THIS test's processes are asked about: each test
  # runs in its own session (tests/run.sh: setsid), and the box's own
  # processes - an smbd or sshd-session whose cwd this uid cannot read -
  # would otherwise keep every checkout and fail the test on that box only.
  pgrep() { command pgrep -s 0 "$@"; }
  gh() {
    printf '%s\n' "$*" >> "$GC_GH"
    [ -z "${GC_GH_SIDE:-}" ] || eval "$GC_GH_SIDE"
    [ "$GC_PR_STATE" != UNKNOWN ] || return 1
    local at="" n="${GC_GH_NUMBER:-$3}"
    [ "$GC_PR_STATE" = OPEN ] || at="$(date -u -d "-$GC_CLOSED_DAYS days" +%Y-%m-%dT%H:%M:%SZ)"
    [ -z "${GC_CLOSED_RAW+set}" ] || at="$GC_CLOSED_RAW"
    jq -n --arg s "$GC_PR_STATE" --arg at "$at" --arg h "$(command git -C "$T/ws/repos/widget" rev-parse HEAD)" \
      --argjson n "$n" --arg u "${GC_GH_URL:-https://github.com/acme/widget/pull/$n}" \
      '{state:$s, closedAt:(if $at == "" then null else $at end), mergedAt:(if $s == "MERGED" and $at != "" then $at else null end),
        headRefOid:$h, number:$n, url:$u}'
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

# An own-uid smbd's cwd and open files are unreadable. It no longer blinds the
# whole pass: it occupies what Samba exports (a checkout inside, equal to or
# containing a share is kept live) and nothing else. Unknown exports: blind.
_rc_smbd() { # <share path, or "" when testparm and smb.conf both fail>
  pgrep() { printf '%s\n' 999001; }
  _gc_comm_of() { printf '%s' 'smbd[192.0.2.7'; }
  _gc_pid_exists() { return 0; }
  _gc_alive() { return 0; }
  find() {
    if [ "${1:-}" = /proc/999001/cwd ]; then
      printf "find: '/proc/999001/cwd': Permission denied\nfind: '/proc/999001/fd': Permission denied\n" >&2; return 1
    fi
    command find "$@"
  }
  _gc_smb_conf() { printf '%s' "$T/none.conf"; }
  if [ -n "$1" ]; then eval "_gc_testparm() { printf '[s]\n\tpath = %s\n' '$1'; }"
  else _gc_testparm() { return 1; }; fi
  _gc_cwd_reset
}
test_rc_unreadable_smbd_keeps_only_checkouts_under_its_shares() {
  _rc_fixture
  local co; co="$(_rc_checkout widget-pr-71)"
  _rc_smbd "$co"
  _rc_run 0
  [ -d "$co" ] || { echo "removed a checkout Samba exports"; cat "$T/out"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "1 live" || { cat "$T/out"; rm -rf "$T"; return 1; }
  _rc_smbd "$co/src"
  _rc_run 0
  [ -d "$co" ] || { echo "removed a checkout containing a share"; cat "$T/out"; rm -rf "$T"; return 1; }
  _rc_smbd "$T"
  _rc_run 0
  [ -d "$co" ] || { echo "removed a checkout inside a share"; cat "$T/out"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "1 live" || { cat "$T/out"; rm -rf "$T"; return 1; }
  _rc_smbd ""
  _rc_run 0
  [ -d "$co" ] || { echo "removed with the share list unknown"; cat "$T/out"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "cannot read every process" || { cat "$T/out"; rm -rf "$T"; return 1; }
  _rc_smbd "$T/elsewhere"
  _rc_run 0
  _rc_gone "$co" || { echo "a share elsewhere still blocked removal"; cat "$T/out"; rm -rf "$T"; return 1; }
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

_rc_packet() { # <checkout>: a retained Rex retirement packet citing it
  (umask 077 && mkdir -p "$T/rex/retirements")
  jq -n --arg c "$1" --arg r "$T/rex/widget-pr-71-review.json" \
    '{version:1, stage:"prepared", identity:{backend:"rex", role:"reviewer", agent:"pi", name:"widget-pr-71-review", cwd:$c},
      checkout:{path:$c}, artifacts:{cwd:$c}, receipt:{path:$r}}' > "$T/rex/retirements/late.json"
  chmod 600 "$T/rex/retirements/late.json"
}

# EVERY VETO IS ASKED AGAIN RIGHT BEFORE THE REMOVE. The pass reads a checkout
# once to choose it (here: already known merged long ago, so what it holds is
# read before the forge is asked), then spends a forge lookup; whatever
# appears in that window - a file, a commit, a retirement packet, a reviewer
# row, a process, a symlink in its place - keeps it.
test_rc_every_veto_is_taken_again_adjacent_to_the_removal() {
  local c co want
  for c in 'late.txt|unique' 'commit|unique' 'packet|evidence' 'row|reviewer' 'process|live' 'symlink|unresolved'; do
    _rc_fixture
    co="$(_rc_checkout widget-pr-71)"
    jq -n --arg k "$co" --argjson c "$(( $(date +%s) - 864000 ))" '{($k): {state:"MERGED", at:0, closed:$c}}' > "$CEL_GC_REVIEW_CHECKOUT_STATE"
    want="${c#*|}"
    case "${c%%|*}" in
      late.txt) GC_GH_SIDE='printf "mine\n" > "$co/late.txt"' ;;
      commit)   GC_GH_SIDE='command git -C "$co" -c user.email=t@t -c user.name=t commit -q --allow-empty -m mine' ;;
      packet)   GC_GH_SIDE='_rc_packet "$co"' ;;
      row)      GC_GH_SIDE='reviewers_record "$T/ws" widget 71 w1:p3 widget-pr-71-review "$co"' ;;
      process)  GC_GH_SIDE='( cd "$co" && exec sleep 30 ) >/dev/null 2>&1 & printf "%s" "$!" > "$T/late.pid"; sleep 0.3' ;;
      symlink)  GC_GH_SIDE='mv "$co" "$co.real" && ln -s "$co.real" "$co"' ;;
    esac
    rm -f "$T/late.pid"
    _rc_run 0
    [ ! -s "$T/late.pid" ] || kill "$(cat "$T/late.pid")" 2>/dev/null || true
    assert_eq "$(grep -c 'pr view' "$GC_GH")" 1 || { echo "$c: the forge was not asked"; rm -rf "$T"; return 1; }
    assert_eq "$rc_removed" 0 || { echo "$c: removed"; cat "$T/out"; rm -rf "$T"; return 1; }
    if [ "${c%%|*}" = symlink ]; then [ -d "$co.real" ] || { echo "symlink: target removed"; rm -rf "$T"; return 1; }
    else [ -d "$co" ] && [ ! -L "$co" ] || { echo "$c: checkout gone"; rm -rf "$T"; return 1; }; fi
    assert_contains "$(cat "$T/out")" "1 $want" || { echo "$c"; cat "$T/out"; rm -rf "$T"; return 1; }
    rm -rf "$T"
  done
}

# A CLOSE TIME IS AN INSTANT THE FORGE STATED. `date -d` would read "now",
# "@0" or "1 year ago", and Forgejo's zero time as ancient; none of those, an
# empty one, a date alone or one before 2000 is a close time: kept. A real
# ISO-8601 instant with an offset is one.
test_rc_only_an_iso_close_time_from_2000_on_counts() {
  local raw co
  for raw in '0001-01-01T00:00:00Z' '' 'now' '@0' '1 year ago' '2026-11-01' '1999-12-31T00:00:00Z' 'junk'; do
    _rc_fixture
    co="$(_rc_checkout widget-pr-71)"
    GC_CLOSED_RAW="$raw"
    _rc_run 0
    [ -d "$co" ] || { echo "removed on closedAt '$raw'"; rm -rf "$T"; return 1; }
    assert_contains "$(cat "$T/out")" "1 unknown" || { echo "'$raw'"; cat "$T/out"; rm -rf "$T"; return 1; }
    rm -rf "$T"
  done
  _rc_fixture
  co="$(_rc_checkout widget-pr-71)"
  GC_CLOSED_RAW="$(TZ=Pacific/Auckland date -d '-10 days' +%Y-%m-%dT%H:%M:%S%:z)"
  _rc_run 0
  _rc_gone "$co" || { echo "an offset ISO time was refused: $GC_CLOSED_RAW"; cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A REVIEWER STARTING NOW WINS. The final check and the remove hold the lock
# `cel run` holds while it starts an agent (<rex state>/launch.lock): while a
# launch holds it past CEL_GC_LAUNCH_LOCK_WAIT, the checkout is kept as busy.
test_rc_a_launch_in_progress_keeps_the_checkout() {
  _rc_fixture
  local co p; co="$(_rc_checkout widget-pr-71)"
  (umask 077 && mkdir -p "$T/rex")
  ( exec 9>>"$T/rex/launch.lock"; flock 9; exec sleep 30 ) & p=$!
  sleep 0.3
  CEL_GC_LAUNCH_LOCK_WAIT=1 _rc_run 0
  kill "$p" 2>/dev/null; wait "$p" 2>/dev/null || true
  [ -d "$co" ] || { echo "removed while a launch held the lock"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "1 busy" || { cat "$T/out"; rm -rf "$T"; return 1; }
  _rc_run 0
  _rc_gone "$co" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# GITHUB'S ANSWER MUST BE THIS PR, as Forgejo's must: its number, and its url
# ending in /<owner>/<name>/pull/<n>.
test_rc_a_github_answer_naming_another_pr_or_repo_keeps_the_checkout() {
  local c co
  for c in 'number|72' 'url|https://github.com/acme/other/pull/71' 'url|https://github.com/acme/widget/pull/711'; do
    _rc_fixture
    co="$(_rc_checkout widget-pr-71)"
    case "${c%%|*}" in number) GC_GH_NUMBER="${c#*|}" ;; url) GC_GH_URL="${c#*|}" ;; esac
    _rc_run 0
    [ -d "$co" ] || { echo "$c: removed"; rm -rf "$T"; return 1; }
    assert_contains "$(cat "$T/out")" "1 unknown" || { echo "$c"; cat "$T/out"; rm -rf "$T"; return 1; }
    assert_contains "$(cat "$GC_GH")" "number,url" || { rm -rf "$T"; return 1; }
    rm -rf "$T"
  done
}

# A PRIVATE CLONE (no worktree of the repo's clone) is named by its directory
# alone, so it goes only when it proves it is that PR's: HEAD at or behind the
# PR's head, or cloned from the repo. One that cannot is kept and named.
test_rc_a_private_clone_goes_only_when_it_is_the_prs() {
  _rc_fixture
  local ok other
  ok="$T/reviews/widget-pr-75"
  git clone -q "$T/ws/repos/widget" "$ok"
  other="$T/reviews/widget-pr-76"
  git init -q "$other"
  git -C "$other" -c user.email=t@t -c user.name=t commit -q --allow-empty -m elsewhere
  git -C "$other" update-ref refs/remotes/origin/main HEAD
  git -C "$other" remote add origin git@github.com:someone/else.git
  _rc_run 0
  [ ! -e "$ok" ] || { echo "the PR's own clone was kept"; cat "$T/out"; rm -rf "$T"; return 1; }
  [ -d "$other/.git" ] || { echo "a clone not proven to be the PR's was removed"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "1 unproven" || { cat "$T/out"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/out")" "$other" || { cat "$T/out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
