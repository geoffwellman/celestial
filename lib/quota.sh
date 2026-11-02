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
# Cached five minutes under ~/.local/share/cel/quota/, keyed by provider and
# key fingerprint, so a steward tick or a burst of delegations does not hammer
# anyone's API.
[ -n "${_CEL_QUOTA:-}" ] && return 0
_CEL_QUOTA=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/manifest.sh
. "${BASH_SOURCE[0]%/*}/manifest.sh"
# shellcheck source=lib/config.sh
. "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"

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

# WHY A CREDIT READ CAME BACK EMPTY. "There is no key for this provider in
# this workspace" is a fact about where you are standing (credit is
# workspace-scoped on purpose); "I asked and could not tell" is a fault. One
# word for both makes every workspace without an OpenRouter key read as broken.
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
# half is SIGNED-IN SUBSCRIPTIONS - Claude (Max, through Claude Code and
# through pi's OAuth) and Codex (ChatGPT, through omp). A five hour window at
# 100% stops every worker on that account just as hard as an empty balance
# does, and it does it without a single error message anywhere the operator
# looks.
#
# A TOKEN IS NEVER PRINTED, ANYWHERE. These are live bearer credentials for
# the owner's own accounts, and this file is read by `cel quota`, by the
# steward's mail, by the console's status edge and by a dashboard served over
# a tailnet.
#
# AN ACCOUNT IS WHERE IT IS SIGNED IN, NOT WHICH TOKEN IT HOLDS. Tokens are
# refreshed at will, so an identity derived from one would mint a new
# "account" on every refresh. The identity is the credential's HOME -
# `claude/pi`, `claude/claude-code`, `codex/<account_id>`,
# `gateway/<provider>/<short id>` - which survives a refresh, and the cache
# file keyed by it is OVERWRITTEN rather than joined by a sibling. Files that
# match no current identity are swept on the next list.
_sub_cache_dir() { printf '%s' "${CEL_CACHE:-$HOME/.cache/cel}"; }
_SUB_TTL="${CEL_SUB_TTL:-60}"

# THE FILE NAME IS A HASH, NEVER THE ACCOUNT ID. Account ids come out of
# credential and provider documents - a `/` or `..` in one is not a path the
# cache may follow - so the name is derived from provider+account and the
# identity itself travels inside the JSON. The provider prefix is cosmetic and
# kept only when it is plain.
_sub_cache_file() { # <provider> <account>
  local p="$1" h
  h="$(printf '%s\t%s' "$1" "$2" | sha256sum | cut -c1-16)"
  case "$p" in ''|*[!a-z0-9]*) p=x ;; esac
  printf '%s/subscription-%s-%s.json' "$(_sub_cache_dir)" "$p" "$h"
}

# ONE FILE IS PUBLISHED WHOLE: a 0600 temp sibling (mktemp's mode), renamed
# over the target, so a reader sees the old answer or the new one and never a
# truncated half. The dot-prefixed temp never matches a reader's glob.
_sub_cache_put() { # <file> <doc>
  local dir tmp; dir="$(dirname "$1")"
  mkdir -p "$dir"; chmod 700 "$dir" 2>/dev/null || true
  tmp="$(mktemp "$dir/.subscription.XXXXXX")" || return 1
  if printf '%s' "$2" > "$tmp" && mv -f -- "$tmp" "$1"; then return 0; fi
  rm -f -- "$tmp"; return 1
}

# ONE WRITER OF THE CACHE SET AT A TIME: a list's publish-and-sweep and a
# single account's write serialise on one flock, so one run cannot sweep a file
# another is publishing. Held for the writes only - never across a network
# read - and a lock that cannot be had in ten seconds is not a reason to leave
# the cache stale, so the write then goes ahead (each file is still atomic).
_sub_cache_locked() { # <cmd...>
  local dir fd="" rc=0; dir="$(_sub_cache_dir)"
  mkdir -p "$dir"; chmod 700 "$dir" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1 && exec {fd}>"$dir/.subscription.lock" 2>/dev/null; then
    flock -w 10 "$fd" || true
  else fd=""; fi
  "$@" || rc=$?
  [ -z "$fd" ] || exec {fd}>&-
  return "$rc"
}

# pi's stored OAuth token answers Anthropic's usage endpoint with both windows.
_SUB_ANTHROPIC_URL="${CEL_SUB_ANTHROPIC_URL:-https://api.anthropic.com/api/oauth/usage}"
# Read out of the Codex binary (0.153.2) rather than guessed: the CLI's own
# rate-limit display is served by `<chatgpt base>/wham/usage`, which answers a
# `RateLimitSnapshot` - `primary` and `secondary` RateLimitWindows of
# used_percent / window_minutes / resets_at. It is a GET and it changes
# nothing, so no inference has to be bought to read it.
_SUB_CODEX_URL="${CEL_SUB_CODEX_URL:-https://chatgpt.com/backend-api/wham/usage}"

# opencode's own usage endpoint. CLIProxyAPI does not hold this credential, so
# celestial reads the source directly.
_SUB_OPENCODE_URL="${CEL_SUB_OPENCODE_URL:-https://opencode.ai/zen/go/v1/usage}"

# `omp usage --json` holds REFRESHED OAUTH PER ACCOUNT and answers for all of
# them in one call, where a credential file on disk may hold a token long
# expired (`401 token_expired`) - and no amount of parsing fixes a stale
# token. So omp is a source when it is there; a box without it must degrade
# to the per-provider reads below, never to an error.
_sub_omp_usage() {
  command -v omp >/dev/null 2>&1 || return 0
  omp usage --json 2>/dev/null || true
}

# The rows omp's document becomes. `omp usage --json` answers
#
#   {generatedAt, reports: [...], accountsWithoutUsage, disabledCredentials,
#    capacity}
#
# and each report is {provider, fetchedAt, metadata:{accountId, email,
# planType, ...}, limits:[...]}. THE EMAIL AND THE ACCOUNT ID LIVE UNDER
# `.metadata`, not at the top of the report.
#
# `.limits[]` is the authoritative window list - reading a named subset
# (`.five_hour`/`.seven_day`) loses every scoped window - and each limit is
# {id, label, scope:{windowId,tier,modelId,...}, window:{id,label,durationMs,
# resetsAt}, amount:{used,limit,remaining,usedFraction,unit}, status}, which
# is exactly the shape a bar needs.
#
# tests/fixtures/omp-usage.json is a real answer with the identities
# replaced: a stub that disagrees with the tool tests nothing.
_sub_omp_rows() {
  local raw; raw="$(_sub_omp_usage)"
  [ -n "$raw" ] || return 0
  printf '%s' "$raw" | jq -c '
    def iso: if . == null then null
             elif type == "number"
             then ((if . > 100000000000 then . / 1000 else . end) | floor | todate)
             else . end;
    def wname($id; $ms): if $id != null and $id != "" then ($id | tostring)
                         elif $ms == null or $ms == 0 then "window"
                         elif $ms >= 604800000 then "7d"
                         elif $ms >= 86400000 then "1d"
                         else "5h" end;
    (.reports // .accounts // .usage // [])
    | if type == "array" then . else [.] end
    | .[]
    | select(type == "object")
    | . as $a
    | (.metadata // {}) as $m
    | ((.provider // "unknown") | ascii_downcase) as $p
    | {provider: (if $p == "anthropic" or $p == "claude" then "claude"
                  elif $p == "openai-codex" or $p == "codex" or $p == "chatgpt" then "codex"
                  elif ($p | startswith("opencode")) then "opencode"
                  else $p end),
       account: (($m.accountId // $m.account_id // $m.orgId // $m.email // $p) | tostring),
       label: (($m.email // $m.accountId // $m.account_id // $m.planType // $p) | tostring),
       source: "omp",
       windows: [ (.limits // .windows // [])[]
                  | select(type == "object")
                  | . as $w
                  | (($w.amount.usedFraction // $w.amount.used_fraction
                      // (if (($w.amount.limit // 0) > 0) and ($w.amount.used != null)
                          then ($w.amount.used / $w.amount.limit) else null end))) as $f
                  | select($f != null)
                  | {name: wname(($w.window.id // $w.scope.windowId);
                                 ($w.window.durationMs // $w.window.duration_ms)),
                     # A SCOPE IS A LABEL, NOT A SPECIAL CASE. A scoped window
                     # is per-tier or per-model - Claude 7 Day (Fable) and
                     # 7 days (gpt-reserve) are both this - and without the
                     # label it reads as a duplicate of the window beside it.
                     # The parenthetical in omp own label is preferred because
                     # it is already capitalised the way the provider says it.
                     scope: (($w.label // "" | capture("\\((?<s>[^)]+)\\)") | .s)?
                             // $w.scope.tier // $w.scope.modelId
                             // $w.scope.model.display_name // null),
                     used_pct: ($f * 100),
                     resets_at: (($w.window.resetsAt // $w.window.resets_at // $w.resetsAt // null) | iso)} ],
       extra: (($m.extra_usage.disabled_reason // $m.extraUsage.disabledReason
                // $a.extra_usage.disabled_reason // null) as $dr
               | if $dr != null
                 then {state: "disabled",
                       reason: (if ((($m.spend.enabled // $a.spend.enabled) // false) == false)
                                then "top-up is off" else ($dr | gsub("_"; " ")) end)}
                 elif ($a.ok // true) == false or (($a.limits // []) | length) == 0
                 then {state: "unreadable",
                       reason: ($a.error // "omp holds this credential but reported no usage for it")}
                 else {state: "enabled", reason: ""} end)}' 2>/dev/null || true
  # A CREDENTIAL OMP DISABLED IS OMP'S TO RE-LOGIN. The orchestrators run on
  # omp's own pool, so a refresh token omp lost leaves them short an account
  # even while the gateway's copy of the same login is fine: the hint is
  # `omp login`, not `cel gateway login`. An account omp still reports usage
  # for is not dead, so it is not repeated.
  printf '%s' "$raw" | jq -c '
    ([(.reports // [])[]? | (.metadata.email // .metadata.accountId // empty)]) as $live
    | (.disabledCredentials // [])[]?
    | select(type == "object")
    | ((.provider // "unknown") | ascii_downcase) as $p
    | ((.email // .accountId // $p) | tostring) as $who
    | select(($live | index($who)) == null)
    | {provider: (if $p == "anthropic" or $p == "claude" then "claude"
                  elif $p == "openai-codex" or $p == "codex" or $p == "chatgpt" then "codex"
                  elif ($p | startswith("opencode")) then "opencode"
                  else $p end),
       account: ((.accountId // .email // $p) | tostring),
       label: $who,
       source: "omp",
       windows: [],
       extra: {state: "needs_login", reason: ("needs login: omp login " + $p)}}' 2>/dev/null || true
  return 0
}

# --- THE ONE VAULT ----------------------------------------------------------
#
# CLIProxyAPI is the only credential store on this box, and it cannot report
# usage: it removed usage statistics in v6.10.0 and keeps only a snapshot of
# the LAST response's rate-limit headers - empty for an idle account,
# overwritten rather than accumulated, and only for three providers. What it
# does keep is each account's OAuth token, one file per account, and celestial
# already knows how to turn a live token into windows. So the vault is the
# account list and the provider is the source of truth for the numbers.
#
# `gateway_auth_dir` (lib/gateway.sh) is the one place that knows where the
# vault lives, so this asks rather than knows. gateway.sh is sourced HERE
# rather than at the top of the file because it pulls in the service
# registry, and every caller of quota.sh does not need it. This reads the
# vault and never writes to it.
#
# `CEL_CPA_AUTH_DIR` is the test seam; the last line is gateway.sh's own
# default, for a caller that has quota.sh without gateway.sh beside it.
_cpa_auth_dir() {
  local d="${CEL_CPA_AUTH_DIR:-}"
  if [ -z "$d" ] && [ -f "${BASH_SOURCE[0]%/*}/gateway.sh" ]; then
    # shellcheck source=lib/gateway.sh
    . "${BASH_SOURCE[0]%/*}/gateway.sh"
    d="$(gateway_auth_dir 2>/dev/null || true)"
  fi
  [ -n "$d" ] || d="${CEL_GATEWAY_STATE:-$HOME/.local/share/cel/gateway}/auth"
  expand "$d"
}

# provider<TAB>account<TAB>label<TAB>file, one line per credential file in the
# vault. The identity comes out of the FILE (`account.uuid`,
# `account.email_address`), never the filename: CLIProxyAPI names the file
# `claude-<hash>-<email>.json` and the hash is not an account.
_cpa_accounts() {
  local d; d="$(_cpa_auth_dir)"
  [ -d "$d" ] || return 0
  local f base p acct label
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    p="$(jq -r '.type // .provider // empty' "$f" 2>/dev/null || true)"
    if [ -z "$p" ]; then
      case "$base" in claude-*) p=claude ;; codex-*) p=codex ;; *) p="" ;; esac
    fi
    case "$p" in
      claude|anthropic) p=claude ;;
      codex|openai-codex|chatgpt) p=codex ;;
      # gemini and the rest live in the same vault and have no usage endpoint
      # celestial can ask; they are not rows, and saying nothing about them is
      # correct - `cel gateway status` is where the whole vault is listed.
      *) continue ;;
    esac
    acct="$(jq -r '.account.uuid // .account_id // .tokens.account_id // .account.email_address // .email // empty' "$f" 2>/dev/null || true)"
    label="$(jq -r '.account.email_address // .email // .tokens.email // .account.uuid // empty' "$f" 2>/dev/null || true)"
    [ -n "$acct" ] || acct="$(_sub_fp "$base")"
    [ -n "$label" ] || label="$acct"
    printf '%s\t%s\t%s\t%s\n' "$p" "$acct" "$label" "$f"
  done
  return 0
}

_cpa_field() { # <file> <jq-path>
  jq -r "$2 // empty" "$1" 2>/dev/null || true
}

# Has the token in this file already expired? An unparseable or absent expiry
# is NOT an expiry - it means "ask and find out", and a 401 from the endpoint
# is the other half of the answer.
_cpa_expired() { # <file>
  local e; e="$(_cpa_field "$1" '.expire // .expired // .expires_at // .expire_at // .tokens.expire')"
  [ -n "$e" ] || return 1
  local t; t="$(date -d "$e" +%s 2>/dev/null || true)"
  [ -n "$t" ] || return 1
  [ "$t" -le "$(( $(date +%s) + 60 ))" ]
}

# CELESTIAL DOES NOT REFRESH THESE CREDENTIALS. NOTHING HERE POSTS TO A TOKEN
# ENDPOINT, AND NOTHING HERE WRITES TO THE AUTH-DIR.
#
# The damage of a refresh is done AT THE PROVIDER, NOT ON DISK: both providers
# rotate the refresh token when it is used - Anthropic's own client keeps the
# stored one only `if tokenResp.RefreshToken == ""`
# (`internal/auth/claude/anthropic_auth.go:579-580`), and CLIProxyAPI's Codex
# path carries a `refresh_token_reused` branch
# (`internal/auth/codex/openai_auth.go:336`) because auth.openai.com enforces
# rotation. Spend the vault's refresh token to draw a usage bar and the file
# is left holding a token the provider has already retired: CLIProxyAPI fails
# at its NEXT refresh and the owner is sent to a browser to log in again.
#
# Writing the rotation back does not fix it either. CLIProxyAPI refreshes
# these credentials itself on a fifteen-minute loop
# (`sdk/cliproxy/service_lifecycle.go:91-93`), serialising per auth id with
# locks that live INSIDE its process (`sdk/cliproxy/auth/conductor.go:196-201`);
# a second writer can only race it and write back a retired token.
#
# So the vault's owner is the only refresher, and celestial presents whatever
# token the file currently holds. A token that is stale ANYWAY is news in
# itself - the gateway is not running, or that account is signed out - and a
# stale row that says so is honest where a broken login is not.
_cpa_access_token() { # <file>
  _cpa_field "$1" '.access_token // .tokens.access_token'
}

# The window mapping, shared by every provider read here so one account's
# windows cannot be shaped differently from another's. It is the shape
# `_sub_omp_rows` produces - `{name, scope, used_pct, resets_at}` - because the
# console's QUOTA view and the dash card render that.
#
# A SCOPE IS READ, NEVER NAMED. `seven_day_fable` is one scoped window among
# however many the provider invents next; the duration prefix gives the name
# and whatever is left is the scope, so the next one appears without a code
# change.
_CPA_WINDOW_JQ='
def iso: if . == null then null
         elif type == "number"
         then ((if . > 100000000000 then . / 1000 else . end) | floor | todate)
         else . end;
def titlecase: [splits("[_ ]+")] | map(select(. != "") | (.[0:1] | ascii_upcase) + .[1:]) | join(" ");
def wname($k): if ($k | test("^five_hour|^5h")) then "5h"
               elif ($k | test("^seven_day|^7d")) then "7d"
               elif ($k | test("^one_day|^daily|^1d")) then "1d"
               else $k end;
def wscope($k): ($k | sub("^(five_hour|seven_day|one_day|daily|5h|7d|1d)_?"; ""))
                | if . == "" then null else titlecase end;
def keywindows: to_entries
  | map(select((.key | test("^(five_hour|seven_day|one_day|daily|5h|7d|1d)"))
               and (.value | type) == "object" and (.value.utilization // .value.used_percent) != null)
        | {name: wname(.key), scope: wscope(.key),
           used_pct: (.value.utilization // .value.used_percent),
           resets_at: ((.value.resets_at // .value.resetsAt) | iso)});
# THE AUTHORITATIVE LIST, WHEN THE PROVIDER SENDS ONE. Anthropic answers a
# dozen top-level codename keys (`nimbus_quill`, `amber_gauge`, ...) - most
# null, some real objects with a null reset - AND `.limits[]` of {kind,
# percent, resets_at, scope.model.display_name}. The keys print codenames as
# windows and miss scoped ones, so when `.limits[]` carries kinds it is the
# only source.
def kindname($k): if ($k | test("session|five_hour|5h")) then "5h"
                  elif ($k | test("weekly|seven_day|7d")) then "7d"
                  elif ($k | test("daily|one_day|1d")) then "1d"
                  elif ($k | test("monthly")) then "monthly"
                  else $k end;
def haskinds: ((.limits // []) | type) == "array"
              and ([(.limits // [])[] | select(type == "object" and .kind != null)] | length) > 0;
def kindwindows: [(.limits // [])[]
  | select(type == "object" and .kind != null and .percent != null)
  | {name: kindname(.kind),
     scope: (.scope.model.display_name // .scope.surface // null),
     used_pct: .percent,
     resets_at: (.resets_at | iso)}];
# opencode Go: `{usage: {rolling, weekly, monthly: {status, percent, resetsAt}}}`.
def usagewindows: [((.usage // {}) | if type == "object" then to_entries[] else empty end)
  | select((.value | type) == "object" and .value.percent != null)
  | {name: (if .key == "rolling" then "5h" else kindname(.key) end), scope: null,
     used_pct: .value.percent, resets_at: ((.value.resetsAt // .value.resets_at) | iso)}];
def limitwindows: (.limits // [])
  | map(select(type == "object" and .kind == null)
        | . as $w
        | (($w.amount.usedFraction // $w.amount.used_fraction
            // (if (($w.amount.limit // 0) > 0) and ($w.amount.used != null)
                then ($w.amount.used / $w.amount.limit) else null end))) as $f
        | select($f != null)
        | {name: (($w.window.id // $w.scope.windowId // "window") | tostring | wname(.)),
           scope: ((($w.label // "") | capture("\\((?<s>[^)]+)\\)") | .s)?
                   // $w.scope.tier // $w.scope.modelId // null),
           used_pct: ($f * 100),
           resets_at: (($w.window.resetsAt // $w.window.resets_at // $w.resetsAt) | iso)});
'

# The body on stdout, and WHICH failure in the status: 0 a 2xx answer, 2 the
# provider rejected the token (401/403), 1 anything else - no connection, a
# timeout, a 5xx. Only the second is a login; the rest is the endpoint.
_cpa_usage_fetch() { # <provider> <token> <account>
  local url out code
  local -a hdr=()
  case "$1" in
    claude) url="$_SUB_ANTHROPIC_URL"; hdr=(-H 'anthropic-beta: oauth-2025-04-20') ;;
    codex) url="$_SUB_CODEX_URL"; hdr=(-H "chatgpt-account-id: $3" -H 'originator: codex_cli_rs') ;;
    opencode) url="$_SUB_OPENCODE_URL" ;;
    *) return 1 ;;
  esac
  out="$(printf 'authorization: Bearer %s\n' "$2" |
    curl -s -m 10 "$url" -H @- "${hdr[@]}" -w '\n%{http_code}' 2>/dev/null)" || return 1
  code="${out##*$'\n'}"
  case "$code" in
    2??) printf '%s' "${out%$'\n'*}"; return 0 ;;
    401|403) return 2 ;;
    *) return 1 ;;
  esac
}

_cpa_map_usage() { # <provider> <account> <label> <source>  (body on stdin)
  case "$1" in
    codex)
      jq -c --arg a "$2" --arg l "$3" --arg s "$4" "$_CPA_WINDOW_JQ"'
        ((.rate_limits // .) as $r
         | {provider: "codex", account: $a, label: $l, source: $s,
            windows: ([$r | to_entries[]
                       | select((.value | type) == "object" and .value.used_percent != null)
                       | {name: (if (.value.window_minutes // 0) >= 10080 then "7d"
                                 elif (.value.window_minutes // 0) >= 1440 then "1d"
                                 else "5h" end),
                          # primary and secondary are Codex own words for
                          # "the short one" and "the long one", not scopes -
                          # anything else it names IS one.
                          scope: (if (.key | test("^(primary|secondary)$")) then null
                                  else (.key | titlecase) end),
                          used_pct: .value.used_percent,
                          resets_at: (.value.resets_at
                                      // (if .value.resets_in_seconds
                                          then (now + .value.resets_in_seconds | todate)
                                          else null end))}]),
            extra: {state: (if ($r.credits.has_credits // true) then "enabled" else "disabled" end),
                    reason: ($r.rate_limit_reached_type // "")}})' 2>/dev/null || true ;;
    *)
      jq -c --arg p "$1" --arg a "$2" --arg l "$3" --arg s "$4" "$_CPA_WINDOW_JQ"'
        {provider: $p, account: $a, label: $l, source: $s,
         windows: ((if haskinds then kindwindows else (keywindows + limitwindows) end)
                   + usagewindows | map(select(.used_pct != null))),
         extra: ((.extra_usage.disabled_reason // null) as $dr
                 | if $dr == null then {state: "enabled", reason: ""}
                   # `out_of_credits` with `spend.enabled: false` means TOP-UP
                   # IS SWITCHED OFF, not "this account is spent".
                   else {state: "disabled",
                         reason: (if ((.spend.enabled // false) == false)
                                  then "top-up is off" else ($dr | gsub("_"; " ")) end)} end)}' \
        2>/dev/null || true ;;
  esac
  return 0
}

# THREE DIFFERENT PIECES OF NEWS, THREE STATES. One word for a transient
# fault, an expired token and a signed-out account gets acted on as the first.
#
#   stale        the vault's token has expired and CLIProxyAPI - the only
#                thing that may refresh it - has not. Nothing is broken: it
#                refreshes when the gateway next runs this account.
#   needs_login  the provider REJECTED a token the vault calls live. That
#                credential is finished and only a human can replace it.
#   unreadable   the endpoint itself could not be read.
_cpa_needs_login_row() { # <provider> <account> <label>
  jq -nc --arg p "$1" --arg a "$2" --arg l "$3" \
    '{provider: $p, account: $a, label: $l, source: "cliproxy", windows: [],
      extra: {state: "needs_login",
              reason: ("needs login: cel gateway login " + $p)}}'
}

# NOT A FAULT, AND NOT A LOGIN. An idle account whose access token has aged out
# is waiting for the refresher that owns it, and telling the owner to log in
# again would send them to a browser to fix nothing - while breaking the
# credential is exactly what this reader refuses to do.
_cpa_stale_row() { # <provider> <account> <label>
  jq -nc --arg p "$1" --arg a "$2" --arg l "$3" \
    '{provider: $p, account: $a, label: $l, source: "cliproxy", windows: [],
      extra: {state: "stale",
              reason: "token stale - refreshed next time this account serves traffic"}}'
}

_cpa_unreadable_row() { # <provider> <account> <label>
  jq -nc --arg p "$1" --arg a "$2" --arg l "$3" \
    '{provider: $p, account: $a, label: $l, source: "cliproxy", windows: [],
      extra: {state: "unreadable",
              reason: "the usage endpoint could not be read - it may be down"}}'
}

# One row per account in the vault, and NOTHING HERE REFRESHES ANYTHING.
# CLIProxyAPI is the only refresher on this box - both providers rotate the
# refresh token when it is used, so a second refresher retires the one the
# gateway has stored (see the note above _cpa_access_token, which carries the
# file:line evidence). A 401 is the second place an expiry shows up, because a
# file can claim a live token and be wrong; the answer to that is a
# `needs_login` row, never a retry through a token endpoint.
_sub_cliproxy_rows() {
  local p a label f tok
  while IFS=$'\t' read -r p a label f; do
    [ -n "$p" ] || continue
    tok="$(_cpa_access_token "$f")"
    # A file that says its token has already expired is not worth a call: the
    # only thing that could refresh it is CLIProxyAPI, and it has not.
    if [ -z "$tok" ] || _cpa_expired "$f"; then
      _cpa_stale_row "$p" "$a" "$label"; continue
    fi
    # A REJECTED TOKEN IS NOT MET WITH A REFRESH: see the note above
    # _cpa_access_token. The vault called this token live and the provider
    # disagreed, which is a credential only a human can replace - and the one
    # thing that must not happen on the way to saying so is a token endpoint
    # call that retires the vault's refresh token.
    _cpa_usage_row "$p" "$tok" "$a" "$label"
  done < <(_cpa_accounts)
  return 0
}

# One account's row from one usage read: needs_login ONLY when the provider
# answered 401/403; no answer, a 5xx or a body that is not usage is unreadable.
_cpa_usage_row() { # <provider> <token> <account> <label>
  local resp doc rc=0
  resp="$(_cpa_usage_fetch "$1" "$2" "$3")" || rc=$?
  case "$rc" in
    0) ;;
    2) _cpa_needs_login_row "$1" "$3" "$4"; return 0 ;;
    *) _cpa_unreadable_row "$1" "$3" "$4"; return 0 ;;
  esac
  doc="$(printf '%s' "$resp" | _cpa_map_usage "$1" "$3" "$4" cliproxy)"
  if [ -n "$doc" ]; then printf '%s\n' "$doc"
  else _cpa_unreadable_row "$1" "$3" "$4"; fi
  return 0
}

# OPENCODE IS NOT IN THE VAULT AND MUST NOT FALL OUT OF THE LIST: CLIProxyAPI
# has never held it. The credential is opencode's own auth file, read exactly
# where opencode keeps it.
_sub_opencode_rows() {
  local f="${CEL_OPENCODE_AUTH:-$HOME/.local/share/opencode/auth.json}"
  [ -f "$f" ] || return 0
  # The live file is keyed `opencode-go` and holds a `key`; the older
  # `.opencode.*` spellings are still read. The account and label are the
  # ones omp gives this credential, so the two sources join on it.
  local tok; tok="$(jq -r '."opencode-go".key // ."opencode-go".access
                           // .opencode.access // .opencode.key // .opencode.token
                           // .access // .key // empty' "$f" 2>/dev/null || true)"
  [ -n "$tok" ] || return 0
  local a=opencode-go l="OpenCode Go"
  _cpa_usage_row opencode "$tok" "$a" "$l"
  return 0
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

# {provider, account, label, source, windows: [{name, used_pct, resets_at}],
#  extra: {state, reason}} for one account, cached 60 s.
#
# A FAILURE TO ASK IS A ROW, NOT A SILENCE. An account missing from the cache
# is missing from `cel fleet` and the console while the dashboard may still
# show it. An empty windows list with `state: unreadable` and the reason is
# something an operator can act on, and it is cached like any other answer so
# every surface shows the same row.
subscription_usage() { # <provider> <token> [account] [label]
  local p="$1" tok="$2" acct="${3:-}" label="${4:-}"
  [ -n "$acct" ] || acct="$(_sub_fp "$tok")"
  [ -n "$label" ] || label="$acct"
  local cache; cache="$(_sub_cache_file "$p" "$acct")"
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
                   # worse than saying nothing.
                   else {state: "disabled",
                         reason: (if ((.spend.enabled // false) == false)
                                  then "top-up is off"
                                  else ($dr | gsub("_"; " ")) end)} end)}' 2>/dev/null || true)"
      ;;
    codex)
      resp="$(printf 'authorization: Bearer %s\n' "$tok" |
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
    # CACHED, deliberately. A cached failure holds for sixty seconds, which is
    # the price of the row being THERE at all - in `cel fleet`, the console
    # and the steward - instead of an account whose wall arrives as a mystery.
    # The reason travels with it.
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
  # (by _sub_cache_put) rather than inherited.
  _sub_cache_locked _sub_cache_put "$cache" "$doc" || true
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
    # each file on its own: one unparseable file is one missing row, never the
    # whole list folded to `[]`
    local f found=""
    for f in "$dir"/subscription-*.json; do
      [ -f "$f" ] || continue
      found="$found$(jq -c 'select(type == "object")' "$f" 2>/dev/null)
"
    done
    printf '%s' "$found" | _sub_fold
    return 0
  fi

  local p a t label rows="" keep="" f
  local -a pub_f=() pub_d=()

  # PER ACCOUNT, NOT PER SOURCE. CLIProxyAPI's vault is the one credential
  # store on this box and celestial reads usage out of those credentials
  # itself; omp's report stays underneath until tools/quota-compare.sh --gate
  # passes on the live box. An account is provider + email: the vault's row
  # answers for it when the vault holds it and could read it, omp's row
  # otherwise, and an account either source knows appears exactly once. An
  # empty or absent vault leaves the omp and direct reads exactly as they are.
  local vrow vk cpa_rows="" cpa_usable=" "
  if [ -n "$(_cpa_accounts)" ]; then
    while IFS= read -r vrow; do
      [ -n "$vrow" ] || continue
      cpa_rows="$cpa_rows$vrow
"
      if [ "$(printf '%s' "$vrow" | jq -r '(.windows | length) > 0')" = true ]; then
        cpa_usable="$cpa_usable$(_sub_key "$vrow") "
      fi
    done < <( _sub_cliproxy_rows; _sub_opencode_rows )
  fi
  local omp_keys=" " cpa_providers
  cpa_providers=" $(printf '%s' "$cpa_rows" | jq -r '.provider' 2>/dev/null | sort -u | tr '\n' ' ')"
  # OMP NEXT. It holds its own refreshed OAuth per account and covers every
  # provider it knows in one call, so for those providers the per-file token
  # reads below are not a second opinion - they are a worse one: a stale token
  # read beside a fresh one makes a healthy account read `unreadable`.
  local orow op oa omp_providers="" omp_seen=0
  while IFS= read -r orow; do
    [ -n "$orow" ] || continue
    omp_seen=1
    vk="$(_sub_key "$orow")"
    op="$(printf '%s' "$orow" | jq -r '.provider')"
    case " $omp_providers " in *" $op "*) ;; *) omp_providers="$omp_providers $op" ;; esac
    case "$cpa_usable" in *" $vk "*) continue ;; esac
    omp_keys="$omp_keys$vk "
    oa="$(printf '%s' "$orow" | jq -r '.account')"
    f="$(_sub_cache_file "$op" "$oa")"
    pub_f+=("$f"); pub_d+=("$orow")
    rows="$rows$orow
"
    keep="$keep ${f##*/}"
  done < <(_sub_omp_rows)

  # TWO SILENCES THAT ARE NOT THE SAME NEWS. A box with no omp on it falls
  # back to the per-provider reads and says nothing: that is not a fault. But
  # omp ON PATH that answers nothing usable - a shape drift, a truncated
  # response, an error document - falls back to the same stale reads and
  # would be invisible. One line on stderr, and only in that case - stdout is
  # a JSON document that callers parse, and the fallback still produces the
  # best answer available.
  if [ "$omp_seen" -eq 0 ] && [ -z "$cpa_rows" ] && command -v omp >/dev/null 2>&1; then
    printf 'cel quota: omp is on PATH but produced no usable subscription rows (%s); falling back to the per-provider reads, which may be stale\n' \
      "try: omp usage --json" >&2
  fi

  while IFS=$'\t' read -r p a t label; do
    [ -n "$p" ] || continue
    # a provider omp answered for is answered; anything else still reads its
    # own credential file, so a box where omp knows Claude and not Codex
    # still sees Codex.
    case " $omp_providers " in *" $p "*) continue ;; esac
    # nor one the vault holds: its credential files are the fresher copy
    case "$cpa_providers" in *" $p "*) continue ;; esac
    rows="$rows$(subscription_usage "$p" "$t" "$a" "$label")
"
    f="$(_sub_cache_file "$p" "$a")"
    keep="$keep ${f##*/}"
  done < <(_sub_direct_accounts)

  # The vault's rows: every usable one, and an unusable one only for an
  # account omp could not answer for either - a stale row is still news.
  local vp va
  while IFS= read -r vrow; do
    [ -n "$vrow" ] || continue
    vk="$(_sub_key "$vrow")"
    case "$omp_keys" in *" $vk "*) continue ;; esac
    vp="$(printf '%s' "$vrow" | jq -r '.provider')"
    va="$(printf '%s' "$vrow" | jq -r '.account')"
    f="$(_sub_cache_file "$vp" "$va")"
    pub_f+=("$f"); pub_d+=("$vrow")
    rows="$rows$vrow
"
    keep="$keep ${f##*/}"
  done <<< "$cpa_rows"

  # PUBLISH, THEN THE SWEEP, under the cache lock and after every network read
  # is done: each file is renamed into place whole, and every file that is not
  # one of this run's identities is a stale identity or a signed-out account -
  # a row on the console for a subscription that does not exist.
  _sub_cache_locked _sub_publish_set "$dir" "$keep" || true

  printf '%s' "$rows" | _sub_fold
}

# subscription_list's write half, run under _sub_cache_locked. The files and
# documents are the caller's `pub_f`/`pub_d` arrays (bash cannot pass an
# array); <keep> is the space-separated set of file names this run owns.
_sub_publish_set() { # <dir> <keep>
  local i f
  for i in "${!pub_f[@]}"; do _sub_cache_put "${pub_f[$i]}" "${pub_d[$i]}" || true; done
  for f in "$1"/subscription-*.json; do
    [ -f "$f" ] || continue
    case " $2 " in *" ${f##*/} "*) continue ;; esac
    rm -f -- "$f"
  done
  return 0
}

# ONE SUBSCRIPTION READ TWICE IS ONE ROW. pi keeps its own copy of the owner's
# Claude OAuth and Claude Code keeps another; two rows for it double every
# window on the display and halve nobody's trust in it. Identical window
# numbers are the evidence that it is one subscription - different numbers are
# two logins, and stay two rows.
#
# Reads JSON objects on stdin, one per line; prints the array, ordered direct
# before gateway so the cached path and the live path draw the same list.
# provider|email - the identity both readers share. omp names a Claude
# account by its uuid and the vault (whose files carry no uuid on this box)
# by its email, so the email is the only field both have. No spaces, so the
# key can live in a space-separated set.
_sub_key() { # <row-json>
  printf '%s' "$1" | jq -r '(.provider + "|" + ((.label // .account) | ascii_downcase)) | gsub("\\s"; "_")'
}

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
  # A credential that needs a human carries the command that fixes it, and it
  # says so where the windows would be - the row with nothing in it is the one
  # nobody acts on.
  [ "$state" = needs_login ] && out="${out}${reason}"
  [ "$state" = stale ] && out="${out}${reason}"
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
    local bal="[]" p r wn wd
    for p in $(_quota_providers "$only"); do
      while IFS=$'\t' read -r wn wd; do
      r="$(quota_remaining "$p" "$wd")"
      # The key's fingerprint (the one the balance cache is keyed on), so the
      # usage card can say "one account, both workspaces" rather than draw the
      # same dry key twice; and the veto as quota_vetoed decides it, so the
      # card never re-derives the floor rule.
      local acct="" vet=false k
      k="$(_quota_key "$p" "$wd")"
      [ -n "$k" ] && acct="$(printf '%s' "$k" | sha256sum | cut -c1-12)"
      if quota_vetoed "$p" "$r"; then vet=true; fi
      bal="$(printf '%s' "$bal" | jq -c --arg p "$p" \
        --arg r "$r" --arg w "$wn" --arg a "$acct" --argjson v "$vet" \
        --arg st "$(quota_state "$p" "$wd" "$r")" \
        --arg f "$(provider_balance "$p" floor)" \
        --arg u "$(provider_balance "$p" unit)" \
        '. + [{provider: $p, workspace: $w, remaining: $r, state: $st, floor: $f, unit: $u, account: $a, vetoed: $v}]')"
      done < <(_quota_owners "$p" "$wsdir")
    done
    local pool gw
    pool="$(quota_orch_pool)"
    gw="$(_cpa_accounts | awk -F'\t' '{print tolower($1 "|" $3)}' | jq -Rsc 'split("\n") | map(select(length > 0))')"
    jq -nc --argjson s "$subs" --argjson b "$bal" --argjson o "$pool" --argjson g "$gw" \
      '{subscriptions: $s, balances: $b, orch_pool: $o, gateway: $g}'
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

# WHO THE ORCHESTRATORS RUN ON. Root and every orchestrator use omp's own
# Anthropic credentials, so the usage card tags an account `orch` from the
# same document the steward's pool check reads, and `not orch` for one omp
# has disabled - a Claude account can be healthy in the gateway's vault and
# still be out of the orchestrators' pool. {live, disabled}, emails
# lowercased; both empty when omp is absent or answers nothing usable.
quota_orch_pool() {
  local raw; raw="$(_sub_omp_usage)"
  printf '%s' "${raw:-null}" | jq -c '
    def anth: ((.provider // "") | ascii_downcase) as $p | $p == "anthropic" or $p == "claude";
    def who: ((.email // .metadata.email // .accountId // .metadata.accountId // "") | tostring | ascii_downcase);
    {live: [(.reports // [])[]? | select(type == "object") | select(anth) | who | select(. != "")],
     disabled: [(.disabledCredentials // [])[]? | select(type == "object") | select(anth) | who | select(. != "")]}' \
    2>/dev/null || printf '{"live":[],"disabled":[]}'
}

# ON PACE FOR THE CAP. Reads a subscription list (the JSON array
# subscription_list prints) on stdin and prints the windows at risk: projected
# to reach 100% before they reset at the pace so far, or already at 95%. The
# projection is used / fraction-of-window-elapsed, and only once 5% of the
# window has passed - earlier than that it is a guess about one burst. The
# dashboard's usage card draws the same rule (tools/dash/v2.mjs).
#
# A WINDOW WHOSE RESET HAS PASSED IS NOT AT RISK. The list is usually the
# cached one, and a cache file is only rewritten when someone asks the
# providers again, so its number can describe a window that is already over.
# It is skipped, so a past reset is never quoted and the item comes down
# until a fresh read.
quota_at_risk() {
  jq -c '
    def len: if . == "5h" then 18000 elif . == "1d" or . == "daily" then 86400
             elif . == "7d" or . == "weekly" then 604800 elif . == "monthly" or . == "30d" then 2592000
             else (capture("^(?<n>[0-9]+)(?<u>[hd])$") | (.n | tonumber) * (if .u == "h" then 3600 else 86400 end))? // null end;
    now as $now
    | [ .[]? | select(type == "object") | . as $s
        | (.windows // [])[] | select(type == "object")
        | (.used_pct // 0) as $u
        | ((.name // "") | len) as $l
        | ((.resets_at // null) | if . == null then null else (sub("\\.[0-9]+"; "") | fromdateiso8601? // null) end) as $r
        | select($r == null or $r > $now)
        | (if $l != null and $r != null then (($l - ($r - $now)) / $l) else null end) as $f
        | (if $f != null and $f > 0.05 and $f <= 1 then ([999, ($u / $f)] | min | round) else ($u | round) end) as $p
        | select($p >= 100 or $u >= 95)
        | {provider: $s.provider, who: ($s.label // $s.account), window: .name, scope: .scope,
           used_pct: ($u | round), projected_pct: $p, resets: .resets_at} ]' 2>/dev/null || printf '[]'
}

# The providers `cel quota` reports a balance for: one named, or every
# provider that declares one.
_quota_providers() { # [provider]
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  yq -r '.providers | to_entries[] | select(.value.balance != null) | .key' "$CEL_MANIFEST"
}

# name<TAB>wsdir for every registered workspace whose OWN env (workspace.yaml
# `env:` or env.local) sets this provider's key - or, when none does, one line
# for the workspace you are standing in. A balance belongs to the workspace
# that owns the key, wherever `cel quota` is run from.
_quota_owners() { # <provider> [wsdir]
  local p="$1" cur="${2:-}" keyenv n d found=0
  keyenv="$(provider_get "$p" key_env)"
  if [ -n "$keyenv" ]; then
    for n in $(registry_names 2>/dev/null || true); do
      d="$(registry_path "$n" 2>/dev/null || true)"
      [ -n "$d" ] && [ -f "$d/workspace.yaml" ] || continue
      # the caller's own environment is NOT this workspace's key: unset it
      # first, so only what the workspace itself declares counts.
      if [ -n "$( ( set +u; unset "$keyenv"
                    eval "$(ws_env_exports "$d" 2>/dev/null)" >/dev/null 2>&1
                    printf '%s' "${!keyenv:-}" ) )" ]; then
        printf '%s\t%s\n' "$n" "$d"; found=1
      fi
    done
  fi
  [ "$found" -eq 1 ] && return 0
  local cn=""; [ -n "$cur" ] && cn="$(ws_name "$cur" 2>/dev/null || true)"
  printf '%s\t%s\n' "$cn" "$cur"
}

_quota_balances() { # [provider] [wsdir]
  local wsdir="${2:-}"
  local p list; list="$(_quota_providers "${1:-}")"
  printf '  %-12s %-12s %-14s %-8s %s\n' PROVIDER WORKSPACE REMAINING FLOOR STATE
  local r floor st wn wd
  for p in $list; do
    while IFS=$'\t' read -r wn wd; do
    r="$(quota_remaining "$p" "$wd")"; floor="$(provider_balance "$p" floor)"
    # TWO KINDS OF `unknown`, AND THEY ARE NOT THE SAME NEWS. No key in this
    # workspace is where you are standing - credit is workspace-scoped by
    # decision, and a workspace without the key is behaving correctly.
    # Asking and not being able to tell is a fault.
    if [ "$r" = unknown ]; then st="$(quota_state_human "$(quota_state "$p" "$wd" "$r")")"
    elif quota_vetoed "$p" "$r"; then st="VETOED - below floor; workers will not be sent here"
    else st="ok"; fi
    [ "$r" = unknown ] || r="$(printf '%.2f' "$r")"
    printf '  %-12s %-12s %-14s %-8s %s\n' "$p" "${wn:--}" "$r $(provider_balance "$p" unit)" "${floor:--}" "$st"
    done < <(_quota_owners "$p" "$wsdir")
  done
}
