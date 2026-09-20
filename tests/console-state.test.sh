# shellcheck shell=bash
# CEL-51: the status edge, asserted on the ASSEMBLED view.
#
# CEL-49 put subscription usage on the console status edge and drew it as a
# bar. Every test it shipped with called `subsEdge` by hand with both of its
# arguments, so all of them passed while four of the five renderers in
# tools/console/state.mjs called `statusRow(status, doc.box)` and handed the
# function `undefined` for the document it declared. `subsEdge(undefined)`
# answers `''`, so on the services, unit, worker and timeline views the edge
# was not barless - it was ABSENT, and looked exactly like a box with no
# subscriptions. The width was not passed either, so even the one correct call
# site selected a zero-width track and drew no bar.
#
# Nothing here calls `subsEdge`. Everything is asserted on what the view
# prints, because what the view prints is the thing that was wrong.
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

# The five views, by the flags that render them. `--render-once` on its own is
# the fleet desk - the only one that was ever correct.
_state_views() {
  printf '%s\n' '' '--services' '--unit bundle' '--worker ABC-49-slug' '--timeline'
}

# THE BUG ITSELF. The owner asked for this display twice and it landed on one
# view out of five, because a call that forgets an argument is a call
# JavaScript is happy to make.
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

# The width has to reach `subsEdge` or it selects a zero-width track and
# `usageBar` correctly draws nothing - which is how a "bar" ticket shipped
# without one. The bar goes AFTER the figures, on the same edge.
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

# A TERMINAL TOO NARROW TO BE HONEST GETS THE TEXT. The figures are what an
# operator reads first; the track is the first thing dropped when the row is
# tight, because a status edge that wraps costs a line of the desk.
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

# The case that must stay DISTINGUISHABLE from the bug: a box that genuinely
# has no subscriptions renders no edge and does not error. Before CEL-51 these
# two looked identical on four views, which is why nobody noticed.
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

# A MISSING DOCUMENT IS A PROGRAMMING ERROR, NOT AN EMPTY EDGE. This is the
# whole of CEL-51 in one assertion: `statusRow` used to accept `undefined` for
# the document it declared and answer with a row that looked fine. It refuses
# now, so the next renderer that forgets fails where it is written rather than
# on the operator's screen six weeks later.
test_status_row_refuses_a_missing_document() {
  local out rc=0
  out="$(node --input-type=module -e "
    const { statusRow } = await import('$CEL_ROOT/tools/console/state.mjs');
    statusRow('', { mem_free_mb: 800 }, undefined, 120);
  " 2>&1)" || rc=$?
  assert_eq "$rc" 1 || { printf '%s\n' "$out"; return 1; }
  # and it says WHAT it could not read, not just that something was wrong
  assert_contains "$out" 'fleet document'
}
