#!/usr/bin/env bash
#
# pr-state.sh — what does this PR need next?
#
# The read half of the pr-loop skill. Strictly read-only: it decides, it never acts, so it is
# always safe to run. Every action it names is taken by the agent afterwards, deliberately.
#
#   pr-state.sh                              # every open PR of mine, across the workspace
#   pr-state.sh 1043                         # one PR, repo inferred if only one matches
#   pr-state.sh owner/repo 1043
#
# REVIEWER=x     the reviewer to shepherd. No default - see lib.sh.
# CEL_PR_REPOS=  'owner/repo ...' to override the workspace's repo list.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

FIELDS='author,number,title,url,headRefName,isDraft,mergeable,reviewDecision,statusCheckRollup,reviews,reviewRequests,commits'
cel_pr_require_reviewer || exit 1
# Whose PRs this loop is allowed to act on. Resolved from the authenticated token, so it is
# whoever is actually holding the gh session rather than a name baked into a script. Every PR
# not authored by them decides `not-mine` and is never acted on — see pr-state.py's guard.
VIEWER="${VIEWER:-$(gh api user -q .login 2>/dev/null)}"
export REVIEWER VIEWER

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

one() { # repo number
  local repo="$1" num="$2"
  # Both payloads go to FILES, never onto a command line. A long-lived PR's timeline runs to
  # megabytes and `jq -n --argjson` died with "Argument list too long" on an 18-day-old PR.
  if ! gh pr view "$num" --repo "$repo" --json "$FIELDS" >"$TMP/pr.json" 2>"$TMP/err"; then
    printf '  \033[31m! %s #%s: %s\033[0m\n' "$repo" "$num" "$(head -1 "$TMP/err")"
    return
  fi
  # The review-request TIMESTAMPS live only in the timeline — `gh pr view` carries the current
  # request but not when it was made, and "how long has this been sitting" is the whole question.
  gh api "repos/$repo/issues/$num/timeline" --paginate >"$TMP/tl.json" 2>/dev/null || echo '[]' >"$TMP/tl.json"
  PR_FILE="$TMP/pr.json" TL_FILE="$TMP/tl.json" python3 "$CEL_PR_BIN/pr-state.py"
}

if [ $# -eq 2 ]; then
  one "$1" "$2"; exit 0
fi

mapfile -t REPOS < <(cel_pr_repos)
cel_pr_require_repos "${REPOS[*]:-}" || exit 1

if [ $# -eq 1 ]; then
  for repo in "${REPOS[@]}"; do
    if gh pr view "$1" --repo "$repo" --json number >/dev/null 2>&1; then one "$repo" "$1"; fi
  done
  exit 0
fi

printf '\033[1mPR loop\033[0m \033[36m%s\033[0m \033[2m→\033[0m \033[36m%s\033[0m  %s\n' "${VIEWER:-anyone}" "$REVIEWER" "$(date '+%H:%M:%S')"
for repo in "${REPOS[@]}"; do
  printf '\n\033[38;5;180m▸ %s\033[0m\n' "$repo"
  # ARM variant drafts are excluded the same way the dashboard excludes them: they say "do not
  # merge" in their own titles and are never waiting on a review.
  nums="$(gh pr list --repo "$repo" --state open --author @me --limit 30 \
            --json number,headRefName,title,isDraft \
            --jq '.[] | select(.headRefName|startswith("omp-variant/")|not)
                      | select(.title|startswith("[ARM")|not) | .number' 2>/dev/null)"
  [ -z "$nums" ] && { printf '  \033[2mnothing open\033[0m\n'; continue; }
  for n in $nums; do one "$repo" "$n"; done
done
