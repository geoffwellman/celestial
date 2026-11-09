#!/usr/bin/env bash
# claude PreToolUse hook: coordinators are read-only over repositories.
#
# Reads the tool call as JSON on stdin. Exit 2 with a reason on stderr blocks
# the call and shows the agent the reason; exit 0 lets it through. Runs under
# --dangerously-skip-permissions too - that flag suppresses permission
# PROMPTS, not hooks, which is exactly why this is a hook and not a permission
# rule. Never exits non-zero for any reason other than a deny: a broken guard
# must fail open, not take down every tool call on the box - except in a team
# member's pane (CEL_ROLE=member), whose scope IS this guard, for a shell
# command that looks like a forge review verdict (no agent posts one; the
# same VERDICT_SHAPED text as the omp and OpenCode adapters), and for a shell
# command the classifier did not finish in CEL_GUARD_TIMEOUT seconds (default
# 10, as omp): those fail closed.
set -uo pipefail
# A pane that lives in a workspace directory but is NOT an orchestrator - the
# owner's own assistant, a scratch session - opts out for its whole life with
# CEL_GUARD=0 in its environment before the agent starts. Hooks inherit the
# session's env, so that is per pane, not per box.
[ "${CEL_GUARD:-1}" = 0 ] && exit 0
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
_broken() { # the guard cannot run: open, or closed for a member or a verdict-shaped command
  if [ "${CEL_ROLE:-}" = member ]; then
    printf 'celestial guard (member pane): the guard cannot run (%s), and a team member'"'"'s scope is the guard - nothing ran\n' "$1" >&2
    exit 2
  fi
  local raw re='pr[[:space:]]+review([^a-z0-9_]|$)|eviews|pullrequestreview|reviewmutation|approve([^a-z0-9_]|$)|lgtm|reject|(^|[^a-z0-9_])gh[[:space:]]+alias([^a-z0-9_]|$)|(^|[^a-z0-9_])tea([^a-z0-9_]|$)|graphql'
  # no jq to rely on here: the command string is read off the raw JSON
  raw="$(cat 2>/dev/null)"; raw="${raw,,}"
  local tre='"tool_name"[[:space:]]*:[[:space:]]*"bash"' cre='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ "$raw" =~ $tre ]] || exit 0
  [[ "$raw" =~ $cre ]] || exit 0
  [[ "${BASH_REMATCH[1]}" =~ $re ]] || exit 0
  printf 'celestial guard: the guard cannot run (%s), and this looks like a forge review verdict, which no agent posts (cel solo review records one) - nothing ran\n' "$1" >&2
  exit 2
}
# shellcheck source=lib/guard.sh
. "$CEL_ROOT/lib/guard.sh" 2>/dev/null || _broken "lib/guard.sh does not load"
command -v jq >/dev/null 2>&1 || _broken "jq is not on PATH"

in="$(cat 2>/dev/null)" || exit 0
tool="$(printf '%s' "$in" | jq -r '.tool_name // empty' 2>/dev/null)"
[ -n "$tool" ] || exit 0

# A one-off the human has approved, for that pane, for that call:
#   CEL_GUARD_ALLOW_ONCE=1 <the command>
# Not standing authority - it is read from the tool call's own environment
# and covers nothing but the call it was set on.
cwd="$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)"; [ -n "$cwd" ] || cwd="$PWD"
role="$(guard_role_of "$cwd")"
_GUARD_CWD="$cwd"   # a builder's bare `git push` and relative paths resolve here (lib/guard.sh)
cmd="$(printf '%s' "$in" | jq -r '.tool_input.command // empty' 2>/dev/null)"
path="$(printf '%s' "$in" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"

# Panes outside the plane (`other`: a reviewer, a scratch session) go through
# the same classifiers, which refuse them only the tokens, `cel run member`
# and forge review verdicts. Whether a one-off is honoured is lib/guard.sh's
# (guard_override_honoured): never for a member, never for a forge verdict.
verdict=allow
case "$tool" in
  Bash)
    # The same classifier the omp/pi and OpenCode adapters run, under a
    # deadline: one that does not finish refuses the call.
    verdict="$(CEL_ROOT="$CEL_ROOT" timeout -k 2 "${CEL_GUARD_TIMEOUT:-10}" \
      bash "$CEL_ROOT/tools/hooks/guard-classify.sh" command "$cwd" "$cmd" 2>/dev/null)"
    case $? in
      0) ;;
      124|137)
        printf 'celestial guard (%s pane): the guard did not finish classifying this command in %ss, so nothing ran - split it into smaller calls\n' "$role" "${CEL_GUARD_TIMEOUT:-10}" >&2
        exit 2 ;;
      *) _broken "the classifier failed" <<<"$in" ;;
    esac ;;
  Read) verdict="$(guard_classify_read "$role" "$path")" ;;
  Edit|Write|MultiEdit|NotebookEdit) verdict="$(guard_classify_path "$role" "$path")" ;;
esac

case "$verdict" in
  allow) exit 0;;
  deny*)
    printf 'celestial guard (%s pane): %s\n' "$role" "${verdict#deny }" >&2
    # no one-off is offered to a member, nor for a refusal that rules it out
    case "$role:$verdict" in member:*|*CEL_GUARD_ALLOW_ONCE*) ;;
      *) printf 'If a human has approved this exact call, prefix it: CEL_GUARD_ALLOW_ONCE=1 <command>\n' >&2 ;;
    esac
    exit 2;;
esac
exit 0
