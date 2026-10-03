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
        | (if $u then . + ($u | {title, options, recommended, context, blocks}) + {updated: $u.ts} else . end)
        | . + {workspace: $ws,
               age_secs: (($now | tonumber) - (.ts | _epoch))} ]
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

cmd_decide() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    ask)     _decide_ask "$@" ;;
    list)    _decide_list "$@" ;;
    answer)  _decide_answer "$@" ;;
    drop)    _decide_drop "$@" ;;
    migrate) _decide_migrate "$@" ;;
    help|--help|-h) _decide_usage ;;
    *) c_err "cel decide: unknown subcommand '$sub'"; _decide_usage; return 2 ;;
  esac
}

_decide_usage() {
  cat <<'EOS'
cel decide - the owner's one queue of decisions, across every workspace

  cel decide ask --title <one line> [--option <label>::<tradeoff>]... [--recommend <n>]
                 [--context <url-or-path>] [--blocks <what waits on it>] [--workspace w]
      file a question for the owner; prints its id. The asker is who you are
      (cel inbox whoami), never a flag. Re-asking the same title updates the
      open record instead of adding a second one.
  cel decide list [--json]
      every open owner decision in every workspace, oldest first.
  cel decide answer <id> <option-number|"free text"> [--by who]
      resolve it and mail `ANSWER to "<title>": ...` to the asker's inbox.
  cel decide drop <id> --why <text> [--by who]
      resolve a question that no longer matters; the asker is told why.
  cel decide migrate [--apply]
      resolve open steward REMINDER items (never real decisions). A dry run
      unless --apply is given.
EOS
}

_decide_ask() {
  local title="" recommend="" context="" blocks="" ws="" opts="[]" o label trade
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
      --workspace) ws="$2"; shift 2 ;;
      *) die "cel decide ask: unknown argument '$1'" ;;
    esac
  done
  [ -n "$title" ] || die "cel decide ask: --title is required"
  if [ -n "$recommend" ]; then
    case "$recommend" in *[!0-9]*) die "cel decide ask: --recommend takes an option number" ;; esac
    [ "$recommend" -ge 1 ] && [ "$recommend" -le "$(jq length <<< "$opts")" ] \
      || die "cel decide ask: --recommend $recommend names no option"
  fi
  local wsname
  wsname="$(_inbox_ws_here "$ws")" || die "cel decide ask: standing here names no workspace - pass --workspace"
  local asker; asker="$(_inbox_me)"
  local f; f="$(_inbox_file "$wsname")"
  local fields
  fields="$(jq -nc --arg title "$title" --argjson options "$opts" --arg rec "$recommend" \
    --arg context "$context" --arg blocks "$blocks" --arg asker "$asker" \
    '{title: $title, options: $options, recommended: (if $rec == "" then null else ($rec | tonumber) end),
      context: $context, blocks: $blocks, asker: $asker, message: $title}')"
  # ONE RECORD PER QUESTION: same asker, same title, still open.
  local ref=""
  ref="$(decide_open_json "$wsname" | jq -r --arg a "$asker" --arg t "$title" \
    'select(.asker == $a and .title == $t) | .id' | sed -n 1p)"
  local id; id="$(date +%s%N)"
  if [ -n "$ref" ]; then
    _inbox_append "$f" "$(jq -c --arg id "$id" --arg ts "$(date -Is)" --arg ref "$ref" --arg from "$asker" \
      '. + {id: $id, ts: $ts, to: "owner", from: $from, kind: "update", ref: $ref}' <<< "$fields")"
    c_ok "updated open decision $ref in $wsname" >&2
    printf '%s\n' "$ref"; return 0
  fi
  _inbox_append "$f" "$(jq -c --arg id "$id" --arg ts "$(date -Is)" --arg from "$asker" --arg cwd "$PWD" \
    '. + {id: $id, ts: $ts, to: "owner", from: $from, kind: "decision", fp: ("decide:" + .title), cwd: $cwd}' <<< "$fields")"
  c_ok "filed decision for the owner in $wsname" >&2
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
      "[\(.id)] \(.workspace) \(.asker) \($age): \(.title)",
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
  local rec="$1" by="$2" field="$3" value="$4" msg="$5" ws id asker f
  ws="$(jq -r .workspace <<< "$rec")"; id="$(jq -r .id <<< "$rec")"; asker="$(jq -r .asker <<< "$rec")"
  f="$(_inbox_file "$ws")"
  _inbox_append "$f" "$(jq -nc --arg id "$(date +%s%N)" --arg ts "$(date -Is)" --arg ref "$id" \
    --arg by "$by" --arg k "$field" --arg v "$value" \
    '{id: $id, ts: $ts, kind: "resolution", ref: $ref, by: $by, to: "owner", message: ("resolved by " + $by)} + {($k): $v}')"
  cmd_inbox send "$asker" "$msg" --from "$by" --workspace "$ws" --kind status >/dev/null 2>&1 \
    || c_warn "resolved $id but could not mail $asker in $ws" >&2
  c_ok "$id resolved; told $asker in $ws" >&2
}

_decide_answer() {
  [ $# -ge 2 ] || die "usage: cel decide answer <id> <option-number|\"free text\"> [--by who]"
  local id="$1" ans="$2" by=""; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) by="$2"; shift 2 ;;
      *) die "cel decide answer: unknown argument '$1'" ;;
    esac
  done
  [ -n "$by" ] || by="$(_inbox_me)"
  local rec; rec="$(_decide_find "$id")"
  [ -n "$rec" ] || die "cel decide answer: no open owner decision with id $id"
  local text="$ans"
  case "$ans" in
    ''|*[!0-9]*) ;;
    *) text="$(jq -r --argjson n "$ans" '.options[$n - 1].label // empty' <<< "$rec")"
       [ -n "$text" ] || die "cel decide answer: option $ans does not exist" ;;
  esac
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
