# shellcheck shell=bash
# Real HTTP regressions run against isolated fixture roots and CLI stand-ins.
test_http_control_plane_security_and_survival() {
  node --test "$CEL_ROOT/tests/http-server.test.mjs"
}
