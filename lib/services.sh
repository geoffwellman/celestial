# shellcheck shell=bash
# cel services - the things this box is RUNNING, as one list.
#
# The owner drives this box from a laptop, 2026-09-18: "anything we can add to
# help with local testing management, monitoring the state of services and
# accessing them?" There was nothing. `workspace.yaml services:` was a list of
# name and url with no state, no health and no way to start or stop anything,
# and the previews `cel-fanout try` starts were a separate world the list did
# not know about. So "is the builder up", "open the preview of ABC-49" and
# "restart the worker service" were all a pane away instead of a key away.
#
# ONE MODEL, TWO SOURCES. A service is what `services:` declares; a preview is
# a ledger row with a `try` block. They are the same row here because they are
# the same question to an operator - something is listening on a port and I
# want to look at it - and a console view that had to be read twice would be
# read once.
[ -n "${_CEL_SERVICES:-}" ] && return 0
_CEL_SERVICES=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/memory.sh
. "$(dirname "${BASH_SOURCE[0]}")/memory.sh"

# Overridable so the suite can drive every pane operation against a stub that
# logs its argv: a service is a pane, and a test that cannot see the pane call
# proves nothing about start or stop.
_SERVICES_HERDR="${CEL_SERVICES_HERDR:-herdr}"

svc_state_file() { printf '%s' "$1/.cel/services.json"; }

# --- box services ------------------------------------------------------------
#
# THE SOURCE WITH NO WORKSPACE. The auth broker and auth gateway (47311/47411)
# ran on this box for a day started by an acceptance run and watched by nobody:
# `cel gateway install` wrote its two definitions to a private file because a
# service could only belong to a workspace. They belong to the BOX - every
# workspace uses them and none owns them - so they live in `services.d`, one
# JSON file per service with exactly a `services:` row's shape, and every
# consumer that iterates services gets them for free.
#
# 0600 files in a 0700 directory: `env` is where a service's bearer goes, and
# the gateway's bearer grants every subscription in the vault to whatever can
# read it.
svc_box_dir() {
  printf '%s' "${CEL_SERVICES_D:-${XDG_CONFIG_HOME:-$HOME/.config}/cel/services.d}"
}

# State for a box service is the box's, never a workspace's: a pane id written
# into some workspace's .cel/ is lost the moment that workspace is removed,
# and then nothing on this box can stop the service.
svc_box_state_dir() {
  printf '%s' "${CEL_SERVICES_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/services}"
}

svc_box_state_file() { printf '%s' "$(svc_box_state_dir)/$1.json"; }
svc_box_declared() { [ -f "$(svc_box_dir)/$1.json" ]; }

# One JSON object per box service, in the shape `_svc_declared` yields. A bare
# `port:` is accepted because box services are loopback by construction and
# repeating http://127.0.0.1: in every file is a typo waiting to happen.
_svc_box() {
  local d f; d="$(svc_box_dir)"
  [ -d "$d" ] || return 0
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    jq -c --arg fb "$(basename "$f" .json)" --arg home "$HOME" '{
        name: (.name // $fb),
        url: (.url // (if (.port // "") != "" then "http://127.0.0.1:" + (.port|tostring) else "" end)),
        cmd: (.cmd // ""), cwd: (if (.cwd // "") != "" then .cwd else $home end),
        health: (.health // ""), restart: (.restart // ""), env: (.env // {}),
        kind: "box", workspace: "box", ticket: ""
      }' "$f" 2>/dev/null || true
  done
}

# Write one, tight and atomically. The caller hands over the row it wants on
# disk; the permissions are not the caller's to get wrong.
svc_box_write() { # <name> <json-spec>
  local d f tmp; d="$(svc_box_dir)"
  mkdir -p "$d"; chmod 700 "$d" 2>/dev/null || true
  f="$d/$1.json"
  tmp="$(mktemp "$d/.svc.XXXXXX")"
  chmod 600 "$tmp"
  printf '%s\n' "$2" > "$tmp" && mv "$tmp" "$f"
  chmod 600 "$f"
}

# A PORT IS THE HANDLE. Everything below - listening, health, the proxy path,
# the row an operator clicks - keys off the port in the declared url, so a url
# without one (http://host/path) is taken as the scheme's default rather than
# guessed at.
svc_port_of_url() { # <url>
  local u="${1:-}" hostport
  [ -n "$u" ] || { printf 0; return 0; }
  hostport="${u#*://}"; hostport="${hostport%%/*}"
  case "$hostport" in
    *:*) printf '%s' "${hostport##*:}" ;;
    *)   case "$u" in https://*) printf 443 ;; *) printf 80 ;; esac ;;
  esac
}

# Listening means something accepted a connection. Deliberately /dev/tcp, in
# bash itself: reaching for nc or lsof would make "is it up" depend on what a
# given box happens to have installed, and this is the question every row asks.
svc_listening() { # <port>
  local p="${1:-0}"
  [ "$p" -gt 0 ] 2>/dev/null || return 1
  (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
}

# UP IS NOT HEALTHY. A dev server binds its port long before it can answer,
# and a process wedged mid-compile keeps the socket open - so a declared
# `health:` path is asked, with a short budget: a probe that can block for
# thirty seconds turns one sick service into a console that will not draw.
svc_health_ok() { # <port> <path>
  local p="${1:-0}" path="${2:-}"
  [ -n "$path" ] || return 1
  case "$path" in /*) ;; *) path="/$path" ;; esac
  curl -sf -m 2 -o /dev/null "http://127.0.0.1:$p$path" 2>/dev/null
}

# The first process whose cwd is inside the service's directory. herdr exposes
# no pid for a pane, so the cwd is the only handle there is - the same
# attribution lib/memory.sh makes, and with the same honesty: a process that
# chdirs elsewhere leaves the tree.
# ONE WALK, NOT ONE PER SERVICE. The first cut ran `readlink` per process per
# row: ~900 external processes for one service, and `cel services` took 15
# seconds - which is 15 seconds the console spends not drawing. `ls -l` prints
# every cwd link in one go, exactly as lib/memory.sh learned to do, and the
# snapshot is a plain string so every later lookup is a grep over it.
SVC_PROCS="${SVC_PROCS:-}"
svc_proc_snapshot() { # pid TAB cwd, this user's processes only
  local me; me="$(id -un)"
  SVC_PROCS="$({ ls -l /proc/[0-9]*/cwd 2>/dev/null || true; } \
    | awk -v me="$me" '$3 == me { i = NF - 2; p = $i; sub(/.*\/proc\//, "", p); sub(/\/cwd$/, "", p); print p "\t" $NF }')"
}
svc_proc_snapshot_clear() { SVC_PROCS=""; }

svc_pid_of_dir() { # <dir> -> pid, or 0
  local dir="${1:-}" snap
  dir="${dir%/}"
  [ -n "$dir" ] && [ -d "$dir" ] || { printf 0; return 0; }
  snap="$SVC_PROCS"
  [ -n "$snap" ] || { svc_proc_snapshot; snap="$SVC_PROCS"; }
  printf '%s\n' "$snap" | awk -F'\t' -v d="$dir" \
    '$2 == d || index($2, d "/") == 1 { print $1; exit }' | head -1 | grep -E '^[0-9]+$' || printf 0
}

svc_uptime_secs() { # <pid>
  local pid="${1:-0}" s
  [ "$pid" -gt 0 ] 2>/dev/null || { printf 0; return 0; }
  s="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  printf '%s' "${s:-0}"
}

# REACH IS THE WHOLE POINT. Every dev server and every preview on this box
# listens on 127.0.0.1, which from the owner's laptop is the laptop. The
# dashboard already binds the tailnet IP, so the address that actually works
# from there is the dash's proxy path - and only when the dash is up, because
# a URL that 404s is worse than the loopback one an operator can tunnel.
svc_reach() { # <wsdir> <port>
  local d="$1" port="${2:-0}" dport host
  [ "$port" -gt 0 ] 2>/dev/null || return 0
  dport="$(_wsy "$d" '.dash.port')"
  [ -n "$dport" ] || return 0
  svc_listening "$dport" || return 0
  host="${CEL_DASH_HOST:-$(tailscale ip -4 2>/dev/null | head -1 || true)}"
  [ -n "$host" ] || host=127.0.0.1
  printf 'http://%s:%s/svc/%s/' "$host" "$dport" "$port"
}

# Every declared service, one JSON object per line, before any liveness is
# asked. `services:` entries of the old name+url shape stay valid - they
# simply carry no cmd, and a service without a cmd is observe-only.
_svc_declared() { # <wsdir>
  [ -n "${1:-}" ] && [ -f "$1/workspace.yaml" ] || return 0
  _yqr -c --arg ws "$(ws_name "$1")" '.services // [] | .[] | {
      name: (.name // ""), url: (.url // ""), cmd: (.cmd // ""), cwd: (.cwd // ""),
      health: (.health // ""), restart: (.restart // ""), env: (.env // {}),
      kind: "declared", workspace: $ws, ticket: ""
    }' "$1/workspace.yaml" 2>/dev/null || true
}

# ...and every running preview. The ledger row IS the declaration: `try`
# allocated the ports and wrote the url, so nothing is re-derived here.
_svc_previews() { # <wsdir>
  [ -n "${1:-}" ] || return 0
  local f="$1/.cel/delegations.json"
  [ -f "$f" ] || return 0
  jq -c --arg ws "$(ws_name "$1")" '.[]? | select(.try.url != null) | {
      name: ("try " + (.ticket // .id)), url: .try.url, cmd: "", cwd: (.worktree // ""),
      health: "", restart: "", env: {}, kind: "preview", workspace: $ws, ticket: (.ticket // ""),
      pane: (.try.pane // ""), id: (.id // "")
    }' "$f" 2>/dev/null || true
}

# THE ENUMERATOR, and the reason box services cost every consumer nothing.
# Workspace rows first, then the box's own: inside a workspace the workspace's
# services are the question being asked and the box's are context underneath.
_svc_all() { # [wsdir]
  _svc_declared "${1:-}"
  _svc_previews "${1:-}"
  _svc_box
}

svc_names() { # [wsdir]
  _svc_all "${1:-}" | jq -r '.name'
}

svc_entry() { # [wsdir] <name> -> the declaration, empty if unknown
  _svc_all "${1:-}" | jq -c --arg n "$2" 'select(.name == $n)' | head -1
}

# A secret in a rendered row is a secret on someone's screen and in whatever
# they pasted it into, so rows carry the KEYS of `env` and not the values that
# look like credentials. The name match is deliberately broad: a value wrongly
# masked costs nobody anything, a bearer printed once has to be rotated.
_SVC_MASK_ENV='with_entries(.value = (if (.key | test("TOKEN|SECRET|KEY|PASSWORD"; "i")) then "***" else .value end))'

# The full document: declaration joined to what is actually true right now.
svc_rows() { # [wsdir] -> JSON array
  local d="${1:-}" e name url cmd cwd health port pid rss up state reach pane
  mem_tree_snapshot
  svc_proc_snapshot
  _svc_all "$d" | while IFS= read -r e; do
    [ -n "$e" ] || continue
    name="$(printf '%s' "$e" | jq -r '.name')"
    url="$(printf '%s' "$e" | jq -r '.url')"
    cmd="$(printf '%s' "$e" | jq -r '.cmd')"
    cwd="$(printf '%s' "$e" | jq -r '.cwd')"
    health="$(printf '%s' "$e" | jq -r '.health')"
    port="$(svc_port_of_url "$url")"
    state=down
    if svc_listening "$port"; then
      state=up
      [ -n "$health" ] && svc_health_ok "$port" "$health" && state=healthy
    fi
    pid=0; rss=0; up=0
    if [ "$state" != down ] && [ -n "$cwd" ]; then
      pid="$(svc_pid_of_dir "$cwd")"
      rss="$(mem_tree_rss_mb "$cwd")"
      up="$(svc_uptime_secs "$pid")"
    fi
    reach=""
    [ -n "$d" ] && reach="$(svc_reach "$d" "$port")"
    pane="$(printf '%s' "$e" | jq -r '.pane // ""')"
    [ -n "$pane" ] || pane="$(svc_pane "$d" "$name")"
    printf '%s' "$e" | jq -c \
      --argjson port "${port:-0}" --arg state "$state" --argjson pid "${pid:-0}" \
      --argjson rss "${rss:-0}" --argjson up "${up:-0}" --arg reach "$reach" --arg pane "$pane" \
      '. + {port: $port, state: $state, pid: $pid, rss_mb: $rss, uptime_secs: $up,
            reach: (if $reach == "" then .url else $reach end), pane: $pane,
            observe_only: ((.kind == "declared" or .kind == "box") and (.cmd == "")),
            env: ((.env // {}) | '"$_SVC_MASK_ENV"')}'
  done | jq -s '.'
  mem_tree_snapshot_clear
  svc_proc_snapshot_clear
}

# --- the pane a service runs in ---------------------------------------------
#
# A started service is a pane and nothing else: no pid file, no daemon, no
# state this plane has to reconcile with the kernel. `.cel/services.json` holds
# the pane id because that is the only handle herdr gives, and a service whose
# pane id is lost is a service nobody can stop.

svc_pane() { # [wsdir] <name>
  local f
  # The box's own state is asked first and by name, because a box service is
  # answerable from anywhere - including from outside every workspace, which
  # is where an operator stands when they ask about the gateway.
  f="$(svc_box_state_file "$2")"
  if [ -f "$f" ]; then jq -r '.pane // ""' "$f" 2>/dev/null || true; return 0; fi
  [ -n "${1:-}" ] || return 0
  f="$(svc_state_file "$1")"
  [ -f "$f" ] || return 0
  jq -r --arg n "$2" '.[$n].pane // ""' "$f" 2>/dev/null || true
}

# One file per box service under the box's own data directory: the pane herdr
# gave us, when it started, and the log to read. `pid` is a courtesy for
# whoever opens the file by hand and is 0 when nothing could be attributed -
# herdr exposes no pid for a pane, and inventing one would be a lie a later
# reader acts on.
_svc_box_record() { # <name> <pane>
  local f; f="$(svc_box_state_file "$1")"
  mkdir -p "$(dirname "$f")"; chmod 700 "$(dirname "$f")" 2>/dev/null || true
  jq -n --arg n "$1" --arg p "$2" --arg at "$(date -u +%FT%TZ)" \
    '{name: $n, pane: $p, pid: 0, started: $at, log: ("pane:" + $p)}' > "$f"
}

_svc_pane_record() { # <wsdir|box> <name> <pane>
  local f
  if [ "$1" = box ]; then _svc_box_record "$2" "$3"; return 0; fi
  f="$(svc_state_file "$1")"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '{}\n' > "$f"
  jq --arg n "$2" --arg p "$3" --arg at "$(date -u +%FT%TZ)" \
    '.[$n] = {pane: $p, started: $at}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

_svc_pane_forget() { # <wsdir|box> <name>
  local f
  if [ "$1" = box ]; then rm -f "$(svc_box_state_file "$2")"; return 0; fi
  f="$(svc_state_file "$1")"
  [ -f "$f" ] || return 0
  jq --arg n "$2" 'del(.[$n])' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# The workspace's own pane, so a service appears beside the workspace it
# belongs to rather than wherever the operator happened to be standing - the
# same rule `cel-fanout try` follows for a preview under its worker.
_svc_ws_pane() { # <wsdir>
  "$_SERVICES_HERDR" agent list 2>/dev/null \
    | jq -r --arg d "$1" '[.result.agents[]? | select(.cwd == $d)][0].pane_id // empty' 2>/dev/null || true
}

svc_start() { # [wsdir] <name>
  local d="${1:-}" name="$2" e cmd cwd kind store
  e="$(svc_entry "$d" "$name")"
  [ -n "$e" ] || { c_err "no service '$name' in this workspace or in $(svc_box_dir)"; return 1; }
  kind="$(printf '%s' "$e" | jq -r '.kind')"
  store="$d"; [ "$kind" = box ] && store=box
  cmd="$(printf '%s' "$e" | jq -r '.cmd')"
  if [ -z "$cmd" ]; then
    c_warn "$name is observe-only: it declares a url and no cmd, so there is nothing here to start"
    return 0
  fi
  local existing; existing="$(svc_pane "$d" "$name")"
  [ -n "$existing" ] && { c_ok "$name is already running in $existing"; return 0; }
  cwd="$(printf '%s' "$e" | jq -r '.cwd')"
  [ -n "$cwd" ] || cwd="${d:-$HOME}"

  # The env map is SHELL-QUOTED before it joins the command line, exactly as
  # `try` does it: `herdr pane run` takes one command line, so an unquoted
  # value with a space in it becomes two words - the second read as a program
  # to run - and a `$`, backtick or `;` out of workspace.yaml would execute.
  local -a envs=(); local k v
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if ! printf '%s' "$k" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
      c_warn "$name: skipping env entry with an invalid variable name: $k"
      continue
    fi
    v="$(printf '%s' "$e" | jq -r --arg k "$k" '.env[$k] | tostring')"
    # ONE EXCEPTION TO THE QUOTING, and it is the reason the gateway works at
    # all: a value that is exactly `$NAME` or `$(one command ...)` is passed
    # through unquoted so the pane expands it itself. That is how a service
    # definition names a bearer without ever holding one - `cel gateway
    # install` writes `$(omp auth-broker token)` and the token stays in omp's
    # own 0600 file. The pattern is narrow on purpose: no quotes, no
    # semicolons, no backticks, no pipes.
    if printf '%s' "$v" | grep -Eq '^\$[A-Za-z_][A-Za-z0-9_]*$|^\$\([A-Za-z0-9_][A-Za-z0-9_./ -]*\)$'; then
      envs+=("$k=$v")
    else
      envs+=("$(printf '%s=%q' "$k" "$v")")
    fi
  done < <(printf '%s' "$e" | jq -r '.env // {} | keys[]' 2>/dev/null || true)

  local -a split=(pane split --cwd "$cwd" --no-focus)
  local wspane=""
  [ -n "$d" ] && wspane="$(_svc_ws_pane "$d")"
  [ -n "$wspane" ] && split=(pane split --pane "$wspane" --direction down --cwd "$cwd" --no-focus)
  local resp pane
  resp="$("$_SERVICES_HERDR" "${split[@]}" 2>/dev/null || true)"
  pane="$(printf '%s' "$resp" | jq -r '.. | .pane_id? // empty' 2>/dev/null | head -1)"
  [ -n "$pane" ] || { c_err "$name: herdr pane split returned no pane id - nothing was started"; return 1; }
  local runline="$cmd"
  [ "${#envs[@]}" -eq 0 ] || runline="env ${envs[*]} $cmd"
  "$_SERVICES_HERDR" pane run "$pane" "$runline" >/dev/null 2>&1 \
    || c_warn "$name: could not start it in $pane - read the pane"
  _svc_pane_record "$store" "$name" "$pane"
  c_ok "$name started in $pane"
}

svc_stop() { # [wsdir] <name>
  local d="${1:-}" name="$2" pane e store
  pane="$(svc_pane "$d" "$name")"
  e="$(svc_entry "$d" "$name")"
  store="$d"
  [ "$(printf '%s' "$e" | jq -r '.kind // ""' 2>/dev/null || true)" = box ] && store=box
  if [ -z "$pane" ]; then
    pane="$(printf '%s' "$e" | jq -r '.pane // ""' 2>/dev/null || true)"
  fi
  [ -n "$pane" ] || { c_warn "$name is not running under a pane this plane started"; return 0; }
  "$_SERVICES_HERDR" pane close "$pane" >/dev/null 2>&1 \
    || c_warn "could not close pane $pane - close it by hand"
  _svc_pane_forget "$store" "$name"
  c_ok "$name stopped ($pane)"
}

# OPEN IT. `o` in the console and the `open_service` intent both land here:
# the reach URL is opened on the box AND printed, because the operator is
# usually on a laptop looking at this through herdr, where a printed URL is a
# clickable OSC 8 link and an xdg-open on this box is a window nobody sees.
svc_open() { # <wsdir> <name>
  local d="$1" name="$2" row
  row="$(svc_rows "$d" | jq -c --arg n "$name" '.[] | select(.name == $n)' | head -1)"
  [ -n "$row" ] || { c_err "no service '$name' in this workspace"; return 1; }
  local url; url="$(printf '%s' "$row" | jq -r '.reach // .url // ""')"
  [ -n "$url" ] || { c_err "$name has no URL to open"; return 1; }
  have xdg-open && ( xdg-open "$url" >/dev/null 2>&1 & ) || true
  printf '%s\n' "$url"
}

svc_restart() { # <wsdir> <name>
  svc_stop "$1" "$2" >/dev/null 2>&1 || true
  svc_start "$1" "$2"
}

# The last sixty lines of the pane. A service that will not start says why in
# its own output, and making someone find the pane first is the reason nobody
# reads it.
svc_logs() { # <wsdir> <name> [lines]
  local d="$1" name="$2" lines="${3:-60}" pane
  pane="$(svc_pane "$d" "$name")"
  [ -n "$pane" ] || pane="$(svc_entry "$d" "$name" | jq -r '.pane // ""' 2>/dev/null || true)"
  # The warning rides STDERR: `svc_last_log_line` puts this output inside a
  # steward blocker, and a warning captured as a log line is a message that
  # quotes the plane to itself instead of quoting the service.
  [ -n "$pane" ] || { c_warn "$name has no pane on this box - nothing to read" >&2; return 0; }
  "$_SERVICES_HERDR" pane read "$pane" --source detection --lines "$lines" 2>/dev/null || true
}

# The last line of the pane, for a steward blocker: "builder is down" is an
# alarm, "builder is down: EADDRINUSE 4322" is a fix.
svc_last_log_line() { # <wsdir> <name>
  svc_logs "$1" "$2" 20 | sed '/^[[:space:]]*$/d' | tail -1
}

# --- rendering ---------------------------------------------------------------

svc_uptime_human() { # <secs>
  local s="${1:-0}"
  [ "$s" -gt 0 ] 2>/dev/null || { printf -- '-'; return 0; }
  if [ "$s" -lt 3600 ]; then printf '%dm' "$((s / 60))"; else printf '%dh' "$((s / 3600))"; fi
}

svc_rows_text() { # <json array on stdin>
  local name state port rss up reach ticket dot
  while IFS=$'\t' read -r name state port rss up reach ticket; do
    [ -n "$name" ] || continue
    case "$state" in healthy|up) dot='●';; *) dot='○';; esac
    printf '  %s %-14s %-8s %-7s %-6s %-5s %s%s\n' \
      "$dot" "$name" "$state" ":$port" "$(mem_human "$rss")" \
      "$(svc_uptime_human "$up")" "$reach" "${ticket:+   ($ticket)}"
  done < <(jq -r '.[] | [.name, .state, .port, .rss_mb, .uptime_secs, .reach, .ticket] | @tsv')
}

cmd_services() { # [start|stop|restart|logs|open <name>] [--workspace w] [--json]
  have jq || die "cel services: jq is not on PATH"
  local verb="" name="" workspace="" json=0
  case "${1:-}" in
    start|stop|restart|logs|open) verb="$1"; shift; name="${1:-}"; [ -n "$name" ] || die "cel services $verb: which service?"; shift || true ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) workspace="$2"; shift 2 ;;
      --json)      json=1; shift ;;
      *) die "cel services: unknown argument '$1' (want --workspace, --json)" ;;
    esac
  done
  local wsdir=""
  if [ -n "$workspace" ]; then
    wsdir="$(registry_require "$workspace")"
  else
    # NOT BEING IN A WORKSPACE IS NO LONGER AN ERROR. Run from ~ this used to
    # say "not inside a workspace", which is exactly the place where the box's
    # own services - the gateway, the broker - are all there is to look at.
    wsdir="$(ws_current || true)"
  fi
  if [ -z "$wsdir" ] && [ -z "$(_svc_box)" ]; then
    die "cel services: not inside a workspace and no box services in $(svc_box_dir) (cd into one, or pass --workspace <name>)"
  fi

  case "$verb" in
    start)   svc_start   "$wsdir" "$name"; return $? ;;
    stop)    svc_stop    "$wsdir" "$name"; return $? ;;
    restart) svc_restart "$wsdir" "$name"; return $? ;;
    logs)    svc_logs    "$wsdir" "$name"; return $? ;;
    open)    svc_open    "$wsdir" "$name"; return $? ;;
  esac

  local rows; rows="$(svc_rows "$wsdir")"
  if [ "$json" -eq 1 ]; then printf '%s\n' "$rows"; return 0; fi
  local n; n="$(printf '%s' "$rows" | jq 'length')"
  if [ "${n:-0}" -eq 0 ]; then
    c_warn "no services declared in $(ws_name "$wsdir") and no previews running"
    return 0
  fi
  # Two blocks, because they answer two different questions: what this
  # workspace runs, and what this box runs on everyone's behalf.
  local wsrows boxrows
  wsrows="$(printf '%s' "$rows" | jq -c '[.[] | select(.workspace != "box")]')"
  boxrows="$(printf '%s' "$rows" | jq -c '[.[] | select(.workspace == "box")]')"
  if [ "$(printf '%s' "$wsrows" | jq 'length')" -gt 0 ]; then
    c_hd "services - $(ws_name "$wsdir")"
    printf '%s' "$wsrows" | svc_rows_text
  fi
  if [ "$(printf '%s' "$boxrows" | jq 'length')" -gt 0 ]; then
    c_hd "services - box"
    printf '%s' "$boxrows" | svc_rows_text
  fi
}
