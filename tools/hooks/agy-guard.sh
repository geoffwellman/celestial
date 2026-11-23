#!/usr/bin/env bash
# agy PreToolUse hook: the celestial guard for Google Antigravity CLI, from
# the `celestial` entry cel merges into ~/.gemini/config/hooks.json.
#
# The tool call arrives as JSON on stdin ({toolCall: {name, args}, cwd, ...}).
# A refusal is {"decision":"deny","reason":...} on stdout: agy refuses the
# call and shows the agent the reason, under --dangerously-skip-permissions
# too (that flag skips prompts, not hooks). A PASS PRINTS NOTHING. Measured
# with agy 1.5.14 (headless, default policy, a command the policy refuses):
#   no hook, or no output   refused by agy's own policy
#   {"decision":"allow"}    refused by agy's own policy (it defers)
#   {"decision":"auto_approve"}  RAN - it overrides the policy
#   {}                      refused as a malformed answer
# So silence leaves agy's own permission policy exactly where it was, in
# every session - the entry is global and also sees sessions cel never
# launched. The guard never approves anything.
#
# The rules are lib/guard.sh's, asked through the same classifier every other
# adapter runs (tools/hooks/guard-classify.sh). FAILURE: in an agent cel
# launched (CEL_ROLE or CEL_INBOX_ME set) the guard is the boundary, so
# anything it cannot judge is refused - no lib/guard.sh, no jq, a classifier
# that fails or misses its CEL_GUARD_TIMEOUT deadline (default 10s), stdin
# that is not a tool call, a file tool without its path, a tool it does not
# know. In any other session a guard that cannot run stays silent, except for
# a command that looks like a forge review verdict, which is refused.
#
# What it reads, by agy 1.5.14 tool (lib/agy.sh grants cel agents exactly
# read_file, run_command, write_file, edit_file, manage_task, send_message,
# search_web and ask_question, plus MCP calls):
#   run_command            CommandLine       a shell command
#   manage_task            send_input: Input  typed into a running task - a
#                          shell command; list/status/kill carry only a task id
#   write_file, edit_file  Path              a write (older names
#                          write_to_file, replace_file_content,
#                          multi_replace_file_content: TargetFile)
#   read_file              Path              a read (view_file: AbsolutePath)
#   run_workflow, schedule, invoke_subagent, define_subagent, swarm
#                          code, deferred prompts or new agents the guard
#                          cannot follow: refused to a cel agent
#   send_message, search_web, ask_question, read_url_content, list_dir,
#   grep_search, find_by_name, call_mcp_tool   carry no command or write the
#                          guard judges; MCP tools are NOT guarded
set -uo pipefail
pass() { exit 0; }
deny() { # <reason>
  if command -v jq >/dev/null 2>&1; then jq -cn --arg r "$1" '{decision: "deny", reason: $r}'
  else r="${1//\\/\\\\}"; r="${r//\"/\\\"}"; printf '{"decision":"deny","reason":"%s"}\n' "${r//$'\n'/\\n}"; fi
  exit 0
}
[ "${CEL_GUARD:-1}" = 0 ] && pass
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
in="$(cat 2>/dev/null)" || in=""
cel_agent=0
[ -z "${CEL_ROLE:-}" ] && [ -z "${CEL_INBOX_ME:-}" ] || cel_agent=1
_broken() { # the guard cannot judge this call: closed for a cel agent or a verdict-shaped command
  [ "$cel_agent" = 0 ] \
    || deny "celestial guard (${CEL_ROLE:-cel} pane): the guard cannot judge this call ($1), and for an agent cel launched the guard is the boundary - nothing ran"
  local raw="${in,,}" re='pr[[:space:]]+review([^a-z0-9_]|$)|eviews|pullrequestreview|reviewmutation|approve([^a-z0-9_]|$)|lgtm|reject|(^|[^a-z0-9_])gh[[:space:]]+alias([^a-z0-9_]|$)|(^|[^a-z0-9_])tea([^a-z0-9_]|$)|graphql'
  local cre='"(commandline|input)"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ "$raw" =~ $cre ]] || pass
  [[ "${BASH_REMATCH[2]}" =~ $re ]] || pass
  deny "celestial guard: the guard cannot run ($1), and this looks like a forge review verdict, which no agent posts (cel solo review records one) - nothing ran"
}
# shellcheck source=lib/guard.sh
. "$CEL_ROOT/lib/guard.sh" 2>/dev/null || _broken "lib/guard.sh does not load"
command -v jq >/dev/null 2>&1 || _broken "jq is not on PATH"
fields="$(jq -r 'select(type == "object" and (.toolCall | type) == "object" and (.toolCall.name | type) == "string")
  | [.toolCall.name, (.cwd // .workspacePaths[0]? // "")] | @tsv' <<<"$in" 2>/dev/null)" || fields=""
[ -n "$fields" ] || _broken "stdin is not a tool call"
IFS=$'\t' read -r tool cwd <<<"$fields"
[ -n "$tool" ] || _broken "the tool call names no tool"
[ -n "$cwd" ] || cwd="$PWD"
arg() { jq -r --arg k "$1" '.toolCall.args[$k] // empty | tostring' <<<"$in" 2>/dev/null; }
role="$(guard_role_of "$cwd")"
_GUARD_CWD="$cwd"   # a builder's bare `git push` and relative paths resolve here (lib/guard.sh)

classify_command() { # <command> -> verdict; refuses itself on a deadline or failure
  local out
  out="$(CEL_ROOT="$CEL_ROOT" timeout -k 2 "${CEL_GUARD_TIMEOUT:-10}" \
    bash "$CEL_ROOT/tools/hooks/guard-classify.sh" command "$cwd" "$1" 2>/dev/null)"
  case $? in
    0) [ -n "$out" ] || _broken "the classifier gave no verdict"; printf '%s' "$out" ;;
    124|137) deny "celestial guard ($role pane): the guard did not finish classifying this command in ${CEL_GUARD_TIMEOUT:-10}s, so nothing ran - split it into smaller calls" ;;
    *) _broken "the classifier failed" ;;
  esac
}
path_of() { # <arg names...> -> the first non-empty one; a cel agent's file tool without one is refused
  local k v
  for k in "$@"; do v="$(arg "$k")"; [ -z "$v" ] || { printf '%s' "$v"; return 0; }; done
  _broken "$tool names no path in ${*}"
}

verdict=allow cmd=""
answered() { # <output of a $(...) that may have answered for the hook>
  case "$1" in \{*) printf '%s\n' "$1"; exit 0 ;; '') exit 0 ;; esac
}
case "$tool" in
  run_command) cmd="$(arg CommandLine)"; verdict="$(classify_command "$cmd")" ;;
  manage_task)
    case "$(arg Action)" in
      send_input) cmd="$(arg Input)"; verdict="$(classify_command "$cmd")" ;;
      list|status|kill) ;;
      *) [ "$cel_agent" = 0 ] || verdict="deny manage_task action '$(arg Action)' is not one the guard knows" ;;
    esac ;;
  write_file|edit_file|write_to_file|replace_file_content|multi_replace_file_content)
    p="$(path_of Path TargetFile)"; answered "$p"; verdict="$(guard_classify_path "$role" "$p")" ;;
  read_file|view_file)
    p="$(path_of Path AbsolutePath)"; answered "$p"; verdict="$(guard_classify_read "$role" "$p")" ;;
  run_workflow|schedule|invoke_subagent|define_subagent|swarm)
    [ "$cel_agent" = 0 ] && [ "$role" = other ] \
      || verdict="deny $tool runs code, a later prompt or another agent that the guard cannot follow - do the step yourself with run_command" ;;
  send_message|search_web|ask_question|read_url_content|list_dir|grep_search|find_by_name|call_mcp_tool) ;;
  *) [ "$cel_agent" = 0 ] || verdict="deny $tool is a tool the celestial guard does not know" ;;
esac
# classify_command and path_of answered (and exited) inside $(...) themselves
case "$verdict" in
  \{*) printf '%s\n' "$verdict"; exit 0 ;;
  ''|allow) pass ;;
  deny*)
    reason="celestial guard ($role pane): ${verdict#deny }"
    case "$role:$verdict" in member:*|*CEL_GUARD_ALLOW_ONCE*) ;;
      *) [ -z "$cmd" ] || reason+=$'\nIf a human has approved this exact call, prefix it: CEL_GUARD_ALLOW_ONCE=1 <command>' ;;
    esac
    deny "$reason" ;;
  *) _broken "the classifier answered '$verdict'" ;;
esac
