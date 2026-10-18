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
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/config.sh
. "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/services.sh
. "${BASH_SOURCE[0]%/*}/services.sh"   # svc_box_write, svc_start

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
#
# The catalog every client but omp sees: ids published only because an
# account carries the omp prefix (CEL-136, `omp/<model>`) are omp's and are
# dropped here, so pi's models.json, the reviewer catalog and doctor read
# exactly the catalog they read before any account was prefixed.
gateway_models_json() {
  local js; js="$(_gateway_models_json_raw)" || return 1
  [ -n "$js" ] || return 1
  jq -c --arg p "$GATEWAY_OMP_PREFIX/" \
    'if (.data | type) == "array" then .data |= map(select((.id // "") | startswith($p) | not)) else . end' \
    <<<"$js" 2>/dev/null
}
_gateway_models_json_raw() {
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
_gateway_claude_cli_version() {
  local output
  output="$(claude --version 2>/dev/null)" || return 1
  if [[ "$output" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

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
# checked against CLIProxyAPI 7.3.14's config struct, and again against
# 8.0.29's (CEL-135): v8 still reads this legacy layout as written and does
# not rewrite it on load - only a v8 management-API config write migrates the
# file to the v8 layout. allow-remote: false is
# what keeps it on this machine - the panel is reached over an ssh tunnel
# (cel gateway panel), never on the tailnet. CLIProxyAPI hashes a plaintext
# secret-key in place on load; the plaintext stays in the 0600 key file.
remote-management:
  allow-remote: false
  secret-key: "$(_gateway_mgmt_key)"
  disable-control-panel: false
EOS
  } > "$tmp"
  local claude_version; claude_version="$(_gateway_claude_cli_version || true)"
  if [ -n "$claude_version" ]; then
    cat >> "$tmp" <<EOF

# Match the installed Claude Code version for Opus model routing.
claude-header-defaults:
  user-agent: "claude-cli/$claude_version (external, cli)"
EOF
  fi
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

# pi's agent dir. An AMBIENT PI_CODING_AGENT_DIR is deliberately not read here:
# omp exports that same variable for itself, so a pane that ever ran an omp
# launch carries omp's root, and every later pi launched from it put its
# sessions in omp's tree - where omp's startup then renamed them from under the
# live process (2026-10-17, two live workers). A custom pi-only root is
# an explicit choice, spelled CEL_PI_AGENT_DIR (the twin of CEL_OMP_AGENT_DIR).
# Every consumer - the models writer, the child's environment, doctor - asks
# this function, and the child is always handed the answer.
gateway_pi_dir() { _agent_root_abs "${CEL_PI_AGENT_DIR:-$HOME/.pi/agent}"; }

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
# The profile prefix and models.json provider keys are derived from the same
# helper; Claude's Anthropic endpoint is a distinct pi provider.
#
# CODEX IS A THIRD BLOCK (AH-261018). Chat Completions is not Codex's protocol:
# its models are served by the gateway's OpenAI RESPONSES surface (POST
# /v1/responses, /v1/responses/compact for compaction, and the Responses
# websocket upgrade on the same path - CLIProxyAPI 8.0.29), and pi and omp
# both speak `openai-responses`. Sending them through `openai-completions`
# silently dropped compaction, reasoning items and the websocket transport,
# and the launch id the profile produced (`ompgw/codex/gpt-5.5`) was not even
# a model models.json listed. The family test is on the BARE id so versioned
# ids (`gpt-5.5-codex`, `gpt-5.6-2026-10-01`, `codex-mini-latest`) are found by
# discovery, never by a hand-kept list.
GATEWAY_CODEX_ID_RE='^(gpt-|codex-|o[0-9])'
gateway_codex_bare_id() { # <any spelling of a codex model id> -> the id the gateway publishes
  local id="$1"
  id="${id#ompgw/}"; id="${id#ompgw-codex/}"; id="${id#celgw-codex/}"
  id="${id#openai-codex/}"; id="${id#codex/}"; id="${id#openai/}"
  printf '%s' "$id"
}
gateway_codex_model_p() { # <model id> - 0 when it names a Codex-family model
  case "$(gateway_codex_bare_id "$1")" in gpt-*|codex-*|o[0-9]*) return 0 ;; esac
  return 1
}
gateway_pi_provider_for_model() { # <model id>
  case "${1#ompgw/}" in claude/*|claude-*) printf 'ompgw-claude'; return 0 ;; esac
  if gateway_codex_model_p "$1"; then printf 'ompgw-codex'; else printf 'ompgw'; fi
}

# apiKey and the session header are written as VARIABLE NAMES. pi expands them
# from the pane's environment at launch, so no key and no session id is ever
# in this file.

# This exact configured ID mirrors Pi 1.2.0's canonical Anthropic entry.
# Unknown IDs never inherit its capabilities by prefix.
# CONCURRENT LAUNCHES AND A REFRESH PUBLISH INTO ONE FILE. read -> merge -> rename
# without a lock loses one writer's update. Every models writer therefore runs
# its whole read-merge-rename under an exclusive flock on a sibling `<file>.lock`,
# on the SYMLINK-RESOLVED path (the rename must replace the target, not the
# link) and keeps the existing file's mode.
_gateway_locked_publish() { # <file> <function> <args...> - function gets <real path> first
  local f="$1" fn="$2" real; shift 2
  real="$(readlink -f "$f" 2>/dev/null)" || real="$f"
  [ -n "$real" ] || real="$f"
  mkdir -p "$(dirname "$real")" || return 1
  ( flock -x 9 || exit 1; "$fn" "$real" "$@" ) 9>"$real.lock"
}

gateway_pi_models_write() { # [models.json path]
  local f="${1:-$(gateway_pi_dir)/models.json}" models tmp
  models="$(gateway_models_json | jq -c --arg re "$GATEWAY_CODEX_ID_RE" '
    # Native Claude 5.5 capabilities. The gateway publishes bare ids, so
    # without this the generic 128000/8192 fallback would cap the window and
    # output and drop adaptive thinking.
    def configured_opus_metadata:
      if .id == "claude-opus-5-5" or .id == "claude-sonnet-5-5" then
        . + { contextWindow: 1000000, maxTokens: 128000, input: ["text", "image"],
              reasoning: true,
              thinkingLevelMap: { off: null, minimal: null, low: "low", medium: "medium",
                                  high: "high", xhigh: "xhigh", max: "max" },
              compat: { supportsMidConvoEffort: true, supportsMidConvoSystemMessages: true,
                        supportsMidConvoToolChanges: true, forceAdaptiveThinking: true,
                        supportsTemperature: false, supportsStrictTools: true } }
      else .
      end;
    # HONEST CODEX METADATA: a field is written only when the gateway
    # catalog states it. No invented window, no assumed reasoning support, no
    # level map for levels the catalog did not advertise.
    def codex_metadata:
      { id: .id }
      + (if .context_length then { contextWindow: .context_length } else {} end)
      + (if .max_output_tokens then { maxTokens: .max_output_tokens } else {} end)
      + (if ((.thinking.levels // []) | length) > 0
         then { reasoning: true,
                thinkingLevelMap: ([.thinking.levels[] | { key: ., value: . }] | from_entries) }
         else {} end);
    [ (.data // [])[]
      | if (.id | test($re)) then (codex_metadata | . + { codex: true })
        else ({
          id: .id,
          contextWindow: (.context_length // 128000),
          maxTokens: (.max_output_tokens // 8192) } | configured_opus_metadata)
        end
    ]' 2>/dev/null || true)"
  [ -n "$models" ] || return 1
  _gateway_locked_publish "$f" _gateway_pi_publish "$models"
}

# The read-merge-rename of the shared models.json, run UNDER the file lock with
# the symlink-resolved path (see _gateway_locked_publish).
_gateway_pi_publish() { # <real path> <models json>
  local f="$1" models="$2" tmp
  [ -f "$f" ] || ( umask 077; printf '{"providers":{}}' > "$f" )
  tmp="$(mktemp "$(dirname "$f")/.models.XXXXXX")"
  local claude_provider; claude_provider="$(gateway_pi_provider_for_model claude-sonnet-4-6)"
  # NON-DESTRUCTIVE BY DEFAULT (AH-261018). This writer runs at every gateway
  # launch, workers and reviewers alike, against ONE shared models.json that
  # live sessions have already read. Replacing a provider's model list rewrote
  # capability metadata under running sessions (thinking maps, windows the
  # owner or a repair tuned). So a launch ADDS ids that are missing and leaves
  # every model entry that already exists exactly as it is (existing fields
  # win); ids no longer published are kept, not deleted. Only an explicit
  # refresh (cel gateway refresh / cel update, GATEWAY_PI_WRITE=refresh) lets the
  # catalog's fields win - and even then nothing is removed. A write that would
  # change nothing is skipped entirely: no temp file, no rename, no mtime churn.
  local refresh=false; [ "${GATEWAY_PI_WRITE:-launch}" = refresh ] && refresh=true
  jq --argjson models "$models" --arg url "$(gateway_url)/v1" --arg root "$(gateway_url)" --arg claude_provider "$claude_provider" --argjson refresh "$refresh" '
    def mm($old; $new):
      [ $new[] | . as $x | (($old // []) | map(select(.id == $x.id)) | .[0]) as $e
        | if $e == null then $x elif $refresh then $e + $x else $x + $e end ]
      + [ ($old // [])[] | select(.id as $i | ($new | map(.id) | index($i)) | not) ];
    ([$models[] | select(.codex == true) | del(.codex)]) as $codex
    | ([$models[] | select(.codex != true) | select(.id | test("^claude"))]) as $claude
    | ([$models[] | select(.codex != true) | select(.id | test("^claude") | not)]) as $rest
    | (.providers // {}) as $cur
    | .providers = ($cur + {
        ompgw: {
          name: "cel gateway",
          baseUrl: $url,
          apiKey: "$OMP_GATEWAY_TOKEN",
          api: "openai-completions",
          headers: { "x-session-id": "$CEL_SESSION_ID" },
          models: mm($cur.ompgw.models; $rest) },
        "ompgw-codex": {
          name: "cel gateway (codex, responses)",
          baseUrl: $url,
          apiKey: "$OMP_GATEWAY_TOKEN",
          api: "openai-responses",
          headers: { "x-session-id": "$CEL_SESSION_ID" },
          models: mm($cur["ompgw-codex"].models; $codex) },
        ($claude_provider): {
          name: "cel gateway (anthropic)",
          baseUrl: $root,
          apiKey: "$OMP_GATEWAY_TOKEN",
          api: "anthropic-messages",
          headers: { "x-session-id": "$CEL_SESSION_ID" },
          models: mm($cur[$claude_provider].models; $claude) } })' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ "$(jq -cS . "$tmp")" = "$(jq -cS . "$f")" ]; then rm -f "$tmp"; return 0; fi
  chmod --reference="$f" "$tmp" 2>/dev/null || true
  mv "$tmp" "$f"
}

# Is <provider>/<id> (the spelling a launch line carries) in pi's models.json?
gateway_pi_registered() { # <provider/id> [models.json]
  local m="$1" f="${2:-$(gateway_pi_dir)/models.json}"
  [ -s "$f" ] || return 1
  jq -e --arg p "${m%%/*}" --arg id "${m#*/}" \
    '[.providers[$p].models[]? | select(.id == $id)] | length > 0' "$f" >/dev/null 2>&1
}

# --- the omp provider (CEL-136) -------------------------------------------
#
# omp's orchestrator reaches the gateway through ONE scoped pool: the claude
# accounts that carry CLIProxyAPI's per-credential `prefix: omp`. A prefixed
# account publishes `omp/<model>` beside its plain ids, a request for
# `omp/<model>` is served ONLY by prefixed accounts, and plain ids keep the
# whole vault - so other clients' pool is unchanged and `force-model-prefix`
# stays false. The personal account never carries the prefix, so omp can
# never be routed to it: an exhausted pool answers 429, it does not widen.
#
# The prefix is set THROUGH THE RUNNING GATEWAY (management PATCH
# /v0/management/auth-files/fields). CLIProxyAPI rewrites these files itself
# on every token refresh and keeps metadata it does not own across the
# rewrite; its PATCH serialises with that. A second writer on the vault is
# how a refresh would quietly drop the prefix or a token.
GATEWAY_OMP_PREFIX=omp
GATEWAY_OMP_PROVIDER=celgw

# omp's agent dir. omp reads PI_CODING_AGENT_DIR exactly as pi does, so an omp
# pane is pinned to this dir explicitly - otherwise a pi-oriented export would
# hand omp pi's directory and its models.yml would be written where omp never
# looks.
gateway_omp_dir() { _agent_root_abs "${CEL_OMP_AGENT_DIR:-$HOME/.omp/agent}"; }

# A root is pinned into the child by value, and the child runs in another cwd
# (a worktree): a relative root would mean a different directory there. Make it
# absolute against the launcher's cwd here, lexically (symlinks are resolved
# only by the overlap check, so the pinned path stays what the owner wrote).
_agent_root_abs() {
  case "$1" in /*) printf '%s' "$1" ;; *) realpath -m -s -- "$1" 2>/dev/null || printf '%s/%s' "$PWD" "$1" ;; esac
}

# pi and omp must never share session storage. omp's startup migrates every
# pi-style `--home-...--` directory under its root to a short name, with no
# liveness check, and pi never re-creates a vanished directory. So the two
# resolved roots, with symlinks and `..` resolved, must be disjoint: neither
# equal to the other nor inside it. Refuses; never moves, copies or rewrites.
_agent_root_real() { realpath -m -- "$1" 2>/dev/null || printf '%s' "$1"; }
agent_roots_check() { # [runtime]: 0 when disjoint, 1 with an actionable message
  local pi omp
  pi="$(_agent_root_real "$(gateway_pi_dir)")"; omp="$(_agent_root_real "$(gateway_omp_dir)")"
  case "$pi/" in "$omp"/*) ;; *) case "$omp/" in "$pi"/*) ;; *) pi="" ;; esac ;; esac
  if [ -z "$pi" ]; then
    # an ambient value that is not the resolved one is ignored, not obeyed
    if [ -n "${PI_CODING_AGENT_DIR:-}" ] && [ "${1:-}" = pi ] \
       && [ "$(_agent_root_real "$PI_CODING_AGENT_DIR")" != "$(_agent_root_real "$(gateway_pi_dir)")" ]; then
      printf 'note: ignoring inherited PI_CODING_AGENT_DIR (%s): pi uses %s. For a custom pi-only root set CEL_PI_AGENT_DIR.\n' \
        "$PI_CODING_AGENT_DIR" "$(gateway_pi_dir)" >&2
    fi
    return 0
  fi
  printf 'agent roots overlap: pi would use %s and OMP uses %s (after resolving symlinks). OMP renames pi-style session directories under its root when it starts, which silently breaks a running pi. Give pi its own directory: unset CEL_PI_AGENT_DIR (default %s) or point it somewhere that is not inside OMP'"'"'s root. Nothing was moved or changed.\n' \
    "$(_agent_root_real "$(gateway_pi_dir)")" "$(_agent_root_real "$(gateway_omp_dir)")" "$HOME/.pi/agent" >&2
  return 1
}

# The identities omp must never be served by: `gateway.omp_exclude` in the box
# config, comma- or space-separated. Lowercased; never printed.
_gateway_omp_exclusions() {
  cel_config_get gateway omp_exclude | tr 'A-Z,' 'a-z ' | tr -s ' ' '\n' | sed '/^$/d'
}

# One row per claude credential: { file, id, excluded, prefix, action }.
# action: add (pool account, unprefixed), keep (pool, prefixed), remove
# (EXCLUDED but prefixed - in omp's pool right now), none (excluded,
# unprefixed) or foreign (some other prefix - not ours, left alone).
# An account is excluded when an excluded address is in its filename OR
# anywhere in its JSON, so a renamed file cannot slip in. FAILS CLOSED with no
# exclusion configured: the pool would then be every claude account.
#
# Owner opt-in: `gateway.omp_include_all: true` (the literal word, nothing
# else) permits an EMPTY exclusion list, so every claude account - personal
# included - joins the omp pool. Precedence: configured exclusions ALWAYS win;
# the opt-in only lifts the empty-list refusal. Absent or any other value
# (yes, 1, on, typos) keeps the fail-closed refusal.
_gateway_omp_include_all() { [ "$(cel_config_get gateway omp_include_all)" = true ]; }

gateway_omp_scope_plan() {
  local ex; ex="$(_gateway_omp_exclusions)"
  if [ -z "$ex" ] && ! _gateway_omp_include_all; then
    c_err "no gateway.omp_exclude in $(cel_config_file) - the omp-scoped pool would include every claude account; set it to the personal address(es) first"
    return 1
  fi
  local d f base rows="" excluded e lc
  d="$(gateway_auth_dir)"
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$(jq -r '.type // empty' "$f" 2>/dev/null)" in
      claude) ;;
      "") case "$base" in claude-*) ;; *) continue ;; esac ;;
      *) continue ;;
    esac
    lc="$(printf '%s ' "$base"; jq -c . "$f" 2>/dev/null)"
    lc="$(printf '%s' "$lc" | tr 'A-Z' 'a-z')"
    excluded=false
    if [ -n "$ex" ]; then
      while IFS= read -r e; do
        case "$lc" in *"$e"*) excluded=true ;; esac
      done <<<"$ex"
    fi
    rows="$rows$(jq -c --arg file "$base" --argjson ex "$excluded" --arg want "$GATEWAY_OMP_PREFIX" '
      (.prefix // "") as $p
      | ($file | sub("^claude-"; "") | .[0:6]) as $id
      | { file: $file, id: $id, excluded: $ex, prefix: $p,
          action: (if $ex then (if $p == $want then "remove" else "none" end)
                   elif $p == $want then "keep" elif $p == "" then "add" else "foreign" end) }' "$f")
"
  done
  printf '%s' "$rows" | jq -sc '.'
}

# Prefixed pool accounts serving omp now.
gateway_omp_scoped_count() {
  local plan; plan="$(gateway_omp_scope_plan 2>/dev/null)" || { printf 0; return 1; }
  jq '[.[] | select(.action == "keep")] | length' <<<"$plan"
}

# Pass: an exclusion is configured (or the owner opted in with
# gateway.omp_include_all: true) and no excluded account carries the prefix.
gateway_omp_scope_check() {
  local plan; plan="$(gateway_omp_scope_plan)" || return 1
  local bad; bad="$(jq -r '[.[] | select(.action == "remove") | .id] | join(" ")' <<<"$plan")"
  if [ -n "$bad" ]; then
    c_err "excluded claude account(s) $bad carry the '$GATEWAY_OMP_PREFIX' prefix - cel gateway omp-scope --apply"
    return 1
  fi
  return 0
}

# One management PATCH per change, key on stdin. Excluded accounts are only
# ever UN-prefixed; nothing outside claude is touched.
gateway_omp_scope_apply() {
  local plan; plan="$(gateway_omp_scope_plan)" || return 1
  local mk; mk="$(_gateway_mgmt_key)"
  [ -n "$mk" ] || { c_err "no management key - cel gateway install"; return 1; }
  local row file id action want body rc=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    file="$(jq -r .file <<<"$row")"; id="$(jq -r .id <<<"$row")"; action="$(jq -r .action <<<"$row")"
    case "$action" in add) want="$GATEWAY_OMP_PREFIX" ;; remove) want="" ;; *) continue ;; esac
    body="$(jq -nc --arg n "$file" --arg p "$want" '{name: $n, prefix: $p}')"
    if printf 'Authorization: Bearer %s\n' "$mk" \
        | curl -sf -m 10 -X PATCH -H @- -H 'Content-Type: application/json' \
            -d "$body" "$(gateway_url)/v0/management/auth-files/fields" >/dev/null 2>&1; then
      c_ok "claude $id: $action prefix '$GATEWAY_OMP_PREFIX'"
    else
      c_err "claude $id: management PATCH failed (is the gateway up? cel gateway status)"; rc=1
    fi
  done < <(jq -c '.[]' <<<"$plan")
  return "$rc"
}

# omp's own resolved catalog for one provider, read-only from its models.db.
# The thinking MODE is only here (`omp models --json` flattens it to levels),
# and copying it is what keeps the profile's thinking level meaning the same
# thing through the gateway as it does direct. `anthropic` for the Claude
# block, `openai-codex` for the Codex block.
# CEL_OMP_CATALOG_FILE / CEL_OMP_CODEX_CATALOG_FILE are TEST SEAMS (the file
# stands in for the database), honoured only under CEL_TESTING.
gateway_omp_catalog_json() { # [provider-id: anthropic|openai-codex]
  local prov="${1:-anthropic}" seam=""
  if [ -n "${CEL_TESTING:-}" ]; then
    case "$prov" in
      anthropic) seam="${CEL_OMP_CATALOG_FILE:-}" ;;
      openai-codex) seam="${CEL_OMP_CODEX_CATALOG_FILE:-}" ;;
    esac
    [ -z "$seam" ] || { cat "$seam"; return; }
  fi
  local db; db="$(gateway_omp_dir)/models.db"
  [ -f "$db" ] || return 1
  python3 - "$db" "$prov" <<'PY' 2>/dev/null
import json, sqlite3, sys
c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
r = c.execute("select models from model_cache where provider_id = ?", (sys.argv[2],)).fetchone()
if not r:
    sys.exit(1)
print(json.dumps(json.loads(r[0])))
PY
}

# Merge the gateway's providers into omp's models.yml (omp 18.11 schema):
#   celgw        Claude, one model per `omp/<id>` the gateway publishes AND
#                omp's catalog describes - an id with no metadata is dropped,
#                never given another model's (the omp-scoped pool).
#   celgw-codex  Codex over `openai-responses` (AH-261018), every Codex-family
#                id the gateway publishes, versioned ids included. Metadata is
#                omp's own catalog entry when it has one for the EXACT id, else
#                only what the gateway catalog states - nothing is borrowed
#                from a neighbouring model.
# apiKey and the session header are ENV NAMES, resolved by omp in the pane.
# A block with no models is not written; the call fails only when NOTHING could
# be registered, so a gateway that has Codex and no Claude pool yet still
# registers Codex.
gateway_omp_models_write() { # [models.yml] [catalog json file] [codex catalog json file]
  local f="${1:-$(gateway_omp_dir)/models.yml}" cat_file="${2:-}" codex_file="${3:-}"
  local raw catalog codex_catalog claude_block codex_block tmp cur n_claude n_codex
  raw="$(_gateway_models_json_raw)" || return 1
  if [ -n "$cat_file" ]; then catalog="$(cat "$cat_file")"; else catalog="$(gateway_omp_catalog_json anthropic || true)"; fi
  if [ -n "$codex_file" ]; then codex_catalog="$(cat "$codex_file")"; else codex_catalog="$(gateway_omp_catalog_json openai-codex || true)"; fi
  [ -n "$codex_catalog" ] || codex_catalog='[]'
  claude_block='{"models":[]}'
  if [ -n "$catalog" ]; then
    claude_block="$(jq -c --argjson cat "$catalog" --arg p "$GATEWAY_OMP_PREFIX/" --arg url "$(gateway_url)" '
      ($cat | map({key: .id, value: .}) | from_entries) as $byid
      | [ (.data // [])[] | .id | select(startswith($p + "claude"))
          | . as $full | ($full | ltrimstr($p)) as $id | $byid[$id] | select(. != null)
          | { id: $full }
            + (with_entries(select(.key | IN("name","reasoning","input","contextWindow","maxTokens","cost","tokenizer"))))
            + (if .thinking then {thinking: (.thinking | with_entries(select(.key | IN("mode","efforts","supportsDisplay"))))} else {} end) ]
      | { name: "cel gateway (omp-pool)", baseUrl: $url, api: "anthropic-messages",
          apiKey: "OMP_GATEWAY_TOKEN", headers: { "x-session-id": "CEL_SESSION_ID" },
          models: . }' <<<"$raw")" || return 1
  fi
  codex_block="$(jq -c --argjson cat "$codex_catalog" --arg re "$GATEWAY_CODEX_ID_RE" --arg url "$(gateway_url)/v1" '
    ($cat | map({key: .id, value: .}) | from_entries) as $byid
    | [ (.data // [])[] | select(.id | test($re)) | . as $g
        | { id: $g.id }
          + (if $byid[$g.id] then ($byid[$g.id] | with_entries(select(.key | IN("name","reasoning","input","contextWindow","maxTokens","cost","thinking"))))
             else ((if $g.context_length then { contextWindow: $g.context_length } else {} end)
                   + (if $g.max_output_tokens then { maxTokens: $g.max_output_tokens } else {} end)
                   + (if (($g.thinking.levels // []) | length) > 0 then { reasoning: true } else {} end)) end) ]
    | { name: "cel gateway (codex, responses)", baseUrl: $url, api: "openai-responses",
        apiKey: "OMP_GATEWAY_TOKEN", headers: { "x-session-id": "CEL_SESSION_ID" },
        models: . }' <<<"$raw")" || return 1
  n_claude="$(jq '.models | length' <<<"$claude_block")"
  n_codex="$(jq '.models | length' <<<"$codex_block")"
  if [ "$n_claude" -eq 0 ] && [ "$n_codex" -eq 0 ]; then
    if [ -z "$catalog" ]; then
      c_err "no anthropic catalog in $(gateway_omp_dir)/models.db - omp's catalog is built the first time it starts"
    else
      c_err "the gateway publishes no omp/claude model in omp's catalog and no Codex model - cel gateway omp-scope"
    fi
    return 1
  fi
  _gateway_locked_publish "$f" _gateway_omp_publish "$claude_block" "$codex_block" "$n_claude" "$n_codex"
}

# omp's read-merge-rename, under the file lock. NON-DESTRUCTIVE like pi's writer:
# existing model entries keep their fields and ids no longer published are kept;
# only GATEWAY_PI_WRITE=refresh lets the catalog's fields win (nothing is ever
# removed). Provider-level fields (name, baseUrl, api, apiKey, headers) are the
# plane's and are rewritten.
_gateway_omp_publish() { # <real path> <claude block> <codex block> <n claude> <n codex>
  local f="$1" claude_block="$2" codex_block="$3" n_claude="$4" n_codex="$5" cur tmp refresh=false
  [ "${GATEWAY_PI_WRITE:-launch}" = refresh ] && refresh=true
  cur='{}'; [ -s "$f" ] && cur="$(yq -c '. // {}' "$f")"
  tmp="$(mktemp "$(dirname "$f")/.models.XXXXXX")"
  jq --argjson c "$claude_block" --argjson x "$codex_block" --arg k "$GATEWAY_OMP_PROVIDER" --argjson nc "$n_claude" --argjson nx "$n_codex" --argjson refresh "$refresh" '
      def mm($old; $new):
        [ $new[] | . as $e0 | (($old // []) | map(select(.id == $e0.id)) | .[0]) as $e
          | if $e == null then $e0 elif $refresh then $e + $e0 else $e0 + $e end ]
        + [ ($old // [])[] | select(.id as $i | ($new | map(.id) | index($i)) | not) ];
      def blk($key; $b): (.providers[$key] // {}) as $o | ($o + ($b | del(.models)) + { models: mm($o.models; $b.models) });
      .providers = ((.providers // {})
        + (if $nc > 0 then {($k): blk($k; $c)} else {} end)
        + (if $nx > 0 then {($k + "-codex"): blk($k + "-codex"; $x)} else {} end))' <<<"$cur" \
    | yq -y . >"$tmp" || { rm -f "$tmp"; return 1; }
  # unchanged => no write (the file is shared with live sessions)
  if [ -s "$f" ] && [ "$(yq -cS . "$tmp")" = "$(yq -cS . "$f")" ]; then rm -f "$tmp"; return 0; fi
  chmod --reference="$f" "$tmp" 2>/dev/null || true
  mv "$tmp" "$f"
}

# Is <provider>/<id> (the launch spelling) registered in omp's models.yml?
gateway_omp_registered() { # <provider/id> [models.yml]
  local m="$1" f="${2:-$(gateway_omp_dir)/models.yml}"
  [ -s "$f" ] || return 1
  yq -e --arg p "${m%%/*}" --arg id "${m#*/}" \
    '[.providers[$p].models[]? | select(.id == $id)] | length > 0' "$f" >/dev/null 2>&1
}

_gateway_omp_scope_cmd() { # [--check|--apply|--json]
  case "${1:-}" in
    --check) gateway_omp_scope_check && c_ok "omp-pool: $(gateway_omp_scoped_count) claude account(s), no excluded account prefixed" ;;
    --apply) gateway_omp_scope_apply ;;
    --json)  gateway_omp_scope_plan | jq -c 'map(del(.file))' ;;
    "")
      local plan; plan="$(gateway_omp_scope_plan)" || return 1
      jq -r '.[] | "  claude \(.id)  \(if .excluded then "excluded" else "pool" end)  prefix=\(if .prefix == "" then "-" else .prefix end)  -> \(.action)"' <<<"$plan" ;;
    *) die "cel gateway omp-scope: unknown option '$1' (--check, --apply, --json)" ;;
  esac
}

# --- refresh after `cel update` (AH-261018) -------------------------------
#
# Re-applies everything the plane writes for the gateway, whether or not
# Celestial's own git moved: the proxy config (it carries the installed Claude
# Code version for header matching, which an agent update changes), the box
# service entry, pi's models.json and omp's models.yml (so a gateway catalog
# that gained a versioned Codex id is registered), and the agent-root
# invariant. Idempotent: the api-key and management key are minted once and
# never rolled, unrelated providers in the owner's files are preserved, no
# credential is read or written, nothing is restarted - CLIProxyAPI reloads
# its config file on change. Returns non-zero when anything that SHOULD have
# been registered was not, and says which.
gateway_refresh() {
  gateway_installed || { c_ok "gateway: not installed on this box - nothing to refresh"; return 0; }
  local rc=0
  if _gateway_config_write; then c_ok "gateway: config rewritten ($(gateway_config_file))"
  else c_err "gateway: could not rewrite $(gateway_config_file)"; rc=1; fi
  _gateway_register_services || rc=1
  if have cli-proxy-api; then
    c_ok "gateway: $(cli-proxy-api -h 2>&1 | sed -n 's/^CLIProxyAPI Version: \([^,]*\),.*/cli-proxy-api \1/p' | head -1) (pinned by agents.yaml base_tools; cel setup owns it)"
  fi
  agent_roots_check >/dev/null 2>&1 || { c_err "gateway: pi and OMP agent roots overlap - $(agent_roots_check 2>&1 >/dev/null | head -1)"; rc=1; }
  if ! gateway_ready; then
    c_err "gateway: installed but not answering on $(gateway_url) - models were NOT re-registered (cel gateway status)"
    return 1
  fi
  if have pi || [ -d "$(gateway_pi_dir)" ]; then
    if GATEWAY_PI_WRITE=refresh gateway_pi_models_write; then c_ok "gateway: pi models registered ($(gateway_pi_dir)/models.json)"
    else c_err "gateway: pi models could not be registered - cel gateway status"; rc=1; fi
  fi
  if have "omp" || [ -d "$(gateway_omp_dir)" ]; then
    if gateway_omp_models_write; then c_ok "gateway: OMP models registered ($(gateway_omp_dir)/models.yml)"
    else c_warn "gateway: OMP models not registered - OMP builds its catalog the first time it starts, or the gateway publishes nothing for it (cel gateway omp-scope --check)"; fi
  fi
  return "$rc"
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
  cel gateway refresh                re-apply config, service and pi/OMP model
                                     registrations (cel update runs this)
  cel gateway status [--json]        the door, and one row per account
  cel gateway login <provider>       sign another subscription in
                                     --no-browser: device flow, headless box
  cel gateway logout <provider> <id> drop one account from the vault
  cel gateway panel [--json]         the web panel's loopback URL, and the
                                     ssh tunnel that reaches it from a laptop
  cel gateway omp-scope [--check|--apply|--json]
                                     omp's scoped claude pool: prefix every
                                     account but gateway.omp_exclude, via the
                                     running gateway's management API; an
                                     empty exclusion list is refused unless
                                     gateway.omp_include_all: true
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
    omp-scope) _gateway_omp_scope_cmd "$@" ;;
    refresh) gateway_refresh ;;
    help|-h|--help) _gateway_usage ;;
    *) c_err "cel gateway: unknown verb '$verb'"; echo; _gateway_usage; return 2 ;;
  esac
}
