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
