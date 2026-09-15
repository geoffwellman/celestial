# shellcheck shell=bash
# The symlink layer. This is where the boundary between contexts is enforced:
# a scoped skill is ABSENT from a foreign repo rather than merely discouraged.
#
# Core skills are symlinked, never copied, so editing one is live everywhere
# immediately.
[ -n "${_CEL_LINK:-}" ] && return 0
_CEL_LINK=1
# shellcheck source=lib/manifest.sh
. "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"

link_core_skills() {
  local a sd s
  for a in $(agent_names); do
    sd="$(agent_skills_dir "$a")"
    [ -z "$sd" ] && continue
    mkdir -p "$sd"
    for s in "$CEL_ROOT"/core/skills/*/; do
      [ -d "$s" ] || continue
      ln -sfn "${s%/}" "$sd/$(basename "${s%/}")"
    done
    c_ok "$a skills -> $sd"
  done
}

# ONLY core/agents/ - genuine in-session subagents a worker calls mid-task.
# core/roles/ is deliberately absent: those are prompt bodies injected at launch
# while anything in an agents dir becomes globally dispatchable.
link_core_agents() {
  local a ad r linked
  for a in $(agent_names); do
    ad="$(agent_agents_dir "$a")"
    [ -z "$ad" ] && continue
    mkdir -p "$ad"; linked=0
    for r in "$CEL_ROOT"/core/agents/*.md; do
      [ -f "$r" ] || continue
      ln -sfn "$r" "$ad/$(basename "$r")"; linked=$((linked+1))
    done
    [ "$linked" -gt 0 ] && c_ok "$a subagents -> $ad ($linked)"
  done
  return 0
}

# The fleet-agents era linked the three role bodies into ~/.claude/agents, which
# is what exposed them to global subagent dispatch. Remove any such link, from
# either repo, wherever it still points at a roles directory.
unlink_stale_roles() {
  local a ad l target
  for a in $(agent_names); do
    ad="$(agent_agents_dir "$a")"
    [ -z "$ad" ] || [ ! -d "$ad" ] && continue
    for l in "$ad"/*.md; do
      [ -L "$l" ] || continue
      target="$(readlink -f "$l" 2>/dev/null || true)"
      case "$target" in
        */core/roles/*|*/fleet-agents/agents/*)
          rm -f "$l"; c_warn "removed stale role link: $l" ;;
      esac
    done
  done
  return 0
}

# CORRECTED in Task 4. The original linked $HOME/.config/herdr/layouts, which
# herdr-plugin-workspace-manager does not read - nothing in the plugin refers to
# that path, so the layout vendored there had never been applied to anything.
# The plugin reads config.yml from its own config directory and nowhere else.
link_herdr_layouts() {
  local cfg="$CEL_ROOT/tools/herdr/layouts/config.yml"
  [ -f "$cfg" ] || return 0
  have herdr || { c_warn "herdr not installed; layout not linked"; return 0; }
  local dir
  dir="$(herdr plugin config-dir herdr-plugin-workspace-manager 2>/dev/null)"
  [ -n "$dir" ] || { c_warn "workspace-manager not installed; layout not linked"; return 0; }
  mkdir -p "$dir"
  ln -sfn "$cfg" "$dir/config.yml"
  c_ok "herdr layout linked into $dir"
}


# Box-wide Claude Code preferences the plane asserts everywhere. Two parts:
# a deep-merge of tools/claude/settings-prefs.json into ~/.claude/settings.json
# (a real serialiser, never string concatenation), and the claude-hud config
# symlinked so HUD customisations are tracked in this repo. The merge is
# plane-wins for the keys it names and touches nothing else.
link_claude_prefs() {
  local prefs="$CEL_ROOT/tools/claude/settings-prefs.json"
  local settings="$HOME/.claude/settings.json"
  if [ -f "$prefs" ]; then
    mkdir -p "$HOME/.claude"
    [ -f "$settings" ] || echo '{}' > "$settings"
    local merged
    merged="$(jq -S --slurpfile p "$prefs" '. * $p[0]' "$settings")" || return 1
    if [ "$merged" != "$(jq -S . "$settings")" ]; then
      printf '%s\n' "$merged" > "$settings"
      c_ok "claude settings merged ($(jq -r 'keys|join(", ")' "$prefs"))"
    else
      c_ok "claude settings already carry the plane prefs"
    fi
  fi
  local hud="$CEL_ROOT/tools/claude/claude-hud.json"
  if [ -f "$hud" ]; then
    mkdir -p "$HOME/.claude/plugins/claude-hud"
    ln -sfn "$hud" "$HOME/.claude/plugins/claude-hud/config.json"
    c_ok "claude-hud config -> plane copy"
  fi
}

link_all() {
  if declare -F generate_skills >/dev/null; then generate_skills || return; fi
  c_hd "Linking core"
  unlink_stale_roles
  link_core_skills
  link_core_agents
  link_herdr_layouts
  link_claude_prefs
}
