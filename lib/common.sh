# shellcheck shell=bash
# Output helpers and small predicates. Sourced by every other lib and by bin/cel.
[ -n "${_CEL_COMMON:-}" ] && return 0
_CEL_COMMON=1

# Honour an inherited CEL_ROOT (the test runner exports one); otherwise resolve
# from this file's location, following symlinks so `cel` works via ~/.local/bin.
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CEL_ROOT

c_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
c_warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
c_hd()   { printf '\n\033[1m%s\033[0m\n' "$*"; }

have()   { command -v "$1" >/dev/null 2>&1; }
die()    { c_err "$*"; exit 1; }

# A DEAD MISE SHIM IS NOT AN INSTALLED TOOL. An npm global lives under the
# node that installed it (mise: installs/node/<release>/lib/node_modules); a
# new release moving the `lts` alias leaves the tool's shim on PATH with
# nothing behind it, so `command -v` succeeds and running it prints "No
# version is set for shim: <bin>". 0 when <bin> resolves to such a shim
# (asked of mise as it would resolve from <dir>, default the caller's cwd);
# SHIM_ERR is then the shim's own first error line. 1 for an absent tool, a
# plain executable and a shim that resolves. `mise which` answers without
# starting the tool; only a shim it refuses is run, to read the error the
# owner would see (a dead shim exits inside mise).
# BOUNDED: each of the two calls gets CEL_SHIM_CHECK_SECS (5) under
# `timeout -k 1`, which signals its whole process group. A call that runs
# out of time (124), or is killed (137: past the grace, or out of memory),
# is "cannot tell": 2, with SHIM_ERR saying which. A caller warns and
# carries on as if the tool runs - a hung mise never refuses a launch, never
# triggers a reinstall and never hangs doctor, setup, update or cel run.
# MISE HUNG IN A DIRECTORY: once `mise which` itself has timed out there,
# every later check from that directory in the same command answers 2 at
# once, so a doctor over many shims waits for one bound, not one per shim.
# Another directory is still asked, and a hung `<shim> --version` is that
# one shim's "cannot tell" only. The record is a file per command (see
# _shim_hung_file), so it holds across the $(...) subshells callers use.
SHIM_ERR=""
_shim_hung_file() { # -> this command's record: named by its PID and that PID's start
  local s; s="$(cat "/proc/$$/stat" 2>/dev/null)" || s=""
  s="${s##*) }"; set -- $s
  printf '%s/cel-shim-hung.%s.%s' "${TMPDIR:-/tmp}" "$$" "${20:-0}"
}
_shim_hung_get() { # <dir> -> 0, SHIM_ERR set, when mise hung there in this command
  local f d m; f="$(_shim_hung_file)"
  [ -f "$f" ] || return 1
  while IFS=$'\t' read -r d m; do
    [ "$d" = "$1" ] && { SHIM_ERR="$m"; return 0; }
  done < "$f"
  return 1
}
_shim_hung_set() { # <dir> <reason>; records of commands that have ended go
  local key="$1" reason="$2" f g rest pid start s
  f="$(_shim_hung_file)"
  for g in "${TMPDIR:-/tmp}"/cel-shim-hung.*.*; do
    [ -O "$g" ] && [ "$g" != "$f" ] || continue
    rest="${g##*/cel-shim-hung.}"; pid="${rest%%.*}"; start="${rest#*.}"
    s="$(cat "/proc/$pid/stat" 2>/dev/null)" || s=""
    s="${s##*) }"; set -- $s
    [ "${20:-}" = "$start" ] || rm -f -- "$g"
  done
  printf '%s\t%s\n' "$key" "$reason" >> "$f"
}
_shim_bound_reason() { # <what> <rc> <secs>
  case "$2" in
    124) printf '%s did not answer within %ss' "$1" "$3" ;;
    *) printf '%s was killed (timed out after %ss, or out of memory)' "$1" "$3" ;;
  esac
}
shim_dead() { # <bin> [dir] -> 0 dead, 1 not dead, 2 cannot tell (timed out or killed)
  local path real mise dir="${2:-.}" secs="${CEL_SHIM_CHECK_SECS:-5}" rc=0 out key
  SHIM_ERR=""
  case "$secs" in ''|*[!0-9]*|0) secs=5 ;; esac
  path="$(command -v "$1" 2>/dev/null)" || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  real="$(readlink -f "$path" 2>/dev/null)" || return 1
  if [ "${real##*/}" = mise ]; then mise="$real"
  elif [[ "$path" = */mise/shims/* ]] && have mise; then mise=mise
  else return 1; fi
  key="$(cd "$dir" 2>/dev/null && pwd -P)" || key="$dir"
  _shim_hung_get "$key" && return 2
  local -a bound=()
  ! have timeout || bound=(timeout -k 1 "$secs")
  ( cd "$dir" 2>/dev/null; exec ${bound[@]+"${bound[@]}"} "$mise" which "${path##*/}" ) >/dev/null 2>&1 </dev/null || rc=$?
  case "$rc" in
    0) return 1 ;;
    124|137) SHIM_ERR="$(_shim_bound_reason mise "$rc" "$secs")"; _shim_hung_set "$key" "$SHIM_ERR"; return 2 ;;
  esac
  rc=0
  out="$(cd "$dir" 2>/dev/null; exec ${bound[@]+"${bound[@]}"} "$path" --version 2>&1 >/dev/null </dev/null)" || rc=$?
  case "$rc" in
    0) return 1 ;;
    124|137) SHIM_ERR="$(_shim_bound_reason "the ${path##*/} shim" "$rc" "$secs")"; return 2 ;;
  esac
  SHIM_ERR="$(printf '%s\n' "$out" | sed -n '1{s/^mise ERROR //;p}')"
  [ -n "$SHIM_ERR" ] || SHIM_ERR="mise resolves no version for ${path##*/}"
  return 0
}

# The node mise selects from <dir> (`mise current node`, bounded as above),
# or nothing when it cannot say.
shim_mise_node() { # <dir>
  local secs="${CEL_SHIM_CHECK_SECS:-5}" v
  case "$secs" in ''|*[!0-9]*|0) secs=5 ;; esac
  have mise || return 0
  local -a bound=(); ! have timeout || bound=(timeout -k 1 "$secs")
  v="$(cd "$1" 2>/dev/null && ${bound[@]+"${bound[@]}"} mise current node 2>/dev/null </dev/null)" || return 0
  printf '%s' "${v%%[[:space:]]*}"
}

# The global mise context: the node agents get unless a workspace's own mise
# config selects another, and the one `npm install -g` reinstalls into from
# there. setup, update and doctor ask from here, so the answer does not
# depend on which directory they were run from; cel run asks from the
# launch's own cwd (where the runtime really starts).
shim_global_dir() { printf '%s' "${HOME:-/}"; }

# A REQUEST CARRYING A LOOPBACK-ONLY SECRET NEVER GOES THROUGH A PROXY. curl
# honours http_proxy / HTTPS_PROXY / ALL_PROXY even for 127.0.0.1 and
# localhost unless told otherwise, and the proxy would be handed the bearer -
# the gateway api-key spends every subscription and the management key opens
# every credential in the vault. So the proxy variables are dropped for this
# one curl, it is told --noproxy '*', and --disable (which curl honours only
# as the FIRST argument) keeps a ~/.curlrc from adding a proxy or a header.
# Every curl that carries the gateway's api-key or management key goes here.
curl_direct() { # <curl args...>
  env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    curl --disable --noproxy '*' "$@"
}

# Is <url> an http(s) URL whose host is this machine's loopback - 127.0.0.1,
# ::1 or localhost, nothing that merely resolves there - with no user info?
url_is_loopback() { # <url>
  local rest host
  case "$1" in http://*|https://*) ;; *) return 1 ;; esac
  rest="${1#*://}"; rest="${rest%%/*}"; rest="${rest%%\?*}"; rest="${rest%%#*}"
  case "$rest" in *@*) return 1 ;; esac
  case "$rest" in
    \[*\]|\[*\]:*) host="${rest#\[}"; host="${host%%\]*}" ;;
    *) host="${rest%%:*}" ;;
  esac
  case "${host,,}" in 127.0.0.1|::1|localhost) return 0 ;; *) return 1 ;; esac
}

# IS THIS PROCESS UNDER ITS OWN CHECKOUT'S TEST SUITE? The test seams that
# redirect what cel trusts - CEL_PROC_DIR (whose /proc an identity is proven
# from), CEL_FORGE_CURL (which binary the forge token goes to) and the gh
# stubs (CEL_WS_GH_BIN, fed from CEL_FORGE_GH, GH or CEL_AFK_GH: cel_gh_bin) -
# are honoured only then, and the environment alone never says so: an agent can
# export anything (`X=CEL_TESTING; export $X=1` included) but cannot change
# which processes are its ancestors. So the answer is read from the kernel:
# some ancestor is the same bash as this shell (its /proc/<pid>/exe) running,
# as its script, this file's own tests/run.sh - located from where this
# function was defined, never from CEL_ROOT, which common.sh inherits. Only
# `bash <that run.sh>` counts: an argument elsewhere (`bash -c '...' run.sh`,
# `find run.sh -exec ...`) or another program renamed with `exec -a` does not.
# Reads only, no forks.
#
# THE LIMIT, PLAINLY: the seams are trusted for EVERY process beneath this
# checkout's tests/run.sh, not only for its tests. Any agent code the suite
# runs - a test file, or a tool a test calls that a PATH put first - can
# point CEL_PROC_DIR at a tree that vouches for a forged identity, or
# CEL_FORGE_CURL or a gh stub at a binary that then receives a token. That is
# accepted: agents run as the owner's Unix user, so they can read the token
# file and call the forge API directly anyway; nothing in-process stops a
# determined one. What this does stop is the easy route - an exported
# variable, from anywhere, outside the suite. tests/run.sh refuses to start
# with BASH_ENV or ENV set, and the guard refuses an agent line that runs the
# suite with BASH_ENV, ENV, PATH or exported functions; both are tripwires,
# not a boundary.
cel_under_suite() {
  local runner="${BASH_SOURCE[0]%/*}/../tests/run.sh" pid="$$" n=0 stat arg
  local -a argv
  [ -f "$runner" ] || return 1
  while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ "$n" -lt 64 ]; do
    argv=()
    { mapfile -d '' -t argv < "/proc/$pid/cmdline"; } 2>/dev/null
    if [ "${#argv[@]}" -ge 2 ] && [ "/proc/$pid/exe" -ef "/proc/$$/exe" ]; then
      arg="${argv[1]}"
      case "$arg" in /*) ;; *) arg="/proc/$pid/cwd/$arg" ;; esac
      [ "$arg" -ef "$runner" ] && return 0
    fi
    { read -r stat < "/proc/$pid/stat"; } 2>/dev/null || return 1
    stat="${stat##*) }"; stat="${stat#* }"; pid="${stat%% *}"
    n=$((n + 1))
  done
  return 1
}

# THE BINARIES A TRUST DECISION RUNS ARE NOT THE CALLER'S TO CHOOSE. PATH is
# the caller's: an agent that puts a directory of its own first hands cel a
# `curl` that is piped the Forgejo token, a `gh` run with GH_TOKEN, a `jq`
# or `yq` whose answer decides who may write. So cel forge and cel team run
# on cel_tool_path instead, and the token's own binaries are resolved by
# cel_tool_bin:
#   - the system directories ($_CEL_SYSTEM_PATH) - where root installs the
#     distribution's packages; normally root-owned, though /usr/local/bin
#     is user-writable on some boxes (Homebrew, a chown), and then a binary
#     there is no better than one in the home directory;
#   - then this user's ~/.local/bin, where `cel setup` installs what the
#     distribution does not ship (yq, herdr, sometimes gh) - its home taken
#     from /etc/passwd, not $HOME, which the caller sets. A binary there is
#     the user's own file and cannot be told from one an agent planted by
#     overwriting it; that is the least-bad rule left: a prepended PATH or a
#     moved HOME no longer chooses, a write over the installed file still
#     would (and the guard is the tripwire for that).
# `--system` takes the system directories only: curl and jq, which every
# supported box has there, are never taken from a home directory.
# Under this checkout's own suite (cel_under_suite) tests stub tools on PATH
# or as shell functions, so the caller's PATH stands and cel_tool_bin answers
# the bare name (found as it always was) - unless the test sets
# CEL_TOOL_PATH_REAL to prove the production rule.
_CEL_SYSTEM_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cel_passwd_home() { # this user's home, from /etc/passwd by EUID
  local name pw uid gid gecos home shell
  { while IFS=: read -r name pw uid gid gecos home shell; do
      if [ "$uid" = "$EUID" ] && [[ "$home" == /?* ]]; then printf '%s' "$home"; return 0; fi
    done < /etc/passwd; } 2>/dev/null
  return 1
}
_cel_tools_from_caller() { [ -z "${CEL_TOOL_PATH_REAL:-}" ] && cel_under_suite; }
cel_tool_path() { # -> the PATH a trust decision runs on
  local home
  if _cel_tools_from_caller; then printf '%s' "$PATH"; return 0; fi
  if home="$(cel_passwd_home)"; then printf '%s:%s/.local/bin' "$_CEL_SYSTEM_PATH" "$home"
  else printf '%s' "$_CEL_SYSTEM_PATH"; fi
}
cel_tool_bin() { # <name> [--system] -> its absolute path on cel_tool_path, else fails
  local d dirs
  if _cel_tools_from_caller; then printf '%s' "$1"; return 0; fi
  dirs="$_CEL_SYSTEM_PATH"
  [ "${2:-}" = --system ] || dirs="$(cel_tool_path)"
  local IFS=:
  for d in $dirs; do
    if [ -f "$d/$1" ] && [ -x "$d/$1" ]; then printf '%s' "$d/$1"; return 0; fi
  done
  return 1
}
# THE gh THIS PROCESS RUNS. Every gh call - with a workspace's token
# (ws_gh) or with the box's own login (afk, release, gc) - runs this binary:
# cel_tool_bin gh, never the caller's PATH. A stub a caller names (the
# tests' CEL_WS_GH_BIN, CEL_FORGE_GH, GH, CEL_AFK_GH, passed in here) is
# honoured only under this checkout's own suite (cel_under_suite); anywhere
# else it names nothing. Fails, saying so, when the box has no gh there.
cel_gh_bin() { # [stub] -> the gh to run
  if [ -n "${1:-}" ] && [ "$1" != gh ] && cel_under_suite; then printf '%s' "$1"; return 0; fi
  cel_tool_bin gh && return 0
  printf 'cel: no gh in the system directories or ~/.local/bin - cel runs no gh found elsewhere on PATH\n' >&2
  return 1
}
# AND IT RUNS ON THE TOOL PATH. gh starts git (remote and branch resolution,
# pr create and merge) and a pager through PATH, and they inherit its
# environment - GH_TOKEN included - so a git planted first on the caller's
# PATH would be handed the token. Every gh call goes through here: PATH is
# cel_tool_path, and the pager is cat (never one the caller names). Other
# caller variables (GH_CONFIG_DIR, GH_EDITOR, BROWSER, ...) still reach gh;
# the environment is not scrubbed.
cel_gh_run() { # <gh> <args...>
  local bin="$1" tp; shift
  tp="$(cel_tool_path)"
  PATH="$tp" GH_PAGER=cat PAGER=cat "$bin" "$@"
}

# The owner's Hermes desktop starts per-profile SSH servers, not previews or
# abandoned fixtures. Match executable ownership plus an actual argv option;
# code/prompt text mentioning the option is not evidence. Never open its token.
_cel_hermes_desktop_server() { # <resolved-exe> <NUL-cmdline-file>
  case "$1" in "${HOME%/}/.hermes/"*) ;; *) return 1 ;; esac
  local arg value expected=0
  while IFS= read -r -d '' arg || [ -n "$arg" ]; do
    if [ "$expected" -eq 1 ]; then
      [[ -n "$arg" && "$arg" != --* ]] && return 0
      expected=0
    fi
    case "$arg" in
      --) return 1 ;;
      --ssh-session-token-file) expected=1 ;;
      --ssh-session-token-file=*)
        value="${arg#--ssh-session-token-file=}"
        [[ -n "$value" && "$value" != --* ]] && return 0 ;;
    esac
  done 2>/dev/null < "$2"
  return 1
}


# THE LATEST RESULT OF EACH CHECK. gh's statusCheckRollup lists every run a
# commit ever had, so a check that failed and then passed on a re-run (a new
# event, a corrected base) still showed as FAILURE beside its SUCCESS and
# blocked landing a green PR. Keep one entry per workflow+check name (or
# status context): the run that started last. Prefix a jq program with this
# and call `latest_checks` on .statusCheckRollup.
# A run is ordered by when it STARTED: a re-run in progress has no real
# completedAt (gh reports 0001-01-01 for it), and it must win over the older
# finished run, so the check counts as pending rather than green.
CEL_JQ_LATEST_CHECKS='def _cel_t: if . == null or startswith("0001-") then "" else . end;
def latest_checks: group_by([(.workflowName // ""), (.name // .context // "")])
  | map(sort_by([(.startedAt | _cel_t), (.completedAt | _cel_t)]) | last);'

# THE ALIAS RULE. A herdr agent name, a mailbox name and a worker's
# cwd-derived identity are the same string, so they must be made by one
# idempotent rule - otherwise one worker can end up with two mailboxes.
#
# Lowercase, squeeze anything outside [a-z0-9_-] to one dash, start at the
# first letter, cut to 32. A dash is stripped only when the result is SHORTER
# than 32 - the dash at position 32 is the truncation boundary of an alias that
# already exists and is kept, so no established alias is renamed. The bash
# wrappers (_inbox_sanitise, _run_agent_name, _steward_agent_name) just call
# this, and tools/dash/v2.mjs asks it rather than keep a copy.
cel_alias_norm() { # <string> -> alias
  local n="$1"
  # An already-clean name (the common case: an alias being re-normalised) is
  # handled with builtins - `cel fleet` counts the processes it starts. tr -s
  # also squeezes a literal `--`, so a name containing one takes the full path.
  if [[ "$n" =~ ^[a-z][a-z0-9_-]*$ ]] && [[ "$n" != *--* ]]; then :
  else
    n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-')"
    n="${n#"${n%%[a-z]*}"}"
  fi
  if [ "${#n}" -gt 32 ]; then
    n="${n:0:32}"
  else
    while [ "${#n}" -lt 32 ] && [ "${n%-}" != "$n" ]; do n="${n%-}"; done
  fi
  printf '%s' "$n"
}

# A PANE'S CWD, AS A PATH. When the directory a pane stands in is removed,
# herdr reports its cwd with the kernel's literal ` (deleted)` suffix; left on,
# it leaks into derived names (a repo slug GitHub does not know). Shell code
# deriving a path or name from a pane cwd strips it here (a few jq filters
# test the suffix inline). The stripped path still does not exist, so "is the
# directory gone" reads the same.
pane_cwd() { # <cwd> -> the path without a trailing " (deleted)"
  printf '%s' "${1% (deleted)}"
}

# WHO HOLDS THE SUITE LOCK, ASKED OF THE KERNEL. The lock file's first line is
# only what the last tests/run.sh or cel-verify wrote: anything else can hold
# the lock (`flock <lockfile> bun test` writes nothing), and then the file names
# a pid that may be long gone. And /proc/locks lists a flock under the pid that
# TOOK it, which for a runner is the short-lived `flock` child it ran on its
# own descriptor - gone a moment later, its pid free for reuse. So a pid counts
# only when one of its descriptors - one whose link resolves to the lock
# file's path - shows the lock itself in its fdinfo: a `lock:` line of type
# FLOCK on this inode. A waiter has the file open too, and shows none; a POSIX
# or OFD lock on the same inode is not what blocks `flock -n`, and counts for
# nothing. The file is the inode plus that path, never stat's st_dev: on btrfs
# subvolumes and overlayfs st_dev is not the s_dev the kernel prints, so the
# device is whatever the kernel's own lines say.
# First the pids /proc/locks lists with a FLOCK on the inode; else every
# process with the file open (fuser, or a walk of <proc>/*/fd when the proc
# root is a fixture or there is no fuser), the oldest that holds it. Prints
# "<pid> <start-ticks>"; fails when nobody can be named.
suite_lock_live_holder() { # <lock-path> [proc-root]
  local proc="${2:-/proc}" path ino pat t pid di s best="" bs="" f
  local -a cands=()
  path="$(readlink -f -- "$1" 2>/dev/null)" && [ -n "$path" ] || path="$1"
  ino="$(stat -L -c '%i' -- "$path" 2>/dev/null)" && [ -n "$ino" ] || return 1
  pat="${path//\\/\\\\}"; pat="${pat//\*/\\*}"; pat="${pat//\?/\\?}"; pat="${pat//\[/\\[}"
  if [ -r "$proc/locks" ]; then
    # "<id>: FLOCK ADVISORY WRITE <pid> <maj:min:ino> ..."; a waiter's line
    # has "->" after the id, so its type is not in this field
    while read -r _ t _ _ pid di _; do
      [ "$t" = FLOCK ] && [ "${di##*:}" = "$ino" ] || continue
      # the device is the kernel's: this line's, matched in the holder's fdinfo
      s="$(_suite_lock_held_by "$proc" "$pid" "$di" "$pat")" && { printf '%s %s\n' "$pid" "$s"; return 0; }
    done < "$proc/locks"
  fi
  if [ "$proc" = /proc ] && have fuser; then
    # an absolute path: fuser takes no `--`
    read -r -a cands <<<"$(fuser "$path" 2>/dev/null)"
  else
    while IFS= read -r f; do
      f="${f#"$proc"/}"; cands+=("${f%%/*}")
    done < <(find "$proc"/[0-9]*/fd -mindepth 1 -maxdepth 1 -lname "$pat" 2>/dev/null)
  fi
  for pid in "${cands[@]}"; do
    s="$(_suite_lock_held_by "$proc" "$pid" "$ino" "$pat")" || continue
    if [ -z "$best" ] || [ "$s" -lt "$bs" ]; then best="$pid"; bs="$s"; fi
  done
  [ -n "$best" ] || return 1
  printf '%s %s\n' "$best" "$bs"
}
_suite_lock_held_by() { # <proc> <pid> <maj:min:ino | ino> <fd-link-pattern> -> its start ticks, when it holds the lock
  local fd l t di line
  local -a f=()
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || return 1
  while IFS= read -r fd; do
    { while IFS= read -r l; do
        # "lock: <id>: FLOCK ADVISORY WRITE <pid> <maj:min:ino> ..."
        case "$l" in lock:*) ;; *) continue ;; esac
        read -r _ _ t _ _ _ di _ <<<"$l"
        [ "$t" = FLOCK ] && { [ "$di" = "$3" ] || [ "${di##*:}" = "$3" ]; } || continue
        { IFS= read -r line < "$1/$2/stat"; } 2>/dev/null || return 1
        read -r -a f <<<"${line##*)}"
        [[ "${f[19]:-}" =~ ^[0-9]+$ ]] || return 1
        printf '%s' "${f[19]}"; return 0
      done < "$1/$2/fdinfo/${fd##*/}"; } 2>/dev/null
  done < <(find "$1/$2/fd" -mindepth 1 -maxdepth 1 -lname "$4" 2>/dev/null)
  return 1
}

# Expand a leading ~ only. Deliberately NOT `eval echo`: manifest paths are data
# edited by humans, and eval would make them a command-injection surface and
# mangle any path containing spaces or glob characters.
expand() {
  local p="$1"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  printf '%s' "$p"
}

# yq must be the PYTHON build (kislyuk, jq syntax). The Go build (mikefarah)
# parses the same file differently and returns different results silently.
# Capture, do not pipe: under `set -o pipefail` a `grep -q` short-circuit
# SIGPIPEs yq and the non-zero exit made every build look like the wrong one.
yq_ok() {
  local v
  have yq || return 1
  v="$(yq --version 2>&1)" || return 1
  case "$v" in *[Mm]ikefarah*) return 1;; esac
  return 0
}

# Resolve the locally known origin default; never guess past a broken
# authoritative origin/HEAD. Reuse main/master only when that symbolic ref
# is absent, and require a real commit before returning any answer.
repo_default_ref() { # <repository-dir> -> verified origin ref, or failure
  local ref rc
  if ref="$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    case "$ref" in origin/*) ;; *) return 1;; esac
    git -C "$1" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || return 1
    printf '%s' "$ref"
    return 0
  else
    rc=$?
    [ "$rc" -eq 1 ] || return 1
  fi
  # A direct ref called origin/HEAD is malformed, not an absent symbolic ref.
  if git -C "$1" show-ref --verify --quiet refs/remotes/origin/HEAD; then
    return 1
  else
    rc=$?
    [ "$rc" -eq 1 ] || return 1
  fi
  for ref in origin/main origin/master; do
    if git -C "$1" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s' "$ref"
      return 0
    fi
  done
  return 1
}
