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

# Only GitHub's own "Branch not protected" says the branch gates nothing; a
# protection read that is refused is unknown, never unprotected.
test_forge_pr_checks_tells_unprotected_from_unknown() {
  _forge_ws git@github.com:acme/widget.git; _forge_gh_stub
  assert_eq "$(STUB_PROTECTION=none forge_pr_checks "$T" widget 12 | jq -c '[.protection, .required]')" '["unprotected",[]]' || { rm -rf "$T"; return 1; }
  assert_eq "$(STUB_PROTECTION=denied forge_pr_checks "$T" widget 12 | jq -c '[.protection, .required]')" '["unknown",[]]' || { rm -rf "$T"; return 1; }
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

# Forgejo has no backend yet: every operation refuses by name, says so, and
# touches no forge at all - no fake answer, no fallback to gh.
test_forge_ops_refuse_forgejo_repos_explicitly() {
  _forge_ws https://code.example.net/acme/gizmo.git forgejo; _forge_gh_stub
  local call out err
  for call in "forge_pr_view 12" "forge_pr_list open" "forge_pr_checks 12" "forge_pr_reviews 12" "forge_pr_merge 12 $H" "forge_whoami"; do
    # shellcheck disable=SC2086
    set -- $call
    local op="$1"; shift
    if out="$("$op" "$T" widget "$@" 2>"$T/err")"; then echo "$op answered for a Forgejo repo: $out"; rm -rf "$T"; return 1; fi
    err="$(cat "$T/err")"
    assert_eq "$out" "" || { rm -rf "$T"; return 1; }
    assert_contains "$err" "Forgejo backend not built yet" || { rm -rf "$T"; return 1; }
    assert_contains "$err" "code.example.net" || { rm -rf "$T"; return 1; }
  done
  assert_eq "$(cat "$GH_LOG")" "" || { echo "a Forgejo repo reached gh"; rm -rf "$T"; return 1; }
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
