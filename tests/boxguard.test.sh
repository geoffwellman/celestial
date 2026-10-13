# shellcheck shell=bash
# lib/boxguard.sh - admission by free memory, the warning line, one heavy
# build at a time and the manager watchdog (CEL-122). The box is driven by a
# fixture meminfo through CEL_MEMINFO: a test may not arrange a full box.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/boxguard.sh"

_bg_meminfo() { # <avail-kb> <swap-total-kb> <swap-free-kb>
  T="${T:-$(mktemp -d)}"
  printf 'MemTotal: 25165824 kB\nMemFree: 100000 kB\nMemAvailable: %s kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' \
    "$1" "$2" "$3" > "$T/meminfo"
  export CEL_MEMINFO="$T/meminfo" CEL_CONFIG_FILE="$T/none.yaml"
}

test_boxguard_admits_a_healthy_box() {
  _bg_meminfo 8388608 8388608 8388608
  boxguard_admit || { echo "refused a healthy box"; return 1; }
  rm -rf "$T"
}

test_boxguard_refuses_below_the_free_floor_and_says_so() {
  _bg_meminfo 1048576 8388608 8388608   # 1 GB free
  local out rc=0; out="$(boxguard_admit)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "box memory low: 1.0 GB free, swap 0% - not starting"
  # the floor is an override
  CEL_BOX_MIN_AVAIL_MB=512 boxguard_admit >/dev/null || { echo "override ignored"; return 1; }
  rm -rf "$T"
}

test_boxguard_refuses_when_swap_is_mostly_used() {
  _bg_meminfo 8388608 8388608 838860    # 90% swap used
  local out rc=0; out="$(boxguard_admit)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "swap 90%"
  CEL_BOX_MAX_SWAP_PCT=95 boxguard_admit >/dev/null || { echo "swap override ignored"; return 1; }
  rm -rf "$T"
}

test_boxguard_unknown_meminfo_admits() {
  CEL_MEMINFO=/nonexistent boxguard_admit || { echo "unknown treated as full"; return 1; }
  CEL_MEMINFO=/nonexistent boxguard_pressure && { echo "unknown treated as pressure"; return 1; }
  return 0
}

test_boxguard_pressure_is_the_warning_line() {
  _bg_meminfo 4194304 0 0               # 4 GB free, warning line 5 GB
  boxguard_pressure || { echo "no pressure at 4 GB"; return 1; }
  CEL_BOX_WARN_AVAIL_MB=2048 boxguard_pressure && { echo "line override ignored"; return 1; }
  rm -rf "$T"
}

test_fanout_delegate_refuses_on_a_full_box() {
  _bg_meminfo 524288 0 0
  local out rc=0
  out="$(cd "$T" && HOME="$T" bash "$CEL_ROOT/core/skills/fanout/bin/cel-fanout" delegate widget b1 /nonexistent 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "delegate started on a full box"; return 1; }
  assert_contains "$out" "box memory low"
  rm -rf "$T"
}

test_build_slot_serialises_heavy_builds() {
  T="$(mktemp -d)"
  export CEL_BUILD_SLOT_DIR="$T/slots" CEL_BUILD_SLOT_POLL=0.1 CEL_CONFIG_FILE="$T/none.yaml"
  local job='printf "start %s\n" "$1" >> "$0"; sleep 0.5; printf "end %s\n" "$1" >> "$0"'
  ( cmd_build_slot -- bash -c "$job" "$T/log" a ) 2>/dev/null &
  sleep 0.1
  ( cmd_build_slot -- bash -c "$job" "$T/log" b ) 2>"$T/err" &
  wait
  assert_eq "$(cat "$T/log" | tr '\n' ' ')" "start a end a start b end b "
  assert_contains "$(cat "$T/err")" "waiting for a build slot"
  rm -rf "$T"
}

test_build_slot_allows_n_concurrent_and_sets_cargo_jobs() {
  T="$(mktemp -d)"
  export CEL_BUILD_SLOT_DIR="$T/slots" CEL_BUILD_SLOTS=2 CEL_CARGO_JOBS=3 CEL_CONFIG_FILE="$T/none.yaml"
  local job='printf "start\n" >> "$0"; sleep 0.4; printf "end\n" >> "$0"'
  ( unset CARGO_BUILD_JOBS; cmd_build_slot -- bash -c "$job" "$T/log" ) &
  ( unset CARGO_BUILD_JOBS; cmd_build_slot -- bash -c "$job" "$T/log" ) &
  wait
  assert_eq "$(head -2 "$T/log" | tr '\n' ' ')" "start start "
  assert_eq "$(unset CARGO_BUILD_JOBS; cmd_build_slot -- bash -c 'printf %s "$CARGO_BUILD_JOBS"')" 3
  # the command's exit status is the slot's
  local rc=0; cmd_build_slot -- false || rc=$?
  assert_eq "$rc" 1
  rm -rf "$T"
}

test_watchdog_print_and_status() {
  T="$(mktemp -d)"
  export CEL_WATCHDOG_UNIT_DIR="$T/sys"
  local out; out="$(cmd_watchdog print)"
  assert_contains "$out" "sudo tee $T/sys/cel-manager-watchdog.service"
  # run as root: nothing a user can write may be executed - only system binaries
  assert_contains "$out" "ExecStart=/usr/bin/systemctl start user@$(id -u).service"
  assert_contains "$out" "/usr/sbin/runuser -u $(id -un) --"
  case "$out" in *"ExecStart=$CEL_ROOT"*|*"ExecStart=$HOME"*|*.sh\ *) echo "root unit runs a user-writable path: $out"; return 1;; esac
  assert_contains "$out" "OnUnitActiveSec=1min"
  assert_contains "$out" "enable --now cel-manager-watchdog.timer"
  boxguard_wd_installed && { echo "installed in an empty dir"; return 1; }
  mkdir -p "$T/sys"; : > "$T/sys/cel-manager-watchdog.timer"
  boxguard_wd_installed || { echo "installed timer not seen"; return 1; }
  rm -rf "$T"
}

test_doctor_memory_line_names_free_swap_and_top() {
  _bg_meminfo 4194304 1000 500
  local out; out="$(CEL_BOXGUARD_TOP="$(printf '900\t/w/widget/b1')" boxguard_doctor_line)"
  assert_contains "$out" "memory: 4.0 GB free, swap 50% used"
  assert_eq "$(CEL_BOXGUARD_TOP="$(printf '900\t/w/widget/b1')" boxguard_top_trees 1)" "$(printf '900\t/w/widget/b1')"
  rm -rf "$T"
}

# A heavy command that itself calls build-slot (a make target wrapping cargo)
# must not wait forever on the slot its own caller holds.
test_build_slot_is_reentrant_for_its_holder() {
  T="$(mktemp -d)"
  export CEL_BUILD_SLOT_DIR="$T/slots" CEL_CONFIG_FILE="$T/none.yaml"
  local out
  out="$(timeout 5 bash -c 'source "$CEL_ROOT/lib/common.sh"; source "$CEL_ROOT/lib/boxguard.sh"
    cmd_build_slot -- bash -c "source \"\$CEL_ROOT/lib/common.sh\"; source \"\$CEL_ROOT/lib/boxguard.sh\"; cmd_build_slot -- echo inner"')"
  assert_eq "$out" inner
  rm -rf "$T"
}

# Stubs on a prepended PATH: sudo runs its argv (or refuses -n when a password
# would be needed), systemctl logs and reports the timer active once enabled.
_wd_stubs() {
  T="$(mktemp -d)"; mkdir -p "$T/bin" "$T/sys"
  export CEL_WATCHDOG_UNIT_DIR="$T/sys" STUB_LOG="$T/log" STUB_T="$T"
  cat > "$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$STUB_LOG"
if [ "${1:-}" = -n ]; then shift; [ -n "${STUB_SUDO_PW:-}" ] && { echo "sudo: a password is required" >&2; exit 1; }; fi
exec "$@"
EOF
  cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
case "$*" in
  *"enable --now"*) : > "$STUB_T/active";;
  *"disable --now"*) rm -f "$STUB_T/active";;
  *is-active*) [ -f "$STUB_T/active" ];;
esac
EOF
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"
}

test_watchdog_printed_script_runs_and_writes_units_byte_for_byte() {
  _wd_stubs
  cmd_watchdog print > "$T/script.sh"
  bash "$T/script.sh" || { echo "printed script failed"; return 1; }
  boxguard_wd_service_text "$(id -un)" "$(id -u)" > "$T/want.service"
  boxguard_wd_timer_text > "$T/want.timer"
  cmp "$T/want.service" "$T/sys/cel-manager-watchdog.service" || { echo "service differs"; return 1; }
  cmp "$T/want.timer" "$T/sys/cel-manager-watchdog.timer" || { echo "timer differs"; return 1; }
  assert_contains "$(cat "$STUB_LOG")" "systemctl enable --now cel-manager-watchdog.timer"
  rm -rf "$T"
}

test_watchdog_install_and_uninstall_are_idempotent() {
  _wd_stubs
  cmd_watchdog install >/dev/null || { echo "install failed"; return 1; }
  cmd_watchdog install >/dev/null || { echo "second install failed"; return 1; }
  boxguard_wd_service_text "$(id -un)" "$(id -u)" > "$T/want.service"
  cmp "$T/want.service" "$T/sys/cel-manager-watchdog.service" || { echo "service differs"; return 1; }
  local log; log="$(cat "$STUB_LOG")"
  assert_contains "$log" "sudo -n systemctl daemon-reload"
  assert_contains "$log" "systemctl is-active cel-manager-watchdog.timer"
  cmd_watchdog uninstall >/dev/null || { echo "uninstall failed"; return 1; }
  cmd_watchdog uninstall >/dev/null || { echo "second uninstall failed"; return 1; }
  [ -e "$T/sys/cel-manager-watchdog.timer" ] && { echo "timer left behind"; return 1; }
  [ -e "$T/sys/cel-manager-watchdog.service" ] && { echo "service left behind"; return 1; }
  rm -rf "$T"
}

test_watchdog_install_refuses_when_sudo_needs_a_password() {
  _wd_stubs
  local out rc=0; out="$(STUB_SUDO_PW=1 cmd_watchdog install 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "cel watchdog print"
  [ -e "$T/sys/cel-manager-watchdog.timer" ] && { echo "wrote without sudo"; return 1; }
  rm -rf "$T"
}
