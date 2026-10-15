#!/usr/bin/env bash
# CEL-136 - the omp -> CLIProxyAPI route, end to end, spending nothing.
#
#   bash tests/live/omp-gateway.sh [path/to/cli-proxy-api]
#
# NOT part of tests/run.sh (CI has neither binary). It runs the REAL
# cli-proxy-api and the REAL omp on this box against a scratch gateway on
# private loopback ports, with junk tokens and synthetic Anthropic upstreams
# (tests/live/fake_anthropic.py). The live gateway, its vault and the box
# services are never touched; nothing printed is a key, token or identity.
#
# NOTHING LEAVES THE BOX. CLIProxyAPI sends a claude OAuth FILE credential to
# api.anthropic.com whatever its JSON says (only kimi honours a file
# base_url), so the scratch config pins `proxy-url` to a dead loopback port:
# a file-vault request fails locally after the balancer has PICKED an
# account, and the pick is read from the gateway's own log.
#
# Phase 1 - the file vault, as on the box:
#   T2 eligibility  gateway_omp_scope_apply prefixes the pool through the real
#                   management API, never the excluded account
#   T3 selection    real omp -> gateway: omp/<model> is only ever bound to
#                   pool accounts; plain ids (other clients) still reach the
#                   personal one
# Phase 2 - the same prefix on `claude-api-key` entries, whose base-url CAN
# point at a synthetic upstream, for the bytes:
#   T1 transport    omp's celgw provider (gateway_omp_models_write) talks to
#                   the gateway with the CLIProxyAPI key; reply comes back
#   T4 routing      0 personal hits, upstream model unprefixed, thinking level
#                   carried; pool exhausted -> 429, still 0 personal hits
#   T5 session      omp sends x-session-id from CEL_SESSION_ID (captured)
# Exit 0 = every check passed, 1 = a check failed, 2 = not runnable here.
set -uo pipefail

CEL_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
export CEL_ROOT
BIN="${1:-$(command -v cli-proxy-api || true)}"
HERE="$CEL_ROOT/tests/live"
for need in "$BIN" omp python3 jq yq curl; do
  [ -n "$need" ] && command -v "$need" >/dev/null 2>&1 || { echo "NOT RUN: $need missing"; exit 2; }
done
OMP_CATALOG_DB="${OMP_CATALOG_DB:-$HOME/.omp/agent/models.db}"
[ -f "$OMP_CATALOG_DB" ] || { echo "NOT RUN: no omp catalog at $OMP_CATALOG_DB (start omp once)"; exit 2; }

W="$(mktemp -d)"; chmod 700 "$W"
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; [ -n "${CEL_LIVE_KEEP:-}" ] && echo "kept: $W" || rm -rf "$W"; }
trap cleanup EXIT

# Scratch everything cel reads: config, gateway state, omp's agent dir, HOME.
export CEL_CONFIG_FILE="$W/config.yaml" CEL_GATEWAY_STATE="$W/gw" CEL_OMP_AGENT_DIR="$W/omp"
unset CEL_GATEWAY_STUB
mkdir -p "$W/gw/auth" "$W/omp" "$W/home"; chmod 700 "$W/gw" "$W/gw/auth"
# omp's catalog, COPIED read-only: this run must not write the owner's db.
cp "$OMP_CATALOG_DB" "$W/omp/models.db"
# shellcheck source=/dev/null
for f in common config gateway; do source "$CEL_ROOT/lib/$f.sh"; done

FAIL=0
check() { # <label> <bool-cmd...>
  local label="$1"; shift
  if "$@" >/dev/null; then echo "  ok   $label"; else echo "  FAIL $label"; FAIL=1; fi
}
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
PORT="$(free_port)"; UP_P="$(free_port)"; UP_A="$(free_port)"; UP_B="$(free_port)"
LOG="$W/up.log"; : >"$LOG"

cel_config_set gateway port "$PORT"
cel_config_set gateway omp_exclude "me@personal.invalid"
_gateway_config_write
KEY="$(_gateway_api_key)"
export FAKE_EXPECT_KEY="$KEY"
CFG1="$W/phase1.yaml"
yq -y '.["proxy-url"] = "http://127.0.0.1:9"' "$(gateway_config_file)" >"$CFG1"; chmod 600 "$CFG1"

gw_pid=""
gw_start() { # <config>
  gw_stop
  "$BIN" --config "$1" >>"$W/gw.log" 2>&1 & gw_pid=$!; pids+=($gw_pid)
  for _ in $(seq 1 50); do gateway_ready && return 0; sleep 0.2; done
  echo "NOT RUN: scratch gateway did not start"; tail -5 "$W/gw.log"; exit 2
}
gw_stop() { [ -z "$gw_pid" ] || { kill "$gw_pid" 2>/dev/null; wait "$gw_pid" 2>/dev/null; gw_pid=""; }; }
mark() { wc -l <"$W/gw.log"; }
since() { tail -n +"$(( $1 + 1 ))" "$W/gw.log"; }
omp_ask() { # <model> <thinking> <session>
  CEL_SESSION_ID="$3" OMP_GATEWAY_TOKEN="$KEY" PI_CODING_AGENT_DIR="$W/omp" HOME="$W/home" \
    timeout 90 omp -p --no-session --model "$1" --thinking "$2" "say pong" >"$W/omp.out" 2>&1
}
curl_ask() { # <model> <session>  -> http code
  printf 'x-api-key: %s\n' "$KEY" | curl -s -m 20 -o /dev/null -w '%{http_code}' -H @- \
    -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -H "x-session-id: $2" \
    -d "{\"model\":\"$1\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
    "$(gateway_url)/v1/messages"
}
# accounts the balancer bound or tried, from the gateway log lines after <mark>
picked() { since "$1" | grep -oE 'auth(_file)?=claude-[0-9]{8}' | sed 's/.*=claude-//' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}'; }
picked_n() { since "$1" | grep -oE "auth(_file)?=claude-$2" | wc -l | tr -d ' '; }

# ---- phase 1: a junk-token FILE vault shaped like the box's ----------------
cred() { # <file> <email>
  jq -n --arg e "$2" --arg x "$(date -d '+1 day' -Iseconds)" \
    '{type:"claude", email:$e, access_token:"cel136-live-invalid", expired:$x, disabled:false}' >"$W/gw/auth/$1"
  chmod 600 "$W/gw/auth/$1"
}
cred "claude-11111111-me@personal.invalid.json" "me@personal.invalid"
cred "claude-22222222-pool-a@example.invalid.json" "pool-a@example.invalid"
cred "claude-33333333-pool-b@example.invalid.json" "pool-b@example.invalid"
gw_start "$CFG1"

echo "T2 eligibility (file vault, management API)"
check "pool empty before apply" test "$(gateway_omp_scoped_count)" = 0
gateway_omp_scope_apply >/dev/null 2>&1; rc=$?
check "apply succeeded through PATCH /v0/management/auth-files/fields" test "$rc" = 0
sleep 1
check "2 pool accounts prefixed" test "$(gateway_omp_scoped_count)" = 2
check "personal account carries no prefix" \
  test "$(jq -r '.prefix // ""' "$W/gw/auth/claude-11111111-me@personal.invalid.json")" = ""
check "scope check passes" gateway_omp_scope_check
check "gateway publishes omp/claude-opus-5-5" \
  jq -e '[.data[].id] | index("omp/claude-opus-5-5") != null' <<<"$(_gateway_models_json_raw)"
check "other clients' catalog has no omp/ ids" \
  jq -e '[.data[].id | select(startswith("omp/"))] | length == 0' <<<"$(gateway_models_json)"
gateway_omp_models_write >/dev/null 2>&1; rc=$?
check "omp models.yml written from the live catalog" test "$rc" = 0
check "models.yml holds no key" bash -c '! grep -qF "$1" "$2"' _ "$KEY" "$W/omp/models.yml"
check "omp resolves celgw/omp/claude-opus-5-5 with thinking up to max" bash -c \
  'PI_CODING_AGENT_DIR="$1" HOME="$2" omp models celgw --json 2>/dev/null | jq -e ".models[] | select(.id == \"omp/claude-opus-5-5\") | .thinking | index(\"max\") != null" >/dev/null' \
  _ "$W/omp" "$W/home"

echo "T3 selection (real omp -> file vault; dead proxy, nothing leaves the box)"
m="$(mark)"
for s in a b c; do omp_ask celgw/omp/claude-opus-5-5 low "cel136-live-$s"; done
for i in 1 2 3 4 5 6; do curl_ask omp/claude-opus-5-5 "cel136-live-p$i" >/dev/null; done
echo "       omp/ picks: $(picked "$m")"
check "omp/ requests reached the balancer" test "$(( $(picked_n "$m" 22222222) + $(picked_n "$m" 33333333) ))" -gt 0
check "omp/ never picked the personal account" test "$(picked_n "$m" 11111111)" = 0
check "no request reached a real provider (no upstream auth answer)" \
  bash -c '! tail -n +"$(( $1 + 1 ))" "$2" | grep -qiE "invalid token|authentication_error"' _ "$m" "$W/gw.log"
m="$(mark)"
for i in 1 2 3 4 5 6; do curl_ask claude-opus-5-5 "cel136-live-q$i" >/dev/null; done
echo "       plain picks: $(picked "$m")"
check "plain ids (other clients) still reach the personal account" test "$(picked_n "$m" 11111111)" -gt 0
gw_stop

# ---- phase 2: the same prefix on api-key entries, synthetic upstreams ------
upstreams() { # <mode for the pool>
  local p; for p in "${up_pids[@]:-}"; do [ -z "$p" ] || kill "$p" 2>/dev/null || true; done
  up_pids=()
  python3 "$HERE/fake_anthropic.py" "$UP_P" personal ok "$LOG" & up_pids+=($!); pids+=($!)
  python3 "$HERE/fake_anthropic.py" "$UP_A" pool-a "$1" "$LOG" & up_pids+=($!); pids+=($!)
  python3 "$HERE/fake_anthropic.py" "$UP_B" pool-b "$1" "$LOG" & up_pids+=($!); pids+=($!)
  local port; for port in "$UP_P" "$UP_A" "$UP_B"; do
    for _ in $(seq 1 50); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done
  done
}
up_pids=()
hits() { jq -s --arg u "$1" '[.[] | select(.upstream == $u)] | length' "$LOG"; }
counts() { printf 'personal=%s pool-a=%s pool-b=%s' "$(hits personal)" "$(hits pool-a)" "$(hits pool-b)"; }
mkdir -p "$W/empty-auth"; chmod 700 "$W/empty-auth"
CFG2="$W/phase2.yaml"
UP_P="$UP_P" UP_A="$UP_A" UP_B="$UP_B" A="$W/empty-auth" yq -y '
  .["auth-dir"] = env.A | del(.["proxy-url"])
  | .["claude-api-key"] = [
      {"api-key": "cel136-live-pers", "base-url": ("http://127.0.0.1:" + env.UP_P),
       models: [{name: "claude-opus-5-5", alias: "claude-opus-5-5"}]},
      {"api-key": "cel136-live-a", "base-url": ("http://127.0.0.1:" + env.UP_A), prefix: "omp",
       models: [{name: "claude-opus-5-5", alias: "claude-opus-5-5"}]},
      {"api-key": "cel136-live-b", "base-url": ("http://127.0.0.1:" + env.UP_B), prefix: "omp",
       models: [{name: "claude-opus-5-5", alias: "claude-opus-5-5"}]} ]' "$CFG1" >"$CFG2"
chmod 600 "$CFG2"
upstreams ok
gw_start "$CFG2"

echo "T1/T4 transport and routing (real omp -> gateway -> synthetic upstream)"
: >"$LOG"
for s in s1 s2 s3 s4; do omp_ask celgw/omp/claude-opus-5-5 low "cel136-live-$s"; done
check "omp got a reply through the gateway" grep -q "pong from pool-" "$W/omp.out"
echo "       upstream hits: $(counts)"
check "0 personal hits" test "$(hits personal)" = 0
check "pool served omp" test "$(( $(hits pool-a) + $(hits pool-b) ))" -gt 0
check "upstream model is the unprefixed id (no substitution)" jq -se 'map(.model) | unique == ["claude-opus-5-5"]' "$LOG"
check "thinking level low reached the upstream" jq -se 'map(.effort) | unique == ["low"]' "$LOG"
: >"$LOG"
omp_ask celgw/omp/claude-opus-5-5 high cel136-live-hi
check "thinking level high reached the upstream" jq -se 'map(.effort) | unique == ["high"]' "$LOG"

echo "T5 session header (omp -> capture, direct)"
: >"$LOG"
cp "$W/omp/models.yml" "$W/omp/models.gw"
yq -y --arg u "http://127.0.0.1:$UP_P" '.providers.celgw.baseUrl = $u' "$W/omp/models.gw" >"$W/omp/models.yml"
omp_ask celgw/omp/claude-opus-5-5 low cel136-live-direct
check "omp sent x-session-id from CEL_SESSION_ID" jq -se 'any(.[]; .session == "cel136-live-direct")' "$LOG"
check "omp sent OMP_GATEWAY_TOKEN as its key" jq -se 'any(.[]; .key_ok)' "$LOG"
mv "$W/omp/models.gw" "$W/omp/models.yml"

echo "T4b exhaustion (pool spent)"
upstreams exhausted
: >"$LOG"
omp_ask celgw/omp/claude-opus-5-5 low cel136-live-x1
check "omp failed rather than widening" bash -c '! grep -q "pong from" "$1"' _ "$W/omp.out"
for i in 1 2 3; do c="$(curl_ask omp/claude-opus-5-5 "cel136-live-c$i")"; echo "       prefixed req $i: $c"; done
echo "       upstream hits: $(counts)"
check "0 personal hits with the pool exhausted" test "$(hits personal)" = 0
: >"$LOG"
code="$(curl_ask claude-opus-5-5 cel136-live-plain)"
check "plain id (other clients) still reaches the whole vault: 200 via personal" test "$code:$(hits personal)" = "200:1"
gw_stop

[ "$FAIL" = 0 ] && echo "PASS" || echo "FAILED"
exit "$FAIL"
