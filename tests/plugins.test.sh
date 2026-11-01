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
  cmd_plugins install egm --runtime opencode --dry-run >/dev/null
  assert_fails cmd_plugins install egm --runtime gemini
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

# Pi: a fake `pi` that records the root it was handed and, like Pi 1.4's
# `pi install <local path>`, appends the path to that root's settings.json
# relative to the root. An inherited OMP root must never be the one written.
_pi_fixture() {
  _optional_fixture
  export PI_CODING_AGENT_DIR="$HOME/.omp/agent"
  PI_DIR="$HOME/.pi/agent"
  mkdir -p "$PI_DIR" "$OPT_T/other/skills/unrelated"
  printf '{"theme":"dark","defaultProvider":"keep-me","packages":["%s"]}\n' "$OPT_T/other" > "$PI_DIR/settings.json"
  pi() {
    [ "$1" = install ] && [ "$#" = 2 ] || return 99
    printf '%s\n' "$PI_CODING_AGENT_DIR" >> "$OPT_T/pi-calls"
    local s="$PI_CODING_AGENT_DIR/settings.json" doc
    doc="$(jq --arg p "$(realpath --relative-to="$PI_CODING_AGENT_DIR" "$2")" '.packages = ((.packages // []) + [$p])' "$s")"
    printf '%s\n' "$doc" > "$s"
  }
}

test_optional_plugin_pi_registers_the_complete_bundle_in_pis_own_settings_once() (
  _pi_fixture
  local out bundle registered sum
  out="$(cmd_plugins install egm --runtime pi)"
  assert_eq "$(cat "$OPT_T/pi-calls")" "$PI_DIR"
  assert_contains "$out" 'egm-review'
  assert_eq "$(jq -r '.theme + " " + .defaultProvider + " " + .packages[0]' "$PI_DIR/settings.json")" "dark keep-me $OPT_T/other"
  bundle="$XDG_DATA_HOME/celestial/optional-plugins/egm/$OPT_REF/bundle"
  registered="$(realpath -m "$PI_DIR/$(jq -r '.packages[1]' "$PI_DIR/settings.json")")"
  assert_eq "$registered" "$(realpath "$bundle")"
  # the package root is the whole pinned checkout, so skills reach their siblings
  assert_eq "$(command git -C "$registered" rev-parse HEAD)" "$OPT_REF"
  assert_eq "$(cat "$registered/resources/document_standards/design.md")" 'Bundled design standard.'
  [ -f "$registered/agents/design.md" ]
  [ ! -e "$HOME/.omp/agent/settings.json" ]
  sum="$(sha256sum < "$PI_DIR/settings.json")"
  out="$(cmd_plugins install egm --runtime pi)"
  assert_contains "$out" 'already present'
  assert_eq "$(wc -l < "$OPT_T/pi-calls")" 1
  assert_eq "$(sha256sum < "$PI_DIR/settings.json")" "$sum"
  rm -rf "$OPT_T"
)

test_optional_plugin_pi_dry_run_writes_nothing() (
  _pi_fixture
  local sum; sum="$(sha256sum < "$PI_DIR/settings.json")"
  assert_contains "$(cmd_plugins install egm --runtime pi --dry-run)" 'for pi'
  assert_eq "$(sha256sum < "$PI_DIR/settings.json")" "$sum"
  [ ! -e "$OPT_T/pi-calls" ] && [ ! -e "$XDG_DATA_HOME" ]
  rm -rf "$OPT_T"
)

test_optional_plugin_pi_refuses_every_conflict_and_leaves_settings_unchanged() (
  _pi_fixture
  local sum
  # a different pinned copy, the upstream repository as a Pi git package, a
  # hand-copied skill Pi auto-discovers, and an unparseable settings file
  mkdir -p "$OPT_T/old/skills/egm-review"
  jq --arg p "$OPT_T/old" '.packages += [$p]' "$PI_DIR/settings.json" > "$OPT_T/s" && mv "$OPT_T/s" "$PI_DIR/settings.json"
  sum="$(sha256sum < "$PI_DIR/settings.json")"
  assert_fails cmd_plugins install egm --runtime pi
  assert_eq "$(sha256sum < "$PI_DIR/settings.json")" "$sum"
  printf '{"packages":["git:github.com/example/egm@v1"]}\n' > "$PI_DIR/settings.json"
  assert_fails cmd_plugins install egm --runtime pi
  assert_eq "$(cat "$PI_DIR/settings.json")" '{"packages":["git:github.com/example/egm@v1"]}'
  printf '{"theme":"dark"}\n' > "$PI_DIR/settings.json"
  mkdir -p "$PI_DIR/skills/egm-review"
  assert_fails cmd_plugins install egm --runtime pi
  rm -rf "$PI_DIR/skills"
  printf '{"theme":' > "$PI_DIR/settings.json"
  assert_fails cmd_plugins install egm --runtime pi
  assert_eq "$(cat "$PI_DIR/settings.json")" '{"theme":'
  [ ! -e "$OPT_T/pi-calls" ]
  rm -rf "$OPT_T"
)

# The REAL installed Pi, in an isolated root, discovers every bundle skill from
# inside the bundle through rpc get_commands: no session, no model call.
test_optional_plugin_pi_real_cli_discovers_every_bundle_skill() (
  local bin; bin="$(mise which pi 2>/dev/null || command -v pi 2>/dev/null)" || { echo "pi not installed - skipped"; return 0; }
  export PATH="${bin%/*}:$PATH" # node + pi without a HOME-bound version-manager shim
  _optional_fixture
  unset PI_CODING_AGENT_DIR
  local d skill bundle out sum
  for skill in egm-review egm-draft; do
    mkdir -p "$OPT_T/upstream/skills/$skill"
    printf -- '---\nname: %s\ndescription: Fixture %s skill that reads ../../agents and ../../resources.\n---\nBody\n' "$skill" "$skill" > "$OPT_T/upstream/skills/$skill/SKILL.md"
  done
  command git -C "$OPT_T/upstream" add -A && command git -C "$OPT_T/upstream" commit -q -m 'Pi-loadable fixture skills'
  OPT_REF="$(command git -C "$OPT_T/upstream" rev-parse HEAD)"
  printf 'plugins:\n  egm: {source: example/egm, ref: %s}\n' "$OPT_REF" > "$CEL_ROOT/optional-plugins.yaml"
  d="$HOME/.pi/agent"; mkdir -p "$d" "$OPT_T/other/skills/unrelated"
  printf -- '---\nname: unrelated\ndescription: Unrelated fixture skill that must keep loading.\n---\nBody\n' > "$OPT_T/other/skills/unrelated/SKILL.md"
  printf '{"theme":"dark","packages":["%s"]}\n' "$OPT_T/other" > "$d/settings.json"
  cmd_plugins install egm --runtime pi >/dev/null
  bundle="$(realpath "$XDG_DATA_HOME/celestial/optional-plugins/egm/$OPT_REF/bundle")"
  out="$(cd "$OPT_T" && printf '{"type":"get_commands"}\n' | PI_CODING_AGENT_DIR="$d" PI_OFFLINE=1 PI_TELEMETRY=0 timeout 60 pi --mode rpc --no-session 2>/dev/null)"
  assert_eq "$(printf '%s\n' "$out" | jq -r --arg b "$bundle/skills/" 'select(.command == "get_commands") | .data.commands[]
    | select(.source == "skill" and (.sourceInfo.path | startswith($b))) | .name' | sort | tr '\n' ' ')" 'skill:egm-draft skill:egm-review '
  assert_contains "$out" 'skill:unrelated'
  assert_eq "$(jq -r '.theme' "$d/settings.json")" dark
  sum="$(sha256sum < "$d/settings.json")"
  cmd_plugins install egm --runtime pi >/dev/null
  assert_eq "$(sha256sum < "$d/settings.json")" "$sum"
  rm -rf "$OPT_T"
)

# OpenCode: the fixture persona and skill carry the frontmatter OpenCode reads.
# A fake `opencode` only satisfies the installed-runtime check; installing
# edits OpenCode's global config and never runs the client.
_opencode_fixture() {
  _optional_fixture
  unset OPENCODE_CONFIG_DIR OPENCODE_CONFIG OPENCODE_CONFIG_CONTENT
  export XDG_CONFIG_HOME="$OPT_T/config"
  OC_DIR="$XDG_CONFIG_HOME/opencode"
  printf -- '---\nname: egm-design\ndescription: Fixture design critic.\nlicense: Apache-2.0\n---\nFresh-context reviewer.\n' > "$OPT_T/upstream/agents/design.md"
  printf -- '---\nname: egm-review\ndescription: Fixture review skill.\n---\nRead the bundled standard.\n' > "$OPT_T/upstream/skills/egm-review/SKILL.md"
  command git -C "$OPT_T/upstream" commit -q -am 'OpenCode-readable fixture frontmatter'
  OPT_REF="$(command git -C "$OPT_T/upstream" rev-parse HEAD)"
  printf 'plugins:\n  egm: {source: example/egm, ref: %s}\n' "$OPT_REF" > "$CEL_ROOT/optional-plugins.yaml"
  OC_BUNDLE="$XDG_DATA_HOME/celestial/optional-plugins/egm/$OPT_REF/bundle"
  opencode() { return 99; }
}

test_optional_plugin_opencode_adds_bundle_skills_and_subagents_and_preserves_config() (
  _opencode_fixture
  local out sum
  mkdir -p "$OC_DIR"
  printf '{"$schema":"https://opencode.ai/config.json","plugin":["keep-me"],"shell":"/bin/zsh","skills":["~/mine"],"agents":{"mine":{"mode":"subagent"}}}\n' > "$OC_DIR/opencode.json"
  out="$(cmd_plugins install egm --runtime opencode)"
  assert_contains "$out" 'egm-design'
  assert_contains "$out" "$OC_BUNDLE/skills"
  assert_eq "$(jq -c '.skills' "$OC_DIR/opencode.json")" "[\"~/mine\",\"$OC_BUNDLE/skills\"]"
  assert_eq "$(jq -c '.agents["egm-design"]' "$OC_DIR/opencode.json")" \
    "{\"description\":\"Fixture design critic.\",\"mode\":\"subagent\",\"system\":\"{file:$OC_BUNDLE/agents/design.md}\"}"
  assert_eq "$(jq -c '[."$schema", .plugin, .shell, .agents.mine, has("default_agent")]' "$OC_DIR/opencode.json")" \
    '["https://opencode.ai/config.json",["keep-me"],"/bin/zsh",{"mode":"subagent"},false]'
  # skills resolve their siblings from inside the pinned checkout
  assert_eq "$(command git -C "$OC_BUNDLE" rev-parse HEAD)" "$OPT_REF"
  assert_eq "$(cat "$OC_BUNDLE/skills/egm-review/../../resources/document_standards/design.md")" 'Bundled design standard.'
  [ ! -e "$OC_DIR/opencode.jsonc" ]
  sum="$(sha256sum < "$OC_DIR/opencode.json")"
  assert_contains "$(cmd_plugins install egm --runtime opencode)" 'already lists'
  assert_eq "$(sha256sum < "$OC_DIR/opencode.json")" "$sum"
  rm -rf "$OPT_T"
)

test_optional_plugin_opencode_creates_config_replaces_its_own_old_pin_and_dry_runs_cleanly() (
  _opencode_fixture
  assert_contains "$(cmd_plugins install egm --runtime opencode --dry-run)" 'for opencode'
  [ ! -e "$XDG_CONFIG_HOME" ] && [ ! -e "$XDG_DATA_HOME" ]
  cmd_plugins install egm --runtime opencode >/dev/null
  assert_eq "$(jq -c '[.skills, (.agents | keys)]' "$OC_DIR/opencode.jsonc")" "[[\"$OC_BUNDLE/skills\"],[\"egm-design\"]]"
  # an earlier pin this adapter wrote is replaced, not duplicated
  local old="$XDG_DATA_HOME/celestial/optional-plugins/egm/0000000000000000000000000000000000000000/bundle"
  printf '{"skills":{"paths":["~/mine","%s/skills"]},"agents":{"egm-old":{"mode":"subagent","system":"{file:%s/agents/old.md}"}}}\n' "$old" "$old" > "$OC_DIR/opencode.jsonc"
  cmd_plugins install egm --runtime opencode >/dev/null
  assert_eq "$(jq -c '[.skills, (.agents | keys)]' "$OC_DIR/opencode.jsonc")" "[{\"paths\":[\"~/mine\",\"$OC_BUNDLE/skills\"]},[\"egm-design\"]]"
  rm -rf "$OPT_T"
)

test_optional_plugin_opencode_refuses_conflicts_and_leaves_config_unchanged() (
  _opencode_fixture
  local sum
  mkdir -p "$OC_DIR"
  # an owner agent with an EGM persona name
  printf '{"agents":{"egm-design":{"mode":"primary","system":"mine"}}}\n' > "$OC_DIR/opencode.json"
  sum="$(sha256sum < "$OC_DIR/opencode.json")"
  assert_fails cmd_plugins install egm --runtime opencode
  assert_eq "$(sha256sum < "$OC_DIR/opencode.json")" "$sum"
  # a legacy v1 `agent` map with that name
  printf '{"agent":{"egm-design":{"prompt":"mine"}}}\n' > "$OC_DIR/opencode.json"
  assert_fails cmd_plugins install egm --runtime opencode
  assert_eq "$(cat "$OC_DIR/opencode.json")" '{"agent":{"egm-design":{"prompt":"mine"}}}'
  # a hand-copied skill OpenCode already discovers under the same name
  printf '{}\n' > "$OC_DIR/opencode.json"
  mkdir -p "$HOME/.agents/skills/egm-review"
  assert_fails cmd_plugins install egm --runtime opencode
  assert_eq "$(cat "$OC_DIR/opencode.json")" '{}'
  rm -rf "$HOME/.agents"
  # JSONC with comments is never rewritten
  printf '{\n  // owner note\n  "shell": "/bin/zsh",\n}\n' > "$OC_DIR/opencode.json"
  sum="$(sha256sum < "$OC_DIR/opencode.json")"
  assert_fails cmd_plugins install egm --runtime opencode
  assert_eq "$(sha256sum < "$OC_DIR/opencode.json")" "$sum"
  rm -rf "$OPT_T"
)

# The REAL installed OpenCode, isolated, lists the bundle skills and persona
# subagents through its serve API, unscoped and under a Celestial-style
# OPENCODE_CONFIG_CONTENT whose default_agent must still win. No model call.
test_optional_plugin_opencode_real_serve_lists_bundle_skills_and_subagents() (
  local bin; bin="$(command -v opencode 2>/dev/null || ls "$HOME/.opencode/bin/opencode" 2>/dev/null)" || { echo "opencode not installed - skipped"; return 0; }
  _opencode_fixture
  unset -f opencode
  export PATH="${bin%/*}:$PATH" XDG_CACHE_HOME="$OPT_T/cache" XDG_STATE_HOME="$OPT_T/state"
  local scoped content label url pid skills agents
  cmd_plugins install egm --runtime opencode >/dev/null
  mkdir -p "$OPT_T/project" && command git init -q "$OPT_T/project"
  scoped='{"default_agent":"cel-fixture","agents":{"cel-fixture":{"description":"Scoped role","mode":"primary","system":"Fixture role."}}}'
  # credentials ride a netrc file, never the command line
  (umask 077; printf 'machine 127.0.0.1 login opencode password fixture\n' > "$OPT_T/netrc")
  for label in unscoped scoped; do
    content=""; [ "$label" = unscoped ] || content="$scoped"
    # exec keeps one pid from the subshell to the server; setsid makes it the
    # group leader, so the whole server tree stops with it
    (cd "$OPT_T/project" && exec env OPENCODE_PASSWORD=fixture OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_AUTOUPDATE=1 \
      ${content:+"OPENCODE_CONFIG_CONTENT=$content"} setsid "$bin" serve --hostname 127.0.0.1 --port 0 > "$OPT_T/serve.log" 2>&1) &
    pid=$! url="" skills=""
    for _ in $(seq 150); do url="$(grep -so 'http://127\.0\.0\.1:[0-9]*' "$OPT_T/serve.log" | head -n1)"; [ -n "$url" ] && break; sleep 0.2; done
    for _ in $(seq 150); do
      skills="$(curl -sf --netrc-file "$OPT_T/netrc" "$url/api/skill?location%5Bdirectory%5D=$(jq -rn --arg d "$OPT_T/project" '$d|@uri')" | jq -r '.data[] | .id + "=" + .path')"
      [[ "$skills" == *egm-review=* ]] && break; sleep 0.2
    done
    agents="$(curl -sf --netrc-file "$OPT_T/netrc" "$url/api/agent?location%5Bdirectory%5D=$(jq -rn --arg d "$OPT_T/project" '$d|@uri')" \
      | jq -c '[.data[0].id, (.data[] | select(.id == "egm-design") | .mode, .system)]')"
    kill -- -"$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    assert_contains "$skills" "egm-review=$OC_BUNDLE/skills/egm-review/SKILL.md"
    if [ "$label" = scoped ]; then local default=cel-fixture; else local default=build; fi
    assert_eq "$agents" "[\"$default\",\"subagent\",\"---\\nname: egm-design\\ndescription: Fixture design critic.\\nlicense: Apache-2.0\\n---\\nFresh-context reviewer.\"]"
  done
  rm -rf "$OPT_T"
)
