#!/usr/bin/env bash
# claude Stop hook: an agent does not end its turn on an unanswered decision
# without being told so.
#
# The failure this closes: an agent's inbox Monitor dies silently, it goes
# idle, and nothing notices until a human asks - root sat nine hours behind on
# exactly this. Before the turn ends, if this pane's identity has UNRESOLVED
# decisions or blockers (`cel inbox open`, which ignores the read cursor), the
# stop is blocked ONCE with the count and the re-arm instruction. A marker
# file bounds it to one block per turn so it can never loop; the marker is
# cleared on the next clean stop. Fails open on every error of its own.
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
    printf 'Then re-arm your monitor before stopping: Monitor(command: "cel inbox watch", persistent: true)\n'
  } >&2
  exit 2
fi
rm -f "$mark" 2>/dev/null
exit 0
