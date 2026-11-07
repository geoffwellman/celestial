# shellcheck shell=bash
# cel fleet - the whole box in one read.
#
# Per workspace and product: the product's agent (`<product>-orch`) and its
# lanes, the solo worktrees they keep, root's mail, orphans and memory. This
# file answers the question an operator asks first - "what is the state of
# everything?" - as a single deterministic call: no tokens, no agent
# judgement, only numbers that are true at the moment of the read.
#
# It is a READ. It never nudges, never writes and always exits 0 (a usage
# error aside), because a view that can change the box is a view people are
# afraid to run.
[ -n "${_CEL_FLEET:-}" ] && return 0
_CEL_FLEET=1
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/inbox.sh
. "${BASH_SOURCE[0]%/*}/inbox.sh"
# shellcheck source=lib/run.sh
. "${BASH_SOURCE[0]%/*}/run.sh"
# shellcheck source=lib/memory.sh
. "${BASH_SOURCE[0]%/*}/memory.sh"
# shellcheck source=lib/orphans.sh
. "${BASH_SOURCE[0]%/*}/orphans.sh"

# The processes with no owner at all, as one field of the box.
#
# Every view of this box reads `cel fleet --json`, so a class of process that
# is not in this document is a class no view can mention. Zeroes rather than
# an absent key: a console that has to ask whether the field exists gets it
# wrong once.
fleet_orphans_json() { # -> {count, rss_mb}  (rss_mb fields here and below are PSS, RSS fallback)
  local n mb
  read -r n mb <<<"$(orphans_list 2>/dev/null | orphans_totals)"
  printf '{"count":%d,"rss_mb":%d}' "${n:-0}" "${mb:-0}"
}

# One herdr roster for the whole run. The sweep below asks about every
# product agent and lane, and a call per question turned a read into a
# visible pause.
#
# AND IT IS A DOCUMENT OR IT IS NOTHING. herdr answering with a truncated
# document - killed mid-write, or dead between the opening brace and the rest
# of it - is not the same as herdr answering; passing those bytes on left the
# roster to fail inside whichever jq touched it first. An unreadable answer is
# an answer nobody got, which this file already has a word for: empty, every
# orchestrator `-`, and nobody convicted. The validation costs one jq per
# render.
#
# AND SHAPE-VALID IS NOT ANSWERED. Checking only that the bytes PARSE admits
# `{}`, `[]`, an error envelope, and any document about something other than
# agents - each of which then reads as a roster that knows about nobody, and
# so as `gone` for every agent on the box. Only a document with
# `.result.agents` as an ARRAY has said anything about who is alive; anything
# else is the no-roster path, and `-`.
_fleet_roster() {
  local out
  out="$(cel_agent_list 2>/dev/null)" || { printf '%s' ''; return 0; }
  [ -n "$out" ] || { printf '%s' ''; return 0; }
  printf '%s' "$out" | jq -e '
    type == "object" and (.result | type) == "object"
      and (.result.agents | type) == "array"' >/dev/null 2>&1 \
    || { printf '%s' ''; return 0; }
  printf '%s' "$out"
}

# The unit line. The unit is the PRODUCT: the thing one agent stands over. A
# declared product names its repos after itself, because `bundle` on its own
# tells an operator nothing about which checkouts are moving; an implicit
# product IS its repo and renders as its bare name. A solo product shows its
# agent, any lanes (extra solo agents on separate goals), and the git
# worktrees they keep for branches.
_fleet_solo_line() { # <label> <agent> <worktrees> <mem> [lanes]
  printf '  %-12s solo %-5s worktrees %s   mem %s%s\n' "$1" "$2" "$3" "$4" "${5:+   lanes: $5}"
}
# A product still declaring the retired `mode: fleet`: its agent is not
# launched until the product is switched.
_fleet_legacy_line() { # <label> <agent> <mem> <product>
  printf '  %-12s fleet %-5s mem %s   (retired: cel mode %s solo)\n' "$1" "$2" "$3" "$4"
}

# WHERE THE PRODUCT AGENT STANDS, which is the directory its memory is
# attributed to. A declared product has its own directory under products/; an
# implicit product is only a repo checkout. The same derivation lib/steward.sh
# makes for the same reason - identity in this plane comes from paths - and
# reading the wrong one reports zero for a live pane, which an operator cannot
# tell apart from an agent that is not running.
_fleet_orch_dir() { # <wsdir> <product>
  if ws_product_declared "$1" "$2"; then printf '%s/products/%s' "$1" "$2"
  else printf '%s/repos/%s' "$1" "$2"; fi
}

# One unit's facts as JSON, so text and --json cannot drift apart: both
# render from this.
_fleet_unit() { # <wsdir> <product> <roster-json> -> JSON
  local wsdir="$1" product="$2" roster="$3"
  local orch="-" declared=false

  local repos=() repo
  while IFS= read -r repo; do
    [ -n "$repo" ] && repos+=("$repo")
  done < <(ws_product_repos "$wsdir" "$product")
  ws_product_declared "$wsdir" "$product" && declared=true
  # ws_build_mode's own reading, minus the second "is it declared?" query this
  # function has just answered: the fleet read is held to a spawn budget.
  local mode solo_wt=0
  if [ "$declared" = true ]; then mode="$(ws_product_get "$wsdir" "$product" mode)"
  else mode="$(ws_repo_get "$wsdir" "$product" mode)"; fi
  mode="${mode:-solo}"
  [ "$mode" != solo ] || solo_wt="$(ws_solo_worktrees "$wsdir" "$product" | grep -c . || true)"

  # An empty roster means herdr did not answer. That is not evidence that
  # anyone died, so with no roster every agent reads as unknown and nothing
  # is convicted.
  local have_roster=0
  [ -n "$roster" ] && have_roster=1

  if [ "$have_roster" = 1 ]; then
    local want status
    want="$(_run_agent_name "$product-orch")"
    status="$(printf '%s' "$roster" | jq -r --arg n "$want" \
      '[.result.agents[]? | select(.name == $n) | .agent_status // ""][0] // ""' 2>/dev/null || true)"
    if [ -n "$status" ]; then
      case "$status" in
        blocked) orch="blocked" ;;
        *)       orch="LIVE" ;;
      esac
    else
      # NO ALIAS IS NOT NO AGENT. herdr can clear a live agent's name on
      # restart, and `orch -` invites starting a second agent on top of the
      # live one. An agent alive in the product's OWN directory is that
      # product's agent whatever herdr calls it, and `unnamed` is a state
      # with a cure: cel ws up <workspace>.
      local here
      here="$(printf '%s' "$roster" | jq -r --arg c "$(_fleet_orch_dir "$wsdir" "$product")" \
        '[.result.agents[]? | select((.cwd // "") == $c) | select((.agent_status // "") != "")] | length' 2>/dev/null || printf 0)"
      [ "${here:-0}" -gt 0 ] 2>/dev/null && orch="unnamed"
    fi
  fi

  local orch_rss
  orch_rss="$(mem_tree_rss_mb "$(_fleet_orch_dir "$wsdir" "$product")")"

  # Live lanes, from the roster this read already holds: agents standing in
  # .cel/solo/<product>/lane-<name> (not in a deleted one). One jq, no herdr
  # call.
  local lanes="[]"
  if [ "$mode" = solo ] && [ "$have_roster" = 1 ]; then
    lanes="$(printf '%s' "$roster" | jq -c --arg b "$(ws_solo_dir "$wsdir" "$product")/lane-" \
      '[.result.agents[]? | select((.cwd // "") | startswith($b) and (endswith(" (deleted)") | not)) | (.cwd | ltrimstr($b))] | unique' 2>/dev/null || printf '[]')"
  fi
  # The repo list arrives as positional arguments - no extra jq to assemble it.
  jq -nc --arg name "$product" --arg orch "$orch" \
    --argjson declared "$declared" --arg mode "$mode" --argjson solo_wt "${solo_wt:-0}" \
    --argjson orch_rss "$orch_rss" --argjson lanes "${lanes:-[]}" \
    '{name: $name, mode: $mode, orch: $orch, orch_rss_mb: $orch_rss, repos: $ARGS.positional, declared: $declared, solo_worktrees: $solo_wt}
     + (if $mode == "solo" then {lanes: $lanes} else {} end)' \
    --args "${repos[@]}"
}

_fleet_workspace() { # <name> <roster-json> -> JSON or nothing
  local ws="$1" roster="$2" wsdir
  wsdir="$(registry_path "$ws")"
  [ -d "$wsdir" ] || return 0
  [ -f "$wsdir/workspace.yaml" ] || return 0

  local unread open units product mail corrupt=false
  # WHETHER ROOT'S MAIL IS GOING ANYWHERE AT ALL. Every view of this box reads
  # `cel fleet --json`, so who is alive to read the mailbox everything
  # escalates to belongs here - otherwise escalations land where nobody is
  # obliged to look.
  # A MAILBOX THAT DOES NOT PARSE IS UNKNOWN, NOT EMPTY: inbox_mail_json says
  # corrupt, and every count read off it is null rather than 0.
  mail="$(inbox_mail_json "$ws" root 2>/dev/null)" || corrupt=true
  [ -n "$mail" ] || mail='{"to_root_unread":0,"oldest_secs":0,"reader":""}'
  if [ "$corrupt" = true ]; then
    unread=null; open=null
  else
    unread="$(_inbox_count --for root --workspace "$ws" 2>/dev/null)" || true
    [ -n "$unread" ] || unread=0
    open="$(_inbox_open --for root --workspace "$ws" 2>/dev/null | grep -c . || true)"
    [ -n "$open" ] || open=0
  fi

  # The agent candidates are one jq over the workspace and the roster,
  # and the product list is read off them rather than asked of the YAML a
  # second time (the fleet read is held to a spawn budget).
  local cands
  cands="$(run_orchestrator_candidates "$ws" "$wsdir" "$roster")"
  units=""
  for product in $(printf '%s\n' "$cands" | while IFS=$'\t' read -r r p _; do [ "$r" = orchestrator ] && printf '%s\n' "$p"; done); do
    units="$units$(_fleet_unit "$wsdir" "$product" "$roster")
"
  done

  # The agent rows are folded into THIS jq, mail included:
  # the rows arrive as TSV with each mailbox's name and cursor state, and the inbox file is
  # read here once for all of them - no jq per agent (the budget).
  local orows ifile
  orows="$(_fleet_orch_tsv "$ws" "$wsdir" "$roster" "$cands")"
  ifile="$(_inbox_file "$ws")"
  [ -f "$ifile" ] || ifile=/dev/null
  printf '%s' "$units" | jq -sc --arg name "$ws" \
    --argjson unread "$unread" --argjson open "$open" --argjson mail "$mail" \
    --argjson corrupt "$corrupt" --arg orows "$orows" --rawfile inbox "$ifile" \
    "$_INBOX_UNREAD_DEF"'([$inbox | split("\n")[] | select(length > 0) | (try fromjson catch empty)]) as $mails
     | ([$mails[] | select(.kind == "resolution") | .ref]) as $done
     | {name: $name, root: {unread: $unread, open: $open}, mail: $mail, units: .,
        orchestrators: [$orows | split("\n")[] | select(length > 0) | split("\t")
          | .[11] as $who
          | (.[12] | fromjson) as $cs
          | {name: .[0], ws: .[1], pane: .[2], status: .[3], since: (.[4] | tonumber? // 0),
             model: .[5], launch: .[6], detail: (if .[7] == "-" then "" else .[7] end), cmd: .[8],
             role: .[9], product: .[10],
             unread: (if $corrupt then null else ([$mails[] | select(.kind != "resolution") | select(.to == $who or .to == "all")
                       | select(unread($cs))] | length) end),
             open: (if $corrupt then null else ([$mails[] | select(.kind == "decision" or .kind == "blocked")
                     | select(.to == $who or .to == "all") | select([.id] | inside($done) | not)] | length) end)}]}'
}

# EVERY PRODUCT AGENT'S STATE AND LAUNCH LINE, from the same rows
# `cel update` acts on, so the console shows what `--restart-orchestrators`
# would do and never runs a probe of its own. Each row gains the mailbox's
# cursor state (mark and holes), the same rule _inbox_count_one applies (the recipient's
# own, and for root the console's too), read with builtins. Sessions are not
# recorded from here: the fleet is a READ.
_fleet_orch_tsv() { # <ws> <wsdir> <roster-json> <candidates>
  [ -n "$3" ] || return 0
  local row name ws pane status since model launch detail cmd role product who cs
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r name ws pane status since model launch detail cmd role product <<< "$row"
    # THE MAILBOX NAME IS THE ALIAS RULE'S, not a bare "$product-orch": a long
    # product's name is cut to 32 characters (and may then end in a dash), and
    # the agent reads - and the cursor is filed under - that name.
    if [ "$role" = root ]; then who=root; else who="$(_run_agent_name "$product-orch")"; fi
    # hole-aware, like every other unread view (_inbox_cursors_json)
    cs="$(_inbox_cursors_json "$(_inbox_dir)/$1.$who.cursor" "$(_inbox_dir)/$1.$who.console.cursor")"
    printf '%s\t%s\t%s\n' "$row" "$who" "$cs"
  done < <(run_orchestrator_rows "$1" "$3" 0 "$2" "$4")
}

# ONE LINE FOR A MAILBOX NOBODY READS, for `cel doctor`. It lives here rather
# than in lib/doctor.sh for the same reason gc_doctor_line and
# orphans_doctor_line do: the check belongs beside the facts it reads.
#
# Silent when someone is reading, and silent when there is nothing unread. A
# watcher that speaks every tick is a watcher people stop reading. A mailbox
# that does not parse is never silent: its unread mail is unknown.
fleet_mail_doctor_line() { # <ws> -> one line, or nothing
  local mail n secs reader age
  if ! mail="$(inbox_mail_json "$1" root 2>/dev/null)"; then
    [ "$(printf '%s' "$mail" | jq -r '.corrupt // false' 2>/dev/null)" = true ] || return 0
    printf "  %s: root's mailbox %s is corrupt - its unread mail is unknown, not empty\n" "$1" "$(_inbox_file "$1")"
    return 0
  fi
  [ -n "$mail" ] || return 0
  n="$(printf '%s' "$mail" | jq -r '.to_root_unread')"
  secs="$(printf '%s' "$mail" | jq -r '.oldest_secs')"
  reader="$(printf '%s' "$mail" | jq -r '.reader')"
  [ "${n:-0}" -gt 0 ] || return 0
  [ -z "$reader" ] || return 0
  if [ "${secs:-0}" -ge 3600 ]; then age="$(( secs / 3600 ))h"; else age="$(( secs / 60 ))m"; fi
  printf '  %s: root has %s unread, oldest %s, nobody reading it\n' "$1" "$n" "$age"
}

_fleet_render() { # <doc>
  local free total
  free="$(mem_human "$(printf '%s' "$1" | jq -r '.box.available_mb // 0')")"
  total="$(mem_human "$(printf '%s' "$1" | jq -r '.box.total_mb // 0')")"
  local orph orph_n
  orph_n="$(printf '%s' "$1" | jq -r '.box.orphans.count // 0')"
  orph=""
  [ "${orph_n:-0}" -gt 0 ] 2>/dev/null \
    && orph="   $orph_n orphans ($(mem_human "$(printf '%s' "$1" | jq -r '.box.orphans.rss_mb // 0')")) - cel gc --orphans"
  printf '%s' "$1" | jq -r --arg box "box $free free of $total$orph" '.workspaces[]
    | (if .mail.corrupt then "root mail: UNKNOWN (mailbox corrupt)"
       else "root mail: \(.root.unread) unread, \(.root.open) open" end) as $rootmail
    | "\(.name)   (\(.units | length) products)   \($rootmail)   \($box)"
      as $head
    | [$head] + [.units[]
        | (if .declared then "\(.name) (\(.repos | join(", ")))" else .name end) as $label
        | if .mode == "solo"
          then "SOLO\t\($label)\t\(.orch)\t\(.solo_worktrees // 0)\t\(.orch_rss_mb // 0)\t\((.lanes // []) | join(","))"
          else "LEGACY\t\($label)\t\(.orch)\t\(.orch_rss_mb // 0)\t\(.name)" end]
    | .[]' \
  | while IFS= read -r line; do
      case "$line" in
        LEGACY*)
          IFS=$'\t' read -r _ n o m p <<<"$line"
          _fleet_legacy_line "$n" "$o" "$(mem_human "$m")" "$p"
          ;;
        SOLO*)
          IFS=$'\t' read -r _ n o t m l <<<"$line"
          _fleet_solo_line "$n" "$o" "$t" "$(mem_human "$m")" "$l"
          ;;
        *) printf '%s\n' "$line" ;;
      esac
    done
}

# THE SUBSCRIPTIONS, FROM THE CACHE AND ONLY FROM THE CACHE.
#
# This read is on the console's refresh loop and on the dashboard's poll. Two
# network round trips to Anthropic and ChatGPT on that path would put a
# provider's latency between an operator and every draw, and a provider having
# a bad afternoon would make the fleet view feel broken. So the field is
# whatever `subscription_usage` last wrote (it refreshes on a 60 s TTL from
# `cel quota` and from the steward's tick) and an empty list when nothing has
# asked yet - absent is absent, never a zero window.
#
# It is the SAME FUNCTION `cel quota --json` calls, not a second reading of
# the same directory, so the console and `cel quota` cannot count different
# subscriptions.
_fleet_subscriptions() {
  # shellcheck source=lib/quota.sh
  . "${BASH_SOURCE[0]%/*}/quota.sh"
  subscription_list --cached
}

# THE WHOLE DOCUMENT, CACHED. Under load one read takes tens of seconds, and a
# console refreshing every few seconds would start read after read behind the
# one still running, adding to the load that makes the read slow. A valid
# copy of any age is served at once, and one older than `fleet.cache_secs`
# (default 30) also starts a detached refill; `--fresh` bypasses the cache.
# Concurrent builders queue on one lock and take what the holder wrote rather
# than each starting a read of its own. CEL_FLEET_CACHE_SECS overrides the
# config; the suite sets it to 0 so a test that mutates a fixture sees it.
_fleet_cache_secs() {
  local v="${CEL_FLEET_CACHE_SECS:-}"
  if [ -z "$v" ]; then
    # shellcheck source=lib/config.sh
    . "${BASH_SOURCE[0]%/*}/config.sh"
    v="$(cel_config_get fleet cache_secs)"
  fi
  case "$v" in ''|*[!0-9]*) v=30 ;; esac
  printf '%s' "$v"
}

_fleet_cache_young() { # <file> <secs>
  [ -s "$1" ] || return 1
  # A young file is served only if it is still a fleet document: a truncated
  # or hand-edited cache would print an empty board with success.
  jq -e '.workspaces | type == "array"' "$1" >/dev/null 2>&1 || return 1
  local now m
  now="$(date +%s)"; m="$(stat -c %Y "$1" 2>/dev/null || printf 0)"
  [ $(( now - m )) -lt "$2" ]
}

_fleet_doc() { # <only> -> the JSON document
  local only="$1" roster names ws blocks=""
  roster="$(_fleet_roster)"
  # The mailbox reader is asked of the roster this pass already holds, not of
  # a fresh `herdr agent list` per workspace.
  _INBOX_ROSTER_HELD="$(printf '%s' "$roster" | jq -r '.result.agents[]?.name // empty' 2>/dev/null || true)"
  [ -n "$roster" ] || _INBOX_ROSTER_HELD=""
  _INBOX_ROSTER_OK=0; [ -n "$roster" ] && _INBOX_ROSTER_OK=1
  export _INBOX_ROSTER_HELD _INBOX_ROSTER_OK
  # ONE /proc WALK FOR THE WHOLE READ. Every agent and the box's own total
  # are answered from this one snapshot; a walk per question made the cost of
  # the view scale with the number of agents.
  mem_tree_snapshot
  if [ -n "$only" ]; then names="$only"; else names="$(registry_names)"; fi

  for ws in $names; do
    blocks="$blocks$(_fleet_workspace "$ws" "$roster")
"
  done
  unset _INBOX_ROSTER_HELD _INBOX_ROSTER_OK

  local total avail used
  read -r total avail used <<<"$(mem_box)"
  printf '%s' "$blocks" | jq -sc \
    --argjson total "${total:-0}" --argjson avail "${avail:-0}" --argjson used "${used:-0}" \
    --argjson subs "$(_fleet_subscriptions)" \
    --argjson orphans "$(fleet_orphans_json)" \
    --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{generated_at: $gen, workspaces: ., subscriptions: $subs}
     | .box = {total_mb: $total, available_mb: $avail, used_pct: $used, orphans: $orphans,
               agents_rss_mb: ([.workspaces[].units[] | .orch_rss_mb // 0] | add // 0)}'
  mem_tree_snapshot_clear
}

# A cache document of any age that is still a fleet document.
_fleet_cache_valid() { # <file>
  [ -s "$1" ] && jq -e '.workspaces | type == "array"' "$1" >/dev/null 2>&1
}

# Build and write the cache, holding the lock on fd 9 in THIS shell only. The
# build runs with fd 9 CLOSED: otherwise every awk, jq and subshell under the
# read inherits it, a killed holder's reparented children keep the lock, and
# every console behind it waits on a read nobody will collect.
_fleet_write() { # <file> <only>
  local doc
  doc="$(_fleet_doc "$2" 9>&-)"
  # Never let a failed build (empty/invalid) replace a good stale cache.
  if printf '%s\n' "$doc" >"$1.tmp.$$" 9>&- &&
    jq -e '.workspaces | type == "array"' "$1.tmp.$$" >/dev/null 2>&1 9>&-; then
    mv -f "$1.tmp.$$" "$1" 9>&-
  else
    rm -f "$1.tmp.$$"
  fi
  printf '%s' "$doc"
}

# THE DETACHED REFILL. The rebuild runs in its own session, where no caller's
# timeout or exit reaches it: a rebuild run inline by a caller that gets
# killed never writes the cache, so every refresh finds it expired and
# repeats the killed work. The caller returns the old document at once.
# SINGLE-FLIGHT on the same lock, taken non-blocking: a second refill that
# finds one running simply exits, and one that wins after a refill has just
# finished sees a young cache and exits too.
_fleet_refill() { # <file> <only> <secs>
  exec 9>"$1.lock"
  flock -n 9 || return 0
  _fleet_cache_young "$1" "$3" && return 0
  [ -n "${CEL_FLEET_REFILL_LOG:-}" ] && printf '%s\n' "$$" >>"$CEL_FLEET_REFILL_LOG"
  # A seam for the suite: holds the refill open long enough to kill its caller.
  [ -n "${CEL_FLEET_REFILL_DELAY:-}" ] && sleep "$CEL_FLEET_REFILL_DELAY" 9>&-
  _fleet_write "$1" "$2" >/dev/null
  exec 9>&-
}

fleet_refill_spawn() { # <file> <only> <secs>
  local root; root="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
  setsid bash -c '. "$1/lib/common.sh"; . "$1/lib/fleet.sh"; _fleet_refill "$2" "$3" "$4"' \
    _ "$root" "$1" "$2" "$3" </dev/null >/dev/null 2>&1 9>&- &
  disown 2>/dev/null || true
}

# The cache file for a read, for the steward's warm-up as well as cmd_fleet.
_fleet_cache_file() { # <only>
  local dir="${CEL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cel}"
  mkdir -p "$dir"
  printf '%s/fleet%s.json' "$dir" "${1:+.$1}"
}

# The steward's tick keeps the cache warm so the first console read after an
# idle spell is not a cold build: one detached refill, and only when stale.
fleet_cache_warm() {
  local secs file
  secs="$(_fleet_cache_secs)"
  [ "$secs" -gt 0 ] || return 0
  file="$(_fleet_cache_file "")"
  _fleet_cache_young "$file" "$secs" && return 0
  fleet_refill_spawn "$file" "" "$secs"
}

cmd_fleet() {
  local json=0 only="" fresh=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --fresh) fresh=1; shift ;;
      --workspace) only="${2:-}"; shift 2 ;;
      -h|--help) printf 'usage: cel fleet [--json] [--fresh] [--workspace <name>]\n'; return 0 ;;
      *) die "cel fleet: unknown argument '$1'" ;;
    esac
  done

  local secs doc="" file
  secs="$(_fleet_cache_secs)"
  if [ "$secs" -gt 0 ]; then
    file="$(_fleet_cache_file "$only")"
    # SERVE STALE: a valid document of ANY age is returned at once;
    # one past `cache_secs` also starts the detached refill. The document
    # carries `generated_at`, so a reader says honestly how old it is.
    if [ "$fresh" -eq 0 ] && _fleet_cache_valid "$file"; then
      doc="$(cat "$file" 2>/dev/null || true)"
      # Re-validated after the read: the file can be replaced between the
      # check and the cat, and an empty read is not a board.
      if printf '%s' "$doc" | jq -e '.workspaces | type == "array"' >/dev/null 2>&1; then
        _fleet_cache_young "$file" "$secs" || fleet_refill_spawn "$file" "$only" "$secs"
        # A cache with no generated_at (written by an older cel) takes its
        # age from the file's mtime, or a reader would pass it off as fresh.
        local m; m="$(stat -c %Y "$file" 2>/dev/null || printf 0)"
        doc="$(printf '%s' "$doc" | jq -c --arg m "$(date -u -d "@$m" +%Y-%m-%dT%H:%M:%SZ)" \
          '.generated_at //= $m')"
      else
        doc=""
      fi
    fi
    if [ -z "$doc" ]; then
      # No cache at all, or --fresh: build inline, under the lock so callers
      # queue behind one build and take what it wrote.
      exec 9>"$file.lock"
      flock 9
      if [ "$fresh" -eq 0 ] && _fleet_cache_valid "$file"; then
        doc="$(cat "$file" 2>/dev/null || true)"
      fi
      if ! printf '%s' "$doc" | jq -e '.workspaces | type == "array"' >/dev/null 2>&1; then
        doc="$(_fleet_write "$file" "$only")"
      fi
      exec 9>&-
    fi
    # The reader judges staleness by the same threshold that starts a refill.
    doc="$(printf '%s' "$doc" | jq -c --argjson s "$secs" '.cache_secs = $s')"
  else
    doc="$(_fleet_doc "$only")"
  fi
  if [ "$json" -eq 1 ]; then printf '%s\n' "$doc"; else _fleet_render "$doc"; fi
  return 0
}
