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
