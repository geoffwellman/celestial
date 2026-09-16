# shellcheck shell=bash
# cel dash - per-workspace dashboard. Gathers the static config (name, repos,
# services, port) here with the same yq the rest of the plane uses, then hands
# it to the zero-dependency node server as JSON; the server reads live state
# (herdr, gh) itself. Defaults to the tailnet IP when available, else loopback;
# --host explicitly selects another listener for the private control plane.
[ -n "${_CEL_DASH:-}" ] && return 0
_CEL_DASH=1
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"

_dash_config() { # <wsdir> <port> <host> -> JSON on stdout
  local d="$1" port="$2" host="$3"
  # slug: git@host:owner/name.git or https://host/owner/name -> owner/name
  local build; build="v$(tr -d '[:space:]' < "$CEL_ROOT/VERSION" 2>/dev/null || printf '?') $(git -C "$CEL_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'nogit')"
  yq -c --arg wsdir "$d" --arg port "$port" --arg host "$host" --arg build "$build" '{
    name: .name,
    wsdir: $wsdir,
    port: ($port | tonumber),
    host: $host,
    repos: [(.repos // [])[] | {name: .name,
      slug: ((.url // "") | sub("^git@[^:]+:"; "") | sub("^https?://[^/]+/"; "") | sub("\\.git$"; ""))}],
    services: (.services // []),
    build: $build,
    linearTeams: ([(.repos // [])[].linear_team // empty] | unique),
    # the state that means "build this", so the board can say so instead of
    # naming a state this team may not even have
    triggerState: (.tickets.trigger_state // "")
  }' "$d/workspace.yaml"
}

# Dashboards are box services like the pages servers: nothing owns their pane,
# so `--ensure` starts one only when its port is not already answering, and
# the steward calls it for every workspace that declares dash.port. Warning
# about a dead dashboard achieved nothing - it stayed dead.
_dash_log_dir() { printf '%s' "${CEL_DASH_LOG_DIR:-$HOME/.local/share/cel/logs}"; }

_dash_ensure() { # <workspace> <port> <host>
  local ws="$1" port="$2" host="$3" log
  log="$(_dash_log_dir)/dash-$ws.log"
  if curl -sf -m 3 -o /dev/null "http://$host:$port/api/state"; then
    c_ok "dash $ws already serving on $port"
    return 0
  fi
  mkdir -p "$(_dash_log_dir)"
  # setsid: outlives the pane or agent that ensured it
  setsid nohup "$CEL_ROOT/bin/cel" dash --workspace "$ws" --port "$port" --host "$host" \
    >>"$log" 2>&1 &
  local i
  for i in 1 2 3 4 5 6 7 8; do
    sleep 0.5
    curl -sf -m 3 -o /dev/null "http://$host:$port/api/state" \
      && { c_ok "dash $ws started on $port (log: $log)"; return 0; }
  done
  c_err "dash $ws did not come up on $port - see $log"
  return 1
}

# `--ensure` leaves a running server alone, which is exactly wrong after an
# update: the old code keeps serving until someone notices. `--restart` stops
# THIS workspace's dashboard only - matched by the server.mjs path plus the
# port in its own CEL_DASH_CONFIG, never by a bare pkill that would take every
# other workspace's dashboard down with it - and then ensures as usual.
_dash_stop() { # <port>
  local port="$1" pid env
  for pid in $(pgrep -f 'tools/dash/server\.mjs' 2>/dev/null); do
    env="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep '^CEL_DASH_CONFIG=' || true)"
    case "$env" in *'"port":'"$port"*) kill "$pid" 2>/dev/null && c_ok "stopped dash on $port (pid $pid)" ;; esac
  done
  return 0
}

_dash_restart() { # <workspace> <port> <host>
  _dash_stop "$2"
  _dash_ensure "$1" "$2" "$3"
}

cmd_dash() { # [--workspace w] [--port n] [--host h] [--ensure] [--restart]
  local workspace="" port="" host="" ensure=0 restart=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) workspace="$2"; shift 2 ;;
      --port)      port="$2"; shift 2 ;;
      --host)      host="$2"; shift 2 ;;
      --ensure)    ensure=1; shift ;;
      --restart)   restart=1; shift ;;
      *) die "cel dash: unknown argument '$1' (want --workspace, --port, --host, --ensure, --restart)" ;;
    esac
  done
  have node || die "cel dash: node is not on PATH"
  have yq   || die "cel dash: yq is not on PATH"

  local wsdir
  if [ -n "$workspace" ]; then
    wsdir="$(registry_require "$workspace")"
  else
    wsdir="$(ws_current)" || die "cel dash: not inside a workspace (cd into one, or pass --workspace <name>)"
  fi
  if [ -z "$port" ]; then
    port="$(_wsy "$wsdir" '.dash.port')"
    [ -n "$port" ] || port=7770
  fi
  if [ -z "$host" ]; then
    host="$(tailscale ip -4 2>/dev/null | head -1)"
    [ -n "$host" ] || host=127.0.0.1
  fi
  [ "$restart" -eq 1 ] && { _dash_restart "$(ws_name "$wsdir")" "$port" "$host"; return $?; }
  [ "$ensure" -eq 1 ] && { _dash_ensure "$(ws_name "$wsdir")" "$port" "$host"; return $?; }

  # A dashboard runs with its workspace's env, exactly like a pane started
  # inside it - that is how LINEAR_API_KEY (env.local) reaches the server
  # without the key ever being written into config or a repo.
  # shellcheck disable=SC1090
  eval "$(ws_env_exports "$wsdir" 2>/dev/null)" || true
  # CEL_DASH_TRUSTED_ORIGINS admits exact additional http(s) origins.
  # Mutations require X-Cel-CSRF from GET /api/session. Automation may instead
  # supply CEL_DASH_CSRF_TOKEN before startup; never put it in workspace.yaml.
  CEL_DASH_CONFIG="$(_dash_config "$wsdir" "$port" "$host")" \
  CEL_EFFECTS_DIR="${CEL_EFFECTS_DIR:-$HOME/.local/share/cel/vendor/canvasui}" \
  CEL_INBOX_DIR="$(printf '%s' "${CEL_INBOX_DIR:-$HOME/.local/share/cel/inbox}")" \
    exec node "$CEL_ROOT/tools/dash/server.mjs"
}
