# shellcheck shell=bash
# cel solo - the review record and the merge door for a SOLO product's PRs.
#
# A fleet PR belongs to a delegation: its review verdict lives on the ledger
# row and `cel-fanout land <id>` merges it. A solo product has no delegations
# - one agent opens its PRs directly - so neither has anywhere to stand. These
# are the same two acts with the PR itself as the key:
#
#   cel solo review <repo>#<n> approved|changes --head <sha> --by <alias>
#   cel solo land   <repo>#<n>
#
# `land` proves what `cel-fanout land` proves (policy, ownership, an approval
# for the exact head, no red check, no conflict, every protected check green
# on that head) using the same checks (lib/land.sh), and merges only that
# head. There is no local gate run here: a solo agent runs the repo gate
# before it pushes, and CI on the exact head is the evidence the merge cites.
[ -n "${_CEL_SOLO:-}" ] && return 0
_CEL_SOLO=1
# shellcheck source=lib/mode.sh
. "${BASH_SOURCE[0]%/*}/mode.sh"   # _mode_product, ws_build_mode, cmd_run plumbing
# shellcheck source=lib/land.sh
. "${BASH_SOURCE[0]%/*}/land.sh"
# shellcheck source=lib/afk.sh
. "${BASH_SOURCE[0]%/*}/afk.sh"
# shellcheck source=lib/guard.sh
. "${BASH_SOURCE[0]%/*}/guard.sh"  # guard_role_of: who is asking to land

# One verdict per PR, keyed `<repo>#<n>`, beside the workspace's other state.
_solo_reviews() { printf '%s' "$1/.cel/solo-reviews.json"; }

# Every read-modify-write of the verdict file holds its lock, so two reviewers
# recording at once cannot drop each other's verdict. A file that does not
# parse as an object is NOT silently replaced - that would erase every other
# PR's verdict - it is moved aside to `.corrupt-<time>` and the refusal says so.
_solo_reviews_update() { # <wsdir> <jq args...> <program>
  local wsdir="$1"; shift
  local f; f="$(_solo_reviews "$wsdir")"
  mkdir -p "$(dirname "$f")" || return 1
  (
    flock -w 30 9 || { c_err "cel solo: $f is locked by another review - try again"; exit 1; }
    local cur='{}' tmp
    if [ -s "$f" ]; then
      cur="$(jq -ce 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null)" || {
        local aside; aside="$f.corrupt-$(date -u +%Y%m%dT%H%M%SZ)"
        mv -f -- "$f" "$aside"
        c_err "cel solo: $f did not parse - moved aside to $aside; nothing recorded, record the verdict again"
        exit 1
      }
    fi
    tmp="$(mktemp "$f.tmp.XXXXXX")" || exit 1
    printf '%s' "$cur" | jq "$@" > "$tmp" && [ -s "$tmp" ] && mv -f -- "$tmp" "$f" \
      || { rm -f -- "$tmp"; exit 1; }
  ) 9>"$f.lock"
}

solo_review_get() { # <wsdir> <repo> <pr> -> the verdict object, or nothing
  jq -c --arg k "$2#$3" '.[$k] // empty' "$(_solo_reviews "$1")" 2>/dev/null || true
}

# A solo product's PRs that `cel solo land` would merge right now - by the
# same rules, never looser, or the steward would nag about a PR land refuses:
# merge: self, the workspace account ready, the PR opened by that account,
# open, not a draft, not conflicting, every check concluded and none red,
# approved at its exact current head (GitHub's review or the recorded
# verdict), and land_ci_gate passing (every protected check green on that
# head). One `<repo><TAB><pr><TAB><head>` line each. The steward nudges the
# product's agent with these; it never lands them itself. A gh failure
# yields nothing - silence, never a guess.
solo_ready_prs() { # <wsdir> <product>
  local wsdir="$1" product="$2" repo slug rows pr
  [ "$(ws_policy "$wsdir" merge)" = self ] || return 0
  ws_github_ready "$wsdir" "${GH:-gh}" || return 0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    slug="$(ws_repo_github_slug "$wsdir" "$repo")" || continue
    rows="$(_land_gh "$wsdir" pr list --repo "$slug" --author @me --state open --limit 50 \
      --json number,headRefOid,baseRefName,isDraft,mergeable,reviewDecision,statusCheckRollup 2>/dev/null)" || continue
    while IFS= read -r pr; do
      [ -n "$pr" ] || continue
      land_ci_gate "$wsdir" "$slug" "$pr" >/dev/null || continue
      printf '%s\t%s\t%s\n' "$repo" "$(printf '%s' "$pr" | jq -r .number)" "$(printf '%s' "$pr" | jq -r .headRefOid)"
    done < <(printf '%s' "$rows" | jq -c --arg repo "$repo" --slurpfile v <(jq -c . "$(_solo_reviews "$wsdir")" 2>/dev/null || printf '{}') "$CEL_JQ_LATEST_CHECKS"'
      ($v[0] // {}) as $verdicts
      | .[]? | select(.isDraft == false and .mergeable != "CONFLICTING")
      | select((.headRefOid // "") | test("^[0-9a-f]{40}$"))
      | select((.statusCheckRollup // []) | length > 0)
      | select(all(.statusCheckRollup | latest_checks[]; ((.conclusion // .state) as $s | $s == "SUCCESS" or $s == "SKIPPED" or $s == "NEUTRAL")))
      | .headRefOid as $head
      | select(.reviewDecision == "APPROVED"
               or (($verdicts["\($repo)#\(.number)"] // {}) | .verdict == "approved" and .head == $head))' 2>/dev/null || true)
  done < <(ws_product_repos "$wsdir" "$product")
}

# `<repo>#<n>` or a bare `<n>` when the product has exactly one repo. Sets
# SOLO_WSDIR, SOLO_PRODUCT, SOLO_REPO, SOLO_PR; refuses a repo that is not in
# a solo product, because a fleet PR has a delegation and its own door.
_solo_resolve() { # <ref> <workspace-or-empty>
  local ref="$1" workspace="$2" repo="" pr=""
  if [ -n "$workspace" ]; then
    SOLO_WSDIR="$(registry_require "$workspace")"
  elif ! SOLO_WSDIR="$(ws_current)"; then
    [ -n "${CEL_INBOX_WS:-}" ] || die "cel solo: not inside a workspace (cd into one, or pass --workspace <name>)"
    SOLO_WSDIR="$(registry_require "$CEL_INBOX_WS")"
  fi
  case "$ref" in
    *#*) repo="${ref%%#*}"; pr="${ref#*#}" ;;
    *)   pr="$ref" ;;
  esac
  [[ "$pr" =~ ^[0-9]+$ ]] || die "cel solo: '$ref' is not <repo>#<pr-number>"
  if [ -z "$repo" ]; then
    local product; product="$(_mode_product "$SOLO_WSDIR")"
    [ -n "$product" ] || die "cel solo: which repo? write it as <repo>#$pr"
    local -a rs; mapfile -t rs < <(ws_product_repos "$SOLO_WSDIR" "$product")
    [ "${#rs[@]}" -eq 1 ] || die "cel solo: product '$product' has ${#rs[@]} repos - write it as <repo>#$pr"
    repo="${rs[0]}"
  fi
  ws_repo_names "$SOLO_WSDIR" | grep -qxF "$repo" \
    || die "cel solo: '$repo' is not a repo of workspace '$(ws_name "$SOLO_WSDIR")'"
  SOLO_PRODUCT="$(ws_product_of_repo "$SOLO_WSDIR" "$repo")"
  [ "$(ws_build_mode "$SOLO_WSDIR" "$SOLO_PRODUCT")" = solo ] \
    || die "cel solo: '$repo' belongs to '$SOLO_PRODUCT', which is not in solo mode - its PRs are delegations: cel-fanout review / cel-fanout land"
  SOLO_REPO="$repo"; SOLO_PR="$pr"
}

_solo_pr_json() { # <wsdir> <slug> <pr>
  _land_gh "$1" pr view "$3" --repo "$2" \
    --json number,author,reviewDecision,statusCheckRollup,isDraft,mergeable,state,headRefOid,baseRefName 2>/dev/null
}

cmd_solo_review() { # <ref> <approved|changes> --head <sha> --by <alias> [--note T] [--workspace W]
  local usage="usage: cel solo review <repo>#<pr> <approved|changes> --head <full-40-char-sha> --by <reviewer-alias> [--note TEXT] [--workspace NAME]"
  [ $# -ge 2 ] || die "$usage"
  # THE AUTHOR DOES NOT APPROVE ITS OWN WORK. A solo agent wrote the PR; a
  # verdict it recorded itself would make the review a formality and let it
  # land unreviewed code. Its reviewer pane records the verdict.
  [ "${CEL_ROLE:-}" != solo ] \
    || die "cel solo review: a solo agent does not review its own PR - its reviewer (cel run reviewer --repo <repo> --pr <n>) records the verdict"
  local ref="$1" verdict="$2"; shift 2
  local by="" note="" workspace="" head="" head_given=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --by)        [ $# -ge 2 ] || die "$usage"; by="$2"; shift 2 ;;
      --note)      [ $# -ge 2 ] || die "$usage"; note="$2"; shift 2 ;;
      --head)      [ $# -ge 2 ] || die "$usage"; head="$2"; head_given=1; shift 2 ;;
      --workspace) [ $# -ge 2 ] || die "$usage"; workspace="$2"; shift 2 ;;
      *) die "cel solo review: unknown argument: $1" ;;
    esac
  done
  # The same rules as a fleet verdict (cel-fanout review): attributed, and
  # bound to the exact commit the reviewer read - never inferred.
  case "$verdict" in approved|changes) ;; *) die "cel solo review: verdict must be approved or changes (got: $verdict)";; esac
  [ -n "$by" ] || die "cel solo review: --by <reviewer-alias> is required - an unattributed verdict is not a review"
  [ "$head_given" -eq 1 ] || die "cel solo review: --head <full-40-char-commit-sha> is required - the verdict covers the commit you reviewed"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "cel solo review: --head must be a full 40-character lowercase commit SHA (got: '$head')"
  _solo_resolve "$ref" "$workspace"
  cel_assert_reviewer_identity "$by" "$SOLO_WSDIR" "$SOLO_REPO" "$SOLO_PR" \
    || die "cel solo review: caller does not match the reviewer identity - nothing recorded"

  if [ "$verdict" = approved ]; then
    # AN APPROVAL IS ONLY EVER FOR THE PR'S CURRENT REMOTE HEAD, on a PR this
    # workspace's account opened. The API validates; it never supplies the SHA.
    local slug pr me author state rhead
    slug="$(ws_repo_github_slug "$SOLO_WSDIR" "$SOLO_REPO")" || die "cel solo review: cannot resolve the GitHub repo for '$SOLO_REPO' - nothing recorded"
    ws_github_ready "$SOLO_WSDIR" "${GH:-gh}" \
      || die "cel solo review: $(ws_github_fix "$(ws_github_user "$SOLO_WSDIR")") - an approval is not recorded unverified"
    pr="$(_solo_pr_json "$SOLO_WSDIR" "$slug" "$SOLO_PR")" || die "cel solo review: no PR #$SOLO_PR on $slug - nothing recorded"
    me="$(_land_gh "$SOLO_WSDIR" api user --jq .login 2>/dev/null || true)"
    author="$(printf '%s' "$pr" | jq -r '.author.login // ""')"
    state="$(printf '%s' "$pr" | jq -r '.state // ""')"
    rhead="$(printf '%s' "$pr" | jq -r '.headRefOid // ""')"
    [ -n "$me" ] && [ "$author" = "$me" ] \
      || die "cel solo review: #$SOLO_PR was opened by '${author:-?}', not this workspace's account ('${me:-?}') - nothing recorded"
    [ "$state" = OPEN ] || die "cel solo review: #$SOLO_PR is $state, not OPEN - nothing recorded"
    [ "$rhead" = "$head" ] \
      || die "cel solo review: --head $head is not #$SOLO_PR's current head (${rhead:-unknown}) - re-review the current head. Nothing recorded"
  fi

  _solo_reviews_update "$SOLO_WSDIR" --arg k "$SOLO_REPO#$SOLO_PR" --arg v "$verdict" --arg by "$by" \
    --arg note "$note" --arg head "$head" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.[$k] = {verdict:$v, by:$by, note:$note, head:$head, at:$at}' \
    || die "cel solo review: could not write $(_solo_reviews "$SOLO_WSDIR")"
  c_ok "$SOLO_REPO#$SOLO_PR reviewed: $verdict by $by (head ${head:0:12})"
}

# THE REPO'S OWN GATE, AT EXACTLY THE HEAD BEING MERGED. Used only when the
# base branch gates nothing, so CI cannot stand in. It runs in a checkout of
# this repo whose HEAD is that commit with no tracked change and nothing staged
# - the solo agent's own worktree for the branch (its dependencies installed,
# as a worker's are for the fleet land). No such checkout is a refusal, never
# a guess. Prints the merge-body line on success, the reason on failure.
_solo_local_gate() { # <wsdir> <repo> <head> <gate>
  local wsdir="$1" repo="$2" head="$3" gate="$4" repodir wt="" w h rc=0 t0 secs
  repodir="$wsdir/repos/$repo"
  # WHICH checkout: the one the caller stands in when it qualifies (the solo
  # agent's prepared worktree, dependencies installed), else the first other
  # qualifying one - never a reviewer's read-only checkout, which has no
  # dependencies and belongs to the review.
  local here; here="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  local -a cands=()
  while read -r w h; do
    [ "$h" = "$head" ] || continue
    case "$w" in */cel/reviews/*) continue ;; esac
    # nothing modified, staged or untracked (ignored build output is fine):
    # anything else could change the gate's outcome at "exactly this head"
    [ -z "$(git -C "$w" status --porcelain 2>/dev/null)" ] || continue
    if [ -n "$here" ] && [ "$(readlink -f "$w")" = "$(readlink -f "$here")" ]; then cands=("$w" "${cands[@]}"); else cands+=("$w"); fi
  done < <(git -C "$repodir" worktree list --porcelain 2>/dev/null | awk '/^worktree /{w=$2} /^HEAD /{print w, $2}')
  wt="${cands[0]:-}"
  [ -n "$wt" ] || { printf '%s' "no clean checkout of $repo is at $head - the base branch gates nothing, so the repo gate (\`$gate\`) must run at exactly that head: check it out (your branch worktree, nothing modified or untracked) and land again"; return 1; }
  [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$head" ] || { printf '%s' "$wt moved off $head"; return 1; }
  c_warn "cel solo land: the base branch gates nothing - running the repo gate \`$gate\` in $wt at ${head:0:12}" >&2
  t0="$(date +%s)"
  ( cd "$wt" && timeout "${CEL_SOLO_GATE_TIMEOUT:-5400}" bash -c "$gate" ) >&2 || rc=$?
  secs=$(( $(date +%s) - t0 ))
  [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$head" ] || { printf '%s' "the checkout moved off $head while the gate ran - nothing proven"; return 1; }
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] \
    || { printf '%s' "the gate changed files in $wt (git status is not clean afterwards) - what passed is not $head; make the gate leave the tree as it found it"; return 1; }
  [ "$rc" -eq 0 ] || { printf '%s' "the repo gate (\`$gate\`) did not pass at $head (exit $rc after ${secs}s) - a red gate is a finding, not a formality"; return 1; }
  printf 'Gate: local `%s` passed on %s (%ss; base branch has no required checks)' "$gate" "$head" "$secs"
}

cmd_solo_land() { # <ref> [--workspace W]
  [ $# -ge 1 ] || die "usage: cel solo land <repo>#<pr> [--workspace NAME]"
  # Landing is the solo agent's (or a person's) act, never a worker's or a
  # reviewer's: the reviewer judges, it does not merge what it judged.
  case "${CEL_ROLE:-}" in
    worker|reviewer|scout|spike) die "cel solo land: a ${CEL_ROLE} does not merge - the product's agent lands an approved PR" ;;
  esac
  [ "$(guard_role_of "$PWD")" != worker ] \
    || die "cel solo land: refused from a worker worktree - the product's agent lands an approved PR"
  local ref="$1" workspace=""; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) [ $# -ge 2 ] || die "cel solo land: --workspace needs a value"; workspace="$2"; shift 2 ;;
      *) die "cel solo land: unknown argument: $1" ;;
    esac
  done
  _solo_resolve "$ref" "$workspace"
  local wsdir="$SOLO_WSDIR" num="$SOLO_PR" slug
  slug="$(ws_repo_github_slug "$wsdir" "$SOLO_REPO")" || die "cel solo land: cannot resolve the GitHub repo for '$SOLO_REPO'"

  ws_github_ready "$wsdir" "${GH:-gh}" \
    || die "cel solo land: refusing to act for workspace '$(ws_name "$wsdir")': $(ws_github_fix "$(ws_github_user "$wsdir")")"
  [ "$(ws_policy "$wsdir" merge)" = self ] \
    || die "cel solo land: this workspace's policy.merge is humans-only - tell the owner #$num is ready; do not merge it"

  local pr; pr="$(_solo_pr_json "$wsdir" "$slug" "$num")" || die "cel solo land: no PR #$num on $slug"
  local me author head
  me="$(_land_gh "$wsdir" api user --jq .login 2>/dev/null || true)"
  author="$(printf '%s' "$pr" | jq -r '.author.login // ""')"
  head="$(printf '%s' "$pr" | jq -r '.headRefOid // ""')"
  [ -n "$me" ] && [ "$author" = "$me" ] \
    || die "cel solo land: #$num was opened by '$author', not this workspace's account ('$me') - someone else's PR is theirs to land"
  [ "$(printf '%s' "$pr" | jq -r .state)" = OPEN ] || die "cel solo land: #$num is not open"
  [ "$(printf '%s' "$pr" | jq -r .isDraft)" = false ] || die "cel solo land: #$num is still a draft"
  [ -n "$head" ] || die "cel solo land: #$num reports no head commit - cannot pin the merge to a reviewed head. Nothing merged."

  # WHO SAYS THIS IS APPROVED: GitHub where it can; where the author would
  # have to approve their own PR, the recorded verdict - for this exact head.
  local rd rv review_by="" review_note="" approved_via=""
  rd="$(printf '%s' "$pr" | jq -r '.reviewDecision // ""')"
  rv="$(solo_review_get "$wsdir" "$SOLO_REPO" "$num")"
  if [ "$rd" = APPROVED ]; then
    approved_via="GitHub approval"
  elif [ "$(printf '%s' "$rv" | jq -r '.verdict // ""')" = approved ]; then
    [ "$(printf '%s' "$rv" | jq -r '.head // ""')" = "$head" ] \
      || die "cel solo land: the recorded approval is for head $(printf '%s' "$rv" | jq -r '.head // "?"' | cut -c1-12), but #$num is at ${head:0:12} - the PR moved since its review; re-review it. Nothing merged."
    review_by="$(printf '%s' "$rv" | jq -r '.by // ""')"
    review_note="$(printf '%s' "$rv" | jq -r '.note // ""')"
    approved_via="verdict by $review_by (GitHub cannot approve a PR its own author would review)"
  else
    die "cel solo land: #$num is not approved (reviewDecision=${rd:-none}, recorded verdict=$(printf '%s' "$rv" | jq -r '.verdict // "none"' 2>/dev/null || printf none))"
  fi

  local red; red="$(printf '%s' "$pr" | jq "$CEL_JQ_LATEST_CHECKS"'[.statusCheckRollup // [] | latest_checks[] | select((.conclusion // .state) as $s | $s == "FAILURE" or $s == "ERROR")] | length')"
  [ "$red" = 0 ] || die "cel solo land: #$num has $red failing check(s) - a red check is a finding, not a formality"
  # A latest run still going is not green yet (a re-run, a slow suite).
  local pending; pending="$(printf '%s' "$pr" | jq -r "$CEL_JQ_LATEST_CHECKS"'[.statusCheckRollup // [] | latest_checks[]
    | select(((.status // "COMPLETED") != "COMPLETED") or ((.state // "") == "PENDING" or (.state // "") == "EXPECTED"))
    | (.name // .context // "?")] | join(", ")')"
  [ -z "$pending" ] || die "cel solo land: #$num still has check(s) running: $pending - land once they finish. Nothing merged."
  [ "$(printf '%s' "$pr" | jq -r '.mergeable // "MERGEABLE"')" != CONFLICTING ] \
    || die "cel solo land: #$num has conflicts - rebase it, then land again"
  # CI stands in for the gate when the base branch's required checks are all
  # green on this head. When the base branch gates nothing at all, the repo's
  # own gate (workspace.yaml `gate:`) runs instead, in a clean checkout at
  # exactly this head - the same evidence the fleet land collects locally.
  local gate_body gate_out rc=0
  gate_out="$(mktemp)"
  land_ci_gate "$wsdir" "$slug" "$pr" > "$gate_out" || rc=$?
  gate_body="$(cat "$gate_out")"; rm -f "$gate_out"
  if [ "$rc" -ne 0 ]; then
    local gate; gate="$(ws_repo_get "$wsdir" "$SOLO_REPO" gate)"; [ "$gate" = null ] && gate=""
    [ "${LAND_CI_UNPROTECTED:-0}" = 1 ] && [ -n "$gate" ] || die "cel solo land: $gate_body. Nothing merged."
    gate_body="$(_solo_local_gate "$wsdir" "$SOLO_REPO" "$head" "$gate")" \
      || die "cel solo land: $gate_body. Nothing merged."
  fi

  if afk_active; then
    local afk_ev
    afk_ev="$(jq -n --arg ws "$(ws_name "$wsdir")" --arg slug "$slug" --arg num "$num" --arg via "$approved_via" \
      --arg gate "$(case "$gate_body" in "Gate: local"*) printf pass;; *) printf ci;; esac)" \
      '{review:"approved", checks:"green", gate:$gate, mergeable:true, author:"fleet",
        workspace:$ws, pr:$num, slug:$slug, approved_via:$via}')"
    afk_authorise land "$afk_ev" "$slug#$num (solo) - approved via $approved_via, checks green" >/dev/null \
      || die "cel solo land: AFK did not authorise this merge - see the refusal above. Nothing was merged."
  fi

  local body="$gate_body"
  if [ -n "$review_by" ]; then
    body="Reviewed-by: $review_by (approved)${review_note:+$'\n'$review_note}"$'\n'"$gate_body"
  fi
  local bad; bad="$(land_body_hygiene "$body")" || die "cel solo land: could not run the hygiene check on the commit body - nothing was merged"
  [ -z "$bad" ] || die "cel solo land: the review note carries a ticket-shaped token the hygiene scan rejects: $(printf '%s' "$bad" | tr '\n' ' ')- re-record the review without it. Nothing was merged."
  # MERGE ONLY THE HEAD THAT WAS CHECKED: GitHub refuses if it moved since.
  _land_gh "$wsdir" pr merge "$num" --repo "$slug" --squash --delete-branch \
    --match-head-commit "$head" --body "$body" >/dev/null 2>&1 \
    || die "cel solo land: merge of #$num failed - check the PR page; nothing here retries a merge"
  c_ok "landed $SOLO_REPO#$num on $slug (approved via $approved_via)"
}

cmd_solo() {
  case "${1:-}" in
    review) shift; cmd_solo_review "$@" ;;
    land)   shift; cmd_solo_land "$@" ;;
    *) die "usage: cel solo review <repo>#<pr> approved|changes --head <sha> --by <alias> | cel solo land <repo>#<pr>" ;;
  esac
}
