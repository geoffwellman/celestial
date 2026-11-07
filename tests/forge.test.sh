# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/forge.sh"

# A workspace with one repo, `widget`, whose url and per-repo forge keys a
# test sets; `extra` is appended at the top level (a github: block).
_forge_ws() { # <url-or-empty> [forge] [host] [extra-yaml]
  T="$(mktemp -d)"
  printf 'name: forgetest\n%s\nrepos:\n  - name: widget\n    prefix: WG\n' "${4:-}" > "$T/workspace.yaml"
  [ -z "$1" ] || printf '    url: %s\n' "$1" >> "$T/workspace.yaml"
  [ -z "${2:-}" ] || printf '    forge: %s\n' "$2" >> "$T/workspace.yaml"
  [ -z "${3:-}" ] || printf '    host: %s\n' "$3" >> "$T/workspace.yaml"
}
_desc() { forge_repo "$T" widget "$T/repos/widget"; }
_field() { _desc | jq -r ".$1"; }
_json_eq() { assert_eq "$(printf '%s' "$1" | jq -S .)" "$(printf '%s' "$2" | jq -S .)"; }

# gh, recorded: every response is a real gh JSON shape (tests/fixtures/forge/
# github), every call is logged with the GH_TOKEN it carried.
_forge_gh_stub() {
  mkdir -p "$T/bin"
  GH_LOG="$T/gh.log"; : > "$GH_LOG"
  FX="$CEL_ROOT/tests/fixtures/forge/github"
  cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|GH_TOKEN=%s\n' "$*" "${GH_TOKEN-<unset>}" >> "$GH_LOG"
case "$1 $2" in
  "auth token") [ "${4:-}" = acct-b ] && { echo tok-b; exit 0; }; echo "no account $4" >&2; exit 1 ;;
  "api user") echo octo-bot ;;
  "pr create") echo "https://github.com/acme/widget/pull/12" ;;
  "pr view")
    case "$*" in
      *statusCheckRollup*) cat "$FX/pr-checks.json" ;;
      *reviewDecision*)    cat "$FX/pr-reviews.json" ;;
      *)                   cat "$FX/pr-view.json" ;;
    esac ;;
  "pr list") cat "$FX/pr-list.json" ;;
  "pr merge")
    [ -z "${STUB_MERGE_FAIL:-}" ] || { echo 'GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)' >&2; exit 1; }
    echo "Squashed and merged pull request acme/widget#12" ;;
  "api repos/acme/widget/branches/main/protection")
    case "${STUB_PROTECTION:-}" in
      none)   echo '{"message":"Branch not protected","documentation_url":"https://docs.github.com/rest/branches/branch-protection#get-branch-protection","status":"404"}'
              echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1 ;;
      denied) echo '{"message":"Resource not accessible by integration","status":"403"}'
              echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
    esac
    cat "$FX/protection.json" ;;
  "api repos/acme/widget/rules/branches/main")
    case "${STUB_RULES:-none}" in
      denied) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
      garbage) echo '{"message":"Server Error"}' ;;
      *) cat "$FX/rules-${STUB_RULES:-none}.json" ;;
    esac ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
SH
  chmod +x "$T/bin/gh"
  export CEL_FORGE_GH="$T/bin/gh" GH_LOG FX
}

H=877d8526184ed6b5b6595d26016e0879b2a54288
GITHUB_WIDGET='{"provider":"github","host":"github.com","owner":"acme","repo":"widget","ssh_host":"github.com","web_url":"https://github.com/acme/widget","api_url":"https://api.github.com/repos/acme/widget"}'

# ---- the descriptor ---------------------------------------------------------

test_forge_repo_describes_github_ssh_https_and_ssh_scheme_urls() {
  local u
  for u in git@github.com:acme/widget.git https://github.com/acme/widget https://github.com/acme/widget.git ssh://git@github.com/acme/widget.git; do
    _forge_ws "$u"
    _json_eq "$(_desc)" "$GITHUB_WIDGET" || { echo "url: $u"; rm -rf "$T"; return 1; }
    rm -rf "$T"
  done
  # an explicit forge: github / host: github.com changes nothing
  _forge_ws git@github.com:acme/widget.git github github.com
  _json_eq "$(_desc)" "$GITHUB_WIDGET" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The workspace's GitHub ssh alias: git dials the alias, the descriptor is
# still github.com's, and it names the same repo ws_repo_github_slug does -
# from the declared url, or from an origin cloned over the alias.
test_forge_repo_follows_the_workspaces_github_ssh_alias() {
  local acct=$'github:\n  user: acct-b\n  ssh_host: github-acct-b'
  _forge_ws git@github.com:acme/widget.git "" "" "$acct"
  assert_eq "$(_field ssh_host)" github-acct-b || { rm -rf "$T"; return 1; }
  assert_eq "$(_field web_url)" https://github.com/acme/widget || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  _forge_ws "" "" "" "$acct"
  mkdir -p "$T/repos/widget"; git -C "$T/repos/widget" init -q
  git -C "$T/repos/widget" remote add origin git@github-acct-b:acme/widget.git
  assert_eq "$(_field provider)/$(_field owner)/$(_field repo)" github/acme/widget || { rm -rf "$T"; return 1; }
  assert_eq "$(_field ssh_host)" github-acct-b || { rm -rf "$T"; return 1; }
  assert_eq "$(ws_repo_github_slug "$T" widget "$T/repos/widget")" acme/widget || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_forge_repo_detects_forgejo_from_a_declared_forge() {
  _forge_ws https://code.example.net/acme/gizmo.git forgejo
  _json_eq "$(_desc)" '{"provider":"forgejo","host":"code.example.net","owner":"acme","repo":"gizmo","ssh_host":"code.example.net","web_url":"https://code.example.net/acme/gizmo","api_url":"https://code.example.net/api/v1/repos/acme/gizmo"}' \
    || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  # an ssh port is ssh's, not the web host's
  _forge_ws ssh://git@code.example.net:2222/acme/gizmo.git forgejo
  assert_eq "$(_field host) $(_field ssh_host) $(_field api_url)" \
    "code.example.net code.example.net https://code.example.net/api/v1/repos/acme/gizmo" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  # an https port is the web host's
  _forge_ws https://code.example.net:3000/acme/gizmo forgejo
  assert_eq "$(_field web_url) $(_field ssh_host)" "https://code.example.net:3000/acme/gizmo code.example.net" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A `host:` of the repo's own marks it Forgejo, and is where the web and API
# live when the clone url dials an ssh alias.
test_forge_repo_detects_forgejo_from_a_host_override() {
  _forge_ws git@forgejo-acme:acme/gizmo.git "" code.example.net
  _json_eq "$(_desc)" '{"provider":"forgejo","host":"code.example.net","owner":"acme","repo":"gizmo","ssh_host":"forgejo-acme","web_url":"https://code.example.net/acme/gizmo","api_url":"https://code.example.net/api/v1/repos/acme/gizmo"}' \
    || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  _forge_ws git@code.example.net:acme/gizmo.git "" code.example.net
  assert_eq "$(_field provider) $(_field ssh_host)" "forgejo code.example.net" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Refused, never guessed: an undeclared host, a lookalike of github.com or
# of the account's alias, and a declaration the url contradicts.
test_forge_repo_refuses_lookalike_hosts_and_contradictions() {
  local acct=$'github:\n  user: acct-b\n  ssh_host: github-acct-b' out
  local -a cases=(
    "git@evilgithub.com:acme/widget.git|||"
    "https://github.com.evil.com/acme/widget|||"
    "https://evil.github.com/acme/widget|||"
    "git@evil.github.com:acme/widget.git|||"
    "https://gitlab.com/github.com/acme/widget|||"
    "https://evil.github.com/acme/widget|github||"
    "git@github-acct-bx:acme/widget.git|||acct"
    "git@github-acct-bx:acme/widget.git|github||acct"
    "git@github.com:acme/widget.git|forgejo||"
    "git@github.com:acme/widget.git||code.example.net|"
    "git@github-acct-b:acme/widget.git|forgejo|code.example.net|acct"
    "git@forgejo-acme:acme/gizmo.git|forgejo||"
    "https://other.example.net/acme/gizmo||code.example.net|"
    "https://code.example.net/acme/gizmo|forgejo|github.com|"
    "https://code.example.net/acme/gizmo|gitlab||"
    "http://code.example.net/acme/gizmo|forgejo||"
    "https://code.example.net/acme/gizmo/extra|forgejo||"
  )
  local c u f h x
  for c in "${cases[@]}"; do
    IFS='|' read -r u f h x <<< "$c"
    _forge_ws "$u" "$f" "$h" "${x:+$acct}"
    if out="$(_desc 2>/dev/null)"; then echo "accepted: url=$u forge=$f host=$h -> $out"; rm -rf "$T"; return 1; fi
    rm -rf "$T"
  done
  # the control: the account's own alias IS GitHub, so the refusals above
  # are about the lookalikes, not about the alias block
  _forge_ws git@github-acct-b:acme/widget.git "" "" "$acct"
  assert_eq "$(_field provider)" github || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  _forge_ws git@evilgithub.com:acme/widget.git
  assert_contains "$(_desc 2>&1)" "cannot tell which forge serves evilgithub.com" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_forge_repo_refuses_a_repo_with_no_url_and_no_origin() {
  _forge_ws ""
  assert_fails _desc || { rm -rf "$T"; return 1; }
  assert_contains "$(_desc 2>&1)" "no url and has no origin" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# ---- GitHub operations, from recorded gh output -----------------------------

test_forge_pr_view_normalises_recorded_gh_output() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  local out; out="$(forge_pr_view "$T" widget 12)" || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  _json_eq "$out" "{\"number\":12,\"state\":\"open\",\"head_sha\":\"$H\",\"head_ref\":\"fix-widget-sizing\",\"base_ref\":\"main\",\"author\":\"octo-bot\",\"draft\":false,\"mergeable\":\"behind\",\"merged_at\":null,\"url\":\"https://github.com/acme/widget/pull/12\"}" \
    || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "pr view 12 --repo acme/widget --json" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_forge_pr_list_passes_filters_and_normalises_each_pr() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  local out; out="$(forge_pr_list "$T" widget open --author @me --limit 50)" || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "pr list --repo acme/widget --state open --author @me --limit 50 --json" || { rm -rf "$T"; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -r 'map("\(.number):\(.mergeable):\(.draft):\(.author)") | join(" ")')" \
    "12:clean:false:octo-bot 14:conflicting:true:app/dependabot" || { rm -rf "$T"; return 1; }
  assert_fails forge_pr_list "$T" widget opened || { rm -rf "$T"; return 1; }
  assert_fails forge_pr_list "$T" widget open --limit 0 || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The latest run of each check wins (a green re-run clears an earlier red), a
# running check has no conclusion yet, and statuses read like checks.
test_forge_pr_checks_normalises_the_rollup_and_required_checks() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  local out; out="$(forge_pr_checks "$T" widget 12)" || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -c '{head_sha, base_ref, required, protection}')" \
    "{\"head_sha\":\"$H\",\"base_ref\":\"main\",\"required\":[\"Tests\"],\"protection\":\"protected\"}" || { rm -rf "$T"; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -r '.checks | sort_by(.name) | map("\(.name)=\(.status)/\(.conclusion)") | join(" ")')" \
    "Docs=completed/skipped EasyCLA=completed/success Lint=in_progress/null Tests=completed/success tide=in_progress/null" \
    || { rm -rf "$T"; return 1; }
  _json_eq "$(printf '%s' "$out" | jq -c '.checks[] | select(.name == "Tests")')" \
    '{"name":"Tests","status":"completed","conclusion":"success","url":"https://github.com/acme/widget/actions/runs/4237223019/job/12840253999"}' \
    || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The required checks are the union of classic protection and the rulesets in
# effect. Only GitHub's own "Branch not protected" AND no ruleset requiring a
# check says the branch requires none; a refused or unreadable read of either
# is unknown, never unprotected.
test_forge_pr_checks_reads_rulesets_and_tells_unprotected_from_unknown() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  _pv() { forge_pr_checks "$T" widget 12 | jq -c '[.protection, .required]'; }
  # gated by a ruleset alone: classic says "Branch not protected"
  assert_eq "$(STUB_PROTECTION=none STUB_RULES=ruleset _pv)" '["protected",["Build","Tests"]]' || { rm -rf "$T"; return 1; }
  # both: the union
  assert_eq "$(STUB_RULES=ruleset _pv)" '["protected",["Build","Tests"]]' || { rm -rf "$T"; return 1; }
  # neither gates anything
  assert_eq "$(STUB_PROTECTION=none _pv)" '["unprotected",[]]' || { rm -rf "$T"; return 1; }
  # either read refused or unreadable
  assert_eq "$(STUB_PROTECTION=denied _pv)" '["unknown",[]]' || { rm -rf "$T"; return 1; }
  assert_eq "$(STUB_PROTECTION=none STUB_RULES=denied _pv)" '["unknown",[]]' || { rm -rf "$T"; return 1; }
  assert_eq "$(STUB_RULES=denied _pv)" '["unknown",[]]' || { rm -rf "$T"; return 1; }
  assert_eq "$(STUB_PROTECTION=none STUB_RULES=garbage _pv)" '["unknown",[]]' || { rm -rf "$T"; return 1; }
  # a required workflow gates on checks no list of names can carry
  assert_eq "$(STUB_PROTECTION=none STUB_RULES=workflows _pv)" '["unknown",[]]' || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "api repos/acme/widget/rules/branches/main --paginate --slurp" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_forge_pr_reviews_normalises_decision_and_reviewed_heads() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  local out; out="$(forge_pr_reviews "$T" widget 12)" || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -r .decision)" changes_requested || { rm -rf "$T"; return 1; }
  _json_eq "$(printf '%s' "$out" | jq -c '.reviews[1]')" \
    "{\"author\":\"reviewer-two\",\"state\":\"changes_requested\",\"head_sha\":\"$H\",\"submitted_at\":\"2026-11-07T15:00:09Z\"}" \
    || { rm -rf "$T"; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -r '.reviews[0] | "\(.state) \(.head_sha)"')" "approved 2d910406c690af0ce2ad39f79f948a713321c2b1" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The merge is a squash of exactly the expected head; a moved head is the
# forge's refusal, and stdout carries only the result.
test_forge_pr_merge_squashes_only_the_expected_head() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  local out; out="$(forge_pr_merge "$T" widget 12 "$H" "Reviewed-by: r (approved)" 2>/dev/null)" || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  _json_eq "$out" "{\"merged\":true,\"number\":12,\"head_sha\":\"$H\"}" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "pr merge 12 --repo acme/widget --squash --delete-branch --match-head-commit $H --body Reviewed-by: r (approved)" \
    || { rm -rf "$T"; return 1; }
  : > "$GH_LOG"
  out="$(STUB_MERGE_FAIL=1 forge_pr_merge "$T" widget 12 "$H" 2>/dev/null)" && { echo "a refused merge reported success"; rm -rf "$T"; return 1; }
  assert_eq "$out" "" || { rm -rf "$T"; return 1; }
  : > "$GH_LOG"
  assert_fails forge_pr_merge "$T" widget 12 877d852 || { rm -rf "$T"; return 1; }
  assert_fails forge_pr_merge "$T" widget 12 || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$GH_LOG")" "" || { echo "merged without a full expected head"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_forge_whoami_names_the_account() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  _json_eq "$(forge_whoami "$T" widget)" '{"login":"octo-bot"}' || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A workspace's declared GitHub account carries every forge call, and an
# account that is not logged in refuses rather than act as another.
test_forge_ops_act_as_the_workspaces_github_account() {
  _forge_ws git@github.com:acme/widget.git "" "" $'github:\n  user: acct-b'; _forge_gh_stub
  forge_pr_view "$T" widget 12 >/dev/null || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_contains "$(grep '^pr view' "$GH_LOG")" "GH_TOKEN=tok-b" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  _forge_ws git@github.com:acme/widget.git "" "" $'github:\n  user: acct-z'; _forge_gh_stub
  assert_fails forge_pr_view "$T" widget 12 || { rm -rf "$T"; return 1; }
  if grep -q '^pr view' "$GH_LOG"; then echo "acted as the active account"; rm -rf "$T"; return 1; fi
  rm -rf "$T"
}

test_forge_ops_refuse_a_pr_that_is_not_a_number() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  local op
  for op in forge_pr_view forge_pr_checks forge_pr_reviews; do
    assert_fails "$op" "$T" widget 12abc || { rm -rf "$T"; return 1; }
  done
  assert_eq "$(cat "$GH_LOG")" "" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# ---- Forgejo operations, from spec-derived fixtures -------------------------
# tests/lib/forgejo-stub.sh answers as Forgejo 17's API does (fixtures in
# tests/fixtures/forge/forgejo - see PROVENANCE) for a gizmo-like repo: cloned
# over the forgejo-ct.internal ssh host, web and API on plain-HTTP
# forgejo.internal.
source "$CEL_ROOT/tests/lib/forgejo-stub.sh"
MOVED=2222222222222222222222222222222222222222
GIZMO='{"provider":"forgejo","host":"forgejo.internal","owner":"geoff","repo":"gizmo","ssh_host":"forgejo-ct.internal","web_url":"http://forgejo.internal/geoff/gizmo","api_url":"http://forgejo.internal/api/v1/repos/geoff/gizmo"}'
_fj_ws() { # [extra-yaml]
  _forge_ws git@forgejo-ct.internal:geoff/gizmo.git forgejo http://forgejo.internal "${1:-}"
  _forge_gh_stub; _forgejo_stub "$T"
}
_fj_no_gh() { assert_eq "$(cat "$GH_LOG")" "" || { echo "a Forgejo repo reached gh"; return 1; }; }

test_forge_repo_describes_an_internal_forgejo_on_plain_http() {
  _forge_ws git@forgejo-ct.internal:geoff/gizmo.git forgejo http://forgejo.internal
  _json_eq "$(_desc)" "$GIZMO" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  # a host of its own marks it Forgejo, as before
  _forge_ws git@forgejo-ct.internal:geoff/gizmo.git "" http://forgejo.internal
  _json_eq "$(_desc)" "$GIZMO" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  # https stays the default: plain http is declared, never implied...
  _forge_ws git@forgejo-ct.internal:geoff/gizmo.git forgejo forgejo.internal
  assert_eq "$(_field api_url)" https://forgejo.internal/api/v1/repos/geoff/gizmo || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  # ...and an https clone url is not served over http
  _forge_ws https://forgejo.internal/geoff/gizmo.git forgejo http://forgejo.internal
  assert_fails _desc || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_forgejo_whoami_and_pr_view_normalise_the_api() {
  _fj_ws
  _json_eq "$(forge_whoami "$T" widget)" '{"login":"geoff"}' || { rm -rf "$T"; return 1; }
  local out; out="$(forge_pr_view "$T" widget 31)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  _json_eq "$out" "{\"number\":31,\"state\":\"open\",\"head_sha\":\"$FJ_FIXTURE_HEAD\",\"head_ref\":\"WG-31-session-beds\",\"base_ref\":\"main\",\"author\":\"geoff\",\"draft\":false,\"mergeable\":\"clean\",\"merged_at\":null,\"url\":\"http://forgejo.internal/geoff/gizmo/pulls/31\"}" \
    || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "GET http://forgejo.internal/api/v1/user" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "GET http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/31" || { rm -rf "$T"; return 1; }
  assert_eq "$(STUB_FJ_STATE=merged forge_pr_view "$T" widget 31 | jq -c '[.state, .mergeable]')" '["merged","unknown"]' || { rm -rf "$T"; return 1; }
  assert_eq "$(STUB_FJ_MERGEABLE=false forge_pr_view "$T" widget 31 | jq -r .mergeable)" conflicting || { rm -rf "$T"; return 1; }
  _fj_no_gh || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The stub serves three PRs a page whatever `limit` asks - as a server whose
# MAX_RESPONSE_ITEMS is lower would - so a short page is not the last one.
test_forgejo_pr_list_reads_every_page_and_filters_like_github() {
  _fj_ws
  _pl() { forge_pr_list "$T" widget "$@" | jq -r 'map("\(.number):\(.state):\(.mergeable):\(.draft):\(.author)") | join(" ")'; }
  assert_eq "$(_pl open)" "31:open:clean:false:geoff 30:open:conflicting:true:geoff 29:open:behind:false:helper-bot" || { rm -rf "$T"; return 1; }
  assert_eq "$(_pl merged)" "27:merged:unknown:false:geoff" || { rm -rf "$T"; return 1; }
  assert_eq "$(_pl closed)" "27:merged:unknown:false:geoff 26:closed:unknown:false:geoff" || { rm -rf "$T"; return 1; }
  : > "$FJ_LOG"
  assert_eq "$(_pl all | wc -w)" 5 || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "pulls?state=all&limit=50&page=3" || { rm -rf "$T"; return 1; }
  assert_eq "$(_pl all --limit 2)" "31:open:clean:false:geoff 30:open:conflicting:true:geoff" || { rm -rf "$T"; return 1; }
  : > "$FJ_LOG"
  assert_eq "$(forge_pr_list "$T" widget open --author @me | jq -r 'map(.number) | join(" ")')" "31 30" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "pulls?state=open&poster=geoff&limit=50&page=1" || { rm -rf "$T"; return 1; }
  assert_eq "$(forge_pr_list "$T" widget all --head docs-mixer | jq -r 'map(.number) | join(" ")')" 29 || { rm -rf "$T"; return 1; }
  assert_fails forge_pr_list "$T" widget opened || { rm -rf "$T"; return 1; }
  _fj_no_gh || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The head's combined status, latest status per context, every page of it;
# the required checks from the base's exact protection rule.
test_forgejo_pr_checks_reads_the_heads_latest_statuses_and_the_rule() {
  _fj_ws
  local out; out="$(forge_pr_checks "$T" widget 31)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -c '{head_sha, base_ref, required, protection}' <<<"$out")" \
    "{\"head_sha\":\"$FJ_FIXTURE_HEAD\",\"base_ref\":\"main\",\"required\":[\"ci / test (pull_request)\"],\"protection\":\"protected\"}" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.checks | sort_by(.name) | map("\(.name)=\(.status)/\(.conclusion)") | join(" ")' <<<"$out")" \
    "ci / docs (pull_request)=completed/failure ci / lint (pull_request)=in_progress/null ci / test (pull_request)=completed/success" || { rm -rf "$T"; return 1; }
  _json_eq "$(jq -c '.checks[] | select(.name == "ci / test (pull_request)")' <<<"$out")" \
    '{"name":"ci / test (pull_request)","status":"completed","conclusion":"success","url":"http://forgejo.internal/geoff/gizmo/actions/runs/41/jobs/0"}' || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "GET http://forgejo.internal/api/v1/repos/geoff/gizmo/commits/$FJ_FIXTURE_HEAD/status?limit=50&page=2" || { rm -rf "$T"; return 1; }
  # a re-run supersedes the run it repeats
  out="$(STUB_FJ_STATUSES='[{"id":50,"context":"ci / test (pull_request)","status":"failure"},{"id":51,"context":"ci / test (pull_request)","status":"success"}]' forge_pr_checks "$T" widget 31)"
  assert_eq "$(jq -r '.checks | map("\(.name)=\(.conclusion)") | join(" ")' <<<"$out")" "ci / test (pull_request)=success" || { rm -rf "$T"; return 1; }
  _fj_no_gh || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Only Forgejo's own 404 for the exact rule AND no glob rule matching the
# base says it requires nothing; a glob rule that matches gates it; any
# other answer - refused, broken, a server error, a rule naming no context, a
# glob this cannot read, or Forgejo's 404 for the rule while the rule list
# itself cannot be read - is unknown, never unprotected.
test_forgejo_protection_is_unprotected_only_on_a_genuine_404_and_no_matching_glob() {
  _fj_ws
  _pv() { forge_pr_checks "$T" widget 31 | jq -c '[.protection, .required]'; }
  assert_eq "$(STUB_FJ_PROT=none _pv)" '["unprotected",[]]' || { rm -rf "$T"; return 1; }
  assert_eq "$(STUB_FJ_PROT=glob _pv)" '["protected",["ci / test (pull_request)"]]' || { rm -rf "$T"; return 1; }
  local p
  for p in unreadable-glob unnamed denied broken-404 error list-denied; do
    assert_eq "$(STUB_FJ_PROT=$p _pv)" '["unknown",[]]' || { echo "protection answer: $p"; rm -rf "$T"; return 1; }
  done
  grep -qx 'GET http://forgejo.internal/api/v1/repos/geoff/gizmo/branch_protections' "$FJ_LOG" \
    || { echo "the rule list was not read"; rm -rf "$T"; return 1; }
  _fj_no_gh || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_forgejo_pr_reviews_normalise_states_and_bind_approval_to_the_head() {
  _fj_ws
  local out; out="$(forge_pr_reviews "$T" widget 31)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r .decision <<<"$out")" approved || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.reviews | map("\(.author):\(.state):\(.head_sha[0:4])") | join(" ")' <<<"$out")" \
    "reviewer-one:changes_requested:1111 reviewer-one:approved:3c1f reviewer-two:commented:3c1f reviewer-three:dismissed:1111" || { rm -rf "$T"; return 1; }
  _json_eq "$(jq -c '.reviews[1]' <<<"$out")" \
    "{\"author\":\"reviewer-one\",\"state\":\"approved\",\"head_sha\":\"$FJ_FIXTURE_HEAD\",\"submitted_at\":\"2026-11-07T16:30:00Z\"}" || { rm -rf "$T"; return 1; }
  # the head moved past the approval: it approves nothing now
  assert_eq "$(STUB_FJ_HEAD=$MOVED forge_pr_reviews "$T" widget 31 | jq -r .decision)" none || { rm -rf "$T"; return 1; }
  _fj_no_gh || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A squash of exactly the expected head, branch deleted. A head that moved is
# refused before anything is sent; the forge's own refusal is a refusal; and
# stdout carries only the result.
test_forgejo_pr_merge_squashes_only_the_expected_head() {
  _fj_ws
  local out; out="$(forge_pr_merge "$T" widget 31 "$FJ_FIXTURE_HEAD" "Reviewed-by: r (approved)" 2>/dev/null)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  _json_eq "$out" "{\"merged\":true,\"number\":31,\"head_sha\":\"$FJ_FIXTURE_HEAD\"}" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "POST http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/31/merge" || { rm -rf "$T"; return 1; }
  _json_eq "$(tail -n1 "$FJ_BODY_LOG")" \
    "{\"Do\":\"squash\",\"head_commit_id\":\"$FJ_FIXTURE_HEAD\",\"delete_branch_after_merge\":true,\"MergeMessageField\":\"Reviewed-by: r (approved)\"}" || { rm -rf "$T"; return 1; }
  : > "$FJ_LOG"
  out="$(STUB_FJ_HEAD=$MOVED forge_pr_merge "$T" widget 31 "$FJ_FIXTURE_HEAD" 2>"$T/err")" && { echo "merged a moved head"; rm -rf "$T"; return 1; }
  assert_eq "$out" "" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/err")" "is now at $MOVED, not the expected $FJ_FIXTURE_HEAD" || { rm -rf "$T"; return 1; }
  out="$(STUB_FJ_MERGE=conflict forge_pr_merge "$T" widget 31 "$FJ_FIXTURE_HEAD" 2>"$T/err")" && { echo "a refused merge reported success"; rm -rf "$T"; return 1; }
  assert_eq "$out" "" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/err")" "HTTP 409" || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -c '^POST' "$FJ_LOG")" 1 || { echo "a moved head reached the merge endpoint"; rm -rf "$T"; return 1; }
  : > "$FJ_LOG"
  assert_fails forge_pr_merge "$T" widget 31 3c1f0e9 || { rm -rf "$T"; return 1; }
  STUB_FJ_STATE=closed assert_fails forge_pr_merge "$T" widget 31 "$FJ_FIXTURE_HEAD" || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -c '^POST' "$FJ_LOG")" 0 || { rm -rf "$T"; return 1; }
  _fj_no_gh || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Ready or draft is the workspace's policy; on Forgejo a draft is the WIP:
# title prefix, so a WIP title under a ready policy is refused, not opened.
test_forgejo_pr_create_opens_ready_or_wip_as_the_policy_says() {
  _fj_ws $'policy:\n  pr_open: ready'
  printf 'What and why.\n' > "$T/body.md"
  local out; out="$(forge_pr_create "$T" widget WG-32-mixer main "Mixer gain staging" "$T/body.md")" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -c '[.number, .draft, .head_ref, .base_ref, .url]' <<<"$out")" '[32,false,"WG-32-mixer","main","http://forgejo.internal/geoff/gizmo/pulls/32"]' || { rm -rf "$T"; return 1; }
  _json_eq "$(tail -n1 "$FJ_BODY_LOG")" '{"head":"WG-32-mixer","base":"main","title":"Mixer gain staging","body":"What and why.\n"}' || { rm -rf "$T"; return 1; }
  : > "$FJ_LOG"
  assert_fails forge_pr_create "$T" widget WG-32-mixer main "WIP: mixer" "$T/body.md" || { rm -rf "$T"; return 1; }
  assert_fails forge_pr_create "$T" widget WG-32-mixer main "Mixer" "$T/missing.md" || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$FJ_LOG")" "" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  _fj_ws
  printf 'x\n' > "$T/body.md"
  out="$(forge_pr_create "$T" widget WG-32-mixer main "Mixer gain staging" "$T/body.md")" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r .draft <<<"$out")" true || { rm -rf "$T"; return 1; }
  assert_eq "$(tail -n1 "$FJ_BODY_LOG" | jq -r .title)" "WIP: Mixer gain staging" || { rm -rf "$T"; return 1; }
  _fj_no_gh || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_forge_pr_create_on_github_follows_the_same_policy() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  printf 'x\n' > "$T/body.md"
  local out; out="$(forge_pr_create "$T" widget fix-widget-sizing main "Fix sizing" "$T/body.md")" || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r .number <<<"$out")" 12 || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "pr create --repo acme/widget --head fix-widget-sizing --base main --title Fix sizing --body-file $T/body.md --draft|" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  _forge_ws git@github.com:acme/widget.git "" "" $'policy:\n  pr_open: ready'; _forge_gh_stub
  printf 'x\n' > "$T/body.md"
  forge_pr_create "$T" widget fix-widget-sizing main "Fix sizing" "$T/body.md" >/dev/null || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "--body-file $T/body.md|GH_TOKEN" || { echo "a ready PR opened as a draft"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# No usable token, no request: missing, or open to anyone but its owner, is
# refused by name before curl runs.
test_forgejo_token_missing_or_open_to_others_is_refused_before_any_request() {
  _fj_ws
  local tok="$XDG_CONFIG_HOME/cel/forge/forgejo.internal.token"
  chmod 640 "$tok"
  forge_whoami "$T" widget >/dev/null 2>"$T/err" && { echo "used a group-readable token"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/err")" "chmod 600" || { rm -rf "$T"; return 1; }
  chmod 604 "$tok"
  assert_fails forge_pr_view "$T" widget 31 || { rm -rf "$T"; return 1; }
  rm -f "$tok"
  forge_pr_checks "$T" widget 31 >/dev/null 2>"$T/err" && { echo "acted without a token"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/err")" "save it to $tok with mode 600" || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$FJ_LOG")" "" || { echo "a request went out without a usable token"; rm -rf "$T"; return 1; }
  _fj_no_gh || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The token reaches curl on stdin as a config line - never in any argv, where
# `ps` would show it - and only for its own host.
test_forgejo_token_travels_on_stdin_never_in_argv_and_only_to_its_host() {
  _fj_ws
  forge_whoami "$T" widget >/dev/null && forge_pr_checks "$T" widget 31 >/dev/null \
    && forge_pr_merge "$T" widget 31 "$FJ_FIXTURE_HEAD" "body" >/dev/null 2>&1 || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  [ -s "$FJ_ARGV_LOG" ] || { rm -rf "$T"; return 1; }
  if grep -qF "$FJ_TOKEN" "$FJ_ARGV_LOG"; then echo "the token reached curl's argv"; rm -rf "$T"; return 1; fi
  assert_eq "$(grep -c -- '--config -' "$FJ_ARGV_LOG")" "$(wc -l < "$FJ_ARGV_LOG")" || { rm -rf "$T"; return 1; }
  assert_eq "$(sort -u "$FJ_STDIN_LOG")" "header = \"Authorization: token $FJ_TOKEN\"" || { rm -rf "$T"; return 1; }
  : > "$FJ_LOG"
  assert_fails _forge_fj forgejo.internal GET http://forgejo.internal.evil.example/api/v1/user || { rm -rf "$T"; return 1; }
  assert_fails _forge_fj forgejo.internal GET https://example.net/api/v1/user || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$FJ_LOG")" "" || { echo "the token went to another host"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A plain-http forge says, at every operation, that the token is crossing the
# network unencrypted; an https one says nothing.
test_forgejo_over_plain_http_warns_that_the_token_is_unencrypted() {
  _fj_ws
  forge_whoami "$T" widget >/dev/null 2>"$T/err" || { cat "$T/err"; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/err")" "forge: token sent unencrypted to forgejo.internal - plain http is declared for this repo" || { rm -rf "$T"; return 1; }
  forge_pr_view "$T" widget 31 >/dev/null 2>"$T/err" || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -c 'token sent unencrypted' "$T/err")" 1 || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  _forge_ws git@forgejo-ct.internal:geoff/gizmo.git forgejo forgejo.internal; _forge_gh_stub; _forgejo_stub "$T"
  forge_whoami "$T" widget >/dev/null 2>"$T/err" || true
  if grep -q 'unencrypted' "$T/err"; then echo "warned about an https forge"; rm -rf "$T"; return 1; fi
  rm -rf "$T"
}

# CEL_FORGE_CURL is a test seam: outside CEL_TESTING the token goes to the
# `curl` on PATH, never to whatever binary a variable names.
test_forgejo_curl_seam_is_honoured_only_under_test() {
  _fj_ws
  mkdir -p "$T/pathbin"
  cat > "$T/pathbin/curl" <<SH
#!/usr/bin/env bash
cat >/dev/null
echo "\$*" >> "$T/path-curl.log"
printf '%s\n%s' '{"login":"path-curl"}' 200
SH
  chmod +x "$T/pathbin/curl"
  local out
  out="$(unset CEL_TESTING; PATH="$T/pathbin:$PATH" forge_whoami "$T" widget 2>/dev/null)" || { rm -rf "$T"; return 1; }
  assert_eq "$out" '{"login":"path-curl"}' || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$FJ_LOG")" "" || { echo "the stub named by CEL_FORGE_CURL ran outside a test"; rm -rf "$T"; return 1; }
  out="$(PATH="$T/pathbin:$PATH" forge_whoami "$T" widget 2>/dev/null)" || { rm -rf "$T"; return 1; }
  assert_eq "$out" '{"login":"geoff"}' || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# `cel forge`: the same answers from a shell, on either forge.
test_cel_forge_cli_reads_either_forge() {
  _fj_ws
  local out
  out="$(cd "$T" && cmd_forge pr view widget#31)" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "#31 open by geoff" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "head $FJ_FIXTURE_HEAD (WG-31-session-beds) -> main" || { rm -rf "$T"; return 1; }
  assert_eq "$(cd "$T" && cmd_forge pr checks widget#31 --json | jq -r .protection)" protected || { rm -rf "$T"; return 1; }
  assert_contains "$(cd "$T" && cmd_forge pr reviews widget#31)" "decision: approved" || { rm -rf "$T"; return 1; }
  _json_eq "$(cd "$T" && cmd_forge repo widget)" "$GIZMO" || { rm -rf "$T"; return 1; }
  # the workspace from the pane's own environment, standing outside it
  assert_eq "$(cd /tmp && CEL_WORKSPACE="$T" cmd_forge whoami widget)" geoff || { rm -rf "$T"; return 1; }
  printf 'x\n' > "$T/body.md"
  ( cd "$T" && CEL_ROLE=reviewer cmd_forge pr create widget --head a --base main --title t --body-file "$T/body.md" ) >/dev/null 2>&1 \
    && { echo "a reviewer opened a PR"; rm -rf "$T"; return 1; }
  ( cd "$T" && cmd_forge pr view nope#1 ) >/dev/null 2>&1 && { echo "read a repo the workspace lacks"; rm -rf "$T"; return 1; }
  assert_eq "$(grep -c '^POST' "$FJ_LOG")" 0 || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  assert_eq "$(cd "$T" && cmd_forge pr view widget#12 --json | jq -r .head_sha)" "$H" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# An address the descriptor refuses is refused by every operation, before gh.
test_forge_ops_refuse_an_unresolvable_repo() {
  _forge_ws git@evilgithub.com:acme/widget.git; _forge_gh_stub
  assert_fails forge_pr_view "$T" widget 12 || { rm -rf "$T"; return 1; }
  assert_fails forge_whoami "$T" widget || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$GH_LOG")" "" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
