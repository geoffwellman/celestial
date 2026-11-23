# shellcheck shell=bash
# MCP servers and skills another installer registered box-wide (here REA's
# `rea setup`: an `rea` server in each runtime's user config and a real
# reverse-engineer-anything skill directory) survive every Celestial writer
# of those same files: the link pass `cel setup` and `cel update` run
# (core skill links and their stale-link cleanup, the codex marked block,
# the claude settings merge, agy's hooks.json entry), a claude launch's
# trust write to ~/.claude.json, a workspace sync's OpenCode skills overlay
# and an OpenCode scoped launch config, and the opt-in OpenCode plugin
# writer. The entry is compared as written, not only as parsed; a file the
# writer has no business with is compared whole.

_ump_setup() {
  T="$(mktemp -d)"
  export HOME="$T/home" XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$T/home/.config"
  # the runner points claude at its own config dir; this proof is about HOME
  unset CLAUDE_CONFIG_DIR OPENCODE_CONFIG_DIR
  mkdir -p "$HOME" "$T/bin"
  export CEL_MANIFEST="$CEL_ROOT/agents.yaml" CEL_MANIFEST_CACHE="$T/cache"
  # agy is "installed" so the link pass writes its hooks.json entry
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/agy"; chmod +x "$T/bin/agy"
  export PATH="$T/bin:$PATH"
  source "$CEL_ROOT/lib/common.sh"
  source "$CEL_ROOT/lib/manifest.sh"
  source "$CEL_ROOT/lib/workspace.sh"
  source "$CEL_ROOT/lib/link.sh"
  # it writes only into the checkout's own core/skills, never under HOME
  fetch_vendored_skills() { :; }
  _ump_seed
}

_ump_node="/opt/fixture/node/24.22.3/bin"

# What `rea setup --client claude_code codex opencode antigravity omp pi`
# leaves behind, in each runtime's own format (placeholders, not a real box).
_ump_seed() {
  local n="$_ump_node" d
  mkdir -p "$HOME/.codex" "$HOME/.config/opencode" "$HOME/.gemini/config" "$HOME/.omp/agent" "$HOME/.pi/agent" "$HOME/.claude"
  cat > "$HOME/.claude.json" <<JSON
{
  "numStartups": 3,
  "projects": {
    "/srv/old": {
      "hasTrustDialogAccepted": true
    }
  },
  "mcpServers": {
    "rea": {
      "command": "$n/node",
      "args": [
        "$n/rea",
        "mcp"
      ],
      "env": {
        "REA_MCP_TOOL_CATALOG_PROFILE": "hot-cold"
      }
    }
  }
}
JSON
  # The order REA leaves on a box Celestial already linked: its table after
  # our marked block.
  cat > "$HOME/.codex/config.toml" <<TOML
model = "gpt-fixture"

[mcp_servers.hindsight]
command = "node"
args = ["/opt/fixture/hindsight.js"]

# cel:workspace-skills:begin - cel update writes this block: workspace-scoped skills are off unless a cel launch enables them
[[skills.config]]
path = "/opt/fixture/retired/SKILL.md"
enabled = false
# cel:workspace-skills:end

[mcp_servers.rea]
command = "$n/node"
args = [ "$n/rea", "mcp" ]
startup_timeout_sec = 30
tool_timeout_sec = 450

[mcp_servers.rea.env]
REA_MCP_TOOL_CATALOG_PROFILE = "hot-cold"
TOML
  cat > "$HOME/.config/opencode/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "mcp": {
    "rea": {
      "type": "local",
      "command": [
        "$n/node",
        "$n/rea",
        "mcp"
      ],
      "enabled": true,
      "environment": {
        "REA_MCP_TOOL_CATALOG_PROFILE": "hot-cold"
      }
    }
  }
}
JSON
  cat > "$HOME/.gemini/config/mcp_config.json" <<JSON
{
  "mcpServers": {
    "rea": {
      "command": "$n/node",
      "args": ["$n/rea", "mcp"],
      "env": { "REA_MCP_TOOL_CATALOG_PROFILE": "hot-cold" }
    }
  }
}
JSON
  cat > "$HOME/.omp/agent/mcp.json" <<JSON
{
  "\$schema": "https://example.invalid/omp-mcp.json",
  "mcpServers": {
    "hindsight": { "command": "node", "args": ["/opt/fixture/hindsight.js"] },
    "rea": { "type": "stdio", "command": "$n/node", "args": ["$n/rea", "mcp"], "env": { "REA_MCP_TOOL_CATALOG_PROFILE": "hot-cold" } }
  }
}
JSON
  cp "$HOME/.gemini/config/mcp_config.json" "$HOME/.pi/agent/mcp.json"
  # REA's skill: a real directory (not a link) in the shared, claude and
  # Antigravity skill roots.
  for d in "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.gemini/config/skills"; do
    mkdir -p "$d/reverse-engineer-anything/references"
    printf -- '---\nname: reverse-engineer-anything\ndescription: fixture\n---\nbody\n' > "$d/reverse-engineer-anything/SKILL.md"
    printf 'reference\n' > "$d/reverse-engineer-anything/references/tools.md"
  done
  _ump_snapshot > "$T/before"
}

# The rea entry of each config exactly as written (its text span), the
# skill trees, and the whole of every file no Celestial writer may touch.
_ump_snapshot() {
  local f d
  printf 'claude %s\n' "$(jq -cS '.mcpServers.rea' "$HOME/.claude.json")"
  printf 'claude-text %s\n' "$(awk '/^    "rea": \{$/,/^    \}$/' "$HOME/.claude.json" | cksum)"
  printf 'codex-text %s\n' "$(awk '/^\[mcp_servers\.rea(\.|\])/{p=1} /^\[/ && !/^\[mcp_servers\.rea(\.|\])/{p=0} /^# cel:workspace-skills/{p=0} p' "$HOME/.codex/config.toml" | sed '/^$/d' | cksum)"
  printf 'codex %s\n' "$(python3 -c 'import sys,tomllib,json; print(json.dumps(tomllib.load(open(sys.argv[1],"rb"))["mcp_servers"]["rea"],sort_keys=True))' "$HOME/.codex/config.toml")"
  printf 'opencode %s\n' "$(jq -cS '.mcp.rea' "$HOME/.config/opencode/opencode.json")"
  for f in "$HOME/.gemini/config/mcp_config.json" "$HOME/.omp/agent/mcp.json" "$HOME/.pi/agent/mcp.json"; do
    printf 'file %s %s\n' "${f#"$HOME"/}" "$(cksum < "$f")"
  done
  for d in "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.gemini/config/skills"; do
    [ -d "$d/reverse-engineer-anything" ] && [ ! -L "$d/reverse-engineer-anything" ] || printf 'NOT A REAL DIR %s\n' "$d"
    printf 'skill %s %s\n' "${d#"$HOME"/}" "$(cd "$d/reverse-engineer-anything" && find . -print0 | LC_ALL=C sort -z | xargs -0 cksum 2>/dev/null | cksum)"
  done
}

_ump_assert_kept() { # <after which step>
  _ump_snapshot > "$T/after"
  diff "$T/before" "$T/after" >&2 || { echo "the rea entry or skill changed after: $1"; return 1; }
}

test_link_pass_keeps_rea_mcp_entries_and_its_skill() {
  _ump_setup
  link_all >/dev/null 2>&1 || { echo "link_all failed"; return 1; }
  _ump_assert_kept "link_all" || return 1
  # the pass did run its writers over these same files
  grep -q '^# cel:workspace-skills:end' "$HOME/.codex/config.toml" || { echo "codex block not written"; return 1; }
  jq -e '.celestial.PreToolUse' "$HOME/.gemini/config/hooks.json" >/dev/null || { echo "agy hooks not written"; return 1; }
  [ -L "$HOME/.claude/skills/review" ] || { echo "core skills not linked"; return 1; }
  # and a second pass is a no-op on codex's file
  local sum; sum="$(cksum < "$HOME/.codex/config.toml")"
  link_all >/dev/null 2>&1 || return 1
  assert_eq "$(cksum < "$HOME/.codex/config.toml")" "$sum" || return 1
  _ump_assert_kept "a second link_all" || return 1
  rm -rf "$T"
}

test_claude_trust_write_keeps_the_rea_entry() {
  _ump_setup
  source "$CEL_ROOT/lib/run.sh"
  mkdir -p "$T/lane"
  _run_claude_trust_dir "$T/lane" || { echo "trust write failed"; return 1; }
  assert_eq "$(jq -r --arg d "$T/lane" '.projects[$d].hasTrustDialogAccepted' "$HOME/.claude.json")" true || return 1
  _ump_assert_kept "the claude trust write" || return 1
  rm -rf "$T"
}

test_opencode_overlays_and_scoped_launch_config_leave_the_global_mcp_alone() {
  _ump_setup
  source "$CEL_ROOT/lib/opencode.sh"
  local ws="$T/ws" sum role config
  sum="$(cksum < "$HOME/.config/opencode/opencode.json")"
  mkdir -p "$ws/repos/app"; git -C "$ws/repos/app" init -q
  printf 'name: ws\nskill_sets: [cloudflare]\n' > "$ws/workspace.yaml"
  ws_link_vendored_skills "$ws" >/dev/null || { echo "workspace skills not linked"; return 1; }
  # the OPENCODE_CONFIG overlay names skills only: OpenCode merges it over
  # the global file, whose mcp then stands
  assert_eq "$(jq -c 'keys' "$ws/.cel/skills/opencode.json")" '["skills"]' || return 1
  role="$ws/.cel/opencode/fixture-orch/role-orchestrator.md"; config="${role%.md}.opencode.json"
  mkdir -p "${role%/*}"
  jq -n --arg role "$role" --arg plugin "$CEL_ROOT/tools/opencode/plugin" '{
    agent:"cel-orchestrator",roleFile:$role,pluginFile:$plugin,modelID:"gpt-6.1-sol",transport:"gateway",
    baseURL:"http://127.0.0.1:8317/v1",route:"{env:CEL_SESSION_ID}",limit:{context:500000,output:128000}
  }' | opencode_write_config "$config" || { echo "scoped config not built"; return 1; }
  opencode_agent_args orchestrator 'role body' 0 "$role" "$config" http://127.0.0.1:8317/v1 || return 1
  # OPENCODE_CONFIG_CONTENT layers over the global file and declares no mcp
  assert_eq "$(jq 'has("mcp")' "$config")" false || return 1
  assert_eq "$(cksum < "$HOME/.config/opencode/opencode.json")" "$sum" || { echo "global opencode.json rewritten"; return 1; }
  _ump_assert_kept "the OpenCode overlay and scoped launch config" || return 1
  rm -rf "$T"
}

test_opencode_optional_plugin_writer_keeps_the_rea_entry() {
  _ump_setup
  source "$CEL_ROOT/lib/plugins.sh"
  local bundle="$XDG_DATA_HOME/celestial/optional-plugins/egm/0123456789abcdef0123456789abcdef01234567/bundle"
  mkdir -p "$bundle/skills/egm-review" "$bundle/agents"
  printf -- '---\nname: egm-review\ndescription: fixture\n---\n' > "$bundle/skills/egm-review/SKILL.md"
  printf -- '---\nname: egm-design\ndescription: Fixture persona\n---\nbody\n' > "$bundle/agents/design.md"
  _plugins_opencode_install egm "$bundle" >/dev/null || { echo "plugin writer failed"; return 1; }
  assert_eq "$(jq -r '.agents["egm-design"].mode' "$HOME/.config/opencode/opencode.json")" subagent || return 1
  _ump_assert_kept "the OpenCode plugin writer" || return 1
  rm -rf "$T"
}
