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

# CEL RUNS IN A CLEAN PROCESS. Shell code smuggled in through the environment
# - an exported function, a BASH_ENV file - is gone before bin/cel's first
# command: it re-executes itself without it. A BASH_ENV file runs once, in
# the process that is replaced (it cannot be stopped), and never again; an
# exported `uname` that would fake the platform never reaches the check.
test_cel_reexecutes_without_smuggled_shell_code() {
  local tmp out; tmp="$(mktemp -d)"
  printf 'echo ran >> %q\nexit() { return 0; }\n' "$tmp/bash-env.log" > "$tmp/bash-env.sh"
  out="$(BASH_ENV="$tmp/bash-env.sh" "$CEL" help 2>&1)" || { echo "$out"; rm -rf "$tmp"; return 1; }
  assert_contains "$out" "cel ws new" || { rm -rf "$tmp"; return 1; }
  assert_eq "$(wc -l < "$tmp/bash-env.log")" 1 || { echo "BASH_ENV ran in the clean process too"; rm -rf "$tmp"; return 1; }
  out="$(bash -c 'uname() { echo Darwin; }; export -f uname; "$1" help' _ "$CEL" 2>&1)" || { echo "$out"; rm -rf "$tmp"; return 1; }
  assert_contains "$out" "cel ws new" || { rm -rf "$tmp"; return 1; }
  # a forged loop marker never lets a dirty process run: it refuses instead
  out="$(_CEL_CLEAN_EXEC=1 BASH_ENV="$tmp/bash-env.sh" "$CEL" help 2>&1)" && { echo "a forged marker ran cel: $out"; rm -rf "$tmp"; return 1; }
  assert_contains "$out" "refusing to run" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}
