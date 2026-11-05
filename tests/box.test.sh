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
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CONFIG_HOME="$HOME/.config" CEL_PROC="$T/proc"
  unset CEL_BOX_DOCKER_KEEP_FILE
  mkdir -p "$CEL_PROC"
  export CEL_BOX_RM_LOG="$T/removed"
  : > "$CEL_BOX_RM_LOG"
  # regenerable: costs a re-download, never data
  mkdir -p "$HOME/.bun/install/cache" "$HOME/.npm/_cacache" "$HOME/.cache/uv"
  # ours: the factory made it
  mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/cel" "${XDG_STATE_HOME:-$HOME/.local/state}/cel/scratch"
  # someone's: large, irreplaceable, NOT the janitor's
  mkdir -p "$HOME/restore"
  _box_age_file "$HOME/.bun/install/cache/old-package" 60
  _box_age_file "$HOME/.bun/install/cache/fresh-package" 1
  _box_age_file "${XDG_CACHE_HOME:-$HOME/.cache}/cel/old-scratch" 60
  _box_age_file "$HOME/restore/profile-dump.tar" 400
  BOX_STUB_BIN="$T/bin"
  mkdir -p "$BOX_STUB_BIN"
  DOCKER_LOG="$T/docker.argv"
  : > "$DOCKER_LOG"
  # AND THE ROSTER, for every test in this file rather than the few that
  # think about it. `cel box space` and `box_doctor_line` ask herdr which
  # panes are reviewers; without this stub each of them reads the LIVE box's
  # agents, which is the convention this suite exists to keep. A test that
  # wants a roster with something in it overrides this after the fixture.
  export CEL_REVIEWERS_STATE="$T/reviewers.json"
  herdr() { jq -n '{result:{agents:[]}}'; }
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
  "container ls") ;;
  "image inspect")
    repo=widget; tag=build-91; size=1200000000
    case "\$3" in
      sha256:aaa) repo=ubuntu; tag=24.04; size=78000000 ;;
      sha256:bbb) repo=alpine; tag=3.19; size=13000000 ;;
      sha256:ccc) repo=ghcr.io/alpha/bundle; tag=base; size=210000000 ;;
    esac
    printf '[{"Id":"%s","RepoTags":["%s:%s"],"Size":%s,"Config":{"Labels":null}}]\n' "\$3" "\$repo" "\$tag" "\$size"
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

# The shape is frozen: other views consume it, and a renamed key is a
# silently empty panel there rather than an error here.
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

# Every unused image and all build cache under --box, and never a
# container or volume prune - a stopped container's image stays.
test_docker_sweep_prunes_all_build_cache_and_never_containers_or_volumes() {
  _box_fixture
  _box_stub_docker
  _box_sweep_docker 0 >/dev/null
  assert_contains "$(grep 'builder prune' "$DOCKER_LOG")" "--all"
  case "$(cat "$DOCKER_LOG")" in
    *"container prune"*|*volume*) printf 'touched containers or volumes\n' >&2; return 1;;
  esac
  rm -rf "$T"
}

# Re-pulling a 13M base to save nothing is a bad trade, however old it is.
test_docker_sweep_keeps_base_images_regardless_of_age() {
  _box_fixture
  _box_stub_docker
  _box_sweep_docker 0 >/dev/null
  local removals; removals="$(_box_prune_calls)"
  for keep in aaa bbb; do
    case "$removals" in *"$keep"*) printf 'keep-listed image %s was in a removal argv\n' "$keep" >&2; return 1;; esac
  done
  assert_contains "$removals" ddd
  # An empty {{.Parent}} is no reason to keep - BuildKit images all have one.
  assert_contains "$removals" ccc
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
  [ -d "${XDG_CACHE_HOME:-$HOME/.cache}/cel" ] || { printf 'cel cache root removed\n' >&2; return 1; }
  [ -e "${XDG_CACHE_HOME:-$HOME/.cache}/cel/old-scratch" ] && { printf 'aged cel scratch kept\n' >&2; return 1; }
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
# Idle reviewer panes are reported alongside the disk rows.
_box_reviewer_rows() {
  reviewers_record widget 71 w1:p3 widget-pr-71-review
  # An empty roster still (discovery must not reach the live box), plus one
  # readable process for the recorded pane.
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
  local json; json="$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box space --json)"
  assert_eq "$(printf '%s' "$json" | jq -r '.reviewers.count')" 0
  assert_eq "$(printf '%s' "$json" | jq -r '.reviewers.bytes')" 0
  assert_contains "$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box space)" "0 reviewer panes"
  rm -rf "$T"
}

# The report counts the panes that are THERE, not the ones that were written
# down: the seven that produced this ticket predated the registry entirely.
test_box_space_counts_an_unrecorded_reviewer_pane_too() {
  _box_fixture
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

test_box_rex_reviewer_rss_uses_the_roster_pid_not_herdr() {
  _box_fixture
  cel_agent_list() {
    jq -n --argjson pid "$$" '{result:{agents:[{name:"widget-pr-71-review",pane_id:"rex/session:fixture/block:fixture",cwd:"/w/repos/widget",agent_status:"idle",backend:"rex",pid:$pid}]}}'
  }
  herdr() { printf '%s\n' "$*" >> "$T/herdr-calls"; return 1; }
  local json; json="$(box_reviewers_json)"
  assert_eq "$(printf '%s' "$json" | jq -r .count)" 1
  [ "$(printf '%s' "$json" | jq -r .bytes)" -gt 0 ] || { echo 'Rex reviewer RSS was not measured'; return 1; }
  [ ! -s "$T/herdr-calls" ] || { echo 'Rex reviewer was sent to Herdr'; return 1; }
  rm -rf "$T"
}

# NEVER TOUCH THE LIVE BOX. box_reviewers_json asks the roster which panes
# are reviewers, so every test that reaches cmd_box space or box_doctor_line
# reads the live herdr unless the fixture itself stubs it - and most of the
# tests above predate that call and never stubbed anything. The stub belongs
# in the fixture, not in the three tests that happened to notice.
test_box_fixture_stubs_the_roster_so_no_test_reads_the_live_one() {
  _box_fixture
  assert_eq "$(type -t herdr)" function
  assert_eq "$(herdr agent list | jq -r '.result.agents | length')" 0
  assert_eq "$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box space --json | jq -r '.reviewers.count')" 0
  rm -rf "$T"
}

# ------------------------------------------------------------- the diagnosis

# A fixture /proc as well as a fixture home: `cel box diag` walks every
# process, and a docker build running on the box the suite runs on must not
# turn up in a fixture's output.
_box_diag_fixture() {
  _box_fixture
  export CEL_PROC="$T/proc"
  export CEL_REX_STATE="$T/rex"
  mkdir -p "$CEL_PROC" "$CEL_REX_STATE"
}

_box_fake_proc() { # <pid> <ppid> <cwd|-> <space-separated environ|-> <argv...>
  local pid="$1" ppid="$2" cwd="$3" env="$4" d
  shift 4
  d="$CEL_PROC/$pid"
  mkdir -p "$d"
  printf 'Name:\tx\nPPid:\t%s\n' "$ppid" > "$d/status"
  printf '%s\0' "$@" > "$d/cmdline"
  # shellcheck disable=SC2086 # one environ entry per word, on purpose
  [ "$env" = - ] || printf '%s\0' $env > "$d/environ"
  if [ "$cwd" != - ]; then mkdir -p "$cwd"; ln -s "$cwd" "$d/cwd"; fi
}

test_box_diag_summarises_docker_images_build_cache_and_volumes() {
  _box_diag_fixture
  _box_stub_docker
  local out; out="$(cmd_box diag)"
  assert_eq "$out" "docker: images 41.2 GB (8.7 GB reclaimable), build cache 8.7 GB (8.7 GB reclaimable), volumes 1.0 GB (0 B reclaimable)
docker builds: none running"
  assert_contains "$(cat "$DOCKER_LOG")" "system df --format json"
  rm -rf "$T"
}

# No docker is a normal box: nothing is said and the alert carries on.
test_box_diag_without_docker_says_nothing_and_exits_zero() {
  _box_diag_fixture
  local out; out="$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box diag 2>&1)"
  assert_eq "$out" ""
  rm -rf "$T"
}

# A user outside the docker group gets docker's "permission denied" on the
# socket; the diagnosis neither repeats it nor reports a zero store.
test_box_diag_skips_a_docker_this_user_cannot_query() {
  _box_diag_fixture
  cat > "$BOX_STUB_BIN/docker" <<'EOS'
#!/usr/bin/env bash
echo 'permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock' >&2
exit 1
EOS
  chmod +x "$BOX_STUB_BIN/docker"
  PATH="$BOX_STUB_BIN:$PATH"
  local out; out="$(cmd_box diag 2>&1)"
  assert_eq "$out" ""
  rm -rf "$T"
}

# An alert is waiting on this line; a hung daemon must not hold it.
test_box_diag_bounds_a_hung_docker_with_its_timeout() {
  _box_diag_fixture
  cat > "$BOX_STUB_BIN/docker" <<'EOS'
#!/usr/bin/env bash
exec sleep 30
EOS
  chmod +x "$BOX_STUB_BIN/docker"
  PATH="$BOX_STUB_BIN:$PATH"
  local start=$SECONDS out
  out="$(CEL_BOX_DIAG_TIMEOUT=1 cmd_box diag 2>&1)"
  assert_eq "$out" ""
  [ $((SECONDS - start)) -lt 10 ] || { printf 'diag took %ss behind a hung docker\n' "$((SECONDS - start))" >&2; return 1; }
  rm -rf "$T"
}

test_box_diag_recognises_build_spellings_and_nothing_else() {
  _box_is_docker_build docker build -t img .
  _box_is_docker_build /usr/bin/docker --context ci build .
  _box_is_docker_build docker image build .
  _box_is_docker_build docker builder build .
  _box_is_docker_build docker buildx --builder ci build .
  _box_is_docker_build docker buildx bake
  _box_is_docker_build /usr/libexec/docker/cli-plugins/docker-buildx buildx build .
  assert_fails _box_is_docker_build docker ps
  assert_fails _box_is_docker_build docker buildx ls
  assert_fails _box_is_docker_build docker run build
  assert_fails _box_is_docker_build bash -c 'docker build .'
}

# The owner comes from the pane the build's process tree inherited (its own
# environment, else its parents'), then from the agent whose cwd contains it,
# said as an inference; the plugin child of a `docker build` is the same build.
test_box_diag_names_running_builds_with_their_owning_agent() {
  _box_diag_fixture
  _box_stub_docker
  herdr() {
    jq -n --arg a "$T/wt/alpha" --arg b "$T/wt/beta" --arg root "$T" '{result:{agents:[
      {name:"worker-alpha", pane_id:"wA:p1", cwd:$a},
      {name:"worker-beta", pane_id:"wA:p2", cwd:$b},
      {name:"rex-worker", pane_id:"rex/s1/b2", cwd:($root + "/wt/rex")},
      {name:"core", pane_id:"wA:p0", cwd:$root}]}}'
  }
  # worker-alpha's runtime -> its shell -> a build with no readable environ,
  # standing in beta's directory: the inherited pane wins over the cwd.
  _box_fake_proc 100 1 "$T/wt/alpha" "HERDR_PANE_ID=wA:p1 PATH=/bin" pi
  _box_fake_proc 101 100 "$T/wt/alpha" "HERDR_PANE_ID=wA:p1" bash -c 'docker buildx build -t img .'
  _box_fake_proc 102 101 "$T/wt/beta/sub" - docker buildx build -t img .
  _box_fake_proc 103 102 "$T/wt/beta/sub" - /usr/libexec/docker/cli-plugins/docker-buildx buildx build -t img .
  # no pane anywhere up the tree: the closest containing agent cwd, not core's
  _box_fake_proc 200 1 "$T/wt/beta" - docker build .
  # a pane nobody in the roster owns, and a cwd that cannot be read
  _box_fake_proc 400 1 - "HERDR_PANE_ID=wZ:p9" docker --context ci build .
  # a Rex session's pane
  _box_fake_proc 500 1 "$T/wt/rex" "REX_SESSION=s1 REX_BLOCK=b2" docker image build .
  # not a build
  _box_fake_proc 300 1 "$T/wt/alpha" "HERDR_PANE_ID=wA:p1" docker ps
  local builds; builds="$(cmd_box diag | sed -n 2p)"
  assert_contains "$builds" "docker builds: 4 running - "
  assert_contains "$builds" "pid 102 agent=worker-alpha cwd=$T/wt/beta/sub: docker buildx build -t img ."
  assert_contains "$builds" "pid 200 agent=worker-beta (by cwd) cwd=$T/wt/beta: docker build ."
  assert_contains "$builds" "pid 400 agent=? pane=wZ:p9 cwd=?: docker --context ci build ."
  assert_contains "$builds" "pid 500 agent=rex-worker cwd=$T/wt/rex: docker image build ."
  case "$builds" in *"pid 103"*|*"pid 101"*|*"docker ps"*) printf 'listed a non-build or a plugin child: %s\n' "$builds" >&2; return 1;; esac
  rm -rf "$T"
}

# Forty parallel builds are one fact: five named, argv cut short, the rest counted.
test_box_diag_bounds_the_builds_line() {
  _box_diag_fixture
  local i long; long="$(printf 'A%.0s' {1..300})"
  for i in 11 12 13 14 15 16 17 18; do
    _box_fake_proc "$i" 1 - - docker build --tag "$long" .
  done
  local out; out="$(CEL_BOX_DOCKER=cel-no-such-docker cmd_box diag)"
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1
  assert_contains "$out" "docker builds: 8 running - pid 11 agent=? cwd=?: docker build --tag AAA"
  assert_contains "$out" "...; pid 12 "
  assert_contains "$out" "; +3 more"
  case "$out" in *"pid 16 "*) printf 'named more than five builds\n' >&2; return 1;; esac
  [ "${#out}" -lt 1000 ] || { printf 'builds line is %s characters\n' "${#out}" >&2; return 1; }
  rm -rf "$T"
}

# The line goes into a mailbox: no build secret may ride along in it.
test_box_diag_redacts_secret_values_from_build_argv() {
  _box_diag_fixture
  # Two builds, so each redacted argv stays under the 120-character cut and
  # truncation can never be what hides a value.
  _box_fake_proc 21 1 - - docker buildx build --build-arg TOKEN=s3cr3t-a --build-arg=NPM=s3cr3t-b \
    --secret id=npm,src=/run/s3cr3t-c --secret=s3cr3t-d .
  _box_fake_proc 22 1 - - docker build -e API=s3cr3t-e --env=s3cr3t-f \
    --env s3cr3t-g PASSWORD=s3cr3t-h -t img:latest .
  local out; out="$(CEL_BOX_DOCKER=cel-no-such-docker CEL_BOX_DIAG_TIMEOUT=1 cmd_box diag)"
  case "$out" in *s3cr3t*) printf 'a secret reached the diagnosis: %s\n' "$out" >&2; return 1;; esac
  assert_contains "$out" "pid 21 agent=? cwd=?: docker buildx build --build-arg TOKEN=*** --build-arg=NPM=*** --secret id=*** --secret=*** .;"
  assert_contains "$out" "pid 22 agent=? cwd=?: docker build -e API=*** --env=*** --env *** PASSWORD=*** -t img:latest ."
  rm -rf "$T"
}

# A herdr that hangs must not hold the alert: the lookup is bounded, and the
# build is still named by the pane its tree inherited.
test_box_diag_bounds_a_hung_herdr_and_falls_back_to_the_pane() {
  _box_diag_fixture
  unset -f herdr
  cat > "$BOX_STUB_BIN/herdr" <<'EOS'
#!/usr/bin/env bash
exec sleep 30
EOS
  chmod +x "$BOX_STUB_BIN/herdr"
  PATH="$BOX_STUB_BIN:$PATH"
  _box_fake_proc 31 1 "$T/wt/alpha" "HERDR_PANE_ID=wA:p1" docker build .
  local start=$SECONDS out
  out="$(CEL_BOX_DOCKER=cel-no-such-docker CEL_BOX_DIAG_TIMEOUT=1 cmd_box diag 2>&1)"
  [ $((SECONDS - start)) -lt 10 ] || { printf 'diag took %ss behind a hung herdr\n' "$((SECONDS - start))" >&2; return 1; }
  assert_eq "$out" "docker builds: 1 running - pid 31 agent=? pane=wA:p1 cwd=$T/wt/alpha: docker build ."
  rm -rf "$T"
}

test_box_diag_takes_no_arguments() {
  _box_diag_fixture
  if (cmd_box diag --json) >/dev/null 2>&1; then printf 'diag accepted an argument\n' >&2; return 1; fi
  rm -rf "$T"
}

# Containerless labelled base, configured rollback alias, seeded local base,
# actual stopped-container ID, and one disposable image. This is a real sweep
# consumer, not a test of just the pattern-matching helper.
_box_retention_fixture() {
  _box_fixture
  export DOCKER_LOG BOX_DOCKER_IMAGES="$T/images.json" BOX_DOCKER_FAIL="" BOX_DOCKER_LATE="" BOX_DOCKER_STATE="$T/state"
  mkdir -p "$BOX_DOCKER_STATE" "$HOME/.config/cel"
  printf '%s\n' 'retained/release:rollback-*' > "$HOME/.config/cel/docker-keep-patterns"
  cat > "$BOX_DOCKER_IMAGES" <<'EOS'
[
 {"Id":"sha256:aaa","RepoTags":["private/base:local","private/base:alias"],"Size":1,"Config":{"Labels":{"cel.keep":"true"}}},
 {"Id":"sha256:bbb","RepoTags":["build:old","retained/release:rollback-42"],"Size":1,"Config":{"Labels":null}},
 {"Id":"sha256:ccc","RepoTags":["slot-studio-media-executor-base:local","ordinary:alias"],"Size":1,"Config":{"Labels":null}},
 {"Id":"sha256:ddd","RepoTags":["disposable:old"],"Size":1,"Config":{"Labels":null}},
 {"Id":"sha256:eee","RepoTags":["moved:old"],"Size":1,"Config":{"Labels":null}},
 {"Id":"sha256:fff","RepoTags":["slot-studio-local/media-executor:rollback-42"],"Size":1,"Config":{"Labels":null}}
]
EOS
  cat > "$BOX_STUB_BIN/docker" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1 $2" in
  "system df") printf '%s\n' '{"Type":"Images","Size":"6B","Reclaimable":"1B"}' '{"Type":"Build Cache","Size":"0B","Reclaimable":"0B"}' ;;
  "container ls")
    [ "$BOX_DOCKER_FAIL" != container-ls ] || exit 1
    printf '%s\n' stopped
    if [ -e "$BOX_DOCKER_STATE/listed" ] && [ "$BOX_DOCKER_LATE" = container ]; then printf '%s\n' new-container; fi ;;
  "container inspect")
    [ "$BOX_DOCKER_FAIL" != container-inspect ] || exit 1
    if [ "$3" = stopped ]; then printf '[{"Image":"sha256:eee"}]\n'; else printf '[{"Image":"sha256:ddd"}]\n'; fi ;;
  "image ls")
    [ "$BOX_DOCKER_FAIL" != image-ls ] || exit 1
    [ "$BOX_DOCKER_FAIL" != image-json ] || { printf 'broken JSON\n'; exit 0; }
    if [ -e "$BOX_DOCKER_STATE/listed" ]; then
      case "$BOX_DOCKER_LATE" in
        label) jq 'map(if .Id == "sha256:ddd" then .Config.Labels={"cel.keep":"true"} else . end)' "$BOX_DOCKER_IMAGES" > "$BOX_DOCKER_IMAGES.next"; mv "$BOX_DOCKER_IMAGES.next" "$BOX_DOCKER_IMAGES" ;;
        tag) jq 'map(if .Id == "sha256:ddd" then .RepoTags += ["retained/release:rollback-new"] else . end)' "$BOX_DOCKER_IMAGES" > "$BOX_DOCKER_IMAGES.next"; mv "$BOX_DOCKER_IMAGES.next" "$BOX_DOCKER_IMAGES" ;;
        inspect) exit 1 ;;
      esac
    fi
    touch "$BOX_DOCKER_STATE/listed"
    jq -c '.[] | {ID:.Id}' "$BOX_DOCKER_IMAGES" ;;
  "image inspect")
    [ "$BOX_DOCKER_FAIL" != image-inspect ] || exit 1
    if [ "$BOX_DOCKER_FAIL" = labels ]; then
      jq -c --arg id "$3" '[.[] | select(.Id == $id) | .Config.Labels={"cel.keep":42}]' "$BOX_DOCKER_IMAGES"
    else jq -c --arg id "$3" '[.[] | select(.Id == $id)]' "$BOX_DOCKER_IMAGES"; fi ;;
  "image rm") [ "$3" = sha256:ddd ] || exit 89 ;;
  "builder prune") printf 'Total reclaimed space: 0B\n' ;;
  *) exit 90 ;;
esac
EOS
  chmod +x "$BOX_STUB_BIN/docker"
  export CEL_BOX_DOCKER="$BOX_STUB_BIN/docker"
}

test_docker_retention_containerless_label_and_configured_rollback_survive() {
  _box_retention_fixture
  cmd_box sweep-docker >/dev/null
  assert_eq "$(grep 'image rm' "$DOCKER_LOG")" 'image rm sha256:ddd'
  case "$(_box_prune_calls)" in *'image prune'*|*'system prune'*|*'image rm --force'*) return 1 ;; esac
  rm -rf "$T"
}

test_docker_retention_unknown_inspection_and_inventory_refuse_all_mutation() {
  local failure rc
  for failure in image-ls image-json image-inspect labels container-ls container-inspect; do
    _box_retention_fixture
    export BOX_DOCKER_FAIL="$failure"
    rc=0; cmd_box sweep-docker >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || { printf 'accepted unknown %s\n' "$failure" >&2; return 1; }
    assert_eq "$(_box_prune_calls)" ''
    rm -rf "$T"
  done
}

test_docker_retention_unreadable_and_missing_declarations_refuse_mutation() {
  local declaration rc
  for declaration in missing directory malformed dangling; do
    _box_retention_fixture
    export CEL_BOX_DOCKER_KEEP_FILE="$T/$declaration"
    case "$declaration" in
      directory) mkdir "$CEL_BOX_DOCKER_KEEP_FILE" ;;
      malformed) printf 'not a repo tag\n' > "$CEL_BOX_DOCKER_KEEP_FILE" ;;
      dangling) ln -s "$T/nonexistent" "$CEL_BOX_DOCKER_KEEP_FILE" ;;
    esac
    rc=0; cmd_box sweep-docker >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || return 1
    assert_eq "$(_box_prune_calls)" ''
    rm -rf "$T"
  done
}

test_docker_retention_rechecks_late_tags_labels_and_actual_container_ids() {
  local late
  for late in tag label container; do
    _box_retention_fixture
    export BOX_DOCKER_LATE="$late"
    cmd_box sweep-docker >/dev/null
    assert_eq "$(grep 'image rm' "$DOCKER_LOG" || true)" ''
    rm -rf "$T"
  done
}

test_docker_retention_unknown_recheck_refuses_image_and_cache_mutation() {
  _box_retention_fixture
  export BOX_DOCKER_LATE=inspect
  local rc=0; cmd_box sweep-docker >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || return 1
  assert_eq "$(_box_prune_calls)" ''
  rm -rf "$T"
}

test_docker_retention_live_build_and_unreadable_process_preserve_images() {
  _box_retention_fixture
  mkdir -p "$CEL_PROC/123"
  printf 'docker\0build\0.\0' > "$CEL_PROC/123/cmdline"
  local rc=0; cmd_box sweep-docker >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || return 1
  assert_eq "$(_box_prune_calls)" ''
  rm "$CEL_PROC/123/cmdline"
  rc=0; cmd_box sweep-docker >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || return 1
  assert_eq "$(_box_prune_calls)" ''
  rm -rf "$T"
}

test_docker_retention_producer_lock_excludes_sweep() {
  _box_retention_fixture
  local lock; lock="$(_box_docker_lock_file)"
  mkdir -p "${lock%/*}"
  exec 8>>"$lock"; flock -x 8
  local rc=0; cmd_box sweep-docker >/dev/null 2>&1 || rc=$?
  exec 8>&-
  [ "$rc" -ne 0 ] || return 1
  assert_eq "$(_box_prune_calls)" ''
  cmd_box sweep-docker >/dev/null
  assert_eq "$(grep 'image rm' "$DOCKER_LOG")" 'image rm sha256:ddd'
  rm -rf "$T"
}

test_docker_retention_public_safety_contract_and_dry_run() {
  _box_retention_fixture
  local contract; contract="$(cmd_box docker-safety)"
  assert_eq "$(printf '%s' "$contract" | jq -r '.version')" 1
  assert_eq "$(printf '%s' "$contract" | jq -r '.keep_label')" cel.keep=true
  assert_eq "$(printf '%s' "$contract" | jq -r '.lock_file')" "$(_box_docker_lock_file)"
  assert_eq "$(cmd_box sweep-docker --dry-run)" 1
  assert_eq "$(_box_prune_calls)" ''
  rm -rf "$T"
}

test_docker_retention_docker_omitted_empty_labels_are_known_absent() {
  _box_retention_fixture
  jq 'map(if .Id == "sha256:ddd" then .Config={} else . end)' "$BOX_DOCKER_IMAGES" > "$BOX_DOCKER_IMAGES.next"
  mv "$BOX_DOCKER_IMAGES.next" "$BOX_DOCKER_IMAGES"
  cmd_box sweep-docker >/dev/null
  assert_eq "$(grep 'image rm' "$DOCKER_LOG")" 'image rm sha256:ddd'
  rm -rf "$T"
}
