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
  # unreleased work on main, ahead of the newest tag
  printf 'later\n' >"$ROOT/UNRELEASED"
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -qm 'after the release'
  git -C "$ROOT" remote add origin "$ORIGIN"
  git -C "$ROOT" push -q origin main --tags
  git -C "$ROOT" reset -q --hard v0.1.0 # the installed box sits at v0.1.0
  export CEL_ROOT="$ROOT"
  export CEL_UPDATE_DIR="$T/updatestate"
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
  _upd_fixture
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
