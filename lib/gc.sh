# shellcheck shell=bash
# cel gc reclaims only positively identified, settled delegation worktrees.
# A closed PR, a missing pane, or elapsed process lifetime is not proof that
# work is disposable. Unknown discovery, ledger, or Git state always keeps it.
[ -n "${_CEL_GC:-}" ] && return 0
_CEL_GC=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/manifest.sh
. "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"
# shellcheck source=lib/orphans.sh
. "$(dirname "${BASH_SOURCE[0]}")/orphans.sh"   # cel gc --orphans

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
    && pr="$(cd "$1" && gh pr view --json state,headRefOid 2>/dev/null)" || return 1
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
  rows="$(cd "$1" && gh pr list --head "$branch" --state all --limit 100 --json state,updatedAt 2>/dev/null)" \
    || { printf UNKNOWN; return 0; }
  printf '%s' "$rows" | jq -er '
    if type != "array" then "UNKNOWN"
    elif length == 0 then "NONE"
    elif all(.[]; (.state == "MERGED" or .state == "CLOSED" or .state == "OPEN") and (.updatedAt | type == "string"))
    then sort_by(.updatedAt) | last | .state else "UNKNOWN" end' 2>/dev/null || printf UNKNOWN
}

# Return success to VETO deletion on running OR unverifiable state. A missing
# row is not evidence of retirement: admission may still be creating it.
# cmd_gc holds the registry and every ledger's writer lock while using this.
_gc_delegated_live() { # <worktree-dir> [allow-unlisted] -> 0 veto, 1 safe
  local names ws wsdir f match found=0
  names="$(registry_names 2>/dev/null)" || return 0
  [ -f "$CEL_REGISTRY" ] && [ -r "$CEL_REGISTRY" ] || return 0
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    wsdir="$(registry_path "$ws" 2>/dev/null)" || return 0
    [ -n "$wsdir" ] && [ -d "$wsdir" ] && [ -r "$wsdir" ] && [ -x "$wsdir" ] || return 0
    if [ -e "$wsdir/.cel" ] || [ -L "$wsdir/.cel" ]; then
      [ -d "$wsdir/.cel" ] && [ -r "$wsdir/.cel" ] && [ -x "$wsdir/.cel" ] || return 0
    fi
    f="$wsdir/.cel/delegations.json"
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
    # /proc reports a canonical cwd, possibly below the checkout root.
    # Resolve ledger aliases too; missing/unresolvable running paths are
    # unknown, never permission to bypass the live-delegation veto.
    match="$(python3 - "$1" "$f" <<'PY'
import json
import sys
from pathlib import Path

try:
    with open(sys.argv[2]) as source:
        rows = json.load(source)
    states = {"running", "finished", "orphaned", "collected", "salvaged", "reported", "released", "landed"}
    if not isinstance(rows, list) or not all(
        isinstance(row, dict) and isinstance(row.get("worktree"), str)
        and row["worktree"] and isinstance(row.get("state"), str)
        and row["state"] in states for row in rows
    ):
        raise ValueError("invalid delegation ledger")
    target = Path(sys.argv[1]).resolve(strict=True)
    found = False
    for row in rows:
        worktree = Path(row["worktree"])
        if not worktree.is_absolute():
            raise ValueError("unanchored worktree")
        worktree = worktree.resolve(strict=row["state"] == "running")
        if target == worktree or worktree in target.parents:
            if row["state"] == "running":
                print("live")
                break
            found = True
    else:
        print("found" if found else "absent")
except (OSError, ValueError, RuntimeError):
    sys.exit(1)
PY
)" || return 0
    case "$match" in
      live) return 0 ;;
      found) found=1 ;;
      absent) ;;
      *) return 0 ;;
    esac
  done <<< "$names"
  [ "$found" -ne 1 ] && [ "${2:-}" != allow-unlisted ]
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
_gc_has_process() { # <worktree-dir> -> 0 present/unknown, 1 absent
  local pids pid cwd rc
  if pids="$(pgrep -u "$(id -u)" 2>/dev/null)"; then :; else
    rc=$?; [ "$rc" -eq 1 ] && return 1; return 0
  fi
  for pid in $pids; do
    if ! cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"; then
      [ ! -d "/proc/$pid" ] && continue
      return 0
    fi
    case "$cwd" in "$1"|"$1"/*) return 0;; esac
  done
  return 1
}

# The three variables `cel run` and fanout put in every agent's environment
# (lib/run.sh). /proc/<pid>/environ is fixed at exec, so they survive a
# runtime that rewrites its own argv - which is the whole reason they exist:
# pi sets process.title, so a live pi worker's cmdline is `pi` plus padding
# and the role path the argv scan below looks for is never in it. GC was
# blind to every pi worker on the box for weeks because of that.

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
      "$wsdir/.cel/role-worker.md"|"$wsdir/.cel/role-scout.md"|"$wsdir/.cel/role-spike.md"|"$wsdir/.cel/role-reviewer.md")
        [ -f "$role" ] || return 1
        printf '%s' "$role"; return 0 ;;
    esac
    return 1
  done <<< "$names"
  return 1
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
  [ -n "$pane" ] || return 1
  cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || return 1
  # An agent_session of null is a herdr-side gap, not evidence that the pid is
  # a stranger: two live omp panes on this box carry one. It disqualifies a
  # process only when nothing else proves whose it is.
  if role="$(_gc_env_role "$pid" "$names")"; then proof=true; else role=""; fi
  row="$(printf '%s' "$agents" | jq -ce --arg p "$pane" --arg d "$cwd" --argjson proof "$proof" '
    [.result.agents[] | select(.pane_id == $p and .cwd == $d)] |
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
      (.foreground_processes | type == "array" and length == 1 and .[0].pid == $pid)' >/dev/null || return 1
  rt="$(printf '%s' "$row" | jq -r .agent)"
  [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "$rt" ] || return 1
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
          "$wsdir/.cel/role-worker.md"|"$wsdir/.cel/role-scout.md"|"$wsdir/.cel/role-spike.md"|"$wsdir/.cel/role-reviewer.md") role="${args[i+1]}";;
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
_GC_KEPT_REASONS=(busy symlink live unlanded open-pr unidentified refused stubborn)

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
_gc_kept_state() { printf '%s' "${CEL_GC_KEPT_STATE:-$HOME/.local/state/cel/gc-kept.json}"; }

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
    pane="$(printf '%s' "$row" | jq -r .pane_id)"
    info="$(lock_spawn "${lock_fd:-} ${fd:-}" herdr pane process-info --pane "$pane" 2>/dev/null)" \
      && pid="$(printf '%s' "$info" | jq -er '.result.process_info.foreground_processes | if length == 1 then .[0].pid else empty end')" \
      && _gc_process_identity "$pid" "$agents" "$3" >/dev/null || return 1
  done < <(printf '%s' "$rows" | jq -c '.[]')
  return 0
}

_gc_reap() { # <hours> <dry> <agents-json> <registry-names>; sets reaped
  local hours="$1" dry="$2" agents="$3" names="$4"
  local file="$HOME/.local/state/cel/gc-idle.json" fd previous='{}' next='{}' tmp="" boot now ignored pids pid identity key since fresh current identities='[]'
  boot="$(cat /proc/sys/kernel/random/boot_id)" && read -r now ignored < /proc/uptime || return 0
  now="${now%%.*}"
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  if [ "$dry" -eq 0 ]; then
    mkdir -p "$(dirname "$file")" || return 0
    # Held on an inherited descriptor, so every spawn below goes through
    # lock_spawn: a child that outlives this sweep would hold the lock with
    # it (the 2026-09-16 ledger hang, lib/registry.sh).
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
    _gc_delegated_live "$(printf '%s' "$identity" | jq -r .cwd)" allow-unlisted && continue
    key="$identity"
    since="$(printf '%s' "$previous" | jq -r --arg k "$key" '.[$k] // empty')"
    [[ "$since" =~ ^[0-9]+$ ]] && [ "$since" -le "$now" ] || since="$now"
    if [ $((now - since)) -ge $((hours * 3600)) ]; then
      fresh="$(lock_spawn "${fd:-} ${lock_fd:-}" herdr agent list 2>/dev/null)" || continue
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

cmd_gc() ( # [--reap <hours>] [--orphans] [--dry-run]; subshell owns lock descriptors
  local reap_hours="" dry=0 orphans=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reap)
        [ $# -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "cel gc: --reap requires a positive whole number of hours"
        reap_hours="$2"; shift 2 ;;
      --orphans) orphans=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) die "cel gc: unknown argument '$1' (want --reap <hours>, --orphans, --dry-run)" ;;
    esac
  done

  # THE PROCESS SWEEP IS ITS OWN VERB, deliberately not a stage of the
  # worktree GC. The worktree GC needs herdr, gh and every ledger's writer
  # lock, and skips itself entirely when any of them is unavailable - which is
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

  have herdr && have jq && have gh && have flock && have python3 || die "cel gc: herdr, jq, gh, flock and python3 are required"

  # A missing registry or failed roster is not an empty fleet. Writer locks
  # also fence delegate's pre-ledger creation window and concurrent re-use.
  # Both locks are held on inherited descriptors for the whole of this
  # subshell, so anything spawned from here - every herdr call, any of which
  # may start a daemon that never exits - is spawned through lock_spawn.
  local lock_fd names ws wsdir roster ids agents panes ws_id cwd state row known=1
  [ -f "$CEL_REGISTRY" ] && [ -r "$CEL_REGISTRY" ] || { c_warn "registry unavailable - GC skipped"; return 0; }
  exec {lock_fd}>"$CEL_REGISTRY.lock" || { c_warn "registry lock unavailable - GC skipped"; return 0; }
  flock -n "$lock_fd" || { c_warn "registry busy - GC skipped"; return 0; }
  names="$(registry_names 2>/dev/null)" || { c_warn "registry unreadable - GC skipped"; return 0; }
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    wsdir="$(registry_path "$ws" 2>/dev/null)" || { known=0; break; }
    [ -n "$wsdir" ] && [ -d "$wsdir" ] && [ -r "$wsdir" ] && [ -x "$wsdir" ] \
      && mkdir -p "$wsdir/.cel" \
      && [ -r "$wsdir/.cel" ] && [ -x "$wsdir/.cel" ] \
      && exec {lock_fd}>"$wsdir/.cel/delegations.lock" \
      && flock -n "$lock_fd" || { known=0; break; }
  done <<< "$names"
  [ "$known" -eq 1 ] || { c_warn "delegation discovery busy or unavailable - GC skipped"; return 0; }
  roster="$(lock_spawn "${lock_fd:-}" herdr workspace list 2>/dev/null)" \
    && ids="$(printf '%s' "$roster" | jq -er '.result.workspaces | if type == "array" and all(.[]; .workspace_id | type == "string" and length > 0) then map(.workspace_id) | join("\n") else error("invalid workspace list") end')" \
    && agents="$(lock_spawn "${lock_fd:-}" herdr agent list 2>/dev/null)" \
    && printf '%s' "$agents" | jq -e '.result.agents | type == "array" and all(.[]; (.cwd | type == "string") and (.pane_id | type == "string") and (.agent_status | type == "string"))' >/dev/null \
    || { c_warn "herdr discovery unavailable - GC skipped"; return 0; }

  local removed=0 reaped=0 kept=0 managed=$'\n' candidates='[]'
  _gc_keep_reset
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

  while IFS= read -r row; do
    cwd="$(printf '%s' "$row" | jq -r .dir)"
    ws_id="$(printf '%s' "$row" | jq -r .workspace)"
    [ "$(readlink -f "$cwd" 2>/dev/null)" = "$cwd" ] || { _gc_keep symlink; continue; }
    if [ -z "$ws_id" ] && _gc_has_process "$cwd"; then _gc_keep live; continue; fi
    if _gc_delegated_live "$cwd"; then _gc_keep live; continue; fi
    # No force removal: Git/herdr must still refuse newly dirty work. Only
    # linked Git worktrees qualify, never an ordinary repository in this dir.
    local gitdir common
    gitdir="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" \
      && common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
      && [ "$gitdir" != "$common" ] || { _gc_keep unlanded; continue; }
    state="$(_gc_pr_state "$cwd")"
    case "$state" in MERGED|CLOSED|NONE) ;; *) _gc_keep open-pr; continue;; esac
    _gc_landed_clean "$cwd" "$state" || { _gc_flag_unlanded "$cwd"; _gc_keep unlanded; continue; }
    # Re-read the exact managed workspace; an orphan must have NO live agent
    # at its path. Unknown/blocked/working never age out of either veto.
    if [ -n "$ws_id" ]; then
      panes="$(lock_spawn "${lock_fd:-}" herdr pane list --workspace "$ws_id" 2>/dev/null)" \
        && _gc_panes_settled "$panes" \
        && [ "$(printf '%s' "$panes" | jq -r '.result.panes[0].cwd')" = "$cwd" ] \
        || { _gc_keep busy; continue; }
    fi
    agents="$(lock_spawn "${lock_fd:-}" herdr agent list 2>/dev/null)" \
      && _gc_agents_removable "$agents" "$cwd" "$names" \
      || { _gc_keep unidentified "$cwd"; continue; }
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
  printf 'gc: %d worktrees removed, %d agents reaped, %d kept%s%s\n' \
    "$removed" "$reaped" "$kept" "$(_gc_kept_line summary)" \
    "$([ "$dry" -eq 1 ] && printf ' (dry run)')"
  # A BLIND GC MUST NOT LOOK LIKE AN IDLE ONE. Naming the directories is the
  # difference between "nothing to do" and "I cannot see anything".
  if [ "${GC_KEPT[unidentified]:-0}" -gt 0 ]; then
    c_warn "unidentified agents kept: ${GC_UNIDENTIFIED[*]}"
  fi
  _gc_kept_save
)
