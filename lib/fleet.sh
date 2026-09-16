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

# One herdr roster for the whole run. The sweep below asks about every
# orchestrator and every running worker, and a call per question turned a
# read into a visible pause.
_fleet_roster() {
  herdr agent list 2>/dev/null || printf '%s' ''
}

# The ledger is read with jq, deliberately, and not by sourcing cel-fanout:
# cel-fanout is a BINARY that runs a delegation when sourced, not a library.
_fleet_running_rows() { # <wsdir> <repo>
  local led="$1/.cel/delegations.json"
  [ -f "$led" ] || return 0
  jq -c --arg r "$2" '.[]? | select(.repo == $r and .state == "running")' "$led" 2>/dev/null || true
}

# The unit line. `ws_repo_names` is today's unit and products are tomorrow's
# (a later ticket makes that swap), so the rendering lives here and the swap
# is one call site rather than a format rewritten under time pressure.
_fleet_unit_line() { # <label> <orch> <workers> <cap> <stalled> <unlanded>
  printf '  %-12s orch %-5s workers %s/%s   stalled %s   unlanded %s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

# One unit's facts as JSON, so text and --json cannot drift apart: both
# render from this.
_fleet_unit() { # <wsdir> <repo> <roster-json> -> JSON
  local wsdir="$1" repo="$2" roster="$3"
  local orch="-" workers=0 stalled=0 unlanded=0 cap
  cap="$(ws_policy "$wsdir" workers)"; [ -n "$cap" ] || cap=4

  # An empty roster means herdr did not answer. That is not evidence that
  # anyone died - lib/stall.sh learned that the hard way - so with no roster
  # every orchestrator reads as unknown and nothing is convicted.
  local have_roster=0
  [ -n "$roster" ] && have_roster=1

  if [ "$have_roster" = 1 ]; then
    local want status
    want="$(_run_agent_name "$repo-orch")"
    status="$(printf '%s' "$roster" | jq -r --arg n "$want" \
      '[.result.agents[]? | select(.name == $n) | .agent_status // ""][0] // ""' 2>/dev/null || true)"
    if [ -n "$status" ]; then
      case "$status" in
        blocked) orch="blocked" ;;
        *)       orch="LIVE" ;;
      esac
    fi
  fi

  local row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    workers=$((workers + 1))
    local pane wt
    pane="$(printf '%s' "$row" | jq -r '.pane // ""')"
    wt="$(printf '%s' "$row" | jq -r '.worktree // ""')"

    [ -n "$(stall_work_at_risk "$wt")" ] && unlanded=$((unlanded + 1))

    [ "$have_roster" = 1 ] || continue
    local live text quiet
    live="$(printf '%s' "$roster" | jq -r --arg p "$pane" \
      '[.result.agents[]? | select(.pane_id == $p) | .agent_status][0] // ""' 2>/dev/null || true)"
    text=""
    if [ -n "$pane" ] && [ -n "$live" ]; then
      text="$(herdr pane read "$pane" --source detection --lines 40 2>/dev/null || true)"
    fi
    quiet="$(stall_quiet_secs "$wt")"
    [ -n "$(stall_verdict "$live" "$text" "$quiet")" ] && stalled=$((stalled + 1))
  done < <(_fleet_running_rows "$wsdir" "$repo")

  jq -nc --arg name "$repo" --arg orch "$orch" \
    --argjson workers "$workers" --argjson cap "$cap" \
    --argjson stalled "$stalled" --argjson unlanded "$unlanded" \
    '{name: $name, orch: $orch, workers: $workers, cap: $cap, stalled: $stalled, unlanded: $unlanded}'
}

_fleet_workspace() { # <name> <roster-json> -> JSON or nothing
  local ws="$1" roster="$2" wsdir
  wsdir="$(registry_path "$ws")"
  [ -d "$wsdir" ] || return 0
  [ -f "$wsdir/workspace.yaml" ] || return 0

  local unread open units repo
  unread="$(_inbox_count --for root --workspace "$ws" 2>/dev/null || printf 0)"
  [ -n "$unread" ] || unread=0
  open="$(_inbox_open --for root --workspace "$ws" 2>/dev/null | grep -c . || true)"
  [ -n "$open" ] || open=0

  units=""
  for repo in $(ws_repo_names "$wsdir" 2>/dev/null); do
    units="$units$(_fleet_unit "$wsdir" "$repo" "$roster")
"
  done

  printf '%s' "$units" | jq -sc --arg name "$ws" \
    --argjson unread "$unread" --argjson open "$open" \
    '{name: $name, root: {unread: $unread, open: $open}, units: .}'
}

_fleet_render() { # <doc>
  printf '%s' "$1" | jq -r '.workspaces[]
    | "\(.name)   (\(.units | length) repos)   root mail: \(.root.unread) unread, \(.root.open) open"
      as $head
    | [$head] + [.units[] | "UNIT\t\(.name)\t\(.orch)\t\(.workers)\t\(.cap)\t\(.stalled)\t\(.unlanded)"]
    | .[]' \
  | while IFS= read -r line; do
      case "$line" in
        UNIT*)
          IFS=$'\t' read -r _ n o w c s u <<<"$line"
          _fleet_unit_line "$n" "$o" "$w" "$c" "$s" "$u"
          ;;
        *) printf '%s\n' "$line" ;;
      esac
    done
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
  if [ -n "$only" ]; then names="$only"; else names="$(registry_names)"; fi

  for ws in $names; do
    blocks="$blocks$(_fleet_workspace "$ws" "$roster")
"
  done

  local doc
  doc="$(printf '%s' "$blocks" | jq -sc '{workspaces: .}')"
  if [ "$json" -eq 1 ]; then printf '%s\n' "$doc"; else _fleet_render "$doc"; fi
  return 0
}
