# shellcheck shell=bash
# cel work / cel history - THE WORK ITEM.
#
# The factory tracked its MACHINES and not its PRODUCTS. `cel fleet` showed
# workspaces and workers, `cel-fanout status` delegations, `cel-linear board`
# tickets and `gh pr list` pull requests; each of those is one system's view of
# a thing none of them owns. So "what happened to ABC-49" could only be
# answered by visiting four surfaces and holding the join in your head, and the
# join is exactly what goes wrong quietly.
#
# A WORK ITEM is that thing: keyed by its ticket when it has one, else by its
# delegation, carrying whichever of the four parts exist, with one merged list
# of events and one computed stage. This file is the MODEL and the two views
# over it. It is a READ: it never writes anything but its own cache.
#
# The JSON shape is FROZEN here (CEL-45) and documented in README beside it -
# the console and the dash render this document and add nothing to it, so that
# two surfaces cannot drift into two different answers about one item.
[ -n "${_CEL_WORK:-}" ] && return 0
_CEL_WORK=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"
# shellcheck source=lib/run.sh
. "$(dirname "${BASH_SOURCE[0]}")/run.sh"      # reviewers_rows - who reviewed, and when
# shellcheck source=lib/afk.sh
. "$(dirname "${BASH_SOURCE[0]}")/afk.sh"      # afk_log_json - what the box did while nobody watched

_work_gh()     { printf '%s' "${CEL_WORK_GH:-gh}"; }
_work_linear() {
  [ -n "${CEL_WORK_LINEAR:-}" ] && { printf '%s' "$CEL_WORK_LINEAR"; return 0; }
  local b="${CEL_ROOT:-}/core/skills/linear/bin/cel-linear"
  if [ -n "${CEL_ROOT:-}" ] && [ -x "$b" ]; then printf '%s' "$b"; else printf 'cel-linear'; fi
}
_work_cache_dir()  { printf '%s' "${CEL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cel}"; }
_work_cache_secs() {
  local v; v="$(cel_config_get work cache_secs)"
  case "$v" in ''|*[!0-9]*) printf '120';; *) printf '%s' "$v";; esac
}

# The workspace directory, whether the caller named a registry workspace, gave
# a path, or named nothing at all and is standing in one.
work_wsdir() { # [name-or-path] -> <wsdir>
  local a="${1:-}"
  if [ -z "$a" ]; then ws_current 2>/dev/null || return 1; return 0; fi
  if [ -f "$a/workspace.yaml" ]; then printf '%s' "$a"; return 0; fi
  registry_require "$a"
}

# --- the ledger, with a history it can always read -------------------------
#
# Rows written before CEL-45 carry one timestamp and no `history`, and a
# timeline that drew nothing for them would make the whole view look broken on
# the first box it met. A missing history is SYNTHESISED here, at read time,
# from what the row does have - and never written back: a backfill on disk is
# a guess that outlives the guesser and is indistinguishable from a record.
work_ledger_json() { # <wsdir> -> JSON array
  local f="$1/.cel/delegations.json"
  [ -f "$f" ] || { printf '[]'; return 0; }
  jq -c 'if type == "array" then . else [] end
    | map(. + {history: (
        if ((.history // []) | length) > 0 then .history
        else (([{state: "created", at: (.created // ""), by: ""}]
              + (if (.verdict.at // "") != "" then
                   [{state: "verified", at: .verdict.at, by: ""}] else [] end)
              + (if (.review.at // "") != "" then
                   [{state: ("review " + (.review.verdict // .review.decision // "")),
                     at: .review.at, by: (.review.by // "")}] else [] end)
              + (if (.created // "") != "" and (.state // "") != "" then
                   [{state: .state, at: (.review.at // .verdict.at // .created), by: ""}]
                 else [] end))
          | map(select(.at != "")) | sort_by(.at))
        end)})' "$f" 2>/dev/null || printf '[]'
}

# --- the two systems that cost a round trip --------------------------------
#
# One `gh pr list` per repo and one `cel-linear board` per workspace, cached
# together in one file: caching them separately would let a view read a PR
# from this minute against a ticket from two minutes ago and narrate a
# transition that never happened. The ledger and the mailbox are local files
# and are never cached - they are free and they are the parts that must be
# right even when the network is not.
_work_remote() { # <wsdir> <ws> <fresh 0|1> -> {tickets:[],prs:[]}
  local wsdir="$1" ws="$2" fresh="$3" f age ttl
  f="$(_work_cache_dir)/work-$ws.json"
  ttl="$(_work_cache_secs)"
  if [ "$fresh" != 1 ] && [ -s "$f" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$ttl" ]; then cat "$f"; return 0; fi
  fi
  # A FAILED READ IS NOT AN EMPTY ONE (CEL-79). Any refusal marks the pass
  # failed: the document is still printed (the ledger and mail parts stand),
  # but it is never cached - the previous cache is kept, and the next read
  # asks again rather than serving "no PRs" for work.cache_secs.
  local tix="[]" prs="[]" repo slug out failed=0 raw rc
  rc=0; raw="$("$(_work_linear)" board --json --workspace "$ws" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || failed=1
  tix="$(printf '%s' "$raw" | jq -sc '.' 2>/dev/null || true)"
  [ -n "$tix" ] || { tix="[]"; failed=1; }
  local all="[]"
  for repo in $(ws_repo_names "$wsdir" 2>/dev/null || true); do
    slug="$(ws_repo_get "$wsdir" "$repo" url 2>/dev/null \
      | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
    [ -n "$slug" ] || continue
    case "$slug" in */*) ;; *) continue;; esac
    # ONE CALL PER REPO, open and closed together: a PR stops being open at
    # exactly the moment it becomes the most interesting thing that happened.
    rc=0; out="$("$(_work_gh)" pr list --repo "$slug" --state all --limit "${CEL_WORK_PR_LIMIT:-50}" \
      --json number,title,headRefName,state,reviewDecision,statusCheckRollup,createdAt,updatedAt,mergedAt,closedAt,url \
      2>/dev/null)" || rc=$?
    [ "$rc" -eq 0 ] || failed=1
    # A zero exit is not a good read: empty or broken JSON fails the pass too.
    printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || { failed=1; continue; }
    all="$(printf '%s' "$all" | jq -c --argjson new "$(printf '%s' "$out" | jq -c '. // []' 2>/dev/null || echo '[]')" \
      --arg repo "$repo" --arg slug "$slug" '. + ($new | map(. + {repo: $repo, slug: $slug}))' 2>/dev/null || printf '%s' "$all")"
  done
  prs="$all"
  local doc
  doc="$(jq -nc --argjson t "$tix" --argjson p "$prs" '{tickets: $t, prs: $p}')"
  if [ "$failed" -eq 0 ]; then
    mkdir -p "$(_work_cache_dir)" 2>/dev/null || true
    printf '%s' "$doc" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$"
  fi
  printf '%s' "$doc"
}

# The mailbox, read RAW and WHOLE. The console's timeline windowed to 24 hours
# and so lost every message about anything that took longer than a day, which
# is most of them. The file is append-only and local; there is no reason to
# read less than all of it.
_work_mail() { # <ws> -> JSON array
  local f="${CEL_INBOX_DIR:-$HOME/.local/share/cel/inbox}/$1.jsonl"
  [ -f "$f" ] || { printf '[]'; return 0; }
  jq -sc '[.[] | select(type == "object")]' "$f" 2>/dev/null || printf '[]'
}

# --- the shared jq: the key, the stage, the next action --------------------
#
# One definition of each, read by the model and by `work_stage` alike: two
# copies of the stage order is two surfaces that can disagree about what a
# thing IS.
_WORK_JQ_DEFS='
# A STAMP IS A MOMENT, NOT A STRING. The ledger writes UTC (`...Z`) and the
# mailbox writes local time with an offset (`...+10:00`), so sorting the text
# put every message ten hours late and a history read as if the mail arrived
# after the merge it announced. Everything orders on THIS.
def tsec:
  (. // "") as $s
  | ($s | capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") // null) as $m
  | if $m == null then 0
    else (($m.b + "Z") | fromdateiso8601)
         - (if ($m.z // "Z") == "Z" then 0
            else (($m.z | .[0:1]) as $sg
                  | (($m.z | ltrimstr("+") | ltrimstr("-") | gsub(":"; "")) as $hm
                     | (($hm | .[0:2] | tonumber) * 3600 + ($hm | .[2:4] | tonumber) * 60))
                  | if $sg == "-" then -. else . end)
            end)
    end;
def tickre: "[A-Z][A-Z0-9]+-[0-9]+";
# The ticket id in a string, or "". A SUBSTRING MATCH IS WRONG: "ABC-4" is
# inside "ABC-49" and matching that way joined a small ticket to a big one s
# PR. The scan is anchored on the whole token.
# CASE IS NOT IDENTITY: a branch cut as abc-49-fix is work for ABC-49, so the
# match ignores case and the key is always the canonical uppercase id.
def tickof($s): (($s // "") | [scan(tickre; "i")] | (.[0] // "") | ascii_upcase);
def names($text; $k): (($text // "") | test("(^|[^A-Za-z0-9])" + ($k | gsub("([.*+?^$()\\[\\]{}|\\\\])"; "\\\\\\1")) + "([^0-9A-Za-z-]|$)"));
# THE FACTORY SEQUENCE, first match wins, the reason beside each case.
def stage_of:
  ((.delegation.state // "")) as $d
  | ((.pr.state // "") | ascii_upcase) as $p
  | ((.pr.review // "") | ascii_upcase) as $r
  | ((.pr.checks // "") | ascii_upcase) as $c
  | ((.ticket.state // "") | ascii_downcase) as $t
  # APPROVED THE WAY `cel-fanout land` READS IT: GitHub'\''s decision, or the
  # ledger verdict `cel-fanout review` records - Celestial'\''s reviewer never
  # posts a GitHub review, so reviewDecision is often empty on a PR it passed.
  | ($r == "APPROVED" or ((.delegation.review.verdict // "") == "approved")) as $approved
  # GREEN: no red check, and the gate passed - the recorded gate verdict when
  # there is one (false or no_verdict is not passed), else the PR'\''s checks.
  | (.delegation.verdict // {}) as $v
  | (if $c == "FAILURE" then false
     elif $v.gate == true then true
     elif ($v | has("gate")) or (($v.gate_outcome // "") != "") then false
     else $c == "SUCCESS" end) as $green
  | if $d == "released" then "released"        # the worktree is gone: done and let go
    elif $p == "MERGED" or $d == "landed" then "merged"   # in main, not yet released
    elif $p == "OPEN" and $approved and $green then "landing"  # needs both
    elif $p == "OPEN" then "review"            # a PR exists, so a person is the next step
    elif ($d != "" and ($d | IN("running","unconfirmed","finished","reported","collected","salvaged","orphaned")))
      then "building"                          # a worker holds it, however it is going
    elif ($t != "" and ($t | IN("todo","ready","unstarted","next","selected","in progress","in review")))
      then "ready"                             # start-able and nobody started it
    else "backlog" end;                        # everything else is not yet the factory\''s problem
# WHAT A PERSON WOULD DO NEXT. The board exists to be acted on; a row that
# says only what state it is in leaves the reader to remember the verb.
def next_of($stage):
  {released: "-", merged: "release", landing: "merge", review: "review",
   building: "collect", ready: "delegate", backlog: "-"}[$stage] // "-";
'

# The stage of one item, for anything holding a part-built item (and for the
# tests, which prove the order case by case).
work_stage() { # <item-json> -> stage
  printf '%s' "$1" | jq -r "$_WORK_JQ_DEFS"' stage_of'
}

work_next_action() { # <stage> -> the verb
  printf '%s' "$1" | jq -Rr "$_WORK_JQ_DEFS"' next_of(.)'
}

# --- the model -------------------------------------------------------------
#
# One JSON object per line, one per work item. Every part is optional: the
# whole point is that an item exists even when only one of the four systems
# has heard of it.
work_items() { # <wsdir> [--since <iso>] [--fresh] [--stage S] [--product P] [--key K]
  local wsdir="$1"; shift || true
  local since="" fresh=0 want_stage="" want_product="" want_key=""
  while [ $# -gt 0 ]; do case "$1" in
    --since)   since="$2"; shift 2;;
    --fresh)   fresh=1; shift;;
    --stage)   want_stage="$2"; shift 2;;
    --product) want_product="$2"; shift 2;;
    --key)     want_key="$2"; shift 2;;
    *) die "work: unknown argument '$1'";;
  esac; done
  local ws; ws="$(ws_name "$wsdir" 2>/dev/null)"; [ -n "$ws" ] || ws="$(basename "$wsdir")"

  local led mail remote repomap
  led="$(work_ledger_json "$wsdir")"
  mail="$(_work_mail "$ws")"
  remote="$(_work_remote "$wsdir" "$ws" "$fresh")"
  # repo -> product, so an item can say which product it belongs to without
  # every consumer re-deriving it from workspace.yaml.
  repomap='{}'
  local r
  for r in $(ws_repo_names "$wsdir" 2>/dev/null || true); do
    repomap="$(printf '%s' "$repomap" | jq -c --arg r "$r" \
      --arg p "$(ws_product_of_repo "$wsdir" "$r" 2>/dev/null || printf '%s' "$r")" '. + {($r): $p}')"
  done

  # THE INPUTS GO THROUGH FILES, NEVER ARGV. A real workspace's mailbox is
  # megabytes of JSON and a box with sixty delegations is not much smaller;
  # passed as --argjson the first run on this box died with "Argument list too
  # long" before it drew a single row. --slurpfile has no such ceiling.
  local tmp; tmp="$(mktemp -d)" || return 1
  printf '%s' "$led"     > "$tmp/led.json"
  printf '%s' "$mail"    > "$tmp/mail.json"
  printf '%s' "$remote"  > "$tmp/remote.json"
  printf '%s' "$repomap" > "$tmp/pmap.json"
  reviewers_rows 2>/dev/null > "$tmp/rev.json" || printf '[]' > "$tmp/rev.json"
  afk_log_json 2>/dev/null | jq -sc '[.[] | select(type == "object")]' > "$tmp/afk.json" 2>/dev/null \
    || printf '[]' > "$tmp/afk.json"

  jq -nc "$_WORK_JQ_DEFS"'
    ($ledf[0] // []) as $led | ($mailf[0] // []) as $mail
    | (($remotef[0] // {}).tickets // []) as $tix
    | (($remotef[0] // {}).prs // []) as $prs
    | ($revf[0] // []) as $rev | ($afkf[0] // []) as $afk
    | ($pmapf[0] // {}) as $pmap

    # --- the parts, each already carrying the key it joins on --------------
    | ($led | map(. as $d
        | (if (tickof($d.ticket)) != "" then tickof($d.ticket)
           elif (tickof($d.branch)) != "" then tickof($d.branch)
           else $d.id end) as $k
        | {key: $k, keyed_on: (if $k == $d.id then "delegation" else "ticket" end), d: $d})) as $dels
    | ($tix | map({key: .identifier, t: .})) as $tickets
    | ($prs | map(. as $p | (tickof($p.headRefName)) as $k
        | {key: (if $k != "" then $k else (($p.repo // "") + "#" + ($p.number | tostring)) end), p: $p})) as $pulls

    | ([ ($dels[].key), ($tickets[].key), ($pulls[].key) ] | map(select(. != null and . != "")) | unique) as $keys

    | [ $keys[] | . as $k
        | ([$dels[] | select(.key == $k)] | sort_by(.d.created // "") | last) as $dl
        | ([$tickets[] | select(.key == $k)] | first) as $tk
        # An OPEN pull request is the live one; otherwise the one that moved last.
        | ([$pulls[] | select(.key == $k) | .p]
           | sort_by([(if (.state // "" | ascii_upcase) == "OPEN" then 1 else 0 end), (.updatedAt // "")]) | last) as $pr
        | ($dl.d) as $d
        | (if $pr == null then null else
            ($pr.statusCheckRollup // []) as $cs
            | (if ($cs | length) == 0 then "NONE"
               elif ($cs | map((.conclusion // .state // "") | ascii_upcase)
                     | any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT")) then "FAILURE"
               elif ($cs | map((.conclusion // .state // "") | ascii_upcase)
                     | any(. == "" or . == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED")) then "PENDING"
               else "SUCCESS" end) end) as $checks
        | {key: $k,
           keyed_on: ($dl.keyed_on // (if $tk != null then "ticket" else "pr" end)),
           ws: $ws,
           product: (if $d != null then ($pmap[$d.repo // ""] // ($d.repo // "")) else ($pmap[$pr.repo // ""] // ($pr.repo // "")) end),
           title: ($tk.t.title // $pr.title // $d.branch // $k),
           ticket: (if $tk == null then null else
                     {id: $tk.t.identifier, state: ($tk.t.state // ""), url: ($tk.t.url // ""),
                      created: ($tk.t.createdAt // ""), updated: ($tk.t.updatedAt // "")} end),
           delegation: (if $d == null then null else
                     {id: $d.id, state: ($d.state // ""), branch: ($d.branch // ""),
                      repo: ($d.repo // ""), worker: ($d.pane // $d.worker // ""),
                      profile: ($d.profile // ""), worktree: ($d.worktree // ""),
                      verdict: ($d.verdict // null), review: ($d.review // null),
                      # READ from the history, never stored twice.
                      landed_at:   ([$d.history[]? | select(.state == "landed")   | .at] | last // ""),
                      released_at: ([$d.history[]? | select(.state == "released") | .at] | last // "")} end),
           pr: (if $pr == null then null else
                     {number: $pr.number, state: ($pr.state // ""), review: ($pr.reviewDecision // ""),
                      checks: $checks, url: ($pr.url // ""), repo: ($pr.repo // ""),
                      branch: ($pr.headRefName // ""), opened: ($pr.createdAt // ""),
                      merged: ($pr.mergedAt // ""), updated: ($pr.updatedAt // "")} end)}

        # --- the events, one list, newest LAST ---------------------------
        | . as $it
        | .events = (
            [ ($d.history // [])[] | {at: .at, source: "worktree",
                what: (.state + (if (.by // "") != "" then " (" + .by + ")" else "" end))} ]
          + [ if $d != null and ($d.profile // "") != "" and (($d.history // []) | length) > 0
              then {at: ($d.history[0].at), source: "worktree",
                    what: ("worker started (" + ($d.runtime // "pi") + "/" + $d.profile + ")")}
              else empty end ]
          + [ if $tk != null and ($tk.t.createdAt // "") != "" then
                {at: $tk.t.createdAt, source: "ticket", what: "created"} else empty end ]
          + [ if $tk != null and ($tk.t.updatedAt // "") != "" then
                {at: $tk.t.updatedAt, source: "ticket",
                 what: ("updated" + (if ($tk.t.state // "") != "" then " (" + $tk.t.state + ")" else "" end))} else empty end ]
          + [ if $pr != null and ($pr.createdAt // "") != "" then
                {at: $pr.createdAt, source: "pr", what: ("#" + ($pr.number|tostring) + " opened")} else empty end ]
          + [ if $pr != null and ($pr.mergedAt // "") != "" then
                {at: $pr.mergedAt, source: "pr", what: ("#" + ($pr.number|tostring) + " merged")} else empty end ]
          + [ if $pr != null and ($pr.closedAt // "") != "" and ($pr.mergedAt // "") == "" then
                {at: $pr.closedAt, source: "pr", what: ("#" + ($pr.number|tostring) + " closed")} else empty end ]
          + [ if ($d.review.at // "") != "" then
                {at: $d.review.at, source: "pr",
                 what: (($d.review.verdict // $d.review.decision // "reviewed")
                        + (if ($d.review.by // "") != "" then " by " + $d.review.by else "" end))}
              else empty end ]
          # The reviewer registry: who reviewed this, and when they started.
          # A PR NUMBER IS ONLY UNIQUE WITHIN ITS REPO: two repos both have a #7.
          + [ $rev[]? | select($pr != null and (.repo // "") == ($pr.repo // "")
                               and (.pr | tostring) == ($pr.number | tostring))
              | [ (if (.started_at // "") != "" then
                     {at: .started_at, source: "reviewer",
                      what: ("reviewer " + (.agent // "") + " started")} else empty end),
                  (if (.closed_at // "") != "" then
                     {at: .closed_at, source: "reviewer", what: ("reviewer " + (.agent // "") + " closed")}
                   else empty end) ] | .[] ]
          # The AFK act log: what the box did on its own while nobody watched -
          # the morning question "what happened to this overnight".
          + [ $afk[]? | select(
                names(.detail; $k)
                or ($d != null and ($d.branch // "") != "" and ((.detail // "") | contains($d.branch)))
                or ($pr != null and ($pr.slug // "") != ""
                    and names(.detail; $pr.slug + "#" + ($pr.number | tostring))))
              | {at: .at, source: "afk", what: (.act + ": " + (.detail // "") + " [" + (.authorisation // "") + "]")} ]
          # The mailbox, whole: a message that NAMES this item is part of its story.
          + [ $mail[]? | select(names(.message; $k) or names(.from; $k))
              | {at: .ts, source: "mail",
                 what: ((.from // "-") + ": " + ((.message // "") | gsub("\n"; " ")))} ]
          | map(select((.at // "") != "")) | sort_by(.at | tsec))
        | .stage = (. | stage_of)
        | .next  = next_of(.stage)
        | .last  = ((.events | last | .at) // ($it.delegation.id // "") )
        | .last_sec = ((.events | map(.at | tsec) | max) // 0)
      ]
    | map(select($since == "" or (.last_sec >= ($since | tsec))))
    | map(select($stage == "" or .stage == $stage))
    | map(select($product == "" or .product == $product))
    | map(select($key == "" or .key == $key))
    | sort_by(.last_sec) | reverse | map(del(.last_sec)) | .[]' \
    --slurpfile ledf "$tmp/led.json" --slurpfile mailf "$tmp/mail.json" \
    --slurpfile remotef "$tmp/remote.json" --slurpfile revf "$tmp/rev.json" \
    --slurpfile afkf "$tmp/afk.json" --slurpfile pmapf "$tmp/pmap.json" \
    --arg ws "$ws" --arg since "$since" --arg stage "$want_stage" \
    --arg product "$want_product" --arg key "$want_key"
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# --- rendering -------------------------------------------------------------

# "41m", "2h", "3d" - the age a person reads, never a raw stamp in a column.
work_ago() { # <iso> -> short age
  local t now d
  t="$(date -d "${1:-}" +%s 2>/dev/null)" || { printf '-'; return 0; }
  now="$(date +%s)"; d=$(( now - t ))
  [ "$d" -lt 0 ] && d=0
  if   [ "$d" -lt 3600 ];  then printf '%dm' $(( d / 60 ))
  elif [ "$d" -lt 86400 ]; then printf '%dh' $(( d / 3600 ))
  else printf '%dd' $(( d / 86400 )); fi
}

# `--since 7d` and `--since 2026-01-01` are the same question asked two ways.
_work_since_iso() { # <spec> -> iso, or ""
  local s="${1:-}"
  [ -n "$s" ] || { printf ''; return 0; }
  case "$s" in
    *[0-9]d) date -u -d "${s%d} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '';;
    *[0-9]h) date -u -d "${s%h} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '';;
    *) printf '%s' "$s";;
  esac
}

# The stage order is the factory's sequence, so the board reads top to bottom
# the way the work moves.
_WORK_STAGES='building review landing merged released ready backlog'

_work_board() { # <ws> <items-jsonl>
  local ws="$1" items="$2" n st line
  n="$(printf '%s' "$items" | grep -c . || true)"
  printf '%s - work items%*s%s item(s)\n' "$ws" $(( 30 - ${#ws} > 1 ? 30 - ${#ws} : 1 )) '' "$n"
  for st in $_WORK_STAGES; do
    local rows; rows="$(printf '%s' "$items" | jq -rc --arg s "$st" 'select(.stage == $s)')"
    [ -n "$rows" ] || continue
    printf '%s\n' "$st"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      local key title holder last next
      key="$(printf '%s' "$line" | jq -r '.key')"
      title="$(printf '%s' "$line" | jq -r '.title' | cut -c1-38)"
      holder="$(printf '%s' "$line" | jq -r '
        (.delegation.worker // "") as $w
        | if $w != "" then $w
          elif .pr != null then ("#" + (.pr.number | tostring))
          elif .ticket != null then (.ticket.state // "-")
          else "-" end')"
      last="$(printf '%s' "$line" | jq -r '.last // ""')"
      next="$(printf '%s' "$line" | jq -r '.next')"
      printf '  %-12s %-38s %-14s %5s   %s\n' "$key" "$title" "$holder" "$(work_ago "$last")" "$next"
    done <<< "$rows"
  done
}

_work_one() { # <item-json>
  local it="$1"
  printf '%s  %s\n' "$(printf '%s' "$it" | jq -r '.key')" "$(printf '%s' "$it" | jq -r '.title')"
  printf '  %-11s %s\n' stage "$(printf '%s' "$it" | jq -r '.stage + "   next: " + .next')"
  printf '  %-11s %s\n' keyed-on "$(printf '%s' "$it" | jq -r '.keyed_on')"
  printf '  %-11s %s\n' ticket "$(printf '%s' "$it" | jq -r '
    if .ticket == null then "-" else (.ticket.id + "  " + .ticket.state + "  " + .ticket.url) end')"
  printf '  %-11s %s\n' delegation "$(printf '%s' "$it" | jq -r '
    if .delegation == null then "-" else
      (.delegation.id + "  " + .delegation.state + "  " + .delegation.branch
       + (if (.delegation.worker // "") != "" then "  " + .delegation.worker else "" end)
       + (if .delegation.verdict == null then "" else
            "  gate:" + (.delegation.verdict.gate_outcome
                         // (if .delegation.verdict.gate == true then "pass"
                             elif .delegation.verdict.gate == false then "fail"
                             else "no_verdict" end)) end)) end')"
  printf '  %-11s %s\n' pr "$(printf '%s' "$it" | jq -r '
    if .pr == null then "-" else
      ("#" + (.pr.number | tostring) + "  " + .pr.state
       + (if .pr.review != "" then "  " + .pr.review else "" end)
       + "  checks:" + .pr.checks + "  " + .pr.url) end')"
  printf '  events\n'
  printf '%s' "$it" | jq -r '.events[] | "    \(.at)  \(.source)  \(.what)"'
}

# THE VERTICAL TIMELINE. Events grouped by item with a spine down the left,
# because the question is never "what happened at 14:02" - it is "what
# happened to this one thing", and a flat chronological list makes the eye do
# the grouping the renderer refused to do.
_work_history() { # <ws> <items-jsonl> <since-label>
  local ws="$1" items="$2" label="$3" n line
  n="$(printf '%s' "$items" | jq -s 'map(.events | length) | add // 0')"
  printf '%s - work history%*s%s, %s events\n' "$ws" 12 '' "$label" "$n"
  printf '|\n'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '+- %-9s %-38s %s %s\n' \
      "$(printf '%s' "$line" | jq -r '.key')" \
      "$(printf '%s' "$line" | jq -r '.title' | cut -c1-38)" \
      "$(printf '%s' "$line" | jq -r '.stage')" \
      "$(work_ago "$(printf '%s' "$line" | jq -r '.last // ""')")"
    printf '%s' "$line" | jq -r '.events[] | "|    \(.at)  \(.source | .[0:8])  \(.what)"' \
      | cut -c1-120
    printf '|\n'
  done <<< "$items"
}

# --- the verbs -------------------------------------------------------------

cmd_work() { # [<workspace>] [<key>] [--stage S] [--product P] [--json] [--fresh]
  local ws_arg="" key="" json=0 pass=()
  while [ $# -gt 0 ]; do case "$1" in
    --json)    json=1; shift;;
    --fresh)   pass+=(--fresh); shift;;
    --stage)   pass+=(--stage "$2"); shift 2;;
    --product) pass+=(--product "$2"); shift 2;;
    -*)        die "work: unknown argument '$1'";;
    *) if [ -z "$ws_arg" ] && { [ -f "$1/workspace.yaml" ] || registry_path "$1" >/dev/null 2>&1; }
       then ws_arg="$1"; else key="$1"; fi; shift;;
  esac; done

  local dirs=() d
  if [ -n "$ws_arg" ]; then
    dirs+=("$(work_wsdir "$ws_arg")")
  else
    # NO WORKSPACE NAMED IS EVERY WORKSPACE. "see all the work items" is the
    # question this verb was asked for, and one workspace at a time is what it
    # was asked to replace.
    local n
    for n in $(registry_names); do dirs+=("$(registry_path "$n")"); done
    [ "${#dirs[@]}" -gt 0 ] || die "work: no workspace - name one, or register one with cel ws add"
  fi

  local first=1 items
  for d in "${dirs[@]}"; do
    [ -n "$d" ] && [ -f "$d/workspace.yaml" ] || continue
    if [ -n "$key" ]; then
      items="$(work_items "$d" --key "$key" "${pass[@]+"${pass[@]}"}")"
      [ -n "$items" ] || continue
      if [ "$json" = 1 ]; then printf '%s\n' "$items"; else _work_one "$items"; fi
      return 0
    fi
    items="$(work_items "$d" "${pass[@]+"${pass[@]}"}")"
    if [ "$json" = 1 ]; then
      [ -n "$items" ] && printf '%s\n' "$items"
    else
      [ "$first" = 1 ] || printf '\n'
      _work_board "$(ws_name "$d")" "$items"
    fi
    first=0
  done
  if [ -n "$key" ]; then
    [ "$json" = 1 ] && { printf '\n'; return 0; }
    die "work: no work item with key '$key'"
  fi
  return 0
}

cmd_history() { # [<workspace>] [--since 7d] [--key K] [--json]
  local ws_arg="" since="7d" key="" json=0
  while [ $# -gt 0 ]; do case "$1" in
    --since) since="$2"; shift 2;;
    --key)   key="$2"; shift 2;;
    --json)  json=1; shift;;
    -*)      die "history: unknown argument '$1'";;
    *)       ws_arg="$1"; shift;;
  esac; done

  local dirs=() d n
  # NO WORKSPACE NAMED IS EVERY WORKSPACE, as for `cel work`.
  if [ -n "$ws_arg" ]; then dirs+=("$(work_wsdir "$ws_arg")")
  else for n in $(registry_names); do dirs+=("$(registry_path "$n")"); done; fi

  local iso; iso="$(_work_since_iso "$since")"
  local first=1 items all=""
  for d in "${dirs[@]}"; do
    [ -n "$d" ] && [ -f "$d/workspace.yaml" ] || continue
    items="$(work_items "$d" ${iso:+--since "$iso"} ${key:+--key "$key"})"
    # The GROUPING is the view: one object per item, its events in time order,
    # groups ordered by most recent event. `--json` is the same document, so
    # the console and the dash render identically (the CEL-35 rule).
    items="$(printf '%s' "$items" | jq -c "$_WORK_JQ_DEFS"' . as $i | {key, title, stage, next, ws, product, last,
        events: ($i.events | map(select($since == "" or ((.at | tsec) >= ($since | tsec)))))}
       | select((.events | length) > 0)' --arg since "$iso" 2>/dev/null || true)"
    if [ "$json" = 1 ]; then
      [ -n "$items" ] && all="$all$items"$'\n'
    else
      [ "$first" = 1 ] || printf '\n'
      _work_history "$(ws_name "$d")" "$items" "$since"
    fi
    first=0
  done
  # ONE DOCUMENT, however many workspaces: a single array, each item carrying
  # its ws, newest group first across all of them. One array per workspace
  # printed back to back is not JSON.
  if [ "$json" = 1 ]; then
    printf '%s' "$all" | jq -sc "$_WORK_JQ_DEFS"' sort_by(.last | tsec) | reverse'
  fi
  return 0
}
