# shellcheck shell=bash
# THE FORGE SEAM: pull-request operations in Celestial's own vocabulary, so a
# caller never speaks one provider's command language or reads its field
# names. Every operation takes <wsdir> <repo> first, resolves the repo's
# provider with forge_repo (lib/workspace.sh), and prints ONE normalised JSON
# value on stdout; any failure - unknown repo, unknown provider, a refused or
# unreadable call - returns non-zero with the reason on stderr and nothing on
# stdout. Silence is never an answer.
#
#   forge_pr_view   <wsdir> <repo> <number>
#       {number, state: open|closed|merged, head_sha, head_ref, base_ref,
#        author, draft, mergeable: clean|conflicting|behind|unknown,
#        merged_at, url}
#   forge_pr_list   <wsdir> <repo> <open|closed|merged|all> [--author LOGIN|@me] [--head BRANCH] [--limit N]
#       [<the forge_pr_view object>, ...]
#   forge_pr_checks <wsdir> <repo> <number>
#       {head_sha, base_ref, checks: [{name, status: queued|in_progress|completed,
#        conclusion, url}], required: [name, ...],
#        protection: protected|unprotected|unknown}
#       `checks` holds the LATEST run of each check (a re-run supersedes the
#       run it repeats); `conclusion` is null until a check completes.
#       `required` names the checks the base branch is protected by;
#       `unknown` means protection could not be read, which is never
#       permission: only `unprotected` says the branch gates nothing.
#   forge_pr_reviews <wsdir> <repo> <number>
#       {decision: approved|changes_requested|review_required|none,
#        reviews: [{author, state, head_sha, submitted_at}]}
#   forge_pr_merge  <wsdir> <repo> <number> <expected-head-sha> [body]
#       {merged: true, number, head_sha} - a squash merge of exactly that
#       head, branch deleted; the forge refuses if the head moved.
#   forge_whoami    <wsdir> <repo>
#       {login} - the account this workspace acts as on that repo's forge.
#
# GitHub is served through `gh` as the workspace's account (ws_gh), so a
# workspace's `github.user` holds here exactly as everywhere else.
# CEL_FORGE_GH names the gh binary - the one stub seam for tests. A repo on
# Forgejo is refused by every operation until that backend exists: a fake
# answer would be worse than none.
[ -n "${_CEL_FORGE:-}" ] && return 0
_CEL_FORGE=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"

forge_pr_view()    { _forge_call pr_view "$@"; }
forge_pr_list()    { _forge_call pr_list "$@"; }
forge_pr_checks()  { _forge_call pr_checks "$@"; }
forge_pr_reviews() { _forge_call pr_reviews "$@"; }
forge_pr_merge()   { _forge_call pr_merge "$@"; }
forge_whoami()     { _forge_call whoami "$@"; }

# Resolve the repo, then hand the operation to its provider's backend with
# the provider's own address (`owner/name` for GitHub). The workspace's clone
# supplies the origin when the repo declares no url.
_forge_call() { # <op> <wsdir> <repo> [args...]
  local op="$1"
  [ $# -ge 3 ] || { printf 'forge %s: usage: forge_%s <wsdir> <repo> ...\n' "$op" "$op" >&2; return 1; }
  local wsdir="$2" repo="$3" desc provider
  shift 3
  desc="$(forge_repo "$wsdir" "$repo" "$wsdir/repos/$repo")" || return 1
  provider="$(printf '%s' "$desc" | jq -r .provider)"
  case "$provider" in
    github)
      "_forge_github_$op" "$wsdir" "$(printf '%s' "$desc" | jq -r '"\(.owner)/\(.repo)"')" "$@" ;;
    forgejo)
      printf "forge %s: repo '%s' is on Forgejo (%s): Forgejo backend not built yet - refused, nothing was done\n" \
        "$op" "$repo" "$(printf '%s' "$desc" | jq -r .host)" >&2
      return 1 ;;
    *)
      printf "forge %s: repo '%s' has no known provider (%s)\n" "$op" "$repo" "$provider" >&2
      return 1 ;;
  esac
}

_forge_number_ok() { # <op> <number>
  [[ "$2" =~ ^[1-9][0-9]*$ ]] && return 0
  printf "forge %s: '%s' is not a pull request number\n" "$1" "$2" >&2
  return 1
}

# ---- GitHub, through gh ----------------------------------------------------

_forge_gh() { # <wsdir> <gh args...>
  CEL_WS_GH_BIN="${CEL_FORGE_GH:-gh}" ws_gh "$@"
}

_FORGE_GH_PR_FIELDS=number,state,headRefOid,headRefName,baseRefName,author,isDraft,mergeable,mergeStateStatus,mergedAt,url

# GitHub's PR fields in Celestial's words. An empty string is absence (null),
# and anything gh did not state plainly is `unknown`, never `clean`: GitHub
# reports mergeability lazily, and BEHIND comes only from mergeStateStatus.
_FORGE_JQ_GH='
def _s: if . == null or . == "" then null else . end;
def gh_pr:
  if type == "object" and (.number | type) == "number" then . else error("not a pull request") end
  | { number,
      state: (.state | _s | if . == null then null else ascii_downcase end),
      head_sha: (.headRefOid | _s), head_ref: (.headRefName | _s), base_ref: (.baseRefName | _s),
      author: (.author.login | _s),
      draft: (.isDraft | if type == "boolean" then . else null end),
      mergeable: (if .mergeable == "CONFLICTING" then "conflicting"
                  elif .mergeable == "MERGEABLE" and .mergeStateStatus == "BEHIND" then "behind"
                  elif .mergeable == "MERGEABLE" then "clean"
                  else "unknown" end),
      merged_at: (.mergedAt | _s), url: (.url | _s) };
def gh_check:
  if .__typename == "StatusContext" or (.context != null and .name == null) then
    { name: (.context | _s),
      status: (if .state == "PENDING" then "in_progress" elif .state == "EXPECTED" or .state == null then "queued" else "completed" end),
      conclusion: (if .state == "PENDING" or .state == "EXPECTED" or .state == null then null else (.state | ascii_downcase) end),
      url: (.targetUrl | _s) }
  else
    (.conclusion | _s | if . == null then null else ascii_downcase end) as $c
    | { name: (.name | _s),
        status: (if .status == "COMPLETED" or (.status == null and $c != null) then "completed"
                 elif .status == "IN_PROGRESS" then "in_progress"
                 else "queued" end),
        conclusion: (if .status == null or .status == "COMPLETED" then $c else null end),
        url: (.detailsUrl | _s) }
  end;'

_forge_github_pr_view() { # <wsdir> <slug> <number>
  _forge_number_ok pr_view "${3:-}" || return 1
  local out
  out="$(_forge_gh "$1" pr view "$3" --repo "$2" --json "$_FORGE_GH_PR_FIELDS")" || return 1
  printf '%s' "$out" | jq -c "$_FORGE_JQ_GH"' gh_pr'
}

_forge_github_pr_list() { # <wsdir> <slug> <state> [--author L] [--head B] [--limit N]
  local wsdir="$1" slug="$2" state="${3:-}" out
  case "$state" in open|closed|merged|all) ;; *) printf "forge pr_list: state must be open, closed, merged or all (got: '%s')\n" "$state" >&2; return 1 ;; esac
  shift 3
  local -a args=(pr list --repo "$slug" --state "$state")
  local limit=30
  while [ $# -gt 0 ]; do
    case "$1" in
      --author|--head) [ $# -ge 2 ] && [ -n "$2" ] || { printf 'forge pr_list: %s needs a value\n' "$1" >&2; return 1; }
                       args+=("$1" "$2"); shift 2 ;;
      --limit) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { printf "forge pr_list: --limit needs a positive number (got: '%s')\n" "${2:-}" >&2; return 1; }
               limit="$2"; shift 2 ;;
      *) printf 'forge pr_list: unknown argument: %s\n' "$1" >&2; return 1 ;;
    esac
  done
  out="$(_forge_gh "$wsdir" "${args[@]}" --limit "$limit" --json "$_FORGE_GH_PR_FIELDS")" || return 1
  printf '%s' "$out" | jq -c "$_FORGE_JQ_GH"' if type == "array" then map(gh_pr) else error("not a list") end'
}

# The PR's checks from its rollup (latest run of each, CEL_JQ_LATEST_CHECKS)
# and the base branch's required checks from its protection. GitHub's own
# "Branch not protected" is the only failure that means `unprotected`; a
# permission error, rate limit or network failure is `unknown`.
_forge_github_pr_checks() { # <wsdir> <slug> <number>
  _forge_number_ok pr_checks "${3:-}" || return 1
  local wsdir="$1" slug="$2" pr base prot prc=0 protection=unknown required='[]'
  pr="$(_forge_gh "$wsdir" pr view "$3" --repo "$slug" --json headRefOid,baseRefName,statusCheckRollup)" || return 1
  base="$(printf '%s' "$pr" | jq -r '.baseRefName // ""')" || return 1
  if [ -n "$base" ]; then
    prot="$(_forge_gh "$wsdir" api "repos/$slug/branches/$base/protection" 2>&1)" || prc=$?
    if [ "$prc" -eq 0 ] && [ -n "$prot" ]; then
      if required="$(printf '%s' "$prot" | jq -ce '[.required_status_checks.contexts[]?, (.required_status_checks.checks[]?.context)] | unique' 2>/dev/null)"; then
        protection=protected
      else
        required='[]'
      fi
    else
      case "$prot" in *"Branch not protected"*) protection=unprotected ;; esac
    fi
  fi
  printf '%s' "$pr" | jq -c --arg p "$protection" --argjson req "$required" "$CEL_JQ_LATEST_CHECKS$_FORGE_JQ_GH"'
    if type == "object" then . else error("not a pull request") end
    | { head_sha: (.headRefOid | _s), base_ref: (.baseRefName | _s),
        checks: [(.statusCheckRollup // []) | latest_checks[] | gh_check],
        required: $req, protection: $p }'
}

_forge_github_pr_reviews() { # <wsdir> <slug> <number>
  _forge_number_ok pr_reviews "${3:-}" || return 1
  local out
  out="$(_forge_gh "$1" pr view "$3" --repo "$2" --json reviewDecision,reviews)" || return 1
  printf '%s' "$out" | jq -c "$_FORGE_JQ_GH"'
    if type == "object" then . else error("not a pull request") end
    | { decision: ({APPROVED: "approved", CHANGES_REQUESTED: "changes_requested",
                    REVIEW_REQUIRED: "review_required"}[.reviewDecision // ""] // "none"),
        reviews: [(.reviews // [])[] | { author: (.author.login | _s),
                                         state: (.state | _s | if . == null then null else ascii_downcase end),
                                         head_sha: (.commit.oid | _s),
                                         submitted_at: (.submittedAt | _s) }] }'
}

# Squash exactly the head that was checked: --match-head-commit makes GitHub
# refuse the merge if the PR moved since. gh's own report goes to stderr so
# stdout stays the one JSON value.
_forge_github_pr_merge() { # <wsdir> <slug> <number> <expected-head> [body]
  _forge_number_ok pr_merge "${3:-}" || return 1
  local head="${4:-}"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] \
    || { printf "forge pr_merge: the expected head must be a full 40-character lowercase commit SHA (got: '%s') - nothing merged\n" "$head" >&2; return 1; }
  local -a args=(pr merge "$3" --repo "$2" --squash --delete-branch --match-head-commit "$head")
  [ -z "${5:-}" ] || args+=(--body "$5")
  _forge_gh "$1" "${args[@]}" >&2 || return 1
  jq -nc --argjson n "$3" --arg h "$head" '{merged: true, number: $n, head_sha: $h}'
}

_forge_github_whoami() { # <wsdir> <slug>
  local login
  login="$(_forge_gh "$1" api user --jq .login)" || return 1
  [ -n "$login" ] || { printf 'forge whoami: GitHub returned no login\n' >&2; return 1; }
  jq -nc --arg l "$login" '{login: $l}'
}
