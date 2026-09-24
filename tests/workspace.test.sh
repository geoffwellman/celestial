# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/workspace.sh"
WSA="$CEL_ROOT/tests/fixtures/ws-alpha"

test_ws_scalars() {
  assert_eq "$(ws_name "$WSA")" "alpha"
  assert_eq "$(ws_kind "$WSA")" "hustle"
  assert_eq "$(ws_org "$WSA")" "someone"
}
test_ws_ticket_and_policy() {
  assert_eq "$(ws_ticket "$WSA" system)" "none"
  assert_eq "$(ws_policy "$WSA" merge)" "humans-only"
  assert_eq "$(ws_policy "$WSA" reviewer)" ""
}
test_ws_runtime_reads_and_defaults() {
  assert_eq "$(ws_runtime "$WSA" worker)" "omp"
  local tmp; tmp="$(mktemp -d)"; printf 'name: bare\n' > "$tmp/workspace.yaml"
  assert_eq "$(ws_runtime "$tmp" worker)" "omp"
  assert_eq "$(ws_runtime "$tmp" root)" "claude"
  rm -rf "$tmp"
}
test_ws_repos() {
  assert_eq "$(ws_repo_names "$WSA")" "widget"
  assert_eq "$(ws_repo_get "$WSA" widget gate)" "bun test"
  assert_eq "$(ws_repo_get "$WSA" widget nope)" ""
}
test_ws_current_walks_up() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/repos/deep/er"; printf 'name: t\n' > "$tmp/workspace.yaml"
  assert_eq "$(ws_current "$tmp/repos/deep/er")" "$tmp"
  assert_fails ws_current /
  rm -rf "$tmp"
}
# env: values must survive an eval unmangled - spaces, quotes and all - and
# env.local is sourced last so local secrets override the committed map.
test_ws_env_exports_are_eval_safe() {
  local tmp; tmp="$(mktemp -d)"
  printf 'name: t\nenv:\n  FOO: bar baz\n  TOKEN: "it'"'"'s"\n' > "$tmp/workspace.yaml"
  local out; out="$(ws_env_exports "$tmp")"
  assert_contains "$out" "export FOO='bar baz'"
  assert_eq "$(bash -c "eval \"$out\"; printf '%s' \"\$TOKEN\"")" "it's"
  rm -rf "$tmp"
}
test_ws_env_skips_illegal_names_and_sources_env_local() {
  local tmp; tmp="$(mktemp -d)"
  printf 'name: t\nenv:\n  "BAD-NAME": x\n' > "$tmp/workspace.yaml"
  printf 'export LOCAL_ONLY=1\n' > "$tmp/env.local"
  local out; out="$(ws_env_exports "$tmp" 2>/dev/null)"
  ! printf '%s' "$out" | grep -q 'BAD-NAME' || { echo "illegal name exported"; return 1; }
  assert_eq "$(bash -c "eval \"$out\"; printf '%s' \"\$LOCAL_ONLY\"")" "1"
  rm -rf "$tmp"
}
test_ws_env_is_empty_when_nothing_declared() {
  local tmp; tmp="$(mktemp -d)"; printf 'name: t\n' > "$tmp/workspace.yaml"
  assert_eq "$(ws_env_exports "$tmp")" ""
  rm -rf "$tmp"
}
test_ws_policy_block_carries_the_rules() {
  local b; b="$(ws_policy_block "$WSA")"
  assert_contains "$b" "humans-only"
  assert_contains "$b" "never invent ticket references"
  assert_contains "$b" "worker runtime: omp"
  assert_contains "$b" "never start workers on the orchestrator runtime"
  assert_contains "$b" "widget"
  assert_contains "$b" "bun test"
}
# The review: block is optional; when present the policy block tells the
# orchestrator to start reviewer panes, and when absent it says nothing.
test_ws_policy_block_renders_review_instruction_only_when_declared() {
  ! printf '%s' "$(ws_policy_block "$WSA")" | grep -q 'cel run reviewer' \
    || { echo "review line rendered with no review block"; return 1; }
  local tmp; tmp="$(mktemp -d)"
  cp "$WSA/workspace.yaml" "$tmp/"
  printf 'review:\n  runtime: omp\n  model: gpt-5.6-sol\n' >> "$tmp/workspace.yaml"
  assert_eq "$(ws_review "$tmp" runtime)" "omp"
  local b; b="$(ws_policy_block "$tmp")"
  assert_contains "$b" 'cel run reviewer --repo <repo> --pr <n>'
  assert_contains "$b" 'omp model gpt-5.6-sol'
  assert_contains "$b" 'PR reviewer'
  rm -rf "$tmp"
}
# Where a reviewer's verdict goes. On a repo whose only GitHub identity is the
# owner's, a posted review is the owner reviewing his own PR - so the default
# is the inbox and GitHub is opt-in, decided in ONE place.
test_ws_review_post_defaults_to_inbox() {
  local tmp; tmp="$(mktemp -d)"; printf 'name: t\n' > "$tmp/workspace.yaml"
  assert_eq "$(ws_review_post "$tmp")" "inbox"
  printf 'review:\n  runtime: omp\n' >> "$tmp/workspace.yaml"
  assert_eq "$(ws_review_post "$tmp")" "inbox"
  printf '  post: github\n' >> "$tmp/workspace.yaml"
  assert_eq "$(ws_review_post "$tmp")" "github"
  rm -rf "$tmp"
}
test_ws_policy_block_review_line_follows_review_post() {
  local tmp; tmp="$(mktemp -d)"
  cp "$WSA/workspace.yaml" "$tmp/"
  printf 'review:\n  runtime: omp\n  model: gpt-5.6-sol\n' >> "$tmp/workspace.yaml"
  local b; b="$(ws_policy_block "$tmp")"
  assert_contains "$b" 'cel-fanout review <id>'
  assert_contains "$b" 'GitHub is **not** posted to'
  printf '  post: github\n' >> "$tmp/workspace.yaml"
  b="$(ws_policy_block "$tmp")"
  assert_contains "$b" 'posted as a GitHub review'
  ! printf '%s' "$b" | grep -q 'GitHub is \*\*not\*\* posted to' \
    || { echo "inbox wording rendered for post: github"; return 1; }
  rm -rf "$tmp"
}
# The role file must never tell a reviewer to post unconditionally; posting is
# the policy block's call.
test_pr_reviewer_role_does_not_post_to_github_unconditionally() {
  local f="$CEL_ROOT/core/roles/pr-reviewer.md"
  ! grep -qi 'submits a real GitHub review' "$f" \
    || { echo "role still promises a GitHub review"; return 1; }
  ! grep -qE '^[0-9]+\. Submit ONE review per round: `gh pr review' "$f" \
    || { echo "role posts a GitHub review unconditionally"; return 1; }
  assert_contains "$(cat "$f")" 'cel-fanout review <id>'
  assert_contains "$(cat "$f")" 'post: github'
}
test_ws_render_role_appends_policy() {
  local out; out="$(ws_render_role "$WSA" "$CEL_ROOT/core/roles/worker.md")"
  assert_contains "$out" "one ticket and one worktree"
  assert_contains "$out" "Workspace policy"
}
test_ws_render_claude_block_is_idempotent() {
  local tmp; tmp="$(mktemp -d)"
  printf '# my repo\nhand-written\n' > "$tmp/CLAUDE.md"
  ws_render_claude_block "$WSA" "$tmp"
  assert_contains "$(cat "$tmp/CLAUDE.md")" "cel:policy:begin"
  assert_contains "$(cat "$tmp/CLAUDE.md")" "hand-written"
  ws_render_claude_block "$WSA" "$tmp"
  assert_eq "$(grep -c 'cel:policy:begin' "$tmp/CLAUDE.md")" "1"
  rm -rf "$tmp"
}
# Deleting a workspace skill must delete its repo links on the next sync -
# a dangling link shadows the plane skill of the same name. Links pointing
# anywhere else are not ours and stay, dangling or not.
test_ws_link_skills_prunes_dangling_workspace_links() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/ws/skills/deploy" "$tmp/repo"
  printf -- '---\nname: deploy\n---\n' > "$tmp/ws/skills/deploy/SKILL.md"
  printf 'name: t\n' > "$tmp/ws/workspace.yaml"
  ws_link_skills "$tmp/ws" "$tmp/repo"
  ln -s "$tmp/nowhere-else" "$tmp/repo/.claude/skills/foreign"
  rm -rf "$tmp/ws/skills/deploy"
  ws_link_skills "$tmp/ws" "$tmp/repo"
  [ ! -e "$tmp/repo/.claude/skills/deploy" ] && [ ! -L "$tmp/repo/.claude/skills/deploy" ] \
    || { echo "dangling workspace link survived"; return 1; }
  [ -L "$tmp/repo/.claude/skills/foreign" ] || { echo "foreign link wrongly pruned"; return 1; }
  rm -rf "$tmp"
}
test_ws_link_skills_links_and_gitignores() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/ws/skills/deploy" "$tmp/repo"
  printf -- '---\nname: deploy\n---\n' > "$tmp/ws/skills/deploy/SKILL.md"
  printf 'name: t\n' > "$tmp/ws/workspace.yaml"
  ws_link_skills "$tmp/ws" "$tmp/repo"
  [ -L "$tmp/repo/.claude/skills/deploy" ]
  assert_contains "$(cat "$tmp/repo/.gitignore")" ".claude/skills"
  ws_link_skills "$tmp/ws" "$tmp/repo"
  assert_eq "$(grep -c '.claude/skills' "$tmp/repo/.gitignore")" "1"
  rm -rf "$tmp"
}

# Linear workspaces get the lifecycle instructions and per-repo team keys in
# the policy block; non-linear workspaces get none of it.
test_ws_policy_block_renders_linear_wiring() {
  local tmp; tmp="$(mktemp -d)"
  cp "$WSA/workspace.yaml" "$tmp/"
  python3 - "$tmp/workspace.yaml" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=s.replace('system: none','system: linear')
s=s.replace('gate: bun test','gate: bun test\n    linear_team: WID')
open(p,'w').write(s)
PY
  local b; b="$(ws_policy_block "$tmp")"
  assert_contains "$b" "tickets: linear"
  assert_contains "$b" "In Review"
  assert_contains "$b" "SEARCH BEFORE CREATE"
  # The branch-name rule is the load-bearing one: Linear links a PR to its
  # ticket from the branch name alone, so an agent that never reads this ships
  # work the board cannot see.
  assert_contains "$b" "THE BRANCH NAME CARRIES THE TICKET ID"
  assert_contains "$b" "linear team WID"
  ! printf '%s' "$(ws_policy_block "$WSA")" | grep -q 'linear' \
    || { echo "linear wiring leaked into a none-ticket workspace"; return 1; }
  rm -rf "$tmp"
}

# Profiles carry a `for:` so the orchestrator can choose per ticket; the
# policy block is where it learns them, and scouts are named there too.
test_ws_policy_block_lists_profile_purposes_and_scouts() {
  local tmp; tmp="$(mktemp -d)"
  cp "$WSA/workspace.yaml" "$tmp/"
  printf 'worker_profiles:\n  fast: { runtime: omp, model: m, for: "small well-specified fixes" }\n' >> "$tmp/workspace.yaml"
  local b; b="$(ws_policy_block "$tmp")"
  assert_contains "$b" "fast: small well-specified fixes"
  assert_contains "$b" "cel-fanout scout"
  assert_contains "$b" "--because"
  ! printf '%s' "$b" | grep -q "scouts run on profile" || { echo "unbound scout claimed a profile"; rm -rf "$tmp"; return 1; }
  # Bind one and the orchestrator is told not to pass --profile itself.
  printf 'role_profiles: { scout: fast }\n' >> "$tmp/workspace.yaml"
  b="$(ws_policy_block "$tmp")"
  assert_contains "$b" "scouts run on profile fast automatically"
  rm -rf "$tmp"
}

# --- products: the 1..n-repo unit an orchestrator owns ---------------------
# ws-products declares `bundle` over widget+gadget and leaves `lone` out of
# it. An undeclared repo is its own implicit product, in place - that is what
# keeps every workspace written before products behave exactly as before.
WSP="$CEL_ROOT/tests/fixtures/ws-products"

test_ws_product_names_lists_declared_then_implicit() {
  assert_eq "$(ws_product_names "$WSP")" "$(printf 'bundle\nlone')"
  # A workspace with no products: block is all implicit, in repos order.
  assert_eq "$(ws_product_names "$WSA")" "widget"
}
test_ws_product_repos_of_declared_and_implicit() {
  assert_eq "$(ws_product_repos "$WSP" bundle)" "$(printf 'widget\ngadget')"
  assert_eq "$(ws_product_repos "$WSP" lone)" "lone"
}
test_ws_product_of_repo_both_ways() {
  assert_eq "$(ws_product_of_repo "$WSP" widget)" "bundle"
  assert_eq "$(ws_product_of_repo "$WSP" gadget)" "bundle"
  assert_eq "$(ws_product_of_repo "$WSP" lone)" "lone"
  # An unknown repo is its own answer rather than an error: callers use this
  # to name a cwd, and dying there would be worse than naming the repo.
  assert_eq "$(ws_product_of_repo "$WSP" nosuch)" "nosuch"
}
test_ws_product_declared_exit_codes() {
  ws_product_declared "$WSP" bundle || { echo "declared product read as implicit"; return 1; }
  assert_fails ws_product_declared "$WSP" lone
  assert_fails ws_product_declared "$WSP" nosuch
}
test_ws_product_get_reads_keys_and_never_fails() {
  assert_eq "$(ws_product_get "$WSP" bundle workers)" "2"
  assert_eq "$(ws_product_get "$WSP" bundle orchestrator)" "auto"
  assert_eq "$(ws_product_get "$WSP" bundle nosuchkey)" ""
  assert_eq "$(ws_product_get "$WSP" lone workers)" ""
}
test_ws_product_dir_declared_vs_implicit() {
  assert_eq "$(ws_product_dir "$WSP" bundle)" "$WSP/products/bundle"
  assert_eq "$(ws_product_dir "$WSP" lone)" "$WSP/repos/lone"
}
# With a product the orchestrator is told the cross-repo hop is its own; with
# no product the block must be what it has always been, byte for byte.
test_ws_policy_block_names_the_product_only_when_given_one() {
  local b; b="$(ws_policy_block "$WSP" bundle)"
  assert_contains "$b" "- product: bundle (repos: widget, gadget) - cross-repo sequencing inside this product is yours; there is no tier above you for it"
  assert_contains "$b" "- repo widget: branch prefix WG"
  assert_eq "$(ws_policy_block "$WSP")" "$(ws_policy_block "$WSP" "")"
  ! printf '%s' "$(ws_policy_block "$WSP")" | grep -q '^- product:' \
    || { echo "product line rendered with no product"; return 1; }
}
test_ws_render_role_passes_the_product_through() {
  local out; out="$(ws_render_role "$WSP" "$CEL_ROOT/core/roles/project-orchestrator.md" bundle)"
  assert_contains "$out" "- product: bundle (repos: widget, gadget)"
  out="$(ws_render_role "$WSP" "$CEL_ROOT/core/roles/project-orchestrator.md")"
  ! printf '%s' "$out" | grep -q '^- product:' || { echo "product line with no product"; return 1; }
}

# SEED: the gitignored local files a worktree needs to run at all. A plain
# string is a symlink (the common case - one keys file); a mapping with
# `copy: true` is copied, for the things a symlink cannot stand in for (a
# built directory a bundler rewrites in place).
test_ws_repo_seed_reads_plain_and_mapping_entries() {
  local tmp; tmp="$(mktemp -d)"
  printf 'name: t\nrepos:\n  - name: widget\n    seed:\n      - apps/builder/.dev.vars\n      - { path: apps/pf/src/wasm, copy: true }\n      - { path: apps/pf/other }\n' > "$tmp/workspace.yaml"
  local out; out="$(ws_repo_seed "$tmp" widget)"
  assert_eq "$out" "$(printf 'apps/builder/.dev.vars\tlink\napps/pf/src/wasm\tcopy\napps/pf/other\tlink')"
  rm -rf "$tmp"
}
test_ws_repo_seed_is_empty_when_absent() {
  assert_eq "$(ws_repo_seed "$WSA" widget)" ""
  assert_eq "$(ws_repo_seed "$WSA" nosuch)" ""
}
test_ws_repo_preview_reads_cmd_url_and_env() {
  local tmp; tmp="$(mktemp -d)"
  printf 'name: t\nrepos:\n  - name: widget\n    preview:\n      cmd: "pnpm --filter builder dev"\n      env: { API_PORT: "{port}", UI_PORT: "{port+1}" }\n      url: "http://localhost:{port+1}"\n' > "$tmp/workspace.yaml"
  assert_eq "$(ws_repo_preview "$tmp" widget cmd)" "pnpm --filter builder dev"
  assert_eq "$(ws_repo_preview "$tmp" widget url)" "http://localhost:{port+1}"
  local env; env="$(ws_repo_preview_env "$tmp" widget)"
  assert_contains "$env" "API_PORT={port}"
  assert_contains "$env" "UI_PORT={port+1}"
  rm -rf "$tmp"
}
test_ws_repo_preview_is_empty_without_a_preview_block() {
  assert_eq "$(ws_repo_preview "$WSA" widget cmd)" ""
  assert_eq "$(ws_repo_preview "$WSA" widget url)" ""
  assert_eq "$(ws_repo_preview_env "$WSA" widget)" ""
}

# The role says in one line what the guard and the binary now enforce.
test_worker_role_forbids_landing() {
  local out; out="$(ws_render_role "$WSA" "$CEL_ROOT/core/roles/worker.md")"
  assert_contains "$out" "Land, release, collect or delegate"
}

# RELEASE DECLARATIONS. A repo says how it is released - which workflow file,
# which dispatch input, what values that input accepts - because the four
# products on a box release four different ways and the plane must not own any
# of those semantics. A repo with no `release:` block is simply not releasable,
# and saying so is the whole point: before this, `cel release` assumed every
# repo was celestial and handed a 403 to anyone else.
_ws_release_fixture() { # -> $tmp with a workspace declaring three shapes
  local tmp; tmp="$(mktemp -d)"
  cat >"$tmp/workspace.yaml" <<'EOS'
name: alpha
repos:
  - name: widget
    url: git@github.com:someone/widget.git
    release:
      workflow: release.yml
      input: version
      accepts: semver
      version_file: VERSION
      changelog: changelog.d/
      tag: "v{version}"
  - name: gizmo
    url: git@github.com:someone/gizmo.git
    release:
      workflow: release.yaml
      input: bump
      accepts: [major, minor, patch]
  - name: plain
    url: git@github.com:someone/plain.git
EOS
  printf '%s' "$tmp"
}

test_ws_repo_release_reads_every_declared_key() {
  local tmp; tmp="$(_ws_release_fixture)"
  assert_eq "$(ws_repo_release "$tmp" widget workflow)" "release.yml" || { rm -rf "$tmp"; return 1; }
  assert_eq "$(ws_repo_release "$tmp" widget input)" "version" || { rm -rf "$tmp"; return 1; }
  assert_eq "$(ws_repo_release "$tmp" widget accepts)" "semver" || { rm -rf "$tmp"; return 1; }
  assert_eq "$(ws_repo_release "$tmp" widget version_file)" "VERSION" || { rm -rf "$tmp"; return 1; }
  assert_eq "$(ws_repo_release "$tmp" widget tag)" "v{version}" || { rm -rf "$tmp"; return 1; }
  # a list of accepted words comes back space separated, so `case` and `for`
  # both work on it without the caller learning jq
  assert_eq "$(ws_repo_release "$tmp" gizmo accepts)" "major minor patch" || { rm -rf "$tmp"; return 1; }
  assert_eq "$(ws_repo_release "$tmp" gizmo version_file)" "" || { rm -rf "$tmp"; return 1; }
  assert_eq "$(ws_repo_release "$tmp" plain workflow)" "" || { rm -rf "$tmp"; return 1; }
  assert_eq "$(ws_repo_release "$tmp" nosuch workflow)" "" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

test_ws_repo_releasable_needs_a_workflow() {
  local tmp; tmp="$(_ws_release_fixture)"
  ws_repo_releasable "$tmp" widget || { rm -rf "$tmp"; return 1; }
  ws_repo_releasable "$tmp" gizmo || { rm -rf "$tmp"; return 1; }
  assert_fails ws_repo_releasable "$tmp" plain || { rm -rf "$tmp"; return 1; }
  assert_fails ws_repo_releasable "$tmp" nosuch || { rm -rf "$tmp"; return 1; }
  # a block without a workflow names nothing to dispatch, so it is not a
  # release declaration however much else it carries
  printf '  - name: half\n    release:\n      input: version\n' >> "$tmp/workspace.yaml"
  assert_fails ws_repo_releasable "$tmp" half || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

# ---- CEL-70: a workspace acts as its own GitHub account -------------------
# gh's ACTIVE account is box-global; a workspace naming `github.user` must get
# that account per process (GH_TOKEN) and never move the global one.
_gh_acct_fixture() { # [github-block-yaml]
  T="$(mktemp -d)"
  cp "$WSA/workspace.yaml" "$T/workspace.yaml"
  [ -z "${1:-}" ] || printf '%s\n' "$1" >> "$T/workspace.yaml"
  mkdir -p "$T/bin"; GH_LOG="$T/gh.log"; : > "$GH_LOG"; export GH_LOG
  cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|GH_TOKEN=%s\n' "$*" "${GH_TOKEN-<unset>}" >> "$GH_LOG"
if [ "$1 $2" = "auth token" ]; then
  case "$4" in acct-a) echo tok-a ;; acct-b) echo tok-b ;;
    *) echo "no oauth token found for github.com account $4" >&2; exit 1 ;; esac
  exit 0
fi
echo '[]'
SH
  chmod +x "$T/bin/gh"
}
test_github_block_absent_resolves_empty() {
  assert_eq "$(ws_github_user "$WSA")" ""
  assert_eq "$(ws_github_ssh_host "$WSA")" ""
}
test_github_block_resolves_user_and_ssh_host() {
  _gh_acct_fixture $'github:\n  user: acct-b\n  ssh_host: github-acct-b'
  assert_eq "$(ws_github_user "$T")" "acct-b"
  assert_eq "$(ws_github_ssh_host "$T")" "github-acct-b"
  rm -rf "$T"
}
test_ws_gh_without_a_block_is_todays_call() {
  _gh_acct_fixture
  PATH="$T/bin:$PATH" ws_gh "$T" pr list --repo o/r >/dev/null
  assert_eq "$(cat "$GH_LOG")" "pr list --repo o/r|GH_TOKEN=<unset>"
  rm -rf "$T"
}
test_ws_gh_with_a_user_carries_that_token_for_that_call_only() {
  _gh_acct_fixture $'github:\n  user: acct-b'
  PATH="$T/bin:$PATH" ws_gh "$T" pr list --repo o/r >/dev/null
  assert_contains "$(cat "$GH_LOG")" "pr list --repo o/r|GH_TOKEN=tok-b"
  assert_eq "${GH_TOKEN-<unset>}" "<unset>"
  rm -rf "$T"
}
test_ws_gh_refuses_when_the_user_is_not_logged_in() {
  _gh_acct_fixture $'github:\n  user: acct-z'
  local out; out="$(PATH="$T/bin:$PATH" ws_gh "$T" pr list --repo o/r 2>&1)" && {
    echo "ws_gh ran for an account that is not logged in"; rm -rf "$T"; return 1; }
  assert_contains "$out" "gh auth login"
  assert_contains "$out" "gh auth status"
  if grep -q '^pr list' "$GH_LOG"; then echo "fell back to the active account"; rm -rf "$T"; return 1; fi
  rm -rf "$T"
}
# The declared alias is accepted as that EXACT host and nothing else: a
# `github-*` pattern would let any lookalike alias name a GitHub slug.
test_github_slug_from_url_maps_the_declared_ssh_alias_exactly() {
  assert_eq "$(github_slug_from_url git@github-acct-b:o/r.git github-acct-b)" "o/r"
  assert_eq "$(github_slug_from_url git@github.com:o/r.git github-acct-b)" "o/r"
  assert_fails github_slug_from_url git@github-acct-b:o/r.git
  assert_fails github_slug_from_url git@github-acct-bx:o/r.git github-acct-b
  assert_fails github_slug_from_url git@xgithub-acct-b:o/r.git github-acct-b
  assert_fails github_slug_from_url git@github-evil:o/r.git github-acct-b
}
test_repo_slug_uses_the_workspaces_declared_alias() {
  _gh_acct_fixture $'github:\n  user: acct-b\n  ssh_host: github-acct-b'
  mkdir -p "$T/repos/widget"; git -C "$T/repos/widget" init -q
  git -C "$T/repos/widget" remote add origin git@github-acct-b:someone/widget.git
  yq -y '.repos[0].url = null' "$T/workspace.yaml" > "$T/w" && mv "$T/w" "$T/workspace.yaml"
  assert_eq "$(ws_repo_github_slug "$T" widget "$T/repos/widget")" "someone/widget"
  rm -rf "$T"
}
test_ws_github_clone_url_uses_the_alias() {
  _gh_acct_fixture $'github:\n  user: acct-b\n  ssh_host: github-acct-b'
  assert_eq "$(ws_github_clone_url "$T" git@github.com:someone/widget.git)" "git@github-acct-b:someone/widget.git"
  rm -rf "$T"
  assert_eq "$(ws_github_clone_url "$WSA" git@github.com:someone/widget.git)" "git@github.com:someone/widget.git"
}
# Nothing in the plane may move the box-global active account.
test_nothing_calls_gh_auth_switch() {
  local hits
  hits="$(grep -rnE 'gh"? auth switch|GH"? auth switch' "$CEL_ROOT/lib" "$CEL_ROOT/bin" "$CEL_ROOT/core/skills" \
          | grep -vE ':[0-9]+:\s*#' || true)"
  assert_eq "$hits" ""
}
