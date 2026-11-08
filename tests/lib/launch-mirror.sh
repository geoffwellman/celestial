# shellcheck shell=bash
# AN AGENT'S LAUNCH, FOR TESTS THAT ARE NOT ABOUT IT. cel team's and cel
# forge's writing verbs check the caller's identity against its launch's
# environ (lib/identity.sh cel_launch_identity), and nothing exported skips
# that check, so a test that runs such a verb as an agent gives it a launch.
#
#   launch_mirror_wrap <fn...>   once, after sourcing: each call of <fn>
#                                first writes the caller's launch
#   launch_mirror_at <dir>       per fixture: the launches go under <dir>,
#                                which becomes the suite's CEL_PROC_DIR
#
# The launch is the caller's $PPID (where the check starts), parented to
# init, and its environ carries exactly the caller's identity variables, so
# the check passes for whatever identity the test gives the call - the verb's
# own rules (role, product, authorship) still decide. A test ABOUT the launch
# check builds its own proc tree and points CEL_PROC_DIR at it; while
# CEL_PROC_DIR names anything but <dir>, nothing is written. Written temp +
# rename: concurrent calls never let the check read half a file.
launch_mirror_wrap() { # <fn...>
  local fn
  for fn in "$@"; do
    declare -F "_launch_unmirrored_$fn" >/dev/null && continue
    eval "_launch_unmirrored_$fn() $(declare -f "$fn" | tail -n +2)"
    eval "$fn() { _launch_mirror_write; _launch_unmirrored_$fn \"\$@\"; }"
  done
}
launch_mirror_at() { # <dir>
  mkdir -p "$1"
  export LAUNCH_MIRROR_DIR="$1" CEL_PROC_DIR="$1"
}
_launch_mirror_write() {
  [ -n "${LAUNCH_MIRROR_DIR:-}" ] && [ "${CEL_PROC_DIR:-}" = "$LAUNCH_MIRROR_DIR" ] || return 0
  local d="$LAUNCH_MIRROR_DIR/$PPID" v
  mkdir -p "$d"
  for v in $_CEL_IDENTITY_VARS; do
    [ -z "${!v+set}" ] || printf '%s=%s\0' "$v" "${!v}"
  done > "$d/environ.$BASHPID"
  mv -f "$d/environ.$BASHPID" "$d/environ"
  printf '%s (bash) S 1 1 1' "$PPID" > "$d/stat.$BASHPID"
  mv -f "$d/stat.$BASHPID" "$d/stat"
}
