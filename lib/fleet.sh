# shellcheck shell=bash
# cel fleet - the whole box in one read.
#
# Every other view is per workspace: `cel-fanout status` needs you standing in
# one, a dashboard serves one, the steward warns about one at a time. So the
# question an operator actually asks first - "what is the state of
# everything?" - was answered by visiting each workspace in turn and holding
# the picture in their head, which is exactly the kind of bookkeeping that
# goes wrong quietly. This is that question as a single deterministic call: no
# tokens, no agent judgement, only numbers that are true at the moment of the
# read.
#
# It is a READ. It never nudges, never writes and always exits 0 (a usage
# error aside), because a view that can change the box is a view people are
# afraid to run.
[ -n "${_CEL_FLEET:-}" ] && return 0
_CEL_FLEET=1
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/inbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/inbox.sh"
# shellcheck source=lib/stall.sh
. "$(dirname "${BASH_SOURCE[0]}")/stall.sh"
# shellcheck source=lib/run.sh
. "$(dirname "${BASH_SOURCE[0]}")/run.sh"
# shellcheck source=lib/memory.sh
. "$(dirname "${BASH_SOURCE[0]}")/memory.sh"

# One herdr roster for the whole run. The sweep below asks about every
# orchestrator and every running worker, and a call per question turned a
# read into a visible pause.
_fleet_roster() {
  herdr agent list 2>/dev/null || printf '%s' ''
}

# The ledger is read with jq, deliberately, and not by sourcing cel-fanout:
# cel-fanout is a BINARY that runs a delegation when sourced, not a library.
# ONLY THE STATES THAT ARE STILL SOMEBODY'S CONCERN. The first cut of this
# list took everything but `released`, and on the live box the unit view
# filled with `landed`, `salvaged` and `orphaned` rows - finished business,
# every one of them rendered as a worker with `live: gone` and no readable
# worktree. A list of things nobody can act on is a list people stop reading,
# and it buried the rows that mattered. `running` is working; `finished` and
# `collected` are waiting on a human to land them or let them go. Everything
# else is history, and history is what `cel-fanout status --json` is for -
# that view still carries every state, `released` included.
_fleet_unit_rows() { # <wsdir> <repo>
  local led="$1/.cel/delegations.json"
  [ -f "$led" ] || return 0
  jq -c --arg r "$2" \
    '.[]? | select(.repo == $r and ((.state // "") | IN("running", "finished", "collected", "blocked")))' \
    "$led" 2>/dev/null || true
}

# How many commits this worktree carries beyond the verified remote default.
# The same answer `cel-fanout status` prints in its AHEAD column, computed the
# same way: unknown stays visible as `?` rather than being flattened to zero,
# because "no commits" and "could not ask" lead an operator to opposite acts.
fleet_ahead() { # <worktree> -> count | ?
  local wt="$1" base n
  [ -d "$wt" ] \
    && git -C "$wt" symbolic-ref --quiet HEAD >/dev/null 2>&1 \
    && base="$(repo_default_ref "$wt")" \
    && n="$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null)" \
    && [[ "$n" =~ ^[0-9]+$ ]] || { printf '?'; return 0; }
  printf '%s' "$n"
}

# ONE LEDGER ROW AS THE THING AN OPERATOR ACTUALLY ASKS ABOUT.
#
# The owner, at the console on 2026-09-18: "when I asked it why one of my
# workers was stalled it just told me to run cel fleet". The view carried a
# stalled COUNT and nothing else - no id, no verdict, no reason - so neither
# the console nor the model could answer from state they were never given.
# This is that state. `cel fleet --json` and `cel-fanout status --json` both
# render from HERE, so the two surfaces cannot describe the same worker
# differently; the shape is a contract the console is written against.
#
# THE VERDICT IS ONLY EVER PASSED ON A RUNNING ROW. A collected or finished
# worker is idle with nothing written since, by design - convicting it of
# being stalled is how a watcher earns its reputation for crying wolf, and it
# would put this list permanently out of step with the `stalled` count beside
# it. An empty `live` (herdr did not answer at all) is not evidence either.
fleet_worker_row() { # <ledger-entry-json> <live> <pane-text> [worktree] [state] -> one JSON object
  local e="$1" live="${2:--}" text="${3:-}"
  [ -n "$live" ] || live="-"
  local wt="${4:-}" state="${5:-}" quiet verdict="" severity="" risk
  # One jq for both when the caller did not already have them: every jq is a
  # process, and at seven per row the fleet spent longer parsing its own
  # ledger than reading the box.
  if [ -z "$wt" ] && [ -z "$state" ]; then
    IFS=$'\t' read -r wt state <<< "$(printf '%s' "$e" | jq -r '[(.worktree // ""), (.state // "")] | @tsv')"
  fi
  # Quiet time is a question about a RUNNING worker. Answering it for every
  # finished and collected row meant a `find` over every worktree on the box
  # on every fleet call - most of the console's start. Those rows show '-'.
  quiet=""
  [ "$state" = running ] && quiet="$(stall_quiet_secs "$wt")"
  if [ "$state" = running ] && [ "$live" != "-" ]; then
    verdict="$(stall_verdict "$live" "$text" "$quiet")"
    risk="$(stall_work_at_risk "$wt")"
    severity="$(stall_severity "$verdict" "$risk")"
  fi
  # -1, not 0: a worktree that cannot be read has an UNKNOWN age, and zero
  # would render as a worker that wrote something a moment ago.
  [ -n "$quiet" ] || quiet=-1
  printf '%s' "$e" | jq -c \
    --arg live "$live" --argjson quiet "$quiet" \
    --arg verdict "$verdict" --arg severity "$severity" \
    --arg ahead "$(fleet_ahead "$wt")" \
    --argjson rss "$(mem_tree_rss_mb "$wt")" \
    --arg harness "${FLEET_HARNESS:-}" \
    '{id: (.id // ""), ticket: (.ticket // ""), repo: (.repo // ""),
      branch: (.branch // ""), shape: (.shape // "ship"), state: (.state // ""),
      live: $live, quiet_secs: $quiet, verdict: $verdict, severity: $severity,
      ahead: $ahead, rss_mb: $rss, pr: (.pr // ""), created: (.created // ""),
      alias: (.alias // ""), pane: (.pane // ""), worktree: (.worktree // ""),
      profile: (.profile // ""), runtime: (.runtime // ""), model: (.model // ""),
      harness: $harness}'
}

# The unit line. The unit is the PRODUCT: the thing one orchestrator stands
# over. A declared product names its repos after itself, because `bundle` on
# its own tells an operator nothing about which checkouts are moving; an
# implicit product IS its repo and renders byte-for-byte as it always has.
_fleet_unit_line() { # <label> <orch> <workers> <cap> <stalled> <unlanded> <mem>
  printf '  %-12s orch %-5s workers %s/%s   stalled %s   unlanded %s   mem %s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# WHERE THE ORCHESTRATOR PANE STANDS, which is the directory its memory is
# attributed to. A declared product has its own directory under products/; an
# implicit product is only a repo checkout. The same derivation lib/steward.sh
# makes for the same reason - identity in this plane comes from paths - and
# reading the wrong one reports zero for a live pane, which an operator cannot
# tell apart from an orchestrator that is not running.
_fleet_orch_dir() { # <wsdir> <product>
  if ws_product_declared "$1" "$2"; then printf '%s/products/%s' "$1" "$2"
  else printf '%s/repos/%s' "$1" "$2"; fi
}

# One unit's facts as JSON, so text and --json cannot drift apart: both
# render from this.
_fleet_unit() { # <wsdir> <product> <roster-json> -> JSON
  local wsdir="$1" product="$2" roster="$3"
  local orch="-" workers=0 stalled=0 unlanded=0 cap declared=false

  local repos=() repo
  while IFS= read -r repo; do
    [ -n "$repo" ] && repos+=("$repo")
  done < <(ws_product_repos "$wsdir" "$product")
  ws_product_declared "$wsdir" "$product" && declared=true

  # THE CAP BELONGS TO THE ORCHESTRATOR, NOT THE REPO - the same precedence
  # `cel-fanout delegate` uses when it refuses a worker. A view that counted
  # per repo would show a two-repo product as half as busy as the thing that
  # actually stops it, and the two numbers people compare must be one number.
  cap="$(ws_product_get "$wsdir" "$product" workers)"
  [ -n "$cap" ] || cap="$(ws_policy "$wsdir" workers)"
  [ -n "$cap" ] || cap=4

  # An empty roster means herdr did not answer. That is not evidence that
  # anyone died - lib/stall.sh learned that the hard way - so with no roster
  # every orchestrator reads as unknown and nothing is convicted.
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
    fi
  fi

  local rss=0 orch_rss
  orch_rss="$(mem_tree_rss_mb "$(_fleet_orch_dir "$wsdir" "$product")")"

  local row rows=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    local pane wt state live="-" text=""
    IFS=$'\t' read -r pane wt state <<< "$(printf '%s' "$row" | jq -r '[(.pane // ""), (.worktree // ""), (.state // "")] | @tsv')"

    local harness=""
    if [ "$have_roster" = 1 ]; then
      # Status AND kind in one read: the kind (pi, omp, claude, hermes) is the
      # harness the ticket runs in, and the roster is the one place that knows
      # it for a row delegated before the ledger recorded a runtime.
      IFS=$'\t' read -r live harness <<< "$(printf '%s' "$roster" | jq -r --arg p "$pane" \
        '[.result.agents[]? | select(.pane_id == $p)][0] // {} | [(.agent_status // ""), (.agent // "")] | @tsv' 2>/dev/null || true)"
      # An agent the roster does not know is GONE, and says so in a word the
      # reader can act on. `-` is reserved for "herdr did not answer", which
      # is a statement about the observer, not the worker.
      [ -n "$live" ] || live=gone
      if [ "$state" = running ] && [ -n "$pane" ] && [ "$live" != gone ]; then
        text="$(herdr pane read "$pane" --source detection --lines 40 2>/dev/null || true)"
      fi
    fi

    if [ "$state" = running ]; then
      workers=$((workers + 1))
      [ -n "$(stall_work_at_risk "$wt")" ] && unlanded=$((unlanded + 1))
    fi

    local obj; obj="$(FLEET_HARNESS="${harness:-}" fleet_worker_row "$row" "$live" "$text" "$wt" "$state")"
    local orss overdict
    IFS=$'\t' read -r orss overdict <<< "$(printf '%s' "$obj" | jq -r '[(.rss_mb // 0), (.verdict // "")] | @tsv')"
    rows="$rows$obj
"
    # The unit's footprint is the sum of its workers' - every state the list
    # carries, not only `running`: a collected worker whose pane is still up
    # is still holding the memory, and hiding it is how 3 GB goes missing
    # between the row and the box.
    rss=$((rss + ${orss:-0}))
    # The count IS the list: counted from the same verdict the row carries, so
    # the two numbers an operator compares can never disagree.
    [ -n "$overdict" ] && stalled=$((stalled + 1))
  done < <(for repo in "${repos[@]}"; do _fleet_unit_rows "$wsdir" "$repo"; done)

  jq -nc --arg name "$product" --arg orch "$orch" \
    --argjson workers "$workers" --argjson cap "$cap" \
    --argjson stalled "$stalled" --argjson unlanded "$unlanded" \
    --argjson repos "$(printf '%s\n' "${repos[@]}" | jq -R . | jq -sc .)" \
    --argjson declared "$declared" \
    --argjson rss "$rss" --argjson orch_rss "$orch_rss" \
    --argjson list "$(printf '%s' "$rows" | jq -sc .)" \
    '{name: $name, orch: $orch, workers: $workers, cap: $cap, stalled: $stalled, unlanded: $unlanded, rss_mb: $rss, orch_rss_mb: $orch_rss, repos: $repos, declared: $declared, workers_list: $list}'
}

_fleet_workspace() { # <name> <roster-json> -> JSON or nothing
  local ws="$1" roster="$2" wsdir
  wsdir="$(registry_path "$ws")"
  [ -d "$wsdir" ] || return 0
  [ -f "$wsdir/workspace.yaml" ] || return 0

  local unread open units product
  unread="$(_inbox_count --for root --workspace "$ws" 2>/dev/null || printf 0)"
  [ -n "$unread" ] || unread=0
  open="$(_inbox_open --for root --workspace "$ws" 2>/dev/null | grep -c . || true)"
  [ -n "$open" ] || open=0

  units=""
  for product in $(ws_product_names "$wsdir" 2>/dev/null); do
    units="$units$(_fleet_unit "$wsdir" "$product" "$roster")
"
  done

  printf '%s' "$units" | jq -sc --arg name "$ws" \
    --argjson unread "$unread" --argjson open "$open" \
    '{name: $name, root: {unread: $unread, open: $open}, units: .}'
}

_fleet_render() { # <doc>
  local free total
  free="$(mem_human "$(printf '%s' "$1" | jq -r '.box.available_mb // 0')")"
  total="$(mem_human "$(printf '%s' "$1" | jq -r '.box.total_mb // 0')")"
  printf '%s' "$1" | jq -r --arg box "box $free free of $total" '.workspaces[]
    | "\(.name)   (\(.units | length) products)   root mail: \(.root.unread) unread, \(.root.open) open   \($box)"
      as $head
    | [$head] + [.units[]
        | (if .declared then "\(.name) (\(.repos | join(", ")))" else .name end) as $label
        | "UNIT\t\($label)\t\(.orch)\t\(.workers)\t\(.cap)\t\(.stalled)\t\(.unlanded)\t\(.rss_mb // 0)"]
    | .[]' \
  | while IFS= read -r line; do
      case "$line" in
        UNIT*)
          IFS=$'\t' read -r _ n o w c s u m <<<"$line"
          _fleet_unit_line "$n" "$o" "$w" "$c" "$s" "$u" "$(mem_human "$m")"
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
_fleet_subscriptions() {
  local dir="${CEL_CACHE:-$HOME/.cache/cel}"
  local f found=""
  for f in "$dir"/subscription-*.json; do
    [ -f "$f" ] || continue
    found="$found$(cat "$f")
"
  done
  printf '%s' "$found" | jq -sc '[.[] | select(type == "object")]' 2>/dev/null || printf '[]'
}

cmd_fleet() {
  local json=0 only=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --workspace) only="${2:-}"; shift 2 ;;
      -h|--help) printf 'usage: cel fleet [--json] [--workspace <name>]\n'; return 0 ;;
      *) die "cel fleet: unknown argument '$1'" ;;
    esac
  done

  local roster names ws blocks=""
  roster="$(_fleet_roster)"
  # ONE /proc WALK FOR THE WHOLE READ. Every worker, every orchestrator and
  # the box's own total are answered from this one snapshot; a walk per
  # question made the cost of the view scale with the number of workers, which
  # is the one thing a view of the workers must not do.
  mem_tree_snapshot
  if [ -n "$only" ]; then names="$only"; else names="$(registry_names)"; fi

  for ws in $names; do
    blocks="$blocks$(_fleet_workspace "$ws" "$roster")
"
  done

  local total avail used doc
  read -r total avail used <<<"$(mem_box)"
  doc="$(printf '%s' "$blocks" | jq -sc \
    --argjson total "${total:-0}" --argjson avail "${avail:-0}" --argjson used "${used:-0}" \
    --argjson subs "$(_fleet_subscriptions)" \
    '{workspaces: ., subscriptions: $subs}
     | .box = {total_mb: $total, available_mb: $avail, used_pct: $used,
               agents_rss_mb: ([.workspaces[].units[] | (.rss_mb // 0) + (.orch_rss_mb // 0)] | add // 0)}')"
  mem_tree_snapshot_clear
  if [ "$json" -eq 1 ]; then printf '%s\n' "$doc"; else _fleet_render "$doc"; fi
  return 0
}
