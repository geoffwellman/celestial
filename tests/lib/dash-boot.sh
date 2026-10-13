# shellcheck shell=bash
# CEL-125: start a test dashboard on a port it really owns.
#
# The suites picked a "free" port by binding port 0 in python and closing it,
# then started node on that number. Under the parallel suite another test
# could take the same number in between: the loser's node died with
# EADDRINUSE, its readiness probe happily got an answer from the WINNER's
# server - another fixture, another gh stub, another CSRF token - and the test
# failed far from the cause (test_v2_merges_flags_an_unreadable_repo and the
# classic browser test, on unrelated PRs). So a boot waits for its OWN
# server's "listening" line; if it died on EADDRINUSE it picks again.
#
#   _dash_launch <port-fn> <log> <config-template> <path>
#     <config-template> holds the literal @PORT@; sets DASH_PORT and DASH_PID.
_dash_launch() {
  local port_fn="$1" log="$2" tmpl="$3" path="$4" try
  for try in 1 2 3 4 5 6 7 8; do
    DASH_PORT="$("$port_fn")"
    CEL_DASH_CONFIG="${tmpl//@PORT@/$DASH_PORT}" PATH="$path" \
      node "$CEL_ROOT/tools/dash/server.mjs" >"$log" 2>&1 &
    DASH_PID=$!
    # No time cap: "alive after N seconds" is not "ready". Under load node
    # took longer than the old 9 s probe to load, the test sent SIGUSR2
    # before the handler was installed, and the default action killed the
    # server (49 of 50 runs under a CPU hog). The suite's per-test timeout
    # bounds a server that never comes up.
    while kill -0 "$DASH_PID" 2>/dev/null; do
      if grep -q "on http://[^ ]*:$DASH_PORT\$" "$log" 2>/dev/null; then return 0; fi
      sleep 0.1
    done
    wait "$DASH_PID" 2>/dev/null || true
    if ! grep -q EADDRINUSE "$log" 2>/dev/null; then
      echo "dashboard died at boot: $(cat "$log")" >&2; DASH_PID=""; return 1
    fi
  done
  echo "no free port after $try tries" >&2; DASH_PID=""; return 1
}
