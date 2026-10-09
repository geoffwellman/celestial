# shellcheck shell=bash
# THE ONE LIST OF DELEGATION LEDGER STATES. cel-fanout writes them, gc and
# doctor read them. On 2026-10-09 gc carried its own copy that lacked
# `abandoned` - a state `cel-fanout reconcile` itself writes - and one such row
# made gc fail closed for every worktree on the box.
[ -n "${_CEL_LEDGER_STATES:-}" ] && return 0
_CEL_LEDGER_STATES=1

CEL_LEDGER_STATES="running unconfirmed finished orphaned collected salvaged reported released landed abandoned"

ledger_state_valid() { # <state>
  case " $CEL_LEDGER_STATES " in *" $1 "*) [ -n "$1" ] ;; *) return 1 ;; esac
}
