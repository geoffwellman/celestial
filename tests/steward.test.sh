# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/steward.sh"

# The dedup window is what separates a reminder from spam: first call for a
# key fires and records, an immediate second call for the same key does not,
# a different key does.
test_steward_due_rate_limits_per_key() {
  local T; T="$(mktemp -d)"
  CEL_STEWARD_STATE="$T/state" _STEWARD_STATE="$T/state"
  _steward_due "repo#1-changes"
  assert_fails _steward_due "repo#1-changes"
  _steward_due "repo#2-changes"
  assert_contains "$(cat "$T/state")" "repo#1-changes"
  rm -rf "$T"
}
test_steward_agent_name_matches_cel_run() {
  assert_eq "$(_steward_agent_name 'widget-games/orch')" "widget-games-orch"
}

# A worker's mailbox name and its herdr agent name are the same string by
# construction - that identity is what lets the steward nudge a worker at all,
# so it is asserted rather than assumed. Both go through the same sanitiser
# from <repo>-<branch>; only the separator in the source differs.
test_worker_mailbox_name_is_its_agent_name() {
  source "$CEL_ROOT/lib/inbox.sh"
  source "$CEL_ROOT/lib/run.sh"
  assert_eq "$(_inbox_sanitise 'widget-WG-1-feature')" "$(_run_agent_name 'widget/WG-1-feature')"
  # and a hyphenated repo name survives both intact
  assert_eq "$(_inbox_sanitise 'long-product-name-ABCD-38-x')" "$(_run_agent_name 'long-product-name/ABCD-38-x')"
}
# The mailbox sweep resolved a pane for root and <repo>-orch only, so every
# worker reported "(no pane to nudge)" while its agent sat idle in a live pane.
# Anything that is neither is a worker and is matched by name.
test_worker_mailbox_resolves_to_a_want_name() {
  assert_eq "$(_steward_mailbox_want root alpha)" "alpha-root"
  assert_eq "$(_steward_mailbox_want widget-orch alpha)" "widget-orch"
  assert_eq "$(_steward_mailbox_want widget-wg-1-feature alpha)" "widget-wg-1-feature"
}

# Exercise the real workspace env loader and the whole sweep. The curl
# double records where each key was used, including the GraphQL team.
_ready_workspaces() {
  T="$(mktemp -d)"
  mkdir -p "$T/alpha" "$T/beta"
  export CEL_REGISTRY="$T/registry.yaml"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n  beta: {path: "%s/beta"}\n' "$T" "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\ntickets: {system: linear}\nrepos: [{name: widget, linear_team: ALPHA}]\n' > "$T/alpha/workspace.yaml"
  printf 'name: beta\ntickets: {system: linear}\nrepos: [{name: widget, linear_team: BETA}]\n' > "$T/beta/workspace.yaml"
  printf 'LINEAR_API_KEY=fixture-alpha\nCEL_ISOLATION_MARKER=alpha\n' > "$T/alpha/env.local"
  export CEL_ISOLATION_MARKER=parent
  : > "$T/requests"
  curl() {
    local argv="$*" url="" body="" headers=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -H)
          case "$2" in
            @-) headers="$(cat)" ;;
            Authorization:*) headers="$2" ;;
          esac
          shift 2 ;;
        -d) body="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
      esac
    done
    jq -nc --arg url "$url" --arg argv "$argv" --arg headers "$headers" \
      --argjson body "$body" '{url:$url, argv:$argv, headers:$headers, body:$body}' >> "$T/requests"
    printf '{"data":{"issues":{"nodes":[]}}}'
  }
}

test_ready_workspaces_do_not_share_credentials_or_modify_parent() {
  _ready_workspaces
  unset LINEAR_API_KEY
  _steward_ready_tickets
  assert_eq "${LINEAR_API_KEY+set}" ""
  assert_eq "$CEL_ISOLATION_MARKER" parent
  assert_eq "$(jq -sc '[.[] | [.url, .body.variables.k, .headers]]' "$T/requests")" \
    '[["https://api.linear.app/graphql","ALPHA","Authorization: fixture-alpha"]]'
  assert_eq "$(jq -s '[.[] | .argv | contains("fixture-alpha")] | any' "$T/requests")" false
  assert_eq "$(jq -r '.body.variables.st' "$T/requests")" Ready

  # Giving B its own key must enable B, without changing A's identity.
  printf 'LINEAR_API_KEY=fixture-beta\n' > "$T/beta/env.local"
  : > "$T/requests"
  _steward_ready_tickets
  assert_eq "$(jq -sc '[.[] | [.body.variables.k, .headers]]' "$T/requests")" \
    '[["ALPHA","Authorization: fixture-alpha"],["BETA","Authorization: fixture-beta"]]'
  assert_eq "$(jq -s '[.[] | .argv | test("fixture-alpha|fixture-beta")] | any' "$T/requests")" false
  assert_eq "${LINEAR_API_KEY+set}" ""
  assert_eq "$CEL_ISOLATION_MARKER" parent
  rm -rf "$T"
}

test_ready_workspaces_preserve_explicit_caller_credential_fallback() {
  _ready_workspaces
  export LINEAR_API_KEY=fixture-parent
  _steward_ready_tickets
  assert_eq "$(jq -sc '[.[] | [.body.variables.k, .headers]]' "$T/requests")" \
    '[["ALPHA","Authorization: fixture-alpha"],["BETA","Authorization: fixture-parent"]]'
  assert_eq "$LINEAR_API_KEY" fixture-parent
  assert_eq "$CEL_ISOLATION_MARKER" parent
  rm -rf "$T"
}

# Where does a <p>-orch live? A DECLARED product has its own directory; an
# implicit one is just a repo. The steward cannot read workspace.yaml to tell
# them apart (identity is derived from paths, deliberately), so the
# directory's existence is the test. Both cwd-fallback sweeps share this one
# function so they cannot drift - they had already been written twice.
test_steward_orch_dir_prefers_a_declared_product() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/products/bundle" "$T/repos/lone"
  assert_eq "$(_steward_orch_dir "$T" bundle-orch)" "$T/products/bundle"
  assert_eq "$(_steward_orch_dir "$T" lone-orch)" "$T/repos/lone"
  rm -rf "$T"
}

# --- ensuring orchestrators ------------------------------------------------
# Root used to start the orchestrators by hand, which produced duplicate
# panes and workspaces nobody could tell apart. Starting a declared
# `orchestrator: auto` product is mechanical, so the steward does it the same
# way it ensures a dashboard.
_orch_fixture() { # [roster-json]
  T="$(mktemp -d)"
  export HOME="$T/home"; mkdir -p "$HOME"
  export CEL_REGISTRY="$T/registry.yaml"
  export CEL_INBOX_DIR="$T/inbox"; mkdir -p "$CEL_INBOX_DIR"
  mkdir -p "$T/alpha/repos/widget" "$T/alpha/products/bundle"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  cat > "$T/alpha/workspace.yaml" <<YAML
name: alpha
tickets: {system: linear, trigger_state: Ready}
products:
  - {name: bundle, repos: [widget], orchestrator: auto}
  - {name: lone, repos: [gadget], orchestrator: manual}
repos:
  - {name: widget, url: "git@github.com:someone/widget.git", prefix: WG, linear_team: ALPHA}
  - {name: gadget, url: "git@github.com:someone/gadget.git", prefix: OT, linear_team: ALPHA}
YAML
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
  : > "$T/launched"
  # The launch is one function precisely so a test can replace it: running
  # `cel run` for real would start a pane on the live box.
  _steward_launch_orch() { printf '%s %s\n' "$1" "$2" >> "$T/launched"; return "${STUB_LAUNCH_RC:-0}"; }
  ROSTER='{"result":{"agents":[{"name":"alpha-root","agent_status":"idle","pane_id":"w:p1"}]}}'
  LIVE_ROSTER='{"result":{"agents":[{"name":"bundle-orch","agent_status":"idle","pane_id":"w:p2"}]}}'
}

test_steward_starts_an_auto_orchestrator_once_per_window() {
  _orch_fixture
  local out; out="$(_steward_orchestrators "$ROSTER")"
  assert_contains "$out" "bundle"
  assert_eq "$(cat "$T/launched")" "bundle alpha"
  # a second tick inside the 30 minute window must not launch again
  _steward_orchestrators "$ROSTER" >/dev/null
  assert_eq "$(wc -l < "$T/launched")" "1"
  rm -rf "$T"
}

test_steward_leaves_live_manual_and_unknown_orchestrators_alone() {
  _orch_fixture
  _steward_orchestrators "$LIVE_ROSTER" >/dev/null   # bundle-orch already up
  assert_eq "$(cat "$T/launched")" ""
  # `lone` is manual and is never started, live or not
  assert_eq "$(grep -c lone "$T/launched" || true)" "0"
  rm -rf "$T"
}

# Herdr unreachable reads as an empty roster, and an empty roster is not
# evidence that anyone died - every other sweep here learned that already.
test_steward_starts_nothing_when_the_roster_is_empty() {
  _orch_fixture
  _steward_orchestrators '{"result":{"agents":[]}}' >/dev/null
  assert_eq "$(cat "$T/launched")" ""
  rm -rf "$T"
}

test_steward_reports_a_failed_orchestrator_launch() {
  _orch_fixture
  local out; out="$(STUB_LAUNCH_RC=1 _steward_orchestrators "$ROSTER")"
  assert_contains "$out" "bundle"
  assert_contains "$out" "✗"
  rm -rf "$T"
}

# --- routing ready tickets -------------------------------------------------
# A ready ticket used to go to root, which then forwarded it by mail nobody
# drained. Its prefix names a repo, the repo names a product, and that
# product's orchestrator can take it directly.
_ready_route_fixture() { # <roster>
  _orch_fixture
  printf 'LINEAR_API_KEY=fixture-alpha\n' > "$T/alpha/env.local"
  : > "$T/sent"
  cmd_inbox() { printf '%s\n' "$2" >> "$T/sent"; }
  STUB_TICKET="${STUB_TICKET:-WG-1}"
  curl() {
    printf '{"data":{"issues":{"nodes":[{"identifier":"%s","title":"a thing"}]}}}' "$STUB_TICKET"
  }
}

test_ready_ticket_goes_to_the_product_orchestrator_that_owns_its_prefix() {
  _ready_route_fixture
  local out; out="$(_steward_ready_tickets "$LIVE_ROSTER")"
  assert_eq "$(cat "$T/sent")" "bundle-orch"
  assert_contains "$out" "bundle-orch"
  rm -rf "$T"
}

test_ready_ticket_falls_back_to_root_without_a_live_orchestrator() {
  _ready_route_fixture
  _steward_ready_tickets "$ROSTER" >/dev/null
  assert_eq "$(cat "$T/sent")" "root"
  rm -rf "$T"
}

test_ready_ticket_with_an_unknown_prefix_goes_to_root() {
  STUB_TICKET=ABCD-9 _ready_route_fixture
  STUB_TICKET=ABCD-9 _steward_ready_tickets "$LIVE_ROSTER" >/dev/null
  assert_eq "$(cat "$T/sent")" "root"
  rm -rf "$T"
}

# --- the review sweep finds the PRODUCT's orchestrator ---------------------
# A repo in a declared product has no orchestrator of its own; addressing
# <repo>/orch nudged a pane that does not exist.
test_review_sweep_nudges_the_products_orchestrator() {
  _orch_fixture
  mkdir -p "$T/bin"
  : > "$T/prompts"
  cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '[{"number":7,"headRefName":"WG-1-x","reviewDecision":"APPROVED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z"}]'
SH
  cat > "$T/bin/herdr" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent get")    [ "\$3" = bundle-orch ] && exit 0 || exit 1 ;;
  "agent prompt") printf '%s\n' "\$3" >> "$T/prompts" ;;
esac
exit 0
SH
  chmod +x "$T/bin/gh" "$T/bin/herdr"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LIVE_ROSTER" >/dev/null
  assert_contains "$(cat "$T/prompts")" "bundle-orch"
  # never the repo's own name: `widget` is a member of `bundle`, so a
  # widget-orch pane does not exist and nudging it reports a success nobody got
  assert_eq "$(grep -c widget-orch "$T/prompts" || true)" "0"
  rm -rf "$T"
}

# ---- orphaned test servers ---------------------------------------------------
# The seven `node tools/pages/server.mjs` processes that held a workspace's
# ledger lock for a hundred minutes on 2026-09-16 were invisible: nothing on
# this box names a test server whose worktree no longer has an agent, so they
# aged out of everyone's attention while the fleet blocked behind them. The
# steward names them with pid and port, and reaps one older than an hour.
# Servers under CEL_ROOT are the box's own services and are never touched.
_orphan_fixture() { # <age-seconds>; sets ORPHAN_PID and stubs process listing
  ORPHAN_ROOT="$(mktemp -d)"
  export CEL_WORKTREE_ROOT="$ORPHAN_ROOT"
  ORPHAN_WT="$ORPHAN_ROOT/widget-WG-1-x"
  mkdir -p "$ORPHAN_WT"
  sleep 60 >/dev/null 2>&1 &
  ORPHAN_PID=$!
  ORPHAN_AGE="$1"
  _steward_server_procs() { printf '%s %s %s %s\n' "$ORPHAN_PID" "$ORPHAN_AGE" 4319 "$ORPHAN_WT"; }
}
_orphan_cleanup() { kill -9 "$ORPHAN_PID" 2>/dev/null || true; rm -rf "$ORPHAN_ROOT"; unset CEL_WORKTREE_ROOT; }

test_orphan_sweep_names_a_server_whose_worktree_has_no_agent() {
  _orphan_fixture 300
  local out; out="$(_steward_orphan_servers '{"result":{"agents":[]}}' 2>&1)"
  local alive=0; if kill -0 "$ORPHAN_PID" 2>/dev/null; then alive=1; fi
  _orphan_cleanup
  assert_contains "$out" "$ORPHAN_PID"
  assert_contains "$out" "4319"
  assert_eq "$alive" 1
}
test_orphan_sweep_reaps_a_server_older_than_an_hour() {
  _orphan_fixture 7200
  local out; out="$(_steward_orphan_servers '{"result":{"agents":[]}}' 2>&1)"
  # reap the signalled child, or kill -0 would still find the zombie
  wait "$ORPHAN_PID" 2>/dev/null || true
  local alive=0; if kill -0 "$ORPHAN_PID" 2>/dev/null; then alive=1; fi
  _orphan_cleanup
  assert_contains "$out" "reaped"
  assert_eq "$alive" 0
}
test_orphan_sweep_leaves_a_server_whose_worktree_still_has_an_agent() {
  _orphan_fixture 7200
  local roster out
  roster="$(printf '{"result":{"agents":[{"pane_id":"p1","agent_status":"idle","cwd":"%s"}]}}' "$ORPHAN_WT")"
  out="$(_steward_orphan_servers "$roster" 2>&1)"
  sleep 0.5
  local alive=0; if kill -0 "$ORPHAN_PID" 2>/dev/null; then alive=1; fi
  _orphan_cleanup
  assert_eq "$out" ""
  assert_eq "$alive" 1
}
test_orphan_sweep_never_touches_a_server_outside_the_worktree_root() {
  _orphan_fixture 7200
  _steward_server_procs() { printf '%s %s %s %s\n' "$ORPHAN_PID" 7200 4318 "$CEL_ROOT"; }
  local out; out="$(_steward_orphan_servers '{"result":{"agents":[]}}' 2>&1)"
  sleep 0.5
  local alive=0; if kill -0 "$ORPHAN_PID" 2>/dev/null; then alive=1; fi
  _orphan_cleanup
  assert_eq "$out" ""
  assert_eq "$alive" 1
}

# --- the steward says a thing once -------------------------------------------
# Measured 2026-09-17: root's mailbox held twenty-four open `blocked` items
# from the steward, all the same sentence about the same exhausted provider,
# one every four hours since the 12th - plus four STALLED WORKER items whose
# panes had been gone for days. The steward posted a fresh item every time its
# window reopened and never looked at what it had already said, and nothing
# resolved an item when the condition stopped being true.
_rollup_fixture() { # a registry with one workspace and a sandbox mailbox
  source "$CEL_ROOT/lib/quota.sh"
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  mkdir -p "$T/alpha" "$CEL_INBOX_DIR"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\n' > "$T/alpha/workspace.yaml"
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
  export CEL_MANIFEST="$T/agents.yaml"
  printf 'providers:\n  deepseek:\n    balance: {unit: usd, floor: "1"}\n' > "$CEL_MANIFEST"
  QUOTA_REMAINING="-0.24"
  quota_remaining() { printf '%s' "$QUOTA_REMAINING"; }
  quota_vetoed() { awk -v r="$2" 'BEGIN { exit !(r+0 < 1) }'; }
  provider_get() { printf 'https://example.invalid/billing'; }
  _quota_key() { printf 'a-key'; }
}

# Three ticks with the window forced open: ONE open item, counted three times.
test_steward_raises_one_item_for_a_condition_that_persists() {
  _rollup_fixture
  local i
  for i in 1 2 3; do _STEWARD_WINDOW=0 _steward_quota >/dev/null 2>&1; done
  local open; open="$(cmd_inbox open --for root --workspace alpha)"
  assert_eq "$(printf '%s\n' "$open" | wc -l)" "1"
  assert_contains "$open" "×3"
  assert_contains "$open" "deepseek"
  rm -rf "$T"
}

# ...and when the credit comes back, the steward takes its own blocker down and
# says so, rather than leaving it open for a human to guess about.
test_steward_clears_a_condition_that_stopped_being_true() {
  _rollup_fixture
  _STEWARD_WINDOW=0 _steward_quota >/dev/null 2>&1
  QUOTA_REMAINING="42.00"
  _STEWARD_WINDOW=0 _steward_quota >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  local mail; mail="$(cmd_inbox read --for root --workspace alpha --all)"
  assert_contains "$mail" "cleared:"
  assert_contains "$mail" "deepseek"
  rm -rf "$T"
}

# The four-days-dead case: a STALLED WORKER item naming a pane that no longer
# exists on this box. Nobody can act on it, and it sat open for days.
test_steward_clears_a_stalled_item_whose_pane_is_gone() {
  _rollup_fixture
  local live dead
  live="$(cmd_inbox send root "STALLED WORKER WG-1 (w:alive): nothing has been written for 40m. branch x pushed=yes" \
    --from steward --kind blocked --fp stall-1 --workspace alpha 2>/dev/null)"
  dead="$(cmd_inbox send root "STALLED WORKER WG-2 (w:gone): nothing has been written for 40m. branch y pushed=yes" \
    --from steward --kind blocked --fp stall-2 --workspace alpha 2>/dev/null)"
  cat > "$T/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"w"}]}}' ;;
  "pane list")      printf '{"result":{"panes":[{"pane_id":"w:alive"}]}}' ;;
  *) printf '{}' ;;
esac
SH
  chmod +x "$T/herdr"
  _STEWARD_HERDR="$T/herdr" _steward_clear_dead_panes >/dev/null 2>&1
  local open; open="$(cmd_inbox open --for root --workspace alpha)"
  assert_contains "$open" "WG-1"
  ! printf '%s' "$open" | grep -q "WG-2" || { echo "item for a pane that is gone stayed open"; rm -rf "$T"; return 1; }
  assert_contains "$(cmd_inbox read --for root --workspace alpha --all)" "cleared: pane gone"
  rm -rf "$T"
}

# herdr unreachable is not evidence that every pane died - the same rule every
# other sweep in this file learned the hard way.
test_steward_clears_no_panes_when_herdr_is_unreachable() {
  _rollup_fixture
  cmd_inbox send root "STALLED WORKER WG-2 (w:gone): stalled" \
    --from steward --kind blocked --fp stall-2 --workspace alpha >/dev/null 2>&1
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/herdr"; chmod +x "$T/herdr"
  _STEWARD_HERDR="$T/herdr" _steward_clear_dead_panes >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "WG-2"
  rm -rf "$T"
}
