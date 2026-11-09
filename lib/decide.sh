# shellcheck shell=bash
# cel decide - one queue for every decision an orchestrator needs from the owner.
#
# A decision is a RECORD in the workspace's inbox JSONL, not a question left at
# the end of a chat turn or mixed into root mail: `kind: decision`, addressed
# to `owner`, with structured fields. `list` reads every workspace, `answer`
# resolves it and mails the answer to the asker (its inbox hook wakes it -
# nothing is ever typed into a pane), and the steward stops nagging.
[ -n "${_CEL_DECIDE:-}" ] && return 0
_CEL_DECIDE=1
# shellcheck source=lib/inbox.sh
. "${BASH_SOURCE[0]%/*}/inbox.sh"
# shellcheck source=lib/identity.sh
. "${BASH_SOURCE[0]%/*}/identity.sh"

# ROUTING (people: in workspace.yaml). A question names a topic; the topic is
# a role; the route is the people holding that role for the asker's product,
# else the workspace's owners, computed once at ask time and kept on the
# record as `route: {role, product, people}`. `to` stays "owner", so every
# reader that knew decisions before routing still finds them. With no
# people: (or nobody holding the role and no owner) there is no route and
# nothing below changes: anyone answers, --by is free text.
_DECIDE_TOPICS="product qa design release merge owner"
_decide_topic_role() { # <topic> -> the people role it is routed to
  case "$1" in
    product) printf product-lead ;; merge) printf approver ;;
    qa|design|release|owner) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

# The asker's product: its launch's CEL_PRODUCT, else the longest declared
# product whose name prefixes the mailbox (<p>-orch, <p>-lead, <p>-<lane>).
_decide_asker_product() { # <wsdir> <asker>
  if [ -n "${CEL_PRODUCT:-}" ]; then printf '%s' "$CEL_PRODUCT"; return 0; fi
  local p best=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$2" in "$p"-*) [ "${#p}" -le "${#best}" ] || best="$p" ;; esac
  done < <(ws_product_names "$1" 2>/dev/null)
  printf '%s' "$best"
}

_decide_route() { # <ws> <asker> <topic> -> route json, or nothing
  local wsdir role product holders
  wsdir="$(registry_path "$1" 2>/dev/null || true)"
  [ -n "$wsdir" ] && [ -f "$wsdir/workspace.yaml" ] || return 0
  [ "$(ws_people_json "$wsdir" 2>/dev/null || printf '[]')" != "[]" ] || return 0
  role="$(_decide_topic_role "$3")" || return 0
  product="$(_decide_asker_product "$wsdir" "$2")"
  holders="$(ws_role_holders "$wsdir" "$product" "$role" 2>/dev/null || true)"
  [ -n "$holders" ] || holders="$(ws_role_holders "$wsdir" "$product" owner 2>/dev/null || true)"
  [ -n "$holders" ] || return 0
  jq -nc --arg r "$role" --arg p "$product" --arg h "$holders" \
    '{role: $r, product: (if $p == "" then null else $p end), people: ($h | split("\n") | map(select(. != "")))}'
}

# What THIS LOGIN is to each open decision, the one rule `list`, the
# dashboard and `answer|drop` all read: `me` (its person in that workspace,
# or null), `mine` (unrouted, or routed to me) and `answerable` (unrouted, or
# me holds the route, or me is an owner - workspace-wide or for the route's
# product). An unrouted decision reads topic `owner`.
_decide_annotate() { # <records, one per line> -> the same records, annotated
  local ws wsdir me people
  for ws in $(jq -r '.workspace' <<< "$1" | awk 'NF && !seen[$0]++'); do
    wsdir="$(registry_path "$ws" 2>/dev/null || true)"; me=""; people='[]'
    if [ -n "$wsdir" ] && [ -f "$wsdir/workspace.yaml" ]; then
      me="$(ws_me "$wsdir")"
      people="$(ws_people_json "$wsdir" 2>/dev/null || true)"; [ -n "$people" ] || people='[]'
    fi
    jq -c --arg ws "$ws" --arg me "$me" --argjson people "$people" '
      select(.workspace == $ws) | . as $d
      | (($d.route.people // []) | length > 0) as $routed
      | ($me != "" and (($d.route.people // []) | index($me)) != null) as $held
      | ($me != "" and ([$people[]? | objects | select(.id == $me)
          | ((.roles // []) + ((.products // {})[$d.route.product // ""] // []))[]?] | index("owner")) != null) as $owner
      | $d + {topic: ($d.topic // "owner"), me: (if $me == "" then null else $me end),
              mine: (($routed | not) or $held), answerable: (($routed | not) or $held or $owner)}' <<< "$1"
  done
}

# Who the resolution records, or a refusal. An agent never answers or drops
# an owner question (core relays the owner's word only on an unrouted one).
# With me: set the answer is recorded under me, and --by may only repeat it;
# a routed question is answered by its people, or by an owner as
# "<id> (owner)". With no me: --by is free text, as before, on an unrouted
# question only.
_decide_by() { # <verb> <record> <--by value or ""> -> by
  local verb="$1" rec="$2" by="$3" ann asker id role me routed where
  ann="$(_decide_annotate "$rec")"
  asker="$(jq -r .asker <<< "$ann")"; id="$(jq -r .id <<< "$ann")"
  routed="$(jq -r '(.route.people // []) | length > 0' <<< "$ann")"
  role="$(cel_agent_role)"
  case "$role" in
    "") ;;
    core|console)
      [ "$routed" = false ] || die "cel decide $verb: an agent does not answer an owner question - $asker waits for a person (core relays the owner's word only on an unrouted one)" ;;
    *) die "cel decide $verb: an agent does not answer an owner question - $asker waits for a person" ;;
  esac
  me="$(jq -r '.me // ""' <<< "$ann")"
  if [ -n "$me" ]; then
    [ -z "$by" ] || [ "$by" = "$me" ] \
      || die "cel decide $verb: --by $by is not this login's person (me: $me) - an answer is recorded under who gave it"
    by="$me"
  fi
  [ -n "$by" ] || by="$(_inbox_me)"
  if [ "$routed" = true ]; then
    where="$(jq -r '.route | "\(.role)\(if (.product // "") != "" then " for " + .product else "" end) (\(.people | join(", ")))"' <<< "$ann")"
    [ -n "$me" ] || die "cel decide $verb: $id is routed to $where; this login names no person (no me: in its workspace.local.yaml) - only they or an owner answer it"
    jq -e '.answerable' <<< "$ann" >/dev/null \
      || die "cel decide $verb: $id is routed to $where; this login is $me - only they or an owner answer it"
    jq -e --arg m "$me" '.route.people | index($m) != null' <<< "$ann" >/dev/null || by="$me (owner)"
  fi
  printf '%s' "$by"
}

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
        | (if $u then . + ($u | {title, options, recommended, context, blocks}) + (if ($u | has("prs")) then {prs: $u.prs} else {} end) + (if $u.urgent == true then {urgent: true} else {} end) + {updated: $u.ts} else . end)
        # the latest confirm (still needs the owner), counted only
        # when it is newer than the last change to the question
        | ([$all[] | select(.kind == "confirm" and .ref == $i)] | last) as $c
        | (if $c and (($c.ts | _epoch) >= ((.updated // .ts) | _epoch))
           then {confirmed: $c.ts, confirmed_secs: (($now | tonumber) - ($c.ts | _epoch))} else {} end) as $cf
        | . + $cf
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
    confirm) _decide_confirm "$@" ;;
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
                 [--supersedes <id>] [--pr <repo>#<num>]... [--topic product|qa|design|release|merge|owner]
      file a question for the owner; prints its id. The asker is who you are
      (cel inbox whoami), never a flag. Re-asking the same title updates the
      open record instead of adding a second one. --urgent is for live risk,
      money, or work that is blocked now: the dashboard sorts it first.
      --supersedes closes your own older question <id> as replaced by this
      one, in the same write. --context is required: at least 120 characters
      of plain prose (URLs do not count) saying what happened and why it needs
      the owner now, what each option does in practice, what you recommend
      and why, and what happens if nobody answers. --pr links a PR the
      question blocks (repeatable): while it is open the steward does not
      nudge that PR as a worker finding. --topic (default owner) routes it,
      when the workspace declares people:, to whoever holds that role for
      your product (product-lead, qa, design, release, approver, owner), else
      to its owners; only they, or an owner, may answer it.
  cel decide list [--json] [--workspace w] [--asker <alias>] [--mine | --for <id>] [--topic <t>]
      every open owner decision in every workspace, oldest first; --workspace
      and --asker narrow it (an agent's own questions: --asker <product>-orch).
      --mine (this login's person, me: in workspace.local.yaml) and --for <id>
      keep the ones routed to that person, plus the unrouted ones; --topic
      keeps one topic (an unrouted question is topic owner).
  cel decide answer <id> <option-number|"free text"|--text <text>|--option <n>> [--by who]
      digits pick that option when it exists, else they are the answer; resolve it and mail `ANSWER to "<title>": ...` to the asker's inbox.
      A person answers, never an agent. With me: set the answer is recorded
      as me (--by may only repeat it); a routed question is answered by its
      people, or by an owner, recorded as "<id> (owner)".
  cel decide drop <id> --why <text> [--by who]
      resolve a question that no longer matters; the asker is told why. Who
      may drop it is who may answer it.
  cel decide withdraw <id> --why <text>
      the ASKER closes its own question (settled in chat, moot after a merge).
      Who you are is derived (cel inbox whoami); nobody else may withdraw it.
  cel decide confirm <id>... [--why <text>]
      the asker (or an orchestrator) says the question still needs the owner;
      the steward's stale reminder skips it for 7 days unless it changes.
  cel decide migrate [--apply]
      resolve open steward REMINDER items (never real decisions). A dry run
      unless --apply is given.
EOS
}

_decide_ask() {
  local title="" recommend="" context="" blocks="" ws="" opts="[]" o label trade urgent=false supersedes="" prs="[]" topic=owner
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
      --topic) topic="${2:-}"; shift 2 ;;
      --pr)
        [[ "${2:-}" =~ ^[^#[:space:]]+#[0-9]+$ ]] || die "cel decide ask: --pr takes <repo>#<num>, got '${2:-}'"
        prs="$(jq -c --arg r "$2" '. + [{ref: $r}]' <<< "$prs")"; shift 2 ;;
      *) die "cel decide ask: unknown argument '$1'" ;;
    esac
  done
  [ -n "$title" ] || die "cel decide ask: --title is required"
  _decide_topic_role "$topic" >/dev/null || die "cel decide ask: --topic must be one of $_DECIDE_TOPICS (got '$topic')"
  # THE OWNER DECIDES FROM THE CARD, so a question without real prose is
  # refused: a URL may ride along, but it does not count toward the minimum.
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
  # A typo must not create a fresh mailbox no list would ever read.
  _inbox_ws_known "$wsname" || die "cel decide ask: no workspace named '$wsname' is registered here (cel ws list)"
  local asker; asker="$(_inbox_me)"
  # Each --pr gets the PR's URL when the workspace knows the repo, so the
  # dashboard card can link straight to it. The workspace helpers are loaded
  # here, not at the top, because `cel decide` otherwise runs without them.
  if [ "$prs" != "[]" ]; then
    # shellcheck source=lib/registry.sh
    . "${BASH_SOURCE[0]%/*}/registry.sh"
    # shellcheck source=lib/workspace.sh
    . "${BASH_SOURCE[0]%/*}/workspace.sh"
    local wsd; wsd="$(registry_path "$wsname" 2>/dev/null || true)"
    if [ -n "$wsd" ] && [ -f "$wsd/workspace.yaml" ]; then
      local r slug out="[]"
      while IFS= read -r r; do
        slug="$(ws_repo_get "$wsd" "${r%%#*}" url 2>/dev/null \
          | sed -E 's#^git@[^:]+:##; s#^(https?|ssh)://[^/]+/##; s#\.git$##; s#/$##' || true)"
        out="$(jq -c --arg r "$r" --arg s "$slug" '. + [{ref: $r} + (if $s != "" then
          {url: ("https://github.com/" + $s + "/pull/" + ($r | split("#") | last))} else {} end)]' <<< "$out")"
      done < <(jq -r '.[].ref' <<< "$prs")
      prs="$out"
    fi
  fi
  # the route is fixed now, at ask time: a later change to people: does not
  # move a question already asked
  local fields route; route="$(_decide_route "$wsname" "$asker" "$topic")"
  fields="$(jq -nc --arg title "$title" --argjson options "$opts" --arg rec "$recommend" \
    --arg context "$context" --arg blocks "$blocks" --arg asker "$asker" --argjson urgent "$urgent" \
    --arg sup "$supersedes" --argjson prs "$prs" --arg topic "$topic" --arg route "$route" \
    '{title: $title, options: $options, recommended: (if $rec == "" then null else ($rec | tonumber) end),
      context: $context, blocks: $blocks, asker: $asker, message: $title}
     # urgent only when asked: a re-ask that omits it must not clear it
     + (if $urgent then {urgent: true} else {} end)
     + (if $sup != "" then {supersedes: $sup} else {} end)
     # always present, even empty: a re-ask is the current word from the asker on
     # which PRs wait, so one that drops --pr must unlink them
     + {prs: $prs}
     + {topic: $topic} + (if $route != "" then {route: ($route | fromjson)} else {} end)')"
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
  local json=0 ws="" asker="" mine=0 for="" topic=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --workspace) ws="${2:-}"; shift 2 ;;
      --asker) asker="${2:-}"; shift 2 ;;
      --mine) mine=1; shift ;;
      --for) for="${2:-}"; [ -n "$for" ] || die "cel decide list: --for takes a person id"; shift 2 ;;
      --topic) topic="${2:-}"; shift 2 ;;
      *) die "cel decide list: unknown argument '$1'" ;;
    esac
  done
  [ -z "$topic" ] || _decide_topic_role "$topic" >/dev/null \
    || die "cel decide list: --topic must be one of $_DECIDE_TOPICS (got '$topic')"
  [ "$mine" -eq 0 ] || [ -z "$for" ] || die "cel decide list: --mine and --for are one filter - pick one"
  if [ "$mine" -eq 1 ]; then
    local w d named=0
    for w in ${ws:-$(_decide_all_ws)}; do
      d="$(registry_path "$w" 2>/dev/null || true)"
      [ -z "$d" ] || [ -z "$(ws_me "$d")" ] || { named=1; break; }
    done
    [ "$named" -eq 1 ] || die "cel decide list --mine: this login names no person (no me: in its workspace.local.yaml) - use --for <id>"
  fi
  local all; all="$(decide_all_json)"
  # Narrowed to one workspace and/or one asker: an agent's own questions.
  if [ -n "$all" ] && { [ -n "$ws" ] || [ -n "$asker" ]; }; then
    all="$(jq -c --arg w "$ws" --arg a "$asker" \
      'select(($w == "" or .workspace == $w) and ($a == "" or .asker == $a))' <<< "$all")"
  fi
  [ -z "$all" ] || all="$(_decide_annotate "$all")"
  # Narrowed to a person (routed to them, or to nobody) and/or a topic.
  if [ -n "$all" ] && { [ "$mine" -eq 1 ] || [ -n "$for" ] || [ -n "$topic" ]; }; then
    all="$(jq -c --argjson mine "$mine" --arg f "$for" --arg t "$topic" '
      select(($mine == 0 or .mine)
        and ($f == "" or ((.route.people // []) | length == 0) or ((.route.people // []) | index($f)) != null)
        and ($t == "" or .topic == $t))' <<< "$all")"
  fi
  if [ "$json" -eq 1 ]; then [ -n "$all" ] && printf '%s\n' "$all"; return 0; fi
  local where=" in any workspace"; [ -z "$ws" ] || where=" in $ws"
  [ -n "$all" ] || { c_ok "no open owner decisions${asker:+ from $asker}$where" >&2; return 0; }
  local line age
  while IFS= read -r line; do
    age="$(_decide_age "$(jq -r '.age_secs' <<< "$line")")"
    jq -r --arg age "$age" '
      "[\(.id)] \(.workspace) \(.asker) \($age): \(if .urgent then "URGENT " else "" end)\(.title)",
      (if ((.route.people // []) | length) > 0 then
        "    routed to \(.route.role)\(if (.route.product // "") != "" then " for " + .route.product else "" end) (\(.route.people | join(", ")))" else empty end),
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
  local rec; rec="$(_decide_find "$id")"
  [ -n "$rec" ] || die "cel decide answer: no open owner decision with id $id"
  # a refusal is die's line, captured here: printed as die prints it
  by="$(_decide_by answer "$rec" "$by")" || { printf '%s\n' "$by"; exit 1; }
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
  local rec; rec="$(_decide_find "$id")"
  [ -n "$rec" ] || die "cel decide drop: no open owner decision with id $id"
  by="$(_decide_by drop "$rec" "$by")" || { printf '%s\n' "$by"; exit 1; }
  local title; title="$(jq -r .title <<< "$rec")"
  _decide_close "$rec" "$by" dropped "$why" "DROPPED \"$title\": $why (decision $id, by $by)"
}

# THE ASKER CAN CLOSE ITS OWN QUESTION: it is the one party that knows when a
# question was settled elsewhere or made moot. Identity is derived, never a
# flag: --by here would let anyone close anyone's question.
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

# "STILL NEEDED" IS REMEMBERED. A `confirm` record names the decision; the
# stale sweep skips it for a week unless the question changes after it.
_decide_confirm() {
  local ids=() why=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --why) why="${2:-}"; shift 2 ;;
      -*) die "cel decide confirm: unknown argument '$1'" ;;
      *) ids+=("$1"); shift ;;
    esac
  done
  [ "${#ids[@]}" -ge 1 ] || die "usage: cel decide confirm <id>... [--why <text>]"
  local me; me="$(_inbox_me)"
  local id rec asker ws rc=0
  for id in "${ids[@]}"; do
    rec="$(_decide_find "$id")"
    if [ -z "$rec" ]; then c_err "cel decide confirm: no open owner decision with id $id" >&2; rc=1; continue; fi
    asker="$(jq -r .asker <<< "$rec")"
    case "$me" in
      "$asker"|root|*-orch) ;;
      *) c_err "cel decide confirm: $id was asked by $asker, not $me" >&2; rc=1; continue ;;
    esac
    ws="$(jq -r .workspace <<< "$rec")"
    _inbox_append "$(_inbox_file "$ws")" "$(jq -nc --arg id "$(date +%s%N)" --arg ts "$(date -Is)" \
      --arg ref "$id" --arg by "$me" --arg why "$why" \
      '{id: $id, ts: $ts, kind: "confirm", ref: $ref, by: $by, to: "owner", message: ("still needed, per " + $by)}
       + (if $why != "" then {why: $why} else {} end)')" || { rc=1; continue; }
    c_ok "$id confirmed as still needing the owner" >&2
  done
  return "$rc"
}

# REMINDERS ARE NOT DECISIONS. Older stewards filed their nags as open
# `blocked` items; this resolves them. Recognised by sender AND text, so a real
# steward alarm (a stalled worker, an exhausted provider) stays open.
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
