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

# Runs "<fn> <i>" for i = 1..n in parallel, every writer released at the same
# instant: each reports ready, then blocks on a lock the test holds until all
# n have reported. A barrier, not a sleep, so the overlap is the point of the
# test rather than an accident of timing.
_steward_barrier_run() { # <n> <fn>
  local n="$1" fn="$2" i ready
  mkfifo "$T/ready"; exec 7<>"$T/ready"
  exec 8>"$T/gate"; flock -x 8
  for i in $(seq 1 "$n"); do
    ( exec 8>&-; exec 9<"$T/gate"; printf 'r\n' >&7; flock -s 9; "$fn" "$i" ) &
  done
  for i in $(seq 1 "$n"); do read -r -u 7 ready; done
  exec 8>&-
  wait
  exec 7>&-
}

# Writers on different keys, released together, lose none of each other's
# records - and leave no temp file behind.
test_steward_concurrent_due_on_different_keys_loses_none() {
  have flock || return 0
  local T i missing=0; T="$(mktemp -d)"
  CEL_STEWARD_STATE="$T/state" _STEWARD_STATE="$T/state"
  _due_key() { _steward_due "repo#$1-changes"; }
  _steward_barrier_run 24 _due_key
  for i in $(seq 1 24); do
    grep -q "^repo#$i-changes " "$T/state" || missing=$((missing + 1))
  done
  assert_eq "$missing" 0 || { rm -rf "$T"; return 1; }
  assert_eq "$(find "$T" -name 'state.*' ! -name state.lock | wc -l | tr -d ' ')" 0
  rm -rf "$T"
}

# A writer killed between its temp file and the rename leaves the temp behind.
# The next edit sweeps the file's own temps once they are an hour old - the
# current mktemp names and the old fixed `.tmp` / `.tmp.<pid>` ones - and
# never a fresh temp (a writer still mid-edit) or a sibling state or lock file.
test_steward_state_edit_sweeps_stale_temps_only() {
  local T f; T="$(mktemp -d)"
  CEL_STEWARD_STATE="$T/state" _STEWARD_STATE="$T/state"
  for f in state.tmp state.tmp.4242 state.Ab12Cd state.services state.lock state.suite-lock \
           state.decide-stale.lock state.services.Qx81Lm; do
    printf 'x\n' > "$T/$f"; touch -d '2 hours ago' "$T/$f"
  done
  printf 'x\n' > "$T/state.Zz99Yy"   # a temp another writer is still filling
  _steward_due "repo#1-changes"
  local left; left="$(cd "$T" && ls -A | LC_ALL=C sort | paste -sd' ' -)"
  assert_eq "$left" "state state.Zz99Yy state.decide-stale.lock state.lock state.services state.services.Qx81Lm state.suite-lock"
  rm -rf "$T"
}

# The same for every other shared writer: first-seen records, forgets and the
# service down-counts, interleaved.
test_steward_concurrent_first_seen_forget_and_service_writes_lose_none() {
  have flock || return 0
  local T i bad=0; T="$(mktemp -d)"
  CEL_STEWARD_STATE="$T/state" _STEWARD_STATE="$T/state"
  for i in $(seq 1 24); do printf 'old-%s 100\n' "$i"; done > "$T/state"
  _mixed_write() {
    case $(( $1 % 3 )) in
      0) _steward_first_seen "seen-$1" >/dev/null ;;
      1) _steward_forget "old-$1" ;;
      2) _steward_svc_write "alpha/svc$1" 2 1 ;;
    esac
  }
  _steward_barrier_run 24 _mixed_write
  for i in $(seq 1 24); do
    case $(( i % 3 )) in
      0) grep -q "^seen-$i " "$T/state" || bad=$((bad + 1))
         grep -q "^old-$i " "$T/state" || bad=$((bad + 1)) ;;
      1) ! grep -q "^old-$i " "$T/state" || bad=$((bad + 1)) ;;
      2) grep -q "^alpha/svc$i 2 1$" "$T/state.services" || bad=$((bad + 1))
         grep -q "^old-$i " "$T/state" || bad=$((bad + 1)) ;;
    esac
  done
  assert_eq "$bad" 0
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
# Any mailbox that is neither root nor <repo>-orch is a worker, and resolves
# to the agent of the same name.
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
# function so they cannot drift.
test_steward_orch_dir_prefers_a_declared_product() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/products/bundle" "$T/repos/lone"
  assert_eq "$(_steward_orch_dir "$T" bundle-orch)" "$T/products/bundle"
  assert_eq "$(_steward_orch_dir "$T" lone-orch)" "$T/repos/lone"
  rm -rf "$T"
}

# --- ensuring orchestrators ------------------------------------------------
# Starting a declared `orchestrator: auto` product is mechanical, so the
# steward does it the same way it ensures a dashboard.
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
# evidence that anyone died.
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

# ONE LOGIN RUNS A PRODUCT. An auto product whose products[].home is another
# person - or any home, on a login that names no person - is not this box's
# to start: the steward starts nothing, says nothing and raises nothing.
test_steward_skips_a_product_whose_home_is_another_login_silently() {
  _orch_fixture
  RAISED="$T/raised"; : > "$RAISED"
  _steward_raise() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$RAISED"; }
  sed -i 's/orchestrator: auto}/orchestrator: auto, home: sam}/' "$T/alpha/workspace.yaml"
  printf 'people:\n  - {id: sam, login: sam-example}\n  - {id: jo, login: jo-example}\n' >> "$T/alpha/workspace.yaml"
  local me out
  for me in jo -; do
    rm -f "$T/alpha/workspace.local.yaml"
    [ "$me" = - ] || printf 'me: %s\n' "$me" > "$T/alpha/workspace.local.yaml"
    : > "$T/state"
    out="$(STUB_LAUNCH_RC=1 _steward_orchestrators "$ROSTER" 2>&1)"
    assert_eq "$(cat "$T/launched")" "" || { rm -rf "$T"; return 1; }
    ! printf '%s' "$out" | grep -q bundle \
      || { echo "the steward spoke about a product that is not this login's ($me): $out"; rm -rf "$T"; return 1; }
    assert_eq "$(cat "$RAISED")" "" || { rm -rf "$T"; return 1; }
    assert_eq "$(_steward_rows)" "0" || { rm -rf "$T"; return 1; }
  done
  # ...and on the home login it starts as before
  printf 'me: sam\n' > "$T/alpha/workspace.local.yaml"
  _steward_orchestrators "$ROSTER" >/dev/null
  assert_eq "$(cat "$T/launched")" "bundle alpha"
  rm -rf "$T"
}
# A fault raised before the home was set comes down once it is set.
test_steward_clears_an_old_start_fault_for_a_product_now_homed_elsewhere() {
  _orch_fixture
  _steward_raise alpha "orch-ensure-bundle" blocked "steward: alpha/bundle resolves orchestrator: auto and bundle-orch will not start"
  sed -i 's/orchestrator: auto}/orchestrator: auto, home: sam}/' "$T/alpha/workspace.yaml"
  printf 'people:\n  - {id: sam, login: sam-example}\n' >> "$T/alpha/workspace.yaml"
  printf 'me: jo\n' > "$T/alpha/workspace.local.yaml"
  _steward_orchestrators "$ROSTER" >/dev/null 2>&1
  ! cmd_inbox open --for root --workspace alpha 2>/dev/null | grep -q 'bundle-orch will not start' \
    || { echo "the stale start fault is still open"; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/launched")" ""
  rm -rf "$T"
}
# With no people:, home: or me: the steward starts the auto product as
# before; a me: alone changes nothing.
test_steward_without_home_keys_is_unchanged() {
  _orch_fixture
  printf 'me: jo\n' > "$T/alpha/workspace.local.yaml"
  _steward_orchestrators "$ROSTER" >/dev/null
  assert_eq "$(cat "$T/launched")" "bundle alpha"
  rm -rf "$T"
}

# An open owner card, written the way `cel decide ask` records one.
_owner_card() { # <ws> <id> <title> <blocks>
  jq -nc --arg id "$2" --arg t "$3" --arg b "$4" \
    '{id: $id, ts: "2026-11-01T00:00:00+00:00", to: "owner", from: "root", kind: "decision", title: $t, message: $t, blocks: $b, asker: "root", options: [], context: "fixture"}' \
    >> "$CEL_INBOX_DIR/$1.jsonl"
}
_steward_rows() { jq -c 'select(.from == "steward")' "$CEL_INBOX_DIR/alpha.jsonl" 2>/dev/null | wc -l | tr -d ' '; }

# A launch that keeps failing is retried every half hour; root hears about it
# once, not on every retry.
test_steward_orchestrator_alert_is_raised_once_per_change() {
  _orch_fixture
  STUB_LAUNCH_RC=1 _steward_orchestrators "$ROSTER" >/dev/null 2>&1
  : > "$T/state"   # the half-hour retry window has passed
  STUB_LAUNCH_RC=1 _steward_orchestrators "$ROSTER" >/dev/null 2>&1
  assert_eq "$(wc -l < "$T/launched" | tr -d ' ')" "2"
  assert_eq "$(_steward_rows)" "1"
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "bundle-orch will not start"
  rm -rf "$T"
}

# THE OWNER ALREADY HAS THE QUESTION. While an open `cel decide` card names the
# agent that will not start, the alert stays down - and one raised before the
# card was filed comes down saying which card holds it. When the card closes,
# a launch that still fails is an alert again.
test_steward_orchestrator_alert_waits_while_an_owner_card_covers_it() {
  _orch_fixture
  STUB_LAUNCH_RC=1 _steward_orchestrators "$ROSTER" >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "will not start"
  _owner_card alpha 1700000000000000001 "Restore Bundle solo agent through the gateway" \
    "Main Bundle solo agent taking turns; not the separate lane"
  : > "$T/state"
  local out; out="$(STUB_LAUNCH_RC=1 _steward_orchestrators "$ROSTER" 2>&1)"
  assert_contains "$out" "1700000000000000001"
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  local rows; rows="$(_steward_rows)"
  : > "$T/state"
  STUB_LAUNCH_RC=1 _steward_orchestrators "$ROSTER" >/dev/null 2>&1
  assert_eq "$(_steward_rows)" "$rows"
  printf '{"id":"1700000000000000009","ts":"2026-11-02T00:00:00+00:00","kind":"resolution","ref":"1700000000000000001","by":"owner","to":"root","message":"answered"}\n' \
    >> "$CEL_INBOX_DIR/alpha.jsonl"
  : > "$T/state"
  STUB_LAUNCH_RC=1 _steward_orchestrators "$ROSTER" >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "bundle-orch will not start"
  rm -rf "$T"
}

# A card covers the agent it names as a name of its own, or the product's own
# agent ("<Product> orchestrator", "<Product> solo agent"); a card about
# another agent of the same product, a longer-named agent or something else
# of the product's covers neither. Two auto products, so every card is also
# checked against the agent it must NOT hide.
test_steward_orchestrator_alert_is_covered_only_by_a_card_naming_that_agent() {
  local title blocks covers open p n=0
  # The cases arrive on their own descriptor, so nothing the sweep runs can
  # read them off stdin and leave a case untested.
  while IFS='|' read -r -u 3 title blocks covers; do
    n=$((n + 1))
    _orch_fixture
    cat > "$T/alpha/workspace.yaml" <<YAML
name: alpha
tickets: {system: linear, trigger_state: Ready}
products:
  - {name: bundle, repos: [widget], orchestrator: auto}
  - {name: slot, repos: [gadget], orchestrator: auto}
repos:
  - {name: widget, url: "git@github.com:someone/widget.git", prefix: WG, linear_team: ALPHA}
  - {name: gadget, url: "git@github.com:someone/gadget.git", prefix: OT, linear_team: ALPHA}
YAML
    _owner_card alpha 1700000000000000001 "$title" "$blocks"
    STUB_LAUNCH_RC=1 _steward_orchestrators "$ROSTER" >/dev/null 2>&1
    open="$(cmd_inbox open --for root --workspace alpha)"
    for p in bundle slot; do
      if [ "$p" = "$covers" ]; then
        case "$open" in *"$p-orch will not start"*)
          echo "card '$title | $blocks' should cover $p-orch: $open"; rm -rf "$T"; return 1 ;; esac
      else
        case "$open" in *"$p-orch will not start"*) ;; *)
          echo "card '$title | $blocks' hid $p-orch: $open"; rm -rf "$T"; return 1 ;; esac
      fi
    done
    rm -rf "$T"
  done 3<<'CASES'
Restore Bundle solo agent through the gateway|Main Bundle solo agent taking turns; not the working Slot Builder lane|bundle
Gateway route for the main lane|bundle-orch taking turns|bundle
Bundle orchestrator credentials|nothing else|bundle
Slot orchestrator credentials||slot
bundle-slot-builder lane stuck|bundle-slot-builder taking turns|none
bundle-slot-orch wont start||none
slot-orchestrator stuck||none
Bundle slot builder agent|the slot builder lane|none
Bundle pricing page copy|the pricing page|none
Widget agent credentials|widget-orch taking turns|none
CASES
  assert_eq "$n" "10"
}

# Names are matched literally: a product name is never a pattern.
test_steward_owner_card_matches_names_literally() {
  _orch_fixture
  _owner_card alpha 1700000000000000001 "xzy orchestrator is down" "xzy-orch taking turns"
  assert_eq "$(_steward_owner_card alpha x.y-orch x.y)" ""
  _owner_card alpha 1700000000000000002 "x.y orchestrator is down" ""
  assert_eq "$(_steward_owner_card alpha x.y-orch x.y)" "1700000000000000002	x.y orchestrator is down"
  rm -rf "$T"
}

_stale_launch_fixture() {
  _orch_fixture
  export CEL_UPDATE_DIR="$T/update"
  run_stale_orchestrators() {
    printf 'bundle-orch\talpha\tmodel differs\tcel run orchestrator --product bundle --workspace alpha --restart\n'
    [ -z "${SECOND_STALE_AGENT:-}" ] || printf 'lone-orch\talpha\tmissing inbox hook\tcel run orchestrator --product lone --workspace alpha --restart\n'
    return 0
  }
}
_stale_launch_message() {
  local id; id="$(_inbox_open_fp alpha orch-stale steward root)"
  jq -rs --arg id "$id" '[.[] | select(.id == $id or (.kind == "update" and .ref == $id)) | .message] | last // ""' "$CEL_INBOX_DIR/alpha.jsonl"
}

test_steward_launch_alert_waits_for_owner_then_reopens_in_same_build() {
  _stale_launch_fixture
  _steward_stale_orchestrators >/dev/null
  assert_contains "$(_stale_launch_message)" "bundle-orch runs an older launch line"
  _owner_card alpha 1700000000000000001 "Keep bundle-orch on its chosen model" "bundle-orch model choice"
  _steward_stale_orchestrators >/dev/null
  assert_eq "$(_inbox_open_fp alpha orch-stale steward root)" ""
  local rows; rows="$(_steward_rows)"
  _steward_stale_orchestrators >/dev/null
  # Losing the report cache must not bypass an open owner card.
  rm -f "$CEL_UPDATE_DIR/orch-stale-reported"
  _steward_stale_orchestrators >/dev/null
  assert_eq "$(_steward_rows)" "$rows"
  printf '{"id":"1700000000000000009","ts":"2026-11-02T00:00:00+00:00","kind":"resolution","ref":"1700000000000000001","by":"owner","to":"root","message":"answered"}\n' >> "$CEL_INBOX_DIR/alpha.jsonl"
  _steward_stale_orchestrators >/dev/null
  assert_contains "$(_stale_launch_message)" "bundle-orch runs an older launch line"
  rm -rf "$T"
}

test_steward_launch_card_does_not_hide_another_stale_agent() {
  _stale_launch_fixture
  SECOND_STALE_AGENT=1
  _steward_stale_orchestrators >/dev/null
  assert_contains "$(_stale_launch_message)" "bundle-orch runs an older launch line"
  assert_contains "$(_stale_launch_message)" "lone-orch runs an older launch line"
  _owner_card alpha 1700000000000000001 "Keep bundle-orch on its chosen model" "bundle-orch model choice"
  _steward_stale_orchestrators >/dev/null
  local message; message="$(_stale_launch_message)"
  assert_contains "$message" "lone-orch runs an older launch line"
  if [[ "$message" == *bundle-orch* ]]; then
    echo "covered agent remained in the active launch warning: $message"; return 1
  fi
  local rows; rows="$(_steward_rows)"
  _steward_stale_orchestrators >/dev/null
  assert_eq "$(_steward_rows)" "$rows"
  rm -rf "$T"
}

# --- routing ready tickets -------------------------------------------------
# A ready ticket's prefix names a repo, the repo names a product, and that
# product's orchestrator takes it directly; root is only the fallback.
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

_ready_owner_fixture() {
  _orch_fixture
  sed -i 's/trigger_state: Ready/trigger_state: Todo/' "$T/alpha/workspace.yaml"
  printf 'LINEAR_API_KEY=fixture-alpha\n' > "$T/alpha/env.local"
  READY_OWNER_NODES='[{"identifier":"WG-1","title":"widget work","assignee":null,"state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[]}}]'
  curl() { jq -nc --argjson nodes "$READY_OWNER_NODES" '{data:{issues:{nodes:$nodes}}}'; }
}
_ready_owner_root_count() {
  jq -s '[.[] | select(.from == "steward" and .to == "root")] | length' "$CEL_INBOX_DIR/alpha.jsonl"
}

test_ready_owner_card_holds_and_rearms_without_waiting_for_window() {
  _ready_owner_fixture
  _owner_card alpha 1700000000000000001 "Restore Bundle solo agent through the gateway" "Main Bundle solo agent taking turns"
  _steward_ready_tickets "$ROSTER" >/dev/null
  _steward_ready_tickets "$ROSTER" >/dev/null
  assert_eq "$(_ready_owner_root_count)" 0
  printf '{"id":"1700000000000000002","kind":"resolution","ref":"1700000000000000001","by":"owner","to":"root"}\n' >> "$CEL_INBOX_DIR/alpha.jsonl"
  _steward_ready_tickets "$ROSTER" >/dev/null
  assert_eq "$(_ready_owner_root_count)" 1
  assert_contains "$(_root_mail)" 'WG-1'
  _owner_card alpha 1700000000000000003 "Restore bundle-orch" "bundle-orch is blocked"
  _steward_ready_tickets "$ROSTER" >/dev/null
  assert_eq "$(_ready_owner_root_count)" 1
  printf '{"id":"1700000000000000004","kind":"resolution","ref":"1700000000000000003","by":"owner","to":"root"}\n' >> "$CEL_INBOX_DIR/alpha.jsonl"
  _steward_ready_tickets "$ROSTER" >/dev/null
  assert_eq "$(_ready_owner_root_count)" 2
  _steward_ready_tickets "$ROSTER" >/dev/null
  assert_eq "$(_ready_owner_root_count)" 2
  rm -rf "$T"
}

test_ready_owner_card_does_not_hide_other_products_or_workspaces() {
  _ready_owner_fixture
  READY_OWNER_NODES='[{"identifier":"WG-1","title":"widget"},{"identifier":"OT-2","title":"other product"}]'
  _owner_card alpha 1700000000000000001 "Restore Bundle solo agent" "bundle-orch taking turns"
  _owner_card beta 1700000000000000002 "Restore lone-orch" "lone-orch taking turns"
  _steward_ready_tickets "$ROSTER" >/dev/null
  assert_eq "$(_ready_owner_root_count)" 1
  local mail; mail="$(_root_mail)"
  assert_contains "$mail" 'OT-2'
  if [[ "$mail" == *WG-1* ]]; then echo 'covered product was nudged'; return 1; fi
  rm -rf "$T"
}

test_ready_owner_card_keeps_ambiguous_and_unknown_ownership_actionable() {
  _ready_owner_fixture
  sed -i 's/prefix: OT/prefix: WG/' "$T/alpha/workspace.yaml"
  READY_OWNER_NODES='[{"identifier":"WG-1","title":"ambiguous owner"},{"identifier":"ABCD-9","title":"unknown owner"}]'
  _owner_card alpha 1700000000000000001 "Restore Bundle solo agent" "bundle-orch taking turns"
  _steward_ready_tickets "$ROSTER" >/dev/null
  assert_eq "$(_ready_owner_root_count)" 2
  local mail; mail="$(_root_mail)"
  assert_contains "$mail" 'WG-1'
  assert_contains "$mail" 'ABCD-9'
  rm -rf "$T"
}

# --- the review sweep finds the PRODUCT's orchestrator ---------------------
# A repo in a declared product has no orchestrator of its own, so the nudge
# goes to the product's orchestrator.
test_review_sweep_nudges_the_products_orchestrator() {
  _orch_fixture
  mkdir -p "$T/bin"
  : > "$T/prompts"
  cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '[{"number":7,"headRefName":"WG-1-x","headRefOid":"h7","reviewDecision":"APPROVED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","reviews":[{"state":"APPROVED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"h7"}}]}]'
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
  # mail to the PRODUCT's mailbox, never the member repo's
  assert_contains "$(cmd_inbox read --for bundle-orch --workspace alpha --all)" "#7"
  assert_eq "$(cmd_inbox count --for widget-orch --workspace alpha)" "0"
  rm -rf "$T"
}

# A DRAFT IS LEFT ALONE - by every sweep, the unticketed-branch reminder
# included.
test_review_sweep_never_nudges_about_a_draft() {
  _orch_fixture
  mkdir -p "$T/bin"
  : > "$T/prompts"
  cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '[{"number":8,"headRefName":"experiment/no-ticket","reviewDecision":"","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z"},
             {"number":9,"headRefName":"experiment/draft-no-ticket","reviewDecision":"APPROVED","isDraft":true,"statusCheckRollup":[{"conclusion":"FAILURE"}],"createdAt":"2020-01-01T00:00:00Z"}]'
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
  # #9 is a draft: unticketed, approved AND red, and still not one word about it
  assert_eq "$(grep -c '#9' "$T/prompts" || true)" "0"
  rm -rf "$T"
}

# A PRODUCT HAS NO WORKERS. Its red or changes-requested PR goes to its own
# agent as a fix-it-on-the-branch finding: no worker lookup on the branch, and
# no "get a worker" or "restart the worker" remedy it cannot follow - even with
# an idle pane standing in some checkout of that branch.
test_review_sweep_routes_a_red_pr_to_its_agent_without_worker_remedies() {
  _orch_fixture
  mkdir -p "$T/bin" "$T/wt"
  local roster
  roster="$(printf '{"result":{"agents":[{"name":"bundle-orch","agent_status":"idle","pane_id":"w:p2"},{"name":"old-worker","agent_status":"idle","pane_id":"w:p3","cwd":"%s/wt"}]}}' "$T")"
  cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '[{"number":7,"headRefName":"WG-1-x","headRefOid":"h7","reviewDecision":"","isDraft":false,"statusCheckRollup":[{"conclusion":"FAILURE"}],"createdAt":"2020-01-01T00:00:00Z","reviews":[]},
             {"number":8,"headRefName":"WG-2-y","headRefOid":"h8","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"h8"}}]}]'
SH
  cat > "$T/bin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/herdr.argv"
case "\$1 \$2" in
  "agent get") [ "\$3" = bundle-orch ] && exit 0 || exit 1 ;;
esac
exit 0
SH
  chmod +x "$T/bin/gh" "$T/bin/herdr"
  PATH="$T/bin:$PATH" _steward_review_sweep "$roster" >/dev/null
  local mail; mail="$(cmd_inbox read --for bundle-orch --workspace alpha --all)"
  assert_contains "$mail" "PR #7 on widget has FAILING checks on WG-1-x - a red gate is a finding: fix it on the branch and push." || { rm -rf "$T"; return 1; }
  assert_contains "$mail" "PR #8 on widget has changes requested at its current head - address them on WG-2-y, push, and ask its reviewer to re-review" || { rm -rf "$T"; return 1; }
  case "$mail" in *worker*|*delegate*|*nobody*) echo "worker remedy mailed to a product: $mail"; rm -rf "$T"; return 1 ;; esac
  # nobody's pane was read to decide who stands on the branch
  if grep -q '^agent read' "$T/herdr.argv" 2>/dev/null; then echo "review sweep read a worker pane"; rm -rf "$T"; return 1; fi
  rm -rf "$T"
}

# ---- orphaned test servers ---------------------------------------------------
# A test server whose worktree no longer has an agent holds a port and memory
# while nothing names it. The steward names it with pid and port,
# and reaps one older than an hour.
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
# A condition that persists is ONE open item counting its repeats, never a
# fresh item per window, and the steward resolves it once the condition stops
# being true.
_rollup_fixture() { # a registry with one workspace and a sandbox mailbox
  source "$CEL_ROOT/lib/quota.sh"
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  mkdir -p "$T/alpha" "$CEL_INBOX_DIR"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  # one profile routes to the provider under test - a dry provider nobody
  # routes to is deliberately NOT a blocker (see the test below)
  printf 'name: alpha\nworker_profiles:\n  cheap: {runtime: omp, model: deepseek/deepseek-chat}\n' > "$T/alpha/workspace.yaml"
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

# A dry account that no profile routes to vetoes nothing, so it is not a
# blocker - and an item raised for it earlier is taken down.
test_steward_stays_quiet_about_a_dry_provider_nobody_routes_to() {
  _rollup_fixture
  _STEWARD_WINDOW=0 _steward_quota >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "deepseek"
  printf 'name: alpha\nworker_profiles:\n  cheap: {runtime: omp, model: openrouter/deepseek/deepseek-chat}\n' > "$T/alpha/workspace.yaml"
  _STEWARD_WINDOW=0 _steward_quota >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  assert_contains "$(cmd_inbox read --for root --workspace alpha --all)" "no profile in alpha routes to it"
  rm -rf "$T"
}

# A STALLED WORKER item naming a pane that no longer exists on this box is
# one nobody can act on, so it is cleared.
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

# herdr unreachable is not evidence that every pane died.
test_steward_clears_no_panes_when_herdr_is_unreachable() {
  _rollup_fixture
  cmd_inbox send root "STALLED WORKER WG-2 (w:gone): stalled" \
    --from steward --kind blocked --fp stall-2 --workspace alpha >/dev/null 2>&1
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/herdr"; chmod +x "$T/herdr"
  _STEWARD_HERDR="$T/herdr" _steward_clear_dead_panes >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "WG-2"
  rm -rf "$T"
}

# --- the plane is behind its own main ----------------------------------------
# On a box that tracks main, "a new release is out" never fires: main moves
# past the newest tag and the tag does not. The steward says the same sentence
# about COMMITS - once, rolled up, and taken down again when the box catches up.
_update_rollup_fixture() { # a registry, a mailbox, and a checkout behind origin
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  export CEL_UPDATE_DIR="$T/update" CEL_CONFIG_FILE="$T/config.yaml"
  mkdir -p "$T/alpha" "$CEL_INBOX_DIR"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\n' > "$T/alpha/workspace.yaml"
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
  printf 'update:\n  channel: main\n' > "$CEL_CONFIG_FILE"

  git init -q --bare "$T/origin.git"
  git init -q -b main "$T/root"
  git -C "$T/root" config user.email t@example.com
  git -C "$T/root" config user.name tester
  printf '0.2.0\n' > "$T/root/VERSION"
  git -C "$T/root" add -A
  git -C "$T/root" commit -qm 'release 0.2.0'
  git -C "$T/root" tag v0.2.0
  printf 'later\n' > "$T/root/AFTER"
  git -C "$T/root" add -A
  git -C "$T/root" commit -qm 'after the release'
  git -C "$T/root" remote add origin "$T/origin.git"
  git -C "$T/root" push -q origin main --tags
  git -C "$T/root" reset -q --hard v0.2.0
  CEL_ROOT="$T/root"
}

test_steward_says_new_commits_on_main_once_as_a_status_line() {
  local keep="$CEL_ROOT"
  _update_rollup_fixture
  _steward_update_check >/dev/null 2>&1
  local mail; mail="$(cmd_inbox read --for root --workspace alpha --all)"
  assert_eq "$(printf '%s\n' "$mail" | grep -c 'new commits on celestial main')" "1" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }
  assert_contains "$mail" "1 new commits on celestial main" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }
  # nobody has to answer it: it is not sitting in root's open list
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" "" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }

  git -C "$T/root" fetch -q origin main
  git -C "$T/root" reset -q --hard origin/main
  _steward_update_check >/dev/null 2>&1
  [ -f "$CEL_UPDATE_DIR/available" ] && { echo "marker survived a box level with main"; CEL_ROOT="$keep"; rm -rf "$T"; return 1; }
  CEL_ROOT="$keep"
  rm -rf "$T"
}

# --- memory: the steward says something before the box does -------------------
# A runaway test server or a forgotten session is invisible until something
# is killed - and then the kernel picks what dies, not whatever was
# expendable. These two sweeps warn first, and neither of them kills
# anything: the steward reports, the orchestrator decides.
_mem_steward_fixture() { # <total-kb> <available-kb>
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  mkdir -p "$T/alpha/.cel" "$T/alpha/products/bundle" "$T/inbox"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\nrepos: [{name: widget}, {name: gadget}]\nproducts:\n  - name: bundle\n    repos: [widget, gadget]\n' \
    > "$T/alpha/workspace.yaml"
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
  printf 'MemTotal:       %s kB\nMemAvailable:   %s kB\n' "$1" "$2" > "$T/meminfo"
  export CEL_MEMINFO="$T/meminfo"
  # The walk itself is proved in tests/memory.test.sh against a real process;
  # here the question is which directory the steward attributes to whom.
  mem_tree_snapshot() { :; }
  mem_tree_snapshot_clear() { :; }
  mem_tree_rss_mb() {
    case "$1" in
      *products/bundle*)    printf 800 ;;
      *) printf 0 ;;
    esac
  }
}

# 1.2 GB of 24 available is minutes from the kernel choosing what dies. One
# blocked item, naming the trees big enough to be worth doing something about.
test_steward_raises_one_blocker_when_the_box_runs_out_of_memory() {
  _mem_steward_fixture 25165824 1258291
  export CEL_SERVE_STATE="$T/serve" CEL_SERVE_PROC_DATA=''
  mkdir -p "$CEL_SERVE_STATE"
  printf '%s\n' '{"name":"preview-demo","unit":"cel-serve-preview-demo","owner":"bundle-orch","workspace":"alpha","started_at":100,"ttl_seconds":3600,"last_request_at":100,"port":8080}' > "$CEL_SERVE_STATE/preview-demo.json"
  _serve_cgroup_memory() { printf 880; }
  local i
  for i in 1 2 3; do _STEWARD_WINDOW=0 _steward_memory >/dev/null 2>&1; done
  local open; open="$(cmd_inbox open --for root --workspace alpha)"
  assert_eq "$(printf '%s\n' "$open" | grep -c 'box memory low')" "1"
  assert_contains "$open" "1.2G of 24G available"
  assert_contains "$open" "bundle-orch 800M"
  assert_contains "$open" "Top servers: preview-demo 880M"
  rm -rf "$T"
}

# HYSTERESIS, deliberately: raised under 10% and cleared over 15%, so a box
# hovering on one threshold does not post and resolve the same item every tick.
test_steward_clears_the_memory_blocker_only_when_headroom_really_returns() {
  _mem_steward_fixture 25165824 1258291
  _STEWARD_WINDOW=0 _steward_memory >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "box memory low"
  # 12%: above the raise threshold, below the clear one - the item stands
  printf 'MemTotal:       25165824 kB\nMemAvailable:   3019898 kB\n' > "$T/meminfo"
  _STEWARD_WINDOW=0 _steward_memory >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "box memory low"
  # 20%: gone, and said to have gone
  printf 'MemTotal:       25165824 kB\nMemAvailable:   5033164 kB\n' > "$T/meminfo"
  _STEWARD_WINDOW=0 _steward_memory >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  assert_contains "$(cmd_inbox read --for root --workspace alpha --all)" "cleared:"
  rm -rf "$T"
}

# A box that cannot be measured is not a box in crisis: the sweep says nothing
# rather than raising a blocker about 0 MB of 0 MB.
test_steward_says_nothing_about_a_box_it_cannot_measure() {
  _mem_steward_fixture 25165824 1258291
  export CEL_MEMINFO=/nonexistent/meminfo
  local out
  out="$(_STEWARD_WINDOW=0 _steward_memory 2>&1)"
  assert_eq "$out" ""
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  rm -rf "$T"
}

# --- the subscriptions the fleet actually runs on ----------------------------
# A Claude or Codex window at 100% stops every worker on that account. The
# sweep speaks ONCE per account per tick, rolled up like every other steward
# condition.
_sub_fixture() { # <five-hour-pct>
  source "$CEL_ROOT/lib/quota.sh"
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  mkdir -p "$T/alpha" "$CEL_INBOX_DIR"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\n' > "$T/alpha/workspace.yaml"
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
  SUB_PCT="$1"
  _subscription_accounts() { printf 'claude\ta1b2c3\tfixture-token\n'; }
  subscription_usage() {
    jq -nc --argjson p "$SUB_PCT" \
      '{provider: "claude", account: "a1b2c3",
        windows: [{name: "5h", used_pct: $p, resets_at: "2026-09-18T09:00:00Z"}],
        extra: {state: "enabled", reason: ""}}'
  }
}

test_steward_warns_once_about_a_subscription_window_over_the_threshold() {
  _sub_fixture 85
  # Three ticks, the real dedup window: the steward says it ONCE. A window
  # that sits at 85% for a morning is one fact, not one fact every five
  # minutes, and the mailbox is what an operator actually reads.
  local i
  for i in 1 2 3; do _steward_subscriptions >/dev/null 2>&1; done
  local mail; mail="$(cmd_inbox read --for root --workspace alpha --all)"
  assert_eq "$(printf '%s\n' "$mail" | grep -c 'subscription a1b2c3')" "1"
  assert_contains "$mail" "claude"
  assert_contains "$mail" "85%"
  rm -rf "$T"
}

test_steward_blocks_on_a_subscription_window_at_a_hundred() {
  _sub_fixture 100
  _steward_subscriptions >/dev/null 2>&1
  # A spent window is a BLOCKER, not a note: it is the reason the next
  # delegation refuses, and it stays open until someone or something clears it.
  local open; open="$(cmd_inbox open --for root --workspace alpha)"
  assert_contains "$open" "blocked"
  assert_contains "$open" "claude"
  assert_contains "$open" "resets"
  rm -rf "$T"
}

test_steward_clears_a_subscription_blocker_when_the_window_drops() {
  _sub_fixture 100
  _steward_subscriptions >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "claude"
  SUB_PCT=40
  _steward_subscriptions >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  assert_contains "$(cmd_inbox read --for root --workspace alpha --all)" "cleared:"
  rm -rf "$T"
}

# ── services ─────────────────────────────────────────────────────────────────
# A declared service with a `health:` path is probed every tick. ONE tick down
# is a restart, a deploy, a laptop lid; TWO consecutive ticks is a service
# that is not coming back on its own, and that is what root hears about -
# once, rolled up, not every tick forever.
_svc_steward_fixture() { # [restart-policy]
  T="$(mktemp -d)"
  mkdir -p "$T/alpha/.cel" "$T/bin"
  export CEL_REGISTRY="$T/registry.yaml"
  export CEL_INBOX_DIR="$T/inbox"
  export CEL_STEWARD_STATE="$T/steward-state"
  _STEWARD_STATE="$T/steward-state"
  export CEL_SERVICES_HERDR="$T/bin/herdr"
  # The sweep also walks the box's own services.d, so that is a fixture here
  # too: otherwise the suite would probe - and restart - whatever this box
  # really declares.
  export CEL_SERVICES_D="$T/services.d"
  export CEL_SERVICES_STATE="$T/services-state"
  export PATH="$T/bin:$PATH"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  SVC_PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  printf 'name: alpha\nservices:\n  - {name: builder, url: "http://127.0.0.1:%s", health: "/", cmd: "python3 -m http.server %s", cwd: "%s/alpha"%s}\n' \
    "$SVC_PORT" "$SVC_PORT" "$T" "${1:+, restart: $1}" > "$T/alpha/workspace.yaml"
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
case "\$1 \$2" in
  'pane split') printf '{"result":{"pane_id":"w1:p9"}}' ;;
  # A workspace service is split from its workspace's own agent pane; with
  # no live agent it must refuse, never fall back to the box home.
  'agent list') [ -f "$T/no-agent" ] && printf '{"result":{"agents":[]}}' \
    || printf '{"result":{"agents":[{"cwd":"$T/alpha","pane_id":"w1:p1"}]}}' ;;
  # Box services go to the dedicated \`cel services\` workspace.
  'workspace list') printf '{"result":{"workspaces":[]}}' ;;
  'workspace create') printf '{"result":{"root_pane":{"pane_id":"w1:p1"}}}' ;;
  'pane read')  printf 'EADDRINUSE 4322\n' ;;
  *) printf '{}' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
  : > "$T/calls"
}

test_steward_raises_one_blocker_after_two_down_ticks_and_clears_it() {
  _svc_steward_fixture
  _steward_services >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  _steward_services >/dev/null 2>&1
  local open; open="$(cmd_inbox open --for root --workspace alpha --json)"
  assert_contains "$open" "builder"
  assert_eq "$(printf '%s\n' "$open" | wc -l | tr -d ' ')" 1
  # a third down tick rolls up onto the same item rather than posting a second
  _steward_services >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha --json | wc -l | tr -d ' ')" 1
  # back up: the item is resolved, because an item nobody takes down is how a
  # mailbox fills with conditions that stopped being true days ago
  ( cd "$T/alpha" && exec python3 -m http.server "$SVC_PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  SVC_PID=$!
  local i; for i in $(seq 1 20); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$SVC_PORT/" && break; sleep 0.3; done
  _steward_services >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  kill "$SVC_PID" 2>/dev/null
  rm -rf "$T"
}

# `restart: auto` means the steward tries the obvious thing once before it
# wakes anyone, and SAYS it tried - a blocker that hides an action taken on
# the operator's behalf is worse than no automation.
test_steward_restarts_an_auto_service_once_before_raising() {
  _svc_steward_fixture auto
  _steward_services >/dev/null 2>&1
  _steward_services >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha --json)" "restarted"
  assert_eq "$(grep -c 'pane split' "$T/calls")" 1
  # and not again on the next tick: one restart per condition, not per tick
  _steward_services >/dev/null 2>&1
  assert_eq "$(grep -c 'pane split' "$T/calls")" 1
  rm -rf "$T"
}

# With no live agent in its workspace, an auto restart refuses and names the
# workspace - it never lands in the box services home instead.
test_steward_restart_without_a_workspace_agent_refuses_naming_it() {
  _svc_steward_fixture auto
  touch "$T/no-agent"
  local out rc=0
  out="$(svc_start "$T/alpha" builder 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "started without a workspace pane"; rm -rf "$T"; return 1; }
  assert_contains "$out" "$T/alpha"
  [ -z "$(grep -E '^(pane split|workspace create)' "$T/calls" 2>/dev/null || true)" ] \
    || { echo "fell back to the box services home"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# THE QUEUE IS VISIBLE OR IT IS A HANG. With one suite running at a time, a
# worker whose gate is waiting looks exactly like a worker that died. A suite
# held far longer than any suite takes is the one case worth a word to root.
# The steward never kills it: it says who has it and for how long.
_suite_lock_fixture() {
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  mkdir -p "$T/alpha/.cel" "$T/inbox"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\nrepos: [{name: widget}]\n' > "$T/alpha/workspace.yaml"
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
  export CEL_SUITE_LOCK="$T/suite.lock"
}

test_steward_reports_a_suite_lock_held_past_the_warning_and_clears_it() {
  _suite_lock_fixture
  # `exec` so the holder IS the process the test kills: a shell that forks a
  # sleep leaves the sleep holding the inherited descriptor after the shell dies
  ( flock 9; exec sleep 30 ) 9>>"$CEL_SUITE_LOCK" &
  local holder=$!
  local i=0
  while flock -n "$CEL_SUITE_LOCK" -c true >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); [ "$i" -lt 50 ] || break; done
  # what a real runner writes after it acquires the lock, aged 31 minutes
  printf '%s %s\n' "$holder" "$(date +%H:%M)" > "$CEL_SUITE_LOCK"
  touch -d '31 minutes ago' "$CEL_SUITE_LOCK"

  # three ticks, one item: a suite that will take an hour is still there in
  # five minutes and does not need saying again
  local j
  for j in 1 2 3; do _steward_suite_lock >/dev/null 2>&1; done
  local mail; mail="$(cmd_inbox read --for root --workspace alpha --all)"
  assert_eq "$(printf '%s\n' "$mail" | grep -c 'suite lock held' || true)" "1"
  assert_contains "$mail" "by pid $holder"
  assert_contains "$mail" "31m"

  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  _steward_suite_lock >/dev/null 2>&1
  mail="$(cmd_inbox read --for root --workspace alpha --all)"
  assert_contains "$mail" "cleared: the suite lock is free again"
  rm -rf "$T"
}

# A suite that has been running for four minutes is a suite. Nothing is said
# about it, or the sweep is noise every tick on a box doing its job.
test_steward_says_nothing_about_a_suite_lock_held_for_a_normal_run() {
  _suite_lock_fixture
  # `exec` so the holder IS the process the test kills: a shell that forks a
  # sleep leaves the sleep holding the inherited descriptor after the shell dies
  ( flock 9; exec sleep 30 ) 9>>"$CEL_SUITE_LOCK" &
  local holder=$!
  local i=0
  while flock -n "$CEL_SUITE_LOCK" -c true >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); [ "$i" -lt 50 ] || break; done
  printf '%s %s\n' "$holder" "$(date +%H:%M)" > "$CEL_SUITE_LOCK"
  _steward_suite_lock >/dev/null 2>&1
  assert_eq "$(cmd_inbox read --for root --workspace alpha --all)" ""
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  rm -rf "$T"
}

# --- the orphan sweep ---------------------------------------------------------

# The memory sweep groups by pane, so watchers, fixtures and shells with no
# pane at all never appear in it. The orphan sweep reaps them and says so
# ONCE - one rolled-up line, never one item per pid, or root's mailbox becomes
# the litter.
_orphan_steward_fixture() {
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox"
  mkdir -p "$T/alpha" "$T/inbox" "$T/proc"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\nrepos: [{name: widget}]\n' > "$T/alpha/workspace.yaml"
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
  export CEL_PROC="$T/proc" CEL_ORPHAN_GRACE=1
}

test_steward_reaps_orphans_and_reports_one_rolled_up_line() {
  _orphan_steward_fixture
  local w f
  sleep 60 & w=$!
  sleep 60 & f=$!
  mkdir -p "$T/proc/$w" "$T/proc/$f"
  printf 'Name:\tbash\nPPid:\t1\nUid:\t%s\t%s\t%s\t%s\nVmRSS:\t8000 kB\n' \
    "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" > "$T/proc/$w/status"
  ln -sfn "$T" "$T/proc/$w/cwd"
  printf 'cel\0inbox\0watch\0--for\0root\0' > "$T/proc/$w/cmdline"
  printf 'Name:\tsh\nPPid:\t1\nUid:\t%s\t%s\t%s\t%s\nVmRSS:\t2000 kB\n' \
    "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" > "$T/proc/$f/status"
  ln -sfn "$T/gone" "$T/proc/$f/cwd"
  printf '/bin/sh\0%s/gone/bin/long-running\0' "$T" > "$T/proc/$f/cmdline"

  local out; out="$(_steward_orphans 2>&1)"
  assert_contains "$out" "reaped 2 orphans (1 watcher, 1 fixture)"
  local mail; mail="$(cmd_inbox read --for root --workspace alpha --all)"
  assert_eq "$(printf '%s\n' "$mail" | grep -c 'reaped 2 orphans')" "1"
  kill -9 "$w" "$f" 2>/dev/null || true
  rm -rf "$T"
}

# NOTHING TO SAY IS SAID BY SAYING NOTHING. A sweep that posts "reaped 0" every
# five minutes is the noise this whole file was written to stop.
test_steward_orphan_sweep_is_silent_when_it_reaped_nothing() {
  _orphan_steward_fixture
  local out; out="$(_steward_orphans 2>&1)"
  assert_eq "$out" ""
  assert_eq "$(cmd_inbox read --for root --workspace alpha --all)" ""
  rm -rf "$T"
}

_orphan_watcher_proc() { # one live process the fixture /proc calls a reparented watcher
  local w
  sleep 60 & w=$!
  mkdir -p "$T/proc/$w"
  printf 'Name:\tbash\nPPid:\t1\nUid:\t%s\t%s\t%s\t%s\nVmRSS:\t%s kB\n' \
    "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" "${1:-8000}" > "$T/proc/$w/status"
  ln -sfn "$T" "$T/proc/$w/cwd"
  printf 'cel\0inbox\0watch\0--for\0root\0' > "$T/proc/$w/cmdline"
}

# THE ORPHANS ARE THE BOX'S. Said in every workspace, root read each reap
# four times; it goes to the first registered workspace only.
test_steward_reports_orphan_reaps_once_per_box() {
  _orphan_steward_fixture
  mkdir -p "$T/beta"
  printf 'name: beta\nrepos: [{name: gizmo}]\n' > "$T/beta/workspace.yaml"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n  beta: {path: "%s/beta"}\n' "$T" "$T" > "$CEL_REGISTRY"
  _orphan_watcher_proc
  _steward_orphans >/dev/null 2>&1
  assert_contains "$(cmd_inbox read --for root --workspace alpha --all)" "reaped 1 orphan (1 watcher)"
  assert_eq "$(cmd_inbox read --for root --workspace beta --all)" ""
  rm -rf "$T"
}

# AND ONLY WHEN IT CHANGES. Another reap of the same shape - whatever its size -
# says nothing new; a reap of a different shape does.
test_steward_reports_an_unchanged_orphan_reap_once() {
  _orphan_steward_fixture
  _orphan_watcher_proc 8000
  _steward_orphans >/dev/null 2>&1
  rm -rf "$T/proc"; mkdir -p "$T/proc"
  _orphan_watcher_proc 3000
  _steward_orphans >/dev/null 2>&1
  assert_eq "$(_steward_rows)" "1"
  rm -rf "$T/proc"; mkdir -p "$T/proc"
  _orphan_watcher_proc; _orphan_watcher_proc
  _steward_orphans >/dev/null 2>&1
  assert_eq "$(_steward_rows)" "2"
  assert_contains "$(jq -r 'select(.from == "steward") | .message' "$CEL_INBOX_DIR/alpha.jsonl" | tail -n1)" "reaped 2 orphans (2 watchers) - "
  rm -rf "$T"
}

# Orphans have no pane to be named under, so the largest-trees line counts
# them as one tree of their own.
test_steward_memory_trees_include_the_orphans_as_one_tree() {
  _mem_steward_fixture 25165824 1258291
  orphans_list() { printf 'watcher\t1\t8000\t10\t/w\tcel inbox watch\nfixture\t2\t400000\t10\t/w\tsh\n'; }
  local trees; trees="$(_steward_mem_trees)"
  assert_contains "$trees" "orphans"
  assert_eq "$(printf '%s\n' "$trees" | awk -F'\t' '$1 == "orphans" { print $2 }')" "398"
  rm -rf "$T"
}

test_steward_failed_roster_cannot_reap_orphan_servers() {
  local t; t="$(mktemp -d)"
  _steward_server_procs() { printf '1 7200 7777 %s/.herdr/worktrees/fixture\n' "$HOME"; }
  kill() { printf '%s\n' "$*" >> "$t/kills"; }
  _steward_orphan_servers '{}' >/dev/null 2>&1
  [ ! -s "$t/kills" ] || { echo 'reaped a server on unknown agent presence'; return 1; }
  rm -rf "$t"
}

# --- a mailbox with no reader must not swallow an escalation -----------------
# Nothing is obliged to read root's mailbox: a root pane or the console may not
# be running. So when root mail sits unread with no live reader, the steward
# escalates the FACT - once per workspace, rolled up, self-clearing - as a
# `blocked` item, which is the kind that already raises a desktop notification.
_root_unread_fixture() {
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  mkdir -p "$T/alpha" "$CEL_INBOX_DIR" "$T/bin" "$T/proc"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\n' > "$T/alpha/workspace.yaml"
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
  export CEL_PROC_DIR="$T/proc"
  cat > "$T/bin/herdr" <<'EOS'
#!/usr/bin/env bash
[ -n "${STUB_AGENTS:-}" ] || STUB_AGENTS='"'"'{"result":{"agents":[]}}'"'"'
printf '%s\n' "$STUB_AGENTS"
EOS
  chmod +x "$T/bin/herdr"
  PATH="$T/bin:$PATH"
  export STUB_AGENTS='{"result":{"agents":[]}}'
  # two hours old, which is past CEL_ROOT_UNREAD_SECS
  local old; old="$(date -Is -d '2 hours ago')"
  printf '%s\n' \
    "$(jq -nc --arg ts "$old" '{id:"100", ts:$ts, to:"root", from:"widget-orch", kind:"escalation", message:"the reviewer pane has been dead for two days"}')" \
    "$(jq -nc --arg ts "$old" '{id:"101", ts:$ts, to:"root", from:"widget-orch", kind:"status", message:"ABC-9 gate green"}')" \
    > "$CEL_INBOX_DIR/alpha.jsonl"
}

test_steward_raises_one_blocker_for_root_mail_nobody_is_reading() {
  _root_unread_fixture
  local i
  for i in 1 2 3; do _STEWARD_WINDOW=0 _steward_root_unread >/dev/null 2>&1; done
  local open; open="$(cmd_inbox open --for root --workspace alpha)"
  assert_eq "$(printf '%s\n' "$open" | wc -l)" "1"
  assert_contains "$open" "nobody is reading"
  assert_contains "$open" "widget-orch"
  assert_contains "$open" "blocked"
  rm -rf "$T"
}

test_steward_says_nothing_about_root_mail_when_a_reader_is_alive() {
  _root_unread_fixture
  export STUB_AGENTS='{"result":{"agents":[{"name":"alpha-root"}]}}'
  _STEWARD_WINDOW=0 _steward_root_unread >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  rm -rf "$T"
}

test_steward_clears_the_root_mail_blocker_once_the_mail_is_read() {
  _root_unread_fixture
  _STEWARD_WINDOW=0 _steward_root_unread >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "nobody is reading"
  printf '999' > "$CEL_INBOX_DIR/alpha.root.cursor"
  _STEWARD_WINDOW=0 _steward_root_unread >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  assert_contains "$(cmd_inbox read --for root --workspace alpha --all)" "cleared:"
  rm -rf "$T"
}
# A root mailbox that does not parse is not one whose mail was read: the open
# blocker stays, nothing is cleared, and the steward says why in its log.
test_steward_neither_clears_nor_raises_root_mail_it_cannot_parse() {
  _root_unread_fixture
  _STEWARD_WINDOW=0 _steward_root_unread >/dev/null 2>&1
  local before; before="$(cksum < "$CEL_INBOX_DIR/alpha.jsonl")"
  { printf 'not json\n'; cat "$CEL_INBOX_DIR/alpha.jsonl"; } > "$T/torn"; cat "$T/torn" > "$CEL_INBOX_DIR/alpha.jsonl"
  local out; out="$(_STEWARD_WINDOW=0 _steward_root_unread 2>&1)"
  assert_contains "$out" "alpha: root's mailbox $CEL_INBOX_DIR/alpha.jsonl is corrupt - its unread mail is unknown"
  ! grep -q 'cleared:' "$CEL_INBOX_DIR/alpha.jsonl" || { echo "the steward cleared root mail it could not read"; rm -rf "$T"; return 1; }
  tail -n +2 "$CEL_INBOX_DIR/alpha.jsonl" > "$T/good"; cat "$T/good" > "$CEL_INBOX_DIR/alpha.jsonl"
  assert_eq "$(cksum < "$CEL_INBOX_DIR/alpha.jsonl")" "$before"
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "nobody is reading"
  rm -rf "$T"
}

# --- the steward and `up` must agree ---------------------------------------
# The steward and `cel ws up` both resolve a product's orchestrator mode
# through ws_orchestrator_mode, so they reach the same verdict.

test_steward_starts_a_product_the_layout_declares_auto() {
  _orch_fixture
  # The workspace-wide switch, with a product that declares nothing: `up`
  # starts this one, so the steward must reach the same verdict.
  cat > "$T/alpha/workspace.yaml" <<YAML
name: alpha
tickets: {system: linear, trigger_state: Ready}
layout: {orchestrators: auto}
products:
  - {name: bundle, repos: [widget]}
repos:
  - {name: widget, url: "git@github.com:someone/widget.git", prefix: WG}
YAML
  _steward_orchestrators "$ROSTER" >/dev/null
  assert_eq "$(cat "$T/launched")" "bundle alpha"
  rm -rf "$T"
}

# A message about failing to start something nobody asked to be started is the
# factory arguing with itself in front of the operator. When the resolved mode
# is manual the steward says that plainly and takes the stale fault down.
test_steward_says_manual_plainly_rather_than_will_not_start() {
  _orch_fixture
  # a stale "will not start" fault for a product that resolves to manual
  _steward_raise alpha "orch-ensure-lone" blocked \
    "steward: alpha/lone declares orchestrator: auto and lone-orch will not start"
  local out; out="$(STUB_LAUNCH_RC=1 _steward_orchestrators "$ROSTER")"
  assert_contains "$out" "alpha/lone is set to manual; nothing will start it automatically"
  ! printf '%s' "$out" | grep -q 'lone-orch will not start' \
    || { echo "the steward still reports a failure to start a manual product: $out"; rm -rf "$T"; return 1; }
  assert_eq "$(grep -c lone "$T/launched" || true)" "0"
  rm -rf "$T"
}

# --- the AFK sweep -----------------------------------------------------------
# The steward notices when the AFK mode authorising it has run out, and raises
# into EVERY registered workspace's mailbox: an expired AFK is a property of
# the box, not of one product. The fixture registry keeps the test off the
# real box's registrations; assertions are on the raises themselves.
_afk_sweep_fixture() { # <until>
  T="$(mktemp -d)"
  export CEL_AFK_STATE="$T/afk"
  export CEL_REGISTRY="$T/registry.yaml"
  mkdir -p "$T/alpha" "$T/beta"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n  beta: {path: "%s/beta"}\n' "$T" "$T" > "$CEL_REGISTRY"
  assert_eq "$(registry_names | sort | paste -sd, -)" "alpha,beta" || return 1
  source "$CEL_ROOT/lib/afk.sh"
  cmd_afk on --until "$1" --reason 'asleep' >/dev/null
  RAISED="$T/raised"; : > "$RAISED"
  _steward_raise() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$RAISED"; }
}
_afk_sweep_teardown() { rm -rf "$T"; unset CEL_AFK_STATE CEL_REGISTRY; }

test_steward_raises_an_expired_afk_still_on() {
  _afk_sweep_fixture '2020-01-01T00:00:00Z' || return 1
  _steward_afk_sweep >/dev/null
  # One raise per registered mailbox, under the condition key that rolls a
  # repeat up onto the item already open rather than posting a fresh one.
  assert_eq "$(wc -l < "$RAISED")" 2 || { cat "$RAISED"; _afk_sweep_teardown; return 1; }
  assert_eq "$(cut -d'|' -f1 "$RAISED" | sort | paste -sd, -)" "alpha,beta"
  assert_eq "$(cut -d'|' -f2 "$RAISED" | sort -u)" "afk-expired"
  assert_contains "$(cat "$RAISED")" "cel afk off"
  assert_contains "$(cat "$RAISED")" "2020-01-01T00:00:00Z"
  _afk_sweep_teardown
}

test_steward_says_nothing_about_a_live_afk() {
  _afk_sweep_fixture '+8h' || return 1
  _steward_afk_sweep >/dev/null
  assert_eq "$(cat "$RAISED")" ""
  _afk_sweep_teardown
}

# AND IT DOES NOT DEPEND ON THIS BOX. With an EMPTY registry the sweep still
# says it out loud in the steward's own output; there is simply no mailbox to
# put it in.
test_steward_afk_sweep_still_speaks_with_an_empty_registry() {
  _afk_sweep_fixture '2020-01-01T00:00:00Z' || return 1
  printf 'workspaces: {}\n' > "$CEL_REGISTRY"
  local out; out="$(_steward_afk_sweep)"
  assert_contains "$out" "AFK expired at 2020-01-01T00:00:00Z"
  assert_eq "$(cat "$RAISED")" ""
  _afk_sweep_teardown
}

# --- the steward never types into an orchestrator pane -----------------------
_nudge_herdr_stub() { # records every herdr argv to $T/herdr.argv
  mkdir -p "$T/bin"; : > "$T/herdr.argv"
  cat > "$T/bin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/herdr.argv"
case "\$1 \$2" in "agent get") [ "\$3" = bundle-orch ] && exit 0 || exit 1 ;; esac
exit 0
SH
  chmod +x "$T/bin/herdr"
}

test_review_sweep_nudges_are_mail_with_zero_prompts_and_stay_rate_limited() {
  _orch_fixture; _nudge_herdr_stub
  cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '[{"number":7,"headRefName":"WG-1-x","headRefOid":"h7","reviewDecision":"APPROVED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","reviews":[{"state":"APPROVED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"h7"}}]},
             {"number":8,"headRefName":"WG-2-y","headRefOid":"h8","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"h8"}}]},
             {"number":9,"headRefName":"WG-3-z","reviewDecision":"","isDraft":false,"statusCheckRollup":[{"conclusion":"FAILURE"}],"createdAt":"2020-01-01T00:00:00Z"},
             {"number":10,"headRefName":"noticket","reviewDecision":"","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z"}]'
SH
  chmod +x "$T/bin/gh"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LIVE_ROSTER" >/dev/null 2>&1
  assert_eq "$(grep -c '^agent prompt' "$T/herdr.argv" || true)" "0"
  local mail; mail="$(cmd_inbox read --for bundle-orch --workspace alpha --all)"
  assert_contains "$mail" "#7"
  assert_contains "$mail" "#8"
  assert_contains "$mail" "#9"
  assert_contains "$mail" "#10"
  local n; n="$(cmd_inbox count --for bundle-orch --workspace alpha)"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LIVE_ROSTER" >/dev/null 2>&1
  assert_eq "$(cmd_inbox count --for bundle-orch --workspace alpha)" "$n"
  rm -rf "$T"
}

test_stale_and_decision_nudges_to_orchestrators_are_mail_naming_the_reader() {
  _orch_fixture; _nudge_herdr_stub
  local old="2020-01-01T00:00:00Z"
  mkdir -p "$CEL_INBOX_DIR"
  printf '{"id":"1","ts":"%s","from":"w","to":"bundle-orch","kind":"decision","message":"merge or wait?"}\n' "$old" > "$CEL_INBOX_DIR/alpha.jsonl"
  printf '{"id":"2","ts":"%s","from":"w","to":"root","kind":"escalation","message":"stuck"}\n' "$old" >> "$CEL_INBOX_DIR/alpha.jsonl"
  local roster='{"result":{"agents":[{"name":"bundle-orch","pane_id":"w:p2","cwd":"/x"},{"name":"alpha-root","pane_id":"w:p1","cwd":"/y"}]}}'
  PATH="$T/bin:$PATH" _steward_mail_sweep "$roster" >/dev/null 2>&1
  assert_eq "$(grep -c '^agent prompt' "$T/herdr.argv" || true)" "0"
  local mail; mail="$(cmd_inbox read --for bundle-orch --workspace alpha --all)"
  assert_contains "$mail" "cel inbox read --for bundle-orch --workspace alpha"
  # an open decision earns no "UNRESOLVED" reminder
  assert_eq "$(printf '%s' "$mail" | grep -c 'UNRESOLVED' || true)" "0"
  assert_contains "$(cmd_inbox read --for root --workspace alpha --all)" "cel inbox read --for root --workspace alpha"
  local n; n="$(cmd_inbox read --for bundle-orch --workspace alpha --all | wc -l)"
  PATH="$T/bin:$PATH" _steward_mail_sweep "$roster" >/dev/null 2>&1
  assert_eq "$(cmd_inbox read --for bundle-orch --workspace alpha --all | wc -l)" "$n"
  rm -rf "$T"
}

# ---- one tick, two workspaces, two identities -------------------------------
# alpha acts as acct-b; beta declares nothing and keeps the active account.
# The token set for alpha's sweep must not bleed into beta's.
test_review_sweep_uses_each_workspaces_own_account_without_bleed() {
  _orch_fixture
  printf 'github:\n  user: acct-b\n' >> "$T/alpha/workspace.yaml"
  mkdir -p "$T/beta/repos/gizmo"
  printf 'name: beta\nrepos:\n  - {name: gizmo, url: "git@github.com:other/gizmo.git", prefix: OT}\n' > "$T/beta/workspace.yaml"
  printf '  beta: {path: "%s/beta"}\n' "$T" >> "$CEL_REGISTRY"
  mkdir -p "$T/bin"; export GH_LOG="$T/gh.log"; : > "$GH_LOG"
  cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|GH_TOKEN=%s\n' "$*" "${GH_TOKEN-<unset>}" >> "$GH_LOG"
if [ "$1 $2" = "auth token" ]; then [ "$4" = acct-b ] && { echo tok-b; exit 0; }; exit 1; fi
echo '[]'
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/herdr"
  chmod +x "$T/bin/gh" "$T/bin/herdr"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LIVE_ROSTER" >/dev/null
  assert_contains "$(grep -- '--repo someone/widget' "$GH_LOG")" "GH_TOKEN=tok-b"
  assert_contains "$(grep -- '--repo other/gizmo' "$GH_LOG")" "GH_TOKEN=<unset>"
  assert_eq "$(grep -- '--repo other/gizmo' "$GH_LOG" | grep -c tok-b || true)" "0"
  rm -rf "$T"
}

# --- steward reminders never pile up -----------------------------------------
# A reminder is never itself an open item, so later reminders cannot count it
# and one blocker over many ticks leaves nothing open from the steward.
test_cel82_one_blocker_and_many_ticks_leave_one_reminder_counting_one() {
  _orch_fixture; _nudge_herdr_stub
  mkdir -p "$CEL_INBOX_DIR"
  printf '{"id":"1","ts":"2020-01-01T00:00:00Z","from":"w","to":"bundle-orch","kind":"blocked","message":"credit gone"}\n' \
    > "$CEL_INBOX_DIR/alpha.jsonl"
  local i roster='{"result":{"agents":[{"name":"bundle-orch","pane_id":"w:p2","cwd":"/x"}]}}'
  for i in 1 2 3 4; do
    PATH="$T/bin:$PATH" _STEWARD_WINDOW=0 _steward_mail_sweep "$roster" >/dev/null 2>&1
  done
  # reminders are never filed as open items
  local open; open="$(cmd_inbox open --for bundle-orch --workspace alpha --json | jq -c 'select(.from == "steward")')"
  assert_eq "$open" ""
  # and no "unresolved for Nh" second opinion goes to root
  assert_eq "$(jq -c 'select(.to == "root" and (.message | test("unresolved for")))' "$CEL_INBOX_DIR/alpha.jsonl")" ""
  rm -rf "$T"
}

# Worker done-reports need no action, so they never earn an unread reminder.
test_cel82_status_mail_alone_raises_no_unread_reminder() {
  _orch_fixture; _nudge_herdr_stub
  mkdir -p "$CEL_INBOX_DIR"
  printf '{"id":"1","ts":"2020-01-01T00:00:00Z","from":"w","to":"bundle-orch","kind":"status","message":"done"}\n' \
    > "$CEL_INBOX_DIR/alpha.jsonl"
  local roster='{"result":{"agents":[{"name":"bundle-orch","pane_id":"w:p2","cwd":"/x"}]}}'
  PATH="$T/bin:$PATH" _STEWARD_WINDOW=0 _steward_mail_sweep "$roster" >/dev/null 2>&1
  assert_eq "$(jq -c 'select(.from == "steward")' "$CEL_INBOX_DIR/alpha.jsonl")" ""
  rm -rf "$T"
}

# A mailbox that does not parse is unknown, not "nothing actionable": the
# sweep says so naming the file, wherever the torn line sits, and concludes
# nothing from it - no reminder, nothing written.
test_steward_mail_sweep_reports_a_corrupt_mailbox_as_unknown_not_empty() {
  _orch_fixture; _nudge_herdr_stub
  mkdir -p "$CEL_INBOX_DIR"
  local f="$CEL_INBOX_DIR/alpha.jsonl" torn out before
  local roster='{"result":{"agents":[{"name":"bundle-orch","pane_id":"w:p2","cwd":"/x"}]}}'
  local decision='{"id":"1","ts":"2020-01-01T00:00:00Z","from":"w","to":"bundle-orch","kind":"decision","message":"merge or wait?"}'
  for torn in first last; do
    { [ "$torn" = first ] && printf '{"id":"0","ts":\n'
      printf '%s\n' "$decision"
      [ "$torn" = last ] && printf '{"id":"2","ts":\n'; } > "$f"
    before="$(cksum < "$f")"
    out="$(PATH="$T/bin:$PATH" _STEWARD_WINDOW=0 _steward_mail_sweep "$roster" 2>&1)"
    assert_contains "$out" "alpha: mailbox $f is corrupt - its unread mail is unknown" || { echo "torn line $torn"; rm -rf "$T"; return 1; }
    assert_eq "$(cksum < "$f")" "$before" || { echo "torn line $torn: the sweep wrote to a mailbox it could not read"; rm -rf "$T"; return 1; }
    if _steward_unread_actionable alpha bundle-orch >/dev/null 2>&1; then
      echo "torn line $torn: a corrupt mailbox read as nothing actionable"; rm -rf "$T"; return 1
    fi
  done
  rm -rf "$T"
}

test_cel82_credit_alert_clears_once_credit_is_above_the_floor() {
  _rollup_fixture
  _STEWARD_WINDOW=0 _steward_quota >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "deepseek"
  QUOTA_REMAINING="5.00"
  _STEWARD_WINDOW=0 _steward_quota >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  rm -rf "$T"
}

test_cel82_orchestrator_alert_clears_once_it_is_live() {
  _orch_fixture
  mkdir -p "$CEL_INBOX_DIR"
  STUB_LAUNCH_RC=1 _steward_orchestrators "$ROSTER" >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "will not start"
  _steward_orchestrators "$LIVE_ROSTER" >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  rm -rf "$T"
}

# A legacy reminder with no fp is superseded by the first new one, not left
# open beside it.
test_cel82_a_legacy_reminder_without_fp_is_superseded() {
  _orch_fixture
  mkdir -p "$CEL_INBOX_DIR"
  printf '{"id":"5","ts":"2020-01-01T00:00:00Z","from":"steward","to":"bundle-orch","kind":"blocked","message":"steward: you have 3 UNRESOLVED decision(s)/blocker(s)"}\n' \
    > "$CEL_INBOX_DIR/alpha.jsonl"
  _steward_remind alpha bundle-orch remind-open blocked "steward: you have 1 UNRESOLVED decision(s)/blocker(s)"
  local open; open="$(cmd_inbox open --for bundle-orch --workspace alpha --json)"
  assert_eq "$(printf '%s\n' "$open" | grep -c . || true)" "1"
  assert_contains "$open" "you have 1 UNRESOLVED"
  rm -rf "$T"
}

# ...and the old one is resolved BEFORE the new one is written, so an
# interruption between the writes can never leave two live.
test_cel82_old_reminder_is_resolved_before_the_new_one_is_written() {
  _orch_fixture
  mkdir -p "$CEL_INBOX_DIR"
  _steward_remind alpha bundle-orch remind-open blocked "first"
  # fail every write after the first: the resolution must be that write
  local real; real="$(declare -f _inbox_append)"
  _inbox_append() { [ -e "$T/wrote" ] && return 1; : > "$T/wrote"; printf '%s\n' "$2" >> "$1"; }
  assert_fails _steward_remind alpha bundle-orch remind-open blocked "second"
  eval "$real"
  assert_eq "$(cmd_inbox open --for bundle-orch --workspace alpha --json | grep -c . || true)" "0"
  rm -rf "$T"
}

# --- an orchestrator brought back without its inbox hook --------------------
# An orchestrator relaunched as a bare `omp --resume` (e.g. by a herdr restart)
# has no hook and cannot receive mail. The steward restarts one that is safe to
# restart, and otherwise says so to root exactly once.
_hook_fixture() { # <status> <composer: empty|draft>
  _orch_fixture
  printf 'bundle-orch\talpha\tbundle\tw:p2\t%s\tstripped\tcel run orchestrator --product bundle --workspace alpha --restart\n' "$1" > "$T/rows"
  STUB_COMPOSER="$2"
  : > "$T/restarted"
  run_stripped_orchestrators() { cat "$T/rows"; }
  _steward_orch_composer_empty() { [ "$STUB_COMPOSER" = empty ]; }
  _steward_restart_orch() { printf '%s %s\n' "$1" "$2" >> "$T/restarted"; }
}
_root_mail() { cmd_inbox read --for root --workspace alpha --all 2>/dev/null; }
_root_open() { cmd_inbox open --for root --workspace alpha --json 2>/dev/null | jq -s 'length'; }

test_steward_restarts_a_stripped_idle_orchestrator_once_and_tells_root() {
  _hook_fixture idle empty
  local out; out="$(_steward_inbox_hooks)"
  assert_eq "$(cat "$T/restarted")" "bundle alpha"
  assert_contains "$out" "bundle-orch"
  assert_contains "$(_root_mail)" "bundle-orch came back without its inbox hook (probably a herdr restart); restarted it with the full launch line"
  rm -rf "$T"
}

test_steward_does_not_restart_a_working_stripped_orchestrator_and_says_so_once() {
  _hook_fixture working empty
  _steward_inbox_hooks >/dev/null
  _steward_inbox_hooks >/dev/null
  assert_eq "$(cat "$T/restarted")" ""
  assert_eq "$(_root_open)" "1"
  assert_eq "$(_root_mail | grep -c 'cannot receive mail' || true)" "1"
  assert_contains "$(_root_mail)" "cel run orchestrator --product bundle --workspace alpha --restart"
  rm -rf "$T"
}

test_steward_does_not_restart_over_a_draft() {
  _hook_fixture idle draft
  _steward_inbox_hooks >/dev/null
  assert_eq "$(cat "$T/restarted")" ""
  assert_contains "$(_root_mail)" "cannot receive mail"
  rm -rf "$T"
}

test_steward_escalates_when_the_restart_comes_back_stripped() {
  _hook_fixture idle empty
  _steward_inbox_hooks >/dev/null
  _steward_inbox_hooks >/dev/null   # still stripped on the next tick
  _steward_inbox_hooks >/dev/null
  assert_eq "$(wc -l < "$T/restarted")" "1"
  assert_eq "$(_root_mail | grep -c 'still without its inbox hook' || true)" "1"
  rm -rf "$T"
}

test_steward_leaves_an_orchestrator_with_its_hook_alone() {
  _hook_fixture idle empty
  sed -i 's/\tstripped\t/\tok\t/' "$T/rows"
  local out; out="$(_steward_inbox_hooks)"
  assert_eq "$(cat "$T/restarted")" ""
  assert_eq "$(_root_mail)" ""
  rm -rf "$T"
}
test_steward_unknown_inbox_evidence_replaces_unproven_failure_without_restart() {
  _hook_fixture idle empty
  _steward_raise alpha orch-nohook-bundle blocked 'previous missing-hook claim' >/dev/null
  printf 'bundle-orch\talpha\tbundle\tw:p2\tidle\tunknown\tunused-restart\n' > "$T/rows"
  _steward_inbox_hooks >/dev/null
  _steward_inbox_hooks >/dev/null
  assert_eq "$(cat "$T/restarted")" ''
  assert_eq "$(cmd_inbox open --for root --workspace alpha --json | jq -sc '[.[].fp]')" '["orch-hook-unverified-bundle"]'
  printf 'bundle-orch\talpha\tbundle\tw:p2\tidle\tok\tunused-restart\n' > "$T/rows"
  _steward_inbox_hooks >/dev/null
  assert_eq "$(_root_open)" 0
  rm -rf "$T"
}

test_steward_observable_missing_hook_after_unknown_remains_actionable() {
  _hook_fixture idle empty
  printf 'bundle-orch\talpha\tbundle\tw:p2\tidle\tunknown\tunused-restart\n' > "$T/rows"
  _steward_inbox_hooks >/dev/null
  assert_eq "$(cat "$T/restarted")" ''
  printf 'bundle-orch\talpha\tbundle\tw:p2\tidle\tstripped\tunused-restart\n' > "$T/rows"
  _steward_inbox_hooks >/dev/null
  assert_eq "$(cat "$T/restarted")" 'bundle alpha'
  assert_eq "$(_root_open)" 0
  rm -rf "$T"
}

# DEAF: the hook is in argv but its `cel inbox watch --parent` child is gone.
# Same rule as stripped - restart only an idle agent with an empty composer -
# once the deafness has outlasted the hook's own restart backoff.
test_steward_restarts_a_deaf_idle_orchestrator_once_it_stays_deaf() {
  _hook_fixture idle empty
  printf 'bundle-orch\talpha\tbundle\tw:p2\tidle\tdeaf\tcel run orchestrator --product bundle --workspace alpha --restart\t-\n' > "$T/rows"
  _steward_inbox_hooks >/dev/null
  assert_eq "$(cat "$T/restarted")" ""          # first sighting: could be the hook's own restart gap
  assert_eq "$(_root_mail)" ""
  # the next tick, past the confirmation window
  sed -i 's/^\(orch-deaf-seen-alpha-bundle\) .*/\1 1/' "$_STEWARD_STATE"
  local out; out="$(_steward_inbox_hooks)"
  assert_eq "$(cat "$T/restarted")" "bundle alpha"
  assert_contains "$out" "bundle-orch has its inbox hook but no live inbox watcher - restarted it"
  assert_contains "$(_root_mail)" "bundle-orch has its inbox hook but no live inbox watcher (its cel inbox watch --parent child is gone); restarted it so its inbox hook starts a new watcher"
  rm -rf "$T"
}

test_steward_forgets_deafness_that_heals_before_it_is_confirmed() {
  _hook_fixture idle empty
  printf 'bundle-orch\talpha\tbundle\tw:p2\tidle\tdeaf\tunused-restart\t-\n' > "$T/rows"
  _steward_inbox_hooks >/dev/null
  printf 'bundle-orch\talpha\tbundle\tw:p2\tidle\tok\tunused-restart\t-\n' > "$T/rows"
  _steward_inbox_hooks >/dev/null
  ! grep -q '^orch-deaf-seen-' "$_STEWARD_STATE" || { echo "healed deafness still recorded"; return 1; }
  assert_eq "$(cat "$T/restarted")" ""
  rm -rf "$T"
}

# A row that vanishes (agent gone, roster unreadable) ends the sighting: an
# agent that comes back deaf later is confirmed afresh, not on an old stamp.
test_steward_forgets_deafness_whose_row_vanished() {
  _hook_fixture idle empty
  printf 'bundle-orch\talpha\tbundle\tw:p2\tidle\tdeaf\tunused-restart\t-\n' > "$T/rows"
  _steward_inbox_hooks >/dev/null
  sed -i 's/^\(orch-deaf-seen-alpha-bundle\) .*/\1 1/' "$_STEWARD_STATE"   # an old sighting
  : > "$T/rows"
  _steward_inbox_hooks >/dev/null
  ! grep -q '^orch-deaf-seen-' "$_STEWARD_STATE" || { echo "vanished row's sighting kept"; return 1; }
  printf 'bundle-orch\talpha\tbundle\tw:p2\tidle\tdeaf\tunused-restart\t-\n' > "$T/rows"
  _steward_inbox_hooks >/dev/null
  assert_eq "$(cat "$T/restarted")" ""
  rm -rf "$T"
}

test_steward_does_not_restart_a_deaf_orchestrator_over_a_draft() {
  _hook_fixture idle draft
  printf 'bundle-orch\talpha\tbundle\tw:p2\tidle\tdeaf\tcel run orchestrator --product bundle --workspace alpha --restart\t-\n' > "$T/rows"
  CEL_STEWARD_DEAF_CONFIRM=0 _steward_inbox_hooks >/dev/null
  assert_eq "$(cat "$T/restarted")" ""
  assert_contains "$(_root_mail)" "cannot receive mail - its inbox hook is loaded but its inbox watcher is gone"
  rm -rf "$T"
}

test_steward_restarts_a_deaf_solo_lane_as_a_lane() {
  _hook_fixture idle empty
  _steward_restart_orch() { printf '%s\n' "$*" >> "$T/restarted"; }
  printf 'bundle-disk-cleanup\talpha\tbundle\tw:p3\tidle\tdeaf\tcel run solo --product bundle --lane disk-cleanup --workspace alpha --restart\tdisk-cleanup\n' > "$T/rows"
  CEL_STEWARD_DEAF_CONFIRM=0 _steward_inbox_hooks >/dev/null
  assert_eq "$(cat "$T/restarted")" "bundle alpha disk-cleanup"
  assert_contains "$(_root_mail)" "bundle-disk-cleanup has its inbox hook but no live inbox watcher"
  rm -rf "$T"
}

test_steward_zero_confirm_deaf_lane_restarts_across_second_rollover() {
  _hook_fixture idle empty
  _steward_restart_orch() { printf '%s\n' "$*" >> "$T/restarted"; }
  printf 'bundle-disk-cleanup\talpha\tbundle\tw:p3\tidle\tdeaf\tcel run solo --product bundle --lane disk-cleanup --workspace alpha --restart\tdisk-cleanup\n' > "$T/rows"
  printf '1700000000\n' > "$T/clock"
  date() {
    if [ "${1:-}" = +%s ]; then
      local clock
      read -r clock < "$T/clock"
      printf '%s\n' "$((clock + 1))" > "$T/clock"
      printf '%s\n' "$clock"
    else
      command date "$@"
    fi
  }
  CEL_STEWARD_DEAF_CONFIRM=0 _steward_inbox_hooks >/dev/null
  assert_eq "$(cat "$T/restarted")" 'bundle alpha disk-cleanup'
  assert_contains "$(_root_mail)" 'bundle-disk-cleanup has its inbox hook but no live inbox watcher'
  rm -rf "$T"
}


# The composer is empty only when the pane PROVES it: an editor box between
# two dividers with nothing in it. Anything else - text, no box, no read - is
# a draft the steward must not kill.
test_steward_composer_is_empty_only_when_provably_so() {
  local frame=$'● done\n────────────\n\n────────────\n~/alpha  ctx 12%'
  _steward_composer_empty_text "$frame"
  assert_fails _steward_composer_empty_text $'● done\n────────────\nhalf a thought\n────────────\nfooter'
  assert_fails _steward_composer_empty_text $'● done\nno editor box here'
  assert_fails _steward_composer_empty_text ""
}

# --- one summary line per workspace per day, never a decision ----------------
test_cel93_steward_summarises_owner_decisions_once_a_day() {
  _orch_fixture; _nudge_herdr_stub
  source "$CEL_ROOT/lib/decide.sh"
  CEL_INBOX_ME=bundle-orch cmd_decide ask --workspace alpha --title "pick a style" --context "The widget build broke after the alpha merge and the beta release waits on it. Option one ships today with a known gap; option two waits a day. I recommend one; if nobody answers, beta slips." >/dev/null 2>&1
  printf '{"id":"1","ts":"2020-01-01T00:00:00Z","from":"w","to":"bundle-orch","kind":"blocked","message":"credit gone"}\n' \
    >> "$CEL_INBOX_DIR/alpha.jsonl"
  local i roster='{"result":{"agents":[{"name":"bundle-orch","pane_id":"w:p2","cwd":"/x"}]}}'
  for i in 1 2 3; do
    PATH="$T/bin:$PATH" _STEWARD_WINDOW=0 _steward_mail_sweep "$roster" >/dev/null 2>&1
  done
  local f="$CEL_INBOX_DIR/alpha.jsonl"
  assert_eq "$(jq -c 'select(.from == "steward" and (.message | test("owner decision")))' "$f" | grep -c . || true)" "1"
  assert_eq "$(jq -c 'select(.from == "steward" and .kind != "status" and .kind != "resolution")' "$f")" ""
  assert_eq "$(jq -c 'select(.message | test("UNRESOLVED"))' "$f")" ""
  rm -rf "$T"
}

# --- the steward stays quiet about things that need no action ---------------
# Each case below is a nudge that needs no action and must not be sent.
_cel96_sweep() { # <gh-json>
  _orch_fixture; _nudge_herdr_stub
  printf '%s' "$1" > "$T/prs.json"
  cat > "$T/bin/gh" <<SH
#!/usr/bin/env bash
cat "$T/prs.json"
SH
  chmod +x "$T/bin/gh"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LIVE_ROSTER" >/dev/null 2>&1
  CEL96_MAIL="$(cmd_inbox read --for bundle-orch --workspace alpha --all)"
}

test_cel96_a_superseded_or_held_pr_is_never_nudged() {
  _cel96_sweep '[{"number":41,"headRefName":"WG-1-x","headRefOid":"h1","reviewDecision":"APPROVED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","labels":[{"name":"superseded"}],"reviews":[{"state":"APPROVED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"h1"}}]},
                 {"number":42,"headRefName":"WG-2-y","headRefOid":"h2","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"statusCheckRollup":[{"conclusion":"FAILURE"}],"createdAt":"2020-01-01T00:00:00Z","labels":[{"name":"Hold"}],"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"h2"}}]},
                 {"number":43,"headRefName":"WG-3-z","headRefOid":"h3","reviewDecision":"APPROVED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","labels":[],"reviews":[{"state":"APPROVED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"h3"}}]}]'
  assert_eq "$(printf '%s' "$CEL96_MAIL" | grep -c '#41' || true)" "0"
  assert_eq "$(printf '%s' "$CEL96_MAIL" | grep -c '#42' || true)" "0"
  assert_contains "$CEL96_MAIL" "PR #43 on widget is APPROVED"
  rm -rf "$T"
}

test_cel96_an_approval_of_an_old_head_is_not_approved() {
  _cel96_sweep '[{"number":41,"headRefName":"WG-1-x","headRefOid":"new","reviewDecision":"APPROVED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","labels":[],"reviews":[{"state":"APPROVED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"old"}}]}]'
  assert_eq "$(printf '%s' "$CEL96_MAIL" | grep -c 'APPROVED' || true)" "0"
  rm -rf "$T"
}

test_cel96_changes_requested_on_a_superseded_head_is_not_nagged() {
  # ana asked for changes on `old`; ben pushed `new`. The fix is on the branch.
  _cel96_sweep '[{"number":41,"headRefName":"WG-1-x","headRefOid":"new","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","labels":[],"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"old"}}]},
                 {"number":42,"headRefName":"WG-2-y","headRefOid":"h2","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","labels":[],"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"h2"}},{"state":"APPROVED","submittedAt":"2020-01-03T00:00:00Z","commit":{"oid":"h2"}}]}]'
  assert_eq "$(printf '%s' "$CEL96_MAIL" | grep -c 'changes requested' || true)" "0"
  rm -rf "$T"
}

test_cel96_changes_requested_on_the_current_head_is_still_nagged() {
  _cel96_sweep '[{"number":41,"headRefName":"WG-1-x","headRefOid":"h1","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","labels":[],"reviews":[{"state":"APPROVED","submittedAt":"2020-01-01T00:00:00Z","commit":{"oid":"h0"}},{"state":"CHANGES_REQUESTED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"h1"}}]}]'
  assert_contains "$CEL96_MAIL" "PR #41 on widget has changes requested"
  rm -rf "$T"
  # an approval submitted later, but of an OLD head, answers nothing
  _cel96_sweep '[{"number":42,"headRefName":"WG-2-y","headRefOid":"h2","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","labels":[],"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"h2"}},{"state":"APPROVED","submittedAt":"2020-01-03T00:00:00Z","commit":{"oid":"h1"}}]}]'
  assert_contains "$CEL96_MAIL" "PR #42 on widget has changes requested"
  rm -rf "$T"
}

# Ticket nags are for the fleet's own open work: not ben's ticket, not a Done
# ticket, not one the owner has marked blocked.
test_cel96_ticket_nags_skip_others_done_and_blocked_tickets() {
  _orch_fixture
  printf 'LINEAR_API_KEY=fixture-alpha\n' > "$T/alpha/env.local"
  : > "$T/sent"
  curl() {
    printf '%s' '{"data":{"issues":{"nodes":[
      {"identifier":"WG-1","title":"mine","assignee":{"isMe":true},"state":{"name":"Ready","type":"unstarted"},"labels":{"nodes":[]}},
      {"identifier":"WG-2","title":"bens","assignee":{"isMe":false},"state":{"name":"Ready","type":"unstarted"},"labels":{"nodes":[]}},
      {"identifier":"WG-3","title":"done","assignee":{"isMe":true},"state":{"name":"Done","type":"completed"},"labels":{"nodes":[]}},
      {"identifier":"WG-4","title":"cancelled","assignee":null,"state":{"name":"Cancelled","type":"canceled"},"labels":{"nodes":[]}},
      {"identifier":"WG-5","title":"held","assignee":{"isMe":true},"state":{"name":"Ready","type":"unstarted"},"labels":{"nodes":[{"name":"Blocked"}]}},
      {"identifier":"WG-6","title":"stated","assignee":{"isMe":true},"state":{"name":"Blocked","type":"started"},"labels":{"nodes":[]}}]}}}'
  }
  local sent=""
  cmd_inbox() { printf '%s\n' "$3" >> "$T/sent"; }
  _steward_ready_tickets "$LIVE_ROSTER" >/dev/null
  sent="$(cat "$T/sent")"
  assert_contains "$sent" "WG-1 "
  local id; for id in WG-2 WG-3 WG-4 WG-5 WG-6; do
    assert_eq "$(printf '%s' "$sent" | grep -c "$id " || true)" "0"
  done
  rm -rf "$T"
}

# An expired AFK is one item counting its raises, resolved once AFK is off.
test_cel96_afk_expired_is_one_item_counting_raises_and_resolves_when_cleared() {
  _afk_sweep_fixture '2020-01-01T00:00:00Z' || return 1
  # the fixture records raises; this test wants the real mailbox behind them
  _steward_raise() { cmd_inbox send root "$4" --from steward --workspace "$1" --kind "$3" --fp "$2" >/dev/null 2>&1 || true; }
  export CEL_INBOX_DIR="$T/inbox"; mkdir -p "$CEL_INBOX_DIR"
  local i; for i in $(seq 1 100); do _steward_afk_sweep >/dev/null 2>&1; done
  local f="$CEL_INBOX_DIR/alpha.jsonl" id
  # one item, 99 updates on it: a count of 100 on one unresolved condition
  assert_eq "$(jq -s '[.[] | select(.fp == "afk-expired" and .kind == "status")] | length' "$f")" "1"
  id="$(_inbox_open_fp alpha afk-expired steward root)"
  assert_eq "$(jq -s --arg i "$id" '1 + ([.[] | select(.kind == "update" and .ref == $i)] | length)' "$f")" "100"
  cmd_afk off >/dev/null 2>&1
  _steward_afk_sweep >/dev/null 2>&1
  assert_eq "$(_inbox_open_fp alpha afk-expired steward root)" ""
  assert_eq "$(_inbox_open_fp beta afk-expired steward root)" ""
  assert_eq "$(jq -s --arg i "$id" '[.[] | select(.kind == "resolution" and .ref == $i)] | length' "$f")" "1"
  _afk_sweep_teardown; unset CEL_INBOX_DIR
}

# --- the orchestrators' own pool, warned before it is spent ------------------
# The orchestrators run on omp's Anthropic credentials, not the gateway, so a
# spent pool stops their turns with no word anywhere. The steward reads `omp
# usage --json` (no model call) and says so ONCE, to root, while there is still
# headroom to act on.
_pool_fixture() { # <jq-filter applied to the omp fixture>
  source "$CEL_ROOT/lib/quota.sh"
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  mkdir -p "$T/alpha" "$CEL_INBOX_DIR"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\n' > "$T/alpha/workspace.yaml"
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
  POOL_FILTER="$1"
  _sub_omp_usage() { jq "$POOL_FILTER" "$CEL_ROOT/tests/fixtures/omp-usage.json"; }
}
# every anthropic credential at or above 85% on its unscoped 5h or 7d window
_POOL_HOT='(.reports[] | select(.provider == "anthropic") | .limits[]
            | select(.id == "anthropic:7d") | .amount.usedFraction) |= 0.9'
_POOL_DEAD='.disabledCredentials = [{id: 10, provider: "anthropic", cause: "oauth refresh failed",
            email: "ana@alpha.test", accountId: "ant-ana"}]'

test_steward_raises_one_item_when_the_orchestrator_pool_is_nearly_spent() {
  _pool_fixture "$_POOL_HOT"
  local i
  for i in 1 2 3; do _STEWARD_WINDOW=0 _steward_orch_pool >/dev/null 2>&1; done
  local open; open="$(cmd_inbox open --for root --workspace alpha --json | jq -s '.')"
  assert_eq "$(printf '%s' "$open" | jq 'length')" 1
  assert_contains "$(printf '%s' "$open" | jq -r '.[0].fp // .[0].fingerprint // ""')" "orch-pool"
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "orchestrator"
  rm -rf "$T"
}

test_steward_raises_the_pool_item_for_a_disabled_credential() {
  _pool_fixture "$_POOL_DEAD"
  _steward_orch_pool >/dev/null 2>&1
  local open; open="$(cmd_inbox open --for root --workspace alpha)"
  assert_contains "$open" "ana@alpha.test"
  assert_contains "$open" "omp login anthropic"
  rm -rf "$T"
}

test_steward_resolves_the_pool_item_when_headroom_returns() {
  _pool_fixture "$_POOL_HOT"
  _steward_orch_pool >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "orchestrator"
  POOL_FILTER='.'
  _steward_orch_pool >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  rm -rf "$T"
}

# The fixture as recorded has one account at 100% and two with headroom:
# that is a working pool, and the steward says nothing about it.
test_steward_is_silent_about_a_pool_with_headroom() {
  _pool_fixture '.'
  _steward_orch_pool >/dev/null 2>&1
  assert_eq "$(cmd_inbox read --for root --workspace alpha --all)" ""
  rm -rf "$T"
}

# An unreadable omp answer is no evidence: it must not clear a true warning.
test_steward_keeps_the_pool_item_when_omp_answers_garbage() {
  _pool_fixture "$_POOL_HOT"
  _steward_orch_pool >/dev/null 2>&1
  _sub_omp_usage() { printf 'not json'; }
  _steward_orch_pool >/dev/null 2>&1
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "orchestrator"
  rm -rf "$T"
}

# OWNER-ONLY, SO ONCE PER CHANGE. A credential omp disabled comes back only
# through an interactive `omp login anthropic`; no tick changes it. It is said
# when it starts, again only when the set of disabled credentials changes, and
# taken down when it is empty.
test_steward_raises_a_disabled_credential_once_per_change_of_state() {
  _pool_fixture "$_POOL_DEAD"
  local f="$CEL_INBOX_DIR/alpha.jsonl" i
  for i in 1 2 3 4 5; do _STEWARD_WINDOW=0 _steward_orch_pool >/dev/null 2>&1; done
  assert_eq "$(jq -s '[.[] | select(.from == "steward" and (.message | contains("ana@alpha.test")))] | length' "$f")" "1"
  # a second credential goes: that is a change, said once
  POOL_FILTER="$_POOL_DEAD"' | .disabledCredentials += [{provider: "anthropic", email: "ben@alpha.test", accountId: "ant-ben"}]'
  for i in 1 2 3; do _STEWARD_WINDOW=0 _steward_orch_pool >/dev/null 2>&1; done
  assert_eq "$(jq -s '[.[] | select(.from == "steward" and (.message | contains("ben@alpha.test")))] | length' "$f")" "1"
  assert_eq "$(jq -s '[.[] | select(.from == "steward" and .kind != "resolution")] | length' "$f")" "2"
  assert_contains "$(cmd_inbox open --for root --workspace alpha)" "omp login anthropic"
  # the owner logs back in: the item comes down
  POOL_FILTER='.'
  _steward_orch_pool >/dev/null 2>&1
  assert_eq "$(cmd_inbox open --for root --workspace alpha)" ""
  rm -rf "$T"
}

# --- a blocked rex upgrade is said once per version -------------------------
# The block's reason names the reviewers and sessions in the way, and that list
# changes with every PR review that starts or ends. Root hears a version once
# when it is first blocked and once more after a day of it - never because the
# list moved. The round itself is lib/rex.sh's (tests/rex-generation.test.sh);
# here it is a fixture.
_rexup_fixture() {
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  mkdir -p "$T/alpha" "$CEL_INBOX_DIR"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\n' > "$T/alpha/workspace.yaml"
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
  REXUP_ROUND=""; REXUP_POLICY=""
  rex_upgrade_round() { [ -z "$REXUP_ROUND" ] || printf '%s\n' "$REXUP_ROUND"; }
  _rex_policy_versions() { [ -z "$REXUP_POLICY" ] || printf '%s\n' "$REXUP_POLICY"; }
}
_rexup_blocked() { # <version> <who is in the way>
  REXUP_ROUND="$(printf 'blocked\t%s\tthese Rex agents could not be resumed after a server restart: %s' "$1" "$2")"
  _steward_rex_upgrade >/dev/null 2>&1
}
# Every word root got about a blocked rex: items and their updates.
_rexup_alerts() {
  jq -s '[.[] | select(.from == "steward" and .to == "root" and (.kind == "blocked" or .kind == "update")
          and (.message | startswith("steward: rex")))] | length' "$CEL_INBOX_DIR/alpha.jsonl"
}
_rexup_open() { cmd_inbox open --for root --workspace alpha 2>/dev/null; }

test_steward_says_a_blocked_rex_upgrade_once_however_the_reviewers_churn() {
  _rexup_fixture
  _rexup_blocked 0.0.2-gbbb 'widget-pr-7-review: a reviewer'
  _rexup_blocked 0.0.2-gbbb 'widget-pr-7-review: a reviewer; widget-pr-8-review: a reviewer'
  _rexup_blocked 0.0.2-gbbb 'widget-pr-8-review: a reviewer'
  _rexup_blocked 0.0.2-gbbb 'gizmo-pr-3-review: a reviewer'
  assert_eq "$(_rexup_alerts)" 1
  # the list still goes with the one word that is said
  assert_contains "$(_rexup_open)" "rex 0.0.2-gbbb is available"
  assert_contains "$(_rexup_open)" "widget-pr-7-review"
  rm -rf "$T"
}

test_steward_says_a_new_blocked_rex_version_again() {
  _rexup_fixture
  _rexup_blocked 0.0.2-gbbb 'widget-pr-7-review: a reviewer'
  _rexup_blocked 0.0.3-gccc 'widget-pr-7-review: a reviewer'
  _rexup_blocked 0.0.3-gccc 'widget-pr-9-review: a reviewer'
  assert_eq "$(_rexup_alerts)" 2
  # one open item, about the new version: the old version's is taken down
  assert_eq "$(cmd_inbox open --for root --workspace alpha --json | jq -s 'length')" 1
  assert_contains "$(_rexup_open)" "rex 0.0.3-gccc is available"
  rm -rf "$T"
}

test_steward_says_a_rex_upgrade_blocked_for_a_day_once_more() {
  _rexup_fixture
  _rexup_blocked 0.0.2-gbbb 'widget-pr-7-review: a reviewer'
  # the block began a day and a bit ago
  printf 'rex-upgrade-blocked 0.0.2-gbbb %s 0\n' "$(( $(date +%s) - 90000 ))" > "$T/state"
  _rexup_blocked 0.0.2-gbbb 'widget-pr-8-review: a reviewer'
  _rexup_blocked 0.0.2-gbbb 'widget-pr-9-review: a reviewer'
  _rexup_blocked 0.0.2-gbbb 'widget-pr-7-review: a reviewer'
  assert_eq "$(_rexup_alerts)" 2
  assert_eq "$(jq -s '[.[] | select(.from == "steward" and (.message | contains("blocked for over a day")))] | length' "$CEL_INBOX_DIR/alpha.jsonl")" 1
  # the day-old word is an update on the same item, with the list as it is now
  assert_eq "$(cmd_inbox open --for root --workspace alpha --json | jq -s 'length')" 1
  assert_contains "$(jq -rs '[.[] | select(.kind == "update")] | last | .message' "$CEL_INBOX_DIR/alpha.jsonl")" "widget-pr-8-review"
  rm -rf "$T"
}

# The item comes down when the block clears or the version is installed. A
# block that clears and comes back for the same version is not news; a skip
# whose answer about the block is unknown, or apt that cannot say what is
# installed, takes nothing down.
test_steward_resolves_the_blocked_rex_item_when_the_block_clears_or_rex_is_installed() {
  _rexup_fixture
  _rexup_blocked 0.0.2-gbbb 'widget-pr-7-review: a reviewer'
  REXUP_ROUND="$(printf 'waiting\t0.0.2-gbbb\tanother Rex server change is in progress\tprecheck')"
  _steward_rex_upgrade >/dev/null 2>&1
  assert_contains "$(_rexup_open)" "rex 0.0.2-gbbb"
  REXUP_ROUND="$(printf 'waiting\t0.0.2-gbbb\tnot every Rex agent went idle within 120s: alpha-orch (working)\tbusy')"
  _steward_rex_upgrade >/dev/null 2>&1
  assert_eq "$(_rexup_open)" ""
  _rexup_blocked 0.0.2-gbbb 'widget-pr-8-review: a reviewer'
  assert_eq "$(_rexup_alerts)" 1
  assert_eq "$(_rexup_open)" ""
  # back blocked under a new version, then installed by hand
  _rexup_blocked 0.0.3-gccc 'widget-pr-8-review: a reviewer'
  assert_contains "$(_rexup_open)" "rex 0.0.3-gccc"
  REXUP_ROUND=""
  _steward_rex_upgrade >/dev/null 2>&1
  assert_contains "$(_rexup_open)" "rex 0.0.3-gccc"
  REXUP_POLICY="$(printf '0.0.2-gbbb\t0.0.3-gccc\t1')"
  _steward_rex_upgrade >/dev/null 2>&1
  assert_contains "$(_rexup_open)" "rex 0.0.3-gccc"
  REXUP_POLICY="$(printf '0.0.3-gccc\t0.0.3-gccc\t1')"
  _steward_rex_upgrade >/dev/null 2>&1
  assert_eq "$(_rexup_open)" ""
  assert_eq "$(grep -c '^rex-upgrade-blocked ' "$T/state" || true)" 0
  rm -rf "$T"
}

# The steward decides on the round's reason code, never its wording: a skip
# that got past every blocking check clears the item, one that did not keeps
# it, and a code it does not know - or none - keeps it too.
test_steward_maps_each_rex_waiting_code_to_clear_or_keep() {
  local code want
  for code in busy:clear admission:clear record:clear precheck:keep rechecked:keep bogus:keep :keep; do
    want="${code#*:}"; code="${code%%:*}"
    _rexup_fixture
    _rexup_blocked 0.0.2-gbbb 'widget-pr-7-review: a reviewer'
    # the same words every time: only the code decides
    if [ -n "$code" ]; then
      REXUP_ROUND="$(printf 'waiting\t0.0.2-gbbb\tnot every Rex agent went idle within 120s: x\t%s' "$code")"
    else
      REXUP_ROUND="$(printf 'waiting\t0.0.2-gbbb\tnot every Rex agent went idle within 120s: x')"
    fi
    _steward_rex_upgrade >/dev/null 2>&1
    if [ "$want" = clear ]; then
      assert_eq "$(_rexup_open)" "" || { echo "code '$code' kept the item"; rm -rf "$T"; return 1; }
    else
      assert_contains "$(_rexup_open)" "rex 0.0.2-gbbb" || { echo "code '$code' cleared the item"; rm -rf "$T"; return 1; }
    fi
    rm -rf "$T"
  done
}

# An alert that was not delivered is not recorded as said: the next round
# says it.
test_steward_does_not_record_a_blocked_rex_alert_that_failed_to_send() {
  _rexup_fixture
  local real; real="$(declare -f cmd_inbox)"
  cmd_inbox() { [ "$1" != send ] || return 1; }
  _rexup_blocked 0.0.2-gbbb 'widget-pr-7-review: a reviewer'
  eval "$real"
  assert_eq "$(cat "$T/state" 2>/dev/null | grep -c '^rex-upgrade-blocked ' || true)" 0 || { rm -rf "$T"; return 1; }
  _rexup_blocked 0.0.2-gbbb 'widget-pr-7-review: a reviewer'
  assert_eq "$(_rexup_alerts)" 1 || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -c '^rex-upgrade-blocked 0.0.2-gbbb .* 0$' "$T/state")" 1 || { rm -rf "$T"; return 1; }
  # the day-old reminder too: a failed send leaves stage 0 for the next round
  printf 'rex-upgrade-blocked 0.0.2-gbbb %s 0\n' "$(( $(date +%s) - 90000 ))" > "$T/state"
  cmd_inbox() { [ "$1" != send ] || return 1; }
  _rexup_blocked 0.0.2-gbbb 'widget-pr-8-review: a reviewer'
  eval "$real"
  assert_eq "$(grep -c '^rex-upgrade-blocked 0.0.2-gbbb .* 0$' "$T/state")" 1 || { rm -rf "$T"; return 1; }
  _rexup_blocked 0.0.2-gbbb 'widget-pr-8-review: a reviewer'
  assert_eq "$(_rexup_alerts)" 2 || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -c '^rex-upgrade-blocked 0.0.2-gbbb .* 1$' "$T/state")" 1 || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# --- stale decisions get one nudge per asker per day -------------------------
test_cel101_steward_asks_each_asker_about_stale_decisions_once_a_day() {
  _orch_fixture; _nudge_herdr_stub
  source "$CEL_ROOT/lib/decide.sh"
  local f="$CEL_INBOX_DIR/alpha.jsonl"
  printf '%s\n' \
    '{"id":"1000000001","ts":"2020-01-01T00:00:00Z","from":"bundle-orch","to":"owner","kind":"decision","title":"old one","asker":"bundle-orch","options":[]}' \
    '{"id":"1000000002","ts":"2020-01-02T00:00:00Z","from":"bundle-orch","to":"owner","kind":"decision","title":"old two","asker":"bundle-orch","options":[]}' \
    '{"id":"1000000003","ts":"2020-01-02T00:00:00Z","from":"gadget-orch","to":"owner","kind":"decision","title":"old three","asker":"gadget-orch","options":[]}' >> "$f"
  CEL_INBOX_ME=bundle-orch cmd_decide ask --workspace alpha --title "fresh one" --context "The widget build broke after the alpha merge and the beta release waits on it. Option one ships today with a known gap; option two waits a day. I recommend one; if nobody answers, beta slips." >/dev/null 2>&1
  local i roster='{"result":{"agents":[]}}'
  for i in 1 2 3; do
    PATH="$T/bin:$PATH" _STEWARD_WINDOW=0 _steward_mail_sweep "$roster" >/dev/null 2>&1
  done
  local b; b="$(jq -c 'select(.from == "steward" and .to == "bundle-orch" and (.message | test("withdraw")))' "$f")"
  assert_eq "$(printf '%s\n' "$b" | grep -c . || true)" "1"
  assert_contains "$b" "old one"
  assert_contains "$b" "old two"
  assert_contains "$b" "cel decide withdraw"
  if printf '%s' "$b" | grep -q 'fresh one'; then echo "nudged about a fresh decision"; return 1; fi
  assert_eq "$(jq -c 'select(.from == "steward" and .to == "gadget-orch" and (.message | test("withdraw")))' "$f" | grep -c . || true)" "1"
  rm -rf "$T"
}

# A re-asked question is not stale; concurrent sweeps send once.
test_cel101_stale_nudge_counts_from_the_last_reask_and_sends_once_concurrently() {
  _orch_fixture; _nudge_herdr_stub
  source "$CEL_ROOT/lib/decide.sh"
  local f="$CEL_INBOX_DIR/alpha.jsonl"
  printf '%s\n' \
    '{"id":"1000000001","ts":"2020-01-01T00:00:00Z","from":"bundle-orch","to":"owner","kind":"decision","title":"reasked","asker":"bundle-orch","options":[]}' \
    '{"id":"1000000002","ts":"2020-01-01T00:00:00Z","from":"gadget-orch","to":"owner","kind":"decision","title":"left alone","asker":"gadget-orch","options":[]}' >> "$f"
  CEL_INBOX_ME=bundle-orch cmd_decide ask --workspace alpha --title "reasked" --context "The widget build broke after the alpha merge and the beta release waits on it. Option one ships today with a known gap; option two waits a day. I recommend one; if nobody answers, beta slips." >/dev/null 2>&1
  local i pids=""; for i in 1 2 3 4; do
    ( PATH="$T/bin:$PATH" _steward_decide_stale_sweep >/dev/null 2>&1 ) & pids="$pids $!"
  done
  # shellcheck disable=SC2086
  wait $pids
  assert_eq "$(jq -c 'select(.from == "steward" and .to == "bundle-orch")' "$f")" ""
  assert_eq "$(jq -c 'select(.from == "steward" and .to == "gadget-orch")' "$f" | grep -c . || true)" "1"
  rm -rf "$T"
}

# --- "still needed" is remembered for a week unless it changes --------------
_cel128_sweep_msgs() { # <f> -> count of stale nudges to bundle-orch
  jq -c 'select(.from == "steward" and .to == "bundle-orch")' "$1" | grep -c . || true
}
test_cel128_confirmed_decision_is_skipped_until_a_week_passes_or_it_changes() {
  _orch_fixture; _nudge_herdr_stub
  source "$CEL_ROOT/lib/decide.sh"
  local f="$CEL_INBOX_DIR/alpha.jsonl" now; now="$(date -Is)"
  printf '%s\n' \
    '{"id":"1000000001","ts":"2020-01-01T00:00:00Z","from":"bundle-orch","to":"owner","kind":"decision","title":"confirmed","asker":"bundle-orch","options":[]}' \
    '{"id":"1000000002","ts":"2020-01-01T00:00:00Z","from":"bundle-orch","to":"owner","kind":"decision","title":"unconfirmed","asker":"bundle-orch","options":[]}' >> "$f"
  CEL_INBOX_ME=bundle-orch cmd_decide confirm 1000000001 --why "still blocks the release" >/dev/null 2>&1
  assert_eq "$(jq -c 'select(.kind == "confirm" and .ref == "1000000001")' "$f" | grep -c .)" "1"
  local st="$_STEWARD_STATE"
  # unconfirmed is listed; confirmed is not
  PATH="$T/bin:$PATH" _steward_decide_stale_sweep >/dev/null 2>&1
  local m; m="$(jq -r 'select(.from == "steward" and .to == "bundle-orch") | .message' "$f")"
  assert_contains "$m" "unconfirmed"
  assert_contains "$m" "cel decide confirm"
  if printf '%s' "$m" | grep -q '\[1000000001\]'; then echo "confirmed decision re-listed"; return 1; fi
  # unconfirmed still listed the next day; confirmed alone stays quiet
  : > "$st"
  PATH="$T/bin:$PATH" _steward_decide_stale_sweep >/dev/null 2>&1
  assert_eq "$(_cel128_sweep_msgs "$f")" "2"
  CEL_INBOX_ME=bundle-orch cmd_decide withdraw 1000000002 --why done >/dev/null 2>&1
  : > "$st"
  PATH="$T/bin:$PATH" _steward_decide_stale_sweep >/dev/null 2>&1
  assert_eq "$(_cel128_sweep_msgs "$f")" "2"
  # after the week it is listed again
  : > "$st"
  CEL_DECIDE_CONFIRM_SECS=0 PATH="$T/bin:$PATH" _steward_decide_stale_sweep >/dev/null 2>&1
  assert_eq "$(_cel128_sweep_msgs "$f")" "3"
  rm -rf "$T"
}
test_cel128_a_change_after_the_confirm_relists_it_at_once() {
  _orch_fixture; _nudge_herdr_stub
  source "$CEL_ROOT/lib/decide.sh"
  local f="$CEL_INBOX_DIR/alpha.jsonl"
  printf '%s\n' \
    '{"id":"1000000001","ts":"2020-01-01T00:00:00Z","from":"bundle-orch","to":"owner","kind":"decision","title":"edited","asker":"bundle-orch","options":[]}' \
    '{"id":"c1","ts":"2020-01-02T00:00:00Z","kind":"confirm","ref":"1000000001","by":"bundle-orch","to":"owner"}' \
    '{"id":"u1","ts":"2020-01-03T00:00:00Z","kind":"update","ref":"1000000001","from":"bundle-orch","to":"owner","title":"edited","context":"new"}' >> "$f"
  # the confirm is days old but the edit came after it: listed now (week not over)
  CEL_DECIDE_CONFIRM_SECS=999999999 PATH="$T/bin:$PATH" _steward_decide_stale_sweep >/dev/null 2>&1
  assert_eq "$(_cel128_sweep_msgs "$f")" "1"
  rm -rf "$T"
}
test_cel128_confirm_takes_several_ids_and_refuses_strangers() {
  _orch_fixture
  source "$CEL_ROOT/lib/decide.sh"
  local f="$CEL_INBOX_DIR/alpha.jsonl"
  printf '%s\n' \
    '{"id":"1000000001","ts":"2020-01-01T00:00:00Z","from":"bundle-orch","to":"owner","kind":"decision","title":"a","asker":"bundle-orch","options":[]}' \
    '{"id":"1000000002","ts":"2020-01-01T00:00:00Z","from":"bundle-orch","to":"owner","kind":"decision","title":"b","asker":"bundle-orch","options":[]}' >> "$f"
  CEL_INBOX_ME=bundle-orch cmd_decide confirm 1000000001 1000000002 >/dev/null 2>&1
  assert_eq "$(jq -c 'select(.kind == "confirm")' "$f" | grep -c .)" "2"
  assert_fails eval "( CEL_INBOX_ME=some-worker cmd_decide confirm 1000000001 >/dev/null 2>&1 )"
  rm -rf "$T"
}

# --- an account on pace to hit its cap before it resets ---------------------
# The usage card draws the projection; the steward says it ONCE, to root, while
# there is still time to move work off the account, and takes it down when the
# pace no longer gets there. The read is the cached subscription list - no
# provider call per tick.
_pace_fixture() { # <used-pct> <seconds-to-reset>
  source "$CEL_ROOT/lib/quota.sh"
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  mkdir -p "$T/alpha" "$CEL_INBOX_DIR"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\n' > "$T/alpha/workspace.yaml"
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
  _pace_set "$1" "$2"
  subscription_list() { cat "$T/subs.json"; }
}
_pace_set() { # <used-pct> <seconds-to-reset>
  jq -nc --argjson u "$1" --arg r "$(date -u -d "@$(( $(date +%s) + $2 ))" +%Y-%m-%dT%H:%M:%SZ)" \
    '[{provider: "claude", account: "ant-ana", label: "ana@alpha.test", source: "omp",
       windows: [{name: "7d", scope: null, used_pct: $u, resets_at: $r},
                 {name: "5h", scope: null, used_pct: 3, resets_at: $r}]},
      {provider: "claude", account: "ant-ben", label: "ben@alpha.test", source: "omp",
       windows: [{name: "7d", scope: null, used_pct: 10, resets_at: $r}]}]' > "$T/subs.json"
}

test_quota_at_risk_projects_to_the_reset_and_flags_ninety_five() {
  _pace_fixture 80 86400
  # 80% with a day of seven left projects to ~93%: not at risk
  assert_eq "$(subscription_list | quota_at_risk | jq 'length')" "0"
  # 80% with two days left: 5/7 gone -> 112% before reset
  _pace_set 80 172800
  assert_eq "$(subscription_list | quota_at_risk | jq -r '.[0].who')" "ana@alpha.test"
  assert_eq "$(subscription_list | quota_at_risk | jq '.[0].projected_pct >= 100')" "true"
  # 96% now is at risk whatever the pace
  _pace_set 96 600
  assert_eq "$(subscription_list | quota_at_risk | jq 'length')" "1"
  rm -rf "$T"
}

test_steward_warns_once_about_an_account_on_pace_for_its_cap() {
  _pace_fixture 80 172800
  local i; for i in 1 2 3; do _STEWARD_WINDOW=0 _steward_usage_pace >/dev/null 2>&1; done
  # a warning, not a blocker: one status item, the repeats roll up onto it
  local f="$CEL_INBOX_DIR/alpha.jsonl" id
  assert_eq "$(jq -s '[.[] | select(.fp == "usage-pace")] | length' "$f")" "1"
  id="$(_inbox_open_fp alpha usage-pace steward root)"
  [ -n "$id" ] || { echo "no open usage-pace item"; return 1; }
  assert_contains "$(jq -r 'select(.fp == "usage-pace") | .message' "$f")" "ana@alpha.test"
  assert_eq "$(jq -s --arg i "$id" '[.[] | select(.kind == "update" and .ref == $i)] | length' "$f")" "2"
  # off pace again: the steward takes its own item down
  _pace_set 20 172800
  _steward_usage_pace >/dev/null 2>&1
  assert_eq "$(_inbox_open_fp alpha usage-pace steward root)" ""
  assert_eq "$(jq -s --arg i "$id" '[.[] | select(.kind == "resolution" and .ref == $i)] | length' "$f")" "1"
  rm -rf "$T"
}

test_steward_says_nothing_about_usage_with_headroom() {
  _pace_fixture 20 172800
  _steward_usage_pace >/dev/null 2>&1
  assert_eq "$(cmd_inbox read --for root --workspace alpha --all)" ""
  rm -rf "$T"
}

# A RESET IN THE PAST IS NOT A FORECAST. The read is the cached list, and
# nothing refreshes a cache file between `cel quota` runs, so a reading can
# outlive its reset. Once the reset passes, that reading describes a window
# that is over: it is not at risk, the open item comes down, and the past
# reset is never quoted.
test_quota_at_risk_ignores_a_window_whose_reset_has_passed() {
  _pace_fixture 97 -3600
  assert_eq "$(subscription_list | quota_at_risk | jq 'length')" "0"
  rm -rf "$T"
}

test_steward_clears_the_pace_item_once_the_reset_passes_and_never_cites_it() {
  _pace_fixture 97 600
  _STEWARD_WINDOW=0 _steward_usage_pace >/dev/null 2>&1
  local f="$CEL_INBOX_DIR/alpha.jsonl" id past i
  id="$(_inbox_open_fp alpha usage-pace steward root)"
  [ -n "$id" ] || { echo "no open usage-pace item"; return 1; }
  # the reset goes by; the cached reading still says 97%
  _pace_set 97 -3600
  past="$(jq -r '.[0].windows[0].resets_at' "$T/subs.json")"
  for i in 1 2 3; do _STEWARD_WINDOW=0 _steward_usage_pace >/dev/null 2>&1; done
  assert_eq "$(_inbox_open_fp alpha usage-pace steward root)" ""
  assert_eq "$(jq -s --arg i "$id" '[.[] | select(.kind == "update" and .ref == $i)] | length' "$f")" "0"
  if grep -qF "$past" "$f"; then echo "cited a reset already past: $past"; return 1; fi
  rm -rf "$T"
}

# Ticks never overlap. A tick that finds one running exits at once,
# before it touches herdr, gc or anything else.
test_steward_tick_exits_when_another_holds_the_lock() {
  have flock || return 0
  local T; T="$(mktemp -d)"
  export CEL_STEWARD_LOCK="$T/tick.lock"
  herdr() { echo "herdr called" >> "$T/calls"; }
  have() { return 0; }
  bash -c 'exec -a "cel steward" sleep 3' &
  printf '%s\n' "$!" > "$CEL_STEWARD_LOCK"
  sleep 0.3
  local out; out="$(cmd_steward --no-gc 2>&1)"; local rc=$?
  assert_eq "$rc" "0"
  assert_contains "$out" "already running"
  [ ! -e "$T/calls" ] || { echo "a locked-out tick still ran"; return 1; }
  wait
  # and a dead holder's claim is stale, not a wedge
  _steward_tick_claim || { echo "stale claim blocked a tick"; return 1; }
  assert_eq "$(cat "$CEL_STEWARD_LOCK")" "$$"
  rm -rf "$T"
}

# The pidfile is read and written under the flock; a claimant that cannot take
# the flock has not synchronised with whoever holds it, so it must not claim -
# whatever the pidfile says.
test_regression_steward_tick_does_not_claim_without_the_flock() {
  have flock || return 0
  local T holder i rc=0; T="$(mktemp -d)"
  export CEL_STEWARD_LOCK="$T/tick.lock"
  : > "$CEL_STEWARD_LOCK"
  ( exec 9>>"$CEL_STEWARD_LOCK"; flock 9; exec sleep 30 ) &
  holder=$!
  for i in $(seq 1 50); do flock -n "$CEL_STEWARD_LOCK" -c true 2>/dev/null || break; sleep 0.1; done
  local out; out="$(_steward_tick_claim 2>&1)" || rc=$?
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 0 ] || { echo "claimed a tick without the flock: $out"; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$CEL_STEWARD_LOCK")" "" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# ---- the retired delegation ledger is never read ----------------------------
# Fan-out was retired on 2026-11-08, so a whole tick - every sweep cmd_steward
# runs, and the detached fleet refill it starts - must leave a workspace's old
# `.cel/delegations.json` alone, however big it is. The tick runs in its own
# bash against a fixture box: stub herdr, gh, omp, tailscale, systemd, curl and
# node, a git that cannot reach the network, and the box web servers (dash,
# pages) not started.
_ledger_tick() { # [tracer argv...] - one real `cmd_steward --no-gc` tick, refill included
  local rc=0 i pid=""
  : > "$CEL_FLEET_REFILL_LOG"; rm -f "$CEL_CACHE/fleet.json"
  timeout 60 "$@" bash -c '
    source "$CEL_ROOT/lib/common.sh"; source "$CEL_ROOT/lib/steward.sh"
    cmd_dash() { :; }; cmd_pages() { :; }
    cmd_steward --no-gc' || rc=$?
  # fleet_cache_warm hands the rebuild to a detached refill; it is part of the
  # tick, so it has finished, and written its cache, before anything is judged.
  for i in $(seq 1 120); do pid="$(head -n1 "$CEL_FLEET_REFILL_LOG" 2>/dev/null)"; [ -z "$pid" ] || break; sleep 0.5; done
  [ -n "$pid" ] || { echo "the tick started no fleet refill"; return 1; }
  for i in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  ! kill -0 "$pid" 2>/dev/null || { echo "the fleet refill $pid did not finish within 60s"; return 1; }
  [ -s "$CEL_CACHE/fleet.json" ] || { echo "the fleet refill wrote no cache"; return 1; }
  return "$rc"
}

# Who touched it: each offending pid, then the programs it descends from.
_ledger_culprits() { # <strace -f output>
  awk '
    / = [0-9]+$/ && (/(clone3?|v?fork)\(/ || /<\.\.\. (clone3?|v?fork) resumed>/) { parent[$NF] = $1 }
    / execve\(/ && !/ = -1 / { a = $0; sub(/^[0-9]+ execve\(/, "", a); cmd[$1] = substr(a, 1, 220) }
    /delegations\.json/ && !/ execve\(/ { bad[$1] = 1 }
    END { for (p in bad) { printf "  pid %s", p; q = p
            while (q != "") { if (q in cmd) printf "\n    <- %s", cmd[q]; q = (q in parent) ? parent[q] : "" }
            printf "\n" } }' "$1"
}

test_regression_steward_tick_never_reads_the_retired_delegation_ledger() {
  local T real_git; T="$(mktemp -d)"; real_git="$(command -v git)"
  export HOME="$T/home" CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox"
  export CEL_STEWARD_STATE="$T/state" CEL_STEWARD_LOCK="$T/tick.lock"
  export CEL_PROC="$T/proc" CEL_PROC_DIR="$T/proc" CEL_PROC_ROOT="$T/proc" CEL_SERVE_PROC_ROOT="$T/proc"
  export CEL_SERVE_PROC_DATA='' CEL_SERVE_ADOPT_DATA='[]' CEL_SERVE_STATE="$T/serve"
  export CEL_SERVE_SYSTEMCTL="$T/bin/systemctl" CEL_SYSTEMD_DIR="$T/systemd" CEL_SERVICES_D="$T/services.d"
  export CEL_WORKTREE_ROOT="$T/wt" CEL_SUITE_LOCK="$T/suite.lock" CEL_UPDATE_DIR="$T/update"
  export CEL_CONFIG_FILE="$T/config.yaml" CEL_MANIFEST="$T/agents.yaml" CEL_CACHE="$T/cache"
  export CEL_STEWARD_HERDR="$T/bin/herdr" CEL_SERVICES_HERDR="$T/bin/herdr"
  # The fleet cache ON, as on a box, so the tick's warm-up really refills.
  export CEL_FLEET_CACHE_SECS=30 CEL_FLEET_REFILL_LOG="$T/refill.log"
  mkdir -p "$HOME" "$T/bin" "$T/proc" "$T/inbox" "$T/cache" "$T/alpha/.cel"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\nrepos: [{name: widget, prefix: WG}]\nproducts:\n  - {name: bundle, repos: [widget]}\n' \
    > "$T/alpha/workspace.yaml"
  # A big ledger whose every row is long over: what a retired box keeps.
  local led="$T/alpha/.cel/delegations.json"
  jq -n '[range(2000) | {id: "WG-\(.)-x", ticket: "WG-\(.)", repo: "widget", branch: "WG-\(.)-x",
    pane: "w:p\(.)", worktree: "/nonexistent/wg-\(.)", state: (["landed", "released", "abandoned"][. % 3])}]' > "$T/ledger.json"
  assert_eq "$(jq length "$T/ledger.json")" "2000" || { rm -rf "$T"; return 1; }
  printf '#!/usr/bin/env bash\ncase "$1 $2" in "agent list") echo %s ;; *) echo "{}" ;; esac\n' \
    "'{\"result\":{\"agents\":[]}}'" > "$T/bin/herdr"
  printf '#!/usr/bin/env bash\necho "[]"\n' > "$T/bin/gh"
  local stub; for stub in omp tailscale systemctl systemd-run curl node; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/$stub"
  done
  printf '#!/usr/bin/env bash\ncase " $* " in *" fetch "*|*" ls-remote "*) exit 1 ;; esac\nexec %q "$@"\n' \
    "$real_git" > "$T/bin/git"
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"
  local out rc sum

  # A: the ledger is a DIRECTORY holding the big ledger as a sentinel. A
  # reader guarded by `[ -f ]` sees nothing; any open or jq of it errors.
  mkdir "$led"; cp "$T/ledger.json" "$led/sentinel"; sum="$(cksum < "$led/sentinel")"
  rc=0; out="$(_ledger_tick 2>&1)" || rc=$?
  assert_eq "$rc" "0" || { echo "$out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "tick complete" || { rm -rf "$T"; return 1; }
  if printf '%s' "$out" | grep -q delegations; then echo "the tick spoke of the ledger: $out"; rm -rf "$T"; return 1; fi
  [ "$(ls -A "$led")" = sentinel ] && [ "$(cksum < "$led/sentinel")" = "$sum" ] \
    || { echo "the tick changed the ledger directory"; rm -rf "$T"; return 1; }
  rm -rf "$led"

  # B: a regular-file ledger, every access to it watched - by strace, else
  # inotifywait, else its access time (relatime moves an atime older than the
  # mtime on any read).
  cp "$T/ledger.json" "$led"
  local method=atime iw="" i
  if command -v strace >/dev/null 2>&1 && strace -f -qq -e trace=%file -o /dev/null true >/dev/null 2>&1; then
    method=strace
  elif command -v inotifywait >/dev/null 2>&1; then
    method=inotifywait
  fi
  echo "ledger-read check: $method"
  case "$method" in
    strace)
      rc=0; out="$(_ledger_tick strace -f -qq -s 200 -e trace=%file,%process -o "$T/strace" 2>&1)" || rc=$? ;;
    inotifywait)
      inotifywait -m -e access,open --format '%e %w%f' "$led" > "$T/inotify" 2> "$T/inotify.err" & iw=$!
      for i in $(seq 1 50); do grep -q 'Watches established' "$T/inotify.err" && break; sleep 0.1; done
      grep -q 'Watches established' "$T/inotify.err" || { echo "inotifywait never watched the ledger"; rm -rf "$T"; return 1; }
      rc=0; out="$(_ledger_tick 2>&1)" || rc=$?
      kill "$iw" 2>/dev/null || true; wait "$iw" 2>/dev/null || true ;;
    atime)
      printf 'x\n' > "$T/alpha/.cel/probe"; touch -a -d @0 "$T/alpha/.cel/probe"; cat "$T/alpha/.cel/probe" >/dev/null
      [ "$(stat -c %X "$T/alpha/.cel/probe")" != 0 ] \
        || { echo "no strace, no inotifywait, and this filesystem keeps no access times: nothing can see a read"; rm -rf "$T"; return 1; }
      touch -a -d @0 "$led"
      assert_eq "$(stat -c %X "$led")" "0" || { rm -rf "$T"; return 1; }
      rc=0; out="$(_ledger_tick 2>&1)" || rc=$? ;;
  esac
  assert_eq "$rc" "0" || { echo "$out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "tick complete" || { rm -rf "$T"; return 1; }
  if printf '%s' "$out" | grep -q delegations; then echo "the tick spoke of the ledger: $out"; rm -rf "$T"; return 1; fi
  case "$method" in
    strace)
      # the trace saw the tick walk this very workspace...
      grep -qF "$T/alpha/workspace.yaml" "$T/strace" || { echo "the trace never saw the workspace"; rm -rf "$T"; return 1; }
      # ...and never once touch the ledger in it
      if grep -q 'delegations\.json' "$T/strace"; then
        echo "the tick touched the ledger:"; grep 'delegations\.json' "$T/strace" | grep -v ' execve(' | head -n 5
        _ledger_culprits "$T/strace"; rm -rf "$T"; return 1
      fi ;;
    inotifywait)
      [ ! -s "$T/inotify" ] || { echo "the tick touched the ledger:"; head -n 5 "$T/inotify"; rm -rf "$T"; return 1; } ;;
    atime)
      assert_eq "$(stat -c %X "$led")" "0" || { echo "the tick read the ledger (its atime moved)"; rm -rf "$T"; return 1; } ;;
  esac
  rm -rf "$T"
}

# ---- a PR waiting on the owner is not a worker finding -----------------------
# A red PR linked to an open `cel decide` question is blocked on the owner, not
# on a worker, so it gets no nudge until the decision closes.
_decision_pr_fixture() { # <decision-json-or-empty>
  _orch_fixture
  mkdir -p "$T/bin"
  : > "$T/prompts"
  cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' '[{"number":7,"headRefName":"WG-1-x","headRefOid":"h7","reviewDecision":"","isDraft":false,"statusCheckRollup":[{"conclusion":"FAILURE"}],"createdAt":"2020-01-01T00:00:00Z","reviews":[]},
             {"number":9,"headRefName":"WG-3-z","headRefOid":"h9","reviewDecision":"APPROVED","isDraft":false,"statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","reviews":[{"state":"APPROVED","submittedAt":"2020-01-02T00:00:00Z","commit":{"oid":"h9"}}]},
             {"number":8,"headRefName":"WG-2-y","headRefOid":"h8","reviewDecision":"","isDraft":false,"statusCheckRollup":[{"conclusion":"FAILURE"}],"createdAt":"2020-01-01T00:00:00Z","reviews":[]}]'
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
  source "$CEL_ROOT/lib/inbox.sh"
  printf '%s\n' '{"id":"d1","ts":"2020-01-01T00:00:00+00:00","to":"owner","from":"bundle-orch","asker":"bundle-orch","kind":"decision","title":"top up the review bot account","options":[],"context":"x","blocks":"","prs":[{"ref":"widget#7"},{"ref":"widget#9"}]}' \
    > "$(_inbox_file alpha)"
}

test_red_pr_with_open_linked_decision_gets_no_nudge() {
  _decision_pr_fixture
  PATH="$T/bin:$PATH" _steward_review_sweep "$LIVE_ROSTER" >/dev/null
  local mail; mail="$(cmd_inbox read --for bundle-orch --workspace alpha --all 2>/dev/null)"
  assert_eq "$(printf '%s\n' "$mail" | grep -c 'PR #7 ' || true)" "0"
  # an unlinked red PR is still a finding
  assert_contains "$mail" "PR #8 on widget has FAILING checks"
  # an approval still needs actioning - the decision does not hide it
  assert_contains "$mail" "PR #9 on widget is APPROVED"
  rm -rf "$T"
}

test_red_pr_is_nudged_again_once_its_decision_is_withdrawn() {
  _decision_pr_fixture
  printf '%s\n' '{"id":"r1","ts":"2020-01-02T00:00:00+00:00","kind":"resolution","ref":"d1","by":"bundle-orch","to":"owner","message":"withdrawn"}' \
    >> "$(_inbox_file alpha)"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LIVE_ROSTER" >/dev/null
  assert_contains "$(cmd_inbox read --for bundle-orch --workspace alpha --all 2>/dev/null)" "PR #7 on widget has FAILING checks"
  rm -rf "$T"
}

# Only the explicit --pr link counts, and only in the PR's own workspace: free
# text naming a PR, or a link from another workspace, never silences it.
test_red_pr_is_nudged_when_only_prose_or_another_workspace_names_it() {
  _decision_pr_fixture
  printf '%s\n' '{"id":"d1","ts":"2020-01-01T00:00:00+00:00","to":"owner","from":"bundle-orch","asker":"bundle-orch","kind":"decision","title":"widget: see gadget#7","options":[],"context":"widget #7 of the other board","blocks":"widget#7"}' \
    > "$(_inbox_file alpha)"
  printf '%s\n' '{"id":"d2","ts":"2020-01-01T00:00:00+00:00","to":"owner","from":"x","asker":"x","kind":"decision","title":"t","options":[],"context":"x","prs":[{"ref":"widget#7"}]}' \
    > "$(_inbox_file beta)"
  PATH="$T/bin:$PATH" _steward_review_sweep "$LIVE_ROSTER" >/dev/null
  assert_contains "$(cmd_inbox read --for bundle-orch --workspace alpha --all 2>/dev/null)" "PR #7 on widget has FAILING checks"
  rm -rf "$T"
}

test_steward_reports_unledgered_servers_to_product_once_a_day() {
  local T; T="$(mktemp -d)"
  export CEL_SERVE_STATE="$T/state" CEL_SERVE_SYSTEMCTL="$T/systemctl" CEL_SERVE_PROC_DATA=''
  mkdir -p "$CEL_SERVE_STATE" "$T/alpha"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CEL_SERVE_SYSTEMCTL"
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  CEL_SERVE_ADOPT_DATA='[{"pid":1234,"memory_mb":240,"age_seconds":4000,"worktree":"/tmp/demo","managed":false}]'
  export CEL_SERVE_ADOPT_DATA
  registry_names() { printf 'alpha\n'; }
  registry_path() { printf '%s/alpha' "$T"; }
  ws_product_names() { printf 'widget\n'; }
  cmd_inbox() { printf '%s\n' "$*" >> "$T/sent"; }
  date() { [ "$*" = '-u +%F' ] && printf '2026-10-15\n' || command date "$@"; }
  _serve_unledgered_report
  _serve_unledgered_report
  assert_eq "$(wc -l < "$T/sent" | tr -d ' ')" "1"
  assert_contains "$(cat "$T/sent")" "widget-orch"
  assert_contains "$(cat "$T/sent")" "240MB"
  assert_contains "$(cat "$T/sent")" "nothing unledgered was stopped"
  unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_SERVE_PROC_DATA CEL_SERVE_ADOPT_DATA
  rm -rf "$T"
}

# A delivery that fails is not stamped: that product is tried again on the
# next tick, while the one that did get it is not mailed twice.
test_steward_unledgered_report_retries_only_the_product_it_failed_to_reach() {
  local T; T="$(mktemp -d)"
  export CEL_SERVE_STATE="$T/state" CEL_SERVE_SYSTEMCTL="$T/systemctl" CEL_SERVE_PROC_DATA=''
  mkdir -p "$CEL_SERVE_STATE" "$T/alpha"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CEL_SERVE_SYSTEMCTL"
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  CEL_SERVE_ADOPT_DATA='[{"pid":1234,"memory_mb":240,"age_seconds":4000,"worktree":"/tmp/demo","managed":false}]'
  export CEL_SERVE_ADOPT_DATA
  registry_names() { printf 'alpha\n'; }
  registry_path() { printf '%s/alpha' "$T"; }
  ws_product_names() { printf 'widget\ngadget\n'; }
  cmd_inbox() { printf '%s\n' "$2" >> "$T/sent"; [ "$2" != gadget-orch ] || [ -e "$T/inbox-up" ]; }
  date() { [ "$*" = '-u +%F' ] && printf '2026-10-15\n' || command date "$@"; }
  _serve_unledgered_report >/dev/null 2>&1
  _serve_unledgered_report >/dev/null 2>&1
  assert_eq "$(grep -cx widget-orch "$T/sent")" 1 || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -cx gadget-orch "$T/sent")" 2 || { rm -rf "$T"; return 1; }
  # once it is delivered, it is stamped like any other
  touch "$T/inbox-up"
  _serve_unledgered_report >/dev/null 2>&1
  _serve_unledgered_report >/dev/null 2>&1
  assert_eq "$(grep -cx gadget-orch "$T/sent")" 3
  assert_eq "$(grep -cx widget-orch "$T/sent")" 1
  unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_SERVE_PROC_DATA CEL_SERVE_ADOPT_DATA
  rm -rf "$T"
}

# --- a solo PR sent back: the recorded `changes` verdict -------------------------
# `cel solo review ... changes` lands in .cel/solo-reviews.json and never on the
# forge, so only this sweep can see it. The heads are the forge layer's (the gh
# stub is forge.sh's `gh`), never a branch.
SC_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SC_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
_solo_changes_fixture() {
  source "$CEL_ROOT/lib/solo.sh"
  T="$(mktemp -d)"
  cp "$CEL_ROOT/tests/fixtures/ws-products/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget" "$T/repos/gadget" "$T/repos/lone" "$T/.cel"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox"; registry_add demo "$T" ""
  mkdir -p "$CEL_INBOX_DIR"
  CEL_STEWARD_STATE="$T/state" _STEWARD_STATE="$T/state"
  : > "$T/mail"; : > "$T/gh.log"
  cmd_inbox() { printf '%s\n' "$*" >> "$T/mail"; }
  solo_ready_prs() { :; }   # the approved half: tests/solo-visibility.test.sh
  _sc_head "$SC_A"
  cat > "$T/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$1 \$2" in
  "pr list") case "\$*" in *someone/widget*) cat "$T/list.json";; *) echo '[]';; esac;;
  "pr view") if [ -f "$T/reviews.json" ]; then cat "$T/reviews.json"; else echo '{"reviewDecision":"","reviews":[]}'; fi;;
  *) echo '{}';;
esac
EOF
  chmod +x "$T/gh"; export GH="$T/gh"
}
_sc_head() { # <head> [label...]: widget#7 is open at <head>, with those labels
  local h="$1"; shift
  jq -nc --arg h "$h" '[{number: 7, state: "OPEN", headRefOid: $h, headRefName: "AH-1-thing", baseRefName: "main",
    author: {login: "me"}, isDraft: false, mergeable: "MERGEABLE", labels: ($ARGS.positional | map({name: .}))}]' --args "$@" > "$T/list.json"
}
_sc_gh_calls() { grep -c . "$T/gh.log" || true; }
_sc_verdict() { # <verdict> <head>
  jq -nc --arg v "$1" --arg h "$2" '{"widget#7": {verdict: $v, by: "widget-pr-7-review", note: "the empty cart crashes", head: $h, at: "2026-11-08T10:00:00Z"}}' \
    > "$T/.cel/solo-reviews.json"
}

test_steward_nudges_a_solo_changes_verdict_once_per_head_and_rearms_on_a_new_head() {
  _solo_changes_fixture
  _sc_verdict changes "$SC_A"
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 1
  assert_contains "$(cat "$T/mail")" "send bundle-orch"
  assert_contains "$(cat "$T/mail")" "widget#7 has a recorded \`changes\` verdict from widget-pr-7-review at its current head ${SC_A:0:12}"
  assert_contains "$(cat "$T/mail")" "the empty cart crashes"
  # the heads came through the forge layer: its list of this account's open PRs
  assert_contains "$(cat "$T/gh.log")" "pr list --repo someone/widget --state open --author @me"
  # once per head, however long it sits (five days) - and a head already
  # nudged costs no forge call at all, list or reviews
  sed -i "s/^\(solo-changes-[^ ]*\) [0-9]*\$/\1 $(( $(date +%s) - 432000 ))/" "$T/state"
  : > "$T/gh.log"
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 1
  assert_eq "$(_sc_gh_calls)" 0
  # a push: the verdict no longer covers the head - nothing until it is re-reviewed
  _sc_head "$SC_B"
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 1
  # changes again at the new head: a new fact, said once
  _sc_verdict changes "$SC_B"
  _steward_solo_sweep >/dev/null
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 2
  assert_contains "$(sed -n 2p "$T/mail")" "${SC_B:0:12}"
  # approved at the head: nothing more to say about changes
  _sc_verdict approved "$SC_B"
  rm -f "$T/state"
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 2
  rm -rf "$T"
}

# A changes request GitHub already carries at that head is mailed by the review
# sweep's reviewDecision nudge; the recorded verdict is the same finding and is
# not said a second time - nor asked about again that day. A request on another
# head does not count.
test_steward_solo_changes_verdict_is_not_doubled_with_the_github_change_request() {
  _solo_changes_fixture
  _sc_verdict changes "$SC_A"
  jq -nc --arg h "$SC_A" '{reviewDecision: "CHANGES_REQUESTED", reviews: [{author: {login: "rev"}, state: "CHANGES_REQUESTED",
    commit: {oid: $h}, submittedAt: "2026-11-08T09:00:00Z"}]}' > "$T/reviews.json"
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail" || true)" 0
  assert_contains "$(cat "$T/gh.log")" "pr view 7 --repo someone/widget --json reviewDecision,reviews"
  # the next tick asks the forge nothing: no list, no reviews
  : > "$T/gh.log"
  _steward_solo_sweep >/dev/null
  assert_eq "$(_sc_gh_calls)" 0
  rm -f "$T/state"
  jq -nc --arg h "$SC_B" '{reviewDecision: "CHANGES_REQUESTED", reviews: [{author: {login: "rev"}, state: "CHANGES_REQUESTED",
    commit: {oid: $h}, submittedAt: "2026-11-08T09:00:00Z"}]}' > "$T/reviews.json"
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 1
  rm -rf "$T"
}

# Silenced exactly as the review sweep is: an open owner card on the PR
# (decided before any forge call), or a `hold`/`superseded` label. A PR set
# aside, or one no longer open, is looked at again after a day, not every tick.
test_steward_solo_changes_verdict_is_silenced_by_an_owner_card_or_a_leave_it_label() {
  _solo_changes_fixture
  _sc_verdict changes "$SC_A"
  printf '%s\n' '{"id":"d1","ts":"2026-11-08T00:00:00+00:00","to":"owner","from":"bundle-orch","asker":"bundle-orch","kind":"decision","title":"pay the review bot","options":[],"context":"x","blocks":"","prs":[{"ref":"widget#7"}]}' \
    > "$CEL_INBOX_DIR/demo.jsonl"
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail" || true)" 0
  assert_eq "$(_sc_gh_calls)" 0
  # the card closes, but the PR is labelled Hold: still nothing, and no reviews call
  : > "$CEL_INBOX_DIR/demo.jsonl"
  _sc_head "$SC_A" Hold
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail" || true)" 0
  assert_eq "$(grep -c 'pr view' "$T/gh.log" || true)" 0
  : > "$T/gh.log"
  _sc_head "$SC_A"
  _steward_solo_sweep >/dev/null
  assert_eq "$(_sc_gh_calls)" 0
  assert_eq "$(grep -c . "$T/mail" || true)" 0
  # a day on, the label gone: the verdict is news again, said once
  sed -i "s/^\(solo-changes-idle-[^ ]*\) [0-9]*\$/\1 $(( $(date +%s) - 90000 ))/" "$T/state"
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c . "$T/mail")" 1
  # a lingering verdict for a PR that is no longer open: one list, then quiet
  jq -nc --arg h "$SC_B" '{"widget#5": {verdict: "changes", by: "r", head: $h}}' > "$T/.cel/solo-reviews.json"
  : > "$T/gh.log"
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c 'pr list' "$T/gh.log")" 1
  _steward_solo_sweep >/dev/null
  assert_eq "$(grep -c 'pr list' "$T/gh.log")" 1
  assert_eq "$(grep -c . "$T/mail")" 1
  rm -rf "$T"
}

# --- feature teams ---------------------------------------------------------------
# Read from the team's own files only (T2's .cel/teams/<feature>/ format). The
# lead hears about a reservation nobody confirmed and a verdict a newer
# candidate outdated - once each - and nothing is ever retired.
TM_H1=1111111111111111111111111111111111111111
TM_H2=2222222222222222222222222222222222222222
TM_H3=3333333333333333333333333333333333333333
_team_fixture() {
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  mkdir -p "$T/alpha/.cel/teams" "$CEL_INBOX_DIR"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\nrepos: [{name: widget}]\n' > "$T/alpha/workspace.yaml"
  CEL_STEWARD_STATE="$T/state"; _STEWARD_STATE="$T/state"
}
_tm_iso() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
_tm_dir() { printf '%s/alpha/.cel/teams/%s' "$T" "$1"; }
_tm_member() { # <alias> <role> <state> <created-secs-ago>
  jq -nc --arg a "$1" --arg r "$2" --arg s "$3" --arg c "$(_tm_iso "$4")" \
    '{alias: $a, role: $r, focus: null, repo: "widget", branch: null, worktree: null, base_sha: null, owns: [], state: $s, model: null, created: $c}'
}
_tm_team() { # <feature> <state> <member-json>...
  local f="$1" st="$2"; shift 2
  mkdir -p "$(_tm_dir "$f")"
  printf '%s\n' "$@" | jq -s --arg f "$f" --arg s "$st" --arg c "$(_tm_iso 7200)" \
    '{feature: $f, product: "bundle", workspace: "alpha", lead: "bundle-orch", repos: ["widget"], created: $c, state: $s, members: .}' \
    > "$(_tm_dir "$f")/team.json"
}
_tm_event() { # <feature> <type> <data-json> <secs-ago>
  jq -nc --arg ts "$(_tm_iso "$4")" --arg t "$2" --argjson d "$3" '{ts: $ts, by: "bundle-orch", type: $t, data: $d}' \
    >> "$(_tm_dir "$1")/events.jsonl"
}
_tm_lead_mail() { jq -r 'select(.to == "bundle-orch" and .from == "steward") | .message' "$CEL_INBOX_DIR/alpha.jsonl" 2>/dev/null || true; }

test_steward_team_nudges_the_lead_once_about_a_member_reserved_over_ten_minutes() {
  _team_fixture
  _tm_team checkout open \
    "$(_tm_member bundle-checkout-builder builder reserved 900)" \
    "$(_tm_member bundle-checkout-qa qa reserved 1500)" \
    "$(_tm_member bundle-checkout-design design ready 3600)"
  _tm_event checkout member.reserved '{"alias":"bundle-checkout-builder","role":"builder"}' 900
  # reserved 25 minutes ago, but reserved AGAIN two minutes ago: that is the reservation
  _tm_event checkout member.reserved '{"alias":"bundle-checkout-qa","role":"qa"}' 1500
  _tm_event checkout member.reserved '{"alias":"bundle-checkout-qa","role":"qa"}' 120
  # a closed team is history: its stale reservation says nothing
  _tm_team shipped closed "$(_tm_member bundle-shipped-builder builder reserved 9000)"
  local before; before="$(cat "$(_tm_dir checkout)/team.json")"
  _steward_team_sweep >/dev/null
  _steward_team_sweep >/dev/null
  local mail; mail="$(_tm_lead_mail)"
  assert_eq "$(printf '%s\n' "$mail" | grep -c 'reserved' || true)" 1
  assert_contains "$mail" "team checkout: member bundle-checkout-builder (builder) has been reserved for 15m"
  assert_contains "$mail" "cel team retire checkout bundle-checkout-builder"
  case "$mail" in *bundle-checkout-qa*|*bundle-shipped*|*design*) echo "nudged about a member that is fine: $mail"; return 1;; esac
  # it retires nothing: the team's files are exactly as they were
  assert_eq "$(cat "$(_tm_dir checkout)/team.json")" "$before"
  # a fresh reservation of the same member is a new fact once it, too, is overdue
  _tm_event checkout member.reserved '{"alias":"bundle-checkout-builder","role":"builder"}' 660
  _steward_team_sweep >/dev/null
  assert_eq "$(_tm_lead_mail | grep -c 'bundle-checkout-builder (builder) has been reserved for 11m' || true)" 1
  rm -rf "$T"
}

test_steward_team_nudges_the_lead_once_per_candidate_about_a_stale_verdict() {
  _team_fixture
  _tm_team checkout open "$(_tm_member bundle-checkout-qa qa working 3600)"
  _tm_event checkout candidate.updated "{\"repo\":\"widget\",\"head\":\"$TM_H1\"}" 3000
  _tm_event checkout candidate.updated "{\"repo\":\"widget\",\"head\":\"$TM_H2\"}" 100
  # qa judged H1 only; the reviewer judged H1, then H2 (its latest covers the candidate)
  jq -n --arg h1 "$TM_H1" --arg h2 "$TM_H2" --arg a "$(_tm_iso 2000)" --arg b "$(_tm_iso 50)" '[
    {role: "qa", focus: "browser", repo: "widget", head: $h1, verdict: "pass", by: "bundle-checkout-qa", at: $a, evidence: []},
    {role: "reviewer", focus: "security", repo: "widget", head: $h1, verdict: "changes", by: "widget-pr-7-review", at: $a, evidence: []},
    {role: "reviewer", focus: "security", repo: "widget", head: $h2, verdict: "pass", by: "widget-pr-7-review", at: $b, evidence: []},
    {role: "qa", focus: "browser", repo: "gadget", head: $h1, verdict: "pass", by: "bundle-checkout-qa", at: $a, evidence: []}]' \
    > "$(_tm_dir checkout)/verdicts.json"
  _steward_team_sweep >/dev/null
  _steward_team_sweep >/dev/null
  local mail; mail="$(_tm_lead_mail)"
  assert_eq "$(printf '%s\n' "$mail" | grep -c 'candidate is now' || true)" 1
  assert_contains "$mail" "team checkout: widget's candidate is now ${TM_H2:0:12}, but these verdicts are for older heads: qa/browser pass at ${TM_H1:0:12} - "
  case "$mail" in *reviewer/security*|*gadget*) echo "a verdict at the candidate, or a repo with no candidate, was called stale: $mail"; return 1;; esac
  # the next candidate re-arms it, and now both verdicts are behind
  _tm_event checkout candidate.updated "{\"repo\":\"widget\",\"head\":\"$TM_H3\"}" 10
  _steward_team_sweep >/dev/null
  mail="$(_tm_lead_mail)"
  assert_eq "$(printf '%s\n' "$mail" | grep -c 'candidate is now' || true)" 2
  assert_contains "$mail" "candidate is now ${TM_H3:0:12}, but these verdicts are for older heads: qa/browser pass at ${TM_H1:0:12}, reviewer/security pass at ${TM_H2:0:12}"
  rm -rf "$T"
}

# A team file the steward cannot read is reported to root - not skipped as if
# the team were healthy - once per change, and taken down when it reads again.
# One broken team does not stop the sweep over the others.
test_steward_team_reports_a_malformed_team_json_and_clears_it_when_fixed() {
  _team_fixture
  mkdir -p "$(_tm_dir broken)"; printf '{"feature": "broken", "members": [' > "$(_tm_dir broken)/team.json"
  _tm_team checkout open "$(_tm_member bundle-checkout-builder builder reserved 900)"
  local out; out="$(_steward_team_sweep)"
  assert_contains "$out" "team alpha/broken: team.json does not parse"
  _steward_team_sweep >/dev/null
  local open; open="$(cmd_inbox open --for root --workspace alpha)"
  assert_eq "$(printf '%s\n' "$open" | grep -c 'team broken' || true)" 1
  assert_contains "$open" "team broken in alpha: team.json does not parse"
  assert_contains "$(_tm_lead_mail)" "bundle-checkout-builder (builder) has been reserved"
  # the right shape, wrong content is still not a team the steward can read
  printf '{"feature":"broken","product":"bundle","members":[{"role":"builder","state":"reserved"}]}\n' > "$(_tm_dir broken)/team.json"
  _steward_team_sweep >/dev/null
  assert_contains "$(cmd_inbox read --for root --workspace alpha --all)" "a team.json member has no alias or state"
  _tm_team broken open "$(_tm_member bundle-broken-qa qa ready 60)"
  printf 'not json' > "$(_tm_dir broken)/verdicts.json"
  _steward_team_sweep >/dev/null
  assert_contains "$(cmd_inbox read --for root --workspace alpha --all)" "verdicts.json does not parse"
  rm -f "$(_tm_dir broken)/verdicts.json"
  _steward_team_sweep >/dev/null
  assert_eq "$(cmd_inbox open --for root --workspace alpha | grep -c 'team broken' || true)" 0
  assert_contains "$(cmd_inbox read --for root --workspace alpha --all)" "cleared: team broken in alpha reads cleanly again"
  rm -rf "$T"
}

# A team raised as unreadable and then deleted - its directory, or the whole
# teams folder - takes its item down with it; nothing is left open for a team
# that no longer exists.
test_steward_team_clears_the_item_of_a_bad_team_that_was_removed() {
  _team_fixture
  mkdir -p "$(_tm_dir broken)" "$(_tm_dir torn)"
  printf 'not json' > "$(_tm_dir broken)/team.json"
  printf 'not json' > "$(_tm_dir torn)/team.json"
  _steward_team_sweep >/dev/null
  assert_eq "$(cmd_inbox open --for root --workspace alpha | grep -c 'team broken\|team torn' || true)" 2
  rm -rf "$(_tm_dir broken)"
  _steward_team_sweep >/dev/null
  assert_eq "$(cmd_inbox open --for root --workspace alpha | grep -c 'team broken' || true)" 0
  assert_eq "$(cmd_inbox open --for root --workspace alpha | grep -c 'team torn' || true)" 1
  assert_contains "$(cmd_inbox read --for root --workspace alpha --all)" "cleared: team broken in alpha is gone (no team.json any more)"
  rm -rf "$T/alpha/.cel/teams"
  _steward_team_sweep >/dev/null
  assert_eq "$(cmd_inbox open --for root --workspace alpha | grep -c 'team torn' || true)" 0
  assert_eq "$(grep -c '^team-bad/' "$T/state" || true)" 0
  rm -rf "$T"
}
