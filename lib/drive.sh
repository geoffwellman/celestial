# shellcheck shell=bash
# `cel drive` (CEL-120): see and drive an orchestrator from one shared core.
#
# list/tail/receipt read herdr and the session files (tools/drive/cli.mjs).
# send is MAIL and only mail: `cel inbox send --kind owner --from owner`, then
# the omp inbox hook delivers it at the next idle point with an empty
# composer, or as soon as a busy turn ends. Never `herdr agent prompt`, never
# keys - those typed over half-written drafts (CEL-65) and left prompts
# sitting unsubmitted in composers for hours.
[ -n "${_CEL_DRIVE:-}" ] && return 0
_CEL_DRIVE=1
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"

_drive_ws_map() { # -> "name<TAB>path" per registered workspace
  local n
  for n in $(registry_names 2>/dev/null || true); do
    printf '%s\t%s\n' "$n" "$(registry_path "$n" 2>/dev/null || true)"
  done
}

_drive_node() { # <subcommand> [args...]
  command -v node >/dev/null || die "cel drive needs node"
  CEL_DRIVE_WS="$(_drive_ws_map)" node --no-warnings "$CEL_ROOT/tools/drive/cli.mjs" "$@"
}

_drive_usage() {
  cat <<'EOS'
cel drive - see and talk to orchestrators without touching their panes

  cel drive list [--json]                 orchestrators: name, status, runtime,
                                          workspace, product, session file
  cel drive tail <orch> [--json] [--follow] [--since <entry-id>]
                                          the conversation, normalised and
                                          redacted; --follow survives a restart
  cel drive send <orch> <message> [--workspace w] [--json]
                                          mail from owner; delivered by the
                                          inbox hook when the agent is idle
                                          with an empty composer
  cel drive receipt <id> [--json]         queued -> delivered -> in-conversation
EOS
}

_drive_send() { # <orch> <message> [--workspace w] [--json]
  [ $# -ge 2 ] || die "usage: cel drive send <orch> <message> [--workspace w] [--json]"
  local orch="$1" msg="$2" ws="" json=0; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws="$2"; shift 2 ;;
      --json) json=1; shift ;;
      *) die "cel drive send: unknown argument '$1'" ;;
    esac
  done
  # The target must be a live orchestrator herdr knows: a typo must not
  # create a mailbox nobody will ever open.
  local info
  info="$(_drive_node find "$orch")" || die "cel drive send: refusing - '$orch' is not a running orchestrator"
  [ -n "$ws" ] || ws="$(jq -r '.workspace // ""' <<<"$info")"
  [ -n "$ws" ] || die "cel drive send: cannot tell $orch's workspace; pass --workspace"
  # shellcheck source=lib/inbox.sh
  . "$CEL_ROOT/lib/inbox.sh"
  local id
  id="$(_inbox_send "$orch" "$msg" --from owner --kind owner --workspace "$ws")" || die "cel drive send: mail failed"
  if [ "$json" -eq 1 ]; then
    jq -nc --arg id "$id" --arg to "$orch" --arg ws "$ws" '{id: $id, to: $to, workspace: $ws, state: "queued"}'
  else
    printf '%s\n' "$id"
  fi
}

cmd_drive() {
  local sub="${1:-help}"; [ $# -gt 0 ] && shift
  case "$sub" in
    list|tail|receipt) _drive_node "$sub" "$@" ;;
    send) _drive_send "$@" ;;
    help|-h|--help) _drive_usage ;;
    *) _drive_usage >&2; die "cel drive: unknown subcommand '$sub'" ;;
  esac
}
