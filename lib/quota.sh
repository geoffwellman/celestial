# shellcheck shell=bash
# cel quota - how much credit a provider has left, asked of the provider.
#
# "The key is set" is not "the account can pay". Ask for the remaining balance
# before spawning a pane and veto a route that cannot finish the job.
# Never a hard dependency: any failure to learn the number is `unknown`,
# and unknown NEVER vetoes.
#
# Per-provider shape lives in agents.yaml providers.<p>.balance:
#   url        GET endpoint, bearer-authenticated with the provider's key_env
#   jq         expression over the response producing a NUMBER of `unit`
#   available  optional jq producing a boolean; false is a veto on its own
#   unit       usd (informational)
#   floor      below this the route is vetoed
# Cached five minutes under ~/.local/share/cel/quota/, keyed by provider, so a
# steward tick or a burst of delegations does not hammer anyone's API.
[ -n "${_CEL_QUOTA:-}" ] && return 0
_CEL_QUOTA=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/manifest.sh
. "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"

_quota_dir() { printf '%s' "${CEL_QUOTA_DIR:-$HOME/.local/share/cel/quota}"; }
_QUOTA_TTL="${CEL_QUOTA_TTL:-300}"

provider_balance() { # <provider> <key>
  yq -r --arg p "$1" --arg k "$2" '.providers[$p].balance[$k] // "" | tostring' "$CEL_MANIFEST"
}

# Read the provider key with workspace overrides in a subshell. The caller's
# environment is the fallback, but workspace overrides never leak back into
# it or into a later workspace. An absent key is handled by the caller.
_quota_key() { # <provider> [wsdir]
  local keyenv; keyenv="$(provider_get "$1" key_env)"
  [ -n "$keyenv" ] || return 0
  local d="${2:-}"
  [ -n "$d" ] || d="$(ws_current 2>/dev/null || true)"
  ( set +u
    [ -n "$d" ] && eval "$(ws_env_exports "$d" 2>/dev/null)" >/dev/null 2>&1
    printf '%s' "${!keyenv:-}" )
}

# <number> | unknown. Number is the remaining credit in the provider's unit,
# possibly negative (DeepSeek reports overdrawn accounts as such). `unknown`
# for: no balance config, no key, network failure, unparseable response.
quota_remaining() { # <provider> [wsdir]
  local p="$1" d="${2:-}"
  # test seam: a script that prints a number or `unknown`
  if [ -n "${CEL_QUOTA_STUB:-}" ]; then "$CEL_QUOTA_STUB" "$p" 2>/dev/null || printf unknown; return 0; fi
  local url jqx avail
  url="$(provider_balance "$p" url)"; jqx="$(provider_balance "$p" jq)"; avail="$(provider_balance "$p" available)"
  [ -n "$url" ] && [ -n "$jqx" ] || { printf unknown; return 0; }

  # The KEY decides the account, so the cache is per provider AND per key
  # (by fingerprint, never the key itself): two workspaces with different
  # keys are different accounts, and a workspace with no key must read
  # `unknown` rather than borrow a neighbour's balance.
  local key; key="$(_quota_key "$p" "$d")"
  [ -n "$key" ] || { printf unknown; return 0; }
  local fp; fp="$(printf '%s' "$key" | sha256sum | cut -c1-12)"
  local cache="$(_quota_dir)/$p.$fp"
  if [ -f "$cache" ]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    [ "$age" -lt "$_QUOTA_TTL" ] && { cat "$cache"; return 0; }
  fi
  local resp; resp="$(printf 'Authorization: Bearer %s\n' "$key" |
    curl -sf -m 10 "$url" -H @- 2>/dev/null || true)"
  [ -n "$resp" ] || { printf unknown; return 0; }

  local n
  n="$(printf '%s' "$resp" | jq -r "$jqx" 2>/dev/null || true)"
  # a provider that says "not available" outright is exhausted whatever the
  # number reads - report the floor-breaking value so callers need one rule
  if [ -n "$avail" ] && [ "$(printf '%s' "$resp" | jq -r "$avail" 2>/dev/null || echo true)" = "false" ]; then
    case "$n" in ''|null) n=0;; esac
  fi
  case "$n" in
    ''|null) printf unknown; return 0;;
    *[!0-9.eE+-]*) printf unknown; return 0;;
  esac
  mkdir -p "$(_quota_dir)"; printf '%s' "$n" > "$cache"
  printf '%s' "$n"
}

# --- SUBSCRIPTIONS ----------------------------------------------------------
#
# A key with credit on it is only half of what the fleet spends. The other
# half is two SIGNED-IN SUBSCRIPTIONS - Claude (Max, through Claude Code and
# through pi's OAuth) and Codex (ChatGPT, through omp) - and until CEL-27
# nothing on the plane could see either. The owner, 2026-09-18: "we need to be
# able to monitor the signed-in subscriptions for Codex and Claude". A five
# hour window at 100% stops every worker on that account just as hard as an
# empty balance does, and it does it without a single error message anywhere
# the operator looks.
#
# A TOKEN IS NEVER PRINTED, ANYWHERE. These are live bearer credentials for
# the owner's own accounts, and this file is read by `cel quota`, by the
# steward's mail, by the console's status edge and by a dashboard served over
# a tailnet. An account is identified by provider plus a short stable id:
# Codex hands us an `account_id`, Anthropic's endpoint carries no account
# field at all, so the id there is the first six hex of the token's sha256 -
# stable across a run, meaningless to anyone who reads it.
_sub_cache_dir() { printf '%s' "${CEL_CACHE:-$HOME/.cache/cel}"; }
_SUB_TTL="${CEL_SUB_TTL:-60}"

# Measured on this box 2026-09-18: pi's stored OAuth token answers Anthropic's
# usage endpoint with both windows, and that was one curl away.
_SUB_ANTHROPIC_URL="${CEL_SUB_ANTHROPIC_URL:-https://api.anthropic.com/api/oauth/usage}"
# Read out of the Codex binary (0.153.2) rather than guessed: the CLI's own
# rate-limit display is served by `<chatgpt base>/wham/usage`, which answers a
# `RateLimitSnapshot` - `primary` and `secondary` RateLimitWindows of
# used_percent / window_minutes / resets_at. It is a GET and it changes
# nothing, so no inference has to be bought to read it.
_SUB_CODEX_URL="${CEL_SUB_CODEX_URL:-https://chatgpt.com/backend-api/wham/usage}"

# THE BROKER KNOWS MORE ACCOUNTS THAN THE FILE DOES. ~/.codex/auth.json holds
# whichever ChatGPT account the Codex CLI logged in as last; omp's auth-broker
# holds every credential the fleet actually routes through, and its gateway
# reports usage per account. So the gateway is preferred WHEN IT IS UP, and
# the Codex endpoint above is the fallback - a box with no broker configured
# is the normal case, not an error.
_SUB_GATEWAY_URL="${CEL_SUB_GATEWAY_URL:-}"

# The gateway's base, or nothing at all. `status --json` is the only thing
# asked of omp here: it is local, it does not spend a token, and `ready:false`
# is the answer on a box where the broker was never set up.
_sub_gateway_base() {
  [ -z "$_SUB_GATEWAY_URL" ] || { printf '%s' "$_SUB_GATEWAY_URL"; return 0; }
  command -v omp >/dev/null 2>&1 || return 0
  local st; st="$(omp auth-gateway status --json 2>/dev/null || true)"
  [ -n "$st" ] || return 0
  [ "$(printf '%s' "$st" | jq -r '.ready // false' 2>/dev/null || echo false)" = true ] || return 0
  printf '%s' "$(printf '%s' "$st" | jq -r '.url // .bind // empty' 2>/dev/null || true)"
}

_sub_fp() { printf '%s' "$1" | sha256sum | cut -c1-6; }

# provider<TAB>account<TAB>token, for the callers that have to spend the
# token. INTERNAL: everything an operator can see goes through
# subscription_list, which drops the third column.
_subscription_accounts() {
  local pi_tok cc_tok cx_tok cx_acct
  pi_tok="$(jq -r '.anthropic.access // empty' "$HOME/.pi/agent/auth.json" 2>/dev/null || true)"
  cc_tok="$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null || true)"
  cx_tok="$(jq -r '.tokens.access_token // empty' "$HOME/.codex/auth.json" 2>/dev/null || true)"
  cx_acct="$(jq -r '.tokens.account_id // empty' "$HOME/.codex/auth.json" 2>/dev/null || true)"

  if [ -n "$pi_tok" ]; then printf 'claude\t%s\t%s\n' "$(_sub_fp "$pi_tok")" "$pi_tok"; fi
  # TWO TOKENS, ONE ACCOUNT, usually. pi refreshes its own copy of the owner's
  # Claude OAuth and Claude Code keeps another; the same subscription read
  # twice would double every window on the display and halve nobody's trust in
  # it. Same token, one row; different tokens, two accounts, because that is
  # what two different tokens mean.
  if [ -n "$cc_tok" ] && [ "$cc_tok" != "$pi_tok" ]; then
    printf 'claude\t%s\t%s\n' "$(_sub_fp "$cc_tok")" "$cc_tok"
  fi
  if [ -n "$cx_tok" ]; then
    printf 'codex\t%s\t%s\n' "${cx_acct:-$(_sub_fp "$cx_tok")}" "$cx_tok"
  fi
  # ...and every OTHER ChatGPT account the broker holds. The file names one;
  # the fleet routes through whatever omp has, and an account nobody can see
  # is an account whose wall arrives as a mystery. The token column is empty
  # for these: their usage is read through the gateway, which holds the
  # credential itself and never hands it out.
  local gacct
  for gacct in $(_sub_gateway_accounts); do
    [ "$gacct" = "$cx_acct" ] && continue
    printf 'codex\t%s\t\n' "$gacct"
  done
  return 0
}

# The codex account ids the broker holds, or nothing when the gateway is down.
_sub_gateway_accounts() {
  local gw; gw="$(_sub_gateway_base)"
  [ -n "$gw" ] || return 0
  local resp; resp="$(printf 'authorization: Bearer %s\n' "$(omp auth-gateway token 2>/dev/null || true)" |
    curl -sf -m 10 "${gw%/}/v1/usage" -H @- 2>/dev/null || true)"
  [ -n "$resp" ] || return 0
  printf '%s' "$resp" | jq -r '
    ((.accounts // .usage // .) | if type == "array" then . else [.] end)
    | .[]? | (.account_id // .account // empty)' 2>/dev/null || true
  return 0
}

# One line per signed-in account: `<provider>\t<account>`. No token, ever.
subscription_list() {
  _subscription_accounts | cut -f1,2
}

# {provider, account, windows: [{name, used_pct, resets_at}], extra: {state, reason}}
# for one account, cached 60 s. A failure to ask is an EMPTY windows list, not
# an error and not a zero: the whole point of the fleet path is that it can
# always draw, and `unknown` never vetoes anything (see quota_remaining).
subscription_usage() { # <provider> <token> [account]
  local p="$1" tok="$2" acct="${3:-}"
  [ -n "$acct" ] || acct="$(_sub_fp "$tok")"
  local cache; cache="$(_sub_cache_dir)/subscription-$p-$acct.json"
  if [ -f "$cache" ]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$_SUB_TTL" ]; then cat "$cache"; return 0; fi
  fi

  local resp="" doc=""
  case "$p" in
    claude)
      # The token goes in on STDIN, never on the command line: an argv is
      # world-readable in /proc for as long as the process lives.
      resp="$(printf 'authorization: Bearer %s\n' "$tok" |
        curl -sf -m 10 "$_SUB_ANTHROPIC_URL" -H @- \
          -H 'anthropic-beta: oauth-2025-04-20' 2>/dev/null || true)"
      [ -n "$resp" ] && doc="$(printf '%s' "$resp" | jq -c --arg a "$acct" '
        {provider: "claude", account: $a,
         windows: ([{name: "5h", used_pct: (.five_hour.utilization // null),
                     resets_at: (.five_hour.resets_at // null)},
                    {name: "7d", used_pct: (.seven_day.utilization // null),
                     resets_at: (.seven_day.resets_at // null)}]
                   | map(select(.used_pct != null))),
         extra: {state: (if (.extra_usage.disabled_reason // null) != null
                         then "disabled" else "enabled" end),
                 reason: (.extra_usage.disabled_reason // "")}}' 2>/dev/null || true)"
      ;;
    codex)
      local gw; gw="$(_sub_gateway_base)"
      if [ -n "$gw" ]; then
        resp="$(printf 'authorization: Bearer %s\n' "$(omp auth-gateway token 2>/dev/null || true)" |
          curl -sf -m 10 "${gw%/}/v1/usage" -H @- 2>/dev/null || true)"
        # The gateway answers for EVERY account the broker holds, so the one
        # this call is about has to be picked out of the list; anything else
        # would report a neighbouring account's window as this one's.
        [ -n "$resp" ] && resp="$(printf '%s' "$resp" | jq -c --arg a "$acct" '
          ((.accounts // .usage // .) | if type == "array" then . else [.] end)
          | (map(select((.account_id // .account // "") == $a)) | first) // empty' \
          2>/dev/null || true)"
      fi
      [ -n "$resp" ] || resp="$(printf 'authorization: Bearer %s\n' "$tok" |
        curl -sf -m 10 "$_SUB_CODEX_URL" -H @- \
          -H "chatgpt-account-id: $acct" -H 'originator: codex_cli_rs' 2>/dev/null || true)"
      # `window_minutes` names the window, not the order of the fields: Codex
      # calls them primary and secondary, and which of those is the five hour
      # one is a decision nobody should have to remember.
      [ -n "$resp" ] && doc="$(printf '%s' "$resp" | jq -c --arg a "$acct" '
        ((.rate_limits // .) as $r
         | {provider: "codex", account: $a,
            windows: ([$r.primary, $r.secondary] | map(select(. != null))
                      | map({name: (if (.window_minutes // 0) >= 10080 then "7d"
                                    elif (.window_minutes // 0) >= 1440 then "1d"
                                    else "5h" end),
                             used_pct: (.used_percent // null),
                             resets_at: (.resets_at
                                         // (if .resets_in_seconds
                                             then (now + .resets_in_seconds | todate)
                                             else null end))})
                      | map(select(.used_pct != null))),
            extra: {state: (if ($r.credits.has_credits // true) then "enabled"
                            else "disabled" end),
                    reason: ($r.rate_limit_reached_type // "")}})' 2>/dev/null || true)"
      ;;
  esac

  if [ -z "$doc" ]; then
    # NOT CACHED. A cached failure would hold for the next sixty seconds and
    # turn one flaky read into a minute of blindness.
    jq -nc --arg p "$p" --arg a "$acct" \
      '{provider: $p, account: $a, windows: [], extra: {state: "unknown", reason: ""}}'
    return 0
  fi
  # 0700 ON THE DIRECTORY, 0600 ON THE FILE. These answers are derived from a
  # credentialed request against the owner's own accounts: they carry no token,
  # but they do carry when each account is spent, which is exactly the thing
  # you would want to know before deciding whether a box is worth attacking.
  # A normal umask of 022 would leave them world-readable, so the mode is set
  # rather than inherited.
  mkdir -p "$(_sub_cache_dir)"
  chmod 700 "$(_sub_cache_dir)" 2>/dev/null || true
  printf '%s' "$doc" > "$cache"
  chmod 600 "$cache" 2>/dev/null || true
  printf '%s' "$doc"
}

# Every signed-in account's usage, one JSON object per line. This is what
# `cel quota`, the steward and `cel fleet` all read.
subscription_all() {
  local p a t
  while IFS=$'\t' read -r p a t; do
    [ -n "$p" ] || continue
    subscription_usage "$p" "$t" "$a"
    printf '\n'
  done < <(_subscription_accounts)
}

# Which subscription, if any, a cel provider spends. `anthropic` is the OAuth
# route (pi's `claude-*` models and the `claude` runtime both sign in as the
# owner); `openai-codex` is omp's ChatGPT login. Everything else is an API key
# and has a balance instead.
_sub_provider_for() { # <cel-provider>
  case "$1" in
    anthropic) printf claude ;;
    openai-codex) printf codex ;;
    *) : ;;
  esac
}

# A human reset: today is a clock time, anything further out carries its day.
# Local time, always - "resets 19:00" is a decision about this evening and
# nobody converts UTC in their head correctly at the moment they need to.
sub_reset_human() { # <iso8601>
  [ -n "${1:-}" ] || return 0
  local at now
  at="$(date -d "$1" +%s 2>/dev/null || true)"
  [ -n "$at" ] || { printf '%s' "$1"; return 0; }
  now="$(date +%s)"
  if [ $((at - now)) -lt 86400 ]; then date -d "@$at" +%H:%M
  else date -d "@$at" '+%a %H:%M'; fi
}

# Is this provider's subscription spent? Prints the refusal, with the reset
# time in it, and returns 0 when it is - so a caller can `if
# subscription_veto anthropic; then` and have the sentence to say.
#
# The rule is the FIVE HOUR window at 100%, because that is the one that stops
# work now; a seven day window at 100% is the same wall but the reset an
# operator can act on is the short one. Extra usage that is the only remaining
# path and is disabled counts as spent for the same reason.
subscription_veto() { # <cel-provider>
  local sub; sub="$(_sub_provider_for "$1")"
  [ -n "$sub" ] || return 1
  local p a t line pct resets state
  while IFS=$'\t' read -r p a t; do
    [ "$p" = "$sub" ] || continue
    line="$(subscription_usage "$p" "$t" "$a")"
    IFS=$'\t' read -r pct resets state <<< "$(printf '%s' "$line" | jq -r '
      [((.windows[] | select(.name == "5h") | .used_pct) // -1),
       ((.windows[] | select(.name == "5h") | .resets_at) // ""),
       (.extra.state // "unknown")] | @tsv' 2>/dev/null || true)"
    case "$pct" in ''|-1) continue ;; esac
    if awk -v p="$pct" 'BEGIN { exit !(p+0 >= 100) }'; then
      printf '%s subscription %s has spent its 5h window (100%%)%s - it resets at %s.' \
        "$1" "$a" \
        "$([ "$state" = disabled ] && printf ' and extra usage is disabled' || true)" \
        "$(sub_reset_human "$resets")"
      return 0
    fi
  done < <(_subscription_accounts)
  return 1
}

# Is this provider out of road? 0 = vetoed.
#
# TWO KINDS OF EMPTY, ONE ANSWER. A key below its floor and a subscription
# window at 100% both mean "a worker sent here dies mid-flight", and every
# caller of this function already knows what to do with a veto. The
# subscription check goes first because a provider can have both (an API key
# with credit AND an OAuth login) and the window is what actually stops work.
# SUBSCRIPTION_VETO carries the sentence, with the reset time, for a caller
# that has something to say to a human.
quota_vetoed() { # <provider> <remaining>
  SUBSCRIPTION_VETO=""
  local msg=""
  if msg="$(subscription_veto "$1")" && [ -n "$msg" ]; then
    SUBSCRIPTION_VETO="$msg"
    return 0
  fi
  local floor; floor="$(provider_balance "$1" floor)"
  [ -n "$floor" ] || return 1
  [ "$2" = unknown ] && return 1
  awk -v r="$2" -v f="$floor" 'BEGIN { exit !(r+0 < f+0) }'
}

# `5h 16% (resets 19:00)   7d 41% (resets Sat 05:00)   extra: out of credits`
_sub_line() { # <usage-json>
  local out="" n p r
  while IFS=$'\t' read -r n p r; do
    [ -n "$n" ] || continue
    out="$out$(printf '%s %s%%%s   ' "$n" "$(printf '%.0f' "$p")" \
      "$([ -n "$r" ] && printf ' (resets %s)' "$(sub_reset_human "$r")" || true)")"
  done < <(printf '%s' "$1" | jq -r '.windows[]? | [.name, (.used_pct // 0), (.resets_at // "")] | @tsv')
  local state reason
  IFS=$'\t' read -r state reason <<< "$(printf '%s' "$1" | jq -r '[(.extra.state // ""), (.extra.reason // "")] | @tsv')"
  [ "$state" = disabled ] && out="${out}extra: ${reason//_/ }"
  [ "$state" = unknown ] && out="${out}unreadable (not signed in here, or the endpoint is down)"
  printf '%s' "$out"
}


cmd_quota() { # [provider] [--json]
  local json=0 only=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help) printf 'usage: cel quota [provider] [--json]\n'; return 0 ;;
      *) only="$1"; shift ;;
    esac
  done
  local wsdir; wsdir="$(ws_current 2>/dev/null || true)"

  # SUBSCRIPTIONS FIRST, because they are what the fleet actually runs on: the
  # API balances underneath are the fallback routes, and reading the cheap
  # thing before the expensive one is the wrong order for a decision.
  local subs; subs="$(subscription_all | jq -sc .)"
  if [ "$json" -eq 1 ]; then
    local bal="[]" p
    for p in $(_quota_providers "$only"); do
      bal="$(printf '%s' "$bal" | jq -c --arg p "$p" \
        --arg r "$(quota_remaining "$p" "$wsdir")" \
        --arg f "$(provider_balance "$p" floor)" \
        --arg u "$(provider_balance "$p" unit)" \
        '. + [{provider: $p, remaining: $r, floor: $f, unit: $u}]')"
    done
    jq -nc --argjson s "$subs" --argjson b "$bal" '{subscriptions: $s, balances: $b}'
    return 0
  fi

  printf '  %-9s %-14s %s\n' SUBSCRIPTION ACCOUNT WINDOWS
  if [ "$(printf '%s' "$subs" | jq -r 'length')" = 0 ]; then
    printf '  none - no signed-in Claude or Codex credential on this box\n'
  fi
  local row acct
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    # The account is an IDENTIFIER, not a fact anyone reads in full: Codex's
    # is a 36-character uuid, and left whole it pushed every window off the
    # right of the table. Twelve characters still tell two accounts apart.
    acct="$(printf '%s' "$row" | jq -r '.account')"
    printf '  %-9s %-14s %s\n' \
      "$(printf '%s' "$row" | jq -r '.provider')" \
      "${acct:0:12}" \
      "$(_sub_line "$row")"
  done < <(printf '%s' "$subs" | jq -c '.[]')
  printf '\n'

  _quota_balances "$only" "$wsdir"
}

# The providers `cel quota` reports a balance for: one named, or every
# provider that declares one.
_quota_providers() { # [provider]
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  yq -r '.providers | to_entries[] | select(.value.balance != null) | .key' "$CEL_MANIFEST"
}

_quota_balances() { # [provider] [wsdir]
  local wsdir="${2:-}"
  local p list
  if [ -n "${1:-}" ]; then list="$1"; else
    list="$(yq -r '.providers | to_entries[] | select(.value.balance != null) | .key' "$CEL_MANIFEST")"
  fi
  printf '  %-12s %-14s %-8s %s\n' PROVIDER REMAINING FLOOR STATE
  local r floor st
  for p in $list; do
    r="$(quota_remaining "$p" "$wsdir")"; floor="$(provider_balance "$p" floor)"
    if [ "$r" = unknown ]; then st="unknown (no key here, or endpoint unreachable)"
    elif quota_vetoed "$p" "$r"; then st="VETOED - below floor; workers will not be sent here"
    else st="ok"; fi
    [ "$r" = unknown ] || r="$(printf '%.2f' "$r")"
    printf '  %-12s %-14s %-8s %s\n' "$p" "$r $(provider_balance "$p" unit)" "${floor:--}" "$st"
  done
}
