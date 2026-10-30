# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/run.sh"
source "$CEL_ROOT/lib/run-evidence.sh"

_rte_setup() {
  RTE="$(mktemp -d)"
  export CEL_PROC_ROOT="$RTE/proc" CEL_REX_STATE="$RTE/rex"
  mkdir -p "$RTE/widget" "$CEL_PROC_ROOT" "$CEL_REX_STATE"
  # Keep the real receipt validator/liveness check; only redirect its kernel
  # start-identity reader to the isolated proc fixture. No live process probes.
  _rex_pid_start() { _run_evidence_start "$CEL_PROC_ROOT" "$1"; }
  agent_inbox_hook() {
    case "$1:$2" in
      pi:flag) printf -- '--extension' ;;
      omp:flag) printf -- '--hook' ;;
      pi:file|omp:file) printf 'tools/hooks/inbox.omp.ts' ;;
    esac
  }
  _rte_proc 410 1 777 pi
}

_rte_proc() { # PID PPID start argv...
  local pid="$1" ppid="$2" start="$3" i; shift 3
  mkdir -p "$CEL_PROC_ROOT/$pid/task/$pid"
  printf '%s\0' "$@" > "$CEL_PROC_ROOT/$pid/cmdline"
  printf 'PPid:\t%s\n' "$ppid" > "$CEL_PROC_ROOT/$pid/status"
  # stat starts with PID (comm) state; starttime is field 22.
  { printf '%s (widget runtime) S' "$pid"; for ((i=4;i<=21;i++)); do printf ' 0'; done; printf ' %s\n' "$start"; } > "$CEL_PROC_ROOT/$pid/stat"
  ln -s "$RTE/widget" "$CEL_PROC_ROOT/$pid/cwd"
  : > "$CEL_PROC_ROOT/$pid/task/$pid/children"
}

_rte_watch() {
  _rte_proc 411 410 778 bash "$CEL_ROOT/bin/cel" inbox watch --workspace widget --for widget-orch --parent 410
  printf '411 ' > "$CEL_PROC_ROOT/410/task/410/children"
}

_rte_receipt() {
  jq -n --arg cwd "$RTE/widget" --arg runtime "${1:-pi}" '{name:"widget-orch",agent:$runtime,backend:"rex",pane_id:"rex/widget/bundle",rex_session:"widget",rex_block:"bundle",cwd:$cwd,pid:410,pid_start:"777"}' > "$CEL_REX_STATE/widget-orch.json"
  chmod 600 "$CEL_REX_STATE/widget-orch.json"
}

_rte_observe() { run_runtime_evidence pi widget-orch rex/widget/bundle "$RTE/widget" 410; }

# Subshells keep overridden fixture helpers out of other test files.
test_runtime_evidence_bare_pi_without_proof_is_unknown() (
  _rte_setup
  _rte_observe
  assert_eq "$RUN_EVIDENCE_ARGV" rewritten
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  _rte_receipt
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  printf 'pi\0\0\0\0' > "$CEL_PROC_ROOT/410/cmdline"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_ARGV" rewritten
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  rm -rf "$RTE"
)

test_runtime_evidence_direct_native_watcher_is_not_guard_proof() (
  _rte_setup; _rte_receipt; _rte_watch
  _rte_observe
  assert_eq "$RUN_EVIDENCE_ARGV" rewritten
  assert_eq "$RUN_EVIDENCE_INBOX" ok
  rm -rf "$RTE"
)

test_runtime_evidence_rex_receipt_binds_every_identity_field() (
  _rte_setup; _rte_watch
  local field value tmp
  for field in agent name backend pane_id cwd pid pid_start rex_session rex_block; do
    _rte_receipt
    case "$field" in pid) value=999 ;; *) value='"forged"' ;; esac
    tmp="$RTE/changed"
    jq --arg field "$field" --argjson value "$value" '.[$field]=$value' "$CEL_REX_STATE/widget-orch.json" > "$tmp"
    cat "$tmp" > "$CEL_REX_STATE/widget-orch.json"
    _rte_observe
    assert_eq "$RUN_EVIDENCE_ARGV" rewritten
    assert_eq "$RUN_EVIDENCE_INBOX" unknown
  done
  _rte_receipt
  chmod 666 "$CEL_REX_STATE/widget-orch.json"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  rm -f "$CEL_REX_STATE/widget-orch.json"
  printf '{invalid' > "$CEL_REX_STATE/widget-orch.json"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  rm -rf "$RTE"
)

test_runtime_evidence_reused_pid_and_symlink_receipt_are_untrusted() (
  _rte_setup; _rte_receipt; _rte_watch
  # Kernel start changes while the receipt retains the previous process.
  printf '410 (widget) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999\n' > "$CEL_PROC_ROOT/410/stat"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  # Restore the native identity so the symlink refusal is independently tested.
  local i
  { printf '410 (widget runtime) S'; for ((i=4;i<=21;i++)); do printf ' 0'; done; printf ' 777\n'; } > "$CEL_PROC_ROOT/410/stat"
  _rte_receipt
  mv "$CEL_REX_STATE/widget-orch.json" "$RTE/forged.json"
  ln -s "$RTE/forged.json" "$CEL_REX_STATE/widget-orch.json"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  rm -rf "$RTE"
)

test_runtime_evidence_observable_missing_hook_is_stripped() (
  _rte_setup
  local runtime
  for runtime in pi omp; do
    printf '%s\0' "$runtime" --model widget > "$CEL_PROC_ROOT/410/cmdline"
    run_runtime_evidence "$runtime" widget-orch herdr-widget "$RTE/widget" 410
    assert_eq "$RUN_EVIDENCE_ARGV" observable
    assert_eq "$RUN_EVIDENCE_INBOX" stripped
  done
  # A watcher does not erase a genuinely observable missing-hook diagnosis.
  _rte_watch
  run_runtime_evidence omp widget-orch herdr-widget "$RTE/widget" 410
  assert_eq "$RUN_EVIDENCE_INBOX" stripped
  rm -rf "$RTE"
)

test_runtime_evidence_reads_nul_argv_and_exact_hook_argument() (
  _rte_setup
  _rte_receipt
  printf '%s\0' pi --model 'widget model' --extension "$CEL_ROOT/tools/hooks/inbox.omp.ts" > "$CEL_PROC_ROOT/410/cmdline"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_ARGV" observable
  assert_eq "$RUN_EVIDENCE_INBOX" ok
  printf '%s\0' pi --prompt "--extension $CEL_ROOT/tools/hooks/inbox.omp.ts" > "$CEL_PROC_ROOT/410/cmdline"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" stripped
  printf '%s\0' omp "--hook=$CEL_ROOT/tools/hooks/inbox.omp.ts" > "$CEL_PROC_ROOT/410/cmdline"
  run_runtime_evidence omp widget-orch herdr-widget "$RTE/widget" 410
  assert_eq "$RUN_EVIDENCE_INBOX" ok
  rm -rf "$RTE"
)

test_runtime_evidence_watcher_requires_direct_parent_exact_command_and_cwd() (
  _rte_setup; _rte_receipt; _rte_watch
  printf 'PPid:\t409\n' > "$CEL_PROC_ROOT/411/status"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  printf 'PPid:\t410\n' > "$CEL_PROC_ROOT/411/status"
  printf '%s\0' bash "$CEL_ROOT/bin/cel" inbox watch --parent 4100 > "$CEL_PROC_ROOT/411/cmdline"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  printf '%s\0' bash /tmp/forged/bin/cel inbox watch --parent 410 > "$CEL_PROC_ROOT/411/cmdline"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  printf '%s\0' bash "$CEL_ROOT/bin/cel" inbox watch --parent 410 --parent 410 > "$CEL_PROC_ROOT/411/cmdline"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  printf '%s\0' bash "$CEL_ROOT/bin/cel" inbox watch --parent 410 > "$CEL_PROC_ROOT/411/cmdline"
  mkdir "$RTE/bundle"
  rm "$CEL_PROC_ROOT/411/cwd"; ln -s "$RTE/bundle" "$CEL_PROC_ROOT/411/cwd"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  rm -rf "$RTE"
)

test_runtime_evidence_watcher_lookup_is_bounded_and_not_required_for_opencode() (
  _rte_setup; _rte_receipt; _rte_watch
  local i
  for ((i=0;i<129;i++)); do printf '411 '; done > "$CEL_PROC_ROOT/410/task/410/children"
  _rte_observe
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  printf '%s\0' opencode --session ses_widget --prompt 'widget kickoff' > "$CEL_PROC_ROOT/410/cmdline"
  run_runtime_evidence opencode widget-orch herdr-widget "$RTE/widget" 410
  assert_eq "$RUN_EVIDENCE_ARGV" observable
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  rm -rf "$RTE"
)

test_runtime_evidence_codex_is_observable_but_unsupported_runtime_is_unknown() (
  _rte_setup
  printf '%s\0' codex --model widget > "$CEL_PROC_ROOT/410/cmdline"
  run_runtime_evidence codex widget-orch herdr-widget "$RTE/widget" 410
  assert_eq "$RUN_EVIDENCE_ARGV" observable
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  run_runtime_evidence unsupported-widget widget-orch herdr-widget "$RTE/widget" 410
  assert_eq "$RUN_EVIDENCE_ARGV" unknown
  assert_eq "$RUN_EVIDENCE_INBOX" unknown
  rm -rf "$RTE"
)

test_runtime_evidence_observable_rex_runtimes_require_owned_matching_receipt() (
  _rte_setup
  local runtime scenario file tmp
  file="$CEL_REX_STATE/widget-orch.json"
  tmp="$RTE/receipt-change"
  for runtime in omp opencode codex; do
    case "$runtime" in
      omp) printf '%s\0' omp --hook "$CEL_ROOT/tools/hooks/inbox.omp.ts" --model widget > "$CEL_PROC_ROOT/410/cmdline" ;;
      *) printf '%s\0' "$runtime" --model widget > "$CEL_PROC_ROOT/410/cmdline" ;;
    esac
    _rte_receipt "$runtime"
    run_runtime_evidence "$runtime" widget-orch rex/widget/bundle "$RTE/widget" 410
    assert_eq "$RUN_EVIDENCE_ARGV" observable
    if [ "$runtime" = omp ]; then
      assert_eq "$RUN_EVIDENCE_INBOX" ok
    else
      assert_eq "$RUN_EVIDENCE_INBOX" unknown
    fi
    for scenario in wrongname world-writable symlink stale-pid missing; do
      rm -f "$file" "$RTE/receipt-target"
      _rte_receipt "$runtime"
      case "$scenario" in
        wrongname)
          jq '.name="bundle-orch"' "$file" > "$tmp"
          cat "$tmp" > "$file" ;;
        world-writable) chmod 666 "$file" ;;
        symlink)
          mv "$file" "$RTE/receipt-target"
          ln -s "$RTE/receipt-target" "$file" ;;
        stale-pid)
          jq '.pid_start="999"' "$file" > "$tmp"
          cat "$tmp" > "$file" ;;
        missing) rm -f "$file" ;;
      esac
      run_runtime_evidence "$runtime" widget-orch rex/widget/bundle "$RTE/widget" 410
      assert_eq "$RUN_EVIDENCE_ARGV" unknown
      assert_eq "$RUN_EVIDENCE_INBOX" unknown
    done
  done
  rm -rf "$RTE"
)
