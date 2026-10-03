# shellcheck shell=bash
# The steward's systemd user timer: the unit text it is installed with, whether
# an installed unit can still fire, and how long ago it last did.
#
# Kept apart from lib/steward.sh because `cel doctor` reads all of this and
# must not source the whole tick to do it.
[ -n "${_CEL_STEWARD_TIMER:-}" ] && return 0
_CEL_STEWARD_TIMER=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

STEWARD_TIMER_UNIT="cel-steward"

steward_timer_dir() { printf '%s' "${CEL_SYSTEMD_DIR:-$HOME/.config/systemd/user}"; }

# THE TIMER MUST HAVE A NEXT TRIGGER IN ANY MANAGER, HOWEVER IT STARTED.
# The first unit was OnBootSec + OnUnitActiveSec + Persistent. After the user
# manager restarted mid-uptime, OnBootSec had long passed, OnUnitActiveSec had
# no activation in that manager to count from, and Persistent only applies to
# OnCalendar - so list-timers showed NEXT "-" and the steward (and gc with it)
# did not run for fourteen hours while the box went into OOM. Restarting the
# timer did not rearm it either.
#
# OnActiveSec fires relative to the TIMER's own activation, so every start of
# the timer - boot, manager restart, `systemctl start` - schedules a tick a
# minute later; OnUnitActiveSec then carries the cadence from that tick.
# Chosen over OnCalendar=*:0/N because it keeps any --interval exact (a
# calendar step only divides the hour cleanly for some N) and keeps ticks
# spread rather than every box firing on the same wall-clock minute.
steward_timer_unit() { # <mins>
  printf '%s' "[Unit]
Description=run the celestial steward every ${1}m

[Timer]
OnBootSec=2min
OnActiveSec=1min
OnUnitActiveSec=${1}min
# A tick missed while the box was asleep runs on wake rather than being
# skipped - a ticket moved to the trigger state overnight is still waiting.
Persistent=true
AccuracySec=30s

[Install]
WantedBy=timers.target
"
}

# Does this timer file still get a next elapse when started in a manager that
# booted long ago and never ran the service? Only triggers that do not depend
# on boot time or on a previous activation qualify.
steward_timer_rearms() { # <timer-file>
  [ -r "$1" ] || return 1
  grep -Eq '^[[:space:]]*(OnActiveSec|OnCalendar)[[:space:]]*=[[:space:]]*[^[:space:]]' "$1"
}

steward_timer_interval() { # <timer-file> -> minutes (default 5)
  local m
  m="$(sed -n 's/^[[:space:]]*OnUnitActiveSec[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)min.*/\1/p' "$1" 2>/dev/null | head -1 || true)"
  printf '%s' "${m:-5}"
}

# Rewrite an installed timer written before it rearmed itself. Silent and a
# no-op when no timer is installed or it is already current.
steward_timer_upgrade() {
  local f; f="$(steward_timer_dir)/$STEWARD_TIMER_UNIT.timer"
  [ -e "$f" ] || return 0
  steward_timer_rearms "$f" && return 0
  steward_timer_unit "$(steward_timer_interval "$f")" > "$f"
  if have systemctl; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user restart "$STEWARD_TIMER_UNIT.timer" >/dev/null 2>&1 || true
  fi
  printf 'rewrote %s so it rearms after a manager restart' "$f"
}

# "Fri 2026-10-02 18:51:20 BST" -> epoch; empty for n/a, 0 or unparseable.
_steward_timer_epoch() {
  case "$1" in ""|n/a|0) return 0 ;; esac
  date -d "$1" +%s 2>/dev/null || true
}

# The doctor verdict on the steward's last tick. Prints one line and returns
# 1 when it is a failure: a tick older than three intervals, or a timer with
# no next trigger at all. Prints nothing when no timer is installed.
steward_timer_health() {
  local f; f="$(steward_timer_dir)/$STEWARD_TIMER_UNIT.timer"
  [ -e "$f" ] || return 0
  have systemctl || return 0
  local mins out last next now le ne age repair
  mins="$(steward_timer_interval "$f")"
  repair="systemctl --user start $STEWARD_TIMER_UNIT.service && systemctl --user restart $STEWARD_TIMER_UNIT.timer"
  out="$(systemctl --user show "$STEWARD_TIMER_UNIT.timer" -p LastTriggerUSec -p NextElapseUSecRealtime 2>/dev/null || true)"
  last="$(printf '%s\n' "$out" | sed -n 's/^LastTriggerUSec=//p' | head -1)"
  next="$(printf '%s\n' "$out" | sed -n 's/^NextElapseUSecRealtime=//p' | head -1)"
  # test-only seam, honoured only under the suite
  now=""; [ -n "${CEL_TESTING:-}" ] && now="${CEL_STEWARD_NOW:-}"
  [ -n "$now" ] || now="$(date +%s)"
  le="$(_steward_timer_epoch "$last")"; ne="$(_steward_timer_epoch "$next")"
  if [ -z "$le" ]; then
    printf 'steward has never ticked in this systemd manager - repair: %s' "$repair"; return 1
  fi
  age=$(( now - le ))
  if [ "$age" -gt $(( 3 * mins * 60 )) ]; then
    printf 'steward last tick %sm ago (interval %sm) - the timer is not firing. Repair: %s' \
      "$((age / 60))" "$mins" "$repair"
    return 1
  fi
  if [ -z "$ne" ]; then
    printf 'steward timer has no next trigger - repair: %s' "$repair"; return 1
  fi
  printf 'steward last tick %sm ago, next in %sm' "$((age / 60))" "$(( (ne - now) / 60 ))"
}
