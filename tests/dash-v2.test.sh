# shellcheck shell=bash
# CEL-105: the dashboard v2 data feeds (/api/v2/*) and its one control door
# (/api/v2/act). Every feed is read against a fixture ledger, inbox, sample
# ring and a stub gh that logs its argv - so "one gh pass serves three cards"
# is a line count, not a hope.
source "$CEL_ROOT/lib/common.sh"

_v2_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
_v2_ago() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

_v2_boot() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/alpha/.cel" "$T/bundle" "$T/inbox" "$T/home" "$T/state"
  printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"result\":{\"agents\":[{\"agent\":\"pi\",\"agent_status\":\"idle\",\"cwd\":\"$T/wt/widget-ok\",\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\"}],\"workspaces\":[],\"panes\":[]}}'" > "$T/bin/herdr"
  local m1 m2 c1 c2
  m1="$(_v2_ago 7200)"; c1="$(_v2_ago 43200)"; m2="$(_v2_ago 90000)"; c2="$(_v2_ago 100000)"
  cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$*" in
  *--state\ merged*) printf '[{"number":7,"title":"add widget","url":"https://example.invalid/pr/7","headRefName":"ABC-1-widget","createdAt":"$c1","mergedAt":"$m1"},{"number":6,"title":"gadget fix","url":"https://example.invalid/pr/6","headRefName":"ABC-2-gadget","createdAt":"$c2","mergedAt":"$m2"}]' ;;
  *--state\ open*) printf '[{"number":9,"title":"clash","url":"https://example.invalid/pr/9","headRefName":"ABC-3-clash","mergeable":"CONFLICTING","reviewDecision":"","updatedAt":"$m1"},{"number":10,"title":"redo","url":"https://example.invalid/pr/10","headRefName":"ABC-4-redo","mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","updatedAt":"$m1"}]' ;;
  *) printf '[]' ;;
esac
EOF
  # cel itself, except quota, which would read the live accounts
  cat >"$T/bin/cel" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/cel.log"
if [ "\$1" = quota ]; then printf '%s' '{"subscriptions":[{"provider":"claude","label":"alpha@example.invalid","windows":[{"name":"5h","scope":null,"used_pct":40,"resets_at":"$(date -u -d '@'$(( $(date +%s) + 9000 )) +%Y-%m-%dT%H:%M:%SZ)"}]}]}'; exit 0; fi
exec "$CEL_ROOT/bin/cel" "\$@"
EOF
  chmod +x "$T/bin/herdr" "$T/bin/gh" "$T/bin/cel"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n  bundle: {path: "%s/bundle"}\n' "$T" "$T" > "$T/registry.yaml"
  printf 'name: alpha\nrepos:\n  - name: widget\n    url: git@example.invalid:alpha/widget.git\n' > "$T/alpha/workspace.yaml"
  printf 'name: bundle\n' > "$T/bundle/workspace.yaml"
  local old; old="$(_v2_ago 1900000)"
  cat >"$T/alpha/.cel/delegations.json" <<EOF
[
 {"id":"ABC-1-widget","repo":"widget","branch":"ABC-1-widget","alias":"widget-abc-1","worktree":"$T/wt/widget-ok","state":"running",
  "history":[{"state":"running","at":"$(_v2_ago 20000)","by":"root"}]},
 {"id":"ABC-5-approved","repo":"widget","branch":"ABC-5-approved","alias":"widget-abc-5","worktree":"$T/wt/x","state":"finished",
  "review":{"verdict":"approved","by":"rev","at":"$(_v2_ago 400000)"},
  "history":[{"state":"running","at":"$(_v2_ago 500000)","by":"root"},{"state":"finished","at":"$(_v2_ago 450000)","by":"root"}]},
 {"id":"ABC-6-quiet","repo":"widget","branch":"ABC-6-quiet","alias":"widget-abc-6","worktree":"$T/wt/q","state":"running",
  "history":[{"state":"running","at":"$old","by":"root"}]}
]
EOF
  cat >"$T/inbox/alpha.jsonl" <<EOF
{"id":"1000000000000000001","ts":"$(_v2_ago 3000)","to":"alpha-orch","from":"steward","kind":"decision","message":"pick a style"}
{"id":"1000000000000000002","ts":"$(_v2_ago 2000)","to":"root","from":"steward","kind":"resolution","ref":"1000000000000000001","message":"resolved"}
{"id":"1000000000000000003","ts":"$(_v2_ago 1000)","to":"root","from":"steward","kind":"blocked","message":"provider down"}
{"id":"1000000000000000004","ts":"$(_v2_ago 500)","to":"widget-abc-1","from":"alpha-orch","kind":"status","message":"rebase please"}
EOF
  # the steward's ring: two load samples and the worker's pane status
  {
    printf '{"ts":"%s","load":1.5,"mem_pct":40,"swap_pct":2,"panes":[{"cwd":"%s/wt/widget-ok","status":"working"}]}\n' "$(_v2_ago 7000)" "$T"
    printf '{"ts":"%s","load":2.5,"mem_pct":50,"swap_pct":3,"panes":[{"cwd":"%s/wt/widget-ok","status":"idle"}]}\n' "$(_v2_ago 600)" "$T"
  } > "$T/state/samples.jsonl"
  export HOME="$T/home" CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox"
  export CEL_SAMPLES_FILE="$T/state/samples.jsonl" CEL_DASH_STATE_DIR="$T/state" CEL_DASH_CEL="$T/bin/cel"
  DASH_PORT="$(_v2_port)"
  CEL_DASH_CONFIG="{\"name\":\"alpha\",\"wsdir\":\"$T/alpha\",\"host\":\"127.0.0.1\",\"port\":$DASH_PORT,\"repos\":[{\"name\":\"widget\",\"slug\":\"alpha/widget\"}],\"services\":[]}" \
    PATH="$T/bin:$PATH" node "$CEL_ROOT/tools/dash/server.mjs" >"$T/dash.log" 2>&1 &
  DASH_PID=$!
  trap '_v2_down' EXIT
  local i; for i in $(seq 1 30); do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$DASH_PORT/api/session" && break; sleep 0.3
  done
  TOKEN="$(curl -sf "http://127.0.0.1:$DASH_PORT/api/session" | jq -r .csrfToken)"
}
_v2_down() {
  if [ -n "${DASH_PID:-}" ]; then kill "$DASH_PID" 2>/dev/null || true; wait "$DASH_PID" 2>/dev/null || true; fi
  DASH_PID=""; if [ -n "${T:-}" ]; then rm -rf "$T"; fi; T=""; trap - EXIT
}
_v2_get() { curl -sf -m 20 "$@"; }
_v2_url() { printf 'http://127.0.0.1:%s/api/v2/%s' "$DASH_PORT" "$1"; }
_v2_act() { # <body> [extra curl args...]
  local b="$1"; shift
  curl -s -m 20 -o "$T/act.out" -w '%{http_code}' -X POST -H 'content-type: application/json' "$@" \
    -d "$b" "$(_v2_url act)"
}

test_v2_one_gh_pass_serves_merges_cycle_and_heat() {
  _v2_boot
  local m c h
  m="$(_v2_get "$(_v2_url 'merges?days=14')")"
  c="$(_v2_get "$(_v2_url cycle)")"
  h="$(_v2_get "$(_v2_url heat)")"
  assert_eq "$(printf '%s' "$m" | jq '[.days[].repos.widget // 0] | add')" "2"
  assert_eq "$(printf '%s' "$m" | jq '.days | length')" "14"
  assert_eq "$(printf '%s' "$c" | jq '.repos.widget.n')" "2"
  # open-to-merge: 10h and ~2.8h -> median of the two
  assert_eq "$(printf '%s' "$c" | jq '.repos.widget.median_hours | floor')" "6"
  assert_eq "$(printf '%s' "$h" | jq '[.grid[][]] | add')" "2"
  assert_eq "$(printf '%s' "$h" | jq '.grid | length')" "7"
  assert_eq "$(grep -c -- '--state merged' "$T/gh.log")" "1"
  _v2_down
}

test_v2_activity_is_newest_first_and_paged() {
  _v2_boot
  local a; a="$(_v2_get "$(_v2_url 'activity?limit=50')")"
  local kinds; kinds="$(printf '%s' "$a" | jq -r '[.items[].kind] | unique | join(",")')"
  assert_contains "$kinds" "merge"
  assert_contains "$kinds" "decision"
  assert_contains "$kinds" "incident"
  assert_contains "$kinds" "worker"
  assert_contains "$kinds" "review"
  # sorted newest first
  assert_eq "$(printf '%s' "$a" | jq '[.items[].ts] == ([.items[].ts] | sort | reverse)')" "true"
  local first before p2
  first="$(_v2_get "$(_v2_url 'activity?limit=2')")"
  assert_eq "$(printf '%s' "$first" | jq '.items | length')" "2"
  before="$(printf '%s' "$first" | jq -r '.items[1].ts')"
  p2="$(_v2_get "$(_v2_url "activity?limit=2&before=$before")")"
  assert_eq "$(printf '%s' "$p2" | jq --arg b "$before" '[.items[].ts < $b] | all')" "true"
  _v2_down
}

test_v2_stuck_names_real_reasons_with_named_fixes() {
  _v2_boot
  local s; s="$(_v2_get "$(_v2_url stuck)")"
  local reasons; reasons="$(printf '%s' "$s" | jq -r '[.items[].reason] | sort | join(",")')"
  assert_contains "$reasons" "approved_not_landed"
  assert_contains "$reasons" "merge_conflict"
  assert_contains "$reasons" "changes_no_worker"
  assert_contains "$reasons" "idle_with_mail"
  assert_contains "$reasons" "no_activity"
  # a fix is an action NAME, never a command line
  assert_eq "$(printf '%s' "$s" | jq '[.items[].fix.action | test("^stuck\\.[a-z_]+$")] | all')" "true"
  _v2_down
}

test_v2_since_counts_and_seen_is_per_browser_cookie() {
  _v2_boot
  local at s; at="$(_v2_ago 86400)"
  s="$(_v2_get "$(_v2_url "since?at=$at")")"
  assert_eq "$(printf '%s' "$s" | jq -c '.counts | [.merged, .decisions_new, .decisions_closed, .incidents]')" "[1,1,1,1]"
  assert_contains "$(printf '%s' "$s" | jq -r .at)" "${at%Z}"
  # no ?at: the server remembers when THIS cookie last looked
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  assert_eq "$(curl -s -m 20 -o /dev/null -w '%{http_code}' -c "$T/jar" -b "$T/jar" -X POST \
    -H 'content-type: application/json' -H "x-cel-csrf: $TOKEN" "$(_v2_url seen)")" "200"
  s="$(curl -sf -m 20 -b "$T/jar" "$(_v2_url since)")"
  assert_eq "$(printf '%s' "$s" | jq '.counts.merged')" "0"
  [ "$(printf '%s' "$s" | jq -r .at)" \> "$(_v2_ago 120)" ] || { echo "seen not stored: $s" >&2; return 1; }
  # a different browser has its own mark
  s="$(_v2_get "$(_v2_url since)")"
  [ "$(printf '%s' "$s" | jq -r .at)" \< "$now" ] || { echo "cookie leaked: $s" >&2; return 1; }
  _v2_down
}

test_v2_lanes_from_ledger_and_samples() {
  _v2_boot
  local l; l="$(_v2_get "$(_v2_url 'lanes?range=3d')")"
  assert_eq "$(printf '%s' "$l" | jq -r '.workspaces[0].ws')" "alpha"
  local lane; lane="$(printf '%s' "$l" | jq -c '.workspaces[0].lanes[] | select(.ref == "widget/ABC-1-widget")')"
  assert_contains "$(printf '%s' "$lane" | jq -r '[.segments[].state] | join(",")')" "running"
  assert_contains "$(printf '%s' "$lane" | jq -r '[.segments[].state] | join(",")')" "idle"
  assert_eq "$(printf '%s' "$l" | jq '.start < .now and .now <= .end')" "true"
  _v2_down
}

test_v2_load_reads_the_sample_ring() {
  _v2_boot
  local l; l="$(_v2_get "$(_v2_url 'load?hours=24')")"
  assert_eq "$(printf '%s' "$l" | jq -c '[.points[].load]')" "[1.5,2.5]"
  assert_eq "$(printf '%s' "$l" | jq '.threads > 0')" "true"
  _v2_down
}

test_v2_forecast_projects_quota_to_reset() {
  _v2_boot
  local f; f="$(_v2_get "$(_v2_url forecast)")"
  assert_eq "$(printf '%s' "$f" | jq -r '.items[0].who')" "alpha@example.invalid"
  assert_eq "$(printf '%s' "$f" | jq -r '.items[0].window')" "5h"
  # 40% used with half the window gone projects to ~80%
  assert_eq "$(printf '%s' "$f" | jq '.items[0].projected_pct | . >= 75 and . <= 85')" "true"
  _v2_down
}

test_v2_ws_all_spans_the_registry() {
  _v2_boot
  local l; l="$(_v2_get "$(_v2_url 'lanes?range=today&ws=all')")"
  assert_eq "$(printf '%s' "$l" | jq -r '[.workspaces[].ws] | join(",")')" "alpha,bundle"
  assert_eq "$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$(_v2_url 'stuck?ws=nosuch')")" "400"
  _v2_down
}

test_v2_act_message_goes_to_the_inbox_never_a_pane() {
  _v2_boot
  : > "$T/herdr.argv"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %s/herdr.argv\nprintf "{}"\n' "$T" > "$T/bin/herdr"
  assert_eq "$(_v2_act '{"action":"message","target":"widget-abc-1","args":{"ws":"alpha","text":"hello widget"}}' -H "x-cel-csrf: $TOKEN")" "200"
  assert_contains "$(jq -r 'select(.to == "widget-abc-1") | .message' "$T/inbox/alpha.jsonl")" "hello widget"
  if grep -q 'prompt\|send-keys\|input' "$T/herdr.argv"; then echo "pane input used" >&2; return 1; fi
  # and the act is in the activity feed
  assert_contains "$(_v2_get "$(_v2_url 'activity?limit=5')" | jq -r '.items[].text')" "message to widget-abc-1"
  _v2_down
}

test_v2_act_refuses_unknown_action_csrf_and_host() {
  _v2_boot
  local body='{"action":"message","target":"widget-abc-1","args":{"ws":"alpha","text":"x"}}'
  assert_eq "$(_v2_act '{"action":"rm -rf","target":"x"}' -H "x-cel-csrf: $TOKEN")" "400"
  assert_eq "$(_v2_act "$body")" "403"
  assert_eq "$(_v2_act "$body" -H "x-cel-csrf: $TOKEN" -H 'Host: evil.example')" "403"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "$(_v2_url act)")" "404"
  if jq -e 'select(.to == "widget-abc-1" and .message == "x")' "$T/inbox/alpha.jsonl" >/dev/null; then
    echo "a refused act was delivered" >&2; return 1
  fi
  _v2_down
}

test_v2_stuck_fix_mails_the_owning_orchestrator() {
  _v2_boot
  assert_eq "$(_v2_act '{"action":"stuck.merge_conflict","target":"widget/ABC-3-clash","args":{"ws":"alpha"}}' -H "x-cel-csrf: $TOKEN")" "200"
  assert_contains "$(jq -r 'select(.to == "widget-orch") | .message' "$T/inbox/alpha.jsonl")" "ABC-3-clash"
  assert_eq "$(_v2_act '{"action":"stuck.bogus","target":"widget/x","args":{"ws":"alpha"}}' -H "x-cel-csrf: $TOKEN")" "400"
  _v2_down
}

test_v2_existing_state_still_answers() {
  _v2_boot
  assert_eq "$(_v2_get "http://127.0.0.1:$DASH_PORT/api/state" | jq -r .workspace)" "alpha"
  _v2_down
}

test_steward_sample_appends_and_trims_the_ring() {
  local t; t="$(mktemp -d)"
  mkdir -p "$t/bin"
  printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"result\":{\"agents\":[{\"cwd\":\"/w/a\",\"agent_status\":\"working\"}]}}'" > "$t/bin/herdr"
  chmod +x "$t/bin/herdr"
  ( export CEL_SAMPLES_FILE="$t/s.jsonl" CEL_SAMPLES_KEEP=3 PATH="$t/bin:$PATH"
    source "$CEL_ROOT/lib/steward.sh"
    local agents; agents="$(herdr agent list)"
    for _ in 1 2 3 4 5; do _steward_sample "$agents"; done )
  assert_eq "$(wc -l < "$t/s.jsonl" | tr -d ' ')" "3"
  assert_eq "$(tail -1 "$t/s.jsonl" | jq -r '.panes[0].status')" "working"
  assert_eq "$(tail -1 "$t/s.jsonl" | jq '(.load|type) == "number" and (.mem_pct|type) == "number"')" "true"
  rm -rf "$t"
}
