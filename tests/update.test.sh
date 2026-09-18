# shellcheck shell=bash
# `cel update` is the one command that rewrites the plane under a running box,
# so every test here works on a throwaway git repo standing in for CEL_ROOT -
# never the live checkout. The fixture carries an origin with three release
# tags AND a main tip that is ahead of the newest tag, because "update lands
# on the tag, not on main" is the whole point of the command.
source "$CEL_ROOT/lib/common.sh"

_UPD_REPO="$CEL_ROOT" # the real plane, captured before CEL_ROOT is moved
source "$_UPD_REPO/lib/update.sh"

_upd_fixture() { # -> sets T, ROOT, ORIGIN, LOG and points CEL_ROOT at the fake
  T="$(mktemp -d)"
  ORIGIN="$T/origin.git"
  ROOT="$T/root"
  LOG="$T/log"
  : >"$LOG"
  git init -q --bare "$ORIGIN"
  git init -q -b main "$ROOT"
  git -C "$ROOT" config user.email t@example.com
  git -C "$ROOT" config user.name tester
  cat >"$ROOT/CHANGELOG.md" <<'EOS'
# Changelog

## [0.3.0] - 2026-01-03

### Added
- gadget mode arrives

## [0.2.0] - 2026-01-02

### Added
- widget mode arrives

## [0.1.0] - 2026-01-01

### Added
- alpha groundwork
EOS
  printf '0.1.0\n' >"$ROOT/VERSION"
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -qm 'release 0.1.0'
  git -C "$ROOT" tag v0.1.0
  printf '0.2.0\n' >"$ROOT/VERSION"
  git -C "$ROOT" commit -qam 'release 0.2.0'
  git -C "$ROOT" tag v0.2.0
  printf '0.3.0\n' >"$ROOT/VERSION"
  git -C "$ROOT" commit -qam 'release 0.3.0'
  git -C "$ROOT" tag v0.3.0
  # unreleased work on main, ahead of the newest tag - with the CHANGELOG
  # note that goes with it, because "what is new on main" is the question the
  # commit subjects alone only half answer
  printf 'later\n' >"$ROOT/UNRELEASED"
  awk 'NR==2{print "\n## [Unreleased]\n\n### Added\n- sanding the gadget"} {print}' \
    "$ROOT/CHANGELOG.md" >"$ROOT/CHANGELOG.new"
  mv "$ROOT/CHANGELOG.new" "$ROOT/CHANGELOG.md"
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -qm 'after the release'
  git -C "$ROOT" remote add origin "$ORIGIN"
  git -C "$ROOT" push -q origin main --tags
  git -C "$ROOT" reset -q --hard v0.1.0 # the installed box sits at v0.1.0
  export CEL_ROOT="$ROOT"
  export CEL_UPDATE_DIR="$T/updatestate"
  # EVERY box-level path is isolated here, in the base fixture, not only in
  # the channel one: the box this suite runs on is itself on the main
  # channel since 2026-09-18, and three release-channel tests started
  # reporting "main is 3 commits ahead" because they read the real config.
  # An absent config file is the release channel; an absent registry has no
  # workspaces to post to.
  export CEL_CONFIG_FILE="$T/config.yaml" CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  # The two side effects are what the tests watch; the real ones re-link the
  # box and shell out to doctor, neither of which belongs in a unit test.
  _update_reapply() { printf 'reapply\n' >>"$LOG"; }
  _update_verify() {
    printf 'verify\n' >>"$LOG"
    return "${VERIFY_RC:-0}"
  }
}
_upd_cleanup() {
  CEL_ROOT="$_UPD_REPO"
  unset CEL_CONFIG_FILE CEL_REGISTRY CEL_INBOX_DIR CEL_INBOX_ME
  rm -rf "$T"
}

# A developer's checkout is mutated with git, by hand. `cel update` refusing to
# touch it is what keeps the two audiences from destroying each other's work.
test_update_refuses_a_dirty_tree_and_a_branch_that_is_not_main() {
  _upd_fixture
  local out rc

  printf 'wip\n' >"$ROOT/scratch"
  rc=0
  out="$(cmd_update 2>&1)" || rc=$?
  assert_eq "$rc" 1 || {
    _upd_cleanup
    return 1
  }
  assert_contains "$out" 'uncommitted' || {
    _upd_cleanup
    return 1
  }

  # --check is read-only, so it works on exactly the tree that update refuses
  rc=0
  out="$(cmd_update --check 2>&1)" || rc=$?
  assert_contains "$out" 'available v0.3.0' || {
    _upd_cleanup
    return 1
  }

  rm -f "$ROOT/scratch"
  git -C "$ROOT" checkout -q -b side
  rc=0
  out="$(cmd_update 2>&1)" || rc=$?
  assert_eq "$rc" 1 || {
    _upd_cleanup
    return 1
  }
  assert_contains "$out" 'side' || {
    _upd_cleanup
    return 1
  }
  rc=0
  out="$(cmd_update --check 2>&1)" || rc=$?
  assert_contains "$out" 'installed v0.1.0' || {
    _upd_cleanup
    return 1
  }

  _upd_cleanup
}

# --check is the thing a script tests and a human reads: exit 1 means behind,
# and the changelog it prints is only what you have not got yet.
test_update_check_prints_only_the_newer_changelog_sections() {
  _upd_fixture
  local out rc

  rc=0
  out="$(cmd_update --check 2>&1)" || rc=$?
  assert_eq "$rc" 1 || {
    _upd_cleanup
    return 1
  }
  assert_contains "$out" 'installed v0.1.0, available v0.3.0' || {
    _upd_cleanup
    return 1
  }
  assert_contains "$out" 'gadget mode arrives' || {
    _upd_cleanup
    return 1
  }
  assert_contains "$out" 'widget mode arrives' || {
    _upd_cleanup
    return 1
  }
  case "$out" in *'alpha groundwork'*)
    echo "printed the installed version's own section"
    _upd_cleanup
    return 1
    ;;
  esac

  git -C "$ROOT" reset -q --hard v0.3.0
  rc=0
  out="$(cmd_update --check 2>&1)" || rc=$?
  assert_eq "$rc" 0 || {
    _upd_cleanup
    return 1
  }
  assert_contains "$out" 'up to date at v0.3.0' || {
    _upd_cleanup
    return 1
  }
  case "$out" in *'run: cel update'* | *'run cel update'*)
    echo "told a current box to update"
    _upd_cleanup
    return 1
    ;;
  esac

  _upd_cleanup
}

# Users track RELEASES. main's tip is where the plane's developer is working
# and is not a build anyone else should be running.
test_update_lands_on_the_release_tag_not_on_main_tip() {
  _upd_fixture
  local out rc before
  before="$(git -C "$ROOT" rev-parse HEAD)"

  rc=0
  out="$(cmd_update 2>&1)" || rc=$?
  assert_eq "$rc" 0 || {
    _upd_cleanup
    return 1
  }
  assert_eq "$(git -C "$ROOT" rev-parse HEAD)" "$(git -C "$ROOT" rev-parse 'v0.3.0^{commit}')" || {
    _upd_cleanup
    return 1
  }
  [ -f "$ROOT/UNRELEASED" ] && {
    echo "landed on main's tip, not the tag"
    _upd_cleanup
    return 1
  }
  assert_eq "$(tr -d '[:space:]' <"$CEL_UPDATE_DIR/previous")" "$before" || {
    _upd_cleanup
    return 1
  }
  assert_eq "$(tr '\n' ' ' <"$LOG")" 'reapply verify ' || {
    _upd_cleanup
    return 1
  }

  _upd_cleanup
}

# A red doctor after an update is the exact moment someone needs to be told
# there is a way back, and rollback has to actually re-apply the old build.
test_update_verify_failure_offers_rollback_and_rollback_restores() {
  _upd_fixture
  local out rc before
  before="$(git -C "$ROOT" rev-parse HEAD)"

  rc=0
  out="$(VERIFY_RC=1 cmd_update 2>&1)" || rc=$?
  assert_eq "$rc" 1 || {
    _upd_cleanup
    return 1
  }
  assert_contains "$out" 'cel update --rollback' || {
    _upd_cleanup
    return 1
  }

  : >"$LOG"
  rc=0
  out="$(cmd_update --rollback 2>&1)" || rc=$?
  assert_eq "$rc" 0 || {
    _upd_cleanup
    return 1
  }
  assert_eq "$(git -C "$ROOT" rev-parse HEAD)" "$before" || {
    _upd_cleanup
    return 1
  }
  assert_contains "$(cat "$LOG")" 'reapply' || {
    _upd_cleanup
    return 1
  }

  rm -f "$CEL_UPDATE_DIR/previous"
  rc=0
  out="$(cmd_update --rollback 2>&1)" || rc=$?
  assert_eq "$rc" 1 || {
    _upd_cleanup
    return 1
  }
  _upd_cleanup
}

# An agent that was already running keeps its old role prompt and guard hook
# in memory. Saying so is the difference between a confusing afternoon and a
# restart, and saying nothing when there are none keeps the output honest.
test_update_lists_long_lived_agents_from_the_previous_build() {
  _upd_fixture
  local out rc
  mkdir -p "$T/bin"
  cat >"$T/bin/pgrep" <<EOS
#!/usr/bin/env bash
printf '%s pi --append-system-prompt /tmp/role-worker.md\n' "\$STALE_PID"
EOS
  chmod +x "$T/bin/pgrep"
  rc=0
  out="$(PATH="$T/bin:$PATH" STALE_PID=$$ cmd_update 2>&1)" || rc=$?
  assert_eq "$rc" 0 || {
    _upd_cleanup
    return 1
  }
  assert_contains "$out" 'worker' || {
    _upd_cleanup
    return 1
  }
  assert_contains "$out" 'restart when convenient' || {
    _upd_cleanup
    return 1
  }

  # nothing long-lived: not a word
  git -C "$ROOT" reset -q --hard v0.1.0
  printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/pgrep"
  rc=0
  out="$(PATH="$T/bin:$PATH" cmd_update 2>&1)" || rc=$?
  assert_eq "$rc" 0 || {
    _upd_cleanup
    return 1
  }
  case "$out" in *'restart when convenient'*)
    echo "talked about agents that do not exist"
    _upd_cleanup
    return 1
    ;;
  esac
  _upd_cleanup
}

# The steward is the only thing that checks for a new release on its own, so
# it is also the only thing that can tell the dashboard about one.
test_steward_writes_and_clears_the_available_marker() {
  # The channel fixture, not the bare one: with the box itself on the main
  # channel, an unisolated CEL_CONFIG_FILE made this test follow the REAL
  # config and post "3 new commits" into every real root mailbox on each
  # suite run (measured 2026-09-18, four times in an hour).
  _upd_channel_fixture
  printf 'update:\n  channel: release\n' >"$CEL_CONFIG_FILE"
  source "$_UPD_REPO/lib/steward.sh"
  CEL_ROOT="$ROOT"
  _steward_update_check >/dev/null 2>&1
  assert_eq "$(tr -d '[:space:]' <"$CEL_UPDATE_DIR/available")" '0.3.0' || {
    _upd_cleanup
    return 1
  }

  git -C "$ROOT" reset -q --hard v0.3.0
  _steward_update_check >/dev/null 2>&1
  [ -f "$CEL_UPDATE_DIR/available" ] && {
    echo "marker survived a box that is current"
    _upd_cleanup
    return 1
  }
  _upd_cleanup
}

# The chip is read from disk per request: the steward writes that file hours
# after the dashboard booted, and a dashboard that only reads it at startup
# would never show an update at all.
test_dash_build_chip_reports_an_available_update() {
  local t port pid page
  t="$(mktemp -d)"
  mkdir -p "$t/update"
  printf '0.3.0\n' >"$t/update/available"
  port=$((17420 + RANDOM % 300))
  CEL_DASH_CONFIG='{"name":"alpha","wsdir":"'"$t"'","port":'"$port"',"host":"127.0.0.1","repos":[],"services":[],"build":"v0.1.0 abc1234"}' \
    CEL_UPDATE_DIR="$t/update" CEL_INBOX_DIR="$t/inbox" \
    node "$_UPD_REPO/tools/dash/server.mjs" >"$t/log" 2>&1 &
  pid=$!
  local i ok=1
  for i in $(seq 1 80); do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$port/" && {
      ok=0
      break
    }
    sleep 0.5
  done
  [ "$ok" -eq 0 ] || {
    echo "dash server did not come up: $(cat "$t/log")"
    kill "$pid" 2>/dev/null
    rm -rf "$t"
    return 1
  }

  page="$(curl -s "http://127.0.0.1:$port/")"
  assert_contains "$page" 'update available v0.3.0' || {
    kill "$pid" 2>/dev/null
    rm -rf "$t"
    return 1
  }

  rm -f "$t/update/available"
  page="$(curl -s "http://127.0.0.1:$port/")"
  case "$page" in *'update available'*)
    echo "chip served from a startup snapshot"
    kill "$pid" 2>/dev/null
    rm -rf "$t"
    return 1
    ;;
  esac
  assert_contains "$page" 'v0.1.0 abc1234' || {
    kill "$pid" 2>/dev/null
    rm -rf "$t"
    return 1
  }
  kill "$pid" 2>/dev/null
  rm -rf "$t"
}

# --restart with nothing running must still leave a server up: the steward and
# the updater both call it, and "stop then ensure" has to survive the stop
# being a no-op.
test_dash_restart_is_idempotent_when_nothing_is_running() {
  source "$_UPD_REPO/lib/dash.sh"
  local log
  log="$(mktemp -d)"
  _dash_ensure() { printf 'ensure %s %s\n' "$1" "$2" >>"$log/calls"; }
  _dash_restart alpha 17999 127.0.0.1
  assert_contains "$(cat "$log/calls")" 'ensure alpha 17999'
  local rc=$?
  rm -rf "$log"
  return $rc
}

# --- the channel ------------------------------------------------------------
# Everything that said "you are behind" compared the installed version to the
# newest release TAG, so a box tracking main sat thirty-odd merges past v0.2.0
# and every surface said "up to date". A box that tracks main has to be told
# about COMMITS; a box that tracks releases keeps today's behaviour. Both have
# to say WHAT is new, which is why the fixture's origin carries both tags and
# extra commits on main.
# EVERY box-level path the code under test can reach goes into the fixture.
# Measured while writing this ticket: the steward test below left CEL_REGISTRY
# and CEL_INBOX_DIR alone, so three suite runs posted "3 new commits on
# celestial main" into the real root mailbox of every workspace on the box. A
# test that can write to the live box is a test that will.
_upd_channel_fixture() { # _upd_fixture + box-level config, registry and mailbox
  _upd_fixture
  export CEL_CONFIG_FILE="$T/config.yaml"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  mkdir -p "$T/alpha" "$CEL_INBOX_DIR"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" >"$CEL_REGISTRY"
  printf 'name: alpha\n' >"$T/alpha/workspace.yaml"
}

test_update_check_prints_the_build_and_the_newest_tag_first() {
  _upd_channel_fixture
  local out rc=0
  out="$(cmd_update --check 2>&1)" || rc=$?
  assert_contains "$out" "installed  v0.1.0+0  $(git -C "$ROOT" rev-parse --short HEAD)  (main)" || { _upd_cleanup; return 1; }
  assert_contains "$out" 'newest tag v0.3.0' || { _upd_cleanup; return 1; }
  _upd_cleanup
}

# At the newest tag with main ahead: the RELEASE channel is content, and the
# header still shows how far past the tag this checkout is.
test_update_check_on_release_is_quiet_at_the_tag_while_main_runs_ahead() {
  _upd_channel_fixture
  git -C "$ROOT" fetch -q origin main
  git -C "$ROOT" reset -q --hard origin/main # a commit past v0.3.0
  local out rc=0
  out="$(cmd_update --check 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { _upd_cleanup; return 1; }
  assert_contains "$out" 'installed  v0.3.0+1' || { _upd_cleanup; return 1; }
  assert_contains "$out" 'up to date at v0.3.0' || { _upd_cleanup; return 1; }
  _upd_cleanup
}

test_update_check_on_main_channel_lists_the_commits_and_the_unreleased_notes() {
  _upd_channel_fixture
  printf 'update:\n  channel: main\n' >"$CEL_CONFIG_FILE"
  git -C "$ROOT" reset -q --hard v0.3.0
  # CHANGELOG work that is on origin/main and not here yet
  git -C "$ROOT" fetch -q origin main
  local out rc=0
  out="$(cmd_update --check 2>&1)" || rc=$?
  assert_eq "$rc" 1 || { _upd_cleanup; return 1; }
  assert_contains "$out" 'main is 1 commits ahead:' || { _upd_cleanup; return 1; }
  assert_contains "$out" 'after the release' || { _upd_cleanup; return 1; }
  assert_contains "$out" 'sanding the gadget' || { _upd_cleanup; return 1; }

  # caught up: nothing to say and exit 0
  git -C "$ROOT" reset -q --hard origin/main
  rc=0
  out="$(cmd_update --check 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { _upd_cleanup; return 1; }
  assert_contains "$out" 'up to date with origin/main' || { _upd_cleanup; return 1; }
  _upd_cleanup
}

# The subjects are read oldest first: they are a story of what happened since
# your build, and newest-first makes it unreadable.
test_update_check_on_main_channel_lists_subjects_oldest_first() {
  _upd_channel_fixture
  printf 'update:\n  channel: main\n' >"$CEL_CONFIG_FILE"
  local out first
  out="$(cmd_update --check 2>&1)" || true
  first="$(printf '%s\n' "$out" | grep -n 'release 0.2.0' | cut -d: -f1)"
  local last; last="$(printf '%s\n' "$out" | grep -n 'after the release' | cut -d: -f1)"
  [ -n "$first" ] && [ -n "$last" ] && [ "$first" -lt "$last" ] || {
    echo "subjects are not oldest first: $out"
    _upd_cleanup
    return 1
  }
  _upd_cleanup
}

test_update_on_main_channel_pulls_the_tip_and_records_previous() {
  _upd_channel_fixture
  printf 'update:\n  channel: main\n' >"$CEL_CONFIG_FILE"
  local out rc=0 before
  before="$(git -C "$ROOT" rev-parse HEAD)"
  out="$(cmd_update 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { _upd_cleanup; return 1; }
  git -C "$ROOT" fetch -q origin main
  assert_eq "$(git -C "$ROOT" rev-parse HEAD)" "$(git -C "$ROOT" rev-parse origin/main)" || { _upd_cleanup; return 1; }
  assert_eq "$(tr -d '[:space:]' <"$CEL_UPDATE_DIR/previous")" "$before" || { _upd_cleanup; return 1; }
  assert_eq "$(tr '\n' ' ' <"$LOG")" 'reapply verify ' || { _upd_cleanup; return 1; }

  # and the way back is the same way back
  : >"$LOG"
  rc=0
  out="$(cmd_update --rollback 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { _upd_cleanup; return 1; }
  assert_eq "$(git -C "$ROOT" rev-parse HEAD)" "$before" || { _upd_cleanup; return 1; }

  # a dirty tree is still refused on this channel
  printf 'wip\n' >"$ROOT/scratch"
  rc=0
  out="$(cmd_update 2>&1)" || rc=$?
  assert_eq "$rc" 1 || { _upd_cleanup; return 1; }
  assert_contains "$out" 'uncommitted' || { _upd_cleanup; return 1; }
  _upd_cleanup
}

# The config file holds the console's provider key in another section, so
# anything that creates it creates it unreadable by anyone else.
test_update_channel_flag_writes_the_config_file_0600() {
  _upd_channel_fixture
  local out rc=0
  out="$(cmd_update --channel main 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { _upd_cleanup; return 1; }
  assert_eq "$(stat -c '%a' "$CEL_CONFIG_FILE")" "600" || { _upd_cleanup; return 1; }
  assert_eq "$(cel_config_get update channel)" "main" || { _upd_cleanup; return 1; }

  # writing it again keeps neighbouring sections and flips the value
  printf 'console:\n  provider: widget\nupdate:\n  channel: main\n' >"$CEL_CONFIG_FILE"
  cmd_update --channel release >/dev/null 2>&1 || { _upd_cleanup; return 1; }
  assert_eq "$(cel_config_get update channel)" "release" || { _upd_cleanup; return 1; }
  assert_eq "$(cel_config_get console provider)" "widget" || { _upd_cleanup; return 1; }

  rc=0
  out="$(cmd_update --channel sideways 2>&1)" || rc=$?
  assert_eq "$rc" 1 || { _upd_cleanup; return 1; }
  _upd_cleanup
}

# What the steward writes is what the dashboard chip shows, so on main it has
# to be the distance and the sha rather than a version that has not happened.
test_steward_marks_main_commits_and_clears_when_caught_up() {
  _upd_channel_fixture
  printf 'update:\n  channel: main\n' >"$CEL_CONFIG_FILE"
  source "$_UPD_REPO/lib/steward.sh"
  CEL_ROOT="$ROOT"
  _steward_update_check >/dev/null 2>&1
  assert_contains "$(cat "$CEL_UPDATE_DIR/available")" 'main+3 ' || { _upd_cleanup; return 1; }

  git -C "$ROOT" fetch -q origin main
  git -C "$ROOT" reset -q --hard origin/main
  _steward_update_check >/dev/null 2>&1
  [ -f "$CEL_UPDATE_DIR/available" ] && {
    echo "marker survived a box that is level with main"
    _upd_cleanup
    return 1
  }
  _upd_cleanup
}

# The chip reads whatever is in that file: on main there is no version to show,
# only how far behind this box is and the command that fixes it.
test_dash_build_chip_reports_commits_on_the_main_channel() {
  local t port pid page
  t="$(mktemp -d)"
  mkdir -p "$t/update"
  printf 'main+7 d43910c\n' >"$t/update/available"
  port=$((17820 + RANDOM % 300))
  CEL_DASH_CONFIG='{"name":"alpha","wsdir":"'"$t"'","port":'"$port"',"host":"127.0.0.1","repos":[],"services":[],"build":"v0.1.0 abc1234"}' \
    CEL_UPDATE_DIR="$t/update" CEL_INBOX_DIR="$t/inbox" \
    node "$_UPD_REPO/tools/dash/server.mjs" >"$t/log" 2>&1 &
  pid=$!
  local i ok=1
  for i in $(seq 1 80); do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$port/" && { ok=0; break; }
    sleep 0.5
  done
  [ "$ok" -eq 0 ] || { echo "dash server did not come up: $(cat "$t/log")"; kill "$pid" 2>/dev/null; rm -rf "$t"; return 1; }
  page="$(curl -s "http://127.0.0.1:$port/")"
  kill "$pid" 2>/dev/null
  assert_contains "$page" 'main +7' || { rm -rf "$t"; return 1; }
  assert_contains "$page" 'cel update' || { rm -rf "$t"; return 1; }
  rm -rf "$t"
}
