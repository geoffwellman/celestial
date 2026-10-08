# shellcheck shell=bash
# cel dash - THE dashboard: one server for the whole box (CEL-107). Gathers
# the static config of every registered workspace (name, repos, services) here
# with the same yq the rest of the plane uses, then hands it to the
# zero-dependency node server as JSON; the server reads live state (herdr, gh)
# itself. Defaults to the tailnet IP when available, else loopback; --host
# explicitly selects another listener for the private control plane.
#
# It used to be one server per workspace. v2 reads across every workspace, so
# all four served the same page while polling the same herdr and gh four times
# over, and the per-workspace restart race took one of them down. The ports
# those servers had still answer, with a redirect here, for one release.
[ -n "${_CEL_DASH:-}" ] && return 0
_CEL_DASH=1
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Every registered workspace's own `dash.port`, in registry order - the ports
# the per-workspace servers used to hold, and now redirect from.
dash_legacy_ports() {
  local ws d p
  for ws in $(registry_names); do
    d="$(registry_path "$ws")" || continue
    [ -n "$d" ] && [ -f "$d/workspace.yaml" ] || continue
    p="$(_wsy "$d" '.dash.port')"
    [[ "$p" =~ ^[0-9]+$ ]] && printf '%s\n' "$p"
  done
  return 0
}

# The one port: `dash: port:` in the box config, else the first workspace's
# old port - so a bookmark of the first dashboard keeps working without a
# redirect hop - else 7770.
dash_port() {
  local p
  p="$(cel_config_get dash port)"
  [[ "$p" =~ ^[0-9]+$ ]] || p="$(dash_legacy_ports | head -n1)"
  printf '%s' "${p:-7770}"
}

dash_host() {
  local h
  h="$(cel_config_get dash host)"
  [ -n "$h" ] || h="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  printf '%s' "${h:-127.0.0.1}"
}

_dash_ws_config() { # <wsdir> -> one workspace's JSON
  yq -c --arg wsdir "$1" '{
    name: .name,
    wsdir: $wsdir,
    # slug: git@host:owner/name.git or https://host/owner/name -> owner/name
    repos: [(.repos // [])[] | {name: .name,
      slug: ((.url // "") | sub("^git@[^:]+:"; "") | sub("^https?://[^/]+/"; "") | sub("\\.git$"; ""))}],
    services: (.services // []),
    linearTeams: ([(.repos // [])[].linear_team // empty] | unique),
    # the state that means "build this", so the board can say so instead of
    # naming a state this team may not even have
    triggerState: (.tickets.trigger_state // "")
  }' "$1/workspace.yaml"
}

_dash_config() { # <port> <host> -> JSON on stdout
  local port="$1" host="$2" ws d build list="" legacy
  build="v$(tr -d '[:space:]' < "$CEL_ROOT/VERSION" 2>/dev/null || printf '?') $(git -C "$CEL_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'nogit')"
  for ws in $(registry_names); do
    d="$(registry_path "$ws")" || continue
    [ -n "$d" ] && [ -f "$d/workspace.yaml" ] || continue
    list+="$(_dash_ws_config "$d")"$'\n'
  done
  legacy="$(dash_legacy_ports | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')"
  printf '%s' "$list" | jq -sc --argjson port "$port" --arg host "$host" --arg build "$build" \
    --argjson legacy "$legacy" '{
      # the first workspace is the default wherever a page shows one
      name: (.[0].name // ""), wsdir: (.[0].wsdir // ""), repos: (.[0].repos // []),
      port: $port, host: $host, build: $build,
      redirectPorts: [$legacy[] | select(. != $port)],
      workspaces: .
    }'
}

# The dashboard is a box service like the pages servers: nothing owns its
# pane, so `--ensure` starts it only when its port is not already answering,
# and the steward calls it every tick. Warning about a dead dashboard achieved
# nothing - it stayed dead.
_dash_log_dir() { printf '%s' "${CEL_DASH_LOG_DIR:-$HOME/.local/share/cel/logs}"; }

# Is anything listening on host:port? A bash /dev/tcp connect, so a server
# mid-shutdown that still holds the port but no longer answers http counts.
# A connect that HANGS (a full backlog nobody accepts) is held too: only a
# refused connection means free.
_dash_port_free() { # <host> <port> -> 0 when nothing accepts a connection
  local rc=0
  timeout 2 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]
}

# CEL-102: wait (bounded, CEL_DASH_PORT_WAIT_S, default 15 s) for the port to
# come free. A restart that starts the new server while the old one still
# holds it dies with EADDRINUSE and nothing retries.
_dash_wait_port_free() { # <host> <port>
  local host="$1" port="$2" bound="${CEL_DASH_PORT_WAIT_S:-15}" t0=$SECONDS
  while ! _dash_port_free "$host" "$port"; do
    [ $((SECONDS - t0)) -lt "$bound" ] || return 1
    sleep 0.25
  done
  return 0
}

_dash_ensure() { # <port> <host>
  local port="$1" host="$2" log
  log="$(_dash_log_dir)/dash.log"
  if curl -sf -m 3 -o /dev/null "http://$host:$port/api/state"; then
    c_ok "dash already serving on $port"
    return 0
  fi
  if ! _dash_wait_port_free "$host" "$port"; then
    c_err "dash: port $port still in use after ${CEL_DASH_PORT_WAIT_S:-15}s and not answering as a dashboard - not starting (what holds it: ss -ltnp | grep :$port)"
    return 1
  fi
  mkdir -p "$(_dash_log_dir)"
  # setsid: outlives the pane or agent that ensured it
  setsid nohup "$CEL_ROOT/bin/cel" dash --port "$port" --host "$host" \
    >>"$log" 2>&1 &
  local pid=$! i
  for i in $(seq 1 20); do
    sleep 0.5
    curl -sf -m 3 -o /dev/null "http://$host:$port/api/state" \
      && { c_ok "dash started on $port (log: $log)"; return 0; }
    kill -0 "$pid" 2>/dev/null || break
  done
  c_err "dash did not come up on $port - see $log"
  return 1
}

# `--ensure` leaves a running server alone, which is exactly wrong after an
# update: the old code keeps serving until someone notices. `--restart` stops
# the dashboard - matched by the server.mjs path plus a port in its own
# CEL_DASH_CONFIG, never by a bare pkill that would also take a worktree's
# test server down - and then ensures as usual. The ports given are the
# dashboard's AND the old per-workspace ones: a box upgrading from one server
# per workspace still runs those, and they hold the ports the redirects need.
_dash_stop() { # <port>...
  local port pid env pids=""
  for pid in $(pgrep -f 'tools/dash/server\.mjs' 2>/dev/null); do
    env="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep '^CEL_DASH_CONFIG=' || true)"
    for port in "$@"; do
      case "$env" in *'"port":'"$port"[,}]*)
        kill "$pid" 2>/dev/null && { c_ok "stopped dash on $port (pid $pid)"; pids+=" $pid"; }
        break ;;
      esac
    done
  done
  # and wait for them to be gone (bounded): a killed node can hold its
  # listener for a moment, and the next start would hit EADDRINUSE
  # A server that outlives TERM past the bound is KILLed: otherwise ensure
  # would find the OLD one still answering and call the restart a success.
  local t0=$SECONDS left=0
  for pid in $pids; do
    while kill -0 "$pid" 2>/dev/null && [ $((SECONDS - t0)) -lt "${CEL_DASH_PORT_WAIT_S:-15}" ]; do sleep 0.2; done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null; sleep 0.3
      kill -0 "$pid" 2>/dev/null && { c_err "dash (pid $pid) survived SIGKILL"; left=1; }
    fi
  done
  return "$left"
}

_dash_restart() { # <port> <host>
  # shellcheck disable=SC2046
  _dash_stop "$1" $(dash_legacy_ports) || { c_err "dash: the old server would not stop - not restarting"; return 1; }
  _dash_ensure "$1" "$2"
}

cmd_dash() { # [--port n] [--host h] [--ensure] [--restart]
  local port="" host="" ensure=0 restart=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)      port="$2"; shift 2 ;;
      --host)      host="$2"; shift 2 ;;
      --ensure)    ensure=1; shift ;;
      --restart)   restart=1; shift ;;
      --workspace) die "cel dash: there is one dashboard for the box now - drop --workspace (open /classic?ws=${2:-<name>} for the old per-workspace page)" ;;
      *) die "cel dash: unknown argument '$1' (want --port, --host, --ensure, --restart)" ;;
    esac
  done
  have node || die "cel dash: node is not on PATH"
  have yq   || die "cel dash: yq is not on PATH"
  [ -n "$port" ] || port="$(dash_port)"
  [ -n "$host" ] || host="$(dash_host)"
  [ "$restart" -eq 1 ] && { _dash_restart "$port" "$host"; return $?; }
  [ "$ensure" -eq 1 ] && { _dash_ensure "$port" "$host"; return $?; }

  # The dashboard runs with the workspaces' env, exactly like a pane started
  # inside one - that is how LINEAR_API_KEY (env.local) reaches the server
  # without the key ever being written into config or a repo. Loaded last to
  # first, so where two workspaces set the same name the first one wins.
  local ws d wsdirs=()
  for ws in $(registry_names); do
    d="$(registry_path "$ws")" || continue
    [ -n "$d" ] && wsdirs=("$d" "${wsdirs[@]}")
  done
  for d in "${wsdirs[@]}"; do
    # shellcheck disable=SC1090
    eval "$(ws_env_exports "$d" 2>/dev/null)" || true
  done
  # CEL_DASH_TRUSTED_ORIGINS admits exact additional http(s) origins.
  # Mutations require X-Cel-CSRF from GET /api/session. Automation may instead
  # supply CEL_DASH_CSRF_TOKEN before startup; never put it in workspace.yaml.
  CEL_DASH_CONFIG="$(_dash_config "$port" "$host")" \
  CEL_EFFECTS_DIR="${CEL_EFFECTS_DIR:-$HOME/.local/share/cel/vendor/canvasui}" \
  CEL_INBOX_DIR="$(printf '%s' "${CEL_INBOX_DIR:-$HOME/.local/share/cel/inbox}")" \
    exec node "$CEL_ROOT/tools/dash/server.mjs"
}

# THE DOCTOR'S LINE: one dashboard, where it is, and whether it answers. A
# second dash server is named too - it is a per-workspace one left over from
# before CEL-107, holding a port the redirects want.
dash_doctor_line() {
  local port host n
  port="$(dash_port)"; host="$(dash_host)"
  if curl -sf -m 3 -o /dev/null "http://$host:$port/api/state"; then
    printf '  dashboard: one for the box, http://%s:%s - up\n' "$host" "$port"
  else
    printf '  dashboard: one for the box, http://%s:%s - DOWN (cel dash --ensure)\n' "$host" "$port"
  fi
  n="$(pgrep -u "$(id -u)" -f "$CEL_ROOT/tools/dash/server\\.mjs" 2>/dev/null | grep -c . || true)"
  if [ "${n:-0}" -gt 1 ]; then
    printf '  %s dashboard servers running, want one - cel dash --restart stops the old per-workspace ones\n' "$n"
  fi
  return 0
}
