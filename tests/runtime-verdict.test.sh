# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/run.sh"
source "$CEL_ROOT/tests/lib/orch-stub.sh"

_rv_setup() {
  orch_stub_setup omp
  export CEL_REX_STATE="$T/rex"
  mkdir -p "$CEL_REX_STATE" "$T/ws/.cel/solo/bundle"
  printf '{"result":{"agents":[]}}\n' > "$T/roster.json"
  cat > "$T/ws/workspace.yaml" <<'YAML'
name: alpha
runtime: {orchestrator: omp, worker: omp}
role_profiles: {orchestrator: baseline}
worker_profiles:
  baseline: {runtime: omp, model: fixture/base}
repos:
  - name: widget
products:
  - name: bundle
    mode: solo
    repos: [widget]
  - name: widget
    mode: solo
    repos: [widget]
YAML
  _rv_local opencode fixture/native
  # Capture the actual argv while the real canonical dry-run constructs it;
  # never reconstruct argv by splitting its human-readable output.
  _run_dry_agent_args() {
    printf '%s\0' "${AGENT_ARGS[@]}" > "$T/canonical.argv"
    printf '%q ' "${AGENT_ARGS[@]}"
  }
  # Rex's production identity check reads /proc directly. This fixture supplies
  # the same start identity from our controlled proc, never the host process.
  _rex_pid_start() { cat "$PROC/$1/start" 2>/dev/null; }
}

_rv_local() {
  cat > "$T/ws/workspace.local.yaml" <<YAML
worker_profiles:
  local-widget: {runtime: $1, model: $2}
products:
  - name: bundle
    role_profiles: {solo: local-widget}
YAML
}

_rv_canonical() { # product backend runtime -> RV_ARGV
  local product="$1" backend="$2" runtime="$3"
  (cmd_run solo --product "$product" --workspace alpha --fresh --force --dry-run --session-backend "$backend") > "$T/preview" || return 1
  local -a args
  mapfile -d '' -t args < "$T/canonical.argv"
  RV_ARGV=("$runtime" "${args[@]}")
}

_rv_proc() { # runtime argv...
  local runtime="$1"; shift
  ORCH_STUB_CWD="$T/ws/.cel/solo/bundle" orch_stub_proc 100 bundle-orch "$T/ws" "$runtime" "$@"
  printf '1000\n' > "$PROC/100/start"
  # Linux stat field 22: starttime, after pid, comm, state and fields 4..21.
  printf '100 (fixture native holder) S 50 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1000\n' > "$PROC/100/stat"
}

_rv_rex() {
  jq -n --arg cwd "$T/ws/.cel/solo/bundle" --arg ws "$T/ws" --arg rt "$1" \
    '{name:"bundle-orch",agent:$rt,cwd:$cwd,role:"solo",workspace:$ws,pane_id:"rex/fixture/session",backend:"rex",rex_session:"fixture",rex_block:"session",pid:100,pid_start:"1000",agent_status:"idle"}' \
    > "$CEL_REX_STATE/bundle-orch.json"
}

_rv_verdict() {
  _run_orch_verdict alpha orchestrator "${3:-bundle}" "${4:-bundle-orch}" "$1" "$T/ws/.cel/solo/bundle" "$2"
}

_rv_down() { unset CEL_REX_STATE; orch_stub_teardown; }

test_runtime_verdict_solo_local_opencode_profile_retains_rex_backend() {
  _rv_setup
  local -a RV_ARGV
  _rv_canonical bundle rex opencode || { _rv_down; return 1; }
  assert_contains "$(cat "$T/preview")" 'rex new'
  local word
  for word in "${RV_ARGV[@]}"; do
    case "$word" in --hook|--no-prewalk|--system-prompt|--append-system-prompt)
      echo "OpenCode inherited OMP-only flag: $word"; _rv_down; return 1 ;;
    esac
  done
  _rv_proc "${RV_ARGV[@]}" --session ses_FixtureNative --prompt 'Continue the fictional widget task'
  _rv_rex opencode
  _rv_verdict rex/fixture/session opencode
  assert_eq "$_RUN_LAUNCH" current
  assert_eq "$_RUN_MODEL" fixture/native
  _rv_down
}

test_runtime_verdict_local_profile_change_invalidates_same_build_and_pid() {
  _rv_setup
  _rv_local omp fixture/first
  local -a RV_ARGV
  _rv_canonical bundle herdr omp || { _rv_down; return 1; }
  _rv_proc "${RV_ARGV[@]}"
  _rv_verdict w1:p1 omp
  assert_eq "$_RUN_LAUNCH" current
  cp "$T/ws/workspace.local.yaml" "$T/route-before"
  _rv_local omp fixture/later
  touch -r "$T/route-before" "$T/ws/workspace.local.yaml"
  _rv_verdict w1:p1 omp
  assert_eq "$_RUN_LAUNCH" stale
  assert_contains "$_RUN_DETAIL" model
  _rv_down
}

test_runtime_verdict_argv_change_invalidates_a_healthy_cache() {
  _rv_setup
  _rv_local omp fixture/first
  local -a RV_ARGV
  _rv_canonical bundle herdr omp || { _rv_down; return 1; }
  _rv_proc "${RV_ARGV[@]}"
  _rv_verdict w1:p1 omp
  assert_eq "$_RUN_LAUNCH" current
  printf '%s\0' "${RV_ARGV[@]}" --retired-widget-flag > "$PROC/100/cmdline"
  _rv_verdict w1:p1 omp
  assert_eq "$_RUN_LAUNCH" stale
  assert_contains "$_RUN_DETAIL" --retired-widget-flag
  _rv_down
}

test_runtime_verdict_reused_rex_pid_does_not_reuse_healthy_cache() {
  _rv_setup
  local -a RV_ARGV
  _rv_canonical bundle rex opencode || { _rv_down; return 1; }
  _rv_proc "${RV_ARGV[@]}"
  _rv_rex opencode
  _rv_verdict rex/fixture/session opencode
  assert_eq "$_RUN_LAUNCH" current
  printf '2000\n' > "$PROC/100/start"
  printf '100 (fixture replacement) S 50 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 2000\n' > "$PROC/100/stat"
  _rv_verdict rex/fixture/session opencode
  assert_eq "$_RUN_LAUNCH" unknown
  _rv_down
}

test_runtime_verdict_missing_omp_inbox_and_guard_remain_actionable() {
  _rv_setup
  _rv_local omp fixture/first
  local -a RV_ARGV stripped=()
  _rv_canonical bundle herdr omp || { _rv_down; return 1; }
  local i
  for ((i=0; i<${#RV_ARGV[@]}; i++)); do
    if [ "${RV_ARGV[$i]}" = --hook ]; then
      case "${RV_ARGV[$((i+1))]}" in */inbox.omp.ts|*/orchestrator-guard.omp.ts) ((i+=1)); continue ;; esac
    fi
    stripped+=("${RV_ARGV[$i]}")
  done
  _rv_proc "${stripped[@]}"
  _rv_verdict w1:p1 omp
  assert_eq "$_RUN_LAUNCH" stale
  assert_contains "$_RUN_DETAIL" inbox
  assert_contains "$_RUN_DETAIL" guard
  _rv_down
}

test_runtime_verdict_product_override_is_not_global_model_drift_waiver() {
  _rv_setup
  _rv_local omp fixture/local
  local -a RV_ARGV
  _rv_canonical bundle herdr omp || { _rv_down; return 1; }
  _rv_proc "${RV_ARGV[@]}"
  _rv_verdict w1:p1 omp
  assert_eq "$_RUN_LAUNCH" current
  # The very same local model is wrong for the unbound sibling product.
  _rv_verdict w1:p1 omp widget widget-orch
  assert_eq "$_RUN_LAUNCH" stale
  assert_contains "$_RUN_DETAIL" model
  _rv_down
}

test_runtime_verdict_multiline_kickoff_cannot_supply_real_hooks_or_model() {
  _rv_setup
  _rv_local omp fixture/first
  local -a RV_ARGV stripped=()
  _rv_canonical bundle herdr omp || { _rv_down; return 1; }
  local i payload='Continue the fictional widget task' removed_hooks=0 removed_model=0
  for ((i=0; i<${#RV_ARGV[@]}; i++)); do
    case "${RV_ARGV[$i]}" in
      --hook)
        case "${RV_ARGV[$((i+1))]}" in
          */inbox.omp.ts|*/orchestrator-guard.omp.ts)
            payload+=$'\n'"${RV_ARGV[$i]}"$'\n'"${RV_ARGV[$((i+1))]}"
            ((removed_hooks+=1)); ((i+=1)); continue ;;
        esac ;;
      --model)
        payload+=$'\n'"${RV_ARGV[$i]}"$'\n'"${RV_ARGV[$((i+1))]}"
        ((removed_model+=1)); ((i+=1)); continue ;;
    esac
    stripped+=("${RV_ARGV[$i]}")
  done
  assert_eq "$removed_hooks" 2
  assert_eq "$removed_model" 1
  # These flag-shaped lines are ONE prompt argument, not launch options.
  _rv_proc "${stripped[@]}" --prompt "$payload"
  _rv_verdict w1:p1 omp
  assert_eq "$_RUN_LAUNCH" stale
  assert_eq "$_RUN_MODEL" '-'
  assert_contains "$_RUN_DETAIL" inbox
  assert_contains "$_RUN_DETAIL" guard
  assert_contains "$_RUN_DETAIL" model
  _rv_down
}

test_runtime_verdict_manifest_content_invalidates_primed_expected_flags_cache() {
  _rv_setup
  _rv_local omp fixture/first
  local manifest_source="$CEL_MANIFEST"
  local CEL_MANIFEST="$T/agents.yaml" CEL_MANIFEST_CACHE="$T/parsed-manifest"
  cp "$manifest_source" "$CEL_MANIFEST"
  # The parsed cache is deliberately newer, without any timing-dependent sleep.
  touch -d '2000-01-01 00:00:00 UTC' "$CEL_MANIFEST"
  local initial_args
  initial_args="$(agent_launch_args omp)"
  local -a RV_ARGV
  _rv_canonical bundle herdr omp || { _rv_down; return 1; }
  _rv_proc "${RV_ARGV[@]}"
  _rv_verdict w1:p1 omp
  assert_eq "$_RUN_LAUNCH" current
  cp "$CEL_MANIFEST" "$T/manifest-before"
  yq -y '.agents.omp.launch_args += ["--fixture-widget-required"]' "$CEL_MANIFEST" > "$T/manifest-next"
  cp "$T/manifest-next" "$CEL_MANIFEST"
  touch -r "$T/manifest-before" "$CEL_MANIFEST"
  # Ordinary manifest reads still see the primed parsed cache. Verdict capture
  # must independently resolve the changed effective manifest, not trust it.
  assert_eq "$(agent_launch_args omp)" "$initial_args"
  _rv_verdict w1:p1 omp
  assert_eq "$_RUN_LAUNCH" stale
  assert_contains "$_RUN_DETAIL" --fixture-widget-required
  _rv_down
}
