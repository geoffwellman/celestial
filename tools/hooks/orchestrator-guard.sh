#!/usr/bin/env bash
# claude PreToolUse hook: orchestrators are read-only over repositories.
#
# Reads the tool call as JSON on stdin. Exit 2 with a reason on stderr blocks
# the call and shows the agent the reason; exit 0 lets it through. Runs under
# --dangerously-skip-permissions too - that flag suppresses permission
# PROMPTS, not hooks, which is exactly why this is a hook and not a permission
# rule. Never exits non-zero for any reason other than a deny: a broken guard
# must fail open, not take down every tool call on the box.
set -uo pipefail
# A pane that lives in a workspace directory but is NOT an orchestrator - the
# owner's own assistant, a scratch session - opts out for its whole life with
# CEL_GUARD=0 in its environment before the agent starts. Hooks inherit the
# session's env, so that is per pane, not per box.
[ "${CEL_GUARD:-1}" = 0 ] && exit 0
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
# shellcheck source=lib/guard.sh
. "$CEL_ROOT/lib/guard.sh" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

in="$(cat 2>/dev/null)" || exit 0
tool="$(printf '%s' "$in" | jq -r '.tool_name // empty' 2>/dev/null)"
[ -n "$tool" ] || exit 0

# A one-off the human has approved, for that pane, for that call:
#   CEL_GUARD_ALLOW_ONCE=1 <the command>
# Not standing authority - it is read from the tool call's own environment
# and covers nothing but the call it was set on.
cwd="$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)"; [ -n "$cwd" ] || cwd="$PWD"
role="$(guard_role_of "$cwd")"
case "$role" in worker|other) exit 0;; esac

verdict=allow
case "$tool" in
  Bash)
    cmd="$(printf '%s' "$in" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    case "$cmd" in CEL_GUARD_ALLOW_ONCE=1*) exit 0;; esac
    verdict="$(guard_classify "$role" "$cmd")" ;;
  Edit|Write|MultiEdit|NotebookEdit)
    path="$(printf '%s' "$in" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
    verdict="$(guard_classify_path "$role" "$path")" ;;
esac

case "$verdict" in
  allow) exit 0;;
  deny*)
    printf 'celestial guard (%s pane): %s\n' "$role" "${verdict#deny }" >&2
    printf 'If a human has approved this exact call, prefix it: CEL_GUARD_ALLOW_ONCE=1 <command>\n' >&2
    exit 2;;
esac
exit 0
