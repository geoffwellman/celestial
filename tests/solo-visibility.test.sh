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
# Live lanes show on the solo unit, from the roster the fleet read holds.
test_fleet_shows_a_solo_products_live_lanes() {
  _sv_ws
  local roster
  roster="$(jq -nc --arg a "$T/.cel/solo/bundle/lane-ui" --arg b "$T/.cel/solo/bundle/lane-api" \
    '{result:{agents:[{name:"bundle-ui",cwd:$a,agent_status:"idle"},{name:"bundle-api",cwd:$b,agent_status:"working"}]}}')"
  assert_eq "$(_fleet_unit "$T" bundle "$roster" | jq -c .lanes)" '["api","ui"]'
  local doc='{"box":{"available_mb":1,"total_mb":2},"workspaces":[{"name":"w","root":{"unread":0,"open":0},"units":[
    {"name":"bundle","mode":"solo","orch":"LIVE","workers":0,"cap":4,"stalled":0,"unlanded":0,"rss_mb":0,"orch_rss_mb":5,"repos":["a"],"declared":true,"solo_worktrees":1,"lanes":["api","ui"]}]}]}'
  assert_contains "$(_fleet_render "$doc" | grep bundle)" "lanes: api,ui"
  rm -rf "$T"
}

# --- the ready-PR finder the steward nudges with -----------------------------
H=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# merge: self, so land would merge at all; `suite` is the protected check and
# is green on every head unless SV_RED_CHECK names one.
_sv_gh() { # <pr-list-json>
  printf '%s' "$1" > "$T/list.json"
  sed -i 's/merge: humans-only/merge: self/' "$T/workspace.yaml"
  cat > "$T/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr list") cat "$T/list.json";;
  *) case "\$2" in
       */protection) [ -z "\${SV_NO_PROTECTION:-}" ] && echo '{"required_status_checks":{"contexts":["suite"]}}';;
       *check-runs)  case "\$2" in *"\${SV_RED_CHECK:-none}"*) echo '{"check_runs":[{"name":"suite","conclusion":"failure"}]}';;
                       *) echo '{"check_runs":[{"name":"suite","conclusion":"success"}]}';; esac;;
       *) echo '{}';;
     esac;;
esac
EOF
  chmod +x "$T/gh"; export GH="$T/gh"
}
_pr() { # <num> <review> <rollup> [draft] [mergeable] [head]
  jq -nc --argjson n "$1" --arg r "$2" --arg c "$3" --argjson d "${4:-false}" --arg m "${5:-MERGEABLE}" --arg h "${6:-$H}" \
    '{number:$n, headRefOid:$h, baseRefName:"main", isDraft:$d, mergeable:$m, reviewDecision:$r, statusCheckRollup:[{conclusion:$c}]}'
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
# Never looser than land: humans-only, no readable protection, or the
# protected check not green on the head each mean land would refuse.
test_solo_ready_prs_is_never_looser_than_land() {
  _sv_ws
  _sv_gh "[$(_pr 1 APPROVED SUCCESS)]"
  sed -i 's/merge: self/merge: humans-only/' "$T/workspace.yaml"
  assert_eq "$(solo_ready_prs "$T" bundle)" ""
  sed -i 's/merge: humans-only/merge: self/' "$T/workspace.yaml"
  assert_eq "$(SV_NO_PROTECTION=1 solo_ready_prs "$T" bundle)" ""
  assert_eq "$(SV_RED_CHECK="$H" solo_ready_prs "$T" bundle)" ""
  assert_contains "$(solo_ready_prs "$T" bundle)" "widget	1	$H"
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
  assert_eq "$(grep -c . "$T/mail")" 1
  assert_contains "$(cat "$T/mail")" "send bundle-orch"
  assert_contains "$(cat "$T/mail")" "cel solo land widget#7"
  # still once when the default four-hour window has long passed (five days)
  sed -i "s/^\(solo-ready-[^ ]*\) [0-9]*\$/\1 $(( $(date +%s) - 432000 ))/" "$T/state"
  READY_HEAD="$H" _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 1
  # a new push is a new fact
  READY_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 2
  rm -rf "$T"
}

# --- the dashboard's copy of the alias rule ------------------------------------
# tools/dash/v2.mjs names a solo product's agent with a JS copy of
# cel_alias_norm; they must agree, or the solo tag lands on nobody.
test_dashboard_alias_rule_matches_cel_alias_norm() {
  local n js
  for n in 'bundle-orch' 'Thor Games-orch' 'a__b-orch' '9lives-orch' 'x--y-orch' \
           'a-very-long-product-name-for-testing-orch' 'widget.app-orch'; do
    js="$(node -e '
      const s = process.argv[1];
      let n = String(s).toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/-+/g, "-").replace(/^[^a-z]+/, "");
      console.log(n.length > 32 ? n.slice(0, 32) : n.replace(/-+$/, ""));' "$n")"
    assert_eq "$js" "$(cel_alias_norm "$n")" || { echo "differs for: $n"; return 1; }
  done
  # and that copy is the one the dashboard runs
  grep -qF '.replace(/[^a-z0-9_-]+/g, '"'"'-'"'"').replace(/-+/g, '"'"'-'"'"').replace(/^[^a-z]+/, '"'"''"'"')' "$CEL_ROOT/tools/dash/v2.mjs" \
    || { echo "tools/dash/v2.mjs no longer carries this rule"; return 1; }
}
