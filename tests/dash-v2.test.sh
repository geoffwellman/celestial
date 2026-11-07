# shellcheck shell=bash
# The dashboard v2 data feeds (/api/v2/*) and its one control door
# (/api/v2/act). Every feed is read against a fixture inbox, sample
# ring and a stub gh that logs its argv - so "one gh pass serves three cards"
# is a line count, not a hope.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/tests/lib/dash-boot.sh"

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
# a launch is only recorded, argument by argument: a test never starts a pane
if [ "\$1" = run ]; then printf '%q ' "\$@" >> "$T/run.log"; printf '\n' >> "$T/run.log"; exit 0; fi
if [ "\$1" = serve ]; then
  case "\$2 \$3" in
    "list --json") printf '[{"name":"widget-preview","owner":"alpha-orch","workspace":"alpha","port":5173,"memory_mb":81,"age_seconds":120,"managed":true}]'; exit 0;;
    "adopt --json") printf '[{"unit":"vite-old","pid":21,"memory_mb":240,"age_seconds":4000,"worktree":"/tmp/demo","managed":false}]'; exit 0;;
  esac
fi
if [ "\$1" = services ]; then
  if [ "\$3" = bundle ]; then printf '[{"name":"gadget-preview","workspace":"bundle","port":8101,"state":"down"}]'
  else printf '[]'; fi
  exit 0
fi
if [ "\$1" = quota ] && [ -f "$T/quota.json" ]; then cat "$T/quota.json"; exit 0; fi
if [ "\$1" = quota ]; then printf '%s' '{"subscriptions":[{"provider":"claude","label":"alpha@example.invalid","windows":[{"name":"5h","scope":null,"used_pct":40,"resets_at":"$(date -u -d '@'$(( $(date +%s) + 9000 )) +%Y-%m-%dT%H:%M:%SZ)"}]}]}'; exit 0; fi
exec "$CEL_ROOT/bin/cel" "\$@"
EOF
  chmod +x "$T/bin/herdr" "$T/bin/gh" "$T/bin/cel"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n  bundle: {path: "%s/bundle"}\n' "$T" "$T" > "$T/registry.yaml"
  printf 'name: alpha\nrepos:\n  - name: widget\n    url: git@example.invalid:alpha/widget.git\n' > "$T/alpha/workspace.yaml"
  printf 'name: bundle\n' > "$T/bundle/workspace.yaml"
  cat >"$T/inbox/alpha.jsonl" <<EOF
{"id":"1000000000000000001","ts":"$(_v2_ago 3000)","to":"alpha-orch","from":"steward","kind":"decision","message":"pick a style"}
{"id":"1000000000000000002","ts":"$(_v2_ago 2000)","to":"root","from":"steward","kind":"resolution","ref":"1000000000000000001","message":"resolved"}
{"id":"1000000000000000003","ts":"$(_v2_ago 1000)","to":"root","from":"steward","kind":"blocked","message":"provider down"}
{"id":"1000000000000000004","ts":"$(_v2_ago 500)","to":"widget-orch","from":"alpha-orch","kind":"status","message":"rebase please"}
EOF
  # the steward's ring: two load samples and a pane's status
  {
    printf '{"ts":"%s","load":1.5,"mem_pct":40,"swap_pct":2,"panes":[{"cwd":"%s/wt/widget-ok","status":"working"}]}\n' "$(_v2_ago 7000)" "$T"
    printf '{"ts":"%s","load":2.5,"mem_pct":50,"swap_pct":3,"panes":[{"cwd":"%s/wt/widget-ok","status":"idle"}]}\n' "$(_v2_ago 600)" "$T"
  } > "$T/state/samples.jsonl"
  export HOME="$T/home" CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_REVIEW_DIR="$T/reviews"
  if [ -n "${_V2_FAIL_GH:-}" ]; then cp "$T/bin/gh" "$T/bin/gh.ok"; printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"; fi
  export CEL_DASH_ACTIVITY_KEEP=5
  export CEL_SAMPLES_FILE="$T/state/samples.jsonl" CEL_DASH_STATE_DIR="$T/state" CEL_DASH_CEL="$T/bin/cel"
  trap '_v2_down' EXIT
  _dash_launch _v2_port "$T/dash.log" \
    "{\"name\":\"alpha\",\"wsdir\":\"$T/alpha\",\"host\":\"127.0.0.1\",\"port\":@PORT@,\"repos\":[{\"name\":\"widget\",\"slug\":\"alpha/widget\"}],\"services\":[]}" \
    "$T/bin:$PATH" || return 1
  local i; for i in $(seq 1 30); do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$DASH_PORT/api/session" && break; sleep 0.3
  done
  TOKEN="$(curl -sf "http://127.0.0.1:$DASH_PORT/api/session" | jq -r .csrfToken)"
}
# the healed ask must see gh's answer, not the degraded one served while a
# slow retry runs: give the retry all the time it needs
_v2_boot_failing_gh() { _V2_FAIL_GH=1 CEL_DASH_DEGRADED_WAIT_MS=20000 CEL_DASH_DEGRADED_RETRY_MS=1 _v2_boot; }
_v2_down() {
  _dash_stop_group "${DASH_PID:-}"
  # the server's CLI children are stopped and joined above; the retry only
  # covers a slow filesystem
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

test_v2_services_feed_includes_ledgered_and_unledgered_preview_memory() {
  _v2_boot
  local rows
  rows="$(_v2_get "$(_v2_url services)")"
  assert_eq "$(printf '%s' "$rows" | jq -r '.items[] | select(.name=="widget-preview") | [.kind,.memory_mb,.owner] | @tsv')" "$(printf 'preview\t81\talpha-orch')"
  assert_eq "$(printf '%s' "$rows" | jq -r '.items[] | select(.name=="vite-old") | [.kind,.memory_mb,.state] | @tsv')" "$(printf 'unledgered\t240\tunledgered')"
  assert_contains "$(cat "$T/cel.log")" "serve list --json"
  assert_contains "$(cat "$T/cel.log")" "serve adopt --json"
  _v2_down
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
  # the retired delegation ledger's kinds are gone
  assert_eq "$(printf '%s' "$a" | jq '[.items[].kind | select(. == "worker" or . == "review")] | length')" "0"
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
  # an open PR that conflicts is the one stuck reason the dashboard can see
  assert_eq "$(printf '%s' "$s" | jq -r '[.items[] | .ref + ":" + .reason] | join(",")')" "widget/ABC-3-clash:merge_conflict"
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

test_v2_load_reads_the_sample_ring() {
  _v2_boot
  local l; l="$(_v2_get "$(_v2_url 'load?hours=24')")"
  assert_eq "$(printf '%s' "$l" | jq -c '[.points[].load]')" "[1.5,2.5]"
  assert_eq "$(printf '%s' "$l" | jq '.threads > 0')" "true"
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
  assert_eq "$(_v2_act '{"action":"message","target":"widget-orch","args":{"ws":"alpha","text":"hello widget","urgent":true,"kind":"ask"}}' -H "x-cel-csrf: $TOKEN")" "200"
  assert_contains "$(jq -r 'select(.to == "widget-orch" and .from == "dashboard") | .message' "$T/inbox/alpha.jsonl")" "[ask] hello widget"
  assert_eq "$(jq -r 'select(.to == "widget-orch" and .from == "dashboard") | .kind' "$T/inbox/alpha.jsonl")" "escalation"
  if grep -q 'prompt\|send-keys\|input' "$T/herdr.argv"; then echo "pane input used" >&2; return 1; fi
  # and the act is in the activity feed
  assert_contains "$(_v2_get "$(_v2_url 'activity?limit=5')" | jq -r '.items[].text')" "message to widget-orch"
  _v2_down
}

test_v2_act_refuses_unknown_action_csrf_and_host() {
  _v2_boot
  local body='{"action":"message","target":"widget-orch","args":{"ws":"alpha","text":"x"}}'
  assert_eq "$(_v2_act '{"action":"rm -rf","target":"x"}' -H "x-cel-csrf: $TOKEN")" "400"
  assert_eq "$(_v2_act "$body")" "403"
  assert_eq "$(_v2_act "$body" -H "x-cel-csrf: $TOKEN" -H 'Host: evil.example')" "403"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "$(_v2_url act)")" "404"
  if jq -e 'select(.to == "widget-orch" and .message == "x")' "$T/inbox/alpha.jsonl" >/dev/null; then
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

# A target is a mailbox somebody reads - a main agent, a solo lane, a live
# reviewer, or root - and a stuck fix's repo is one the workspace declares.
# Anything else would mint a phantom mailbox.
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

# The page names an orchestrator by its agent's alias (cel_alias_norm); the
# act door must accept exactly that name, and the fleet row's solo tag must
# land on it - for a repo or product whose declared name is not already one.
test_v2_orchestrators_are_known_by_their_canonical_alias() {
  _v2_boot
  printf 'name: bundle\nrepos:\n  - name: Gadget.App\n    url: git@example.invalid:bundle/gadget.git\nproducts:\n  - name: Thor Games\n    mode: solo\n    repos: [Gadget.App]\n' > "$T/bundle/workspace.yaml"
  printf '#!/usr/bin/env bash\necho %s\n' "'{\"result\":{\"agents\":[{\"name\":\"gadget-app-orch\",\"agent\":\"omp\",\"agent_status\":\"idle\",\"cwd\":\"$T/bundle\",\"pane_id\":\"w0:p1\"},{\"name\":\"thor-games-orch\",\"agent\":\"omp\",\"agent_status\":\"idle\",\"cwd\":\"$T/bundle\",\"pane_id\":\"w0:p2\"}],\"workspaces\":[]}}'" > "$T/bin/herdr"
  local f; f="$(_v2_get "$(_v2_url 'fleet?ws=bundle')")"
  assert_eq "$(printf '%s' "$f" | jq -r '[.orchestrators[] | .name + ":" + .mode] | sort | join(",")')" "gadget-app-orch:fleet,thor-games-orch:solo"
  local who
  for who in gadget-app-orch thor-games-orch; do
    assert_eq "$(_v2_act "{\"action\":\"message\",\"target\":\"$who\",\"args\":{\"ws\":\"bundle\",\"text\":\"hi $who\"}}" -H "x-cel-csrf: $TOKEN")" "200" \
      || { cat "$T/act.out"; _v2_down; return 1; }
    assert_eq "$(jq -r --arg w "$who" 'select(.to == $w and .from == "dashboard") | .message' "$T/inbox/bundle.jsonl")" "hi $who"
  done
  _v2_down
}

# A solo product, named so its agents' names are cel_alias_norm's and not the
# product's own ("Thor Games" -> thor-games-*): its main agent, two live
# lanes (ui working; api idle, standing on a branch with an open PR), a lane
# made but not running (docs), a reviewer in its review checkout, and three
# panes that only LOOK like one of them - a stranger in a lane's directory, a
# lane whose directory is gone, and a reviewer's name outside any review
# checkout.
_v2_solo_fixture() {
  SOLO="$T/bundle/.cel/solo/Thor Games"
  mkdir -p "$T/bundle/products/Thor Games" "$SOLO/lane-ui" "$SOLO/lane-api" "$SOLO/lane-docs" "$T/gitdirs/api" "$T/reviews/gadget-pr-10"
  printf 'name: bundle\nrepos:\n  - name: gadget\n    url: git@example.invalid:bundle/gadget.git\nproducts:\n  - name: Thor Games\n    mode: solo\n    repos: [gadget]\n' > "$T/bundle/workspace.yaml"
  printf 'gitdir: %s/gitdirs/api\n' "$T" > "$SOLO/lane-api/.git"
  printf 'ref: refs/heads/ABC-4-redo\n' > "$T/gitdirs/api/HEAD"
  jq -n --arg b "$T/bundle" --arg s "$SOLO" --arg r "$T/reviews" '{result: {agents: [
    {name: "thor-games-orch", agent: "omp", agent_status: "working", cwd: ($b + "/products/Thor Games"), pane_id: "w2:p1"},
    {name: "thor-games-ui", agent: "claude", agent_status: "working", cwd: ($s + "/lane-ui"), pane_id: "w2:p2"},
    {name: "thor-games-api", agent: "omp", agent_status: "idle", cwd: ($s + "/lane-api"), pane_id: "w2:p3"},
    {name: "gadget-pr-10-review", agent: "pi", agent_status: "working", cwd: ($r + "/gadget-pr-10"), pane_id: "w2:p4"},
    {name: "intruder", agent: "pi", agent_status: "working", cwd: ($s + "/lane-ui"), pane_id: "w2:p5"},
    {name: "thor-games-old", agent: "pi", agent_status: "working", cwd: ($s + "/lane-old (deleted)"), pane_id: "w2:p6"},
    {name: "gadget-pr-9-review", agent: "pi", agent_status: "working", cwd: ($b + "/../elsewhere/gadget-pr-9"), pane_id: "w2:p7"}],
    workspaces: [], panes: []}}' > "$T/agents.json"
  printf '#!/usr/bin/env bash\ncat %q\n' "$T/agents.json" > "$T/bin/herdr"
}

# Solo agents' and lanes' names do not end -orch: each is
# known by the directory and name cel gave it.
test_v2_solo_fleet_knows_agents_lanes_and_reviewers_by_identity() {
  _v2_boot; _v2_solo_fixture
  local f; f="$(_v2_get "$(_v2_url 'fleet?ws=bundle')")"
  assert_eq "$(printf '%s' "$f" | jq -r '[.orchestrators[] | "\(.name)|\(.mode)|\(.product)|\(.lane // "-")|\(.status)"] | sort | join(",")')" \
    "thor-games-api|solo|Thor Games|api|idle,thor-games-orch|solo|Thor Games|-|working,thor-games-ui|solo|Thor Games|ui|working"
  # where a solo agent's pane stands on a branch, it says so, with that PR
  assert_eq "$(printf '%s' "$f" | jq -r '.orchestrators[] | select(.name == "thor-games-api") | "\(.branch) \(.repo)#\(.pr)"')" "ABC-4-redo gadget#10"
  assert_eq "$(printf '%s' "$f" | jq -r '[.reviewers[] | "\(.name)|\(.repo)#\(.pr)|\(.branch)|\(.status)"] | join(",")')" \
    "gadget-pr-10-review|gadget#10|ABC-4-redo|working"
  # a stranger in a lane's directory, a lane whose directory is gone, or a
  # reviewer's name outside its review checkout, is none of them
  assert_eq "$(printf '%s' "$f" | jq '[.orchestrators[], .reviewers[] | select(.name == "intruder" or .name == "thor-games-old" or .name == "gadget-pr-9-review")] | length')" "0"
  _v2_down
}

# Restart binds the exact agent named: lane B's own command, the product's
# main agent by its product - never the workspace's default orchestrator.
test_v2_solo_restart_binds_the_exact_product_or_lane() {
  _v2_boot; _v2_solo_fixture
  assert_eq "$(_v2_act '{"action":"orch.restart","target":"thor-games-api","args":{"ws":"bundle"}}' -H "x-cel-csrf: $TOKEN")" "200"
  assert_eq "$(_v2_act '{"action":"orch.restart","target":"thor-games-orch","args":{"ws":"bundle"}}' -H "x-cel-csrf: $TOKEN")" "200"
  # a made lane that is not running restarts the same way
  assert_eq "$(_v2_act '{"action":"orch.restart","target":"thor-games-docs","args":{"ws":"bundle"}}' -H "x-cel-csrf: $TOKEN")" "200"
  # a main agent with no product of its own: a declared repo's by --repo, the
  # workspace's own by the workspace alone
  assert_eq "$(_v2_act '{"action":"orch.restart","target":"gadget-orch","args":{"ws":"bundle"}}' -H "x-cel-csrf: $TOKEN")" "200"
  assert_eq "$(_v2_act '{"action":"orch.restart","target":"bundle-orch","args":{"ws":"bundle"}}' -H "x-cel-csrf: $TOKEN")" "200"
  assert_eq "$(cat "$T/run.log")" "$(printf '%s\n' \
    'run solo --workspace bundle --product Thor\ Games --lane api --restart ' \
    'run orchestrator --workspace bundle --product Thor\ Games --restart ' \
    'run solo --workspace bundle --product Thor\ Games --lane docs --restart ' \
    'run orchestrator --workspace bundle --repo gadget --restart ' \
    'run orchestrator --workspace bundle --restart ')"
  # nothing else is restartable: a reviewer, a stranger, a lane the workspace
  # never made, a lane of another workspace
  local who
  for who in gadget-pr-10-review intruder thor-games-nope; do
    assert_eq "$(_v2_act "{\"action\":\"orch.restart\",\"target\":\"$who\",\"args\":{\"ws\":\"bundle\"}}" -H "x-cel-csrf: $TOKEN")" "400"
  done
  assert_eq "$(_v2_act '{"action":"orch.restart","target":"thor-games-api","args":{"ws":"alpha"}}' -H "x-cel-csrf: $TOKEN")" "400"
  assert_eq "$(wc -l < "$T/run.log" | tr -d ' ')" "5"
  _v2_down
}

# A lane's mailbox is one somebody reads - running or not - and so is a live
# reviewer's; a lane-shaped name the workspace never made is not.
test_v2_solo_message_reaches_lanes_and_reviewers() {
  _v2_boot; _v2_solo_fixture
  local who
  for who in thor-games-ui thor-games-docs gadget-pr-10-review; do
    assert_eq "$(_v2_act "{\"action\":\"message\",\"target\":\"$who\",\"args\":{\"ws\":\"bundle\",\"text\":\"hi $who\"}}" -H "x-cel-csrf: $TOKEN")" "200" \
      || { cat "$T/act.out"; return 1; }
    assert_eq "$(jq -r --arg w "$who" 'select(.to == $w and .from == "dashboard") | .message' "$T/inbox/bundle.jsonl")" "hi $who"
  done
  assert_eq "$(_v2_act '{"action":"message","target":"thor-games-nope","args":{"ws":"bundle","text":"x"}}' -H "x-cel-csrf: $TOKEN")" "400"
  assert_eq "$(_v2_act '{"action":"message","target":"intruder","args":{"ws":"bundle","text":"x"}}' -H "x-cel-csrf: $TOKEN")" "400"
  assert_eq "$(_v2_act '{"action":"message","target":"gadget-pr-9-review","args":{"ws":"bundle","text":"x"}}' -H "x-cel-csrf: $TOKEN")" "400"
  _v2_down
}

# A workspace whose product builds solo has its agents at work: each live one
# is a row of its own, from its own pane's samples, the live pane having the
# last word.
test_v2_solo_today_shows_live_agents() {
  _v2_boot; _v2_solo_fixture
  {
    printf '{"ts":"%s","load":1,"mem_pct":40,"swap_pct":2,"panes":[{"cwd":"%s/lane-ui","status":"blocked"}]}\n' "$(_v2_ago 1200)" "$SOLO"
    printf '{"ts":"%s","load":1,"mem_pct":40,"swap_pct":2,"panes":[{"cwd":"%s/lane-ui","status":"working"}]}\n' "$(_v2_ago 300)" "$SOLO"
  } >> "$T/state/samples.jsonl"
  local l; l="$(_v2_get "$(_v2_url 'lanes?range=3d&ws=bundle')")"
  assert_eq "$(printf '%s' "$l" | jq -r '[.workspaces[0].lanes[] | "\(.agent)|\(.kind)|\(.lane // "-")"] | sort | join(",")')" \
    "thor-games-api|lane|api,thor-games-orch|solo|-,thor-games-ui|lane|ui"
  assert_eq "$(printf '%s' "$l" | jq -r '.workspaces[0].lanes[] | select(.agent == "thor-games-ui") | [.segments[].state] | join(",")')" "waiting,running"
  assert_eq "$(printf '%s' "$l" | jq -r '.workspaces[0].lanes[] | select(.agent == "thor-games-api") | "\(.branch)#\(.pr)"')" "ABC-4-redo#10"
  # every live row reaches now, in the live pane's own state
  assert_eq "$(printf '%s' "$l" | jq -r '.now as $now | [.workspaces[0].lanes[] | .segments[-1].to == $now] | all')" "true"
  assert_eq "$(printf '%s' "$l" | jq -r '.workspaces[0].lanes[] | select(.agent == "thor-games-orch") | .segments[-1].state')" "running"
  # and today, the card's own range, shows the active solo agent
  l="$(_v2_get "$(_v2_url 'lanes?range=today&ws=bundle')")"
  assert_eq "$(printf '%s' "$l" | jq -r '[.workspaces[0].lanes[].agent] | index("thor-games-orch") != null')" "true"
  _v2_down
}

# Parallel cold requests share ONE gh fetch, and a failed gh call is not
# cached - the next request tries again.
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

# The dashboard's own action log is a ring, not a growing file.
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

# The fleet feed covers every workspace in scope; a pane in a herdr worktree
# is no agent the dashboard lists (the fan-out workers it named are retired).
test_v2_fleet_lists_orchestrators_and_prs_across_workspaces() {
  _v2_boot
  printf '#!/usr/bin/env bash\necho %s\n' "'{\"result\":{\"agents\":[{\"name\":\"alpha-orch\",\"agent\":\"omp\",\"agent_status\":\"working\",\"cwd\":\"$T/alpha\",\"pane_id\":\"w0:p1\"},{\"name\":\"bundle-orch\",\"agent\":\"omp\",\"agent_status\":\"idle\",\"cwd\":\"$T/bundle\",\"pane_id\":\"w0:p2\"},{\"name\":\"widget-abc-1\",\"agent\":\"pi\",\"agent_status\":\"blocked\",\"cwd\":\"$T/wt/widget-ok\",\"pane_id\":\"w1:p1\"},{\"name\":\"stranger\",\"agent\":\"pi\",\"agent_status\":\"idle\",\"cwd\":\"/elsewhere\",\"pane_id\":\"w9:p1\"}],\"workspaces\":[]}}'" > "$T/bin/herdr"
  local f; f="$(_v2_get "$(_v2_url 'fleet?ws=all')")"
  assert_eq "$(printf '%s' "$f" | jq -r '[.orchestrators[] | .name + "@" + .ws + ":" + .status] | sort | join(",")')" "alpha-orch@alpha:working,bundle-orch@bundle:idle"
  assert_eq "$(printf '%s' "$f" | jq 'has("workers")')" "false"
  assert_eq "$(printf '%s' "$f" | jq -r '[.prs[] | .repo + "#" + (.number|tostring) + "@" + .ws] | sort | join(",")')" "widget#10@alpha,widget#9@alpha"
  assert_eq "$(printf '%s' "$f" | jq -r '.prs[] | select(.number == 10) | .review')" "CHANGES_REQUESTED"
  # one workspace: only its own
  f="$(_v2_get "$(_v2_url 'fleet?ws=bundle')")"
  assert_eq "$(printf '%s' "$f" | jq -r '[.orchestrators[].name] | join(",")')" "bundle-orch"
  assert_eq "$(printf '%s' "$f" | jq '.prs | length')" "0"
  _v2_down
}

# The delegation ledger is retired: a workspace's .cel/delegations.json stays
# on disk but the dashboard never reads it. Its rows would make a worker, a
# lane, activity and usage attribution if anything read them.
_v2_ledger_rows() { # <worktree>
  jq -n --arg wt "$1" --arg at "$(_v2_ago 20000)" '[{id: "ABC-1-widget", repo: "widget", branch: "ABC-1-widget",
    alias: "widget-abc-1", worktree: $wt, state: "running", model: "anthropic/opus", profile: "opus-pi", shape: "ship",
    verdict: "green", review: {verdict: "approved", by: "rev", at: $at}, history: [{state: "running", at: $at, by: "root"}]}]'
}
# /api/state and every v2 feed answer, and none carries a ledger-derived field
_v2_hit_everything_without_the_ledger() { # <worktree>
  printf '#!/usr/bin/env bash\necho %s\n' "'{\"result\":{\"agents\":[{\"name\":\"widget-abc-1\",\"agent\":\"pi\",\"agent_status\":\"working\",\"cwd\":\"$1\",\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\"}],\"workspaces\":[],\"panes\":[]}}'" > "$T/bin/herdr"
  local st; st="$(curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/api/state")" || { echo "/api/state failed"; return 1; }
  assert_eq "$(printf '%s' "$st" | jq -r .workspace)" "alpha" || return 1
  assert_eq "$(printf '%s' "$st" | jq -r '.inflight[] | select(.branch == "ABC-1-widget") | .agent')" "pi" || return 1
  assert_eq "$(printf '%s' "$st" | jq '[.inflight[] | keys[] | select(. == "model" or . == "shape" or . == "why" or . == "verdict")] | length')" "0" || return 1
  local f
  for f in fleet services since activity stuck lanes load merges cycle heat usage; do
    curl -sf -m 20 -o "$T/feed.$f" "$(_v2_url "$f?ws=all")" || { echo "feed $f failed"; return 1; }
  done
  assert_eq "$(_v2_get "$(_v2_url 'snapshot?ws=all')" | jq '[.feeds[] | .v != null] | all and length == 11')" "true" || return 1
  assert_eq "$(jq 'has("workers")' "$T/feed.fleet")" "false" || return 1
  assert_eq "$(jq '[.items[].kind | select(. == "worker" or . == "review")] | length' "$T/feed.activity")" "0" || return 1
  assert_eq "$(jq -r '[.items[].reason] | unique | join(",")' "$T/feed.stuck")" "merge_conflict" || return 1
  assert_eq "$(jq '[.workspaces[].lanes[]] | length' "$T/feed.lanes")" "0" || return 1
  assert_eq "$(jq '[.. | objects | select(has("used_by") or has("profiles"))] | length' "$T/feed.usage")" "0" || return 1
  if grep -q 'anthropic/opus\|opus-pi' "$T"/feed.*; then echo "a ledger row reached a feed"; return 1; fi
}
test_v2_unreadable_ledger_is_never_read() {
  # a pane in a herdr worktree, so /api/state has a worktree row to join onto
  local wt w
  # leg 1: a directory where the ledger was (a reader throws), rows beside it
  _v2_boot
  wt="$T/home/.herdr/worktrees/widget/ABC-1-widget"; mkdir -p "$wt"
  for w in alpha bundle; do
    mkdir -p "$T/$w/.cel/delegations.json"
    _v2_ledger_rows "$wt" > "$T/$w/.cel/delegations.json/rows.json"
  done
  _v2_hit_everything_without_the_ledger "$wt" || { _v2_down; return 1; }
  _v2_down
  # leg 2: a readable ledger of real rows, its atime at the epoch - a read on
  # this relatime filesystem moves it, so it staying 0 is proof nothing read it
  _v2_boot
  wt="$T/home/.herdr/worktrees/widget/ABC-1-widget"; mkdir -p "$wt"
  _v2_ledger_rows "$wt" > "$T/probe"; touch -a -d @0 "$T/probe"; cat "$T/probe" >/dev/null
  [ "$(stat -c %X "$T/probe")" != 0 ] || { echo "this filesystem does not record reads (noatime): the probe proves nothing"; _v2_down; return 1; }
  for w in alpha bundle; do
    mkdir -p "$T/$w/.cel"; _v2_ledger_rows "$wt" > "$T/$w/.cel/delegations.json"
    touch -a -d @0 "$T/$w/.cel/delegations.json"
  done
  _v2_hit_everything_without_the_ledger "$wt" || { _v2_down; return 1; }
  for w in alpha bundle; do
    assert_eq "$(stat -c %X "$T/$w/.cel/delegations.json")" "0" || { echo "$w ledger was read"; _v2_down; return 1; }
  done
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
# workspace's declared services; no per-workspace dashboard rows, and the one
# dashboard is this server - up.
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

# Each service is probed on its own host (the box's servers bind the tailnet
# address, not loopback); the pages server on CEL_PAGES_HOST.
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

# Two simultaneous services requests share one `cel services` run.
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

# --- the usage card's feed --------------------------------------------------
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

# A reading whose reset has passed is a window that is over - the card does
# not flag it, the same rule as the steward's quota_at_risk.
test_v2_usage_does_not_flag_a_window_whose_reset_has_passed() {
  _v2_boot; _v2_quota_fixture
  local past; past="$(date -u -d "@$(( $(date +%s) - 3600 ))" +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg p "$past" '.subscriptions[1].windows[0] |= (.used_pct = 97 | .resets_at = $p)' "$T/quota.json" > "$T/q.json" \
    && mv "$T/q.json" "$T/quota.json"
  local u; u="$(_v2_get "$(_v2_url usage)")"
  assert_eq "$(printf '%s' "$u" | jq -r '[.summary.at_risk[].who] | join(",")')" "ana@alpha.test"
  assert_eq "$(printf '%s' "$u" | jq '.groups[0].accounts[] | select(.who == "ben@alpha.test") | .at_risk')" "false"
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

# A refresh paints from one snapshot of every card's feed, and a
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

# The Needs-you card comes from /api/state, which must be
# warm like the feeds, and before its first answer the page says loading -
# never a count of 0 that reads as "nothing needs you"
test_v2_state_is_served_warm_and_needs_you_never_paints_zero_before_data() {
  _v2_boot
  local a b
  a="$(curl -sf -m 20 -D - -o /dev/null "http://127.0.0.1:$DASH_PORT/api/state" | tr -d '\r' | grep -i '^x-cel-computed-at:' || true)"
  b="$(curl -sf -m 20 -D - -o /dev/null "http://127.0.0.1:$DASH_PORT/api/state" | tr -d '\r' | grep -i '^x-cel-computed-at:' || true)"
  assert_contains "$a" "x-cel-computed-at"
  assert_eq "$b" "$a"
  local html; html="$(curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/")"
  assert_eq "$(printf '%s' "$html" | grep -c 'id="nyc">0<' || true)" "0"
  _v2_down
}

# /api/state asks racing inbox appends all answer 200, and the last answer
# shows the last line.
test_v2_state_asks_racing_inbox_changes_never_fail() {
  _v2_boot
  curl -sf -m 20 -o /dev/null "http://127.0.0.1:$DASH_PORT/api/state"
  local i pids=()
  for i in 1 2 3 4 5 6; do
    printf '{"id":"100000000000000010%s","ts":"%s","to":"root","from":"steward","kind":"status","message":"widget %s"}\n' "$i" "$(_v2_ago 5)" "$i" >> "$T/inbox/alpha.jsonl"
    curl -s -m 20 -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$DASH_PORT/api/state" >> "$T/codes" & pids+=($!)
    sleep 0.05
  done
  wait "${pids[@]}"
  assert_eq "$(sort -u "$T/codes" | tr -d '\n')" "200"
  assert_contains "$(curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/api/state")" "widget 6"
  _v2_down
}

# The merged-PR list is fetched by date, not by count, so a busy repo's oldest
# merges are never dropped.
_v2_gh_merges() { # <count>: a gh that answers <count> merges only to a dated search, 200 otherwise
  local m; m="$(_v2_ago 7200)"
  cat >"$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$*" in *--state\ merged*) ;; *) printf '[]'; exit 0 ;; esac
n=$1; case "\$*" in *merged:\>=*) ;; *) n=200 ;; esac
printf '['; for i in \$(seq 1 \$n); do [ \$i -gt 1 ] && printf ','; printf '{"number":%d,"title":"t","url":"u","headRefName":"b","createdAt":"$m","mergedAt":"$m"}' \$i; done; printf ']'
EOF
  chmod +x "$T/bin/gh"
}
test_v2_merges_counts_a_busy_repo_in_full() {
  _v2_boot
  _v2_gh_merges 250
  sleep 1; : > "$T/gh.log"; kill -USR2 "$DASH_PID"; sleep 0.3
  assert_eq "$(_v2_get "$(_v2_url 'merges?days=14')" | jq '[.days[].counts.widget // 0] | add')" "250"
  assert_contains "$(cat "$T/gh.log")" "merged:>="
  _v2_down
}

# The day boundary is the box's local midnight, in every feed.
test_v2_merges_buckets_by_local_midnight() {
  local tz=Pacific/Auckland y d2 a b
  y="$(TZ=$tz date -d 'yesterday' +%F)"; d2="$(TZ=$tz date -d '2 days ago' +%F)"
  a="$(date -u -d "TZ=\"$tz\" $y 00:30" +%Y-%m-%dT%H:%M:%SZ)"; b="$(date -u -d "TZ=\"$tz\" $d2 23:30" +%Y-%m-%dT%H:%M:%SZ)"
  TZ=$tz _v2_boot
  printf '#!/usr/bin/env bash\ncase "$*" in *--state\\ merged*) printf %%s %s ;; *) printf %%s "[]" ;; esac\n' \
    "'[{\"number\":1,\"title\":\"a\",\"url\":\"u\",\"headRefName\":\"x\",\"createdAt\":\"$b\",\"mergedAt\":\"$a\"},{\"number\":2,\"title\":\"b\",\"url\":\"u\",\"headRefName\":\"y\",\"createdAt\":\"$b\",\"mergedAt\":\"$b\"}]'" > "$T/bin/gh"
  sleep 1; kill -USR2 "$DASH_PID"; sleep 0.3
  local m; m="$(_v2_get "$(_v2_url 'merges?days=14')")"
  assert_eq "$(printf '%s' "$m" | jq --arg d "$y" '.days[] | select(.day==$d) | .counts.widget')" "1"
  assert_eq "$(printf '%s' "$m" | jq --arg d "$d2" '.days[] | select(.day==$d) | .counts.widget')" "1"
  assert_eq "$(printf '%s' "$m" | jq -r '.timezone')" "$tz"
  _v2_down
}

# A boot must end talking to its own server or not at all: a port picked by
# bind-and-close can be taken by a parallel test's server.
test_v2_boot_never_talks_to_a_server_it_did_not_start() {
  local decoy port
  port="$(_v2_port)"
  python3 -c 'import http.server,sys
class H(http.server.BaseHTTPRequestHandler):
  def do_GET(s): s.send_response(200); s.send_header("content-type","application/json"); s.end_headers(); s.wfile.write(b"{\"csrfToken\":\"decoy\"}")
  def log_message(s,*a): pass
http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()' "$port" &
  decoy=$!
  local i; for i in $(seq 1 30); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done
  # the first pick is the decoy's port, as a parallel test's would be
  local first; first="$(mktemp)"
  _v2_port() { if [ ! -s "$first" ]; then echo 1 > "$first"; echo "$port"; else python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; fi; }
  _v2_boot; rm -f "$first"
  kill "$decoy" 2>/dev/null || true; wait "$decoy" 2>/dev/null || true
  if [ "$DASH_PORT" = "$port" ]; then echo "boot kept the decoy's port"; _v2_down; return 1; fi
  if [ "$TOKEN" = decoy ]; then echo "boot took the decoy's token"; _v2_down; return 1; fi
  assert_eq "$(_v2_get "$(_v2_url 'merges?days=14')" | jq '[.days[].counts.widget // 0] | add')" "2"
  _v2_down
}

# A repo the box cannot read is flagged, not counted as 0 merges.
# GitHub's search answers an unreadable repo with an empty list and exit 0, so
# "no merges" has to be checked against the repo itself.
test_v2_merges_flags_an_unreadable_repo() {
  _v2_boot
  cat >"$T/bin/gh" <<'EOF2'
#!/usr/bin/env bash
case "$*" in
  *--search*) printf '[]' ;;
  *) echo "GraphQL: Could not resolve to a Repository with the name 'alpha/widget'. (repository)" >&2; exit 1 ;;
esac
EOF2
  sleep 1; kill -USR2 "$DASH_PID"; sleep 0.3
  assert_eq "$(_v2_get "$(_v2_url 'merges?days=14')" | jq -c '.no_access')" '["widget"]'
  _v2_down
}

# A rate limit or a network blip is not "no access".
test_v2_merges_does_not_call_a_transient_failure_no_access() {
  _v2_boot
  printf '#!/usr/bin/env bash\necho "API rate limit exceeded" >&2\nexit 1\n' > "$T/bin/gh"
  sleep 1; kill -USR2 "$DASH_PID"; sleep 0.3
  local m; m="$(_v2_get "$(_v2_url 'merges?days=14')")"
  assert_eq "$(printf '%s' "$m" | jq -c '.no_access')" '[]'
  assert_eq "$(printf '%s' "$m" | jq -c '.unavailable')" '["widget"]'
  _v2_down
}

# One long ask fetches its own window; it does not widen the shared fetch
# every card uses.
test_v2_a_long_window_ask_does_not_widen_the_shared_fetch() {
  _v2_boot
  sleep 1; : > "$T/gh.log"; kill -USR2 "$DASH_PID"; sleep 0.3
  _v2_get "$(_v2_url 'heat?days=365')" >/dev/null
  _v2_get "$(_v2_url 'merges?days=14')" >/dev/null
  local d365 d90
  d365="$(date -u -d '365 days ago' +%F)"; d90="$(date -u -d '90 days ago' +%F)"
  assert_contains "$(cat "$T/gh.log")" "merged:>=$d365"
  assert_contains "$(cat "$T/gh.log")" "merged:>=$d90"
  : > "$T/gh.log"; kill -USR2 "$DASH_PID"; sleep 0.3
  _v2_get "$(_v2_url 'merges?days=14')" >/dev/null
  assert_eq "$(grep -c -- "merged:>=$d365" "$T/gh.log")" "0"
  _v2_down
}

# ---- the drive routes behind an orchestrator's room ------------------------
# A live orchestrator (alpha-orch) whose session file is a fixture: herdr is
# re-stubbed to name it, so `cel drive` (the real one) resolves it.
_v2_drive_fixture() {
  mkdir -p "$T/sess"
  SESS="$T/sess/alpha-orch.jsonl"
  cat >"$T/bin/herdr" <<EOF2
#!/usr/bin/env bash
case "\$*" in
  "agent list") printf '%s\n' '{"result":{"agents":[{"name":"alpha-orch","agent":"omp","agent_status":"working","cwd":"$T/alpha","pane_id":"w1:p9","agent_session":{"kind":"path","value":"$SESS"}}]}}' ;;
  "pane list") printf '%s\n' '{"result":{"panes":[]}}' ;;
  *) printf '%s\n' '{"result":{"agents":[],"workspaces":[],"panes":[]}}' ;;
esac
EOF2
  chmod +x "$T/bin/herdr"
  # a credential-shaped string, assembled here so no literal is ever committed
  FAKE_SECRET="sk-$(printf 'q%.0s' $(seq 1 24))"
  {
    printf '{"type":"session","id":"s0"}\n'
    printf '{"type":"message","id":"e1","parentId":null,"timestamp":"2026-01-01T10:00:00Z","message":{"role":"user","content":"hello widget"}}\n'
    printf '{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-01-01T10:00:05Z","message":{"role":"assistant","model":"gadget-1","content":[{"type":"text","text":"key is %s"},{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"ls"}}]}}\n' "$FAKE_SECRET"
  } > "$SESS"
}

test_v2_drive_list_and_tail_are_incremental_no_store_and_redacted() {
  _v2_boot; _v2_drive_fixture
  assert_eq "$(_v2_get "$(_v2_url drive/list)" | jq -r '.[0].name')" "alpha-orch"
  curl -s -m 20 -D "$T/h1" -o "$T/t1" "$(_v2_url 'drive/tail?orch=alpha-orch')"
  assert_contains "$(tr -d '\r' < "$T/h1")" "cache-control: no-store"
  assert_eq "$(jq -r '[.events[].kind] | join(",")' "$T/t1")" "user,assistant,tool"
  if grep -q "$FAKE_SECRET" "$T/t1"; then echo "secret leaked into the tail"; return 1; fi
  assert_eq "$(jq -r .last "$T/t1")" "e2"
  assert_eq "$(jq -r .status "$T/t1")" "working"
  assert_eq "$(jq -r .model "$T/t1")" "gadget-1"
  printf '{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-01-01T10:01:00Z","message":{"role":"assistant","content":[{"type":"text","text":"done with beta"}]}}\n' >> "$SESS"
  local t2; t2="$(_v2_get "$(_v2_url 'drive/tail?orch=alpha-orch&since=e2')")"
  assert_eq "$(printf '%s' "$t2" | jq -r '[.events[].text] | join("|")')" "done with beta"
  assert_eq "$(printf '%s' "$t2" | jq -r .reset)" "false"
  # nothing new: nothing sent
  assert_eq "$(_v2_get "$(_v2_url 'drive/tail?orch=alpha-orch&since=e3')" | jq '.events | length')" "0"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "$(_v2_url 'drive/tail?orch=nobody-orch')")" "404"
  _v2_down
}

test_v2_drive_send_needs_csrf_mails_owner_and_has_a_receipt() {
  _v2_boot; _v2_drive_fixture
  local body='{"action":"drive.send","target":"alpha-orch","args":{"text":"test: hello from the room"}}'
  assert_eq "$(_v2_act "$body")" "403"
  assert_eq "$(_v2_act '{"action":"drive.send","target":"nobody-orch","args":{"text":"x"}}' -H "x-cel-csrf: $TOKEN")" "400"
  assert_eq "$(_v2_act "$body" -H "x-cel-csrf: $TOKEN")" "200"
  local id; id="$(jq -r .id "$T/act.out")"
  [ -n "$id" ] && [ "$id" != null ] || { echo "no id: $(cat "$T/act.out")"; return 1; }
  local row; row="$(grep "\"$id\"" "$T/inbox/alpha.jsonl")"
  assert_eq "$(printf '%s' "$row" | jq -r '.to + " " + .from + " " + .kind')" "alpha-orch owner owner"
  assert_eq "$(_v2_get "$(_v2_url "drive/receipt?id=$id")" | jq -r .state)" "queued"
  printf '%s' "$id" > "$T/inbox/alpha.alpha-orch.cursor"
  assert_eq "$(_v2_get "$(_v2_url "drive/receipt?id=$id")" | jq -r .state)" "delivered"
  printf '{"type":"custom_message","id":"e9","parentId":"e2","customType":"cel-inbox","display":true,"content":"[%s] owner: test"}\n' "$id" >> "$SESS"
  assert_eq "$(_v2_get "$(_v2_url "drive/receipt?id=$id")" | jq -r .state)" "in-conversation"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "$(_v2_url 'drive/receipt?id=abc')")" "400"
  # never a pane: nothing typed
  if grep -q 'agent prompt' "$T/cel.log" 2>/dev/null; then echo "typed into a pane"; return 1; fi
  _v2_down
}

# Teardown stops and joins the CLIs the server runs as children (cel quota,
# gh), so none is still writing under $T when the fixture is removed.
test_v2_teardown_stops_and_joins_a_child_the_server_spawned() {
  _v2_boot
  cat >"$T/bin/cel" <<EOS
#!/usr/bin/env bash
if [ "\$1" = quota ]; then
  echo \$\$ > "$T/child.pid"
  sleep 30
  mkdir -p "$T/home/.cache/late" && : > "$T/home/.cache/late/x"
fi
exit 0
EOS
  chmod +x "$T/bin/cel"
  curl -s -m 5 "$(_v2_url 'usage?ws=all')" >/dev/null 2>&1 &
  local i; for i in $(seq 1 50); do [ -s "$T/child.pid" ] && break; sleep 0.1; done
  [ -s "$T/child.pid" ] || { echo "the server never ran the child"; _v2_down; return 1; }
  local pid; pid="$(cat "$T/child.pid")"
  _v2_down
  wait 2>/dev/null || true
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; echo "teardown left the server's child ($pid) running"; return 1; fi
}
