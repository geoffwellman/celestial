# shellcheck shell=bash
# ONE BOX-WIDE HELPER BUDGET. Every agent the plane starts costs memory and
# attention, and the pressure that retired fan-out came from starting one per
# ticket. So a team member or a reviewer is started only while the box holds
# fewer live HELPERS than `budget.max_live_agents` (default 8) - a team member
# also only while fewer than `budget.max_team_members` (default 4) members are
# live - and only while the memory floor admits it (boxguard_admit).
#
# A helper is what a product launches beside itself: reviewers, team members
# and any other agent on the roster. Product agents (<product>-orch, solo
# lanes) and core/root are the box's standing crew, not helpers: they are
# shown (cel budget) but never counted, so a box running ten products still
# has the whole helper budget for their reviewers. Product agents are never
# blocked; only the memory floor warns them (lib/run.sh).
#
# The count is the native inventory (cel_agent_list: herdr + managed Rex),
# not a ledger: a ledger can say an agent is gone that is still running. An
# inventory that cannot be read is UNKNOWN, and unknown refuses - "could not
# count" never means "room to spare".
[ -n "${_CEL_BUDGET:-}" ] && return 0
_CEL_BUDGET=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/config.sh
. "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/boxguard.sh
. "${BASH_SOURCE[0]%/*}/boxguard.sh"   # boxguard_admit, _boxguard_cfg: the memory floor and the config rule
# shellcheck source=lib/rex.sh
. "${BASH_SOURCE[0]%/*}/rex.sh"        # cel_agent_list: the one native inventory

# Limits: env first (the suite), then ~/.local/share/cel/config.yaml `budget:`,
# then the default - the same rule as the memory thresholds.
budget_max_live_agents() { _boxguard_cfg "${CEL_BUDGET_MAX_LIVE_AGENTS:-}" budget max_live_agents 8; }
budget_max_team_members() { _boxguard_cfg "${CEL_BUDGET_MAX_TEAM_MEMBERS:-}" budget max_team_members 4; }

# WHO IS LIVE, BY ROLE. A Rex row says its role; a herdr row is classified by
# what cel run named it and where it stands:
#   team member  stands under <ws>/.cel/teams/ (its worktree or its team dir)   helper
#   reviewer     <repo>-pr-<n>-review, <repo>-pr-<n>-review-<focus>             helper
#   core/root    core, <ws>-root                                                not counted
#   product      <product>-orch, or a solo lane (<ws>/.cel/solo/<p>/lane-<l>)   not counted
#   other        anything else on the roster - still an agent                  helper
_BUDGET_JQ_COUNTS='
  def class:
    ((.role // "") | tostring) as $r | ((.name // "") | tostring) as $n | ((.cwd // "") | tostring) as $c
    | if $r == "member" or ($c | test("/\\.cel/teams/")) then "members"
      elif $r == "reviewer" or ($n | test("-pr-[0-9]+-review(-[a-z0-9_-]*)?$")) then "reviewers"
      elif $r == "core" or $r == "root" or $n == "core" or ($n | test("-root$")) then "core_root"
      elif $r == "orchestrator" or $r == "solo" or ($n | test("-orch$")) or ($c | test("/\\.cel/solo/[^/]+/lane-[^/]+$")) then "products"
      else "other" end;
  .result.agents as $a
  | {total: ($a | length),
     products: ([$a[] | select(class == "products")] | length),
     reviewers: ([$a[] | select(class == "reviewers")] | length),
     members: ([$a[] | select(class == "members")] | length),
     core_root: ([$a[] | select(class == "core_root")] | length),
     other: ([$a[] | select(class == "other")] | length)}
  | .helpers = .reviewers + .members + .other'

# Counts as one JSON object; rc 1 (nothing printed) when the inventory is
# unreadable or not a roster.
budget_counts() { # [agents-json]
  local roster="${1:-}"
  if [ -z "$roster" ]; then roster="$(cel_agent_list 2>/dev/null)" || return 1; fi
  printf '%s' "$roster" | jq -ce '.result.agents | type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$roster" | jq -c "$_BUDGET_JQ_COUNTS" 2>/dev/null
}

_budget_breakdown() { # <counts-json>
  printf '%s' "$1" | jq -r '"reviewers \(.reviewers), team members \(.members), other \(.other); not counted: product \(.products), core/root \(.core_root)"'
}

# 0 = admit. 1 = refuse, with ONE plain sentence on stdout (boxguard_admit's
# convention). <kind>: team-member | reviewer | product. A product agent is
# not a helper, so only the memory floor can answer it, and that answer is the
# caller's warning, never its block. The optional roster is a cel_agent_list
# document the caller has already read for its own checks.
# --pending N counts N team members that are reserved but not launched yet
# (cel team add counts them from every team.json): they are added to the live
# helpers and to the team members before either limit is compared.
budget_admit() { # <kind> [agents-json] [--pending N]
  local kind="${1:-}" roster="" pending=0 counts helpers members max max_members what verdict mem held=""
  [ $# -eq 0 ] || shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --pending) pending="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
      --pending=*) pending="${1#--pending=}"; shift ;;
      *) roster="$1"; shift ;;
    esac
  done
  case "$kind" in
    team-member) what="a team member" ;;
    reviewer)    what="a reviewer" ;;
    product)     what="a product agent" ;;
    *) printf 'box agent budget: unknown launch kind %q - not starting it\n' "$kind"; return 1 ;;
  esac
  [[ "$pending" =~ ^[0-9]+$ ]] \
    || { printf 'box agent budget: --pending wants a count of reserved members, got %q - not starting %s\n' "$pending" "$what"; return 1; }
  verdict="not starting $what"
  [ "$kind" != product ] || verdict="the product agent starts anyway (product agents are not counted, never blocked)"
  if ! counts="$(budget_counts "$roster")" || [ -z "$counts" ]; then
    printf 'box agent budget: the live agent inventory (herdr agent list / Rex receipts) is unreadable, so how many agents run is unknown - %s (fail closed; check herdr, then retry)\n' "$verdict"
    return 1
  fi
  max="$(budget_max_live_agents)"; max_members="$(budget_max_team_members)"
  pending=$((10#$pending))
  helpers=$(( $(printf '%s' "$counts" | jq -r .helpers) + pending ))
  members=$(( $(printf '%s' "$counts" | jq -r .members) + pending ))
  [ "$pending" -eq 0 ] || held=" ($pending reserved, not launched yet)"
  if [ "$kind" != product ] && [ "$helpers" -ge "$max" ]; then
    printf 'box agent budget: %s helper agents live%s, the limit is %s (%s) - %s; retire a team member or a finished reviewer first (cel budget; budget.max_live_agents in %s)\n' \
      "$helpers" "$held" "$max" "$(_budget_breakdown "$counts")" "$verdict" "$(cel_config_file)"
    return 1
  fi
  if [ "$kind" = team-member ] && [ "$members" -ge "$max_members" ]; then
    printf 'box agent budget: %s team members live%s, the limit is %s - not starting another; retire one first (cel budget; budget.max_team_members in %s)\n' \
      "$members" "$held" "$max_members" "$(cel_config_file)"
    return 1
  fi
  if ! mem="$(boxguard_admit)"; then
    if [ "$kind" = product ]; then
      printf '%s (%s)\n' "${mem:-box memory is under the admission floor}" "$verdict"
    else
      printf '%s\n' "${mem:-box memory is under the admission floor - $verdict}"
    fi
    return 1
  fi
  return 0
}

# `cel budget [--json]`: helpers against the limits, every live agent by role
# (product agents and core/root shown, not counted), and the memory floor.
cmd_budget() {
  local json=0 counts max max_members mem="" admit=true
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help) printf 'usage: cel budget [--json]\n'; return 0 ;;
      *) die "cel budget: unknown argument '$1' (usage: cel budget [--json])" ;;
    esac
  done
  have jq || die "cel budget: jq is not on PATH"
  counts="$(budget_counts)" && [ -n "$counts" ] \
    || die "cel budget: the live agent inventory is unreadable - every team-member and reviewer launch is refused until it reads"
  max="$(budget_max_live_agents)"; max_members="$(budget_max_team_members)"
  mem="$(boxguard_admit)" || admit=false
  if [ "$json" = 1 ]; then
    printf '%s' "$counts" | jq -c --argjson max "$max" --argjson mm "$max_members" --argjson ok "$admit" --arg why "$mem" \
      '{live: ., limits: {max_live_agents: $max, max_team_members: $mm}, memory: {admit: $ok, reason: $why}}'
    return 0
  fi
  printf 'helpers       %s of %s  (reviewers %s, team members %s, other %s)\n' \
    "$(printf '%s' "$counts" | jq -r .helpers)" "$max" \
    "$(printf '%s' "$counts" | jq -r .reviewers)" "$(printf '%s' "$counts" | jq -r .members)" "$(printf '%s' "$counts" | jq -r .other)"
  printf 'live agents   %s  (product %s, core/root %s: shown, not counted)\n' \
    "$(printf '%s' "$counts" | jq -r .total)" "$(printf '%s' "$counts" | jq -r .products)" "$(printf '%s' "$counts" | jq -r .core_root)"
  printf 'team members  %s of %s\n' "$(printf '%s' "$counts" | jq -r .members)" "$max_members"
  if [ "$admit" = true ]; then
    printf 'memory        admits\n'
  else
    printf 'memory        refuses: %s\n' "$mem"
  fi
}
