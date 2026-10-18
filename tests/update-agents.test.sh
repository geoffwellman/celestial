# shellcheck shell=bash
# AH-261018: `cel update` keeps the box's coding agents and gateway
# registrations current even when Celestial's own git is already current.
#
# Every CLI here is a stub on a prepended PATH that keeps its "installed
# version" in a file: nothing installs, downloads or contacts a registry. What
# is asserted is the CONTRACT the owner asked for - per-component old/new
# versions, idempotence, partial failure that is not reported as success, a
# declared pin that is reported rather than silently called current, a latest
# that is still ahead after the update treated as a blocker, no restart of a
# live session, and a recoverable rollback.
source "$CEL_ROOT/lib/common.sh"
_UAG_REPO="$CEL_ROOT"
source "$_UAG_REPO/lib/update.sh"

_uag_fixture() {
  T="$(mktemp -d)"; LOG="$T/log"; : >"$LOG"
  export HOME="$T/home"; mkdir -p "$HOME" "$T/bin"
  # a git root exactly at its newest release tag: "Celestial is current"
  ORIGIN="$T/origin.git"; ROOT="$T/root"
  git init -q --bare "$ORIGIN"; git init -q -b main "$ROOT"
  git -C "$ROOT" config user.email t@example.com; git -C "$ROOT" config user.name tester
  printf '0.1.0\n' >"$ROOT/VERSION"; printf '# Changelog\n\n## [0.1.0] - 2026-01-01\n' >"$ROOT/CHANGELOG.md"
  git -C "$ROOT" add -A; git -C "$ROOT" commit -qm 'release 0.1.0'; git -C "$ROOT" tag v0.1.0
  git -C "$ROOT" remote add origin "$ORIGIN"; git -C "$ROOT" push -q origin main --tags
  export CEL_ROOT="$ROOT" CEL_UPDATE_DIR="$T/updatestate" CEL_CONFIG_FILE="$T/config.yaml"
  export CEL_REGISTRY="$T/registry.yaml" CEL_INBOX_DIR="$T/inbox" CEL_INBOX_ME=steward
  CEL_MANIFEST="$T/agents.yaml"
  cat >"$CEL_MANIFEST" <<'YML'
agents:
  alpha:
    bin: alpha
    update: { command: "alpha update", latest: "cat $UAG_T/alpha.latest", rollback: 'alpha install "$CEL_OLD_VERSION"' }
  beta:
    bin: beta
    update: { command: "beta update", latest: "cat $UAG_T/beta.latest" }
  gamma:
    bin: gamma
    update: { command: "gamma update", latest: "cat $UAG_T/gamma.latest" }
  absent:
    bin: absent-agent
    update: { command: "absent-agent update" }
  pi:
    bin: pi
    extensions_file: tools/pi/extensions.txt
    update: { command: "pi update --self", latest: "cat $UAG_T/pi.latest" }
YML
  export UAG_T="$T"
  local a
  for a in alpha beta gamma pi; do
    printf '1.0.0\n' >"$T/$a.ver"; printf '1.1.0\n' >"$T/$a.latest"
    cat >"$T/bin/$a" <<EOS
#!/usr/bin/env bash
case "\$1" in
  --version) printf '$a %s\n' "\$(cat "$T/$a.ver")" ;;
  update) printf '$a update\n' >>"$LOG"
          [ ! -e "$T/$a.fail" ] || { echo "registry unreachable" >&2; exit 1; }
          [ -e "$T/$a.stuck" ] || cp "$T/$a.latest" "$T/$a.ver" ;;
  install) printf '$a install %s\n' "\$2" >>"$LOG"; printf '%s\n' "\$2" >"$T/$a.ver" ;;
esac
EOS
    chmod +x "$T/bin/$a"
  done
  PATH="$T/bin:$PATH"
  # the side effects that are not under test
  _update_reapply() { printf 'reapply\n' >>"$LOG"; }
  _update_verify() { printf 'verify\n' >>"$LOG"; return 0; }
  _update_stale_agents() { :; }
  _update_stale_orchestrators() { :; }
  _update_stale_gateway_env() { :; }
  gateway_refresh() { printf 'gateway_refresh\n' >>"$LOG"; return "${GW_REFRESH_RC:-0}"; }
  herdr() { printf 'HERDR %s\n' "$*" >>"$LOG"; return 1; }
  kill() { printf 'KILL %s\n' "$*" >>"$LOG"; }
}
_uag_cleanup() { CEL_ROOT="$_UAG_REPO"; unset CEL_UPDATE_DIR CEL_CONFIG_FILE CEL_REGISTRY CEL_INBOX_DIR CEL_INBOX_ME UAG_T; rm -rf "$T"; }

test_update_upgrades_agents_even_when_celestial_is_already_current() {
  _uag_fixture
  local out rc=0
  out="$(cmd_update 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { echo "$out"; _uag_cleanup; return 1; }
  assert_contains "$out" "alpha"; assert_contains "$out" "1.0.0 -> 1.1.0" || { echo "$out"; _uag_cleanup; return 1; }
  assert_eq "$(cat "$T/beta.ver")" 1.1.0
  assert_eq "$(cat "$T/pi.ver")" 1.1.0
  # an agent that is not installed is not installed by update, and not an error
  assert_contains "$out" "absent"; assert_contains "$out" "not installed"
  ! grep -q 'absent-agent' "$LOG" || { echo "update installed a missing agent"; _uag_cleanup; return 1; }
  # registrations and launch config refreshed although git did not move
  grep -q '^gateway_refresh$' "$LOG" || { echo "gateway not refreshed"; _uag_cleanup; return 1; }
  _uag_cleanup
}

test_update_is_idempotent_and_reports_current_versions_the_second_time() {
  _uag_fixture
  cmd_update >/dev/null 2>&1
  local out rc=0
  out="$(cmd_update 2>&1)" || rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "alpha 1.1.0 (current)" || { echo "$out"; _uag_cleanup; return 1; }
  assert_eq "$(cat "$T/alpha.ver")" 1.1.0
  # the recorded "previous" versions are from the FIRST run, not overwritten by a no-op
  assert_eq "$(jq -r '.alpha' "$CEL_UPDATE_DIR/agents-previous.json")" 1.0.0
  _uag_cleanup
}

# A failed component is an honest non-success: the other components are still
# attempted, the failure names the component and the way forward, and the
# command does not end by saying everything is up to date.
test_update_partial_failure_is_not_success_and_other_agents_still_update() {
  _uag_fixture
  : >"$T/beta.fail"
  local out rc=0
  out="$(cmd_update 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "a failed agent update exited 0"; echo "$out"; _uag_cleanup; return 1; }
  assert_contains "$out" "beta" ; assert_contains "$out" "FAILED"
  assert_contains "$out" "cel update" # rerun is the recovery path
  assert_eq "$(cat "$T/alpha.ver")" 1.1.0
  assert_eq "$(cat "$T/gamma.ver")" 1.1.0
  assert_eq "$(cat "$T/beta.ver")" 1.0.0
  ! printf '%s' "$out" | grep -qi 'everything is up to date' || { echo "claimed success"; _uag_cleanup; return 1; }
  # rerun after the cause is fixed completes
  rm -f "$T/beta.fail"
  cmd_update >/dev/null 2>&1 || { echo "rerun did not recover"; _uag_cleanup; return 1; }
  assert_eq "$(cat "$T/beta.ver")" 1.1.0
  _uag_cleanup
}

# An updater that exits 0 but leaves the agent behind the published latest is
# a blocker, never "current".
test_update_reports_an_agent_still_behind_the_latest_as_a_blocker() {
  _uag_fixture
  : >"$T/gamma.stuck"
  local out rc=0
  out="$(cmd_update 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "stale agent exited 0"; _uag_cleanup; return 1; }
  assert_contains "$out" "gamma"; assert_contains "$out" "latest 1.1.0"
  assert_contains "$out" "still 1.0.0"
  _uag_cleanup
}

# A pin is reported by name, not silently treated as current.
test_update_reports_a_held_agent_and_does_not_run_its_updater() {
  _uag_fixture
  printf 'update:\n  hold: alpha\n' >"$CEL_CONFIG_FILE"
  local out rc=0
  out="$(cmd_update 2>&1)" || rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "alpha 1.0.0 held"
  assert_contains "$out" "Pinned exceptions"
  ! grep -q '^alpha update$' "$LOG" || { echo "ran the updater of a held agent"; _uag_cleanup; return 1; }
  assert_eq "$(cat "$T/alpha.ver")" 1.0.0
  _uag_cleanup
}

# pi's extensions are pinned by tools/pi/extensions.txt: named, not updated.
test_update_names_pi_extensions_as_a_pin_exception() {
  _uag_fixture
  mkdir -p "$ROOT/tools/pi"; printf '@scope/ext@1.2.3\n' >"$ROOT/tools/pi/extensions.txt"
  git -C "$ROOT" add -A; git -C "$ROOT" commit -qm 'pin an extension'
  local out; out="$(cmd_update 2>&1)"
  assert_contains "$out" "pi extensions"
  assert_contains "$out" "pinned"
  _uag_cleanup
}

test_update_gateway_refresh_failure_is_a_failure_even_when_agents_succeed() {
  _uag_fixture
  GW_REFRESH_RC=1
  local out rc=0
  out="$(cmd_update 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "registration failure exited 0"; _uag_cleanup; return 1; }
  assert_contains "$out" "gateway"
  assert_eq "$(cat "$T/alpha.ver")" 1.1.0
  unset GW_REFRESH_RC
  _uag_cleanup
}

# Live owner sessions are never restarted or signalled by update.
test_update_never_restarts_or_signals_a_live_session() {
  _uag_fixture
  cmd_update >/dev/null 2>&1
  ! grep -q '^HERDR \|^KILL ' "$LOG" || { cat "$LOG"; _uag_cleanup; return 1; }
  _uag_cleanup
}

test_update_check_reports_installed_and_latest_without_changing_anything() {
  _uag_fixture
  local out rc=0
  out="$(cmd_update --check --agents 2>&1)" || rc=$?
  assert_contains "$out" "alpha 1.0.0 (latest 1.1.0)"
  ! grep -q ' update$' "$LOG" || { echo "--check ran an updater"; _uag_cleanup; return 1; }
  assert_eq "$(cat "$T/alpha.ver")" 1.0.0
  _uag_cleanup
}

# Recovery: the pre-update versions are recorded, and --rollback restores each
# agent that DECLARES a rollback; one that does not is named, never guessed.
test_update_rollback_restores_recorded_agent_versions_where_declared() {
  _uag_fixture
  cmd_update >/dev/null 2>&1
  : >"$LOG"
  _update_rollback_git() { :; }
  local out; out="$(_update_agents_rollback 2>&1)"
  assert_eq "$(cat "$T/alpha.ver")" 1.0.0
  grep -q '^alpha install 1.0.0$' "$LOG" || { cat "$LOG"; _uag_cleanup; return 1; }
  assert_contains "$out" "beta"; assert_contains "$out" "no declared rollback"
  _uag_cleanup
}

# ------------------------------------------- pi extensions + built-in MCP
# AH-261018: startup warnings are fixed by supported upgrades/migration, never
# by patching node_modules or suppressing output.
_uag_pi_fixture() {
  _uag_fixture
  export CEL_PI_AGENT_DIR="$T/piagent"
  mkdir -p "$T/piagent/npm/node_modules/pi-subagents" "$T/piagent/npm/node_modules/@scope/ext" "$ROOT/tools/pi"
  printf '{"version":"0.68.0"}' >"$T/piagent/npm/node_modules/pi-subagents/package.json"
  printf '{"version":"9.0.0"}' >"$T/piagent/npm/node_modules/@scope/ext/package.json"
  printf 'pi-subagents@0.79.0\n@scope/ext@1.0.0\n' >"$ROOT/tools/pi/extensions.txt"
  git -C "$ROOT" add -A; git -C "$ROOT" commit -qm pins
  printf '{"packages":["npm:pi-subagents@0.68.0","npm:@scope/ext@9.0.0","npm:pi-mcp-adapter@2.34.0"]}' >"$T/piagent/settings.json"
  printf '{"mcpServers":{"hindsight":{"type":"stdio","command":"node","args":["/x/mcp-server.js"],"env":{"HINDSIGHT_MCP_HARNESS":"s3cr3t-value"}}}}' >"$HOME/.claude.json"
  # a pi stub that models install/remove/mcp list against the fixture state
  cat >"$T/bin/pi" <<EOS
#!/usr/bin/env bash
case "\$1" in
  --version) echo 1.2.0 ;;
  update) : ;;
  install) printf 'pi install %s\n' "\$2" >>"$LOG"; [ ! -e "$T/install.fail" ] || exit 1
           n="\${2#npm:}"; n="\${n%@*}"; v="\${2##*@}"; mkdir -p "$T/piagent/npm/node_modules/\$n"
           printf '{"version":"%s"}' "\$v" >"$T/piagent/npm/node_modules/\$n/package.json"
           jq --arg s "\$2" '.packages += [\$s]' "$T/piagent/settings.json" >"$T/s.tmp" && mv "$T/s.tmp" "$T/piagent/settings.json" ;;
  remove) printf 'pi remove %s\n' "\$2" >>"$LOG"
          jq --arg s "\$2" '.packages -= [\$s]' "$T/piagent/settings.json" >"$T/s.tmp" && mv "$T/s.tmp" "$T/piagent/settings.json" ;;
  mcp) [ "\$2" = list ] && printf '{"servers":[{"name":"hindsight","state":"connected"}]}' ;;
esac
EOS
  chmod +x "$T/bin/pi"
  # these tests are about the pi steps only
  _update_agents() { return 0; }
}

test_update_upgrades_a_pi_extension_below_its_pin_and_never_downgrades() {
  _uag_pi_fixture
  local out; out="$(_update_pi_extensions 2>&1)" || { echo "$out"; _uag_cleanup; return 1; }
  assert_contains "$out" "pi-subagents 0.68.0 -> 0.79.0"
  assert_contains "$out" "@scope/ext 9.0.0 (pin 1.0.0: current)"
  grep -q '^pi install npm:pi-subagents@0.79.0$' "$LOG" || { cat "$LOG"; _uag_cleanup; return 1; }
  ! grep -q 'npm:@scope/ext' "$LOG" || { echo "downgraded/reinstalled an ahead extension"; _uag_cleanup; return 1; }
  # the superseded spec is dropped, so settings carries one pi-subagents entry
  assert_eq "$(jq -r '[.packages[] | select(startswith("npm:pi-subagents"))] | join(",")' "$T/piagent/settings.json")" "npm:pi-subagents@0.79.0"
  # idempotent
  : >"$LOG"; _update_pi_extensions >/dev/null 2>&1
  ! grep -q 'pi install' "$LOG" || { echo "second run reinstalled"; _uag_cleanup; return 1; }
  _uag_cleanup
}

test_update_pi_extension_install_failure_is_reported_and_keeps_the_old_version() {
  _uag_pi_fixture
  : >"$T/install.fail"
  local out rc=0; out="$(_update_pi_extensions 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "install failure exited 0"; _uag_cleanup; return 1; }
  assert_contains "$out" "FAILED"
  assert_eq "$(jq -r .version "$T/piagent/npm/node_modules/pi-subagents/package.json")" 0.68.0
  _uag_cleanup
}

test_update_migrates_mcp_servers_verbatim_then_removes_the_adapter_without_printing_values() {
  _uag_pi_fixture
  local out; out="$(_update_pi_mcp 2>&1)" || { echo "$out"; _uag_cleanup; return 1; }
  assert_eq "$(jq -r '.mcpServers.hindsight.env.HINDSIGHT_MCP_HARNESS' "$T/piagent/mcp.json")" "s3cr3t-value"
  assert_eq "$(jq -r '.mcpServers.hindsight.args[0]' "$T/piagent/mcp.json")" "/x/mcp-server.js"
  ! printf '%s' "$out" | grep -q 's3cr3t-value' || { echo "a value was printed"; _uag_cleanup; return 1; }
  grep -q '^pi remove npm:pi-mcp-adapter@2.34.0$' "$LOG" || { cat "$LOG"; _uag_cleanup; return 1; }
  assert_eq "$(stat -c %a "$T/piagent/mcp.json")" 600
  # idempotent: nothing left to do
  : >"$LOG"; _update_pi_mcp >/dev/null 2>&1; ! grep -q 'pi remove' "$LOG"
  _uag_cleanup
}

test_update_keeps_the_adapter_when_a_builtin_server_does_not_come_up() {
  _uag_pi_fixture
  printf '{"mcpServers":{"linear":{"type":"http","url":"https://mcp.example.invalid/mcp"}}}' >"$HOME/.claude.json"
  local out rc=0; out="$(_update_pi_mcp 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "unsigned http server exited 0"; _uag_cleanup; return 1; }
  assert_contains "$out" "pi mcp login"
  ! grep -q 'pi remove' "$LOG" || { echo "adapter removed while a server lacked auth"; _uag_cleanup; return 1; }
  _uag_cleanup
}

test_update_prefers_an_existing_builtin_server_definition() {
  _uag_pi_fixture
  printf '{"mcpServers":{"hindsight":{"command":"mine"}}}' >"$T/piagent/mcp.json"
  _update_pi_mcp >/dev/null 2>&1
  assert_eq "$(jq -r '.mcpServers.hindsight.command' "$T/piagent/mcp.json")" mine
  _uag_cleanup
}

# The shared pi models.json is written at every gateway launch: an existing
# model entry (owner-tuned capabilities of a live session) is never rewritten
# by a launch, and an unchanged write does not touch the file at all.
test_launch_writer_never_rewrites_existing_model_metadata_or_touches_an_unchanged_file() {
  T="$(mktemp -d)"; export HOME="$T/h" CEL_CONFIG_FILE="$T/c.yaml" CEL_GATEWAY_STATE="$T/s" CEL_PI_AGENT_DIR="$T/pi"
  mkdir -p "$HOME" "$T/pi"; printf 'gateway:\n  port: 8317\n' >"$CEL_CONFIG_FILE"
  printf '#!/usr/bin/env bash\ncase "$1" in ready) exit 0;; models) printf %%s '"'"'{"data":[{"id":"claude-opus-5-5"},{"id":"gpt-5.5"}]}'"'"';; esac\n' >"$T/stub"
  chmod +x "$T/stub"; export CEL_GATEWAY_STUB="$T/stub"
  source "$_UAG_REPO/lib/gateway.sh"
  gateway_pi_models_write "$T/pi/models.json"
  jq '.providers["ompgw-claude"].models[0].contextWindow = 555' "$T/pi/models.json" >"$T/x" && mv "$T/x" "$T/pi/models.json"
  local ino; ino="$(stat -c %i%Y "$T/pi/models.json")"; sleep 1.1
  gateway_pi_models_write "$T/pi/models.json"
  assert_eq "$(jq '.providers["ompgw-claude"].models[0].contextWindow' "$T/pi/models.json")" 555
  assert_eq "$(stat -c %i%Y "$T/pi/models.json")" "$ino"
  GATEWAY_PI_WRITE=refresh gateway_pi_models_write "$T/pi/models.json"
  assert_eq "$(jq '.providers["ompgw-claude"].models[0].contextWindow' "$T/pi/models.json")" 1000000
  unset CEL_GATEWAY_STUB CEL_PI_AGENT_DIR
  rm -rf "$T"
}
