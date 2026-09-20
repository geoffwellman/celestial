# shellcheck shell=bash
# SUBSCRIPTIONS - the two signed-in accounts the fleet actually runs on.
#
# `cel quota` knew API balances only, so the box could be one delegation away
# from a five-hour wall and nothing on the plane could see it. Everything here
# drives the real functions against a stub HTTP server and fixture credential
# files under a temporary HOME: a test that read the live credentials would
# both leak them into an assertion message and spend the owner's windows.
source "$CEL_ROOT/lib/common.sh"

# A miniature signed-in box. Fixture tokens are obviously fake and obviously
# distinct, because the strongest assertion in this file is that NO output
# ever contains one of them.
# Deliberately NOT shaped like the real credentials: the hygiene sweep reads
# this tree for anything that looks like a provider token, and a fixture that
# trips it teaches everyone to ignore the sweep.
PI_TOKEN='fixture-claude-pi-value'
CC_TOKEN='fixture-claude-code-value'
CX_TOKEN='fixture-codex-value'
CX_ACCOUNT='acct-alpha-1'

_quota_setup() { # [--same-claude-token]
  T="$(mktemp -d)"
  export HOME="$T/home"
  mkdir -p "$HOME/.pi/agent" "$HOME/.claude" "$HOME/.codex"
  export CEL_CACHE="$T/cache"
  local cc="$CC_TOKEN"
  [ "${1:-}" = --same-claude-token ] && cc="$PI_TOKEN"

  jq -nc --arg t "$PI_TOKEN" '{anthropic: {access: $t, refresh: "r"}}' \
    > "$HOME/.pi/agent/auth.json"
  jq -nc --arg t "$cc" '{claudeAiOauth: {accessToken: $t, scopes: ["user:inference"]}}' \
    > "$HOME/.claude/.credentials.json"
  jq -nc --arg t "$CX_TOKEN" --arg a "$CX_ACCOUNT" \
    '{auth_mode: "chatgpt", tokens: {access_token: $t, account_id: $a}}' \
    > "$HOME/.codex/auth.json"
}

_quota_teardown() { rm -rf "$T"; }

# One stub for both providers. It answers by PATH, counts the hits per path so
# the cache can be proved, and records the headers so the Claude beta header
# and the Codex account header are asserted rather than assumed.
#
# A THIRD BODY, PICKED BY BEARER. CEL-35 turns on whether two Claude logins
# read the same windows or different ones, and the only thing that tells the
# two reads apart is the token they present - so the stub answers the
# claude-code token from its own file when one is given.
_quota_stub_server() { # <claude-json> <codex-json> [claude-code-json]
  printf '%s' "$1" > "$T/claude.json"
  printf '%s' "$2" > "$T/codex.json"
  printf '%s' "${3:-$1}" > "$T/claude-cc.json"
  export STUB_CC_TOKEN="$CC_TOKEN"
  cat >"$T/stub.mjs" <<'EOF'
import { createServer } from 'node:http';
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
const dir = process.env.STUB_DIR;
const s = createServer((req, res) => {
  appendFileSync(`${dir}/hits`, `${req.url}\n`);
  appendFileSync(`${dir}/headers`, `${JSON.stringify(req.headers)}\n`);
  const auth = String(req.headers.authorization || '');
  const file = req.url.includes('codex') ? 'codex.json'
    : auth.includes(process.env.STUB_CC_TOKEN || '\u0000') ? 'claude-cc.json'
    : 'claude.json';
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(readFileSync(`${dir}/${file}`, 'utf8'));
});
s.listen(0, '127.0.0.1', () => { writeFileSync(`${dir}/port`, String(s.address().port)); });
EOF
  export STUB_DIR="$T"
  rm -f "$T/port" "$T/hits" "$T/headers"
  node "$T/stub.mjs" >"$T/stub.log" 2>&1 </dev/null & STUB_PID=$!
  # shellcheck disable=SC2064
  trap "kill $STUB_PID 2>/dev/null || true" EXIT INT TERM
  # TWENTY SECONDS, NOT ONE. This box runs the whole fleet: a verifier run at
  # load 26 took longer than five seconds just to get node to the point of
  # calling listen(), and the test failed with 'stub server never listened'
  # about a stub that was starting perfectly well. A fixed short wait measures
  # the box's load, not the code under test. The poll exits the moment the
  # port file appears, so a quiet box pays nothing for the longer ceiling.
  local i=0
  while [ ! -s "$T/port" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$T/port" ] || {
    # Say WHY it never listened: a bare 'never listened' sent the last reader
    # looking at the wrong thing entirely.
    printf 'stub server never listened after 20s; its log:\n%s\n' "$(cat "$T/stub.log" 2>/dev/null)"
    return 1
  }
  local base="http://127.0.0.1:$(cat "$T/port")"
  export CEL_SUB_ANTHROPIC_URL="$base/api/oauth/usage"
  export CEL_SUB_CODEX_URL="$base/backend-api/codex-wham/usage"
}

_quota_stub_stop() {
  [ -n "${STUB_PID:-}" ] || return 0
  kill "$STUB_PID" 2>/dev/null || true
  wait "$STUB_PID" 2>/dev/null || true
  STUB_PID=""
  trap - EXIT INT TERM
}

# The Anthropic OAuth usage shape, measured on this box 2026-09-18.
_claude_body() { # [five-hour-pct] [seven-day-pct]
  jq -nc --argjson a "${1:-16.0}" --argjson b "${2:-41.0}" \
    '{five_hour: {utilization: $a, resets_at: "2026-09-18T09:00:00Z"},
      seven_day: {utilization: $b, resets_at: "2026-09-19T19:00:00Z"},
      extra_usage: {disabled_reason: "out_of_credits"},
      limits: []}'
}

# The Codex shape: `rate_limits.primary/secondary`, each a RateLimitWindow of
# used_percent / window_minutes / resets_in_seconds.
_codex_body() { # [primary-pct] [secondary-pct]
  jq -nc --argjson a "${1:-9.0}" --argjson b "${2:-62.0}" \
    '{rate_limits: {primary: {used_percent: $a, window_minutes: 300, resets_in_seconds: 1800},
                    secondary: {used_percent: $b, window_minutes: 10080, resets_in_seconds: 200000},
                    plan_type: "pro"}}'
}

test_subscription_list_finds_both_providers_and_prints_no_token() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  assert_contains "$out" claude
  assert_contains "$out" codex
  assert_contains "$out" "$CX_ACCOUNT"
  case "$out" in *"$PI_TOKEN"*|*"$CC_TOKEN"*|*"$CX_TOKEN"*)
    printf 'subscription_list printed a token:\n%s\n' "$out" >&2; return 1;; esac
  _quota_stub_stop
  _quota_teardown
}

# --- CEL-35: an account is WHERE it is signed in --------------------------
#
# The owner, 2026-09-19: "somehow we are showing 4 claude subscriptions? there
# are only 3 I've signed into". CEL-27 named a Claude account by the first six
# hex of its token's sha256, and pi refreshes that token: every refresh minted
# a new account, a new cache file and a new row on every surface. The identity
# is now the credential's HOME - pi, claude-code, the codex account id - so a
# refresh overwrites one file and the row count is the login count.
test_a_rotated_pi_token_leaves_one_row_and_one_cache_file() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  # the five stale files this box woke up with, as one of them
  mkdir -p "$CEL_CACHE"
  printf '%s' '{"provider":"claude","account":"abc123","windows":[],"extra":{}}' \
    > "$CEL_CACHE/subscription-claude-abc123.json"

  subscription_list >/dev/null
  # pi refreshes its OAuth token between the two reads, as it does all day
  jq -nc --arg t "${PI_TOKEN}-rotated" '{anthropic: {access: $t, refresh: "r"}}' \
    > "$HOME/.pi/agent/auth.json"
  rm -f "$CEL_CACHE"/subscription-claude-pi.json
  local out; out="$(subscription_list)"

  # pi and Claude Code are two credential files and so two cache files; what
  # must NOT be there is a third one minted by the refresh.
  assert_eq "$(ls "$CEL_CACHE" | grep -c '^subscription-claude-')" 2
  assert_eq "$(ls "$CEL_CACHE" | grep -c '^subscription-claude-pi.json$')" 1
  [ -f "$CEL_CACHE/subscription-claude-pi.json" ] || {
    printf 'the cache is not keyed by identity: %s\n' "$(ls "$CEL_CACHE")" >&2; return 1; }
  [ -f "$CEL_CACHE/subscription-claude-abc123.json" ] && {
    printf 'the stale token-hashed cache file survived\n' >&2; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "claude")] | length')" 1
  _quota_stub_stop
  _quota_teardown
}

# pi and Claude Code hold two copies of one subscription. Same windows, one
# row - two rows double every number on the display and halve nobody's trust
# in it. Different windows are two subscriptions, and stay two rows.
test_pi_and_claude_code_fold_into_one_row_when_the_windows_match() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "claude")] | length')" 1
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.provider == "claude") | .label')" 'pi + claude-code'
  _quota_stub_stop
  _quota_teardown
}

test_two_claude_logins_with_different_windows_stay_two_rows() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)" "$(_claude_body 71.0 22.0)"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "claude")] | length')" 2
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "claude") | .account] | sort | join(",")')" 'claude-code,pi'
  _quota_stub_stop
  _quota_teardown
}

# AN UNREADABLE ACCOUNT IS A ROW, NOT A SILENCE. Codex answers nothing on this
# box, so CEL-27 cached nothing, so `cel fleet` listed nothing, so the console
# showed Claude alone while the dashboard showed everything. A row that says
# why is the only version of this an operator can act on.
test_codex_unreadable_is_still_a_row_with_its_reason() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  # a port nobody is listening on: the read fails the way the live one does
  export CEL_SUB_CODEX_URL="http://127.0.0.1:1/backend-api/wham/usage"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  local row; row="$(printf '%s' "$out" | jq -c '.[] | select(.provider == "codex")')"
  assert_eq "$(printf '%s' "$row" | jq -r '.extra.state')" unreadable
  assert_eq "$(printf '%s' "$row" | jq -r '.windows | length')" 0
  [ -n "$(printf '%s' "$row" | jq -r '.extra.reason')" ] || {
    printf 'an unreadable row with no reason is a row nobody can act on\n' >&2; return 1; }
  [ -f "$CEL_CACHE/subscription-codex-$CX_ACCOUNT.json" ] || {
    printf 'the unreadable row was not cached, so the fleet path cannot see it\n' >&2; return 1; }
  assert_contains "$(cmd_quota 2>/dev/null)" 'unreadable'
  _quota_stub_stop
  _quota_teardown
}

test_subscription_usage_parses_the_claude_shape() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_usage claude "$PI_TOKEN" pi)"
  assert_eq "$(printf '%s' "$out" | jq -r '.provider')" claude
  assert_eq "$(printf '%s' "$out" | jq -r '.windows[] | select(.name == "5h") | .used_pct == 16')" true
  assert_eq "$(printf '%s' "$out" | jq -r '.windows[] | select(.name == "7d") | .used_pct == 41')" true
  assert_eq "$(printf '%s' "$out" | jq -r '.extra.state')" disabled
  # CEL-49: `disabled_reason: out_of_credits` with spending switched off means
  # top-up is off, not "this account is spent", and the row says the true one.
  assert_eq "$(printf '%s' "$out" | jq -r '.extra.reason')" 'top-up is off'
  # the endpoint only answers an OAuth token with its beta header
  assert_contains "$(cat "$T/headers")" 'oauth-2025-04-20'
  _quota_stub_stop
  _quota_teardown
}

test_subscription_usage_parses_the_codex_shape() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_usage codex "$CX_TOKEN" "$CX_ACCOUNT")"
  assert_eq "$(printf '%s' "$out" | jq -r '.account')" "$CX_ACCOUNT"
  assert_eq "$(printf '%s' "$out" | jq -r '.windows[] | select(.name == "5h") | .used_pct == 9')" true
  assert_eq "$(printf '%s' "$out" | jq -r '.windows[] | select(.name == "7d") | .used_pct == 62')" true
  # the account header is what routes the read to the right ChatGPT account
  assert_contains "$(cat "$T/headers")" "$CX_ACCOUNT"
  _quota_stub_stop
  _quota_teardown
}

test_subscription_usage_caches_so_two_calls_ask_once() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  subscription_usage claude "$PI_TOKEN" pi >/dev/null
  subscription_usage claude "$PI_TOKEN" pi >/dev/null
  assert_eq "$(grep -c . "$T/hits")" 1
  assert_eq "$(ls "$CEL_CACHE" | grep -c '^subscription-claude-pi.json')" 1
  _quota_stub_stop
  _quota_teardown
}

# The cached answer carries no token, but it does say when each account is
# spent - which is precisely what you would want to know before deciding a box
# was worth attacking. A normal umask leaves a new file world-readable, so the
# mode is set rather than inherited, and asserted rather than assumed.
test_subscription_cache_is_readable_only_by_its_owner() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  # a permissive umask is the case this exists for
  ( umask 022
    subscription_usage claude "$PI_TOKEN" pi >/dev/null )
  local f; f="$(ls "$CEL_CACHE"/subscription-claude-*.json | head -n1)"
  assert_eq "$(stat -c %a "$f")" 600
  assert_eq "$(stat -c %a "$CEL_CACHE")" 700
  _quota_stub_stop
  _quota_teardown
}

test_quota_vetoed_refuses_a_full_five_hour_window_with_its_reset() {
  _quota_setup
  _quota_stub_server "$(_claude_body 100.0 99.0)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  local msg=""
  quota_vetoed anthropic unknown && msg="$SUBSCRIPTION_VETO"
  [ -n "$msg" ] || { echo 'anthropic at 100% was not vetoed'; return 1; }
  assert_contains "$msg" 'resets'
  _quota_stub_stop
  _quota_teardown
}

test_quota_vetoed_lets_ninety_nine_percent_through() {
  _quota_setup
  _quota_stub_server "$(_claude_body 99.0 99.0)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  assert_fails quota_vetoed anthropic unknown
  _quota_stub_stop
  _quota_teardown
}

test_cmd_quota_prints_subscriptions_above_the_balances_without_a_token() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(cmd_quota 2>/dev/null)"
  assert_contains "$out" SUBSCRIPTION
  assert_contains "$out" 'claude'
  assert_contains "$out" '5h 16%'
  assert_contains "$out" '7d 41%'
  case "$out" in *"$PI_TOKEN"*|*"$CX_TOKEN"*)
    printf 'cel quota printed a token\n' >&2; return 1;; esac
  _quota_stub_stop
  _quota_teardown
}

test_cmd_quota_json_carries_subscriptions() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(cmd_quota --json 2>/dev/null)"
  assert_eq "$(printf '%s' "$out" | jq -r '.subscriptions | length >= 2')" true
  assert_eq "$(printf '%s' "$out" | jq -r '[.subscriptions[].provider] | sort | unique | join(",")')" 'claude,codex'
  _quota_stub_stop
  _quota_teardown
}

# --- CEL-35: the gateway's accounts are subscriptions too -------------------
#
# CEL-28 put them behind `cel gateway status` alone, so the dashboard (which
# called it) showed them and the console (which reads the fleet document) did
# not. One list, or two surfaces answer the same question differently.
_quota_gateway_stub() { # [--down]
  mkdir -p "$T/bin"
  export CEL_CONFIG_FILE="$T/config.yaml"
  printf 'gateway:\n  gateway_port: 47411\n  broker_port: 47311\n' > "$CEL_CONFIG_FILE"
  cat >"$T/bin/omp" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth-broker token"|"auth-gateway token") printf 'gw-fixture-token\n' ;;
  "auth-gateway status") printf '%s\n' '{"ready":true,"reason":null,"credentialCount":2}' ;;
  "auth-gateway check") cat <<'JSON'
{"credentials":[
 {"id":1,"provider":"openai-codex","type":"oauth","ok":true,
  "accountId":"aaaaaaaa-1111-2222-3333-444444444444",
  "report":{"limits":[{"label":"7 days","window":{"id":"7d","resetsAt":1789994511000},
    "amount":{"used":12,"limit":100,"usedFraction":0.12},"status":"ok"}]}}]}
JSON
  ;;
esac
EOF
  chmod +x "$T/bin/omp"
  PATH="$T/bin:$PATH"
  cat >"$T/gwstub" <<'EOF'
#!/usr/bin/env bash
case "$1" in ready) exit "${GW_STUB_DOWN:-0}" ;; esac
EOF
  chmod +x "$T/gwstub"
  export CEL_GATEWAY_STUB="$T/gwstub"
  [ "${1:-}" = --down ] && export GW_STUB_DOWN=1
  return 0
}

test_gateway_accounts_join_the_subscription_list() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  _quota_gateway_stub
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  local row; row="$(printf '%s' "$out" | jq -c '.[] | select(.source == "gateway")')"
  [ -n "$row" ] || { printf 'no gateway row in the subscription list\n' >&2; return 1; }
  assert_eq "$(printf '%s' "$row" | jq -r '.provider')" openai-codex
  assert_eq "$(printf '%s' "$row" | jq -r '.windows[0].used_pct')" 12
  _quota_stub_stop
  _quota_teardown
}

test_a_gateway_that_is_down_adds_no_rows_and_no_error() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  _quota_gateway_stub --down
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.source == "gateway")] | length')" 0
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "claude")] | length >= 1')" true
  _quota_stub_stop
  _quota_teardown
}

# The fleet path never asks a provider: it reads the cache and folds exactly
# as the live path does, or the console and `cel quota` disagree about how
# many subscriptions this box has - which is the bug this ticket exists for.
test_the_cached_list_is_the_same_list_as_the_live_one() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  local live cached
  live="$(subscription_list | jq -S .)"
  cached="$(subscription_list --cached | jq -S .)"
  assert_eq "$cached" "$live"
  _quota_stub_stop
  _quota_teardown
}

# --- CEL-49: ask the box what it already knows ------------------------------
#
# The owner, 2026-09-20: Codex reads `unreadable` while their prompt tool shows
# it fine, Fable is missing, one Anthropic account of three is missing, and
# opencode is nowhere. Every one of those is cel reading a worse source than
# the box already has: `omp usage --json` holds refreshed OAuth per account and
# answers for all of them, with `.limits[]` as the authoritative window list.
#
# NOTHING HERE CALLS A PROVIDER. `omp` is a stub on a prepended PATH printing
# canned JSON, exactly as the endpoint stub above serves the fallback path.

# THE FIXTURE IS THIS BOX'S OWN ANSWER, with the identities replaced by
# fictional ones: `omp usage --json | jq del(.reports[].limits)` carries no
# secret, and a stub shaped like a document omp does not produce tests
# nothing - the first cut of this file invented `{accounts: [...]}`, the code
# was written to match the invention, and the gate passed while `cel quota`
# never changed. So tests/fixtures/omp-usage.json is the real shape:
# {generatedAt, reports:[{provider, metadata:{accountId,email,planType},
# limits:[...]}], accountsWithoutUsage, disabledCredentials, capacity}, with
# three Anthropic accounts (each carrying a Fable-scoped weekly window), two
# ChatGPT accounts and opencode-go - plus one `null` limit added to the first
# Anthropic report, because a window that answers null must be skipped rather
# than drawn at 0%.
_omp_stub() {
  mkdir -p "$T/bin"
  cp "$(fixture omp-usage.json)" "$T/omp-usage.json"
  cat >"$T/bin/omp" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  usage) cat "$OMP_USAGE_JSON" ;;
  auth-gateway) case "$2" in status) printf '%s\n' '{"ready":false}' ;; esac ;;
esac
EOF
  chmod +x "$T/bin/omp"
  export OMP_USAGE_JSON="$T/omp-usage.json"
  export PATH="$T/bin:$PATH"
}

test_omp_usage_is_the_source_and_every_account_is_its_own_row() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  _omp_stub
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "claude")] | length')" 3
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "codex")] | length')" 2
  # an account is provider + account id, and a reader tells them apart by email
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "claude") | .label] | sort | join(",")')" \
    'one@example.invalid,three@example.invalid,two@example.invalid'
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "claude") | .account] | sort | join(",")')" \
    'ant-one,ant-three,ant-two'
  case "$out" in *"$PI_TOKEN"*|*"$CX_TOKEN"*)
    printf 'the omp path printed a token\n' >&2; return 1;; esac
  _quota_stub_stop
  _quota_teardown
}

# Fable is not a special case - it is one scoped window among several, and
# hardcoding its name would reintroduce this bug for the next one.
test_a_scoped_window_keeps_its_scope_and_is_not_dropped() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  _omp_stub
  . "$CEL_ROOT/lib/quota.sh"
  local row; row="$(subscription_list | jq -c '.[] | select(.account == "ant-one")')"
  assert_eq "$(printf '%s' "$row" | jq -r '[.windows[] | select(.scope == "Fable")] | length')" 1
  assert_eq "$(printf '%s' "$row" | jq -r '.windows[] | select(.scope == "Fable") | .used_pct')" 31
  # and it is told apart from the account-wide window of the same length
  assert_eq "$(printf '%s' "$row" | jq -r '[.windows[] | select(.name == "7d")] | length')" 2
  assert_contains "$(cmd_quota 2>/dev/null)" 'Fable'
}

test_a_null_window_is_skipped_rather_than_drawn_empty() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  _omp_stub
  . "$CEL_ROOT/lib/quota.sh"
  local row; row="$(subscription_list | jq -c '.[] | select(.account == "ant-one")')"
  assert_eq "$(printf '%s' "$row" | jq -r '.windows | length')" 3
  assert_eq "$(printf '%s' "$row" | jq -r '[.windows[] | select(.used_pct == null)] | length')" 0
}

# This repo runs on boxes with no omp at all, and absent it must degrade to
# exactly today's behaviour rather than to an error.
test_without_omp_the_endpoint_reads_answer_exactly_as_before() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  mkdir -p "$T/empty"
  export PATH="$T/empty:/usr/bin:/bin"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(cmd_quota 2>/dev/null)"
  assert_contains "$out" '5h 16%'
  assert_contains "$out" '7d 41%'
  assert_contains "$out" 'codex'
  _quota_stub_stop
  _quota_teardown
}

# A plan with windows and no credit number is normal, not a gap to fill with
# `unknown`: opencode renders usage and no balance row at all.
test_opencode_renders_usage_and_no_credit_row() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  _omp_stub
  . "$CEL_ROOT/lib/quota.sh"
  assert_eq "$(subscription_list | jq -r '[.[] | select(.provider == "opencode")] | length')" 1
  # a plan with three windows and no credit number at all
  assert_eq "$(subscription_list | jq -r '.[] | select(.provider == "opencode") | .windows | length')" 3
  local out; out="$(cmd_quota 2>/dev/null)"
  assert_contains "$out" 'opencode'
  # the balances table names providers that declare a balance; opencode has none
  assert_eq "$(printf '%s' "$out" | sed -n '/PROVIDER/,$p' | grep -c opencode)" 0
}

# "Out of credits" on a healthy account is worse than silence: the field is
# `extra_usage.disabled_reason` with `spend.enabled=false`, which means top-up
# is switched off.
# The field lives in the Anthropic OAuth usage response, which is the direct
# path - omp's document does not carry it - so this drives that path with no
# omp on PATH, exactly as a box without the broker runs.
test_top_up_being_off_never_reads_as_out_of_credits() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  mkdir -p "$T/empty"; export PATH="$T/empty:/usr/bin:/bin"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(cmd_quota 2>/dev/null)"
  case "$out" in *'out of credits'*|*'out_of_credits'*)
    printf 'a healthy account was reported as out of credits:\n%s\n' "$out" >&2; return 1;; esac
  assert_contains "$out" 'top-up is off'
}

# CREDIT IS WORKSPACE-SCOPED, DECIDED. A workspace without the key reads
# `unknown`, and that is a fact about where you are standing - not a fault.
# The fault is asking and not being able to tell, and the two must not read
# the same.
_quota_manifest_stub() {
  CEL_MANIFEST="$T/agents.yaml"
  export CEL_MANIFEST
  cat >"$CEL_MANIFEST" <<'YAML'
providers:
  nokeyhere:
    key_env: CEL_TEST_ABSENT_KEY
    balance: {url: "http://127.0.0.1:1/balance", jq: ".credit", unit: usd, floor: 1}
  deadend:
    key_env: CEL_TEST_PRESENT_KEY
    balance: {url: "http://127.0.0.1:1/balance", jq: ".credit", unit: usd, floor: 1}
YAML
  unset CEL_TEST_ABSENT_KEY
  export CEL_TEST_PRESENT_KEY=fixture-not-a-real-key
  export CEL_QUOTA_DIR="$T/quota"
}

test_no_key_in_this_workspace_reads_differently_from_asked_and_failed() {
  _quota_setup
  _quota_manifest_stub
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(cmd_quota 2>/dev/null)"
  assert_contains "$out" 'no key in this workspace'
  assert_contains "$out" 'could not tell'
  local js; js="$(cmd_quota --json 2>/dev/null)"
  assert_eq "$(printf '%s' "$js" | jq -r '.balances[] | select(.provider == "nokeyhere") | .state')" no_key
  assert_eq "$(printf '%s' "$js" | jq -r '.balances[] | select(.provider == "deadend") | .state')" unknown
  _quota_teardown
}

# A STUB THAT DISAGREES WITH THE TOOL IS THE BUG, NOT THE SAFETY NET. The
# first cut of this file invented `{accounts: [...]}`; omp answers
# `{generatedAt, reports, accountsWithoutUsage, disabledCredentials,
# capacity}`, so every row fell out, every caller fell back to the old path,
# and this suite passed while `cel quota` printed exactly the output the
# ticket was filed about. The fixture is pinned to the real shape here, and
# where omp is actually installed its own top-level keys are compared - which
# is the assertion that would have caught it.
test_the_omp_fixture_is_the_shape_the_tool_answers() {
  local keys; keys="$(jq -r 'keys | sort | join(",")' "$(fixture omp-usage.json)")"
  assert_eq "$keys" 'accountsWithoutUsage,capacity,disabledCredentials,generatedAt,reports'
  # the identity fields the mapping depends on live under .metadata
  assert_eq "$(jq -r '[.reports[] | select(.metadata.accountId != null)] | length >= 5' "$(fixture omp-usage.json)")" true
  assert_eq "$(jq -r '[.reports[].limits[]? | select(.amount.usedFraction != null)] | length >= 10' "$(fixture omp-usage.json)")" true
  command -v omp >/dev/null 2>&1 || return 0
  local live; live="$(omp usage --json 2>/dev/null | jq -r 'keys | sort | join(",")' 2>/dev/null || true)"
  [ -n "$live" ] || return 0
  assert_eq "$live" "$keys"
}

# The row count is the whole point: a mapping that reads the wrong key yields
# nothing and every caller silently falls back to the old path, which is
# precisely how this shipped once. Zero rows from a document with six reports
# is a failure, not an empty answer.
test_the_omp_mapping_yields_a_row_per_report() {
  _quota_setup
  _omp_stub
  . "$CEL_ROOT/lib/quota.sh"
  assert_eq "$(_sub_omp_rows | grep -c .)" 6
}
