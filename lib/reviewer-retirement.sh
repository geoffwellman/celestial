# shellcheck shell=bash
# Retirement owns the exact Rex runtime receipt, never its retained review checkout.
[ -z "${_CEL_REVIEWER_RETIREMENT:-}" ] || return 0
_CEL_REVIEWER_RETIREMENT=1

rex_reviewer_retire() ( # repo pr pane agent dry [repodir]
  local repo="${1:-}" pr="${2:-}" pane="${3:-}" agent="${4:-}" dry="${5:-}" repodir="${6:-}"
  local file fd workspace wsname slug helpers user="" resolved=1 ghbin toolpath
  _rr_unknown() { printf '{"status":"unknown","reason":"%s"}\n' "$1"; exit 2; }
  [[ "$agent" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && [[ "$pr" =~ ^[1-9][0-9]*$ ]] \
    && [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && [[ "$dry" =~ ^[01]$ ]] || _rr_unknown invalid_arguments
  file="$(_rex_file "$agent")" || _rr_unknown receipt_path_unavailable
  [ ! -L "$file" ] && [ ! -L "$file.lock" ] || _rr_unknown receipt_unavailable
  exec {fd}>"$file.lock" || _rr_unknown receipt_lock_unavailable
  flock -n "$fd" || _rr_unknown receipt_busy
  wsname="" slug="" helpers=""
  if [ -f "$file" ]; then
    # Resolution failures still reach proof-only replay. Without a completed
    # proof the helper rejects the invalid policy arguments before any action.
    workspace="$(jq -er '.workspace | select(type == "string" and startswith("/"))' "$file" 2>/dev/null)" || resolved=0
    wsname="$(ws_name "$workspace" 2>/dev/null)" || resolved=0
    slug="$(ws_repo_github_slug "$workspace" "$repo" "$repodir" 2>/dev/null)" || resolved=0
    helpers="$(agent_owned_children pi 2>/dev/null)" || resolved=0
    if declare -F ws_github_user >/dev/null; then user="$(ws_github_user "$workspace" 2>/dev/null)" || resolved=0; fi
    [ "$resolved" -eq 1 ] || slug=""
  fi
  # The gh retire.mjs runs with the workspace's token, and the PATH it runs on
  # (gh starts git and a pager through PATH): resolved here, by the same rule
  # as ws_gh (cel_gh_bin, cel_tool_path), and handed over as arguments -
  # retire.mjs reads neither from its environment. Empty when there is no gh:
  # it then refuses to ask GitHub.
  ghbin="$(cel_gh_bin "${CEL_WS_GH_BIN:-}" 2>/dev/null)" || ghbin=""
  toolpath="$(cel_tool_path)"
  # No child or Rex server may inherit launch, GC, or retirement lock leases.
  (
    exec {fd}>&-
    [ -z "${_RUN_ADMISSION_FD:-}" ] || exec {_RUN_ADMISSION_FD}>&-
    [ -z "${_REX_LAUNCH_FD:-}" ] || exec {_REX_LAUNCH_FD}>&-
    [ -z "${lock_fd:-}" ] || exec {lock_fd}>&-
    exec node "$CEL_ROOT/tools/reviewers/retire.mjs" "$repo" "$pr" "$pane" "$agent" "$dry" "$file" "$wsname" "$slug" "$helpers" "$user" "$repodir" "$ghbin" "$toolpath"
  )
)

# Read-only deletion veto. A prepared packet protects evidence even if close
# failed; this function never authorizes a close or approves a review round.
rex_reviewer_checkout_preserved() (
  [ $# -eq 1 ] || return 1
  exec node "$CEL_ROOT/tools/reviewers/retire.mjs" --checkout-preserved "$1" "$(_rex_state)"
)
