# shellcheck shell=bash
# `cel fleet` - the whole box in one read. Every assertion here is a number an
# operator would otherwise have gathered by visiting each workspace in turn,
# so the fixture is a miniature box: two workspaces, a ledger, a worktree, a
# mailbox and a herdr stub.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/fleet.sh"

# The pane text from the 2026-09-14 incident, copied (not sourced) from
# tests/stall.test.sh on purpose: a shared helper between two suites makes a
# change in one silently move the other's evidence.
_fleet_death() {
  printf '%s\n' \
    '  Running tests...' \
    '✘ server_error: Upstream error from Together: Stream error: h2 protocol error: error reading a body from connection' \
    '↻ F5 to Retry'
}

_fleet_ws_yaml() { # <name> <repo>...
  local name="$1"
  shift
  cat <<EOF
name: $name
kind: hustle
org: someone
tickets: { system: none, adhoc: "AH-<yymmdd>" }
policy: { merge: humans-only, pr: required, workers: 4, reviewer: null }
runtime: { root: claude, orchestrator: claude, worker: omp }
tools: []
repos:
EOF
  local r
  for r in "$@"; do
    printf -- '  - name: %s\n    url: git@github.com:someone/%s.git\n    prefix: WG\n    gate: bun test\n' "$r" "$r"
  done
}

_fleet_setup() {
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml"
  export CEL_INBOX_DIR="$T/inbox"
  mkdir -p "$T/inbox" "$T/alpha/.cel" "$T/beta/.cel" "$T/bin"

  cat >"$CEL_REGISTRY" <<EOF
workspaces:
  alpha: { path: $T/alpha, remote: null }
  beta: { path: $T/beta, remote: null }
EOF
  _fleet_ws_yaml alpha widget gadget >"$T/alpha/workspace.yaml"
  _fleet_ws_yaml beta gadget >"$T/beta/workspace.yaml"

  # The running worker's worktree: a real git repo, because unlanded work is
  # measured with git and a stub would prove nothing.
  WT="$T/wt-widget"
  mkdir -p "$WT"
  git -C "$WT" init -q -b main
  git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$WT" update-ref refs/remotes/origin/main HEAD
  git -C "$WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$WT" checkout -q -b widget-work
  git -C "$WT" update-ref refs/remotes/origin/widget-work HEAD

  cat >"$T/alpha/.cel/delegations.json" <<EOF
[{"id":"one","repo":"widget","branch":"widget-work","pane":"wA:p2","worktree":"$WT","state":"running","ticket":""},
 {"id":"two","repo":"widget","branch":"widget-old","pane":"wA:p3","worktree":"$T/gone","state":"collected","ticket":""}]
EOF
  printf '[]\n' >"$T/beta/.cel/delegations.json"

  # One unread message for root, in alpha only.
  printf '%s\n' '{"id":"1","ts":"2026-09-16T00:00:00+00:00","to":"root","from":"widget-orch","kind":"status","message":"hello","cwd":"/","pane":""}' \
    >"$T/inbox/alpha.jsonl"

  cat >"$T/bin/herdr" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_HERDR_FAIL:-}" ] && exit 1
# A roster that ANSWERS with a truncated document: herdr killed mid-write, or
# a pane manager that died between the opening brace and the rest of it.
[ -n "${STUB_HERDR_BAD:-}" ] && { printf '%s' '{"result":{"agents":[{"name":"widget-orch",'; exit 0; }
case "$1 $2" in
  "agent list")
    # CEL-44: a live agent with NO herdr name, in a cwd the caller names. The
    # fleet must not read it as an absence.
    extra=""
    [ -z "${STUB_UNNAMED_CWD:-}" ] \
      || extra=",{\"name\":null,\"agent_status\":\"idle\",\"pane_id\":\"wA:p7\",\"cwd\":\"$STUB_UNNAMED_CWD\"}"
    printf '{"result":{"agents":[%s%s]}}\n' '
      {"name":"widget-orch","agent_status":"idle","pane_id":"wA:p1","cwd":"/nowhere/widget"},
      {"name":"bundle-orch","agent_status":"idle","pane_id":"wA:p9","cwd":"/nowhere/bundle"},
      {"name":"widget-widget-work","agent_status":"idle","pane_id":"wA:p2","cwd":"/nowhere/wt"}' "$extra" ;;
  "pane read")  printf '%s\n' "${STUB_PANE_TEXT:-reading src and running the gate}" ;;
  *) printf '%s\n' '{}' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
  PATH="$T/bin:$PATH"
  # No live console on this fixture box: CEL-43 reads the CEL-32 marker out of
  # a process environment, and the real /proc would let whatever is running on
  # the developer's box decide the answer.
  export CEL_PROC_DIR="$T/proc"; mkdir -p "$CEL_PROC_DIR"
}

# MEMORY. The box has 24 GB and no view on this plane could say where it had
# gone: one pi worker is ~340 MB resident and a forgotten test server is
# invisible until something is killed. A fixture meminfo stands in for the box
# (a test may not arrange 5% available) and the tree walk is stubbed, because
# what `cel fleet` owns is the SHAPE - which directory belongs to which row -
# and not the arithmetic, which tests/memory.test.sh proves against a real
# process.
_fleet_stub_memory() {
  printf 'MemTotal:       25165824 kB\nMemAvailable:    7235174 kB\n' >"$T/meminfo"
  export CEL_MEMINFO="$T/meminfo"
  mem_tree_snapshot() { :; }
  mem_tree_rss_mb() {
    case "$1" in
      *wt-widget*) printf 370 ;;
      *repos/widget*|*products/bundle*) printf 120 ;;
      *) printf 0 ;;
    esac
  }
}
_fleet_teardown() { rm -rf "$T"; }

test_fleet_prints_a_block_per_workspace_and_a_line_per_repo() {
  _fleet_setup
  local out
  out="$(cmd_fleet)"
  assert_contains "$out" "alpha"
  assert_contains "$out" "beta"
  assert_contains "$out" "widget"
  assert_contains "$out" "gadget"
  # the orchestrator herdr knows about is LIVE; the one it does not is a dash
  assert_contains "$out" "$(printf 'widget')"
  case "$out" in *"widget"*"orch LIVE"*) ;; *)
    echo "widget was not LIVE: $out"
    _fleet_teardown
    return 1
    ;;
  esac
  case "$out" in *"gadget"*"orch -"*) ;; *)
    echo "gadget was not '-': $out"
    _fleet_teardown
    return 1
    ;;
  esac
  assert_contains "$out" "workers 1/4"
  _fleet_teardown
}

# Root's mail is per workspace: the point of the view is that nobody has to
# remember which mailbox they last looked at.
test_fleet_counts_root_mail_per_workspace() {
  _fleet_setup
  local doc
  doc="$(cmd_fleet --json)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[] | select(.name=="alpha") | .root.unread')" "1"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[] | select(.name=="beta")  | .root.unread')" "0"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[] | select(.name=="alpha") | .root.open')" "0"
  assert_contains "$(cmd_fleet --workspace alpha)" "1 unread"
  _fleet_teardown
}

# The incident replayed through the fleet view: a dead pane plus a worktree
# nothing has written to for two hours is one stalled worker.
test_fleet_reports_a_dead_pane_as_stalled() {
  _fleet_setup
  find "$WT" -exec touch -d '2 hours ago' {} + 2>/dev/null || true
  local out
  out="$(STUB_PANE_TEXT="$(_fleet_death)" cmd_fleet --workspace alpha)"
  assert_contains "$out" "stalled 1"
  _fleet_teardown
}

# Unlanded is what would be LOST, not what is merely unfinished.
test_fleet_reports_uncommitted_work_as_unlanded() {
  _fleet_setup
  assert_contains "$(cmd_fleet --workspace alpha)" "unlanded 0"
  printf 'work\n' >"$WT/scratch.txt"
  assert_contains "$(cmd_fleet --workspace alpha)" "unlanded 1"
  _fleet_teardown
}

test_fleet_json_carries_the_same_numbers_and_workspace_limits_the_scope() {
  _fleet_setup
  printf 'work\n' >"$WT/scratch.txt"
  local doc
  doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces | length')" "1"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].name')" "alpha"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units | length')" "2"
  local u
  u="$(printf '%s' "$doc" | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch')" "LIVE"
  assert_eq "$(printf '%s' "$u" | jq -r '.workers')" "1"
  assert_eq "$(printf '%s' "$u" | jq -r '.cap')" "4"
  assert_eq "$(printf '%s' "$u" | jq -r '.stalled')" "0"
  assert_eq "$(printf '%s' "$u" | jq -r '.unlanded')" "1"
  _fleet_teardown
}

# herdr being unreachable is not evidence that anyone died: the read still
# completes, every orchestrator reads as unknown, and nothing is convicted.
test_fleet_survives_herdr_being_down() {
  _fleet_setup
  find "$WT" -exec touch -d '2 hours ago' {} + 2>/dev/null || true
  local doc
  doc="$(STUB_HERDR_FAIL=1 cmd_fleet --json)"
  assert_eq "$(printf '%s' "$doc" | jq -r '[.workspaces[].units[].orch] | unique | join(",")')" "-"
  assert_eq "$(printf '%s' "$doc" | jq -r '[.workspaces[].units[].stalled] | add')" "0"
  _fleet_teardown
}

# PRODUCTS. The unit of the view is the thing an orchestrator actually stands
# over. Measured on 2026-09-17: a workspace declaring one product over two
# repos, with one live orchestrator for it, rendered as two repo rows both
# saying `orch -` - the one orchestrator that existed was invisible, and the
# cap `cel-fanout delegate` enforces per product was shown per repo.
_fleet_declare_bundle() { # [workers-cap]
  local cap="${1:-}"
  {
    printf 'products:\n  - name: bundle\n    repos: [widget, gadget]\n'
    [ -n "$cap" ] && printf '    workers: %s\n' "$cap"
  } >>"$T/alpha/workspace.yaml"
  # A second running worker, in the product's OTHER repo: the product count is
  # the sum across its repos, which is exactly what the cap is measured against.
  local led="$T/alpha/.cel/delegations.json"
  jq -c '. + [{"id":"three","repo":"gadget","branch":"gadget-work","pane":"wA:p4","worktree":"'"$T/none"'","state":"running","ticket":""}]' \
    "$led" >"$led.tmp" && mv "$led.tmp" "$led"
}

test_fleet_counts_a_declared_product_as_one_unit() {
  _fleet_setup
  _fleet_declare_bundle
  local doc
  doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units | length')" "1"
  local u
  u="$(printf '%s' "$doc" | jq -c '.workspaces[0].units[0]')"
  assert_eq "$(printf '%s' "$u" | jq -r '.name')" "bundle"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch')" "LIVE"
  assert_eq "$(printf '%s' "$u" | jq -r '.declared')" "true"
  assert_eq "$(printf '%s' "$u" | jq -r '.repos | join(",")')" "widget,gadget"
  assert_eq "$(printf '%s' "$u" | jq -r '.workers')" "2"
  assert_eq "$(printf '%s' "$u" | jq -r '.cap')" "4"
  printf '%s' "$doc" | jq -e '.workspaces[0].units[0] | .repos|length == 2' >/dev/null \
    || { echo "repos was not a two-element array: $u"; _fleet_teardown; return 1; }
  _fleet_teardown
}

# The cap is the orchestrator's, so `products[].workers` wins over
# `policy.workers` - the same precedence `cel-fanout delegate` uses, so the
# view and the thing that refuses a fifth worker never disagree.
test_fleet_prefers_the_products_worker_cap() {
  _fleet_setup
  _fleet_declare_bundle 3
  assert_eq "$(cmd_fleet --json --workspace alpha | jq -r '.workspaces[0].units[0].cap')" "3"
  assert_contains "$(cmd_fleet --workspace alpha)" "workers 2/3"
  _fleet_teardown
}

# A declared product says which repos it is; an implicit one is a repo and
# renders exactly as it always did.
test_fleet_text_names_a_declared_products_repos() {
  _fleet_setup
  _fleet_declare_bundle
  local out
  out="$(cmd_fleet --workspace alpha)"
  assert_contains "$out" "(1 products)"
  assert_contains "$out" "bundle (widget, gadget)"
  _fleet_teardown
}

test_fleet_leaves_an_undeclared_workspace_as_repos() {
  _fleet_setup
  local out doc
  out="$(cmd_fleet --workspace alpha)"
  doc="$(cmd_fleet --json --workspace alpha)"
  assert_contains "$out" "(2 products)"
  assert_contains "$out" "$(printf '  %-12s orch %-5s workers 1/4' widget LIVE)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units[0].declared')" "false"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units[0].repos | join(",")')" "widget"
  _fleet_teardown
}

# THE COUNT WAS NEVER THE ANSWER. `stalled 1` told an operator that something
# was wrong and nothing about which worker, why, or what it was holding - so
# the console could only tell them to run the view they were already staring
# at. These are the rows behind the number, and the console (CEL-20) is
# written against exactly these keys.
test_fleet_workers_list_carries_a_row_per_live_worker() {
  _fleet_setup
  local led="$T/alpha/.cel/delegations.json"
  jq -c '. + [{"id":"three","repo":"widget","branch":"widget-let-go","pane":"wA:p5","worktree":"'"$T/none"'","state":"released","ticket":""},
              {"id":"four","repo":"widget","branch":"widget-shipped","pane":"wA:p6","worktree":"'"$T/none"'","state":"landed","ticket":""},
              {"id":"five","repo":"widget","branch":"widget-lost","pane":"wA:p7","worktree":"'"$T/none"'","state":"orphaned","ticket":""}]' \
    "$led" >"$led.tmp" && mv "$led.tmp" "$led"
  local u
  u="$(cmd_fleet --json --workspace alpha | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  # the running row and the collected one. A landed, released or orphaned row
  # is finished business - nobody can act on it, and listing it as a worker
  # buries the ones who need something.
  assert_eq "$(printf '%s' "$u" | jq -r '.workers_list | length')" "2"
  assert_eq "$(printf '%s' "$u" | jq -r '[.workers_list[].id] | join(",")')" "one,two"
  local w
  w="$(printf '%s' "$u" | jq -c '.workers_list[0]')"
  assert_eq "$(printf '%s' "$w" | jq -r '.repo')" "widget"
  assert_eq "$(printf '%s' "$w" | jq -r '.branch')" "widget-work"
  assert_eq "$(printf '%s' "$w" | jq -r '.state')" "running"
  assert_eq "$(printf '%s' "$w" | jq -r '.live')" "idle"
  assert_eq "$(printf '%s' "$w" | jq -r '.pane')" "wA:p2"
  assert_eq "$(printf '%s' "$w" | jq -r '.worktree')" "$WT"
  assert_eq "$(printf '%s' "$w" | jq -r '.quiet_secs | type')" "number"
  assert_eq "$(printf '%s' "$w" | jq -r '["id","ticket","repo","branch","shape","state","live","quiet_secs","verdict","severity","ahead","pr","created","alias","pane","worktree","rss_mb","activity","activity_confidence"] - keys | join(",")')" ""
  _fleet_teardown
}

# A working worker is not news. The verdict is empty and the count agrees.
test_fleet_workers_list_leaves_a_working_worker_unjudged() {
  _fleet_setup
  local u
  u="$(cmd_fleet --json --workspace alpha | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.workers_list[0].verdict')" ""
  assert_eq "$(printf '%s' "$u" | jq -r '.workers_list[0].severity')" ""
  assert_eq "$(printf '%s' "$u" | jq -r '.stalled')" "0"
  _fleet_teardown
}

# The number and the rows are one fact computed once: if they could disagree,
# whichever the operator read second would be the one they stopped trusting.
test_fleet_workers_list_verdict_matches_the_stalled_count() {
  _fleet_setup
  find "$WT" -exec touch -d '2 hours ago' {} + 2>/dev/null || true
  local u
  u="$(STUB_PANE_TEXT="$(_fleet_death)" cmd_fleet --json --workspace alpha \
        | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.stalled')" "1"
  assert_eq "$(printf '%s' "$u" | jq -r '[.workers_list[] | select(.verdict != "")] | length')" "1"
  assert_contains "$(printf '%s' "$u" | jq -r '.workers_list[0].verdict')" "dead-"
  assert_eq "$(printf '%s' "$u" | jq -r '.workers_list[0].severity')" "normal"
  _fleet_teardown
}

test_fleet_json_carries_the_box_and_a_footprint_per_worker() {
  _fleet_setup
  _fleet_stub_memory
  local doc u
  doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.box.total_mb')" "24576"
  assert_eq "$(printf '%s' "$doc" | jq -r '.box.available_mb')" "7065"
  assert_eq "$(printf '%s' "$doc" | jq -r '.box.used_pct')" "71"
  u="$(printf '%s' "$doc" | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  # the worker's own tree, the unit's sum, and the orchestrator pane's tree
  assert_eq "$(printf '%s' "$u" | jq -r '.workers_list[0].rss_mb')" "370"
  assert_eq "$(printf '%s' "$u" | jq -r '.rss_mb')" "370"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch_rss_mb')" "120"
  # every tree the fleet knows about: widget's worker and its orchestrator,
  # with gadget contributing nothing
  assert_eq "$(printf '%s' "$doc" | jq -r '.box.agents_rss_mb')" "490"
  _fleet_teardown
}

# A DECLARED PRODUCT'S ORCHESTRATOR STANDS IN THE PRODUCT DIRECTORY, an
# implicit one in the repo checkout - the same derivation the steward uses.
# Reading the wrong one reports zero for a live pane, which is
# indistinguishable from an orchestrator that is not running at all.
test_fleet_reads_a_declared_products_orchestrator_from_its_product_dir() {
  _fleet_setup
  _fleet_declare_bundle
  _fleet_stub_memory
  local u
  u="$(cmd_fleet --json --workspace alpha | jq -c '.workspaces[0].units[0]')"
  assert_eq "$(printf '%s' "$u" | jq -r '.name')" "bundle"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch_rss_mb')" "120"
  _fleet_teardown
}

test_fleet_text_shows_a_units_memory_and_the_boxs_headroom() {
  _fleet_setup
  _fleet_stub_memory
  local out
  out="$(cmd_fleet --workspace alpha)"
  assert_contains "$out" "mem 370M"
  assert_contains "$out" "box 6.9G free of 24G"
  _fleet_teardown
}

# An unreadable meminfo is a statement about the observer: the read still
# completes and every number it can still answer is unchanged.
test_fleet_survives_a_box_it_cannot_measure() {
  _fleet_setup
  local doc
  doc="$(CEL_MEMINFO=/nonexistent/meminfo cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.box.total_mb')" "0"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units | length')" "2"
  _fleet_teardown
}

test_fleet_rejects_unknown_arguments() {
  _fleet_setup
  assert_fails bash -c "source '$CEL_ROOT/lib/fleet.sh'; cmd_fleet --nonsense"
  _fleet_teardown
}

# --- CEL-27: subscriptions, from the cache and never from the network --------
# The fleet read is on the console's refresh loop. A live call to Anthropic or
# ChatGPT on that path would put two network round trips between an operator
# and every draw, so the field is whatever the 60 s cache already holds.
test_fleet_json_carries_subscriptions_from_the_cache() {
  _fleet_setup
  export CEL_CACHE="$T/cache"
  mkdir -p "$CEL_CACHE"
  jq -nc '{provider: "claude", account: "a1b2c3",
           windows: [{name: "5h", used_pct: 16, resets_at: "2026-09-18T09:00:00Z"}],
           extra: {state: "enabled", reason: ""}}' \
    > "$CEL_CACHE/subscription-claude-a1b2c3.json"
  local doc; doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.subscriptions[0].provider')" claude
  assert_eq "$(printf '%s' "$doc" | jq -r '.subscriptions[0].windows[0].used_pct')" 16
  _fleet_teardown
}

test_fleet_json_carries_an_empty_subscription_list_when_nothing_is_cached() {
  _fleet_setup
  export CEL_CACHE="$T/empty-cache"
  local doc; doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.subscriptions | length')" 0
  _fleet_teardown
}

# CEL-35: the fleet field is not a directory listing, it is the subscription
# list read from the cache. Two copies of one Claude login (pi's and Claude
# Code's) with the same windows are one subscription here exactly as they are
# in `cel quota`, or the console and the dashboard count this box's logins
# differently - which is how five rows appeared for two accounts.
test_fleet_subscriptions_are_the_quota_list_folded_the_same_way() {
  _fleet_setup
  export CEL_CACHE="$T/cache35"
  mkdir -p "$CEL_CACHE"
  local w='[{"name":"5h","used_pct":16,"resets_at":"2026-09-18T09:00:00Z"}]'
  jq -nc --argjson w "$w" '{provider: "claude", account: "pi", label: "pi", source: "direct",
                            windows: $w, extra: {state: "enabled", reason: ""}}' \
    > "$CEL_CACHE/subscription-claude-pi.json"
  jq -nc --argjson w "$w" '{provider: "claude", account: "claude-code", label: "claude-code",
                            source: "direct", windows: $w, extra: {state: "enabled", reason: ""}}' \
    > "$CEL_CACHE/subscription-claude-claude-code.json"
  local doc; doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.subscriptions | length')" 1
  assert_eq "$(printf '%s' "$doc" | jq -r '.subscriptions[0].label')" 'pi + claude-code'
  _fleet_teardown
}

# CEL-42: what the pane is DOING, beside what herdr says it is doing. The
# fleet never asks the model itself - a view that makes a network call per row
# is a view people stop running - it carries the steward's last answer, which
# is why the two fields are only present when one was remembered.
test_fleet_workers_list_carries_the_last_liveness_answer() {
  _fleet_setup
  export CEL_LIVENESS_STATE="$T/liveness-state"
  source "$CEL_ROOT/lib/liveness.sh"
  liveness_remember one looping 0.81
  local u
  u="$(cmd_fleet --json --workspace alpha | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.workers_list[0].activity')" "looping"
  assert_eq "$(printf '%s' "$u" | jq -r '.workers_list[0].activity_confidence')" "0.81"
  # ...and a row nobody has classified says so by carrying nothing.
  assert_eq "$(printf '%s' "$u" | jq -r '.workers_list[1].activity')" ""
  _fleet_teardown
}

# A NAMELESS AGENT IS A FAULT, NOT AN ABSENCE (CEL-44). herdr cleared a live
# orchestrator's name on restart; `cel fleet` resolves one by its alias on the
# roster, so the product read `orch -` - which anyone acting on would answer by
# starting a SECOND orchestrator on top of the live one. A live agent in the
# product's own cwd reads as `unnamed`, which is a state with a cure.
test_fleet_reports_a_live_unnamed_agent_as_unnamed() {
  _fleet_setup
  local doc
  doc="$(STUB_UNNAMED_CWD="$T/alpha/repos/gadget" cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units[] | select(.name=="gadget") | .orch')" "unnamed"
  assert_contains "$(STUB_UNNAMED_CWD="$T/alpha/repos/gadget" cmd_fleet --workspace alpha)" "orch unnamed"
  # And with nothing there it is still the dash it always was.
  doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units[] | select(.name=="gadget") | .orch')" "-"
  _fleet_teardown
}

# --- CEL-43: a mailbox with no reader --------------------------------------
# Every view of this box reads `cel fleet --json`, so the three facts that
# decide whether root's mail is going anywhere belong in it: how much is
# unread, how long the oldest has waited, and WHO is alive to read it. The
# herdr stub's roster has no alpha-root and the fixture has no console, so
# alpha's mail is landing in a mailbox nobody reads - which is the fault.
test_fleet_json_carries_the_mail_triple_per_workspace() {
  _fleet_setup
  local doc; doc="$(cmd_fleet --json)"
  local alpha; alpha="$(printf '%s' "$doc" | jq -c '.workspaces[] | select(.name=="alpha") | .mail')"
  assert_eq "$(printf '%s' "$alpha" | jq -r '.to_root_unread')" "1"
  assert_eq "$(printf '%s' "$alpha" | jq -r '.reader')" ""
  [ "$(printf '%s' "$alpha" | jq -r '.oldest_secs')" -gt 0 ] || { echo "no age on the oldest unread"; return 1; }
  # a live root pane IS a reader, and then there is nothing to report
  mkdir -p "$CEL_PROC_DIR/4242"
  printf 'CEL_ROLE=console\0' > "$CEL_PROC_DIR/4242/environ"
  assert_eq "$(cmd_fleet --json | jq -r '.workspaces[] | select(.name=="alpha") | .mail.reader')" "console"
  _fleet_teardown
}

# The doctor line is the one a human reads. It says the count, the age and the
# fact that nobody is reading it - and says nothing at all when someone is.
test_fleet_mail_doctor_line_names_the_mailbox_nobody_reads() {
  _fleet_setup
  assert_contains "$(fleet_mail_doctor_line alpha)" "alpha: root has 1 unread"
  assert_contains "$(fleet_mail_doctor_line alpha)" "nobody reading it"
  assert_eq "$(fleet_mail_doctor_line beta)" ""
  mkdir -p "$CEL_PROC_DIR/4242"
  printf 'CEL_ROLE=console\0' > "$CEL_PROC_DIR/4242/environ"
  assert_eq "$(fleet_mail_doctor_line alpha)" ""
  _fleet_teardown
}

# --- CEL-50: mail to a pane that is not there -------------------------------
#
# `alpha-ABC-48` was sent a finding by inbox; the ledger showed `live: -` and
# nothing received it. The message was accepted and went nowhere, which is the
# worst of both: the sender believes it was delivered. An alias with no live
# pane is a fact the box can see, so it says so.
test_mail_to_an_alias_with_no_live_pane_is_reported() {
  local roster='{"result":{"agents":[{"pane_id":"wA:p1","name":"widget-ABC-1","agent_status":"working"}]}}'
  assert_eq "$(fleet_alias_undeliverable "$roster" widget-ABC-1)" ""
  local out; out="$(fleet_alias_undeliverable "$roster" widget-ABC-48 || true)"
  assert_contains "$out" 'widget-ABC-48'
  assert_contains "$out" 'no live pane'
  # A roster nobody could read is not evidence that anyone died - the lesson
  # lib/stall.sh already paid for.
  assert_eq "$(fleet_alias_undeliverable '' widget-ABC-48)" ""
}

# --- CEL-48: the cost of the read is itself a fact the suite holds ----------
#
# Measured on 2026-09-20, before any of this: `cel console --render-once`
# took 7.1-7.4s wall with 62% of it SYSTEM time, and `cel fleet --json` was
# ~70% of that - 278 jq and 112 git processes on one render, 154 of the jq and
# all of the git inside this file. Nothing on the path talks to a network; the
# whole cost was fork and exec for crumbs of work. A performance fix with no
# test rots in a month, so the budget is asserted: jq and git are shimmed onto
# a prepended PATH, they log their argv, and the counts must stay under a
# ceiling that GROWS WITH THE ROWS rather than multiplying by them.

# The shim: a counter in front of EVERY binary the read can reach, not just
# the two this ticket set out to reduce. The first version of this budget
# counted jq and git alone and would have passed while the total tripled -
# "a budget that only watches the two tools you were thinking about is a
# budget that rots the moment someone reaches for a third". PATH is REPLACED
# rather than prepended, so a tool nobody listed here cannot run at all and
# the render fails loudly instead of slipping past uncounted.
_FLEET_SHIMMED_TOOLS=(
  awk sed grep cut tr head tail sort uniq wc find stat readlink dirname
  basename date id ls cat rm mkdir mktemp touch flock xargs getent ps
  bash sh env jq git yq node python3 cksum mv cp chmod ln sleep tee expr seq
)
_fleet_spawn_shim() { # -> $T/shim, the whole PATH; argv lands in CEL_SPAWN_LOG
  local s="$T/shim" b real
  mkdir -p "$s"
  export CEL_SPAWN_LOG="$T/spawns.log"
  : >"$CEL_SPAWN_LOG"
  for b in "${_FLEET_SHIMMED_TOOLS[@]}"; do
    real="$(command -v "$b" 2>/dev/null)" || continue
    [ -n "$real" ] || continue
    cat >"$s/$b" <<SHIM
#!/bin/bash
printf '%s\t%s\n' "$b" "\${*//$'\\n'/ }" >>"\$CEL_SPAWN_LOG"
exec "$real" "\$@"
SHIM
    chmod +x "$s/$b"
  done
}

# THE BOX'S PROCESS TABLE IS NOT THIS FIXTURE'S BUSINESS. `fleet_orphans_json`
# walks every pid on the machine (lib/orphans.sh, CEL-47) and costs ~1050 awk,
# 117 tr and 117 readlink on this box - three quarters of every process a real
# `cel fleet` starts, identical on main and on this branch, and completely
# outside anything a fixture can arrange. It is stubbed for the same reason
# `_fleet_stub_memory` stubs the memory walk: what is being budgeted here is
# what lib/fleet.sh does per row, and a number that moves with whatever else
# is running on the box budgets nothing.
_fleet_stub_box_walk() {
  orphans_list() { :; }
  orphans_totals() { printf '0 0\n'; }
}

_fleet_spawns() { # [binary] -> how many processes were started, in all or of one
  if [ $# -eq 0 ]; then grep -c . "$CEL_SPAWN_LOG" || true; return 0; fi
  grep -c "^$1	" "$CEL_SPAWN_LOG" || true
}

# n more RUNNING rows in widget, each with its own pane and no worktree: the
# cheapest row there is, which is the right thing to scale with - it isolates
# the per-row process cost from the work any one row implies.
_fleet_add_rows() { # <n>
  local n="$1" led="$T/alpha/.cel/delegations.json" i add="[]"
  for ((i = 0; i < n; i++)); do
    add="$(jq -c --arg i "$i" '. + [{"id": ("bulk" + $i), "repo": "widget",
            "branch": ("widget-bulk-" + $i), "pane": ("wA:b" + $i),
            "worktree": "", "state": "running", "ticket": ""}]' <<<"$add")"
  done
  jq -c --argjson add "$add" '. + $add' "$led" >"$led.tmp" && mv "$led.tmp" "$led"
}

# THE CEILING IS ON EVERY PROCESS, NOT ON THE TWO THIS TICKET WAS ABOUT.
#
# Measured on this fixture against main e545cff (CEL-51), with the box walk
# stubbed and PATH REPLACED by the shim so nothing can run uncounted:
#
#                3 rows                        12 rows
#   before       177 total (64 jq, 12 git)       231 total (109 jq, 12 git)
#   after        150 total (47 jq,  4 git)       168 total ( 56 jq,  4 git)
#
# Five processes per extra row became one. The remainder is fixed cost that
# belongs to other libraries reading their own documents - `cksum` and `stat`
# per file for lib/yaml.sh's cache key, `yq` per YAML, and the jq those
# accessors run - and it MOVES: CEL-43's mail triple added 26 to both sides
# between one measurement and the next, and CEL-49 and CEL-51 added an awk per
# row to both. That is why this number is taken against the main the branch
# actually sits on and re-taken after every rebase; a ceiling measured against
# a different main is how a branch gets called three times slower than a
# checkout that predates two other tickets. What the ceiling asserts is the
# SHAPE - a fixed cost plus a small constant per row - not a frozen count.
#
# The first version of this budget counted jq and git ALONE. It would have
# passed a change that traded a per-row jq for a per-row awk, which is the
# same fan-out wearing different clothes; a budget that watches only the tools
# its author was thinking about rots the moment somebody reaches for a third.
# The ceiling below is the TOTAL, and main fails it at both sizes (177 > 160,
# 231 > 178), which is the only way to know it is measuring anything. The
# branch measures 150 and 168 on consecutive runs, so the headroom is real
# slack and not a repeat of the measurement. One of those jq is the roster
# being validated once per render rather than being allowed to fail inside
# whichever program touched it first, which is a process well spent.
_fleet_assert_budget() { # <rows> <total-spawns>
  local rows="$1" total="$2"
  local max=$(( 154 + 2 * rows ))
  if [ "$total" -gt "$max" ]; then
    printf 'the read started %s processes, over the ceiling of %s for %s rows\n' \
      "$total" "$max" "$rows" >&2
    printf 'by tool:\n%s\n' "$(cut -f1 "$CEL_SPAWN_LOG" | sort | uniq -c | sort -rn | head -10)" >&2
    return 1
  fi
  return 0
}

test_fleet_stays_under_its_spawn_budget() {
  _fleet_setup
  _fleet_stub_memory
  export CEL_CACHE="$T/nocache"
  _fleet_declare_bundle
  local rc=0
  _fleet_stub_box_walk
  _fleet_spawn_shim
  PATH="$T/shim:$T/bin" cmd_fleet --json >/dev/null
  _fleet_assert_budget 3 "$(_fleet_spawns)" || rc=1
  _fleet_teardown
  return "$rc"
}

# ...and the shape of the growth, which is the whole point: four times the
# rows must not be four times the processes plus a constant per row.
test_fleet_spawn_budget_grows_with_rows_rather_than_multiplying_by_them() {
  _fleet_setup
  _fleet_stub_memory
  export CEL_CACHE="$T/nocache"
  _fleet_declare_bundle
  _fleet_add_rows 9
  local rc=0
  _fleet_stub_box_walk
  _fleet_spawn_shim
  PATH="$T/shim:$T/bin" cmd_fleet --json >/dev/null
  _fleet_assert_budget 12 "$(_fleet_spawns)" || rc=1
  _fleet_teardown
  return "$rc"
}

# THE DOCUMENT DID NOT MOVE. CEL-48 changed how every row is computed - one
# jq over the ledger, one batched git per worktree - and the one thing it was
# not allowed to change is the answer. This is `cel fleet --json` captured on
# this fixture before the rewrite, compact and in order, so a field that
# silently reorders or loses its type fails here. The box, subscriptions and
# orphan fields are the live machine's and are not part of the capture; the
# worktree path, the age of the newest file and the age of the oldest unread
# are normalised for the same reason. RE-CAPTURED after each rebase, from the
# main the branch sits on: it landed first against 9f7cf2d and is taken here
# against 931954c, which added the `mail` triple to every workspace.
_FLEET_GOLDEN_WORKSPACES='[{"name":"alpha","root":{"unread":1,"open":0},"mail":{"to_root_unread":1,"oldest_secs":1,"reader":""},"units":[{"name":"bundle","orch":"LIVE","workers":2,"cap":4,"stalled":1,"unlanded":1,"rss_mb":370,"orch_rss_mb":120,"repos":["widget","gadget"],"declared":true,"workers_list":[{"id":"one","ticket":"","repo":"widget","branch":"widget-work","shape":"ship","state":"running","live":"idle","quiet_secs":0,"verdict":"","severity":"","ahead":"0","rss_mb":370,"pr":"","created":"","alias":"","pane":"wA:p2","worktree":"WT","profile":"","runtime":"","model":"","activity":"","activity_confidence":"","harness":""},{"id":"two","ticket":"","repo":"widget","branch":"widget-old","shape":"ship","state":"collected","live":"gone","quiet_secs":-1,"verdict":"","severity":"","ahead":"?","rss_mb":0,"pr":"","created":"","alias":"","pane":"wA:p3","worktree":"T/gone","profile":"","runtime":"","model":"","activity":"","activity_confidence":"","harness":""},{"id":"three","ticket":"","repo":"gadget","branch":"gadget-work","shape":"ship","state":"running","live":"gone","quiet_secs":-1,"verdict":"vanished","severity":"normal","ahead":"?","rss_mb":0,"pr":"","created":"","alias":"","pane":"wA:p4","worktree":"T/none","profile":"","runtime":"","model":"","activity":"","activity_confidence":"","harness":""}]}]},{"name":"beta","root":{"unread":0,"open":0},"mail":{"to_root_unread":0,"oldest_secs":0,"reader":""},"units":[{"name":"gadget","orch":"-","workers":0,"cap":4,"stalled":0,"unlanded":0,"rss_mb":0,"orch_rss_mb":0,"repos":["gadget"],"declared":false,"workers_list":[]}]}]'

_fleet_normalise() { # < doc -> .workspaces, paths and ages made reproducible
  jq -c --arg t "$T" --arg wt "$WT" '
    .workspaces
    | walk(if type == "string"
           then (sub("\\Q" + $wt + "\\E"; "WT") | sub("\\Q" + $t + "\\E"; "T"))
           else . end)
    | walk(if type == "object" and has("quiet_secs")
           then .quiet_secs = (if .quiet_secs >= 0 then 0 else -1 end)
           else . end)
    # The oldest unread (CEL-43) is measured from a fixed timestamp in the
    # fixture against the clock, so it grows by a second every second.
    | walk(if type == "object" and has("oldest_secs")
           then .oldest_secs = (if .oldest_secs > 0 then 1 else 0 end)
           else . end)'
}

test_fleet_json_is_identical_to_the_document_captured_before_the_rewrite() {
  _fleet_setup
  _fleet_stub_memory
  export CEL_CACHE="$T/nocache"
  _fleet_declare_bundle
  printf 'work\n' >"$WT/scratch.txt"
  local got rc=0
  got="$(cmd_fleet --json | _fleet_normalise)"
  assert_eq "$got" "$_FLEET_GOLDEN_WORKSPACES" || rc=1
  _fleet_teardown
  return "$rc"
}

# A REPO IN A STATE NOBODY PLANNED FOR. The per-row git calls were forgiving -
# every one of them ended in `|| true` or a `?` - and a batched query that
# asks one question for four repos is exactly the kind of change that turns
# "could not ask" into an error. Detached HEAD, a branch with no remote twin,
# a checkout with no origin at all and a dirty tree each produce the row they
# produced before, `?` and all.
_fleet_broken_worktrees() {
  local d
  for d in detached noupstream noorigin dirty; do
    mkdir -p "$T/$d"
    git -C "$T/$d" init -q -b main
    git -C "$T/$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
    case "$d" in
      noorigin) ;;
      *) git -C "$T/$d" update-ref refs/remotes/origin/main HEAD
         git -C "$T/$d" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main ;;
    esac
  done
  git -C "$T/detached" -c user.email=t@t -c user.name=t commit -q --allow-empty -m extra
  git -C "$T/detached" checkout -q --detach HEAD
  git -C "$T/noupstream" checkout -q -b feature
  git -C "$T/noupstream" -c user.email=t@t -c user.name=t commit -q --allow-empty -m w1
  git -C "$T/noorigin" checkout -q -b feature
  git -C "$T/dirty" checkout -q -b feature
  git -C "$T/dirty" update-ref refs/remotes/origin/feature HEAD
  printf 'x\n' >"$T/dirty/a.txt"
  mkdir -p "$T/dirty/.agent"
  printf 'y\n' >"$T/dirty/.agent/result.md"
  local led="$T/beta/.cel/delegations.json" d2
  printf '[]' >"$led"
  for d2 in detached noupstream noorigin dirty; do
    jq -c --arg d "$d2" --arg wt "$T/$d2"       '. + [{"id": $d, "repo": "gadget", "branch": "feature", "pane": "", "worktree": $wt,
             "state": "running", "ticket": ""}]' "$led" >"$led.tmp" && mv "$led.tmp" "$led"
  done
}

test_fleet_rows_survive_a_repo_in_a_broken_state() {
  _fleet_setup
  _fleet_stub_memory
  export CEL_CACHE="$T/nocache"
  _fleet_broken_worktrees
  local u rc=0
  u="$(cmd_fleet --json --workspace beta | jq -c '.workspaces[0].units[0]')"
  # a detached HEAD has no branch to count from, and says so rather than 0
  assert_eq "$(jq -r '.workers_list[] | select(.id=="detached") | .ahead' <<<"$u")" "?" || rc=1
  # a branch the remote has never seen counts from origin/HEAD: one commit,
  # and one commit of work that would be lost
  assert_eq "$(jq -r '.workers_list[] | select(.id=="noupstream") | .ahead' <<<"$u")" "1" || rc=1
  # no origin at all is unknown, not zero
  assert_eq "$(jq -r '.workers_list[] | select(.id=="noorigin") | .ahead' <<<"$u")" "?" || rc=1
  # dirty tree, pushed branch: nothing ahead, but work at risk - and
  # `.agent/` is the worker's report, not work
  assert_eq "$(jq -r '.workers_list[] | select(.id=="dirty") | .ahead' <<<"$u")" "0" || rc=1
  # noupstream (1 unpushed) and dirty (1 dirty file) are the two at risk
  assert_eq "$(jq -r '.unlanded' <<<"$u")" "2" || rc=1
  assert_eq "$(jq -r '.workers_list | length' <<<"$u")" "4" || rc=1
  _fleet_teardown
  return "$rc"
}

# THE HELPERS ARE A CONTRACT WITH cel-fanout, NOT PRIVATE TO THE SWEEP.
# `fleet_ahead` is what `cel-fanout status` prints in its AHEAD column, and
# `fleet_worker_row` with three arguments is how that binary renders a row.
# The sweep inside this file reaches the batched git query directly, so
# nothing here exercised either entry point - and a duplicated definition of
# `fleet_ahead` calling a function that does not exist shipped green, because
# bash keeps only the LAST definition of a name and no test ever called it.
test_fleet_ahead_answers_the_external_caller() {
  _fleet_setup
  assert_eq "$(fleet_ahead "$WT")" "0"
  git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
  assert_eq "$(fleet_ahead "$WT")" "1"
  # A worktree that cannot be read is unknown, not zero.
  assert_eq "$(fleet_ahead "$T/nowhere")" "?"
  _fleet_teardown
}

# The three-argument form cel-fanout calls, which has to derive the worktree,
# the state and the id from the entry on its own.
test_fleet_worker_row_renders_from_the_entry_alone() {
  _fleet_setup
  local row
  row="$(fleet_worker_row "$(jq -c '.[0]' "$T/alpha/.cel/delegations.json")" idle "")"
  assert_eq "$(printf '%s' "$row" | jq -r '.id')" "one"
  assert_eq "$(printf '%s' "$row" | jq -r '.ahead')" "0"
  assert_eq "$(printf '%s' "$row" | jq -r '.state')" "running"
  _fleet_teardown
}

# AN UNREADABLE ROSTER MUST NOT BE ABLE TO EMPTY THE FLEET.
#
# `herdr agent list` answering with non-empty MALFORMED JSON made `--argjson
# roster` fail before jq ever opened the ledger, and the `|| true` that keeps
# this read from dying turned that into an empty row list - so `cel fleet
# --json` rendered a box with no workers on it, which is indistinguishable
# from a box with no workers on it. A failure path that degrades to silence is
# the worst kind: the operator acts on the silence.
#
# The rows are the LEDGER's, and the ledger is readable whatever herdr is
# doing. An unusable roster is the same statement as an absent one - `-`, a
# fact about the observer - and never a statement about the worker.
test_fleet_rows_survive_a_roster_that_is_not_json() {
  _fleet_setup
  local doc u
  doc="$(STUB_HERDR_BAD=1 cmd_fleet --json --workspace alpha)"
  u="$(printf '%s' "$doc" | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.workers_list | length')" "2"
  assert_eq "$(printf '%s' "$u" | jq -r '[.workers_list[].id] | join(",")')" "one,two"
  assert_eq "$(printf '%s' "$u" | jq -r '.workers')" "1"
  # ...and nobody is convicted on the strength of a document nobody could read
  assert_eq "$(printf '%s' "$u" | jq -r '[.workers_list[].live] | unique | join(",")')" "-"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch')" "-"
  assert_eq "$(printf '%s' "$u" | jq -r '.stalled')" "0"
  _fleet_teardown
}

# herdr exiting non-zero is the same statement, by a different route, and the
# rows are just as present.
test_fleet_rows_survive_herdr_exiting_non_zero() {
  _fleet_setup
  local u
  u="$(STUB_HERDR_FAIL=1 cmd_fleet --json --workspace alpha | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.workers_list | length')" "2"
  assert_eq "$(printf '%s' "$u" | jq -r '[.workers_list[].live] | unique | join(",")')" "-"
  _fleet_teardown
}

# AND THE CASE THAT IS NOT A FAILURE AT ALL. A roster that answers properly
# with an empty agent list is EVIDENCE: it knows about nobody, so the rows it
# does not mention are `gone`, not `-`. If an unreadable roster and an empty
# one produced the same row, neither word would mean anything.
test_fleet_tells_an_empty_roster_from_an_unreadable_one() {
  _fleet_setup
  cat >"$T/bin/herdr" <<'HERDR'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list") printf '%s\n' '{"result":{"agents":[]}}' ;;
  *) printf '%s\n' '{}' ;;
esac
HERDR
  chmod +x "$T/bin/herdr"
  local u
  u="$(cmd_fleet --json --workspace alpha | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.workers_list | length')" "2"
  assert_eq "$(printf '%s' "$u" | jq -r '[.workers_list[].live] | unique | join(",")')" "gone"
  _fleet_teardown
}
