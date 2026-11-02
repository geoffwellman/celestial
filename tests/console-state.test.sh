# shellcheck shell=bash
# The status edge, asserted on what every ASSEMBLED view prints (never by
# calling `subsEdge` directly): each view carries the subscription edge.
source "$CEL_ROOT/lib/common.sh"

CONSOLE_MJS="$CEL_ROOT/tools/console/console.mjs"

# A miniature box carrying, at once, everything the five views need: a unit
# with workers (unit and worker views), services (services view), mail (the
# timeline) and two subscriptions. Never the live box.
_state_setup() { # [fleet-json-file]
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/inbox" "$T/cache" "$T/state"

  cat >"$T/fleet.json" <<'EOF'
{"workspaces":[
 {"name":"alpha","root":{"unread":1,"open":1},"units":[
   {"name":"bundle","orch":"LIVE","pane":"w1:p0","workers":1,"cap":4,"stalled":0,"unlanded":0,
    "repos":["widget"],"declared":true,
    "workers_list":[
      {"id":"ABC-49-slug","ticket":"ABC-49","repo":"widget","branch":"ABC-49-slug","shape":"ship",
       "state":"running","live":"working","quiet_secs":10,"verdict":"","severity":"",
       "ahead":"0","pr":"","alias":"widget/ABC-49-slug","pane":"w3:p1"}]}]}],
 "subscriptions":[
  {"provider":"claude","account":"a1b2c3",
   "windows":[{"name":"5h","used_pct":16,"resets_at":"2026-09-18T09:00:00Z"},
              {"name":"7d","used_pct":41,"resets_at":"2026-09-19T19:00:00Z"}],
   "extra":{"state":"enabled","reason":""}},
  {"provider":"codex","account":"acct-alpha-1",
   "windows":[{"name":"5h","used_pct":9,"resets_at":"2026-09-18T07:30:00Z"},
              {"name":"7d","used_pct":62,"resets_at":"2026-09-21T02:00:00Z"}],
   "extra":{"state":"enabled","reason":""}}]}
EOF

  cat >"$T/services.json" <<'JSON'
[{"name":"builder","kind":"declared","state":"up","port":4322,"rss_mb":312,"uptime_secs":7200,
  "reach":"","ticket":"","url":"http://127.0.0.1:4322","observe_only":false}]
JSON

  : >"$T/open.alpha.json"
  printf '%s\n' \
    '{"id":"m1","ts":"2026-09-20T09:00:00+00:00","kind":"status","from":"bundle-orch","to":"root","message":"first line"}' \
    >"$T/inbox/alpha.jsonl"

  cat >"$T/bin/cel" <<EOF
#!/usr/bin/env bash
case "\$1" in
  fleet)    cat "$T/fleet.json" ;;
  services) cat "$T/services.json" ;;
  inbox)
    ws=""
    for a in "\$@"; do [ "\$prev" = --workspace ] && ws="\$a"; prev="\$a"; done
    cat "$T/open.\$ws.json" 2>/dev/null || true ;;
  *) printf '' ;;
esac
EOF
  chmod +x "$T/bin/cel"

  cat >"$T/bin/cel-fanout" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  why) printf '%s\n' "$2 - running, agent working" ;;
  *)   printf '' ;;
esac
EOF
  chmod +x "$T/bin/cel-fanout"

  export CEL_BIN="$T/bin/cel" CEL_FANOUT_BIN="$T/bin/cel-fanout"
  export CEL_INBOX_DIR="$T/inbox" CEL_CONSOLE_CONFIG="$T/config.yaml"
  export CEL_CACHE="$T/cache" CEL_CONSOLE_STATE_DIR="$T/state"
}

_state_teardown() { rm -rf "$T"; }

# The five views, by the flags that render them (`--render-once` alone is the
# fleet desk).
_state_views() {
  printf '%s\n' '' '--services' '--unit bundle' '--worker ABC-49-slug' '--timeline'
}

# Every view shows the subscription edge for every provider.
test_every_view_shows_the_subscription_edge() {
  _state_setup
  export COLUMNS=120
  local flags out
  while IFS= read -r flags; do
    # shellcheck disable=SC2086
    out="$(node "$CONSOLE_MJS" --render-once $flags)" || {
      printf 'view [%s] failed to render\n' "$flags"; _state_teardown; return 1
    }
    case "$out" in
      *'claude 16%/41%'*) ;;
      *) printf 'view [%s] has no subscription edge:\n%s\n' "$flags" "$out"; _state_teardown; return 1 ;;
    esac
    case "$out" in
      *'codex 9%/62%'*) ;;
      *) printf 'view [%s] lost the second provider:\n%s\n' "$flags" "$out"; _state_teardown; return 1 ;;
    esac
  done < <(_state_views)
  _state_teardown
}

# Every view passes its width through, so the bar is drawn after the figures.
test_every_view_draws_a_bar_when_the_width_allows() {
  _state_setup
  export COLUMNS=120
  local flags out
  while IFS= read -r flags; do
    # shellcheck disable=SC2086
    out="$(node "$CONSOLE_MJS" --render-once $flags)" || { _state_teardown; return 1; }
    if ! printf '%s' "$out" | grep -q 'claude 16%/41% [█░]'; then
      printf 'view [%s] drew no bar at 120 columns:\n%s\n' "$flags" "$out"
      _state_teardown; return 1
    fi
  done < <(_state_views)
  _state_teardown
}

# A narrow terminal keeps the figures and drops the bar rather than wrapping.
test_a_narrow_terminal_keeps_the_figures_and_drops_the_bar() {
  _state_setup
  export COLUMNS=50
  local flags out
  while IFS= read -r flags; do
    # shellcheck disable=SC2086
    out="$(node "$CONSOLE_MJS" --render-once $flags)" || { _state_teardown; return 1; }
    assert_contains "$out" 'claude 16%/41%' || { _state_teardown; return 1; }
    case "$out" in
      *'█'*|*'░'*) printf 'view [%s] drew a bar at 50 columns:\n%s\n' "$flags" "$out"
                   _state_teardown; return 1 ;;
    esac
  done < <(_state_views)
  _state_teardown
}

# A box with no subscriptions renders no edge and does not error.
test_a_box_with_no_subscriptions_renders_no_edge_and_does_not_error() {
  _state_setup
  # the same fleet, with the subscriptions taken out
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    const doc = JSON.parse(fs.readFileSync(p, "utf8"));
    delete doc.subscriptions;
    fs.writeFileSync(p, JSON.stringify(doc));
  ' "$T/fleet.json"
  export COLUMNS=120
  local flags out rc
  while IFS= read -r flags; do
    rc=0
    # shellcheck disable=SC2086
    out="$(node "$CONSOLE_MJS" --render-once $flags 2>&1)" || rc=$?
    assert_eq "$rc" 0 || { printf '%s\n' "$out"; _state_teardown; return 1; }
    case "$out" in
      *'claude'*|*'codex'*) printf 'view [%s] invented an edge:\n%s\n' "$flags" "$out"
                            _state_teardown; return 1 ;;
    esac
  done < <(_state_views)
  _state_teardown
}

# `statusRow` refuses a missing fleet document instead of drawing an empty edge.
test_status_row_refuses_a_missing_document() {
  local out rc=0
  out="$(node --input-type=module -e "
    const { statusRow } = await import('$CEL_ROOT/tools/console/state.mjs');
    statusRow('', { mem_free_mb: 800 }, undefined, 120);
  " 2>&1)" || rc=$?
  assert_eq "$rc" 1 || { printf '%s\n' "$out"; return 1; }
  # and it says WHAT it could not read, not just that something was wrong
  assert_contains "$out" 'fleet document'
  return 0
}

# --- gathering: the CLI calls made before anything is drawn -----------------
# Per-workspace `cel inbox open` and `cel services` calls run concurrently.
source "$CEL_ROOT/lib/common.sh"

STATE_MJS="$CEL_ROOT/tools/console/state.mjs"

# Four workspaces, each call taking 0.2s, and `beta` failing outright.
_cs_setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin"
  cat >"$T/bin/cel" <<'EOF'
#!/usr/bin/env bash
ws=""
prev=""
for a in "$@"; do
  [ "$prev" = --workspace ] && ws="$a"
  prev="$a"
done
sleep "${STUB_CEL_DELAY:-0.2}"
[ "$ws" = beta ] && exit 1
# A distinct timestamp per workspace, ascending in the order the doc lists
# them, so "oldest first" is a real assertion and not a coincidence.
case "$ws" in alpha) n=1 ;; beta) n=2 ;; gamma) n=3 ;; *) n=4 ;; esac
case "$1" in
  inbox)    printf '{"id":"%s-1","ts":"2026-09-2%sT00:00:00Z","kind":"decision","from":"root","message":"m"}\n' "$ws" "$n" ;;
  services) printf '[{"name":"svc-%s","status":"up"}]\n' "$ws" ;;
esac
EOF
  chmod +x "$T/bin/cel"
  export CEL_BIN="$T/bin/cel"
}
_cs_teardown() { rm -rf "$T"; }

_cs_node() { # <script-body> -> stdout of the run
  cat >"$T/t.mjs" <<EOF
import assert from 'node:assert/strict';
import { openItems, servicesByWorkspace, allServices } from '$STATE_MJS';
const doc = { workspaces: ['alpha', 'beta', 'gamma', 'delta'].map((name) => ({ name })) };
$1
EOF
  node "$T/t.mjs"
}

# The four calls run together: the threshold is half the serial time.
test_console_state_opens_every_inbox_at_once() {
  _cs_setup
  local rc=0
  _cs_node '
const t0 = Date.now();
const items = await openItems(doc);
const ms = Date.now() - t0;
assert.ok(ms < 500, `openItems took ${ms}ms - the four calls are still serial`);
' || rc=1
  _cs_teardown
  return "$rc"
}

test_console_state_probes_every_workspaces_services_at_once() {
  _cs_setup
  local rc=0
  _cs_node '
const t0 = Date.now();
await servicesByWorkspace(doc);
const ms = Date.now() - t0;
assert.ok(ms < 500, `servicesByWorkspace took ${ms}ms - the four calls are still serial`);
' || rc=1
  _cs_teardown
  return "$rc"
}

# One workspace failing its calls leaves that entry empty and the rest intact.
test_console_state_survives_one_workspace_failing_its_calls() {
  _cs_setup
  local rc=0
  _cs_node '
const items = await openItems(doc);
assert.deepEqual(items.map((i) => i.ws), ["alpha", "gamma", "delta"]);
const by = await servicesByWorkspace(doc);
assert.deepEqual(Object.keys(by), ["alpha", "beta", "gamma", "delta"]);
assert.deepEqual(by.beta, []);
assert.equal(by.alpha.length, 1);
assert.equal(by.alpha[0].name, "svc-alpha");
const all = await allServices(doc);
assert.deepEqual(all.map((s) => s.ws), ["alpha", "gamma", "delta"]);
' || rc=1
  _cs_teardown
  return "$rc"
}

# Open items stay oldest first whatever order the answers arrive in.
test_console_state_keeps_open_items_oldest_first() {
  _cs_setup
  local rc=0
  _cs_node '
const items = await openItems(doc);
const ts = items.map((i) => i.ts);
assert.deepEqual(ts, [...ts].sort());
' || rc=1
  _cs_teardown
  return "$rc"
}
