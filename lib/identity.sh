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
# It reads /proc with shell builtins only (read and redirections, no cat or
# grep), so a PATH that puts other binaries first cannot feed it a forged
# environ. Shell functions an agent smuggles in (exported, or defined by a
# BASH_ENV file) never reach it: bin/cel re-executes itself without them
# before any lib is loaded.
#
# Callers: `cel team`'s writing verbs (lib/team.sh) and `cel forge`'s writes
# (lib/forge.sh _forge_cli_authorise). A process with no identity at all
# passes here; each caller refuses that itself.
_CEL_IDENTITY_VARS='CEL_ROLE CEL_PRODUCT CEL_INBOX_ME CEL_INBOX_WS CEL_TEAM CEL_TEAM_ROLE CEL_TEAM_MEMBER'
cel_launch_identity() { # <what, e.g. "cel team start"> -> dies unless this identity is its launch's
  local proc=/proc pid="$PPID" n=0 stat item v launch
  if [ -n "${CEL_PROC_DIR:-}" ] && cel_under_suite; then proc="$CEL_PROC_DIR"; fi
  [ -n "${CEL_ROLE:-}${CEL_TEAM_MEMBER:-}" ] || return 0   # no identity: the caller refuses it
  local -A env
  while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ "$n" -lt 64 ]; do
    env=(); launch=0
    { while IFS= read -r -d '' item; do
        case "$item" in
          CEL_*=*) env["${item%%=*}"]="${item#*=}"; [[ "$item" != CEL_ROLE=* ]] || launch=1 ;;
        esac
      done < "$proc/$pid/environ"; } 2>/dev/null
    if [ "$launch" = 1 ]; then
      for v in $_CEL_IDENTITY_VARS; do
        if [ "${!v+set}" != "${env[$v]+set}" ] || [ "${!v:-}" != "${env[$v]:-}" ]; then
          die "$1: this process says $v=${!v-<unset>} but its launch (pid $pid) says $v=${env[$v]-<unset>} - an agent acts as the one it was launched as; nothing changed"
        fi
      done
      return 0
    fi
    stat=""
    { read -r stat < "$proc/$pid/stat" || [ -n "$stat" ]; } 2>/dev/null || break
    stat="${stat##*) }"; stat="${stat#* }"; pid="${stat%% *}"
    n=$((n + 1))
  done
  die "$1: this process claims CEL_ROLE=${CEL_ROLE:-} ${CEL_TEAM_MEMBER:+CEL_TEAM_MEMBER=$CEL_TEAM_MEMBER }but no agent launch above it carries one (detached, or never launched) - nothing vouches for it; nothing changed"
}

# WHICH AGENT ROLE IS THIS, IF ANY: CEL_ROLE as this process says it, else as
# the nearest launch above it carries it - an agent that unsets CEL_ROLE (or
# runs `env -u CEL_ROLE cel ...`) is still the agent its launch made it.
# Prints nothing for a person's own shell, or a service such as the
# dashboard's unit, with no launch above it. Under this checkout's suite the
# ancestry is the developer's shell, not the test's, so only a launch fixture
# (CEL_PROC_DIR) is walked there. Caller: `cel decide answer|drop`, which
# refuses an agent.
cel_agent_role() { # -> the role, or nothing
  [ -z "${CEL_ROLE:-}" ] || { printf '%s' "$CEL_ROLE"; return 0; }
  local proc=/proc pid="$PPID" n=0 stat item
  if cel_under_suite; then
    [ -n "${CEL_PROC_DIR:-}" ] || return 0
    proc="$CEL_PROC_DIR"
  fi
  while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ "$n" -lt 64 ]; do
    { while IFS= read -r -d '' item; do
        case "$item" in CEL_ROLE=?*) printf '%s' "${item#CEL_ROLE=}"; return 0 ;; esac
      done < "$proc/$pid/environ"; } 2>/dev/null
    stat=""
    { read -r stat < "$proc/$pid/stat" || [ -n "$stat" ]; } 2>/dev/null || break
    stat="${stat##*) }"; stat="${stat#* }"; pid="${stat%% *}"
    n=$((n + 1))
  done
  return 0
}
