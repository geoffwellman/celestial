# shellcheck shell=bash
# Google Antigravity CLI (agy) as a runtime: its pinned release, the launch
# line cel run builds (role and workspace skills in a per-agent agent file,
# --conversation resume, --model/--effort), its global hooks.json entry, the
# PreToolUse guard adapter, the inbox/session hooks and `cel inbox wait`, the
# background task whose exit is agy's own wake for an idle conversation.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/manifest.sh"
source "$CEL_ROOT/lib/rex.sh"

AGY_CONV=4a5c02de-f0a0-41b0-93aa-663583ecf701
AGY_GUARD_HOOK="$CEL_ROOT/tools/hooks/agy-guard.sh"

# --- the manifest row ---------------------------------------------------------

test_agy_manifest_pins_the_hash_checked_release() {
  CEL_MANIFEST="$CEL_ROOT/agents.yaml"
  assert_eq "$(agent_get agy bin)" agy
  assert_eq "$(agent_get agy version)" 1.5.14
  local a
  for a in x64 arm64; do
    assert_eq "$(yq -r --arg a "$a" '.agents.agy.assets[$a].member' "$CEL_MANIFEST")" antigravity
    assert_contains "$(yq -r --arg a "$a" '.agents.agy.assets[$a].url' "$CEL_MANIFEST")" \
      "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.14-5302690847260672/"
  done
  assert_eq "$(yq -r '.agents.agy.assets.x64.sha256' "$CEL_MANIFEST")" d58386322d2073e96b33f7cc32b4e9ae2db6228f58440369725967b2de48c7b5
  assert_eq "$(yq -r '.agents.agy.assets.arm64.sha256' "$CEL_MANIFEST")" e5f69a3123fac66974b303d9a201f381a0fb32b3ef869d9139da85d5caf67a2a
  assert_contains "$(agent_get agy install)" 'install_pinned_binary agents agy'
  case "$(agent_get agy install) $(agent_update_get agy command)" in *curl*\|*bash*) echo "agy installs through a piped script"; return 1 ;; esac
  assert_contains "$(agent_update_get agy command)" 'install_pinned_binary agents agy'
  assert_eq "$(agent_resume agy flag) $(agent_resume agy value)" "--conversation id"
  assert_eq "$(agent_model_flag agy)" --model
  assert_eq "$(agent_thinking agy strategy) $(agent_thinking agy flag)" "flag --effort"
  assert_eq "$(agent_thinking_levels agy | tr '\n' ' ')" "low medium high "
  assert_eq "$(agent_injection agy strategy)" agent_file
  assert_eq "$(agent_workspace_skills agy strategy)" agent_file
  assert_eq "$(agent_skills_dir agy)" "$HOME/.gemini/antigravity-cli/skills"
  assert_eq "$(agent_get agy herdr_integration)" antigravity-cli
  assert_contains "$(agent_launch_args agy | tr '\n' ' ')" --dangerously-skip-permissions
  assert_eq "$(agent_owned_children agy)" "$(printf 'node\t/.hindsight/coding-agents/dist/mcp-server.js')"
}

# --- model and effort ---------------------------------------------------------

# agy validates --effort against the model's own variants; low, medium and
# high are the ones every adjustable model publishes, so xhigh and max clamp
# down rather than refusing the launch.
test_agy_launch_args_map_model_and_thinking_to_effort() {
  source "$CEL_ROOT/lib/profiles.sh"
  local PROFILE_ARGS
  profile_launch_args agy gemini-4-neon xhigh
  assert_eq "${PROFILE_ARGS[*]}" "--model gemini-4-neon --effort high"
  profile_launch_args agy "" minimal
  assert_eq "${PROFILE_ARGS[*]}" "--effort low"
  profile_launch_args agy claude-opus-5-5 medium
  assert_eq "${PROFILE_ARGS[*]}" "--model claude-opus-5-5 --effort medium"
}

# --- the agent file: role, tools and this workspace's skills ------------------

_agy_ws() { # -> $T: a workspace with repo widget; $HOME inside it
  T="$(mktemp -d)"; export HOME="$T/home"; mkdir -p "$HOME"
  export CEL_MANIFEST="$CEL_ROOT/agents.yaml" CEL_MANIFEST_CACHE="$T/cache"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  sed -i 's/^runtime: .*/runtime: { root: agy, orchestrator: agy }/' "$T/workspace.yaml"
  mkdir -p "$T/repos/widget" "$T/bin"
  git -C "$T/repos/widget" init -q
  cat > "$T/bin/herdr" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'agent list' ] || exit 1
printf '{"result":{"agents":[]}}\n'
SH
  chmod +x "$T/bin/herdr"
  export PATH="$T/bin:$PATH"
  source "$CEL_ROOT/lib/run.sh"
}
_agy_skill() { # <wsdir> <name>
  mkdir -p "$1/.cel/skills/skills/$2"
  printf -- '---\nname: %s\ndescription: d\n---\n' "$2" > "$1/.cel/skills/skills/$2/SKILL.md"
}

test_agy_role_and_workspace_skills_travel_in_a_per_agent_agent_file() {
  _agy_ws
  _agy_skill "$T" wrangler; _agy_skill "$T" web-perf
  local AGENT_ARGS=() AGENT_ROLE_FILE="" LAUNCH_ENV_EXTRA=() f
  _run_agent_args agy orchestrator $'# Solo\nbuild and ship' 0 "$T" "$T/.cel/role-orchestrator.md" widget-orch
  f="$HOME/.gemini/config/agents/cel-widget-orch.md"
  assert_eq "${AGENT_ARGS[*]}" "--agent cel-widget-orch"
  assert_eq "$AGENT_ROLE_FILE" "$f"
  [ -f "$f" ] || { echo "no agent file"; rm -rf "$T"; return 1; }
  # frontmatter: the name --agent selects, a main agent only, agy's full
  # main-agent toolset (an agent file without one gets six read-only tools),
  # and the workspace's skills by absolute path
  assert_eq "$(sed -n 2p "$f")" "name: cel-widget-orch"
  assert_contains "$(cat "$f")" "subagent: false"
  assert_contains "$(cat "$f")" "mainAgent: true"
  assert_contains "$(cat "$f")" "tools: [read_file, run_command, write_file, edit_file, manage_task, send_message, schedule, invoke_subagent, define_subagent, manage_subagents, search_web, run_workflow, ask_question]"
  assert_contains "$(cat "$f")" "  - \"$T/.cel/skills/skills/web-perf\""
  assert_contains "$(cat "$f")" "  - \"$T/.cel/skills/skills/wrangler\""
  assert_eq "$(tail -n 2 "$f")" $'# Solo\nbuild and ship'
  # the scoped skills are carried, so the launch adds nothing else for them
  AGENT_ARGS=(--agent cel-widget-orch)
  _run_workspace_skills agy "$T"
  assert_eq "${AGENT_ARGS[*]} | ${LAUNCH_ENV_EXTRA[*]}" "--agent cel-widget-orch | "
  # nothing in the repository, nothing in agy's global skills dir
  assert_eq "$(git -C "$T/repos/widget" status --porcelain --ignored)" ""
  [ ! -e "$HOME/.gemini/antigravity-cli/skills/wrangler" ] || { echo "a scoped skill went global"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# #335: a workspace's scoped skills reach its launch or the launch is refused.
_agy_sub() { ( "$@" ); }
test_workspace_skills_a_launch_cannot_scope_refuse_the_launch() {
  _agy_ws
  _agy_skill "$T" wrangler
  local AGENT_ARGS=() LAUNCH_ENV_EXTRA=() AGENT_FILE_SKILLS=""
  # agy's agent file did not carry them (written for another workspace)
  assert_fails _agy_sub _run_workspace_skills agy "$T"
  # a runtime that declares no way to scope them
  cp "$CEL_ROOT/agents.yaml" "$T/agents.yaml"
  yq -y -i '.agents.bare = {bin: "bare", role_injection: {strategy: "prompt_arg"}}' "$T/agents.yaml"
  CEL_MANIFEST="$T/agents.yaml" assert_fails _agy_sub _run_workspace_skills bare "$T"
  # nothing to scope: nothing refused, nothing added
  rm -rf "$T/.cel/skills"
  AGENT_ARGS=(--x)
  CEL_MANIFEST="$T/agents.yaml" _run_workspace_skills bare "$T"
  assert_eq "${AGENT_ARGS[*]}" "--x"
  rm -rf "$T"
}

# --- the launch line ----------------------------------------------------------

test_cel_run_builds_the_agy_launch_line() {
  _agy_ws
  local out
  out="$(cd "$T" && cmd_run orchestrator --repo widget --dry-run 2>&1)"
  assert_contains "$out" "--kind agy"
  assert_contains "$out" "--agent cel-"
  assert_contains "$out" "--dangerously-skip-permissions"
  assert_contains "$out" "--effort high"
  # the folder is trusted for this launch only (agy never saves --settings)
  assert_contains "$out" "--settings {\"trustedWorkspaces\":[\"$T/repos/widget\"]}"
  # its hooks are merged before it starts (a dry run only says so)
  assert_contains "$out" "merge the celestial hooks entry into $HOME/.gemini/config/hooks.json"
  [ ! -e "$HOME/.gemini/config/hooks.json" ] || { echo "a dry run wrote hooks"; rm -rf "$T"; return 1; }
  # agy's own updater would replace the pinned binary under the plane
  assert_contains "$out" "AGY_CLI_DISABLE_AUTO_UPDATE=true"
  # a first turn: it arms the inbox waiter on it
  assert_contains "$out" " -i "
  rm -rf "$T"
}

test_agy_resume_takes_the_conversation_id_herdr_or_rex_reported() {
  source "$CEL_ROOT/lib/run.sh"
  assert_eq "$(_run_resume_native_id agy "$AGY_CONV")" "$AGY_CONV"
  assert_eq "$(_run_resume_native_id agy "/h/.gemini/antigravity-cli/brain/$AGY_CONV/.system_generated/logs/transcript_full.jsonl")" "$AGY_CONV"
  assert_eq "$(_run_resume_native_id claude /x/y.jsonl)" /x/y.jsonl
  rex_native_session_valid agy "$AGY_CONV" || { echo "rex refused an agy conversation id"; return 1; }
  ! rex_native_session_valid agy /x/transcript.jsonl || { echo "rex took a path for agy"; return 1; }
  local _REX_NATIVE=""
  _rex_launch_native agy /tmp --agent cel-x --conversation "$AGY_CONV"
  assert_eq "$_REX_NATIVE" "$AGY_CONV"
  local f; f="$(mktemp)"
  printf '/home/u/.local/bin/agy\0--conversation\0%s\0' "$AGY_CONV" > "$f"
  _run_is_agent_argv "$f" || { rm -f "$f"; echo "agy not recognised as a session holder"; return 1; }
  rm -f "$f"
  source "$CEL_ROOT/lib/serve.sh"
  _serve_agent_argv "/home/u/.local/bin/agy --conversation $AGY_CONV" || { echo "agy taken for a preview"; return 1; }
  # a restart resumes only a conversation agy actually has: an unknown id
  # would make agy start a new one silently
  export HOME; HOME="$(mktemp -d)"
  assert_fails _agy_sub _run_resume_identity_check agy "$AGY_CONV" /tmp cel-orchestrator
  assert_fails _agy_sub _run_resume_identity_check agy not-an-id /tmp cel-orchestrator
  mkdir -p "$HOME/.gemini/antigravity-cli/conversations"; : > "$HOME/.gemini/antigravity-cli/conversations/$AGY_CONV.db"
  _agy_sub _run_resume_identity_check agy "$AGY_CONV" /tmp cel-orchestrator || { echo "refused a real conversation"; rm -rf "$HOME"; return 1; }
  # agy postdates the runtime field: an untagged record is never its own
  _run_resume_foreign agy "$AGY_CONV" "" widget-orch 2>/dev/null || { echo "agy resumed an untagged session"; rm -rf "$HOME"; return 1; }
  _run_resume_foreign agy "$AGY_CONV" agy widget-orch && { echo "agy refused its own session"; rm -rf "$HOME"; return 1; }
  rm -rf "$HOME"
}

# --- the global hooks.json entry ----------------------------------------------

test_agy_hooks_link_merges_one_celestial_entry_and_keeps_the_rest() {
  T="$(mktemp -d)"; export HOME="$T/home"
  source "$CEL_ROOT/lib/agy.sh"
  local f="$HOME/.gemini/config/hooks.json"
  mkdir -p "${f%/*}"
  printf '{"herdr":{"SessionStart":[{"type":"command","command":"sh x session"}]},"hindsight":{"Stop":[]}}\n' > "$f"
  ! agy_hooks_current || { echo "current before linking"; rm -rf "$T"; return 1; }
  agy_hooks_link >/dev/null || { echo "link failed"; rm -rf "$T"; return 1; }
  agy_hooks_current || { echo "not current after linking"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r 'keys | join(" ")' "$f")" "celestial herdr hindsight"
  assert_eq "$(jq -r '.herdr.SessionStart[0].command' "$f")" "sh x session"
  assert_eq "$(jq -r '.celestial.PreToolUse[0].hooks[0].command' "$f")" "bash $(printf '%q' "$CEL_ROOT/tools/hooks/agy-guard.sh")"
  local e
  for e in SessionStart:session PreInvocation:invoke Stop:stop; do
    assert_eq "$(jq -r --arg e "${e%%:*}" '.celestial[$e][0].command' "$f")" "bash $(printf '%q' "$CEL_ROOT/tools/hooks/agy-hook.sh") ${e#*:}"
  done
  local before; before="$(cat "$f")"
  agy_hooks_link >/dev/null
  assert_eq "$(cat "$f")" "$before"
  # a hooks.json that is not a JSON object is the user's to fix
  printf 'not json' > "$f"
  assert_fails agy_hooks_link
  assert_eq "$(cat "$f")" "not json"
  rm -rf "$T"
}

# --- the guard: PreToolUse, under --dangerously-skip-permissions too ----------

_agy_guard() { # <cwd> <tool> <args-json> -> the hook's JSON answer
  jq -cn --arg cwd "$1" --arg t "$2" --argjson a "$3" --arg c "$AGY_CONV" \
    '{hookEventName:"PreToolUse",cwd:$cwd,workspacePaths:[$cwd],conversationId:$c,toolCall:{name:$t,args:$a}}' \
    | bash "$AGY_GUARD_HOOK"
}
_agy_gws() { T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"; mkdir -p "$T/repos/widget/src" "$T/.cel"; }
_agy_decision() { jq -r .decision <<<"$1"; }

test_agy_guard_refuses_what_the_shared_classifier_refuses() {
  _agy_gws
  local out
  out="$(_agy_guard "$T/repos/widget" run_command '{"CommandLine":"git commit -m x","WaitMsBeforeAsync":500}')"
  assert_eq "$(_agy_decision "$out")" deny || { rm -rf "$T"; return 1; }
  assert_contains "$(jq -r .reason <<<"$out")" "celestial guard (orchestrator pane)"
  out="$(_agy_guard "$T/repos/widget" write_file "{\"Path\":\"$T/repos/widget/src/a.ts\",\"Content\":\"x\"}")"
  assert_eq "$(_agy_decision "$out")" deny || { rm -rf "$T"; return 1; }
  out="$(_agy_guard "$T/repos/widget" edit_file "{\"Path\":\"$T/repos/widget/src/a.ts\",\"Target\":\"a\",\"Replacement\":\"b\"}")"
  assert_eq "$(_agy_decision "$out")" deny || { rm -rf "$T"; return 1; }
  out="$(_agy_guard "$T/repos/widget" write_file "{\"Path\":\"$T/.cel/spec.md\",\"Content\":\"x\"}")"
  assert_eq "$(_agy_decision "$out")" allow || { rm -rf "$T"; return 1; }
  out="$(_agy_guard "$T/repos/widget" read_file "{\"Path\":\"$T/repos/widget/src/a.ts\"}")"
  assert_eq "$(_agy_decision "$out")" allow || { rm -rf "$T"; return 1; }
  # a solo agent builds: it commits and pushes, but never merges by hand
  out="$(CEL_ROLE=solo _agy_guard "$T/repos/widget" run_command '{"CommandLine":"git commit -m x"}')"
  assert_eq "$(_agy_decision "$out")" allow || { rm -rf "$T"; return 1; }
  out="$(CEL_ROLE=solo _agy_guard "$T/repos/widget" run_command '{"CommandLine":"gh pr merge 3 --squash"}')"
  assert_eq "$(_agy_decision "$out")" deny || { rm -rf "$T"; return 1; }
  assert_contains "$(jq -r .reason <<<"$out")" "cel solo land"
  # text typed into a running task's stdin is a command line too
  out="$(CEL_ROLE=solo _agy_guard "$T/repos/widget" manage_task '{"Action":"send_input","TaskId":"t-1","Input":"gh pr merge 3"}')"
  assert_eq "$(_agy_decision "$out")" deny || { rm -rf "$T"; return 1; }
  out="$(CEL_ROLE=solo _agy_guard "$T/repos/widget" manage_task '{"Action":"status","TaskId":"t-1"}')"
  assert_eq "$(_agy_decision "$out")" allow || { rm -rf "$T"; return 1; }
  # a Python workflow script is code the classifier cannot read: refused
  out="$(CEL_ROLE=solo _agy_guard "$T/repos/widget" run_workflow '{"Script":"import subprocess"}')"
  assert_eq "$(_agy_decision "$out")" deny || { rm -rf "$T"; return 1; }
  # the waiter every agy launch arms is allowed in every role
  local r
  for r in solo orchestrator root reviewer; do
    out="$(CEL_ROLE=$r _agy_guard "$T/repos/widget" run_command '{"CommandLine":"cel inbox wait"}')"
    assert_eq "$(_agy_decision "$out")" allow || { echo "$r cannot arm its waiter"; rm -rf "$T"; return 1; }
  done
  rm -rf "$T"
}
test_agy_guard_lets_panes_outside_the_plane_through_and_honours_the_opt_out() {
  assert_eq "$(_agy_decision "$(_agy_guard /tmp run_command '{"CommandLine":"git push origin main"}')")" allow
  _agy_gws
  assert_eq "$(_agy_decision "$(CEL_GUARD=0 _agy_guard "$T/repos/widget" run_command '{"CommandLine":"git commit -m x"}')")" allow
  rm -rf "$T"
}
# Its own failure: open for everyone but a member, closed on a deadline.
test_agy_guard_fails_open_except_for_a_member_and_a_timeout() {
  local R; R="$(mktemp -d)"
  assert_eq "$(printf 'not json' | bash "$CEL_ROOT/tools/hooks/agy-guard.sh" | jq -r .decision)" allow
  assert_eq "$(_agy_decision "$(CEL_ROOT="$R" _agy_guard /tmp run_command '{"CommandLine":"ls"}')")" allow
  assert_eq "$(_agy_decision "$(CEL_ROOT="$R" CEL_ROLE=member _agy_guard /tmp run_command '{"CommandLine":"ls"}')")" deny
  assert_eq "$(_agy_decision "$(CEL_ROOT="$R" CEL_ROLE=solo _agy_guard /tmp run_command '{"CommandLine":"gh pr review 3 --approve"}')")" deny
  mkdir -p "$R/tools/hooks" "$R/lib"
  cp "$CEL_ROOT/lib/"*.sh "$R/lib/"
  printf 'exec sleep 30\n' > "$R/tools/hooks/guard-classify.sh"
  local out
  out="$(CEL_ROOT="$R" CEL_GUARD_TIMEOUT=1 CEL_ROLE=solo _agy_guard /tmp run_command '{"CommandLine":"ls"}')"
  assert_eq "$(_agy_decision "$out")" deny || { rm -rf "$R"; return 1; }
  assert_contains "$(jq -r .reason <<<"$out")" "did not finish"
  rm -rf "$R"
}

# --- session identity and inbox delivery --------------------------------------

_agy_native_setup() {
  AN_DIR="$(mktemp -d)"
  mkdir -p "$AN_DIR/root/bin" "$AN_DIR/state" "$AN_DIR/cwd"
  ln -s "$CEL_ROOT/lib" "$AN_DIR/root/lib"
  ln -s "$CEL_ROOT/tools" "$AN_DIR/root/tools"
  cat > "$AN_DIR/root/bin/cel" <<'SH'
#!/bin/bash
if [ "$1 $2" = 'inbox read' ]; then
  printf '%s\n' "$*" >> "$AN_DIR/reads"
  [ ! -f "$AN_DIR/mail" ] || { cat "$AN_DIR/mail"; : > "$AN_DIR/mail"; }
  exit 0
fi
if [ "$1 $2 $3" = 'inbox wait --check' ]; then [ -f "$AN_DIR/armed" ]; exit; fi
[ "$1 $2" = 'sessions note' ] || exit 1
shift
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/rex.sh"
cmd_sessions "$@"
SH
  chmod +x "$AN_DIR/root/bin/cel"
  export AN_DIR CEL_REX_STATE="$AN_DIR/state" CEL_REX_RECORD="$AN_DIR/state/lane.json" CEL_ORCH_SESSIONS="$AN_DIR/sessions.json"
  export CEL_INBOX_ME=widget-lane-a CEL_INBOX_WS=alpha
  local pid="${BASHPID:-$$}" start
  start="$(_rex_pid_start "$pid")"
  jq -n --argjson pid "$pid" --arg start "$start" --arg cwd "$AN_DIR/cwd" \
    '{name:"widget-lane-a",agent:"agy",role:"solo",backend:"rex",workspace:$cwd,cwd:$cwd,pid:$pid,pid_start:$start,agent_status:"working"}' > "$CEL_REX_RECORD"
}
_agy_native_hook() { # <event-word> <payload-json>
  CEL_ROOT="$AN_DIR/root" bash "$CEL_ROOT/tools/hooks/agy-hook.sh" "$1" <<<"$2"
}
_agy_payload() { # <hookEventName> [jq assignments]
  jq -cn --arg e "$1" --arg c "$AGY_CONV" --arg cwd "$AN_DIR/cwd" \
    "{hookEventName:\$e,conversationId:\$c,cwd:\$cwd,workspacePaths:[\$cwd],transcriptPath:\"/t/$AGY_CONV/transcript_full.jsonl\"} ${2:+| $2}"
}
_agy_native_down() { rm -rf "$AN_DIR"; unset AN_DIR CEL_REX_STATE CEL_REX_RECORD CEL_ORCH_SESSIONS CEL_INBOX_ME CEL_INBOX_WS; }

test_agy_session_hook_reports_the_conversation_and_state_to_rex() {
  _agy_native_setup
  assert_eq "$(_agy_native_hook session "$(_agy_payload SessionStart)")" '{}'
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" working
  assert_eq "$(jq -r .agent_session.value "$CEL_REX_RECORD")" "$AGY_CONV"
  assert_eq "$(jq -c --arg cwd "$AN_DIR/cwd" '.[$cwd]' "$CEL_ORCH_SESSIONS")" "$(jq -cn --arg s "$AGY_CONV" '{session: $s, runtime: "agy"}')"
  # an id that is not a conversation UUID is never recorded
  local before; before="$(cat "$CEL_REX_RECORD")"
  _agy_native_hook session "$(_agy_payload SessionStart '.conversationId="../x"')" >/dev/null
  assert_eq "$(cat "$CEL_REX_RECORD")" "$before"
  _agy_native_down
}

test_agy_first_invocation_of_a_turn_carries_the_mail_once() {
  _agy_native_setup
  local out
  printf 'INBOX review from widget-pr-3: changes\n' > "$AN_DIR/mail"
  out="$(_agy_native_hook invoke "$(_agy_payload PreInvocation '.invocationNum=1')")"
  assert_eq "$out" '{}'
  [ -s "$AN_DIR/mail" ] || { echo "a later step consumed the mail"; _agy_native_down; return 1; }
  out="$(_agy_native_hook invoke "$(_agy_payload PreInvocation '.invocationNum=0')")"
  assert_contains "$(jq -r '.injectSteps[0].systemMessage.systemMessage' <<<"$out")" 'INBOX review from widget-pr-3: changes'
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" working
  # the reader is the launch's own mailbox, not the cwd's
  assert_contains "$(cat "$AN_DIR/reads")" "--for widget-lane-a --workspace alpha"
  assert_eq "$(_agy_native_hook invoke "$(_agy_payload PreInvocation '.invocationNum=0')")" '{}'
  _agy_native_down
}

# Stop: mail that arrived during the turn continues it; a conversation that
# would go idle with no waiter running is sent back once to arm it (a waiter
# is the background task whose exit wakes an idle agy); otherwise idle.
test_agy_stop_continues_for_mail_arms_the_waiter_then_goes_idle() {
  _agy_native_setup
  local out
  printf 'INBOX note from root: hi\n' > "$AN_DIR/mail"
  out="$(_agy_native_hook stop "$(_agy_payload Stop '.fullyIdle=true | .continuationActive=false')")"
  assert_eq "$(jq -r .decision <<<"$out")" continue
  assert_contains "$(jq -r .reason <<<"$out")" 'INBOX note from root: hi'
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" working
  out="$(_agy_native_hook stop "$(_agy_payload Stop '.fullyIdle=true | .continuationActive=false')")"
  assert_eq "$(jq -r .decision <<<"$out")" continue
  assert_contains "$(jq -r .reason <<<"$out")" 'cel inbox wait'
  assert_contains "$(jq -r .reason <<<"$out")" 'WaitMsBeforeAsync'
  # sent back once: a second stop in the same continuation is let through
  out="$(_agy_native_hook stop "$(_agy_payload Stop '.fullyIdle=true | .continuationActive=true')")"
  assert_eq "$out" '{}'
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" idle
  : > "$AN_DIR/armed"
  out="$(_agy_native_hook stop "$(_agy_payload Stop '.fullyIdle=false | .continuationActive=false')")"
  assert_eq "$out" '{}'
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" idle
  _agy_native_down
}

# A session cel did not launch (no mailbox) is left exactly as it was.
test_agy_hooks_do_nothing_outside_a_cel_launch() {
  _agy_native_setup
  unset CEL_INBOX_ME CEL_INBOX_WS CEL_REX_RECORD
  printf 'mail\n' > "$AN_DIR/mail"
  assert_eq "$(_agy_native_hook stop "$(_agy_payload Stop '.fullyIdle=true')")" '{}'
  assert_eq "$(_agy_native_hook invoke "$(_agy_payload PreInvocation '.invocationNum=0')")" '{}'
  assert_eq "$(_agy_native_hook session "$(_agy_payload SessionStart)")" '{}'
  assert_eq "$(cat "$AN_DIR/mail")" mail
  [ ! -e "$AN_DIR/reads" ] || { echo "read a mailbox it does not own"; _agy_native_down; return 1; }
  _agy_native_down
}

# --- cel inbox wait: the waiter ------------------------------------------------

_aw_setup() {
  source "$CEL_ROOT/lib/inbox.sh"
  CEL_INBOX_DIR="$(mktemp -d)"; XDG_RUNTIME_DIR="$(mktemp -d)"; export CEL_INBOX_DIR XDG_RUNTIME_DIR
}
_aw_down() { rm -rf "$CEL_INBOX_DIR" "$XDG_RUNTIME_DIR"; }
_aw_gone() { local i; for i in $(seq 1 40); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.25; done; return 1; }

test_inbox_wait_returns_at_once_for_waiting_mail_and_consumes_nothing() {
  _aw_setup
  _inbox_send widget-lane-a "already here" --from root --workspace demo >/dev/null 2>&1
  local out
  out="$(timeout 10 bash -c 'source "$CEL_ROOT/lib/common.sh"; source "$CEL_ROOT/lib/inbox.sh"; _inbox_wait --for widget-lane-a --workspace demo')"
  assert_contains "$out" "widget-lane-a"
  assert_contains "$out" "cel inbox read --for widget-lane-a --workspace demo"
  assert_eq "$(_inbox_count --for widget-lane-a --workspace demo)" 1
  _aw_down
}

test_inbox_wait_blocks_until_mail_arrives_then_exits() {
  _aw_setup
  local o; o="$(mktemp)"
  ( _inbox_wait --for widget-lane-a --workspace demo > "$o" 2>&1 ) & local w=$!
  sleep 2
  kill -0 "$w" 2>/dev/null || { echo "the waiter returned with no mail"; cat "$o"; _aw_down; return 1; }
  _inbox_send widget-lane-a "wake up" --from root --workspace demo >/dev/null 2>&1
  _aw_gone "$w" || { echo "the waiter did not wake on mail"; kill "$w"; _aw_down; return 1; }
  assert_contains "$(cat "$o")" "wake up"
  rm -f "$o"; _aw_down
}

test_inbox_wait_is_one_per_reader_and_check_says_whether_it_runs() {
  _aw_setup
  _agy_sub _inbox_wait --check --for widget-lane-a --workspace demo && { echo "armed with no waiter"; _aw_down; return 1; }
  ( _inbox_wait --for widget-lane-a --workspace demo >/dev/null 2>&1 ) & local w=$!
  sleep 1.5
  _agy_sub _inbox_wait --check --for widget-lane-a --workspace demo || { echo "check missed a live waiter"; kill "$w"; _aw_down; return 1; }
  local out; out="$(timeout 5 bash -c 'source "$CEL_ROOT/lib/common.sh"; source "$CEL_ROOT/lib/inbox.sh"; _inbox_wait --for widget-lane-a --workspace demo')"
  assert_contains "$out" "already"
  kill -0 "$w" 2>/dev/null || { echo "the first waiter died"; _aw_down; return 1; }
  pkill -P "$w" 2>/dev/null; kill "$w" 2>/dev/null; _aw_gone "$w"
  sleep 0.5
  _agy_sub _inbox_wait --check --for widget-lane-a --workspace demo && { echo "armed after its waiter went"; _aw_down; return 1; }
  _aw_down
}

test_inbox_wait_goes_when_its_parent_goes() {
  _aw_setup
  sleep 60 & local parent=$!
  ( CEL_WATCH_PARENT_POLL=1 _inbox_wait --for widget-lane-a --workspace demo --parent "$parent" >/dev/null 2>&1 ) & local w=$!
  sleep 1.5
  kill -0 "$w" 2>/dev/null || { echo "the waiter did not start"; kill "$parent"; _aw_down; return 1; }
  kill "$parent"; wait "$parent" 2>/dev/null || true
  _aw_gone "$w" || { echo "the waiter outlived its parent"; kill "$w"; _aw_down; return 1; }
  _aw_down
}
