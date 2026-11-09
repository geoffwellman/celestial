# shellcheck shell=bash
# cel steward - one proactive tick over everything the plane supervises,
# deterministic and token-free. Each tick: collect garbage, sweep every
# registered workspace's review flow and nudge the responsible orchestrator
# when it has stalled, surface blocked agents, and check the plane's own
# servers answer. Nudges are rate-limited per PR through a state file so a
# stuck orchestrator is reminded, not spammed. Keep it running with
# `cel steward --install` (a systemd user timer).
[ -n "${_CEL_STEWARD:-}" ] && return 0
_CEL_STEWARD=1
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/gc.sh
. "${BASH_SOURCE[0]%/*}/gc.sh"
# shellcheck source=lib/box.sh
. "${BASH_SOURCE[0]%/*}/box.sh"
# shellcheck source=lib/pages.sh
. "${BASH_SOURCE[0]%/*}/pages.sh"
# shellcheck source=lib/dash.sh
. "${BASH_SOURCE[0]%/*}/dash.sh"
# shellcheck source=lib/inbox.sh
. "${BASH_SOURCE[0]%/*}/inbox.sh"
# shellcheck source=lib/run.sh
. "${BASH_SOURCE[0]%/*}/run.sh"
# shellcheck source=lib/memory.sh
. "${BASH_SOURCE[0]%/*}/memory.sh"
# shellcheck source=lib/orphans.sh
. "${BASH_SOURCE[0]%/*}/orphans.sh"
# shellcheck source=lib/services.sh
# shellcheck source=lib/serve.sh
. "${BASH_SOURCE[0]%/*}/serve.sh"
. "${BASH_SOURCE[0]%/*}/services.sh"

# Overridable so the pane sweeps can be driven against a stub herdr.
_STEWARD_HERDR="${CEL_STEWARD_HERDR:-herdr}"
_STEWARD_STATE="${CEL_STEWARD_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/steward-state}"
_STEWARD_WINDOW="${CEL_STEWARD_WINDOW:-14400}"   # repeat-nudge window, seconds

# ONE WRITER AT A TIME, AND NEVER A TORN FILE. Every rewrite of a steward state
# file goes through here: under the file's own lock, <fn> reads the current
# content on stdin and prints the new content, which is published through a
# unique temp file in the same directory and a rename. A non-zero <fn> leaves
# the file as it was and is the return status, so a check and its record (is
# this key due?) are one step that no other writer can get between.
#
# A writer killed between its temp file and the rename leaves the temp behind,
# so each edit first sweeps this file's own leftovers: mktemp's names, and the
# fixed `.tmp` / `.tmp.<pid>` names older code used. Only ones an hour old -
# an edit takes milliseconds - and never a sibling state or lock file.
_steward_state_edit() { # <file> <fn> [args...]
  local f="$1" rc=0 an='[A-Za-z0-9]'; shift
  mkdir -p "$(dirname "$f")" && touch "$f" || return 1
  (
    if have flock; then flock 9 || exit 1; fi
    base="$(basename "$f")"
    find "$(dirname "$f")" -maxdepth 1 -type f -mmin +60 \
      \( -name "$base.$an$an$an$an$an$an" -o -name "$base.tmp" -o -name "$base.tmp.[0-9]*" \) \
      ! -name "$base.lock" -delete 2>/dev/null || true
    tmp="$(mktemp "$f.XXXXXX")" || exit 1
    chmod --reference="$f" "$tmp" 2>/dev/null || true
    "$@" < "$f" > "$tmp" || { st=$?; rm -f "$tmp"; exit "$st"; }
    mv -f "$tmp" "$f" || { rm -f "$tmp"; exit 1; }
  ) 9>>"$f.lock" || rc=$?
  return "$rc"
}

# The edits, each a filter from the old content to the new. A record is one
# line: "<key> <value...>".
_steward_state_due() { # <key> <now> <window>: record now, or fail inside the window
  awk -v k="$1" -v now="$2" -v w="$3" '
    $1 == k { t = $2; next } { print }
    END { if (now - (t + 0) < w) exit 1; print k, now }'
}
_steward_state_note() { # <key> <now>: record now unless already recorded
  awk -v k="$1" -v now="$2" '{ print } $1 == k { f = 1 } END { if (f) exit 1; print k, now }'
}
_steward_state_set() { # <key> <value...>: replace the record
  local k="$1"; shift
  awk -v k="$k" -v line="$k $*" '$1 != k { print } END { print line }'
}
_steward_state_add() { # <key> <n>: add n to the record's value
  awk -v k="$1" -v n="$2" '$1 == k { t = $2; next } { print } END { printf "%s %.0f\n", k, t + n }'
}
_steward_state_drop() { # <key>: drop the record; fail when there is none
  awk -v k="$1" '$1 == k { f = 1; next } { print } END { exit !f }'
}
_steward_state_drop_unseen() { # <prefix> [key...]: drop prefix* records but the keys named; fail if none
  local p="$1"; shift
  awk -v p="$p" -v keep=" $* " '
    index($1, p) == 1 && index(keep, " " $1 " ") == 0 { f = 1; next } { print }
    END { exit !f }'
}

# True (and records the nudge) when this key has not been nudged inside the
# window. Keys carry no spaces: "owner/repo#1".
_steward_due() { # <key>
  _steward_state_edit "$_STEWARD_STATE" _steward_state_due "$1" "$(date +%s)" "$_STEWARD_WINDOW"
}

# THE STEWARD SAYS A THING ONCE. A raise carries a condition key, so a repeat
# lands as an update on the item already open instead of a fresh item.
_steward_raise() { # <ws> <fp> <kind> <message>
  cmd_inbox send root "$4" --from steward --workspace "$1" --kind "$3" --fp "$2" \
    >/dev/null 2>&1 || true
}

# ONCE PER CHANGE OF STATE. Some conditions only the owner can change - an
# interactive login - and re-raising them every window says nothing new. This
# raises when no item with the key is open, or when the open item's latest
# word differs from <message>; an unchanged state says nothing. So the message
# must carry the state and nothing that drifts per tick - no percentages, no
# clock times.
_steward_raise_on_change() { # <ws> <fp> <kind> <message>
  local id last
  # a mailbox that does not parse says nothing this tick: unknown is not absent
  id="$(_inbox_open_fp "$1" "$2" steward root)" || return 0
  if [ -n "$id" ]; then
    last="$(jq -r -s --arg i "$id" \
      '[.[] | select(.id == $i or (.kind == "update" and .ref == $i)) | .message] | last // ""' \
      "$(_inbox_file "$1")" 2>/dev/null || true)"
    [ "$last" = "$4" ] && return 0
  fi
  _steward_raise "$@"
}

# ...and takes it down again once its condition stops being true, so the
# backlog does not only grow. A `cleared:` status line goes with it, because an
# item that vanishes silently leaves the operator wondering whether it was
# fixed or merely lost.
# ONE LINE PER CHANGE. Every open item under the key goes in one pass: a
# mailbox from before roll-up holds several, and taking down one per tick said
# `cleared:` every tick until the last was gone. The line goes out only when
# something was resolved - a failed resolve leaves the item open, and the next
# tick tries again rather than having said a false thing.
_steward_clear_ids() { # <ws> <message> <id...>
  local ws="$1" msg="$2" id n=0; shift 2
  for id in "$@"; do
    [ -n "$id" ] || continue
    if cmd_inbox resolve "$id" --by steward --workspace "$ws" >/dev/null 2>&1; then n=$((n + 1)); fi
  done
  [ "$n" -gt 0 ] || return 0
  cmd_inbox send root "cleared: $msg" --from steward --workspace "$ws" --kind status \
    >/dev/null 2>&1 || true
  c_ok "$ws: cleared - $msg"
}

_steward_clear() { # <ws> <fp> <message>
  local ids; ids="$(_inbox_open_fp_ids "$1" "$2" steward root)" || return 0
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086 # ids are digits, one per line
  _steward_clear_ids "$1" "$3" $ids
}

# Every pane herdr can see, one per line. Empty means herdr did not answer,
# and the caller must treat that as no evidence rather than as a dead box.
_steward_panes() {
  local ids w
  ids="$("$_STEWARD_HERDR" workspace list 2>/dev/null \
    | jq -r '.result.workspaces[]?.workspace_id // empty' 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    for w in $ids; do
      "$_STEWARD_HERDR" pane list --workspace "$w" 2>/dev/null \
        | jq -r '.result.panes[]?.pane_id // empty' 2>/dev/null || true
    done
  fi
}

# DEAD PANES. A STALLED WORKER item names the pane the operator
# would go and look at; when that pane no longer exists on the box there is
# nothing left to act on, and the item is pure noise in a mailbox someone has
# to read. Cleared once per tick, and only when herdr actually answered -
# an unreachable herdr is not evidence that every pane died.
_steward_clear_dead_panes() {
  local panes; panes="$(_steward_panes)"
  [ -n "$panes" ] || return 0
  local ws id pane
  for ws in $(registry_names); do
    while IFS=$'\t' read -r id pane; do
      [ -n "$id" ] && [ -n "$pane" ] || continue
      # Herdr pane discovery says nothing about a Rex session's existence.
      case "$pane" in rex/*) continue;; esac
      if printf '%s\n' "$panes" | grep -qxF "$pane"; then continue; fi
      _steward_clear_ids "$ws" "pane gone" "$id"
    done < <(cmd_inbox open --for root --workspace "$ws" --json 2>/dev/null \
      | jq -r 'select(.from == "steward")
               | select(.message | startswith("STALLED WORKER"))
               | [.id, ((.message | capture("^STALLED WORKER [^(]*\\((?<p>[^)]*)\\)") | .p) // "")]
               | @tsv' 2>/dev/null || true)
  done
}

# STALE MAIL AND OPEN DECISIONS. Mail unread for half an hour means the
# recipient may not have seen it. Remind every mailbox by inbox, never by
# typing into a pane; delivery behavior remains runtime-specific.
_steward_mail_sweep() { # <agents-json>
  local agents_json="$1"
  local ws wsdir who n oldest age pane
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    local f; f="$(_inbox_file "$ws")"
    [ -s "$f" ] || continue
    # A corrupt mailbox is unknown, not "nothing actionable": said once for
    # the file (every recipient in it reads the same), and nothing concluded.
    local whos
    if ! whos="$(jq -r '.to' "$f" 2>/dev/null)"; then
      c_warn "$ws: mailbox $f is corrupt - its unread mail is unknown"
      continue
    fi
    for who in $(printf '%s\n' "$whos" | sort -u); do
      case "$who" in *:*) continue;; esac   # pane-addressed, not a mailbox
      # the owner's queue is `cel decide`, summarised once a day below
      [ "$who" = owner ] && continue
      # ONLY MAIL THAT NEEDS SOMEONE: escalations, decisions and blockers from
      # other senders. Done-reports (`status`) and the steward's own earlier
      # reminders ask nothing of anyone.
      local waiting
      # (the file can tear between the two reads)
      if ! waiting="$(_steward_unread_actionable "$ws" "$who")"; then
        c_warn "$ws: mailbox $f is corrupt - its unread mail is unknown"
        continue 2
      fi
      n="$(printf '%s\n' "$waiting" | grep -c . || true)"
      [ "${n:-0}" -gt 0 ] || continue
      # age of the OLDEST unread, not the newest: that is how long the
      # recipient has actually been behind
      oldest="$(printf '%s\n' "$waiting" | jq -r '.ts' 2>/dev/null | sort | sed -n 1p)"
      [ -n "$oldest" ] || continue
      age=$(( $(date +%s) - $(date -d "$oldest" +%s 2>/dev/null || date +%s) ))
      [ "$age" -ge 1800 ] || continue

      # Resolve the mailbox's pane for status text only. Every reminder below
      # still goes to the inbox, regardless of whether a pane is live.
      local target="" want=""
      want="$(_steward_mailbox_want "$who" "$(ws_name "$wsdir")")"
      if [ "$who" = root ]; then
        target="$wsdir"
      else
        target="$(_steward_orch_dir "$wsdir" "$who")"
      fi
      # Match the exact alias first; cwd is a fallback only for root/orch
      # mailboxes. This lookup never chooses a delivery route.
      pane=""
      [ -n "$want" ] && pane="$(printf '%s' "$agents_json" | jq -r --arg n "$want" \
        '[.result.agents[] | select(.name == $n)][0].pane_id // empty')"
      [ -n "$pane" ] || { [ -n "$target" ] && pane="$(printf '%s' "$agents_json" \
        | jq -r --arg d "$target" '[.result.agents[] | select(.cwd == $d)][0].pane_id // empty')"; }

      local readcmd="cel inbox read --for $who --workspace $ws"
      local stale_msg="steward: $n unread escalation(s)/decision(s)/blocker(s) in your celestial inbox, oldest untouched $((age / 60))m. Run '$readcmd' now and act on the escalations first."
      # Never type into any agent's composer. Runtime delivery differs: Pi/OMP
      # can wake idle agents; Claude hooks run only on a submitted turn or
      # while a turn is active.
      if _steward_due "inbox-stale-$ws-$who"; then
        _steward_remind "$ws" "$who" remind-unread status "$stale_msg" \
          && c_warn "$ws/$who: $n unread ($((age / 60))m) - mailed a reminder"
      else
        c_warn "$ws/$who: $n unread, oldest $((age / 60))m$([ -z "$pane" ] && printf ' (no pane)')"
      fi
    done
  done

  # OWNER DECISIONS: ONE LINE A DAY, NEVER A DECISION ITSELF. Questions for the
  # owner live in `cel decide`; per-recipient reminders would be counted as open
  # items in their own right. The steward's whole contribution is a status line
  # per workspace per day saying how many are waiting and for how long.
  # shellcheck source=lib/decide.sh
  . "${BASH_SOURCE[0]%/*}/decide.sh"
  for ws in $(registry_names); do
    local open3 n3 age3 who3
    open3="$(decide_open_json "$ws")"
    [ -n "$open3" ] || continue
    n3="$(printf '%s\n' "$open3" | grep -c . || true)"
    age3="$(printf '%s\n' "$open3" | jq -r '.age_secs' | sort -n | tail -1)"
    # Routed questions (people:) are counted per person they wait on; with
    # none routed the line reads as it always has.
    who3="$(printf '%s\n' "$open3" | jq -rs '
      [.[] | (.route.people // [])[]] as $p
      | if ($p | length) == 0 then "" else
          " - waiting on " + ($p | group_by(.) | map(.[0] + " " + (length | tostring)) | join(", "))
          + "; " + ([.[] | select(((.route.people // []) | length) == 0)] | length | tostring) + " unrouted" end')"
    _STEWARD_WINDOW=86400 _steward_due "decide-summary-$ws" || continue
    cmd_inbox send root "steward: $n3 open owner decision(s) in $ws, oldest $(( ${age3:-0} / 3600 ))h$who3 - 'cel decide list'" \
      --from steward --workspace "$ws" --kind status >/dev/null 2>&1 || true
    c_warn "$ws: $n3 open owner decision(s) - see cel decide list"
  done
  _steward_decide_stale_sweep
}

# STALE QUESTIONS GO BACK TO WHOEVER ASKED. A decision may have been settled in
# an orchestrator's chat or made moot by a merge, and only the asker knows - so
# once a day each asker gets ONE message listing its questions older than three
# days and is asked to confirm or withdraw them. The day window stops repeats;
# the fp rolls a next-day nudge into the one still open instead of stacking a
# second item beside it.
_steward_decide_stale_sweep() {
  local ws open asker
  for ws in $(registry_names); do
    # idle, not age: a question the asker re-asked yesterday is not stale
    # a recent "still needed" (newer than any change) silences it
    open="$(decide_open_json "$ws" | jq -c --argjson cw "${CEL_DECIDE_CONFIRM_SECS:-604800}" \
      'select((.idle_secs // .age_secs) >= 259200)
       | select((.confirmed_secs // null) == null or .confirmed_secs >= $cw)' 2>/dev/null || true)"
    [ -n "$open" ] || continue
    for asker in $(printf '%s\n' "$open" | jq -r '.asker // empty' | sort -u); do
      case "$asker" in owner|steward|dashboard|'') continue ;; esac
      _steward_stale_nudge_once "$ws" "$asker" "$open" || true
    done
  done
}

# CHECK, SEND, RECORD - UNDER ONE LOCK. The day key is written only after the
# mail landed, so a failed send does not silence the asker for a day, and the
# lock spanning all three stops two sweeps from both passing the check and
# both sending.
_steward_stale_nudge_once() { # <ws> <asker> <open-json-lines>
  local ws="$1" asker="$2" open="$3" lock key last list
  key="decide-stale-$ws-$asker"
  mkdir -p "${_STEWARD_STATE%/*}"; touch "$_STEWARD_STATE"
  lock="$_STEWARD_STATE.decide-stale.lock"
  (
    if have flock; then flock 7; fi
    last="$(awk -v k="$key" '$1==k{t=$2} END{print t+0}' "$_STEWARD_STATE")"
    [ $(( $(date +%s) - last )) -ge 86400 ] || exit 0
    list="$(printf '%s\n' "$open" | jq -r --arg a "$asker" \
      'select(.asker == $a) | "  [\(.id)] \(.title) (\((.age_secs / 86400) | floor)d)"')"
    if ! cmd_inbox send "$asker" "steward: your open owner decision(s) in $ws older than 3 days - if one still needs the owner say so with 'cel decide confirm <id>' (quiet for 7 days unless it changes), or withdraw it with 'cel decide withdraw <id> --why <text>' if it was settled or is moot:"$'\n'"$list" \
        --from steward --workspace "$ws" --kind status --fp decide-stale >/dev/null 2>&1; then
      c_warn "$ws: could not mail $asker about stale decision(s); will retry next sweep"
      exit 1
    fi
    _STEWARD_WINDOW=0 _steward_due "$key" || true
    c_warn "$ws: asked $asker to confirm or withdraw stale decision(s)"
  ) 7>>"$lock"
}

# Unread mail for <who> that someone must answer, decide or unblock - one JSON
# object per line. Never `status`, never the steward's own reminders.
# Returns 1 with nothing when the mailbox is corrupt: unknown, never empty.
_steward_unread_actionable() { # <ws> <who>
  local items
  items="$(inbox_unread_json "$1" "$2" 2>/dev/null)" || return 1
  [ -n "$items" ] || return 0
  printf '%s\n' "$items" | jq -c '
    select(.kind == "escalation" or .kind == "decision" or .kind == "blocked")
    | select(.from != "steward")' 2>/dev/null || true
}

# ONE LIVE REMINDER PER RECIPIENT AND KIND. Posting a new one resolves every
# earlier open one with the same key, with a resolution line naming its
# replacement so nothing vanishes unexplained.
_steward_remind() { # <ws> <who> <fp> <kind> <message>
  local ws="$1" who="$2" fp="$3" kind="$4" msg="$5" f new prev id legacy=""
  f="$(_inbox_file "$ws")"
  mkdir -p "$(dirname "$f")"
  new="$(date +%s%N)"
  # Legacy reminders carry no fp, so they are recognised by their sentence -
  # otherwise the first reminder after an upgrade would leave every old one
  # open beside it.
  case "$fp" in
    remind-open)   legacy="UNRESOLVED decision" ;;
    remind-unread) legacy="in your celestial inbox" ;;
  esac
  prev="$(jq -r -s --arg fp "$fp" --arg to "$who" --arg legacy "$legacy" '
    ([.[] | select(.kind == "resolution") | .ref]) as $done
    | .[] | select(.from == "steward" and .to == $to and .kind != "resolution" and .kind != "update")
    | select((.fp // "") == $fp
             or ((.fp // "") == "" and $legacy != "" and ((.message // "") | contains($legacy))))
    | select([.id] | inside($done) | not) | .id' "$f" 2>/dev/null || true)"
  # RESOLUTIONS FIRST. Interrupted between the two writes, this order leaves
  # at most the new reminder missing - never two live ones - and a failed
  # resolution fails the call rather than posting a duplicate beside it.
  for id in $prev; do
    _inbox_append "$f" "$(jq -nc --arg id "$(date +%s%N)" --arg ts "$(date -Is)" --arg ref "$id" \
      --arg to "$who" --arg new "$new" \
      '{id: $id, ts: $ts, kind: "resolution", ref: $ref, by: "steward", to: $to, message: ("superseded by " + $new)}')" \
      || return 1
  done
  _inbox_append "$f" "$(jq -nc --arg id "$new" --arg ts "$(date -Is)" --arg to "$who" \
    --arg kind "$kind" --arg msg "$msg" --arg fp "$fp" \
    '{id: $id, ts: $ts, to: $to, from: "steward", kind: $kind, message: $msg, fp: $fp}')" || return 1
  return 0
}

# A NUDGE IS MAIL. Every recipient gets a rate-limited inbox
# message; the runtime controls when it can be delivered to an agent turn.
_steward_nudge() { # <mailbox> <workspace> <key> <message>
  _steward_due "$3" || return 0
  local kind=status
  case "$3" in *-blocked) kind=blocked ;; esac
  if cmd_inbox send "$1" "$4" --from steward --workspace "$2" --kind "$kind" >/dev/null 2>&1; then
    c_ok "mailed $1: $4"
  else
    c_warn "wanted to mail $1 (inbox send failed): $4"
  fi
}

# The steward addresses orchestrators by the name cel run gave them: the same
# rule, not a copy of it (cel_alias_norm, lib/common.sh).
_steward_agent_name() { cel_alias_norm "$1"; }

# Which herdr agent owns a mailbox - the inverse of lib/inbox.sh's identity.
#
#   root            -> <workspace>-root
#   <repo>-orch     -> <repo>-orch   (and <product>-orch alike: a product
#                      orchestrator's mailbox is named by the same rule, so
#                      the *-orch case below already covers it)
#   anything else   -> A WORKER, whose mailbox name IS its agent name: both
#                      come from the same <repo>-<branch> string through the
#                      same rule (_inbox_sanitise, _run_agent_name and this file's
#                      _steward_agent_name all call cel_alias_norm).
#
# Workers can wait on inbox instructions too; resolving only root and
# orchestrator panes would silently leave their unread mail unattended.
_steward_mailbox_want() { # <who> <workspace-name>
  case "$1" in
    root) _steward_agent_name "$2/root" ;;
    *-orch) _steward_agent_name "${1%-orch}/orch" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Where a <name>-orch actually stands, for the cwd fallbacks below. A DECLARED
# product has its own directory under products/; an implicit one is only a
# repo. Telling them apart by reading workspace.yaml is not available here -
# identity in this plane is derived from paths, deliberately - so the
# directory's existence is the test. Both sweeps call this rather than
# spelling the choice out twice, which is how the two of them drifted before.
_steward_orch_dir() { # <wsdir> <name>
  local wsdir="$1" name="$2" p="${2%-orch}"
  [ "$p" != "$name" ] || return 0
  if [ -d "$wsdir/products/$p" ]; then printf '%s/products/%s' "$wsdir" "$p"
  else printf '%s/repos/%s' "$wsdir" "$p"; fi
}

# Starting an orchestrator is MECHANICAL, so the steward does it rather than
# root. Root started them by hand and produced duplicate panes bound to
# hand-made workspaces nobody could tell apart; a product declaring
# `orchestrator: auto` is a standing instruction to have one, which is the
# same shape as "this workspace declares a dashboard port".
#
# The launch is its own function so tests can replace it: calling `cel run`
# for real would open a pane on the live box.
_steward_launch_orch() { # <product> <workspace>
  cel run orchestrator --product "$1" --workspace "$2" >/dev/null 2>&1
}

# AN ALERT THE OWNER ALREADY HOLDS A CARD FOR IS NOT AN ALERT. An orchestrator
# that will not start because it waits on an owner answer (a profile only the
# owner may reroute) was re-raised to root every half hour for days beside
# the open `cel decide` card that already asked the owner.
# A card carries no structured link to an agent - only to PRs (`--pr`) - so
# the link is what the asker wrote, and it is read narrowly: an open card in
# the same workspace whose title or blocks names the agent as a name of its
# own (`widget-orch`, but not `big-widget-orch` or `widget-orchestrator`), or
# names the product's own agent - the product as a name of its own followed
# directly by "orch", "orchestrator" or "solo agent" ("Restore Widget solo
# agent ..."). "Widget lane builder agent" names another agent of the
# product, and `widget-lane-orch` another agent altogether: neither matches.
# Names are matched literally, never as patterns.
_steward_owner_card() { # <ws> <agent> <product> -> "<id>\t<title>" or nothing
  # shellcheck source=lib/decide.sh
  . "${BASH_SOURCE[0]%/*}/decide.sh"
  decide_open_json "$1" | jq -r --arg a "$2" --arg p "$3" '
    def literal: ascii_downcase | gsub("(?<c>[.*+?^$()\\[\\]{}|\\\\])"; "\\\(.c)");
    ("(^|[^a-z0-9-])" + ($a | literal) + "($|[^a-z0-9-])") as $agent
    | ("(^|[^a-z0-9-])" + ($p | literal) + "\\s+(orch|orchestrator|solo\\s+agent)($|[^a-z0-9-])") as $main
    | select([(.title // ""), (.blocks // "")] | map(ascii_downcase) | any(test($agent) or test($main)))
    | [.id, .title] | @tsv' 2>/dev/null | head -n1
}

_steward_orchestrators() { # <agents-json>
  local agents_json="$1" ws wsdir p want live mode src card
  # An empty roster means herdr did not answer, not that every orchestrator
  # died - launching one per product on a transport failure would fill the box
  # with duplicate orchestrators.
  [ "$(printf '%s' "$agents_json" | jq -r '[.result.agents[]?] | length' 2>/dev/null || printf 0)" -gt 0 ] || return 0
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    [ -f "$wsdir/workspace.yaml" ] || continue
    for p in $(ws_product_names "$wsdir"); do
      # THE SAME RESOLVED VALUE `up` ACTS ON: both ask ws_orchestrator_mode, so
      # `cel ws up` and the steward never disagree. Only `auto` is ever
      # started: a product started deliberately, or not at all, must never be
      # started behind the operator's back.
      IFS=$'\t' read -r mode src <<< "$(ws_orchestrator_mode "$wsdir" "$p")"
      want="$(_run_agent_name "$p-orch")"
      if [ "$mode" != auto ]; then
        # Nobody asked for this one to be started, so its absence is not a
        # fault - any fault raised earlier comes down with a sentence that
        # says what is actually true.
        _steward_clear "$ws" "orch-ensure-$p" \
          "$ws/$p is set to manual; nothing will start it automatically ($mode via $src)"
        continue
      fi
      # NOT THIS LOGIN'S TO START (products[].home names another person, or
      # this login names none): somebody else's product is not a fault, so
      # nothing is said or raised - and a start fault raised before the home
      # was set comes down.
      if ! ws_product_home_check "$wsdir" "$p" >/dev/null; then
        _steward_clear "$ws" "orch-ensure-$p" \
          "$ws/$p runs on another login (products[].home: $(ws_product_home "$wsdir" "$p")) - this box does not start $want"
        continue
      fi
      live="$(printf '%s' "$agents_json" | jq -r --arg n "$want" \
        '[.result.agents[]? | select(.name == $n)] | length')"
      # It came back: whatever the steward raised about it is no longer true.
      [ "$live" = "0" ] || { _steward_clear "$ws" "orch-ensure-$p" "$want is back on the roster"; continue; }
      # An orchestrator that crash-loops would otherwise be relaunched every
      # tick, which is a fork bomb at five-minute cadence. Half an hour.
      _STEWARD_WINDOW=1800 _steward_due "orch-ensure-$ws-$p" || continue
      if _steward_launch_orch "$p" "$ws"; then
        c_ok "started $want - $ws/$p resolves orchestrator: auto (via $src) and had no live pane (retried at most every 30m)"
        _steward_clear "$ws" "orch-ensure-$p" "$want was started again"
      else
        card="$(_steward_owner_card "$ws" "$want" "$p")"
        if [ -n "$card" ]; then
          # The owner has the question; root gains nothing from the alarm too,
          # and one already raised comes down saying why.
          c_warn "$want will not start for $ws/$p and waits on owner decision ${card%%$'\t'*} - no alert while that card is open"
          _steward_clear "$ws" "orch-ensure-$p" \
            "$want will not start, and that waits on open owner decision ${card%%$'\t'*} (${card#*$'\t'}) - no alert while the card is open"
        else
          c_err "could not start $want for $ws/$p - cel run orchestrator --product $p --workspace $ws (retried at most every 30m)"
          # Once per change: the retry every half hour is not news to root.
          _steward_raise_on_change "$ws" "orch-ensure-$p" blocked \
            "steward: $ws/$p resolves orchestrator: auto (via $src) and $want will not start - cel run orchestrator --product $p --workspace $ws"
        fi
      fi
    done
  done
}

# A resumed orchestrator or solo lane without the canonical launch contract (a
# bare `omp --resume=<file>` after a herdr restart) cannot receive inbox
# hooks; one whose hook is loaded but whose `cel inbox watch --parent` child
# is gone (deaf) cannot either. Restart it through `cel run --restart` only
# when its composer is provably empty - losing a typed draft is worse than a
# missed wake; otherwise root is told, once.
#
# Its own functions so tests can replace them: a real restart opens a pane.
_steward_restart_orch() { # <product> <workspace> [lane]
  if [ -n "${3:-}" ]; then
    cel run solo --product "$1" --lane "$3" --workspace "$2" --restart >/dev/null 2>&1
  else
    cel run orchestrator --product "$1" --workspace "$2" --restart >/dev/null 2>&1
  fi
}

# EMPTY ONLY WHEN THE PANE PROVES IT. Neither herdr nor omp will tell another
# process what is in a composer, so the only evidence is the screen: omp
# draws its editor between two divider lines, and empty means nothing but
# whitespace or a prompt mark between the last two. No box, no read, or
# anything in it is treated as a draft.
_steward_composer_empty_text() { # <pane-text>
  [ -n "$1" ] || return 1
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*[─━═]{6,}[[:space:]]*$/ { n++; prev = cur; cur = ""; next }
    { cur = cur $0 "\n" }
    END {
      if (n < 2) exit 1
      gsub(/[[:space:]>❯›]/, "", prev)
      exit (prev == "" ? 0 : 1)
    }'
}

_steward_orch_composer_empty() { # <pane>
  local text
  text="$("$_STEWARD_HERDR" pane read "$1" --source detection --lines 40 2>/dev/null)" || return 1
  _steward_composer_empty_text "$text"
}

# CLAIM BEFORE RESTARTING. Two overlapping ticks (a timer tick beside a hand
# run) could both read an old timestamp and both restart the same pane, so
# the 30-minute check and its record are one locked step: the second tick
# finds the first one's claim and leaves the restart to it.
_steward_claim_restart() { # <key>
  _STEWARD_WINDOW=1800 _steward_due "$1"
}

# FIRST SEEN. A condition that must hold across ticks before the steward acts
# records when it was first observed; _steward_forget drops it once it is gone.
_steward_first_seen() { # <key> -> epoch first observed (recorded now if new)
  local first now
  now="$(date +%s)"
  _steward_state_edit "$_STEWARD_STATE" _steward_state_note "$1" "$now" || true
  first="$(awk -v k="$1" '$1==k{t=$2} END{print t+0}' "$_STEWARD_STATE" 2>/dev/null || true)"
  if [ "${first:-0}" -gt 0 ]; then printf '%s' "$first"; else printf '%s' "$now"; fi
}
_steward_forget() { # <key>
  _steward_state_edit "$_STEWARD_STATE" _steward_state_drop "$1" || true
}
# Drop every <prefix>* record but the keys named: a condition no row
# reported this tick - the agent gone, its row unreadable - starts over.
_steward_forget_unseen() { # <prefix> [key...]
  _steward_state_edit "$_STEWARD_STATE" _steward_state_drop_unseen "$@" || true
}

_steward_inbox_hooks() {
  local name ws p pane status state cmd lane unit fp stuck key seen seen_at now last why deaf_seen=()
  local gone hint still has_no fixed cleared lost esc
  while IFS=$'\t' read -r name ws p pane status state cmd lane; do
    [ -n "$name" ] || continue
    [ "$lane" != - ] || lane=""
    unit="$p${lane:+-lane-$lane}"
    fp="orch-nohook-$unit"; stuck="orch-nohook-stuck-$unit"; key="orch-hook-restart-$ws-$unit"
    seen="orch-deaf-seen-$ws-$unit"
    [ "$state" != deaf ] || deaf_seen+=("$seen")
    if [ "$state" = unknown ]; then
      # Native title rewriting is not a negative hook observation. Withdraw
      # the unsupported failure claim, but keep the uncertainty actionable.
      _steward_clear "$ws" "$fp" "$name missing-hook claim is unproven; native inbox evidence is unknown"
      _steward_clear "$ws" "$stuck" "$name missing-hook claim is unproven; native inbox evidence is unknown"
      c_warn "$name inbox evidence is unknown; inspect its native session and owned watcher, not its rewritten argv"
      _steward_remind "$ws" root "orch-hook-unverified-$unit" blocked \
        "steward: $name native inbox evidence is unverified. Rewritten or unreadable argv does not prove a missing hook; inspect its exact native session and owned watcher. No automatic restart or guard-enforcement claim." || true
      continue
    fi
    _steward_clear "$ws" "orch-hook-unverified-$unit" "$name inbox evidence is observable again"
    if [ "$state" = ok ]; then
      _steward_clear "$ws" "$fp" "$name inbox evidence is present; guard enforcement is not inferred"
      _steward_clear "$ws" "$stuck" "$name inbox evidence is present; guard enforcement is not inferred"
      continue
    fi
    case "$state" in
      stripped)
        gone="came back without its inbox hook"; hint=" (probably a herdr restart)"
        still="still without its inbox hook"; has_no="has no inbox hook"
        fixed="restarted it with the full launch line"; cleared="was restarted with its inbox hook"
        lost="its process came back without the inbox hook (probably a herdr restart)" ;;
      deaf)
        # Deaf must outlast the hook's own restart backoff (60s): a watcher
        # caught between two of the hook's restarts is not deafness.
        # Record a new sighting before sampling decision time: otherwise a
        # second rollover makes its age negative even with no confirm delay.
        seen_at="$(_steward_first_seen "$seen")"
        now="$(date +%s)"
        [ $((now - seen_at)) -ge "${CEL_STEWARD_DEAF_CONFIRM:-120}" ] || continue
        gone="has its inbox hook but no live inbox watcher"; hint=" (its cel inbox watch --parent child is gone)"
        still="still without a live inbox watcher"; has_no="has no live inbox watcher"
        fixed="restarted it so its inbox hook starts a new watcher"; cleared="was restarted so its hook starts a new watcher"
        lost="its inbox hook is loaded but its inbox watcher is gone" ;;
      *) continue ;;
    esac
    # Once escalated, a human owns it: never loop restarts behind their back.
    # A mailbox that does not parse cannot prove it was not: no restart.
    esc="$(_inbox_open_fp "$ws" "$stuck" steward root)" || continue
    [ -z "$esc" ] || continue
    now="$(date +%s)"
    last="$(awk -v k="$key" '$1==k{t=$2} END{print t+0}' "$_STEWARD_STATE" 2>/dev/null || printf 0)"
    if [ "${last:-0}" -gt 0 ] && [ $((now - last)) -lt 1800 ]; then
      c_err "$name was restarted and is $still - not restarting again: $cmd"
      _steward_raise "$ws" "$stuck" blocked \
        "steward: $name was restarted $(( (now - last) / 60 ))m ago and came back $still, so it cannot receive mail. Not restarting it again - look at its pane and run: $cmd"
      continue
    fi
    why=""
    if [ "$status" != idle ]; then why="it is $status"
    elif ! _steward_orch_composer_empty "$pane"; then why="its composer may hold a draft"
    fi
    if [ -z "$why" ]; then
      _steward_claim_restart "$key" || continue
      if _steward_restart_orch "$p" "$ws" ${lane:+"$lane"}; then
        c_ok "$name $gone - restarted it ($cmd)"
        cmd_inbox send root "$name $gone$hint; $fixed" \
          --from steward --workspace "$ws" --kind status >/dev/null 2>&1 || true
        _steward_clear "$ws" "$fp" "$name $cleared"
        _steward_forget "$seen"
      else
        c_err "$name $has_no and the restart failed: $cmd"
        _steward_raise "$ws" "$stuck" blocked \
          "steward: $name $has_no and 'cel run --restart' failed, so it cannot receive mail. Run: $cmd"
      fi
      continue
    fi
    c_warn "$name $has_no and $why - not restarting it: $cmd"
    # Said once: a stripped or deaf agent stays so tick after tick.
    esc="$(_inbox_open_fp "$ws" "$fp" steward root)" || continue
    [ -z "$esc" ] || continue
    _steward_remind "$ws" root "$fp" blocked \
      "steward: $name cannot receive mail - $lost, and $why, so the steward will not restart it. When it is safe, run: $cmd" || true
  done < <(run_stripped_orchestrators)
  # Deafness is confirmed across consecutive sightings only: an agent whose
  # row vanished (gone, restarted, unreadable) and comes back deaf is new.
  _steward_forget_unseen orch-deaf-seen- "${deaf_seen[@]}"
  return 0
}

# WAITING ON THE OWNER IS NOT A WORKER FINDING: no worker can, say, pay an
# external review bot's bill. An open decision filed with
# `cel decide ask --pr <repo>#<n>` silences every nudge about exactly that PR
# until it is closed - the review sweep's and the solo changes-verdict one
# alike. Only the explicit link counts: free text naming "#7" is too loose to
# identify a PR. One `<repo>#<n>` per line.
_steward_owner_prs() { # <ws>
  # shellcheck source=lib/decide.sh
  . "${BASH_SOURCE[0]%/*}/decide.sh"
  decide_open_json "$1" 2>/dev/null | jq -r '.prs[]?.ref // empty' 2>/dev/null || true
}
# "LEAVE IT" IS SAYABLE. A `superseded` or `hold` label tells the steward to
# stop nudging about a PR (e.g. one whose code reached main through others).
# A jq definition over a PR's label NAMES, for every sweep that nudges.
_STEWARD_JQ_LEFT_ALONE='def left_alone: any(.[]?; strings | ascii_downcase | . == "superseded" or . == "hold");'

_steward_review_sweep() { # <agents-json>
  local agents_json="$1" ws wsdir repo slug orch prsj ref
  printf '%s' "$agents_json" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 || return 0
  # Owner cards (_steward_owner_prs) silence the red, changes-requested and
  # no-worker nudges for their PRs. Read once per workspace.
  local -A owner_prs
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    [ -f "$wsdir/workspace.yaml" ] || continue
    owner_prs=()
    while IFS= read -r ref; do
      [ -n "$ref" ] && owner_prs["$ref"]=1
    done < <(_steward_owner_prs "$ws")
    for repo in $(ws_repo_names "$wsdir"); do
      slug="$(ws_repo_get "$wsdir" "$repo" url \
              | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
      [ -n "$slug" ] || continue
      # Address the orchestrator by the alias cel run gave it; when that name
      # is not registered (started by hand), fall back to whichever agent
      # pane lives in the repo checkout.
      # THE PRODUCT'S orchestrator, not the repo's: a repo inside a declared
      # product has no pane of its own.
      local prod; prod="$(ws_product_of_repo "$wsdir" "$repo")"
      orch="$(_run_agent_name "$prod-orch")"
      local fallback
      fallback="$(printf '%s' "$agents_json" | jq -r --arg d "$(_steward_orch_dir "$wsdir" "$prod-orch")" \
        '[.result.agents[] | select(.cwd == $d)][0].pane_id // empty')"
      if ! printf '%s' "$agents_json" | jq -e --arg n "$orch" \
        'any(.result.agents[]?; .name == $n and .backend == "rex")' >/dev/null 2>&1; then
        herdr agent get "$orch" >/dev/null 2>&1 || { [ -n "$fallback" ] && orch="$fallback"; }
      fi
      # ONLY OUR OWN PRs. Every PR a solo agent opens is authored by the
      # token cel runs under, so `--author @me` is the ownership line; a
      # colleague's PR must never be nudged into "action it now".
      # Colleagues' PRs are theirs to land. This filter guards every check
      # below it, including reminders about our ticket naming convention.
      prsj="$(ws_gh "$wsdir" pr list --repo "$slug" --author @me \
              --json number,headRefName,headRefOid,reviewDecision,isDraft,statusCheckRollup,createdAt,labels,reviews 2>/dev/null)" || continue
      # A `superseded` or `hold` PR (_STEWARD_JQ_LEFT_ALONE) is dropped before
      # any check below sees it.
      prsj="$(printf '%s' "$prsj" | jq -c "$_STEWARD_JQ_LEFT_ALONE"'[.[] | select([.labels[]?.name] | left_alone | not)]' 2>/dev/null)" || continue

      # UNTICKETED PRs. Linear links a PR to its ticket purely from the branch
      # name, so a branch with no identifier can never be tracked: no status to
      # read, no attachment, nothing on the board. Branches opened without a
      # ticket still need surfacing, so the board and the repo cannot drift
      # apart silently. A day's grace, so work in flight is not nagged immediately.
      # A DRAFT IS THE AUTHOR'S PRIVATE WORK, left alone here as in the review
      # sweep below.
      # Any prefix the repo answers to, current or historical - a branch named
      # before a team re-key is still ticketed and must not be nagged.
      # `tprefix` is an ALTERNATION of every prefix the repo answers to, for
      # matching; `tcanon` is the single current one, for anything a human
      # reads. Kept apart because "ABCD|ABC" is a correct regex and a nonsense
      # instruction.
      local tprefix tcanon
      tprefix="$(ws_repo_prefixes "$wsdir" "$repo" | paste -sd'|' -)"
      tcanon="$(ws_repo_get "$wsdir" "$repo" prefix)"
      if [ "$(ws_ticket "$wsdir" system)" = "linear" ] && [ -n "$tprefix" ]; then
        local unum ubranch uage
        while IFS=$'\t' read -r unum ubranch uage; do
          [ -n "$unum" ] || continue
          # An `if`, not `grep ... && continue`: under set -e the && form
          # returns non-zero exactly when the branch has NO ticket, which is
          # the case this check exists for, and would abort the tick.
          # GROUPED: without the parentheses "ABCD|ABC-[0-9]+" means "ABCD" OR
          # "ABC-<digits>", so any branch merely containing the prefix would
          # count as ticketed.
          if printf '%s' "$ubranch" | grep -qiE "(${tprefix})-[0-9]+"; then continue; fi
          [ "$(( ( $(date +%s) - $(date -d "$uage" +%s 2>/dev/null || date +%s) ) / 86400 ))" -ge 1 ] || continue
          _steward_nudge "$prod-orch" "$(ws_name "$wsdir")" "$slug#$unum-noticket" \
            "steward: PR #$unum on $repo ($ubranch) has no $tcanon ticket in its branch name, so Linear cannot link it and it is invisible on the board. Find or create the ticket (cel-linear search / create), comment the PR link on it, and set its state. Name future branches ${tcanon}-<n>-<slug>."
        done < <(printf '%s' "$prsj" | jq -r '.[] | select(.isDraft | not) | [.number, .headRefName, .createdAt] | @tsv')
      fi

      # THE PRODUCT'S OWN AGENT opened the PR and fixes it on the branch:
      # the nudge goes to it, never to a worker it does not have.
      local num branch review failing
      while IFS=$'\t' read -r num branch review failing; do
        [ -n "$num" ] || continue
        failing="${failing:-0}"
        if [ "$review" != "APPROVED" ] && [ -n "${owner_prs["$repo#$num"]:-}" ]; then continue; fi
        if [ "$review" = "APPROVED" ]; then
          _steward_nudge "$prod-orch" "$(ws_name "$wsdir")" "$slug#$num-approved" \
            "steward: PR #$num on $repo is APPROVED - action it now (merge per policy, or surface for the human)."
          continue
        fi
        if [ "$review" = "CHANGES_REQUESTED" ]; then
          _steward_nudge "$prod-orch" "$(ws_name "$wsdir")" "$slug#$num-changes" \
            "steward: PR #$num on $repo has changes requested at its current head - address them on $branch, push, and ask its reviewer to re-review (cel run reviewer --repo $repo --pr $num if none is running)."
        elif [ "$failing" -gt 0 ]; then
          _steward_nudge "$prod-orch" "$(ws_name "$wsdir")" "$slug#$num-red" \
            "steward: PR #$num on $repo has FAILING checks on $branch - a red gate is a finding: fix it on the branch and push."
        fi
      done < <(printf '%s' "$prsj" | jq -r '.[] | select(.isDraft | not) |
        [.number, .headRefName,
         # HEAD-AWARE. reviewDecision is sticky across pushes: an approval of a
         # head that has since moved still reads APPROVED, and a change request
         # already answered by a push still reads CHANGES_REQUESTED. Only a
         # review of the CURRENT head counts, and a change request is over once
         # a later approval exists.
         (. as $pr | .headRefOid as $h | ([.reviews[]?] | sort_by(.submittedAt // "")) as $rs
          | ([$rs[] | select(.state == "CHANGES_REQUESTED")] | last) as $cr
          | if ($pr.reviewDecision // "") == "APPROVED" then
              (if [$rs[] | select(.state == "APPROVED" and (.commit.oid // "") == $h)] | length > 0
               then "APPROVED" else "NONE" end)
            elif ($pr.reviewDecision // "") == "CHANGES_REQUESTED" then
              (if $cr != null and ($cr.commit.oid // "") == $h
                  and ([$rs[] | select(.state == "APPROVED" and (.commit.oid // "") == $h
                    and (.submittedAt // "") > ($cr.submittedAt // ""))] | length == 0)
               then "CHANGES_REQUESTED" else "NONE" end)
            else "NONE" end),
         ([.statusCheckRollup[]? | select((.conclusion // .state) as $s | $s == "FAILURE" or $s == "ERROR")] | length)]
        | @tsv')
    done
  done
}

# A SOLO PRODUCT'S READY PRS. The review sweep above nudges about changes
# requested and red checks; what can still
# stall is the last step: a PR approved at its head with every check green,
# waiting on its own agent to land it. That agent is told once per head (the
# key carries it, so a new push is a new fact); the steward never lands it.
#
# AND ITS PRS SENT BACK. A solo PR's reviewer records its verdict with `cel
# solo review` in the workspace's .cel/solo-reviews.json, and that verdict
# never reaches the forge - so a `changes` verdict is invisible to the review
# sweep above, and an agent that missed the reviewer's mail leaves the PR
# sitting. The product's agent is told once per head when the verdict on
# record is `changes` at the PR's CURRENT head: a push since means the verdict
# no longer covers the head (nothing to say until the reviewer records the new
# one), and a `changes` verdict at the new head is a new key, a new nudge.
# It is silenced exactly as the review sweep is: an open owner card on the PR,
# or a `hold`/`superseded` label.
_steward_solo_sweep() {
  local ws wsdir product repo pr head by note owner
  # shellcheck source=lib/solo.sh
  . "${BASH_SOURCE[0]%/*}/solo.sh"
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    [ -f "$wsdir/workspace.yaml" ] || continue
    owner=""
    for product in $(ws_product_names "$wsdir"); do
      [ "$(ws_build_mode "$wsdir" "$product")" = solo ] || continue
      while IFS=$'\t' read -r repo pr head; do
        [ -n "$pr" ] || continue
        # ONCE PER HEAD, NOT ONCE PER WINDOW: the default dedup window is four
        # hours, which would re-mail the same fact all day while the PR sits.
        _STEWARD_WINDOW=999999999 _steward_nudge "$product-orch" "$ws" "solo-ready-$ws-$repo-$pr-${head:0:12}" \
          "steward: $repo#$pr is approved at its current head and every check is green - land it: cel solo land $repo#$pr"
      done < <(solo_ready_prs "$wsdir" "$product")
      # the owner cards are read once per workspace, and only when there is
      # a solo verdict file to weigh them against
      [ -s "$(_solo_reviews "$wsdir")" ] || continue
      [ -n "$owner" ] || owner="$(_steward_owner_prs "$ws")"$'\n'
      while IFS=$'\t' read -r repo pr head by note; do
        [ -n "$pr" ] || continue
        _STEWARD_WINDOW=999999999 _steward_nudge "$product-orch" "$ws" "$(_steward_solo_changes_key "$ws" "$repo" "$pr" "$head")" \
          "steward: $repo#$pr has a recorded \`changes\` verdict from $by at its current head ${head:0:12}${note:+ (\"$note\")} and nothing was pushed since - address it on the PR's branch, push, and ask $by to re-review the new head."
      done < <(_steward_solo_changes "$ws" "$wsdir" "$product" "$owner")
    done
  done
}

_steward_solo_changes_key() { printf 'solo-changes-%s-%s-%s-%s' "$1" "$2" "$3" "${4:0:12}"; } # <ws> <repo> <pr> <head>

# Read-only looks at the steward's state, for a check that must come BEFORE
# a forge call: is the key recorded at all / recorded inside <window> seconds?
_steward_state_has() { # <key>
  [ -f "$_STEWARD_STATE" ] && awk -v k="$1" '$1 == k { f = 1 } END { exit !f }' "$_STEWARD_STATE"
}
_steward_state_within() { # <key> <window>
  [ -f "$_STEWARD_STATE" ] && awk -v k="$1" -v now="$(date +%s)" -v w="$2" \
    '$1 == k { t = $2 } END { exit !(t != "" && now - t < w) }' "$_STEWARD_STATE"
}

# The open PRs of <product> whose recorded solo verdict is `changes` at their
# current head, one `<repo>\t<pr>\t<head>\t<by>\t<note>` line each.
#
# THE FORGE IS ASKED ONLY ABOUT WHAT COULD STILL BE NEWS. A nudge needs the
# PR's head to equal the verdict's, so the nudge key is known from the verdict
# file alone: a verdict already nudged at its head, under an open owner card,
# or set aside in the last day costs no forge call. Only for the rest is the
# repo's open-PR list read (forge_pr_list, either forge - heads never come
# from a branch), once per repo. A verdict whose PR is not open, is a draft,
# has moved on, carries a `hold`/`superseded` label, or already carries the
# same changes request on GitHub (the review sweep's to say) is set aside for
# a day (`solo-changes-idle-*`): long-merged PRs whose old verdicts linger in
# the file cost one list a day, not one a tick.
# A verdict file that does not parse is said, never read as "no verdicts".
_steward_solo_changes() { # <ws> <wsdir> <product> <owner-pr-refs, one per line>
  local ws="$1" wsdir="$2" product="$3" owner=$'\n'"$4" f verdicts repo prs num vhead pr by note idle
  local -a pending
  f="$(_solo_reviews "$wsdir")"
  [ -s "$f" ] || return 0
  verdicts="$(jq -ce 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null)" \
    || { c_warn "$f does not parse - no solo changes-verdict nudges for $ws this tick" >&2; return 0; }
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    pending=()
    while IFS=$'\t' read -r num vhead; do
      [ -n "$num" ] || continue
      case "$owner" in *$'\n'"$repo#$num"$'\n'*) continue ;; esac
      _steward_state_has "$(_steward_solo_changes_key "$ws" "$repo" "$num" "$vhead")" && continue
      _steward_state_within "solo-changes-idle-$ws-$repo-$num-${vhead:0:12}" 86400 && continue
      pending+=("$num $vhead")
    done < <(printf '%s' "$verdicts" | jq -r --arg p "$repo#" '
      to_entries[] | select((.key | startswith($p)) and (.key | ltrimstr($p) | test("^[0-9]+$"))
                            and .value.verdict? == "changes" and ((.value.head? // "") | test("^[0-9a-f]{40}$")))
      | [(.key | ltrimstr($p)), .value.head] | @tsv' 2>/dev/null || true)
    [ "${#pending[@]}" -gt 0 ] || continue
    prs="$(_solo_forge forge_pr_list "$wsdir" "$repo" open --author @me --limit 50 2>/dev/null)" || continue
    for pr in "${pending[@]}"; do
      num="${pr%% *}" vhead="${pr#* }"
      idle="solo-changes-idle-$ws-$repo-$num-${vhead:0:12}"
      if ! printf '%s' "$prs" | jq -e --argjson n "$num" --arg h "$vhead" "$_STEWARD_JQ_LEFT_ALONE"'
           any(.[]?; .number == $n and .draft == false and .head_sha == $h and ((.labels // []) | left_alone | not))' >/dev/null 2>&1 \
         || _steward_forge_changes_at "$wsdir" "$repo" "$num" "$vhead"; then
        _STEWARD_WINDOW=86400 _steward_due "$idle" || true
        continue
      fi
      IFS=$'\t' read -r by note < <(printf '%s' "$verdicts" | jq -r --arg k "$repo#$num" '.[$k] as $r
        | [(if ($r.by | type) == "string" and $r.by != "" then $r.by else "its reviewer" end),
           (($r.note // "") | tostring | gsub("[\t\n\r]+"; " ") | .[0:200])] | @tsv') || true
      printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$num" "$vhead" "$by" "$note"
    done
  done < <(ws_product_repos "$wsdir" "$product")
}

# True when <repo> is on GitHub and its PR's own reviews request changes at
# <head> - the condition the review sweep's `<slug>#<n>-changes` nudge mails
# about (the PR has passed the same owner-card and label checks there and
# here). The recorded verdict is then the same finding, said once.
_steward_forge_changes_at() { # <wsdir> <repo> <pr> <head>
  [ "$(forge_repo "$1" "$2" "$1/repos/$2" 2>/dev/null | jq -r '.provider // ""' 2>/dev/null)" = github ] || return 1
  _solo_forge forge_pr_reviews "$1" "$2" "$3" 2>/dev/null | jq -e --arg h "$4" \
    '.decision == "changes_requested" and any(.reviews[]?; .state == "changes_requested" and .head_sha == $h)' >/dev/null 2>&1
}

# FEATURE TEAMS (`cel team ...`, lib/team.sh). The steward reads each team's
# own files - <wsdir>/.cel/teams/<feature>/team.json, events.jsonl and
# verdicts.json - and nothing else: no ledger, no branch names. Two things
# stall a team that nobody inside it will notice, and its lead (team.json
# `lead`, else `<product>-orch`) is told about each once:
#   - a member still `reserved` ten minutes after its reservation (the latest
#     member.reserved event for it, else its row's `created`): `cel team add`
#     never confirmed the launch, so whether an agent runs is unknown. Keyed
#     on the reservation time, so a new reservation is a new fact.
#   - a specialist verdict for a head older than its repo's candidate (the
#     latest candidate.updated event): it no longer covers what would land.
#     Only each role/focus's latest verdict for the repo counts - one already
#     at the candidate leaves nothing stale. Keyed on the candidate head, so
#     the next candidate re-arms it.
# It retires, relaunches and closes nothing: the lead decides. A closed team
# is history and says nothing.
#
# A team.json or verdicts.json that does not parse, or lacks the fields the
# sweep reads, is not a team the steward can supervise - and silence would
# read as a healthy team - so root is told, once per change, and the item is
# taken down when the files read cleanly again, or when the team (its
# team.json, its directory, the whole teams folder) is gone: the steward's
# state remembers each team it raised (`team-bad/<ws>/<feature>`), so a
# removal is noticed even though nothing is left on disk to read.
_STEWARD_TEAM_RESERVED_SECS="${CEL_TEAM_RESERVED_SECS:-600}"
_steward_team_sweep() {
  local ws wsdir dir feature out lead age kind a b c now k
  local -A bad
  now="$(date +%s)"
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    bad=()
    for dir in "$wsdir/.cel/teams"/*/; do
      dir="${dir%/}"; feature="${dir##*/}"
      # a directory without a team.json is not a team (yet)
      [ -e "$dir/team.json" ] || continue
      out="$(_steward_team_read "$dir" "$feature" "$now")"
      if [ "${out%%$'\t'*}" = bad ]; then
        out="${out#bad$'\t'}"; bad["$feature"]=1
        c_err "team $ws/$feature: $out - not supervised this tick"
        _steward_raise_on_change "$ws" "team-bad-$feature" blocked \
          "steward: team $feature in $ws: $out ($dir) - the steward cannot supervise this team until it reads cleanly; nothing was retired or changed"
        _steward_state_edit "$_STEWARD_STATE" _steward_state_note "team-bad/$ws/$feature" "$now" || true
        continue
      fi
      if _steward_state_has "team-bad/$ws/$feature"; then
        _steward_clear "$ws" "team-bad-$feature" "team $feature in $ws reads cleanly again"
        _steward_forget "team-bad/$ws/$feature"
      fi
      lead=""
      # every field is non-empty ("-" for an unknown time): IFS tab is
      # whitespace to `read`, so an empty field would shift the next one
      while IFS=$'\t' read -r kind a b c; do
        case "$kind" in
          lead) lead="$a" ;;
          reserved)
            if [ "$b" != - ]; then age="for $(( (now - b) / 60 ))m"; else age="with no reservation time on record"; fi
            _STEWARD_WINDOW=999999999 _steward_nudge "$lead" "$ws" "team-reserved-$ws-$feature-$a-$b" \
              "steward: team $feature: member $a ($c) has been reserved $age - cel team add never confirmed its launch, so whether it is running is unknown. Look (cel team status $feature), then retire it (cel team retire $feature $a) or add it again; the steward retires nothing." ;;
          stale)
            _STEWARD_WINDOW=999999999 _steward_nudge "$lead" "$ws" "team-stale-$ws-$feature-${a// /_}-${b:0:12}" \
              "steward: team $feature: $a's candidate is now ${b:0:12}, but these verdicts are for older heads: $c - they do not cover what would land. Ask for fresh verdicts on ${b:0:12} (cel team status $feature); the steward retires nothing." ;;
        esac
      done <<< "$out"
    done
    # raised once, and no longer here to read: the item comes down
    while read -r k _; do
      feature="${k#"team-bad/$ws/"}"
      [ -z "${bad["$feature"]:-}" ] || continue
      _steward_clear "$ws" "team-bad-$feature" "team $feature in $ws is gone (no team.json any more)"
      _steward_forget "$k"
    done < <(awk -v p="team-bad/$ws/" 'index($1, p) == 1' "$_STEWARD_STATE" 2>/dev/null || true)
  done
}

# One team's files, read into what the sweep acts on: `bad\t<why>` alone, or
# `lead\t<alias>`, then `reserved\t<alias>\t<since-epoch|->\t<role>` per overdue
# reservation and `stale\t<repo>\t<candidate>\t<verdicts>` per repo.
# events.jsonl is append-only, so its last line can be one still being
# written: an unparseable line is passed over, never a reason to stop.
_steward_team_read() { # <dir> <feature> <now>
  local dir="$1" team events verdicts='[]'
  team="$(jq -c . "$dir/team.json" 2>/dev/null)" && [ -n "$team" ] \
    || { printf 'bad\tteam.json does not parse'; return 0; }
  if [ -s "$dir/verdicts.json" ]; then
    verdicts="$(jq -c 'if type == "array" then . elif type == "object" then [.[]] else error("no") end' "$dir/verdicts.json" 2>/dev/null)" \
      || { printf 'bad\tverdicts.json does not parse'; return 0; }
  fi
  events="$(jq -cR 'fromjson? | select(type == "object")' "$dir/events.jsonl" 2>/dev/null | jq -cs . 2>/dev/null)"
  [ -n "$events" ] || events='[]'
  printf '%s' "$team" | jq -r --arg feature "$2" --argjson now "$3" --argjson max "$_STEWARD_TEAM_RESERVED_SECS" \
    --argjson ev "$events" --argjson vs "$verdicts" '
    def ep: if type == "number" then . elif type == "string"
      then (sub("\\.[0-9]+"; "") | sub("[+]00:?00$"; "Z") | (try fromdateiso8601 catch null)) else null end;
    def bad($w): "bad\t" + $w;
    if type != "object" then bad("team.json is not an object")
    elif .feature != $feature then bad("team.json names feature \(.feature | tojson), not its directory")
    elif (.product | type) != "string" or .product == "" then bad("team.json has no product")
    elif (.members | type) != "array" then bad("team.json has no members list")
    elif any(.members[]; type != "object" or (.alias | type) != "string" or .alias == "" or (.state | type) != "string")
      then bad("a team.json member has no alias or state")
    elif any($vs[]; type != "object" or (.repo | type) != "string" or (.head | type) != "string")
      then bad("a verdicts.json entry has no repo or head")
    else
      "lead\t\(if (.lead | type) == "string" and .lead != "" then .lead else .product + "-orch" end)",
      (if (.state // "open") == "closed" then empty else
        (.members[] | select(.state == "reserved") | . as $m
          | ([$ev[] | select(.type == "member.reserved" and (.data.alias? // "") == $m.alias) | .ts] | last) as $rts
          | (($rts | ep) // ($m.created | ep)) as $since
          | select($since == null or ($now - $since) >= $max)
          | "reserved\t\($m.alias)\t\(if $since == null then "-" else ($since | floor) end)\t\($m.role // "?")"),
        ((reduce ($ev[] | select(.type == "candidate.updated" and (.data.repo? | type) == "string"
                                  and (.data.head? | type) == "string")) as $e
            ({}; .[$e.data.repo] = $e.data.head)) as $cand
          | [$vs[] | select($cand[.repo] != null)]
          | group_by([.repo, (.role // ""), (.focus // "")]) | map(sort_by(.at | ep // 0) | last)
          | map(select(.head != $cand[.repo])) | group_by(.repo)[]
          | "stale\t\(.[0].repo)\t\($cand[.[0].repo])\t"
            + (map("\(.role // "?")\(if (.focus | type) == "string" and .focus != "" then "/" + .focus else "" end) \(.verdict // "?") at \(.head[0:12])") | join(", ")))
      end)
    end' 2>/dev/null || printf 'bad\tteam.json could not be read'
}

# TICKETS THAT ARE READY TO BUILD. Moving a ticket into the trigger state
# (workspace.yaml `tickets.trigger_state`, default "Ready") is how a human
# starts work from the board. The steward notices, and tells root through the
# INBOX rather than typing into its pane. Rate-limited per ticket, and only
# when no branch already carries the ticket id - a started ticket is not a
# request to start it again.
# Resolve ticket ownership independently of liveness: an absent orchestrator
# still owns its tickets, and its covering owner card must hold their nudges.
# Unknown or ambiguous prefix ownership stays actionable through root.
_steward_ready_ticket_product() { # <wsdir> <ticket-id> -> unique product or empty
  local wsdir="$1" id="$2" repo pfx prods
  pfx="${id%-*}"
  [ -n "$pfx" ] && [ "$pfx" != "$id" ] || return 0
  prods=""
  for repo in $(ws_repo_names "$wsdir"); do
    if ws_repo_prefixes "$wsdir" "$repo" | grep -qix -- "$pfx"; then
      prods="$prods$(ws_product_of_repo "$wsdir" "$repo")"$'\n'
    fi
  done
  prods="$(printf '%s' "$prods" | sed '/^$/d' | sort -u)"
  case "$prods" in ""|*$'\n'*) return 0 ;; esac
  printf '%s' "$prods"
}

_steward_ready_ticket_dest() { # <resolved-product> <agents-json>
  local product="$1" agents_json="$2" live
  [ -n "$product" ] || { printf root; return 0; }
  live="$(printf '%s' "$agents_json" | jq -r --arg n "$(_run_agent_name "$product-orch")" \
    '[.result.agents[]? | select(.name == $n)] | length' 2>/dev/null || printf 0)"
  [ "${live:-0}" = "0" ] && { printf root; return 0; }
  printf '%s-orch' "$product"
}

_steward_ready_tickets() { # [agents-json]
  local agents_json="${1:-}"
  local ws wsdir trigger teams key ids id title repo found product owner card dest
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    [ "$(ws_ticket "$wsdir" system)" = "linear" ] || continue
    (
    trigger="$(_yqr -r '.tickets.trigger_state // "Ready"' "$wsdir/workspace.yaml" 2>/dev/null)"
    # Each workspace starts from the caller's environment, never the previous
    # workspace's overrides. Scope the full credential-dependent sweep so
    # env.local cannot change subsequent workspaces or the parent shell.
    eval "$(ws_env_exports "$wsdir" 2>/dev/null)" >/dev/null 2>&1 || true
    [ -n "${LINEAR_API_KEY:-}" ] || exit 0
    teams="$(_yqr -r '[.repos[].linear_team // empty] | unique | .[]' "$wsdir/workspace.yaml" 2>/dev/null)"
    [ -n "$teams" ] || exit 0
    local -A owner_cards=()
    for key in $teams; do
      # curl reads sensitive headers from stdin, not the process argument list.
      ids="$(printf 'Authorization: %s\n' "$LINEAR_API_KEY" |
        curl -sf -m 15 -X POST https://api.linear.app/graphql \
        -H @- -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg k "$key" --arg st "$trigger" '{query: "query($k: String!, $st: String!) { issues(filter: {team: {key: {eq: $k}}, state: {name: {eq: $st}}}, first: 100) { nodes { identifier title assignee { isMe } state { name type } labels { nodes { name } } } } }", variables: {k: $k, st: $st}}')" \
        2>/dev/null | jq -r '
        # ONLY OPEN WORK FOR THE FLEET: skip tickets assigned to colleagues,
        # completed or canceled, or deliberately blocked. Unassigned stays in:
        # the board trigger is how the owner hands the fleet new work, usually
        # before anyone owns it. The page is 100 because these filters run
        # after the limit.
        .data.issues.nodes[]?
        | select(.assignee == null or .assignee.isMe == true)
        | select(((.state.type // "") | IN("completed", "canceled")) | not)
        | select(((.state.name // "") | ascii_downcase | test("blocked")) | not)
        | select([.labels.nodes[]?.name | ascii_downcase] | any(. == "blocked") | not)
        | "\(.identifier)\t\(.title)"')" || continue
      [ -n "$ids" ] || continue
      while IFS=$'\t' read -r id title; do
        [ -n "$id" ] || continue
        # already being worked? any branch or worktree naming the ticket
        # The id must END at a separator. A bare `^ABC-1` prefix also matches
        # abc-18-*, so once ticket 18 had a worktree, ticket 1 would look like
        # it was already being worked and be skipped in silence - forever, with
        # no output saying why. Exactly the failure mode this whole sweep
        # exists to prevent, so the boundary is spelled out.
        found=0
        for repo in $(ws_repo_names "$wsdir"); do
          # The ticket NUMBER is stable across a team re-key, the prefix is
          # not. Build every prefix form of this id (ABCD-3 and ABC-3) so a
          # branch cut before the rename still counts as "someone is on it" -
          # otherwise every in-flight ticket looks unstarted and gets handed to
          # root again, and root delegates a second worker onto live work.
          local alt; alt="$(ws_repo_prefixes "$wsdir" "$repo" \
            | sed "s|\$|-${id##*-}|" | paste -sd'|' -)"
          [ -n "$alt" ] || alt="$id"
          [ -d "$HOME/.herdr/worktrees/$repo" ] && \
            ls "$HOME/.herdr/worktrees/$repo" 2>/dev/null | grep -qiE "^(${alt})([-_.]|$)" && found=1
          git -C "$wsdir/repos/$repo" ls-remote --heads origin 2>/dev/null \
            | grep -qiE "refs/heads/(.*/)?(${alt})([-_./]|$)" && found=1
          [ "$found" = 1 ] && break
        done
        [ "$found" = 1 ] && continue
        product="$(_steward_ready_ticket_product "$wsdir" "$id")"
        if [ -n "$product" ]; then
          # Match the owner before a missing agent falls back to root. Cache
          # once per product for this workspace sweep, never across ticks.
          if [ -z "${owner_cards[$product]+present}" ]; then
            owner="$(_run_agent_name "$product-orch")"
            owner_cards["$product"]="$(_steward_owner_card "$ws" "$owner" "$product")"
          fi
          card="${owner_cards[$product]}"
          if [ -n "$card" ]; then
            # A card opened after an earlier nudge must re-arm that ticket
            # when it closes, not wait out the old four-hour report stamp.
            _steward_forget "ready-$id"
            continue
          fi
        fi
        _steward_due "ready-$id" || continue
        # NEVER offer to move it back. The trigger state is the HUMAN'S signal
        # that they want this built; an agent reversing it erases the request
        # with nobody informed. If it genuinely cannot be started, say so ON the
        # ticket and leave the state for the human to change.
        dest="$(_steward_ready_ticket_dest "$product" "$agents_json")"
        cmd_inbox send "$dest" \
          "steward: $id is in '$trigger' with no branch anywhere - $title. The owner moved it there to say BUILD THIS: plan it and delegate to the owning repo orchestrator. DO NOT change its state out of '$trigger' yourself - if it cannot be started, comment on the ticket saying exactly what is missing and leave the state alone for the owner to decide." \
          --from steward --workspace "$ws" --kind status >/dev/null 2>&1 \
          && c_ok "ready ticket $id handed to $dest's inbox"
      done <<< "$ids"
    done
    ) || true
  done
}

# PROVIDER CREDIT, checked every tick and named when it is gone.
# Delegation vetoes an exhausted provider; this sweep makes the balance
# visible before someone attempts another delegation.
# Keys come from each workspace's env, so a provider is checked once per
# workspace that can reach it; the balance is cached, so this is cheap.
# Does any profile in the workspace route to this provider? worker_profiles
# and the review profile are the routes; role_profiles only name them.
_steward_provider_used() { # <wsdir> <provider> -> 0 yes, 1 no
  command -v profile_provider >/dev/null 2>&1 || . "$CEL_ROOT/lib/profiles.sh"
  local m j; j="$(_ws_effective_json "$1" 2>/dev/null)" || return 1
  for m in $(jq -r '[(.worker_profiles // {} | .[]? | .model // empty), (.review.model // empty)] | .[]' "$j" 2>/dev/null); do
    [ "$(profile_provider "$m" 2>/dev/null)" = "$2" ] && return 0
  done
  return 1
}

_steward_quota() {
  # shellcheck source=lib/quota.sh
  . "$CEL_ROOT/lib/quota.sh"
  local ws wsdir p r floor seen=""
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    for p in $(_yqr -r '.providers | to_entries[] | select(.value.balance != null) | .key' "$CEL_MANIFEST" 2>/dev/null); do
      r="$(quota_remaining "$p" "$wsdir" 2>/dev/null || printf unknown)"
      [ "$r" = unknown ] && continue
      # A dry account nobody routes to vetoes nothing: having its key in the
      # environment is not a route. The blocker is about routes, so it needs a
      # route to exist.
      if ! _steward_provider_used "$wsdir" "$p"; then
        _steward_clear "$ws" "quota-dry-$p" "$p is dry but no profile in $ws routes to it - nothing is vetoed"
        continue
      fi
      # two workspaces on the same key are one account: say it once per tick
      local fp; fp="$(_quota_key "$p" "$wsdir" | sha256sum | cut -c1-12)"
      case " $seen " in *" $p.$fp "*) continue;; esac
      seen="$seen $p.$fp"
      floor="$(provider_balance "$p" floor)"
      if quota_vetoed "$p" "$r"; then
        c_err "$ws: $p has $(printf '%.2f' "$r") $(provider_balance "$p" unit) left (floor $floor) - workers routed there are VETOED until it is topped up: $(provider_get "$p" console)"
        _steward_due "quota-dry-$ws-$p" && _steward_raise "$ws" "quota-dry-$p" blocked \
          "steward: $p credit is $(printf '%.2f' "$r") (floor $floor). Profiles routed there are vetoed; delegations on them will refuse. Top up or repoint the profile." || true
      else
        # Back above the floor: the blocker the steward raised is no longer
        # true, so the steward takes it down rather than leaving a human to
        # work out whether an old item still applies.
        _steward_clear "$ws" "quota-dry-$p" "$p credit is $(printf '%.2f' "$r") (floor $floor) - back above the floor, routes to it are live again"
        if awk -v r="$r" -v f="$floor" 'BEGIN { exit !(r+0 < 3*f+0) }'; then
          c_warn "$ws: $p is down to $(printf '%.2f' "$r") $(provider_balance "$p" unit) (floor $floor) - running low"
        fi
      fi
    done
  done
}

# THE SUBSCRIPTIONS, once per account per tick.
#
# The two windows the fleet actually runs on are invisible until they stop it:
# a Claude or Codex five-hour window at 100% refuses every worker on that
# account and says nothing anywhere an operator looks. So a window over the
# warning threshold is a rolled-up `status` and a spent one is a `blocked`,
# both keyed per account so a condition that persists lands as an update on
# the item that is already open rather than as a fresh one every tick.
#
# A SUBSCRIPTION IS THE BOX'S, NOT A WORKSPACE'S. There is one Claude account
# behind every workspace on this machine, so the item goes to the first
# registered workspace's root mailbox - saying it once per box, not once per
# workspace.
_steward_subscriptions() {
  # shellcheck source=lib/quota.sh
  . "$CEL_ROOT/lib/quota.sh"
  local ws; ws="$(registry_names | head -n1)"
  [ -n "$ws" ] || return 0
  local warn="${CEL_SUB_WARN_PCT:-80}"
  local p a t doc worst wname resets state
  while IFS=$'\t' read -r p a t; do
    [ -n "$p" ] || continue
    doc="$(subscription_usage "$p" "$t" "$a" 2>/dev/null || true)"
    [ -n "$doc" ] || continue
    # ONE LINE PER ACCOUNT, so the tightest window speaks for it: two lines
    # about one account is the same fact twice, and the operator acts on the
    # shorter reset either way.
    IFS=$'\t' read -r worst wname resets state <<< "$(printf '%s' "$doc" | jq -r '
      ((.windows // []) | sort_by(-(.used_pct // 0)) | first) as $w
      | [(($w.used_pct // -1)), ($w.name // ""), ($w.resets_at // ""), (.extra.state // "")]
      | @tsv' 2>/dev/null || true)"
    case "$worst" in ''|-1) continue ;; esac

    local pct; pct="$(printf '%.0f' "$worst" 2>/dev/null || printf 0)"
    if [ "$pct" -ge 100 ]; then
      c_err "$p $a: $wname window is spent (100%) - workers on that account are VETOED until it resets at $(sub_reset_human "$resets")"
      _steward_due "sub-$p-$a" && _steward_raise "$ws" "sub-$p-$a" blocked \
        "steward: the $p subscription $a has spent its $wname window (100%). Delegations routed there will refuse until it resets at $(sub_reset_human "$resets")." || true
    elif [ "$pct" -ge "$warn" ]; then
      c_warn "$p $a: $wname window at $pct% (resets $(sub_reset_human "$resets"))"
      _steward_due "sub-$p-$a" && _steward_raise "$ws" "sub-$p-$a" status \
        "steward: the $p subscription $a is at $pct% of its $wname window, resetting at $(sub_reset_human "$resets"). Work routed there will start refusing at 100%." || true
    else
      # Back under the threshold: the steward takes its own item down rather
      # than leaving someone to work out whether a day-old warning still holds.
      _steward_clear "$ws" "sub-$p-$a" "$p $a is back to $pct% of its $wname window - routes to it are clear"
    fi
  done < <(_subscription_accounts)
}

# THE ORCHESTRATORS' OWN POOL. Root and the orchestrators run
# `omp --model anthropic/...` on omp's OWN Anthropic credentials, not the
# gateway, so the per-account sweep above - which reads whichever copy answers
# best - can call an account healthy while omp's copy of it is dead. So the
# pool is judged as a pool: ONE item to root when every live credential is at
# or above the threshold on its unscoped 5h or 7d window, resolved when that
# stops being true. Read from `omp usage --json` - no model call.
#
# A DISABLED CREDENTIAL IS ITS OWN ITEM, SAID ONCE PER CHANGE. It comes back
# only when the owner runs `omp login anthropic` at a terminal; nothing a tick
# does changes it. `orch-pool-login` is raised when the set of disabled
# credentials changes and taken down when it is empty.
_steward_orch_pool() {
  # shellcheck source=lib/quota.sh
  command -v _sub_omp_usage >/dev/null 2>&1 || . "$CEL_ROOT/lib/quota.sh"
  local ws; ws="$(registry_names | head -n1)"
  [ -n "$ws" ] || return 0
  local raw; raw="$(_sub_omp_usage)"
  [ -n "$raw" ] || return 0
  local warn="${CEL_ORCH_POOL_WARN_PCT:-85}" verdict hot dead
  verdict="$(printf '%s' "$raw" | jq -c --argjson warn "$warn" '
    def anth: ((.provider // "") | ascii_downcase) as $p | $p == "anthropic" or $p == "claude";
    [(.reports // [])[]? | select(anth)
     | {who: (.metadata.email // .metadata.accountId // "?"),
        pct: ([(.limits // [])[]? | select(type == "object")
               | select((.scope.tier // null) == null and (.scope.modelId // null) == null)
               | select((.window.id // .scope.windowId // "") as $w | $w == "5h" or $w == "7d")
               | (.amount.usedFraction // 0) * 100] | max // 0)}] as $live
    | ([(.disabledCredentials // [])[]? | select(anth) | (.email // .accountId // "?")] | unique) as $dead
    | ($live | length > 0 and all(.pct >= $warn)) as $hot
    | {hot: (if $hot then "every live credential is at or above \($warn)% of its 5h or 7d window ("
                + ($live | map("\(.who) \(.pct | floor)%") | join(", ")) + ")" else "" end),
       dead: ($dead | join(", "))}' 2>/dev/null || true)"
  # An unreadable answer is NO EVIDENCE, not headroom: clearing on it would
  # take down a true warning the first time omp changed its document shape.
  [ -n "$verdict" ] || return 0
  hot="$(printf '%s' "$verdict" | jq -r '.hot')"
  dead="$(printf '%s' "$verdict" | jq -r '.dead')"
  if [ -n "$hot" ]; then
    c_warn "orchestrator pool: $hot"
    _steward_due "orch-pool" && _steward_raise "$ws" orch-pool blocked \
      "steward: the orchestrators' Claude pool (omp's anthropic credentials) is nearly out - $hot. When it is spent, orchestrator turns wait for the reset." || true
  else
    _steward_clear "$ws" orch-pool "the orchestrators' Claude pool has headroom again"
  fi
  if [ -n "$dead" ]; then
    c_warn "orchestrator pool: disabled in omp: $dead - re-login with: omp login anthropic"
    _steward_raise_on_change "$ws" orch-pool-login blocked \
      "steward: omp has disabled the orchestrators' anthropic credential(s) $dead - orchestrators run without them until the owner signs back in at a terminal: omp login anthropic" || true
  else
    _steward_clear "$ws" orch-pool-login "omp's anthropic credentials are all signed in again"
  fi
}

# ON PACE FOR THE CAP. The per-account sweep above speaks at 80% of a
# window; by then a weekly window can already be a day from empty, and the
# question the owner asks is earlier - "at this week's pace, does anything run
# out before it resets?". So ONE item to root, keyed `usage-pace`, naming every
# account that will (quota_at_risk: projected >= 100% before the reset, or a
# window at 95%), updated in place while it stays true and resolved when the
# pace no longer gets there. Read from the cached list - the steward never
# asks a provider for this.
_steward_usage_pace() {
  # shellcheck source=lib/quota.sh
  command -v quota_at_risk >/dev/null 2>&1 || . "$CEL_ROOT/lib/quota.sh"
  local ws; ws="$(registry_names | head -n1)"
  [ -n "$ws" ] || return 0
  local subs; subs="$(subscription_list --cached 2>/dev/null || true)"
  # no cached reading is no evidence: leave whatever is open alone
  [ -n "$subs" ] && [ "$subs" != "[]" ] || return 0
  local risk; risk="$(printf '%s' "$subs" | quota_at_risk | jq -r '
    map("\(.who) (\(.provider) \(.window)\(if .scope then " " + .scope else "" end): \(.used_pct)% now, ~\(.projected_pct)% at reset\(if .resets then " " + .resets else "" end))")
    | join("; ")' 2>/dev/null || true)"
  if [ -n "$risk" ]; then
    c_warn "usage on pace for a cap: $risk"
    _steward_due "usage-pace" && _steward_raise "$ws" usage-pace status \
      "steward: on this week's pace an account hits its cap before it resets - $risk. Move work off it or expect refusals." || true
  else
    _steward_clear "$ws" usage-pace "no account is on pace to hit its cap before it resets"
  fi
}

# THE QUEUE IS VISIBLE OR IT IS A HANG. The suite takes a box-wide lock
# (tests/run.sh), so a worker whose gate is queued behind another suite looks,
# from outside, exactly like a worker that died - and killing the holder would
# lose both runs. So the steward watches the lock itself: held far longer than
# any suite takes, and root is told who has it and for how long. It NEVER
# kills it.
_STEWARD_SUITE_HOLD_WARN_SECS="${CEL_SUITE_HOLD_WARN_SECS:-1800}"

_steward_suite_lock_path() {
  if [ -n "${CEL_SUITE_LOCK:-}" ]; then printf '%s' "$CEL_SUITE_LOCK"; return 0; fi
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
    printf '%s/cel-suite.lock' "$XDG_RUNTIME_DIR"; return 0
  fi
  printf '%s/cel-suite-%s.lock' "${TMPDIR:-/tmp}" "${UID:-0}"
}

_steward_suite_lock() {
  local path ws
  path="$(_steward_suite_lock_path)"
  [ "$path" = none ] && return 0
  have flock || return 0

  # Free, or gone entirely: whatever was said about it is no longer true. The
  # file surviving an unheld lock is normal - it is the descriptor that holds
  # it, not the file - so its existence proves nothing on its own.
  local raised="$_STEWARD_STATE.suite-lock"
  if [ ! -f "$path" ] || flock -n "$path" -c true >/dev/null 2>&1; then
    [ -f "$raised" ] || return 0
    # One line per workspace that was told: the clear says it, never a second
    # `cleared:` beside it.
    for ws in $(registry_names); do
      _steward_clear "$ws" suite-lock "the suite lock is free again - gates are no longer queued"
    done
    rm -f "$raised"
    return 0
  fi

  # The holder wrote its pid into the first line after acquiring, and that
  # write is also when the hold started - so the file's own mtime is the
  # clock, with no second file to keep in step with it.
  local held pid mtime age
  held="$(sed -n 1p "$path" 2>/dev/null || true)"
  pid="${held%% *}"
  case "$pid" in ''|*[!0-9]*) pid="?" ;; esac
  mtime="$(stat -c %Y "$path" 2>/dev/null || printf 0)"
  [ "${mtime:-0}" -gt 0 ] || return 0
  age=$(( $(date +%s) - mtime ))
  [ "$age" -ge "$_STEWARD_SUITE_HOLD_WARN_SECS" ] || return 0

  # Which tree it is running in, if the kernel will say. Unknown is not a
  # reason to stay quiet: the pid and the duration are already actionable.
  local wt="unknown"
  [ "$pid" = "?" ] || wt="$(readlink "/proc/$pid/cwd" 2>/dev/null || printf unknown)"
  local msg
  msg="steward: suite lock held $(( age / 60 ))m by pid $pid (worktree $wt) - every other gate on this box is queued behind it. Nothing has been killed; check whether that run is still making progress."
  c_warn "$msg"
  # Once per window, not once per tick: the steward says a thing once, and a
  # suite that is going to take an hour will still be there in five minutes.
  _steward_due suite-lock || return 0
  : > "$raised"
  for ws in $(registry_names); do _steward_raise "$ws" suite-lock status "$msg"; done
}

# AFK IS A MODE WITH AN HOUR ON IT, and the steward is the thing still running
# when that hour passes. A `--until` in the past means the factory has ALREADY
# stopped acting on its own - nothing here is an emergency - but an AFK left on
# reads to every surface like authorisation that is still live, and the person
# who could turn it off is the one who is not looking. So it is raised, once per
# condition through the fingerprint rather than once per tick.
_steward_afk_sweep() {
  # shellcheck source=lib/afk.sh
  . "${BASH_SOURCE[0]%/*}/afk.sh"
  local s msg ws
  # ...and taken down when it stops being true.
  if ! afk_expired; then
    for ws in $(registry_names); do _steward_clear "$ws" afk-expired "AFK is no longer expired-and-on"; done
    return 0
  fi
  s="$(afk_state_json)"
  msg="steward: AFK expired at $(printf '%s' "$s" | jq -r '(.until // .until_text)') and is still on. Nothing autonomous is happening any more - an expired AFK reads as off - but the switch is still up: cel afk off (cel afk log for what was done while it was on)."
  c_warn "$msg"
  for ws in $(registry_names); do _steward_raise "$ws" afk-expired status "$msg"; done
}

_steward_servers() {
  # ONE dashboard for the box, ensured once - never one per
  # workspace; the old per-workspace ports are its redirects, not servers.
  # SUBSHELL, not a bare call. cmd_dash reports missing prerequisites with
    # die(), and die() is `exit 1` - which `||` cannot catch, because an exit
    # is not a non-zero return. A single missing tool (node absent from PATH
    # under systemd) would otherwise end the whole tick here, silently
    # skipping everything after it: ready tickets, the share sweep, the
    # update check.
  ( cmd_dash --ensure ) >/dev/null 2>&1 \
    || c_err "dash (port $(dash_port)) is down and would not start - cel dash --ensure"
  # Expired public shares are swept, not merely refused: a token dir left on
  # disk is a document sitting in an internet-reachable root.
  local pubroot; pubroot="$(_pages_public_root)"
  if [ -d "$pubroot" ]; then
    local d m exp n=0
    for d in "$pubroot"/*/; do
      d="${d%/}"; m="$d/.share.json"
      [ -f "$m" ] || continue
      exp="$(jq -r '.expires // empty' "$m" 2>/dev/null)"
      [ -n "$exp" ] || continue
      if [ "$(date -u -d "$exp" +%s 2>/dev/null || printf 9999999999)" -lt "$(date -u +%s)" ]; then
        rm -rf "$d" && n=$((n+1))
      fi
    done
    [ "$n" -gt 0 ] && c_ok "swept $n expired public share(s)"
  fi

  # The pages servers are box services with no owning pane, so warning about
  # them was useless - the steward brings them back instead.
  cmd_pages --ensure >/dev/null 2>&1 || c_err "pages server is down and would not start - cel pages --ensure"
  cmd_pages --public --ensure >/dev/null 2>&1 || c_err "public pages server is down and would not start - cel pages --public --ensure"
}

# ORPHANED TEST SERVERS HAVE NO OWNER TO NOTICE THEM. A server booted by a
# repo's suite inside a gate run that was killed mid-flight outlives it,
# parented to init - and may hold an inherited ledger lock that blocks every
# delegation command on that workspace. A server in a worktree is not a pane,
# not an agent and not a box service, so only this sweep names it. Age comes
# from the listing rather than being read again here so the sweep can be
# tested without a real server.
_steward_server_procs() { # "<pid> <age-seconds> <port> <cwd>" per pages/dash server
  local pid cmd cwd age port
  for pid in $(pgrep -u "$(id -u)" -f 'tools/(pages|dash)/server\.mjs' 2>/dev/null || true); do
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
    case "$cmd" in *tools/pages/server.mjs*|*tools/dash/server.mjs*) ;; *) continue;; esac
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" || continue
    age="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')" || continue
    [ -n "$cwd" ] && [[ "$age" =~ ^[0-9]+$ ]] || continue
    port="$(printf '%s' "$cmd" | grep -oE '(--port|PORT=)[ =]?[0-9]+' | grep -oE '[0-9]+$' | head -n1 || true)"
    printf '%s %s %s %s\n' "$pid" "$age" "${port:-?}" "$cwd"
  done
}

_steward_orphan_servers() { # <agents-json>
  local agents="$1" root pid age port cwd live
  printf '%s' "$agents" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 || return 0
  root="${CEL_WORKTREE_ROOT:-$HOME/.herdr/worktrees}"
  while read -r pid age port cwd; do
    [ -n "${pid:-}" ] || continue
    # Only worktrees. The servers under CEL_ROOT are this box's own services,
    # kept alive on purpose by _steward_servers, and are never touched here.
    case "$cwd" in "$root"/*) ;; *) continue;; esac
    # A worktree with a live agent still owns its servers, whatever their age:
    # a worker running its own suite is the normal case, not an orphan.
    live="$(printf '%s' "$agents" | jq -r --arg d "$cwd" \
      '[.result.agents[]? | select((.cwd // "") == $d or (($d + "/") | startswith((.cwd // "\u0000") + "/")))] | length' 2>/dev/null || printf 0)"
    [ "${live:-0}" -eq 0 ] || continue
    if [ "$age" -ge 3600 ]; then
      if kill -TERM "$pid" 2>/dev/null; then
        c_warn "reaped orphaned test server pid $pid (port $port, $((age / 60))m old) in $cwd - its worktree has no agent"
      else
        c_warn "orphaned test server pid $pid (port $port) in $cwd would not die - kill it by hand"
      fi
    else
      c_warn "orphaned test server pid $pid (port $port, $((age / 60))m old) in $cwd - its worktree has no agent"
    fi
  done < <(_steward_server_procs)
}

# MEMORY: THE STEWARD SAYS SOMETHING BEFORE THE BOX DOES.
#
# A runaway test server or a forgotten session is otherwise invisible until the
# kernel picks something to kill, and what it picks is never what anyone would
# have chosen. Two warnings, and NO KILLING: the steward reports, the
# orchestrator decides. A sweep that reaped a worker mid-gate would destroy the
# work it was measuring, and the one number it has is an attribution by cwd,
# not proof of who is at fault.

# Every tree the steward knows about, largest first, as `name<TAB>mb`. One
# /proc walk for the whole sweep, as in lib/fleet.sh: the snapshot is what
# keeps this cheap enough to run every five minutes.
_steward_mem_trees() { # -> name<TAB>mb, biggest first
  _steward_mem_trees_raw | sort -t"$(printf '\t')" -k2,2nr
}

_steward_mem_trees_raw() {
  local ws wsdir p d mb
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    [ -f "$wsdir/workspace.yaml" ] || continue
    for p in $(ws_product_names "$wsdir" 2>/dev/null); do
      d="$(_steward_orch_dir "$wsdir" "$p-orch")"
      [ -n "$d" ] && [ -d "$d" ] || continue
      mb="$(mem_tree_rss_mb "$d")"
      [ "${mb:-0}" -gt 0 ] && printf '%s-orch\t%s\n' "$p" "$mb"
    done
  done
  # ORPHANS ARE A TREE TOO, even though no pane owns them: the line exists to
  # answer "what is holding the memory", and orphaned processes can be the
  # true answer.
  local on omb
  read -r on omb <<<"$(orphans_list 2>/dev/null | orphans_totals)"
  [ "${on:-0}" -gt 0 ] && [ "${omb:-0}" -gt 0 ] && printf 'orphans\t%s\n' "$omb"
  printf ''
}

# THE WARNING LINE. Below it the orchestrators - the ones who can
# stop what they started - hear about it once per condition, rolled up
# (one fp per workspace, re-sent at most once per _steward_due window), naming
# the biggest consumers grouped by worktree. Admission (lib/boxguard.sh)
# refuses new launches lower down; this is the earlier word.
_steward_mem_pressure_warn() { # <avail-mb>
  # ONCE PER CONDITION: the orchestrators hear it on entering
  # pressure and not again until the box has recovered and fallen back in.
  local flag="${_STEWARD_STATE%/*}/mem-pressure.on"
  if ! boxguard_pressure; then rm -f "$flag" 2>/dev/null; return 0; fi
  local avail swap top="" mb dir ws wsdir p acted server_rows server_top
  read -r avail swap <<<"$(boxguard_read)"
  while IFS=$'\t' read -r mb dir; do
    [ -n "$dir" ] && top="$top${top:+, }${dir#"$HOME"/.herdr/worktrees/} $(mem_human "$mb")"
  done < <(boxguard_top_trees 5 2>/dev/null || true)
  server_rows="$(serve_list_json 2>/dev/null || printf '[]')"
  server_top="$(printf '%s' "$server_rows" | jq -r '.[0:5][] | "\(.name) \(.memory_mb)M"' | paste -sd', ' -)"
  top="${top}${server_top:+; top servers: $server_top}"
  # The finished reviewers gc's last sweep closed - all of it is what was stopped.
  acted="$(grep . "$(_gc_idle_stop_last)" 2>/dev/null | paste -sd';' - || true)"
  acted="${acted:+gc closed finished reviewers: $acted}"
  local msg; msg="steward: $(boxguard_warning_text "$acted") Biggest worktrees: ${top:-none attributable}."
  c_warn "$msg"
  [ -f "$flag" ] && return 0
  mkdir -p "${flag%/*}" 2>/dev/null; : > "$flag" 2>/dev/null || true
  for ws in $(registry_names); do
    wsdir="$(registry_path "$ws")" || continue
    for p in $(ws_product_names "$wsdir" 2>/dev/null); do
      cmd_inbox send "$p-orch" "$msg" --from steward --workspace "$ws" --kind status \
        --fp mem-pressure >/dev/null 2>&1 || true
    done
  done
}

_steward_memory() {
  local total avail used
  read -r total avail used <<<"$(mem_box)"
  # A box that cannot be measured is not a box in crisis. mem_box prints zeroes
  # for an unreadable meminfo, and a sweep that treated "could not ask" as 0 MB
  # available would raise a blocker every tick on a perfectly healthy box.
  [ "${total:-0}" -gt 0 ] || return 0
  mem_tree_snapshot
  local tracked untracked servers
  tracked="$(serve_list_json 2>/dev/null || printf '[]')"
  untracked="$(serve_adopt_json 2>/dev/null || printf '[]')"
  servers="$(jq -cn --argjson tracked "$tracked" --argjson untracked "$untracked" '$tracked + ($untracked | map(. + {owner:"unledgered"})) | sort_by(-.memory_mb)')"

  local availpct=$(( avail * 100 / total )) ws
  # Servers have their own cgroup attribution; include them beside process trees.
  local server_top; server_top="$(printf '%s' "$servers" | jq -r '.[0:5][] | "\(.name // .unit // ("pid:"+(.pid|tostring))) \(.memory_mb)M[\(.owner // "unledgered")]"' | paste -sd', ' -)"
  # HYSTERESIS, 10% to raise and 15% to clear. A single threshold on a box
  # hovering at it would post and resolve the same item every tick.
  if [ "$availpct" -lt 10 ]; then
    local trees top="" name mb n=0
    trees="$(_steward_mem_trees)"
    while IFS=$'\t' read -r name mb; do
      [ -n "$name" ] || continue
      top="$top${top:+, }$name $(mem_human "$mb")"
      n=$((n + 1)); [ "$n" -ge 3 ] && break
    done <<<"$trees"
    local msg
    msg="steward: box memory low: $(mem_human "$avail") of $(mem_human "$total") available - the largest trees: ${top:-none this sweep can see}. Top servers: ${server_top:-none}. Collect or let something go; nothing here has been killed."
    c_err "$msg"
    # The box is one box, but root's mailbox is per workspace - as with a
    # provider account shared by two workspaces, the condition key makes it one
    # rolled-up item in each rather than a fresh one every tick.
    for ws in $(registry_names); do _steward_raise "$ws" mem-box blocked "$msg"; done
  elif [ "$availpct" -ge 15 ]; then
    for ws in $(registry_names); do
      _steward_clear "$ws" mem-box "box memory is back to $(mem_human "$avail") of $(mem_human "$total") available"
    done
  fi

  _steward_mem_pressure_warn "$avail"

  mem_tree_snapshot_clear
}

# THE ORPHANS, ONCE PER TICK, AND ONE LINE ABOUT IT.
#
# Unlike every other sweep in this file, this one ACTS: the memory sweep
# reports and never kills, because what it is looking at is a worker mid-gate
# whose work a kill would destroy. Nothing in the four orphan classes has any
# work to lose - a watcher for a console that exited, a fixture whose worktree
# was deleted, a shell on a pty nobody can reach, a runner whose suite was
# killed - and left alone they accumulate for days.
#
# ONE ROLLED-UP LINE, AND ONLY WHEN SOMETHING WENT. `reaped 6 orphans (2
# watchers, 3 fixtures, 1 shell), 410 MB` is a sentence somebody reads; an item
# per reaped pid is the litter moved from /proc to root's mailbox. And a tick
# that reaped nothing says nothing at all.
#
# ONCE PER BOX, AND ONCE PER CHANGE. The orphans are the box's, not a
# workspace's, so the line goes to the first registered workspace's root
# mailbox only, as the subscription items do; posted to every workspace, root
# read each reap four times. And every reap rolled up into one item shown as
# "x45" under the latest line, which read as that line repeating every cycle.
# So a reap that says what the last one said posts nothing, and the mail
# carries the classes, not the megabytes, which differ every time a fixture
# is taken - the journal line keeps the size.
_steward_orphans() {
  local rows line ws
  rows="$(orphans_list 2>/dev/null)" || return 0
  [ -n "$rows" ] || return 0
  local class pid rss age cwd args
  while IFS=$'\t' read -r class pid rss age cwd args; do
    [ -n "$class" ] || continue
    _orphans_kill "$class" "$pid"
  done <<<"$rows"
  line="$(printf '%s\n' "$rows" | orphans_reaped_line)"
  [ -n "$line" ] || return 0
  c_warn "$line"
  ws="$(registry_names | head -n1)"
  [ -n "$ws" ] || return 0
  _steward_raise_on_change "$ws" orphans status \
    "steward: ${line%, * MB} - processes with no owner (reparented watchers, fixtures whose worktree is gone, shells on dead ptys). cel gc --orphans --dry-run shows what a sweep would take."
  return 0
}

# THE BOX ITSELF, ON A CADENCE - NOT EVERY TICK. The steward runs every five
# minutes; a `docker image prune` per tick is its own kind of waste, spending
# disk churn and daemon time on a box whose litter accumulates over days. Six
# hours is the interval at which a sweep still has something to take. Bytes
# freed go into the steward's own state, so "how much has the janitor
# actually reclaimed" is a question with an answer.
_steward_box() {
  # _steward_due reads this window from the enclosing scope; a local here is
  # the whole of the override, and the box key cannot collide with a PR key
  # because those always contain a '#'.
  local _STEWARD_WINDOW="${CEL_STEWARD_BOX_WINDOW:-21600}"
  _steward_due box-sweep || return 0
  box_sweep 0 || true   # a failed docker delete is already warned; still count what was freed
  local freed=$(( ${BOX_FREED_DOCKER:-0} + ${BOX_FREED_CACHES:-0} + ${BOX_FREED_OURS:-0} ))
  local total=0
  _steward_state_edit "$_STEWARD_STATE" _steward_state_add box-freed-bytes "$freed" || true
  total="$(awk '$1=="box-freed-bytes"{t=$2} END{printf "%.0f", t+0}' "$_STEWARD_STATE" 2>/dev/null || printf 0)"
  c_ok "box: $(box_human "$freed") freed this sweep, $(box_human "$total") since this state file began"
  return 0
}

_STEWARD_UNIT="cel-steward"
# shellcheck source=lib/steward_timer.sh
. "${BASH_SOURCE[0]%/*}/steward_timer.sh"   # steward_timer_unit
# A MAILBOX NOBODY READS MUST NOT BE ABLE TO SWALLOW AN ESCALATION.
#
# A root mailbox can take hundreds of messages with nothing obliged to open
# it: the console that reads it is a process that may not be running, and
# `lib/inbox.sh` raises a desktop notification for the blocking kinds only.
#
# So the steward escalates the FACT, once per workspace, rolled up on
# `root-unread-<ws>` and self-clearing: a `blocked` item, which is the kind
# that already takes the notification path. It names the count and the oldest
# sender, because "you have mail" is not a reason to go and look.
#
# Mail FROM the steward is excluded from the count on purpose: its own alarm
# would otherwise be the alarm's evidence, and the condition could never clear.
_STEWARD_ROOT_UNREAD_SECS="${CEL_ROOT_UNREAD_SECS:-3600}"
_steward_root_unread() {
  local ws n oldest_secs oldest_from reader rc
  for ws in $(registry_names); do
    local f; f="$(_inbox_file "$ws")"
    [ -s "$f" ] || continue
    # Only what a person must answer, decide or unblock. Status is the
    # ledger's job.
    # A mailbox that does not parse is unknown: neither "read" (which would
    # clear the item) nor news. Said in the log; nothing raised or cleared.
    local unread waiting
    if ! unread="$(inbox_unread_json "$ws" root 2>/dev/null)"; then
      c_warn "$ws: root's mailbox $f is corrupt - its unread mail is unknown"
      continue
    fi
    waiting="$(printf '%s' "$unread" \
      | jq -sc --argjson age "$_STEWARD_ROOT_UNREAD_SECS" --arg now "$(date -Is)" '
          [ .[] | select(.kind == "escalation" or .kind == "decision" or .kind == "blocked")
                | select(.from != "steward") ]
          | sort_by(.ts)' 2>/dev/null || printf '[]')"
    n="$(printf '%s' "$waiting" | jq -r 'length' 2>/dev/null || printf 0)"
    if [ "${n:-0}" -eq 0 ]; then
      _steward_clear "$ws" "root-unread-$ws" "root's mail in $ws has been read"
      continue
    fi
    oldest_secs="$(inbox_oldest_unread_secs "$ws" root 'escalation|decision|blocked')" || continue
    [ "${oldest_secs:-0}" -ge "$_STEWARD_ROOT_UNREAD_SECS" ] || continue
    # herdr unreachable is NOT evidence that nobody is reading - the same rule
    # as `cel inbox prune` and the orchestrator sweep. Unknown says nothing
    # this tick.
    reader="$(inbox_reader_of "$ws" root)"; rc=$?
    [ "$rc" -eq 2 ] && continue
    if [ -n "$reader" ]; then
      _steward_clear "$ws" "root-unread-$ws" "$reader is reading root's mail in $ws again"
      continue
    fi
    oldest_from="$(printf '%s' "$waiting" | jq -r '.[0].from // "someone"')"
    _steward_raise "$ws" "root-unread-$ws" blocked \
      "steward: $n unread escalation(s)/decision(s) in $ws addressed to root and nobody is reading that mailbox - oldest is $((oldest_secs / 60))m old, from $oldest_from. Start a root pane, open the console, or read it with 'cel inbox open --for root --workspace $ws --ranked'."
    c_warn "$ws: root has $n unread, oldest $((oldest_secs / 60))m, nobody reading it"
  done
}

_steward_unit_dir() { printf '%s' "${CEL_SYSTEMD_DIR:-$HOME/.config/systemd/user}"; }
# `cel steward --install` - the thing that actually makes the steward proactive.
#
# Every trigger the steward owns (a Linear ticket moved into the workspace's
# trigger state, a stalled review, a mailbox nobody is draining, a dashboard
# that fell over) is documented as "the steward notices", and none of it
# happens unless something runs a tick.
#
# A systemd USER TIMER rather than a herdr pane running `while true`, because
# the steward's whole job is to be running when nobody is watching. A pane
# loop dies with the herdr session and takes the watcher with it silently.
# The timer survives logout and reboot, and `journalctl --user -u cel-steward`
# keeps the history.
_steward_install() { # [--interval MIN] [--remove]
  local mins=5 remove=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) mins="$2"; shift 2 ;;
      --remove)   remove=1; shift ;;
      *) die "cel steward --install: unknown argument '$1'" ;;
    esac
  done
  have systemctl || die "cel steward --install: systemd --user is required (on a box without it, run 'cel steward' from cron or a supervised loop)"
  local d; d="$(_steward_unit_dir)"; mkdir -p "$d"

  if [ "$remove" -eq 1 ]; then
    systemctl --user disable --now "$_STEWARD_UNIT.timer" >/dev/null 2>&1 || true
    rm -f "$d/$_STEWARD_UNIT.service" "$d/$_STEWARD_UNIT.timer"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    c_ok "removed the $_STEWARD_UNIT timer"
    return 0
  fi

  printf '%s' "[Unit]
Description=celestial steward - one proactive tick over the fleet
After=default.target

[Service]
Type=oneshot
# A login shell, because the tick needs the per-workspace env that carries
# LINEAR_API_KEY. But a NON-INTERACTIVE login shell does not activate mise, so
# node and bun are missing from PATH and every server check fails - the shim
# directory is prepended explicitly rather than relying on shell rc files that
# only run for interactive sessions.
ExecStart=/bin/bash -lc 'export PATH=\"\$HOME/.local/share/mise/shims:\$HOME/.local/bin:\$PATH\"; exec \"$CEL_ROOT/bin/cel\" steward'
TimeoutStartSec=600
" > "$d/$_STEWARD_UNIT.service"

  steward_timer_unit "$mins" > "$d/$_STEWARD_UNIT.timer"

  systemctl --user daemon-reload || die "cel steward --install: systemctl daemon-reload failed"
  systemctl --user enable --now "$_STEWARD_UNIT.timer" \
    || die "cel steward --install: could not enable $_STEWARD_UNIT.timer"
  c_ok "steward timer installed - every ${mins}m (systemctl --user list-timers | grep $_STEWARD_UNIT)"
  # Without lingering the timer stops when the last session closes, which
  # would reproduce the pane-loop failure this exists to avoid.
  if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
    c_warn "user lingering is off - the timer stops when you log out. Enable with: sudo loginctl enable-linger $USER"
  fi
}

# Is this box behind its latest release? The steward is the only thing that
# asks on its own, so it is also the only thing that can tell the dashboard:
# the marker file it writes here is what the dash build chip reads per request,
# hours after the dashboard booted. Removing it when current matters as much as
# writing it - a stale chip would nag about an update that already landed.
_steward_update_check() {
  # shellcheck source=lib/version.sh
  . "${BASH_SOURCE[0]%/*}/version.sh"
  # shellcheck source=lib/config.sh
  . "${BASH_SOURCE[0]%/*}/config.sh"
  local v latest dir chan
  dir="${CEL_UPDATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/update}"
  chan="$(cel_config_get update channel)"
  case "$chan" in main) ;; *) chan=release ;; esac

  # On the main channel the tag never moves, so "a new release is out" never
  # fires however far behind the box is. What it needs to hear is the
  # distance and the sha its build came from.
  if [ "$chan" = main ]; then
    local n ws
    git -C "$CEL_ROOT" fetch -q origin main 2>/dev/null || true
    n="$(cel_commits_behind_main)"
    if [ "$n" -gt 0 ] 2>/dev/null; then
      mkdir -p "$dir"
      printf 'main+%s %s\n' "$n" "$(cel_build_sha)" >"$dir/available"
      c_warn "$n new commits on celestial main since $(cel_build_line) - run: cel update --check"
      # A STATUS line, and exactly one: nobody has to ANSWER "there are new
      # commits" - the console reads it and the operator runs the command when
      # they feel like it. A decision or a blocker would sit in root's open
      # list waiting on a human who owes it nothing. The once-a-day window
      # around this check is what keeps it to one line.
      for ws in $(registry_names 2>/dev/null); do
        _steward_raise "$ws" cel-update status \
          "steward: $n new commits on celestial main since your build ($(cel_build_sha)) - cel update --check lists them, cel update takes them"
      done
    else
      rm -f "$dir/available"
      for ws in $(registry_names 2>/dev/null); do
        _steward_clear "$ws" cel-update "celestial is level with main again"
      done
    fi
    return 0
  fi

  v="$(cel_version)"; latest="$(cel_latest_remote_version)"
  if [ -n "$latest" ] && cel_version_lt "$v" "$latest"; then
    mkdir -p "$dir"
    printf '%s\n' "$latest" >"$dir/available"
    c_warn "celestial v$latest is out (installed v$v) - run: cel update"
  else
    rm -f "$dir/available"
  fi
  return 0
}

# OLDER LAUNCH LINES: report once per build, orchestrator and difference.
# An open owner card suppresses only the agent it names; closing the card
# makes an unresolved difference actionable again within the same build.
_steward_stale_orchestrators() {
  # shellcheck source=lib/version.sh
  . "${BASH_SOURCE[0]%/*}/version.sh"
  local dir marker build rows fresh ws msg key seen agent why restart card actionable covered wsrows
  dir="${CEL_UPDATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/update}"; marker="$dir/orch-stale-reported"
  build="$(cel_build_sha)"
  rows="$(run_stale_orchestrators)"
  [ -n "$rows" ] || return 0
  # Keys from an older build are history: drop them so the file stays small.
  seen="$(awk -F '\t' -v b="$build" '$1 == b' "$marker" 2>/dev/null || true)"
  actionable=""; covered=""
  while IFS=$'\t' read -r agent ws why restart; do
    [ -n "$agent" ] || continue
    card="$(_steward_owner_card "$ws" "$agent" "${agent%-orch}")"
    if [ -n "$card" ]; then
      covered+="$agent"$'\t'"$ws"$'\n'
      # Forget its report while covered: closing the card must make the
      # still-stale launch actionable again, even within this same build.
      seen="$(printf '%s\n' "$seen" | awk -F '\t' -v a="$agent" -v w="$ws" '$2 != a || $3 != w')"
      c_warn "$agent waits on owner decision ${card%%$'\t'*} - no launch-line alert while that card is open"
      continue
    fi
    actionable+="$agent"$'\t'"$ws"$'\t'"$why"$'\t'"$restart"$'\n'
  done <<< "$rows"
  fresh=""
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf '%s\n' "$seen" | grep -qxF -- "$build	$key" && continue
    fresh="$fresh$key"$'\n'
  done < <(printf '%s' "$actionable" | cut -f1-3)
  for ws in $(printf '%s\n' "$rows" | cut -f2 | sort -u); do
    [ -n "$ws" ] || continue
    wsrows="$(printf '%s' "$actionable" | awk -F '\t' -v w="$ws" '$2 == w')"
    if [ -z "$wsrows" ]; then
      _steward_clear "$ws" orch-stale "stale launch differences in $ws wait on open owner decisions - no launch-line alert while those cards are open"
      continue
    fi
    msg="$(printf '%s\n' "$wsrows" | awk -F '\t' '{
      printf "%s%s runs an older launch line (%s)", (n++ ? "; " : ""), $1, $3 }')"
    msg="$msg - $(printf '%s\n' "$wsrows" | awk -F '\t' '{ printf "%s%s", (n++ ? "; " : ""), $4 }')"
    if [ -n "$(printf '%s' "$fresh" | awk -F '\t' -v w="$ws" '$2 == w')" ]; then
      c_warn "$msg"
      _steward_raise "$ws" orch-stale status "steward: after the update to $build, $msg"
    elif [ -n "$(printf '%s' "$covered" | awk -F '\t' -v w="$ws" '$2 == w')" ] &&
         [ -n "$(_inbox_open_fp "$ws" orch-stale steward root)" ]; then
      # An aggregate already open must stop naming a newly covered agent,
      # without silencing another agent or repeating an unchanged warning.
      _steward_raise_on_change "$ws" orch-stale status "steward: after the update to $build, $msg"
    fi
  done
  mkdir -p "$dir" 2>/dev/null || return 0
  { [ -z "$seen" ] || printf '%s\n' "$seen"
    printf '%s' "$fresh" | sed "s/^/$build	/"; } > "$marker.tmp" && mv -f "$marker.tmp" "$marker"
  return 0
}

# `| sed -n 1p`, NEVER `| head -1`, on anything that can be long. bin/cel runs
# under `set -euo pipefail`: when `head` closes the pipe after one line the
# producer takes SIGPIPE, the pipeline's status is 141, and `set -e` ends the
# tick right there - silently - once the input passes a pipe buffer in size.
# sed reads to the end and exits 0.
# THE DASHBOARD'S MEMORY OF THE BOX. The dashboard draws load over a day and
# which worker was running, waiting or idle when - and herdr answers only
# "now" while the ledger records only state changes a person made. So each
# tick appends one line (load, memory, swap, every pane's status) to a small
# ring, trimmed to the newest CEL_SAMPLES_KEEP lines. Cheap by design: /proc
# and the agent list the tick already fetched.
_steward_sample() { # <agents-json>
  local f="${CEL_SAMPLES_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/samples.jsonl}" keep="${CEL_SAMPLES_KEEP:-2000}"
  local load mem swap
  load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || printf 0)"
  mem="$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{if(t>0) printf "%.1f", (t-a)*100/t; else print 0}' /proc/meminfo 2>/dev/null || printf 0)"
  swap="$(awk '/^SwapTotal/{t=$2} /^SwapFree/{f=$2} END{if(t>0) printf "%.1f", (t-f)*100/t; else print 0}' /proc/meminfo 2>/dev/null || printf 0)"
  mkdir -p "$(dirname "$f")"
  printf '%s' "$1" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson load "${load:-0}" --argjson mem "${mem:-0}" --argjson swap "${swap:-0}" \
    '{ts: $ts, load: $load, mem_pct: $mem, swap_pct: $swap,
      panes: [(.result.agents // [])[] | {cwd: .cwd, status: .agent_status}]}' >> "$f" 2>/dev/null || return 0
  if [ "$(wc -l < "$f")" -gt "$keep" ]; then
    tail -n "$keep" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
}

# ── Rex server restarts and upgrades ─────────────────────────────────────────
# lib/rex.sh decides and acts (rex_generation_tick, rex_upgrade_round); this
# says what happened, once: ONE summary to root per restart or upgrade, and a
# note to each resumed agent, whose background shells, subagents and servers
# ended with the old server. The Rex server is box-wide, so the summary goes
# to the root mailbox of the first workspace it touched (core reads them all).
_steward_rex_ws() { # [rows] -> workspace name for root's summary
  local p n first=""
  while IFS=$'\t' read -r _ _ p _; do
    [ -n "$p" ] || continue
    n="$(ws_name "$p" 2>/dev/null || true)"
    [ -z "$n" ] || first="$(printf '%s\n%s\n' "$first" "$n" | sed '/^$/d' | sort | sed -n 1p)"
  done <<<"${1:-}"
  [ -n "$first" ] || first="$(registry_names 2>/dev/null | sed -n 1p)"
  printf '%s' "$first"
}

_steward_rex_summary() { # <headline> <rows> -> the message
  local msg="$1" rows="$2" o label list
  for o in server-failed server resumed failed held skipped; do
    list="$(awk -F '\t' -v o="$o" '$1 == o {
      if (o ~ /^server/) printf "%s%s", (n++ ? "; " : ""), $4
      else { printf "%s%s", (n++ ? "; " : ""), $2; if (o != "resumed") printf " (%s)", $4 } }' <<<"$rows")"
    [ -n "$list" ] || continue
    case "$o" in
      server-failed) label="Rex server NEEDS ATTENTION" ;;
      server)  label="Rex server" ;;
      resumed) label="Resumed in their saved sessions and alive" ;;
      failed)  label="FAILED to resume" ;;
      held)    label="Not resumed" ;;
      skipped) label="Left alone" ;;
    esac
    msg+=" $label: $list."
  done
  printf '%s' "$msg"
}

_steward_rex_report() { # <headline> <rows> <what happened, for the agents>
  # Never `status`: status to root is telemetry nobody reads, and every agent
  # the root coordinates was just restarted under it.
  local rows="$2" ws kind=escalation name p n
  ws="$(_steward_rex_ws "$rows")"
  if awk -F '\t' '$1 == "failed" || $1 == "held" || $1 == "server-failed" { f = 1 } END { exit !f }' <<<"$rows"; then kind=blocked; fi
  local msg; msg="$(_steward_rex_summary "$1" "$rows")"
  if [ "$kind" = blocked ]; then c_err "$msg"; else c_ok "$msg"; fi
  [ -z "$ws" ] || cmd_inbox send root "$msg" --from steward --workspace "$ws" --kind "$kind" >/dev/null 2>&1 || true
  while IFS=$'\t' read -r _ name p _; do
    n="$(ws_name "$p" 2>/dev/null || true)"
    [ -n "$n" ] || continue
    cmd_inbox send "$name" "steward: $3, which ended your runtime; you were resumed in your saved session. Anything running then - subagents, background shells, gates, dev servers - was killed: re-check it and rerun only what is still needed." \
      --from steward --workspace "$n" --kind status >/dev/null 2>&1 || true
  done < <(awk -F '\t' '$1 == "resumed"' <<<"$rows")
}

# The safety net: a restart this plane did not drive (see rex_generation_tick).
_steward_rex_generation() {
  local out rc=0 old new rows
  out="$(rex_generation_tick)" || rc=$?
  [ "$rc" != 2 ] || c_warn "a Rex receipt is unreadable - Rex restart detection skipped this tick"
  [ -n "$out" ] || return 0
  IFS=$'\t' read -r _ old new <<<"$(sed -n 1p <<<"$out")"
  rows="$(sed 1d <<<"$out")"
  # Every restart gets its server facts logged; root hears only when an agent
  # was affected or the server needs a person.
  awk -F '\t' '$1 == "server" { print "the Rex server restarted: " $4 }' <<<"$rows" | while IFS= read -r l; do c_ok "$l"; done
  if ! awk -F '\t' '$1 != "server" { f = 1 } END { exit !f }' <<<"$rows"; then
    c_ok "the Rex server restarted ($old -> $new); no managed agent was live under it"; return 0
  fi
  _steward_rex_report "steward: the Rex server restarted outside the managed upgrade (instance $old -> $new), ending every program in its sessions." \
    "$rows" "the Rex server restarted"
}

# A BLOCKED UPGRADE IS SAID ONCE PER VERSION. Its reason lists the agents and
# sessions in the way, and that list changes whenever a reviewer comes or goes:
# keyed on the message, root heard it again every round of normal PR flow. The
# record is "rex-upgrade-blocked <version> <first-blocked-epoch> <stage>": root
# hears when a version is first blocked (stage 0) and once more when it has been
# blocked for a day (stage 1, an update on the same item), and nothing in
# between. A new version replaces an older version's open item. The record
# outlives the item: a block that clears and comes back for the same version is
# not news. It goes when that version, or a later one, is installed.
# THE WORD IS SENT BEFORE IT IS RECORDED: a send that fails records nothing,
# so the next round says it again instead of believing root was told.
_steward_rex_blocked() { # <ws> <version> <why>
  local ver since stage now msg id ids
  read -r ver since stage < <(awk '$1 == "rex-upgrade-blocked" { r = $2 " " $3 " " $4 } END { print r }' "$_STEWARD_STATE" 2>/dev/null || true) || true
  now="$(date +%s)"
  case "$since" in ''|*[!0-9]*) since="$now" ;; esac
  if [ "$ver" != "$2" ]; then
    # The older version's item says nothing true any more; the new one says it
    # all. A mailbox that does not parse says nothing this round, and records
    # nothing, so the next round says it. The old items go first - every one,
    # as a pre-roll-up mailbox can hold several - or the new word would land on
    # one as an update and go down with it.
    ids="$(_inbox_open_fp_ids "$1" rex-upgrade-blocked steward root)" || return 0
    for id in $ids; do cmd_inbox resolve "$id" --by steward --workspace "$1" >/dev/null 2>&1 || true; done
    msg="steward: rex $2 is available, but the managed upgrade will not restart the Rex server: $3"
    set -- "$1" "$2" "$now" 0 "$msg"
  elif [ "${stage:-0}" = 0 ] && [ $((now - since)) -ge 86400 ]; then
    msg="steward: rex $2 has been blocked for over a day - the managed upgrade still will not restart the Rex server: $3"
    set -- "$1" "$2" "$since" 1 "$msg"
  else
    return 0
  fi
  cmd_inbox send root "$5" --from steward --workspace "$1" --kind blocked --fp rex-upgrade-blocked \
    >/dev/null 2>&1 || return 0
  _steward_state_edit "$_STEWARD_STATE" _steward_state_set rex-upgrade-blocked "$2" "$3" "$4" || true
}

# No round output: no newer rex from its origin - or apt could not say. Only an
# installed version at or past the blocked one takes the block down.
_steward_rex_installed() { # <ws>
  local ver inst
  read -r ver _ < <(awk '$1 == "rex-upgrade-blocked" { r = $2 } END { print r }' "$_STEWARD_STATE" 2>/dev/null || true) || true
  [ -n "$ver" ] || return 0
  IFS=$'\t' read -r inst _ _ < <(_rex_policy_versions) || return 0
  [ -n "$inst" ] && [ "$inst" != "(none)" ] && dpkg --compare-versions "$inst" ge "$ver" || return 0
  _steward_clear "$1" rex-upgrade-blocked "rex $inst is installed"
  _steward_forget rex-upgrade-blocked
}

# The managed upgrade; `cel sessions rex-upgrade` runs one round by hand.
_steward_rex_upgrade() {
  local out status a b c rows ws
  out="$(rex_upgrade_round)" || true
  ws="$(_steward_rex_ws)"
  if [ -z "$out" ]; then
    [ -z "$ws" ] || _steward_rex_installed "$ws"
    return 0
  fi
  IFS=$'\t' read -r status a b c <<<"$(sed -n 1p <<<"$out")"
  rows="$(sed 1d <<<"$out")"
  case "$status" in
    waiting)
      c_warn "rex $a is available; the managed upgrade skipped this round: $b"
      # The reason CODE (4th field, see rex_upgrade_round), never the words,
      # says whether the round got past every blocking check. Only those that
      # did clear the block; any other code, or none, leaves it as it was.
      case "$c" in
        busy|admission|record) [ -z "$ws" ] || _steward_clear "$ws" rex-upgrade-blocked "the rex $a upgrade is no longer blocked: $b" ;;
        *) ;;
      esac ;;
    blocked)
      c_err "rex $a is available; the managed upgrade is blocked: $b"
      [ -z "$ws" ] || _steward_rex_blocked "$ws" "$a" "$b" ;;
    failed)
      # Nothing was stopped: said once per state, not every round.
      c_err "the managed rex upgrade to $a failed: $b"
      [ -z "$ws" ] || {
        _steward_clear "$ws" rex-upgrade-blocked "the rex $a upgrade is no longer blocked"
        _steward_raise_on_change "$ws" rex-upgrade-failed blocked \
          "steward: the managed rex upgrade to $a failed and nothing was restarted: $b"
      } ;;
    upgraded)
      _steward_forget rex-upgrade-blocked
      [ -z "$ws" ] || { _steward_clear "$ws" rex-upgrade-blocked "rex was upgraded to $b"; _steward_clear "$ws" rex-upgrade-failed "rex was upgraded to $b"; }
      _steward_rex_report "steward: upgraded rex $a -> $b while every Rex agent was idle; $c." "$rows" "rex was upgraded and its server restarted" ;;
  esac
}

# The claim is a pidfile, checked and written under a flock that is held for
# that instant only. Holding the flock for the whole tick would hand the
# descriptor to everything the tick starts - one long-lived child and no tick
# would ever run again. A recorded pid that is gone, or is no longer a
# steward, is stale and is taken over.
_steward_tick_claim() {
  local f="${CEL_STEWARD_LOCK:-$_STEWARD_STATE.tick.lock}" fd pid cmd rc=0
  mkdir -p "${f%/*}" 2>/dev/null || true
  exec {fd}>>"$f" || return 0
  # No flock, no claim: whoever holds it is mid-claim, and reading the pidfile
  # without it is exactly the race the lock exists to close.
  if have flock && ! flock -w 5 "$fd"; then
    printf 'steward: could not take the tick lock %s within 5s - this one exits\n' "$f"
    exec {fd}>&-
    return 1
  fi
  pid="$(head -c 32 "$f" 2>/dev/null | tr -dc 0-9)"
  if [ -n "$pid" ] && [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null; then
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    case "$cmd" in *steward*) rc=1;; esac
  fi
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$$" > "$f"
    trap '[ "$(head -c 32 "'"$f"'" 2>/dev/null | tr -dc 0-9)" = "'"$$"'" ] && : > "'"$f"'"' EXIT
  else
    printf 'steward: a tick is already running (pid %s) - this one exits\n' "$pid"
  fi
  exec {fd}>&-
  return "$rc"
}

cmd_steward() { # [--no-gc] [--install [--interval MIN] [--remove]]
  local do_gc=1
  if [ "${1:-}" = "--install" ]; then shift; _steward_install "$@"; return $?; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-gc) do_gc=0; shift ;;
      *) die "cel steward: unknown argument '$1' (want --no-gc or --install)" ;;
    esac
  done
  # TICKS NEVER OVERLAP. A slow tick can outlive the timer interval, and
  # overlapping stewards each walk /proc and every worktree. A tick that finds
  # one running says so and goes.
  _steward_tick_claim || return 0
  have herdr || die "cel steward: herdr is not on PATH"
  have jq    || die "cel steward: jq is not on PATH"
  have gh    || die "cel steward: gh is not on PATH"
  c_hd "steward tick $(date '+%F %T')"

  # FIRST: a Rex server that restarted took its agents with it, and every
  # sweep below would read their absence as the truth. Then, at most every
  # 30 minutes, the managed rex upgrade (skipped while any Rex agent is busy).
  _steward_rex_generation
  if _STEWARD_WINDOW=1800 _steward_due rex-upgrade; then _steward_rex_upgrade; fi

  # Under memory pressure the reap window collapses: idle agents are the
  # reclaimable mass on this box, and 2h idle is finished work, not a pause.
  local reap="${CEL_STEWARD_REAP_HOURS:-12}" avail
  avail="$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || printf 9999999)"
  if [ "$avail" -lt 2097152 ]; then
    c_warn "memory pressure: $((avail / 1024))MB available - reap window drops to 2h"
    reap=2
  fi
  [ "$do_gc" -eq 1 ] && cmd_gc --reap "$reap"
  [ "$do_gc" -eq 1 ] && _steward_box

  local agents_json
  agents_json="$(cel_agent_list 2>/dev/null)" || { agents_json=""; c_warn "agent discovery unavailable - liveness observations skipped"; }
  _steward_sample "$agents_json"

  _steward_review_sweep "$agents_json"
  _steward_solo_sweep
  # feature teams: reservations nobody confirmed, verdicts a newer candidate
  # outdated - the lead is told; nothing is retired
  _steward_team_sweep
  # (No ledger reconcile or stalled-worker sweep: fan-out was retired on
  # 2026-11-08 and the steward reads no delegation ledger any more.)
  # An item naming a pane that no longer exists cannot be acted on by anyone.
  _steward_clear_dead_panes
  # And the mailbox itself: unread escalations with nobody alive to read them.
  _steward_root_unread
  # ...and whether the mode that authorised any of tonight's autonomy has run out.
  _steward_afk_sweep

  # blocked agents are the human's queue - name them every tick, no dedup
  printf '%s' "$agents_json" | jq -r \
    '.result.agents[] | select(.agent_status == "blocked") | "\(.pane_id) \(.cwd)"' \
    | while read -r pane cwd; do c_warn "BLOCKED agent in $pane ($cwd) - needs input"; done

  # STALE ACTIONABLE MAIL GETS A RATE-LIMITED INBOX REMINDER. It never types into
  # the recipient's pane; delivery still depends on the runtime's idle support.
  _steward_mail_sweep "$agents_json"

  # page feedback whose publishing pane is gone queues here; it stays a
  # warning every tick until someone drains the log
  local fblog n
  for fblog in "$(_pages_root)/.meta/feedback.log" "$(_pages_public_root)/.meta/feedback.log"; do
    [ -s "$fblog" ] || continue
    n="$(wc -l < "$fblog" | tr -d ' ')"
    c_warn "$n undelivered page feedback item(s) in $fblog - deliver or clear"
  done

  # Once a day: is the plane itself behind its latest release? The steward
  # is the thing the human actually reads, so the update notice lives here
  # too, not only in doctor.
  if _STEWARD_WINDOW=86400 _steward_due "cel-update-check"; then
    _steward_update_check
  fi

  _steward_ready_tickets "$agents_json"
  _steward_quota
  _steward_subscriptions
  _steward_orch_pool
  _steward_usage_pace
  # Before the server sweeps: a box at 5% available is why the next thing in
  # this tick fails to start, and reading that warning after three failures is
  # reading it in the wrong order.
  _steward_memory
  # AND WHAT HAS NO PANE AT ALL. The sweep above groups by worktree and pane,
  # so reparented watchers, dead-worktree fixtures and pane-less shells are
  # invisible to it.
  _steward_orphans
  _steward_services
  # And the other box-wide resource: one suite runs at a time, so a gate that
  # is queued is not a gate that is stuck - but only if somebody says so.
  _steward_suite_lock
  _steward_servers
  _steward_orphan_servers "$agents_json"
  _steward_orchestrators "$agents_json"
  _steward_inbox_hooks
  run_sessions_note_roster "$agents_json"
  _steward_stale_orchestrators
  serve_sweep
  # previews of PRs that closed or merged, and checkouts of reaped previews
  ( . "${BASH_SOURCE[0]%/*}/preview.sh"; preview_sweep ) || true
  _serve_unledgered_report
  # Keep the fleet cache warm so the first console read after an idle
  # spell serves a recent board. One detached refill, only when stale; the
  # tick never waits on it.
  ( . "${BASH_SOURCE[0]%/*}/fleet.sh" && fleet_cache_warm ) || true
  c_ok "tick complete"
}

# ── declared services ────────────────────────────────────────────────────────
#
# A service with a `health:` path is the only thing on this box that can be
# asked, rather than guessed at, whether it is working - so it is asked, once
# per tick. ONE down tick is a restart, a deploy, a laptop lid; TWO CONSECUTIVE
# down ticks is a service that is not coming back on its own, and that is the
# point at which root hears about it. The count lives beside the nudge state
# because it is the same kind of fact: what was true last time this ran.
# RESOLVED PER CALL, never captured at source time. The suite points
# CEL_STEWARD_STATE at a fixture AFTER sourcing this file; a path frozen when
# the library loaded would make every test count down-ticks in the real box's
# state file.
_steward_svc_state() {
  printf '%s' "${CEL_STEWARD_SVC_STATE:-${CEL_STEWARD_STATE:-$_STEWARD_STATE}.services}"
}

_steward_svc_read() { # <key> -> "<down-count> <restarted>"
  local f; f="$(_steward_svc_state)"
  awk -v k="$1" '$1 == k { c = $2; r = $3 } END { printf "%d %d", c + 0, r + 0 }' "$f" 2>/dev/null \
    || printf '0 0'
}

_steward_svc_write() { # <key> <down-count> <restarted>
  _steward_state_edit "$(_steward_svc_state)" _steward_state_set "$1" "$2" "$3"
}

_steward_services() {
  local ws
  for ws in $(registry_names); do
    _steward_services_for "$ws" "$(registry_path "$ws" || true)"
  done
  # ...and the box's own: the services no workspace declares, which is the
  # whole reason services.d exists.
  _steward_services_for box ""
}

# One workspace, or the box when <ws> is `box` and <wsdir> is empty.
_steward_services_for() { # <ws> <wsdir>
  local ws="$1" wsdir="$2" e name url health hauth restart port key count restarted msg last note where
  if [ "$ws" != box ]; then
    [ -n "$wsdir" ] || return 0
    [ -f "$wsdir/workspace.yaml" ] || return 0
  fi
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    health="$(printf '%s' "$e" | jq -r '.health // ""')"
    # No health path, no opinion. A port that is merely open is not evidence
    # a service works, and raising a blocker on a guess is how a watcher
    # earns the right to be ignored.
    [ -n "$health" ] || continue
    name="$(printf '%s' "$e" | jq -r '.name')"
    url="$(printf '%s' "$e" | jq -r '.url')"
    restart="$(printf '%s' "$e" | jq -r '.restart // ""')"
    port="$(svc_port_of_url "$url")"
    key="$ws/$name"
    read -r count restarted <<<"$(_steward_svc_read "$key")"
    hauth="$(printf '%s' "$e" | jq -r '.health_auth // ""')"
    if svc_listening "$port" && svc_health_ok "$port" "$health" "$hauth"; then
      _steward_svc_write "$key" 0 0
      [ "${count:-0}" -ge 2 ] && _steward_clear "$ws" "service-$ws-$name" \
        "$name is answering on :$port again"
      continue
    fi
    count=$((count + 1))
    note=""
    if [ "$count" -ge 2 ] && [ "$restart" = auto ] && [ "${restarted:-0}" -eq 0 ]; then
      # ONE restart per condition, not one per tick. A service that dies on
      # start would otherwise be restarted every five minutes forever, and
      # the blocker would never say anything a human could act on.
      ( svc_restart "$wsdir" "$name" ) >/dev/null 2>&1 || true
      restarted=1
      note=" I restarted it once (restart: auto) and it did not come back."
    fi
    _steward_svc_write "$key" "$count" "$restarted"
    [ "$count" -ge 2 ] || { c_warn "$ws: $name did not answer on :$port (first miss)"; continue; }
    last="$(svc_last_log_line "$wsdir" "$name" 2>/dev/null || true)"
    # A box service is addressed without --workspace, because it has none and
    # a copy-pasted command that names one would fail in front of whoever is
    # trying to fix it at 2am.
    where=" --workspace $ws"; [ "$ws" = box ] && where=""
    msg="steward: service $name ($ws) is down - nothing answered $health on :$port for two consecutive ticks.${note} Last line of its pane: ${last:-nothing to read}. Start it with 'cel services start $name$where' or read it with 'cel services logs $name$where'."
    c_err "$msg"
    _steward_raise "$ws" "service-$ws-$name" blocked "$msg"
  done < <(if [ "$ws" = box ]; then _svc_box; else _svc_declared "$wsdir"; fi)
}
