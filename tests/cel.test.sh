# shellcheck shell=bash
CEL="$CEL_ROOT/bin/cel"

test_bare_invocation_prints_usage() {
  assert_contains "$("$CEL" 2>&1)" "cel setup"
}

test_help_lists_the_workspace_commands() {
  assert_contains "$("$CEL" help 2>&1)" "cel ws new"
}

test_unknown_subcommand_exits_non_zero() {
  assert_fails "$CEL" nonsense-subcommand
}

test_shellenv_exports_cel_root() {
  assert_contains "$("$CEL" shellenv)" "export CEL_ROOT="
}

test_shellenv_puts_bin_on_path() {
  assert_contains "$("$CEL" shellenv)" "/bin:\$PATH"
}


test_shellenv_is_evaluable() {
  bash -c "eval \"\$($CEL shellenv)\"; [ -n \"\$CEL_ROOT\" ]"
}

test_shellenv_hooks_workspace_env() {
  assert_contains "$("$CEL" shellenv)" "ws env"
}

test_ws_list_reaches_the_real_command() {
  assert_contains "$("$CEL" ws list 2>&1)" "NAME"
}

test_shellenv_puts_cel_linear_on_path() {
  assert_contains "$("$CEL" shellenv)" "core/skills/linear/bin"
}

# The shim must fail loudly without a key and reject unknown commands, and it
# must do both without any network.
test_cel_linear_guards() {
  local BIN="$CEL_ROOT/core/skills/linear/bin/cel-linear"
  assert_fails env -u LINEAR_API_KEY "$BIN" me
  assert_fails "$BIN" nonsense
  assert_fails "$BIN" search
  assert_contains "$("$BIN" help)" "my-issues"
  assert_contains "$("$BIN" help)" "search"
}

test_version_prints_semver() {
  # nearest tag (VERSION when untagged), not the VERSION file: on a release
  # bump PR VERSION is already ahead of any tag (CEL-77)
  source "$CEL_ROOT/lib/version.sh"
  assert_contains "$("$CEL" version)" "celestial v$(cel_build_tag)"
}

# An unsupported platform must stop before a supervisor module can start work.
setup_platform_dispatch_fixture() {
  PLATFORM_TEST_HOME="$(mktemp -d)"
  mkdir -p "$PLATFORM_TEST_HOME/bin" "$PLATFORM_TEST_HOME/home" "$PLATFORM_TEST_HOME/plane/bin" "$PLATFORM_TEST_HOME/plane/lib"
  cp "$CEL" "$PLATFORM_TEST_HOME/plane/bin/cel"
  : > "$PLATFORM_TEST_HOME/plane/lib/common.sh"
  : > "$PLATFORM_TEST_HOME/plane/lib/link.sh"
  local command library
  for command in setup steward gc run; do
    library="$command"; [ "$command" != setup ] || library=install
    printf 'cmd_%s() { touch "$HOME/dispatched"; }\n' "$command" > "$PLATFORM_TEST_HOME/plane/lib/$library.sh"
  done
}

test_unsupported_platform_refuses_before_dispatch() {
  local tmp command
  setup_platform_dispatch_fixture
  tmp="$PLATFORM_TEST_HOME"
  cat > "$tmp/bin/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in -s) echo Darwin;; -o) echo Darwin;; *) echo x86_64;; esac
SH
  chmod +x "$tmp/bin/uname"
  for command in setup steward gc run; do
    if HOME="$tmp/home" PATH="$tmp/bin:$PATH" "$tmp/plane/bin/cel" "$command" > "$tmp/output" 2>&1; then
      return 1
    fi
    assert_contains "$(cat "$tmp/output")" "requires GNU/Linux"
  done
  [ ! -e "$tmp/home/dispatched" ]
  rm -rf "$tmp"
}

test_android_linux_refuses_before_dispatch() {
  local tmp
  setup_platform_dispatch_fixture
  tmp="$PLATFORM_TEST_HOME"
  cat > "$tmp/bin/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in -s) echo Linux;; -o) echo Android;; *) echo aarch64;; esac
SH
  chmod +x "$tmp/bin/uname"
  if HOME="$tmp/home" PATH="$tmp/bin:$PATH" "$tmp/plane/bin/cel" steward > "$tmp/output" 2>&1; then return 1; fi
  assert_contains "$(cat "$tmp/output")" "requires GNU/Linux"
  [ ! -e "$tmp/home/dispatched" ]
  rm -rf "$tmp"
}
