# shellcheck shell=bash
# cel serve: explicitly owned, cgroup-accounted long-running development servers.
#
# A ledgered server lives on a TTL (default 8h) and an idle limit, and the
# steward's serve_sweep stops it when either runs out - or it is PERMANENT
# (`cel serve adopt <unit|pid> --permanent`): an agent's standing box service,
# such as a product's live app in a persistent user unit that its own
# follow-main unit recreates. A permanent server has no TTL and no idle or
# pressure limit; no sweep stops it (serve_sweep, preview_sweep, the orphan
# reaper), and only `cel serve stop` by its owner or a person ends it. A unit
# is matched by its NAME, so systemd recreating it is the same server; one
# that stays gone past the re-creation window (or a pid that exits) is
# dropped from the registry with one note to its owner - never restarted.
[ -n "${_CEL_SERVE:-}" ] && return 0
_CEL_SERVE=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/memory.sh
. "${BASH_SOURCE[0]%/*}/memory.sh"
# shellcheck source=lib/boxguard.sh
. "${BASH_SOURCE[0]%/*}/boxguard.sh"
# shellcheck source=lib/identity.sh
. "${BASH_SOURCE[0]%/*}/identity.sh"

_serve_state() { printf '%s' "${CEL_SERVE_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/servers}"; }
_serve_systemctl() { "${CEL_SERVE_SYSTEMCTL:-systemctl}" --user "$@"; }
_serve_systemd_run() { "${CEL_SERVE_SYSTEMD_RUN:-systemd-run}" --user "$@"; }
_serve_now() { if [ -n "${CEL_SERVE_NOW:-}" ]; then printf '%s' "$CEL_SERVE_NOW"; else printf '%(%s)T' -1; fi; }
# A process's start time (stat field 22), read with builtins: it is what tells
# a pid from the same number reused, and `cel fleet` pays for every process.
_serve_pid_start_in() { # <proc-root> <pid>
  local line="" rest
  local -a f=()
  { IFS= read -r line < "$1/$2/stat"; } 2>/dev/null || [ -n "$line" ] || return 0
  rest="${line##*)}"   # comm may hold spaces and ')': fields follow the LAST ')'
  read -ra f <<<"$rest"
  printf '%s' "${f[19]:-}"
}
_serve_pid_start() { _serve_pid_start_in /proc "$1"; }
_serve_rss_mb() { # <pid> -> VmRSS in MB, read with builtins
  local k v rest
  { while read -r k v rest; do
      [ "$k" = VmRSS: ] && { printf '%s' "$((v / 1024))"; return 0; }
    done < "/proc/$1/status"; } 2>/dev/null
  printf 0
}
_serve_mark_request() { # <name>
  local f now
  f="$(_serve_file "$1")"; [ -f "$f" ] || return 1
  now="$(_serve_now)"
  local tmp; tmp="$(mktemp "$(_serve_state)/.request.XXXXXX")"
  jq --argjson at "$now" '.last_request_at=$at' "$f" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$f"
}
_serve_name_ok() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$ ]]; }
_serve_file() { printf '%s/%s.json' "$(_serve_state)" "$1"; }

serve_start() { # <name> <owner> <workspace> <ttl-seconds> <port> -- <command...>
  local name="$1" owner="$2" ws="$3" ttl="$4" port="$5"; shift 5
  [ "${1:-}" = -- ] && shift || die 'cel serve start: expected -- before command'
  [ $# -gt 0 ] || die 'cel serve start: command required'
  _serve_name_ok "$name" || die 'cel serve start: invalid name'
  [[ "$ttl" =~ ^[1-9][0-9]*$ ]] || die 'cel serve start: ttl must be positive seconds'
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -le 65535 ] || die 'cel serve start: invalid port'
  [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die 'cel serve start: invalid owner'
  [[ "$ws" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die 'cel serve start: invalid workspace'
  local d unit worktree now tmp cmd f
  d="$(_serve_state)"; mkdir -p "$d"; chmod 700 "$d"
  f="$(_serve_file "$name")"
  [ ! -e "$f" ] || die "cel serve start: $name already recorded"
  unit="cel-serve-$name"; worktree="${CEL_SERVE_WORKTREE:-$(pwd -P)}"; now="$(_serve_now)"
  printf -v cmd '%q ' "$@"
  # A transient unit of this name that is still LOADED blocks systemd-run
  # ("already loaded or has a fragment file"): a server that was stopped and
  # exited non-zero (a dev server killed by SIGTERM does) stays loaded as
  # failed. A running one is refused; a dead one is cleared. New units are
  # collected even when they fail, so the next start has a free name.
  if _serve_systemctl is-active --quiet "$unit.service" 2>/dev/null; then
    die "cel serve start: $unit is still running - cel serve stop $name first"
  fi
  _serve_systemctl reset-failed "$unit.service" >/dev/null 2>&1 || true
  # THE LEDGER ROW COMES FIRST. Only a ledgered server may be stopped, so a
  # unit launched before its record was written could outlive a failed write
  # with nothing able to stop it. The record is published (no-clobber: a
  # concurrent start of the same name loses here, before it launches) and the
  # unit launched second; a launch that fails takes its record back.
  tmp="$(mktemp "$d/.serve.XXXXXX")" || die "cel serve start: cannot write the ledger in $d"
  if ! jq -n --arg name "$name" --arg unit "$unit" --arg owner "$owner" --arg workspace "$ws" \
      --arg worktree "$worktree" --argjson started "$now" --argjson ttl "$ttl" --argjson port "$port" \
      --arg command "$cmd" '{name:$name,unit:$unit,owner:$owner,workspace:$workspace,worktree:$worktree,started_at:$started,ttl_seconds:$ttl,port:$port,last_request_at:$started,command:$command}' > "$tmp" \
    || ! chmod 600 "$tmp"; then
    rm -f "$tmp"; die "cel serve start: could not write the ledger record for $name - nothing started"
  fi
  if ! ln "$tmp" "$f" 2>/dev/null; then
    rm -f "$tmp"; die "cel serve start: $name already recorded"
  fi
  rm -f "$tmp"
  _serve_systemd_run --unit="$unit" --property="WorkingDirectory=$worktree" \
    --property="MemoryAccounting=yes" --property="CollectMode=inactive-or-failed" \
    --property="Description=cel serve $name ($owner, $ws)" \
    -- /bin/bash -lc "$cmd" || { rm -f "$f"; die "cel serve start: could not start $unit"; }
}

_serve_cgroup_memory() { # <unit> -> memory current MB
  local path
  path="$(_serve_systemctl show -p ControlGroup --value "${1%.service}.service" 2>/dev/null || true)"
  [ -n "$path" ] || { printf 0; return; }
  awk '{print int($1/1048576)}' "${CEL_SERVE_CGROUP_ROOT:-/sys/fs/cgroup}${path}/memory.current" 2>/dev/null || printf 0
}

# EVERY RECORD, AT A CONSTANT COST: `cel fleet` and the dashboard read this on
# their budgeted paths. One jq reads all the records, one batched `systemctl
# show` names every unit's cgroup, memory and pid identity are read with
# builtins, and one jq assembles the answer. No record, no process at all. A
# record that does not parse is skipped.
serve_list_json() {
  local d now records='' line kind unit pid start i=0 mems='' path mb out id cur='' f
  local -a rows=() ids=()
  local -A cg=()
  d="$(_serve_state)"
  compgen -G "$d/*.json" >/dev/null || { printf '[]\n'; return 0; }
  now="$(_serve_now)"
  # the records as one array, then one line per record (fields split by
  # US: a tab is whitespace to `read`, and empty fields would collapse)
  local prog='. as $r | ($r | tojson), ($r[] | [(.kind // "unit"), (.unit // ""), ((.pid // 0) | tostring), (.pid_start // "")] | join("\u001f"))'
  out="$(jq -rn "[inputs] | $prog" "$d"/*.json 2>/dev/null)" \
    || out="$(for f in "$d"/*.json; do jq -c . "$f" 2>/dev/null; done | jq -rs "$prog")"
  { IFS= read -r records; while IFS= read -r line; do rows+=("$line"); done; } <<<"$out"
  [ -n "$records" ] || { printf '[]\n'; return 0; }
  for line in "${rows[@]}"; do
    IFS=$'\x1f' read -r kind unit pid start <<<"$line"
    [ "$kind" = pid ] || [ -z "$unit" ] || ids+=("${unit%.service}.service")
  done
  if [ "${#ids[@]}" -gt 0 ]; then
    while IFS= read -r line; do
      case "$line" in
        Id=*) cur="${line#Id=}" ;;
        ControlGroup=*) [ -z "$cur" ] || cg[$cur]="${line#ControlGroup=}" ;;
      esac
    done < <(_serve_systemctl show -p Id -p ControlGroup "${ids[@]}" 2>/dev/null)
  fi
  for line in "${rows[@]}"; do
    IFS=$'\x1f' read -r kind unit pid start <<<"$line"
    mb=0
    if [ "$kind" = pid ]; then
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -n "$start" ] && [ "$(_serve_pid_start "$pid")" = "$start" ]; then mb="$(_serve_rss_mb "$pid")"; fi
    elif [ -n "$unit" ]; then
      id="${unit%.service}.service"; path="${cg[$id]:-}"
      if [ -n "$path" ]; then
        mb=""; { read -r mb < "${CEL_SERVE_CGROUP_ROOT:-/sys/fs/cgroup}$path/memory.current"; } 2>/dev/null || true
        if [[ "$mb" =~ ^[0-9]+$ ]]; then mb=$((mb / 1048576)); else mb=0; fi
      fi
    fi
    mems="$mems$i"$'\t'"$mb"$'\n'
    i=$((i + 1))
  done
  jq -n --argjson r "$records" --arg mems "$mems" --argjson now "$now" '
    ($mems | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber)}) | from_entries) as $m
    | [$r | to_entries[] | .value + {
        age_seconds: ($now - (.value.started_at // $now) + ((.value.initial_age_seconds // 0) | if type == "number" then . else 0 end)),
        memory_mb: ($m[.key | tostring] // 0), managed: true, permanent: (.value.permanent == true)}]
    | sort_by(-.memory_mb)'
}

serve_unit_stop() { # <unit> -- require exact durable ledger ownership
  local unit="$1" id f
  [[ "$unit" =~ ^[a-zA-Z0-9_.@-]{1,160}$ ]] || return 1
  for f in "$(_serve_state)"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.unit // ""' "$f" 2>/dev/null)" = "$unit" ] || continue
    id="$unit"; [[ "$id" == *.service ]] || id="$id.service"
    # A server that already exited on its own was collected
    # (CollectMode=inactive-or-failed): stop says "not loaded", and that IS
    # stopped - otherwise its record could never be cleared. A unit still
    # loaded that refuses to stop is a real failure.
    if ! _serve_systemctl stop "$id" 2>/dev/null; then
      [ "$(_serve_systemctl show -p LoadState --value "$id" 2>/dev/null)" = not-found ] || return 1
    fi
    # a server that exits non-zero on SIGTERM is left failed and loaded
    _serve_systemctl reset-failed "$id" >/dev/null 2>&1 || true
    return 0
  done
  return 1
}

# Whether a user unit is there: `present` (active, or on its way up or down),
# `gone` (not loaded, or loaded and inactive or failed) or `unknown` - a user
# manager that cannot be asked is never read as a unit that is gone.
_serve_unit_state() { # <unit> -> present | gone | unknown
  local id="${1%.service}.service" out line load='' active=''
  out="$(_serve_systemctl show "$id" -p LoadState -p ActiveState 2>/dev/null)" || { printf unknown; return 0; }
  while IFS= read -r line; do
    case "$line" in LoadState=*) load="${line#*=}" ;; ActiveState=*) active="${line#*=}" ;; esac
  done <<<"$out"
  if [ "$load" = not-found ]; then printf gone; return 0; fi
  case "$active" in
    active|activating|reloading|deactivating|refreshing) printf present ;;
    inactive|failed) printf gone ;;
    *) printf unknown ;;
  esac
}
# Whether a unit is dead for good: not loaded at all, or loaded but inactive
# (or failed) with no main pid. A user manager that cannot answer is not dead.
_serve_unit_dead() { # <unit>
  local id="${1%.service}.service" out line load='' active='' main=''
  out="$(_serve_systemctl show "$id" -p LoadState -p ActiveState -p MainPID 2>/dev/null)" || return 1
  while IFS= read -r line; do
    case "$line" in LoadState=*) load="${line#*=}" ;; ActiveState=*) active="${line#*=}" ;; MainPID=*) main="${line#*=}" ;; esac
  done <<<"$out"
  [ "$load" = not-found ] && return 0
  case "$active" in inactive|failed) [ -z "$main" ] || [ "$main" = 0 ] ;; *) return 1 ;; esac
}
# Whether a pid record's process is still the one registered: same pid, same
# start time. A pid that exited, or whose number another process now holds,
# is not.
_serve_pid_live() { # <row>
  local pid start
  pid="$(jq -r '.pid // 0' <<<"$1")"; start="$(jq -r '.pid_start // ""' <<<"$1")"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -n "$start" ] && [ "$(_serve_pid_start "$pid")" = "$start" ]
}
# Who a server is registered to: the owner of the record naming this unit (by
# its unit, whatever the record is called) or this pid. Status 1: nobody's.
_serve_registered_owner() { # <unit|pid> -> owner
  local f
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    f="$(_serve_file "pid-$1")"
    [ -f "$f" ] || return 1
    jq -r '.owner // ""' "$f" 2>/dev/null; return 0
  fi
  for f in "$(_serve_state)"/*.json; do
    [ -f "$f" ] || continue
    jq -er --arg u "${1%.service}" 'select((.kind // "unit") != "pid" and ((.unit // "") | sub("\\.service$"; "")) == $u) | .owner // ""' "$f" 2>/dev/null && return 0
  done
  return 1
}

# Every registered permanent server, as `pid <n> <start>` or `unit <name>` lines, for
# the sweeps that must never touch one (lib/orphans.sh). Read with builtins
# first: no record that mentions `permanent`, no process.
serve_permanent_ids() {
  local f body
  for f in "$(_serve_state)"/*.json; do
    [ -f "$f" ] || continue
    body=""; IFS= read -r -d '' body < "$f" 2>/dev/null || true
    [[ "$body" == *'"permanent"'* ]] || continue
    jq -r 'select(.permanent == true) | if (.kind // "unit") == "pid" then "pid \(.pid) \(.pid_start // "")" else "unit \(.unit)" end' "$f" 2>/dev/null || true
  done
}

# A PERMANENT SERVER IS ITS OWNER'S, OR A PERSON'S, to register and to stop: a
# registration shields it from every sweep, and only its owner or a person
# can undo it. A person's own shell (no agent launch above it, lib/identity.sh
# cel_agent_role) may act for any owner; an agent only as the alias its launch
# fixed (CEL_INBOX_ME, checked against the launch's environ), and only when
# that alias is the owner. An agent that shed CEL_ROLE is still an agent, and
# proves no alias - refused. The sweeps never come here: they skip it.
_serve_owner_or_person() { # <verb> <owner> <what> -> dies unless the caller may
  local verb="$1" owner="$2" what="$3" role
  role="$(cel_agent_role)"
  [ -n "$role" ] || return 0
  [ -n "${CEL_ROLE:-}" ] && [ -n "${CEL_INBOX_ME:-}" ] \
    || die "cel serve $verb: $what - an agent acts only for itself, and this agent ($role) does not say which alias it is; nothing changed"
  cel_launch_identity "cel serve $verb"
  [ "$(cel_alias_norm "$CEL_INBOX_ME")" = "$(cel_alias_norm "$owner")" ] \
    || die "cel serve $verb: $what - an agent acts only for itself, not as $CEL_INBOX_ME for $owner; nothing changed"
}
_serve_stop_authorised() { # <row>
  [ "$(jq -r '.permanent // false' <<<"$1")" = true ] || return 0
  local name owner
  name="$(jq -r '.name // ""' <<<"$1")"; owner="$(jq -r '.owner // ""' <<<"$1")"
  _serve_owner_or_person stop "$owner" "$name is a permanent server of $owner, and only its owner or a person stops it"
}

serve_stop() { # <name|unit|pid>
  local id="$1" f unit row kind pid
  if _serve_name_ok "$id" && [ -f "$(_serve_file "$id")" ]; then
    f="$(_serve_file "$id")"
  elif [[ "$id" =~ ^cel-serve-([A-Za-z0-9][A-Za-z0-9_.-]{0,47})$ ]] && [ -f "$(_serve_file "${BASH_REMATCH[1]}")" ]; then
    f="$(_serve_file "${BASH_REMATCH[1]}")"
  elif [[ "$id" =~ ^[0-9]+$ ]]; then
    f="$(_serve_file "pid-$id")"
  else
    die 'cel serve stop: only a ledgered server can be stopped'
  fi
  [ -f "$f" ] || die 'cel serve stop: server is not ledgered'
  row="$(jq -c . "$f")"; kind="$(jq -r '.kind // "unit"' <<<"$row")"
  _serve_stop_authorised "$row"
  # A server already gone leaves only its registration: clear that and signal
  # nothing - a reused pid belongs to some other process now.
  if [ "$kind" = pid ]; then
    pid="$(jq -r '.pid' <<<"$row")"
    if ! _serve_pid_live "$row"; then
      rm -f "$f"
      printf 'pid-%s was already gone (or its pid was reused); registration removed, nothing was stopped\n' "$pid"
      return 0
    fi
    kill -TERM "$pid" || return $?
    rm -f "$f"
    return 0
  else
    unit="$(jq -r '.unit' <<<"$row")"
    if _serve_unit_dead "$unit"; then
      rm -f "$f"
      printf '%s (unit %s) was already gone; registration removed, nothing was stopped\n' "$(jq -r '.name // ""' <<<"$row")" "$unit"
      return 0
    fi
    serve_unit_stop "$unit" || return $?
    rm -f "$f"
  fi
}

# One running user unit as an adopt row: its main pid, the port that pid
# listens on, its cgroup's memory, age and working directory.
_serve_unit_row() { # <unit> [execstart]
  local short="${1%.service}" execstart="${2-}" mainpid mem cwd='' age=0 port=0
  [ $# -ge 2 ] || execstart="$(_serve_systemctl show "$short.service" -p ExecStart --value 2>/dev/null || true)"
  mainpid="$(_serve_systemctl show "$short.service" -p MainPID --value 2>/dev/null || printf 0)"
  [[ "$mainpid" =~ ^[0-9]+$ ]] || mainpid=0
  mem="$(_serve_cgroup_memory "$short")"
  if [ "$mainpid" -gt 0 ]; then
    cwd="$(readlink -f "${CEL_SERVE_PROC_ROOT:-/proc}/$mainpid/cwd" 2>/dev/null || true)"
    age="$(ps -o etimes= -p "$mainpid" 2>/dev/null | tr -d ' ' || true)"
    [[ "$age" =~ ^[0-9]+$ ]] || age=0
    port="$(ss -H -ltnp 2>/dev/null | awk -v p="pid=$mainpid," 'index($0,p) && !found {x=$4; sub(/^.*:/,"",x); print x; found=1}')"
    [[ "$port" =~ ^[0-9]+$ ]] || port=0
  fi
  jq -cn --arg unit "$short" --arg command "$execstart" --arg cwd "$cwd" \
    --argjson pid "$mainpid" --argjson mem "$mem" --argjson age "$age" --argjson port "$port" \
    '{unit:$unit,pid:(if $pid==0 then null else $pid end),port:$port,memory_mb:$mem,age_seconds:$age,worktree:$cwd,command:$command,managed:false}'
}

_serve_adopt_rows() {
  local now unit pid age row mem
  now="$(_serve_now)"
  if [ "${CEL_SERVE_PROC_DATA+x}" = x ]; then
    while IFS=$'\t' read -r pid port rss elapsed cwd command; do
      [ -n "$pid" ] || continue
      jq -cn --argjson pid "$pid" --argjson port "${port:-0}" --argjson mem "$(( ${rss:-0} / 1024 ))" \
        --argjson age "${elapsed:-0}" --arg cwd "$cwd" --arg command "$command" \
        --arg pid_start "$(_serve_pid_start "$pid")" \
        '{pid:$pid,pid_start:$pid_start,port:$port,memory_mb:$mem,age_seconds:$age,worktree:$cwd,command:$command,managed:false}'
    done <<<"$CEL_SERVE_PROC_DATA"
  else
    local proc cmd cwd listen_pids='' listeners='' owner_uid
    if have ss; then
      listeners="$(ss -H -ltnp 2>/dev/null || true)"
      listen_pids="$(printf '%s\n' "$listeners" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
    fi
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
      proc="/proc/$pid"
      [ -r "$proc/cmdline" ] || continue
      owner_uid="$(awk '/^Uid:/{print $2; exit}' "$proc/status" 2>/dev/null || true)"
      [ "$owner_uid" = "$EUID" ] || continue
      cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
      cwd="$(readlink -f "$proc/cwd" 2>/dev/null || true)"
      [ -n "$cwd" ] || continue
      age="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
      [[ "$age" =~ ^[0-9]+$ ]] || age=0
      mem="$(awk '/^VmRSS:/{print int($2/1024)}' "$proc/status" 2>/dev/null || printf 0)"
      local port; port="$(printf '%s' "$cmd" | grep -oE -- '--port(=| +)[0-9]+' | grep -oE '[0-9]+$' | sed -n '1p' || true)"
      if [ -z "$port" ] && [ -n "$listeners" ]; then
        port="$(printf '%s\n' "$listeners" | awk -v p="pid=$pid," 'index($0,p) && !found {x=$4; sub(/^.*:/,"",x); print x; found=1}')"
      fi
      jq -cn --argjson pid "$pid" --argjson port "${port:-0}" --argjson mem "$mem" --argjson age "$age" \
        --arg cwd "$cwd" --arg command "$cmd" --arg pid_start "$(_serve_pid_start "$pid")" \
        '{pid:$pid,pid_start:$pid_start,port:$port,memory_mb:$mem,age_seconds:$age,worktree:$cwd,command:$command,managed:false}'
    done <<<"$listen_pids"
  fi
  if [ -n "${CEL_SERVE_ADOPT_DATA:-}" ]; then printf '%s\n' "$CEL_SERVE_ADOPT_DATA" | jq -c '.[] | . + {managed:false}'; fi
  local description execstart
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    local short="${unit%.service}"
    [ -f "$(_serve_file "$short")" ] && continue
    # Celestial's own services (cel-dash, cel-pages, cel-auth-gateway, ...)
    # are the plane, not previews; only cel-serve-* units are servers it ran.
    case "$short" in cel-serve-*) ;; cel-*) continue ;; esac
    description="$(_serve_systemctl show "$unit" -p Description --value 2>/dev/null || true)"
    execstart="$(_serve_systemctl show "$unit" -p ExecStart --value 2>/dev/null || true)"
    case "$unit $description $execstart" in
      *cel-serve-*|*server*|*preview*|*dev*|*wrangler*|*vite*|*playground*) ;;
      *) continue;;
    esac
    _serve_unit_row "$short" "$execstart"
  done < <(_serve_systemctl list-units --type=service --state=running --plain --no-legend 2>/dev/null | awk '{print $1}')
}

_serve_cgroup_is_ledgered_unit() { # <cgroup-path> <unit...>
  local cgroup="$1" unit
  shift
  for unit in "$@"; do
    unit="${unit%.service}"
    case "$cgroup" in *"/$unit.service"|*"/$unit.service/"*) return 0;; esac
  done
  return 1
}
_serve_pid_in_ledgered_unit() { # <pid> <unit...>
  local pid="$1" cgroup
  shift
  cgroup="$(awk -F: '$1 == "0" {print $3; exit}' "${CEL_SERVE_PROC_ROOT:-/proc}/$pid/cgroup" 2>/dev/null || true)"
  [ -n "$cgroup" ] && _serve_cgroup_is_ledgered_unit "$cgroup" "$@"
}
# The user service a pid runs inside: one of the user manager's own services,
# never a session scope and never a system service.
_serve_pid_unit() { # <pid> -> unit name, or status 1
  local line cg='' part
  { while IFS= read -r line; do
      case "$line" in 0::*) cg="${line#0::}"; break ;; esac
    done < "${CEL_SERVE_PROC_ROOT:-/proc}/$1/cgroup"; } 2>/dev/null
  case "$cg" in */user@*.service/*) cg="${cg#*/user@*.service/}" ;; *) return 1 ;; esac
  local IFS=/
  for part in $cg; do
    case "$part" in ?*.service) printf '%s' "${part%.service}"; return 0 ;; esac
  done
  return 1
}

# WHAT IS NOT A PREVIEW, though it listens on a port. "Every process of mine
# with a TCP listener" includes live agent runtimes and standing gateways, and
# adopting puts a thing on a TTL that stops it. Refused here:
#   - coding-agent runtimes (omp, pi, claude, codex, opencode, by argv[0], or
#     argv[1] for a node/bun script);
#   - build-tool daemons (Gradle daemon and workers, Kotlin compile daemon,
#     Metals), by exact main class (_serve_build_daemon);
#   - a process inside a running user SERVICE whose name the unit pass below
#     would not offer (hermes-gateway, cel-dash, ...): services are judged as
#     units, by name, never as loose pids;
#   - owner-managed Hermes desktop SSH servers, by executable and NUL argv;
#   - anything whose command contains an entry of box config `serve.ignore`
#     (comma-separated substrings) - the operator's own standing tools.
_serve_ignored() { # <command> -> 0 when box config serve.ignore matches it
  local ignore pat; ignore="$(cel_config_get serve ignore 2>/dev/null || true)"
  local IFS=,
  for pat in $ignore; do
    pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
    [ -n "$pat" ] && [[ "$1" == *"$pat"* ]] && return 0
  done
  return 1
}
_serve_agent_argv() { # <command> -> 0 when it is an agent runtime (omp, pi, claude, ...)
  local a0 a1 n
  read -r a0 a1 _ <<<"$1"
  n="${a0##*/}"
  # argv[1] names the program only when argv[0] is a script host; for
  # anything else it is an argument (`http-server ~/claude` is a preview).
  case "$n" in node|nodejs|bun|deno|python|python3*) n="${a1##*/}" ;; esac
  case "$n" in omp|pi|claude|codex|opencode|omp.*|pi.*) return 0 ;; esac
  return 1
}
# AN AGENT'S VERIFICATION BROWSER. A harness (omp's
# `__omp_worker_daemon_broker`, pi, claude, opencode) drives a headless Chrome
# that listens on a loopback DevTools port; it is a tool of that agent, not a
# preview, and `cel serve adopt` is the wrong answer for it. Only a Chrome or
# Chromium binary qualifies - a dev server an agent started is still a dev
# server - and only when an ancestor is an agent runtime, or when the one port
# it was seen on is its own --remote-debugging-port (or it debugs over a
# pipe). An orphaned one, its agent gone, is left to lib/orphans.sh, whose
# rules are unchanged: reaped when its directory is gone, kept otherwise.
_serve_agent_browser() { # <pid> <command> <port>
  local pid="$1" cmd="$2" port="$3" a0 n p depth=0 key val rest arg part proc="${CEL_SERVE_PROC_ROOT:-/proc}"
  local -a argv
  read -r -a argv <<<"$cmd"
  a0="${argv[0]:-}"
  n="${a0##*/}"
  case "$n" in chrome|chromium|chromium-browser|google-chrome*|chrome-headless-shell|headless_shell) ;; *) return 1 ;; esac
  for arg in "${argv[@]}"; do
    case "$arg" in
      --remote-debugging-pipe) return 0 ;;
      --remote-debugging-port=*)
        p="${arg#*=}"
        { [ "$p" = 0 ] || [ "$p" = "$port" ]; } && return 0 ;;
    esac
  done
  p="$pid"
  while [ "$depth" -lt 32 ]; do
    depth=$((depth + 1)); n=''
    while IFS=$'\t' read -r key val rest; do
      [ "$key" = PPid: ] && { n="$val"; break; }
    done < "$proc/$p/status" 2>/dev/null
    [[ "$n" =~ ^[1-9][0-9]*$ ]] && [ "$n" != 1 ] || return 1
    p="$n"; arg=''
    while IFS= read -r -d '' part || [ -n "$part" ]; do arg="$arg$part "; done < "$proc/$p/cmdline" 2>/dev/null
    _serve_agent_argv "$arg" && return 0
  done
  return 1
}
# A BUILD TOOL'S DAEMON. Gradle's daemon, its worker processes and the Kotlin
# compile daemon listen on random loopback ports for as long as a build keeps
# them warm; they are build machinery, not previews. Judged by the MAIN CLASS
# of a `java` process - the first argument after the JVM options and their
# values (`-m mod/cls` names it too) - never by the java binary alone, and
# never by a class name appearing later as a program argument: a Spring Boot
# app or any `java -jar app.jar` is still a server. argv comes NUL-split from
# /proc/<pid>/cmdline so quoted arguments stay whole; the space-joined command
# is the fallback only when that is unreadable. Metals is the Scala language
# server. _serve_build_daemon_class prints the main class it matched (the
# steward's idle-daemon check tells Gradle from Kotlin by it).
_serve_build_daemon() { _serve_build_daemon_class "$@" >/dev/null; }
_serve_build_daemon_class() { # <pid> <command> -> the daemon's main class
  local arg cls='' i=1 f="${CEL_SERVE_PROC_ROOT:-/proc}/$1/cmdline"
  local -a argv=()
  if [[ "$1" =~ ^[1-9][0-9]*$ ]] && [ -r "$f" ]; then
    mapfile -d '' -t argv < "$f" 2>/dev/null
  fi
  [ "${#argv[@]}" -gt 0 ] || read -r -a argv <<<"$2"
  [ "${argv[0]##*/}" = java ] || return 1
  while [ "$i" -lt "${#argv[@]}" ]; do
    arg="${argv[$i]}"; i=$((i + 1))
    case "$arg" in
      -jar|--jar) return 1 ;;
      -m|--module) cls="${argv[$i]:-}"; cls="${cls#*/}"; break ;;
      --module=*) cls="${arg#*=}"; cls="${cls#*/}"; break ;;
      -cp|-classpath|--class-path|-p|--module-path|--upgrade-module-path|--add-modules|\
      --add-opens|--add-exports|--add-reads|--patch-module|--limit-modules|--source)
        i=$((i + 1)) ;;
      -*|@*) ;;
      *) cls="$arg"; break ;;
    esac
  done
  case "$cls" in
    org.gradle.launcher.daemon.bootstrap.GradleDaemon|\
    worker.org.gradle.process.internal.worker.GradleWorkerMain|\
    org.gradle.process.internal.worker.GradleWorkerMain|\
    org.jetbrains.kotlin.daemon.KotlinCompileDaemon|\
    scala.meta.metals.Main) printf '%s\n' "$cls"; return 0 ;;
  esac
  return 1
}
_serve_not_a_preview() { # <pid> <command> [port]
  local pid="$1" cmd="$2" cg unit exe proc="${CEL_SERVE_PROC_ROOT:-/proc}"
  _serve_agent_argv "$cmd" && return 0
  _serve_build_daemon "$pid" "$cmd" && return 0
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    _serve_agent_browser "$pid" "$cmd" "${3:-0}" && return 0
    exe="$(readlink "$proc/$pid/exe" 2>/dev/null || true)"
    _cel_hermes_desktop_server "$exe" "$proc/$pid/cmdline" && return 0
    cg="$(awk -F: '$1 == "0" {print $3; exit}' "$proc/$pid/cgroup" 2>/dev/null || true)"
    unit="${cg##*/}"
    # only services of the user's own manager - a system service (a CI
    # runner, sshd) says nothing about what the process inside it serves
    case "$cg" in
      */user@*.service/*.service)
        case "$unit" in *cel-serve-*|*server*|*preview*|*dev*|*wrangler*|*vite*|*playground*) ;; *) return 0 ;; esac ;;
    esac
  fi
  _serve_ignored "$cmd"
}

# A REGISTERED SERVER COVERS ITS DESCENDANTS. A server registered by pid (a
# bun API that starts Vite, say) has children listening on their own ports;
# they are that server's, not new unledgered ones. A candidate is covered when
# its ancestor chain (ppid from /proc/<pid>/stat, at most 32 levels) reaches a
# registered pid whose start time is the one its record holds - a pid number
# reused by another process covers nothing. One pass over every candidate,
# all of it with builtins: each ancestor's answer is remembered so a shared
# ancestor is read once. A covered answer is remembered as the DISTANCE (hops)
# to the registered pid, and reused only while the whole chain stays within
# the cap; "not covered" is remembered only from a walk that really ended (pid
# 1, no ppid, an unreadable stat), never from one the cap cut short - so the
# verdict never depends on the order candidates come in. (A registered unit
# covers whatever runs in its cgroup: _serve_pid_in_ledgered_unit.) Prints
# `<candidate> <registered-pid>` for each covered candidate.
_serve_ledgered_descendants() { # <pid:start...> ; candidate pids on stdin
  local proc="${CEL_SERVE_PROC_ROOT:-/proc}" pid p line rest depth dist reg i n
  local -A start=() dist_of=() reg_of=() dead=()
  local -a f chain
  for p in "$@"; do start["${p%%:*}"]="${p#*:}"; done
  [ "${#start[@]}" -gt 0 ] || return 0
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    chain=(); dist=''; reg=''; depth=0
    line=''; { IFS= read -r line < "$proc/$pid/stat"; } 2>/dev/null || true
    rest="${line##*)}"; read -ra f <<<"$rest"; p="${f[1]:-}"
    while :; do
      if ! [[ "$p" =~ ^[1-9][0-9]*$ ]] || [ "$p" = 1 ]; then
        for i in "${chain[@]}"; do dead["$i"]=1; done; break
      fi
      [ "$depth" -lt 32 ] || break          # truncated: remember nothing negative
      depth=$((depth + 1))
      [ -z "${dead[$p]:-}" ] || { for i in "${chain[@]}"; do dead["$i"]=1; done; break; }
      if [ -n "${dist_of[$p]:-}" ]; then dist="${dist_of[$p]}"; reg="${reg_of[$p]}"; break; fi
      chain+=("$p")
      line=''; { IFS= read -r line < "$proc/$p/stat"; } 2>/dev/null || true
      if [ -z "$line" ]; then for i in "${chain[@]}"; do dead["$i"]=1; done; break; fi
      rest="${line##*)}"; read -ra f <<<"$rest"
      if [ -n "${start[$p]:-}" ] && [ "${f[19]:-}" = "${start[$p]}" ]; then dist=0; reg="$p"; break; fi
      p="${f[1]:-}"
    done
    [ -n "$dist" ] || continue
    # chain[i] sits at depth i+1; the match (or cached ancestor) at $depth
    n="${#chain[@]}"
    for ((i = 0; i < n; i++)); do
      dist_of["${chain[$i]}"]=$((depth - i - 1 + dist)); reg_of["${chain[$i]}"]="$reg"
    done
    [ $((depth + dist)) -le 32 ] && printf '%s %s\n' "$pid" "$reg"
  done
  return 0
}
# Every server registered by pid, as `pid:start` (records without a start
# time cover no descendants: nothing proves the pid is still theirs).
_serve_ledgered_pid_starts() {
  local f
  for f in "$(_serve_state)"/*.json; do
    [ -f "$f" ] || continue
    jq -r 'select(.kind == "pid" and ((.pid // 0) | tostring | test("^[1-9][0-9]*$")) and ((.pid_start // "") | tostring | test("^[0-9]+$"))) | "\(.pid):\(.pid_start)"' "$f" 2>/dev/null || true
  done
}
# The registered server a pid is covered by - an ancestor registered by pid,
# or the registered unit whose cgroup it runs in - by its record name.
_serve_covering_server() { # <pid> -> name, or status 1
  local pid="$1" reg _x f u
  local -a starts=()
  mapfile -t starts < <(_serve_ledgered_pid_starts)
  if [ "${#starts[@]}" -gt 0 ] && read -r _x reg < <(printf '%s\n' "$pid" | _serve_ledgered_descendants "${starts[@]}") && [ -n "$reg" ]; then
    for f in "$(_serve_state)"/*.json; do
      [ -f "$f" ] || continue
      jq -er --argjson p "$reg" 'select(.kind == "pid" and .pid == $p) | .name // "pid-\($p)"' "$f" 2>/dev/null && return 0
    done
    printf 'pid-%s' "$reg"; return 0
  fi
  for f in "$(_serve_state)"/*.json; do
    [ -f "$f" ] || continue
    u="$(jq -r 'select((.kind // "unit") != "pid") | .unit // ""' "$f" 2>/dev/null)"
    [ -n "$u" ] && _serve_pid_in_ledgered_unit "$pid" "$u" && { jq -r '.name // .unit' "$f"; return 0; }
  done
  return 1
}

serve_adopt_json() {
  local rows row pid unit id f kind
  local -a ledger_units=() ledger_starts=()
  local -A ledger_pids=() ledger_names=() covered=()
  mapfile -t ledger_starts < <(_serve_ledgered_pid_starts)
  for f in "$(_serve_state)"/*.json; do
    [ -f "$f" ] || continue
    kind="$(jq -r '.kind // "unit"' "$f" 2>/dev/null)"
    if [ "$kind" = pid ]; then
      pid="$(jq -r '.pid // 0' "$f" 2>/dev/null)"
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ledger_pids["$pid"]=1
    else
      unit="$(jq -r '.unit // ""' "$f" 2>/dev/null)"
      if [ -n "$unit" ]; then
        id="${unit%.service}"
        ledger_names["$id"]=1
        ledger_units+=("$unit")
      fi
    fi
  done
  rows="$(_serve_adopt_rows | jq -s 'reverse | unique_by(if (.pid // 0) > 0 then "pid:\(.pid)" else "unit:\(.unit)" end)')"
  if [ "${#ledger_starts[@]}" -gt 0 ]; then
    while read -r pid _; do covered["$pid"]=1; done \
      < <(printf '%s' "$rows" | jq -r '.[] | .pid // empty' | _serve_ledgered_descendants "${ledger_starts[@]}")
  fi
  while IFS= read -r row; do
    pid="$(jq -r '.pid // 0' <<<"$row")"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      [[ -n "${ledger_pids[$pid]:-}" ]] && continue
      [[ -n "${covered[$pid]:-}" ]] && continue
      if [ "${#ledger_units[@]}" -gt 0 ] && _serve_pid_in_ledgered_unit "$pid" "${ledger_units[@]}"; then continue; fi
    fi
    # a unit row is already judged by its name (and the ignore list); a loose
    # pid is judged here
    if [ -z "$(jq -r '.unit // ""' <<<"$row")" ]; then
      _serve_not_a_preview "$pid" "$(jq -r '.command // ""' <<<"$row")" "$(jq -r '.port // 0' <<<"$row")" && continue
    else
      _serve_ignored "$(jq -r '.command // ""' <<<"$row")" && continue
    fi
    unit="$(jq -r '.unit // ""' <<<"$row")"
    if [ -n "$unit" ]; then
      id="${unit%.service}"
      [[ -n "${ledger_names[$id]:-}" ]] && continue
    fi
    printf '%s\n' "$row"
  done < <(printf '%s\n' "$rows" | jq -c '.[]') |
    jq -s 'map(. + {group:(.unit // .worktree // "unknown")}) | sort_by(-.memory_mb)'
}
# EXPLICIT ADOPTION ONLY. A TTL adoption takes a row `cel serve adopt` lists:
# the classifier above is what keeps agents and standing services off a clock
# that stops them. A PERMANENT one (ttl `permanent`) is never stopped by
# anything but its owner or a person, so only a person or the owner itself
# registers it (_serve_owner_or_person), and a server already registered is
# never re-registered to anyone else. It may name any running user unit
# outright (not Celestial's own `cel-*` services), wherever it runs - the
# record keeps its WorkingDirectory and ExecStart, and `cel serve list` shows
# them, so a person can see what was shielded. A pid inside a user service
# registers that UNIT, so the unit recreated under its name - a new pid - is
# still the registered server. An empty port takes the one seen.
serve_adopt() { # <unit|pid> <owner> <workspace> <ttl-seconds|permanent> <port|""> [why]
  local target="$1" owner="$2" ws="$3" ttl="$4" port="$5" why="${6:-}" rows row='' id unit='' pid='' now f tmp initial_age permanent=false
  if [[ "$target" =~ ^pid:([1-9][0-9]*)$ ]]; then target="${BASH_REMATCH[1]}"; fi
  if [ "$ttl" = permanent ]; then permanent=true; ttl=null
  else [[ "$ttl" =~ ^[1-9][0-9]*$ ]] || die 'cel serve adopt: invalid ttl seconds'
  fi
  { [ -z "$port" ] || { [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -le 65535 ]; }; } || die 'cel serve adopt: invalid port'
  [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die 'cel serve adopt: invalid owner'
  [[ "$ws" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die 'cel serve adopt: invalid workspace'
  [[ "$target" =~ ^[0-9]+$ ]] || target="${target%.service}"
  if [ "$permanent" = true ]; then
    _serve_owner_or_person adopt "$owner" "registering $target as a permanent server of $owner"
    if [[ "$target" =~ ^[0-9]+$ ]] && unit="$(_serve_pid_unit "$target")"; then target="$unit"; fi
  fi
  unit=''
  local prev
  if prev="$(_serve_registered_owner "$target")"; then
    [ "$(cel_alias_norm "$prev")" = "$(cel_alias_norm "$owner")" ] \
      || die "cel serve adopt: $target is already registered to $prev - it is never re-registered to anyone else; $prev or a person stops it with cel serve stop"
    die 'cel serve adopt: already ledgered'
  fi
  rows="$(serve_adopt_json)"
  row="$(printf '%s' "$rows" | jq -ce --arg target "$target" '[.[] | select((.unit // "") == $target or ((.pid // 0) | tostring) == $target)] | .[0] // empty')" || row=''
  if [ -z "$row" ]; then
    if [[ "$target" =~ ^[1-9][0-9]*$ ]]; then
      local by
      by="$(_serve_covering_server "$target")" && die "cel serve adopt: $target is already covered by registered server $by"
    fi
    [ "$permanent" = true ] && ! [[ "$target" =~ ^[0-9]+$ ]] && _serve_name_ok "$target" \
      || die 'cel serve adopt: target is not a running unledgered server'
    case "$target" in cel-serve-*) ;; cel-*) die "cel serve adopt: $target is one of Celestial's own services, not a server to register" ;; esac
    [ "$(_serve_unit_state "$target")" = present ] || die "cel serve adopt: $target is not a running user unit"
    row="$(_serve_unit_row "$target")"
  fi
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    pid="$target"; id="pid-$pid"; unit=''
  else
    unit="$target"; id="$unit"; _serve_name_ok "$id" || die 'cel serve adopt: unit name cannot be ledgered'
  fi
  _serve_name_ok "$id" || die 'cel serve adopt: invalid identifier'
  [ -n "$port" ] || port="$(jq -r '.port // 0' <<<"$row")"
  [[ "$port" =~ ^[0-9]+$ ]] || port=0
  initial_age="$(jq -r '.age_seconds // 0' <<<"$row")"; [[ "$initial_age" =~ ^[0-9]+$ ]] || initial_age=0
  f="$(_serve_file "$id")"; [ ! -e "$f" ] || die 'cel serve adopt: already ledgered'
  now="$(_serve_now)"; mkdir -p "$(_serve_state)"; chmod 700 "$(_serve_state)"; tmp="$(mktemp "$(_serve_state)/.adopt.XXXXXX")"
  local wd=''
  [ -z "$unit" ] || wd="$(_serve_systemctl show "$unit.service" -p WorkingDirectory --value 2>/dev/null || true)"
  [ -n "$wd" ] || wd="$(jq -r '.worktree // ""' <<<"$row")"
  jq -n --arg name "$id" --arg unit "$unit" --arg owner "$owner" --arg workspace "$ws" \
    --arg worktree "$(jq -r '.worktree // ""' <<<"$row")" --arg command "$(jq -r '.command // ""' <<<"$row")" --arg wd "$wd" \
    --argjson pid "${pid:-0}" --argjson started "$now" --argjson ttl "$ttl" --argjson port "$port" --argjson initial_age "$initial_age" \
    --arg pid_start "$(jq -r '.pid_start // ""' <<<"$row")" --argjson permanent "$permanent" --arg why "$why" \
    --arg kind "$([ -n "$pid" ] && printf pid || printf unit)" \
    '{name:$name,unit:$unit,kind:$kind,pid:(if $kind == "pid" then $pid else null end),pid_start:$pid_start,owner:$owner,workspace:$workspace,worktree:$worktree,working_directory:$wd,command:$command,started_at:$started,initial_age_seconds:$initial_age,ttl_seconds:$ttl,permanent:$permanent,port:$port,last_request_at:$started}
     + (if $why == "" then {} else {why:$why} end)' > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$f"
}

serve_request() { _serve_mark_request "$1"; }

_serve_refresh_connections() {
  local f row port last active now
  have ss || return 0
  now="$(_serve_now)"
  for f in "$(_serve_state)"/*.json; do
    [ -f "$f" ] || continue
    row="$(jq -c . "$f" 2>/dev/null)" || continue
    port="$(jq -r '.port // 0' <<<"$row")"
    [[ "$port" =~ ^[1-9][0-9]*$ ]] || continue
    active="$(ss -Htn state established "( sport = :$port )" 2>/dev/null | wc -l | tr -d ' ')"
    [ "${active:-0}" -gt 0 ] || continue
    last="$(jq -r '.last_request_at // .started_at' <<<"$row")"
    [ "$last" -lt "$now" ] && _serve_mark_request "$(jq -r '.name' <<<"$row")" || true
  done
}

_serve_idle_seconds() {
  local hours
  hours="${CEL_SERVE_IDLE_HOURS:-$(cel_config_get serve idle_hours 2>/dev/null || true)}"
  [[ "$hours" =~ ^[1-9][0-9]*$ ]] || hours=6
  printf '%s' "$((hours * 3600))"
}
_serve_pressure_idle_seconds() {
  local hours
  hours="${CEL_SERVE_PRESSURE_IDLE_HOURS:-$(cel_config_get serve pressure_idle_hours 2>/dev/null || true)}"
  [[ "$hours" =~ ^[1-9][0-9]*$ ]] || hours=1
  printf '%s' "$((hours * 3600))"
}

# Gone is a FACT ABOUT TIME for a unit: a redeploy stops it and starts it
# again under the same name, so it is gone only once it has stayed gone past
# this window (default 15 minutes, three steward ticks).
_serve_gone_grace() {
  local s="${CEL_SERVE_GONE_GRACE_SECONDS:-}"
  [[ "$s" =~ ^[0-9]+$ ]] || s=900
  printf '%s' "$s"
}

# A PERMANENT ROW: never stopped here, whatever its age, idleness, the box's
# pressure or its checkout. Only whether it is still there is asked. A pid
# that exited (or was reused) is gone at once; a unit is gone once it has
# stayed gone past the window, and back before then clears the mark. Gone is
# dropped from the registry with one note to the owner - nothing restarted.
_serve_sweep_permanent() { # <file> <row> <now>
  local f="$1" row="$2" now="$3" name owner ws kind unit pid state since msg tmp what
  name="$(jq -r '.name' <<<"$row")"; owner="$(jq -r '.owner' <<<"$row")"; ws="$(jq -r '.workspace' <<<"$row")"
  kind="$(jq -r '.kind // "unit"' <<<"$row")"; unit="$(jq -r '.unit // ""' <<<"$row")"
  if [ "$kind" = pid ]; then
    pid="$(jq -r '.pid // 0' <<<"$row")"
    if _serve_pid_live "$row"; then state=present; else state=gone; fi
  else
    state="$(_serve_unit_state "$unit")"
  fi
  since="$(jq -r '.gone_since // ""' <<<"$row")"
  case "$state" in
    unknown) return 0 ;;
    present)
      [ -n "$since" ] || return 0
      tmp="$(mktemp "$(_serve_state)/.gone.XXXXXX")" || return 0
      { jq 'del(.gone_since)' <<<"$row" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$f"; } || rm -f "$tmp"
      return 0 ;;
  esac
  if [ "$kind" != pid ]; then
    if ! [[ "$since" =~ ^[0-9]+$ ]]; then
      since="$now"
      tmp="$(mktemp "$(_serve_state)/.gone.XXXXXX")" || return 0
      { jq --argjson at "$now" '.gone_since = $at' <<<"$row" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$f"; } || rm -f "$tmp"
    fi
    [ "$((now - since))" -ge "$(_serve_gone_grace)" ] || return 0
  fi
  rm -f "$f"
  if [ "$kind" = pid ]; then what="pid $pid exited"; else what="unit $unit is gone"; fi
  msg="steward: your permanent server $name is gone ($what) - its registration is dropped and nothing was restarted. If it comes back, register it again: cel serve adopt <unit|pid> --owner $owner --workspace $ws --permanent."
  cmd_inbox send "$owner" "$msg" --from steward --workspace "$ws" --kind status --fp "serve-gone-$name" >/dev/null 2>&1 || true
  c_warn "$msg"
}

serve_sweep() {
  local f row now started ttl last idle unit name owner ws worktree msg reason
  _serve_refresh_connections
  now="$(_serve_now)"
  idle="${CEL_SERVE_IDLE_SECONDS:-$(_serve_idle_seconds)}"
  if boxguard_pressure 2>/dev/null; then idle="${CEL_SERVE_PRESSURE_IDLE_SECONDS:-$(_serve_pressure_idle_seconds)}"; fi
  for f in "$(_serve_state)"/*.json; do
    [ -f "$f" ] || continue
    row="$(jq -c . "$f" 2>/dev/null)" || continue
    if [ "$(jq -r '.permanent // false' <<<"$row")" = true ]; then _serve_sweep_permanent "$f" "$row" "$now"; continue; fi
    local kind pid
    kind="$(jq -r '.kind // "unit"' <<<"$row")"
    # a pid that exited or was reused is gone at once, whatever its clock
    if [ "$kind" = pid ] && ! _serve_pid_live "$row"; then
      rm -f "$f"
      name="$(jq -r '.name' <<<"$row")"; owner="$(jq -r '.owner' <<<"$row")"; ws="$(jq -r '.workspace' <<<"$row")"
      msg="steward: your registered server $name is gone (pid $(jq -r '.pid' <<<"$row") exited, or its pid was reused) - its registration is dropped and nothing was stopped."
      cmd_inbox send "$owner" "$msg" --from steward --workspace "$ws" --kind status --fp "serve-gone-$name" >/dev/null 2>&1 || true
      c_warn "$msg"
      continue
    fi
    name="$(jq -r '.name' <<<"$row")"; unit="$(jq -r '.unit' <<<"$row")"
    owner="$(jq -r '.owner' <<<"$row")"; ws="$(jq -r '.workspace' <<<"$row")"
    worktree="$(jq -r '.worktree' <<<"$row")"; started="$(jq -r '.started_at' <<<"$row")"
    ttl="$(jq -r '.ttl_seconds' <<<"$row")"; last="$(jq -r '.last_request_at // .started_at' <<<"$row")"
    if [ -n "$worktree" ] && [ ! -d "$worktree" ]; then reason='worktree is gone'
    elif [ "$((now-started))" -ge "$ttl" ]; then reason='TTL expired'
    elif [ "$((now-last))" -ge "$idle" ]; then reason="no request for $((idle/3600)) hours"
    else continue
    fi
    if [ "$kind" = pid ]; then
      pid="$(jq -r '.pid' <<<"$row")"
      _serve_pid_live "$row" || continue
      kill -TERM "$pid" 2>/dev/null || continue
    else
      serve_unit_stop "$unit" || continue
    fi
    rm -f "$f"
    msg="steward: stopped preview server $name ($unit) for $owner: $reason. Restart with 'cel serve start $name --owner $owner --workspace $ws --ttl $((ttl/3600))h --port $(jq -r '.port' <<<"$row") -- $(jq -r '.command' <<<"$row")'."
    cmd_inbox send "$owner" "$msg" --from steward --workspace "$ws" --kind status --fp "serve-stop-$name" >/dev/null 2>&1 || true
    c_warn "$msg"
  done
}
# WHO IS TOLD ABOUT A SERVER: the agent whose directory it runs in, asked in
# this order:
#  1. a product's own directory is its agent's; a lane's directory the lane's;
#  2. a directory inside a git work tree is known by the repository it is a
#     checkout of, not by its path - a repo symlinked into <ws>/repos/<repo>
#     (its checkout lives elsewhere), a worktree of it anywhere, a solo
#     worktree: when its common git dir is that of a registered workspace's
#     repos/<repo>, it is the repo's PR owner (ws_repo_pr_owner: the lane a
#     repo declares, else its product's agent);
#  3. a repo's repos[].owns_paths (committed workspace.yaml only): globs, ~/
#     the home dir, a relative one under the workspace (ws_owns_glob); a dir
#     a glob matches, or one under it, is the repo's. The longest glob wins;
#  4. a dir no git identity placed whose path is a repo's real root (repos/
#     <repo> with every symlink resolved) or under it, or a sibling of it
#     named "<real root>" plus a KNOWN suffix, alone or followed by a dash -
#     -wt, -worktrees, -local[-*], -data[-*], -release[-*]: the worktree,
#     data and release dirs a repo's tooling puts beside it,
#     ~/code/slot-studio-wt or -local-cf-data next to ~/code/slot-studio - is
#     that repo's. Any other "<root>-..." is another project (app-other-
#     project, app-database and app-release-notes are not app's); owns_paths
#     claims it if it is the repo's. The longest root wins: a repo checked out
#     at <root>-data beats <root>'s "-data-*" for dirs in <root>-data;
#  5. inside a workspace: repos/<repo> is the repo's owner, .cel/solo/
#     <product>/... the product's agent, anything else that workspace's root;
#  6. anything outside every workspace is root of the box's first workspace
#     in registry order, said with a third word, "outside".
# A git call that cannot answer in 2s (a hung mount) is no git identity: the
# path rules decide. An empty or missing dir has none either (git -C '' would
# answer for the steward's own cwd), and an empty path matches no path rule.
_serve_git_common() { # <dir> -> the resolved common git dir of the work tree <dir> is in
  local c
  [ -n "$1" ] && [ -d "$1" ] || return 1
  local -a git=(git -C "$1" rev-parse --is-inside-work-tree --path-format=absolute --git-common-dir)
  command -v timeout >/dev/null 2>&1 && git=(timeout 2 "${git[@]}")
  c="$("${git[@]}" 2>/dev/null)" || return 1
  # a bare repo, or a .git dir, is no work tree
  [ "${c%%$'\n'*}" = true ] || return 1
  c="${c#*$'\n'}"
  [ -n "$c" ] || return 1
  readlink -f "$c" 2>/dev/null || printf '%s\n' "$c"
}
# Each workspace's repos/<repo> common dirs, and each workspace's repos (one
# line each: <repo> TAB <real root> [TAB <owns_paths glob>]...), read once per
# tick: the unledgered report and the idle build-daemon note call
# _serve_owner_preload before they resolve any owner, in the calling shell, so
# the _serve_dir_owner subshells after it ask yq and git nothing again.
declare -gA _SERVE_REPO_COMMON=() _SERVE_WS_REPOS=()
_serve_repo_common() { # <dir> -> memoised _serve_git_common (empty: none)
  [ "${_SERVE_REPO_COMMON[$1]+x}" = x ] || _SERVE_REPO_COMMON[$1]="$(_serve_git_common "$1" || true)"
  printf '%s' "${_SERVE_REPO_COMMON[$1]}"
}
_serve_ws_repos_load() { # <wsdir> - fills _SERVE_WS_REPOS[<wsdir>] unless read this tick
  [ "${_SERVE_WS_REPOS[$1]+x}" != x ] || return 0
  local r rest out=''
  while IFS=$'\t' read -r r rest; do
    [ -n "$r" ] || continue
    out+="$r"$'\t'"$(readlink -f "$1/repos/$r" 2>/dev/null || printf '%s' "$1/repos/$r")${rest:+$'\t'$rest}"$'\n'
  done < <(_yqr -r '.repos // [] | .[] | select((.name | type) == "string" and (.name | length) > 0)
      | [.name] + ((.owns_paths // []) | if type == "array" then map(strings | select(length > 0)) else [] end)
      | @tsv' "$1/workspace.yaml" 2>/dev/null)
  _SERVE_WS_REPOS[$1]="$out"
}
_serve_owner_preload() { # empties both memos and reads this tick's
  local w wd r
  _SERVE_REPO_COMMON=(); _SERVE_WS_REPOS=()
  for w in $(registry_names 2>/dev/null); do
    wd="$(registry_path "$w")" && [ -n "$wd" ] || continue
    wd="$(readlink -f "$wd" 2>/dev/null || printf '%s' "$wd")"
    _serve_ws_repos_load "$wd"
    while IFS=$'\t' read -r r _; do [ -z "$r" ] || _serve_repo_common "$wd/repos/$r" >/dev/null; done <<<"${_SERVE_WS_REPOS[$wd]}"
  done
}
_serve_dir_owner() { # <dir> -> "<ws> <mailbox>" | "<first-ws> root outside"
  local dir="${1%/}" ws wsdir rel p rest repo common i root sib g len best=-1 bi='' br=''
  local -a names=() dirs=() globs=()
  for ws in $(registry_names 2>/dev/null); do
    wsdir="$(registry_path "$ws")" && [ -n "$wsdir" ] || continue
    wsdir="$(readlink -f "$wsdir" 2>/dev/null || printf '%s' "$wsdir")"
    names+=("$ws"); dirs+=("$wsdir")
    _serve_ws_repos_load "$wsdir"
  done
  [ "${#names[@]}" -gt 0 ] || return 0
  case "$dir" in /?*) ;; *) printf '%s root outside\n' "${names[0]}"; return 0 ;; esac
  for i in "${!names[@]}"; do
    ws="${names[$i]}"; wsdir="${dirs[$i]}"
    case "$dir" in "$wsdir"/*) ;; *) continue ;; esac
    rel="${dir#"$wsdir"/}"
    case "$rel" in
      products/*) p="${rel#products/}"; p="${p%%/*}"
        ws_product_names "$wsdir" 2>/dev/null | grep -qxF -- "$p" && { printf '%s %s-orch\n' "$ws" "$p"; return 0; } ;;
      .cel/solo/?*/lane-?*) p="${rel#.cel/solo/}"; rest="${p#*/}"; rest="${rest%%/*}"; p="${p%%/*}"
        ws_product_names "$wsdir" 2>/dev/null | grep -qxF -- "$p" && { printf '%s %s\n' "$ws" "$(cel_alias_norm "$p/${rest#lane-}")"; return 0; } ;;
    esac
  done
  if common="$(_serve_git_common "$dir")"; then
    for i in "${!names[@]}"; do
      while IFS=$'\t' read -r repo _; do
        [ -n "$repo" ] && [ "$(_serve_repo_common "${dirs[$i]}/repos/$repo")" = "$common" ] || continue
        printf '%s %s\n' "${names[$i]}" "$(ws_repo_pr_owner "${dirs[$i]}" "$repo")"; return 0
      done <<<"${_SERVE_WS_REPOS[${dirs[$i]}]}"
    done
  fi
  # owns_paths, else real roots and their "<root>-" siblings: the longest match
  for i in "${!names[@]}"; do
    while IFS=$'\t' read -r repo root rest; do
      [ -n "$repo" ] && [ -n "$rest" ] || continue
      IFS=$'\t' read -r -a globs <<<"$rest"
      for g in "${globs[@]}"; do
        g="$(ws_owns_glob "${dirs[$i]}" "$g")"; [ -n "$g" ] || continue
        # shellcheck disable=SC2053 # the glob is a pattern on purpose
        [[ "$dir" == $g || "$dir" == $g/* ]] || continue
        [ "${#g}" -gt "$best" ] && { best="${#g}"; bi="$i"; br="$repo"; }
      done
    done <<<"${_SERVE_WS_REPOS[${dirs[$i]}]}"
  done
  if [ -z "$br" ]; then
    for i in "${!names[@]}"; do
      while IFS=$'\t' read -r repo root _; do
        [ -n "$repo" ] && [ "${root%/}" != "" ] || continue
        root="${root%/}"
        case "$dir" in
          "$root"|"$root"/*) len="${#root}" ;;
          "$root"-*) sib="${dir#"$root"}"; sib="${sib%%/*}"
            case "$sib" in -wt|-worktrees|-local|-local-*|-data|-data-*|-release|-release-*) len="$(( ${#root} + 1 ))" ;; *) continue ;; esac ;;
          *) continue ;;
        esac
        [ "$len" -gt "$best" ] && { best="$len"; bi="$i"; br="$repo"; }
      done <<<"${_SERVE_WS_REPOS[${dirs[$i]}]}"
    done
  fi
  [ -z "$br" ] || { printf '%s %s\n' "${names[$bi]}" "$(ws_repo_pr_owner "${dirs[$bi]}" "$br")"; return 0; }
  for i in "${!names[@]}"; do
    ws="${names[$i]}"; wsdir="${dirs[$i]}"
    case "$dir" in "$wsdir"|"$wsdir"/*) ;; *) continue ;; esac
    rel="${dir#"$wsdir"}"; rel="${rel#/}"
    case "$rel" in
      repos/?*) repo="${rel#repos/}"; repo="${repo%%/*}"
        ws_repo_names "$wsdir" 2>/dev/null | grep -qxF -- "$repo" && { printf '%s %s\n' "$ws" "$(ws_repo_pr_owner "$wsdir" "$repo")"; return 0; } ;;
      .cel/solo/?*) p="${rel#.cel/solo/}"; p="${p%%/*}"
        ws_product_names "$wsdir" 2>/dev/null | grep -qxF -- "$p" && { printf '%s %s-orch\n' "$ws" "$p"; return 0; } ;;
    esac
    printf '%s root\n' "$ws"; return 0
  done
  printf '%s root outside\n' "${names[0]}"
}

# A server's identity, which drifts with nothing a tick sees: a unit by its
# name; a bare pid by its directory, command name and what tells two servers
# of one interpreter apart - the port it listens on, else its script (the first
# non-flag argument after the interpreter) - never the pid, so a dev server
# restarted in the same directory on the same port is the same server, and
# vite and next (both node) in one directory are two.
_SERVE_UNLEDGERED_JQ='
  def words: [(.command // "") | splits(" +") | select(. != "")];
  def comm: (words | .[0] // "?") | split("/") | last;
  def script: words | .[1:] | map(select(startswith("-") | not)) | (.[0] // "");
  def ident: . as $r | ($r.worktree // "") as $d
    | (if ($r.unit // "") != "" then {key: ("unit:" + $r.unit), name: ($r.unit + (if $d != "" then " in " + $d else "" end))}
       else ($r | comm) as $c | ($r.port // 0) as $p | ($r | script) as $s
         | (if $p > 0 then {id: " port \($p)", shown: " on port \($p)"}
            elif $s != "" then {id: (" " + $s), shown: (" " + ($s | split("/") | last))}
            else {id: "", shown: ""} end) as $x
         | {key: ("dir:" + $d + " " + $c + $x.id), name: ($c + $x.shown + " in " + (if $d == "" then "?" else $d end))} end)
    | . + {dir: $d, line: (.name + " (" + (if ($r.pid // 0) > 0 then "pid \($r.pid), " else "" end)
                           + "\($r.memory_mb // 0)MB, \($r.age_seconds // 0)s)")};
  # Only a server up $min seconds counts, or one already reported (its key is
  # in $prev - a restart under that key resets its age but not its identity).
  ($rows | map(ident + {age: (.age_seconds // 0)})) as $seen
  | ($seen | map(select(.age >= $min or $prev[.key] != null))) as $cur
  | (reduce $cur[] as $s ({}; if has($s.key) then . else . + {($s.key): $s} end)) as $now
  | {n: ($cur | length), all: ($cur | map(.line)), now: $now,
     new: (reduce $cur[] as $s ([]; if $prev[$s.key] != null or any(.[]; .key == $s.key) then . else . + [$s] end)),
     gone: [$prev | to_entries[] | select($now[.key] == null) | {key, name: .value.name}]}'

# ONCE PER CHANGE OF THE SET. Memory and age differ every tick, so a report of
# them is a report every tick; what root needs is which servers came and went.
# A server counts only once it has been up CEL_UNLEDGERED_MIN_AGE_MIN minutes
# (default 15): a worker's dev server restarting every few minutes, a test
# server, is never New, and so never Gone - Gone is said only of servers once
# said New. The adopt, fleet and dashboard views still list young servers.
# The state file holds the set last reported (key -> name, and the owner still
# owed its new line). A change - a server new since then, or one gone - is one
# message to the first workspace's root, as the orphan line goes: what is new,
# what is gone, and the full current list. An unchanged set says nothing, and
# a server that goes and comes back is new again, from its new age. Each new server's line also
# goes to the agent whose directory it runs in (_serve_dir_owner), one message
# per agent, and root's summary says after that server who was told; when that
# is root, the summary already told it. A server in no workspace is root's of
# the first workspace in registry order, and the summary says so, naming it. A
# send that fails is not a report: root's leaves the state as it was, so the
# change is offered again next tick, and an owner's stays owed until it arrives.
_serve_unledgered_report() {
  local rows state_file prev plan n new gone all root_ws msg owners='{}' next key dir name line owner item mbox tmp outside='' min
  rows="$(serve_adopt_json 2>/dev/null)" || return 0
  min="${CEL_UNLEDGERED_MIN_AGE_MIN:-15}"; [[ "$min" =~ ^[0-9]+$ ]] || min=15
  state_file="$(_serve_state)/unledgered-reported.json"
  prev="$(jq -ce 'objects' "$state_file" 2>/dev/null)" || prev='{}'
  plan="$(jq -cn --argjson rows "$rows" --argjson prev "$prev" --argjson min "$(( 10#$min * 60 ))" "$_SERVE_UNLEDGERED_JQ")" || return 0
  new="$(jq -r '.new | map(.line) | join("; ")' <<<"$plan")"
  gone="$(jq -r '.gone | map(.name) | join("; ")' <<<"$plan")"
  next="$prev"
  if [ -n "$new$gone" ]; then
    root_ws="$(registry_names 2>/dev/null | head -n1)"
    [ -n "$root_ws" ] || return 0
    _serve_owner_preload
    new=''
    # \x1f, not a tab: an empty dir must stay a field of its own
    while IFS=$'\x1f' read -r key dir name line; do
      [ -n "$key" ] || continue
      owner="$(_serve_dir_owner "$dir")"
      case "$owner" in
        *" outside") outside="${outside:+$outside; }$name" ;;
        ""|"$root_ws root") ;;
        *) owners="$(jq -c --arg k "$key" --arg o "$owner" '. + {($k): $o}' <<<"$owners")"
           line+=", told ${owner#* } (${owner%% *})" ;;
      esac
      new="${new:+$new; }$line"
    done < <(jq -r '.new[] | [.key, .dir, .name, .line] | join("\u001f")' <<<"$plan")
    [ -z "$outside" ] || outside=" Outside every workspace, so reported to workspace $root_ws's root (the first in the registry): $outside."
    n="$(jq -r '.n' <<<"$plan")"; all="$(jq -r '.all | join("; ")' <<<"$plan")"
    msg="steward: unledgered preview/dev servers changed.${new:+ New: $new.}${gone:+ Gone: $gone.} Now $n${all:+, biggest first: $all}.$outside Review with 'cel serve adopt'; nothing unledgered was stopped."
    c_warn "$msg"
    if ! cmd_inbox send root "$msg" --from steward --workspace "$root_ws" --kind status --fp unledgered-servers >/dev/null 2>&1; then
      c_warn "unledgered-server change not delivered to root ($root_ws) - retried next tick"
      return 0
    fi
    # Keys change shape now and then (dir+comm became dir+comm+port/script):
    # the first tick after reports the old keys gone and the same servers new,
    # once, and an owner's line still owed under an old key is dropped - the
    # new key's owner is owed it afresh, which is intended.
    next="$(jq -c --argjson plan "$plan" --argjson owners "$owners" '
      with_entries(select($plan.now[.key] != null))
      + ($plan.new | map({(.key): ({name} + (if $owners[.key] then {owed: $owners[.key]} else {} end))}) | add // {})' <<<"$prev")"
  fi
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    owner="$(jq -r '.owner' <<<"$item")"; mbox="${owner#* }"
    msg="steward: new unledgered preview/dev server(s) in your directory: $(jq -r '.lines' <<<"$item"). Review with 'cel serve adopt'; nothing unledgered was stopped."
    if cmd_inbox send "$mbox" "$msg" --from steward --workspace "${owner%% *}" --kind status --fp unledgered-servers >/dev/null 2>&1; then
      next="$(jq -c --argjson ks "$(jq -c '.keys' <<<"$item")" 'reduce $ks[] as $k (.; .[$k] |= del(.owed))' <<<"$next")"
    else
      c_warn "unledgered-server note not delivered to $mbox (${owner%% *}) - retried next tick"
    fi
  done < <(jq -c --argjson plan "$plan" '[to_entries[] | select(.value.owed and $plan.now[.key]) | {owner: .value.owed, key, line: $plan.now[.key].line}]
    | group_by(.owner)[] | {owner: .[0].owner, keys: map(.key), lines: (map(.line) | join("; "))}' <<<"$next")
  [ "$next" != "$prev" ] || return 0
  mkdir -p "$(_serve_state)" && tmp="$(mktemp "$state_file.XXXXXX")" || return 0
  printf '%s\n' "$next" > "$tmp" && mv -f "$tmp" "$state_file" || rm -f "$tmp"
}


cmd_serve() {
  local action="${1:-}"; [ $# -gt 0 ] && shift
  case "$action" in
    start)
      local name="${1:-}" owner='' ws='' ttl=28800 port=0
      [ $# -gt 0 ] && shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --owner) owner="${2:-}"; shift 2;;
          --workspace) ws="${2:-}"; shift 2;;
          --ttl) ttl="${2:-}"; shift 2; ttl="${ttl%h}"; [[ "$ttl" =~ ^[0-9]+$ ]] || die 'cel serve start: bad ttl'; ttl=$((ttl * 3600));;
          --port) port="${2:-}"; shift 2;;
          --) shift; serve_start "$name" "$owner" "$ws" "$ttl" "$port" -- "$@"; return $?;;
          *) die "cel serve start: unexpected argument $1";;
        esac
      done
      die 'cel serve start: expected -- <command>';;
    list)
      if [ "${1:-}" = --json ]; then serve_list_json; else
        printf '%-24s %-18s %-12s %-7s %-10s %-14s %-10s %s\n' NAME OWNER WORKSPACE PORT MEMORY AGE TTL LAST-REQUEST
        # a permanent server also says where it runs and what: what a
        # registration shields from every sweep is in view of a person
        serve_list_json | jq -r '.[] | [.name,.owner,.workspace,(.port|tostring),((.memory_mb|tostring)+"M"),((.age_seconds|tostring)+"s"),(if .permanent then "permanent" else ((.ttl_seconds // 0) / 3600 | floor | tostring) + "h" end),((now - (.last_request_at // .started_at))|floor|tostring + "s ago"),(if .permanent then "dir \(.working_directory // .worktree // "?")  runs \(.command // "?")" else "" end)] | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' \
          | while IFS=$'\x1f' read -r name owner ws port mem age ttl last detail; do
            printf '%-24s %-18s %-12s %-7s %-10s %-14s %-10s %s\n' "$name" "$owner" "$ws" "$port" "$mem" "$age" "$ttl" "$last"
            [ -z "$detail" ] || printf '  %s\n' "$detail"
          done
      fi;;
    stop) [ $# -eq 1 ] || die 'cel serve stop <name|unit|pid>'; serve_stop "$1";;
    adopt)
      if [ "${1:-}" = --json ]; then serve_adopt_json
      elif [ $# -eq 0 ]; then
        serve_adopt_json | jq -r '.[] | "\(.unit // "pid:\(.pid)") group=\(.group) \(.memory_mb)MB \(.age_seconds)s port=\(.port // 0) \(.worktree // "")"'
      else
        local target="$1" owner='' ws='' ttl='' port='' permanent=0 why=''
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            --owner) owner="${2:-}"; shift 2;;
            --workspace) ws="${2:-}"; shift 2;;
            --ttl) ttl="${2:-}"; shift 2; ttl="${ttl%h}"; [[ "$ttl" =~ ^[0-9]+$ ]] || die 'cel serve adopt: bad ttl'; ttl=$((ttl*3600));;
            --permanent) permanent=1; shift;;
            --why) why="${2:-}"; shift 2;;
            --port) port="${2:-}"; shift 2;;
            *) die "cel serve adopt: unexpected argument $1";;
          esac
        done
        [ -n "$owner" ] && [ -n "$ws" ] || die 'cel serve adopt <unit|pid> --owner <alias> --workspace <ws> [--ttl 8h | --permanent] [--port N] [--why "..."]'
        if [ "$permanent" = 1 ]; then
          [ -z "$ttl" ] || die 'cel serve adopt: --permanent has no TTL - give --ttl or --permanent, not both'
          ttl=permanent
        fi
        serve_adopt "$target" "$owner" "$ws" "${ttl:-28800}" "$port" "$why"
      fi;;
    request) [ $# -eq 1 ] || die 'cel serve request <name>'; serve_request "$1";;
    *) die 'usage: cel serve start|list|stop|adopt';;
  esac
}
