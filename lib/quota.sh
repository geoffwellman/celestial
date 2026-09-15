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

# Is this remaining amount below the provider's floor? 1 = vetoed.
quota_vetoed() { # <provider> <remaining>
  local floor; floor="$(provider_balance "$1" floor)"
  [ -n "$floor" ] || return 1
  [ "$2" = unknown ] && return 1
  awk -v r="$2" -v f="$floor" 'BEGIN { exit !(r+0 < f+0) }'
}

cmd_quota() { # [provider]
  local wsdir; wsdir="$(ws_current 2>/dev/null || true)"
  local p list
  if [ $# -ge 1 ]; then list="$1"; else
    list="$(yq -r '.providers | to_entries[] | select(.value.balance != null) | .key' "$CEL_MANIFEST")"
  fi
  printf '  %-12s %-14s %-8s %s\n' PROVIDER REMAINING FLOOR STATE
  for p in $list; do
    local r floor st
    r="$(quota_remaining "$p" "$wsdir")"; floor="$(provider_balance "$p" floor)"
    if [ "$r" = unknown ]; then st="unknown (no key here, or endpoint unreachable)"
    elif quota_vetoed "$p" "$r"; then st="VETOED - below floor; workers will not be sent here"
    else st="ok"; fi
    [ "$r" = unknown ] || r="$(printf '%.2f' "$r")"
    printf '  %-12s %-14s %-8s %s\n' "$p" "$r $(provider_balance "$p" unit)" "${floor:--}" "$st"
  done
}
