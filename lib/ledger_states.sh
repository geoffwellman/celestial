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

# True when <ledger> may hold a row some sweep still has to look at. False in
# exactly two cases: the file does not exist (no delegation was ever made in
# this workspace), or it is a list of rows - the document itself, or its
# `.delegations` - every one of them in a terminal state. Anything else is
# true, because unknown is never taken as "nothing to do": a row in an unknown
# or missing state, an empty file, a document of any other shape ('null',
# '{}', '{"delegations": null}') or one jq cannot read. One jq pass, cheap
# enough for every tick.
ledger_has_live_rows() { # <delegations.json>
  [ -e "$1" ] || return 1
  local rc=0
  jq -e --arg t " $CEL_LEDGER_TERMINAL_STATES " '
    (if type == "array" then .
     elif type == "object" and (.delegations | type) == "array" then .delegations
     else null end) as $rows
    | if $rows == null then true
      else any($rows[]; (" " + ((.state // "") | tostring) + " ") as $s | $t | contains($s) | not)
      end' "$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 1 ]
}
