# shellcheck shell=bash
# The dashboard's Needs-you panel answers owner decisions through the
# real `cel decide`, behind the dashboard's Host and CSRF guard.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/tests/lib/dash-boot.sh"
# every question needs real context
DD_CTX="The widget build broke after the alpha merge and the beta release waits on it. Option one ships today with a known gap; option two waits a day. I recommend one; if nobody answers, beta slips."

_dd_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

_dd_boot() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/alpha" "$T/inbox" "$T/home"
  printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"result\":{\"agents\":[],\"workspaces\":[],\"panes\":[]}}'" > "$T/bin/herdr"
  printf '#!/usr/bin/env bash\nprintf "[]"\n' > "$T/bin/gh"
  chmod +x "$T/bin/herdr" "$T/bin/gh"
  mkdir -p "$T/bundle"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n  bundle: {path: "%s/bundle"}\n' "$T" "$T" > "$T/registry.yaml"
  # a test may declare people (DD_PEOPLE) and say which one this login is (DD_ME)
  printf 'name: alpha\n%s' "${DD_PEOPLE:-}" > "$T/alpha/workspace.yaml"
  [ -z "${DD_ME:-}" ] || printf 'me: %s\n' "$DD_ME" > "$T/alpha/workspace.local.yaml"
  printf 'name: bundle\n' > "$T/bundle/workspace.yaml"
  export HOME="$T/home" CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox"
  ID="$(CEL_INBOX_ME=alpha-orch "$CEL_ROOT/bin/cel" decide ask --workspace alpha --context "$DD_CTX" \
    --title "pick a style" --option "flat::quick" --option "glossy::pretty" --recommend 2 2>/dev/null)"
  # however the test ends - a failed assert included - the server goes too
  trap '_dd_down' EXIT
  _dash_launch _dd_port "$T/dash.log" \
    "{\"name\":\"alpha\",\"wsdir\":\"$T/alpha\",\"host\":\"127.0.0.1\",\"port\":@PORT@,\"repos\":[],\"services\":[]${DD_CFG_EXTRA:-}}" \
    "$T/bin:$PATH" || return 1
  local i; for i in $(seq 1 30); do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$DASH_PORT/api/session" && break; sleep 0.3
  done
  TOKEN="$(curl -sf "http://127.0.0.1:$DASH_PORT/api/session" | jq -r .csrfToken)"
}
# the v2 page and the decisions panel it loads from /decisions.js
_dd_page() {
  curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/" && curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/decisions.js"
}
_dd_down() {
  # the server runs under its own process group (_dash_launch): stop and join it,
  # CLI children included, BEFORE the fixture is removed
  _dash_stop_group "${DASH_PID:-}"
  DASH_PID=""; if [ -n "${T:-}" ]; then rm -rf "$T"; fi; T=""; trap - EXIT
}
_dd_post() { # <body> [extra curl args...]
  local b="$1"; shift
  curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' "$@" \
    -d "$b" "http://127.0.0.1:$DASH_PORT/api/decide"
}

test_dash_needs_you_lists_and_answers_through_cel_decide() {
  _dd_boot
  local st; st="$(curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/api/state")"
  assert_eq "$(printf '%s' "$st" | jq -r '.needsYou[0].title')" "pick a style"
  assert_eq "$(printf '%s' "$st" | jq -r '.needsYou[0].recommended')" "2"
  assert_eq "$(_dd_post "{\"id\":\"$ID\",\"action\":\"answer\",\"value\":\"glossy\"}" -H "x-cel-csrf: $TOKEN")" "200"
  assert_eq "$("$CEL_ROOT/bin/cel" decide list --json 2>/dev/null)" ""
  assert_contains "$(jq -r 'select(.to == "alpha-orch") | .message' "$T/inbox/alpha.jsonl")" 'ANSWER to "pick a style": glossy'
  # the page carries the panel and its client script parses
  # the panel's client script parses
  curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/decisions.js" > "$T/decisions.js"
  node --check "$T/decisions.js"
  _dd_down
}

test_dash_drop_needs_a_reason_and_tells_the_asker() {
  _dd_boot
  assert_eq "$(_dd_post "{\"id\":\"$ID\",\"action\":\"drop\",\"value\":\"\"}" -H "x-cel-csrf: $TOKEN")" "400"
  assert_eq "$(_dd_post "{\"id\":\"$ID\",\"action\":\"drop\",\"value\":\"moot\"}" -H "x-cel-csrf: $TOKEN")" "200"
  assert_contains "$(jq -r 'select(.to == "alpha-orch") | .message' "$T/inbox/alpha.jsonl")" 'DROPPED'
  _dd_down
}

test_dash_decide_refuses_missing_csrf_and_alien_host() {
  _dd_boot
  local body="{\"id\":\"$ID\",\"action\":\"answer\",\"value\":\"flat\"}"
  assert_eq "$(_dd_post "$body")" "403"
  assert_eq "$(_dd_post "$body" -H 'x-cel-csrf: wrong-token-wrong-token-wrong-token')" "403"
  assert_eq "$(_dd_post "$body" -H "x-cel-csrf: $TOKEN" -H 'Host: evil.example')" "403"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DASH_PORT/api/decide")" "404"
  # nothing was answered
  assert_eq "$("$CEL_ROOT/bin/cel" decide list --json 2>/dev/null | jq -r .title)" "pick a style"
  _dd_down
}

# A button sends its 1-based index, so a numeric label is
# recorded as clicked; free text from the box is free text even if digits.
test_dash_option_buttons_answer_by_index() {
  _dd_boot
  local id2; id2="$(CEL_INBOX_ME=alpha-orch "$CEL_ROOT/bin/cel" decide ask --workspace alpha --context "$DD_CTX" \
    --title "how many?" --option "2::two" --option "1::one" 2>/dev/null)"
  assert_eq "$(_dd_post "{\"id\":\"$id2\",\"action\":\"answer\",\"option\":1}" -H "x-cel-csrf: $TOKEN")" "200"
  assert_contains "$(jq -r 'select(.to == "alpha-orch") | .message' "$T/inbox/alpha.jsonl")" '"how many?": 2 '
  assert_eq "$(_dd_post "{\"id\":\"$ID\",\"action\":\"answer\",\"value\":\"1\"}" -H "x-cel-csrf: $TOKEN")" "200"
  assert_contains "$(jq -r 'select(.to == "alpha-orch") | .message' "$T/inbox/alpha.jsonl")" '"pick a style": 1 '
  # the page sends the index, not the label
  assert_contains "$(_dd_page)" "option:+b.dataset.n"
  _dd_down
}

# Two tabs answering the same decision at once: one wins, the asker hears once.
test_dash_concurrent_answers_resolve_once() {
  _dd_boot
  # wait on THESE pids only: a bare `wait` also waits on the dash server
  # itself, which never exits - that hung the suite (and its box-wide lock)
  local i pids=""; for i in 1 2 3 4; do
    _dd_post "{\"id\":\"$ID\",\"action\":\"answer\",\"option\":$(( (i % 2) + 1 ))}" -H "x-cel-csrf: $TOKEN" -m 20 > "$T/code.$i" &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086
  wait $pids
  assert_eq "$(cat "$T"/code.* | grep -o 200 | grep -c . || true)" "1"
  assert_eq "$(jq -c 'select(.kind == "resolution")' "$T/inbox/alpha.jsonl" | grep -c . || true)" "1"
  assert_eq "$(jq -c 'select(.to == "alpha-orch")' "$T/inbox/alpha.jsonl" | grep -c . || true)" "1"
  _dd_down
}

# An option the decision does not have is refused, never
# recorded as the free-text answer "9".
test_dash_refuses_an_option_the_decision_does_not_have() {
  _dd_boot
  local code; code="$(_dd_post "{\"id\":\"$ID\",\"action\":\"answer\",\"option\":9}" -H "x-cel-csrf: $TOKEN")"
  [ "$code" = 400 ] || [ "$code" = 409 ] || { echo "option 9 accepted: $code"; return 1; }
  assert_eq "$("$CEL_ROOT/bin/cel" decide list --json 2>/dev/null | jq -r .title)" "pick a style"
  assert_eq "$(jq -c 'select(.to == "alpha-orch")' "$T/inbox/alpha.jsonl")" ""
  _dd_down
}

# ...and malformed JSON is the client's error (400), not a server 500.
test_dash_decide_malformed_json_is_a_400() {
  _dd_boot
  assert_eq "$(_dd_post '{not json' -H "x-cel-csrf: $TOKEN")" "400"
  _dd_down
}

_dd_ask() { # <ws> args...
  local ws="$1"; shift
  CEL_INBOX_ME="$ws-orch" "$CEL_ROOT/bin/cel" decide ask --workspace "$ws" --context "$DD_CTX" "$@" 2>/dev/null
}

# Decisions are grouped by workspace; inside a group urgent first,
# then the ones that block something, then oldest first.
test_dash_groups_and_orders_decisions() {
  _dd_boot
  _dd_ask bundle --title "bundle plain" --option "a::x" >/dev/null
  _dd_ask alpha --title "alpha blocks" --option "a::x" --blocks "the release" >/dev/null
  _dd_ask alpha --title "alpha urgent" --option "a::x" --recommend 1 --urgent >/dev/null
  local st; st="$(curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/api/state")"
  assert_eq "$(printf '%s' "$st" | jq -r '[.needsYouGroups[].workspace] | join(",")')" "alpha,bundle"
  assert_eq "$(printf '%s' "$st" | jq -r '.needsYouGroups[0].items | map(.title) | join("|")')" "alpha urgent|alpha blocks|pick a style"
  assert_eq "$(printf '%s' "$st" | jq -r '.needsYouGroups[0].count')" "3"
  assert_eq "$(printf '%s' "$st" | jq -r '.needsYouGroups[0].recommended')" "2"
  assert_eq "$(printf '%s' "$st" | jq -r '.needsYou | length')" "4"
  # the page lands on needs you, and no browser confirm() remains
  local page; page="$(_dd_page)"
  assert_contains "$page" "accept all recommended"
  if printf '%s' "$page" | grep -q 'confirm('; then echo "page still uses confirm()"; return 1; fi
  _dd_down
}

# Bulk accept answers exactly the listed ids, each with its option, through
# the guarded path; one that is refused stays open and says why.
test_dash_bulk_accept_sends_only_listed_ids_and_keeps_refusals() {
  _dd_boot
  local a b c
  a="$(_dd_ask alpha --title "q-a" --option "one::x" --option "two::y" --recommend 2)"
  b="$(_dd_ask alpha --title "q-b" --option "one::x" --recommend 1)"
  c="$(_dd_ask alpha --title "q-c" --option "one::x" --recommend 1)"
  local url="http://127.0.0.1:$DASH_PORT/api/decide-bulk"
  local body="{\"items\":[{\"id\":\"$a\",\"option\":2},{\"id\":\"$b\",\"option\":7}]}"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d "$body" "$url")" "403"
  local out; out="$(curl -s -m 30 -X POST -H 'content-type: application/json' -H "x-cel-csrf: $TOKEN" -d "$body" "$url")"
  assert_eq "$(printf '%s' "$out" | jq -r --arg a "$a" '.results[] | select(.id == $a) | .ok')" "true"
  assert_eq "$(printf '%s' "$out" | jq -r --arg b "$b" '.results[] | select(.id == $b) | .ok')" "false"
  assert_contains "$(printf '%s' "$out" | jq -r --arg b "$b" '.results[] | select(.id == $b) | .error')" "not recorded"
  local open; open="$("$CEL_ROOT/bin/cel" decide list --json 2>/dev/null | jq -r .title | sort | tr '\n' ',')"
  assert_eq "$open" "pick a style,q-b,q-c,"
  assert_contains "$(jq -r 'select(.to == "alpha-orch") | .message' "$T/inbox/alpha.jsonl")" '"q-a": two'
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -H "x-cel-csrf: $TOKEN" -d '{"items":[]}' "$url")" "400"
  _dd_down
}

# One click closes a stale decision with a fixed reason, through the same
# guarded path a typed drop takes.
test_dash_one_click_close_sends_the_fixed_reason() {
  _dd_boot
  local page; page="$(_dd_page)"
  assert_contains "$page" 'data-why="already done"'
  assert_contains "$page" 'data-why="no longer needed"'
  assert_contains "$page" "action:'drop',value:b.dataset.why"
  # the guard still stands in front of it
  assert_eq "$(_dd_post "{\"id\":\"$ID\",\"action\":\"drop\",\"value\":\"already done\"}")" "403"
  assert_eq "$(_dd_post "{\"id\":\"$ID\",\"action\":\"drop\",\"value\":\"already done\"}" -H "x-cel-csrf: $TOKEN")" "200"
  assert_contains "$(jq -r 'select(.to == "alpha-orch") | .message' "$T/inbox/alpha.jsonl")" 'DROPPED "pick a style": already done'
  _dd_down
}

# The card shows the context text itself, links clickable, plus
# blocks and age - the owner decides from the card, not from a click away.
test_cel113_card_renders_context_blocks_and_age() {
  local out; out="$(node -e '
    const fs=require("fs"),vm=require("vm");
    const ls={getItem:()=>null,setItem(){}};
    const esc=s=>String(s==null?"":s).replace(/[&<>"\x27]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","\x27":"&#39;"}[c]));
    const ctx={localStorage:ls,esc};vm.createContext(ctx);
    vm.runInContext(fs.readFileSync(process.argv[1],"utf8"),ctx);
    console.log(ctx.nyCard({id:"1",title:"pick",asker:"alpha-orch",age_secs:7200,blocks:"the beta release",
      context:"The widget build broke <b>. See https://example.com/widget/pull/7 for the diff.",options:[{label:"a",tradeoff:"x"}]}));
  ' "$CEL_ROOT/tools/dash/decisions.js")"
  assert_contains "$out" "nyctx"
  assert_contains "$out" "The widget build broke &lt;b&gt;."
  assert_contains "$out" '<a href="https://example.com/widget/pull/7" target="_blank" rel="noopener">'
  assert_contains "$out" "blocks: the beta release"
  assert_contains "$out" "2h"
}

# A decision's --pr links show on the card, as links when known.
test_cel115_card_links_the_prs_a_decision_blocks() {
  local out; out="$(node -e '
    const fs=require("fs"),vm=require("vm");
    const ls={getItem:()=>null,setItem(){}};
    const esc=s=>String(s==null?"":s).replace(/[&<>"\x27]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","\x27":"&#39;"}[c]));
    const ctx={localStorage:ls,esc};vm.createContext(ctx);
    vm.runInContext(fs.readFileSync(process.argv[1],"utf8"),ctx);
    console.log(ctx.nyCard({id:"1",title:"pick",asker:"alpha-orch",age_secs:60,options:[],
      prs:[{ref:"widget#7",url:"https://github.com/someone/widget/pull/7"},{ref:"gadget#3"}]}));
  ' "$CEL_ROOT/tools/dash/decisions.js")"
  assert_contains "$out" '<a class="pr" href="https://github.com/someone/widget/pull/7" target="_blank" rel="noopener">widget#7</a>'
  assert_contains "$out" '<span class="pr">gadget#3</span>'
}

# --- routed questions (spec B.4) ---------------------------------------------
DD_ROUTED_PEOPLE='repos:
  - {name: atlas-web}
products:
  - {name: atlas, repos: [atlas-web]}
people:
  - {id: sam, roles: [owner]}
  - {id: jo, products: {atlas: [qa]}}
  - {id: ann, products: {atlas: [design]}}
'
_dd_routed() { # <topic> <title> -> id, asked by atlas's agent
  CEL_INBOX_ME=atlas-orch "$CEL_ROOT/bin/cel" decide ask --workspace alpha --context "$DD_CTX" \
    --title "$2" --topic "$1" --option "yes::go" 2>/dev/null
}
_dd_by() { # <ws> <id> -> who the resolution records
  jq -r --arg id "$2" 'select(.kind == "resolution" and .ref == $id) | .by' "$T/inbox/$1.jsonl"
}

# THE BOX TODAY: no people:, no me: - the dashboard still answers every
# decision, recorded as the dashboard, exactly as before.
test_dash_without_people_answers_as_the_dashboard_unchanged() {
  _dd_boot
  local st; st="$(curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/api/state")"
  assert_eq "$(printf '%s' "$st" | jq -c '[.me, .needsYou[0].mine, .needsYou[0].answerable]')" '[null,true,true]' || { _dd_down; return 1; }
  assert_eq "$(_dd_post "{\"id\":\"$ID\",\"action\":\"answer\",\"option\":1}" -H "x-cel-csrf: $TOKEN")" "200" || { _dd_down; return 1; }
  assert_eq "$(_dd_by alpha "$ID")" "dashboard" || { _dd_down; return 1; }
  _dd_down
}

# With me: the dashboard answers as that person; a question routed to someone
# else is refused (409) and stays open; the state says who this login is and,
# per card, whether it is this person's and whether this login may answer it.
test_dash_answers_as_me_and_only_what_me_may_answer() {
  DD_PEOPLE="$DD_ROUTED_PEOPLE" DD_ME=jo _dd_boot
  local mine theirs st
  mine="$(_dd_routed qa "qa for jo")"; theirs="$(_dd_routed design "design for ann")"
  st="$(curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/api/state")"
  assert_eq "$(printf '%s' "$st" | jq -r .me)" "jo" || { _dd_down; return 1; }
  assert_eq "$(printf '%s' "$st" | jq -r --arg i "$mine" '.needsYou[] | select(.id == $i) | "\(.topic) \(.route.people | join(",")) \(.mine) \(.answerable)"')" "qa jo true true" || { _dd_down; return 1; }
  assert_eq "$(printf '%s' "$st" | jq -r --arg i "$theirs" '.needsYou[] | select(.id == $i) | "\(.mine) \(.answerable)"')" "false false" || { _dd_down; return 1; }
  assert_eq "$(_dd_post "{\"id\":\"$theirs\",\"action\":\"answer\",\"option\":1}" -H "x-cel-csrf: $TOKEN")" "409" || { _dd_down; return 1; }
  # pick a style was asked by alpha-orch (no product, topic owner): routed to sam
  assert_eq "$(_dd_post "{\"id\":\"$ID\",\"action\":\"drop\",\"value\":\"moot\"}" -H "x-cel-csrf: $TOKEN")" "409" || { _dd_down; return 1; }
  assert_eq "$(_dd_post "{\"id\":\"$mine\",\"action\":\"answer\",\"option\":1}" -H "x-cel-csrf: $TOKEN")" "200" || { _dd_down; return 1; }
  assert_eq "$(_dd_by alpha "$mine")" "jo" || { _dd_down; return 1; }
  assert_eq "$("$CEL_ROOT/bin/cel" decide list --json 2>/dev/null | jq -r .title | sort | tr '\n' ,)" "design for ann,pick a style," || { _dd_down; return 1; }
  _dd_down
}

# No me: on a workspace with people: the dashboard answers only unrouted
# decisions; a routed one is refused with the reason.
test_dash_with_no_me_answers_only_unrouted() {
  DD_PEOPLE="$DD_ROUTED_PEOPLE" _dd_boot
  local r out; r="$(_dd_routed qa "qa q")"
  out="$(curl -s -m 20 -X POST -H 'content-type: application/json' -H "x-cel-csrf: $TOKEN" \
    -d "{\"id\":\"$r\",\"action\":\"answer\",\"option\":1}" "http://127.0.0.1:$DASH_PORT/api/decide")"
  assert_contains "$out" "names no person" || { _dd_down; return 1; }
  assert_eq "$("$CEL_ROOT/bin/cel" decide list --json 2>/dev/null | jq -r --arg i "$r" 'select(.id == $i) | .title')" "qa q" || { _dd_down; return 1; }
  # bundle declares no people: its question is unrouted and still answered
  local u; u="$(_dd_ask bundle --title "bundle q" --option "a::x")"
  assert_eq "$(_dd_post "{\"id\":\"$u\",\"action\":\"answer\",\"option\":1}" -H "x-cel-csrf: $TOKEN")" "200" || { _dd_down; return 1; }
  assert_eq "$(_dd_by bundle "$u")" "dashboard" || { _dd_down; return 1; }
  _dd_down
}

# decisions.js: the Mine chip (on by default when this login is a person),
# topic grouping, and a card this login may not answer says why and sends
# nothing.
_dd_vm() { # <js printing a value> - decisions.js in a bare context
  node -e '
    const fs=require("fs"),vm=require("vm");
    const store={};const ls={getItem:k=>k in store?store[k]:null,setItem(k,v){store[k]=String(v)}};
    const esc=s=>String(s==null?"":s).replace(/[&<>"\x27]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","\x27":"&#39;"}[c]));
    const ctx={localStorage:ls,esc,LAST:null};vm.createContext(ctx);
    vm.runInContext(fs.readFileSync(process.argv[1],"utf8"),ctx);
    console.log(vm.runInContext(process.argv[2],ctx));
  ' "$CEL_ROOT/tools/dash/decisions.js" "$1"
}
test_dash_decisions_mine_chip_and_topic_grouping() {
  local items='[{id:"1",mine:true,topic:"qa"},{id:"2",mine:false,topic:"design"},{id:"3",mine:true}]'
  # no me: no chip, nothing filtered
  assert_eq "$(_dd_vm "LAST={me:null};JSON.stringify([nyMineOn(),nyMineItems($items).length])")" '[false,3]' || return 1
  # me set: on by default, only mine shown; the owner's pick is remembered
  assert_eq "$(_dd_vm "LAST={me:\"jo\"};JSON.stringify([nyMineOn(),nyMineItems($items).map(d=>d.id)])")" '[true,["1","3"]]' || return 1
  assert_eq "$(_dd_vm "LAST={me:\"jo\"};localStorage.setItem(\"cel-ny-mine\",\"0\");NYMINE=nyMinePref();JSON.stringify([nyMineOn(),nyMineItems($items).length])")" '[false,3]' || return 1
  # topic is a grouping beside the others; an unrouted question is topic owner
  assert_eq "$(_dd_vm "JSON.stringify([NYBYS.topic.label,NYBYS.topic.of({topic:\"qa\"}),NYBYS.topic.of({})])")" '["topic","qa","owner"]' || return 1
  local card; card="$(_dd_vm 'nyCard({id:"1",title:"t",asker:"atlas-orch",options:[{label:"a",tradeoff:""}],topic:"qa",
    route:{role:"qa",product:"atlas",people:["jo"]},me:"ann",mine:false,answerable:false},true)')"
  assert_contains "$card" "routed to qa for atlas (jo)" || return 1
  assert_contains "$card" "this login (ann) cannot answer it" || return 1
  assert_contains "$card" 'class="nycard readonly' || return 1
  card="$(_dd_vm 'nyCard({id:"1",title:"t",asker:"atlas-orch",options:[],topic:"qa",route:{role:"qa",product:"atlas",people:["jo"]},me:"jo",mine:true,answerable:true},true)')"
  assert_contains "$card" "routed to qa for atlas (jo)" || return 1
  case "$card" in *readonly*|*"cannot answer"*) echo "an answerable card was read-only"; return 1;; esac
}
