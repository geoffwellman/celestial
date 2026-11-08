# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/forge.sh"
source "$CEL_ROOT/tests/lib/launch-mirror.sh"
# cel forge's writes check the caller against its launch: every call gets one
# that carries exactly its identity, unless a test builds its own proc tree.
launch_mirror_wrap cmd_forge

# A workspace with one repo, `widget`, whose url and per-repo forge keys a
# test sets; `extra` is appended at the top level (a github: block).
_forge_ws() { # <url-or-empty> [forge] [host] [extra-yaml]
  T="$(mktemp -d)"; launch_mirror_at "$T/launch-proc"
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
      *)                   cat "${FX_VIEW:-$FX/pr-view.json}" ;;
    esac ;;
  "pr list") cat "$FX/pr-list.json" ;;
  "pr close") echo "✓ Closed pull request acme/widget#12" >&2 ;;
  "pr ready") echo "✓ Pull request acme/widget#12 is marked as \"ready for review\"" >&2 ;;
  "run list") cat "$FX/run-list.json" ;;
  "run rerun") echo "✓ Requested rerun of job" >&2 ;;
  "run view")
    case "$*" in
      *--log-failed*) cat "$FX/job-log.txt" ;;
      *) cat "$FX/run-view.json" ;;
    esac ;;
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
  _json_eq "$out" "{\"number\":12,\"state\":\"open\",\"head_sha\":\"$H\",\"head_ref\":\"fix-widget-sizing\",\"base_ref\":\"main\",\"author\":\"octo-bot\",\"draft\":false,\"mergeable\":\"behind\",\"merged_at\":null,\"url\":\"https://github.com/acme/widget/pull/12\",\"labels\":[]}" \
    || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "pr view 12 --repo acme/widget --json" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_forge_pr_list_passes_filters_and_normalises_each_pr() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  local out; out="$(forge_pr_list "$T" widget open --author @me --limit 50)" || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "pr list --repo acme/widget --state open --author @me --limit 50 --json" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" ",url,labels|" || { rm -rf "$T"; return 1; }
  # a PR's labels are its names, so a caller can honour `hold` on either forge
  assert_eq "$(printf '[{"number":3,"labels":[{"id":"L1","name":"Hold","color":"fff"},{"name":"superseded"}]}]' \
    | jq -c "$_FORGE_JQ_GH"' map(gh_pr) | .[0].labels')" '["Hold","superseded"]' || { rm -rf "$T"; return 1; }
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

# ---- Forgejo operations, from recorded fixtures -----------------------------
# tests/lib/forgejo-stub.sh answers as Forgejo 17's API does (fixtures in
# tests/fixtures/forge/forgejo, recorded and anonymised - see PROVENANCE) for
# a gizmo-like repo: cloned over the forgejo-ct.internal ssh host, web and
# API on plain-HTTP forgejo.internal.
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
  _json_eq "$out" "{\"number\":31,\"state\":\"open\",\"head_sha\":\"$FJ_FIXTURE_HEAD\",\"head_ref\":\"WG-31-session-beds\",\"base_ref\":\"main\",\"author\":\"geoff\",\"draft\":false,\"mergeable\":\"clean\",\"merged_at\":null,\"url\":\"http://forgejo.internal/geoff/gizmo/pulls/31\",\"labels\":[]}" \
    || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "GET http://forgejo.internal/api/v1/user" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "GET http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/31" || { rm -rf "$T"; return 1; }
  assert_eq "$(STUB_FJ_STATE=merged forge_pr_view "$T" widget 31 | jq -c '[.state, .mergeable]')" '["merged","unknown"]' || { rm -rf "$T"; return 1; }
  # Forgejo's false is not proof of a conflict (it also says false before it
  # has computed the PR): unknown, never conflicting.
  assert_eq "$(STUB_FJ_MERGEABLE=false forge_pr_view "$T" widget 31 | jq -r .mergeable)" unknown || { rm -rf "$T"; return 1; }
  assert_eq "$(printf '{"number":4,"state":"open","labels":[{"id":7,"name":"hold"}]}' | jq -c "$_FORGE_JQ_FJ"' fj_pr | .labels')" '["hold"]' || { rm -rf "$T"; return 1; }
  _fj_no_gh || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The stub serves three PRs a page whatever `limit` asks - as a server whose
# MAX_RESPONSE_ITEMS is lower would - so a short page is not the last one.
test_forgejo_pr_list_reads_every_page_and_filters_like_github() {
  _fj_ws
  _pl() { forge_pr_list "$T" widget "$@" | jq -r 'map("\(.number):\(.state):\(.mergeable):\(.draft):\(.author)") | join(" ")'; }
  assert_eq "$(_pl open)" "31:open:clean:false:geoff 30:open:unknown:true:geoff 29:open:behind:false:helper-bot" || { rm -rf "$T"; return 1; }
  assert_eq "$(_pl merged)" "27:merged:unknown:false:geoff" || { rm -rf "$T"; return 1; }
  assert_eq "$(_pl closed)" "27:merged:unknown:false:geoff 26:closed:unknown:false:geoff" || { rm -rf "$T"; return 1; }
  : > "$FJ_LOG"
  assert_eq "$(_pl all | wc -w)" 5 || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "pulls?state=all&limit=50&page=3" || { rm -rf "$T"; return 1; }
  assert_eq "$(_pl all --limit 2)" "31:open:clean:false:geoff 30:open:unknown:true:geoff" || { rm -rf "$T"; return 1; }
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

# Recorded live (Forgejo 17.0.1): an open PR on a clean fast-forward - its
# merge base IS the base's tip - answered mergeable:false until Forgejo
# recomputed it. That shape reads `unknown`, never `conflicting`.
test_forgejo_recorded_mergeable_false_is_unknown_never_conflicting() {
  _fj_ws
  local out; out="$(STUB_FJ_PULL=pull-open-mergeable-false.json forge_pr_view "$T" widget 31)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.mergeable' "$FJX/pull-open-mergeable-false.json"):$(jq -r '.merge_base == .base.sha' "$FJX/pull-open-mergeable-false.json")" "false:true" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -c '[.state, .draft, .mergeable]' <<<"$out")" '["open",true,"unknown"]' || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Recorded live: a migrated PR's author is Forgejo's placeholder `Ghost`, a
# closed PR says mergeable:false, and its migrated reviews carry no commit.
test_forgejo_recorded_migrated_pr_and_reviews_normalise() {
  _fj_ws
  local out; out="$(STUB_FJ_PULL=pull-migrated.json STUB_FJ_STATE=merged forge_pr_view "$T" widget 29)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -c '[.author, .state, .mergeable, .head_ref]' <<<"$out")" '["Ghost","merged","unknown","refs/pull/29/head"]' || { rm -rf "$T"; return 1; }
  out="$(jq -c --slurpfile r "$FJX/reviews-migrated.json" -n "$_FORGE_JQ_FJ"' $r[0] | {decision: fj_decision("x"), heads: [.[].commit_id | _s], authors: ([.[].user.login] | unique)}')"
  assert_eq "$out" '{"decision":"none","heads":[null,null,null],"authors":["Ghost"]}' || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Recorded live: the statuses Forgejo Actions writes - `status` with no
# `state`, `skipped` among them, a site-relative target_url, no creator - read
# as checks with absolute urls.
test_forgejo_recorded_actions_statuses_read_as_checks() {
  _fj_ws
  local out
  out="$(STUB_FJ_STATUSES="$(jq -c .statuses "$FJX/status-actions.json")" forge_pr_checks "$T" widget 31)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.checks | sort_by(.name) | map("\(.status)/\(.conclusion)") | join(" ")' <<<"$out")" \
    "in_progress/null completed/skipped completed/success" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '[.checks[].url | startswith("http://forgejo.internal/geoff/gizmo/actions/runs/")] | all' <<<"$out")" true || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Actions runs and jobs: recorded `status` with a null `conclusion` (a run's
# `failure` IS its failure), the branch filter applied here because Forgejo
# ignores it, a job's plain-text log with its timestamps removed.
test_forgejo_runs_list_view_and_logs_from_recorded_actions() {
  _fj_ws
  local out
  out="$(forge_run_list "$T" widget)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r 'map("\(.id):\(.state):\(.branch)") | join(" ")' <<<"$out")" \
    "21:running:#105 17:success:main 16:success:main 15:cancelled:main 11:failure:main 9:failure:main" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -c '.[] | select(.id == 9) | [.number, .workflow, .event, .head_sha[0:7], .url]' <<<"$out")" \
    '[3,"desktop.yml","push","f77c249","http://forgejo.internal/geoff/gizmo/actions/runs/3"]' || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "GET http://forgejo.internal/api/v1/repos/geoff/gizmo/actions/runs?limit=50&page=1" || { rm -rf "$T"; return 1; }
  assert_eq "$(forge_run_list "$T" widget --branch '#105' | jq -r 'map(.id) | join(" ")')" 21 || { rm -rf "$T"; return 1; }
  assert_eq "$(forge_run_list "$T" widget --limit 2 | jq -r 'map(.id) | join(" ")')" "21 17" || { rm -rf "$T"; return 1; }
  out="$(forge_run_view "$T" widget 9)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -c '[.id, .state, (.jobs | map([.id, .name, .state]))]' <<<"$out")" \
    '[9,"failure",[[15,"build · test · headless snapshot","failure"]]]' || { rm -rf "$T"; return 1; }
  out="$(forge_run_logs "$T" widget 15)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(printf '%s\n' "$out" | tail -n1)" "Job 'build · test · headless snapshot' failed" || { rm -rf "$T"; return 1; }
  assert_eq "$(printf '%s\n' "$out" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" 0 || { rm -rf "$T"; return 1; }
  assert_eq "$(forge_run_logs "$T" widget 15 --raw | grep -cE '^2026-11-07T')" "$(grep -c . "$FJX/actions-job.log")" || { rm -rf "$T"; return 1; }
  assert_fails forge_run_view "$T" widget 999 2>/dev/null || { rm -rf "$T"; return 1; }
  assert_fails forge_run_logs "$T" widget 15abc 2>/dev/null || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -vc '^GET ' "$FJ_LOG")" 0 || { echo "a read wrote"; rm -rf "$T"; return 1; }
  _fj_no_gh || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# GitHub runs through gh, the same shapes: recorded `gh run list|view` and a
# `--log-failed` job log with its job/step columns and timestamps removed.
test_github_runs_list_view_and_logs_from_recorded_gh() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  local out
  out="$(forge_run_list "$T" widget --branch main --limit 6)" || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "run list --repo acme/widget --limit 6 --branch main --json databaseId,number," || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r 'map(.state) | join(" ")' <<<"$out")" "skipped success success failure failure cancelled" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -c '.[0] | [.id, .number, .workflow, .branch]' <<<"$out")" '[42425906115,211,"Release","main"]' || { rm -rf "$T"; return 1; }
  out="$(forge_run_view "$T" widget 42414804133)" || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '[.state] + (.jobs | map("\(.id)=\(.state)")) | join(" ")' <<<"$out")" \
    "failure 128530529707=success 128530529824=failure 128530530840=skipped 128532717430=failure" || { rm -rf "$T"; return 1; }
  out="$(forge_run_logs "$T" widget 128530529824)" || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "run view --repo acme/widget --log-failed --job 128530529824" || { rm -rf "$T"; return 1; }
  assert_eq "$(printf '%s\n' "$out" | head -n1)" "##[group]Run bash tests/run.sh" || { rm -rf "$T"; return 1; }
  assert_eq "$(printf '%s\n' "$out" | tail -n1)" "##[error]Process completed with exit code 1." || { rm -rf "$T"; return 1; }
  assert_contains "$(forge_run_logs "$T" widget 128530529824 --raw | head -n1)" $'Regression suite\tRun regression suite\t' || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The run vocabulary from every state either forge names.
test_run_states_map_to_the_check_vocabulary() {
  assert_eq "$(jq -nc "$_FORGE_JQ_FJ"' [{status:"failure",conclusion:null},{status:"success"},{status:"running"},{status:"waiting"},{status:"blocked"},{status:"cancelled"},{status:"skipped"},{status:"unknown"}] | map(fj_state)')" \
    '["failure","success","running","queued","queued","cancelled","skipped","unknown"]' || return 1
  assert_eq "$(jq -nc "$_FORGE_JQ_GH"' [{status:"completed",conclusion:"timed_out"},{status:"completed",conclusion:"neutral"},{status:"in_progress",conclusion:""},{status:"queued"},{status:"waiting"},{status:"completed",conclusion:"cancelled"},{status:"completed",conclusion:"startup_failure"}] | map(gh_state)')" \
    '["failure","success","running","queued","queued","cancelled","failure"]' || return 1
}

# `cel forge pr close|ready` on Forgejo: the comment goes first, the state is
# PATCHed (the branch is never deleted), ready strips the WIP prefix and is a
# no-op on a ready PR; an agent may change only its own account's PRs or a
# migrated one (Ghost), and reviewers, members and core may not at all.
test_forgejo_pr_close_and_ready() {
  _fj_ws
  printf 'Superseded by #32.\n' > "$T/why.md"
  local out
  out="$(cd "$T" && CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge pr close widget#31 --comment-file "$T/why.md" --json)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r .state <<<"$out")" closed || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -E '^(POST|PATCH|DELETE)' "$FJ_LOG")" $'POST http://forgejo.internal/api/v1/repos/geoff/gizmo/issues/31/comments\nPATCH http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/31' || { rm -rf "$T"; return 1; }
  assert_eq "$(sed -n 1p "$FJ_BODY_LOG" | jq -r .body)" "Superseded by #32." || { rm -rf "$T"; return 1; }
  assert_eq "$(sed -n 2p "$FJ_BODY_LOG")" '{"state":"closed"}' || { rm -rf "$T"; return 1; }
  # a migrated PR (author Ghost) is the agent's to close
  : > "$FJ_LOG"
  ( cd "$T" && STUB_FJ_PULL=pull-migrated.json CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge pr close widget#29 ) >/dev/null || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "PATCH http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/29" || { rm -rf "$T"; return 1; }
  # someone else's PR is refused by name, before any write
  : > "$FJ_LOG"
  out="$(cd "$T" && STUB_FJ_LOGIN=helper-bot CEL_ROLE=orchestrator CEL_INBOX_ME=widget-orch cmd_forge pr close widget#29 2>&1)" && { echo "closed someone else's PR"; rm -rf "$T"; return 1; }
  assert_contains "$out" "helper-bot's pull request" || { rm -rf "$T"; return 1; }
  out="$(cd "$T" && STUB_FJ_LOGIN=helper-bot STUB_FJ_TITLE='WIP: x' CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge pr ready widget#29 2>&1)" && { echo "readied someone else's PR"; rm -rf "$T"; return 1; }
  assert_contains "$out" "helper-bot's pull request" || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -cE '^(POST|PATCH)' "$FJ_LOG")" 0 || { rm -rf "$T"; return 1; }
  # ...and a process with no agent identity is refused, whatever it is
  out="$(cd "$T" && STUB_FJ_LOGIN=helper-bot cmd_forge pr close widget#29 2>&1)" && { echo "no identity closed a PR"; rm -rf "$T"; return 1; }
  assert_contains "$out" "web UI" || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -cE '^(POST|PATCH)' "$FJ_LOG")" 0 || { rm -rf "$T"; return 1; }
  # roles that never close or ready
  local r
  for r in reviewer member core; do
    ( cd "$T" && CEL_ROLE=$r cmd_forge pr close widget#31 ) >/dev/null 2>&1 && { echo "$r closed a PR"; rm -rf "$T"; return 1; }
    ( cd "$T" && CEL_ROLE=$r cmd_forge pr ready widget#31 ) >/dev/null 2>&1 && { echo "$r readied a PR"; rm -rf "$T"; return 1; }
  done
  # ready: the WIP prefix comes off the title; a ready PR is left alone
  : > "$FJ_LOG"; : > "$FJ_BODY_LOG"
  out="$(cd "$T" && STUB_FJ_TITLE='WIP: Session audio' CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge pr ready widget#31 --json)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r .draft <<<"$out")" false || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$FJ_BODY_LOG")" '{"title":"Session audio"}' || { rm -rf "$T"; return 1; }
  : > "$FJ_LOG"
  ( cd "$T" && STUB_FJ_TITLE='[WIP] Session audio' CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge pr ready widget#31 ) >/dev/null || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "PATCH" || { rm -rf "$T"; return 1; }
  : > "$FJ_LOG"
  out="$(cd "$T" && CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge pr ready widget#31 --json)" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -r .draft <<<"$out")" false || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -c '^PATCH' "$FJ_LOG")" 0 || { echo "readied a ready PR"; rm -rf "$T"; return 1; }
  # a refused comment closes nothing
  : > "$FJ_LOG"
  ( cd "$T" && STUB_FJ_WRITE=denied CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge pr close widget#31 --comment-file "$T/why.md" ) >/dev/null 2>&1 && { echo "closed after a refused comment"; rm -rf "$T"; return 1; }
  assert_eq "$(grep -c '^PATCH' "$FJ_LOG")" 0 || { rm -rf "$T"; return 1; }
  _fj_no_gh || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The same verbs on GitHub: gh pr close (no --delete-branch) and gh pr ready,
# a no-op on a PR that is not a draft.
test_github_pr_close_and_ready() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  printf 'Superseded.\n' > "$T/why.md"
  ( cd "$T" && CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge pr close widget#12 --comment-file "$T/why.md" ) >/dev/null 2>&1 || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_contains "$(grep '^pr close' "$GH_LOG")" "pr close 12 --repo acme/widget --comment Superseded." || { rm -rf "$T"; return 1; }
  assert_fails grep -q -- '--delete-branch' "$GH_LOG" || { rm -rf "$T"; return 1; }
  ( cd "$T" && CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge pr ready widget#12 ) >/dev/null 2>&1 || { rm -rf "$T"; return 1; }
  assert_fails grep -q '^pr ready' "$GH_LOG" || { rm -rf "$T"; return 1; }
  # a draft is made ready
  jq '.isDraft = true' "$FX/pr-view.json" > "$T/draft.json"
  ( cd "$T" && FX_VIEW="$T/draft.json" CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge pr ready widget#12 ) >/dev/null 2>&1 || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "pr ready 12 --repo acme/widget" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# NO IDENTITY IS NO AUTHORITY. There is no owner path through cel forge: a
# process that carries no agent role - never launched as one, or an agent
# that shed its marks (env -u CEL_ROLE, setsid into a fresh environment) - is
# refused every write and pointed at the forge's web UI; it still reads.
test_forge_writes_refuse_a_process_with_no_agent_identity() {
  _fj_ws
  local out c
  for c in 'pr close widget#29' 'pr ready widget#29' 'run rerun widget 15'; do
    # shellcheck disable=SC2086
    out="$(cd "$T" && STUB_FJ_LOGIN=helper-bot cmd_forge $c 2>&1)" && { echo "no identity: $c went through"; rm -rf "$T"; return 1; }
    assert_contains "$out" "web UI" || { echo "$c: $out"; rm -rf "$T"; return 1; }
    # an agent that drops CEL_ROLE keeps nothing it can act on
    out="$(cd "$T" && env -u CEL_ROLE CEL_INBOX_ME=widget-orch CEL_PRODUCT=widget CEL_SESSION_ID=s1 \
      bash -c '. "$CEL_ROOT/lib/common.sh"; . "$CEL_ROOT/lib/forge.sh"; cmd_forge '"$c" 2>&1)" \
      && { echo "env -u CEL_ROLE: $c went through"; rm -rf "$T"; return 1; }
    assert_contains "$out" "no agent role" || { echo "env -u: $c: $out"; rm -rf "$T"; return 1; }
    # nor one that leaves its session and its environment behind
    out="$(cd "$T" && setsid -w env -u CEL_ROLE -u CEL_INBOX_ME -u CEL_PRODUCT \
      bash -c '. "$CEL_ROOT/lib/common.sh"; . "$CEL_ROOT/lib/forge.sh"; cmd_forge '"$c" 2>&1)" \
      && { echo "setsid: $c went through"; rm -rf "$T"; return 1; }
    assert_contains "$out" "web UI" || { echo "setsid: $c: $out"; rm -rf "$T"; return 1; }
  done
  assert_eq "$(grep -cE '^(POST|PATCH|DELETE)' "$FJ_LOG")" 0 || { rm -rf "$T"; return 1; }
  # reads stay open to everyone
  ( cd "$T" && cmd_forge pr view widget#31 ) >/dev/null || { echo "no identity could not read a PR"; rm -rf "$T"; return 1; }
  ( cd "$T" && cmd_forge run list widget ) >/dev/null || { echo "no identity could not list runs"; rm -rf "$T"; return 1; }
  ( cd "$T" && cmd_forge whoami widget ) >/dev/null || { echo "no identity could not whoami"; rm -rf "$T"; return 1; }
  ( cd "$T" && CEL_ROLE=reviewer cmd_forge pr reviews widget#31 ) >/dev/null || { echo "a reviewer could not read reviews"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# AN AGENT WRITES AS ITS LAUNCH (lib/identity.sh). A product agent that
# re-dresses its shell - `export CEL_PRODUCT=other` through any indirection -
# keeps its launch's environ, fixed at exec; the nearest process above cel
# carrying CEL_ROLE must agree, so the forged product is refused before any
# write and the agent's own product still works. The suite's /proc is
# CEL_PROC_DIR: here, the caller is $PPID, its runtime 4242.
test_forge_writes_act_only_as_the_launch_environ_says() {
  _fj_ws $'products:\n  - name: shop\n    repos: [web]\n  - name: tools\n    repos: [widget]'
  local P="$T/proc" out
  mkdir -p "$P/$PPID" "$P/4242"
  printf '%s\0' CEL_ROLE=solo CEL_PRODUCT=shop CEL_INBOX_ME=shop-orch > "$P/4242/environ"
  printf '4242 (omp) S 1 1 1' > "$P/4242/stat"
  printf '%s\0' HOME=/h > "$P/$PPID/environ"
  printf '%s (bash) S 4242 1 1' "$PPID" > "$P/$PPID/stat"
  # shop's agent exports tools as its product (and mailbox, so they agree)
  out="$(cd "$T" && X=CEL_PRODUCT; declare -x "$X=tools"; CEL_PROC_DIR="$P" CEL_ROLE=solo CEL_INBOX_ME=tools-orch cmd_forge pr close widget#31 2>&1)" \
    && { echo "a forged product closed another product's PR"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cel forge pr close: this process says CEL_PRODUCT=tools but its launch (pid 4242) says CEL_PRODUCT=shop" || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -cE '^(POST|PATCH|DELETE)' "$FJ_LOG")" 0 || { rm -rf "$T"; return 1; }
  # the agent's real product: tools' agent, launched as tools, closes its own PR
  printf '%s\0' CEL_ROLE=solo CEL_PRODUCT=tools CEL_INBOX_ME=tools-orch > "$P/4242/environ"
  ( cd "$T" && CEL_PROC_DIR="$P" CEL_ROLE=solo CEL_PRODUCT=tools CEL_INBOX_ME=tools-orch cmd_forge pr close widget#31 ) >/dev/null \
    || { echo "its own launch was refused"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "PATCH http://forgejo.internal/api/v1/repos/geoff/gizmo/pulls/31" || { rm -rf "$T"; return 1; }
  # detached: a role with no launch above it changes nothing
  : > "$FJ_LOG"
  printf 'HOME=/h\0' > "$P/4242/environ"
  out="$(cd "$T" && CEL_PROC_DIR="$P" CEL_ROLE=solo CEL_PRODUCT=tools CEL_INBOX_ME=tools-orch cmd_forge run rerun widget 15 2>&1)" \
    && { echo "a detached agent reran a job"; rm -rf "$T"; return 1; }
  assert_contains "$out" "no agent launch above it" || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -cE '^(POST|PATCH|DELETE)' "$FJ_LOG")" 0 || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# NOTHING EXPORTED SKIPS OR REDIRECTS THAT CHECK. CEL_TESTING alone used to
# skip it, and `X=CEL_TESTING; export $X=1` slips past the guard's literal
# spellings. Now the check always runs, and its seam (CEL_PROC_DIR) and the
# forge's curl seam (CEL_FORGE_CURL) are honoured only for a process under
# this checkout's own tests/run.sh - its ancestry, which no variable sets.
test_forge_writes_check_the_launch_whatever_the_environment_says() {
  _fj_ws $'products:\n  - name: shop\n    repos: [web]\n  - name: tools\n    repos: [widget]'
  local out
  # under the suite with no proc fixture: the real /proc decides, and nothing
  # above this test was launched as tools' agent
  out="$(cd "$T" && X=CEL_TESTING; export "$X=1"; unset CEL_PROC_DIR; CEL_ROLE=solo CEL_PRODUCT=tools CEL_INBOX_ME=tools-orch cmd_forge pr close widget#31 2>&1)" \
    && { echo "CEL_TESTING without a proc fixture skipped the check"; rm -rf "$T"; return 1; }
  assert_contains "$out" "launch" || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -cE '^(POST|PATCH|DELETE)' "$FJ_LOG")" 0 || { rm -rf "$T"; return 1; }
  cel_under_suite || { echo "this test is not under the suite"; rm -rf "$T"; return 1; }
  # OUTSIDE the suite - a process the runner did not start (detached, then
  # reparented away from it) - exporting CEL_TESTING, a proc tree that vouches
  # for tools and a stub curl changes nothing: the seams are not honoured
  local P="$T/fake-proc" pc="$T/pathbin" o="$T/outside"
  mkdir -p "$pc"
  printf '#!/usr/bin/env bash\ncat >/dev/null\necho "$*" >> %q\nprintf "%%s\\n%%s" %q 200\n' "$T/path-curl.log" '{"login":"path-curl"}' > "$pc/curl"
  chmod +x "$pc/curl"
  # shellcheck disable=SC2016  # expanded by the detached shell
  OUT_P="$P" OUT_T="$T" OUT_PC="$pc" setsid -f bash -c '
    while p="$(cut -d" " -f4 /proc/$$/stat)"; [ "$(cat "/proc/$p/comm" 2>/dev/null)" = setsid ]; do sleep 0.05; done
    . "$CEL_ROOT/lib/common.sh"
    if cel_under_suite; then echo under; else echo outside; fi
    # the fake tree vouches for this shell as tools agent launch
    mkdir -p "$OUT_P/$$"; printf "%s\0" CEL_ROLE=solo CEL_PRODUCT=tools CEL_INBOX_ME=tools-orch > "$OUT_P/$$/environ"
    printf "%s (bash) S 1 1 1" "$$" > "$OUT_P/$$/stat"
    cd "$OUT_T"
    CEL_TESTING=1 CEL_PROC_DIR="$OUT_P" CEL_ROLE=solo CEL_PRODUCT=tools CEL_INBOX_ME=tools-orch \
      bash -c ". \"\$CEL_ROOT/lib/common.sh\"; . \"\$CEL_ROOT/lib/forge.sh\"; cmd_forge pr close widget#31" && echo closed
    CEL_TESTING=1 PATH="$OUT_PC:$PATH" bash -c ". \"\$CEL_ROOT/lib/common.sh\"; . \"\$CEL_ROOT/lib/forge.sh\"; forge_whoami \"\$OUT_T\" widget"
  ' > "$o" 2>&1 < /dev/null
  local i=0
  until grep -q 'login' "$o" 2>/dev/null || [ "$i" -ge 200 ]; do sleep 0.05; i=$((i + 1)); done
  out="$(cat "$o")"
  assert_contains "$out" outside || { echo "$out"; rm -rf "$T"; return 1; }
  case "$out" in *under*|*closed*) echo "outside the suite the seams were honoured: $out"; rm -rf "$T"; return 1 ;; esac
  assert_contains "$out" "launch" || { echo "$out"; rm -rf "$T"; return 1; }
  # the token went to the curl on PATH, never to CEL_FORGE_CURL's stub
  assert_contains "$out" '{"login":"path-curl"}' || { echo "$out"; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$FJ_LOG")" "" || { echo "the stub named by CEL_FORGE_CURL ran outside the suite"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A product's agent changes only its own product's repos, however the
# workspace account authored the PR.
test_forge_agent_changes_only_its_own_products_repos() {
  _fj_ws $'products:\n  - name: shop\n    repos: [web]\n  - name: tools\n    repos: [widget]'
  local out
  out="$(cd "$T" && CEL_ROLE=solo CEL_PRODUCT=shop cmd_forge pr close widget#31 2>&1)" && { echo "closed another product's PR"; rm -rf "$T"; return 1; }
  assert_contains "$out" "widget is not a repo of product shop" || { rm -rf "$T"; return 1; }
  out="$(cd "$T" && CEL_ROLE=orchestrator CEL_INBOX_ME=shop-orch cmd_forge run rerun widget 15 2>&1)" && { echo "reran another product's job"; rm -rf "$T"; return 1; }
  assert_contains "$out" "not a repo of product shop" || { rm -rf "$T"; return 1; }
  out="$(cd "$T" && CEL_ROLE=solo cmd_forge pr close widget#31 2>&1)" && { echo "closed with no product"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cannot tell which product" || { rm -rf "$T"; return 1; }
  # a product and a mailbox that disagree are no identity at all
  out="$(cd "$T" && CEL_ROLE=solo CEL_PRODUCT=tools CEL_INBOX_ME=shop-orch cmd_forge pr close widget#31 2>&1)" && { echo "closed with a contradictory identity"; rm -rf "$T"; return 1; }
  assert_contains "$out" "name different products" || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -cE '^(POST|PATCH)' "$FJ_LOG")" 0 || { rm -rf "$T"; return 1; }
  ( cd "$T" && CEL_ROLE=orchestrator CEL_INBOX_ME=tools-orch cmd_forge pr close widget#31 ) >/dev/null || { echo "refused its own product"; rm -rf "$T"; return 1; }
  ( cd "$T" && CEL_ROLE=solo CEL_PRODUCT=tools CEL_INBOX_ME=tools-orch cmd_forge pr close widget#31 ) >/dev/null || { echo "refused an agreeing identity"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# `cel forge run rerun`: Forgejo POST /actions/jobs/<id>/rerun, GitHub
# `gh run rerun --job`; the product's agent only, never a member, reviewer,
# core or a process with no role.
test_forge_run_rerun_on_either_forge() {
  _fj_ws
  local out r
  out="$(cd "$T" && CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge run rerun widget 15 --json)" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  _json_eq "$out" '{"rerun":true,"job_id":15}' || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -E '^(POST|PATCH)' "$FJ_LOG")" "POST http://forgejo.internal/api/v1/repos/geoff/gizmo/actions/jobs/15/rerun" || { rm -rf "$T"; return 1; }
  : > "$FJ_LOG"
  for r in member reviewer core; do
    ( cd "$T" && CEL_ROLE=$r CEL_PRODUCT=widget cmd_forge run rerun widget 15 ) >/dev/null 2>&1 && { echo "$r reran a job"; rm -rf "$T"; return 1; }
  done
  assert_eq "$(grep -c '^POST' "$FJ_LOG")" 0 || { rm -rf "$T"; return 1; }
  ( cd "$T" && STUB_FJ_WRITE=denied CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge run rerun widget 15 ) >/dev/null 2>&1 && { echo "a refused rerun said yes"; rm -rf "$T"; return 1; }
  rm -rf "$T"
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  ( cd "$T" && CEL_ROLE=solo CEL_PRODUCT=widget cmd_forge run rerun widget 128530529824 ) >/dev/null 2>&1 || { cat "$GH_LOG"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$GH_LOG")" "run rerun --repo acme/widget --job 128530529824" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Runs by commit, with their job ids; a web page mapped to API ids only by
# Forgejo's own html_url (the UI's run 3 is API run 9, its job 0 is job 15),
# anything else refused with the --sha hint.
test_forge_runs_by_sha_and_by_web_page() {
  _fj_ws
  local out sha=f77c249f8ef63638458ca239ebdced36f545f90a
  out="$(forge_run_list "$T" widget --sha "$sha")" || { cat "$FJ_LOG"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -c 'map([.id, .number, (.jobs | map(.id))])' <<<"$out")" '[[9,3,[15]]]' || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$FJ_LOG")" "actions/runs?head_sha=$sha&limit=50&page=1" || { rm -rf "$T"; return 1; }
  assert_fails forge_run_list "$T" widget --sha f77c249 2>/dev/null || { rm -rf "$T"; return 1; }
  out="$(cd "$T" && cmd_forge run list widget --sha "$sha")" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "run 9  failure  desktop.yml  main" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "(web #3)" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "  job 15  failure  build · test · headless snapshot" || { rm -rf "$T"; return 1; }
  _json_eq "$(forge_run_resolve "$T" widget http://forgejo.internal/geoff/gizmo/actions/runs/3/jobs/0)" '{"run_id":9,"job_id":15}' || { rm -rf "$T"; return 1; }
  _json_eq "$(forge_run_resolve "$T" widget /geoff/gizmo/actions/runs/3)" '{"run_id":9,"job_id":null}' || { rm -rf "$T"; return 1; }
  assert_eq "$(cd "$T" && cmd_forge run logs widget http://forgejo.internal/geoff/gizmo/actions/runs/3/jobs/0/attempt/1 --tail 1)" "Job 'build · test · headless snapshot' failed" || { rm -rf "$T"; return 1; }
  assert_contains "$(cd "$T" && cmd_forge run view widget http://forgejo.internal/geoff/gizmo/actions/runs/3)" "run 9 failure" || { rm -rf "$T"; return 1; }
  for out in http://forgejo.internal/geoff/gizmo/actions/runs/99 http://forgejo.internal/geoff/gizmo/actions/runs/3/jobs/4 \
             http://forgejo.internal/geoff/other/actions/runs/3 'task 52'; do
    ( cd "$T" && cmd_forge run logs widget "$out" ) >/dev/null 2>"$T/err" && { echo "mapped $out"; rm -rf "$T"; return 1; }
    assert_contains "$(cat "$T/err")" "--sha <head>" || { echo "$out: $(cat "$T/err")"; rm -rf "$T"; return 1; }
  done
  ( cd "$T" && cmd_forge run logs widget http://forgejo.internal/geoff/gizmo/actions/runs/3 ) >/dev/null 2>"$T/err" && { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/err")" "a run's page, not a job's" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  forge_run_list "$T" widget --sha 2c2d05c1e6971f10381ce76ed268ab19fca851f6 >/dev/null || { rm -rf "$T"; return 1; }
  assert_contains "$(grep '^run list' "$GH_LOG")" "--commit 2c2d05c1e6971f10381ce76ed268ab19fca851f6" || { rm -rf "$T"; return 1; }
  _json_eq "$(forge_run_resolve "$T" widget https://github.com/acme/widget/actions/runs/42414804133/job/128530529824)" '{"run_id":42414804133,"job_id":128530529824}' || { rm -rf "$T"; return 1; }
  assert_fails forge_run_resolve "$T" widget https://github.com/other/repo/actions/runs/1 2>/dev/null || { rm -rf "$T"; return 1; }
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

# A plain-http forge says, for every request that sends its token, that the
# token is crossing the network unencrypted; an https one says nothing.
test_forgejo_over_plain_http_warns_that_the_token_is_unencrypted() {
  _fj_ws
  forge_whoami "$T" widget >/dev/null 2>"$T/err" || { cat "$T/err"; rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/err")" "forge: token sent unencrypted to forgejo.internal - plain http is declared for this repo" || { rm -rf "$T"; return 1; }
  forge_pr_view "$T" widget 31 >/dev/null 2>"$T/err" || { rm -rf "$T"; return 1; }
  assert_eq "$(grep -c 'token sent unencrypted' "$T/err")" 1 || { rm -rf "$T"; return 1; }
  rm -rf "$T"
  # No token on disk: nothing is sent, so nothing is said to have been sent.
  _fj_ws
  rm -f "$(_forge_forgejo_token_path forgejo.internal)"
  forge_whoami "$T" widget >/dev/null 2>"$T/err" && { echo "succeeded without a token"; rm -rf "$T"; return 1; }
  if grep -q 'unencrypted' "$T/err"; then echo "warned before any request was sent"; rm -rf "$T"; return 1; fi
  assert_contains "$(cat "$T/err")" "no Forgejo API token" || { rm -rf "$T"; return 1; }
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
