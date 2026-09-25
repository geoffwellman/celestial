# shellcheck shell=bash
# cel gateway - several subscriptions behind one loopback door.
#
# The owner has more than one Codex or Claude subscription signed in and wants
# work spread across them so no single one maxes out. Until CEL-60 that door
# was omp's `auth-broker` + `auth-gateway` pair, and on this box it had NEVER
# run: `omp auth-gateway status --json` answered `ready:false,
# brokerConfigured:false` with zero credentials, so every worker queued on one
# account - on 2026-09-20 one Anthropic account hit its five-hour limit and
# stalled four workers while another sat at 16%.
#
# The door is now CLIProxyAPI: ONE supervised process that is both the
# credential vault (one OAuth JSON per account in its auth-dir) and the
# OpenAI/Anthropic-shaped surface on loopback. omp stays on the box - it is an
# agent runtime kind - but nothing here calls it any more, because two
# credential vaults is the failure this replaced.
#
# THE SESSION KEY IS THE WHOLE BALANCING MECHANISM, AND PI DOES NOT SEND ONE.
# The first spike (.cel/specs/SPIKE-gateway.report.md) put a logging proxy in
# front of the gateway and watched three pi runs with three distinct
# --session-id values arrive with no session header at all - pi's --session-id
# is local bookkeeping and never leaves the process. So the launcher injects
# one: a provider `headers` entry bound to $CEL_SESSION_ID, set per worker.
# CLIProxyAPI reads exactly that header, and `routing.session-affinity: true`
# then pins one account for the length of the conversation.
#
# THE API-KEY IS NEVER PRINTED. One key unlocks every subscription in the
# vault to anything that can reach the port, which is why the service binds
# 127.0.0.1, the management API is left out of the config entirely, and pi's
# provider block names the VARIABLE ($CEL_GATEWAY_API_KEY) rather than holding
# the value.
[ -n "${_CEL_GATEWAY:-}" ] && return 0
_CEL_GATEWAY=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"
# shellcheck source=lib/services.sh
. "$(dirname "${BASH_SOURCE[0]}")/services.sh"   # svc_box_write, svc_start

# CLIProxyAPI's own default (config.example.yaml:7). Nothing on this box has
# ever bound it, so there is no legacy port to keep.
_GATEWAY_DEFAULT_PORT=8317

# The box's gateway state: the config CLIProxyAPI reads, the api-key it
# accepts, and the vault of OAuth files. NEVER inside a repo - a worktree gets
# committed, pushed and read by a reviewer.
gateway_state_dir() { printf '%s' "${CEL_GATEWAY_STATE:-$HOME/.local/share/cel/gateway}"; }
gateway_config_file() { printf '%s/config.yaml' "$(gateway_state_dir)"; }
gateway_auth_dir()   { printf '%s/auth' "$(gateway_state_dir)"; }
_gateway_key_file()  { printf '%s/api-key' "$(gateway_state_dir)"; }
_gateway_mgmt_key_file() { printf '%s/management-key' "$(gateway_state_dir)"; }

# The port, from the box config, with CLIProxyAPI's default. `gateway_port`
# is the key CEL-60 writes; `gateway.gateway_port` is what CEL-28 wrote and is
# still read so an existing box keeps answering on the port its workers know.
# Loopback is not configurable: see the api-key note above.
gateway_port() {
  local v; v="$(cel_config_get gateway port)"
  [ -n "$v" ] || v="$(cel_config_get gateway gateway_port)"
  printf '%s' "${v:-$_GATEWAY_DEFAULT_PORT}"
}

gateway_url()        { printf 'http://127.0.0.1:%s' "$(gateway_port)"; }
gateway_health_url() { printf '%s/healthz' "$(gateway_url)"; }

# Installed means the config says so, not that the port answers - a box whose
# service is merely down is installed and broken, which is a different
# sentence from "there is no gateway here".
gateway_installed() {
  [ -n "$(cel_config_get gateway port)" ] || [ -n "$(cel_config_get gateway gateway_port)" ]
}

# The api-key, minted once and read from a 0600 file. MINTED ONCE MATTERS: a
# second `install` that rolled it would 401 every pi worker already launched
# against this gateway, and the failure reads as "the model is gone".
_gateway_api_key() {
  local f; f="$(_gateway_key_file)"
  if [ ! -s "$f" ]; then
    mkdir -p "$(dirname "$f")"; chmod 700 "$(dirname "$f")" 2>/dev/null || true
    ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$f" )
  fi
  tr -d '\r\n' < "$f"
}

# The management secret, minted once like the api-key and for the same reason:
# a panel already open in a browser holds it. 0600 in the gateway's own state
# dir, never printed and never in a repo.
_gateway_mgmt_key() {
  local f; f="$(_gateway_mgmt_key_file)"
  if [ ! -s "$f" ]; then
    mkdir -p "$(dirname "$f")"; chmod 700 "$(dirname "$f")" 2>/dev/null || true
    ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$f" )
  fi
  chmod 600 "$f" 2>/dev/null || true
  tr -d '\r\n' < "$f"
}

# The web panel CLIProxyAPI serves, and how to reach it from somewhere that is
# not this box. It is loopback only: the tunnel is the way in, never a
# tailnet bind.
gateway_panel_url() { printf '%s/management.html' "$(gateway_url)"; }
gateway_panel_ssh() {
  local p; p="$(gateway_port)"
  printf 'ssh -L %s:127.0.0.1:%s %s' "$p" "$p" "$(hostname -s 2>/dev/null || hostname)"
}

# TEST SEAM, kept from CEL-28 because lib/quota.sh and lib/profiles.sh have
# suites that set it: `$CEL_GATEWAY_STUB ready|models` stands in for the HTTP
# reads so no suite depends on which accounts this box is signed in to.
_gateway_stub() { [ -n "${CEL_GATEWAY_STUB:-}" ]; }

# Is the door open? GET /healthz, UNAUTHENTICATED - the real health probe this
# gateway never had. omp's only readable route was /v1/models behind a bearer,
# so a health check had to carry the key that unlocks every subscription just
# to say "up", and an unauthenticated read answered 401 and called a working
# gateway down once a tick forever.
gateway_ready() {
  _gateway_stub && { "$CEL_GATEWAY_STUB" ready; return $?; }
  curl -sf -m 5 -o /dev/null "$(gateway_health_url)" 2>/dev/null
}

# GET /v1/models, which every /v1 route requires the api-key for. The key
# rides STDIN, never argv - a bearer in a command line is a bearer in `ps`.
gateway_models_json() {
  _gateway_stub && { "$CEL_GATEWAY_STUB" models; return $?; }
  local key; key="$(_gateway_api_key)"
  [ -n "$key" ] || return 1
  printf 'Authorization: Bearer %s\n' "$key" \
    | curl -sf -m 10 "$(gateway_url)/v1/models" -H @- 2>/dev/null
}

# --- the account table ----------------------------------------------------

# THE AUTH-DIR IS THE ACCOUNT LIST. CLIProxyAPI's management API is off on
# this box (it is the remote-control surface, and one api-key already unlocks
# everything), so the files ARE the evidence - and reading them costs no
# quota, which omp's `auth-gateway check --strict` spent once per status.
#
# The filenames carry what the table needs (SPIKE-cliproxy.report.md):
#   claude-<hash>-<email>.json          internal/auth/claude/filename.go:27,32
#   codex-<hash>-<email>-<plan>.json    internal/auth/codex/filename.go:24-31
# The PLAN exists only in the name, which is why the name is parsed at all
# rather than only the JSON inside.
#
# Rows come out in the shape a subscription row has, so the QUOTA view can
# list gateway accounts beside the direct ones:
#   { source, provider, id, email, plan, type, ok, windows: [] }
#
# `windows` is EMPTY, always, and that is not a bug: CLIProxyAPI removed
# built-in usage accounting in v6.10.0, and its per-credential quota snapshot
# is the last upstream response's rate-limit headers - empty until an account
# serves traffic, so "no usage probe" and not "0% used". CEL-61 builds the
# usage reader over these same files.
gateway_accounts_json() {
  local d; d="$(gateway_auth_dir)"
  [ -d "$d" ] || { printf '[]'; return 0; }
  local f base rest provider hash email plan rows=""
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .json)"
    provider="${base%%-*}"
    rest="${base#*-}"
    [ "$rest" != "$base" ] || continue
    hash="${rest%%-*}"
    rest="${rest#*-}"
    plan=""
    email="$rest"
    # A trailing segment that is not part of the address is the plan: emails
    # may contain a hyphen, so the test is "the last segment has no @".
    case "$rest" in
      *-*) case "${rest##*-}" in *@*) ;; *) plan="${rest##*-}"; email="${rest%-*}" ;; esac ;;
    esac
    rows="$rows$(jq -nc --arg p "$provider" --arg i "${hash:0:6}" --arg e "$email" --arg pl "$plan" \
      '{source:"gateway", provider:$p, id:$i, email:$e, plan:$pl, type:"oauth", ok:true, windows:[]}')
"
  done
  printf '%s' "$rows" | jq -sc '.' 2>/dev/null || printf '[]'
}

# How many accounts the balancer could actually pick from, all providers or
# one. A credential file that exists is a credential the proxy will try; it
# cannot be known to be spent without spending a request on finding out.
gateway_usable_count() { # [provider]
  local js; js="$(gateway_accounts_json)"
  if [ -n "${1:-}" ]; then
    printf '%s' "$js" | jq --arg p "$1" '[.[] | select(.provider == $p and .ok != false)] | length'
  else
    printf '%s' "$js" | jq '[.[] | select(.ok != false)] | length'
  fi
}

gateway_status_json() {
  local accounts ready=false
  accounts="$(gateway_accounts_json)"
  gateway_ready && ready=true
  jq -n --argjson accounts "$accounts" \
        --arg port "$(gateway_port)" \
        --arg url "$(gateway_url)" \
        --arg authdir "$(gateway_auth_dir)" \
        --argjson installed "$(gateway_installed && echo true || echo false)" \
        --argjson ready "$ready" '{
    installed: $installed, ready: $ready,
    port: ($port | tonumber), url: $url, auth_dir: $authdir,
    credentials: ($accounts | length),
    accounts: $accounts }'
}

# --- the config file ------------------------------------------------------

# CLIProxyAPI HAS NO FLAG-ONLY MODE (cmd/server/main.go): every setting below
# exists only in this file, so install writes it and the suite asserts each
# line by key. The comments say WHY, because the next person to edit this file
# is deciding whether a line matters.
_gateway_config_write() {
  local f; f="$(gateway_config_file)"
  local d; d="$(gateway_state_dir)"
  mkdir -p "$d" "$(gateway_auth_dir)"
  chmod 700 "$d" "$(gateway_auth_dir)"
  local tmp; tmp="$(mktemp "$d/.config.XXXXXX")"
  {
    cat <<'EOS'
# Written by `cel gateway install` - edit the box config (cel.yaml) and run it
# again rather than hand-editing, or the next install overwrites you.
EOS
    cat <<EOS
# ONE API-KEY BELOW UNLOCKS EVERY SUBSCRIPTION IN THE VAULT, so the listener
# never leaves this machine. A LAN bind would hand the owner's accounts to
# whatever else is on the network.
host: "127.0.0.1"
port: $(gateway_port)

# The vault: one OAuth JSON per account, 0700, in the box state dir. Never
# inside a repo - a worktree gets committed, pushed and read by a reviewer.
auth-dir: "$(gateway_auth_dir)"

# The static bearer every /v1 route requires. pi is handed the NAME of the
# variable that holds it, never the value.
api-keys:
  - "$(_gateway_api_key)"

# Provider prefixes stay off, so model ids reach pi plain (gpt-5.5, not
# ompgw/openai-codex/gpt-5.5). The earlier gateway's three-segment ids broke
# everything in the plane that splits a model id on the first slash.
force-model-prefix: false

routing:
  # THE DEFAULT IS false AND false IS WORSE THAN ONE ACCOUNT: without affinity
  # a worker switches account mid-conversation, so the second turn of a task
  # is answered by a subscription that never saw the first. The key it pins on
  # is the x-session-id header the launcher injects per worker.
  session-affinity: true
  session-affinity-ttl: 1h

# THE MANAGEMENT API, LOOPBACK ONLY (CEL-80). CEL-60 left this block out, and
# the web panel at /management.html could then read and change nothing. Keys
# checked against CLIProxyAPI 7.3.14's config struct. allow-remote: false is
# what keeps it on this machine - the panel is reached over an ssh tunnel
# (cel gateway panel), never on the tailnet. CLIProxyAPI hashes a plaintext
# secret-key in place on load; the plaintext stays in the 0600 key file.
remote-management:
  allow-remote: false
  secret-key: "$(_gateway_mgmt_key)"
  disable-control-panel: false
EOS
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$f"
}

# --- the service ----------------------------------------------------------

# ONE box service, where omp needed two. It belongs to the BOX and not to any
# workspace - every workspace's workers go through this one door - so CEL-34's
# `services.d` is its home, where `cel services` and the steward sweep already
# look.
#
# THE NAME IS UNCHANGED (`cel-auth-gateway`). lib/doctor.sh and lib/orphans.sh
# both key off it, and they belong to other tickets; the process behind the
# name changed, the handle the box holds it by did not.
#
# The health check carries NO bearer: /healthz is unauthenticated
# (internal/api/server_routes.go:44-52), so the probe no longer has to present
# the key that unlocks every subscription just to say "up".
gateway_service_specs() {
  jq -n --arg p "$(gateway_port)" --arg cfg "$(gateway_config_file)" '[
    { name: "cel-auth-gateway",
      cmd: ("cli-proxy-api --config " + $cfg),
      url: ("http://127.0.0.1:" + $p),
      health: ("http://127.0.0.1:" + $p + "/healthz"),
      restart: "auto",
      env: {} }
  ]'
}

_gateway_register_services() {
  local spec name
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    name="$(printf '%s' "$spec" | jq -r '.name')"
    svc_box_write "$name" "$spec"
  done < <(gateway_service_specs | jq -c '.[]')
  c_ok "the gateway service is in $(svc_box_dir) - supervised by the steward"
  return 0
}

# Start it through the SAME path everything else on this box is started by: a
# pane the steward can read and restart, rather than a nohup and a pid file.
# Idempotent by construction - a port already listening is left alone.
_gateway_start() {
  local p; p="$(gateway_port)"
  svc_listening "$p" || svc_start "" cel-auth-gateway || true
}

# --- the pi provider ------------------------------------------------------

gateway_pi_dir() { printf '%s' "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"; }

# Write the gateway's providers into pi's models.json, MERGING.
#
# models.json is the owner's file: it carries whatever providers they added by
# hand, and a writer that rebuilt the document from the gateway's model list
# would silently delete them. jq merges the two keys and leaves the rest
# byte-alike.
#
# TWO BLOCKS, ONE GATEWAY. CLIProxyAPI serves both an OpenAI-shaped
# /v1/chat/completions and an Anthropic-shaped /v1/messages over the same
# accounts, and pi speaks both; Claude models go through `anthropic-messages`
# because that is the protocol they were designed for, everything else through
# `openai-completions`.
#
# THE PROVIDER KEY IS STILL `ompgw`. lib/profiles.sh prefixes a `via: gateway`
# model with exactly that string and lib/run.sh names it in the launch
# environment; both belong to other tickets, so renaming the key here would
# break every gateway profile on the box for a cosmetic gain. The rename is
# noted in .agent/result.md as a follow-up.
#
# apiKey and the session header are written as VARIABLE NAMES. pi expands them
# from the pane's environment at launch, so no key and no session id is ever
# in this file.
gateway_pi_models_write() { # [models.json path]
  local f="${1:-$(gateway_pi_dir)/models.json}" models tmp
  models="$(gateway_models_json | jq -c '[ (.data // [])[] | {
      id: .id,
      contextWindow: (.context_length // 128000),
      maxTokens: (.max_output_tokens // 8192) } ]' 2>/dev/null || true)"
  [ -n "$models" ] || return 1
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '{"providers":{}}' > "$f"
  tmp="$(mktemp "$(dirname "$f")/.models.XXXXXX")"
  jq --argjson models "$models" --arg url "$(gateway_url)/v1" '
    ([$models[] | select(.id | test("^claude"))]) as $claude
    | ([$models[] | select(.id | test("^claude") | not)]) as $rest
    | .providers = ((.providers // {}) + {
        ompgw: {
          name: "cel gateway",
          baseUrl: $url,
          apiKey: "$CEL_GATEWAY_API_KEY",
          api: "openai-completions",
          headers: { "x-session-id": "$CEL_SESSION_ID" },
          models: $rest },
        "ompgw-claude": {
          name: "cel gateway (anthropic)",
          baseUrl: $url,
          apiKey: "$CEL_GATEWAY_API_KEY",
          api: "anthropic-messages",
          headers: { "x-session-id": "$CEL_SESSION_ID" },
          models: $claude } })' "$f" > "$tmp" && mv "$tmp" "$f"
}

# --- doctor ---------------------------------------------------------------

# One line, and the verb that fixes it. The failure this exists for is silent:
# a provider with no credential in the vault serves no model of that shape at
# all, so a worker launched at it dies with "Unknown model" rather than "auth
# expired", and nothing on the box said the account was never signed in.
# CEL_GATEWAY_WATCH names the providers worth asserting about on this box.
gateway_doctor_line() {
  if ! gateway_installed; then
    printf '  gateway: not installed - cel gateway install\n'
    return 0
  fi
  if ! gateway_ready; then
    printf '  gateway: installed, NOT ready on %s - cel gateway status\n' "$(gateway_url)"
    return 0
  fi
  local accounts; accounts="$(gateway_accounts_json)"
  local per; per="$(printf '%s' "$accounts" \
    | jq -r 'group_by(.provider)[] | "\(.[0].provider) \([.[] | select(.ok != false)] | length)"')"
  local summary="" p n
  while read -r p n; do
    [ -n "$p" ] || continue
    summary="${summary:+$summary, }$p $n"
  done <<< "$per"
  printf '  gateway: ready on %s - accounts signed in: %s\n' "$(gateway_url)" "${summary:-none}"
  for p in ${CEL_GATEWAY_WATCH:-}; do
    n="$(gateway_usable_count "$p")"
    [ "$n" -gt 0 ] 2>/dev/null && continue
    printf '  gateway: no %s account in the vault - cel gateway login %s\n' "$p" "$p"
  done
  return 0
}

# --- the verbs ------------------------------------------------------------

_gateway_usage() {
  cat <<'EOS'
cel gateway - several subscriptions behind one loopback door

  cel gateway install [--no-start]   write the proxy config, register the box
                                     service, mint the api-key
  cel gateway status [--json]        the door, and one row per account
  cel gateway login <provider>       sign another subscription in
                                     --no-browser: device flow, headless box
  cel gateway logout <provider> <id> drop one account from the vault
  cel gateway panel [--json]         the web panel's loopback URL, and the
                                     ssh tunnel that reaches it from a laptop
EOS
}

# The login flags CLIProxyAPI itself takes, per provider. Claude and Codex are
# what this box signs in; anything else is named rather than guessed at.
_gateway_login_flags() { # <provider> <no-browser 0|1>
  case "$1" in
    claude|anthropic) printf -- '-claude-login%s' "$([ "$2" = 1 ] && printf ' -no-browser')" ;;
    codex|openai)     [ "$2" = 1 ] && printf -- '-codex-device-login -no-browser' || printf -- '-codex-login' ;;
    *) return 1 ;;
  esac
}

_gateway_install() {
  local start=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-start) start=0; shift ;;
      *) die "cel gateway install: unknown argument '$1'" ;;
    esac
  done
  have jq || die "cel gateway install: jq is not on PATH"
  have cli-proxy-api \
    || c_warn "cli-proxy-api is not on PATH - cel setup installs it; the config below is written anyway"

  cel_config_set gateway port "$(gateway_port)"
  _gateway_config_write
  c_ok "gateway: $(gateway_url) - config $(gateway_config_file), vault $(gateway_auth_dir)"

  _gateway_register_services
  [ "$start" -eq 1 ] && _gateway_start
  if gateway_ready; then
    c_ok "gateway ready on $(gateway_url) - $(gateway_usable_count) account(s) signed in"
  else
    c_warn "gateway not answering yet on $(gateway_url) - cel gateway status"
  fi
  return 0
}

_gateway_status_text() {
  local js; js="$(gateway_status_json)"
  local ready; ready="$(printf '%s' "$js" | jq -r '.ready')"
  # WHO IS WATCHING IT is the first thing to say. An unsupervised gateway is
  # one lid-close away from being down with nobody on the box able to notice,
  # and that is a different sentence from "not ready".
  local watched="(unsupervised)"
  svc_box_declared cel-auth-gateway && watched="(box service, steward-watched)"
  if [ "$(printf '%s' "$js" | jq -r '.installed')" != true ]; then
    c_warn "no gateway on this box - cel gateway install"
  else
    printf '  gateway on %s %s\n' "$(gateway_url)" "$watched"
  fi
  printf '  health   %s  %s\n' "$(gateway_health_url)" \
    "$([ "$ready" = true ] && echo ready || echo "NOT ready")"
  printf '  vault    %s\n' "$(gateway_auth_dir)"
  printf '\n  %-10s %-8s %-8s %s\n' PROVIDER ACCOUNT PLAN EMAIL
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '  %s\n' "$line"
  done < <(printf '%s' "$js" | jq -r '.accounts[] |
    "\(.provider | .[0:10] | . + (" " * (10 - length))) " +
    "\(.id | .[0:8] | . + (" " * (8 - length))) " +
    "\((if .plan == "" then "-" else .plan end) | .[0:8] | . + (" " * (8 - length))) " +
    .email')
  [ "$(printf '%s' "$js" | jq -r '.accounts | length')" != 0 ] \
    || printf '  no account in the vault - cel gateway login <provider>\n'
  return 0
}

cmd_gateway() {
  local verb="${1:-status}"; shift || true
  case "$verb" in
    install) _gateway_install "$@" ;;
    status)
      if [ "${1:-}" = "--json" ]; then gateway_status_json; else _gateway_status_text; fi ;;
    login)
      local p="" nb=0 a
      for a in "$@"; do
        case "$a" in
          --no-browser) nb=1 ;;
          -*) die "cel gateway login: unknown option '$a'" ;;
          *) [ -n "$p" ] || p="$a" ;;
        esac
      done
      [ -n "$p" ] || die "cel gateway login: name a provider (claude or codex)"
      local flags; flags="$(_gateway_login_flags "$p" "$nb")" \
        || die "cel gateway login: no login flow for '$p' (claude or codex)"
      # An OAuth dance needs a human at a browser. Off a TTY - a steward tick,
      # a worker, a script - the instruction is the answer; a hung process
      # holding a terminal nobody is looking at is not.
      if [ -t 0 ] && [ -t 1 ]; then
        cli-proxy-api --config "$(gateway_config_file)" $flags
      else
        printf 'not a terminal - run this yourself, it opens a browser:\n\n  cli-proxy-api --config %s %s\n\n' \
          "$(gateway_config_file)" "$flags"
        printf 'then: cel gateway status\n'
      fi ;;
    logout)
      # Dropping an account is deleting its file: the vault has no other
      # registry, and the proxy rereads the directory.
      local p="${1:-}" id="${2:-}"
      [ -n "$p" ] && [ -n "$id" ] \
        || die "cel gateway logout: name a provider and an account id (cel gateway status lists them)"
      local f found=0
      for f in "$(gateway_auth_dir)/$p"-*.json; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in "$p-$id"*) rm -f "$f"; found=1; c_ok "dropped $(basename "$f" .json)" ;; esac
      done
      [ "$found" = 1 ] || die "cel gateway logout: no $p account whose id starts '$id'" ;;
    panel)
      # The URL and the tunnel, never the key: the key is typed into the
      # panel from the 0600 file, by someone already on the box.
      if [ "${1:-}" = --json ]; then
        jq -nc --arg u "$(gateway_panel_url)" --arg s "$(gateway_panel_ssh)" \
          --arg k "$(_gateway_mgmt_key_file)" '{url: $u, ssh: $s, key_file: $k}'
      else
        printf '  panel    %s\n' "$(gateway_panel_url)"
        printf '  laptop   %s   then open the URL above\n' "$(gateway_panel_ssh)"
        printf '  key      in %s (0600) - never on the tailnet\n' "$(_gateway_mgmt_key_file)"
      fi ;;
    help|-h|--help) _gateway_usage ;;
    *) c_err "cel gateway: unknown verb '$verb'"; echo; _gateway_usage; return 2 ;;
  esac
}
