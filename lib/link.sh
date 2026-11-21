# shellcheck shell=bash
# The symlink layer. This is where the boundary between contexts is enforced:
# a scoped skill is ABSENT from a foreign repo rather than merely discouraged.
#
# Core skills are symlinked, never copied, so editing one is live everywhere
# immediately.
[ -n "${_CEL_LINK:-}" ] && return 0
_CEL_LINK=1
# shellcheck source=lib/manifest.sh
. "${BASH_SOURCE[0]%/*}/manifest.sh"

# A link into core/skills/ whose skill was retired (fanout, pr-loop) is
# removed: a dangling skill link is listed by some runtimes and read as an
# instruction to use a tool that no longer exists.
#
# The plane once linked omp's and pi's skills into ~/.omp/skills and
# ~/.pi/skills, which neither reads (both read <agent root>/skills). Its links
# left there are removed; anything else there is the user's and stays.
_CEL_UNREAD_SKILLS_DIRS=(.omp/skills .pi/skills)
link_core_skills() {
  local a sd s l d linked=" "
  for a in $(agent_names); do
    sd="$(agent_skills_dir "$a")"
    [ -z "$sd" ] && continue
    mkdir -p "$sd"
    linked+="$sd "
    for s in "$CEL_ROOT"/core/skills/*/; do
      [ -d "$s" ] || continue
      ln -sfn "${s%/}" "$sd/$(basename "${s%/}")"
    done
    for l in "$sd"/*; do
      [ -L "$l" ] && [ ! -e "$l" ] || continue
      case "$(readlink "$l")" in
        "$CEL_ROOT"/core/skills/*) rm -f "$l"; c_warn "removed retired skill link: $l" ;;
      esac
    done
    c_ok "$a skills -> $sd"
  done
  for d in "${_CEL_UNREAD_SKILLS_DIRS[@]}"; do
    case "$linked" in *" $HOME/$d "*) continue ;; esac
    for l in "$HOME/$d"/*; do
      [ -L "$l" ] || continue
      case "$(readlink "$l")" in "$CEL_ROOT"/core/skills/*) rm -f "$l" ;; esac
    done
  done
  return 0
}

# A vendored skill's npm inputs (vendored-skills.yaml) are not committed; they
# are fetched here, from the pinned tarball, into the skill's own directory.
# Files already present with their pinned sha256 are kept, so once a box has
# them this needs no network. A failed fetch leaves the skill linked and the
# rest of the plane working, and says what is missing.
fetch_vendored_skills() {
  [ -f "$CEL_ROOT/vendored-skills.yaml" ] || return 0
  local out l
  if out="$(python3 "$CEL_ROOT/tools/skills/vendor.py" fetch 2>&1)"; then
    while IFS= read -r l; do [ -z "$l" ] || c_ok "$l"; done <<< "$out"
  else
    c_warn "vendored skill inputs not fetched (${out##*vendor.py: }); rerun \`cel update\` online"
  fi
  return 0
}

# CODEX AND WORKSPACE-SCOPED SKILLS. Codex finds skills only in the repo
# (cwd up to the git root), ~/.agents/skills (which omp, pi and OpenCode read
# too) and its own skills dir; it has no per-launch skill directory. So every
# workspace-scoped skill (vendored-skills.yaml `set:`) is linked into
# codex's skills dir - which no other runtime reads - and DISABLED in its
# config.toml, in one marked block; a launch for a declared workspace enables
# that workspace's with `-c skills.config=[...]` (lib/run.sh), which codex
# merges over this block per path. Codex matches the entry by the skill's
# resolved path. The block is written before a link appears and outlives it,
# so there is never a moment a scoped skill is enabled everywhere. A
# config.toml that already sets skills.config itself is not edited: the
# scoped links are then removed and codex gets none of them.
_CEL_CODEX_SKILLS_BEGIN='# cel:workspace-skills:begin - cel update writes this block: workspace-scoped skills are off unless a cel launch enables them'
_CEL_CODEX_SKILLS_END='# cel:workspace-skills:end'
_link_codex_block() { # <config.toml> <skills-dir> <names...> -> the file with the block for <names> at its end
  local f="$1" sd="$2" n p; shift 2
  [ ! -f "$f" ] || awk -v b="$_CEL_CODEX_SKILLS_BEGIN" -v e="$_CEL_CODEX_SKILLS_END" \
    '$0 == b {skip = 1; next} skip && $0 == e {skip = 0; next} !skip' "$f"
  [ "$#" -gt 0 ] || return 0
  printf '%s\n' "$_CEL_CODEX_SKILLS_BEGIN"
  for n in "$@"; do
    p="$sd/$n/SKILL.md"; p="${p//\\/\\\\}"; p="${p//\"/\\\"}"
    printf '[[skills.config]]\npath = "%s"\nenabled = false\n' "$p"
  done
  printf '%s\n' "$_CEL_CODEX_SKILLS_END"
}
link_codex_workspace_skills() {
  local a sd f names n l tmp keep=" "
  [ -f "$CEL_ROOT/vendored-skills.yaml" ] || return 0
  for a in $(agent_names); do
    [ "$(agent_workspace_skills "$a" strategy)" = codex_config ] || continue
    sd="$(agent_skills_dir "$a")"
    [ -n "$sd" ] || continue
    f="${sd%/*}/config.toml"
    if ! names="$(python3 "$CEL_ROOT/tools/skills/vendor.py" scoped 2>&1)"; then
      c_warn "$a: workspace-scoped skills not linked (${names##*vendor.py: })"; continue
    fi
    # shellcheck disable=SC2086  # names are skill names, one word each
    if [ -f "$f" ] && _link_codex_block "$f" "$sd" | grep -qE '^[[:space:]]*(\[\[?[[:space:]]*skills[]. ]|skills[[:space:]]*[.=])'; then
      c_warn "$a: $f already configures skills itself; workspace-scoped skills are not linked for $a"
      names=""
    fi
    for n in $names; do keep+="$n "; done
    # Unlink what is no longer scoped before its entry goes; add entries
    # before their links appear.
    for l in "$sd"/*; do
      [ -L "$l" ] || continue
      case "$(readlink "$l")" in
        "$CEL_ROOT"/core/workspace-skills/*) case "$keep" in *" ${l##*/} "*) ;; *) rm -f "$l" ;; esac ;;
      esac
    done
    mkdir -p "${f%/*}" || return
    tmp="$(mktemp "$f.cel-XXXXXX")" || return
    # shellcheck disable=SC2086
    if ! _link_codex_block "$f" "$sd" $names > "$tmp"; then rm -f "$tmp"; return 1; fi
    if [ -f "$f" ] && cmp -s "$tmp" "$f"; then
      rm -f "$tmp"
    elif [ ! -f "$f" ] && [ ! -s "$tmp" ]; then
      rm -f "$tmp"
    else
      [ ! -f "$f" ] || chmod --reference="$f" "$tmp"
      mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    fi
    [ -z "$names" ] || mkdir -p "$sd"
    for n in $names; do ln -sfn "$CEL_ROOT/core/workspace-skills/$n" "$sd/$n"; done
    [ -z "$names" ] || c_ok "$a workspace-scoped skills -> $sd (disabled unless a launch enables them)"
  done
  return 0
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

# Role bodies must never sit in an agents dir, where they become globally
# dispatchable subagents. Remove any link into core/roles/ or a fleet-agents
# checkout.
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

# herdr-plugin-workspace-manager reads config.yml from its own config
# directory (`herdr plugin config-dir`) and nowhere else.
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


# Box-wide Claude Code preferences the plane asserts everywhere. Objects are
# deep-merged; the plane's UserPromptSubmit hook is appended once, preserving
# the user's handlers. Its script path is resolved here so Claude need not
# inherit CEL_ROOT in unrelated sessions.
link_claude_prefs() {
  local prefs="$CEL_ROOT/tools/claude/settings-prefs.json"
  local settings="$HOME/.claude/settings.json"
  if [ -f "$prefs" ]; then
    mkdir -p "$HOME/.claude"
    [ -f "$settings" ] || echo '{}' > "$settings"
    local hook_command merged
    printf -v hook_command 'bash %q' "$CEL_ROOT/tools/hooks/inbox-drain.sh"
    merged="$(jq -S --arg hook_command "$hook_command" --slurpfile p "$prefs" '
      def append_unique:
        reduce .[] as $item
          ([]; if any(.[]; . == $item) then . else . + [$item] end);
      . as $current
      | ($p[0] | .hooks.UserPromptSubmit[0].hooks[0].command = $hook_command) as $plane
      | ($current * $plane)
      # An entry an older install wrote with the placeholder unresolved runs a
      # command that does not exist on every prompt; the plane wrote it, so it
      # goes.
      | .hooks.UserPromptSubmit =
          ((($current.hooks.UserPromptSubmit // [])
              | map(.hooks = [(.hooks // [])[] | select(((.command // "") | test("^__CEL_[A-Z_]+__$")) | not)])
              | map(select((.hooks | length) > 0)) +
            ($plane.hooks.UserPromptSubmit // [])) | append_unique)
    ' "$settings")" || return 1
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
  # The in-agent commands (/cel-mode, /cel-status, ... - lib/here.sh), one
  # link per file so the user's own commands stay theirs. A link into a plane
  # commands dir whose file is gone is pruned, so a retired command goes too.
  local cmds="$CEL_ROOT/tools/claude/commands" dest="$HOME/.claude/commands" f l n=0
  if [ -d "$cmds" ]; then
    mkdir -p "$dest"
    for l in "$dest"/cel-*.md; do
      [ -L "$l" ] && [ ! -e "$l" ] || continue
      case "$(readlink "$l")" in */tools/claude/commands/*) rm -f "$l" ;; esac
    done
    for f in "$cmds"/cel-*.md; do
      [ -f "$f" ] || continue
      ln -sfn "$f" "$dest/$(basename "$f")"; n=$((n + 1))
    done
    c_ok "claude commands -> plane copies ($n: /cel-*)"
  fi
}

link_all() {
  if declare -F generate_skills >/dev/null; then generate_skills || return; fi
  fetch_vendored_skills
  c_hd "Linking core"
  unlink_stale_roles
  link_core_skills
  link_codex_workspace_skills
  link_core_agents
  link_herdr_layouts
  link_claude_prefs
}
