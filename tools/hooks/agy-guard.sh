#!/usr/bin/env bash
# agy PreToolUse hook: the celestial guard for Google Antigravity CLI, from
# the `celestial` entry cel merges into ~/.gemini/config/hooks.json.
#
# The tool call arrives as JSON on stdin ({toolCall: {name, args}, cwd, ...});
# the answer is JSON on stdout: {"decision":"allow"} lets it through to agy's
# own permission policy, {"decision":"deny","reason":...} refuses it and the
# agent is shown the reason. agy runs hooks under
# --dangerously-skip-permissions too: that flag skips PROMPTS, not hooks.
#
# The rules are lib/guard.sh's, asked through the same classifier every other
# adapter runs (tools/hooks/guard-classify.sh), with the same failure policy
# as claude's (orchestrator-guard.sh): a guard that cannot run lets the call
# through - except in a team member's pane, for a shell command that looks
# like a forge review verdict, and for a command the classifier did not
# finish in CEL_GUARD_TIMEOUT seconds (default 10): those are refused.
#
# What it reads, by agy 1.5.14 tool:
#   run_command            CommandLine           a shell command
#   manage_task send_input Input                 typed into a running task: a
#                                                shell command too
#   write_file, edit_file  Path                  a write (and the older names
#                                                write_to_file, replace_file_content,
#                                                multi_replace_file_content: TargetFile)
#   read_file              Path                  a read (view_file: AbsolutePath)
#   run_workflow           Script/ScriptPath     a Python program the classifier
#                                                cannot read: refused in any
#                                                pane the plane guards
# Anything else (search, MCP calls, subagents, messages) is let through; a
# subagent's own tool calls come back through this hook.
set -uo pipefail
allow() { printf '{"decision":"allow"}\n'; exit 0; }
deny() { # <reason>
  if command -v jq >/dev/null 2>&1; then jq -cn --arg r "$1" '{decision: "deny", reason: $r}'
  else printf '{"decision":"deny","reason":"%s"}\n' "${1//\"/\'}"; fi
  exit 0
}
[ "${CEL_GUARD:-1}" = 0 ] && allow
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
in="$(cat 2>/dev/null)" || in=""
_broken() { # the guard cannot run: open, or closed for a member or a verdict-shaped command
  [ "${CEL_ROLE:-}" != member ] \
    || deny "celestial guard (member pane): the guard cannot run ($1), and a team member's scope is the guard - nothing ran"
  local raw="${in,,}" re='pr[[:space:]]+review([^a-z0-9_]|$)|eviews|pullrequestreview|reviewmutation|approve([^a-z0-9_]|$)|lgtm|reject|(^|[^a-z0-9_])gh[[:space:]]+alias([^a-z0-9_]|$)|(^|[^a-z0-9_])tea([^a-z0-9_]|$)|graphql'
  local cre='"(commandline|input)"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ "$raw" =~ $cre ]] || allow
  [[ "${BASH_REMATCH[2]}" =~ $re ]] || allow
  deny "celestial guard: the guard cannot run ($1), and this looks like a forge review verdict, which no agent posts (cel solo review records one) - nothing ran"
}
# shellcheck source=lib/guard.sh
. "$CEL_ROOT/lib/guard.sh" 2>/dev/null || _broken "lib/guard.sh does not load"
command -v jq >/dev/null 2>&1 || _broken "jq is not on PATH"
fields="$(jq -r 'select(type == "object" and (.toolCall | type) == "object")
  | [(.toolCall.name // ""), (.cwd // .workspacePaths[0]? // "")] | @tsv' <<<"$in" 2>/dev/null)" || allow
[ -n "$fields" ] || allow
IFS=$'\t' read -r tool cwd <<<"$fields"
[ -n "$cwd" ] || cwd="$PWD"
arg() { jq -r --arg k "$1" '.toolCall.args[$k] // empty | tostring' <<<"$in" 2>/dev/null; }
role="$(guard_role_of "$cwd")"
_GUARD_CWD="$cwd"   # a builder's bare `git push` and relative paths resolve here (lib/guard.sh)

classify_command() { # <command> -> verdict, or refuses on a deadline/failure
  local out
  out="$(CEL_ROOT="$CEL_ROOT" timeout -k 2 "${CEL_GUARD_TIMEOUT:-10}" \
    bash "$CEL_ROOT/tools/hooks/guard-classify.sh" command "$cwd" "$1" 2>/dev/null)"
  case $? in
    0) printf '%s' "$out" ;;
    124|137) deny "celestial guard ($role pane): the guard did not finish classifying this command in ${CEL_GUARD_TIMEOUT:-10}s, so nothing ran - split it into smaller calls" ;;
    *) _broken "the classifier failed" ;;
  esac
}

verdict=allow cmd=""
case "$tool" in
  run_command) cmd="$(arg CommandLine)"; verdict="$(classify_command "$cmd")" ;;
  manage_task)
    if [ "$(arg Action)" = send_input ]; then cmd="$(arg Input)"; verdict="$(classify_command "$cmd")"; fi ;;
  write_file|edit_file) verdict="$(guard_classify_path "$role" "$(arg Path)")" ;;
  write_to_file|replace_file_content|multi_replace_file_content) verdict="$(guard_classify_path "$role" "$(arg TargetFile)")" ;;
  read_file) verdict="$(guard_classify_read "$role" "$(arg Path)")" ;;
  view_file) verdict="$(guard_classify_read "$role" "$(arg AbsolutePath)")" ;;
  run_workflow)
    [ "$role" = other ] || verdict="deny a workflow script is code the guard cannot read - run its steps with run_command" ;;
esac
# classify_command exits the hook itself on a refusal of its own
case "$verdict" in
  \{*) printf '%s\n' "$verdict"; exit 0 ;;
  deny*)
    reason="celestial guard ($role pane): ${verdict#deny }"
    case "$role:$verdict" in member:*|*CEL_GUARD_ALLOW_ONCE*) ;;
      *) [ -z "$cmd" ] || reason+=$'\nIf a human has approved this exact call, prefix it: CEL_GUARD_ALLOW_ONCE=1 <command>' ;;
    esac
    deny "$reason" ;;
esac
allow
