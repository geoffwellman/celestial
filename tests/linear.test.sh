# shellcheck shell=bash
# The CLI sends JSON on stdin, so its private header file must preserve both
# credential secrecy and request bodies, then disappear on success or failure.
_linear_transport_fixture() {
  T="$(mktemp -d)"
  export LINEAR_TEST_DIR="$T" LINEAR_API_KEY=fixture-linear-key
  export LINEAR_API_URL=https://linear.invalid/graphql
  export TMPDIR="$T" PATH="$T:$PATH"
  unset LINEAR_TEST_FAIL
  cat > "$T/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" > "$LINEAR_TEST_DIR/argv"
headers=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H)
      case "$2" in
        @*) headers="${2#@}" ;;
        Authorization:*) printf '%s' "$2" > "$LINEAR_TEST_DIR/header" ;;
      esac
      shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$headers" ]; then
  printf '%s' "$headers" > "$LINEAR_TEST_DIR/header-path"
  stat -c %a "$headers" > "$LINEAR_TEST_DIR/header-mode"
  cat "$headers" > "$LINEAR_TEST_DIR/header"
fi
cat > "$LINEAR_TEST_DIR/body"
[ "${LINEAR_TEST_FAIL:-0}" = 0 ] || exit 22
printf '{"data":{"searchIssues":{"nodes":[]},"viewer":{"name":"Example"}}}'
EOF
  chmod +x "$T/curl"
}

test_linear_credentials_are_private_and_json_body_survives() {
  _linear_transport_fixture
  local terms=$'quoted "value"\nsecond line with \\ slash'
  "$CEL_ROOT/core/skills/linear/bin/cel-linear" search "$terms" > "$T/out" 2> "$T/err"
  assert_eq "$(cat "$T/header")" 'Authorization: fixture-linear-key'
  assert_eq "$(cat "$T/header-mode")" 600
  assert_eq "$(jq -r '.variables.t' "$T/body")" "$terms"
  assert_contains "$(jq -r '.query' "$T/body")" 'searchIssues(term: $t'
  assert_contains "$(cat "$T/argv")" https://linear.invalid/graphql
  assert_fails grep -Fq "$LINEAR_API_KEY" "$T/argv" "$T/out" "$T/err"
  assert_fails test -e "$(cat "$T/header-path")"
  rm -rf "$T"
}

test_linear_request_failure_removes_private_header_file() {
  _linear_transport_fixture
  export LINEAR_TEST_FAIL=1
  if "$CEL_ROOT/core/skills/linear/bin/cel-linear" me > "$T/out" 2> "$T/err"; then
    echo 'failed request was reported as successful'
    return 1
  fi
  assert_contains "$(cat "$T/err")" 'linear: API request failed'
  assert_eq "$(cat "$T/header-mode")" 600
  assert_fails grep -Fq "$LINEAR_API_KEY" "$T/argv" "$T/out" "$T/err"
  assert_fails test -e "$(cat "$T/header-path")"
  rm -rf "$T"
}

# --- CEL-25: the board -----------------------------------------------------

# `cel-linear board` is what the console's BOARD panel reads, and the console
# refreshes after every command - so the raw query is cached for a minute on
# disk. Without it, one operator with the console open is a request to Linear
# every ten seconds for as long as the box is up.
_linear_board_fixture() {
  _linear_transport_fixture
  export CEL_CACHE="$T/cache"
  mkdir -p "$CEL_CACHE"
  cat > "$T/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'call\n' >> "$LINEAR_TEST_DIR/calls"
cat > /dev/null
cat <<'JSON'
{"data":{"teams":{"nodes":[{"key":"ABC","states":{"nodes":[
  {"name":"Todo","position":0,"type":"unstarted"},
  {"name":"In Progress","position":1,"type":"started"},
  {"name":"Done","position":2,"type":"completed"}]},
 "issues":{"nodes":[
  {"identifier":"ABC-49","title":"ship the gadget bundle","url":"https://linear.invalid/ABC-49","updatedAt":"2026-09-20T10:00:00Z","state":{"name":"In Progress"},"assignee":{"name":"Sam"}},
  {"identifier":"ABC-48","title":"the kerning is wrong","url":"https://linear.invalid/ABC-48","updatedAt":"2026-09-20T09:00:00Z","state":{"name":"Todo"},"assignee":null}]}}]}}}
JSON
EOF
  chmod +x "$T/curl"
  : > "$T/calls"
}

test_linear_board_groups_by_state_in_workflow_order() {
  _linear_board_fixture
  local out
  out="$("$CEL_ROOT/core/skills/linear/bin/cel-linear" board --team ABC)"
  assert_contains "$out" 'Todo'
  assert_contains "$out" 'In Progress'
  assert_contains "$out" 'ABC-49'
  assert_contains "$out" 'Sam'
  # workflow order, not the order the API happened to return them in
  local todo prog
  todo="$(printf '%s\n' "$out" | grep -n '^Todo' | cut -d: -f1)"
  prog="$(printf '%s\n' "$out" | grep -n '^In Progress' | cut -d: -f1)"
  [ "$todo" -lt "$prog" ] || { echo 'the board is out of workflow order'; return 1; }
  rm -rf "$T"
}

test_linear_board_json_is_one_object_per_line() {
  _linear_board_fixture
  local out
  out="$("$CEL_ROOT/core/skills/linear/bin/cel-linear" board --team ABC --json)"
  assert_eq "$(printf '%s\n' "$out" | wc -l)" 2
  assert_eq "$(printf '%s\n' "$out" | head -1 | jq -r '.identifier')" ABC-48
  assert_eq "$(printf '%s\n' "$out" | head -1 | jq -r '.state')" Todo
  assert_contains "$(printf '%s\n' "$out" | tail -1)" 'https://linear.invalid/ABC-49'
  rm -rf "$T"
}

test_linear_board_caches_the_query_for_a_minute() {
  _linear_board_fixture
  "$CEL_ROOT/core/skills/linear/bin/cel-linear" board --team ABC --json >/dev/null
  "$CEL_ROOT/core/skills/linear/bin/cel-linear" board --team ABC --json >/dev/null
  assert_eq "$(wc -l < "$T/calls")" 1
  assert_eq "$(ls "$CEL_CACHE"/linear-board-ABC.json | wc -l)" 1
  rm -rf "$T"
}
