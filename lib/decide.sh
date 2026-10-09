# shellcheck shell=bash
# cel decide - one queue for every decision an orchestrator needs from the owner.
#
# Questions for the owner used to live at the end of an orchestrator's chat
# turn ("pick a style, pick a name..."), invisible to anyone not looking at
# that pane, or as root mail mixed in with the steward's own reminders about
# them. One orchestrator told the owner "18 open decisions going back days";
# the mailboxes held 12 open items, 7 of them reminders - neither number was
# the owner's real to-do list. And an answer typed into a pane recorded
# nothing, so stale questions stayed open and the reminders kept firing.
#
# So a decision is a RECORD in the workspace's inbox JSONL: `kind: decision`,
# addressed to `owner`, with structured fields. `list` reads every workspace,
# `answer` resolves it and mails the answer to the asker (its inbox hook wakes
# it - nothing is ever typed into a pane), and the steward stops nagging.
[ -n "${_CEL_DECIDE:-}" ] && return 0
_CEL_DECIDE=1
# shellcheck source=lib/inbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/inbox.sh"

# The open owner decisions in one workspace, one JSON object per line, oldest
# first. A re-ask is an `update` naming the record; its fields win, so the
# record reads as the latest version of the question.
decide_open_json() { # <ws>
  local f; f="$(_inbox_file "$1")"
  [ -f "$f" ] || return 0
  jq -cs --arg ws "$1" --arg now "$(date +%s)" '
    # date -Is carries a +HH:MM offset that fromdateiso8601 will not parse
    def _epoch: ((try (.[0:19] + "Z" | fromdateiso8601) catch null) // ($now | tonumber))
      - ((try (.[19:] | capture("^(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})")
              | (if .s == "+" then 1 else -1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60))
          catch 0) // 0);
    . as $all
    | ([.[] | select(.kind == "resolution") | .ref]) as $done
    | [ .[] | select(.kind == "decision" and .to == "owner" and has("title"))
        | select([.id] | inside($done) | not)
        | .id as $i
        | ([$all[] | select(.kind == "update" and .ref == $i and has("title"))] | last) as $u
        | (if $u then . + ($u | {title, options, recommended, context, blocks}) + (if $u.urgent == true then {urgent: true} else {} end) + {updated: $u.ts} else . end)
        | . + {workspace: $ws, urgent: (.urgent == true),
               age_secs: (($now | tonumber) - (.ts | _epoch)),
               # since the asker last touched it: a re-ask is not stale
               idle_secs: (($now | tonumber) - ((.updated // .ts) | _epoch))} ]
    | sort_by(.ts) | .[]' "$f" 2>/dev/null || true
}

# Every registered workspace, plus any that holds a mailbox file but has not
# reached the registry yet: a question filed there must not be invisible.
_decide_all_ws() {
  { _inbox_all_ws; local f; for f in "$(_inbox_dir)"/*.jsonl; do
      [ -f "$f" ] || continue
      f="$(basename "$f" .jsonl)"
      case "$f" in *.*) continue ;; esac   # x.archive.jsonl is not a mailbox
      printf '%s\n' "$f"
    done; } | awk 'NF && !seen[$0]++'
}

decide_all_json() {
  local ws; for ws in $(_decide_all_ws); do decide_open_json "$ws"; done \
    | jq -cs 'sort_by(.ts) | .[]' 2>/dev/null || true
}

# CHECK-THEN-APPEND UNDER ONE LOCK. Deduping a re-ask and refusing to answer
# a closed question both read the mailbox and then write it; two processes
# (two orchestrators, a double-click, two dashboard tabs) could each read
# "open" before either wrote. One flock per mailbox, held across both steps -
# a separate file from the one _inbox_append locks, so the nested append does
# not deadlock against it.
_decide_locked() { # <ws> <cmd...>
  local lock; lock="$(_inbox_dir)/$1.decide.lock"; shift
  mkdir -p "$(_inbox_dir)"
  if have flock; then ( flock 8; "$@" ) 8>>"$lock"; else "$@"; fi
}

cmd_decide() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    ask)     _decide_ask "$@" ;;
    list)    _decide_list "$@" ;;
    answer)  _decide_answer "$@" ;;
    drop)    _decide_drop "$@" ;;
    withdraw) _decide_withdraw "$@" ;;
    migrate) _decide_migrate "$@" ;;
    help|--help|-h) _decide_usage ;;
    *) c_err "cel decide: unknown subcommand '$sub'"; _decide_usage; return 2 ;;
  esac
}

_decide_usage() {
  cat <<'EOS'
cel decide - the owner's one queue of decisions, across every workspace

  cel decide ask --title <one line> [--option <label>::<tradeoff>]... [--recommend <n>]
                 --context <what/why, options, recommendation, if unanswered> [--blocks <what waits on it>] [--urgent] [--workspace w]
                 [--supersedes <id>]
      file a question for the owner; prints its id. The asker is who you are
      (cel inbox whoami), never a flag. Re-asking the same title updates the
      open record instead of adding a second one. --urgent is for live risk,
      money, or work that is blocked now: the dashboard sorts it first.
      --supersedes closes your own older question <id> as replaced by this
      one, in the same write. --context is required: at least 120 characters
      of plain prose (URLs do not count) saying what happened and why it needs
      the owner now, what each option does in practice, what you recommend
      and why, and what happens if nobody answers.
  cel decide list [--json]
      every open owner decision in every workspace, oldest first.
  cel decide answer <id> <option-number|"free text"|--text <text>|--option <n>> [--by who]
      digits pick that option when it exists, else they are the answer; resolve it and mail `ANSWER to "<title>": ...` to the asker's inbox.
  cel decide drop <id> --why <text> [--by who]
      resolve a question that no longer matters; the asker is told why.
  cel decide withdraw <id> --why <text>
      the ASKER closes its own question (settled in chat, moot after a merge).
      Who you are is derived (cel inbox whoami); nobody else may withdraw it.
  cel decide migrate [--apply]
      resolve open steward REMINDER items (never real decisions). A dry run
      unless --apply is given.
EOS
}

_decide_ask() {
  local title="" recommend="" context="" blocks="" ws="" opts="[]" o label trade urgent=false supersedes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --option)
        o="$2"; label="${o%%::*}"; trade=""
        [ "$label" != "$o" ] && trade="${o#*::}"
        opts="$(jq -c --arg l "$label" --arg t "$trade" '. + [{label: $l, tradeoff: $t}]' <<< "$opts")"
        shift 2 ;;
      --recommend) recommend="$2"; shift 2 ;;
      --context) context="$2"; shift 2 ;;
      --blocks) blocks="$2"; shift 2 ;;
      --urgent) urgent=true; shift ;;
      --workspace) ws="$2"; shift 2 ;;
      --supersedes) supersedes="$2"; shift 2 ;;
      *) die "cel decide ask: unknown argument '$1'" ;;
    esac
  done
  [ -n "$title" ] || die "cel decide ask: --title is required"
  # CEL-113: THE OWNER DECIDES FROM THE CARD. Most open questions once carried
  # a title, two option labels and at best a bare URL, and the owner had to go
  # digging before answering. So a question without real prose is refused: a
  # URL may ride along, but it does not count toward the minimum.
  local prose
  prose="$(printf '%s' "$context" | sed -E 's#[a-z]+://[^[:space:]]+##g' | tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//')"
  if [ "${#prose}" -lt 120 ]; then
    die "cel decide ask: --context needs real substance (at least 120 characters of prose; a bare URL does not count). Say, in plain English: what happened and why it needs the owner now; what each option does in practice (cost, risk, what breaks or waits); what you recommend and why; what happens if nobody answers. A URL may be added on top."
  fi
  if [ -n "$recommend" ]; then
    case "$recommend" in *[!0-9]*) die "cel decide ask: --recommend takes an option number" ;; esac
    [ "$recommend" -ge 1 ] && [ "$recommend" -le "$(jq length <<< "$opts")" ] \
      || die "cel decide ask: --recommend $recommend names no option"
  fi
  local wsname
  wsname="$(_inbox_ws_here "$ws")" || die "cel decide ask: standing here names no workspace - pass --workspace"
  # A typo here used to create a fresh mailbox no list would ever read.
  _inbox_ws_known "$wsname" || die "cel decide ask: no workspace named '$wsname' is registered here (cel ws list)"
  local asker; asker="$(_inbox_me)"
  local fields
  fields="$(jq -nc --arg title "$title" --argjson options "$opts" --arg rec "$recommend" \
    --arg context "$context" --arg blocks "$blocks" --arg asker "$asker" --argjson urgent "$urgent" \
    --arg sup "$supersedes" \
    '{title: $title, options: $options, recommended: (if $rec == "" then null else ($rec | tonumber) end),
      context: $context, blocks: $blocks, asker: $asker, message: $title}
     # urgent only when asked: a re-ask that omits it must not clear it
     + (if $urgent then {urgent: true} else {} end)
     + (if $sup != "" then {supersedes: $sup} else {} end)')"
  _decide_locked "$wsname" _decide_ask_write "$wsname" "$asker" "$title" "$fields" "$supersedes"
}

_decide_ask_write() { # <ws> <asker> <title> <fields-json> [supersedes-id]
  local wsname="$1" asker="$2" title="$3" fields="$4" sup="${5:-}"
  local f; f="$(_inbox_file "$wsname")"
  # SUPERSEDING IS CHECKED BEFORE ANYTHING IS WRITTEN, under the same lock: a
  # refused --supersedes must not leave the new question filed beside the old.
  # Only the asker's own open question in this mailbox can be replaced.
  if [ -n "$sup" ]; then
    decide_open_json "$wsname" | jq -e --arg id "$sup" --arg a "$asker" \
      'select(.id == $id and .asker == $a)' >/dev/null 2>&1 \
      || { c_err "cel decide ask: --supersedes $sup names no open question of yours in $wsname" >&2; return 1; }
  fi
  # ONE RECORD PER QUESTION: same asker, same title, still open.
  local ref=""
  ref="$(decide_open_json "$wsname" | jq -r --arg a "$asker" --arg t "$title" \
    'select(.asker == $a and .title == $t) | .id' | sed -n 1p)"
  local id; id="$(date +%s%N)"
  # A same-title re-ask updates in place and files no new question, so there
  # is nothing to supersede WITH: refuse rather than leave the old one open.
  if [ -n "$ref" ] && [ -n "$sup" ]; then
    c_err "cel decide ask: '$title' is already open as $ref - a re-ask updates it in place and cannot supersede $sup; withdraw $sup instead" >&2
    return 1
  fi
  if [ -n "$ref" ]; then
    _inbox_append "$f" "$(jq -c --arg id "$id" --arg ts "$(date -Is)" --arg ref "$ref" --arg from "$asker" \
      '. + {id: $id, ts: $ts, to: "owner", from: $from, kind: "update", ref: $ref}' <<< "$fields")"
    c_ok "updated open decision $ref in $wsname" >&2
    printf '%s\n' "$ref"; return 0
  fi
  local rec
  rec="$(jq -c --arg id "$id" --arg ts "$(date -Is)" --arg from "$asker" --arg cwd "$PWD" \
    '. + {id: $id, ts: $ts, to: "owner", from: $from, kind: "decision", fp: ("decide:" + .title), cwd: $cwd}' <<< "$fields")"
  if [ -n "$sup" ]; then
    # ONE WRITE: the new question and the old one's resolution land together,
    # so no reader ever sees both open or neither.
    rec="$rec"$'\n'"$(jq -nc --arg id "$(date +%s%N)" --arg ts "$(date -Is)" --arg ref "$sup" \
      --arg by "$asker" --arg new "$id" \
      '{id: $id, ts: $ts, kind: "resolution", ref: $ref, by: $by, to: "owner",
        superseded_by: $new, message: ("superseded by " + $new)}')"
  fi
  _inbox_append "$f" "$rec"
  c_ok "filed decision for the owner in $wsname$([ -n "$sup" ] && printf ' (supersedes %s)' "$sup")" >&2
  printf '%s\n' "$id"
}

_decide_age() { # <secs>
  local s="$1"
  if [ "$s" -ge 86400 ]; then printf '%dd' $((s / 86400))
  elif [ "$s" -ge 3600 ]; then printf '%dh' $((s / 3600))
  else printf '%dm' $((s / 60)); fi
}

_decide_list() {
  local json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) die "cel decide list: unknown argument '$1'" ;;
    esac
  done
  local all; all="$(decide_all_json)"
  if [ "$json" -eq 1 ]; then [ -n "$all" ] && printf '%s\n' "$all"; return 0; fi
  [ -n "$all" ] || { c_ok "no open owner decisions in any workspace" >&2; return 0; }
  local line age
  while IFS= read -r line; do
    age="$(_decide_age "$(jq -r '.age_secs' <<< "$line")")"
    jq -r --arg age "$age" '
      "[\(.id)] \(.workspace) \(.asker) \($age): \(if .urgent then "URGENT " else "" end)\(.title)",
      ((.recommended // 0) as $r | .options | to_entries[]
        | "    \(.key + 1). \(.value.label)\(if .value.tradeoff != "" then " - " + .value.tradeoff else "" end)\(if .key + 1 == $r then "  (recommended)" else "" end)"),
      (if (.blocks // "") != "" then "    blocks: \(.blocks)" else empty end),
      (if (.context // "") != "" then "    context: \(.context)" else empty end)' <<< "$line"
  done <<< "$all"
}

# The record for <id> in whichever workspace holds it.
_decide_find() { # <id> -> record json
  decide_all_json | jq -c --arg id "$1" 'select(.id == $id)' | sed -n 1p
}

# Resolve the record and mail the asker. One function so answer and drop
# cannot drift apart on what "closed" means.
_decide_close() { # <record> <by> <field> <value> <message-to-asker>
  local ws; ws="$(jq -r .workspace <<< "$1")"
  _decide_locked "$ws" _decide_close_locked "$@"
}

_decide_close_locked() {
  local rec="$1" by="$2" field="$3" value="$4" msg="$5" ws id asker f
  ws="$(jq -r .workspace <<< "$rec")"; id="$(jq -r .id <<< "$rec")"; asker="$(jq -r .asker <<< "$rec")"
  f="$(_inbox_file "$ws")"
  # still open NOW, under the lock: whoever got here first answered it
  decide_open_json "$ws" | jq -e --arg id "$id" 'select(.id == $id)' >/dev/null 2>&1 \
    || { c_err "cel decide: $id was already answered or dropped" >&2; return 1; }
  _inbox_append "$f" "$(jq -nc --arg id "$(date +%s%N)" --arg ts "$(date -Is)" --arg ref "$id" \
    --arg by "$by" --arg k "$field" --arg v "$value" \
    '{id: $id, ts: $ts, kind: "resolution", ref: $ref, by: $by, to: "owner", message: ("resolved by " + $by)} + {($k): $v}')"
  cmd_inbox send "$asker" "$msg" --from "$by" --workspace "$ws" --kind status >/dev/null 2>&1 \
    || c_warn "resolved $id but could not mail $asker in $ws" >&2
  c_ok "$id resolved; told $asker in $ws" >&2
}

_decide_answer() {
  [ $# -ge 2 ] || die "usage: cel decide answer <id> <option-number|\"free text\"|--text <text>> [--by who]"
  local id="$1" ans="" by="" free=0; shift
  # --option <n> is strict (the dashboard's buttons): a number naming no
  # option is refused rather than recorded as the text "9".
  if [ "$1" = --text ]; then free=1; ans="${2:-}"; shift 2 || true
  elif [ "$1" = --option ]; then free=2; ans="${2:-}"; shift 2 || true
  else ans="$1"; shift; fi
  [ -n "$ans" ] || die "cel decide answer: an answer is required"
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) by="$2"; shift 2 ;;
      *) die "cel decide answer: unknown argument '$1'" ;;
    esac
  done
  [ -n "$by" ] || by="$(_inbox_me)"
  local rec; rec="$(_decide_find "$id")"
  [ -n "$rec" ] || die "cel decide answer: no open owner decision with id $id"
  # All digits is an option number only when that option exists; otherwise
  # it is the answer itself ("2026"). --text says so outright.
  local text="$ans" picked=""
  if [ "$free" -eq 2 ]; then
    case "$ans" in *[!0-9]*) die "cel decide answer: --option takes a number" ;; esac
    text="$(jq -r --argjson n "$ans" 'if $n >= 1 then (.options[$n - 1].label // empty) else empty end' <<< "$rec")"
    [ -n "$text" ] || die "cel decide answer: decision $id has no option $ans"
  elif [ "$free" -eq 0 ]; then
    case "$ans" in
      *[!0-9]*) ;;
      *) picked="$(jq -r --argjson n "$ans" 'if $n >= 1 then (.options[$n - 1].label // empty) else empty end' <<< "$rec")"
         [ -n "$picked" ] && text="$picked" ;;
    esac
  fi
  local title; title="$(jq -r .title <<< "$rec")"
  _decide_close "$rec" "$by" answer "$text" "ANSWER to \"$title\": $text (decision $id, from $by)"
}

_decide_drop() {
  [ $# -ge 1 ] || die "usage: cel decide drop <id> --why <text> [--by who]"
  local id="$1" why="" by=""; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --why) why="$2"; shift 2 ;;
      --by) by="$2"; shift 2 ;;
      *) die "cel decide drop: unknown argument '$1'" ;;
    esac
  done
  [ -n "$why" ] || die "cel decide drop: --why is required"
  [ -n "$by" ] || by="$(_inbox_me)"
  local rec; rec="$(_decide_find "$id")"
  [ -n "$rec" ] || die "cel decide drop: no open owner decision with id $id"
  local title; title="$(jq -r .title <<< "$rec")"
  _decide_close "$rec" "$by" dropped "$why" "DROPPED \"$title\": $why (decision $id, by $by)"
}

# THE ASKER CAN CLOSE ITS OWN QUESTION (CEL-101). Questions settled in an
# orchestrator's chat or made moot by a merge sat in the owner's panel until
# the owner typed a reason to drop them; the one party that knew they were
# stale had no way to say so. Identity is derived, never a flag: --by here
# would let anyone close anyone's question.
_decide_withdraw() {
  [ $# -ge 1 ] || die "usage: cel decide withdraw <id> --why <text>"
  local id="$1" why=""; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --why) why="$2"; shift 2 ;;
      *) die "cel decide withdraw: unknown argument '$1'" ;;
    esac
  done
  [ -n "$why" ] || die "cel decide withdraw: --why is required"
  local me; me="$(_inbox_me)"
  local rec; rec="$(_decide_find "$id")"
  [ -n "$rec" ] || die "cel decide withdraw: no open owner decision with id $id"
  [ "$(jq -r .asker <<< "$rec")" = "$me" ] \
    || die "cel decide withdraw: $id was asked by $(jq -r .asker <<< "$rec"), not $me - only the asker may withdraw it"
  local ws; ws="$(jq -r .workspace <<< "$rec")"
  _decide_locked "$ws" _decide_withdraw_locked "$ws" "$id" "$me" "$why"
}

_decide_withdraw_locked() { # <ws> <id> <asker> <why>
  local f; f="$(_inbox_file "$1")"
  decide_open_json "$1" | jq -e --arg id "$2" 'select(.id == $id)' >/dev/null 2>&1 \
    || { c_err "cel decide: $2 was already answered or dropped" >&2; return 1; }
  # no mail: the asker is the one closing it
  _inbox_append "$f" "$(jq -nc --arg id "$(date +%s%N)" --arg ts "$(date -Is)" --arg ref "$2" \
    --arg by "$3" --arg why "$4" \
    '{id: $id, ts: $ts, kind: "resolution", ref: $ref, by: $by, to: "owner",
      withdrawn: $why, message: ("withdrawn by " + $by + ": " + $why)}')"
  c_ok "$2 withdrawn" >&2
}

# REMINDERS ARE NOT DECISIONS. The steward used to file its nags as open
# `blocked` items, and each one was then counted as another thing the owner
# had to decide. Recognised by sender AND text, so a real steward alarm (a
# stalled worker, an exhausted provider) stays open.
_DECIDE_REMINDER_RE='UNRESOLVED decision|open decision\(s\)|in your celestial inbox|^REMINDER|REMINDER for'
_decide_migrate() {
  local apply=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      --dry-run) apply=0; shift ;;
      *) die "cel decide migrate: unknown argument '$1'" ;;
    esac
  done
  local ws f n=0 id to msg
  for ws in $(_decide_all_ws); do
    f="$(_inbox_file "$ws")"
    [ -f "$f" ] || continue
    while IFS=$'\t' read -r id to msg; do
      [ -n "$id" ] || continue
      n=$((n + 1))
      if [ "$apply" -eq 1 ]; then
        _inbox_append_resolution "$f" "$id" "$to" "cel-decide-migrate"
        printf 'resolved [%s] %s %s: %s\n' "$ws" "$id" "$to" "$msg"
      else
        printf 'would resolve [%s] %s %s: %s\n' "$ws" "$id" "$to" "$msg"
      fi
    done < <(jq -rs --arg re "$_DECIDE_REMINDER_RE" '
        ([.[] | select(.kind == "resolution") | .ref]) as $done
        | .[] | select(.kind == "decision" or .kind == "blocked")
        | select(.from == "steward")
        | select((.fp // "" | startswith("remind-")) or ((.message // "") | test($re)))
        | select([.id] | inside($done) | not)
        | [.id, .to, ((.message // "") | split("\n")[0] | .[0:120])] | @tsv' "$f" 2>/dev/null || true)
  done
  if [ "$apply" -eq 1 ]; then c_ok "resolved $n reminder item(s)" >&2
  else c_ok "$n reminder item(s) would be resolved - rerun with --apply" >&2; fi
}
