#!/usr/bin/env bash
# The classifier as a command, so every runtime adapter asks the SAME rules:
#   guard-classify.sh command <cwd> <shell command>   -> allow | deny <reason>
#   guard-classify.sh path    <cwd> <file path>       -> allow | deny <reason>  (a write)
#   guard-classify.sh read    <cwd> <file path>       -> allow | deny <reason>
# The claude adapter (orchestrator-guard.sh) sources lib/guard.sh directly; the
# omp/pi adapter is TypeScript inside the agent process and shells out to
# this, which costs a few milliseconds per tool call and buys one source of
# truth for what an orchestrator may do. ITS OWN FAILURE IS NOT A VERDICT: a
# policy that will not load or a mode it does not know exits 2 with the reason
# on stderr and prints nothing, so an adapter can tell "the classifier broke"
# from "allow" and apply its own failure policy to it.
set -uo pipefail
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
# shellcheck source=lib/guard.sh
. "$CEL_ROOT/lib/guard.sh" 2>/dev/null || { printf 'guard-classify: cannot load %s/lib/guard.sh\n' "$CEL_ROOT" >&2; exit 2; }
mode="${1:-}"; cwd="${2:-$PWD}"; arg="${3:-}"
case "$mode" in
  command|path|read) ;;
  *) printf 'guard-classify: unknown mode %q (want command, path or read)\n' "$mode" >&2; exit 2 ;;
esac
role="$(guard_role_of "$cwd")"
# Where the pane stands: a builder's bare `git push` and a relative edit path
# are resolved against it (lib/guard.sh).
_GUARD_CWD="$cwd"
case "$mode" in
  command) guard_classify "$role" "$arg" ;;
  path)    guard_classify_path "$role" "$arg" ;;
  read)    guard_classify_read "$role" "$arg" ;;
esac
exit 0
