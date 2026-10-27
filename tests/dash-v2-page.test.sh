# shellcheck shell=bash
# CEL-106: dashboard v2, the page. Served by the real dash server at /, the
# classic page at /classic; every /api/ call the page makes is answered from
# tests/fixtures/dash-v2 by the browser driver (tests/lib/dash-v2-browser.mjs)
# and recorded, so nothing here reaches a real inbox or decision.
source "$CEL_ROOT/lib/common.sh"

_vp_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

_vp_boot() {
  # found under the real HOME, before the fixture replaces it
  V2_CHROME="${CEL_TEST_CHROME:-$(node --input-type=module -e "import {findChrome} from '$CEL_ROOT/tests/lib/dash-browser.mjs'; console.log(findChrome())")}"
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/alpha" "$T/inbox" "$T/home" "$T/shots"
  printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"result\":{\"agents\":[],\"workspaces\":[],\"panes\":[]}}'" > "$T/bin/herdr"
  printf '#!/usr/bin/env bash\nprintf "[]"\n' > "$T/bin/gh"
  cat > "$T/bin/cel" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "quota --json") printf '{"subscriptions":[]}';;
  *) printf '[]';;
esac
EOF
  chmod +x "$T/bin/herdr" "$T/bin/gh" "$T/bin/cel"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n' "$T" > "$T/registry.yaml"
  printf 'name: alpha\n' > "$T/alpha/workspace.yaml"
  export HOME="$T/home" CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox"
  DASH_PORT="$(_vp_port)"
  CEL_DASH_CONFIG="{\"name\":\"alpha\",\"wsdir\":\"$T/alpha\",\"host\":\"127.0.0.1\",\"port\":$DASH_PORT,\"repos\":[],\"services\":[]}" \
    CEL_DASH_CEL="$T/bin/cel" PATH="$T/bin:$PATH" node "$CEL_ROOT/tools/dash/server.mjs" >"$T/dash.log" 2>&1 &
  DASH_PID=$!
  trap '_vp_down' EXIT
  local i; for i in $(seq 1 30); do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$DASH_PORT/api/session" && break; sleep 0.3
  done
}
_vp_down() {
  if [ -n "${DASH_PID:-}" ]; then kill "$DASH_PID" 2>/dev/null || true; wait "$DASH_PID" 2>/dev/null || true; fi
  DASH_PID=""; if [ -n "${T:-}" ]; then rm -rf "$T"; fi; T=""; trap - EXIT
}
# run one scenario; a missing browser fails in CI and says so loudly elsewhere
# (a skip that reads as a pass is how a browser test went unrun before)
_vp_run() { # <scenario>
  OUT="$(CEL_TEST_CHROME="$V2_CHROME" node "$CEL_ROOT/tests/lib/dash-v2-browser.mjs" \
    "http://127.0.0.1:$DASH_PORT" "$CEL_ROOT/tests/fixtures/dash-v2" "$1" "$T/shots")"
  if printf '%s' "$OUT" | jq -e .skip >/dev/null 2>&1; then
    echo "SKIP: $(printf '%s' "$OUT" | jq -r .skip) - set CEL_TEST_CHROME" >&2
    [ -z "${CI:-}" ] && return 2
    return 1
  fi
  echo "v2 $1: $OUT" >&2
  assert_eq "$(printf '%s' "$OUT" | jq -r .loaded)" "true"
  assert_eq "$(printf '%s' "$OUT" | jq -c .errors)" "[]"
}
_vpj() { printf '%s' "$OUT" | jq -r "$1"; }

test_dash_v2page_is_the_front_door_and_classic_redirects() {
  _vp_boot
  local v2
  v2="$(curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/")"
  assert_contains "$v2" 'src="/v2.js"'
  assert_contains "$v2" 'src="/decisions.js"'
  if printf '%s' "$v2" | grep -q 'href="/classic"'; then echo "v2 still links /classic"; return 1; fi
  assert_eq "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://127.0.0.1:$DASH_PORT/classic")" "302 http://127.0.0.1:$DASH_PORT/"
  # the token is spliced in, never the placeholder
  if printf '%s' "$v2" | grep -q '__CEL_CSRF__'; then echo "csrf placeholder left in the page"; return 1; fi
  curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/v2.js" > "$T/v2.js"
  node --check "$T/v2.js"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DASH_PORT/server.mjs")" "404"
  _vp_down
}


test_dash_v2page_filter_changes_every_card() {
  _vp_boot
  local rc=0; _vp_run filter || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj '.unchanged | length')" "0"
  assert_eq "$(_vpj '.alphaAfter | length')" "0"
  [ "$(_vpj .alphaBefore)" -ge 5 ] || { echo "too few cards carried alpha rows before: $OUT"; return 1; }
  [ "$(_vpj .feedsAskedForBundle)" -ge 5 ] || { echo "feeds not asked with ws=bundle: $OUT"; return 1; }
  assert_eq "$(_vpj .paletteAlpha)" "0"
  _vp_down
}

test_dash_v2page_drag_and_resize_survive_a_reload() {
  _vp_boot
  local rc=0; _vp_run layout || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_contains "$(_vpj .orderDragged)" "activity,since"
  assert_eq "$(_vpj .orderAfterReload)" "$(_vpj .orderDragged | sed 's/,heat//')"
  assert_contains "$(_vpj .prsClass)" "full"
  assert_contains "$(_vpj .boxClass)" "tall"
  assert_eq "$(_vpj .heatShown)" "false"
  assert_eq "$(_vpj .heatInCustomize)" "true"
  _vp_down
}

test_dash_v2page_needs_you_answers_once_with_two_clicks() {
  _vp_boot
  local rc=0; _vp_run decide || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj .afterOne)" "0"
  assert_eq "$(_vpj .armed)" "true"
  assert_eq "$(printf "%s" "$OUT" | jq -c .decides)" '[{"id":"1759800000000000002","action":"answer","option":1}]'
  assert_eq "$(_vpj .csrf)" "true"
  assert_eq "$(_vpj .gone)" "true"
  _vp_down
}

test_dash_v2page_needs_you_shows_every_option_without_a_click() {
  _vp_boot
  local rc=0; _vp_run unopened || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj '.cards|length>0')" "true"
  local want; want="$(jq -c '[.. | objects | select(has("options") and has("id")) | {id:(.id|tostring), labels:[.options[].label]}] | unique_by(.id) | sort_by(.id)' "$CEL_ROOT/tests/fixtures/dash-v2/state.json")"
  assert_eq "$(_vpj '[.cards[]|{id,labels}]|sort_by(.id)|tostring')" "$want"
  assert_eq "$(_vpj '[.cards[]|.other and .controls]|all')" "true"
  _vp_down
}

test_dash_v2page_needs_you_is_a_board_grouped_by_urgency_then_the_owners_pick() {
  _vp_boot
  local rc=0; _vp_run board || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  # fixed columns stay, empty ones too, so "nothing urgent" is visible
  assert_eq "$(_vpj '.byUrgency|map("\(.col)=\(.ids|join(","))")|join(" ")')" \
    "urgent=1759800000000000001 blocks= wait=1759800000000000003,1759800000000000002"
  assert_eq "$(_vpj '.byWorkspace|map("\(.col)=\(.ids|length)")|join(" ")')" "alpha=2 bundle=1"
  assert_eq "$(_vpj .reloaded)" "true"
  assert_eq "$(_vpj '.afterReload|map(.col)|join(" ")')" "alpha bundle"
  assert_eq "$(_vpj .ctxFolded)" "true"
  assert_eq "$(printf "%s" "$OUT" | jq -c .decides)" '[{"id":"1759800000000000002","action":"answer","option":1}]'
  _vp_down
}

test_dash_v2page_composer_sends_one_message_act_and_any_goes_to_celestial() {
  _vp_boot
  local rc=0; _vp_run composer || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj '.acts | length')" "2"
  assert_eq "$(_vpj '.acts[0].action')" "message"
  assert_eq "$(_vpj '.acts[0].target')" "bundle-orch"
  assert_eq "$(_vpj '.acts[0].args.text')" "add a gadget beta toggle"
  assert_eq "$(_vpj '.acts[0].args.kind')" "task"
  assert_eq "$(_vpj '.acts[1].target')" "celestial-orch"
  assert_eq "$(_vpj '.acts[1].args.kind')" "ask"
  assert_contains "$(_vpj .anyLabel)" "Any"
  assert_contains "$(_vpj .thread)" "add a gadget beta toggle"
  _vp_down
}

test_dash_v2page_refresh_keeps_what_the_owner_is_doing() {
  _vp_boot
  local rc=0; _vp_run refresh || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj .refreshed)" "true"
  assert_eq "$(_vpj .state.task)" "half a thought"
  assert_eq "$(_vpj .state.focused)" "true"
  assert_eq "$(_vpj .state.caret)" "4"
  assert_eq "$(_vpj .state.other)" "true"
  assert_eq "$(_vpj .state.free)" "keep it as is"
  assert_eq "$(_vpj .state.armed)" "true"
  assert_eq "$(_vpj .state.drawer)" "true"
  assert_eq "$(_vpj .state.dmsg)" "status please"
  _vp_down
}

test_dash_v2page_palette_finds_a_decision_and_opens_it() {
  _vp_boot
  local rc=0; _vp_run palette || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj .paletteOpen)" "true"
  assert_contains "$(_vpj .first)" "ship the gadget beta now?"
  assert_eq "$(_vpj .paletteClosed)" "true"
  assert_eq "$(_vpj .decisionOpen)" "true"
  assert_eq "$(_vpj .optionsShown)" "true"
  assert_eq "$(_vpj .actsAfterOneEnter)" "0"
  assert_eq "$(printf "%s" "$OUT" | jq -c .actsAfterTwo)" '["afk.on"]'
  _vp_down
}

test_dash_v2page_expand_opens_and_escape_closes() {
  _vp_boot
  local rc=0; _vp_run expand || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj .open)" "true"
  assert_eq "$(_vpj .title)" "Activity"
  assert_eq "$(_vpj .search)" "true"
  assert_eq "$(_vpj .matches)" "2"
  assert_eq "$(_vpj .closed)" "true"
  assert_eq "$(_vpj .needsInOverlay)" "true"
  assert_eq "$(_vpj .bulk)" "true"
  assert_eq "$(_vpj .needsBack)" "true"
  assert_eq "$(_vpj .lanesRange)" "true"
  _vp_down
}

# A feed that fails says so - "unavailable (404) - retrying" - rather than
# "loading" forever, and the cards around it still draw.
test_dash_v2page_a_failing_feed_is_unavailable_and_the_rest_still_draw() {
  _vp_boot
  local rc=0; V2_MISSING=heat _vp_run missing || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_contains "$(_vpj .heat)" "unavailable (404) - retrying"
  assert_contains "$(_vpj .cycle)" "widget"
  assert_contains "$(_vpj .activity)" "widget#11 merged"
  _vp_down
}

test_dash_v2page_working_now_lists_only_working_and_blocked() {
  _vp_boot
  local rc=0; _vp_run working || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj .working)" "widget-abc-12-colour,gadget-wg-7-beta"
  _vp_down
}

# CEL-108: one Usage card replaces "Usage forecast" and "Claude accounts" -
# summary strip, a group per provider with a bar per window and a pace tick,
# who-uses-it tags, merged pay-as-you-go rows, a row that opens to who used it
# only when the feed could tell, and per-window history when expanded.
test_dash_v2page_usage_card_is_structured_from_the_mockup() {
  _vp_boot
  local rc=0; _vp_run usage || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj .oldCards)" "0"
  assert_eq "$(_vpj .summary)" '1 at risk|1 of 2|2 dry|$22.54'
  assert_eq "$(_vpj .groups)" "claude,codex"
  assert_eq "$(_vpj .bars)" "7"
  assert_eq "$(_vpj .ticks)" "4"
  assert_eq "$(_vpj .amber)" "1"
  assert_eq "$(_vpj .tags)" "orch,workers,workers,not orch"
  assert_eq "$(_vpj .money)" "deepseek · alpha, bundle|openrouter · bundle|openrouter · gadget"
  assert_eq "$(_vpj .offers)" "1"
  assert_contains "$(_vpj .usedBy)" "bundle · luna ×2"
  assert_eq "$(_vpj .overlaySparks)" "2"
  if [ -n "${CEL_DASH_SHOTS:-}" ]; then cp "$T"/shots/usage-*.png "$CEL_DASH_SHOTS"/ 2>/dev/null || true; fi
  _vp_down
}

test_dash_v2page_room_opens_from_the_grid_with_transcript_composer_and_status() {
  _vp_boot
  local rc=0; _vp_run room || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj .opened)" "true"
  assert_eq "$(_vpj .hash)" "#room=alpha-orch"
  assert_eq "$(_vpj .gridHidden)" "true"
  assert_eq "$(_vpj '.kinds | join(",")')" "user,assistant,tool,system,thinking,assistant"
  assert_eq "$(_vpj .toolFolded)" "true"
  assert_contains "$(_vpj .mail)" "widget-abc-12-colour"
  assert_contains "$(_vpj .side)" "working"
  assert_contains "$(_vpj .side)" "gadget-1"
  assert_contains "$(_vpj .side)" "widget-abc-12-colour"
  assert_contains "$(_vpj .side)" "widget#12"
  assert_contains "$(_vpj .side)" "ABC-13-sprocket"
  assert_eq "$(_vpj .decisions)" "2"
  assert_contains "$(_vpj .busyHint)" "when the current turn ends"
  assert_eq "$(_vpj '.acts | length')" "1"
  assert_eq "$(_vpj '.acts[0].action')" "drive.send"
  assert_eq "$(_vpj '.acts[0].target')" "alpha-orch"
  assert_eq "$(_vpj '.acts[0].args.text')" "test: hello alpha"
  assert_eq "$(_vpj .csrf)" "true"
  assert_contains "$(_vpj .receipt)" "in conversation"
  assert_eq "$(_vpj .closed)" "true"
  assert_eq "$(_vpj .hashAfter)" ""
  _vp_down
}

# review of #147 on live data: a repo orchestrator's room showed its
# neighbours' PRs, markdown came out raw, and the grid's decisions chrome
# was repeated in the side panel
test_dash_v2page_room_is_scoped_to_its_repo_renders_markdown_and_lists_decisions_plainly() {
  _vp_boot
  local rc=0; _vp_run room || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj '.repoScope | map(tostring) | join(",")')" "true,false,false"
  assert_eq "$(_vpj .md.strong)" "1"
  assert_eq "$(_vpj .md.code)" "1"
  assert_eq "$(_vpj .md.li)" "2"
  assert_eq "$(_vpj .md.ol)" "2"
  assert_eq "$(_vpj .md.a)" "https://example.invalid/d"
  assert_eq "$(_vpj .md.rawB)" "0"
  assert_eq "$(_vpj .decHeading)" "false"
  assert_eq "$(_vpj '.chipRoom | join(",")')" "bundle-orch"
  _vp_down
}

# CEL-129: live, a product orchestrator's room listed none of its 13 decisions; a
# room loaded from its URL must hold the decisions panel, not the grid
test_dash_v2page_room_opened_from_its_url_lists_its_decisions() {
  _vp_boot
  local rc=0; _vp_run roomdirect || rc=$?; [ "$rc" = 2 ] && { _vp_down; return 0; }; [ "$rc" = 0 ] || return 1
  assert_eq "$(_vpj .decisions)" "2"
  _vp_down
}
