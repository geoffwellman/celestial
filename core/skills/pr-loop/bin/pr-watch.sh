#!/usr/bin/env bash
#
# pr-watch.sh — a standing dashboard of open PRs across every repo in the workspace.
#
# Meant to live in its own Herdr pane and just sit there. Strictly read-only: it only
# ever runs `gh pr list`, never merges, closes, comments or pushes. Refresh defaults to
# 60s — two repos is two API calls a minute, nowhere near a rate limit, and slow enough
# that the screen isn't flickering while you read it.
#
#   INTERVAL=30 pr-watch.sh     # override the refresh
#   ALL=1       pr-watch.sh     # everyone's PRs, not just yours
#   AUTHOR=x    pr-watch.sh     # somebody else's
#   ARM=1       pr-watch.sh     # include the omp-variant experiment branches
#
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

INTERVAL="${INTERVAL:-60}"

# Default to your own PRs. games carries 21 open PRs, 15 of them long-lived
# `[ARM · do not merge]` variant drafts, which drowns the handful you actually need to
# act on. `@me` is resolved by gh from the authenticated token, so this stays correct
# for whoever runs it rather than hardcoding a login.
AUTHOR="${AUTHOR:-@me}"
[ -n "${ALL:-}" ] && AUTHOR=""
if [ -n "$AUTHOR" ]; then
  AUTHOR_ARGS=(--author "$AUTHOR")
  SCOPE="$AUTHOR"
else
  AUTHOR_ARGS=()
  SCOPE="everyone"
fi

# Repo list comes from the workspace, not a hardcoded pair, so a third repo appears
# here the moment the workspace gains one.
mapfile -t REPOS < <(cel_pr_repos)
cel_pr_require_repos "${REPOS[*]:-}" || exit 1

while :; do
  # Home + clear rather than `clear`, so the pane's scrollback survives a refresh.
  printf '\033[H\033[2J'
  printf '\033[1mOpen PRs\033[0m \033[36m%s\033[0m%s  %s  \033[2m(refresh %ss · ALL=1 everyone · ARM=1 arms · ctrl+c)\033[0m\n' \
    "$SCOPE" "${ARM:+ \033[36m+arms\033[0m}" "$(date '+%H:%M:%S')" "$INTERVAL"

  for repo in "${REPOS[@]}"; do
    printf '\n\033[38;5;180m▸ %s\033[0m\n' "$repo"
    # A failed API call must not kill the loop — a flaky network or an expired token
    # should show as one bad line and recover on the next tick, not drop you back to a
    # bare shell an hour later with no dashboard and no idea when it died.
    if ! json="$(gh pr list --repo "$repo" --state open --limit 30 "${AUTHOR_ARGS[@]}" \
          --json number,title,headRefName,author,isDraft,reviewDecision,mergeable,statusCheckRollup,updatedAt \
          2>&1)"; then
      printf '  \033[31m! %s\033[0m\n' "$(printf '%s' "$json" | head -1)"
      continue
    fi
    printf '%s' "$json" | python3 "$CEL_PR_BIN/pr-format.py"
  done

  sleep "$INTERVAL"
done
