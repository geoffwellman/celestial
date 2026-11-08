# shellcheck shell=bash
# THE LAUNCH SAYS WHO AN AGENT IS. `cel run` execs every agent runtime under
# `env CEL_ROLE=... CEL_PRODUCT=...` (lib/run.sh _run_launch_env), and
# /proc/<pid>/environ is fixed at exec - the marks `cel gc` proves agents by.
# An agent that re-dresses its own shell (`export CEL_PRODUCT=other`,
# `X=CEL_PRODUCT; declare -x "$X=other"`, `bash -c 'CEL_ROLE=solo cel ...'`)
# changes its variables but not the environ its launch fixed. So from the
# caller (cel's parent) upward, the nearest process whose environ carries
# CEL_ROLE is this agent's launch, and every identity variable here must
# equal that environ's (set to the same value, or unset in both). A process
# that claims a role or a membership with no such launch above it - detached
# by `setsid` or a double fork, or never launched - is refused: nothing
# vouches for it. Limit: a process that execs a fresh environment carrying
# CEL_ROLE (`env CEL_ROLE=solo CEL_PRODUCT=x bash -c ...`) is its own nearest
# launch; that spelling is the guard's to refuse (_guard_cel_env_tamper).
# The check always runs. Its one seam, CEL_PROC_DIR (the proc root a test
# builds, as lib/inbox.sh's), is honoured only under this checkout's own
# suite (cel_under_suite, lib/common.sh: decided by the process's ancestry,
# never by a variable); anywhere else the root is /proc. So a test that runs
# a writing verb as an agent gives it a launch fixture - nothing exported
# skips or redirects the check.
#
# Callers: `cel team`'s writing verbs (lib/team.sh) and `cel forge`'s writes
# (lib/forge.sh _forge_cli_authorise). A process with no identity at all
# passes here; each caller refuses that itself.
_CEL_IDENTITY_VARS='CEL_ROLE CEL_PRODUCT CEL_INBOX_ME CEL_INBOX_WS CEL_TEAM CEL_TEAM_ROLE CEL_TEAM_MEMBER'
cel_launch_identity() { # <what, e.g. "cel team start"> -> dies unless this identity is its launch's
  local proc=/proc pid="$PPID" n=0 stat item v
  if [ -n "${CEL_PROC_DIR:-}" ] && cel_under_suite; then proc="$CEL_PROC_DIR"; fi
  [ -n "${CEL_ROLE:-}${CEL_TEAM_MEMBER:-}" ] || return 0   # no identity: the caller refuses it
  local -A env=()
  while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ "$n" -lt 64 ]; do
    if grep -qsz '^CEL_ROLE=' "$proc/$pid/environ"; then
      while IFS= read -r -d '' item; do
        case "$item" in CEL_*=*) env["${item%%=*}"]="${item#*=}" ;; esac
      done < <({ cat "$proc/$pid/environ"; } 2>/dev/null)
      for v in $_CEL_IDENTITY_VARS; do
        if [ "${!v+set}" != "${env[$v]+set}" ] || [ "${!v:-}" != "${env[$v]:-}" ]; then
          die "$1: this process says $v=${!v-<unset>} but its launch (pid $pid) says $v=${env[$v]-<unset>} - an agent acts as the one it was launched as; nothing changed"
        fi
      done
      return 0
    fi
    stat="$({ cat "$proc/$pid/stat"; } 2>/dev/null)" || break
    stat="${stat##*) }"; stat="${stat#* }"; pid="${stat%% *}"
    n=$((n + 1))
  done
  die "$1: this process claims CEL_ROLE=${CEL_ROLE:-} ${CEL_TEAM_MEMBER:+CEL_TEAM_MEMBER=$CEL_TEAM_MEMBER }but no agent launch above it carries one (detached, or never launched) - nothing vouches for it; nothing changed"
}
