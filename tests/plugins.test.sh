# shellcheck shell=bash
source "$CEL_ROOT/lib/plugins.sh"

_optional_fixture() {
  OPT_T="$(mktemp -d)"
  export HOME="$OPT_T/home" XDG_DATA_HOME="$OPT_T/data"
  local source_root="$CEL_ROOT"
  export CEL_ROOT="$OPT_T/cel"
  mkdir -p "$CEL_ROOT" "$HOME" "$OPT_T/upstream/skills/egm-review" "$OPT_T/upstream/agents" \
    "$OPT_T/upstream/resources/document_standards" "$OPT_T/upstream/.claude-plugin" "$OPT_T/upstream/.codex-plugin"
  printf '{"name":"egm","version":"0.1.0"}\n' > "$OPT_T/upstream/plugin.json"
  cp "$OPT_T/upstream/plugin.json" "$OPT_T/upstream/.claude-plugin/plugin.json"
  cp "$OPT_T/upstream/plugin.json" "$OPT_T/upstream/.codex-plugin/plugin.json"
  printf 'Read the bundled standard.\n' > "$OPT_T/upstream/skills/egm-review/SKILL.md"
  printf 'Fresh-context reviewer.\n' > "$OPT_T/upstream/agents/design.md"
  printf 'Bundled design standard.\n' > "$OPT_T/upstream/resources/document_standards/design.md"
  command git init -q "$OPT_T/upstream"
  command git -C "$OPT_T/upstream" config user.name Fixture
  command git -C "$OPT_T/upstream" config user.email fixture@example.test
  command git -C "$OPT_T/upstream" add .
  command git -C "$OPT_T/upstream" commit -q -m 'Fixture plugin bundle'
  OPT_REF="$(command git -C "$OPT_T/upstream" rev-parse HEAD)"
  printf 'plugins:\n  egm: {source: example/egm, ref: %s}\n' "$OPT_REF" > "$CEL_ROOT/optional-plugins.yaml"
  # Keep real checkout/pin/status behavior. Redirect only the remote fetch to
  # the isolated repository, so no network or live harness is involved.
  git() {
    local previous="" directory="" arg fetch=0
    for arg in "$@"; do
      [ "$previous" != -C ] || directory="$arg"
      [ "$arg" != fetch ] || fetch=1
      previous="$arg"
    done
    if [ "$fetch" = 1 ]; then command git -C "$directory" remote set-url origin "$OPT_T/upstream"; fi
    command git "$@"
  }
  _optional_consume() {
    local runtime="$1"; shift
    if [ "$1 $2 $3" = 'plugin marketplace add' ]; then
      printf '%s' "$4" > "$OPT_T/$runtime-market"
      return
    fi
    [ "$1 $2" = 'plugin install' ] || [ "$1 $2" = 'plugin add' ] || return 99
    local market bundle
    market="$(cat "$OPT_T/$runtime-market")"
    if [ "$runtime" = codex ]; then
      bundle="$market/$(jq -r '.plugins[0].source' "$market/.agents/plugins/marketplace.json")"
    else
      bundle="$market/$(jq -r '.plugins[0].source' "$market/.claude-plugin/marketplace.json")"
    fi
    [ "$(command git -C "$bundle" rev-parse HEAD)" = "$OPT_REF" ] || return 1
    [ -f "$bundle/skills/egm-review/SKILL.md" ] && [ -f "$bundle/agents/design.md" ] || return 1
    cat "$bundle/resources/document_standards/design.md" > "$OPT_T/$runtime-consumed-standard"
  }
  omp() { _optional_consume omp "$@"; }
  claude() { _optional_consume claude "$@"; }
  codex() { _optional_consume codex "$@"; }
}

test_optional_plugin_installs_the_same_pinned_complete_bundle_for_supported_harnesses() (
  _optional_fixture
  local runtime
  for runtime in omp claude codex; do
    cmd_plugins install egm --runtime "$runtime" >/dev/null
    assert_eq "$(cat "$OPT_T/$runtime-consumed-standard")" 'Bundled design standard.'
  done
  rm -rf "$OPT_T"
)

test_optional_plugin_dry_run_and_unsupported_runtime_do_not_install_or_create_cache() (
  _optional_fixture
  cmd_plugins install egm --runtime omp --dry-run >/dev/null
  assert_fails cmd_plugins install egm --runtime opencode
  assert_fails cmd_plugins install egm --runtime pi
  assert_fails cmd_plugins install unknown --runtime omp
  [ ! -e "$XDG_DATA_HOME" ]
  [ ! -e "$OPT_T/omp-market" ]
  rm -rf "$OPT_T"
)

test_optional_plugin_refuses_and_preserves_an_edited_cached_bundle() (
  _optional_fixture
  cmd_plugins install egm --runtime omp >/dev/null
  local bundle="$XDG_DATA_HOME/celestial/optional-plugins/egm/$OPT_REF/bundle"
  printf 'Owner modification.\n' > "$bundle/agents/design.md"
  rm "$OPT_T/omp-consumed-standard"
  assert_fails cmd_plugins install egm --runtime omp
  assert_eq "$(cat "$bundle/agents/design.md")" 'Owner modification.'
  [ ! -e "$OPT_T/omp-consumed-standard" ]
  rm -rf "$OPT_T"
)

test_optional_plugin_missing_resources_never_reaches_native_installation() (
  _optional_fixture
  command git -C "$OPT_T/upstream" rm -q resources/document_standards/design.md
  command git -C "$OPT_T/upstream" commit -q -m 'Remove required fixture resource'
  OPT_REF="$(command git -C "$OPT_T/upstream" rev-parse HEAD)"
  printf 'plugins:\n  egm: {source: example/egm, ref: %s}\n' "$OPT_REF" > "$CEL_ROOT/optional-plugins.yaml"
  assert_fails cmd_plugins install egm --runtime omp
  [ ! -e "$OPT_T/omp-market" ]
  rm -rf "$OPT_T"
)

test_optional_plugin_invalid_pin_fails_discovery_without_partial_output() (
  _optional_fixture
  printf 'plugins:\n  egm: {source: example/egm, ref: main}\n' > "$CEL_ROOT/optional-plugins.yaml"
  local output
  if output="$(cmd_plugins list 2>/dev/null)"; then return 1; fi
  assert_eq "$output" ''
  [ ! -e "$XDG_DATA_HOME" ]
  rm -rf "$OPT_T"
)
