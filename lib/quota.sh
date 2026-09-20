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

# WHY A CREDIT READ CAME BACK EMPTY. `unknown` answered two different
# questions with one word: "there is no key for this provider in this
# workspace" - a fact about where you are standing, and correct, since CEL-49
# left credit workspace-scoped on purpose - and "I asked and could not tell",
# which is a fault. An operator who cannot tell those apart reads every
# workspace without an OpenRouter key as broken.
#
#   ok      a number was read
#   no_key  this provider declares a balance and this workspace has no key
#   unknown asked and could not tell (or the provider declares no balance)
quota_state() { # <provider> [wsdir] [remaining]
  local p="$1" d="${2:-}" r="${3:-}"
  local url jqx; url="$(provider_balance "$p" url)"; jqx="$(provider_balance "$p" jq)"
  if [ -n "$url" ] && [ -n "$jqx" ] && [ -z "$(_quota_key "$p" "$d")" ]; then
    printf no_key; return 0
  fi
  [ -n "$r" ] || r="$(quota_remaining "$p" "$d")"
  [ "$r" = unknown ] && { printf unknown; return 0; }
  printf ok
}

# How that state reads to a human. One word each was the whole requirement.
quota_state_human() { # <state>
  case "$1" in
    no_key) printf 'unknown - no key in this workspace' ;;
    unknown) printf 'unknown - asked and could not tell' ;;
    *) printf ok ;;
  esac
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
# a tailnet.
#
# AN ACCOUNT IS WHERE IT IS SIGNED IN, NOT WHICH TOKEN IT HOLDS. CEL-27 named
# a Claude account by the first six hex of its token's sha256, and pi refreshes
# that token whenever it feels like it: every refresh minted a new "account",
# a new `subscription-claude-<fp>.json` and a new row on every surface that
# lists that directory. The owner, 2026-09-19: "somehow we are showing 4
# claude subscriptions? there are only 3 I've signed into." So the identity is
# the credential's HOME - `claude/pi`, `claude/claude-code`,
# `codex/<account_id>`, `gateway/<provider>/<short id>` - which survives a
# refresh, and the cache file keyed by it is OVERWRITTEN rather than joined by
# a sibling. Files that match no current identity are swept on the next list,
# which is also the one-off migration for the five that existed when this
# landed.
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

# THE BOX ALREADY KNOWS. CEL-49: every symptom the owner reported on
# 2026-09-20 - Codex reading `unreadable`, Fable missing, one Anthropic
# account of three missing, opencode absent - was cel reading a file it hoped
# was fresh while `omp usage --json` sat on PATH holding REFRESHED OAUTH PER
# ACCOUNT and answering for all of them in one call. ~/.codex/auth.json last
# refreshed 2026-09-04 and that endpoint answers `401 token_expired`; no
# amount of parsing fixes a stale token.
#
# So omp is the source when it is there, and the per-provider endpoint reads
# below are the fallback for a box without it - which is the normal case for
# this repo, and must degrade to exactly the old behaviour, never to an error.
_sub_omp_usage() {
  command -v omp >/dev/null 2>&1 || return 0
  omp usage --json 2>/dev/null || true
}

# The rows omp's document becomes. `.limits[]` is the AUTHORITATIVE window
# list - the old jq read the `.five_hour`/`.seven_day` subset and so lost
# every scoped window, of which Fable is one; naming Fable here would lose
# the next one - and each limit carries {label, window:{id,label,durationMs,
# resetsAt}, amount:{used,limit,remaining,usedFraction,unit}, status}, which
# is exactly the shape a bar needs.
_sub_omp_rows() {
  local raw; raw="$(_sub_omp_usage)"
  [ -n "$raw" ] || return 0
  printf '%s' "$raw" | jq -c '
    def iso: if . == null then null
             elif type == "number"
             then ((if . > 100000000000 then . / 1000 else . end) | floor | todate)
             else . end;
    def wname($id; $ms): if $ms == null or $ms == 0 then ($id // "window")
                         elif $ms >= 604800000 then "7d"
                         elif $ms >= 86400000 then "1d"
                         else "5h" end;
    ((.accounts // .usage // .) | if type == "array" then . else [.] end)[]
    | select(type == "object")
    | . as $a
    | ((.provider // "unknown") | ascii_downcase) as $p
    | {provider: (if $p == "anthropic" or $p == "claude" then "claude"
                  elif $p == "openai-codex" or $p == "codex" or $p == "chatgpt" then "codex"
                  else $p end),
       account: ((.accountId // .account_id // .id // .account // "?") | tostring),
       label: ((.email // .accountEmail // .label // .accountId // .account_id // .id // "?") | tostring),
       source: "omp",
       windows: [ (.limits // .windows // .report.limits // [])[]
                  | select(type == "object")
                  | . as $w
                  | (($w.amount.usedFraction // $w.amount.used_fraction
                      // (if (($w.amount.limit // 0) > 0) and ($w.amount.used != null)
                          then ($w.amount.used / $w.amount.limit) else null end))) as $f
                  | select($f != null)
                  | {name: wname(($w.window.id // $w.window.label // $w.label);
                                 ($w.window.durationMs // $w.window.duration_ms)),
                     scope: ($w.scope.model.display_name // $w.scope.model.displayName
                             // $w.scope.label // $w.scope.name // null),
                     used_pct: ($f * 100),
                     resets_at: (($w.window.resetsAt // $w.window.resets_at // $w.resetsAt // null) | iso)} ],
       extra: (($a.extra_usage.disabled_reason // $a.extraUsage.disabledReason // null) as $dr
               | if $dr != null
                 then {state: "disabled",
                       reason: (if (($a.spend.enabled // false) == false)
                                then "top-up is off" else ($dr | gsub("_"; " ")) end)}
                 elif ($a.ok // true) == false
                 then {state: "unreadable",
                       reason: ($a.error // "the broker reports this credential as failing")}
                 else {state: "enabled", reason: ""} end)}
    | select((.windows | length) > 0 or (.extra.state != "enabled"))' 2>/dev/null || true
  return 0
}

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

# A DISPLAY LABEL IS NOT AN IDENTITY. The identity is where the credential
# lives; the label is whatever stable account field the file itself carries -
# an email, an account id, an org - because `pi` tells an operator which
# runtime holds the token and `someone@example.invalid` tells them which
# subscription it is. Absent, the identity is the label.
_sub_label_from() { # <file> <jq-path> <fallback>
  local v; v="$(jq -r "$2 // empty" "$1" 2>/dev/null || true)"
  printf '%s' "${v:-$3}"
}

# provider<TAB>account<TAB>token<TAB>label, one line per credential FILE on
# this box. INTERNAL, and frozen at three columns for `_subscription_accounts`
# below, which the steward reads.
_sub_direct_accounts() {
  local pi_f="$HOME/.pi/agent/auth.json" cc_f="$HOME/.claude/.credentials.json" cx_f="$HOME/.codex/auth.json"
  local pi_tok cc_tok cx_tok cx_acct
  pi_tok="$(jq -r '.anthropic.access // empty' "$pi_f" 2>/dev/null || true)"
  cc_tok="$(jq -r '.claudeAiOauth.accessToken // empty' "$cc_f" 2>/dev/null || true)"
  cx_tok="$(jq -r '.tokens.access_token // empty' "$cx_f" 2>/dev/null || true)"
  cx_acct="$(jq -r '.tokens.account_id // empty' "$cx_f" 2>/dev/null || true)"

  if [ -n "$pi_tok" ]; then
    printf 'claude\tpi\t%s\t%s\n' "$pi_tok" \
      "$(_sub_label_from "$pi_f" '.anthropic.account.email_address // .anthropic.account.email // .anthropic.email' pi)"
  fi
  if [ -n "$cc_tok" ]; then
    printf 'claude\tclaude-code\t%s\t%s\n' "$cc_tok" \
      "$(_sub_label_from "$cc_f" '.claudeAiOauth.account.email_address // .claudeAiOauth.account.email // .claudeAiOauth.email' claude-code)"
  fi
  if [ -n "$cx_tok" ]; then
    local cx_id="${cx_acct:-cli}"
    printf 'codex\t%s\t%s\t%s\n' "$cx_id" "$cx_tok" \
      "$(_sub_label_from "$cx_f" '.tokens.email // .tokens.account_email' "$cx_id")"
  fi
  return 0
}

# provider<TAB>account<TAB>token. FROZEN: lib/steward.sh reads exactly this.
_subscription_accounts() {
  _sub_direct_accounts | cut -f1,2,3
}

# The gateway's accounts, as subscription rows, or nothing at all when there
# is no gateway or the door is shut. CEL-28 put these behind `cel gateway
# status` alone, so the dashboard (which called it) listed them and the
# console (which reads the fleet document) did not: two surfaces, two answers
# to one question. They belong in the list with everything else, and `source`
# says which door they came through.
#
# `check --json` is asked, never `check --strict`: strict probes each
# credential against its provider and SPENDS QUOTA, which is not a thing a
# status read may do behind someone's back.
_sub_gateway_rows() {
  command -v omp >/dev/null 2>&1 || return 0
  # sourced here rather than at the top: lib/gateway.sh pulls in the config and
  # the service registry, and every caller of quota.sh does not need them.
  # shellcheck source=lib/gateway.sh
  . "$(dirname "${BASH_SOURCE[0]}")/gateway.sh"
  gateway_installed || return 0
  gateway_ready || return 0
  local raw; raw="$(gateway_accounts_json 2>/dev/null || true)"
  [ -n "$raw" ] || return 0
  printf '%s' "$raw" | jq -c '.[]? | {
    provider: (.provider // "gateway"),
    account: (.id // "?"),
    label: (.id // "?"),
    source: "gateway",
    windows: [ (.windows // [])[] | select(.used_pct != null) | {
      name: (.label // "window"),
      used_pct: .used_pct,
      # omp reports a reset as epoch MILLISECONDS; every other window on this
      # display is an ISO string, and a bare 1789994511000 on the console was
      # read as a percentage more than once.
      resets_at: (if (.resets_at | type) == "number"
                  then (.resets_at / 1000 | floor | todate)
                  else .resets_at end) } ],
    extra: {state: (if .ok == false then "unreadable"
                    elif ((.windows // []) | map(select(.used_pct != null)) | length) == 0
                    then "unreadable" else "enabled" end),
            reason: (if .ok == false then "the gateway reports this credential as failing"
                     elif ((.windows // []) | map(select(.used_pct != null)) | length) == 0
                     then "no usage probe for this provider" else "" end)} }' 2>/dev/null || true
  return 0
}

# {provider, account, label, source, windows: [{name, used_pct, resets_at}],
#  extra: {state, reason}} for one account, cached 60 s.
#
# A FAILURE TO ASK IS A ROW, NOT A SILENCE. Until CEL-35 an unreadable account
# was left out of the cache entirely, so `cel fleet` never mentioned it and
# the console showed Claude alone while the dashboard (which asked the
# providers itself) showed Codex too. An empty windows list with `state:
# unreadable` and the reason is the version of that an operator can act on,
# and it is cached like any other answer so every surface shows the same row.
subscription_usage() { # <provider> <token> [account] [label]
  local p="$1" tok="$2" acct="${3:-}" label="${4:-}"
  [ -n "$acct" ] || acct="$(_sub_fp "$tok")"
  [ -n "$label" ] || label="$acct"
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
      [ -n "$resp" ] && doc="$(printf '%s' "$resp" | jq -c --arg a "$acct" --arg l "$label" '
        {provider: "claude", account: $a, label: $l, source: "direct",
         windows: ([{name: "5h", used_pct: (.five_hour.utilization // null),
                     resets_at: (.five_hour.resets_at // null)},
                    {name: "7d", used_pct: (.seven_day.utilization // null),
                     resets_at: (.seven_day.resets_at // null)}]
                   | map(select(.used_pct != null))),
         extra: ((.extra_usage.disabled_reason // null) as $dr
                 | if $dr == null then {state: "enabled", reason: ""}
                   # `disabled_reason: out_of_credits` with `spend.enabled:
                   # false` means TOP-UP IS SWITCHED OFF, not "this account is
                   # spent". Saying the second about a healthy account is
                   # worse than saying nothing (CEL-49).
                   else {state: "disabled",
                         reason: (if ((.spend.enabled // false) == false)
                                  then "top-up is off"
                                  else ($dr | gsub("_"; " ")) end)} end)}' 2>/dev/null || true)"
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
      [ -n "$resp" ] && doc="$(printf '%s' "$resp" | jq -c --arg a "$acct" --arg l "$label" '
        ((.rate_limits // .) as $r
         | {provider: "codex", account: $a, label: $l, source: "direct",
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
    # CACHED, deliberately, since CEL-35. A cached failure holds for sixty
    # seconds, which is the price of the row being THERE at all: the row that
    # was missing from the cache was missing from `cel fleet`, from the console
    # and from the steward, and an account nobody can see is an account whose
    # wall arrives as a mystery. The reason travels with it.
    doc="$(jq -nc --arg p "$p" --arg a "$acct" --arg l "$label" \
      '{provider: $p, account: $a, label: $l, source: "direct", windows: [],
        extra: {state: "unreadable",
                reason: "the usage endpoint could not be read - not signed in here, or it is down"}}')"
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

# THE LIST. One JSON array of subscription rows, and the only answer anything
# on this box gives to "which subscriptions does it have": `cel quota --json
# .subscriptions`, `cel fleet --json .subscriptions`, the console's QUOTA view
# and the dashboard's card are all this function, so two surfaces cannot
# disagree about how many accounts are signed in.
#
# `--cached` reads the cache directory and asks nobody: that is the fleet
# path, which is on the console's refresh loop and the dashboard's poll, where
# a provider having a bad afternoon must not put its latency in front of a
# draw.
subscription_list() { # [--cached]
  local dir; dir="$(_sub_cache_dir)"
  if [ "${1:-}" = --cached ]; then
    local f found=""
    for f in "$dir"/subscription-*.json; do
      [ -f "$f" ] || continue
      found="$found$(cat "$f")
"
    done
    printf '%s' "$found" | _sub_fold
    return 0
  fi

  local p a t label rows="" keep=""

  # OMP FIRST, WHEN IT IS THERE. It holds its own refreshed OAuth per account
  # and covers every provider it knows in one call, so for those providers the
  # per-file token reads below are not a second opinion - they are a worse one,
  # and a stale token read beside a fresh one is how an account came to read
  # `unreadable` while the owner's own prompt tool showed it fine.
  local orow op oa omp_providers="" omp_seen=0
  while IFS= read -r orow; do
    [ -n "$orow" ] || continue
    omp_seen=1
    op="$(printf '%s' "$orow" | jq -r '.provider')"
    oa="$(printf '%s' "$orow" | jq -r '.account')"
    case " $omp_providers " in *" $op "*) ;; *) omp_providers="$omp_providers $op" ;; esac
    mkdir -p "$dir"; chmod 700 "$dir" 2>/dev/null || true
    printf '%s' "$orow" > "$dir/subscription-$op-$oa.json"
    chmod 600 "$dir/subscription-$op-$oa.json" 2>/dev/null || true
    rows="$rows$orow
"
    keep="$keep subscription-$op-$oa.json"
  done < <(_sub_omp_rows)

  while IFS=$'\t' read -r p a t label; do
    [ -n "$p" ] || continue
    # a provider omp answered for is answered; anything else still reads its
    # own credential file, so a box where omp knows Claude and not Codex
    # still sees Codex.
    case " $omp_providers " in *" $p "*) continue ;; esac
    rows="$rows$(subscription_usage "$p" "$t" "$a" "$label")
"
    keep="$keep subscription-$p-$a.json"
  done < <(_sub_direct_accounts)

  local row gp ga
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    gp="$(printf '%s' "$row" | jq -r '.provider')"
    ga="$(printf '%s' "$row" | jq -r '.account')"
    mkdir -p "$dir"; chmod 700 "$dir" 2>/dev/null || true
    printf '%s' "$row" > "$dir/subscription-gateway-$gp-$ga.json"
    chmod 600 "$dir/subscription-gateway-$gp-$ga.json" 2>/dev/null || true
    rows="$rows$row
"
    keep="$keep subscription-gateway-$gp-$ga.json"
    # the gateway is the older door onto the same broker: when `omp usage`
    # answered, its rows are that answer already, at one account each.
  done < <(if [ "$omp_seen" -eq 1 ]; then :; else _sub_gateway_rows; fi)

  # THE SWEEP. Every file that is not one of this run's identities is a token
  # hash from before CEL-35 or an account that has been signed out, and both
  # of them are a row on the console for a subscription that does not exist.
  local f base
  for f in "$dir"/subscription-*.json; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case " $keep " in *" $base "*) continue ;; esac
    rm -f "$f"
  done

  printf '%s' "$rows" | _sub_fold
}

# ONE SUBSCRIPTION READ TWICE IS ONE ROW. pi keeps its own copy of the owner's
# Claude OAuth and Claude Code keeps another; two rows for it double every
# window on the display and halve nobody's trust in it. Identical window
# numbers are the evidence that it is one subscription - different numbers are
# two logins, and stay two rows.
#
# Reads JSON objects on stdin, one per line; prints the array, ordered direct
# before gateway so the cached path and the live path draw the same list.
_sub_fold() {
  jq -sc '
    [.[] | select(type == "object")]
    | sort_by((if .source == "gateway" then 1 else 0 end), .provider, .account)
    | (map(select(.source != "gateway" and .provider == "claude"
                  and (.account == "pi" or .account == "claude-code")))) as $c
    | def wk: [.windows[]? | {name, used_pct}] | sort_by(.name);
      if ($c | length) == 2 and (($c[0] | wk) == ($c[1] | wk)) and (($c[0].windows | length) > 0)
      then map(select(((.source != "gateway") and (.provider == "claude")
                       and (.account == "claude-code")) | not))
           | map(if (.source != "gateway" and .provider == "claude" and .account == "pi")
                 then .account = "pi+claude-code" | .label = "pi + claude-code"
                 else . end)
      else . end' 2>/dev/null || printf '[]'
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

# A BAR, IN THE ONE PLACE BASH DRAWS ONE. The rule is the renderer's rule in
# tools/console/views.mjs and it is the same rule for a reason: a filled
# prefix of a fixed-width track, 100% the only percentage that fills it, so
# "the next delegation refuses" never looks like "there is room for one more";
# and never wider than the track, because a bar that wraps is worse than no
# bar. A track too narrow to be honest draws nothing and the text stands alone.
sub_bar() { # <pct> <width>
  local w="${2:-0}"
  case "$w" in ''|*[!0-9]*) return 0 ;; esac
  [ "$w" -ge 6 ] || return 0
  awk -v p="${1:-0}" -v w="$w" 'BEGIN {
    if (p < 0 || p == "") p = 0
    f = (p >= 100) ? w : int((p / 100) * w)
    if (p < 100 && f > w - 1) f = w - 1
    if (f < 0) f = 0
    s = ""
    for (i = 0; i < f; i++) s = s "\342\226\210"
    for (i = f; i < w; i++) s = s "\342\226\221"
    printf "%s", s }'
}

# `5h 16% (resets 19:00)   7d 41% (resets Sat 05:00)   7d Fable 75%`
_sub_line() { # <usage-json> [bar-width]
  local out="" n p r s bw="${2:-0}"
  while IFS=$'\t' read -r n p r s; do
    [ -n "$n" ] || continue
    # A SCOPE IS PART OF THE WINDOW'S NAME, not a footnote: two 7d windows on
    # one account are told apart by the model they are scoped to.
    [ -n "$s" ] && n="$n $s"
    out="$out$(printf '%s%s %s%%%s   ' "$n" \
      "$([ "$bw" -ge 6 ] 2>/dev/null && printf ' %s' "$(sub_bar "$p" "$bw")" || true)" \
      "$(printf '%.0f' "$p")" \
      "$([ -n "$r" ] && printf ' (resets %s)' "$(sub_reset_human "$r")" || true)")"
  done < <(printf '%s' "$1" | jq -r '.windows[]? | [.name, (.used_pct // 0), (.resets_at // ""), (.scope // "")] | @tsv')
  local state reason
  IFS=$'\t' read -r state reason <<< "$(printf '%s' "$1" | jq -r '[(.extra.state // ""), (.extra.reason // "")] | @tsv')"
  [ "$state" = disabled ] && out="${out}extra: ${reason//_/ }"
  [ "$state" = unreadable ] && out="${out}unreadable: ${reason}"
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
  local subs; subs="$(subscription_list)"
  if [ "$json" -eq 1 ]; then
    local bal="[]" p r
    for p in $(_quota_providers "$only"); do
      r="$(quota_remaining "$p" "$wsdir")"
      bal="$(printf '%s' "$bal" | jq -c --arg p "$p" \
        --arg r "$r" \
        --arg st "$(quota_state "$p" "$wsdir" "$r")" \
        --arg f "$(provider_balance "$p" floor)" \
        --arg u "$(provider_balance "$p" unit)" \
        '. + [{provider: $p, remaining: $r, state: $st, floor: $f, unit: $u}]')"
    done
    jq -nc --argjson s "$subs" --argjson b "$bal" '{subscriptions: $s, balances: $b}'
    return 0
  fi

  printf '  %-12s %-24s %s\n' SUBSCRIPTION ACCOUNT WINDOWS
  # The track is sized to the terminal, and a terminal too narrow for one is
  # given the text it had before.
  local cols="${COLUMNS:-0}"; [ "$cols" -gt 0 ] 2>/dev/null || cols="$(tput cols 2>/dev/null || echo 80)"
  local bw=0; [ "$cols" -ge 100 ] 2>/dev/null && bw=10
  if [ "$(printf '%s' "$subs" | jq -r 'length')" = 0 ]; then
    printf '  none - no signed-in Claude or Codex credential on this box\n'
  fi
  local row acct
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    # The label is what an operator reads - `pi + claude-code`, or the email
    # the credential file carries. The account underneath it is an IDENTIFIER:
    # Codex's is a 36-character uuid, and left whole it pushed every window off
    # the right of the table.
    acct="$(printf '%s' "$row" | jq -r '.label // .account')"
    printf '  %-12s %-24s %s\n' \
      "$(printf '%s' "$row" | jq -r '.provider')" \
      "${acct:0:24}" \
      "$(_sub_line "$row" "$bw")"
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
    # TWO KINDS OF `unknown`, AND THEY ARE NOT THE SAME NEWS. No key in this
    # workspace is where you are standing - credit is workspace-scoped by
    # decision, and a workspace without the key is behaving correctly.
    # Asking and not being able to tell is a fault.
    if [ "$r" = unknown ]; then st="$(quota_state_human "$(quota_state "$p" "$wsdir" "$r")")"
    elif quota_vetoed "$p" "$r"; then st="VETOED - below floor; workers will not be sent here"
    else st="ok"; fi
    [ "$r" = unknown ] || r="$(printf '%.2f' "$r")"
    printf '  %-12s %-14s %-8s %s\n' "$p" "$r $(provider_balance "$p" unit)" "${floor:--}" "$st"
  done
}
