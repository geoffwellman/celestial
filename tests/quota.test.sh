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
_quota_stub_server() { # <claude-json> <codex-json>
  printf '%s' "$1" > "$T/claude.json"
  printf '%s' "$2" > "$T/codex.json"
  cat >"$T/stub.mjs" <<'EOF'
import { createServer } from 'node:http';
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
const dir = process.env.STUB_DIR;
const s = createServer((req, res) => {
  appendFileSync(`${dir}/hits`, `${req.url}\n`);
  appendFileSync(`${dir}/headers`, `${JSON.stringify(req.headers)}\n`);
  const file = req.url.includes('codex') ? 'codex.json' : 'claude.json';
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
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  assert_contains "$out" claude
  assert_contains "$out" codex
  assert_contains "$out" "$CX_ACCOUNT"
  case "$out" in *"$PI_TOKEN"*|*"$CC_TOKEN"*|*"$CX_TOKEN"*)
    printf 'subscription_list printed a token:\n%s\n' "$out" >&2; return 1;; esac
  # two distinct Claude tokens are two accounts, plus codex
  assert_eq "$(printf '%s\n' "$out" | grep -c .)" 3
  _quota_teardown
}

test_subscription_list_folds_one_claude_account_when_the_tokens_match() {
  _quota_setup --same-claude-token
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^claude')" 1
  _quota_teardown
}

test_subscription_usage_parses_the_claude_shape() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_usage claude "$PI_TOKEN")"
  assert_eq "$(printf '%s' "$out" | jq -r '.provider')" claude
  assert_eq "$(printf '%s' "$out" | jq -r '.windows[] | select(.name == "5h") | .used_pct == 16')" true
  assert_eq "$(printf '%s' "$out" | jq -r '.windows[] | select(.name == "7d") | .used_pct == 41')" true
  assert_eq "$(printf '%s' "$out" | jq -r '.extra.state')" disabled
  assert_eq "$(printf '%s' "$out" | jq -r '.extra.reason')" out_of_credits
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
  subscription_usage claude "$PI_TOKEN" >/dev/null
  subscription_usage claude "$PI_TOKEN" >/dev/null
  assert_eq "$(grep -c . "$T/hits")" 1
  assert_eq "$(ls "$CEL_CACHE" | grep -c '^subscription-claude-')" 1
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
    subscription_usage claude "$PI_TOKEN" >/dev/null )
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
