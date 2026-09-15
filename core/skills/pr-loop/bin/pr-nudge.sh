#!/usr/bin/env bash
#
# pr-nudge.sh <repo> <number> — re-trigger the reviewer on a PR it has gone quiet on.
#
# TWO calls, deliberately. `gh pr edit --remove-reviewer X --add-reviewer X` sends both in ONE
# API request and the REMOVAL WINS: it returns success, prints the PR url, and leaves the PR
# with NO reviewer at all — a nudge that silently un-asks for the review it meant to chase
# (observed 2026-08-31). The removal is also what makes the nudge work: adding a
# login already on the request is a no-op that fires no event.
#
# Verifies the reviewer is actually back on the PR before reporting success — the failure this
# exists to prevent was invisible precisely because the command reported success.
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
cel_pr_require_reviewer || exit 1
repo="$1"; num="$2"; reviewer="$REVIEWER"

gh pr edit "$num" --repo "$repo" --remove-reviewer "$reviewer" >/dev/null
gh pr edit "$num" --repo "$repo" --add-reviewer "$reviewer" >/dev/null

for _ in 1 2 3; do
  if gh pr view "$num" --repo "$repo" --json reviewRequests \
       --jq '[.reviewRequests[].login]' | grep -q "$reviewer"; then
    echo "nudged: $reviewer re-requested on $repo#$num"
    exit 0
  fi
  sleep 2
done
echo "FAILED: $reviewer is NOT on $repo#$num after the re-request — fix by hand before looping" >&2
exit 1
