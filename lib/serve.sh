# shellcheck shell=bash
# cel serve: explicitly owned, cgroup-accounted long-running development servers.
[ -n "${_CEL_SERVE:-}" ] && return 0
_CEL_SERVE=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/memory.sh
. "${BASH_SOURCE[0]%/*}/memory.sh"
# shellcheck source=lib/boxguard.sh
. "${BASH_SOURCE[0]%/*}/boxguard.sh"

_serve_state() { printf '%s' "${CEL_SERVE_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/servers}"; }
_serve_systemctl() { "${CEL_SERVE_SYSTEMCTL:-systemctl}" --user "$@"; }
_serve_systemd_run() { "${CEL_SERVE_SYSTEMD_RUN:-systemd-run}" --user "$@"; }
_serve_now() { printf '%s' "${CEL_SERVE_NOW:-$(date +%s)}"; }
_serve_pid_start() { cut -d ')' -f2 "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
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
  local d unit worktree now tmp cmd
  d="$(_serve_state)"; mkdir -p "$d"; chmod 700 "$d"
  [ ! -e "$d/$name.json" ] || die "cel serve start: $name already recorded"
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
  _serve_systemd_run --unit="$unit" --property="WorkingDirectory=$worktree" \
    --property="MemoryAccounting=yes" --property="CollectMode=inactive-or-failed" \
    --property="Description=cel serve $name ($owner, $ws)" \
    -- /bin/bash -lc "$cmd" || die "cel serve start: could not start $unit"
  tmp="$(mktemp "$d/.serve.XXXXXX")"
  jq -n --arg name "$name" --arg unit "$unit" --arg owner "$owner" --arg workspace "$ws" \
    --arg worktree "$worktree" --argjson started "$now" --argjson ttl "$ttl" --argjson port "$port" \
    --arg command "$cmd" '{name:$name,unit:$unit,owner:$owner,workspace:$workspace,worktree:$worktree,started_at:$started,ttl_seconds:$ttl,port:$port,last_request_at:$started,command:$command}' > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$( _serve_file "$name" )"
}

_serve_cgroup_memory() { # <unit> -> memory current bytes
  local path
  path="$(_serve_systemctl show -p ControlGroup --value "$1.service" 2>/dev/null || true)"
  [ -n "$path" ] || { printf 0; return; }
  awk '{print int($1/1048576)}' "/sys/fs/cgroup${path}/memory.current" 2>/dev/null || printf 0
}

serve_list_json() {
  local f row unit age mem now kind pid pid_start initial_age
  now="$(_serve_now)"
  for f in "$(_serve_state)"/*.json; do
    [ -f "$f" ] || continue
    row="$(jq -c . "$f" 2>/dev/null)" || continue
    unit="$(jq -r '.unit // ""' <<<"$row")"
    initial_age="$(jq -r '.initial_age_seconds // 0' <<<"$row")"
    [[ "$initial_age" =~ ^[0-9]+$ ]] || initial_age=0
    age=$((now - $(jq -r '.started_at' <<<"$row") + initial_age))
    kind="$(jq -r '.kind // "unit"' <<<"$row")"
    if [ "$kind" = pid ]; then
      pid="$(jq -r '.pid // 0' <<<"$row")"
      pid_start="$(jq -r '.pid_start // ""' <<<"$row")"
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -n "$pid_start" ] && [ "$(_serve_pid_start "$pid")" = "$pid_start" ]; then
        mem="$(awk '/^VmRSS:/{print int($2/1024)}' "/proc/$pid/status" 2>/dev/null || printf 0)"
      else
        mem=0
      fi
    else
      mem="$(_serve_cgroup_memory "$unit")"
    fi
    jq -c --argjson age "$age" --argjson memory "$mem" '. + {age_seconds:$age,memory_mb:$memory,managed:true}' <<<"$row"
  done | jq -s 'sort_by(-.memory_mb)'
}

serve_unit_stop() { # <unit> -- require exact durable ledger ownership
  local unit="$1" id f
  [[ "$unit" =~ ^[a-zA-Z0-9_.@-]{1,160}$ ]] || return 1
  for f in "$(_serve_state)"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.unit // ""' "$f" 2>/dev/null)" = "$unit" ] || continue
    id="$unit"; [[ "$id" == *.service ]] || id="$id.service"
    _serve_systemctl stop "$id" || return $?
    # a server that exits non-zero on SIGTERM is left failed and loaded
    _serve_systemctl reset-failed "$id" >/dev/null 2>&1 || true
    return 0
  done
  return 1
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
  local systemctl_bin="${CEL_SERVE_SYSTEMCTL:-systemctl}" description execstart mainpid
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    local short="${unit%.service}"
    [ -f "$(_serve_file "$short")" ] && continue
    # Celestial's own services (cel-dash, cel-pages, cel-auth-gateway, ...)
    # are the plane, not previews; only cel-serve-* units are servers it ran.
    case "$short" in cel-serve-*) ;; cel-*) continue ;; esac
    description="$("$systemctl_bin" --user show "$unit" -p Description --value 2>/dev/null || true)"
    execstart="$("$systemctl_bin" --user show "$unit" -p ExecStart --value 2>/dev/null || true)"
    case "$unit $description $execstart" in
      *cel-serve-*|*server*|*preview*|*dev*|*wrangler*|*vite*|*playground*) ;;
      *) continue;;
    esac
    mainpid="$("$systemctl_bin" --user show "$unit" -p MainPID --value 2>/dev/null || printf 0)"
    mem="$(_serve_cgroup_memory "$short")"
    local cwd='' age=0 port=0
    if [[ "$mainpid" =~ ^[1-9][0-9]*$ ]]; then
      cwd="$(readlink -f "/proc/$mainpid/cwd" 2>/dev/null || true)"
      age="$(ps -o etimes= -p "$mainpid" 2>/dev/null | tr -d ' ' || true)"
      [[ "$age" =~ ^[0-9]+$ ]] || age=0
      port="$(ss -H -ltnp 2>/dev/null | awk -v p="pid=$mainpid," 'index($0,p) && !found {x=$4; sub(/^.*:/,"",x); print x; found=1}')"
      [[ "$port" =~ ^[0-9]+$ ]] || port=0
    fi
    jq -cn --arg unit "$short" --arg command "$execstart" --arg cwd "$cwd" \
      --argjson pid "${mainpid:-0}" --argjson mem "$mem" --argjson age "$age" --argjson port "$port" \
      '{unit:$unit,pid:(if $pid==0 then null else $pid end),port:$port,memory_mb:$mem,age_seconds:$age,worktree:$cwd,command:$command,managed:false}'
  done < <("$systemctl_bin" --user list-units --type=service --state=running --plain --no-legend 2>/dev/null | awk '{print $1}')
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
  cgroup="$(awk -F: '$1 == "0" {print $3; exit}' "/proc/$pid/cgroup" 2>/dev/null || true)"
  [ -n "$cgroup" ] && _serve_cgroup_is_ledgered_unit "$cgroup" "$@"
}

# WHAT IS NOT A PREVIEW, though it listens on a port. The candidate list was
# "every process of mine with a TCP listener", and on 2026-10-24 it named live
# omp orchestrators, Hermes' gateway and its desktop servers as previews to
# adopt - and adopting puts a thing on a TTL that stops it. Refused here:
#   - coding-agent runtimes (omp, pi, claude, codex, opencode, by argv[0], or
#     argv[1] for a node/bun script);
#   - a process inside a running user SERVICE whose name the unit pass below
#     would not offer (hermes-gateway, cel-dash, ...): services are judged as
#     units, by name, never as loose pids;
#   - anything whose command contains an entry of box config `serve.ignore`
#     (comma-separated substrings) - the owner's own standing tools.
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
  local pid="$1" cmd="$2" a0 a1 n cg unit
  read -r a0 a1 _ <<<"$cmd"
  n="${a0##*/}"
  # argv[1] names the program only when argv[0] is a script host; for
  # anything else it is an argument (`http-server ~/claude` is a preview).
  case "$n" in node|nodejs|bun|deno|python|python3*) n="${a1##*/}" ;; esac
  case "$n" in omp|pi|claude|codex|opencode|omp.*|pi.*) return 0 ;; esac
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    cg="$(awk -F: '$1 == "0" {print $3; exit}' "${CEL_SERVE_PROC_ROOT:-/proc}/$pid/cgroup" 2>/dev/null || true)"
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
serve_adopt() { # <unit|pid> <owner> <workspace> <ttl-seconds> <port>
  local target="$1" owner="$2" ws="$3" ttl="$4" port="$5" rows row id unit='' pid='' now f tmp initial_age
  if [[ "$target" =~ ^pid:([1-9][0-9]*)$ ]]; then target="${BASH_REMATCH[1]}"; fi
  [[ "$ttl" =~ ^[1-9][0-9]*$ ]] || die 'cel serve adopt: invalid ttl seconds'
  [[ "$port" =~ ^[0-9]+$ ]] || die 'cel serve adopt: invalid port'
  [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die 'cel serve adopt: invalid owner'
  [[ "$ws" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die 'cel serve adopt: invalid workspace'
  rows="$(serve_adopt_json)"
  row="$(printf '%s' "$rows" | jq -ce --arg target "$target" '[.[] | select((.unit // "") == $target or ((.pid // 0) | tostring) == $target)] | .[0] // empty')" || die 'cel serve adopt: target is not a running unledgered server'
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    pid="$target"; id="pid-$pid"; unit=''
  else
    unit="$target"; id="${unit%.service}"; _serve_name_ok "$id" || die 'cel serve adopt: unit name cannot be ledgered'
  fi
  _serve_name_ok "$id" || die 'cel serve adopt: invalid identifier'
  initial_age="$(jq -r '.age_seconds // 0' <<<"$row")"; [[ "$initial_age" =~ ^[0-9]+$ ]] || initial_age=0
  f="$(_serve_file "$id")"; [ ! -e "$f" ] || die 'cel serve adopt: already ledgered'
  now="$(_serve_now)"; mkdir -p "$(_serve_state)"; chmod 700 "$(_serve_state)"; tmp="$(mktemp "$(_serve_state)/.adopt.XXXXXX")"
  jq -n --arg name "$id" --arg unit "$unit" --arg owner "$owner" --arg workspace "$ws" \
    --arg worktree "$(jq -r '.worktree // ""' <<<"$row")" --arg command "$(jq -r '.command // ""' <<<"$row")" \
    --argjson pid "${pid:-0}" --argjson started "$now" --argjson ttl "$ttl" --argjson port "$port" --argjson initial_age "$initial_age" \
    --arg pid_start "$(jq -r '.pid_start // ""' <<<"$row")" \
    --arg kind "$([ -n "$pid" ] && printf pid || printf unit)" \
    '{name:$name,unit:$unit,kind:$kind,pid:(if $kind == "pid" then $pid else null end),pid_start:$pid_start,owner:$owner,workspace:$workspace,worktree:$worktree,command:$command,started_at:$started,initial_age_seconds:$initial_age,ttl_seconds:$ttl,port:$port,last_request_at:$started}' > "$tmp"
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

serve_sweep() {
  local f row now started ttl last idle unit name owner ws worktree msg reason
  _serve_refresh_connections
  now="$(_serve_now)"
  idle="${CEL_SERVE_IDLE_SECONDS:-$(_serve_idle_seconds)}"
  if boxguard_pressure 2>/dev/null; then idle="${CEL_SERVE_PRESSURE_IDLE_SECONDS:-$(_serve_pressure_idle_seconds)}"; fi
  for f in "$(_serve_state)"/*.json; do
    [ -f "$f" ] || continue
    row="$(jq -c . "$f" 2>/dev/null)" || continue
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
_serve_unledgered_report() {
  local rows n state_file today ws wsdir product msg
  rows="$(serve_adopt_json 2>/dev/null || printf '[]')"
  n="$(printf '%s' "$rows" | jq 'length')"
  [ "$n" -gt 0 ] || return 0
  today="$(date -u +%F)"; state_file="$(_serve_state)/unledgered-reported"
  mkdir -p "$(_serve_state)" || return 0
  [ "$(cat "$state_file" 2>/dev/null || true)" != "$today" ] || return 0
  msg="steward: $n unledgered preview/dev server(s), biggest first: $(printf '%s' "$rows" | jq -r '.[0:10][] | "\(.unit // ("pid:"+(.pid|tostring))) \(.memory_mb)MB \(.age_seconds)s \(.worktree)"' | paste -sd';' -). Review with 'cel serve adopt'; nothing unledgered was stopped."
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    for product in $(ws_product_names "$wsdir" 2>/dev/null); do
      cmd_inbox send "$product-orch" "$msg" --from steward --workspace "$ws" --kind status --fp unledgered-servers >/dev/null 2>&1 || true
    done
  done
  printf '%s\n' "$today" > "$state_file"
  c_warn "$msg"
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
        printf '%-24s %-18s %-12s %-7s %-10s %-14s %s\n' NAME OWNER WORKSPACE PORT MEMORY AGE LAST-REQUEST
        serve_list_json | jq -r '.[] | [.name,.owner,.workspace,(.port|tostring),((.memory_mb|tostring)+"M"),((.age_seconds|tostring)+"s"),((now - (.last_request_at // .started_at))|floor|tostring + "s ago")] | @tsv' | while IFS=$'\t' read -r name owner ws port mem age last; do printf '%-24s %-18s %-12s %-7s %-10s %-14s %s\n' "$name" "$owner" "$ws" "$port" "$mem" "$age" "$last"; done
      fi;;
    stop) [ $# -eq 1 ] || die 'cel serve stop <name|unit|pid>'; serve_stop "$1";;
    adopt)
      if [ "${1:-}" = --json ]; then serve_adopt_json
      elif [ $# -eq 0 ]; then
        serve_adopt_json | jq -r '.[] | "\(.unit // "pid:\(.pid)") group=\(.group) \(.memory_mb)MB \(.age_seconds)s port=\(.port // 0) \(.worktree // "")"'
      else
        local target="$1" owner='' ws='' ttl=28800 port=0
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            --owner) owner="${2:-}"; shift 2;;
            --workspace) ws="${2:-}"; shift 2;;
            --ttl) ttl="${2:-}"; shift 2; ttl="${ttl%h}"; [[ "$ttl" =~ ^[0-9]+$ ]] || die 'cel serve adopt: bad ttl'; ttl=$((ttl*3600));;
            --port) port="${2:-}"; shift 2;;
            *) die "cel serve adopt: unexpected argument $1";;
          esac
        done
        [ -n "$owner" ] && [ -n "$ws" ] || die 'cel serve adopt <unit|pid> --owner <alias> --workspace <ws> [--ttl 8h] [--port N]'
        serve_adopt "$target" "$owner" "$ws" "$ttl" "$port"
      fi;;
    request) [ $# -eq 1 ] || die 'cel serve request <name>'; serve_request "$1";;
    *) die 'usage: cel serve start|list|stop|adopt';;
  esac
}
