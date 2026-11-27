# shellcheck shell=bash
# GOOGLE ANTIGRAVITY CLI (agy): what its agents.yaml row cannot say.
#
# agy has no system-prompt flag and loads no hooks from --settings, and a
# directory added with --add-dir becomes a workspace folder (agy runs every
# command in the alphabetically first one). So a launch carries:
#   its role and scoped skills  a custom agent file per agent name, chosen
#                               with --agent: the body is the system prompt,
#                               the frontmatter grants agy's toolset and
#                               names this workspace's skills
#   its folder trust            --settings for this launch only (agy never
#                               saves it), so no first-run trust prompt
#   its first turn              -i: the Stop hook arms the inbox waiter on it
# and the box carries one `celestial` entry in the global
# ~/.gemini/config/hooks.json: the guard (PreToolUse) and session/inbox
# (SessionStart, PreInvocation, Stop). Every one of those scripts does
# nothing for a session cel did not launch, except the guard, which judges
# every agy session by where it stands, as claude's global hook does.
[ -n "${_CEL_AGY:-}" ] && return 0
_CEL_AGY=1
# shellcheck source=lib/manifest.sh
. "${BASH_SOURCE[0]%/*}/manifest.sh"

# THE TOOLS A CEL AGENT FILE GRANTS, by the names agy 1.5.14's agent-file
# registry resolves (one it does not know refuses the launch; none at all
# leaves six read-only tools): only those whose every argument the guard
# judges or that carry nothing it judges (tools/hooks/agy-guard.sh). Left
# out: schedule (a prompt that runs later), invoke_subagent, define_subagent
# and manage_subagents (agents the guard does not launch), run_workflow (a
# Python program). MCP servers come on top and are NOT guarded.
AGY_AGENT_TOOLS='read_file, run_command, write_file, edit_file, manage_task, send_message, search_web, ask_question'

# This workspace's scoped skills (lib/workspace.sh ws_link_vendored_skills),
# one directory per line, in glob order - the order _run_workspace_skills
# counts them in.
agy_workspace_skill_dirs() { # <wsdir>
  local d s; d="$(ws_skills_dir "$1")"
  for s in "$d"/skills/*/; do
    [ -f "$s/SKILL.md" ] && printf '%s\n' "${s%/}"
  done
  return 0
}

# THE ROLE IS AN AGENT FILE, one per agent name (unique among live agents),
# so two lanes or two workspaces never share or overwrite one. Written on
# every launch; a dry run writes nothing.
agy_agent_args() { # <agent-name> <body> <dry 0|1> <wsdir> -> AGENT_ARGS, AGENT_ROLE_FILE, AGENT_FILE_SKILLS
  local name="$1" body="$2" dry="$3" wsdir="$4" dir file tmp s
  local -a skills=() names=()
  [[ "$name" =~ ^[a-z][a-z0-9_-]*$ ]] || { c_err "agy: '$name' is not an agent name"; return 1; }
  dir="$(expand "$(agent_injection agy dir)")"; file="$dir/cel-$name.md"
  while IFS= read -r s; do
    skills+=("$s"); names+=("${s##*/}")
  done < <(agy_workspace_skill_dirs "$wsdir")
  if [ "$dry" -eq 0 ]; then
    mkdir -p "$dir" || return 1
    tmp="$(mktemp "$dir/.cel-$name.XXXXXX")" || return 1
    if ! {
      printf -- '---\nname: cel-%s\n' "$name"
      printf 'description: "Celestial agent %s - written by cel run at every launch; edits are overwritten"\n' "$name"
      printf 'subagent: false\nmainAgent: true\ntools: [%s]\n' "$AGY_AGENT_TOOLS"
      if [ "${#skills[@]}" -gt 0 ]; then
        printf 'skills:\n'
        for s in "${skills[@]}"; do printf '  - %s\n' "$(jq -cn --arg p "$s" '$p')"; done
      fi
      printf -- '---\n%s\n' "$body"
    } > "$tmp" || ! mv -f -- "$tmp" "$file"; then
      rm -f -- "$tmp"; return 1
    fi
  fi
  AGENT_ARGS=(--agent "cel-$name")
  AGENT_ROLE_FILE="$file"
  AGENT_FILE_SKILLS="${names[*]}"
}

# Trusts the launch's own folder for this session only: agy reads --settings
# and never saves it.
agy_launch_settings() { # <cwd> -> one-line JSON
  jq -cn --arg c "$1" '{trustedWorkspaces: [$c]}'
}

# Where agy keeps a conversation it can resume (one SQLite file per id).
agy_conversation_file() { # <conversation id>
  printf '%s/.gemini/antigravity-cli/conversations/%s.db' "$HOME" "$1"
}

# HOW AN agy AGENT STAYS WAKEABLE. Its only wake while idle is one of its own
# background tasks finishing, so it keeps `cel inbox wait` running as one
# (lib/inbox.sh _inbox_wait). Said once here: the first turn and the Stop
# hook both say it.
agy_wait_instruction() {
  printf '%s' 'Before you end your turn, start your inbox waiter: call run_command with CommandLine "cel inbox wait" and WaitMsBeforeAsync 500, without IsDaemon. It keeps running as a background task and finishes when mail arrives, which wakes you; do not wait for it, poll it or kill it. If it says it is already armed, nothing more is needed.'
}

agy_kickoff() { # <agent-name> -> the first turn of every cel agy launch
  printf 'Celestial launch: you are %s. Mail already waiting in your inbox is attached to this turn - act on it; with none there is nothing to do yet. %s' \
    "$1" "$(agy_wait_instruction)"
}

# --- the global hooks.json entry ----------------------------------------------

agy_hooks_file() { printf '%s/.gemini/config/hooks.json' "$HOME"; }

# THE INSTALLED PLANE, never the checkout this code runs from: the agy entry
# is box-wide and outlives a worktree or a review checkout. It is the root of
# the `cel` on PATH (cel shellenv puts the installed one there).
agy_hooks_root() {
  _cel_path_root || printf '%s' "$CEL_ROOT"
}
_cel_path_root() { # -> the root of the `cel` on PATH; fails when there is none
  local c
  c="$(type -P cel 2>/dev/null)" && c="$(readlink -f -- "$c")" && [ "${c%/bin/cel}" != "$c" ] \
    && { printf '%s' "${c%/bin/cel}"; return 0; }
  return 1
}
# STRICT, for Claude's guard (lib/link.sh): the `cel` on PATH, and only when
# it is not a linked git worktree (a solo or review checkout put first on
# PATH). No fallback to CEL_ROOT: fails when there is no installed plane.
installed_plane_root() {
  local r g c
  r="$(_cel_path_root)" || return 1
  if g="$(git -C "$r" rev-parse --absolute-git-dir 2>/dev/null)" \
    && c="$(git -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    && [ "$g" != "$c" ]; then
    return 1
  fi
  printf '%s' "$r"
}

agy_hooks_entry() { # [root] -> the `celestial` value, script paths resolved
  local root="${1:-$(agy_hooks_root)}" hook guard
  printf -v hook 'bash %q' "$root/tools/hooks/agy-hook.sh"
  printf -v guard 'bash %q' "$root/tools/hooks/agy-guard.sh"
  jq -cn --arg h "$hook" --arg g "$guard" '{
    SessionStart:  [{type: "command", command: ($h + " session"), timeout: 10}],
    PreInvocation: [{type: "command", command: ($h + " invoke"), timeout: 15}],
    PreToolUse:    [{matcher: "*", hooks: [{type: "command", command: $g, timeout: 20}]}],
    Stop:          [{type: "command", command: ($h + " stop"), timeout: 15}]
  }'
}

agy_hooks_current() {
  local f; f="$(agy_hooks_file)"
  [ -f "$f" ] && jq -e --argjson e "$(agy_hooks_entry)" '.celestial == $e' "$f" >/dev/null 2>&1
}

# ONE KEY, `celestial`, merged into the user's file: herdr's and Hindsight's
# entries, and the user's own, stay as they are. A file that is not a JSON
# object is the user's to fix, and nothing is installed over it. A symlinked
# hooks.json (a dotfile manager's) is written through to its target, which
# keeps its mode; the read-modify-write holds a lock beside it. An installed
# plane without these hook scripts (older than this one) is refused: the
# entry would name scripts that are not there, and a missing guard is silent.
agy_hooks_link() {
  local f target root merged tmp lk rc=0
  f="$(agy_hooks_file)"; root="$(agy_hooks_root)"
  [ -f "$root/tools/hooks/agy-guard.sh" ] && [ -f "$root/tools/hooks/agy-hook.sh" ] \
    || { c_err "agy: the installed plane at $root has no agy hooks - cel update first; the celestial guard and inbox hooks are NOT installed"; return 1; }
  mkdir -p "${f%/*}" || return 1
  target="$(readlink -f -- "$f")" || return 1
  mkdir -p "${target%/*}" || return 1
  exec {lk}>>"$target.cel.lock" || return 1
  flock -w 10 "$lk" || { exec {lk}>&-; c_err "agy: $target is locked by another writer"; return 1; }
  if agy_hooks_current; then
    exec {lk}>&-; c_ok "agy hooks already carry the celestial entry"; return 0
  fi
  if [ -f "$target" ]; then
    merged="$(jq --argjson e "$(agy_hooks_entry "$root")" \
      'if type == "object" then .celestial = $e else error("not an object") end' "$target" 2>/dev/null)" \
      || { exec {lk}>&-; c_err "agy: $f is not a JSON object - fix it and re-run; the celestial guard and inbox hooks are NOT installed"; return 1; }
  else
    merged="$(jq -n --argjson e "$(agy_hooks_entry "$root")" '{celestial: $e}')" || { exec {lk}>&-; return 1; }
  fi
  tmp="$(mktemp "$target.XXXXXX")" || { exec {lk}>&-; return 1; }
  [ ! -f "$target" ] || chmod --reference="$target" "$tmp" || rc=1
  if [ "$rc" = 1 ] || ! printf '%s\n' "$merged" > "$tmp" || ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"; exec {lk}>&-; return 1
  fi
  exec {lk}>&-
  c_ok "agy hooks: celestial entry merged into $f"
}
