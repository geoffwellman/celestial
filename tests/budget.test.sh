# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/budget.sh"

# ONE BOX-WIDE AGENT BUDGET (lib/budget.sh): team members and reviewers start
# only while the live inventory is under the limits and the memory floor
# admits; unknown inventory refuses; product agents are only warned.

_bud() { # a private herdr roster ($T/roster.json) and no Rex receipts
  T="$(mktemp -d)"; mkdir -p "$T/bin" "$T/rex"
  export CEL_REX_STATE="$T/rex" CEL_CONFIG_FILE="$T/config.yaml"
  printf '{"result":{"agents":[]}}\n' > "$T/roster.json"
  cat > "$T/bin/herdr" <<SH
#!/usr/bin/env bash
[ "\$*" = 'agent list' ] || exit 1
[ -f "$T/herdr-down" ] && exit 1
cat "$T/roster.json"
SH
  chmod +x "$T/bin/herdr"
  export PATH="$T/bin:$PATH"
}
_roster() { # <name|cwd>... : one agent per word; a word with a / is a member's cwd
  local w rows='[]' i=0
  for w in "$@"; do
    i=$((i + 1))
    case "$w" in
      */*) rows="$(jq -c --arg c "$w" --arg p "w1:p$i" '. + [{name:("m" + $p), pane_id:$p, cwd:$c, agent_status:"idle"}]' <<< "$rows")" ;;
      *)   rows="$(jq -c --arg n "$w" --arg p "w1:p$i" '. + [{name:$n, pane_id:$p, cwd:"/x", agent_status:"idle"}]' <<< "$rows")" ;;
    esac
  done
  jq -cn --argjson a "$rows" '{result:{agents:$a}}' > "$T/roster.json"
}

test_budget_admits_under_the_limit() {
  _bud; _roster core alpha-root widget-orch
  local out rc=0
  out="$(budget_admit team-member)" || rc=$?
  assert_eq "$rc:$out" "0:"
  assert_eq "$(budget_admit reviewer >/dev/null; echo $?)" 0
  rm -rf "$T"
}

test_budget_refuses_at_the_limit_for_members_and_reviewers() {
  _bud; _roster core alpha-root a-orch b-orch c-orch widget-pr-1-review widget-pr-2-review stray
  local out rc=0
  out="$(budget_admit team-member)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "8 live agents, the limit is 8"
  assert_contains "$out" "product 3, reviewers 2, team members 0, core/root 2, other 1"
  assert_contains "$out" "not starting a team member"
  rc=0; out="$(budget_admit reviewer)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "not starting a reviewer"
  # one fewer is admitted: the limit is "fewer than", counted exactly
  _roster core alpha-root a-orch b-orch c-orch widget-pr-1-review widget-pr-2-review
  assert_eq "$(budget_admit reviewer >/dev/null; echo $?)" 0
  rm -rf "$T"
}

test_budget_team_member_limit_is_separate() {
  _bud
  _roster widget-orch /w/.cel/teams/login/wt/a /w/.cel/teams/login /w/.cel/teams/login /w/.cel/teams/pay
  local out rc=0
  out="$(budget_admit team-member)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "4 team members live, the limit is 4"
  # a reviewer is not a team member: 5 of 8 admits it
  assert_eq "$(budget_admit reviewer >/dev/null; echo $?)" 0
  rm -rf "$T"
}

test_budget_reads_limits_from_box_config() {
  _bud; _roster core widget-orch
  printf 'budget:\n  max_live_agents: 2\n  max_team_members: 1\n' > "$CEL_CONFIG_FILE"
  local out rc=0
  out="$(budget_admit reviewer)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "2 live agents, the limit is 2"
  assert_eq "$(budget_max_team_members)" 1
  rm -rf "$T"
}

# Unknown is not empty: an unreadable or malformed inventory refuses.
test_budget_refuses_when_the_inventory_is_unreadable() {
  _bud; touch "$T/herdr-down"
  local out rc=0
  out="$(budget_admit team-member)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "inventory"
  assert_contains "$out" "unreadable"
  rm -f "$T/herdr-down"; printf '{"result":{"agents":{}}}\n' > "$T/roster.json"
  rc=0; out="$(budget_admit reviewer)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unreadable"
  rm -rf "$T"
}

test_budget_refuses_under_the_memory_floor() {
  _bud; _roster core
  printf 'MemTotal: 16000000 kB\nMemAvailable: 1024000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$T/meminfo"
  local out rc=0
  out="$(CEL_MEMINFO="$T/meminfo" budget_admit team-member)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "box memory low"
  rm -rf "$T"
}

test_budget_unknown_kind_is_refused() {
  _bud
  assert_eq "$(budget_admit worker >/dev/null; echo $?)" 1
  rm -rf "$T"
}

# Product agents are counted, never blocked: the sentence is a warning.
test_budget_product_kind_says_it_starts_anyway() {
  _bud; _roster a b c d e f g h
  local out rc=0
  out="$(budget_admit product)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "starts anyway"
  rm -rf "$T"
}

test_budget_classifies_by_role() {
  _bud
  local rows
  rows='{"result":{"agents":[
    {"name":"core","pane_id":"a","cwd":"/c"},
    {"name":"alpha-root","pane_id":"b","cwd":"/w"},
    {"name":"widget-orch","pane_id":"c","cwd":"/w/repos/widget"},
    {"name":"widget-ui","pane_id":"d","cwd":"/w/.cel/solo/widget/lane-ui"},
    {"name":"widget-pr-12-review","pane_id":"e","cwd":"/r/widget-pr-12"},
    {"name":"widget-login-builder","pane_id":"f","cwd":"/w/.cel/teams/login/wt/widget-login-builder"},
    {"name":"widget-login-qa","pane_id":"g","cwd":"/w/.cel/teams/login"},
    {"name":"","pane_id":"h","cwd":"/tmp"},
    {"name":"x","pane_id":"rex/s/b","backend":"rex","role":"reviewer","cwd":"/r"}]}}'
  assert_eq "$(budget_counts "$rows")" '{"total":9,"products":2,"reviewers":2,"members":2,"core_root":2,"other":1}'
  rm -rf "$T"
}

test_cel_budget_prints_counts_against_limits() {
  _bud; _roster core widget-orch /w/.cel/teams/login
  local out
  out="$("$CEL_ROOT/bin/cel" budget)"
  assert_contains "$out" "live agents   3 of 8"
  assert_contains "$out" "team members  1 of 4"
  assert_contains "$out" "memory        admits"
  out="$("$CEL_ROOT/bin/cel" budget --json)"
  assert_eq "$(jq -r '[.live.total, .limits.max_live_agents, .live.members, .memory.admit] | @tsv' <<< "$out")" $'3\t8\t1\ttrue'
  touch "$T/herdr-down"
  assert_fails "$CEL_ROOT/bin/cel" budget
  rm -rf "$T"
}
