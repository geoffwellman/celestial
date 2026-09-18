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
case "$1 $2" in
  "agent list") printf '%s\n' '{"result":{"agents":[
      {"name":"widget-orch","agent_status":"idle","pane_id":"wA:p1"},
      {"name":"bundle-orch","agent_status":"idle","pane_id":"wA:p9"},
      {"name":"widget-widget-work","agent_status":"idle","pane_id":"wA:p2"}]}}' ;;
  "pane read")  printf '%s\n' "${STUB_PANE_TEXT:-reading src and running the gate}" ;;
  *) printf '%s\n' '{}' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
  PATH="$T/bin:$PATH"
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
  assert_eq "$(printf '%s' "$w" | jq -r '["id","ticket","repo","branch","shape","state","live","quiet_secs","verdict","severity","ahead","pr","created","alias","pane","worktree","rss_mb"] - keys | join(",")')" ""
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
