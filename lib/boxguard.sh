# shellcheck shell=bash
# THE BOX SURVIVES MEMORY PRESSURE (CEL-122).
#
# 2026-10-12: 23 GB of RAM and 7 GB of swap full, load 182. The kernel's
# OOM-killer took rustc and node, then the user systemd manager itself - and
# with it the steward, gc, the dashboard and every transient unit. One
# orchestrator had six release cargo builds going at once, four workers
# compiling the same crate. Nothing in the plane asked whether the box could
# afford another worker or another build before starting one.
#
# Four guards live here, all small and all overridable by env for the suite:
#   - admission: no new worker while MemAvailable is under a floor or swap is
#     mostly used (boxguard_admit, called by cel-fanout delegate/scout);
#   - the warning line: below it the steward warns orchestrators and gc stops
#     idle agents sooner (boxguard_pressure);
#   - one heavy build at a time across the box (cel build-slot -- <cmd>);
#   - a system-level watchdog for the user manager (cel watchdog).
[ -n "${_CEL_BOXGUARD:-}" ] && return 0
_CEL_BOXGUARD=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/config.sh
. "${BASH_SOURCE[0]%/*}/config.sh"

_boxguard_num() { # <value> <default>
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}
_boxguard_cfg() { # <env value> <section> <key> <default>
  local v="$1"
  [ -n "$v" ] || v="$(cel_config_get "$2" "$3" 2>/dev/null || true)"
  _boxguard_num "$v" "$4"
}

# Thresholds: env first (the suite), then config (box), then the default.
boxguard_min_avail_mb() { _boxguard_cfg "${CEL_BOX_MIN_AVAIL_MB:-}" box min_available_mb 3072; }
boxguard_max_swap_pct() { _boxguard_cfg "${CEL_BOX_MAX_SWAP_PCT:-}" box max_swap_pct 80; }
boxguard_warn_avail_mb() { _boxguard_cfg "${CEL_BOX_WARN_AVAIL_MB:-}" box warn_available_mb 5120; }
boxguard_build_slots() { _boxguard_cfg "${CEL_BUILD_SLOTS:-}" build slots 1; }

# `avail_mb swap_pct` - from the same CEL_MEMINFO seam lib/memory.sh reads.
# Unreadable is UNKNOWN and prints `-1 -1`: no guard may turn "could not ask"
# into "the box is full".
boxguard_read() {
  # The suite never measures the box it happens to run on: only a fixture.
  if [ -n "${CEL_TESTING:-}" ] && [ -z "${CEL_MEMINFO:-}" ]; then printf -- '-1 -1\n'; return 0; fi
  awk '
    /^MemTotal:/     { t = $2 }
    /^MemAvailable:/ { a = $2 }
    /^SwapTotal:/    { st = $2 }
    /^SwapFree:/     { sf = $2 }
    END {
      if (t + 0 <= 0) { print "-1 -1"; exit }
      sp = (st + 0 > 0) ? int((st - sf) * 100 / st) : 0
      printf "%d %d\n", a / 1024, sp
    }' "${CEL_MEMINFO:-/proc/meminfo}" 2>/dev/null || printf -- '-1 -1\n'
}

_boxguard_gb() { awk -v mb="$1" 'BEGIN { printf "%.1f", mb / 1024 }'; }

# 0 = admit. 1 = refuse, with the plain sentence on stdout.
boxguard_admit() {
  local avail swap min maxs
  read -r avail swap <<<"$(boxguard_read)"
  [ "${avail:--1}" -ge 0 ] || return 0
  min="$(boxguard_min_avail_mb)"; maxs="$(boxguard_max_swap_pct)"
  if [ "$avail" -lt "$min" ] || [ "$swap" -gt "$maxs" ]; then
    printf 'box memory low: %s GB free, swap %s%% - not starting (floor %s GB free, swap at most %s%%; cel doctor names what is holding it)\n' \
      "$(_boxguard_gb "$avail")" "$swap" "$(_boxguard_gb "$min")" "$maxs"
    return 1
  fi
  return 0
}

# 0 = the box is below the warning line (or swap is past its ceiling).
boxguard_pressure() {
  local avail swap
  read -r avail swap <<<"$(boxguard_read)"
  [ "${avail:--1}" -ge 0 ] || return 1
  [ "$avail" -lt "$(boxguard_warn_avail_mb)" ] || [ "$swap" -gt "$(boxguard_max_swap_pct)" ]
}

# Half the cores, at least one: four workers each running cargo at full
# width was most of the load-182 afternoon.
boxguard_cargo_jobs() {
  if [[ "${CEL_CARGO_JOBS:-}" =~ ^[1-9][0-9]*$ ]]; then printf '%s' "$CEL_CARGO_JOBS"; return 0; fi
  local n; n="$(nproc 2>/dev/null || printf 2)"
  n=$(( n / 2 )); [ "$n" -ge 1 ] || n=1
  printf '%s' "$n"
}

# ── one heavy build at a time ────────────────────────────────────────────────
_boxguard_slot_dir() { printf '%s' "${CEL_BUILD_SLOT_DIR:-$HOME/.local/share/cel/build-slot}"; }

cmd_build_slot() { # [--] <cmd...>
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || die "usage: cel build-slot -- <command...>   (one heavy build at a time across the box)"
  # RE-ENTRANT: a heavy command that itself calls build-slot (a make target
  # wrapping cargo) already holds a slot through its caller; waiting for
  # another would deadlock at one slot.
  if [ -n "${CEL_BUILD_SLOT_HELD:-}" ]; then "$@"; return; fi
  local dir slots i fd="" said=0
  dir="$(_boxguard_slot_dir)"; mkdir -p "$dir" || die "build-slot: cannot create $dir"
  slots="$(boxguard_build_slots)"; [ "$slots" -ge 1 ] || slots=1
  while :; do
    for ((i = 0; i < slots; i++)); do
      exec {fd}>"$dir/slot-$i.lock" || continue
      if flock -n "$fd"; then
        [ -n "${CARGO_BUILD_JOBS:-}" ] || export CARGO_BUILD_JOBS="$(boxguard_cargo_jobs)"
        # The command inherits the descriptor, so the slot is held exactly as
        # long as the build (and anything it forked) runs.
        local rc=0; CEL_BUILD_SLOT_HELD=1 "$@" || rc=$?
        exec {fd}>&-
        return "$rc"
      fi
      exec {fd}>&-
    done
    if [ "$said" -eq 0 ]; then
      printf 'build-slot: waiting for a build slot (%s in use box-wide) - not starting a second heavy build\n' "$slots" >&2
      said=1
    fi
    sleep "${CEL_BUILD_SLOT_POLL:-2}"
  done
}

# ── the manager watchdog ─────────────────────────────────────────────────────
# The user manager is not restarted by anything when the OOM-killer takes it:
# it needed `sudo systemctl start user@<uid>.service` by hand. A user unit can
# not watch its own manager, so this is a SYSTEM timer, installed once by the
# owner: `cel watchdog install` via non-interactive sudo, or `print` to paste.
_boxguard_wd_dir() { printf '%s' "${CEL_WATCHDOG_UNIT_DIR:-/etc/systemd/system}"; }
BOXGUARD_WD_UNIT=cel-manager-watchdog

boxguard_wd_installed() { [ -f "$(_boxguard_wd_dir)/$BOXGUARD_WD_UNIT.timer" ]; }

# RUN AS ROOT, so it executes nothing a user can write: every command is a
# root-owned system binary and the unit file itself is written by root. The
# user's own `cel` runs only after runuser has dropped to that user.
boxguard_wd_service_text() { # <user> <uid>
  local env="XDG_RUNTIME_DIR=/run/user/$2"
  printf '%s' "[Unit]
Description=celestial: restart the user manager for $1 if it died, then its services

[Service]
Type=oneshot
ExecCondition=/usr/bin/sh -c '! /usr/bin/systemctl is-active -q user@$2.service'
ExecStart=/usr/bin/systemctl start user@$2.service
ExecStartPost=/usr/bin/sleep 5
ExecStartPost=-/usr/sbin/runuser -u $1 -- /usr/bin/env $env $CEL_ROOT/bin/cel dash --ensure
ExecStartPost=-/usr/sbin/runuser -u $1 -- /usr/bin/env $env $CEL_ROOT/bin/cel pages --ensure
"
}

boxguard_wd_timer_text() {
  printf '%s' "[Unit]
Description=celestial: user-manager watchdog

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
"
}

# `install` writes the same two files `print` shows, through `sudo -n`: cel
# never prompts for a password, and an owner without passwordless sudo gets
# `print` instead. Units are written via tee from files - the printed script
# once lost the newline before its EOF (command substitution strips it), the
# heredoc never closed and pasting it swallowed the timer.
_boxguard_wd_install() { # <user> <uid> <dir>
  local tmp u=$BOXGUARD_WD_UNIT
  if ! sudo -n true 2>/dev/null; then
    c_warn "cel watchdog install needs passwordless sudo - run the script from cel watchdog print instead"
    return 1
  fi
  tmp="$(mktemp -d)"
  boxguard_wd_service_text "$1" "$2" > "$tmp/$u.service"
  boxguard_wd_timer_text > "$tmp/$u.timer"
  sudo -n tee "$3/$u.service" < "$tmp/$u.service" >/dev/null \
    && sudo -n tee "$3/$u.timer" < "$tmp/$u.timer" >/dev/null \
    || { rm -rf "$tmp"; die "cel watchdog install: could not write the units in $3"; }
  rm -rf "$tmp"
  sudo -n systemctl daemon-reload || die "cel watchdog install: daemon-reload failed"
  sudo -n systemctl enable --now "$u.timer" || die "cel watchdog install: enable --now $u.timer failed"
  if systemctl is-active "$u.timer" >/dev/null 2>&1; then
    c_ok "manager watchdog installed and active ($3/$u.timer)"
  else
    c_warn "manager watchdog written but $u.timer is not active"; return 1
  fi
}

_boxguard_wd_uninstall() { # <dir>
  local u=$BOXGUARD_WD_UNIT
  if ! sudo -n true 2>/dev/null; then
    c_warn "cel watchdog uninstall needs passwordless sudo"; return 1
  fi
  sudo -n systemctl disable --now "$u.timer" >/dev/null 2>&1 || true
  sudo -n rm -f "$1/$u.timer" "$1/$u.service" || die "cel watchdog uninstall: could not remove the units in $1"
  sudo -n systemctl daemon-reload || true
  c_ok "manager watchdog removed"
}

cmd_watchdog() { # [status|print|install|uninstall]
  local user uid d
  user="$(id -un)"; uid="$(id -u)"; d="$(_boxguard_wd_dir)"
  case "${1:-status}" in
    print)
      printf '# one-time, as the owner (root needed: the watchdog must outlive the user manager)\n'
      printf "sudo tee %s/%s.service >/dev/null <<'EOF'\n" "$d" "$BOXGUARD_WD_UNIT"
      boxguard_wd_service_text "$user" "$uid"; printf 'EOF\n'
      printf "sudo tee %s/%s.timer >/dev/null <<'EOF'\n" "$d" "$BOXGUARD_WD_UNIT"
      boxguard_wd_timer_text; printf 'EOF\n'
      printf 'sudo systemctl daemon-reload && sudo systemctl enable --now %s.timer\n' "$BOXGUARD_WD_UNIT"
      ;;
    install) _boxguard_wd_install "$user" "$uid" "$d" ;;
    uninstall) _boxguard_wd_uninstall "$d" ;;
    status)
      if boxguard_wd_installed; then c_ok "manager watchdog installed ($d/$BOXGUARD_WD_UNIT.timer)"
      else c_warn "manager watchdog not installed - run cel watchdog install (or cel watchdog print without sudo)"; return 1; fi
      ;;
    *) die "cel watchdog: want status, print, install or uninstall" ;;
  esac
}

# One line for cel doctor: free, swap, and the three largest consumers.
boxguard_doctor_line() {
  local avail swap
  read -r avail swap <<<"$(boxguard_read)"
  if [ "${avail:--1}" -lt 0 ]; then printf 'memory: unknown (meminfo unreadable)'; return 0; fi
  printf 'memory: %s GB free, swap %s%% used (admission floor %s GB, swap %s%%)' \
    "$(_boxguard_gb "$avail")" "$swap" "$(_boxguard_gb "$(boxguard_min_avail_mb)")" "$(boxguard_max_swap_pct)"
}

# Largest consumers grouped by worktree: `mb<TAB>dir` biggest first.
boxguard_top_trees() { # [n]
  local n="${1:-3}"
  [ -n "${CEL_BOXGUARD_TOP:-}" ] && { printf '%s\n' "$CEL_BOXGUARD_TOP" | head -n "$n"; return 0; }
  local p cwd rss rel rest base="$HOME/.herdr/worktrees"
  for p in /proc/[0-9]*; do
    cwd="$(readlink "$p/cwd" 2>/dev/null)" || continue
    case "$cwd" in "$HOME"/.herdr/worktrees/*/*) ;; *) continue ;; esac
    rel="${cwd#"$base"/}"; rest="${rel#*/}"
    cwd="$base/${rel%%/*}/${rest%%/*}"
    rss="$(awk '/^VmRSS:/{print $2}' "$p/status" 2>/dev/null)"
    [ -n "$rss" ] && printf '%s\t%s\n' "$rss" "$cwd"
  done | awk -F'\t' '{s[$2]+=$1} END {for (d in s) printf "%d\t%s\n", s[d]/1024, d}' \
       | sort -t"$(printf '\t')" -k1,1nr | head -n "$n"
}
