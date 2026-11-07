# shellcheck shell=bash
# What a merge must prove, for the door that merges: `cel solo land` (a
# product's own PR, merged by its solo agent). One definition of "is CI green
# enough to stand in for a gate", so it cannot drift between callers.
[ -n "${_CEL_LAND:-}" ] && return 0
_CEL_LAND=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/forge.sh
. "${BASH_SOURCE[0]%/*}/forge.sh" # forge_pr_checks: the head's checks and what the base requires

# gh as the workspace's account; GH (a test stub seam) when set.
_land_gh() { # <wsdir> <gh args...>
  CEL_WS_GH_BIN="${GH:-gh}" ws_gh "$@"
}

# Prints "Gate: CI (<checks>) on <head>" when every check the PR's base branch
# requires concluded success on the PR's exact head; otherwise prints why not
# and returns 1. Never dies: fleet land asks this BEFORE its local gate too,
# and a "no" there means "run the gate as before", not "refuse".
#
# WHAT MAY STAND IN FOR A GATE: only EVERY check the base branch REQUIRES,
# concluded success in its LATEST run on this head, matched by name - a green
# docs or lint job alone never carries a merge, and an earlier green run of a
# check whose re-run failed is not green. Both facts come from one
# forge_pr_checks read (lib/forge.sh), on GitHub (classic protection and
# rulesets) or Forgejo (branch protection rules) alike. Requirements that
# cannot be read, or a rule that requires checks without naming them, are not
# permission: absence of evidence is not evidence.
land_ci_gate() { # <wsdir> <repo> <pr-json: {number, head_sha, base_ref}>
  local wsdir="$1" repo="$2" pr="$3"
  local num head base checks protection req missing
  # Set only when the base branch requires no check - the forge's own answer
  # that nothing protects it, or protection that names no check: CI cannot
  # stand in, but a caller may run the repo's own gate instead. A required
  # check that is not green, or requirements that could not be established,
  # never set it.
  LAND_CI_UNPROTECTED=0
  num="$(printf '%s' "$pr" | jq -r '.number // ""')"
  head="$(printf '%s' "$pr" | jq -r '.head_sha // ""')"
  base="$(printf '%s' "$pr" | jq -r '.base_ref // ""')"
  [ -n "$head" ] || { printf '%s' "the PR reports no head commit - nothing to check CI against"; return 1; }
  [ -n "$base" ] || { printf '%s' "the PR reports no base branch - nothing to read protection from"; return 1; }
  checks="$(CEL_FORGE_GH="${GH:-gh}" forge_pr_checks "$wsdir" "$repo" "$num" 2>/dev/null)" \
    || { printf '%s' "cannot read the checks of $repo#$num from its forge - nothing for CI to stand in with"; return 1; }
  [ "$(printf '%s' "$checks" | jq -r '.head_sha // ""')" = "$head" ] \
    || { printf '%s' "$repo#$num moved to $(printf '%s' "$checks" | jq -r '.head_sha // "an unknown head"') since $head was read - nothing decided"; return 1; }
  protection="$(printf '%s' "$checks" | jq -r '.protection // "unknown"')"
  if [ "$protection" != protected ] && [ "$protection" != unprotected ]; then
    printf '%s' "cannot establish which checks $base on $repo requires (branch protection or rulesets unreadable, or a rule requires checks it does not name) - with no known required check there is nothing for CI to stand in with, and nothing proves the branch gates nothing. Give the gate more time instead (CEL_VERIFY_GATE_TIMEOUT)."
    return 1
  fi
  req="$(printf '%s' "$checks" | jq -r '.required[]')"
  [ -n "$req" ] || { LAND_CI_UNPROTECTED=1; printf '%s' "$base on $repo requires no check - a branch nothing gates cannot lend its verdict to this one"; return 1; }
  missing="$(printf '%s' "$checks" | jq -r '
    [.checks[] | select(.status == "completed" and .conclusion == "success") | .name] as $green
    | [.required[] | select(. as $w | ($green | index($w)) | not)] | join(", ")')"
  [ -z "$missing" ] || { printf '%s' "required check(s) not green on $head: $missing - CI cannot stand in for a gate it did not pass"; return 1; }
  printf 'Gate: CI (%s) on %s' "$(printf '%s' "$checks" | jq -r '.required | join(", ")')" "$head"
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
