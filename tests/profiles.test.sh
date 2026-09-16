# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/profiles.sh"
source "$CEL_ROOT/lib/run.sh"

# These tests are about resolution, not about which accounts this box is signed
# in to. The credential probe shells out to the real runtime, so it is off here
# and exercised deliberately in its own test with a stub.
export CEL_NO_CREDENTIAL_PROBE=1
# Likewise the quota probe reaches a provider's balance endpoint; off here,
# exercised with a stub in its own tests.
export CEL_NO_QUOTA_PROBE=1

_pws() { T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-profiles/workspace.yaml" "$T/"
         mkdir -p "$T/repos/widget"; }
_aws() { T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
         mkdir -p "$T/repos/widget"; }

_in_subshell() { ( "$@" ); }

# --- the default thinking level ------------------------------------------

# ws-alpha declares no `thinking:`, so it must inherit agents.yaml defaults.
test_thinking_falls_back_to_the_plane_default() {
  _aws; assert_eq "$(ws_thinking "$T")" "$(manifest_default thinking)"; rm -rf "$T"
}
test_workspace_thinking_beats_the_plane_default() {
  _pws; assert_eq "$(ws_thinking "$T")" xhigh; rm -rf "$T"
}

# --- clamping to what a runtime actually accepts ---------------------------

test_clamp_passes_a_level_the_runtime_accepts() {
  assert_eq "$(profile_clamp omp medium)" medium
}
# claude's ladder has no `minimal`, so it must step DOWN to low rather than
# hand claude a level it will reject at launch.
test_clamp_walks_down_to_the_nearest_accepted_level() {
  assert_eq "$(profile_clamp claude minimal)" low
}
# `off` is below everything claude accepts: the weakest it does accept is the
# only honest answer.
test_clamp_below_the_range_uses_the_weakest_accepted() {
  assert_eq "$(profile_clamp claude off)" low
}
# `auto` is not on the ladder at all - unrepresentable, so nothing is emitted
# and the caller omits the flag entirely.
test_clamp_rejects_an_off_ladder_level() {
  assert_fails _in_subshell profile_clamp claude auto
}
test_clamp_fails_for_a_runtime_with_no_thinking_block() {
  assert_fails _in_subshell profile_clamp opencode high
}

# --- rendering the flags each runtime actually spells ----------------------

test_launch_args_render_omps_flag_form() {
  local PROFILE_ARGS; profile_launch_args omp some-model high
  assert_eq "${PROFILE_ARGS[*]}" "--model some-model --thinking high"
}
test_launch_args_render_claudes_effort_flag() {
  local PROFILE_ARGS; profile_launch_args claude claude-opus-5 high
  assert_eq "${PROFILE_ARGS[*]}" "--model claude-opus-5 --effort high"
}
# codex has no thinking FLAG - it takes a config override. Getting this wrong
# means inventing --reasoning-effort and failing at launch.
test_launch_args_render_codexs_config_override() {
  local PROFILE_ARGS; profile_launch_args codex gpt-6-astra xhigh
  assert_eq "${PROFILE_ARGS[*]}" "--model gpt-6-astra -c model_reasoning_effort=xhigh"
}
# opencode carries effort in its own config: the model still goes on the
# command line, the level is silently left alone.
test_launch_args_omit_thinking_for_a_runtime_without_one() {
  local PROFILE_ARGS; profile_launch_args opencode anthropic/claude-opus-5 high
  assert_eq "${PROFILE_ARGS[*]}" "--model anthropic/claude-opus-5"
}
test_launch_args_are_empty_when_nothing_is_requested() {
  local PROFILE_ARGS; profile_launch_args omp "" ""
  assert_eq "${#PROFILE_ARGS[@]}" 0
}

# --- resolution, including the reachability fallback ----------------------

test_resolve_reads_runtime_model_and_thinking() {
  _pws
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE
  profile_resolve "$T" swap
  assert_eq "$PROFILE_RUNTIME" codex
  assert_eq "$PROFILE_MODEL" gpt-6-astra
  assert_eq "$PROFILE_THINKING" max
  rm -rf "$T"
}
# No `thinking:` on the profile: it inherits the workspace default, not the
# runtime's own.
test_resolve_inherits_the_workspace_thinking_level() {
  _pws
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE
  profile_resolve "$T" inherit
  assert_eq "$PROFILE_THINKING" xhigh
  rm -rf "$T"
}
# THE POINT OF FALLBACK: DEEPSEEK_API_KEY is absent from the fixture's env, so
# the profile must resolve to the OpenRouter route BEFORE a pane is spawned -
# not spawn one that prints an auth error and then idles.
test_resolve_falls_back_when_the_primary_key_is_missing() {
  _pws
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE
  profile_resolve "$T" remote 2>/dev/null
  assert_eq "$PROFILE_MODEL" openrouter/deepseek/deepseek-v4.1-flash
  assert_contains "$PROFILE_NOTE" "DEEPSEEK_API_KEY"
  rm -rf "$T"
}
test_resolve_keeps_the_primary_when_its_key_is_present() {
  _pws
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE
  DEEPSEEK_API_KEY=sk-test profile_resolve "$T" remote 2>/dev/null
  assert_eq "$PROFILE_MODEL" deepseek/deepseek-flash
  assert_eq "$PROFILE_NOTE" ""
  rm -rf "$T"
}
# No fallback declared and no key: we do NOT refuse to start - a warning plus
# the primary is more useful than a dead end, but it must be recorded.
test_resolve_warns_but_proceeds_with_no_reachable_route() {
  _pws
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE
  profile_resolve "$T" stranded 2>/dev/null
  assert_eq "$PROFILE_MODEL" deepseek/deepseek-flash
  assert_contains "$PROFILE_NOTE" unreachable
  rm -rf "$T"
}
# A bare model name names no provider, so there is nothing to check and nothing
# to fall back from.
test_resolve_leaves_a_bare_model_alone() {
  _pws
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE
  profile_resolve "$T" bare
  assert_eq "$PROFILE_MODEL" some-model
  assert_eq "$PROFILE_NOTE" ""
  rm -rf "$T"
}
test_resolve_dies_on_an_unknown_profile() {
  _pws; ( cd "$T" && assert_fails _in_subshell profile_resolve "$T" nope ); rm -rf "$T"
}

# --- cel run wiring --------------------------------------------------------

# A profile that names a different runtime must change the CLI that is started,
# not just the model - which is why it resolves before the role is injected.
test_run_profile_switches_the_runtime_and_model() {
  _pws
  local out; out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --profile swap --dry-run 2>/dev/null)"
  assert_contains "$out" "--kind codex"
  assert_contains "$out" "--model gpt-6-astra"
  assert_contains "$out" "-c model_reasoning_effort=max"
  rm -rf "$T"
}
test_run_without_a_profile_still_gets_the_default_thinking_level() {
  _pws
  local out; out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --dry-run 2>/dev/null)"
  assert_contains "$out" "--kind omp"
  assert_contains "$out" "--thinking xhigh"
  rm -rf "$T"
}
test_run_explicit_flags_beat_the_profile() {
  _pws
  local out; out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x \
                    --profile swap --model gpt-5.6-sol --thinking low --dry-run 2>/dev/null)"
  assert_contains "$out" "--model gpt-5.6-sol"
  assert_contains "$out" "-c model_reasoning_effort=low"
  rm -rf "$T"
}
test_run_dies_on_an_unknown_profile() {
  _pws
  ( cd "$T" && assert_fails _in_subshell cmd_run worker --repo widget --branch WG-1-x --profile nope --dry-run )
  rm -rf "$T"
}

# --- role bindings ---------------------------------------------------------

# THE WHOLE POINT: root is started by the layout, never by hand, so its model
# has to come from the file rather than from a flag someone remembers to type.
test_role_binding_applies_to_root_without_a_flag() {
  _pws; local out; out="$(cd "$T" && cmd_run root --dry-run 2>/dev/null)"
  assert_contains "$out" "--kind codex"
  assert_contains "$out" "--model gpt-6-astra"
  rm -rf "$T"
}
test_role_binding_applies_to_workers() {
  _pws; local out; out="$(cd "$T" && cmd_run worker --repo widget --branch WG-1-x --dry-run 2>/dev/null)"
  assert_contains "$out" "--model some-model"
  rm -rf "$T"
}
# An unbound role keeps the plain `runtime:` behaviour - binding one role must
# not quietly re-point the others.
test_unbound_role_is_untouched_by_bindings() {
  _pws; local out; out="$(cd "$T" && cmd_run orchestrator --repo widget --dry-run 2>/dev/null)"
  assert_contains "$out" "--kind claude"
  ! printf '%s' "$out" | grep -q -- "--model" || { echo "orchestrator picked up a model"; return 1; }
  rm -rf "$T"
}
test_explicit_profile_beats_the_role_binding() {
  _pws; local out; out="$(cd "$T" && cmd_run root --profile bare --dry-run 2>/dev/null)"
  assert_contains "$out" "--model some-model"
  ! printf '%s' "$out" | grep -q "gpt-6-astra" || { echo "binding beat the flag"; return 1; }
  rm -rf "$T"
}
# A profile bound for its runtime/effort alone must not wipe a model that was
# already resolved from the `review:` block.
test_a_profile_without_a_model_keeps_the_reviewers_model() {
  _pws
  printf 'review:\n  runtime: omp\n  model: gpt-5.6-sol\n' >> "$T/workspace.yaml"
  local out; out="$(cd "$T" && cmd_run reviewer --repo widget --pr 3 --profile effortonly --dry-run 2>/dev/null)"
  assert_contains "$out" "--model gpt-5.6-sol"
  assert_contains "$out" "--thinking low"
  rm -rf "$T"
}
test_bindings_are_listed_by_cel_profiles() {
  _pws; local out; out="$(cd "$T" && cmd_profiles 2>/dev/null)"
  assert_contains "$out" "bound by role"
  assert_contains "$out" "root         -> swap"
  rm -rf "$T"
}
test_no_bindings_says_so() {
  _aws
  printf 'worker_profiles:\n  only: { runtime: omp, model: m }\n' >> "$T/workspace.yaml"
  local out; out="$(cd "$T" && cmd_profiles 2>/dev/null)"
  assert_contains "$out" "No role_profiles"
  rm -rf "$T"
}
# The policy block is how root LEARNS profiles exist - it is injected at launch
# and is the only place an agent is told.
test_policy_block_advertises_profiles_and_the_worker_binding() {
  _pws; local out; out="$(ws_policy_block "$T")"
  assert_contains "$out" "worker profiles:"
  assert_contains "$out" "default here: bare"
  rm -rf "$T"
}

# --- credential probe -------------------------------------------------------
# "The env var is set" is NOT "this account gets billed". omp keeps its own
# credential vault and that vault BEATS the environment, so a key exported from
# env.local can be ignored outright. A mismatched runtime credential can bill
# another account even while `cel profiles` reports the route reachable.
_probe_setup() { # <what the stub runtime reports it will use>
  _pws
  STUB="$T/probe.sh"
  printf '#!/usr/bin/env bash\nprintf %%s "%s"\n' "$1" > "$STUB"; chmod +x "$STUB"
  # a manifest whose runtime probes via the stub
  CEL_MANIFEST="$T/agents.yaml"
  yq -y --arg p "$STUB" '.agents.omp.credential_probe = $p' "$CEL_ROOT/agents.yaml" > "$CEL_MANIFEST"
  export CEL_MANIFEST
  unset CEL_NO_CREDENTIAL_PROBE
}
_probe_teardown() { export CEL_NO_CREDENTIAL_PROBE=1; unset CEL_MANIFEST; rm -rf "$T"; }

test_credential_mismatch_is_reported() {
  _probe_setup "a-totally-different-key"
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE
  OPENROUTER_API_KEY=the-workspace-key profile_resolve "$T" remote 2>/dev/null
  assert_contains "$PROFILE_NOTE" "credential mismatch"
  _probe_teardown
}

test_matching_credential_is_silent() {
  _probe_setup "sk-test-openrouter"   # same value the fixture's env map carries
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE
  profile_resolve "$T" remote 2>/dev/null
  ! printf '%s' "$PROFILE_NOTE" | grep -q "credential mismatch" \
    || { echo "warned about a credential that matches"; _probe_teardown; return 1; }
  _probe_teardown
}

# --- quota preflight ------------------------------------------------------------
# "The key is set" is not "the account can pay". A provider below its floor
# is vetoed BEFORE a pane spawns; a fallback on a solvent provider is taken
# and said aloud; unknown never vetoes.
_quota_setup() { # <deepseek-remaining> <openrouter-remaining>
  _pws
  QSTUB="$T/quota-stub.sh"
  printf '#!/usr/bin/env bash\ncase "$1" in deepseek) echo "%s";; openrouter) echo "%s";; *) echo unknown;; esac\n' "$1" "$2" > "$QSTUB"
  chmod +x "$QSTUB"; export CEL_QUOTA_STUB="$QSTUB"; unset CEL_NO_QUOTA_PROBE
}
_quota_teardown() { export CEL_NO_QUOTA_PROBE=1; unset CEL_QUOTA_STUB; rm -rf "$T"; }

test_quota_below_floor_takes_a_solvent_fallback() {
  _quota_setup 0.5 50
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_VETO PROFILE_ISOLATE
  DEEPSEEK_API_KEY=x profile_resolve "$T" remote 2>/dev/null
  assert_eq "$PROFILE_MODEL" openrouter/deepseek/deepseek-v4.1-flash
  assert_contains "$PROFILE_NOTE" "vetoed: deepseek balance 0.5"
  assert_eq "$PROFILE_VETO" ""
  _quota_teardown
}
test_quota_below_floor_with_no_fallback_is_a_veto() {
  _quota_setup 0.5 50
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_VETO PROFILE_ISOLATE
  DEEPSEEK_API_KEY=x profile_resolve "$T" stranded 2>/dev/null
  assert_contains "$PROFILE_VETO" "below its floor"
  assert_contains "$PROFILE_VETO" "platform.deepseek.com"
  assert_eq "$PROFILE_MODEL" deepseek/deepseek-flash   # route unchanged, caller refuses
  _quota_teardown
}
test_quota_fallback_also_dry_is_a_veto() {
  _quota_setup 0.5 1
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_VETO PROFILE_ISOLATE
  DEEPSEEK_API_KEY=x profile_resolve "$T" remote 2>/dev/null
  assert_contains "$PROFILE_VETO" "below its floor"
  _quota_teardown
}
# A balance we could not read is NOT a reason to refuse work.
test_quota_unknown_never_vetoes() {
  _quota_setup unknown unknown
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_VETO PROFILE_ISOLATE
  DEEPSEEK_API_KEY=x profile_resolve "$T" stranded 2>/dev/null
  assert_eq "$PROFILE_VETO" ""
  assert_eq "$PROFILE_MODEL" deepseek/deepseek-flash
  _quota_teardown
}
test_quota_above_floor_is_untouched() {
  _quota_setup 25 50
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_VETO PROFILE_ISOLATE
  DEEPSEEK_API_KEY=x profile_resolve "$T" remote 2>/dev/null
  assert_eq "$PROFILE_MODEL" deepseek/deepseek-flash
  assert_eq "$PROFILE_NOTE" ""
  assert_eq "$PROFILE_VETO" ""
  _quota_teardown
}
# The refusal reaches the launcher: cel run must not start the pane.
test_run_refuses_a_vetoed_profile() {
  _quota_setup 0.5 50
  ( cd "$T" && DEEPSEEK_API_KEY=x assert_fails _in_subshell cmd_run worker --repo widget --branch WG-1-x --profile stranded --dry-run )
  _quota_teardown
}
# A negative balance (an overdrawn account, as DeepSeek reports one) is below any floor.
test_quota_negative_balance_is_vetoed() {
  source "$CEL_ROOT/lib/quota.sh"
  quota_vetoed deepseek -0.24 || { echo "negative balance not vetoed"; return 1; }
  quota_vetoed openrouter 10.6 && { echo "10.6 vetoed against floor 2"; return 1; }
  quota_vetoed openrouter unknown && { echo "unknown vetoed"; return 1; }
  return 0
}

# --- per-repo role bindings ------------------------------------------------
# A workspace's repos are not alike. Re-pointing every orchestrator to change
# one of them is too blunt, and a --profile flag at launch is the thing role
# bindings exist to avoid, so the binding narrows to a repo.
# The fixture's repos block, re-declared with a per-repo binding on `widget`
# and a second repo that has none.
_pws_repo_binding() {
  _pws
  sed -i '/^repos:/,$d' "$T/workspace.yaml"
  cat >> "$T/workspace.yaml" <<'YAML'
repos:
  - name: widget
    url: git@github.com:someone/widget.git
    prefix: WG
    gate: bun test
    role_profiles: { orchestrator: bare, worker: bare }
  - name: other
    url: git@github.com:someone/other.git
    prefix: OT
YAML
}
test_repo_binding_beats_the_workspace_binding() {
  _pws_repo_binding
  assert_eq "$(role_profile_for "$T" orchestrator widget)" bare
  rm -rf "$T"
}
test_repo_without_a_binding_falls_back_to_the_workspace() {
  _pws_repo_binding
  assert_eq "$(role_profile_for "$T" root widget)" "$(role_profile "$T" root)"
  rm -rf "$T"
}
test_a_binding_on_one_repo_does_not_reach_another() {
  _pws_repo_binding
  assert_eq "$(role_profile_for "$T" orchestrator other)" "$(role_profile "$T" orchestrator)"
  rm -rf "$T"
}
test_run_applies_the_repo_binding_without_a_flag() {
  _pws_repo_binding
  local out; out="$(cd "$T" && cmd_run orchestrator --repo widget --dry-run 2>/dev/null)"
  assert_contains "$out" "--model some-model"
  rm -rf "$T"
}

# The balance belongs to the key, not to a provider name or a preceding
# workspace. Exercise the real key loader, request transport, and cache.
test_quota_accounts_are_isolated_and_credentials_stay_out_of_argv() {
  source "$CEL_ROOT/lib/quota.sh"
  local T; T="$(mktemp -d)"
  mkdir -p "$T/alpha" "$T/beta"
  printf 'name: alpha\nenv: {CEL_BALANCE_TEST_KEY: fixture-alpha}\n' > "$T/alpha/workspace.yaml"
  printf 'name: beta\nenv: {CEL_BALANCE_TEST_KEY: fixture-beta}\n' > "$T/beta/workspace.yaml"
  unset CEL_QUOTA_STUB CEL_BALANCE_TEST_KEY
  export CEL_QUOTA_DIR="$T/cache"
  provider_get() { printf CEL_BALANCE_TEST_KEY; }
  provider_balance() {
    case "$2" in
      url) printf 'https://balance.invalid/account' ;;
      jq) printf '.remaining' ;;
    esac
  }
  curl() {
    local argv="$*" headers=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -H)
          case "$2" in
            @-) headers="$(cat)" ;;
            Authorization:*) headers="$2" ;;
          esac
          shift 2 ;;
        *) shift ;;
      esac
    done
    jq -nc --arg argv "$argv" --arg headers "$headers" \
      '{argv:$argv, headers:$headers}' >> "$T/requests"
    case "$headers" in
      'Authorization: Bearer fixture-alpha') printf '{"remaining":12}' ;;
      'Authorization: Bearer fixture-beta') printf '{"remaining":34}' ;;
      *) return 1 ;;
    esac
  }
  assert_eq "$(quota_remaining demo "$T/alpha")" 12
  assert_eq "$(quota_remaining demo "$T/beta")" 34
  assert_eq "$(quota_remaining demo "$T/alpha")" 12
  printf 'name: beta\n' > "$T/beta/workspace.yaml"
  assert_eq "$(quota_remaining demo "$T/beta")" unknown
  assert_eq "${CEL_BALANCE_TEST_KEY+set}" ""
  assert_eq "$(jq -sc '[.[].headers]' "$T/requests")" \
    '["Authorization: Bearer fixture-alpha","Authorization: Bearer fixture-beta"]'
  assert_eq "$(jq -s '[.[] | .argv | test("fixture-alpha|fixture-beta")] | any' "$T/requests")" false
  rm -rf "$T"
}

# --- product bindings ------------------------------------------------------
# An orchestrator is launched per PRODUCT, not per repo, so a product binding
# has to be the one that reaches it. Order: product, then repo, then the
# workspace.
_pws_product_binding() {
  T="$(mktemp -d)"
  cat > "$T/workspace.yaml" <<'YAML'
name: profiled
kind: hustle
org: someone
policy: { merge: humans-only, pr: required, workers: 4, reviewer: null }
runtime: { root: claude, orchestrator: claude, worker: omp }
worker_profiles:
  swap: { runtime: codex, model: gpt-6-astra }
  bare: { runtime: omp, model: some-model }
role_profiles: { orchestrator: swap, worker: bare }
products:
  - name: bundle
    repos: [widget, gadget]
    role_profiles: { orchestrator: bare }
repos:
  - name: widget
    url: git@github.com:someone/widget.git
    prefix: WG
    gate: bun test
    role_profiles: { orchestrator: bare }
  - name: gadget
    url: git@github.com:someone/gadget.git
    prefix: WGT
    gate: bun test
YAML
}
test_product_binding_beats_repo_and_workspace() {
  _pws_product_binding
  assert_eq "$(role_profile_for "$T" orchestrator bundle)" bare
  assert_eq "$(role_profile_for "$T" root bundle)" "$(role_profile "$T" root)"
  rm -rf "$T"
}
test_repo_binding_beats_the_workspace_when_no_product_matches() {
  _pws_product_binding
  assert_eq "$(role_profile_for "$T" orchestrator widget)" bare
  assert_eq "$(role_profile_for "$T" worker gadget)" "$(role_profile "$T" worker)"
  rm -rf "$T"
}
