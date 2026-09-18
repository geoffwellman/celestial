# shellcheck shell=bash
# cel gateway - several subscriptions behind one loopback door.
#
# The owner has more than one Codex or Claude subscription signed in and wants
# work spread across them so no single one maxes out. omp already holds the
# accounts: `auth-broker` is the vault (several OAuth credentials per provider,
# keyed by an identity hash per account) and `auth-gateway` is a LiteLLM-shaped
# OpenAI/Anthropic surface on loopback that mints the OAuth itself, drops the
# accounts that are unavailable and picks one of the rest by SESSION KEY. This
# file is the plane's side of that: two supervised services, an account table,
# and the one-line verb for logging another subscription in.
#
# THE SESSION KEY IS THE WHOLE BALANCING MECHANISM, AND PI DOES NOT SEND ONE.
# The spike (.cel/specs/SPIKE-gateway.report.md) put a logging proxy in front
# of the gateway and watched three pi runs with three distinct --session-id
# values arrive with no session header at all - pi's --session-id is local
# bookkeeping and never leaves the process. So the launcher injects one:
# a provider `headers` entry bound to $CEL_SESSION_ID, set per worker. Without
# it every worker on the box is the same anonymous session and the balancer
# has nothing to balance on.
#
# THE BEARER IS NEVER PRINTED AND NEVER WRITTEN. It grants every subscription
# in the vault to anything that can reach the port. It lives in
# ~/.omp/auth-gateway.token (0600, omp's own file); the plane passes the NAME
# of the variable and lets the pane read the value itself at launch.
[ -n "${_CEL_GATEWAY:-}" ] && return 0
_CEL_GATEWAY=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"
# shellcheck source=lib/services.sh
. "$(dirname "${BASH_SOURCE[0]}")/services.sh"   # svc_box_write, svc_start

_GATEWAY_DEFAULT_BROKER_PORT=47311
_GATEWAY_DEFAULT_GATEWAY_PORT=47411

gateway_state_dir() { printf '%s' "${CEL_GATEWAY_STATE:-$HOME/.local/share/cel/gateway}"; }

# The ports, from the box config, with the spike's defaults. Loopback is not
# configurable: see the bearer note above.
gateway_port() { # <broker|gateway>
  local v
  case "$1" in
    broker)  v="$(cel_config_get gateway broker_port)";  printf '%s' "${v:-$_GATEWAY_DEFAULT_BROKER_PORT}" ;;
    gateway) v="$(cel_config_get gateway gateway_port)"; printf '%s' "${v:-$_GATEWAY_DEFAULT_GATEWAY_PORT}" ;;
    *) return 1 ;;
  esac
}

gateway_url()        { printf 'http://127.0.0.1:%s' "$(gateway_port gateway)"; }
gateway_broker_url() { printf 'http://127.0.0.1:%s' "$(gateway_port broker)"; }

# Installed means the config says so, not that the port answers - a box whose
# services are merely down is installed and broken, which is a different
# sentence from "there is no gateway here".
gateway_installed() { [ -n "$(cel_config_get gateway gateway_port)" ]; }

# The two tokens, read at the moment they are needed and never stored by us.
# `omp auth-gateway token` CREATES the file on first call, which is why
# install calls it once: a service that has to mint its own bearer races with
# the health check that reads it.
_gateway_token()        { omp auth-gateway token 2>/dev/null | tr -d '\r\n'; }
_gateway_broker_token() { omp auth-broker token 2>/dev/null | tr -d '\r\n'; }

# The broker's address and bearer are required by BOTH omp subcommands - they
# error out without them, and that error is exactly the `not_configured` the
# spike chased for an afternoon.
_gateway_omp() { # <args...>
  OMP_AUTH_BROKER_URL="$(gateway_broker_url)" \
  OMP_AUTH_BROKER_TOKEN="$(_gateway_broker_token)" \
  omp "$@"
}

# TEST SEAM. `$CEL_GATEWAY_STUB ready|models` stands in for the HTTP reads so
# a suite never depends on which accounts this box is signed in to. Same shape
# as lib/quota.sh's CEL_QUOTA_STUB.
_gateway_stub() { [ -n "${CEL_GATEWAY_STUB:-}" ]; }

# Is the door open? A bearer-authenticated GET /v1/models, which is also the
# health check the services carry: an unauthenticated read answers 401 and a
# port knock answers nothing useful at all.
gateway_ready() {
  _gateway_stub && { "$CEL_GATEWAY_STUB" ready; return $?; }
  local tok; tok="$(_gateway_token)"
  [ -n "$tok" ] || return 1
  printf 'Authorization: Bearer %s\n' "$tok" \
    | curl -sf -m 5 -o /dev/null "$(gateway_url)/v1/models" -H @- 2>/dev/null
}

gateway_models_json() {
  _gateway_stub && { "$CEL_GATEWAY_STUB" models; return $?; }
  local tok; tok="$(_gateway_token)"
  [ -n "$tok" ] || return 1
  printf 'Authorization: Bearer %s\n' "$tok" \
    | curl -sf -m 10 "$(gateway_url)/v1/models" -H @- 2>/dev/null
}

# --- the account table ----------------------------------------------------

# `auth-gateway check --json` without --strict: strict probes each credential
# against its provider's chat endpoint and SPENDS QUOTA per credential, which
# is not a thing a status command may do behind someone's back.
#
# Normalised to one row per account, in the shape a subscription row has, so
# the QUOTA view can list gateway accounts beside the direct ones:
#   { source, provider, id, type, ok, windows: [{label, used, limit,
#     used_pct, state, resets_at}] }
#
# THE ID IS SHORT AND THE EMAIL IS DROPPED. The table is read over shoulders
# and pasted into tickets; the account email is personal data no operator
# decision needs, and a 36-character UUID pushes every other column off the
# edge.
gateway_accounts_json() {
  local raw
  raw="$(_gateway_omp auth-gateway check --json 2>/dev/null || true)"
  [ -n "$raw" ] || { printf '[]'; return 0; }
  printf '%s' "$raw" | jq -c '
    [ (.credentials // [])[] | {
        source: "gateway",
        provider: (.provider // "?"),
        id: (if (.accountId // "") != "" then (.accountId | tostring | .[0:6])
             else "cred-" + ((.id // "?") | tostring) end),
        type: (.type // ""),
        ok: .ok,
        windows: [ ((.report.limits // [])[] | {
          label: (.label // .window.label // .window.id // "window"),
          used: (.amount.used // null),
          limit: (.amount.limit // null),
          used_pct: (if (.amount.usedFraction // null) != null
                     then ((.amount.usedFraction * 100) | round)
                     elif (.amount.limit // 0) > 0 then (((.amount.used // 0) * 100 / .amount.limit) | round)
                     else null end),
          state: (.status // "unknown"),
          resets_at: (.window.resetsAt // null),
        }) ]
      } ]' 2>/dev/null || printf '[]'
}

# How many accounts the balancer could actually pick from, all providers or
# one. `ok: null` means "no usage probe for this provider" - the credential is
# there and works, it just cannot report a number - so it counts as usable;
# only an explicit false does not. An api_key credential is listed but is NOT
# part of the OAuth balancer (proved by `omp dry-balance`), which is a caveat
# for the docs, not a reason to hide the row.
gateway_usable_count() { # [provider]
  local js; js="$(gateway_accounts_json)"
  if [ -n "${1:-}" ]; then
    printf '%s' "$js" | jq --arg p "$1" '[.[] | select(.provider == $p and .ok != false)] | length'
  else
    printf '%s' "$js" | jq '[.[] | select(.ok != false)] | length'
  fi
}

gateway_status_json() {
  local broker gwstat accounts ready=false
  broker="$(_gateway_omp auth-broker status --json 2>/dev/null || true)"
  gwstat="$(_gateway_omp auth-gateway status --json 2>/dev/null || true)"
  accounts="$(gateway_accounts_json)"
  gateway_ready && ready=true
  jq -n --argjson accounts "$accounts" \
        --argjson broker "${broker:-null}" \
        --argjson gw "${gwstat:-null}" \
        --arg port "$(gateway_port gateway)" \
        --arg bport "$(gateway_port broker)" \
        --argjson installed "$(gateway_installed && echo true || echo false)" \
        --argjson ready "$ready" '{
    installed: $installed, ready: $ready,
    port: ($port | tonumber), broker_port: ($bport | tonumber),
    broker_ok: ($broker.ok // false),
    credentials: ($gw.credentialCount // 0),
    reason: ($gw.reason // null),
    accounts: $accounts }'
}

# --- the services ---------------------------------------------------------

# The two box services, as data. They belong to the BOX and not to any
# workspace - every workspace's workers go through this one door - so CEL-34
# gives them a home in `services.d`, where `cel services` and the steward
# sweep already look.
#
# The gateway process is useless without the broker's URL and bearer, so both
# ride in its environment - the bearer by a command that READS it, never by
# value: a service definition is a file on disk, and a token in it is a token
# on disk waiting to be backed up somewhere it should not be. The gateway's
# health check names its bearer the same way, because /v1/models answers 401
# unauthenticated and a check that could not present one would call a working
# gateway down once a tick forever.
#
# ONLY THE GATEWAY DECLARES A HEALTH PATH. The broker (omp 18.1.17) has no GET
# route at all - `/`, `/status` and `/healthz` all answer 404, bearer or not -
# so any path declared for it is a permanent false alarm, and the rule here is
# that no health beats a health check that always fails. The gateway's
# /v1/models is the read that proves both: the gateway mints its OAuth through
# the broker and cannot answer without it.
gateway_service_specs() {
  jq -n --arg b "$(gateway_port broker)" --arg g "$(gateway_port gateway)" '[
    { name: "cel-auth-broker",
      cmd: ("omp auth-broker serve --bind 127.0.0.1:" + $b),
      restart: "auto",
      env: {} },
    { name: "cel-auth-gateway",
      cmd: ("omp auth-gateway serve --bind 127.0.0.1:" + $g),
      health: ("http://127.0.0.1:" + $g + "/v1/models"),
      health_auth: "bearer $(omp auth-gateway token)",
      restart: "auto",
      env: { OMP_AUTH_BROKER_URL: ("http://127.0.0.1:" + $b),
             OMP_AUTH_BROKER_TOKEN: "$(omp auth-broker token)" } }
  ]'
}

# Hand the two definitions to the box's service registry. Before CEL-34 this
# wrote them to a private file under the gateway's state directory and printed
# "NOT supervised", which was true and stayed true: the processes ran for a day
# with nothing watching them. `services.d` is the seam - one 0600 file per
# service in a 0700 directory, and the steward sweep finds them itself.
#
# A `port:` and a `url:` are both accepted there; these carry a full health URL
# and the port is read out of it, so nothing here needs to agree twice about
# which port the gateway is on.
_gateway_register_services() {
  local specs name spec
  specs="$(gateway_service_specs)"
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    name="$(printf '%s' "$spec" | jq -r '.name')"
    # The declared url is the health url without its path when there is one,
    # and the bind port otherwise: the port is the handle every service row
    # keys off, and the broker declares no health check.
    spec="$(printf '%s' "$spec" | jq -c --arg b "$(gateway_port broker)" \
      '. + {url: (if (.health // "") != "" then (.health | capture("^(?<base>[a-z]+://[^/]+)").base)
                  else "http://127.0.0.1:" + $b end)}')"
    svc_box_write "$name" "$spec"
  done < <(printf '%s' "$specs" | jq -c '.[]')
  c_ok "both services are in $(svc_box_dir) - supervised by the steward"
  return 0
}

# Start whatever is not already answering, through the SAME path everything
# else on this box is started by: a pane the steward can read and restart,
# rather than the nohup-and-a-pid-file this used to do behind the plane's back.
# Idempotent by construction - a service already listening is left alone.
_gateway_start() {
  local b g
  b="$(gateway_port broker)"; g="$(gateway_port gateway)"
  svc_listening "$b" || svc_start "" cel-auth-broker || true
  if ! svc_listening "$g"; then
    # The gateway mints OAuth against the broker at startup, so a gateway
    # started in the same breath as its broker asks a door that is not open
    # yet and exits. Two seconds is what the spike measured.
    sleep 2
    svc_start "" cel-auth-gateway || true
  fi
}

# --- the pi provider ------------------------------------------------------

gateway_pi_dir() { printf '%s' "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"; }

# Write the `ompgw` provider into pi's models.json, MERGING.
#
# models.json is the owner's file: it carries whatever providers they added by
# hand, and a writer that rebuilt the document from the gateway's model list
# would silently delete them. jq merges one key and leaves the rest byte-alike.
#
# The model list is GENERATED, never hand-written: pi replaces a provider's
# list wholesale, so every context window and output cap in it is ours to fill
# and would be wrong the moment the gateway's upstreams changed. The ids are
# the gateway's own `<provider>/<model>`, so through pi they read
# `ompgw/openai-codex/gpt-5.5` - three segments, which anything in the plane
# that splits a model id on the first slash has to expect.
#
# apiKey and the session header are written as VARIABLE NAMES. pi expands them
# from the pane's environment at launch, so no token and no session id is ever
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
    .providers = ((.providers // {}) + { ompgw: {
      name: "omp auth-gateway",
      baseUrl: $url,
      apiKey: "$OMP_GATEWAY_TOKEN",
      api: "openai-completions",
      headers: { "x-session-id": "$CEL_SESSION_ID" },
      models: $models } })' "$f" > "$tmp" && mv "$tmp" "$f"
}

# --- doctor ---------------------------------------------------------------

# One line, and the verb that fixes it. The failure this exists for is silent:
# a credential the broker has disabled VANISHES from /v1/models entirely, so a
# worker launched at `ompgw/anthropic/...` dies with "Unknown model" rather
# than "auth expired", and nothing on the box said the account had lapsed.
#
# The broker does not expose its disabled rows over HTTP in omp 18.1.17, so
# the count is only printed when it can be learned; the provider having
# NOTHING usable is the part that is always knowable and always actionable.
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
  local summary=""
  local p n
  while read -r p n; do
    [ -n "$p" ] || continue
    summary="${summary:+$summary, }$p $n"
  done <<< "$per"
  printf '  gateway: ready on %s - accounts usable: %s\n' "$(gateway_url)" "${summary:-none}"
  local watch; watch="${CEL_GATEWAY_WATCH:-}"
  for p in $watch; do
    n="$(gateway_usable_count "$p")"
    [ "$n" -gt 0 ] 2>/dev/null && continue
    printf '  gateway: no usable %s credential (a disabled one is not listed at all) - cel gateway login %s\n' "$p" "$p"
  done
  return 0
}

# --- the verbs ------------------------------------------------------------

_gateway_usage() {
  cat <<'EOS'
cel gateway - several subscriptions behind one loopback door

  cel gateway install [--no-start]   write the ports, declare broker+gateway
                                     as box services, mint the bearer
  cel gateway status [--json]        broker, gateway, and one row per account
  cel gateway login <provider>       sign another subscription in
  cel gateway logout <provider> <id> drop one
EOS
}

_gateway_install() {
  local start=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-start) start=0; shift ;;
      *) die "cel gateway install: unknown argument '$1'" ;;
    esac
  done
  have omp || die "cel gateway install: omp is not on PATH - it owns the credential vault"
  have jq  || die "cel gateway install: jq is not on PATH"

  cel_config_set gateway broker_port  "$(gateway_port broker)"
  cel_config_set gateway gateway_port "$(gateway_port gateway)"
  c_ok "gateway: loopback ports $(gateway_port broker) (broker) and $(gateway_port gateway) (gateway)"

  # Mint the bearer once, here, rather than letting the service race its own
  # health check for a file that does not exist yet. The value is not read.
  _gateway_token >/dev/null 2>&1 || true

  _gateway_register_services
  [ "$start" -eq 1 ] && _gateway_start
  if gateway_ready; then
    c_ok "gateway ready on $(gateway_url) - $(gateway_usable_count) account(s) usable"
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
  printf '  broker   %s  %s\n' "$(gateway_broker_url)" \
    "$([ "$(printf '%s' "$js" | jq -r '.broker_ok')" = true ] && echo ok || echo "NOT reachable")"
  printf '  gateway  %s  %s  (%s credentials)\n' "$(gateway_url)" \
    "$([ "$ready" = true ] && echo ready || echo "NOT ready")" \
    "$(printf '%s' "$js" | jq -r '.credentials')"
  printf '\n  %-14s %-9s %-4s %s\n' PROVIDER ACCOUNT OK WINDOWS
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '  %s\n' "$line"
  done < <(printf '%s' "$js" | jq -r '.accounts[] |
    "\(.provider | .[0:14] | . + (" " * (14 - length))) \(.id | .[0:9] | . + (" " * (9 - length))) " +
    (if .ok == false then "no  " elif .ok == true then "yes " else "?   " end) +
    (if (.windows | length) == 0 then "no usage probe"
     else ([.windows[] | "\(.label) \(.used_pct // "?")% \(.state)"] | join(" | ")) end)')
  [ "$(printf '%s' "$js" | jq -r '.accounts | length')" != 0 ] \
    || printf '  no account is usable - cel gateway login <provider>\n'
  return 0
}

cmd_gateway() {
  local verb="${1:-status}"; shift || true
  case "$verb" in
    install) _gateway_install "$@" ;;
    status)
      if [ "${1:-}" = "--json" ]; then gateway_status_json; else _gateway_status_text; fi ;;
    login)
      local p="${1:-}"
      [ -n "$p" ] || die "cel gateway login: name a provider (cel gateway status lists what is signed in)"
      # An OAuth dance needs a human at a terminal. Off a TTY - a steward tick,
      # a worker, a script - the instruction is the answer; a hung process
      # holding a terminal nobody is looking at is not.
      if [ -t 0 ] && [ -t 1 ]; then
        _gateway_omp auth-broker login "$p"
      else
        printf 'not a terminal - run this yourself, it opens a browser:\n\n  omp auth-broker login %s\n\n' "$p"
        printf 'then: cel gateway status\n'
      fi ;;
    logout)
      local p="${1:-}" id="${2:-}"
      [ -n "$p" ] || die "cel gateway logout: name a provider and a credential id (cel gateway status)"
      _gateway_omp auth-broker logout "$p" ${id:+"$id"} ;;
    help|-h|--help) _gateway_usage ;;
    *) c_err "cel gateway: unknown verb '$verb'"; echo; _gateway_usage; return 2 ;;
  esac
}
