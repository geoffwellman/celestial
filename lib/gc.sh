# shellcheck shell=bash
# cel gc reclaims only positively identified, settled worktrees and panes.
# A closed PR, a missing pane, or elapsed process lifetime is not proof that
# work is disposable. Unknown discovery, process, or Git state always keeps it.
[ -n "${_CEL_GC:-}" ] && return 0
_CEL_GC=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"
# shellcheck source=lib/solo.sh
. "${BASH_SOURCE[0]%/*}/solo.sh"   # solo_review_get: the recorded reviewer verdicts
# shellcheck source=lib/manifest.sh
. "${BASH_SOURCE[0]%/*}/manifest.sh"
# shellcheck source=lib/orphans.sh
. "${BASH_SOURCE[0]%/*}/orphans.sh"   # cel gc --orphans
# shellcheck source=lib/box.sh
. "${BASH_SOURCE[0]%/*}/box.sh"   # cel gc --box
# shellcheck source=lib/run.sh
. "${BASH_SOURCE[0]%/*}/run.sh"   # the reviewer registry cel run writes
# shellcheck source=lib/memory.sh
. "${BASH_SOURCE[0]%/*}/memory.sh"   # what an idle agent was holding

# WHOSE ACCOUNT ASKS ABOUT A CHECKOUT. ws_of_checkout names the
# workspace a worktree belongs to, and a workspace with `github.user` must be asked about
# as that account. A declared account that is not logged in makes the call
# fail, which every caller here already reads as UNKNOWN: kept, never closed.
# Without a workspace it is plain gh - the box's (cel_gh_bin), never one the
# caller's PATH offers.
_gc_gh() { # <dir> <gh args...> - run in <dir>, as its workspace's account
  local d="$1" w bin; shift
  w="$(ws_of_checkout "$d")" || w=""
  if [ -n "$w" ]; then (cd "$d" && ws_gh "$w" "$@"); return; fi
  bin="$(cel_gh_bin)" || return 1
  (cd "$d" && cel_gh_run "$bin" "$@")
}

_gc_landed_clean() { # <dir> [MERGED|CLOSED|NONE]
  local def status head pr
  def="$(repo_default_ref "$1")" || return 1
  git -C "$1" symbolic-ref --quiet HEAD >/dev/null 2>&1 || return 1
  status="$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null)" || return 1
  [ -z "$status" ] || return 1
  if git -C "$1" merge-base --is-ancestor HEAD "$def" 2>/dev/null; then return 0; fi
  [ "${2:-}" = MERGED ] || return 1
  # Squash merges need not preserve ancestry. A successful GitHub lookup
  # must attest that this EXACT local head was merged; later commits keep it.
  head="$(git -C "$1" rev-parse --verify HEAD 2>/dev/null)" \
    && pr="$(_gc_gh "$1" pr view --json state,headRefOid 2>/dev/null)" || return 1
  printf '%s' "$pr" | jq -e --arg h "$head" '.state == "MERGED" and .headRefOid == $h' >/dev/null 2>&1
}

_gc_flag_unlanded() { # <dir>
  local d="$1" def n status last
  def="$(repo_default_ref "$d")" || { c_warn "UNKNOWN: $d has no verifiable remote default - kept"; return 0; }
  n="$(git -C "$d" rev-list --count "$def..HEAD" 2>/dev/null)" \
    && status="$(git -C "$d" status --porcelain --untracked-files=all 2>/dev/null)" \
    && last="$(git -C "$d" log -1 --format=%ct 2>/dev/null)" \
    || { c_warn "UNKNOWN: cannot inspect $d - kept"; return 0; }
  [[ "$n" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] || return 0
  [ "$n" -gt 0 ] || [ -n "$status" ] || return 0
  [ $(( $(date +%s) - last )) -ge 172800 ] || return 0
  c_warn "UNLANDED: $d holds $n commit(s) or uncommitted changes, last commit 2d+ ago - keep or explicitly discard it"
}

_gc_pr_state() { # <worktree-dir> -> MERGED|CLOSED|OPEN|NONE|UNKNOWN
  local branch rows
  branch="$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    || { printf UNKNOWN; return 0; }
  # Unlike pr view, a successful empty list distinguishes no PR from an API
  # outage. A later PR on a reused branch takes precedence over an older one.
  rows="$(_gc_gh "$1" pr list --head "$branch" --state all --limit 100 --json state,updatedAt 2>/dev/null)" \
    || { printf UNKNOWN; return 0; }
  printf '%s' "$rows" | jq -er '
    if type != "array" then "UNKNOWN"
    elif length == 0 then "NONE"
    elif all(.[]; (.state == "MERGED" or .state == "CLOSED" or .state == "OPEN") and (.updatedAt | type == "string"))
    then sort_by(.updatedAt) | last | .state else "UNKNOWN" end' 2>/dev/null || printf UNKNOWN
}

# A SOLO WORKTREE'S PR, BY ITS EXACT HEAD. `cel solo land` deletes the merged
# branch, so an agent that reuses the name for a fresh worktree would inherit
# the old PR's MERGED - and a fresh worktree at an ancestor of main reads as
# landed clean - and gc would remove it from under the agent. Only a PR whose
# head IS this worktree's HEAD speaks for it; anything else is NONE (kept).
_gc_solo_pr_state() { # <worktree-dir> -> MERGED|CLOSED|OPEN|NONE|UNKNOWN
  local branch head rows
  branch="$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    && head="$(git -C "$1" rev-parse --verify HEAD 2>/dev/null)" \
    || { printf UNKNOWN; return 0; }
  rows="$(_gc_gh "$1" pr list --head "$branch" --state all --limit 100 --json state,headRefOid 2>/dev/null)" \
    || { printf UNKNOWN; return 0; }
  printf '%s' "$rows" | jq -er --arg h "$head" '
    if type != "array" then "UNKNOWN"
    else [.[] | select(.headRefOid == $h) | .state] as $s
      | if ($s | index("MERGED")) then "MERGED" elif ($s | index("OPEN")) then "OPEN"
        elif ($s | index("CLOSED")) then "CLOSED" else "NONE" end end' 2>/dev/null || printf UNKNOWN
}

_gc_panes_known() { # <pane-list-json>
  printf '%s' "$1" | jq -e '
    .result.panes | type == "array" and length > 0 and all(.[];
      (.pane_id | type == "string" and length > 0) and
      (.cwd | type == "string" and length > 0) and
      (.agent_status | IN("idle", "done", "working", "blocked", "unknown", "none")))' >/dev/null 2>&1
}

_gc_panes_settled() { # <pane-list-json>
  _gc_panes_known "$1" || return 1
  printf '%s' "$1" | jq -e 'all(.result.panes[]; .agent_status | IN("idle", "done", "none"))' >/dev/null
}

# An unregistered worktree can still host a hand-started process. Unknown
# /proc visibility is a veto, not an empty process list.
# ONE /proc PASS PER RUN. The cwd table is read once per run and every
# worktree is matched against it - the fast path, which can only KEEP. A
# table that could not be read is still a veto. Nothing is removed on the
# snapshot's word alone: _gc_has_process_live re-walks /proc for that one
# worktree immediately before any removal, so a process started mid-sweep is
# still seen.
_GC_CWDS="" _GC_CWDS_STATE=""
_gc_cwd_reset() { _GC_CWDS="" _GC_CWDS_STATE=""; }
# AN UNREADABLE cwd IS A VETO - EXCEPT FOR A FIXED SET OF SYSTEM PROCESSES.
# Our own uid runs privilege-separated or non-dumpable processes whose cwd the
# kernel will not show us: the user systemd manager and its (sd-pam),
# ssh-agent, sshd-session, sftp-server. Left as vetoes, any one of them would
# keep EVERY worktree live. These are matched by
# exact comm and none of them is an agent, a runtime or a tool that could sit
# in a worktree. Anything else unreadable, an agent included, still vetoes.
# Chosen over an environ PWD fallback: environ is unreadable for exactly the
# same processes, and PWD is only where the process started, not where it is now.
_gc_unreadable_is_system() { # <comm>
  case "$1" in systemd|'(sd-pam)'|ssh-agent|sshd-session|sftp-server) return 0;; esac
  return 1
}
_gc_cwd_of() { readlink "/proc/$1/cwd" 2>/dev/null; }
_gc_pid_exists() { [ -d "/proc/$1" ]; }
_gc_comm_of() { local c=""; read -r c < "/proc/$1/comm" 2>/dev/null; printf '%s' "$c"; }
_gc_cwd_load() { # fills _GC_CWDS with "pid<TAB>cwd" lines; state ok|none|unknown
  local pids pid cwd rc out=""
  if pids="$(pgrep -u "$(id -u)" 2>/dev/null)"; then :; else
    rc=$?; [ "$rc" -eq 1 ] && { _GC_CWDS_STATE=none; return 0; }
    _GC_CWDS_STATE=unknown; return 0
  fi
  for pid in $pids; do
    if cwd="$(_gc_cwd_of "$pid")"; then
      out="$out$pid"$'\t'"$cwd"$'\n'
    elif _gc_pid_exists "$pid"; then
      _gc_unreadable_is_system "$(_gc_comm_of "$pid")" && continue
      _GC_CWDS_STATE=unknown; return 0
    fi
  done
  _GC_CWDS="$out" _GC_CWDS_STATE=ok
}
_gc_has_process() { # <worktree-dir> -> 0 present/unknown, 1 absent
  [ -n "$_GC_CWDS_STATE" ] || _gc_cwd_load
  case "$_GC_CWDS_STATE" in none) return 1;; unknown) return 0;; esac
  local line cwd
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cwd="${line#*$'\t'}"
    case "$cwd" in "$1"|"$1"/*) return 0;; esac
  done <<< "$_GC_CWDS"
  return 1
}

# The live check, run only right before a removal: a fresh /proc walk.
_gc_has_process_live() { # <worktree-dir> -> 0 present/unknown, 1 absent
  local _GC_CWDS="" _GC_CWDS_STATE=""
  _gc_has_process "$1"
}

# The variables `cel run` puts in every agent's environment (lib/run.sh).
# /proc/<pid>/environ is fixed at exec, so they survive a runtime that
# rewrites its own argv - which is the whole reason they exist: pi sets
# process.title, so a live pi agent's cmdline is `pi` plus padding and the
# role path the argv scan below looks for is never in it.

# A readable-looking /proc/<pid>/environ can still refuse to open - a setuid
# process, or one that exited between the check and the read. Failing quietly
# is right; printing "Permission denied" over every GC summary is not.
_gc_environ_lines() { # <pid> -> NUL-separated environ on stdout, or fail
  { cat "/proc/$1/environ"; } 2>/dev/null
}

_gc_env_role() { # <pid> <registry-names> -> role file path, or fail
  local pid="$1" names="$2" item role="" wsvar="" ws wsdir
  while IFS= read -r -d '' item; do
    case "$item" in
      CEL_ROLE_FILE=*) role="${item#*=}";;
      CEL_WORKSPACE=*) wsvar="${item#*=}";;
    esac
  done < <(_gc_environ_lines "$pid")
  [ -n "$role" ] && [ -n "$wsvar" ] || return 1
  # A root or orchestrator pane is identified and deliberately NOT removable,
  # exactly as its argv form has always been.
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    wsdir="$(registry_path "$ws")" || return 1
    [ "$wsdir" = "$wsvar" ] || continue
    case "$role" in
      "$wsdir/.cel/role-reviewer.md")
        [ -f "$role" ] || return 1
        printf '%s' "$role"; return 0 ;;
    esac
    return 1
  done <<< "$names"
  return 1
}

# --- foreground group ownership --------------------------------------------
# A verified root may carry helpers it launched (e.g. Claude's Hindsight MCP
# server, a direct child in the same foreground group). The root is still
# proven by the exact checks in _gc_process_identity (pid, birth, pane, role,
# session, comm); every OTHER foreground process must be a declared
# helper (agents.yaml `owned_children`) that is
#   - exactly the declared path under $HOME (no suffix trust),
#   - a DIRECT child of the verified root pid (a grandchild is not owned),
#   - born after the root (its start tick is not earlier),
#   - in the same herdr pane (HERDR_PANE_ID inherited),
#   - exactly `<argv0 basename> <argv[1] ending in the declared suffix>`.
# Anything else - a preview server, a test run, a tool child, an unreadable
# process - is a veto. Never "any child".
_gc_ppid_of() { # <pid> -> parent pid
  local line; line="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  local -a f; read -r -a f <<< "${line##*) }"
  [[ "${f[1]:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${f[1]}"
}
_gc_start_of() { # <pid> -> start tick
  local line; line="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  local -a f; read -r -a f <<< "${line##*) }"
  [[ "${f[19]:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${f[19]}"
}
# The root of a pane's foreground group: the one member whose parent is not
# another member. More than one such member (two unrelated groups' worth of
# processes) is no root at all.
_gc_fg_root() { # <process-info json> -> root pid
  local info="$1" pids pid par root="" member
  pids="$(printf '%s' "$info" | jq -er '[.result.process_info.foreground_processes[]?.pid | select(type == "number")] | if length > 0 then join(" ") else empty end')" || return 1
  for pid in $pids; do
    par="$(_gc_ppid_of "$pid")" || return 1
    member=0
    case " $pids " in *" $par "*) member=1 ;; esac
    [ "$member" -eq 1 ] && continue
    [ -z "$root" ] || return 1
    root="$pid"
  done
  [ -n "$root" ] || return 1
  printf '%s' "$root"
}
_gc_fg_helpers_owned() { # <root-pid> <runtime> <process-info json> <pane>
  local root="$1" rt="$2" info="$3" pane="$4" pids pid par rstart cstart item envpane matched comm_ argv0 suffix
  local -a args
  pids="$(printf '%s' "$info" | jq -er '[.result.process_info.foreground_processes[]?.pid] | map(tostring) | join(" ")')" || return 1
  rstart="$(_gc_start_of "$root")" || return 1
  for pid in $pids; do
    [ "$pid" != "$root" ] || continue
    par="$(_gc_ppid_of "$pid")" || return 1
    [ "$par" = "$root" ] || return 1
    cstart="$(_gc_start_of "$pid")" || return 1
    [ "$cstart" -ge "$rstart" ] || return 1
    envpane=""
    while IFS= read -r -d '' item; do
      case "$item" in HERDR_PANE_ID=*) envpane="${item#*=}";; esac
    done < <(_gc_environ_lines "$pid")
    [ "$envpane" = "$pane" ] || return 1
    args=(); mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null || return 1
    [ "${#args[@]}" -eq 2 ] || return 1
    matched=0
    while IFS=$'\t' read -r argv0 suffix; do
      [ -n "$argv0" ] && [ -n "$suffix" ] || continue
      [ "${args[0]##*/}" = "$argv0" ] || continue
      # EXACT PROVENANCE, not a suffix: the declared path anchored at this
      # user's home (or its realpath). `node /tmp/.hindsight/.../mcp-server.js`
      # ends with the same suffix and is some other program.
      if [ "${args[1]}" = "$HOME$suffix" ] \
         || { [ -e "${args[1]}" ] && [ "$(readlink -f "${args[1]}")" = "$(readlink -f "$HOME$suffix" 2>/dev/null)" ]; }; then
        matched=1; break
      fi
    done < <(agent_owned_children "$rt")
    [ "$matched" -eq 1 ] || return 1
  done
  return 0
}

# Exact binding supported for runtimes launched with a plane role-file flag.
# cwd/comm alone never establishes ownership. Root/orchestrator roles and
# runtimes without that verifiable launch stamp are deliberately retained.
_gc_process_identity() { # <pid> <agents-json> <registry-names>
  local pid="$1" agents="$2" names="$3" pane="" item cwd row rt flag ws wsdir role="" statline start info proof=false
  [ -r "/proc/$pid/environ" ] && [ -r "/proc/$pid/cmdline" ] || return 1
  while IFS= read -r -d '' item; do
    case "$item" in HERDR_PANE_ID=*) pane="${item#*=}";; esac
  done < <(_gc_environ_lines "$pid")
  [ -n "$pane" ] && [[ "$pane" != rex/* ]] || return 1
  cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || return 1
  # An agent_session of null is a herdr-side gap, not evidence that the pid is
  # a stranger: two live omp panes on this box carry one. It disqualifies a
  # process only when nothing else proves whose it is.
  if role="$(_gc_env_role "$pid" "$names")"; then proof=true; else role=""; fi
  row="$(printf '%s' "$agents" | jq -ce --arg p "$pane" --arg d "$cwd" --argjson proof "$proof" '
    [.result.agents[] | select(.pane_id == $p and .cwd == $d and (.backend // "herdr") != "rex")] |
    if length == 1 and (.[0].agent_status | IN("idle", "done")) and
      (.[0].state_change_seq | type == "number") and
      (.[0].terminal_id | type == "string") and
      (.[0].name | type == "string" and length > 0) and
      ((.[0].agent_session.value | type == "string" and length > 0)
       or ($proof and (.[0].agent_session.value == null)))
    then .[0] else empty end')" || return 1
  # The inherited pane id alone could also belong to a descendant. Herdr's
  # current foreground process group must independently bind this exact PID.
  info="$(herdr pane process-info --pane "$pane" 2>/dev/null)" \
    && printf '%s' "$info" | jq -e --arg p "$pane" --argjson pid "$pid" '
      .result.process_info | .pane_id == $p and
      (.shell_pid | type == "number") and .shell_pid != $pid and
      (.foreground_process_group_id | type == "number") and
      (.foreground_processes | type == "array" and length >= 1 and any(.[]; .pid == $pid))' >/dev/null || return 1
  rt="$(printf '%s' "$row" | jq -r .agent)"
  [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "$rt" ] || return 1
  # The foreground group is this pid ALONE or this pid plus declared helpers
  # that are its own direct children. The pid must also be the group's root.
  [ "$(_gc_fg_root "$info")" = "$pid" ] || return 1
  _gc_fg_helpers_owned "$pid" "$rt" "$info" "$pane" || return 1
  local -a fields=()
  # ONLY when the launcher left no variables: an omp or claude pane started by
  # an older build carries the role path in argv and nothing else, and must
  # keep working until it restarts.
  if [ "$proof" != true ]; then
    [ "$(agent_injection "$rt" strategy)" = append_flag_file ] || return 1
    flag="$(agent_injection "$rt" flag)" || return 1
    [ -n "$flag" ] || return 1
    local -a args=()
    mapfile -d '' -t args < "/proc/$pid/cmdline"
    for item in "${args[@]}"; do
      case "$item" in *role-root.md*|*role-orchestrator.md*) return 1;; esac
    done
    while IFS= read -r ws; do
      [ -n "$ws" ] || continue
      wsdir="$(registry_path "$ws")" || return 1
      local i
      for ((i=0; i+1<${#args[@]}; i++)); do
        [ "${args[i]}" = "$flag" ] || continue
        case "${args[i+1]}" in
          "$wsdir/.cel/role-reviewer.md") role="${args[i+1]}";;
        esac
      done
    done <<< "$names"
  fi
  [ -n "$role" ] && [ -f "$role" ] || return 1
  statline="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
  read -r -a fields <<< "${statline##*) }"
  start="${fields[19]:-}"
  [[ "$start" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$row" | jq -c --arg pid "$pid" --arg start "$start" --arg role "$role" --arg rt "$rt" \
    '{pid:$pid,start:$start,role:$role,runtime:$rt,name:.name,pane:.pane_id,terminal:.terminal_id,session:.agent_session,seq:.state_change_seq,cwd:.cwd}'
}

# Why a kept row was kept, in the order the checks run. One number for every
# kept worktree meant a GC that could identify NOTHING printed the same line
# as one with nothing to do - which is how the pi blindness above went
# unnoticed for weeks.
_GC_KEPT_REASONS=(busy symlink live unlanded open-pr no-pr unidentified refused stubborn)

_gc_keep_reset() {
  unset GC_KEPT GC_UNIDENTIFIED
  declare -gA GC_KEPT=()
  declare -ga GC_UNIDENTIFIED=()
}

_gc_keep() { # <reason> [dir]
  local r="$1" d="${2:-}"
  [ -n "${GC_KEPT[*]+set}" ] || _gc_keep_reset
  GC_KEPT["$r"]=$(( ${GC_KEPT["$r"]:-0} + 1 ))
  if [ "$r" = unidentified ] && [ -n "$d" ]; then GC_UNIDENTIFIED+=("$d"); fi
  kept=$(( ${kept:-0} + 1 ))
  # A dry run says why, row by row: a bare total says nothing about which
  # worker is holding what.
  if [ "${dry:-0}" -eq 1 ] && [ -n "${cwd:-}" ]; then printf '  kept %s: %s\n' "$cwd" "$r"; fi
  return 0
}

_gc_kept_line() { # <summary|doctor>
  local r n parts=() out=""
  case "$1" in
    summary)
      for r in "${_GC_KEPT_REASONS[@]}"; do
        n="${GC_KEPT[$r]:-0}"
        [ "$n" -gt 0 ] || continue
        parts+=("$n $r")
      done
      [ "${#parts[@]}" -gt 0 ] || return 0
      printf -v out '%s, ' "${parts[@]}"
      printf ' (%s)' "${out%, }"
      ;;
    doctor)
      n="${GC_KEPT[unidentified]:-0}"
      [ "$n" -gt 0 ] || return 0
      printf 'gc: %d worktrees unidentified - cel gc --dry-run to see them' "$n"
      ;;
  esac
  return 0
}

# cel doctor reports the LAST sweep's blindness rather than running its own:
# a doctor that swept would take the registry lock every time anyone ran it.
_gc_kept_state() { printf '%s' "${CEL_GC_KEPT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/cel/gc-kept.json}"; }

_gc_kept_save() {
  local f r json='{}' tmp=""
  f="$(_gc_kept_state)"
  for r in "${_GC_KEPT_REASONS[@]}"; do
    json="$(printf '%s' "$json" | jq --arg k "$r" --argjson n "${GC_KEPT[$r]:-0}" '.[$k] = $n')" || return 0
  done
  mkdir -p "$(dirname "$f")" && tmp="$(mktemp "$f.tmp.XXXXXX")" || return 0
  printf '%s\n' "$json" > "$tmp" && mv -f -- "$tmp" "$f" || rm -f -- "$tmp"
  return 0
}

gc_doctor_line() { # the one line cel doctor prints, from the same renderer
  local f r n
  f="$(_gc_kept_state)"
  _gc_keep_reset
  [ -r "$f" ] || return 0
  for r in "${_GC_KEPT_REASONS[@]}"; do
    n="$(jq -r --arg k "$r" '.[$k] // 0 | tostring' "$f" 2>/dev/null)" || return 0
    [[ "$n" =~ ^[0-9]+$ ]] && GC_KEPT["$r"]="$n"
  done
  _gc_kept_line doctor
}

# A zombie still has a /proc directory until its launcher waits for it, so
# "the directory exists" is not "still running".
_gc_alive() { # <pid>
  local line state
  line="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  state="${line##*) }"; state="${state%% *}"
  [ "$state" != Z ]
}

# pi IGNORES SIGTERM, so the old single TERM reported a reap that never
# happened. A runtime declaring `signal: int` in agents.yaml gets SIGINT
# first, then CEL_GC_GRACE seconds, then TERM, then it is reported and kept.
# GC never sends -9: a worker holding an unfinished commit is worth more than
# a tidy process list.
_gc_reap_signal() { # <pid> <runtime> -> 0 exited, 1 still alive
  local pid="$1" rt="$2" grace="${CEL_GC_GRACE:-10}" i
  if [ "$(agent_get "$rt" signal)" != int ]; then
    kill -TERM "$pid" 2>/dev/null
    return
  fi
  kill -INT "$pid" 2>/dev/null || return 1
  for ((i=0; i<grace*10; i++)); do _gc_alive "$pid" || return 0; sleep 0.1; done
  kill -TERM "$pid" 2>/dev/null || return 1
  for ((i=0; i<grace*10; i++)); do _gc_alive "$pid" || return 0; sleep 0.1; done
  return 1
}

_gc_agents_removable() { # <agents-json> <dir> <registry-names>
  local agents="$1" rows row pane info pid
  rows="$(printf '%s' "$agents" | jq -ce --arg d "$2" '
    .result.agents | if type == "array" and all(.[];
      (.cwd | type == "string" and length > 0) and (.pane_id | type == "string" and length > 0))
    then [.[] | select(.cwd == $d or (.cwd | startswith($d + "/")))]
    else error("invalid agent roster") end')" || return 1
  while IFS= read -r row; do
    # Presence is a veto until Rex has a backend-specific retirement proof.
    printf '%s' "$row" | jq -e '.backend == "rex" or (.pane_id | startswith("rex/"))' >/dev/null && return 1
    pane="$(printf '%s' "$row" | jq -r .pane_id)"
    info="$(lock_spawn "${lock_fd:-} ${fd:-}" herdr pane process-info --pane "$pane" 2>/dev/null)" \
      && pid="$(_gc_fg_root "$info")" \
      && _gc_process_identity "$pid" "$agents" "$3" >/dev/null || return 1
  done < <(printf '%s' "$rows" | jq -c '.[]')
  return 0
}

_gc_reap() { # <hours> <dry> <agents-json> <registry-names>; sets reaped
  local hours="$1" dry="$2" agents="$3" names="$4"
  local file="${XDG_STATE_HOME:-$HOME/.local/state}/cel/gc-idle.json" fd previous='{}' next='{}' tmp="" boot now ignored pids pid identity key since fresh current identities='[]'
  boot="$(cat /proc/sys/kernel/random/boot_id)" && read -r now ignored < /proc/uptime || return 0
  now="${now%%.*}"
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  if [ "$dry" -eq 0 ]; then
    mkdir -p "$(dirname "$file")" || return 0
    # Held on an inherited descriptor, so every spawn below goes through
    # lock_spawn: a child that outlives this sweep would hold the lock with
    # it (see lib/registry.sh).
    exec {fd}>"$file.lock" && flock -n "$fd" || return 0
  fi
  if [ -e "$file" ]; then
    previous="$(jq -ce --arg boot "$boot" 'if .boot == $boot and (.idle | type == "object") then .idle else {} end' "$file" 2>/dev/null)" || previous='{}'
  fi
  pids="$(pgrep -u "$(id -u)" 2>/dev/null)" || return 0
  for pid in $pids; do
    identity="$(_gc_process_identity "$pid" "$agents" "$names")" || continue
    identities="$(printf '%s' "$identities" | jq --argjson item "$identity" '. + [$item]')"
  done
  while IFS= read -r identity; do
    pid="$(printf '%s' "$identity" | jq -r .pid)"
    key="$identity"
    since="$(printf '%s' "$previous" | jq -r --arg k "$key" '.[$k] // empty')"
    [[ "$since" =~ ^[0-9]+$ ]] && [ "$since" -le "$now" ] || since="$now"
    if [ $((now - since)) -ge $((hours * 3600)) ]; then
      fresh="$(lock_spawn "${fd:-} ${lock_fd:-}" cel_agent_list 2>/dev/null)" || continue
      current="$(_gc_process_identity "$pid" "$fresh" "$names")" || continue
      [ "$identity" = "$current" ] || continue
      if [ "$dry" -eq 1 ]; then
        c_ok "would reap idle plane pid $pid after $((now-since)) observed idle seconds"
      elif _gc_reap_signal "$pid" "$(printf '%s' "$identity" | jq -r .runtime)"; then
        c_ok "reaped idle plane pid $pid after $((now-since)) observed idle seconds"
      else
        c_warn "idle plane pid $pid did not exit - kept"
        _gc_keep stubborn
        continue
      fi
      reaped=$((reaped+1))
    else
      next="$(printf '%s' "$next" | jq --arg k "$key" --argjson n "$since" '.[$k] = $n')"
    fi
  done < <(printf '%s' "$identities" | jq -c 'group_by(.pane)[] | select(length == 1) | .[0]')
  # Snapshot only still-eligible identities. Working, resumed, replaced,
  # unobserved, and unknown agents lose their prior idle clocks.
  if [ "$dry" -eq 0 ]; then
    tmp="$(mktemp "$file.tmp.XXXXXX")" || return 0
    if ! printf '%s' "$next" | jq --arg boot "$boot" '{boot:$boot,idle:.}' > "$tmp" \
      || ! mv -f -- "$tmp" "$file"; then rm -f -- "$tmp"; fi
    flock -u "$fd"
    exec {fd}>&-
  fi
  return 0
}

# THE STATE OF ONE PULL REQUEST, asked of GitHub directly rather than
# inferred from a branch: a reviewer has no worktree and no branch of its
# own, only the PR number it was started for. Anything that is not one of the
# three states GitHub actually returns is UNKNOWN, and unknown is never
# closed - this file's whole history is bugs where "could not tell" was
# treated as "nothing there".
_gc_reviewer_pr_state() { # <repo> <pr> [cwd] [repodir] -> MERGED|CLOSED|OPEN|UNKNOWN
  local out state
  out="$(_gc_reviewer_pr_json "$1" "$2" "${3:-}" "${4:-}" state)" || { printf UNKNOWN; return 0; }
  state="$(printf '%s' "$out" | jq -r 'if (.state | type) == "string" then .state else "UNKNOWN" end' 2>/dev/null)" \
    || state=UNKNOWN
  case "$state" in MERGED|CLOSED|OPEN) printf '%s' "$state";; *) printf UNKNOWN;; esac
}

_gc_reviewer_pr_json() { # <repo> <pr> <cwd> <repodir> <fields> -> gh pr view JSON, or fail
  local out cwd wsdir slug f="$5"
  cwd="$(pane_cwd "${3:-}")"
  # Asked from the reviewer's own checkout when it still has one, because
  # that is where gh can resolve the repository from its remote.
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    out="$(_gc_gh "$cwd" pr view "$2" --json "$f" 2>/dev/null)" || return 1
  else
    # The folder is gone: resolve the GitHub repo the way `cel run
    # reviewer` does - declared url, else the clone's origin - never
    # from the folder name. The bare name is the last resort.
    IFS=$'\t' read -r wsdir slug < <(_gc_reviewer_slug "$1" "${4:-}") || true
    if [ -n "${slug:-}" ] && [ -n "${wsdir:-}" ]; then
      out="$(ws_gh "$wsdir" pr view "$2" --repo "$slug" --json "$f" 2>/dev/null)" || return 1
    else
      local bin; bin="$(cel_gh_bin)" || return 1
      out="$(cel_gh_run "$bin" pr view "$2" --repo "$1" --json "$f" 2>/dev/null)" || return 1
    fi
  fi
  printf '%s' "$out"
}

# Which workspace a reviewer's repo belongs to, and its GitHub slug: the row's
# recorded clone first, else the first registered workspace with that repo.
_gc_reviewer_slug() { # <repo> [repodir] -> wsdir<TAB>owner/name, or fail
  local repo="$1" repodir="${2:-}" wsdir="" ws slug
  if [ -n "$repodir" ] && [ -d "$repodir" ]; then wsdir="$(ws_of_checkout "$repodir")" || wsdir=""; fi
  if [ -z "$wsdir" ]; then
    repodir=""
    while IFS= read -r ws; do
      [ -n "$ws" ] || continue
      ws="$(registry_path "$ws" 2>/dev/null)" || continue
      if [ -n "$ws" ] && [ -d "$ws/repos/$repo" ]; then wsdir="$ws"; repodir="$ws/repos/$repo"; break; fi
    done < <(registry_names 2>/dev/null || true)
  fi
  [ -n "$wsdir" ] || return 1
  slug="$(ws_repo_github_slug "$wsdir" "$repo" "$repodir" 2>/dev/null)" || return 1
  printf '%s\t%s\n' "$wsdir" "$slug"
}

# KEPT AS UNKNOWN FOR A DAY IS A BLOCKER. The fail-safe keeps a reviewer
# whose PR cannot be read; warning every steward tick is noise. Past 24h the
# pane is reported to root once, keyed by a condition fp so a repeat
# supersedes rather than stacks, and marked reported so later ticks stay quiet.
_gc_unknown_file() { printf '%s' "${CEL_GC_UNKNOWN_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/cel/gc-reviewer-unknown.json}"; }

# Keyed by pane AND reviewer: herdr reuses pane ids, and a reused pane is a
# different reviewer whose clock starts fresh.
_gc_unknown_note() { # <pane> <repo> <pr> <wsdir-or-empty>
  local f now cur since reported ws="" key="$1 $2#$3"
  f="$(_gc_unknown_file)"; now="$(date +%s)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  cur="$(jq -c . "$f" 2>/dev/null)" || cur='{}'
  [ -n "$cur" ] || cur='{}'
  since="$(printf '%s' "$cur" | jq -r --arg p "$key" '.[$p].since // empty')"
  reported="$(printf '%s' "$cur" | jq -r --arg p "$key" '.[$p].reported // false')"
  [[ "$since" =~ ^[0-9]+$ ]] || since="$now"
  if [ "$reported" != true ] && [ $((now - since)) -ge 86400 ]; then
    [ -n "${4:-}" ] && ws="$(ws_name "$4" 2>/dev/null)" || true
    cmd_inbox send root "reviewer pane $1 for $2#$3 has been kept as UNKNOWN for over 24h - its PR state cannot be read; close it by hand or fix the lookup" \
      --from gc ${ws:+--workspace "$ws"} --kind blocked --fp "gc-reviewer-unknown-$1-$2-$3" >/dev/null 2>&1 \
      && reported=true   # a send that failed was not a report; the next tick retries
  fi
  printf '%s' "$cur" | jq --arg p "$key" --argjson s "$since" --argjson r "$reported" \
    '.[$p] = {since:$s, reported:$r}' > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" || rm -f "$f.tmp"
  return 0
}

_gc_unknown_clear() { # <pane> <repo> <pr>
  local f; f="$(_gc_unknown_file)"
  [ -f "$f" ] || return 0
  jq --arg p "$1 $2#$3" 'del(.[$p])' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" || rm -f "$f.tmp"
  return 0
}

# Everything this sweep can see, from both directions: the rows `cel run`
# recorded, and the reviewer panes on the roster that nobody recorded. A pane
# in both is ONE reviewer - keyed by pane id, so it is never closed or
# counted twice.
_gc_reviewer_candidates() { # <rows> <agents-json> -> one JSON object per line
  local out='[]' repo pr pane agent status rd backend observed ws attributed
  while IFS=$'\x1f' read -r repo pr pane agent rd backend ws; do
    [ -n "$repo" ] && [ -n "$pane" ] || continue
    # A recorded pane that is not on the roster has gone by other means.
    # `gone` is a stale row, dropped as bookkeeping rather than closed.
    status="$(printf '%s' "$2" | jq -r --arg p "$pane" \
      '[.result.agents[]? | select(.pane_id == $p)][0].agent_status // "gone"' 2>/dev/null)" || status=unknown
    observed="$(printf '%s' "$2" | jq -r --arg p "$pane" '[.result.agents[]? | select(.pane_id == $p)][0].backend // empty' 2>/dev/null)"
    backend="${observed:-${backend:-herdr}}"
    # A row with no workspace of its own gets the one its live process
    # proves (reviewer_pane_workspace); the write-back records it.
    attributed=false
    if [ -z "$ws" ] && [ "$status" != gone ]; then
      ws="$(reviewer_pane_workspace "$2" "$pane")"
      [ -z "$ws" ] || attributed=true
    fi
    out="$(printf '%s' "$out" | jq -c --arg r "$repo" --arg p "$pr" --arg pane "$pane" \
      --arg a "$agent" --arg s "$status" --arg c "$(_gc_reviewer_cwd "$2" "$pane")" --arg rd "$rd" --arg b "$backend" --arg ws "$ws" \
      --argjson attributed "$attributed" \
      '. + [{repo:$r, pr:$p, pane:$pane, agent:$a, status:$s, cwd:$c, repodir:$rd, backend:$b, workspace:$ws, recorded:true, attributed:$attributed}]')"
  done < <(printf '%s' "$1" | jq -r "$_REVIEWERS_JQ_SCOPE"'.[] | [.repo, (.pr | tostring), .pane, (.agent // ""), (.repodir // ""), (.backend // "herdr"), (rv_ws // "")] | join("\u001f")')
  while IFS=$'\t' read -r repo pr pane agent status backend; do
    [ -n "$pane" ] || continue
    printf '%s' "$out" | jq -e --arg p "$pane" 'any(.[]; .pane == $p)' >/dev/null 2>&1 && continue
    out="$(printf '%s' "$out" | jq -c --arg r "$repo" --arg p "$pr" --arg pane "$pane" \
      --arg a "$agent" --arg s "$status" --arg c "$(_gc_reviewer_cwd "$2" "$pane")" --arg b "${backend:-herdr}" \
      --arg ws "$(reviewer_pane_workspace "$2" "$pane")" \
      '. + [{repo:$r, pr:$p, pane:$pane, agent:$a, status:$s, cwd:$c, backend:$b, workspace:$ws, recorded:false}]')"
  done < <(reviewers_discover "$2")
  printf '%s' "$out" | jq -c '.[]'
}

_gc_reviewer_cwd() { # <agents-json> <pane> -> the pane's cwd, or empty
  printf '%s' "$1" | jq -r --arg p "$2" \
    '[.result.agents[]? | select(.pane_id == $p)][0].cwd // ""' 2>/dev/null | { IFS= read -r c || true; pane_cwd "${c:-}"; }
}

# A reviewer exists to review one pull request, and when that pull request
# closes the reviewer is done. Not idle-for-a-while, not probably-finished -
# done, by a fact about the world. The vetoes are the worktree pass's own:
# a reviewer mid-sentence on a PR that merged a second ago keeps its pane,
# and a PR whose state cannot be read keeps its reviewer and says so.
#
# A reviewer that survives is WRITTEN BACK, recorded or not: the index
# catches up with the box, so the next `cel run reviewer` for that PR reuses
# the pane instead of splitting another one beside it.
#
# THE WRITE BACK IS A MERGE, NOT A SNAPSHOT. This sweep reads the rows once
# and then spends seconds in `gh` per reviewer; a snapshot write would erase
# a `cel run reviewer` landing in that window, and the next call for its PR
# would split a duplicate pane. So the sweep carries only the two facts it
# actually established - which panes it closed or found gone, and which live
# panes had no row - and applies them under the registry lock to whatever
# the file says by then. A row this sweep never saw is never touched.
_gc_reviewers() { # <dry> <agents-json>; sets reviewers_closed
  local dry="$1" agents="$2" rows cand drop='[]' adopt='[]' attrib='[]' repo pr pane agent status cwd state repodir backend recover=()
  reviewers_closed=0
  printf '%s' "$agents" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 || return 0
  local rv_what="" rv_prev='{}' rv_next='{}' rv_file
  rv_file="$(_gc_reviewer_stop_state)"
  [ -f "$rv_file" ] && rv_prev="$(jq -c 'if type == "object" then . else {} end' "$rv_file" 2>/dev/null || printf '{}')"
  # An unreadable registry refuses `cel run reviewer`; this pass is what
  # recovers it. Every live reviewer is then unrecorded, so the ones this
  # sweep keeps are adopted, and the write below rebuilds the index from them.
  rows="$(reviewers_rows)" || { rows='[]'; recover=(--recover); }
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    IFS=$'\t' read -r repo pr pane agent status cwd < <(printf '%s' "$cand" \
      | jq -r '[.repo, .pr, .pane, .agent, .status, .cwd] | @tsv')
    backend="$(printf '%s' "$cand" | jq -r '.backend // "herdr"')"
    repodir="$(printf '%s' "$cand" | jq -r '.repodir // ""')"
    if [ "$backend" = rex ] || [[ "$pane" == rex/* ]]; then
      local retirement retirement_rc=0 retirement_status retirement_reason retirement_detail
      retirement="$(rex_reviewer_retire "$repo" "$pr" "$pane" "$agent" "$dry" "$repodir")" || retirement_rc=$?
      retirement_status="$(printf '%s' "$retirement" | jq -er '.status | select(type == "string")' 2>/dev/null)" || retirement_status=unknown
      if [ "$retirement_rc" = 0 ] && [ "$dry" = 1 ] && [ "$retirement_status" = retired ]; then
        c_ok "would reconcile completed native retirement for $repo#$pr (pane $pane; no runtime close)"
        continue
      fi
      if [ "$retirement_rc" = 0 ] && [ "$dry" = 1 ] && [ "$retirement_status" = eligible ]; then
        c_ok "would retire completed native reviewer for $repo#$pr (pane $pane; evidence and checkout kept)"
      elif [ "$retirement_rc" = 0 ] && [ "$dry" = 0 ] && [ "$retirement_status" = retired ]; then
        drop="$(printf '%s' "$drop" | jq -c --arg p "$pane" '. + [$p]')"
        reviewers_closed=$((reviewers_closed + 1))
        c_ok "retired native reviewer for $repo#$pr (pane $pane; native evidence and checkout kept)"
      elif [ "$status" = gone ] && _gc_rex_row_runtime_gone "$agent" "$pane" "$retirement"; then
        # Gone by other means, with no retirement of ours in flight: the row
        # is bookkeeping, and keeping it would refuse every relaunch for the
        # PR. Only the row goes - receipt, checkout and native log stay.
        if [ "$dry" -eq 1 ]; then
          c_ok "would drop the stale row for $repo#$pr (Rex pane $pane gone, runtime exited; evidence kept)"
        else
          drop="$(printf '%s' "$drop" | jq -c --arg p "$pane" '. + [$p]')"
          c_ok "dropped the stale row for $repo#$pr (Rex pane $pane gone, runtime exited; evidence kept)"
        fi
      else
        _gc_reviewers_adopt
        if [ "$retirement_status" != protected ]; then
          retirement_reason="$(printf '%s' "$retirement" | jq -r '.reason // "native retirement proof unavailable"' 2>/dev/null)" || retirement_reason='native retirement proof unavailable'
          retirement_detail="$(printf '%s' "$retirement" | jq -r '.detail // ""' 2>/dev/null)" || retirement_detail=''
          c_warn "native reviewer retirement incomplete for $repo#$pr: $retirement_reason${retirement_detail:+ ($retirement_detail)}"
        fi
      fi
      continue
    fi
    if [ "$status" = gone ]; then
      # A recorded pane that is no longer on the roster has gone by other
      # means. Dropping the row is bookkeeping, not a closure - but its
      # checkout is now owned by nobody, so it goes too.
      [ "$dry" -eq 1 ] || { reviewer_checkout_release "$repo" "$pr" "$pane"
        drop="$(printf '%s' "$drop" | jq -c --arg p "$pane" '. + [$p]')"; }
      continue
    fi
    state="$(_gc_reviewer_pr_state "$repo" "$pr" "$cwd" "$repodir")"
    if [ "$state" = UNKNOWN ]; then
      [ "$dry" -eq 1 ] || _gc_unknown_note "$pane" "$repo" "$pr" \
        "$(_gc_reviewer_slug "$repo" "$repodir" | cut -f1)"
    else
      [ "$dry" -eq 1 ] || _gc_unknown_clear "$pane" "$repo" "$pr"
    fi
    case "$state" in
      OPEN)
        # FINISHED IS A FACT TOO: idle, an approved verdict recorded for
        # the head GitHub shows now, and quiet for the window. Its checkout is
        # kept - `cel run reviewer --repo --pr` brings the reviewer back.
        if _gc_reviewer_finished "$repo" "$pr" "$cwd" "$repodir" "$pane" "$status"; then
          if [ "$dry" -eq 1 ]; then
            c_ok "would close the finished reviewer for $repo#$pr (verdict recorded, pane $pane)"
          elif lock_spawn "${lock_fd:-}" herdr pane close "$pane" >/dev/null 2>&1; then
            drop="$(printf '%s' "$drop" | jq -c --arg p "$pane" '. + [$p]')"
            local mbr; mbr="$(mem_tree_rss_mb "$cwd" 2>/dev/null || printf 0)"; [[ "$mbr" =~ ^[0-9]+$ ]] || mbr=0
            c_ok "closed the reviewer for $repo#$pr (verdict recorded for the current head, pane $pane, freed ~${mbr}M; checkout kept)"
            reviewers_closed=$((reviewers_closed + 1))
            rv_what="$rv_what${rv_what:+, }$repo#$pr reviewer ~${mbr}M"
            continue
          else
            c_warn "could not close pane $pane for $repo#$pr - kept"
          fi
        fi
        _gc_reviewers_adopt; continue ;;
      UNKNOWN)
        _gc_reviewers_adopt
        c_warn "UNKNOWN: cannot read the state of $repo#$pr - its reviewer is kept"; continue ;;
    esac
    case "$status" in
      idle|done|none) ;;
      *) _gc_reviewers_adopt
         c_warn "reviewer for $repo#$pr is $status on a $state PR - kept until it is idle"; continue ;;
    esac
    if [ "$dry" -eq 1 ]; then
      c_ok "would close the reviewer for $repo#$pr (PR $state, pane $pane)"
      continue
    fi
    if ! lock_spawn "${lock_fd:-}" herdr pane close "$pane" >/dev/null 2>&1; then
      _gc_reviewers_adopt
      c_warn "could not close pane $pane for $repo#$pr - kept"
      continue
    fi
    drop="$(printf '%s' "$drop" | jq -c --arg p "$pane" '. + [$p]')"
    # The pane is gone; its checkout goes with it - a reviewer checkout that
    # outlives its reviewer is litter. Released before the row is dropped,
    # because the row is where the path is written down.
    reviewer_checkout_release "$repo" "$pr" "$pane"
    c_ok "closed the reviewer for $repo#$pr (PR $state, pane $pane)"
    reviewers_closed=$((reviewers_closed + 1))
  done < <(_gc_reviewer_candidates "$rows" "$agents")
  # A dry run establishes nothing to write: it closes no pane, drops no
  # stale row and adopts nothing.
  [ "$dry" -eq 1 ] && return 0
  mkdir -p "$(dirname "$rv_file")" 2>/dev/null && printf '%s\n' "$rv_next" > "$rv_file" 2>/dev/null || true
  # The steward's pressure warning names what this sweep stopped; an empty
  # file says nothing was. Best effort: stderr is redirected before the file
  # is opened, so a write that cannot open it stays quiet.
  local idle_last; idle_last="$(_gc_idle_stop_last)"
  mkdir -p "$(dirname "$idle_last")" 2>/dev/null || true
  if [ -n "$rv_what" ]; then printf '%s\n' "$rv_what" 2>/dev/null > "$idle_last" || true
  else : 2>/dev/null > "$idle_last" || true; fi
  [ "${#recover[@]}" -gt 0 ] || printf '%s' "$drop$adopt$attrib" | grep -q '[^][]' || return 0
  reviewers_update "${recover[@]}" --argjson drop "$drop" --argjson adopt "$adopt" --argjson attrib "$attrib" \
    'map(select((.pane as $p | $drop | index($p)) == null))
     | map(. as $row | ([$attrib[] | select(.pane == $row.pane)][0]) as $a
           | if $a != null and (($row.workspace // "") == "") then .workspace = $a.workspace else . end)
     | . as $cur
     | $cur + [$adopt[] | select((.pane as $p | $cur | map(.pane) | index($p)) == null)]' \
    || c_warn "could not update the reviewer registry - stale rows remain"
  return 0
}

# A recorded Rex reviewer whose pane left the roster is gone only when all of
# these are facts: the retirement attempt answered with valid JSON and names
# no retirement proof of ours (prepared/exit debt is settled by replay, never
# dropped), no launch for the alias is unresolved, and the receipt is absent,
# belongs to another pane, or records a PID generation that has exited.
_gc_rex_row_runtime_gone() { # <agent> <pane> <retirement-json>
  local agent="$1" pane="$2" f
  [ -n "$agent" ] || return 1
  printf '%s' "$3" | jq -e 'type == "object" and (has("proof") | not)' >/dev/null 2>&1 || return 1
  f="$(_rex_file "$agent")"
  [ ! -e "$f.pending" ] && [ ! -e "$f.pid" ] && [ ! -L "$f" ] || return 1
  [ -e "$f" ] || return 0
  _rex_receipt_valid "$f" || return 1
  [ "$(jq -r '.pane_id // ""' "$f")" = "$pane" ] || return 0
  ! _rex_live "$f"
}

# THE ONE TARGETED RETIREMENT: `cel sessions retire-reviewer` and `cel solo
# land` (after its merge) share it, with the same proof the GC sweep uses.
# It never releases a checkout or native log. Prints the result JSON; returns
# 0 retired (eligible on a dry run), 3 protected, 2 unknown, and 4 when this
# PR has no Rex reviewer to retire - none at all, or a Herdr one, which keeps
# its canonical GC path.
reviewer_retire_target() { # <wsdir> <repo> <pr> <dry 0|1>
  local wsdir="$1" repo="$2" pr="$3" dry="$4" roster rows selected pane agent backend result rc=0 status
  roster="$(cel_agent_list 2>/dev/null)" \
    && printf '%s' "$roster" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 \
    || { printf '%s\n' '{"status":"unknown","reason":"native_inventory_unreadable"}'; return 2; }
  rows="$(reviewers_rows)" || { printf '%s\n' '{"status":"unknown","reason":"reviewer_registry_unreadable"}'; return 2; }
  # Another workspace's row for the same repo and PR is another review, and a
  # row with no proven workspace is this one's only by the registry key's own
  # rule (lib/run.sh rv_key: no other workspace has the repo).
  selected="$(_gc_reviewer_candidates "$rows" "$roster" \
    | jq -sc --arg r "$repo" --arg p "$pr" --arg ws "$wsdir" --argjson here "$(_reviewers_here "$wsdir" "$repo")" \
      '[.[] | select(.repo == $r and (.pr|tostring) == $p
          and (if (.workspace // "") == "" then $here else .workspace == $ws end))]')" \
    || { printf '%s\n' '{"status":"unknown","reason":"candidate_inventory_invalid"}'; return 2; }
  case "$(printf '%s' "$selected" | jq length)" in
    0) printf '%s\n' '{"status":"absent","reason":"no_reviewer_for_pull_request"}'; return 4 ;;
    1) ;;
    *) printf '%s\n' '{"status":"unknown","reason":"multiple_reviewers_for_pull_request"}'; return 2 ;;
  esac
  IFS=$'\t' read -r pane agent backend < <(printf '%s' "$selected" | jq -r '.[0] | [.pane,.agent,(.backend // "herdr")] | @tsv')
  { [ "$backend" = rex ] || [[ "$pane" = rex/* ]]; } \
    || { printf '%s\n' '{"status":"absent","reason":"herdr_reviewer_keeps_gc_path"}'; return 4; }
  [ -n "$agent" ] || { printf '%s\n' '{"status":"unknown","reason":"reviewer_identity_missing"}'; return 2; }
  result="$(rex_reviewer_retire "$repo" "$pr" "$pane" "$agent" "$dry" "$wsdir/repos/$repo")" || rc=$?
  status="$(printf '%s' "$result" | jq -er '.status | select(type == "string")' 2>/dev/null)" \
    || { printf '%s\n' '{"status":"unknown","reason":"invalid native retirement response"}'; return 2; }
  if [ "$rc" = 0 ] && [ "$dry" = 0 ] && [ "$status" = retired ]; then
    if ! reviewers_update --arg r "$repo" --arg p "$pr" --arg pane "$pane" \
      'map(select(.repo != $r or (.pr|tostring) != $p or .pane != $pane))'; then
      printf '%s' "$result" | jq -c '.status="unknown" | .reason="native runtime retired; reviewer registry cleanup remains owed"'
      return 2
    fi
  elif [ "$rc" = 0 ]; then
    case "$dry:$status" in
      1:eligible|1:retired) : ;;
      *) printf '%s\n' '{"status":"unknown","reason":"native retirement phase did not match its result"}'; return 2 ;;
    esac
  fi
  printf '%s\n' "$result" | jq -c --arg pane "$pane" '. + {pane:$pane}'
  return "$rc"
}

cmd_reviewer_retire() { # repo#pr [--workspace W] [--dry-run]
  local usage='usage: cel sessions retire-reviewer <repo>#<pr> [--workspace W] [--dry-run]'
  [ $# -ge 1 ] || die "$usage"
  local ref="$1" workspace="" dry=0 wsdir repo pr result rc=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) [ $# -ge 2 ] || die "$usage"; workspace="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "$usage" ;;
    esac
  done
  [[ "$ref" = *#* ]] || die "$usage"
  repo="${ref%%#*}"; pr="${ref#*#}"
  [ -n "$repo" ] && [[ "$pr" =~ ^[0-9]+$ ]] || die "$usage"
  if [ -n "$workspace" ]; then wsdir="$(registry_require "$workspace")"
  else wsdir="$(ws_current)" || die 'reviewer retirement requires --workspace outside a registered workspace'; fi
  ws_repo_names "$wsdir" | grep -qxF "$repo" || die "reviewer retirement: repo is not in the requested workspace"
  result="$(reviewer_retire_target "$wsdir" "$repo" "$pr" "$dry")" || rc=$?
  if [ "$rc" = 4 ]; then
    case "$(printf '%s' "$result" | jq -r .reason)" in
      herdr_reviewer_keeps_gc_path) die 'targeted native retirement supports Rex reviewers; Herdr reviewers retain their canonical GC path' ;;
      *) die 'reviewer retirement: no unique recorded reviewer target' ;;
    esac
  fi
  printf '%s\n' "$result"
  return "$rc"
}

# THE FINISHED REVIEWER. A reviewer whose approved verdict is recorded (the
# solo verdict file) for the PR's CURRENT head has nothing left to do until the
# author pushes again - and a push is a new head, which its recorded verdict
# no longer covers. N minutes quiet (gc.reviewer_stop_minutes, default 30;
# ~5 under memory pressure) and its pane goes.
_gc_reviewer_stop_state() { printf '%s' "${CEL_GC_REVIEWER_STOP_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/cel/gc-reviewer-stop.json}"; }

gc_reviewer_stop_minutes() {
  local n="${CEL_GC_REVIEWER_STOP_MIN:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || n="$(cel_config_get gc reviewer_stop_minutes 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=30
  if boxguard_pressure; then
    local p="${CEL_GC_REVIEWER_STOP_PRESSURE_MIN:-5}"
    [ "$p" -lt "$n" ] && n="$p"
  fi
  printf '%s' "$n"
}

# Reads/writes rv_prev/rv_next from _gc_reviewers. The clock is keyed by pane
# AND head, so a push restarts it.
_gc_reviewer_finished() { # <repo> <pr> <cwd> <repodir> <pane> <status>
  local repo="$1" pr="$2" cwd="$3" repodir="$4" pane="$5" now since key out head mins
  case "$6" in idle|done) ;; *) return 1 ;; esac
  out="$(_gc_reviewer_pr_json "$repo" "$pr" "$cwd" "$repodir" headRefOid)" || return 1
  head="$(printf '%s' "$out" | jq -r '.headRefOid // empty' 2>/dev/null)"
  [ -n "$head" ] || return 1
  _gc_verdict_recorded "$repo" "$pr" "$head" || return 1
  now="${CEL_GC_NOW:-$(date +%s)}"; key="$pane@$head"
  since="$(printf '%s' "$rv_prev" | jq -r --arg k "$key" '.[$k] // empty')"
  [[ "$since" =~ ^[0-9]+$ ]] && [ "$since" -le "$now" ] || since="$now"
  mins="$(gc_reviewer_stop_minutes)"
  if [ $(( now - since )) -lt $(( mins * 60 )) ]; then
    rv_next="$(printf '%s' "$rv_next" | jq -c --arg k "$key" --argjson n "$since" '.[$k] = $n')"
    return 1
  fi
  return 0
}

# An APPROVED verdict for exactly this head, in any workspace, as `cel solo
# review` records it (solo_review_get, lib/solo.sh) - a finished reviewer
# must not wait for the merge to be closed. A CHANGES verdict is a reviewer
# waiting on a re-push: closing it would leave "pushed - re-review" with
# nobody to read it.
_gc_verdict_recorded() { # <repo> <pr> <head>
  local ws wsdir
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    wsdir="$(registry_path "$ws" 2>/dev/null)" || continue
    solo_review_get "$wsdir" "$1" "$2" | jq -e --arg h "$3" \
      'type == "object" and .verdict == "approved" and .head == $h' >/dev/null 2>&1 && return 0
  done < <(registry_names 2>/dev/null || true)
  return 1
}

# A reviewer that is staying and has no row gets one, with the facts the
# roster gave us and the workspace its live process proves, if any - a row
# without one belongs to no workspace while another also has the repo
# (lib/run.sh _reviewers_here). A recorded one is left exactly as it is: its
# started-at is when it started, not when a sweep noticed it - except that a
# row with no workspace gets the one its process proved.
_gc_reviewers_adopt() { # reads repo/pr/pane/agent/cand from its caller
  [ "$dry" -eq 0 ] || return 0
  if printf '%s' "$cand" | jq -e '.recorded' >/dev/null 2>&1; then
    printf '%s' "$cand" | jq -e '.attributed == true' >/dev/null 2>&1 || return 0
    attrib="$(printf '%s' "$attrib" | jq -c --argjson c "$cand" '. + [{pane:$c.pane, workspace:$c.workspace}]')"
    return 0
  fi
  local ws; ws="$(printf '%s' "$cand" | jq -r '.workspace // ""')"
  local checkout base suffix
  checkout="$(printf '%s' "$cand" | jq -r '.cwd // ""')"
  checkout="$(pane_cwd "$checkout")"
  base="$(reviewer_checkout_path "$repo" "$pr")"
  case "$checkout" in
    "$base") ;;
    "$base".round.*)
      suffix="${checkout#"$base.round."}"; suffix="${suffix%%/*}"
      checkout="$base.round.$suffix" ;;
    *) checkout="" ;;
  esac
  adopt="$(printf '%s' "$adopt" | jq -c --arg r "$repo" --arg p "$pr" --arg pane "$pane" \
    --arg a "$agent" --arg b "${backend:-herdr}" --arg co "$checkout" --arg rd "${repodir:-}" --arg ws "$ws" --argjson t "$(date +%s)" \
    '. + [{repo:$r, pr:$p, pane:$pane, agent:$a, backend:$b, started_at:$t}
      + (if $ws != "" then {workspace:$ws} else {} end)
      + (if $co != "" then {checkout:$co} else {} end)
      + (if $rd != "" then {repodir:$rd} else {} end)]')"
  return 0
}

# THE EMPTY PANES. An agent that already QUIT leaves its shell
# behind. Agentless panes also host proxies, scripts, editors and the owner's
# own shells - so "no agent" alone is never enough. A pane is empty only when herdr reports no
# agent, its foreground is a bare interactive shell with no child, it sits in
# a checkout under ~/.herdr/worktrees (or a directory
# that no longer exists), that checkout holds nothing uncommitted or unpushed
# beyond .pi/ and .agent/ scratch, and no layout declared it. Closing a pane
# never removes its worktree; that stays the worktree pass's own decision.
_gc_idle_kept() { # <reason>; reads why/idle_kept/dry/pane from its caller
  why[$1]=$(( ${why[$1]:-0} + 1 )); idle_kept=$((idle_kept + 1))
  [ "$dry" -eq 1 ] && printf '  kept pane %s (%s): %s\n' "$pane" "$cwd" "$1"
  return 0
}

_gc_worktree_clean() { # <dir> -> 0 when nothing but .pi/.agent scratch is unsaved
  local st up
  st="$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null)" || return 1
  st="$(printf '%s\n' "$st" | grep -Ev '^.. "?\.(pi|agent)/' | grep . || true)"
  up="$(git -C "$1" rev-list HEAD --not --remotes 2>/dev/null)" || return 1
  [ -z "$st" ] && [ -z "$up" ]
}

_gc_shell_children() { # <shell-pid> -> one command name per child process
  [[ "$1" =~ ^[0-9]+$ ]] && [ -d "/proc/$1" ] || return 1
  ps -o comm= --ppid "$1" 2>/dev/null || true
}

_gc_idle_panes() { # <dry> <pane-list-json>; sets idle_closed
  local dry="$1" panes="$2" row pane cwd label info name inwt n
  local -A why=()
  idle_closed=0
  local idle_kept=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\x1f' read -r pane cwd label \
      <<< "$(printf '%s' "$row" | jq -r '[.pane_id, (.cwd // ""), (.label // "")] | join("\u001f")')" || true
    [ -n "$pane" ] || continue
    case "$pane" in rex/*) _gc_idle_kept unknown; continue;; esac
    cwd="$(pane_cwd "$cwd")"
    # A layout names the panes it owns (services, dash, pr-watch, notes);
    # herdr carries that name as the label. A named pane was meant to stay.
    if [ -n "$label" ]; then _gc_idle_kept declared; continue; fi
    case "$cwd" in "$HOME"/.herdr/worktrees/*) inwt=1 ;; *) inwt=0 ;; esac
    info="$(lock_spawn "${lock_fd:-}" herdr pane process-info --pane "$pane" 2>/dev/null)" \
      && name="$(printf '%s' "$info" | jq -er '.result.process_info
        | if (.foreground_processes | length) == 1
             and .foreground_processes[0].pid == .shell_pid
             and (.foreground_processes[0].name | IN("zsh", "bash", "sh", "fish"))
          then "" else ([.foreground_processes[]?.name] | first // "unknown") end')" \
      || { _gc_idle_kept unknown; continue; }
    # The foreground group misses a background or stopped job ('sleep 100 &',
    # a suspended editor): the shell is in front, but it is not idle.
    if [ -z "$name" ]; then
      name="$(_gc_shell_children "$(printf '%s' "$info" | jq -r '.result.process_info.shell_pid')")" \
        || { _gc_idle_kept unknown; continue; }
      name="${name%%$'\n'*}"
    fi
    if [ -n "$name" ]; then
      if [ "$inwt" -eq 1 ]; then _gc_idle_kept "running $name"; else _gc_idle_kept service; fi
      continue
    fi
    [ "$inwt" -eq 1 ] || { _gc_idle_kept "owner shell"; continue; }
    if [ -d "$cwd" ] && ! _gc_worktree_clean "$cwd"; then _gc_idle_kept dirty; continue; fi
    if [ "$dry" -eq 1 ]; then
      printf '  would close empty pane %s (%s)\n' "$pane" "$cwd"
      idle_closed=$((idle_closed + 1)); continue
    fi
    if lock_spawn "${lock_fd:-}" herdr pane close "$pane" >/dev/null 2>&1; then
      c_ok "closed empty pane $pane ($cwd)"
      idle_closed=$((idle_closed + 1))
    else
      c_warn "could not close pane $pane - kept"; _gc_idle_kept refused
    fi
  done < <(printf '%s' "$panes" | jq -c '.result.panes[]? | select((.agent // "") == "")')
  local parts="" r
  for r in "${!why[@]}"; do parts="${parts:+$parts, }${why[$r]} $r"; done
  printf 'gc: %s %d empty panes, kept %d%s\n' "$([ "$dry" -eq 1 ] && printf 'would close' || printf closed)" \
    "$idle_closed" "$idle_kept" "${parts:+: $parts}"
  return 0
}

# The last sweep's stops, one line - the finished reviewers it closed - read
# by the steward's pressure warning so it can name what was done rather than
# promise it.
_gc_idle_stop_last() { printf '%s' "${CEL_GC_IDLE_STOP_LAST:-${XDG_STATE_HOME:-$HOME/.local/state}/cel/gc-idle-stop-last.txt}"; }

cmd_gc() ( # [--reap <hours>] [--orphans] [--box] [--dry-run]; subshell owns lock descriptors
  local reap_hours="" dry=0 orphans=0 box=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reap)
        [ $# -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "cel gc: --reap requires a positive whole number of hours"
        reap_hours="$2"; shift 2 ;;
      --orphans) orphans=1; shift ;;
      --box) box=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) die "cel gc: unknown argument '$1' (want --reap <hours>, --orphans, --box, --dry-run)" ;;
    esac
  done

  # THE PROCESS SWEEP IS ITS OWN VERB, deliberately not a stage of the
  # worktree GC. The worktree GC needs herdr, gh and the registry lock, and
  # skips itself entirely when any of them is unavailable - which is
  # the state a box is in precisely when it is covered in orphans. A sweep of
  # processes nobody owns needs none of that, so it must not inherit the
  # reasons not to run.
  if [ "$orphans" -eq 1 ]; then
    local out
    out="$(orphans_reap "$([ "$dry" -eq 1 ] && printf -- --dry-run)")"
    if [ -z "$out" ]; then printf 'no orphans\n'; return 0; fi
    printf '%s\n' "$out"
    return 0
  fi

  have herdr && have jq && have gh && have flock || die "cel gc: herdr, jq, gh and flock are required"

  # A missing registry or failed roster is not an empty fleet. The registry
  # lock is held on an inherited descriptor for the whole of this
  # subshell, so anything spawned from here - every herdr call, any of which
  # may start a daemon that never exits - is spawned through lock_spawn.
  local lock_fd names ws wsdir roster ids agents panes ws_id cwd state row
  [ -f "$CEL_REGISTRY" ] && [ -r "$CEL_REGISTRY" ] || { c_warn "registry unavailable - GC skipped"; return 0; }
  exec {lock_fd}>"$CEL_REGISTRY.lock" || { c_warn "registry lock unavailable - GC skipped"; return 0; }
  flock -n "$lock_fd" || { c_warn "registry busy - GC skipped"; return 0; }
  names="$(registry_names 2>/dev/null)" || { c_warn "registry unreadable - GC skipped"; return 0; }
  roster="$(lock_spawn "${lock_fd:-}" herdr workspace list 2>/dev/null)" \
    && ids="$(printf '%s' "$roster" | jq -er '.result.workspaces | if type == "array" and all(.[]; .workspace_id | type == "string" and length > 0) then map(.workspace_id) | join("\n") else error("invalid workspace list") end')" \
    && agents="$(lock_spawn "${lock_fd:-}" cel_agent_list 2>/dev/null)" \
    && printf '%s' "$agents" | jq -e '.result.agents | type == "array" and all(.[]; (.cwd | type == "string") and (.pane_id | type == "string") and (.agent_status | type == "string"))' >/dev/null \
    || { c_warn "herdr discovery unavailable - GC skipped"; return 0; }

  local removed=0 reaped=0 kept=0 reviewers_closed=0 managed=$'\n' candidates='[]'
  _gc_keep_reset; _gc_cwd_reset
  # NEVER SILENT: announce the sweep up front, so a slow run is
  # distinguishable from a hung one.
  printf 'gc: sweeping %d workspace(s)%s\n' "$(printf '%s\n' "$names" | grep -c . || true)" \
    "$([ "$dry" -eq 1 ] && printf ' (dry run)')" >&2
  # The panes whose agent is gone entirely. Its own roster read: the
  # agent list omits exactly the panes this pass is for.
  local all_panes idle_closed=0
  if all_panes="$(lock_spawn "${lock_fd:-}" herdr pane list 2>/dev/null)" \
    && printf '%s' "$all_panes" | jq -e '.result.panes | type == "array"' >/dev/null; then
    _gc_idle_panes "$dry" "$all_panes"
  else
    c_warn "pane list unavailable - empty panes kept"
  fi
  # Complete discovery BEFORE removing anything. A failed pane read must not
  # make its worktree look orphaned to a later pass.
  while IFS= read -r ws_id; do
    [ -n "$ws_id" ] || continue
    panes="$(lock_spawn "${lock_fd:-}" herdr pane list --workspace "$ws_id" 2>/dev/null)" && _gc_panes_known "$panes" \
      || { c_warn "pane discovery unavailable - GC skipped"; return 0; }
    cwd="$(printf '%s' "$panes" | jq -r '.result.panes[0].cwd')"
    case "$cwd" in "$HOME"/.herdr/worktrees/*) ;; *) continue;; esac
    managed="$managed$cwd"$'\n'
    _gc_panes_settled "$panes" || { _gc_keep busy; continue; }
    candidates="$(printf '%s' "$candidates" | jq --arg w "$ws_id" --arg d "$cwd" '. + [{workspace:$w, dir:$d}]')"
  done <<< "$ids"
  local d
  for d in "$HOME"/.herdr/worktrees/*/*; do
    [ -d "$d" ] || continue
    case "$managed" in *$'\n'"$d"$'\n'*) continue;; esac
    candidates="$(printf '%s' "$candidates" | jq --arg d "$d" '. + [{workspace:"", dir:$d}]')"
  done
  # A SOLO AGENT'S OWN WORKTREES (<ws>/.cel/solo/<product>/<branch>). They
  # must show a MERGED or CLOSED PR for their exact head: a clean worktree
  # with no PR yet may be one the agent has only just made.
  local sp sd
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    wsdir="$(registry_path "$ws" 2>/dev/null)" || continue
    for sp in $(ws_product_names "$wsdir" 2>/dev/null); do
      while IFS= read -r sd; do
        [ -n "$sd" ] && candidates="$(printf '%s' "$candidates" | jq --arg d "$sd" '. + [{workspace:"", dir:$d, solo:true}]')"
      done < <(ws_solo_worktrees "$wsdir" "$sp")
    done
  done <<< "$names"

  while IFS= read -r row; do
    cwd="$(printf '%s' "$row" | jq -r .dir)"
    ws_id="$(printf '%s' "$row" | jq -r .workspace)"
    local solo_wt; solo_wt="$(printf '%s' "$row" | jq -r '.solo // false')"
    [ "$(readlink -f "$cwd" 2>/dev/null)" = "$cwd" ] || { _gc_keep symlink; continue; }
    if [ -z "$ws_id" ] && _gc_has_process "$cwd"; then _gc_keep live; continue; fi
    # No force removal: Git/herdr must still refuse newly dirty work. Only
    # linked Git worktrees qualify, never an ordinary repository in this dir.
    local gitdir common
    gitdir="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" \
      && common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
      && [ "$gitdir" != "$common" ] || { _gc_keep unlanded; continue; }
    if [ "$solo_wt" = true ]; then state="$(_gc_solo_pr_state "$cwd")"; else state="$(_gc_pr_state "$cwd")"; fi
    case "$state" in MERGED|CLOSED|NONE) ;; *) _gc_keep open-pr; continue;; esac
    [ "$solo_wt" != true ] || [ "$state" != NONE ] || { _gc_keep no-pr; continue; }
    _gc_landed_clean "$cwd" "$state" || { _gc_flag_unlanded "$cwd"; _gc_keep unlanded; continue; }
    # Re-read the exact managed workspace; an orphan must have NO live agent
    # at its path. Unknown/blocked/working never age out of either veto.
    if [ -n "$ws_id" ]; then
      panes="$(lock_spawn "${lock_fd:-}" herdr pane list --workspace "$ws_id" 2>/dev/null)" \
        && _gc_panes_settled "$panes" \
        && [ "$(printf '%s' "$panes" | jq -r '.result.panes[0].cwd')" = "$cwd" ] \
        || { _gc_keep busy; continue; }
    fi
    agents="$(lock_spawn "${lock_fd:-}" cel_agent_list 2>/dev/null)" \
      && _gc_agents_removable "$agents" "$cwd" "$names" \
      || { _gc_keep unidentified "$cwd"; continue; }
    if [ -z "$ws_id" ] && _gc_has_process_live "$cwd"; then _gc_keep live; continue; fi
    if [ "$dry" -eq 1 ]; then
      c_ok "would remove ${ws_id:-orphan} ($cwd, PR $state, settled and landed clean)"
    elif [ -n "$ws_id" ]; then
      lock_spawn "${lock_fd:-}" herdr worktree remove --workspace "$ws_id" >/dev/null \
        || { c_warn "$ws_id: worktree remove refused"; _gc_keep refused; continue; }
      c_ok "removed $ws_id ($cwd)"
    else
      git --git-dir="$common" worktree remove "$cwd" 2>/dev/null \
        || { c_warn "$cwd: worktree remove refused"; _gc_keep refused; continue; }
      c_ok "removed orphan $cwd"
    fi
    removed=$((removed+1))
  done < <(printf '%s' "$candidates" | jq -c '.[]')
  [ -z "$reap_hours" ] || _gc_reap "$reap_hours" "$dry" "$agents" "$names"
  # THE REVIEWERS, which no pass here ever looked at: a reviewer runs in the
  # orchestrator's own checkout, so the worktree filter above skips it, and
  # the orphan reaper does not want it either - it has a live owner. Seven of
  # them, six for merged PRs, were most of a `box memory low` warning.
  _gc_reviewers "$dry" "$agents"
  # AFTER the worktree pass, deliberately: a freed worktree may have been the
  # last reference to a cache entry, and sweeping first would leave that entry
  # behind for another fortnight. `cel gc` is unchanged without --box.
  local box_line="" box_rc=0
  if [ "$box" -eq 1 ]; then box_sweep "$dry" || box_rc=$?; box_line="$(box_summary_fragment)"; fi
  printf 'gc: %d worktrees removed, %d reviewers closed, %d agents reaped, %d kept%s%s%s\n' \
    "$removed" "$reviewers_closed" "$reaped" "$kept" "$(_gc_kept_line summary)" "$box_line" \
    "$([ "$dry" -eq 1 ] && printf ' (dry run)')"
  # A BLIND GC MUST NOT LOOK LIKE AN IDLE ONE. Naming the directories is the
  # difference between "nothing to do" and "I cannot see anything".
  if [ "${GC_KEPT[unidentified]:-0}" -gt 0 ]; then
    c_warn "unidentified agents kept: ${GC_UNIDENTIFIED[*]}"
  fi
  _gc_kept_save
  return "$box_rc"
)
