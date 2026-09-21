# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/run.sh"

_ws() { T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
        mkdir -p "$T/repos/widget"; }

# cmd_run dies via die() (exit) on the failure paths below. assert_fails runs
# its argument as a plain function call in this same process, so a bare exit
# would kill the whole test invocation instead of being observed as a failing
# exit status. Route through a subshell to contain it.
_cmd_run_in_subshell() { ( cmd_run "$@" ); }

test_run_direct_defaults_single_repo_and_injects_no_role() {
  _ws; local out; out="$(cd "$T" && cmd_run --dry-run)"
  assert_contains "$out" "workspace create"
  assert_contains "$out" "widget/direct"
  assert_contains "$out" "--kind claude"
  ! printf '%s' "$out" | grep -q "root-orchestrator"
  rm -rf "$T"
}
test_run_root_targets_workspace_dir() {
  _ws; local out; out="$(cd "$T" && cmd_run root --dry-run)"
  assert_contains "$out" "alpha/root"
  assert_contains "$out" "--cwd $T"
  rm -rf "$T"
}
test_run_orchestrator_targets_repo() {
  _ws; local out; out="$(cd "$T" && cmd_run orchestrator --repo widget --dry-run)"
  assert_contains "$out" "widget/orch"
  assert_contains "$out" "--append-system-prompt"
  rm -rf "$T"
}
test_run_worker_creates_a_herdr_worktree() {
  _ws; local out; out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --dry-run)"
  assert_contains "$out" "worktree create"
  assert_contains "$out" "--kind omp"
  rm -rf "$T"
}
test_run_worker_requires_branch() {
  _ws; ( cd "$T" && assert_fails _cmd_run_in_subshell worker --repo widget --dry-run ); rm -rf "$T"
}
test_run_outside_a_workspace_dies() {
  ( cd /tmp && assert_fails _cmd_run_in_subshell --dry-run )
}
# herdr rejects agent names outside [a-z][a-z0-9_-]{0,31}: the `repo/role`
# alias keeps the slash only as the workspace label, never as the agent name.
test_run_agent_start_uses_a_herdr_legal_name() {
  _ws; local out; out="$(cd "$T" && cmd_run root --dry-run)"
  assert_contains "$out" "agent start alpha-root"
  out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --dry-run)"
  assert_contains "$out" "agent start widget-wg-1-x"
  rm -rf "$T"
}
# herdr agent start rejects any argument it cannot encode on one line
# (invalid_agent_argument), so multi-line role bodies must travel as files.
test_run_role_body_travels_as_a_file_path() {
  _ws; local out; out="$(cd "$T" && cmd_run root --dry-run)"
  assert_contains "$out" "--append-system-prompt-file $T/.cel/role-root.md"
  out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --dry-run)"
  assert_contains "$out" "--append-system-prompt $T/.cel/role-worker.md"
  rm -rf "$T"
}
test_append_flag_file_writes_the_body_and_no_arg_holds_a_newline() {
  _ws
  local AGENT_ARGS=() body=$'# Role\n\nline two' a
  _run_agent_args claude root "$body" 0 "$T"
  assert_eq "${AGENT_ARGS[0]}" "--append-system-prompt-file"
  assert_eq "${AGENT_ARGS[1]}" "$T/.cel/role-root.md"
  assert_eq "$(cat "$T/.cel/role-root.md")" "$body"
  for a in "${AGENT_ARGS[@]}"; do
    case "$a" in *$'\n'*) echo "arg contains a newline: $a"; return 1;; esac
  done
  rm -rf "$T"
}
# agents.yaml launch_args ride every launch of that runtime, ahead of the
# role-injection args - claude declares --dangerously-skip-permissions and
# omp declares --auto-approve, so nothing plane-launched stops on prompts.
# The thinking flag sits between them: it is per-launch (a profile can change
# it), the launch args are per-runtime, and the role body always goes last.
test_run_launch_args_precede_role_injection() {
  _ws; local out; out="$(cd "$T" && cmd_run root --dry-run)"
  assert_contains "$out" " -- --dangerously-skip-permissions --effort high --append-system-prompt-file"
  out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --dry-run)"
  assert_contains "$out" " -- --auto-approve --thinking high --append-system-prompt"
  ! printf '%s' "$out" | grep -q 'dangerously' || { echo "omp worker got claude launch args"; return 1; }
  rm -rf "$T"
}

# A workspace may declare a herdr workspace-manager layout; only root mode
# applies it (the whole working view), and it must come before agent start
# because apply replaces the workspace's first tab.
test_run_root_applies_declared_layout() {
  _ws
  printf 'layout: example\n' >> "$T/workspace.yaml"
  local out; out="$(cd "$T" && cmd_run root --dry-run)"
  assert_contains "$out" "herdr-workspace-manager apply example"
  out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --dry-run)"
  ! printf '%s' "$out" | grep -q "workspace-manager" || { echo "worker applied a layout"; return 1; }
  rm -rf "$T"
}
test_run_without_layout_skips_apply() {
  _ws; local out; out="$(cd "$T" && cmd_run root --dry-run)"
  ! printf '%s' "$out" | grep -q "workspace-manager" || { echo "layout applied with none declared"; return 1; }
  rm -rf "$T"
}
# Reviewer mode joins the caller's herdr view (tab "PR reviewer") instead of
# creating a workspace, injects the pr-reviewer role, and puts the workspace's
# review model ahead of the role args.
_ws_review() { _ws; printf 'review:\n  runtime: omp\n  model: gpt-5.6-sol\n' >> "$T/workspace.yaml"; }
test_run_reviewer_targets_review_tab_with_model() {
  _ws_review; local out; out="$(cd "$T" && cmd_run reviewer --repo widget --pr 12 --dry-run)"
  assert_contains "$out" 'tab "PR reviewer"'
  assert_contains "$out" "agent start widget-pr-12-review --kind omp"
  assert_contains "$out" " -- --auto-approve --model gpt-5.6-sol --thinking high --append-system-prompt"
  ! printf '%s' "$out" | grep -q "workspace create" || { echo "reviewer created a workspace"; return 1; }
  rm -rf "$T"
}
test_run_reviewer_requires_pr_and_review_block() {
  _ws_review; ( cd "$T" && assert_fails _cmd_run_in_subshell reviewer --repo widget --dry-run )
  rm -rf "$T"
  _ws; ( cd "$T" && assert_fails _cmd_run_in_subshell reviewer --repo widget --pr 12 --dry-run )
  rm -rf "$T"
}
test_run_agent_name_sanitiser() {
  assert_eq "$(_run_agent_name 'example/root')" "example-root"
  assert_eq "$(_run_agent_name 'repo/AH-260901-ws-example-demote')" "repo-ah-260901-ws-example-demote"
  assert_eq "$(_run_agent_name '9lives/x')" "lives-x"
  assert_eq "$(_run_agent_name 'a-very-long-repo-name/with-a-very-long-branch')" \
            "a-very-long-repo-name-with-a-ver"
}

# Layouts resolve workspace-first: <wsdir>/layouts.yml beats the plane file,
# the plane file is the fallback, and neither defining the id is a failure.
test_layout_config_resolves_workspace_first() {
  _ws
  printf 'layouts:\n  - id: example\n    tabs: []\n' > "$T/layouts.yml"
  assert_eq "$(_run_layout_config "$T" example)" "$T/layouts.yml"
  assert_eq "$(_run_layout_config "$T" worker)" "$CEL_ROOT/tools/herdr/layouts/config.yml"
  assert_fails _run_layout_config "$T" no-such-layout
  rm -rf "$T"
}

# READ-ONLY ORCHESTRATORS: root and orchestrator launches on a runtime that
# has a guard_hook get it; workers never do - writing is their whole job.
test_run_loads_the_guard_hook_for_orchestrators_only() {
  _ws; printf 'runtime: { root: omp, orchestrator: omp, worker: omp }\n' >> "$T/workspace.yaml"
  local out
  out="$(cd "$T" && cmd_run orchestrator --repo widget --dry-run 2>/dev/null)"
  assert_contains "$out" "--hook $CEL_ROOT/tools/hooks/orchestrator-guard.omp.ts"
  out="$(cd "$T" && cmd_run root --dry-run 2>/dev/null)"
  assert_contains "$out" "orchestrator-guard.omp.ts"
  out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --dry-run 2>/dev/null)"
  ! printf '%s' "$out" | grep -q "orchestrator-guard" || { echo "worker got the guard"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# --- products -------------------------------------------------------------
# An orchestrator owns a PRODUCT: one or more repos. `bundle` is declared over
# widget+gadget, `lone` is undeclared and therefore implicit - and an implicit
# product must launch byte-for-byte the way a repo always has.
_ws_products() {
  T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-products/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget" "$T/repos/gadget" "$T/repos/lone"
}
test_run_orchestrator_targets_a_declared_product() {
  _ws_products; local out; out="$(cd "$T" && cmd_run orchestrator --product bundle --dry-run)"
  assert_contains "$out" "--cwd $T/products/bundle"
  assert_contains "$out" "--label bundle/orch"
  assert_contains "$out" "agent start bundle-orch"
  assert_contains "$out" "--append-system-prompt-file $T/.cel/products/bundle/role-orchestrator.md"
  rm -rf "$T"
}
test_run_orchestrator_for_an_implicit_product_is_unchanged() {
  _ws_products; local out; out="$(cd "$T" && cmd_run orchestrator --repo lone --dry-run)"
  assert_contains "$out" "--cwd $T/repos/lone"
  assert_contains "$out" "--label lone/orch"
  assert_contains "$out" "agent start lone-orch"
  assert_contains "$out" "--append-system-prompt-file $T/.cel/role-orchestrator.md"
  rm -rf "$T"
}
# --repo still works for an orchestrator and means "the product this repo is
# in" - so a member repo lands in the product's pane, not one of its own.
test_run_orchestrator_repo_resolves_to_its_product() {
  _ws_products; local out; out="$(cd "$T" && cmd_run orchestrator --repo widget --dry-run)"
  assert_contains "$out" "--cwd $T/products/bundle"
  assert_contains "$out" "agent start bundle-orch"
  rm -rf "$T"
}
# The single-repo auto-fill becomes a single-PRODUCT auto-fill: ws-alpha has
# one repo, hence one implicit product, and nothing about it changes.
test_run_orchestrator_autofills_a_lone_product() {
  _ws; local out; out="$(cd "$T" && cmd_run orchestrator --dry-run)"
  assert_contains "$out" "widget/orch"
  rm -rf "$T"
}
# The role body of two products must not overwrite each other, and the name
# must keep ending in role-orchestrator.md: lib/gc.sh recognises long-lived
# agents by that substring in the cmdline.
test_run_role_file_is_per_declared_product() {
  _ws_products
  assert_eq "$(_run_role_file "$T" orchestrator bundle)" "$T/.cel/products/bundle/role-orchestrator.md"
  assert_eq "$(_run_role_file "$T" orchestrator lone)" "$T/.cel/role-orchestrator.md"
  assert_eq "$(_run_role_file "$T" orchestrator)" "$T/.cel/role-orchestrator.md"
  rm -rf "$T"
}

# --- the console ----------------------------------------------------------
# The console is BOX-LEVEL: it routes across every workspace and therefore
# stands in none. No --workspace is resolved, no policy block is rendered
# (there is no workspace to describe), and its runtime comes from agents.yaml
# `defaults.console` rather than from a workspace binding.
# These read the SHIPPED default from agents.yaml and assert the launch is
# consistent with it, whatever it is - so changing the default is one edit in
# one place. The default's value is pinned by its own test below.
_console() { CONS="$(mktemp -d)/console"; CRT="$(manifest_default console | jq -r .runtime)"; CMODEL="$(manifest_default console | jq -r .model)"; }

# What a first-time reader gets: the runtime the README leads with, and the
# cheapest model that handles a fixed vocabulary of cel commands. A default
# that rides on a subscription quota is not a default.
test_the_shipped_console_default_is_claude_haiku() {
  assert_eq "$(yq -r '.defaults.console.runtime' "$CEL_ROOT/agents.yaml")" claude
  assert_eq "$(yq -r '.defaults.console.model' "$CEL_ROOT/agents.yaml")" haiku
}
test_run_console_needs_no_workspace_and_has_a_dir_of_its_own() {
  _console
  local out; out="$(cd /tmp && CEL_CONSOLE_DIR="$CONS" cmd_run console --agent --dry-run)"
  assert_contains "$out" "workspace create --cwd $CONS --label celestial/console"
  assert_contains "$out" "agent start console --kind $CRT"
  rm -rf "$CONS"
}
test_run_console_takes_its_model_from_the_manifest_default() {
  _console
  local out; out="$(cd /tmp && CEL_CONSOLE_DIR="$CONS" cmd_run console --agent --dry-run)"
  assert_contains "$out" "--model $CMODEL"
  out="$(cd /tmp && CEL_CONSOLE_DIR="$CONS" cmd_run console --agent --model x/y --thinking high --dry-run)"
  assert_contains "$out" "--model x/y"
  assert_contains "$out" "high"
  rm -rf "$CONS"
}
# The role file must keep ending in role-console.md: lib/gc.sh recognises a
# long-lived agent by a role-*.md in its cmdline, and the console is the
# longest-lived pane on the box.
test_run_console_role_travels_as_a_file_beside_the_console_dir() {
  _console
  local out; out="$(cd /tmp && CEL_CONSOLE_DIR="$CONS" cmd_run console --agent --dry-run)"
  assert_contains "$out" "$CONS/role-console.md"
  rm -rf "$CONS"
}
# The guard rides differently per runtime: omp/pi load it as a --hook file,
# claude gets it from the PreToolUse hook registered in settings.json (so
# nothing to assert on argv beyond the permission bypass that lets the hook
# be the only gate).
test_run_console_gets_the_guard_hook() {
  _console
  local out; out="$(cd /tmp && CEL_CONSOLE_DIR="$CONS" cmd_run console --agent --dry-run)"
  case "$CRT" in
    claude) assert_contains "$out" "--dangerously-skip-permissions"
            ! printf '%s' "$out" | grep -q -- '--hook' || { echo "claude got an omp hook flag"; rm -rf "$CONS"; return 1; } ;;
    *)      assert_contains "$out" "--hook $CEL_ROOT/tools/hooks/orchestrator-guard.omp.ts" ;;
  esac
  rm -rf "$CONS"
}
test_run_console_body_carries_no_workspace_policy_block() {
  local body; body="$(_run_console_body)"
  assert_contains "$body" "You are the console"
  ! printf '%s' "$body" | grep -q "Workspace policy" \
    || { echo "the console got a policy block for a workspace it does not have"; return 1; }
}
# A profile is a per-workspace binding; the console has no workspace to bind
# one from, so asking for one is a mistake rather than a silent no-op.
test_run_console_refuses_a_profile() {
  _console
  ( cd /tmp && CEL_CONSOLE_DIR="$CONS" assert_fails _cmd_run_in_subshell console --agent --profile opus-pi --dry-run )
  rm -rf "$CONS"
}

# --- through the gateway --------------------------------------------------
# A profile that says `via: gateway` launches pi against the loopback gateway
# instead of a provider: the model is the gateway's `<provider>/<model>` id
# behind the `ompgw` provider, and the pane gets two env vars. pi sends no
# session identity of its own, so CEL_SESSION_ID is the only thing the
# gateway's balancer can pin an account by (SPIKE-gateway).
_ws_gateway() {
  _ws
  cat >>"$T/workspace.yaml" <<'YAML'
worker_profiles:
  gw: { runtime: pi, model: openai-codex/gpt-5.5, via: gateway }
YAML
  GWT="$(mktemp -d)"; mkdir -p "$GWT/bin"
  export CEL_CONFIG_FILE="$GWT/config.yaml"
  printf 'gateway:\n  broker_port: 47311\n  gateway_port: 47411\n' > "$CEL_CONFIG_FILE"
  cat >"$GWT/gwstub" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  ready)  exit "${GW_STUB_DOWN:-0}" ;;
  models) printf '%s\n' '{"data":[{"id":"openai-codex/gpt-5.5","context_length":272000,"max_output_tokens":8192}]}' ;;
esac
EOS
  chmod +x "$GWT/gwstub"; export CEL_GATEWAY_STUB="$GWT/gwstub"
  cat >"$GWT/bin/omp" <<'EOS'
#!/usr/bin/env bash
case "$1 $2" in
  "auth-gateway check") printf '%s\n' '{"credentials":[{"id":1,"provider":"openai-codex","type":"oauth","ok":true,"accountId":"aaaaaaaa-1111","report":{"limits":[]}}]}' ;;
  *) printf '%s\n' 'gw-fixture-token-do-not-print' ;;
esac
EOS
  chmod +x "$GWT/bin/omp"; PATH="$GWT/bin:$PATH"
}
_ws_gateway_clean() { rm -rf "$T" "$GWT"; unset CEL_CONFIG_FILE CEL_GATEWAY_STUB; }

test_run_worker_via_gateway_uses_the_ompgw_model_and_masks_the_env() {
  _ws_gateway
  local out; out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --profile gw --dry-run 2>&1)"
  assert_contains "$out" "--model ompgw/openai-codex/gpt-5.5"
  assert_contains "$out" "OMP_GATEWAY_TOKEN"
  assert_contains "$out" "CEL_SESSION_ID"
  ! printf '%s' "$out" | grep -q "gw-fixture-token" || { echo "the gateway token reached the launch line"; _ws_gateway_clean; return 1; }
  _ws_gateway_clean
}

# A dry run is a PREVIEW. models.json is the owner's file and writing it for a
# launch that never happened is a side effect nobody asked for.
test_run_worker_via_gateway_writes_no_models_json_on_a_dry_run() {
  _ws_gateway
  export PI_CODING_AGENT_DIR="$GWT/pi"
  ( cd "$T" && cmd_run worker --repo widget --branch WG-1-x --profile gw --dry-run >/dev/null 2>&1 )
  [ ! -e "$GWT/pi/models.json" ] || { echo "a dry run wrote models.json"; unset PI_CODING_AGENT_DIR; _ws_gateway_clean; return 1; }
  unset PI_CODING_AGENT_DIR
  _ws_gateway_clean
}

# Gateway down means every account behind it is unreachable, and a pane that
# starts against a dead provider looks exactly like a worker thinking hard.
test_run_worker_via_gateway_dies_when_the_gateway_is_down() {
  _ws_gateway
  ( cd "$T" && GW_STUB_DOWN=1 assert_fails _cmd_run_in_subshell worker --repo widget --branch WG-1-x --profile gw --dry-run )
  _ws_gateway_clean
}

# THE LAUNCHER MARKS ITS CHILDREN. A runtime that rewrites its own argv (pi
# sets process.title) leaves `cel gc` nothing to recognise in /proc/<pid>/cmdline,
# so ownership travels in the environment instead, where exec fixes it for the
# life of the process. `herdr agent start` has no --env option, so the three
# variables are typed as an `env K=V ...` PREFIX to the launch line - set for
# that command only, never exported into the pane's shell for good.
test_run_worker_launch_carries_role_rolefile_and_workspace() {
  _ws; local out; out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --dry-run)"
  assert_contains "$out" "CEL_ROLE=worker"
  assert_contains "$out" "CEL_ROLE_FILE=$T/.cel/role-worker.md"
  assert_contains "$out" "CEL_WORKSPACE=$T"
  rm -rf "$T"
}
test_run_root_and_orchestrator_are_marked_too() {
  _ws
  local out; out="$(cd "$T" && cmd_run root --dry-run)"
  assert_contains "$out" "CEL_ROLE=root"
  assert_contains "$out" "CEL_ROLE_FILE=$T/.cel/role-root.md"
  out="$(cd "$T" && cmd_run orchestrator --repo widget --dry-run)"
  assert_contains "$out" "CEL_ROLE=orchestrator"
  rm -rf "$T"
}
# The values are a role name and two paths - nothing here is a secret, and the
# preview is worthless if it hides what the pane will actually carry.
test_run_dry_run_shows_the_prefix_ahead_of_the_agent_command() {
  _ws; local out; out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --dry-run)"
  assert_contains "$out" "env CEL_ROLE=worker"
  rm -rf "$T"
}

# CEL-44: A LIVE AGENT IN THE PRODUCT'S CWD IS AN ORCHESTRATOR, NAMED OR NOT.
# On 2026-09-18 herdr cleared `widget-orch`'s name when it restarted; every
# surface resolves an orchestrator by its alias on the roster, so the live one
# read as dead and the cure for a dead one is to start another - on top of it.
# The refusal is here, at the one door that starts them.
_run_stub_roster() { # <cwd> <name|->
  mkdir -p "$T/bin"
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent list") printf '%s\n' '{"result":{"agents":[{"name":$([ "$2" = "-" ] && printf null || printf '"%s"' "$2"),"agent_status":"idle","pane_id":"wQ:p1","cwd":"$1"}]}}' ;;
  *) printf '{}\n' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
  PATH="$T/bin:$PATH"
}

test_run_orchestrator_refuses_a_duplicate_over_a_live_agent() {
  _ws; _run_stub_roster "$T/repos/widget" widget-orch
  ( cd "$T" && assert_fails _cmd_run_in_subshell orchestrator --repo widget --dry-run )
  rm -rf "$T"
}
test_run_orchestrator_refuses_over_an_unnamed_live_agent_too() {
  _ws; _run_stub_roster "$T/repos/widget" -
  ( cd "$T" && assert_fails _cmd_run_in_subshell orchestrator --repo widget --dry-run )
  rm -rf "$T"
}
test_run_orchestrator_force_starts_anyway() {
  _ws; _run_stub_roster "$T/repos/widget" -
  local out; out="$(cd "$T" && cmd_run orchestrator --repo widget --dry-run --force)"
  assert_contains "$out" "agent start widget-orch"
  rm -rf "$T"
}
# A live agent somewhere else is not this product's orchestrator.
test_run_orchestrator_ignores_a_live_agent_in_another_cwd() {
  _ws; _run_stub_roster "$T/elsewhere" -
  local out; out="$(cd "$T" && cmd_run orchestrator --repo widget --dry-run)"
  assert_contains "$out" "agent start widget-orch"
  rm -rf "$T"
}

# ---------------------------------------------------- the reviewer registry
# A reviewer is started by `cel run reviewer --repo r --pr n` and was recorded
# NOWHERE, so nothing downstream could know it had finished: seven idle
# reviewer panes for six merged PRs held ~3.0 GB on this box one morning
# because no sweep could even see them. The row is what makes the reviewer
# collectable; `cel gc` reads it.
_reviewers_fixture() { export CEL_REVIEWERS_STATE="$T/reviewers.json"; }

test_reviewer_row_records_the_pr_and_is_found_and_dropped_again() {
  _ws; _reviewers_fixture
  reviewers_record widget 71 w1:p3 widget-pr-71-review
  assert_eq "$(reviewers_rows | jq -r length)" 1
  assert_eq "$(reviewers_find widget 71 | jq -r .pane)" w1:p3
  assert_fails reviewers_find widget 72
  reviewers_drop widget 71
  assert_eq "$(reviewers_rows | jq -r length)" 0
  rm -rf "$T"
}

# A missing or corrupt registry is an empty one, never an error: a stale file
# must not make the launcher - or the sweep that reads it - fail.
test_reviewer_registry_reads_a_corrupt_file_as_empty() {
  _ws; _reviewers_fixture
  printf 'not json' > "$CEL_REVIEWERS_STATE"
  assert_eq "$(reviewers_rows | jq -r length)" 0
  rm -rf "$T"
}

# Today a second `cel run reviewer --pr 12` gives you two reviewers for one
# PR and no way to tell them apart. One PR, one reviewer.
test_second_reviewer_for_the_same_pr_reuses_the_pane_and_adds_no_row() {
  _ws_review; _reviewers_fixture
  reviewers_record widget 12 w1:p3 widget-pr-12-review
  local out; out="$(cd "$T" && cmd_run reviewer --repo widget --pr 12 --dry-run)"
  assert_contains "$out" w1:p3
  case "$out" in *'tab "PR reviewer"'*) printf 'a second pane was split for one PR\n' >&2; return 1;; esac
  assert_eq "$(reviewers_rows | jq -r length)" 1
  rm -rf "$T"
}

# A read-modify-write with no lock is two reviewers overwriting each other.
# The whole update is held under a lock on the registry, and a registry
# somebody else is holding is REFUSED rather than clobbered.
test_reviewer_registry_update_is_refused_while_another_writer_holds_it() {
  _ws; _reviewers_fixture
  reviewers_record widget 71 w1:p3 widget-pr-71-review
  local fd; exec {fd}>"$CEL_REVIEWERS_STATE.lock"; flock "$fd"
  ( CEL_REVIEWERS_LOCK_WAIT=1 assert_fails reviewers_record gadget 99 w1:p9 gadget-pr-99-review )
  exec {fd}>&-
  assert_eq "$(reviewers_rows | jq -r length)" 1
  assert_eq "$(reviewers_find widget 71 | jq -r .pane)" w1:p3
  rm -rf "$T"
}
