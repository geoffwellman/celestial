# shellcheck shell=bash
# cel pages / cel publish - the plane's own artifact hosting. Documents live
# in one flat directory on this box and are served over the tailnet by a
# zero-dependency node server; publishing is just copying a file in and
# printing its URL. Same name, same URL: republishing updates in place, like
# an artifact redeploy but on hardware you own.
[ -n "${_CEL_PAGES:-}" ] && return 0
_CEL_PAGES=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"

_pages_root() { printf '%s' "${CEL_PAGES_ROOT:-$HOME/.local/share/cel/pages}"; }

# Which workspace a document was published FROM, or empty.
#
# The document root stays flat and box-wide - one namespace, one server - but
# a page with no idea where it came from cannot be filtered, cannot be pushed
# to the right repo, and cannot be protected from another workspace's page of
# the same name. The answer is derived, never asked for: `cel publish` is
# typed by agents, and a flag they must remember is a flag they will forget.
#
# Three ways a publisher's cwd names a workspace, most direct first:
#   1. inside the workspace tree          ~/ws/alpha, ~/ws/alpha/repos/x
#   2. a worker's worktree                ~/.herdr/worktrees/<repo>/<branch>
#      - <repo> is declared by exactly one workspace
#   3. an agent scratchpad                /tmp/claude-<uid>/-home-you-ws-alpha/...
#      - the harness mangles the project dir into one path segment by
#        replacing / with -. Rather than parse that ambiguous form back into a
#        path, mangle each KNOWN workspace path the same way and look for it:
#        exact, and wrong only if two workspace paths mangle alike.
_pages_workspace() { # [dir] -> name | ""
  local d="${1:-$PWD}" n p wt repo
  if n="$(ws_current "$d" 2>/dev/null)" && [ -n "$n" ]; then
    ws_name "$n"; return 0
  fi
  wt="${CEL_WORKTREES:-$HOME/.herdr/worktrees}"
  case "$d" in
    "$wt"/*)
      repo="${d#"$wt"/}"; repo="${repo%%/*}"
      # AMBIGUITY IS NOT A TIE TO BREAK. Worktrees are global - one directory
      # per repo NAME, not per workspace - so when two registered workspaces
      # declare the same repo, the path cannot say which one spawned this
      # worker. Picking the first in the registry would attribute the page to a
      # workspace that has never seen it, and attribution drives both the
      # filter and the collision rule. Unattributed is honest; wrong is not.
      # (Codex review, PR #9.)
      local hits="" 
      while read -r n; do
        [ -n "$n" ] || continue
        p="$(registry_path "$n")"; [ -d "$p" ] || continue
        if ws_repo_names "$p" 2>/dev/null | grep -qxF "$repo"; then
          hits="${hits:+$hits }$n"
        fi
      done < <(registry_names)
      case "$hits" in
        '') ;;
        *\ *) return 0 ;;                  # more than one claimant: say nothing
        *) printf '%s' "$hits"; return 0 ;;
      esac
      ;;
  esac
  while read -r n; do
    [ -n "$n" ] || continue
    p="$(registry_path "$n")"; [ -n "$p" ] || continue
    local m; m="$(printf '%s' "$p" | tr '/' '-')"
    # A WHOLE PATH SEGMENT, not a substring. `/home/me/ws/a` mangles to
    # `-home-me-ws-a`, which is a prefix of `alpha`'s `-home-me-ws-alpha`, so a
    # substring match hands every page published from alpha to workspace a -
    # whichever the registry happens to list first. The sidecar and the
    # collision decision would then both name the wrong workspace.
    # (Codex review, PR #9.)
    case "$d" in */"$m"|*/"$m"/*) printf '%s' "$n"; return 0;; esac
  done < <(registry_names)
  return 0
}

# What workspace owns the document already sitting at <name>, or empty for
# "nobody" (never published, or published before attribution existed).
_pages_owner() { # <root> <name>
  local f="$1/.meta/$2.json"
  [ -f "$f" ] || return 0
  jq -r '.workspace // ""' "$f" 2>/dev/null || true
}
_pages_port() { printf '%s' "${CEL_PAGES_PORT:-7780}"; }

# The public tier is a SEPARATE root and server: nothing crosses from the
# tailnet-private tier without an explicit --public at publish time.
_pages_public_root() { printf '%s' "${CEL_PAGES_PUBLIC_ROOT:-$HOME/.local/share/cel/pages-public}"; }
_pages_public_port() { printf '%s' "${CEL_PAGES_PUBLIC_PORT:-7781}"; }

# Where a public share is reachable from, most durable first:
#   1. CEL_PAGES_PUBLIC_URL      - an explicit hostname (your own domain, a
#                                  named cloudflare tunnel, a reverse proxy)
#   2. the live tunnel URL       - written by `cel pages tunnel`, which works
#                                  with no account and no tailscale
#   3. the tailscale funnel name - when tailscale happens to be present
#   4. loopback                  - honest fallback: nothing is public yet
# Tailscale is therefore ONE option, never a requirement: a laptop with
# cloudflared (or any tunnel that prints a URL) shares publicly just fine.
_pages_tunnel_url_file() { printf '%s' "${CEL_PAGES_TUNNEL_URL_FILE:-$HOME/.local/share/cel/pages-tunnel.url}"; }

_pages_public_url() {
  if [ -n "${CEL_PAGES_PUBLIC_URL:-}" ]; then printf '%s' "${CEL_PAGES_PUBLIC_URL%/}"; return 0; fi
  local f; f="$(_pages_tunnel_url_file)"
  if [ -s "$f" ]; then
    local u; u="$(tr -d '[:space:]' < "$f")"
    [ -n "$u" ] && { printf '%s' "${u%/}"; return 0; }
  fi
  local dns
  dns="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null)"
  dns="${dns%.}"
  [ -n "$dns" ] && printf 'https://%s' "$dns" || printf 'http://127.0.0.1:%s' "$(_pages_public_port)"
}

# The private tier binds the tailscale address when there is one, so other
# devices on the tailnet can read it; on a plain laptop it is loopback, which
# is exactly right - private means private to this machine.
_pages_host() {
  if [ -n "${CEL_PAGES_HOST:-}" ]; then printf '%s' "$CEL_PAGES_HOST"; return 0; fi
  local ip
  ip="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$ip" ] && printf '%s' "$ip" || printf '127.0.0.1'
}

# Box services, not workspace services: one pages server per machine, so no
# workspace layout owns them. `--ensure` is the supervision hook - idempotent,
# detached, logs to ~/.local/share/cel/logs - and the steward calls it every
# tick, which is what makes a dead server come back without a human noticing.
_pages_log_dir() { printf '%s' "${CEL_PAGES_LOG_DIR:-$HOME/.local/share/cel/logs}"; }

_pages_ensure() { # <public 0|1>
  local public="$1" port host log url tier
  # NOT ${public:+...}: "0" is a non-empty string, so that expansion fires on
  # the private tier too and would launch the public server against the
  # private port. Branch on the value.
  local -a flag=()
  if [ "$public" = 1 ]; then
    port="$(_pages_public_port)"; host=127.0.0.1
    log="$(_pages_log_dir)/pages-public.log"; tier=" (public)"; flag=(--public)
  else
    port="$(_pages_port)"; host="$(_pages_host)"
    log="$(_pages_log_dir)/pages.log"; tier=""
  fi
  url="http://$host:$port/"
  if curl -sf -m 3 -o /dev/null "$url"; then
    c_ok "pages$tier already serving on $port"
    return 0
  fi
  mkdir -p "$(_pages_log_dir)"
  # setsid, so the server outlives the pane or agent that ensured it
  setsid nohup "$CEL_ROOT/bin/cel" pages "${flag[@]}" >>"$log" 2>&1 &
  local i
  for i in 1 2 3 4 5 6 7 8; do
    sleep 0.5
    curl -sf -m 3 -o /dev/null "$url" && { c_ok "pages$tier started on $port (log: $log)"; return 0; }
  done
  c_err "pages$tier did not come up on $port - see $log"
  return 1
}

# Fill in the workspace on documents published before attribution existed.
# Their sidecars already recorded the publishing cwd, so the answer is simply
# re-derivable - a migration, not a guess. Idempotent: anything already filled
# in, or whose cwd names no workspace, is left exactly as it is.
_pages_reindex() { # <root>
  local root="$1" f name ws cwd filled=0 skipped=0
  [ -d "$root/.meta" ] || { c_ok "nothing to reindex"; return 0; }
  for f in "$root"/.meta/*.json; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .json)"
    case "$name" in revisions.log|feedback.log) continue;; esac
    ws="$(jq -r '.workspace // ""' "$f" 2>/dev/null || true)"
    [ -n "$ws" ] && continue
    cwd="$(jq -r '.cwd // ""' "$f" 2>/dev/null || true)"
    ws="$(_pages_workspace "$cwd")"
    if [ -z "$ws" ]; then skipped=$((skipped+1)); continue; fi
    local tmp; tmp="$(mktemp)"
    jq --arg w "$ws" '.workspace = $w' "$f" > "$tmp" && mv "$tmp" "$f"
    printf '  %-42s -> %s\n' "$name" "$ws"
    filled=$((filled+1))
  done
  c_ok "reindexed $filled document(s)$([ "$skipped" -gt 0 ] && printf ', %s left unfiled (cwd names no workspace)' "$skipped")"
}

# `--ensure` leaves a running server alone, so after an update the old code
# keeps serving. `--restart` stops the server for THIS TIER only - matched by
# the pages server.mjs path plus the port it was started on, so restarting the
# public tier never takes the private one down - then ensures as usual. A stop
# that finds nothing is not an error: the updater and the steward both call it.
_pages_stop() { # <public 0|1>
  local port pid env
  if [ "$1" = 1 ]; then port="$(_pages_public_port)"; else port="$(_pages_port)"; fi
  for pid in $(pgrep -f 'tools/pages/server\.mjs' 2>/dev/null); do
    env="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep '^CEL_PAGES_PORT=' || true)"
    [ "$env" = "CEL_PAGES_PORT=$port" ] && { kill "$pid" 2>/dev/null && c_ok "stopped pages on $port (pid $pid)"; }
  done
  return 0
}

_pages_restart() { # <public 0|1>
  _pages_stop "$1"
  _pages_ensure "$1"
}

cmd_pages() { # [--public] [--ensure] [--restart] [--reindex] [--port n] [--host h]
  local port="" host="" public=0 ensure=0 reindex=0 restart=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --public) public=1; shift ;;
      --ensure) ensure=1; shift ;;
      --restart) restart=1; shift ;;
      --reindex) reindex=1; shift ;;
      --port) port="$2"; shift 2 ;;
      --host) host="$2"; shift 2 ;;
      *) die "cel pages: unknown argument '$1' (want --public, --ensure, --restart, --reindex, --port, --host)" ;;
    esac
  done
  if [ "$reindex" -eq 1 ]; then
    _pages_reindex "$([ "$public" -eq 1 ] && _pages_public_root || _pages_root)"
    return $?
  fi
  have node || die "cel pages: node is not on PATH"
  [ "$restart" -eq 1 ] && { _pages_restart "$public"; return $?; }
  [ "$ensure" -eq 1 ] && { _pages_ensure "$public"; return $?; }
  local root
  if [ "$public" -eq 1 ]; then
    root="$(_pages_public_root)"
    # funnel/cloudflared proxy from localhost, so the public instance never
    # binds an interface itself
    port="${port:-$(_pages_public_port)}"; host="${host:-127.0.0.1}"
  else
    root="$(_pages_root)"
    port="${port:-$(_pages_port)}"; host="${host:-$(_pages_host)}"
  fi
  mkdir -p "$root"
  # feedback + promote controls exist ONLY on the private tier: the public
  # internet gets no path that prompts agents or changes what is published.
  # The private server carries the public root/URL so its promote button can
  # copy documents across.
  # CEL_PAGES_TRUSTED_ORIGINS optionally admits exact additional http(s)
  # origins on the private tier. The read-only public tier accepts tunnel
  # hosts without granting any control API. Mutations use X-Cel-CSRF from
  # GET /api/session, or a CEL_PAGES_CSRF_TOKEN supplied before server startup.
  CEL_PAGES_ROOT="$root" CEL_PAGES_PORT="$port" CEL_PAGES_HOST="$host" \
  CEL_PAGES_FEEDBACK="$([ "$public" -eq 1 ] && printf 0 || printf 1)" \
  CEL_PAGES_PUBLIC_ROOT="$(_pages_public_root)" \
  CEL_PAGES_PUBLIC_URL="$(_pages_public_url)" \
    exec node "$CEL_ROOT/tools/pages/server.mjs"
}

# `cel pages tunnel` - make the public tier reachable from the internet on a
# machine with no tailscale. Uses whichever tunnel binary is installed and
# prints a URL on stdout; cloudflared's quick tunnel needs no account at all.
# The URL is recorded so _pages_public_url (and therefore every share link)
# picks it up, and cleared when the tunnel dies.
cmd_pages_tunnel() { # [--provider cloudflared|ngrok] [--port n]
  local provider="" port=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) provider="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      *) die "cel pages tunnel: unknown argument '$1'" ;;
    esac
  done
  port="${port:-$(_pages_public_port)}"
  if [ -z "$provider" ]; then
    if have cloudflared; then provider=cloudflared
    elif have ngrok; then provider=ngrok
    else die "cel pages tunnel: install cloudflared (no account needed: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) or ngrok"; fi
  fi
  have "$provider" || die "cel pages tunnel: $provider is not on PATH"

  local urlf log; urlf="$(_pages_tunnel_url_file)"; log="$(_pages_log_dir)/pages-tunnel.log"
  mkdir -p "$(dirname "$urlf")" "$(_pages_log_dir)"
  : > "$log"
  case "$provider" in
    cloudflared) cloudflared tunnel --url "http://127.0.0.1:$port" --no-autoupdate >>"$log" 2>&1 & ;;
    ngrok)       ngrok http "$port" --log stdout >>"$log" 2>&1 & ;;
  esac
  local pid=$! i url=""
  for i in $(seq 1 40); do
    sleep 1
    url="$(grep -oE 'https://[a-z0-9-]+\.(trycloudflare\.com|ngrok[-.]free\.app|ngrok\.io)' "$log" | head -1)"
    [ -n "$url" ] && break
  done
  if [ -z "$url" ]; then
    kill "$pid" 2>/dev/null
    die "cel pages tunnel: $provider did not report a URL - see $log"
  fi
  printf '%s\n' "$url" > "$urlf"
  c_ok "public tier tunnelled: $url (provider $provider, pid $pid)" >&2
  c_warn "share links now use this host; it changes if the tunnel restarts" >&2
  printf '%s\n' "$url"
  # Foreground wait: the tunnel is the process, so it belongs in a pane the
  # same way the servers do. The URL file is cleared on exit so stale hosts
  # never end up in a share link.
  wait "$pid" || true
  rm -f "$urlf"
}

cmd_publish() { # [--public] <file> [name]
  local public=0
  [ "${1:-}" = "--public" ] && { public=1; shift; }
  [ $# -ge 1 ] || die "cel publish: usage: cel publish [--public] <file> [name]"
  local file="$1" name="${2:-}"
  [ -f "$file" ] || die "cel publish: no such file: $file"
  local base ext
  base="$(basename "$file")"; ext="${base##*.}"
  [ "$ext" = "$base" ] && ext="html"   # no extension: it is a page
  if [ -z "$name" ]; then name="${base%.*}"; fi
  # names are URL segments and filenames at once - keep them boring
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')"
  name="${name#-}"; name="${name%-}"
  name="${name%."$ext"}.$ext"
  [ "$name" != ".$ext" ] || die "cel publish: name '$2' sanitised to nothing"
  local root url ws; ws="$(_pages_workspace)"
  if [ "$public" -eq 1 ]; then
    # public shares live in an unguessable token dir with a manifest the
    # public server reads for expiry - same shape the nav bar creates.
    root="$(_pages_public_root)"
    local token ttl_h expires
    token="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    ttl_h="${CEL_PAGES_SHARE_TTL_HOURS:-168}"
    if [ "$ttl_h" = "0" ]; then expires=null
    else expires="\"$(date -u -d "+$ttl_h hours" +%Y-%m-%dT%H:%M:%SZ)\""; fi
    mkdir -p "$root/$token"
    printf '{"doc":"%s","created":"%s","expires":%s}\n' \
      "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$expires" > "$root/$token/.share.json"
    root="$root/$token"
    url="$(_pages_public_url)/$token/$name"
  else
    root="$(_pages_root)"
    # ONE FLAT NAMESPACE, BUT NOT A SHARED BLAST RADIUS. Republishing a name
    # in place is the whole design - the URL stays stable across revisions,
    # like an artifact redeploy - so a timestamp on every name would be a cure
    # worse than the disease: every revision would get a new URL and every
    # link already sent would rot. The clobber worth preventing is the one
    # nobody intends: ANOTHER workspace's page of the same name. So the name is
    # suffixed only when the incumbent belongs to someone else, and suffixed
    # with the workspace rather than a timestamp, so that workspace's own
    # republishes stay stable and in place too.
    local owner; owner="$(_pages_owner "$root" "$name")"
    if [ -n "$owner" ] && [ -n "$ws" ] && [ "$owner" != "$ws" ]; then
      # Separate statements: a single `local a=... b=$a` leaves b reading an
      # unset a on this shell, which silently produced names like `-beta.html`.
      local stem; stem="${name%."$ext"}"
      # SANITISE THE SUFFIX. A workspace name is not restricted to
      # filename-safe characters, and this is appended AFTER the document name
      # was sanitised - so a workspace called `team/docs` would produce
      # `report-team/docs.html`, a path rather than a name. Same rule the
      # document name gets. (Codex review, PR #9.)
      local wss; wss="$(printf '%s' "$ws" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')"
      wss="${wss#-}"; wss="${wss%-}"; wss="${wss:-ws}"
      local want="$stem-$wss" n=1
      # AND THE FALLBACK HAS TO BE FREE TOO. `report-beta.html` can already
      # belong to a third workspace - one that simply published a document
      # called that - and stopping at the first candidate would overwrite it,
      # reintroducing the clobber one name along. Walk until the name is
      # unowned or ours. (Codex review, PR #9.)
      while :; do
        local cand="$want.$ext" cowner
        cowner="$(_pages_owner "$root" "$cand")"
        if [ -z "$cowner" ] || [ "$cowner" = "$ws" ]; then name="$cand"; break; fi
        n=$((n + 1)); want="$stem-$wss-$n"
      done
      c_warn "'$stem.$ext' belongs to workspace '$owner' - publishing as '$name' instead" >&2
    fi
    url="http://$(_pages_host):$(_pages_port)/$name"
  fi
  mkdir -p "$root/.meta"
  # EDIT HISTORY: republishing under the same name is the normal way to revise
  # a page, so the outgoing bytes are archived first - otherwise every revision
  # silently destroys the one a reader may still be looking at. Dot-prefixed,
  # so the server can never serve .versions as a document. Bounded at 20.
  if [ -f "$root/$name" ] && ! cmp -s "$file" "$root/$name"; then
    mkdir -p "$root/.versions/$name"
    cp "$root/$name" "$root/.versions/$name/$(date +%s).$ext"
    ls -1t "$root/.versions/$name" 2>/dev/null | tail -n +21 | while read -r old; do
      rm -f "$root/.versions/$name/$old"
    done
  fi
  cp "$file" "$root/$name"
  jq -nc --arg doc "$name" --arg pane "${HERDR_PANE_ID:-}" --arg ts "$(date -Is)" \
     --argjson bytes "$(wc -c < "$file" | tr -d ' ')" \
     '{ts: $ts, doc: $doc, pane: $pane, bytes: $bytes}' >> "$root/.meta/revisions.log"
  # Who published this is who gets its feedback: cel publish runs inside the
  # agent's own pane, so the herdr pane id is the routing address. The .meta
  # dir is unservable by construction (dotfile names 404).
  jq -n --arg pane "${HERDR_PANE_ID:-}" --arg cwd "$PWD" --arg ts "$(date -Is)" \
    --arg ws "$ws" \
    '{pane: $pane, cwd: $cwd, workspace: $ws, published: $ts}' > "$root/.meta/$name.json"
  printf '%s\n' "$url"
  # eval-proof second line for humans; the URL alone stays machine-readable
  c_ok "published as $name$([ "$public" -eq 1 ] && printf ' [PUBLIC - the whole internet]') (same name republish updates it)" >&2
}
