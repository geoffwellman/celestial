#!/usr/bin/env bash
# Claude Stop hook: mail arriving during a turn must not be stranded until
# somebody types again. Block completion once with the mail as the continuation
# reason; the turn can act on it, and the next Stop sees an empty mailbox.
set -uo pipefail
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
[ -x "$CEL_ROOT/bin/cel" ] || exit 0
args=(inbox read)
[ -z "${CEL_INBOX_ME:-}" ] || args+=(--for "$CEL_INBOX_ME")
[ -z "${CEL_INBOX_WS:-}" ] || args+=(--workspace "$CEL_INBOX_WS")
mail="$("$CEL_ROOT/bin/cel" "${args[@]}" 2>/dev/null)" || exit 0
[ -n "$mail" ] || exit 0
jq -nc --arg m "$mail" '{decision:"block",reason:("New messages arrived in your celestial inbox while you were working. Act on them before stopping:\n" + $m)}'
