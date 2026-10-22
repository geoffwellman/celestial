# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/fleet.sh"
source "$CEL_ROOT/lib/solo.sh"

# A products workspace with `bundle` (widget+gadget) in solo mode; `lone`
# stays fleet.
_sv_ws() {
  T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-products/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget" "$T/repos/gadget" "$T/repos/lone" "$T/.cel"
  ( cd "$T" && cmd_mode bundle solo --no-restart ) >/dev/null
}

# --- fleet -------------------------------------------------------------------
# A solo unit says so, and counts the worktrees its agent keeps instead of
# workers it has none of.
test_fleet_unit_carries_the_mode_and_the_solo_worktrees() {
  _sv_ws
  mkdir -p "$T/.cel/solo/bundle/feat-a" "$T/.cel/solo/bundle/feat-b" "$T/.cel/solo/bundle/scratch"
  : > "$T/.cel/solo/bundle/feat-a/.git"; : > "$T/.cel/solo/bundle/feat-b/.git"   # scratch is no worktree
  local u; u="$(_fleet_unit "$T" bundle "")"
  assert_eq "$(printf '%s' "$u" | jq -r .mode)" solo
  assert_eq "$(printf '%s' "$u" | jq -r .solo_worktrees)" 2
  u="$(_fleet_unit "$T" lone "")"
  assert_eq "$(printf '%s' "$u" | jq -r .mode)" fleet
  assert_eq "$(printf '%s' "$u" | jq -r .solo_worktrees)" 0
  rm -rf "$T"
}
test_fleet_text_draws_a_solo_unit_without_worker_counts() {
  local doc out
  doc='{"box":{"available_mb":1,"total_mb":2},"workspaces":[{"name":"w","root":{"unread":0,"open":0},"units":[
    {"name":"bundle","mode":"solo","orch":"LIVE","workers":0,"cap":4,"stalled":0,"unlanded":0,"rss_mb":0,"orch_rss_mb":5,"repos":["a","b"],"declared":true,"solo_worktrees":3},
    {"name":"lone","mode":"fleet","orch":"-","workers":1,"cap":4,"stalled":0,"unlanded":0,"rss_mb":0,"repos":["lone"],"declared":false}]}]}'
  out="$(_fleet_render "$doc")"
  assert_contains "$(printf '%s\n' "$out" | grep bundle)" "solo LIVE  worktrees 3"
  ! printf '%s\n' "$out" | grep bundle | grep -q 'workers' || { echo "solo row counts workers"; return 1; }
  assert_contains "$(printf '%s\n' "$out" | grep lone)" "workers 1/4"
}

# --- the ready-PR finder the steward nudges with -----------------------------
H=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
_sv_gh() { # <pr-list-json>
  printf '%s' "$1" > "$T/list.json"
  cat > "$T/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr list") cat "$T/list.json";;
  *) echo '{}';;
esac
EOF
  chmod +x "$T/gh"; export GH="$T/gh"
}
_pr() { # <num> <review> <rollup> [draft] [mergeable] [head]
  jq -nc --argjson n "$1" --arg r "$2" --arg c "$3" --argjson d "${4:-false}" --arg m "${5:-MERGEABLE}" --arg h "${6:-$H}" \
    '{number:$n, headRefOid:$h, isDraft:$d, mergeable:$m, reviewDecision:$r, statusCheckRollup:[{conclusion:$c}]}'
}
test_solo_ready_prs_lists_only_what_land_would_merge() {
  _sv_ws
  _sv_gh "[$(_pr 1 APPROVED SUCCESS),$(_pr 2 APPROVED FAILURE),$(_pr 3 APPROVED SUCCESS true),$(_pr 4 APPROVED SUCCESS false CONFLICTING),$(_pr 5 REVIEW_REQUIRED SUCCESS),$(_pr 6 "" SUCCESS)]"
  # #6 has no GitHub approval but a recorded verdict for its exact head
  printf '{"widget#6":{"verdict":"approved","head":"%s"}}' "$H" > "$T/.cel/solo-reviews.json"
  local got; got="$(solo_ready_prs "$T" bundle | awk -F'\t' '$1=="widget"{print $2}' | sort -n | paste -sd, -)"
  assert_eq "$got" "1,6"
  rm -rf "$T"
}
test_solo_ready_prs_needs_the_verdict_for_the_current_head() {
  _sv_ws
  _sv_gh "[$(_pr 6 "" SUCCESS)]"
  printf '{"widget#6":{"verdict":"approved","head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}' > "$T/.cel/solo-reviews.json"
  assert_eq "$(solo_ready_prs "$T" bundle)" ""
  rm -rf "$T"
}

# --- the steward ---------------------------------------------------------------
# The product's own agent is told, once per head; the steward lands nothing.
test_steward_nudges_a_solo_agent_once_per_ready_head() {
  source "$CEL_ROOT/lib/steward.sh"
  _sv_ws
  export CEL_REGISTRY="$T/registry.yaml"; registry_add demo "$T" ""
  CEL_STEWARD_STATE="$T/state" _STEWARD_STATE="$T/state"
  solo_ready_prs() { [ "$2" = bundle ] && printf 'widget\t7\t%s\n' "${READY_HEAD:-$H}"; }
  cmd_inbox() { printf '%s\n' "$*" >> "$T/mail"; }
  READY_HEAD="$H" _steward_solo_sweep >/dev/null
  READY_HEAD="$H" _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 1
  assert_contains "$(cat "$T/mail")" "send bundle-orch"
  assert_contains "$(cat "$T/mail")" "cel solo land widget#7"
  # a new push is a new fact
  READY_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 2
  rm -rf "$T"
}
