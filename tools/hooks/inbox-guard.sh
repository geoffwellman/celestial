#!/usr/bin/env bash
# claude Stop hook: an agent does not end its turn on an unanswered decision
# without being told so.
#
# Claude's Stop hook cannot wake an idle session; this guard only catches an
# unanswered decision or blocker while a turn is active. Before that turn ends,
# `cel inbox open` identifies unresolved decisions/blockers regardless of the
# read cursor. A marker bounds the block to once per turn, so it cannot loop.
# Fails open on every error of its own.
#
# Register in ~/.claude/settings.json under hooks.Stop:
#   {"hooks":[{"type":"command","command":"bash <CEL_ROOT>/tools/hooks/inbox-guard.sh","timeout":10}]}
set -uo pipefail
[ "${CEL_INBOX_GUARD:-1}" = 0 ] && exit 0
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
cel="$CEL_ROOT/bin/cel"
[ -x "$cel" ] || exit 0

me="$("$cel" inbox whoami 2>/dev/null | tr -d '\r\n')" || exit 0
[ -n "$me" ] || exit 0
open="$("$cel" inbox open 2>/dev/null | wc -l | tr -d ' ')" || exit 0
mark="${TMPDIR:-/tmp}/cel-inbox-guard-${me}"

if [ "${open:-0}" -gt 0 ] && [ ! -f "$mark" ]; then
  : > "$mark" 2>/dev/null || exit 0
  {
    printf 'celestial: %s unresolved decision(s)/blocker(s) in your inbox. Reading them did not resolve them.\n' "$open"
    printf 'Run `cel inbox open`, act on each or answer it, then `cel inbox resolve <id>`.\n'
    printf 'Mail arriving after this turn ends waits for the next submitted turn; Claude has no idle Monitor.\n'
  } >&2
  exit 2
fi
rm -f "$mark" 2>/dev/null
exit 0
