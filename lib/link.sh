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
# shellcheck source=lib/agy.sh
. "${BASH_SOURCE[0]%/*}/agy.sh"

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
# config.toml, in one marked block (tools/skills/vendor.py codex-config); a
# launch for a declared workspace enables that workspace's with
# `-c skills.config=[...]` (lib/run.sh), which codex merges over this block
# per path. Codex resolves a skill's path before matching an entry (0.166,
# proved with the link path and the resolved one), and both sides write the
# resolved path. The block is written before a link appears and outlives it,
# so a scoped skill is never enabled everywhere. A config.toml vendor.py will
# not edit (one of the user's own skills settings in any spelling, an
# incomplete block of ours, invalid TOML) is left alone and codex gets none
# of them: their links are removed.
link_codex_workspace_skills() {
  local a sd f names n l tmp keep refused
  local -a paths
  [ -f "$CEL_ROOT/vendored-skills.yaml" ] || return 0
  for a in $(agent_names); do
    [ "$(agent_workspace_skills "$a" strategy)" = codex_config ] || continue
    sd="$(agent_skills_dir "$a")"
    [ -n "$sd" ] || continue
    f="${sd%/*}/config.toml"
    if ! names="$(python3 "$CEL_ROOT/tools/skills/vendor.py" scoped 2>&1)"; then
      c_warn "$a: workspace-scoped skills not linked (${names##*vendor.py: })"; continue
    fi
    paths=() keep=" " refused=0
    for n in $names; do paths+=("$(readlink -f -- "$CEL_ROOT/core/workspace-skills/$n")/SKILL.md"); done
    mkdir -p "${f%/*}" || return
    tmp="$(mktemp "$f.cel-XXXXXX")" || return
    if python3 "$CEL_ROOT/tools/skills/vendor.py" codex-config "$f" ${paths[@]+"${paths[@]}"} > "$tmp" 2> "$tmp.err"; then
      for n in $names; do keep+="$n "; done
    else
      c_warn "$a: workspace-scoped skills not linked for $a ($(sed -n 's/^vendor.py: //p' "$tmp.err" | head -1))"
      names="" refused=1
    fi
    rm -f "$tmp.err"
    # Unlink what is no longer scoped (or everything, on a refusal) before
    # its entry goes; add entries before their links appear.
    for l in "$sd"/*; do
      [ -L "$l" ] || continue
      case "$(readlink "$l")" in
        "$CEL_ROOT"/core/workspace-skills/*) case "$keep" in *" ${l##*/} "*) ;; *) rm -f "$l" ;; esac ;;
      esac
    done
    if [ "$refused" = 1 ] || { [ -f "$f" ] && cmp -s "$tmp" "$f"; } || { [ ! -f "$f" ] && [ ! -s "$tmp" ]; }; then
      rm -f "$tmp"
    else
      [ ! -f "$f" ] || chmod --reference="$f" "$tmp"
      mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    fi
    [ -n "$names" ] || continue
    mkdir -p "$sd"
    for n in $names; do ln -sfn "$CEL_ROOT/core/workspace-skills/$n" "$sd/$n"; done
    c_ok "$a workspace-scoped skills -> $sd (disabled unless a launch enables them)"
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
# inherit CEL_ROOT in unrelated sessions. Claude's guard
# (tools/hooks/orchestrator-guard.sh) is one PreToolUse entry naming the
# INSTALLED plane (installed_plane_root, lib/agy.sh), never a worktree: every
# other PreToolUse hook (the user's, moshi's, Orca's...) stays where it is,
# and only a guard hook an older install wrote is replaced. Codex has no hook
# API, so it has no guard to register.
link_claude_prefs() {
  local prefs="$CEL_ROOT/tools/claude/settings-prefs.json"
  local settings="$HOME/.claude/settings.json"
  if [ -f "$prefs" ]; then
    mkdir -p "$HOME/.claude"
    [ -f "$settings" ] || echo '{}' > "$settings"
    local hook_command guard_command merged
    printf -v hook_command 'bash %q' "$CEL_ROOT/tools/hooks/inbox-drain.sh"
    printf -v guard_command 'bash %q' "$(installed_plane_root)/tools/hooks/orchestrator-guard.sh"
    merged="$(jq -S --arg hook_command "$hook_command" --arg guard_command "$guard_command" --slurpfile p "$prefs" '
      def append_unique:
        reduce .[] as $item
          ([]; if any(.[]; . == $item) then . else . + [$item] end);
      . as $current
      | ($p[0] | .hooks.UserPromptSubmit[0].hooks[0].command = $hook_command) as $plane
      | {matcher: "Bash|Edit|Write|MultiEdit|NotebookEdit",
         hooks: [{type: "command", command: $guard_command, timeout: 10}]} as $guard
      | ($current * $plane)
      # An entry an older install wrote with the placeholder unresolved runs a
      # command that does not exist on every prompt; the plane wrote it, so it
      # goes.
      | .hooks.UserPromptSubmit =
          ((($current.hooks.UserPromptSubmit // [])
              | map(.hooks = [(.hooks // [])[] | select(((.command // "") | test("^__CEL_[A-Z_]+__$")) | not)])
              | map(select((.hooks | length) > 0)) +
            ($plane.hooks.UserPromptSubmit // [])) | append_unique)
      # The guard entry, once. A guard hook naming any other path (an older
      # install, a worktree) is dropped from its entry; an entry left empty goes.
      | .hooks.PreToolUse =
          (($current.hooks.PreToolUse // [])
            | map(if . == $guard then . else
                .hooks = [(.hooks // [])[] | select(((.command // "") | test("/tools/hooks/orchestrator-guard\\.sh")) | not)] end)
            | map(select((.hooks | length) > 0))
            | if any(.[]; . == $guard) then . else . + [$guard] end)
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
  # agy's guard, session and inbox hooks (lib/agy.sh); `cel run` installs
  # them too and refuses an agy launch without them.
  if have agy; then agy_hooks_link || c_warn "agy: celestial hooks not installed - agy launches are refused until they are"; fi
}
