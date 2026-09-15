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
