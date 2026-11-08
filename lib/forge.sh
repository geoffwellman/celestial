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
#        merged_at, url, labels: [name, ...]}
#   forge_pr_list   <wsdir> <repo> <open|closed|merged|all> [--author LOGIN|@me] [--head BRANCH] [--limit N]
#       [<the forge_pr_view object>, ...]
#   forge_pr_checks <wsdir> <repo> <number>
#       {head_sha, base_ref, checks: [{name, status: queued|in_progress|completed,
#        conclusion, url}], required: [name, ...],
#        protection: protected|unprotected|unknown}
#       `checks` holds the LATEST run of each check (a re-run supersedes the
#       run it repeats); `conclusion` is null until a check completes.
#       `required` names the checks the base branch requires, from classic
#       branch protection and repository/organisation rulesets together;
#       `unknown` means that could not be established, which is never
#       permission: only `unprotected` says the branch requires no check.
#   forge_pr_reviews <wsdir> <repo> <number>
#       {decision: approved|changes_requested|review_required|none,
#        reviews: [{author, state, head_sha, submitted_at}]}
#   forge_pr_merge  <wsdir> <repo> <number> <expected-head-sha> [body]
#       {merged: true, number, head_sha} - a squash merge of exactly that
#       head, branch deleted; the forge refuses if the head moved.
#   forge_pr_create <wsdir> <repo> <head-branch> <base-branch> <title> <body-file>
#       <the forge_pr_view object> of the new PR - ready for review, or a
#       draft only where the workspace's policy.pr_open is not `ready`.
#   forge_pr_close  <wsdir> <repo> <number> [comment-file]
#       <the forge_pr_view object> after closing - the comment, if any, is
#       posted first; the branch is never deleted.
#   forge_pr_ready  <wsdir> <repo> <number>
#       <the forge_pr_view object> once it is ready for review; a PR that is
#       not a draft is left as it is.
#   forge_whoami    <wsdir> <repo>
#       {login} - the account this workspace acts as on that repo's forge.
#   forge_run_list  <wsdir> <repo> [--branch B] [--sha SHA] [--limit N]
#       [{id, number, workflow, title, event, branch, head_sha,
#         state, url, created_at}, ...] newest first. `id` is the API's run
#       id - the one every other op takes; `number` is the web UI's run
#       number (Forgejo's /actions/runs/<number>), which is NOT an id. With
#       --sha (a full 40-character commit) only that commit's runs, each
#       with its `jobs` as forge_run_view gives them.
#   forge_run_view  <wsdir> <repo> <run-id>
#       <the run object> + {jobs: [{id, name, state, url}]}
#   forge_run_logs  <wsdir> <repo> <job-id> [--raw]
#       the job's log as PLAIN TEXT (the one op that prints no JSON), each
#       line's timestamp (and on GitHub its job and step columns) removed
#       unless --raw. On GitHub it is the job's failed steps (gh --log-failed).
#   forge_run_rerun <wsdir> <repo> <job-id>
#       {rerun: true, job_id} - the job runs again on the same head.
#   forge_run_resolve <wsdir> <repo> <web-url>
#       {run_id, job_id} (job_id null for a run's url) - the API ids behind a
#       run's or job's web page; refused when the page cannot be matched
#       exactly (Forgejo: by the run's and the job's own html_url).
#   A run's or job's `state` is the check vocabulary: success | failure |
#   cancelled | skipped | running | queued | unknown. Forgejo Actions says it
#   in `status` and leaves `conclusion` null, so a status of `failure` IS the
#   failure.
#
# GitHub is served through `gh` as the workspace's account (ws_gh), so a
# workspace's `github.user` holds here exactly as everywhere else.
# CEL_FORGE_GH names the gh binary - the one stub seam for tests.
#
# Forgejo is served over its REST API (/api/v1) with curl, as the account
# whose token sits in ${XDG_CONFIG_HOME:-~/.config}/cel/forge/<host>.token
# (mode 600, the host as the descriptor names it). The token is read only
# for a request to that exact host and travels on curl's stdin as a config
# line - never in argv, a log or an error. A repo declared on plain http://
# says so on stderr for every request that sends its token: it crosses the
# network unencrypted. CEL_FORGE_CURL names the curl binary - that backend's one
# stub seam, honoured only under CEL_TESTING (set by tests/run.sh), so a
# stray variable cannot hand the token to another binary. The token's
# directory follows XDG_CONFIG_HOME, the standard per-user config root.
# Where Forgejo cannot say what GitHub says, the answer is the conservative
# one, never a guess:
#   - `draft` is Forgejo's own `WIP:` title prefix; mergeable=false reads as
#     `unknown`, never `conflicting`: Forgejo also says false while it has not
#     (re)computed the PR - recorded live on a clean fast-forward whose head
#     contained the base - and its API has no field that proves a conflict.
#   - a commit status's target_url is site-relative on Forgejo Actions
#     (`/owner/repo/actions/runs/N/jobs/M`); it is made absolute on its host.
#   - `decision` is `approved` only for an approval of the CURRENT head that
#     Forgejo has not marked stale or dismissed, and no reviewer's latest
#     verdict requesting changes; Forgejo has no review_required.
#   - required checks come from the branch protection rule that applies to
#     the base: the exact rule, else every glob rule matching it; see
#     _forge_forgejo_base_required.
[ -n "${_CEL_FORGE:-}" ] && return 0
_CEL_FORGE=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/identity.sh
. "${BASH_SOURCE[0]%/*}/identity.sh"   # cel_launch_identity: a write acts as its launch

forge_pr_view()    { _forge_call pr_view "$@"; }
forge_pr_list()    { _forge_call pr_list "$@"; }
forge_pr_checks()  { _forge_call pr_checks "$@"; }
forge_pr_reviews() { _forge_call pr_reviews "$@"; }
forge_pr_merge()   { _forge_call pr_merge "$@"; }
forge_pr_close()   { _forge_call pr_close "$@"; }
forge_pr_ready()   { _forge_call pr_ready "$@"; }
forge_whoami()     { _forge_call whoami "$@"; }
forge_run_view()   { _forge_call run_view "$@"; }
forge_run_logs()   { _forge_call run_logs "$@"; }
forge_run_rerun()  { _forge_call run_rerun "$@"; }
forge_run_resolve() { _forge_call run_resolve "$@"; }

# With --sha every run carries its jobs: an agent finding a commit's runs
# wants the job ids its logs and reruns take, not the web UI's numbers.
forge_run_list() { # <wsdir> <repo> [--branch B] [--sha SHA] [--limit N]
  local out sha="" a prev="" id view all='[]'
  for a in "$@"; do [ "$prev" != --sha ] || sha="$a"; prev="$a"; done
  out="$(_forge_call run_list "$@")" || return 1
  [ -n "$sha" ] || { printf '%s\n' "$out"; return 0; }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    view="$(forge_run_view "$1" "$2" "$id")" || return 1
    all="$(printf '%s\n%s' "$all" "$view" | jq -sc '.[0] + [.[1]]')"
  done < <(printf '%s' "$out" | jq -r '.[].id')
  printf '%s\n' "$all"
}

# A PR opens ready for review unless the workspace's policy says draft
# (policy.pr_open other than `ready`, the same rule the policy block states):
# the draft/ready choice is the workspace's, not the caller's.
forge_pr_create() { # <wsdir> <repo> <head> <base> <title> <body-file>
  [ $# -eq 6 ] || { printf 'forge pr_create: usage: forge_pr_create <wsdir> <repo> <head-branch> <base-branch> <title> <body-file>\n' >&2; return 1; }
  local a
  for a in "$3" "$4" "$5"; do
    [ -n "$a" ] || { printf 'forge pr_create: head, base and title must all be given - nothing opened\n' >&2; return 1; }
  done
  [ -f "$6" ] && [ -r "$6" ] || { printf "forge pr_create: body file '%s' is not a readable file - nothing opened\n" "$6" >&2; return 1; }
  local draft=1
  [ "$(ws_policy "$1" pr_open)" != ready ] || draft=0
  _forge_call pr_create "$@" "$draft"
}

# Resolve the repo, then hand the operation to its provider's backend with
# the provider's own address: `owner/name` for GitHub, the whole descriptor
# for Forgejo (its host and API root vary per repo). The workspace's clone
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
      "_forge_forgejo_$op" "$wsdir" "$desc" "$@" ;;
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

_forge_id_ok() { # <op> <what> <id>
  [[ "$3" =~ ^[1-9][0-9]*$ ]] && return 0
  printf "forge %s: '%s' is not a %s id\n" "$1" "$3" "$2" >&2
  return 1
}

# run_list's arguments, one reading for both backends: sets _RL_BRANCH,
# _RL_SHA and _RL_LIMIT (default 20).
_forge_run_args() { # [--branch B] [--sha SHA] [--limit N]
  _RL_BRANCH="" _RL_SHA="" _RL_LIMIT=20
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch) [ $# -ge 2 ] && [ -n "$2" ] || { printf 'forge run_list: --branch needs a value\n' >&2; return 1; }
                _RL_BRANCH="$2"; shift 2 ;;
      --sha) [[ "${2:-}" =~ ^[0-9a-f]{40}$ ]] \
               || { printf "forge run_list: --sha needs the full 40-character commit (got: '%s'; git rev-parse <ref>, or head_sha from cel forge pr view)\n" "${2:-}" >&2; return 1; }
             _RL_SHA="$2"; shift 2 ;;
      --limit) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { printf "forge run_list: --limit needs a positive number (got: '%s')\n" "${2:-}" >&2; return 1; }
               _RL_LIMIT="$2"; shift 2 ;;
      *) printf 'forge run_list: unknown argument: %s\n' "$1" >&2; return 1 ;;
    esac
  done
}

# A job log without its per-line prefixes: GitHub's `<job>\t<step>\t` columns
# (gh run view --log*), a byte-order mark, and the runner's RFC 3339 timestamp.
_forge_log_strip() { # [--github] < log
  if [ "${1:-}" = --github ]; then
    sed -E $'s/^[^\t]*\t[^\t]*\t//; s/^\xEF\xBB\xBF//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//'
  else
    sed -E $'s/^\xEF\xBB\xBF//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//'
  fi
}

# ---- GitHub, through gh ----------------------------------------------------

_forge_gh() { # <wsdir> <gh args...>
  CEL_WS_GH_BIN="${CEL_FORGE_GH:-gh}" ws_gh "$@"
}

_FORGE_GH_PR_FIELDS=number,state,headRefOid,headRefName,baseRefName,author,isDraft,mergeable,mergeStateStatus,mergedAt,url,labels

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
      merged_at: (.mergedAt | _s), url: (.url | _s),
      labels: [(.labels // [])[]? | .name? | strings] };
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
  end;
def gh_state:
  ((.status // "") | ascii_downcase) as $st | ((.conclusion // "") | ascii_downcase) as $c
  | if $st == "completed" or ($st == "" and $c != "") then
      ({success: "success", neutral: "success", failure: "failure", timed_out: "failure",
        startup_failure: "failure", cancelled: "cancelled", stale: "cancelled", skipped: "skipped",
        action_required: "queued"}[$c] // "unknown")
    elif $st == "in_progress" then "running"
    elif $st == "queued" or $st == "waiting" or $st == "requested" or $st == "pending" then "queued"
    else "unknown" end;
def gh_run:
  if type == "object" and (.databaseId | type) == "number" then . else error("not a run") end
  | { id: .databaseId, number: (.number // null), workflow: (.workflowName | _s), title: (.displayTitle | _s),
      event: (.event | _s), branch: (.headBranch | _s), head_sha: (.headSha | _s), state: gh_state,
      url: (.url | _s), created_at: (.createdAt | _s) };
def gh_job: { id: .databaseId, name: (.name | _s), state: gh_state, url: (.url | _s) };'

_forge_github_pr_view() { # <wsdir> <slug> <number>
  _forge_number_ok pr_view "${3:-}" || return 1
  local out
  out="$(_forge_gh "$1" pr view "$3" --repo "$2" --json "$_FORGE_GH_PR_FIELDS")" || return 1
  printf '%s' "$out" | jq -c "$_FORGE_JQ_GH"' gh_pr'
}

# pr_list's arguments, one reading for both backends: sets _FL_STATE,
# _FL_AUTHOR, _FL_HEAD and _FL_LIMIT (default 30).
_forge_list_args() { # <state> [--author L] [--head B] [--limit N]
  _FL_STATE="${1:-}" _FL_AUTHOR="" _FL_HEAD="" _FL_LIMIT=30
  case "$_FL_STATE" in open|closed|merged|all) ;; *) printf "forge pr_list: state must be open, closed, merged or all (got: '%s')\n" "$_FL_STATE" >&2; return 1 ;; esac
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --author|--head) [ $# -ge 2 ] && [ -n "$2" ] || { printf 'forge pr_list: %s needs a value\n' "$1" >&2; return 1; }
                       if [ "$1" = --author ]; then _FL_AUTHOR="$2"; else _FL_HEAD="$2"; fi; shift 2 ;;
      --limit) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { printf "forge pr_list: --limit needs a positive number (got: '%s')\n" "${2:-}" >&2; return 1; }
               _FL_LIMIT="$2"; shift 2 ;;
      *) printf 'forge pr_list: unknown argument: %s\n' "$1" >&2; return 1 ;;
    esac
  done
}

_forge_github_pr_list() { # <wsdir> <slug> <state> [--author L] [--head B] [--limit N]
  local wsdir="$1" slug="$2" out _FL_STATE _FL_AUTHOR _FL_HEAD _FL_LIMIT
  shift 2
  _forge_list_args "$@" || return 1
  local -a args=(pr list --repo "$slug" --state "$_FL_STATE")
  [ -z "$_FL_AUTHOR" ] || args+=(--author "$_FL_AUTHOR")
  [ -z "$_FL_HEAD" ] || args+=(--head "$_FL_HEAD")
  out="$(_forge_gh "$wsdir" "${args[@]}" --limit "$_FL_LIMIT" --json "$_FORGE_GH_PR_FIELDS")" || return 1
  printf '%s' "$out" | jq -c "$_FORGE_JQ_GH"' if type == "array" then map(gh_pr) else error("not a list") end'
}

# The PR's checks from its rollup (latest run of each, CEL_JQ_LATEST_CHECKS)
# and the base branch's required checks (_forge_github_base_required).
_forge_github_pr_checks() { # <wsdir> <slug> <number>
  _forge_number_ok pr_checks "${3:-}" || return 1
  local wsdir="$1" slug="$2" pr base gate='{"protection":"unknown","required":[]}'
  pr="$(_forge_gh "$wsdir" pr view "$3" --repo "$slug" --json headRefOid,baseRefName,statusCheckRollup)" || return 1
  base="$(printf '%s' "$pr" | jq -r '.baseRefName // ""')" || return 1
  [ -z "$base" ] || gate="$(_forge_github_base_required "$wsdir" "$slug" "$base")"
  printf '%s' "$pr" | jq -c --argjson g "$gate" "$CEL_JQ_LATEST_CHECKS$_FORGE_JQ_GH"'
    if type == "object" then . else error("not a pull request") end
    | { head_sha: (.headRefOid | _s), base_ref: (.baseRefName | _s),
        checks: [(.statusCheckRollup // []) | latest_checks[] | gh_check],
        required: $g.required, protection: $g.protection }'
}

# {protection: protected|unprotected|unknown, required: [name, ...]} for a
# base branch, from BOTH places GitHub keeps required checks: classic branch
# protection and the rulesets in effect on the branch (rules/branches/<b>,
# which covers repository and organisation rulesets). A branch gated only by
# a ruleset answers "Branch not protected" from the classic endpoint, so that
# answer alone proves nothing. `cel solo land` (lib/land.sh) asks this same
# question.
#
#   - either read fails (permission, rate limit, network, garbage): unknown
#   - a rule requiring checks it does not name as contexts - required
#     workflows (`workflows`), code scanning (`code_scanning`), deployments
#     (`required_deployments`): unknown, since no list of names can be complete
#   - classic protection readable, or a `required_status_checks` rule:
#     protected, with the union of their contexts
#   - classic "Branch not protected" and no such rule: unprotected
# Review, signature, history and merge-queue rules gate other things than
# checks and are not this answer's business. Always prints the object.
_forge_github_base_required() { # <wsdir> <slug> <base>
  local wsdir="$1" slug="$2" base="$3" prot prc=0 rules rrc=0
  local classic=unknown classic_req='[]' rinfo='' protection=unknown required='[]'
  prot="$(_forge_gh "$wsdir" api "repos/$slug/branches/$base/protection" 2>&1)" || prc=$?
  if [ "$prc" -eq 0 ] && [ -n "$prot" ]; then
    classic_req="$(printf '%s' "$prot" | jq -ce '[.required_status_checks.contexts[]?, (.required_status_checks.checks[]?.context)] | unique' 2>/dev/null)" \
      && classic=protected || classic_req='[]'
  else
    case "$prot" in *"Branch not protected"*) classic=none ;; esac
  fi
  rules="$(_forge_gh "$wsdir" api "repos/$slug/rules/branches/$base" --paginate --slurp 2>/dev/null)" || rrc=$?
  [ "$rrc" -ne 0 ] || rinfo="$(printf '%s' "$rules" | jq -ce '
    if type == "array" and all(.[]; type == "array") then add // [] else error("not rule pages") end
    | { names: [.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context | strings],
        gated: any(.[]; .type == "required_status_checks"),
        unnamed: any(.[]; .type == "workflows" or .type == "code_scanning" or .type == "required_deployments") }' 2>/dev/null)" \
    || rinfo=''
  if [ "$classic" != unknown ] && [ -n "$rinfo" ] && [ "$(printf '%s' "$rinfo" | jq -r .unnamed)" = false ]; then
    if [ "$classic" = protected ] || [ "$(printf '%s' "$rinfo" | jq -r .gated)" = true ]; then
      protection=protected
      required="$(jq -cn --argjson a "$classic_req" --argjson r "$rinfo" '$a + $r.names | unique')"
    else
      protection=unprotected
    fi
  fi
  jq -cn --arg p "$protection" --argjson req "$required" '{protection: $p, required: $req}'
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

# gh prints the new PR's url; the PR is then read like any other, so the
# answer is the one normalised object.
_forge_github_pr_create() { # <wsdir> <slug> <head> <base> <title> <body-file> <draft 0|1>
  local -a args=(pr create --repo "$2" --head "$3" --base "$4" --title "$5" --body-file "$6")
  [ "$7" = 0 ] || args+=(--draft)
  local out num
  out="$(_forge_gh "$1" "${args[@]}")" || return 1
  num="$(printf '%s\n' "$out" | grep -oE "/pull/[0-9]+" | tail -n1)"
  num="${num##*/}"
  [ -n "$num" ] || { printf 'forge pr_create: gh answered without a pull request url: %s\n' "$out" >&2; return 1; }
  _forge_github_pr_view "$1" "$2" "$num"
}

# Closing never deletes the branch (no --delete-branch); gh's own report
# goes to stderr so stdout stays the one JSON value.
_forge_github_pr_close() { # <wsdir> <slug> <number> [comment-file]
  _forge_number_ok pr_close "${3:-}" || return 1
  local -a args=(pr close "$3" --repo "$2")
  if [ -n "${4:-}" ]; then
    [ -f "$4" ] && [ -r "$4" ] || { printf "forge pr_close: comment file '%s' is not a readable file - nothing closed\n" "$4" >&2; return 1; }
    args+=(--comment "$(cat -- "$4")")
  fi
  _forge_gh "$1" "${args[@]}" >&2 || return 1
  _forge_github_pr_view "$1" "$2" "$3"
}

_forge_github_pr_ready() { # <wsdir> <slug> <number>
  _forge_number_ok pr_ready "${3:-}" || return 1
  local pr
  pr="$(_forge_github_pr_view "$1" "$2" "$3")" || return 1
  [ "$(printf '%s' "$pr" | jq -r .draft)" = true ] || { printf '%s\n' "$pr"; return 0; }
  _forge_gh "$1" pr ready "$3" --repo "$2" >&2 || return 1
  _forge_github_pr_view "$1" "$2" "$3"
}

_FORGE_GH_RUN_FIELDS=databaseId,number,status,conclusion,displayTitle,headSha,headBranch,event,workflowName,createdAt,url

_forge_github_run_list() { # <wsdir> <slug> [--branch B] [--sha SHA] [--limit N]
  local wsdir="$1" slug="$2" out _RL_BRANCH _RL_SHA _RL_LIMIT
  shift 2
  _forge_run_args "$@" || return 1
  local -a args=(run list --repo "$slug" --limit "$_RL_LIMIT")
  [ -z "$_RL_BRANCH" ] || args+=(--branch "$_RL_BRANCH")
  [ -z "$_RL_SHA" ] || args+=(--commit "$_RL_SHA")
  out="$(_forge_gh "$wsdir" "${args[@]}" --json "$_FORGE_GH_RUN_FIELDS")" || return 1
  printf '%s' "$out" | jq -c "$_FORGE_JQ_GH"' if type == "array" then map(gh_run) else error("not a list") end'
}

_forge_github_run_view() { # <wsdir> <slug> <run-id>
  _forge_id_ok run_view run "${3:-}" || return 1
  local out
  out="$(_forge_gh "$1" run view "$3" --repo "$2" --json "$_FORGE_GH_RUN_FIELDS,jobs")" || return 1
  printf '%s' "$out" | jq -c "$_FORGE_JQ_GH"' gh_run + {jobs: [(.jobs // [])[] | gh_job]}'
}

# gh shows a job's FAILED steps (--log-failed): the part worth reading.
_forge_github_run_logs() { # <wsdir> <slug> <job-id> [--raw]
  _forge_id_ok run_logs job "${3:-}" || return 1
  local out
  out="$(_forge_gh "$1" run view --repo "$2" --log-failed --job "$3")" || return 1
  [ -n "$out" ] || return 0
  if [ "${4:-}" = --raw ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | _forge_log_strip --github; fi
}

# A rerun of one job keeps the run's head, so a review of that head stands.
_forge_github_run_rerun() { # <wsdir> <slug> <job-id>
  _forge_id_ok run_rerun job "${3:-}" || return 1
  _forge_gh "$1" run rerun --repo "$2" --job "$3" >&2 || return 1
  jq -nc --argjson j "$3" '{rerun: true, job_id: $j}'
}

# GitHub's web pages carry the API ids themselves:
# .../actions/runs/<run-id>[/job/<job-id>].
_forge_github_run_resolve() { # <wsdir> <slug> <url>
  local url="${3:-}"
  [[ "$url" =~ ^https://github\.com/([^/]+/[^/]+)/actions/runs/([0-9]+)(/job/([0-9]+))?/?([?#].*)?$ ]] \
    || { printf "forge run_resolve: '%s' is not a GitHub run or job page - use the ids cel forge run list --sha <head> shows\n" "$url" >&2; return 1; }
  [ "${BASH_REMATCH[1],,}" = "${2,,}" ] \
    || { printf "forge run_resolve: '%s' is a page of %s, not %s\n" "$url" "${BASH_REMATCH[1]}" "$2" >&2; return 1; }
  jq -nc --argjson r "${BASH_REMATCH[2]}" --arg j "${BASH_REMATCH[4]}" '{run_id: $r, job_id: (if $j == "" then null else ($j | tonumber) end)}'
}

# ---- Forgejo, over its REST API ---------------------------------------------

_forge_forgejo_token_path() { # <host>
  printf '%s/cel/forge/%s.token' "${XDG_CONFIG_HOME:-$HOME/.config}" "$1"
}

# The token for <host>, onto stdout for the caller's variable: a command
# substitution forks, it execs nothing that could carry the value. Refused,
# naming the file, when it is missing, not this user's, open to the group or
# others, or not one token-shaped line.
_forge_forgejo_token() { # <host>
  local f mode t
  f="$(_forge_forgejo_token_path "$1")"
  [ -f "$f" ] || { printf 'forge: no Forgejo API token for %s - create one in Forgejo (Settings > Applications) and save it to %s with mode 600\n' "$1" "$f" >&2; return 1; }
  [ "$(stat -L -c %u -- "$f" 2>/dev/null)" = "$(id -u)" ] \
    || { printf 'forge: %s is not owned by you - refused, the token was not read\n' "$f" >&2; return 1; }
  mode="$(stat -L -c %a -- "$f" 2>/dev/null)" || mode=777
  (( (8#$mode & 8#077) == 0 )) \
    || { printf 'forge: %s is open to the group or others (mode %s) - chmod 600 it; refused, the token was not read\n' "$f" "$mode" >&2; return 1; }
  t="$(<"$f")"
  t="${t//[[:space:]]/}"
  [[ "$t" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { printf 'forge: %s does not hold one token (letters, digits, . _ -) - refused\n' "$f" >&2; return 1; }
  printf '%s' "$t"
}

# ONE REQUEST. Sets FJ_CODE (the HTTP status), FJ_BODY and FJ_REQ; returns 0
# only on 2xx. The url must be on <host>: the token is that host's and goes
# nowhere else, and curl follows no redirect that could carry it on. The
# Authorization header reaches curl as a config line on its stdin (printf is
# a builtin), so it is in no argv (ps, /proc/<pid>/cmdline), file or log.
_forge_fj() { # <host> <METHOD> <url> [json-body]
  local host="$1" method="$2" url="$3" tok out rc=0 bodyf=""
  FJ_CODE="" FJ_BODY="" FJ_REQ="$method $url"
  case "$url" in
    "http://$host/"*|"https://$host/"*) ;;
    *) printf 'forge: refusing to send the %s token to %s\n' "$host" "$url" >&2; return 1 ;;
  esac
  tok="$(_forge_forgejo_token "$host")" || return 1
  # Said only now, with the token in hand and the request about to go: an
  # operation refused before this point sent nothing over plain http.
  case "$url" in
    http://*) printf 'forge: token sent unencrypted to %s - plain http is declared for this repo\n' "$host" >&2 ;;
  esac
  local -a args=(--config - --silent --show-error --proto '=http,https' --max-time "${CEL_FORGE_TIMEOUT:-60}"
                 --request "$method" --header 'Accept: application/json' --write-out '\n%{http_code}')
  if [ $# -ge 4 ]; then
    bodyf="$(mktemp)" || return 1
    printf '%s' "$4" > "$bodyf"
    args+=(--header 'Content-Type: application/json' --data-binary "@$bodyf")
  fi
  local curl=curl
  [ -z "${CEL_TESTING:-}" ] || curl="${CEL_FORGE_CURL:-curl}"
  out="$(printf 'header = "Authorization: token %s"\n' "$tok" | "$curl" "${args[@]}" "$url")" || rc=$?
  [ -z "$bodyf" ] || rm -f -- "$bodyf"
  [ "$rc" -eq 0 ] || { printf 'forge: %s failed (curl exit %s)\n' "$FJ_REQ" "$rc" >&2; return 1; }
  FJ_CODE="${out##*$'\n'}" FJ_BODY="${out%$'\n'*}"
  [[ "$FJ_CODE" =~ ^2[0-9][0-9]$ ]]
}

# Why the last request failed, on stderr; always returns 1. A curl failure
# has said so already.
_forge_fj_fail() { # <op>
  [ -n "$FJ_CODE" ] || return 1
  local msg; msg="$(printf '%s' "$FJ_BODY" | jq -r '.message // empty' 2>/dev/null | cut -c1-300)"
  printf 'forge %s: Forgejo answered HTTP %s to %s%s\n' "$1" "$FJ_CODE" "$FJ_REQ" "${msg:+: $msg}" >&2
  return 1
}

_forge_fj_get() { # <op> <host> <url> -> the JSON answer
  _forge_fj "$2" GET "$3" || { _forge_fj_fail "$1"; return 1; }
  printf '%s' "$FJ_BODY" | jq -ce . 2>/dev/null || { printf 'forge %s: %s did not answer JSON\n' "$1" "$FJ_REQ" >&2; return 1; }
}

# Every page of a list endpoint (limit/page) until a page comes back empty -
# a short page proves nothing, the server caps `limit` at its own
# MAX_RESPONSE_ITEMS - or [max] items are in. <field> names the list inside
# an object answer (`statuses` of a combined status), `.` a bare list. A
# server that answers every page alike is refused, not read forever.
_forge_fj_pages() { # <op> <host> <url> <field> [max]
  local op="$1" host="$2" url="$3" field="$4" max="${5:-0}" page=1 all='[]' items prev="" sep='?'
  case "$url" in *\?*) sep='&' ;; esac
  while :; do
    _forge_fj "$host" GET "$url${sep}limit=50&page=$page" || { _forge_fj_fail "$op"; return 1; }
    items="$(printf '%s' "$FJ_BODY" | jq -c --arg f "$field" '
      if $f == "." then . else (.[$f] // []) end | if type == "array" then . else error("not a list") end' 2>/dev/null)" \
      || { printf 'forge %s: %s did not answer a list\n' "$op" "$FJ_REQ" >&2; return 1; }
    [ "$items" != '[]' ] || break
    [ "$items" != "$prev" ] || { printf 'forge %s: %s answers every page alike - refused rather than guess where the list ends\n' "$op" "$url" >&2; return 1; }
    prev="$items"
    # On stdin, never as an argument: one page of Actions runs (each with its
    # repository and event payload) outgrows the kernel's argument limit.
    all="$(printf '%s\n%s' "$all" "$items" | jq -sc '.[0] + .[1]')"
    [ "$max" -eq 0 ] || [ "$(jq length <<<"$all")" -lt "$max" ] || break
    page=$((page + 1))
    [ "$page" -le "${CEL_FORGE_MAX_PAGES:-100}" ] \
      || { printf 'forge %s: %s has more than %s pages - refused rather than read part of it\n' "$op" "$url" "$((page - 1))" >&2; return 1; }
  done
  printf '%s' "$all"
}

_forge_fj_host() { printf '%s' "$1" | jq -r .host; }
_forge_fj_api()  { printf '%s' "$1" | jq -r .api_url; }   # the repository's API root
_forge_fj_root() { local a; a="$(_forge_fj_api "$1")"; printf '%s' "${a%/repos/*}"; }
_forge_fj_web()  { local a; a="$(_forge_fj_root "$1")"; printf '%s' "${a%/api/v1}"; }   # scheme://host[:port]

# Forgejo's fields in Celestial's words (see the header for what differs).
_FORGE_JQ_FJ='
def _s: if . == null or . == "" then null else . end;
def fj_pr:
  if type == "object" and (.number | type) == "number" then . else error("not a pull request") end
  | { number,
      state: (if .merged == true then "merged" elif .state == "open" or .state == "closed" then .state else null end),
      head_sha: (.head.sha | _s), head_ref: (.head.ref | _s), base_ref: (.base.ref | _s),
      author: (.user.login | _s),
      draft: (.draft | if type == "boolean" then . else null end),
      mergeable: (if .state != "open" or .merged == true or .mergeable != true then "unknown"
                  elif (.merge_base | _s) != null and (.base.sha | _s) != null and .merge_base != .base.sha then "behind"
                  else "clean" end),
      merged_at: (.merged_at | _s), url: (.html_url | _s),
      labels: [(.labels // [])[]? | .name? | strings] };
def fj_latest: group_by(.context // "") | map(max_by(.id // 0));
def fj_check($web):
  ((.status // .state) | _s) as $st
  | { name: (.context | _s),
      status: (if $st == null then "queued" elif $st == "pending" then "in_progress" else "completed" end),
      conclusion: (if $st == null or $st == "pending" then null else $st end),
      url: (.target_url | _s | if type == "string" and startswith("/") then $web + . else . end) };
def fj_state:
  ((.conclusion // .status // "") | ascii_downcase) as $s
  | if $s == "success" or $s == "failure" or $s == "cancelled" or $s == "skipped" or $s == "running" then $s
    elif $s == "waiting" or $s == "blocked" or $s == "queued" or $s == "pending" then "queued"
    else "unknown" end;
def fj_run:
  if type == "object" and (.id | type) == "number" then . else error("not a run") end
  | { id, number: (.index_in_repo // null), workflow: (.workflow_id | _s), title: (.title | _s),
      event: (.event | _s), branch: ((.prettyref // .head_branch) | _s), head_sha: ((.commit_sha // .head_sha) | _s),
      state: fj_state, url: (.html_url | _s), created_at: ((.created // .created_at) | _s) };
def fj_job: { id, name: (.name | _s), state: fj_state, url: (.html_url | _s) };
def fj_review_state:
  if .dismissed == true then "dismissed"
  else ({APPROVED: "approved", REQUEST_CHANGES: "changes_requested", COMMENT: "commented",
         PENDING: "pending", REQUEST_REVIEW: "review_requested"}[.state // ""]
        // ((.state // "") | ascii_downcase | _s)) end;
def fj_decision($head):
  [.[] | select(.dismissed != true and (.state == "APPROVED" or .state == "REQUEST_CHANGES"))]
  | (group_by(.user.login // "") | map(sort_by([(.submitted_at // ""), (.id // 0)]) | last)) as $latest
  | if any($latest[]; .state == "REQUEST_CHANGES") then "changes_requested"
    elif $head != null and any($latest[]; .state == "APPROVED" and .stale != true and .commit_id == $head) then "approved"
    else "none" end;
def fj_rule_name: (.rule_name // .branch_name // "");
def fj_glob: test("[*?\\[\\]{}\\\\,!]");
def fj_glob_hard: test("[\\[\\]{}\\\\,!]");
def fj_glob_re:
  split("**") | map(split("*") | map(split("?") | map(gsub("(?<c>[.+()^$|])"; "\\\(.c)")) | join("[^/]")) | join("[^/]*"))
  | join(".*") | "^" + . + "$";
def fj_base_required($b; $one; $rules):
  if ($rules | type) != "array" then error("not a rule list") else . end
  | if any($rules[]; fj_rule_name == $b) then
      (if ($one | type) == "object" and ($one.found | fj_rule_name) == $b then {rules: [$one.found], undecidable: false} else null end)
    elif $one != "absent" then null
    else [$rules[] | select(fj_rule_name | fj_glob)] as $globs
      | { undecidable: any($globs[]; fj_rule_name | fj_glob_hard),
          rules: [$globs[] | select(fj_rule_name | fj_glob_hard | not) | select(fj_rule_name as $r | $b | test($r | fj_glob_re))] }
    end
  | if . == null or .undecidable then {protection: "unknown", required: []}
    elif (.rules | length) == 0 then {protection: "unprotected", required: []}
    elif any(.rules[]; .enable_status_check == true and ((.status_check_contexts // []) | length) == 0) then {protection: "unknown", required: []}
    else ([.rules[] | select(.enable_status_check == true) | (.status_check_contexts // [])[]] | unique) as $req
      | if any($req[]; fj_glob) then {protection: "unknown", required: []}
        else {protection: "protected", required: $req} end
    end;'

_forge_forgejo_pr_view() { # <wsdir> <desc> <number>
  _forge_number_ok pr_view "${3:-}" || return 1
  local pr
  pr="$(_forge_fj_get pr_view "$(_forge_fj_host "$2")" "$(_forge_fj_api "$2")/pulls/$3")" || return 1
  printf '%s' "$pr" | jq -c "$_FORGE_JQ_FJ"' fj_pr'
}

# `closed` includes merged, as on GitHub; `merged` is closed AND merged. The
# author is filtered by the server (`poster`) and again here, the head here.
_forge_forgejo_pr_list() { # <wsdir> <desc> <state> [--author L] [--head B] [--limit N]
  local wsdir="$1" desc="$2" q pulls me max _FL_STATE _FL_AUTHOR _FL_HEAD _FL_LIMIT
  shift 2
  _forge_list_args "$@" || return 1
  case "$_FL_STATE" in merged) q="state=closed" ;; *) q="state=$_FL_STATE" ;; esac
  if [ "$_FL_AUTHOR" = @me ]; then
    me="$(_forge_forgejo_whoami "$wsdir" "$desc")" || return 1
    _FL_AUTHOR="$(printf '%s' "$me" | jq -r .login)"
  fi
  [ -z "$_FL_AUTHOR" ] || q="$q&poster=$(jq -rn --arg a "$_FL_AUTHOR" '$a | @uri')"
  max="$_FL_LIMIT"
  [ "$_FL_STATE" != merged ] && [ -z "$_FL_HEAD" ] || max=0
  pulls="$(_forge_fj_pages pr_list "$(_forge_fj_host "$desc")" "$(_forge_fj_api "$desc")/pulls?$q" . "$max")" || return 1
  printf '%s' "$pulls" | jq -c --arg s "$_FL_STATE" --arg a "$_FL_AUTHOR" --arg h "$_FL_HEAD" --argjson n "$_FL_LIMIT" "$_FORGE_JQ_FJ"'
    [.[] | select($s != "merged" or .merged == true)
         | select($a == "" or .user.login == $a)
         | select($h == "" or .head.ref == $h)]
    | unique_by(.number) | sort_by(-.number) | .[:$n] | map(fj_pr)'
}

# The checks are the head commit's combined status - the latest status of
# each context, every page of it - and the required ones are the base's
# (_forge_forgejo_base_required).
_forge_forgejo_pr_checks() { # <wsdir> <desc> <number>
  _forge_number_ok pr_checks "${3:-}" || return 1
  local host api pr head base statuses gate='{"protection":"unknown","required":[]}'
  host="$(_forge_fj_host "$2")" api="$(_forge_fj_api "$2")"
  pr="$(_forge_fj_get pr_checks "$host" "$api/pulls/$3")" || return 1
  head="$(printf '%s' "$pr" | jq -r '.head.sha // ""')" base="$(printf '%s' "$pr" | jq -r '.base.ref // ""')"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { printf 'forge pr_checks: #%s reports no head commit\n' "$3" >&2; return 1; }
  statuses="$(_forge_fj_pages pr_checks "$host" "$api/commits/$head/status" statuses)" || return 1
  [ -z "$base" ] || gate="$(_forge_forgejo_base_required "$1" "$2" "$base")"
  jq -nc --arg h "$head" --arg b "$base" --arg web "$(_forge_fj_web "$2")" --argjson s "$statuses" --argjson g "$gate" "$_FORGE_JQ_FJ"'
    {head_sha: $h, base_ref: ($b | _s), checks: [$s | fj_latest[] | fj_check($web)],
     required: $g.required, protection: $g.protection}'
}

# {protection: protected|unprotected|unknown, required: [name, ...]} for a
# base branch - the same answer _forge_github_base_required gives, from
# Forgejo's branch protection rules. A rule names a branch exactly or is a
# glob (`*` within a path segment, `**` across, `?` one character), and an
# exact rule wins over every glob. So:
#   - the list of rules or the exact rule unreadable (permission - reading
#     protection needs repo admin -, network, garbage): unknown
#   - an exact rule: that rule; else every glob rule matching the base
#     (their union, since which one Forgejo applies is its own ordering)
#   - a matching rule with status checks on but no contexts named (Forgejo
#     then requires EVERY status green), a context that is itself a pattern,
#     or a glob this cannot read ([...], {...}): unknown - no list of names
#     can be complete
#   - matching rules: protected, with the contexts of those that check
#   - the exact rule a genuine 404 (Forgejo's own not-found answer for that
#     branch) AND no glob rule matching it: unprotected
# Always prints the object.
_forge_forgejo_base_required() { # <wsdir> <desc> <base>
  local host api enc one=error rules
  host="$(_forge_fj_host "$2")" api="$(_forge_fj_api "$2")"
  enc="$(jq -rn --arg b "$3" '$b | split("/") | map(@uri) | join("/")')"
  if _forge_fj "$host" GET "$api/branch_protections/$enc" 2>/dev/null; then
    one="$(printf '%s' "$FJ_BODY" | jq -ce 'if type == "object" then {found: .} else error("not a rule") end' 2>/dev/null)" || one=error
  elif [ "$FJ_CODE" = 404 ] && printf '%s' "$FJ_BODY" | jq -e 'type == "object" and (.message | type) == "string"' >/dev/null 2>&1; then
    one='"absent"'
  fi
  rules="$(_forge_fj_get base_required "$host" "$api/branch_protections" 2>/dev/null)" || rules=""
  if [ "$one" != error ] && [ -n "$rules" ] \
     && jq -nc --arg b "$3" --argjson one "$one" --argjson rules "$rules" "$_FORGE_JQ_FJ"' fj_base_required($b; $one; $rules)' 2>/dev/null; then
    return 0
  fi
  printf '%s' '{"protection":"unknown","required":[]}'
}

_forge_forgejo_pr_reviews() { # <wsdir> <desc> <number>
  _forge_number_ok pr_reviews "${3:-}" || return 1
  local host api pr reviews
  host="$(_forge_fj_host "$2")" api="$(_forge_fj_api "$2")"
  pr="$(_forge_fj_get pr_reviews "$host" "$api/pulls/$3")" || return 1
  reviews="$(_forge_fj_pages pr_reviews "$host" "$api/pulls/$3/reviews" .)" || return 1
  jq -nc --argjson p "$pr" --argjson r "$reviews" "$_FORGE_JQ_FJ"'
    ($p.head.sha | _s) as $h
    | {decision: ($r | fj_decision($h)),
       reviews: [$r[] | {author: (.user.login | _s), state: fj_review_state,
                         head_sha: (.commit_id | _s), submitted_at: (.submitted_at | _s)}]}'
}

# Squash exactly the expected head. Forgejo checks head_commit_id itself;
# the PR is re-read first all the same, so a moved head is refused here,
# before anything is sent, and says what it moved to.
_forge_forgejo_pr_merge() { # <wsdir> <desc> <number> <expected-head> [body]
  _forge_number_ok pr_merge "${3:-}" || return 1
  local head="${4:-}" pr state cur payload
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] \
    || { printf "forge pr_merge: the expected head must be a full 40-character lowercase commit SHA (got: '%s') - nothing merged\n" "$head" >&2; return 1; }
  pr="$(_forge_forgejo_pr_view "$1" "$2" "$3")" || { printf 'forge pr_merge: could not re-read #%s - nothing merged\n' "$3" >&2; return 1; }
  state="$(printf '%s' "$pr" | jq -r '.state // ""')" cur="$(printf '%s' "$pr" | jq -r '.head_sha // ""')"
  [ "$state" = open ] || { printf 'forge pr_merge: #%s is %s, not open - nothing merged\n' "$3" "${state:-in no known state}" >&2; return 1; }
  [ "$cur" = "$head" ] \
    || { printf 'forge pr_merge: #%s is now at %s, not the expected %s - the PR moved; nothing merged\n' "$3" "${cur:-no head}" "$head" >&2; return 1; }
  payload="$(jq -nc --arg h "$head" --arg b "${5:-}" \
    '{Do: "squash", head_commit_id: $h, delete_branch_after_merge: true} + (if $b == "" then {} else {MergeMessageField: $b} end)')"
  _forge_fj "$(_forge_fj_host "$2")" POST "$(_forge_fj_api "$2")/pulls/$3/merge" "$payload" \
    || { _forge_fj_fail pr_merge; printf 'forge pr_merge: #%s was not merged\n' "$3" >&2; return 1; }
  jq -nc --argjson n "$3" --arg h "$head" '{merged: true, number: $n, head_sha: $h}'
}

# Forgejo's draft is its `WIP:` title prefix, so the prefix is the policy's
# alone: added for a draft, and a title that already carries one (`WIP:` or
# `[WIP]`, any case) is refused for a ready PR rather than opened as a draft.
_forge_forgejo_pr_create() { # <wsdir> <desc> <head> <base> <title> <body-file> <draft 0|1>
  local title="$5" lc payload
  lc="${title,,}"
  if [ "$7" = 0 ]; then
    case "$lc" in wip:*|"[wip]"*) printf "forge pr_create: '%s' would open as a draft on Forgejo (WIP prefix), and this workspace opens PRs ready for review - nothing opened\n" "$title" >&2; return 1 ;; esac
  else
    case "$lc" in wip:*|"[wip]"*) ;; *) title="WIP: $title" ;; esac
  fi
  payload="$(jq -nc --arg h "$3" --arg b "$4" --arg t "$title" --rawfile body "$6" '{head: $h, base: $b, title: $t, body: $body}')" || return 1
  _forge_fj "$(_forge_fj_host "$2")" POST "$(_forge_fj_api "$2")/pulls" "$payload" || { _forge_fj_fail pr_create; return 1; }
  printf '%s' "$FJ_BODY" | jq -c "$_FORGE_JQ_FJ"' fj_pr' 2>/dev/null \
    || { printf 'forge pr_create: Forgejo answered %s without a pull request\n' "$FJ_CODE" >&2; return 1; }
}

# A comment goes first (POST /issues/<n>/comments: a PR is an issue), so a
# refused comment leaves the PR open; then the state alone is changed - the
# branch stays.
_forge_forgejo_pr_close() { # <wsdir> <desc> <number> [comment-file]
  _forge_number_ok pr_close "${3:-}" || return 1
  local host api payload
  host="$(_forge_fj_host "$2")" api="$(_forge_fj_api "$2")"
  if [ -n "${4:-}" ]; then
    [ -f "$4" ] && [ -r "$4" ] || { printf "forge pr_close: comment file '%s' is not a readable file - nothing closed\n" "$4" >&2; return 1; }
    payload="$(jq -nc --rawfile b "$4" '{body: $b}')" || return 1
    _forge_fj "$host" POST "$api/issues/$3/comments" "$payload" \
      || { _forge_fj_fail pr_close; printf 'forge pr_close: the comment was refused - #%s was not closed\n' "$3" >&2; return 1; }
  fi
  _forge_fj "$host" PATCH "$api/pulls/$3" '{"state":"closed"}' || { _forge_fj_fail pr_close; return 1; }
  printf '%s' "$FJ_BODY" | jq -c "$_FORGE_JQ_FJ"' fj_pr' 2>/dev/null \
    || { printf 'forge pr_close: Forgejo answered %s without a pull request\n' "$FJ_CODE" >&2; return 1; }
}

# Ready = the `WIP:` / `[WIP]` title prefix removed (the prefix IS Forgejo's
# draft). A PR that is not a draft is answered as it is; one Forgejo still
# calls a draft afterwards is a failure, not a success.
_forge_forgejo_pr_ready() { # <wsdir> <desc> <number>
  _forge_number_ok pr_ready "${3:-}" || return 1
  local host api pr title payload
  host="$(_forge_fj_host "$2")" api="$(_forge_fj_api "$2")"
  pr="$(_forge_fj_get pr_ready "$host" "$api/pulls/$3")" || return 1
  if [ "$(printf '%s' "$pr" | jq -r '.draft == true')" != true ]; then
    printf '%s' "$pr" | jq -c "$_FORGE_JQ_FJ"' fj_pr'; return
  fi
  title="$(printf '%s' "$pr" | jq -r '.title // "" | sub("^(wip:|\\[wip\\])\\s*"; ""; "i")')"
  [ -n "$title" ] && [ "$title" != "$(printf '%s' "$pr" | jq -r '.title // ""')" ] \
    || { printf "forge pr_ready: Forgejo calls #%s a draft but its title has no WIP: or [WIP] prefix to remove - nothing changed\n" "$3" >&2; return 1; }
  payload="$(jq -nc --arg t "$title" '{title: $t}')"
  _forge_fj "$host" PATCH "$api/pulls/$3" "$payload" || { _forge_fj_fail pr_ready; return 1; }
  pr="$(printf '%s' "$FJ_BODY" | jq -c "$_FORGE_JQ_FJ"' fj_pr' 2>/dev/null)" \
    || { printf 'forge pr_ready: Forgejo answered %s without a pull request\n' "$FJ_CODE" >&2; return 1; }
  [ "$(printf '%s' "$pr" | jq -r .draft)" != true ] \
    || { printf 'forge pr_ready: #%s is still a draft after its title was changed\n' "$3" >&2; return 1; }
  printf '%s\n' "$pr"
}

# Forgejo ignores a branch filter on actions/runs, so --branch is applied
# here, against the run's ref (`main`, or `#<n>` for a pull request's run),
# over every page. --sha is asked of the server (head_sha) and applied here
# again, so a server that ignored it still answers only that commit's runs.
_forge_forgejo_run_list() { # <wsdir> <desc> [--branch B] [--sha SHA] [--limit N]
  local desc="$2" runs max url _RL_BRANCH _RL_SHA _RL_LIMIT
  shift 2
  _forge_run_args "$@" || return 1
  max="$_RL_LIMIT"; [ -z "$_RL_BRANCH$_RL_SHA" ] || max=0
  url="$(_forge_fj_api "$desc")/actions/runs"
  [ -z "$_RL_SHA" ] || url="$url?head_sha=$_RL_SHA"
  runs="$(_forge_fj_pages run_list "$(_forge_fj_host "$desc")" "$url" workflow_runs "$max")" || return 1
  printf '%s' "$runs" | jq -c --arg b "$_RL_BRANCH" --arg s "$_RL_SHA" --argjson n "$_RL_LIMIT" "$_FORGE_JQ_FJ"'
    [.[] | select($b == "" or .prettyref == $b or .head_branch == $b)
         | select($s == "" or (.commit_sha // .head_sha) == $s)]
    | unique_by(.id) | sort_by(-.id) | .[:$n] | map(fj_run)'
}

_forge_forgejo_run_view() { # <wsdir> <desc> <run-id>
  _forge_id_ok run_view run "${3:-}" || return 1
  local host api run jobs
  host="$(_forge_fj_host "$2")" api="$(_forge_fj_api "$2")"
  run="$(_forge_fj_get run_view "$host" "$api/actions/runs/$3")" || return 1
  jobs="$(_forge_fj_get run_view "$host" "$api/actions/runs/$3/jobs")" || return 1
  printf '%s\n%s' "$run" "$jobs" | jq -sc "$_FORGE_JQ_FJ"'
    .[0] as $r | .[1] as $j
    | if ($j | type) != "array" then error("jobs not a list") else . end
    | ($r | fj_run) + {jobs: [$j[] | fj_job]}' 2>/dev/null \
    || { printf 'forge run_view: run %s is not a run with a list of jobs\n' "$3" >&2; return 1; }
}

# A rerun of one job keeps the run's head, so a review of that head stands.
_forge_forgejo_run_rerun() { # <wsdir> <desc> <job-id>
  _forge_id_ok run_rerun job "${3:-}" || return 1
  _forge_fj "$(_forge_fj_host "$2")" POST "$(_forge_fj_api "$2")/actions/jobs/$3/rerun" '{}' \
    || { _forge_fj_fail run_rerun; return 1; }
  jq -nc --argjson j "$3" '{rerun: true, job_id: $j}'
}

# The web UI numbers a run by its place in the repo (/actions/runs/<number>)
# and a job by its place in the run (/jobs/<index>) - neither is an API id.
# Mapped only by Forgejo's own html_url of the run and of the job, never by
# arithmetic; anything that does not match exactly is refused.
_forge_forgejo_run_resolve() { # <wsdir> <desc> <url>
  local url="${3:-}" web path num jidx runs id jobs jid
  web="$(printf '%s' "$2" | jq -r .web_url)"
  path="${web#*://*/}"                       # owner/repo
  [[ "$url" =~ ^(https?://[^/]+)?/${path}/actions/runs/([0-9]+)(/jobs/([0-9]+))?(/attempt/[0-9]+)?/?([?#].*)?$ ]] \
    || { printf "forge run_resolve: '%s' is not a run or job page of %s - use the ids cel forge run list --sha <head> shows\n" "$url" "$web" >&2; return 1; }
  num="${BASH_REMATCH[2]}" jidx="${BASH_REMATCH[4]}"
  runs="$(_forge_fj_pages run_resolve "$(_forge_fj_host "$2")" "$(_forge_fj_api "$2")/actions/runs" workflow_runs)" || return 1
  id="$(printf '%s' "$runs" | jq -r --arg u "$web/actions/runs/$num" '[.[] | select(.html_url == $u) | .id] | if length == 1 then .[0] else empty end')"
  [ -n "$id" ] || { printf 'forge run_resolve: no single run of %s has the page %s - use cel forge run list --sha <head>\n' "$web" "$web/actions/runs/$num" >&2; return 1; }
  if [ -z "$jidx" ]; then jq -nc --argjson r "$id" '{run_id: $r, job_id: null}'; return 0; fi
  jobs="$(_forge_fj_get run_resolve "$(_forge_fj_host "$2")" "$(_forge_fj_api "$2")/actions/runs/$id/jobs")" || return 1
  jid="$(printf '%s' "$jobs" | jq -r --arg u "$web/actions/runs/$num/jobs/$jidx" '
    [.[]? | select(.html_url == $u or (.html_url // "" | startswith($u + "/"))) | .id] | if length == 1 then .[0] else empty end')"
  [ -n "$jid" ] || { printf 'forge run_resolve: run %s has no single job with the page %s - use cel forge run view <repo> %s\n' "$id" "$web/actions/runs/$num/jobs/$jidx" "$id" >&2; return 1; }
  jq -nc --argjson r "$id" --argjson j "$jid" '{run_id: $r, job_id: $j}'
}

# The job's log is plain text (the run-wide /logs answer is a zip archive,
# which a shell variable cannot hold: it drops NUL bytes).
_forge_forgejo_run_logs() { # <wsdir> <desc> <job-id> [--raw]
  _forge_id_ok run_logs job "${3:-}" || return 1
  _forge_fj "$(_forge_fj_host "$2")" GET "$(_forge_fj_api "$2")/actions/jobs/$3/logs" || { _forge_fj_fail run_logs; return 1; }
  local log="${FJ_BODY%$'\n'}"
  [ -n "$log" ] || return 0
  if [ "${4:-}" = --raw ]; then printf '%s\n' "$log"; else printf '%s\n' "$log" | _forge_log_strip; fi
}

_forge_forgejo_whoami() { # <wsdir> <desc>
  local u login
  u="$(_forge_fj_get whoami "$(_forge_fj_host "$2")" "$(_forge_fj_root "$2")/user")" || return 1
  login="$(printf '%s' "$u" | jq -r '.login // ""')"
  [ -n "$login" ] || { printf 'forge whoami: Forgejo returned no login\n' >&2; return 1; }
  jq -nc --arg l "$login" '{login: $l}'
}

# ---- cel forge --------------------------------------------------------------
# The same operations from a shell, for an agent or a person, on either
# provider. Reads for everyone (CI runs and job logs included: a Forgejo's
# web UI wants a login and its token is no agent's to read); `pr create` for
# whoever opens PRs (a solo agent) - the guard refuses it to orchestrators and
# core, and a reviewer never opens one; `pr close`, `pr ready` and `run
# rerun` only for the product's own agent (solo or orchestrator) on its own
# product's repos - see _forge_cli_authorise. The owner changes a forge in its
# web UI (Forgejo or GitHub) or with gh, never through cel forge.
# There is no merge verb: merges go through `cel solo land`, which checks
# what a merge must prove.
#
#   cel forge repo   <repo>                         the descriptor (JSON)
#   cel forge whoami <repo> [--json]
#   cel forge pr view|checks|reviews <repo>#<n> [--json]
#   cel forge pr list <repo> [open|closed|merged|all] [--author L|@me] [--head B] [--limit N] [--json]
#   cel forge pr create <repo> --head <branch> --base <branch> --title <t> --body-file <f> [--json]
#   cel forge pr close <repo>#<n> [--comment-file <f>] [--json]
#   cel forge pr ready <repo>#<n> [--json]
#   cel forge run list <repo> [--branch B] [--sha <head>] [--limit N] [--json]
#   cel forge run view <repo> <run-id|run page url> [--json]      the run and its jobs
#   cel forge run logs <repo> <job-id|job page url> [--tail N] [--raw]
#   cel forge run rerun <repo> <job-id|job page url> [--json]
#
# Every verb takes --workspace <name>; without it, the workspace you stand
# in, else the pane's own (CEL_WORKSPACE, then CEL_INBOX_WS).
_forge_cli_ws() { # <workspace-name-or-empty> -> wsdir
  [ -n "$(type -t registry_require)" ] || . "${BASH_SOURCE[0]%/*}/registry.sh"
  if [ -n "$1" ]; then registry_require "$1"; return; fi
  ws_current && return 0
  if [ -n "${CEL_WORKSPACE:-}" ] && [ -f "$CEL_WORKSPACE/workspace.yaml" ]; then printf '%s' "$CEL_WORKSPACE"; return 0; fi
  if [ -n "${CEL_INBOX_WS:-}" ]; then registry_require "$CEL_INBOX_WS"; return; fi
  die "cel forge: not inside a workspace (cd into one, or pass --workspace <name>)"
}

_forge_cli_repo() { # <wsdir> <repo>
  [ -n "$2" ] || die "cel forge: which repo?"
  ws_repo_names "$1" | grep -qxF -- "$2" || die "cel forge: '$2' is not a repo of workspace '$(ws_name "$1")'"
}

# The product this agent is: its launch's CEL_PRODUCT and/or its mailbox
# (<product>-orch). Fails when the two name different products; prints
# nothing when neither names one.
_forge_cli_agent_product() {
  local p="${CEL_PRODUCT:-}" m=""
  case "${CEL_INBOX_ME:-}" in *-orch) m="${CEL_INBOX_ME%-orch}" ;; esac
  [ -z "$p" ] || [ -z "$m" ] || [ "$p" = "$m" ] || return 1
  printf '%s' "${p:-$m}"
}

# May this process change <repo> (close or ready a PR, rerun a job)? ONLY A
# POSITIVELY IDENTIFIED PRODUCT AGENT: CEL_ROLE solo or orchestrator, and a
# product (CEL_PRODUCT or its <product>-orch mailbox, agreeing when both are
# set) that owns <repo>; for a PR, only one its workspace's account authored
# or a migrated Forgejo PR (author Ghost, the placeholder for an imported
# PR's author). The identity must also be the one the agent's launch fixed
# (cel_launch_identity). Anything missing or contradictory is refused. There is no
# owner path: the absence of an agent's marks proves nothing (an agent can
# shed them - env -u, setsid, a fresh environment), so a process with no
# identity is refused and the owner uses the forge's web UI or gh. Every
# agent acts as the one workspace account, so authorship cannot tell one
# agent's PR from another's on the same product: that is the limit.
_forge_cli_authorise() { # <wsdir> <repo> <verb> [pr-number]
  local role="${CEL_ROLE:-}" product pr author me provider
  case "$role" in
    solo|orchestrator) ;;
    "") die "cel forge $3: only the product's own agent (CEL_ROLE solo or orchestrator) changes a forge, and this process carries no agent role - a missing role proves nothing, so it is refused. At your own shell, use the forge's web UI (Forgejo or GitHub) or gh directly; nothing changed" ;;
    *) die "cel forge $3: a ${role} does not do this - the product's own agent does (the owner uses the forge's web UI or gh); nothing changed" ;;
  esac
  # ...and that identity is the one its launch fixed (lib/identity.sh), so an
  # exported CEL_PRODUCT cannot steer a write to another product.
  cel_launch_identity "cel forge $3"
  product="$(_forge_cli_agent_product)" \
    || die "cel forge $3: this agent's CEL_PRODUCT ($CEL_PRODUCT) and mailbox ($CEL_INBOX_ME) name different products - nothing changed"
  [ -n "$product" ] || die "cel forge $3: cannot tell which product this agent is (no CEL_PRODUCT, no <product>-orch mailbox) - nothing changed"
  [ "$(ws_product_of_repo "$1" "$2")" = "$product" ] \
    || die "cel forge $3: $2 is not a repo of product $product - an agent changes only its own product's PRs and runs; nothing changed"
  [ -n "${4:-}" ] || return 0
  pr="$(forge_pr_view "$1" "$2" "$4")" || die "cel forge $3: could not read $2#$4 - nothing changed"
  author="$(printf '%s' "$pr" | jq -r '.author // ""')"
  me="$(forge_whoami "$1" "$2")" || die "cel forge $3: could not tell this workspace's account on $2's forge - nothing changed"
  me="$(printf '%s' "$me" | jq -r '.login // ""')"
  [ -n "$me" ] && [ "$author" = "$me" ] && return 0
  provider="$(forge_repo "$1" "$2" "$1/repos/$2" | jq -r .provider)"
  [ "$provider" = forgejo ] && [ "$author" = Ghost ] && return 0
  die "cel forge $3: $2#$4 is ${author:-an unknown author}'s pull request, not this workspace's account (${me:-unknown}) - an agent changes only its own PRs or a migrated one (author Ghost); nothing changed"
}

# A run or job named by its web page rather than its API id: mapped by
# forge_run_resolve (exactly, or refused). <want> is run or job. It runs in a
# command substitution, so its refusal goes to stderr, not into the id.
_forge_cli_run_id() { # <wsdir> <repo> <id-or-url> <want> <verb>
  local r id
  if [[ "$3" =~ ^[1-9][0-9]*$ ]]; then printf '%s' "$3"; return 0; fi
  case "$3" in
    http://*|https://*|/*) ;;
    *) die "cel forge run $5: '$3' is neither a $4 id nor a web page - cel forge run list $2 --sha <head> shows the ids" >&2 ;;
  esac
  r="$(forge_run_resolve "$1" "$2" "$3")" || die "cel forge run $5: cannot map '$3' to an API id - cel forge run list $2 --sha <head> shows the run and job ids" >&2
  id="$(printf '%s' "$r" | jq -r --arg w "$4" 'if $w == "run" then .run_id else .job_id end // empty')"
  [ -n "$id" ] || die "cel forge run $5: '$3' is a run's page, not a job's - cel forge run view $2 $(printf '%s' "$r" | jq -r .run_id) lists its jobs" >&2
  printf '%s' "$id"
}

cmd_forge() {
  local usage='usage: cel forge repo|whoami <repo> | cel forge pr view|checks|reviews|ready <repo>#<n> | cel forge pr close <repo>#<n> [--comment-file f] | cel forge pr list <repo> [open|closed|merged|all] [--author L|@me] [--head B] [--limit N] | cel forge pr create <repo> --head <branch> --base <branch> --title <title> --body-file <file> | cel forge run list <repo> [--branch B] [--sha <head>] [--limit N] | cel forge run view <repo> <run-id|url> | cel forge run logs <repo> <job-id|url> [--tail N] [--raw] | cel forge run rerun <repo> <job-id|url>   (each: [--json] [--workspace NAME])'
  local verb="${1:-}" sub=""
  [ $# -eq 0 ] || shift
  if [ "$verb" = pr ] || [ "$verb" = run ]; then sub="${1:-}"; [ $# -eq 0 ] || shift; fi
  case "$verb${sub:+ $sub}" in
    repo|whoami|"pr view"|"pr checks"|"pr reviews"|"pr list"|"pr create"|"pr close"|"pr ready"|"run list"|"run view"|"run logs"|"run rerun") ;;
    help|-h|--help|"") printf '%s\n' "$usage"; return 0 ;;
    *) die "cel forge: unknown command '$verb${sub:+ $sub}' - $usage" ;;
  esac
  local workspace="" json=0 raw=0 head="" base="" title="" bodyf="" author="" limit="" commentf="" branch="" tail="" sha=""
  local -a pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --raw) raw=1; shift ;;
      --workspace|--head|--base|--title|--body-file|--author|--limit|--comment-file|--branch|--tail|--sha)
        [ $# -ge 2 ] || die "cel forge: $1 needs a value"
        case "$1" in
          --workspace) workspace="$2" ;; --head) head="$2" ;; --base) base="$2" ;; --title) title="$2" ;;
          --body-file) bodyf="$2" ;; --author) author="$2" ;; --limit) limit="$2" ;;
          --comment-file) commentf="$2" ;; --branch) branch="$2" ;; --tail) tail="$2" ;; --sha) sha="$2" ;;
        esac
        shift 2 ;;
      -*) die "cel forge: unknown option: $1" ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  local wsdir repo num out
  wsdir="$(_forge_cli_ws "$workspace")" || exit 1
  case "$verb${sub:+ $sub}" in
    repo|whoami|"pr list"|"pr create"|"run list")
      repo="${pos[0]:-}"; _forge_cli_repo "$wsdir" "$repo" ;;
    "run view"|"run logs"|"run rerun")
      [ "${#pos[@]}" -eq 2 ] || die "cel forge run $sub: name the repo and the $(if [ "$sub" = view ]; then printf run; else printf job; fi) id: cel forge run $sub <repo> <id> (cel forge run list <repo> --sha <head> shows them)"
      repo="${pos[0]}"
      _forge_cli_repo "$wsdir" "$repo"
      if [ "$sub" = view ]; then num="$(_forge_cli_run_id "$wsdir" "$repo" "${pos[1]}" run "$sub")" || exit 1
      else num="$(_forge_cli_run_id "$wsdir" "$repo" "${pos[1]}" job "$sub")" || exit 1; fi ;;
    *)
      [ "${#pos[@]}" -eq 1 ] && [[ "${pos[0]}" == *#* ]] || die "cel forge pr $sub: name the PR as <repo>#<n>"
      repo="${pos[0]%%#*}" num="${pos[0]#*#}"
      _forge_cli_repo "$wsdir" "$repo" ;;
  esac
  case "$verb${sub:+ $sub}" in
    repo)
      forge_repo "$wsdir" "$repo" "$wsdir/repos/$repo" || exit 1 ;;
    whoami)
      out="$(forge_whoami "$wsdir" "$repo")" || exit 1
      if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r .login; fi ;;
    "pr view")
      out="$(forge_pr_view "$wsdir" "$repo" "$num")" || exit 1
      if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r '
        "#\(.number) \(.state)\(if .draft then " (draft)" else "" end) by \(.author // "?")",
        "  head \(.head_sha // "?") (\(.head_ref // "?")) -> \(.base_ref // "?")",
        "  mergeable \(.mergeable)", "  \(.url // "")"'; fi ;;
    "pr checks")
      out="$(forge_pr_checks "$wsdir" "$repo" "$num")" || exit 1
      if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r '
        "head \(.head_sha) -> \(.base_ref // "?"): base \(.protection), required: \(if (.required | length) == 0 then "none" else (.required | join(", ")) end)",
        (.checks[] | "  \(.status)\(if .conclusion then "/" + .conclusion else "" end)  \(.name // "?")")'; fi ;;
    "pr reviews")
      out="$(forge_pr_reviews "$wsdir" "$repo" "$num")" || exit 1
      if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r '
        "decision: \(.decision)",
        (.reviews[] | "  \(.state // "?")  \(.author // "?")  at \((.head_sha // "?")[0:12])  \(.submitted_at // "")")'; fi ;;
    "pr list")
      local -a la=("${pos[1]:-open}")
      [ -z "$author" ] || la+=(--author "$author")
      [ -z "$head" ] || la+=(--head "$head")
      [ -z "$limit" ] || la+=(--limit "$limit")
      out="$(forge_pr_list "$wsdir" "$repo" "${la[@]}")" || exit 1
      if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r '
        .[] | "#\(.number)  \(.state)\(if .draft then " (draft)" else "" end)  \(.head_ref // "?") -> \(.base_ref // "?")  \(.author // "?")  \(.url // "")"'; fi ;;
    "pr create")
      case "${CEL_ROLE:-}" in reviewer|scout) die "cel forge pr create: a ${CEL_ROLE} does not open pull requests" ;; esac
      [ -n "$head" ] && [ -n "$base" ] && [ -n "$title" ] && [ -n "$bodyf" ] \
        || die "cel forge pr create: --head, --base, --title and --body-file are all required - $usage"
      out="$(forge_pr_create "$wsdir" "$repo" "$head" "$base" "$title" "$bodyf")" || exit 1
      if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r '.url // "#\(.number)"'; fi ;;
    "pr close")
      [ -z "$commentf" ] || { [ -f "$commentf" ] && [ -r "$commentf" ]; } \
        || die "cel forge pr close: --comment-file '$commentf' is not a readable file - nothing closed"
      _forge_cli_authorise "$wsdir" "$repo" "pr close" "$num"
      out="$(forge_pr_close "$wsdir" "$repo" "$num" ${commentf:+"$commentf"})" || exit 1
      if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r '"#\(.number) \(.state)  \(.url // "")"'; fi ;;
    "pr ready")
      _forge_cli_authorise "$wsdir" "$repo" "pr ready" "$num"
      out="$(forge_pr_ready "$wsdir" "$repo" "$num")" || exit 1
      if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r '"#\(.number) \(.state)\(if .draft then " (draft)" else ", ready for review" end)  \(.url // "")"'; fi ;;
    "run list")
      local -a ra=()
      [ -z "$branch" ] || ra+=(--branch "$branch")
      [ -z "$sha" ] || ra+=(--sha "$sha")
      [ -z "$limit" ] || ra+=(--limit "$limit")
      out="$(forge_run_list "$wsdir" "$repo" "${ra[@]}")" || exit 1
      if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r '
        .[] | ("run \(.id)  \(.state)  \(.workflow // "?")  \(.branch // "?")  \((.head_sha // "?")[0:12])  \(.title // "")\(if .number then "  (web #\(.number))" else "" end)"),
              ((.jobs // [])[] | "  job \(.id)  \(.state)  \(.name // "?")")'
        printf '%s\n' "$out" | jq -e 'length > 0' >/dev/null \
          && printf '(ids are the API ids that run view, logs and rerun take; "web #" is the web page number%s)\n' \
               "$(if [ -z "$sha" ]; then printf ', and --sha <head> lists each run'"'"'s job ids'; fi)"
      fi ;;
    "run view")
      out="$(forge_run_view "$wsdir" "$repo" "$num")" || exit 1
      if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r '
        "run \(.id) \(.state)  \(.workflow // "?") on \(.branch // "?") at \((.head_sha // "?")[0:12])  \(.title // "")\(if .number then "  (web #\(.number))" else "" end)",
        "  \(.url // "")",
        (.jobs[] | "  job \(.id)  \(.state)  \(.name // "?")")'; fi ;;
    "run rerun")
      _forge_cli_authorise "$wsdir" "$repo" "run rerun"
      out="$(forge_run_rerun "$wsdir" "$repo" "$num")" || exit 1
      if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf 'job %s queued again (same head; an approval of it stands)\n' "$num"; fi ;;
    "run logs")
      [ -z "$tail" ] || [[ "$tail" =~ ^[1-9][0-9]*$ ]] || die "cel forge run logs: --tail needs a positive number of lines (got: '$tail')"
      local -a lo=()
      [ "$raw" = 0 ] || lo+=(--raw)
      out="$(forge_run_logs "$wsdir" "$repo" "$num" "${lo[@]}")" || exit 1
      [ -n "$out" ] || { printf 'cel forge run logs: job %s has no log to show (on GitHub only failed steps are shown)\n' "$num" >&2; return 0; }
      if [ -n "$tail" ]; then printf '%s\n' "$out" | tail -n "$tail"; else printf '%s\n' "$out"; fi ;;
  esac
}
