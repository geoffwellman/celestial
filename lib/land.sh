# shellcheck shell=bash
# What a merge must prove, shared by the two doors that merge: `cel-fanout
# land` (a fleet delegation) and `cel solo land` (a solo product's own PR).
# Two copies of "is CI green enough to stand in for a gate" would drift, and
# the one that drifted would be the one nobody was watching.
[ -n "${_CEL_LAND:-}" ] && return 0
_CEL_LAND=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/forge.sh
. "${BASH_SOURCE[0]%/*}/forge.sh" # _forge_github_base_required: what the base requires

# gh as the workspace's account; GH (cel-fanout's stub seam) when set.
_land_gh() { # <wsdir> <gh args...>
  CEL_WS_GH_BIN="${GH:-gh}" ws_gh "$@"
}

# Prints "Gate: CI (<checks>) on <head>" when every check the PR's base branch
# is protected by concluded success on the PR's exact head; otherwise prints why
# not and returns 1. Never dies: fleet land asks this BEFORE its local gate too,
# and a "no" there means "run the gate as before", not "refuse".
#
# WHAT MAY STAND IN FOR A GATE: only EVERY check the base branch REQUIRES -
# through classic branch protection or a ruleset, read by lib/forge.sh's
# _forge_github_base_required - concluded success on this head, matched by
# name: a green docs or lint job alone never carries a merge. Requirements
# this token cannot read, or a rule that requires checks without naming them,
# are not permission: absence of evidence is not evidence.
land_ci_gate() { # <wsdir> <slug> <pr-json>
  local wsdir="$1" slug="$2" pr="$3"
  local head base gate protection req cr missing
  # Set only when the base branch requires no check - GitHub's own "Branch
  # not protected" and no ruleset requiring one, or protection that names no
  # check: CI cannot stand in, but a caller may run the repo's own gate
  # instead. A required check that is not green, or requirements that could
  # not be established, never set it.
  LAND_CI_UNPROTECTED=0
  head="$(printf '%s' "$pr" | jq -r '.headRefOid // ""')"
  base="$(printf '%s' "$pr" | jq -r '.baseRefName // ""')"
  [ -n "$head" ] || { printf '%s' "the PR reports no head commit - nothing to check CI against"; return 1; }
  [ -n "$base" ] || { printf '%s' "the PR reports no base branch - nothing to read protection from"; return 1; }
  gate="$(CEL_FORGE_GH="${GH:-gh}" _forge_github_base_required "$wsdir" "$slug" "$base")"
  protection="$(printf '%s' "$gate" | jq -r '.protection // "unknown"' 2>/dev/null)"
  if [ "$protection" != protected ] && [ "$protection" != unprotected ]; then
    printf '%s' "cannot establish which checks $base on $slug requires (branch protection or rulesets unreadable, or a rule requires checks it does not name) - with no known required check there is nothing for CI to stand in with, and nothing proves the branch gates nothing. Give the gate more time instead (CEL_VERIFY_GATE_TIMEOUT)."
    return 1
  fi
  req="$(printf '%s' "$gate" | jq -r '.required[]')"
  [ -n "$req" ] || { LAND_CI_UNPROTECTED=1; printf '%s' "$base on $slug requires no check - a branch nothing gates cannot lend its verdict to this one"; return 1; }
  cr="$(_land_gh "$wsdir" api "repos/$slug/commits/$head/check-runs" 2>/dev/null || true)"
  missing="$(printf '%s' "$cr" | jq -r --argjson want "$(printf '%s' "$req" | jq -R . | jq -sc .)" '
    [.check_runs[]? | select((.conclusion // "") == "success") | .name] as $green
    | [$want[] | select(. as $w | ($green | index($w)) | not)] | join(", ")' 2>/dev/null || true)"
  [ -z "$missing" ] || { printf '%s' "required check(s) not green on $head: $missing - CI cannot stand in for a gate it did not pass"; return 1; }
  local names; names="$(printf '%s' "$req" | paste -sd, - | sed 's/,/, /g')"
  printf 'Gate: CI (%s) on %s' "$names" "$head"
}

# The squash body lands on main, and the push-run hygiene scan reads all of
# history: a merge whose body would break every later PR is refused here,
# naming the token. Reuses the scanner's own regex and prefix sets.
# Prints the offending tokens (nothing when clean); fails only when the check
# itself cannot run.
land_body_hygiene() { # <body>
  printf '%s' "$1" | python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import hygiene as h
ok = h.EXAMPLE_PREFIXES | h.STANDARD_PREFIXES
for line in sys.stdin.read().splitlines():
    for m in h.TICKET.finditer(line.replace("[A-Z0-9]", " " * 8)):
        if m[1] not in ok: print(m[0])
' "$CEL_ROOT/tools/release"
}
