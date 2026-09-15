# shellcheck shell=bash
# Shared resolution for the pr-loop helpers.
#
# These scripts used to sit beside a single repo manifest and resolve everything
# with `cd "$(dirname "$0")/.."` — one directory, one repo list, one reviewer. As
# core content they must run from any repo in any workspace, so the two things
# they cannot know for themselves now arrive from outside: WHICH REPOS (a
# workspace fact) and WHICH REVIEWER (a policy fact).

CEL_PR_BIN="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# The plane owns no repo list: repos belong to a workspace. CEL_PR_REPOS wins so a
# caller can scope a run to one repo; otherwise the workspace's own manifest.
cel_pr_repos() {
  if [ -n "${CEL_PR_REPOS:-}" ]; then
    printf '%s\n' ${CEL_PR_REPOS}
    return 0
  fi
  # CEL_WORKSPACE wins when set; otherwise walk up from the cwd - layout panes
  # and ad-hoc shells sit inside the workspace dir without the env var.
  local d="${CEL_WORKSPACE:-$PWD}"
  while [ "$d" != "/" ] && [ ! -f "$d/workspace.yaml" ]; do d="$(dirname "$d")"; done
  [ -f "$d/workspace.yaml" ] || return 0
  yq -r '.repos // [] | .[].url' "$d/workspace.yaml" 2>/dev/null \
    | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##'
}

# A null reviewer disables the skill rather than defaulting to somebody. Shepherding
# a review towards a login the workspace never named is worse than doing nothing:
# it puts a stranger on a colleague's PR.
cel_pr_require_reviewer() {
  [ -n "${REVIEWER:-}" ] && return 0
  echo "pr-loop: no reviewer. Set REVIEWER, or policy.reviewer in the workspace;" >&2
  echo "         where policy.reviewer is null this skill does not apply." >&2
  return 1
}

cel_pr_require_repos() {
  [ -n "$1" ] && return 0
  echo "pr-loop: no repos. Set CEL_PR_REPOS='owner/repo ...', or run inside a" >&2
  echo "         workspace so CEL_WORKSPACE/workspace.yaml resolves." >&2
  return 1
}
