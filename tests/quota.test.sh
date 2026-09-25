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
// A DEAD MAN'S SWITCH, BECAUSE A TRAP IS NOT ENOUGH. On 2026-09-23 a stub
// outlived the test that started it and the suite sat on the box-wide lock for
// 54 minutes with another worker retrying flock behind it. A test that fails
// its assertion never reaches its cleanup line, and a runner killed with -9
// never runs its EXIT trap either - so the server also ends itself, and no
// leak can outlive one test by more than a minute.
setTimeout(() => process.exit(0), 60000);
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

# --- CEL-49 review: the two silences are not the same news ------------------
#
# A box with no omp falls back quietly, as the ticket requires. omp that IS
# there and answers nothing usable falls back to the same stale reads - and
# read the same way it is invisible, which is exactly how the `.accounts`
# mapping shipped green. One line on stderr tells them apart.
test_omp_present_but_useless_says_so_on_stderr() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  mkdir -p "$T/bin"
  # omp is installed and answers a document this mapping cannot use: a shape
  # drift, an error body, a truncated response - all of them land here.
  cat >"$T/bin/omp" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  usage) printf '%s\n' '{"error":"unsupported","reports":null}' ;;
  auth-gateway) case "$2" in status) printf '%s\n' '{"ready":false}' ;; esac ;;
esac
EOF
  chmod +x "$T/bin/omp"
  export PATH="$T/bin:$PATH"
  . "$CEL_ROOT/lib/quota.sh"
  local err; err="$(subscription_list 2>&1 >/dev/null)"
  assert_contains "$err" 'omp is on PATH but produced no usable subscription rows'
  # and the fallback still answered, because the best available answer beats
  # no answer - the line is a warning, not a refusal
  local out; out="$(subscription_list 2>/dev/null)"
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "claude")] | length >= 1')" true
  # stdout stays a parseable document: the warning may never land in it
  case "$out" in *'omp is on PATH'*) printf 'the warning was printed to stdout\n' >&2; return 1;; esac
  _quota_stub_stop
  _quota_teardown
}

test_a_box_without_omp_falls_back_in_silence() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  mkdir -p "$T/empty"; export PATH="$T/empty:/usr/bin:/bin"
  . "$CEL_ROOT/lib/quota.sh"
  local err; err="$(subscription_list 2>&1 >/dev/null)"
  [ -z "$err" ] || {
    printf 'a box with no omp complained about omp:\n%s\n' "$err" >&2; return 1; }
  _quota_stub_stop
  _quota_teardown
}

# The warning is about a source that answered badly, and the cached path asks
# nobody: the console's refresh loop and the dashboard's poll must not print a
# line per draw about a tool they never ran.
test_the_cached_path_never_warns_about_omp() {
  _quota_setup
  _omp_stub
  . "$CEL_ROOT/lib/quota.sh"
  subscription_list >/dev/null 2>&1
  printf '#!/usr/bin/env bash\ncase "$1" in usage) printf "{}\\n" ;; esac\n' > "$T/bin/omp"
  local err; err="$(subscription_list --cached 2>&1 >/dev/null)"
  [ -z "$err" ] || {
    printf 'the cached path warned about a tool it never ran:\n%s\n' "$err" >&2; return 1; }
}

# --- CEL-61: the usage reader owns the vault --------------------------------
#
# The owner's decision, 2026-09-23 (option C): CLIProxyAPI becomes the ONE
# credential store on the box and celestial reads usage from those credentials
# itself, because the alternative - CPA serving traffic while omp reports usage
# - leaves two lists of accounts with nothing keeping them the same, and an
# account logged into one and forgotten in the other stops `cel quota` matching
# the accounts the workers actually run on.
#
# NOTHING HERE CALLS A PROVIDER AND NOTHING HERE TOUCHES THE REAL VAULT: the
# fixture auth-dir is built under mktemp in CLIProxyAPI's own filename and JSON
# shapes (`claude-<hash>-<email>.json`, `codex-<hash>-<email>-<plan>.json`,
# access/refresh token plus `account.email_address` / `account.uuid` /
# `organization.uuid`), and every endpoint is a stub on 127.0.0.1.

# One stub for usage - claude, codex and opencode - AND A TOKEN ENDPOINT THAT
# EXISTS ONLY AS A TRAP. celestial never refreshes: CLIProxyAPI is the only
# refresher on this box, because both providers rotate the refresh token when
# it is used and a second refresher retires the one the gateway has stored. The
# stub answers `/oauth/token` and records every hit so a test can fail the
# moment that call reappears; nothing in lib/quota.sh knows the address.
#
# It answers 401 to any bearer that is not in its `fresh` list, which is what
# an expired access token looks like from here - the CEL-49 symptom
# ("unreadable" for sixteen days) was exactly this answer going unrecognised.
_cpa_stub_server() { # <claude-json> <codex-json> <opencode-json>
  printf '%s' "$1" > "$T/claude.json"
  printf '%s' "$2" > "$T/codex.json"
  printf '%s' "$3" > "$T/opencode.json"
  cat >"$T/cpastub.mjs" <<'EOF'
import { createServer } from 'node:http';
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
const dir = process.env.STUB_DIR;
// See the note on the other stub: the server ends itself after a minute so a
// failed assertion that skips the cleanup line cannot hold the suite lock.
setTimeout(() => process.exit(0), 60000);
const read = (n) => (existsSync(`${dir}/${n}`) ? readFileSync(`${dir}/${n}`, 'utf8') : '');
const fresh = () => read('fresh').split('\n').map((x) => x.trim()).filter(Boolean);
const s = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    appendFileSync(`${dir}/hits`, `${req.method} ${req.url}\n`);
    const auth = String(req.headers.authorization || '').replace(/^Bearer /i, '');
    const json = (code, o) => {
      res.writeHead(code, { 'content-type': 'application/json' });
      res.end(typeof o === 'string' ? o : JSON.stringify(o));
    };
    if (req.url.includes('/oauth/token')) {
      // Recorded, and answered generously ON PURPOSE: a trap that refused
      // would let a reader that called it still look correct.
      appendFileSync(`${dir}/refreshes`, `${body}\n`);
      const t = `refreshed-access-${fresh().length}`;
      writeFileSync(`${dir}/fresh`, fresh().concat([t]).join('\n') + '\n');
      return json(200, { access_token: t, refresh_token: 'fixture-refresh-rotated', expires_in: 3600 });
    }
    if (!fresh().includes(auth)) return json(401, { error: 'token_expired' });
    if (req.url.includes('codex')) return json(200, read('codex.json'));
    if (req.url.includes('zen')) return json(200, read('opencode.json'));
    return json(200, read('claude.json'));
  });
});
s.listen(0, '127.0.0.1', () => { writeFileSync(`${dir}/port`, String(s.address().port)); });
EOF
  export STUB_DIR="$T"
  rm -f "$T/port" "$T/hits" "$T/refreshes"
  node "$T/cpastub.mjs" >"$T/cpastub.log" 2>&1 </dev/null & STUB_PID=$!
  # shellcheck disable=SC2064
  trap "kill $STUB_PID 2>/dev/null || true" EXIT INT TERM
  local i=0
  while [ ! -s "$T/port" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$T/port" ] || {
    printf 'cpa stub never listened after 20s; its log:\n%s\n' "$(cat "$T/cpastub.log" 2>/dev/null)"
    return 1
  }
  local base="http://127.0.0.1:$(cat "$T/port")"
  export CEL_SUB_ANTHROPIC_URL="$base/api/oauth/usage"
  export CEL_SUB_CODEX_URL="$base/backend-api/codex-wham/usage"
  export CEL_SUB_OPENCODE_URL="$base/zen/go/v1/usage"
}

# The Anthropic OAuth usage answer, with a SCOPED weekly window beside the
# account-wide one. Fable is not named anywhere in the reader: the scope is
# read off the key, so the next scoped window appears without a code change.
_cpa_claude_body() {
  jq -nc '{five_hour: {utilization: 16, resets_at: "2026-09-18T09:00:00Z"},
           seven_day: {utilization: 41, resets_at: "2026-09-19T19:00:00Z"},
           seven_day_fable: {utilization: 31, resets_at: "2026-09-19T19:00:00Z"}}'
}

_cpa_opencode_body() {
  jq -nc '{limits: [
    {label: "5 hours", window: {id: "5h", durationMs: 18000000, resetsAt: "2026-09-18T09:00:00Z"},
     amount: {used: 1, limit: 10, usedFraction: 0.1}},
    {label: "7 days", window: {id: "7d", durationMs: 604800000, resetsAt: "2026-09-19T19:00:00Z"},
     amount: {used: 5, limit: 10, usedFraction: 0.5}},
    {label: "7 days (gadget)", window: {id: "7d", durationMs: 604800000, resetsAt: "2026-09-19T19:00:00Z"},
     amount: {used: 2, limit: 10, usedFraction: 0.2}}]}'
}

# CLIProxyAPI's vault: one OAuth JSON per account, named
# `claude-<hash>-<email>.json` / `codex-<hash>-<email>-<plan>.json`.
_cpa_vault() { # [--expired]
  local exp="2099-01-01T00:00:00Z"
  [ "${1:-}" = --expired ] && exp="2020-01-01T00:00:00Z"
  export CEL_CPA_AUTH_DIR="$T/cpa-auth"
  mkdir -p "$CEL_CPA_AUTH_DIR"; chmod 700 "$CEL_CPA_AUTH_DIR"
  jq -nc --arg e "$exp" '{type: "claude", access_token: "fixture-cpa-claude-one",
    refresh_token: "fixture-cpa-refresh-one", expire: $e,
    account: {email_address: "one@example.invalid", uuid: "ant-one"},
    organization: {uuid: "org-one"}}' > "$CEL_CPA_AUTH_DIR/claude-aaaa1111-one@example.invalid.json"
  jq -nc --arg e "$exp" '{type: "claude", access_token: "fixture-cpa-claude-two",
    refresh_token: "fixture-cpa-refresh-two", expire: $e,
    account: {email_address: "two@example.invalid", uuid: "ant-two"},
    organization: {uuid: "org-two"}}' > "$CEL_CPA_AUTH_DIR/claude-bbbb2222-two@example.invalid.json"
  jq -nc --arg e "$exp" '{type: "codex", access_token: "fixture-cpa-codex-three",
    refresh_token: "fixture-cpa-refresh-three", expire: $e, email: "three@example.invalid",
    account: {email_address: "three@example.invalid", uuid: "cx-three"}}' \
    > "$CEL_CPA_AUTH_DIR/codex-cccc3333-three@example.invalid-plus.json"
  jq -nc --arg e "$exp" '{type: "codex", access_token: "fixture-cpa-codex-four",
    refresh_token: "fixture-cpa-refresh-four", expire: $e, email: "four@example.invalid",
    account: {email_address: "four@example.invalid", uuid: "cx-four"}}' \
    > "$CEL_CPA_AUTH_DIR/codex-dddd4444-four@example.invalid-pro.json"
  # every access token in the vault is live unless a test says otherwise
  printf '%s\n' fixture-cpa-claude-one fixture-cpa-claude-two \
    fixture-cpa-codex-three fixture-cpa-codex-four > "$T/fresh"
}

_cpa_opencode_auth() {
  mkdir -p "$HOME/.local/share/opencode"
  jq -nc '{opencode: {type: "oauth", access: "fixture-opencode-token"}}' \
    > "$HOME/.local/share/opencode/auth.json"
  printf 'fixture-opencode-token\n' >> "$T/fresh"
}

test_the_cliproxy_vault_is_the_source_and_every_account_is_its_own_row() {
  _quota_setup
  _cpa_stub_server "$(_cpa_claude_body)" "$(_codex_body)" "$(_cpa_opencode_body)"
  _cpa_vault
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "claude")] | length')" 2
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "codex")] | length')" 2
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | .label] | sort | join(",")')" \
    'four@example.invalid,one@example.invalid,three@example.invalid,two@example.invalid'
  # each account carries its OWN windows, and a scoped one nobody named in code
  local row; row="$(printf '%s' "$out" | jq -c '.[] | select(.account == "ant-one")')"
  assert_eq "$(printf '%s' "$row" | jq -r '.windows | length')" 3
  assert_eq "$(printf '%s' "$row" | jq -r '.windows[] | select(.scope == "Fable") | .used_pct')" 31
  assert_eq "$(printf '%s' "$row" | jq -r '[.windows[] | select(.name == "7d")] | length')" 2
  case "$out" in *fixture-cpa-claude-one*|*fixture-cpa-refresh-one*)
    printf 'the vault reader printed a token\n' >&2; return 1;; esac
  _quota_stub_stop
  _quota_teardown
}

# THE VAULT'S OWNER IS THE ONLY REFRESHER. CLIProxyAPI runs a 15-minute
# auto-refresh loop over every credential it holds
# (`sdk/cliproxy/service_lifecycle.go:91-93`), serialised per auth id
# (`sdk/cliproxy/auth/conductor.go:196-201`), and persists what comes back. Both
# providers can ROTATE the refresh token on use - Anthropic's own client keeps
# the old one only `if tokenResp.RefreshToken == ""`
# (`internal/auth/claude/anthropic_auth.go:579-580`), and CPA's Codex path has a
# `refresh_token_reused` branch (`internal/auth/codex/openai_auth.go:336`)
# precisely because auth.openai.com enforces rotation - so a second refresher
# that discards the rotated token leaves the vault's stored one DEAD on the
# server: valid JSON in the file, and CLIProxyAPI failing at its next refresh.
# A status read may not do that, so celestial does not refresh at all. It
# presents what the vault holds and says so when that is stale.
test_the_usage_reader_never_calls_a_token_endpoint() {
  _quota_setup
  _cpa_stub_server "$(_cpa_claude_body)" "$(_codex_body)" "$(_cpa_opencode_body)"
  _cpa_vault --expired
  . "$CEL_ROOT/lib/quota.sh"
  subscription_list >/dev/null 2>&1
  [ -s "$T/refreshes" ] && {
    printf 'the usage reader posted to a token endpoint and can burn the vault refresh token:\n%s\n' \
      "$(cat "$T/refreshes")" >&2; return 1; }
  case "$(cat "$T/hits" 2>/dev/null)" in *oauth/token*)
    printf 'the usage reader hit a token endpoint\n' >&2; return 1;; esac
  _quota_stub_stop
  _quota_teardown
}

# An access token CLIProxyAPI has not refreshed is a row that says what to do
# about it. The old Codex path read a raw token, never noticed it had gone
# stale, and printed `unreadable` for sixteen days - a word that reads like a
# transient fault and gets waited out.
test_a_stale_vault_token_reads_as_stale_not_unreadable() {
  _quota_setup
  _cpa_stub_server "$(_cpa_claude_body)" "$(_codex_body)" "$(_cpa_opencode_body)"
  _cpa_vault --expired
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  # STALE IS ITS OWN STATE. Nothing is broken: CLIProxyAPI - the only thing
  # that may refresh this - simply has not yet. Calling that a login sends the
  # owner to a browser to fix nothing; calling it unreadable gets it waited out.
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.extra.state == "stale")] | length')" 4
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.extra.state == "unreadable")] | length')" 0
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.extra.state == "needs_login")] | length')" 0
  assert_contains "$(printf '%s' "$out" | jq -r '.[0].extra.reason')" 'serves traffic'
  assert_contains "$(cmd_quota 2>/dev/null)" 'token stale'
  _quota_stub_stop
  _quota_teardown
}

# A token the vault calls LIVE and the provider rejects anyway is the other
# news: that credential is finished and only a human can replace it. Still not
# a refresh - the one call that must never happen is the one that would retire
# the vault's refresh token on the way to saying so.
test_a_rejected_vault_token_reads_as_needs_login() {
  _quota_setup
  _cpa_stub_server "$(_cpa_claude_body)" "$(_codex_body)" "$(_cpa_opencode_body)"
  _cpa_vault
  : > "$T/fresh"   # every token in the vault is rejected by the provider
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.extra.state == "needs_login")] | length')" 4
  [ -s "$T/refreshes" ] && { printf 'a rejected token was met with a refresh\n' >&2; return 1; }
  _quota_stub_stop
  _quota_teardown
}

# TWO WRITERS OF ONE VAULT CANNOT BOTH BE RIGHT, AND NEITHER MAY BE celestial.
# CLIProxyAPI serves live traffic from these files, refreshes them on its own
# loop, and persists the result under a per-auth lock celestial cannot join.
# Two of its readers at once must therefore leave the vault EXACTLY as
# CLIProxyAPI last wrote it - same bytes, same refresh token, and no refresh
# posted anywhere that could have invalidated that token server-side.
test_two_readers_leave_the_cliproxy_vault_byte_identical() {
  _quota_setup
  _cpa_stub_server "$(_cpa_claude_body)" "$(_codex_body)" "$(_cpa_opencode_body)"
  _cpa_vault --expired
  . "$CEL_ROOT/lib/quota.sh"
  local f="$CEL_CPA_AUTH_DIR/claude-aaaa1111-one@example.invalid.json"
  local before; before="$(cat "$f")"
  # `trap - EXIT` inside each subshell: the EXIT trap that kills the stub is
  # inherited by a background subshell, and the first one to finish would
  # otherwise shoot the server out from under the second.
  ( trap - EXIT INT TERM; CEL_CACHE="$T/cache-a" subscription_list >/dev/null 2>&1 ) &
  ( trap - EXIT INT TERM; CEL_CACHE="$T/cache-b" subscription_list >/dev/null 2>&1 ) &
  wait
  jq -e . "$f" >/dev/null 2>&1 || {
    printf 'the vault file is no longer valid JSON after two readers:\n%s\n' "$(cat "$f")" >&2
    return 1; }
  assert_eq "$(jq -r '.refresh_token' "$f")" fixture-cpa-refresh-one
  assert_eq "$(cat "$f")" "$before"
  # and that stored refresh token is still LIVE on the provider, because nobody
  # spent it: a rotating endpoint invalidates the old one on use.
  [ -s "$T/refreshes" ] && {
    printf 'a reader spent the vault refresh token; a rotating provider would now reject it\n' >&2
    return 1; }
  _quota_stub_stop
  _quota_teardown
}

# omp's path is the fallback until the new reader has proved itself on the live
# box: an empty or absent vault must degrade to exactly today's output.
test_an_absent_cliproxy_vault_falls_back_to_omp_unchanged() {
  _quota_setup
  _quota_stub_server "$(_claude_body)" "$(_codex_body)"
  _omp_stub
  export CEL_CPA_AUTH_DIR="$T/no-vault-here"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  local expected; expected="$(_sub_omp_rows | _sub_fold)"
  assert_eq "$out" "$expected"
  mkdir -p "$CEL_CPA_AUTH_DIR"
  assert_eq "$(subscription_list)" "$expected"
  _quota_stub_stop
  _quota_teardown
}

# CLIProxyAPI does not hold opencode, and the owner has that row today.
test_opencode_still_reports_beside_the_vault_accounts() {
  _quota_setup
  _cpa_stub_server "$(_cpa_claude_body)" "$(_codex_body)" "$(_cpa_opencode_body)"
  _cpa_vault
  _cpa_opencode_auth
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list)"
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "opencode")] | length')" 1
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.provider == "opencode") | .windows | length')" 3
  assert_contains "$(cmd_quota 2>/dev/null)" 'opencode'
  case "$out" in *fixture-opencode-token*)
    printf 'the opencode read printed a token\n' >&2; return 1;; esac
  _quota_stub_stop
  _quota_teardown
}

# THE RENDERERS DO NOT CHANGE. The console's QUOTA view and the dash card read
# the row shape `_sub_omp_rows` produced; a new source that answers a different
# shape is a silent regression on three surfaces at once.
test_the_vault_rows_have_the_same_shape_as_the_omp_rows() {
  _quota_setup
  _cpa_stub_server "$(_cpa_claude_body)" "$(_codex_body)" "$(_cpa_opencode_body)"
  _cpa_vault
  _omp_stub
  . "$CEL_ROOT/lib/quota.sh"
  local omp_keys cpa_keys omp_wkeys cpa_wkeys
  omp_keys="$(_sub_omp_rows | jq -s -r '[.[] | keys[]] | sort | unique | join(",")')"
  omp_wkeys="$(_sub_omp_rows | jq -s -r '[.[].windows[] | keys[]] | sort | unique | join(",")')"
  local rows; rows="$(subscription_list)"
  cpa_keys="$(printf '%s' "$rows" | jq -r '[.[] | keys[]] | sort | unique | join(",")')"
  cpa_wkeys="$(printf '%s' "$rows" | jq -r '[.[].windows[] | keys[]] | sort | unique | join(",")')"
  assert_eq "$cpa_keys" "$omp_keys"
  assert_eq "$cpa_wkeys" "$omp_wkeys"
  assert_eq "$(printf '%s' "$rows" | jq -r '[.[].extra | keys[]] | sort | unique | join(",")')" 'reason,state'
  _quota_stub_stop
  _quota_teardown
}

# The parity tool is what the owner runs on the live box before omp's path is
# removed in a later ticket: both readers, per account and per window.
test_the_parity_tool_prints_both_readers_side_by_side() {
  _quota_setup
  _cpa_stub_server "$(_cpa_claude_body)" "$(_codex_body)" "$(_cpa_opencode_body)"
  _cpa_vault
  _omp_stub
  local out; out="$(bash "$CEL_ROOT/tools/quota-compare.sh" 2>/dev/null)"
  assert_contains "$out" 'cliproxy'
  assert_contains "$out" 'omp'
  assert_contains "$out" 'one@example.invalid'
  case "$out" in *fixture-cpa-claude-one*)
    printf 'the parity tool printed a token\n' >&2; return 1;; esac
  _quota_stub_stop
  _quota_teardown
}

# ONE ANSWER TO "WHERE ARE THE CREDENTIALS". CEL-60 owns the vault's location
# and publishes `gateway_auth_dir`; a second opinion here would be the
# two-lists failure this ticket exists to end, rebuilt inside one process. With
# no test seam set, the reader must find the accounts `cel gateway status`
# lists.
test_the_vault_is_found_where_cel_gateway_says_it_is() {
  _quota_setup
  _cpa_stub_server "$(_cpa_claude_body)" "$(_codex_body)" "$(_cpa_opencode_body)"
  export CEL_GATEWAY_STATE="$T/gwstate"
  _cpa_vault
  mkdir -p "$CEL_GATEWAY_STATE"
  mv "$CEL_CPA_AUTH_DIR" "$CEL_GATEWAY_STATE/auth"
  unset CEL_CPA_AUTH_DIR
  . "$CEL_ROOT/lib/quota.sh"
  assert_eq "$(_cpa_auth_dir)" "$CEL_GATEWAY_STATE/auth"
  assert_eq "$(subscription_list | jq -r '[.[] | select(.source == "cliproxy")] | length')" 4
  _quota_stub_stop
  _quota_teardown
}

# --- CEL-80 (absorbs CEL-64): merge per account, not per source -------------
#
# #84 made the vault all-or-nothing: the moment CLIProxyAPI held one account,
# omp was skipped entirely, and on 2026-09-23 both Codex accounts and opencode
# fell off `cel quota` because the vault held only Claude. An account is
# provider + email; whichever source can read it answers once.

_cpa_vault_claude_only() {
  export CEL_CPA_AUTH_DIR="$T/cpa-auth"
  mkdir -p "$CEL_CPA_AUTH_DIR"; chmod 700 "$CEL_CPA_AUTH_DIR"
  # CLIProxyAPI's real Claude file carries the email and NO uuid: the live
  # vault on 2026-09-25 had `email` + `type` only, so the join is by email.
  local n
  for n in one two; do
    jq -nc --arg n "$n" '{type: "claude", access_token: ("fixture-cpa-claude-" + $n),
      refresh_token: "r", expire: "2099-01-01T00:00:00Z",
      email: ($n + "@example.invalid")}' \
      > "$CEL_CPA_AUTH_DIR/claude-$n@example.invalid.json"
  done
  printf '%s\n' fixture-cpa-claude-one fixture-cpa-claude-two > "$T/fresh"
}

test_every_account_from_either_source_appears_exactly_once() {
  _quota_setup
  _cpa_stub_server "$(cat "$(fixture anthropic-oauth-usage.json)")" "$(_codex_body)" '{}'
  _cpa_vault_claude_only
  _omp_stub
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list 2>/dev/null)"
  # omp knows claude one/two/three, two codex and opencode; the vault knows
  # claude one/two. Six accounts, each once.
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" 6
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | .provider + "|" + .label] | unique | length')" 6
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "codex")] | length')" 2
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "opencode")] | length')" 1
  # the vault answers for the accounts it holds
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.provider == "claude" and .source == "cliproxy")] | length')" 2
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.label == "three@example.invalid") | .source')" omp
  _quota_stub_stop
  _quota_teardown
}

# The live Anthropic answer, captured 2026-09-25 with the numbers changed: a
# dozen codename keys, most null, one (`nimbus_quill`) a real object with a
# null reset - and the authoritative `.limits[]` beside them. Reading the keys
# printed `nimbus_quill 0% (resets Nimbus Quill)` and lost Fable.
test_the_claude_reader_maps_limits_and_ignores_codename_keys() {
  _quota_setup
  _cpa_stub_server "$(cat "$(fixture anthropic-oauth-usage.json)")" "$(_codex_body)" '{}'
  _cpa_vault_claude_only
  . "$CEL_ROOT/lib/quota.sh"
  local row; row="$(subscription_list 2>/dev/null | jq -c '.[] | select(.label == "one@example.invalid")')"
  assert_eq "$(printf '%s' "$row" | jq -r '[.windows[] | .name + (if .scope then " " + .scope else "" end)] | join(",")')" \
    '5h,7d,7d Fable'
  assert_eq "$(printf '%s' "$row" | jq -r '.windows[] | select(.scope == "Fable") | .used_pct')" 31
  case "$row" in *nimbus*|*Nimbus*) printf 'a codename key became a window: %s\n' "$row" >&2; return 1;; esac
  _quota_stub_stop
  _quota_teardown
}

# opencode's real auth file is keyed `opencode-go` and holds a `key`, and its
# usage answer is `{usage: {rolling, weekly, monthly}}` - neither of which the
# CEL-61 reader looked for, so the row silently vanished on the live box.
test_opencode_reads_its_real_auth_and_usage_shapes_beside_the_vault() {
  _quota_setup
  _cpa_stub_server "$(cat "$(fixture anthropic-oauth-usage.json)")" "$(_codex_body)" \
    '{"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2026-09-18T09:00:40.089Z"},"weekly":{"status":"ok","percent":17,"resetsAt":"2026-09-21T00:00:00.000Z"},"monthly":{"status":"ok","percent":97,"resetsAt":"2026-09-30T04:41:25.000Z"}}}'
  _cpa_vault_claude_only
  mkdir -p "$HOME/.local/share/opencode"
  jq -nc '{"opencode-go": {type: "api", key: "fixture-opencode-go-key"}}' > "$HOME/.local/share/opencode/auth.json"
  printf 'fixture-opencode-go-key\n' >> "$T/fresh"
  . "$CEL_ROOT/lib/quota.sh"
  local out; out="$(subscription_list 2>/dev/null)"
  local row; row="$(printf '%s' "$out" | jq -c '.[] | select(.provider == "opencode")')"
  assert_eq "$(printf '%s' "$row" | jq -r '[.windows[] | .name + "=" + (.used_pct | tostring)] | join(",")')" '5h=4,7d=17,monthly=97'
  case "$out" in *fixture-opencode-go-key*) printf 'printed the opencode key\n' >&2; return 1;; esac
  _quota_stub_stop
  _quota_teardown
}

# The check #84 should have passed before it became the default: every
# account and window omp reports must be in the merged list.
test_quota_compare_gate_fails_when_the_merge_loses_an_omp_window() {
  _quota_setup
  _cpa_stub_server "$(cat "$(fixture anthropic-oauth-usage.json)")" "$(_codex_body)" '{}'
  _cpa_vault_claude_only
  _omp_stub
  local out rc=0
  out="$(bash "$CEL_ROOT/tools/quota-compare.sh" --gate 2>&1)" || rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" 'gate: ok'
  # a merged list that drops an omp account fails the gate
  rc=0
  out="$(CEL_QUOTA_COMPARE_MERGED='[]' bash "$CEL_ROOT/tools/quota-compare.sh" --gate 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" 'missing'
  _quota_stub_stop
  _quota_teardown
}

# CREDIT IS READ WITH THE KEY OF THE WORKSPACE THAT OWNS IT (CEL-80). From
# plane, `cel quota` printed "no key in this workspace" for OpenRouter and
# DeepSeek while the workspaces holding those keys sat one directory away.
# Every workspace that owns a key gets its own balance row.
test_credit_is_shown_for_every_workspace_that_owns_a_key() {
  _quota_setup
  _quota_manifest_stub
  unset CEL_TEST_PRESENT_KEY
  mkdir -p "$T/ws-alpha" "$T/ws-beta"
  printf 'name: alpha\nkind: personal\n' > "$T/ws-alpha/workspace.yaml"
  printf 'name: beta\nkind: personal\n' > "$T/ws-beta/workspace.yaml"
  printf 'CEL_TEST_ABSENT_KEY=fixture-beta-key\n' > "$T/ws-beta/env.local"
  printf 'workspaces:\n  alpha: {path: "%s/ws-alpha"}\n  beta: {path: "%s/ws-beta"}\n' "$T" "$T" > "$T/registry.yaml"
  export CEL_REGISTRY="$T/registry.yaml"
  cat > "$T/qstub" <<'EOF2'
#!/usr/bin/env bash
printf 42
EOF2
  chmod +x "$T/qstub"; export CEL_QUOTA_STUB="$T/qstub"
  . "$CEL_ROOT/lib/quota.sh"
  cd "$T/ws-alpha"
  local js; js="$(cmd_quota --json 2>/dev/null)"
  assert_eq "$(printf '%s' "$js" | jq -r '.balances[] | select(.provider == "nokeyhere") | .workspace')" beta
  assert_eq "$(printf '%s' "$js" | jq -r '.balances[] | select(.provider == "nokeyhere") | .state')" ok
  local out; out="$(cmd_quota 2>/dev/null)"
  assert_contains "$out" beta
  case "$out" in *'nokeyhere'*'no key in this workspace'*)
    printf 'read the balance with the wrong workspace key:\n%s\n' "$out" >&2; return 1;; esac
  case "$js$out" in *fixture-beta-key*) printf 'printed a key\n' >&2; return 1;; esac
  _quota_teardown
}
