# shellcheck shell=bash
# CEL-102: the browser helper waited 10 s for Chrome's DevToolsActivePort; on a
# loaded CI runner Chrome took longer and the test flaked. The wait is now
# generous, env-overridable, retried once, and a failure shows Chrome's stderr.
source "$CEL_ROOT/lib/common.sh"

# a "chrome" that takes <delay> s to open its port, chattering on stderr
_db_stub() { # <delay>
  T="$(mktemp -d)"
  {
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do case "$a" in --user-data-dir=*) prof="${a#--user-data-dir=}" ;; esac; done'
    echo 'echo "stub chrome warming up" >&2'
    echo "sleep $1"
    echo 'printf "45678\n/devtools/browser/x\n" >"$prof/DevToolsActivePort"'
    echo 'exec sleep 30'
  } >"$T/chrome"
  chmod +x "$T/chrome"
}

_db_launch() {
  node --input-type=module -e "
import {launchChrome} from '$CEL_ROOT/tests/lib/dash-browser.mjs';
try { const r = await launchChrome('$T/chrome'); r.chrome.kill('SIGKILL'); console.log('port ' + r.port); }
catch (e) { console.log(String(e.message)); process.exitCode = 1; }"
}

test_dash_browser_waits_as_long_as_the_env_says() {
  _db_stub 2
  local out; out="$(CEL_TEST_CHROME_WAIT_MS=8000 _db_launch)"
  assert_eq "$out" "port 45678"
  rm -rf "$T"
}

test_dash_browser_slow_chrome_fails_with_its_stderr_after_a_retry() {
  _db_stub 5
  local out rc=0; out="$(CEL_TEST_CHROME_WAIT_MS=600 _db_launch)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected failure: $out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "chrome never opened its debugging port"
  assert_contains "$out" "attempt 2"
  assert_contains "$out" "stub chrome warming up"
  rm -rf "$T"
}

test_dash_browser_default_wait_is_generous() {
  local out; out="$(node --input-type=module -e "import {chromeWaitMs} from '$CEL_ROOT/tests/lib/dash-browser.mjs'; console.log(chromeWaitMs())")"
  [ "$out" -ge 60000 ] || { echo "default wait $out ms is too short"; return 1; }
}
