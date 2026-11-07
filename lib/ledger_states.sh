# shellcheck shell=bash
# THE LIST OF DELEGATION LEDGER STATES. cel-fanout refuses to write any other;
# gc and doctor read this same list, so every state a writer can produce is
# one the readers know.
[ -n "${_CEL_LEDGER_STATES:-}" ] && return 0
_CEL_LEDGER_STATES=1

CEL_LEDGER_STATES="running unconfirmed finished orphaned collected salvaged reported released landed abandoned"

ledger_state_valid() { # <state>
  case " $CEL_LEDGER_STATES " in *" $1 "*) [ -n "$1" ] ;; *) return 1 ;; esac
}

# The states a row never leaves: its work is over, and nothing reconciles or
# watches it again.
CEL_LEDGER_TERMINAL_STATES="released landed abandoned"

# True when <ledger> has a row some sweep still has to look at - any state not
# terminal, an unknown or missing one included. No file, or nothing but
# terminal rows, is false. A ledger jq cannot read is true: unknown is never
# taken as "nothing to do". One jq pass, cheap enough for every tick.
ledger_has_live_rows() { # <delegations.json>
  [ -s "$1" ] || return 1
  local rc=0
  jq -e --arg t " $CEL_LEDGER_TERMINAL_STATES " \
    'any((if type == "array" then .[] else .delegations[]? end);
         (" " + ((.state // "") | tostring) + " ") as $s | $t | contains($s) | not)' \
    "$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 1 ]
}
