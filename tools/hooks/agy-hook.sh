#!/usr/bin/env bash
# agy (Google Antigravity CLI) native hooks, from the `celestial` entry cel
# merges into ~/.gemini/config/hooks.json (lib/agy.sh agy_hooks_link):
#   session  SessionStart   the conversation id, to Rex (Herdr's own
#                           antigravity-cli hook reports it to Herdr)
#   invoke   PreInvocation  mail waiting when a turn starts, attached to it
#   stop     Stop           mail that came during the turn continues it; a
#                           conversation about to go idle with no inbox waiter
#                           running is sent back once to start one
# An idle agy wakes on nothing but one of its own background tasks finishing,
# so the waiter (`cel inbox wait`, lib/inbox.sh) is that task, and its exit on
# new mail is the wake. Nothing here ever types into a pane.
#
# agy wants a JSON object on stdout from every hook: every path prints one.
# A session cel did not launch (no CEL_INBOX_ME/CEL_INBOX_WS) gets `{}` and
# nothing read or recorded.
set -uo pipefail
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
event="${1:-}"
reply() { if [ $# -gt 0 ]; then printf '%s\n' "$1"; else printf '{}\n'; fi; exit 0; }
payload="$(cat 2>/dev/null)" || payload=""
me="${CEL_INBOX_ME:-}" ws="${CEL_INBOX_WS:-}"
[ -n "$me" ] && [ -n "$ws" ] && [ -x "$CEL_ROOT/bin/cel" ] || reply
command -v jq >/dev/null 2>&1 || reply
conv="$(jq -r 'select(type == "object") | .conversationId // empty' <<<"$payload" 2>/dev/null)" || conv=""
[[ "$conv" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || conv=""
field() { jq -r --arg k "$1" 'select(type == "object") | .[$k] // empty | tostring' <<<"$payload" 2>/dev/null; }

# Rex records whose conversation this is and whether it is working, proven by
# process ancestry (lib/rex.sh rex_reporter_pid), never by a label.
note() { # <idle|working>
  [ -n "${CEL_REX_RECORD:-}" ] && [ -f "$CEL_REX_RECORD" ] && [ -n "$conv" ] || return 0
  (
    # shellcheck source=lib/rex.sh
    . "$CEL_ROOT/lib/rex.sh" 2>/dev/null || exit 0
    jq -e '.agent == "agy" and .backend == "rex"' "$CEL_REX_RECORD" >/dev/null 2>&1 || exit 0
    pid="$(rex_reporter_pid)" || exit 0
    "$CEL_ROOT/bin/cel" sessions note "$pid" "$1" "$conv" >/dev/null 2>&1
  ) || true
}
mail() { "$CEL_ROOT/bin/cel" inbox read --for "$me" --workspace "$ws" 2>/dev/null || true; }

case "$event" in
  session)
    note working
    reply ;;
  invoke)
    note working
    # Only a turn's first model call: later steps of the same turn leave
    # their mail to Stop, so one turn is never handed the same queue twice.
    [ "$(field invocationNum)" = 0 ] || reply
    m="$(mail)"
    [ -n "$m" ] || reply
    reply "$(jq -cn --arg m "$m" '{injectSteps: [{systemMessage: {systemMessage: ("Messages waiting in your celestial inbox (delivered once):\n" + $m + "\nAct on them as part of this turn, or say why not.")}}]}')" ;;
  stop)
    m="$(mail)"
    if [ -n "$m" ]; then
      note working
      reply "$(jq -cn --arg m "$m" '{decision: "continue", reason: ("New messages arrived in your celestial inbox while you were working. Act on them before stopping:\n" + $m)}')"
    fi
    if ! "$CEL_ROOT/bin/cel" inbox wait --check --for "$me" --workspace "$ws" >/dev/null 2>&1 \
       && [ "$(field continuationActive)" != true ]; then
      note working
      # shellcheck source=lib/agy.sh
      . "$CEL_ROOT/lib/agy.sh" 2>/dev/null || reply
      reply "$(jq -cn --arg w "$(agy_wait_instruction)" '{decision: "continue", reason: ("No inbox waiter is running, so mail would not wake you once you stop. " + $w)}')"
    fi
    note idle
    reply ;;
esac
reply
