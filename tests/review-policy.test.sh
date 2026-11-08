# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/review-policy.sh"

# A workspace whose policy requires a security reviewer everywhere and a
# db-migration reviewer for widget; gadget declares none of its own.
_rp_ws() {
  T="$(mktemp -d)"
  cat > "$T/workspace.yaml" <<'YAML'
name: rp
review:
  model: sonnet
  extra:
    - focus: security
      paths: ['lib/auth/**', '**/*token*']
repos:
  - name: widget
    url: git@github.com:acme/widget.git
    review:
      extra:
        - focus: db-migration
          paths: ['migrations/**']
        - focus: security
          kind: review
          paths: ['api/**']
  - name: gadget
    url: git@github.com:acme/gadget.git
YAML
}
_match() { # <globs-json> <files-json> -> the matching files, comma-joined
  jq -nr --argjson p "$1" --argjson f "$2" "$_REVIEW_JQ_GLOB"'
    [$f[] | . as $x | select(any($p[]; . as $g | $x | test($g | review_glob_re)))] | join(",")'
}

# THE GLOB SEMANTICS: `*` and `?` stay inside one segment, `**` as a whole
# segment spans any number of directories (zero included), a glob matches
# the whole path, and everything else is literal.
test_review_globs_match_whole_paths_and_double_star_crosses_directories() {
  local files='["token.sh","lib/token.ts","a/b/api_token.ts","lib/auth","lib/auth/login.ts","lib/auth/x/y/z.sh","lib/authx/a.sh",
    "migrations/001.sql","migrations","src/a.ts","src/ab.ts","src/x/a.ts","docs/a.b/c.md","docs/aXb/c.md"]'
  assert_eq "$(_match '["**/*token*"]' "$files")" "token.sh,lib/token.ts,a/b/api_token.ts"
  assert_eq "$(_match '["lib/auth/**"]' "$files")" "lib/auth/login.ts,lib/auth/x/y/z.sh"
  assert_eq "$(_match '["lib/auth"]' "$files")" "lib/auth"
  assert_eq "$(_match '["migrations/**"]' "$files")" "migrations/001.sql"
  assert_eq "$(_match '["src/*.ts"]' "$files")" "src/a.ts,src/ab.ts"
  assert_eq "$(_match '["src/?.ts"]' "$files")" "src/a.ts"
  assert_eq "$(_match '["src/**/a.ts"]' "$files")" "src/a.ts,src/x/a.ts"
  # `.` is a dot, not any character
  assert_eq "$(_match '["docs/a.b/*"]' "$files")" "docs/a.b/c.md"
  assert_eq "$(_match '["**"]' '["a","b/c"]')" "a,b/c"
}

# What matched, and why, travels with each required reviewer.
test_review_extra_match_says_which_file_and_glob_required_it() {
  local es='[{"kind":"review","focus":"security","slot":"review-security","paths":["lib/auth/**"]},
             {"kind":"review","focus":"db-migration","slot":"review-db-migration","paths":["migrations/**"]}]'
  local got; got="$(review_extra_match "$es" '["README.md","lib/auth/a.ts","lib/auth/b.ts"]')"
  assert_eq "$(jq -c '[.[] | [.focus, .because.file, .because.glob, .files]]' <<<"$got")" '[["security","lib/auth/a.ts","lib/auth/**",2]]'
  assert_eq "$(review_extra_why "$(jq -c '.[0]' <<<"$got")")" 'review.extra: lib/auth/a.ts matches "lib/auth/**" (2 files match)'
}

# The workspace-wide list and the repo's own, one entry per focus with their
# paths joined; a repo without its own gets the workspace-wide ones.
test_review_extra_entries_join_the_workspace_and_repo_lists() {
  _rp_ws
  assert_eq "$(review_extra_entries "$T" widget | jq -c 'map([.slot, .paths])')" \
    '[["review-db-migration",["migrations/**"]],["review-security",["**/*token*","api/**","lib/auth/**"]]]' || { rm -rf "$T"; return 1; }
  assert_eq "$(review_extra_entries "$T" gadget | jq -c 'map(.focus)')" '["security"]' || { rm -rf "$T"; return 1; }
  printf 'name: none\nreview:\n  model: sonnet\n' > "$T/workspace.yaml"
  assert_eq "$(review_extra_entries "$T" widget)" '[]' || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A malformed entry is refused, never skipped: a typo must not quietly drop
# a required review.
test_review_extra_entries_refuse_a_malformed_policy() {
  _rp_ws
  local bad out
  for bad in \
    "  extra:\n    - focus: speed\n      paths: [a]|no reviewer focus 'speed' - have: db-migration performance security" \
    "  extra:\n    - focus: security\n      path: [a]|unknown key(s) path" \
    "  extra:\n    - focus: security\n      kind: qa\n      paths: [a]|kind \"qa\" is not a kind of reviewer there is" \
    "  extra:\n    - focus: security\n      paths: []|focus security needs paths" \
    "  extra:\n    - focus: security\n      paths: [/etc/x, 'a//b', '../x']|not a repo-relative glob" \
    "  extra:\n    - paths: [a]|an entry needs a focus" \
    "  extra: security|an entry must be a map"; do
    printf 'name: bad\nreview:\n%b\n' "${bad%%|*}" > "$T/workspace.yaml"
    out="$(review_extra_entries "$T" widget 2>&1)" && { echo "accepted: ${bad%%|*} -> $out"; rm -rf "$T"; return 1; }
    assert_contains "$out" "${bad#*|}" || { rm -rf "$T"; return 1; }
  done
  rm -rf "$T"
}

# THE POLICY IS NOT A LOCAL SETTING: workspace.local.yaml may override
# role_profiles, worker_profiles and env, and nothing it says about review -
# workspace-wide or on a repo entry - adds or drops an extra reviewer.
test_review_extra_cannot_be_changed_by_a_local_override() {
  _rp_ws
  local before; before="$(review_extra_entries "$T" widget)"
  cat > "$T/workspace.local.yaml" <<'YAML'
review:
  extra:
    - focus: performance
      paths: ['**']
repos:
  - name: widget
    review:
      extra: []
YAML
  assert_eq "$(review_extra_entries "$T" widget)" "$before" || { rm -rf "$T"; return 1; }
  printf 'review: { extra: [] }\n' > "$T/workspace.local.yaml"
  assert_eq "$(review_extra_entries "$T" widget)" "$before" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A repo whose policy names no extra reviewer asks the forge nothing.
test_review_extra_required_asks_the_forge_only_when_the_policy_names_one() {
  _rp_ws
  printf 'name: none\nreview:\n  model: sonnet\nrepos:\n  - name: widget\n    url: git@github.com:acme/widget.git\n' > "$T/workspace.yaml"
  forge_pr_files() { : > "$T/asked"; printf '{"files":[]}'; }
  assert_eq "$(review_extra_required "$T" widget 7)" '[]' || { rm -rf "$T"; return 1; }
  [ ! -e "$T/asked" ] || { echo "asked the forge with no policy"; rm -rf "$T"; return 1; }
  rm -rf "$T"; _rp_ws
  forge_pr_files() { printf '{"files":["migrations/002.sql","src/x.ts"]}'; }
  assert_eq "$(review_extra_required "$T" widget 7 | jq -c 'map(.focus)')" '["db-migration"]' || { rm -rf "$T"; return 1; }
  forge_pr_files() { return 1; }
  ! review_extra_required "$T" widget 7 >/dev/null 2>&1 || { echo "an unreadable file list read as none"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Names: each focus reviewer answers to its own alias, and a focus whose
# alias would be cut into another reviewer's is refused.
test_review_aliases_are_distinct_or_refused() {
  assert_eq "$(review_alias widget 7)" widget-pr-7-review
  assert_eq "$(review_alias widget 7 security)" widget-pr-7-review-security
  assert_eq "$(review_alias celestial 277 db-migration)" celestial-pr-277-review-db-migra
  review_alias_free celestial 277 db-migration >/dev/null || return 1
  local why; why="$(review_alias_free a-long-repository-name 12345 security)" && { echo "a cut alias was free"; return 1; }
  assert_contains "$why" "is the plain reviewer's (names are cut to 32 characters)"
  assert_eq "$(review_focus_names | paste -sd' ' -)" "db-migration performance security"
}
