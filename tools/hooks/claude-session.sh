#!/usr/bin/env bash
# Claude 2.1.312 command hook: native stdin identity plus proven Rex ancestry.
# No output or input injection: status reporting never touches the composer.
set -uo pipefail
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
[ -n "${CEL_REX_RECORD:-}" ] && [ -f "$CEL_REX_RECORD" ] || exit 0
[ -x "$CEL_ROOT/bin/cel" ] || exit 0
payload="$(cat)" || exit 0
fields="$(jq -er '
  select(type == "object" and ((.agent_id // "") == ""))
  | [.session_id, .cwd, .hook_event_name]
  | select(all(.[]; type == "string" and length > 0 and (test("[[:cntrl:]]") | not)))
  | @tsv' <<<"$payload" 2>/dev/null)" || exit 0
IFS=$'\t' read -r native cwd event <<<"$fields"
[[ "$native" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || exit 0
case "$event" in
  SessionStart)
    case "$(jq -r '.source // empty' <<<"$payload")" in
      startup|resume|clear) state=idle ;;
      compact) state=working ;;
      *) exit 0 ;;
    esac ;;
  UserPromptSubmit) state=working ;;
  # Stop's inbox handler decides whether this is really idle or continuing.
  Stop) case "${1:-}" in idle|working) state="$1" ;; *) exit 0 ;; esac ;;
  *) exit 0 ;;
esac
source "$CEL_ROOT/lib/rex.sh"
jq -e '.agent == "claude" and .backend == "rex"' "$CEL_REX_RECORD" >/dev/null 2>&1 || exit 0
record_cwd="$(jq -r '.cwd // empty' "$CEL_REX_RECORD")" || exit 0
[ -n "$record_cwd" ] && [ "$cwd" -ef "$record_cwd" ] || exit 0
pid="$(rex_reporter_pid)" || exit 0
"$CEL_ROOT/bin/cel" sessions note "$pid" "$state" "$native" >/dev/null 2>&1 || true
