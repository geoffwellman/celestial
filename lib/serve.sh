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
  rest="${line#*)}"; rest="${rest%%)*}"
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
  if [ "$kind" = pid ]; then
    pid="$(jq -r '.pid' <<<"$row")"
    [ "$(_serve_pid_start "$pid")" = "$(jq -r '.pid_start // ""' <<<"$row")" ] || return 1
    kill -TERM "$pid" || return $?
    rm -f "$f"
    return 0
  else
    unit="$(jq -r '.unit' <<<"$row")"
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
_serve_not_a_preview() { # <pid> <command>
  local pid="$1" cmd="$2" a0 a1 n cg unit exe proc="${CEL_SERVE_PROC_ROOT:-/proc}"
  read -r a0 a1 _ <<<"$cmd"
  n="${a0##*/}"
  # argv[1] names the program only when argv[0] is a script host; for
  # anything else it is an argument (`http-server ~/claude` is a preview).
  case "$n" in node|nodejs|bun|deno|python|python3*) n="${a1##*/}" ;; esac
  case "$n" in omp|pi|claude|codex|opencode|omp.*|pi.*) return 0 ;; esac
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
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

serve_adopt_json() {
  local rows row pid unit id f kind
  local -a ledger_units=()
  local -A ledger_pids=() ledger_names=()
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
  while IFS= read -r row; do
    pid="$(jq -r '.pid // 0' <<<"$row")"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      [[ -n "${ledger_pids[$pid]:-}" ]] && continue
      if [ "${#ledger_units[@]}" -gt 0 ] && _serve_pid_in_ledgered_unit "$pid" "${ledger_units[@]}"; then continue; fi
    fi
    # a unit row is already judged by its name (and the ignore list); a loose
    # pid is judged here
    if [ -z "$(jq -r '.unit // ""' <<<"$row")" ]; then
      _serve_not_a_preview "$pid" "$(jq -r '.command // ""' <<<"$row")" && continue
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
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ "$(_serve_pid_start "$pid")" = "$(jq -r '.pid_start // ""' <<<"$row")" ]; then
      state=present
    else
      state=gone
    fi
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
    name="$(jq -r '.name' <<<"$row")"; unit="$(jq -r '.unit' <<<"$row")"
    owner="$(jq -r '.owner' <<<"$row")"; ws="$(jq -r '.workspace' <<<"$row")"
    worktree="$(jq -r '.worktree' <<<"$row")"; started="$(jq -r '.started_at' <<<"$row")"
    ttl="$(jq -r '.ttl_seconds' <<<"$row")"; last="$(jq -r '.last_request_at // .started_at' <<<"$row")"
    if [ -n "$worktree" ] && [ ! -d "$worktree" ]; then reason='worktree is gone'
    elif [ "$((now-started))" -ge "$ttl" ]; then reason='TTL expired'
    elif [ "$((now-last))" -ge "$idle" ]; then reason="no request for $((idle/3600)) hours"
    else continue
    fi
    local kind pid
    kind="$(jq -r '.kind // "unit"' <<<"$row")"
    if [ "$kind" = pid ]; then
      pid="$(jq -r '.pid' <<<"$row")"
      [ "$(_serve_pid_start "$pid")" = "$(jq -r '.pid_start // ""' <<<"$row")" ] || { rm -f "$f"; continue; }
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
# ONCE A DAY PER PRODUCT, AND ONLY WHEN IT ARRIVED. The stamp file holds one
# "<day> <ws> <product>" line per delivered message; a send that fails leaves
# its product unstamped, so the next tick tries it again instead of the day
# passing in silence. Lines from an earlier day are dropped.
_serve_unledgered_report() {
  local rows n state_file today ws wsdir product msg sent delivered="" failed="" tmp
  rows="$(serve_adopt_json 2>/dev/null || printf '[]')"
  n="$(printf '%s' "$rows" | jq 'length')"
  [ "$n" -gt 0 ] || return 0
  today="$(date -u +%F)"; state_file="$(_serve_state)/unledgered-reported"
  mkdir -p "$(_serve_state)" || return 0
  sent="$(awk -v d="$today" '$1 == d && NF == 3 { print $2, $3 }' "$state_file" 2>/dev/null || true)"
  msg="steward: $n unledgered preview/dev server(s), biggest first: $(printf '%s' "$rows" | jq -r '.[0:10][] | "\(.unit // ("pid:"+(.pid|tostring))) \(.memory_mb)MB \(.age_seconds)s \(.worktree)"' | paste -sd';' -). Review with 'cel serve adopt'; nothing unledgered was stopped."
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    for product in $(ws_product_names "$wsdir" 2>/dev/null); do
      case $'\n'"$sent"$'\n' in *$'\n'"$ws $product"$'\n'*) continue ;; esac
      if cmd_inbox send "$product-orch" "$msg" --from steward --workspace "$ws" --kind status --fp unledgered-servers >/dev/null 2>&1; then
        delivered="$delivered$ws $product"$'\n'
      else
        failed="$failed $ws/$product-orch"
      fi
    done
  done
  [ -n "$delivered$failed" ] || return 0
  if [ -n "$delivered" ]; then
    tmp="$(mktemp "$state_file.XXXXXX")" || return 0
    { [ -z "$sent" ] || printf '%s\n' "$sent"; printf '%s' "$delivered"; } | sed "s/^/$today /" > "$tmp" \
      && mv -f "$tmp" "$state_file" || rm -f "$tmp"
  fi
  c_warn "$msg"
  [ -z "$failed" ] || c_warn "unledgered-server report not delivered to:$failed - retried next tick"
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
