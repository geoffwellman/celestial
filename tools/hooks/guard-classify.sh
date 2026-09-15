#!/usr/bin/env bash
# The classifier as a command, so every runtime adapter asks the SAME rules:
#   guard-classify.sh command <cwd> <shell command>   -> allow | deny <reason>
#   guard-classify.sh path    <cwd> <file path>       -> allow | deny <reason>
# The claude adapter (orchestrator-guard.sh) sources lib/guard.sh directly; the
# omp/pi adapter is TypeScript inside the agent process and shells out to
# this, which costs a few milliseconds per tool call and buys one source of
# truth for what an orchestrator may do. Fails OPEN on any error of its own:
# a broken guard must not take down every tool call on the box.
set -uo pipefail
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
# shellcheck source=lib/guard.sh
. "$CEL_ROOT/lib/guard.sh" 2>/dev/null || { printf allow; exit 0; }
mode="${1:-}"; cwd="${2:-$PWD}"; arg="${3:-}"
role="$(guard_role_of "$cwd")"
case "$mode" in
  command) guard_classify "$role" "$arg" ;;
  path)    guard_classify_path "$role" "$arg" ;;
  *)       printf allow ;;
esac
exit 0
