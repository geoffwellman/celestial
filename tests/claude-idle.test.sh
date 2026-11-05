# shellcheck shell=bash
test_claude_native_idle_watcher_identity_retry_and_cursor_contract() {
  python3 "$CEL_ROOT/tests/claude-idle.test.py"
}
