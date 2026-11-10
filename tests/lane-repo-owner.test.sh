# shellcheck shell=bash
# A REPO A LANE OWNS. `repos[].lane: <lane>` in workspace.yaml says that one
# solo lane owns the repo's PRs; ws_repo_pr_owner (lib/workspace.sh) is the one
# answer to "who owns repo R's PRs", and every per-PR steward nudge and every
# reviewer's "send findings to" asks it. A lane that is not running hands the
# nudge back to the product agent, with a note once per head.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/steward.sh"
source "$CEL_ROOT/lib/doctor.sh"

LO_H=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
LO_H2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# `bundle` (widget + gadget) and `lone`; widget belongs to lane `ui` unless
# LO_NO_LANE is set. Mail is recorded, never sent.
_lo_ws() {
  T="$(mktemp -d)"
  cp "$CEL_ROOT/tests/fixtures/ws-products/workspace.yaml" "$T/"
  if [ -z "${LO_NO_LANE:-}" ]; then
    yq -y '(.repos[] | select(.name == "widget")).lane = "ui"' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  fi
  mkdir -p "$T/repos/widget" "$T/repos/gadget" "$T/repos/lone" "$T/.cel/solo/bundle/lane-ui"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox"; registry_add demo "$T" ""
  mkdir -p "$CEL_INBOX_DIR"
  CEL_STEWARD_STATE="$T/state" _STEWARD_STATE="$T/state"
  : > "$T/mail"
  cmd_inbox() { printf '%s\n' "$*" >> "$T/mail"; }
  LANE_UP="$(jq -nc --arg c "$T/.cel/solo/bundle/lane-ui" '{result: {agents: [
    {name: "bundle-orch", agent_status: "idle", pane_id: "w:p2", cwd: "/elsewhere"},
    {name: "bundle-ui", agent_status: "idle", pane_id: "w:p3", cwd: $c}]}}')"
  LANE_DOWN='{"result":{"agents":[{"name":"bundle-orch","agent_status":"idle","pane_id":"w:p2","cwd":"/elsewhere"}]}}'
}

# --- the resolver ------------------------------------------------------------
test_repo_pr_owner_is_the_declared_lane_and_the_product_agent_otherwise() {
  _lo_ws
  assert_eq "$(ws_repo_pr_owner "$T" widget)" "bundle-ui"
  assert_eq "$(ws_repo_pr_owner "$T" gadget)" "bundle-orch"
  assert_eq "$(ws_repo_pr_owner "$T" lone)" "lone-orch"
  # a default stands in for the product agent, never for a declared lane
  assert_eq "$(ws_repo_pr_owner "$T" gadget bundle-api)" "bundle-api"
  assert_eq "$(ws_repo_pr_owner "$T" widget bundle-api)" "bundle-ui"
  rm -rf "$T"
}

# What is not a lane name (cel run solo --lane refuses it) names no lane.
test_repo_pr_owner_ignores_what_is_not_a_lane_name() {
  _lo_ws
  local v
  for v in '"Slot Builder"' '"orch"' '"-ui"' '["ui"]' '7'; do
    yq -y "(.repos[] | select(.name == \"widget\")).lane = $v" "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
    assert_eq "$(ws_repo_pr_owner "$T" widget)" "bundle-orch" || { echo "lane: $v"; rm -rf "$T"; return 1; }
  done
  rm -rf "$T"
}

# workspace.local.yaml is personal routing; who owns a repo's PRs is the
# team's contract, so the overlay cannot set it - and doctor says so.
test_a_local_overlay_cannot_declare_a_repos_lane() {
  LO_NO_LANE=1 _lo_ws
  printf 'repos:\n  - name: widget\n    lane: ui\n' > "$T/workspace.local.yaml"
  assert_eq "$(ws_repo_pr_owner "$T" widget)" "bundle-orch"
  assert_contains "$(doctor_ws_local_lines "$T" demo 2>&1 || true)" "'lane'"
  source "$CEL_ROOT/lib/run.sh"
  assert_contains "$(CEL_ROLE='' CEL_INBOX_ME='' _run_reviewer_solo_brief "$T" widget 7)" "send findings and your verdict to \`bundle-orch\`"
  rm -rf "$T"
}

# --- the review sweep (forge review decision, red checks, no ticket) ---------
_lo_pr() { # <num> <branch> <head> <APPROVED|CHANGES_REQUESTED|""> <failing 0|1>
  jq -nc --argjson n "$1" --arg b "$2" --arg h "$3" --arg d "$4" --argjson f "$5" '
    {number: $n, headRefName: $b, headRefOid: $h, reviewDecision: $d, isDraft: false,
     statusCheckRollup: (if $f == 1 then [{conclusion: "FAILURE"}] else [] end),
     createdAt: "2020-01-01T00:00:00Z", labels: [],
     reviews: (if $d == "" then [] else [{state: $d, submittedAt: "2020-01-02T00:00:00Z", commit: {oid: $h}}] end)}'
}
_lo_gh() { # <widget-prs-json> <gadget-prs-json>
  mkdir -p "$T/bin"
  printf '%s' "$1" > "$T/widget.json"; printf '%s' "$2" > "$T/gadget.json"
  cat > "$T/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"--repo someone/widget"*) cat "$T/widget.json" ;;
  *"--repo someone/gadget"*) cat "$T/gadget.json" ;;
  *) echo '[]' ;;
esac
SH
  chmod +x "$T/bin/gh"
}
_lo_linear() {
  yq -y '.tickets = {system: "linear"}' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
}

test_review_sweep_sends_a_lane_owned_repos_pr_nudges_to_the_lane() {
  _lo_ws; _lo_linear
  _lo_gh "[$(_lo_pr 7 WG-1-a h7 APPROVED 0),$(_lo_pr 8 WG-2-b h8 CHANGES_REQUESTED 0),$(_lo_pr 9 WG-3-c h9 "" 1),$(_lo_pr 10 no-ticket h10 "" 0)]" \
         "[$(_lo_pr 4 WGT-1-d h4 "" 1)]"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LANE_UP" >/dev/null
  local lane orch
  lane="$(grep '^send bundle-ui ' "$T/mail" || true)"; orch="$(grep '^send bundle-orch ' "$T/mail" || true)"
  assert_contains "$lane" "PR #7 on widget is APPROVED" || { cat "$T/mail"; rm -rf "$T"; return 1; }
  assert_contains "$lane" "PR #8 on widget has changes requested" || { rm -rf "$T"; return 1; }
  assert_contains "$lane" "PR #9 on widget has FAILING checks" || { rm -rf "$T"; return 1; }
  assert_contains "$lane" "PR #10 on widget (no-ticket) has no WG ticket" || { rm -rf "$T"; return 1; }
  # other repos are unchanged: the product agent's
  assert_contains "$orch" "PR #4 on gadget has FAILING checks" || { rm -rf "$T"; return 1; }
  case "$orch" in *widget*) echo "a lane-owned PR went to the product agent: $orch"; rm -rf "$T"; return 1 ;; esac
  case "$lane" in *gadget*) echo "another repo's PR went to the lane: $lane"; rm -rf "$T"; return 1 ;; esac
  case "$(cat "$T/mail")" in *"not running"*) echo "a live lane was called down"; rm -rf "$T"; return 1 ;; esac
  rm -rf "$T"
}

# The lane is not running: its nudges go to the product agent, and the first
# one for each head says why - never silence, never the note twice for a head.
test_review_sweep_falls_back_to_the_product_agent_with_a_note_once_per_head() {
  _lo_ws
  _lo_gh "[$(_lo_pr 9 WG-3-c h9 "" 1)]" "[]"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LANE_DOWN" >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 1 || { cat "$T/mail"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/mail")" "send bundle-orch steward: PR #9 on widget has FAILING checks" || { cat "$T/mail"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/mail")" "bundle-ui" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/mail")" "not running" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/mail")" "cel run solo --product bundle --lane ui" || { rm -rf "$T"; return 1; }
  # the nudge's window passes (still the same head): the nudge again, no note
  sed -i '/#9-red /d' "$T/state"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LANE_DOWN" >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 2 || { rm -rf "$T"; return 1; }
  assert_contains "$(sed -n 2p "$T/mail")" "send bundle-orch steward: PR #9 on widget has FAILING checks" || { rm -rf "$T"; return 1; }
  case "$(sed -n 2p "$T/mail")" in *"not running"*) echo "the note was said twice for one head"; rm -rf "$T"; return 1 ;; esac
  # a push: a new head, the note once more
  _lo_gh "[$(_lo_pr 9 WG-3-c h9b "" 1)]" "[]"
  sed -i '/#9-red /d' "$T/state"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LANE_DOWN" >/dev/null
  assert_contains "$(sed -n 3p "$T/mail")" "not running" || { cat "$T/mail"; rm -rf "$T"; return 1; }
  assert_eq "$(grep -c '^send bundle-ui ' "$T/mail" || true)" 0
  rm -rf "$T"
}

# A lane is running only as itself in its own directory: the right name in
# a deleted directory is not it.
test_a_lane_in_a_deleted_directory_is_not_running() {
  _lo_ws
  _lo_gh "[$(_lo_pr 9 WG-3-c h9 "" 1)]" "[]"
  local roster
  roster="$(jq -nc --arg c "$T/.cel/solo/bundle/lane-ui (deleted)" '{result: {agents: [{name: "bundle-ui", agent_status: "idle", pane_id: "w:p3", cwd: $c}]}}')"
  PATH="$T/bin:$PATH" _steward_review_sweep "$roster" >/dev/null
  assert_contains "$(cat "$T/mail")" "send bundle-orch " || { cat "$T/mail"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# --- the solo sweep (ready to land, recorded `changes` verdict) --------------
_lo_solo() {
  source "$CEL_ROOT/lib/solo.sh"
  printf '{}' > "$T/.cel/solo-reviews.json"
  solo_ready_prs() { [ "$2" = bundle ] && printf 'widget\t7\t%s\ngadget\t4\t%s\n' "$LO_H" "$LO_H"; }
  _steward_solo_changes() { [ "$3" = bundle ] && printf 'widget\t8\t%s\twidget-pr-8-review\tthe cart crashes\n' "$LO_H"; }
}

test_solo_sweep_sends_a_lane_owned_repos_ready_and_changes_nudges_to_the_lane() {
  _lo_ws; _lo_solo
  _steward_solo_sweep "$LANE_UP" >/dev/null
  assert_contains "$(grep '^send bundle-ui ' "$T/mail")" "widget#7 is approved at its current head and every check is green - land it: cel solo land widget#7" || { cat "$T/mail"; rm -rf "$T"; return 1; }
  assert_contains "$(grep '^send bundle-ui ' "$T/mail")" "widget#8 has a recorded \`changes\` verdict" || { rm -rf "$T"; return 1; }
  assert_contains "$(grep '^send bundle-orch ' "$T/mail")" "gadget#4 is approved" || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -c '^send bundle-orch ' "$T/mail")" 1
  # a roster that could not be read is not proof the lane is gone: its mailbox
  : > "$T/mail"; rm -f "$T/state"
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c '^send bundle-ui ' "$T/mail")" 2 || { cat "$T/mail"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_solo_sweep_falls_back_to_the_product_agent_with_a_note_once_per_head() {
  _lo_ws; _lo_solo
  _steward_solo_sweep "$LANE_DOWN" >/dev/null
  local mail; mail="$(cat "$T/mail")"
  assert_eq "$(grep -c '^send bundle-ui ' "$T/mail" || true)" 0
  assert_contains "$(grep 'widget#7' "$T/mail")" "send bundle-orch" || { echo "$mail"; rm -rf "$T"; return 1; }
  assert_contains "$(grep 'widget#7' "$T/mail")" "not running" || { echo "$mail"; rm -rf "$T"; return 1; }
  assert_contains "$(grep 'widget#8' "$T/mail")" "send bundle-orch" || { rm -rf "$T"; return 1; }
  assert_contains "$(grep 'widget#8' "$T/mail")" "not running" || { rm -rf "$T"; return 1; }
  case "$(grep 'gadget#4' "$T/mail")" in *"not running"*) echo "a note on a repo no lane owns"; rm -rf "$T"; return 1 ;; esac
  # once per head: a second tick says nothing new
  _steward_solo_sweep "$LANE_DOWN" >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 3
  rm -rf "$T"
}

# --- reviewers ---------------------------------------------------------------
# Whoever starts it, a reviewer of a lane-owned repo's PR sends its findings
# to that lane; elsewhere the solo agent that started it, else the product's.
test_reviewer_of_a_lane_owned_repo_sends_findings_to_the_lane() {
  _lo_ws
  source "$CEL_ROOT/lib/run.sh"
  cel_agent_list() { printf '%s' "$LANE_UP"; }
  assert_contains "$(CEL_ROLE=solo CEL_INBOX_ME=bundle-orch _run_reviewer_solo_brief "$T" widget 7)" "send findings and your verdict to \`bundle-ui\`"
  assert_contains "$(CEL_ROLE='' CEL_INBOX_ME='' _run_reviewer_solo_brief "$T" widget 7)" "send findings and your verdict to \`bundle-ui\`"
  assert_contains "$(CEL_ROLE=solo CEL_INBOX_ME=bundle-api _run_reviewer_solo_brief "$T" gadget 4)" "send findings and your verdict to \`bundle-api\`"
  assert_contains "$(CEL_ROLE='' CEL_INBOX_ME='' _run_reviewer_solo_brief "$T" gadget 4)" "send findings and your verdict to \`bundle-orch\`"
  rm -rf "$T"
}

# THE LANE IS DOWN AS THE REVIEW STARTS: the findings still go to the lane -
# its mailbox keeps them until it runs, and they are its work - and the
# reviewer also copies its verdict line to the product agent, saying the lane
# is down, so the re-route is visible and the PR is not stranded. A roster
# that cannot be read proves nothing: no copy.
test_reviewer_of_a_down_lanes_repo_names_the_lane_and_copies_the_product_agent() {
  _lo_ws
  source "$CEL_ROOT/lib/run.sh"
  local b
  cel_agent_list() { printf '%s' "$LANE_DOWN"; }
  b="$(CEL_ROLE='' CEL_INBOX_ME='' _run_reviewer_solo_brief "$T" widget 7)"
  assert_contains "$b" "send findings and your verdict to \`bundle-ui\`" || { rm -rf "$T"; return 1; }
  assert_contains "$b" "\`bundle-ui\` is not running" || { echo "$b"; rm -rf "$T"; return 1; }
  assert_contains "$b" "copy your verdict line to \`bundle-orch\`" || { echo "$b"; rm -rf "$T"; return 1; }
  # a repo no lane owns: no copy, whatever the roster says
  case "$(_run_reviewer_solo_brief "$T" gadget 4)" in *"copy your verdict"*) echo "a copy asked for on a repo no lane owns"; rm -rf "$T"; return 1 ;; esac
  # the lane is running: no copy
  cel_agent_list() { printf '%s' "$LANE_UP"; }
  case "$(_run_reviewer_solo_brief "$T" widget 7)" in *"copy your verdict"*) echo "a copy asked for while the lane runs"; rm -rf "$T"; return 1 ;; esac
  # an unreadable roster: the lane, no copy
  cel_agent_list() { return 1; }
  b="$(_run_reviewer_solo_brief "$T" widget 7)"
  assert_contains "$b" "send findings and your verdict to \`bundle-ui\`" || { rm -rf "$T"; return 1; }
  case "$b" in *"copy your verdict"*) echo "an unreadable roster read as a down lane"; rm -rf "$T"; return 1 ;; esac
  rm -rf "$T"
}

# A lane-down note is said once per head - but only once it has been SAID: a
# send that fails leaves it owed, so the next nudge for that head carries it.
test_a_failed_send_does_not_spend_the_lane_down_note() {
  _lo_ws
  _lo_gh "[$(_lo_pr 9 WG-3-c h9 "" 1)]" "[]"
  cmd_inbox() { return 1; }
  PATH="$T/bin:$PATH" _steward_review_sweep "$LANE_DOWN" >/dev/null 2>&1
  if grep -q '^lane-down-' "$T/state" 2>/dev/null; then echo "the note was marked sent by a failed send"; rm -rf "$T"; return 1; fi
  cmd_inbox() { printf '%s\n' "$*" >> "$T/mail"; }
  sed -i '/#9-red /d' "$T/state"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LANE_DOWN" >/dev/null
  assert_contains "$(cat "$T/mail")" "not running" || { cat "$T/mail"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/state")" "lane-down-" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# --- the policy every agent reads --------------------------------------------
test_policy_block_says_which_lane_owns_a_repos_prs() {
  _lo_ws
  assert_contains "$(ws_policy_block "$T" | grep '^- repo widget:')" "its PRs belong to lane \`bundle-ui\`"
  case "$(ws_policy_block "$T" | grep '^- repo gadget:')" in *lane*) echo "a lane named on a repo no lane owns"; rm -rf "$T"; return 1 ;; esac
  rm -rf "$T"
}

# The policy's review line, read by every agent, says where findings go on a
# repo a lane owns - never only "to you (<product>-orch)".
test_policy_review_line_names_the_lane_for_its_repo() {
  _lo_ws
  yq -y '.review = {model: "sonnet"}' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  local line; line="$(ws_policy_block "$T" | grep '^- pr review:')"
  assert_contains "$line" "on widget, to lane \`bundle-ui\`" || { echo "$line"; rm -rf "$T"; return 1; }
  yq -y 'del(.repos[] | select(.name == "widget") | .lane)' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  line="$(ws_policy_block "$T" | grep '^- pr review:')"
  case "$line" in *lane*) echo "a lane named with none declared: $line"; rm -rf "$T"; return 1 ;; esac
  rm -rf "$T"
}

# --- doctor --------------------------------------------------------------------
# The lane must be real: a lane-state record (the lane's own directory, which
# `cel run solo --lane` creates) or a name that cannot be one is warned about.
test_doctor_repo_lane_lines_checks_the_lane_is_real() {
  _lo_ws
  assert_eq "$(doctor_repo_lane_lines "$T" demo)" ""
  rm -rf "$T/.cel/solo/bundle/lane-ui"
  local out; out="$(doctor_repo_lane_lines "$T" demo)"
  assert_contains "$out" "demo/widget: repos[].lane 'ui'" || { echo "$out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cel run solo --product bundle --lane ui" || { echo "$out"; rm -rf "$T"; return 1; }
  yq -y '(.repos[] | select(.name == "widget")).lane = "Slot Builder"' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  out="$(doctor_repo_lane_lines "$T" demo)"
  assert_contains "$out" "is not a lane name" || { echo "$out"; rm -rf "$T"; return 1; }
  yq -y '(.repos[] | select(.name == "widget")).lane = "a-very-long-lane-name-that-is-cut"' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  mkdir -p "$T/.cel/solo/bundle/lane-a-very-long-lane-name-that-is-cut"
  out="$(doctor_repo_lane_lines "$T" demo)"
  assert_contains "$out" "32 characters" || { echo "$out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
