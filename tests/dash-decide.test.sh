# shellcheck shell=bash
# CEL-93: the dashboard's Needs-you panel answers owner decisions through the
# real `cel decide`, behind the dashboard's Host and CSRF guard.
source "$CEL_ROOT/lib/common.sh"

_dd_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

_dd_boot() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/alpha" "$T/inbox" "$T/home"
  printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"result\":{\"agents\":[],\"workspaces\":[],\"panes\":[]}}'" > "$T/bin/herdr"
  printf '#!/usr/bin/env bash\nprintf "[]"\n' > "$T/bin/gh"
  chmod +x "$T/bin/herdr" "$T/bin/gh"
  mkdir -p "$T/bundle"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n  bundle: {path: "%s/bundle"}\n' "$T" "$T" > "$T/registry.yaml"
  printf 'name: alpha\n' > "$T/alpha/workspace.yaml"
  printf 'name: bundle\n' > "$T/bundle/workspace.yaml"
  export HOME="$T/home" CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox"
  ID="$(CEL_INBOX_ME=alpha-orch "$CEL_ROOT/bin/cel" decide ask --workspace alpha \
    --title "pick a style" --option "flat::quick" --option "glossy::pretty" --recommend 2 2>/dev/null)"
  DASH_PORT="$(_dd_port)"
  CEL_DASH_CONFIG="{\"name\":\"alpha\",\"wsdir\":\"$T/alpha\",\"host\":\"127.0.0.1\",\"port\":$DASH_PORT,\"repos\":[],\"services\":[]}" \
    PATH="$T/bin:$PATH" node "$CEL_ROOT/tools/dash/server.mjs" >"$T/dash.log" 2>&1 &
  DASH_PID=$!
  # however the test ends - a failed assert included - the server goes too
  trap '_dd_down' EXIT
  local i; for i in $(seq 1 30); do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$DASH_PORT/api/session" && break; sleep 0.3
  done
  TOKEN="$(curl -sf "http://127.0.0.1:$DASH_PORT/api/session" | jq -r .csrfToken)"
}
_dd_down() {
  if [ -n "${DASH_PID:-}" ]; then kill "$DASH_PID" 2>/dev/null || true; wait "$DASH_PID" 2>/dev/null || true; fi
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
  local page; page="$(curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/")"
  assert_contains "$page" 'id="needsyou"'
  printf '%s' "$page" | python3 -c 'import sys,re;print("\n".join(re.findall(r"<script>(.*?)</script>",sys.stdin.read(),re.S)))' > "$T/page.js"
  node --check "$T/page.js"
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

# Review on #118: a button sends its 1-based index, so a numeric label is
# recorded as clicked; free text from the box is free text even if digits.
test_dash_option_buttons_answer_by_index() {
  _dd_boot
  local id2; id2="$(CEL_INBOX_ME=alpha-orch "$CEL_ROOT/bin/cel" decide ask --workspace alpha \
    --title "how many?" --option "2::two" --option "1::one" 2>/dev/null)"
  assert_eq "$(_dd_post "{\"id\":\"$id2\",\"action\":\"answer\",\"option\":1}" -H "x-cel-csrf: $TOKEN")" "200"
  assert_contains "$(jq -r 'select(.to == "alpha-orch") | .message' "$T/inbox/alpha.jsonl")" '"how many?": 2 '
  assert_eq "$(_dd_post "{\"id\":\"$ID\",\"action\":\"answer\",\"value\":\"1\"}" -H "x-cel-csrf: $TOKEN")" "200"
  assert_contains "$(jq -r 'select(.to == "alpha-orch") | .message' "$T/inbox/alpha.jsonl")" '"pick a style": 1 '
  # the page sends the index, not the label
  assert_contains "$(curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/")" "option:+b.dataset.n"
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

# Sourcery on #122: an option the decision does not have is refused, never
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
  CEL_INBOX_ME="$ws-orch" "$CEL_ROOT/bin/cel" decide ask --workspace "$ws" "$@" 2>/dev/null
}

# CEL-99: decisions are grouped by workspace; inside a group urgent first,
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
  local page; page="$(curl -sf -m 20 "http://127.0.0.1:$DASH_PORT/")"
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
