# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/box.sh"

# EVERY TEST IN THIS FILE RUNS AGAINST A FIXTURE HOME AND A STUB docker.
# This is the one suite whose subject deletes things, so "never touch the live
# box" is not a style rule here: a policy table resolved from the real $HOME
# with a real docker on PATH would prune the machine the suite is running on.
# The policy is read from $HOME and every removal goes through _box_rm, which
# logs to CEL_BOX_RM_LOG - so the argv of every deletion is observable without
# any deletion escaping the fixture.
_box_fixture() {
  T="$(mktemp -d)"
  export HOME="$T/home"
  export CEL_BOX_RM_LOG="$T/removed"
  : > "$CEL_BOX_RM_LOG"
  # regenerable: costs a re-download, never data
  mkdir -p "$HOME/.bun/install/cache" "$HOME/.npm/_cacache" "$HOME/.cache/uv"
  # ours: the factory made it
  mkdir -p "$HOME/.cache/cel" "$HOME/.local/state/cel/scratch"
  # someone's: large, irreplaceable, NOT the janitor's
  mkdir -p "$HOME/restore"
  _box_age_file "$HOME/.bun/install/cache/old-package" 60
  _box_age_file "$HOME/.bun/install/cache/fresh-package" 1
  _box_age_file "$HOME/.cache/cel/old-scratch" 60
  _box_age_file "$HOME/restore/profile-dump.tar" 400
  BOX_STUB_BIN="$T/bin"
  mkdir -p "$BOX_STUB_BIN"
  DOCKER_LOG="$T/docker.argv"
  : > "$DOCKER_LOG"
}

_box_age_file() { # <path> <days-old>
  mkdir -p "$(dirname "$1")"
  printf 'x%.0s' {1..2048} > "$1"
  touch -d "$2 days ago" "$1"
}

# argv logged, canned JSON printed - and nothing on this box touched. The
# recorded ages are deliberately extreme (a year) so that an image surviving
# the sweep can only be the keep list doing it, never a young image.
_box_stub_docker() {
  cat > "$BOX_STUB_BIN/docker" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DOCKER_LOG"
case "\$1 \$2" in
  "system df")
    printf '%s\n' '{"Type":"Images","TotalCount":"12","Active":"3","Size":"41.2GB","Reclaimable":"8.7GB (21%)"}'
    printf '%s\n' '{"Type":"Containers","TotalCount":"4","Active":"1","Size":"3.5GB","Reclaimable":"3.5GB (100%)"}'
    printf '%s\n' '{"Type":"Local Volumes","TotalCount":"2","Active":"2","Size":"1.0GB","Reclaimable":"0B (0%)"}'
    printf '%s\n' '{"Type":"Build Cache","TotalCount":"40","Active":"0","Size":"8.7GB","Reclaimable":"8.7GB (100%)"}'
    ;;
  "image ls")
    printf '%s\n' '{"ID":"sha256:aaa","Repository":"ubuntu","Tag":"24.04","CreatedAt":"2025-01-01 00:00:00 +0000 UTC","Size":"78MB"}'
    printf '%s\n' '{"ID":"sha256:bbb","Repository":"alpine","Tag":"3.19","CreatedAt":"2025-01-01 00:00:00 +0000 UTC","Size":"13MB"}'
    printf '%s\n' '{"ID":"sha256:ccc","Repository":"ghcr.io/alpha/bundle","Tag":"base","CreatedAt":"2025-01-01 00:00:00 +0000 UTC","Size":"210MB"}'
    printf '%s\n' '{"ID":"sha256:ddd","Repository":"widget","Tag":"build-91","CreatedAt":"2025-01-01 00:00:00 +0000 UTC","Size":"1.2GB"}'
    ;;
  "image inspect")
    case "\$*" in *ccc*) printf '\n';; *) printf 'sha256:parent\n';; esac
    ;;
  *) printf 'Total reclaimed space: 1.5GB\n' ;;
esac
EOS
  chmod +x "$BOX_STUB_BIN/docker"
  PATH="$BOX_STUB_BIN:$PATH"
}

_box_prune_calls() { grep -E 'prune|image rm' "$DOCKER_LOG" || true; }

# ---------------------------------------------------------------- the report

test_box_space_reports_all_three_classes_and_exits_zero() {
  _box_fixture
  _box_stub_docker
  local out; out="$(cmd_box space)"
  assert_contains "$out" regenerable
  assert_contains "$out" ours
  assert_contains "$out" "$HOME/restore"
  assert_contains "$out" docker
  rm -rf "$T"
}

# The shape is frozen: CEL-45's work views may consume it, and a renamed key
# is a silently empty panel over there rather than an error over here.
test_box_space_json_shape_is_frozen() {
  _box_fixture
  _box_stub_docker
  local json; json="$(cmd_box space --json)"
  printf '%s' "$json" | jq -e '
    (.paths | type == "array" and length > 0 and all(.[];
      (.path | type == "string") and (.class | IN("ours","regenerable","someones"))
      and (.bytes | type == "number") and (.reclaimable | type == "number")
      and (.age_days | type == "number")))
    and (.docker.images.reclaimable | type == "number")
    and (.docker.build_cache.reclaimable | type == "number")' >/dev/null
  rm -rf "$T"
}

# A 15G dump nobody may touch is less interesting than 8.7G of build cache.
test_box_space_sorts_by_reclaimable_not_total() {
  _box_fixture
  _box_stub_docker
  # The untouchable dump is by far the largest thing on this fixture box.
  _box_age_file "$HOME/restore/huge.img" 400
  dd if=/dev/zero of="$HOME/restore/huge.img" bs=1024 count=512 status=none
  touch -d '400 days ago' "$HOME/restore/huge.img"
  local first
  first="$(cmd_box space --json | jq -r '.paths[0].reclaimable as $r
    | if (.paths | all(.[]; .reclaimable <= $r)) then "sorted" else "unsorted" end')"
  assert_eq "$first" sorted
  rm -rf "$T"
}

# Docker absent is a normal box, not a fault.
test_box_space_without_docker_exits_zero_with_no_docker_rows() {
  _box_fixture
  local out; out="$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box space)"
  assert_contains "$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box space --json | jq -r '.docker')" null
  case "$out" in *docker*) printf 'docker rows present with no docker\n' >&2; return 1;; esac
  rm -rf "$T"
}

# --------------------------------------------------------------- the sweepers

# 14 days on images and build cache, because the working set is 3-6 days old
# and superseded build tags are two weeks and older. Nothing depends on a dead
# container, so the container prune carries no age filter at all.
test_docker_sweep_filters_images_and_builder_by_age_but_not_containers() {
  _box_fixture
  _box_stub_docker
  _box_sweep_docker 0 >/dev/null
  local calls; calls="$(cat "$DOCKER_LOG")"
  assert_contains "$(grep 'image prune' "$DOCKER_LOG")" "until=336h"
  assert_contains "$(grep 'builder prune' "$DOCKER_LOG")" "until=336h"
  case "$(grep 'container prune' "$DOCKER_LOG")" in
    *until=*) printf 'container prune carried an age filter\n' >&2; return 1;;
    '') printf 'container prune never ran\n' >&2; return 1;;
  esac
  assert_contains "$calls" prune
  rm -rf "$T"
}

# Re-pulling a 13M base to save nothing is a bad trade, however old it is.
test_docker_sweep_keeps_base_images_regardless_of_age() {
  _box_fixture
  _box_stub_docker
  _box_sweep_docker 0 >/dev/null
  local removals; removals="$(_box_prune_calls)"
  for keep in aaa bbb ccc; do
    case "$removals" in *"$keep"*) printf 'keep-listed image %s was in a removal argv\n' "$keep" >&2; return 1;; esac
  done
  assert_contains "$removals" ddd
  rm -rf "$T"
}

# There is no "prune and report" path: --dry-run means the stub records
# nothing that could remove anything, and still produces a byte count.
test_docker_sweep_dry_run_produces_bytes_and_zero_removals() {
  _box_fixture
  _box_stub_docker
  local bytes; bytes="$(_box_sweep_docker 1)"
  case "$bytes" in ''|*[!0-9]*) printf 'dry run produced no byte count: [%s]\n' "$bytes" >&2; return 1;; esac
  [ "$bytes" -gt 0 ] || { printf 'dry run reported zero reclaimable\n' >&2; return 1; }
  assert_eq "$(_box_prune_calls)" ""
  rm -rf "$T"
}

# Never remove a cache root itself, only entries inside it: a missing root is
# a tool that reinstalls itself rather than a cache that refills.
test_cache_sweep_takes_aged_entries_and_leaves_fresh_ones_and_the_root() {
  _box_fixture
  _box_sweep_caches 0 >/dev/null
  [ -d "$HOME/.bun/install/cache" ] || { printf 'cache root removed\n' >&2; return 1; }
  [ -e "$HOME/.bun/install/cache/fresh-package" ] || { printf 'fresh entry removed\n' >&2; return 1; }
  [ -e "$HOME/.bun/install/cache/old-package" ] && { printf 'aged entry kept\n' >&2; return 1; }
  assert_contains "$(cat "$CEL_BOX_RM_LOG")" "$HOME/.bun/install/cache/old-package"
  rm -rf "$T"
}

test_cache_sweep_dry_run_produces_bytes_and_removes_nothing() {
  _box_fixture
  local bytes; bytes="$(_box_sweep_caches 1)"
  case "$bytes" in ''|*[!0-9]*) printf 'dry run produced no byte count: [%s]\n' "$bytes" >&2; return 1;; esac
  [ "$bytes" -gt 0 ] || { printf 'dry run reported zero bytes\n' >&2; return 1; }
  [ -e "$HOME/.bun/install/cache/old-package" ] || { printf 'dry run removed an entry\n' >&2; return 1; }
  assert_eq "$(cat "$CEL_BOX_RM_LOG")" ""
  rm -rf "$T"
}

test_ours_sweep_takes_aged_cel_scratch() {
  _box_fixture
  _box_sweep_ours 0 >/dev/null
  [ -d "$HOME/.cache/cel" ] || { printf 'cel cache root removed\n' >&2; return 1; }
  [ -e "$HOME/.cache/cel/old-scratch" ] && { printf 'aged cel scratch kept\n' >&2; return 1; }
  rm -rf "$T"
}

# THE RULE THIS TICKET ENCODES. A sweeper may delete only what the box can
# make again; everything else is a number on a report.
test_someones_path_is_never_in_any_sweeper_argv_under_any_flag() {
  _box_fixture
  _box_stub_docker
  local dry
  for dry in 0 1; do
    _box_sweep_docker "$dry" >/dev/null
    _box_sweep_caches "$dry" >/dev/null
    _box_sweep_ours "$dry" >/dev/null
    box_sweep "$dry" >/dev/null
  done
  case "$(cat "$CEL_BOX_RM_LOG")" in
    *"$HOME/restore"*) printf 'a sweeper took a class-three path\n' >&2; return 1;;
  esac
  [ -e "$HOME/restore/profile-dump.tar" ] || { printf 'the dump is gone\n' >&2; return 1; }
  rm -rf "$T"
}

# A sweeper never takes a path from argv: there must be no call shape that
# points one at a home directory by mistake.
test_no_sweeper_accepts_a_path_argument() {
  _box_fixture
  _box_sweep_caches 0 "$HOME/restore" >/dev/null 2>&1 || true
  _box_sweep_ours 0 "$HOME/restore" >/dev/null 2>&1 || true
  [ -e "$HOME/restore/profile-dump.tar" ] || { printf 'an argv path was swept\n' >&2; return 1; }
  rm -rf "$T"
}

# A class that found nothing says so, rather than vanishing: "did it run?"
# must never be a question a summary leaves open.
test_box_sweep_names_every_class_including_the_empty_ones() {
  _box_fixture
  local out; out="$(CEL_BOX_DOCKER=cel-no-such-docker box_sweep 1)"
  assert_contains "$out" caches
  assert_contains "$out" ours
  assert_contains "$out" "docker"
  assert_contains "$out" skipped
  rm -rf "$T"
}

# A full disk should be diagnosed before it is a build failure - and the
# finding names the command that clears it, not just the problem.
test_doctor_line_fires_below_the_floor_and_names_the_remedy() {
  _box_fixture
  _box_stub_docker
  local line
  line="$(CEL_BOX_FREE_FLOOR_GB=999999 box_doctor_line)"
  assert_contains "$line" "cel gc --box"
  assert_eq "$(CEL_BOX_FREE_FLOOR_GB=0 box_doctor_line)" ""
  rm -rf "$T"
}

# ------------------------------------------------------------- the reviewers
# 3 GB of idle reviewer panes was a bigger number than most of the disk rows
# above it, and it was invisible: the report measured the floor and never the
# agents standing on it.
_box_reviewer_rows() {
  export CEL_REVIEWERS_STATE="$T/reviewers.json"
  reviewers_record widget 71 w1:p3 widget-pr-71-review
  # Both calls this makes are stubbed: an empty roster so discovery cannot
  # reach the live box, and one readable process for the recorded pane.
  herdr() {
    case "$1 $2" in
      "agent list") jq -n '{result:{agents:[]}}';;
      *) jq -n --argjson pid "$$" '{result:{process_info:{foreground_processes:[{pid:$pid}]}}}';;
    esac
  }
}

test_box_space_reports_reviewer_panes_and_their_rss() {
  _box_fixture
  _box_reviewer_rows
  local json; json="$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box space --json)"
  assert_eq "$(printf '%s' "$json" | jq -r '.reviewers.count')" 1
  [ "$(printf '%s' "$json" | jq -r '.reviewers.bytes')" -gt 0 ] \
    || { printf 'a live reviewer pane measured as zero RSS\n' >&2; return 1; }
  assert_contains "$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box space)" reviewers
  unset -f herdr
  rm -rf "$T"
}

# None is a number, not an absent row: "did it look?" must never be a question
# the report leaves open.
test_box_space_reports_zero_reviewers_cleanly() {
  _box_fixture
  export CEL_REVIEWERS_STATE="$T/reviewers.json"
  # An empty roster, deliberately: without this stub the discovery below
  # reads the LIVE box's reviewer panes and the fixture's "none" is whatever
  # the machine happens to be running (it found seven the first time).
  herdr() { jq -n '{result:{agents:[]}}'; }
  local json; json="$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box space --json)"
  assert_eq "$(printf '%s' "$json" | jq -r '.reviewers.count')" 0
  assert_eq "$(printf '%s' "$json" | jq -r '.reviewers.bytes')" 0
  assert_contains "$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box space)" "0 reviewer panes"
  unset -f herdr
  rm -rf "$T"
}

# The report counts the panes that are THERE, not the ones that were written
# down: the seven that produced this ticket predated the registry entirely.
test_box_space_counts_an_unrecorded_reviewer_pane_too() {
  _box_fixture
  export CEL_REVIEWERS_STATE="$T/reviewers.json"
  herdr() {
    case "$1 $2" in
      "agent list") jq -n '{result:{agents:[{name:"widget-pr-71-review",pane_id:"w1:p3",cwd:"/w/repos/widget",agent_status:"idle"}]}}';;
      *) jq -n --argjson pid "$$" '{result:{process_info:{foreground_processes:[{pid:$pid}]}}}';;
    esac
  }
  local json; json="$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box space --json)"
  assert_eq "$(printf '%s' "$json" | jq -r '.reviewers.count')" 1
  unset -f herdr
  rm -rf "$T"
}
