#!/usr/bin/env bash
# Run as root by cel-manager-watchdog.timer (CEL-122; install with
# `cel watchdog print`). When the OOM-killer takes user@<uid>.service nothing
# brings it back: this does, then re-ensures the box services that lived in it.
set -u
user="${1:?user}" uid="${2:?uid}"
unit="user@$uid.service"
[ "$(systemctl is-active "$unit" 2>/dev/null)" = active ] && exit 0
logger -t cel-watchdog "$unit is not active - starting it" 2>/dev/null || true
systemctl start "$unit" || exit 1
cel="$(dirname "$(readlink -f "$0")")/../../bin/cel"
for s in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "/run/user/$uid/bus" ] && break; sleep 1
done
runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" "$cel" dash --ensure || true
runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" "$cel" pages --ensure || true
