# shellcheck shell=bash
# The steward timer's unit text and the doctor verdict on its last tick.
# systemctl is a stub on a prepended PATH that logs argv and prints canned
# `show` output; nothing here touches the live user manager.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/steward_timer.sh"

_st_setup() {
  T="$(mktemp -d)"
  export CEL_SYSTEMD_DIR="$T/units"; mkdir -p "$CEL_SYSTEMD_DIR" "$T/bin"
  cat > "$T/bin/systemctl" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ST_LOG"
case "$*" in *show*) cat "$ST_SHOW" 2>/dev/null ;; esac
S
  chmod +x "$T/bin/systemctl"
  export ST_LOG="$T/log" ST_SHOW="$T/show" PATH="$T/bin:$PATH"
  export CEL_STEWARD_NOW="$(date -d '2026-10-03 09:00:00' +%s)"
}
_st_teardown() { rm -rf "$T"; }

# The unit the incident ran on: no trigger survives a manager restart.
_st_old_timer() {
  printf '[Timer]\nOnBootSec=2min\nOnUnitActiveSec=5min\nPersistent=true\n' > "$1"
}

test_generated_timer_fires_in_a_manager_that_never_ran_the_service() {
  _st_setup
  steward_timer_unit 5 > "$T/new.timer"; _st_old_timer "$T/old.timer"
  steward_timer_rearms "$T/new.timer"
  assert_fails steward_timer_rearms "$T/old.timer"
  assert_eq "$(steward_timer_interval "$T/new.timer")" "5"
  _st_teardown
}

test_generated_timer_keeps_the_requested_interval() {
  _st_setup
  steward_timer_unit 7 > "$T/t.timer"
  assert_eq "$(steward_timer_interval "$T/t.timer")" "7"
  _st_teardown
}

test_upgrade_rewrites_a_timer_that_cannot_rearm_and_reloads() {
  _st_setup
  _st_old_timer "$CEL_SYSTEMD_DIR/cel-steward.timer"
  assert_contains "$(steward_timer_upgrade)" "rewrote"
  steward_timer_rearms "$CEL_SYSTEMD_DIR/cel-steward.timer"
  assert_contains "$(cat "$ST_LOG")" "--user daemon-reload"
  # current unit: left alone
  : > "$ST_LOG"
  assert_eq "$(steward_timer_upgrade)" ""
  assert_eq "$(cat "$ST_LOG")" ""
  _st_teardown
}

test_doctor_fails_a_steward_last_tick_older_than_three_intervals() {
  _st_setup
  steward_timer_unit 5 > "$CEL_SYSTEMD_DIR/cel-steward.timer"
  printf 'LastTriggerUSec=Fri 2026-10-02 18:51:20 UTC\nNextElapseUSecRealtime=\n' > "$ST_SHOW"
  local out rc=0; out="$(TZ=UTC steward_timer_health)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "systemctl --user start cel-steward.service"
  _st_teardown
}

test_doctor_passes_a_fresh_steward_tick() {
  _st_setup
  steward_timer_unit 5 > "$CEL_SYSTEMD_DIR/cel-steward.timer"
  printf 'LastTriggerUSec=Sat 2026-10-03 08:58:00 UTC\nNextElapseUSecRealtime=Sat 2026-10-03 09:03:00 UTC\n' > "$ST_SHOW"
  export CEL_STEWARD_NOW="$(TZ=UTC date -d '2026-10-03 09:00:00' +%s)"
  local out; out="$(TZ=UTC steward_timer_health)"
  assert_contains "$out" "last tick 2m ago"
  _st_teardown
}

test_doctor_fails_a_timer_with_no_next_trigger() {
  _st_setup
  steward_timer_unit 5 > "$CEL_SYSTEMD_DIR/cel-steward.timer"
  export CEL_STEWARD_NOW="$(TZ=UTC date -d '2026-10-03 09:00:00' +%s)"
  printf 'LastTriggerUSec=Sat 2026-10-03 08:58:00 UTC\nNextElapseUSecRealtime=n/a\n' > "$ST_SHOW"
  assert_fails steward_timer_health
  _st_teardown
}

test_doctor_says_nothing_without_an_installed_timer() {
  _st_setup
  assert_eq "$(steward_timer_health)" ""
  _st_teardown
}

# What the live box reports: an all-monotonic timer leaves the realtime field
# empty and is armed all the same.
test_doctor_reads_a_monotonic_next_elapse_as_armed() {
  _st_setup
  steward_timer_unit 5 > "$CEL_SYSTEMD_DIR/cel-steward.timer"
  export CEL_STEWARD_NOW="$(TZ=UTC date -d '2026-10-03 09:00:00' +%s)"
  printf 'LastTriggerUSec=Sat 2026-10-03 08:58:00 UTC\nNextElapseUSecRealtime=\nNextElapseUSecMonotonic=1d 10h 50min\n' > "$ST_SHOW"
  assert_contains "$(TZ=UTC steward_timer_health)" "armed"
  _st_teardown
}
