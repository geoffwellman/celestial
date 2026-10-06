# shellcheck shell=bash
# CEL-103: every worker pane exports its inbox identity (CEL_INBOX_ME,
# CEL_INBOX_WS since CEL-95, plus CEL_ROLE, HERDR_PANE_ID ...). The runner let
# it leak into every test, and eight inbox tests failed on every worker's box
# for a week while CI - which has no such environment - stayed green. A
# miniature suite, run with a worker's identity exported, must see none of it.

test_runner_clears_the_callers_identity_before_a_test_runs() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/tests/lib"
  cp "$CEL_ROOT/tests/run.sh" "$T/tests/run.sh"
  cp "$CEL_ROOT/tests/lib/assert.sh" "$T/tests/lib/assert.sh"
  cat > "$T/tests/probe.test.sh" <<'PROBE'
test_probe_sees_no_identity() {
  local v leaked=""
  for v in CEL_INBOX_ME CEL_INBOX_WS CEL_ROLE CEL_WORKSPACE CEL_ROLE_FILE \
           HERDR_PANE_ID CEL_SESSION_ID CEL_INBOX_DIR CEL_REGISTRY HERDR_SOCKET_PATH; do
    [ -z "${!v+x}" ] || leaked+=" $v"
  done
  [ -z "$leaked" ] || { echo "leaked:$leaked"; return 1; }
  [ "${CEL_TESTING:-}" = 1 ] || { echo "CEL_TESTING lost"; return 1; }
}
PROBE
  local out rc=0
  out="$(CEL_INBOX_ME=alpha-orch CEL_INBOX_WS=alpha CEL_ROLE=worker CEL_WORKSPACE=/srv/alpha \
         CEL_ROLE_FILE=/srv/role.md HERDR_PANE_ID=w9:p9 CEL_SESSION_ID=beta \
         CEL_INBOX_DIR=/srv/inbox CEL_REGISTRY=/srv/registry.yaml HERDR_SOCKET_PATH=/srv/sock \
         bash "$T/tests/run.sh" --no-lock 2>&1)" || rc=$?
  rm -rf "$T"
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; return 1; }
  assert_contains "$out" "1 passed, 0 failed"
}
