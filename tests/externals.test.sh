# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/externals.sh"

BASE="$(fixture externals-base.yaml)"
WORKSPACE="$(fixture externals-workspace.yaml)"
CLASH="$(fixture externals-clash.yaml)"

test_overlay_adds_to_the_base() {
  assert_eq "$(externals_resolved "$BASE" "$WORKSPACE" | wc -l)" "5"
  assert_contains "$(externals_resolved "$BASE" "$WORKSPACE")" "$(printf 'herdr_plugin\tlinear\tffffffffffffffffffffffffffffffffffffffff\texample/linear')"
}

test_a_missing_overlay_file_is_not_an_error() {
  assert_eq "$(externals_resolved "$BASE" /no/such/file.yaml | wc -l)" "4"
}

test_no_conflict_when_revisions_agree() {
  externals_conflicts "$BASE" "$WORKSPACE"
}

test_conflicting_revisions_are_reported_with_origins() {
  local output
  if output="$(externals_conflicts "$BASE" "$CLASH" 2>&1)"; then return 1; fi
  assert_contains "$output" "triage"
  assert_contains "$output" "$BASE"
  assert_contains "$output" "$CLASH"
}

test_resolved_deduplicates() {
  assert_eq "$(externals_resolved "$BASE" "$BASE" | wc -l)" "4"
}

test_resolved_refuses_to_emit_on_conflict() {
  local output
  if output="$(externals_resolved "$BASE" "$CLASH" 2>/dev/null)"; then return 1; fi
  assert_eq "$output" ""
}

test_external_source_change_conflicts_even_at_same_revision() {
  local tmp output
  tmp="$(mktemp -d)"
  cat > "$tmp/overlay.yaml" <<'YAML'
herdr_plugins:
  triage: { source: another/triage, ref: dddddddddddddddddddddddddddddddddddddddd }
YAML
  if output="$(externals_resolved "$BASE" "$tmp/overlay.yaml" 2>/dev/null)"; then return 1; fi
  assert_eq "$output" ""
  rm -rf "$tmp"
}

test_external_malformed_overlay_never_emits_partial_plan() {
  local tmp output
  tmp="$(mktemp -d)"
  printf 'plugins: [\n' > "$tmp/broken.yaml"
  if output="$(externals_resolved "$BASE" "$tmp/broken.yaml" 2>/dev/null)"; then return 1; fi
  assert_eq "$output" ""
  rm -rf "$tmp"
}

# All external processes are replaced, even for red/green runs of the old code.
# The fake Claude consumes the generated catalog; no real plugin can install.
setup_external_install_fixture() {
  source "$CEL_ROOT/lib/install.sh"
  INSTALL_TEST_HOME="$(mktemp -d)"
  export INSTALL_TEST_HOME
  mkdir -p "$INSTALL_TEST_HOME/bin" "$INSTALL_TEST_HOME/home"
  cat > "$INSTALL_TEST_HOME/bin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INSTALL_TEST_HOME/herdr-calls"
if [ -n "${FAIL_PLUGIN:-}" ]; then echo 'plugin source unavailable' >&2; exit 17; fi
SH
  cat > "$INSTALL_TEST_HOME/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INSTALL_TEST_HOME/claude-calls"
if [ "$1 $2 $3" = 'plugin list --json' ]; then
  if [ -n "${INSTALLED_PLUGIN_FIXTURE:-}" ]; then cat "$INSTALLED_PLUGIN_FIXTURE"; else echo '[]'; fi
  exit 0
fi
if [ -n "${FAIL_MARKETPLACE:-}" ]; then echo 'marketplace access denied' >&2; exit 18; fi
if [ "$1 $2 $3" = 'plugin marketplace add' ]; then
  cp "$4/.claude-plugin/marketplace.json" "$INSTALL_TEST_HOME/consumed.json"
fi
SH
  chmod +x "$INSTALL_TEST_HOME/bin/herdr" "$INSTALL_TEST_HOME/bin/claude"
  export PATH="$INSTALL_TEST_HOME/bin:$PATH"
  export HOME="$INSTALL_TEST_HOME/home" XDG_DATA_HOME="$INSTALL_TEST_HOME/data"
  CEL_ROOT="$INSTALL_TEST_HOME"
}

test_install_externals_consumes_exact_herdr_revision() {
  setup_external_install_fixture
  cat > "$CEL_ROOT/externals.yaml" <<'YAML'
herdr_plugins:
  triage: { source: example/triage, ref: dddddddddddddddddddddddddddddddddddddddd }
YAML
  install_externals
  assert_eq "$(cat "$INSTALL_TEST_HOME/herdr-calls")" 'plugin install example/triage --ref dddddddddddddddddddddddddddddddddddddddd --yes'
  rm -rf "$INSTALL_TEST_HOME"
}

test_install_externals_materializes_claude_plugin_source_pin() {
  setup_external_install_fixture
  cat > "$CEL_ROOT/externals.yaml" <<'YAML'
plugins:
  sample: { source: example/plugin, ref: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa }
YAML
  install_externals
  assert_eq "$(jq -r '.plugins[0].source.repo' "$INSTALL_TEST_HOME/consumed.json")" example/plugin
  assert_eq "$(jq -r '.plugins[0].source.sha' "$INSTALL_TEST_HOME/consumed.json")" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  assert_contains "$(cat "$INSTALL_TEST_HOME/claude-calls")" 'plugin install --yes --scope user sample@celestial-sample-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  rm -rf "$INSTALL_TEST_HOME"
}

test_install_externals_pins_subdirectory_without_changing_repository() {
  setup_external_install_fixture
  cat > "$CEL_ROOT/externals.yaml" <<'YAML'
plugins:
  sample: { source: example/catalog/plugins/sample, ref: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb }
YAML
  install_externals
  assert_eq "$(jq -r '.plugins[0].source.url' "$INSTALL_TEST_HOME/consumed.json")" https://github.com/example/catalog.git
  assert_eq "$(jq -r '.plugins[0].source.path' "$INSTALL_TEST_HOME/consumed.json")" plugins/sample
  assert_eq "$(jq -r '.plugins[0].source.sha' "$INSTALL_TEST_HOME/consumed.json")" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  rm -rf "$INSTALL_TEST_HOME"
}

test_install_externals_rejects_ineffective_version_before_commands() {
  setup_external_install_fixture
  cat > "$CEL_ROOT/externals.yaml" <<'YAML'
herdr_plugins:
  triage: { source: example/triage, version: latest }
YAML
  if install_externals > "$INSTALL_TEST_HOME/output" 2>&1; then return 1; fi
  [ ! -e "$INSTALL_TEST_HOME/herdr-calls" ]
  [ ! -e "$INSTALL_TEST_HOME/claude-calls" ]
  assert_contains "$(cat "$INSTALL_TEST_HOME/output")" 'exact 40-character ref'
  rm -rf "$INSTALL_TEST_HOME"
}

test_install_externals_preserves_herdr_failure_diagnostics() {
  setup_external_install_fixture
  cat > "$CEL_ROOT/externals.yaml" <<'YAML'
herdr_plugins:
  triage: { source: example/triage, ref: dddddddddddddddddddddddddddddddddddddddd }
YAML
  export FAIL_PLUGIN=1
  local status=0
  install_externals > "$INSTALL_TEST_HOME/output" 2>&1 || status=$?
  assert_eq "$status" 17
  assert_contains "$(cat "$INSTALL_TEST_HOME/output")" 'plugin source unavailable'
  rm -rf "$INSTALL_TEST_HOME"
}

test_install_externals_marketplace_failure_never_installs_plugin() {
  setup_external_install_fixture
  cat > "$CEL_ROOT/externals.yaml" <<'YAML'
plugins:
  sample: { source: example/plugin, ref: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa }
YAML
  export FAIL_MARKETPLACE=1
  local status=0
  install_externals > "$INSTALL_TEST_HOME/output" 2>&1 || status=$?
  assert_eq "$status" 18
  assert_contains "$(cat "$INSTALL_TEST_HOME/output")" 'marketplace access denied'
  assert_eq "$(wc -l < "$INSTALL_TEST_HOME/claude-calls")" 2
  rm -rf "$INSTALL_TEST_HOME"
}

test_install_command_reports_pipeline_source_failure() {
  source "$CEL_ROOT/lib/install.sh"
  local tmp status=0
  tmp="$(mktemp -d)"
  install_command fixture '(echo "source request failed" >&2; exit 23) | cat' > "$tmp/output" 2>&1 || status=$?
  assert_eq "$status" 23
  assert_contains "$(cat "$tmp/output")" 'source request failed'
  rm -rf "$tmp"
}

test_install_script_never_executes_failed_partial_download() {
  source "$CEL_ROOT/lib/install.sh"
  local tmp status=0
  tmp="$(mktemp -d)"
  export INSTALL_MARKER="$tmp/executed"
  curl() { printf 'touch "$INSTALL_MARKER"\n' > "$4"; echo 'download interrupted' >&2; return 22; }
  install_script https://example.test/install aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa sh > "$tmp/output" 2>&1 || status=$?
  assert_eq "$status" 22
  assert_contains "$(cat "$tmp/output")" 'download interrupted'
  [ ! -e "$INSTALL_MARKER" ]
  rm -rf "$tmp"
}

test_install_script_refuses_checksum_mismatch() {
  source "$CEL_ROOT/lib/install.sh"
  local tmp
  tmp="$(mktemp -d)"
  export INSTALL_MARKER="$tmp/executed"
  curl() { printf 'touch "$INSTALL_MARKER"\n' > "$4"; }
  if install_script https://example.test/install aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa sh > "$tmp/output" 2>&1; then return 1; fi
  assert_contains "$(cat "$tmp/output")" 'checksum mismatch'
  [ ! -e "$INSTALL_MARKER" ]
  rm -rf "$tmp"
}

test_install_script_executes_verified_bytes_with_requested_release() {
  source "$CEL_ROOT/lib/install.sh"
  local tmp digest
  tmp="$(mktemp -d)"
  export INSTALL_MARKER="$tmp/executed" INSTALL_PAYLOAD="$tmp/payload"
  printf 'printf "%%s\\n" "$*" > "$INSTALL_MARKER"\n' > "$INSTALL_PAYLOAD"
  digest="$(sha256sum "$INSTALL_PAYLOAD")"; digest="${digest%% *}"
  curl() { cp "$INSTALL_PAYLOAD" "$4"; }
  install_script https://example.test/install "$digest" sh --release 1.2.3
  assert_eq "$(cat "$INSTALL_MARKER")" '--release 1.2.3'
  rm -rf "$tmp"
}

test_install_agents_returns_failure_even_for_optional_agent() {
  source "$CEL_ROOT/lib/install.sh"
  local tmp status=0
  tmp="$(mktemp -d)"
  cat > "$tmp/agents.yaml" <<'YAML'
agents:
  fixture:
    bin: cel-test-nonexistent-agent
    required: false
    version: 1.2.3
    install: '(echo "agent source failed" >&2; exit 24) | cat'
YAML
  CEL_MANIFEST="$tmp/agents.yaml"
  install_agents all > "$tmp/output" 2>&1 || status=$?
  assert_eq "$status" 24
  assert_contains "$(cat "$tmp/output")" 'agent source failed'
  rm -rf "$tmp"
}

test_gh_minimum_compares_major_and_minor_numerically() {
  source "$CEL_ROOT/lib/install.sh"
  gh() { echo "gh version $GH_TEST_VERSION (test)"; }
  GH_TEST_VERSION=2.9.0; assert_fails install_gh_supported
  GH_TEST_VERSION=2.89.9; assert_fails install_gh_supported
  GH_TEST_VERSION=2.90.0; install_gh_supported
  GH_TEST_VERSION=2.100.0; install_gh_supported
  GH_TEST_VERSION=3.0.0; install_gh_supported
  GH_TEST_VERSION=unknown; assert_fails install_gh_supported
}

test_install_externals_new_pin_retires_only_prior_owned_user_install() {
  setup_external_install_fixture
  cat > "$CEL_ROOT/externals.yaml" <<'YAML'
plugins:
  sample: { source: example/plugin, ref: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb }
YAML
  export INSTALLED_PLUGIN_FIXTURE="$INSTALL_TEST_HOME/installed.json"
  cat > "$INSTALLED_PLUGIN_FIXTURE" <<'JSON'
[
  {"id":"sample@celestial-sample-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","scope":"user","version":"1.0.0"},
  {"id":"sample@unrelated","scope":"user","version":"1.0.0"},
  {"id":"sample@celestial-sample-cccccccccccccccccccccccccccccccccccccccc","scope":"managed","version":"1.0.0"}
]
JSON
  install_externals
  local calls
  calls="$(cat "$INSTALL_TEST_HOME/claude-calls")"
  assert_contains "$calls" 'plugin install --yes --scope user sample@celestial-sample-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  assert_contains "$calls" 'plugin uninstall sample@celestial-sample-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --scope user'
  case "$calls" in *'plugin uninstall sample@unrelated'*|*'plugin uninstall sample@celestial-sample-cccc'*) return 1;; esac
  rm -rf "$INSTALL_TEST_HOME"
}

test_install_binary_activates_only_verified_release_bytes() {
  source "$CEL_ROOT/lib/install.sh"
  local tmp digest
  tmp="$(mktemp -d)"
  export HOME="$tmp/home" INSTALL_PAYLOAD="$tmp/payload"
  printf '#!/usr/bin/env bash\necho pinned-release\n' > "$INSTALL_PAYLOAD"
  digest="$(sha256sum "$INSTALL_PAYLOAD")"; digest="${digest%% *}"
  jq -n --arg hash "$digest" '
    {agents:{"fixture-agent":{assets:{
      x64:{url:"https://example.test/v1/binary",sha256:$hash},
      arm64:{url:"https://example.test/v1/binary",sha256:$hash}
    }}}}' > "$tmp/manifest.json"
  CEL_MANIFEST="$tmp/manifest.json"
  curl() { cp "$INSTALL_PAYLOAD" "$4"; }
  install_pinned_binary agents fixture-agent
  assert_eq "$("$HOME/.local/bin/fixture-agent")" pinned-release
  printf 'unverified replacement\n' > "$INSTALL_PAYLOAD"
  if install_pinned_binary agents fixture-agent > "$tmp/output" 2>&1; then return 1; fi
  assert_contains "$(cat "$tmp/output")" 'checksum mismatch'
  assert_eq "$("$HOME/.local/bin/fixture-agent")" pinned-release
  rm -rf "$tmp"
}
