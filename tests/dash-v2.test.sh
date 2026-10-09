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
if [ "\$1" = quota ] && [ -f "$T/quota.json" ]; then cat "$T/quota.json"; exit 0; fi
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
  if [ -n "${_V2_FAIL_GH:-}" ]; then cp "$T/bin/gh" "$T/bin/gh.ok"; printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"; fi
  export CEL_DASH_ACTIVITY_KEEP=5
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
_v2_boot_failing_gh() { _V2_FAIL_GH=1 _v2_boot; }
_v2_down() {
  if [ -n "${DASH_PID:-}" ]; then kill "$DASH_PID" 2>/dev/null || true; wait "$DASH_PID" 2>/dev/null || true; fi
  # a CLI the server spawned can outlive it by a moment and still be writing
  # under $T/home on a loaded box; retry the removal rather than flake
  local i; if [ -n "${T:-}" ]; then for i in 1 2 3 4 5; do rm -rf "$T" 2>/dev/null && break; sleep 0.3; done; rm -rf "$T"; fi
  DASH_PID=""; T=""; trap - EXIT
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
  assert_eq "$(printf '%s' "$m" | jq '[.days[].counts.widget // 0] | add')" "2"
  assert_eq "$(printf '%s' "$m" | jq '.days | length')" "14"
  assert_eq "$(printf '%s' "$c" | jq '.repos[0].prs')" "2"
  # open-to-merge: 10h and ~2.8h -> median of the two
  assert_eq "$(printf '%s' "$c" | jq '.repos[0].median_hours | floor')" "6"
  assert_eq "$(printf '%s' "$h" | jq '[.cells[][]] | add')" "2"
  assert_eq "$(printf '%s' "$h" | jq '.cells | length')" "7"
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
  assert_eq "$(printf '%s' "$f" | jq -r '.accounts[0].who')" "alpha@example.invalid"
  assert_eq "$(printf '%s' "$f" | jq -r '.accounts[0].window')" "5h"
  # 40% used with half the window gone projects to ~80%
  assert_eq "$(printf '%s' "$f" | jq '.accounts[0].projected_pct | . >= 75 and . <= 85')" "true"
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
  assert_eq "$(_v2_act '{"action":"message","target":"widget-abc-1","args":{"ws":"alpha","text":"hello widget","urgent":true,"kind":"ask"}}' -H "x-cel-csrf: $TOKEN")" "200"
  assert_contains "$(jq -r 'select(.to == "widget-abc-1") | .message' "$T/inbox/alpha.jsonl")" "[ask] hello widget"
  assert_eq "$(jq -r 'select(.to == "widget-abc-1" and .from == "dashboard") | .kind' "$T/inbox/alpha.jsonl")" "escalation"
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

# Review on #131: a target is a mailbox somebody reads - a ledger alias, an
# orchestrator the workspace has, or root - and a stuck fix's repo is one the
# workspace declares. Anything else would mint a phantom mailbox.
test_v2_act_refuses_phantom_targets_and_repos() {
  _v2_boot
  assert_eq "$(_v2_act '{"action":"message","target":"nobody-here","args":{"ws":"alpha","text":"x"}}' -H "x-cel-csrf: $TOKEN")" "400"
  assert_eq "$(_v2_act '{"action":"stuck.merge_conflict","target":"gadget/ABC-9-x","args":{"ws":"alpha"}}' -H "x-cel-csrf: $TOKEN")" "400"
  if jq -e 'select(.to == "nobody-here" or .to == "gadget-orch")' "$T/inbox/alpha.jsonl" >/dev/null; then
    echo "phantom mailbox written" >&2; return 1
  fi
  assert_eq "$(_v2_act '{"action":"message","target":"widget-orch","args":{"ws":"alpha","text":"hi orch"}}' -H "x-cel-csrf: $TOKEN")" "200"
  assert_eq "$(_v2_act '{"action":"message","target":"root","args":{"ws":"alpha","text":"hi root"}}' -H "x-cel-csrf: $TOKEN")" "200"
  _v2_down
}

# Review on #131: parallel cold requests share ONE gh fetch, and a failed gh
# call is not cached - the next request tries again.
test_v2_gh_pass_is_shared_in_flight_and_failures_are_not_cached() {
  _v2_boot
  # slow the stub so the four requests overlap while it runs
  sed -i 's|^esac$|esac; sleep 1|' "$T/bin/gh"
  # the boot-time warm-up may already be in flight; let it land, then go cold
  sleep 2; : > "$T/gh.log"; kill -USR2 "$DASH_PID"; sleep 0.3
  local pids=() f
  for f in merges cycle heat merges; do curl -s -m 20 -o /dev/null "$(_v2_url "$f")" & pids+=($!); done
  wait "${pids[@]}"
  assert_eq "$(grep -c -- '--state merged' "$T/gh.log")" "1"
  _v2_down
  # boot with a failing gh (the warm-up fails too), then heal it and ask again
  _v2_boot_failing_gh
  assert_eq "$(curl -sf -m 20 "$(_v2_url merges)" | jq '[.days[].counts.widget // 0] | add')" "0"
  cp "$T/bin/gh.ok" "$T/bin/gh"
  assert_eq "$(curl -sf -m 20 "$(_v2_url merges)" | jq '[.days[].counts.widget // 0] | add')" "2"
  _v2_down
}

# Review on #131: the dashboard's own action log is a ring, not a growing file.
test_v2_activity_log_is_bounded() {
  _v2_boot
  local i
  for i in $(seq 1 8); do
    _v2_act '{"action":"message","target":"root","args":{"ws":"alpha","text":"n'"$i"'"}}' -H "x-cel-csrf: $TOKEN" >/dev/null
  done
  [ "$(wc -l < "$T/state/dash-activity.jsonl")" -le 5 ] || { echo "activity log unbounded: $(wc -l < "$T/state/dash-activity.jsonl")" >&2; return 1; }
  assert_contains "$(tail -1 "$T/state/dash-activity.jsonl")" "message to root"
  _v2_down
}

# --- CEL-106, real-data round ------------------------------------------------
# With "All workspaces" the page showed no orchestrators, no workers and no
# PRs: it read them from the per-workspace /api/state. The fleet feed covers
# every workspace in scope.
test_v2_fleet_lists_orchestrators_workers_and_prs_across_workspaces() {
  _v2_boot
  printf '#!/usr/bin/env bash\necho %s\n' "'{\"result\":{\"agents\":[{\"name\":\"alpha-orch\",\"agent\":\"omp\",\"agent_status\":\"working\",\"cwd\":\"$T/alpha\",\"pane_id\":\"w0:p1\"},{\"name\":\"bundle-orch\",\"agent\":\"omp\",\"agent_status\":\"idle\",\"cwd\":\"$T/bundle\",\"pane_id\":\"w0:p2\"},{\"name\":\"widget-abc-1\",\"agent\":\"pi\",\"agent_status\":\"blocked\",\"cwd\":\"$T/wt/widget-ok\",\"pane_id\":\"w1:p1\"},{\"name\":\"stranger\",\"agent\":\"pi\",\"agent_status\":\"idle\",\"cwd\":\"/elsewhere\",\"pane_id\":\"w9:p1\"}],\"workspaces\":[]}}'" > "$T/bin/herdr"
  local f; f="$(_v2_get "$(_v2_url 'fleet?ws=all')")"
  assert_eq "$(printf '%s' "$f" | jq -r '[.orchestrators[] | .name + "@" + .ws + ":" + .status] | sort | join(",")')" "alpha-orch@alpha:working,bundle-orch@bundle:idle"
  assert_eq "$(printf '%s' "$f" | jq -r '[.workers[] | .name + "@" + .ws + ":" + .status + ":" + .id] | join(",")')" "widget-abc-1@alpha:blocked:ABC-1-widget"
  assert_eq "$(printf '%s' "$f" | jq -r '[.prs[] | .repo + "#" + (.number|tostring) + "@" + .ws] | sort | join(",")')" "widget#10@alpha,widget#9@alpha"
  assert_eq "$(printf '%s' "$f" | jq -r '.prs[] | select(.number == 10) | .review')" "CHANGES_REQUESTED"
  # one workspace: only its own
  f="$(_v2_get "$(_v2_url 'fleet?ws=bundle')")"
  assert_eq "$(printf '%s' "$f" | jq -r '[.orchestrators[].name] | join(",")')" "bundle-orch"
  assert_eq "$(printf '%s' "$f" | jq '.prs | length')" "0"
  _v2_down
}

# Lanes were amber all day: stale ledger rows (a "running" nobody has touched
# in weeks, finished work) each drew one segment over the whole window, and
# every non-running state read as "waiting". Only work active in the range
# shows; finished is not waiting; an open-ended "running" with no live pane
# is not running now.
test_v2_lanes_show_only_live_work_and_never_call_finished_waiting() {
  _v2_boot
  local l; l="$(_v2_get "$(_v2_url 'lanes?range=3d')")"
  local refs; refs="$(printf '%s' "$l" | jq -r '[.workspaces[].lanes[].ref] | join(",")')"
  assert_eq "$refs" "widget/ABC-1-widget"
  assert_eq "$(printf '%s' "$l" | jq '[.workspaces[].lanes[].segments[] | select(.state == "waiting")] | length')" "0"
  _v2_down
}

# A box whose steward has not sampled yet: the feed says since when it is
# collecting, and carries the box's current CPU, memory and swap regardless.
test_v2_load_without_samples_says_collecting_and_has_current() {
  _v2_boot
  rm -f "$T/state/samples.jsonl"
  local l; l="$(_v2_get "$(_v2_url 'load?hours=24')")"
  assert_eq "$(printf '%s' "$l" | jq '.points | length')" "0"
  assert_eq "$(printf '%s' "$l" | jq '.collecting_since | type')" '"string"'
  assert_eq "$(printf '%s' "$l" | jq '(.current.load|type) == "number" and (.current.mem_pct|type) == "number" and (.current.swap_pct|type) == "number"')" "true"
  _v2_down
}

# Running services: the box's own (pages, the one dashboard) beside every
# workspace's declared services. One dashboard for the box (CEL-107): no
# per-workspace dashboard rows, and the one there is is this server - up.
test_v2_services_lists_box_and_workspace_services() {
  _v2_boot
  printf 'name: bundle\ndash:\n  port: 1\nservices:\n  - name: gadget-preview\n    url: http://127.0.0.1:2\n' > "$T/bundle/workspace.yaml"
  local s; s="$(_v2_get "$(_v2_url 'services?ws=all')")"
  local names; names="$(printf '%s' "$s" | jq -r '[.items[] | .name + "@" + .ws] | join(",")')"
  assert_contains "$names" "pages@box"
  assert_contains "$names" "dashboard@box"
  assert_contains "$names" "gadget-preview@bundle"
  assert_eq "$(printf '%s' "$s" | jq -r '[.items[] | select(.name | startswith("dashboard "))] | length')" "0"
  assert_eq "$(printf '%s' "$s" | jq -r '.items[] | select(.name == "dashboard") | .state')" "up"
  s="$(_v2_get "$(_v2_url 'services?ws=bundle')")"
  assert_eq "$(printf '%s' "$s" | jq -r '[.items[] | select(.ws == "alpha")] | length')" "0"
  _v2_down
}

# The box's servers bind the tailnet address, not loopback; a probe of
# 127.0.0.1 called every one of them down. The pages server is probed on its
# own CEL_PAGES_HOST.
test_v2_services_probe_each_service_on_its_own_host() {
  _v2_boot
  local p2; p2="$(_v2_port)"
  python3 -c "import socket,time;t=socket.socket();t.bind(('127.0.0.3',$p2));t.listen();time.sleep(60)" &
  local lp=$!
  sleep 0.5
  kill "$DASH_PID"; wait "$DASH_PID" 2>/dev/null || true
  CEL_PAGES_PORT="$p2" CEL_PAGES_HOST=127.0.0.3 CEL_DASH_CONFIG="{\"name\":\"alpha\",\"wsdir\":\"$T/alpha\",\"host\":\"127.0.0.1\",\"port\":$DASH_PORT,\"repos\":[{\"name\":\"widget\",\"slug\":\"alpha/widget\"}],\"services\":[]}" \
    PATH="$T/bin:$PATH" node "$CEL_ROOT/tools/dash/server.mjs" >"$T/dash.log" 2>&1 &
  DASH_PID=$!
  local i; for i in $(seq 1 30); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$DASH_PORT/api/session" && break; sleep 0.3; done
  local s; s="$(_v2_get "$(_v2_url 'services?ws=all')")"
  kill "$lp" 2>/dev/null || true
  assert_eq "$(printf '%s' "$s" | jq -r '.items[] | select(.name == "pages") | .state')" "up"
  _v2_down
}

# Review on #132: the services feed ran `cel services` per workspace on every
# poll of every tab. Two requests at once share one run.
test_v2_services_two_simultaneous_requests_run_cel_services_once() {
  _v2_boot
  : > "$T/cel.log"
  _v2_get "$(_v2_url 'services?ws=alpha')" > "$T/a.json" &
  local a=$!
  _v2_get "$(_v2_url 'services?ws=alpha')" > "$T/b.json" &
  wait "$a" $!
  assert_eq "$(grep -c '^services --workspace alpha' "$T/cel.log")" "1"
  assert_eq "$(jq -r '[.items[].name] | index("pages") != null' "$T/a.json")" "true"
  assert_eq "$(jq -r '[.items[].name] | index("pages") != null' "$T/b.json")" "true"
  _v2_down
}

# --- CEL-108: the usage card's feed ------------------------------------------
# One feed for the one card: subscriptions grouped by provider with every
# window projected to its reset, who runs on each account (omp's pool for the
# orchestrators, the gateway's vault for workers), and the pay-as-you-go
# balances with two workspaces on one key merged into one row.
_v2_quota_fixture() {
  local r2 r5
  r2="$(date -u -d "@$(( $(date +%s) + 172800 ))" +%Y-%m-%dT%H:%M:%SZ)"
  r5="$(date -u -d "@$(( $(date +%s) + 9000 ))" +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg r2 "$r2" --arg r5 "$r5" '{
    subscriptions: [
      {provider: "claude", account: "ant-ana", label: "ana@alpha.test", source: "omp",
       windows: [{name: "5h", scope: null, used_pct: 6, resets_at: $r5},
                 {name: "7d", scope: null, used_pct: 80, resets_at: $r2},
                 {name: "7d", scope: "Fable", used_pct: 0, resets_at: $r2}]},
      {provider: "claude", account: "ant-ben", label: "ben@alpha.test", source: "omp",
       windows: [{name: "7d", scope: null, used_pct: 20, resets_at: $r2}]},
      {provider: "codex", account: "cx-ana", label: "ana@alpha.test", source: "omp",
       windows: [{name: "7d", scope: null, used_pct: 10, resets_at: $r2}]}],
    balances: [
      {provider: "openrouter", workspace: "alpha", remaining: "-0.11", state: "ok", floor: "2", unit: "usd", account: "aaaaaaaaaaaa", vetoed: true},
      {provider: "openrouter", workspace: "bundle", remaining: "-0.11", state: "ok", floor: "2", unit: "usd", account: "aaaaaaaaaaaa", vetoed: true},
      {provider: "deepseek", workspace: "alpha", remaining: "22.54", state: "ok", floor: "1", unit: "usd", account: "bbbbbbbbbbbb", vetoed: false}],
    orch_pool: {live: ["ana@alpha.test"], disabled: ["ben@alpha.test"]},
    gateway: ["claude|ana@alpha.test", "claude|ben@alpha.test"]}' > "$T/quota.json"
  # one worker this week on a codex model, so that account can say who used it
  jq '.[0].profile = "luna" | .[0].model = "gpt-6"' "$T/alpha/.cel/delegations.json" > "$T/d.json" \
    && mv "$T/d.json" "$T/alpha/.cel/delegations.json"
}

test_v2_usage_groups_by_provider_and_tags_who_runs_on_each_account() {
  _v2_boot; _v2_quota_fixture
  local u; u="$(_v2_get "$(_v2_url 'usage?ws=all')")"
  assert_eq "$(printf '%s' "$u" | jq -r '[.groups[].provider] | join(",")')" "claude,codex"
  assert_eq "$(printf '%s' "$u" | jq -r '.groups[0].accounts | length')" "2"
  assert_eq "$(printf '%s' "$u" | jq -r '.groups[0].accounts[] | select(.who == "ana@alpha.test") | .tags | join(",")')" "orch,workers"
  assert_eq "$(printf '%s' "$u" | jq -r '.groups[0].accounts[] | select(.who == "ben@alpha.test") | .tags | join(",")')" "workers,not orch"
  assert_eq "$(printf '%s' "$u" | jq -r '.summary.orch.serving, .summary.orch.of' | paste -sd/)" "1/2"
  # a scoped window is its own bar, labelled by its scope
  assert_contains "$(printf '%s' "$u" | jq -r '[.groups[0].accounts[0].windows[].label] | join(",")')" "Fable week"
  _v2_down
}

test_v2_usage_projects_each_window_and_flags_the_account_at_risk() {
  _v2_boot; _v2_quota_fixture
  local u; u="$(_v2_get "$(_v2_url usage)")"
  # 80% with 5 of 7 days gone is ~112% at reset
  assert_eq "$(printf '%s' "$u" | jq '.groups[0].accounts[0].windows[] | select(.label == "Week") | .projected_pct >= 100')" "true"
  assert_eq "$(printf '%s' "$u" | jq -r '[.summary.at_risk[].who] | join(",")')" "ana@alpha.test"
  assert_eq "$(printf '%s' "$u" | jq -r '.groups[0].accounts[0].windows[] | select(.label == "Week") | .level')" "warn"
  _v2_down
}

test_v2_usage_merges_a_shared_balance_and_counts_below_floor() {
  _v2_boot; _v2_quota_fixture
  local u; u="$(_v2_get "$(_v2_url 'usage?ws=all')")"
  assert_eq "$(printf '%s' "$u" | jq -r '.balances[] | select(.provider == "openrouter") | .workspaces | join(",")')" "alpha,bundle"
  assert_eq "$(printf '%s' "$u" | jq '.balances | length')" "2"
  assert_eq "$(printf '%s' "$u" | jq '.summary.below_floor')" "1"
  assert_eq "$(printf '%s' "$u" | jq '.summary.funded')" "22.54"
  # the filter narrows balances; subscriptions are the box's and always shown
  u="$(_v2_get "$(_v2_url 'usage?ws=bundle')")"
  assert_eq "$(printf '%s' "$u" | jq -r '[.balances[].provider] | join(",")')" "openrouter"
  assert_eq "$(printf '%s' "$u" | jq '.groups | length')" "2"
  _v2_down
}

test_v2_usage_says_who_used_an_account_only_when_it_can_tell() {
  _v2_boot; _v2_quota_fixture
  local u; u="$(_v2_get "$(_v2_url 'usage?ws=all')")"
  # one codex account: the ledger's codex-model work is that account's
  assert_eq "$(printf '%s' "$u" | jq -c '.groups[1].accounts[0].used_by')" '[{"ws":"alpha","profile":"luna","n":1}]'
  # two claude accounts behind one gateway: no way to split it, so no offer
  assert_eq "$(printf '%s' "$u" | jq -c '[.groups[0].accounts[].used_by]')" '[null,null]'
  _v2_down
}

# CEL-116: a refresh paints from one snapshot of every card's feed, and a
# feed answered from the warm cache says when it was computed
test_v2_snapshot_carries_every_card_feed_with_its_age() {
  _v2_boot
  local s; s="$(_v2_get "$(_v2_url 'snapshot?ws=all')")"
  local f
  for f in fleet services since activity stuck lanes load merges cycle heat usage; do
    assert_eq "$(printf '%s' "$s" | jq --arg f "$f" '.feeds[$f].v != null')" "true"
    assert_eq "$(printf '%s' "$s" | jq --arg f "$f" '.feeds[$f].at | test("^[0-9]{4}-")')" "true"
  done
  # the snapshot is what the feed itself answers, shape for shape
  assert_eq "$(printf '%s' "$s" | jq '.feeds.merges.v.days | length')" "14"
  local h; h="$(curl -sf -m 20 -D - -o /dev/null "$(_v2_url 'heat?ws=all')" | tr -d '\r' | grep -i '^x-cel-computed-at:' || true)"
  assert_contains "$h" "x-cel-computed-at"
  _v2_down
}

# a second request for a computed feed is served from the cache - the inbox
# is not re-parsed per request - yet a new inbox line still shows up
test_v2_feed_cache_serves_warm_and_sees_new_mail() {
  _v2_boot
  _v2_get "$(_v2_url 'activity?limit=50')" >/dev/null
  printf '{"id":"1000000000000000009","ts":"%s","to":"root","from":"steward","kind":"blocked","message":"gadget wedged"}\n' "$(_v2_ago 10)" >> "$T/inbox/alpha.jsonl"
  local i a=""; for i in $(seq 1 20); do
    a="$(_v2_get "$(_v2_url 'activity?limit=50')")"
    printf '%s' "$a" | grep -q 'gadget wedged' && break; sleep 0.3
  done
  assert_contains "$a" "gadget wedged"
  _v2_down
}
