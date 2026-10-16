# shellcheck shell=bash
# `cel-fanout recover` (AH-261017): canonical registration and one safe
# continuation of a worker whose launch was only partly recorded.
#
# The fixture rebuilds the exact W710 shape with NO real herdr, gh, token or
# model: a live agent in a pane, the right worktree and branch, herdr reporting
# idle + launch_pending, a session path that does not exist, and no ledger row.
# The herdr stub answers from files and refuses to log anything it should never
# be asked: agent start, send-keys, send-text, pane run, report-agent,
# release-agent. /proc is a fixture directory (CEL_FANOUT_PROC, honoured only
# under CEL_TESTING). Every test drives the real cel-fanout.
source "$CEL_ROOT/lib/common.sh"
BIN="$CEL_ROOT/core/skills/fanout/bin/cel-fanout"

_rc_setup() {
  T="$(mktemp -d)"; T="$(cd "$T" && pwd)"
  cp "$CEL_ROOT/tests/fixtures/ws-profiles/workspace.yaml" "$T/"
  RS="$T/rs"; mkdir -p "$RS" "$T/proc" "$T/repos/widget"
  git -C "$T/repos/widget" init -q -b main
  git -C "$T/repos/widget" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  RC_WT="$T/wt/WG-1-recover"
  git -C "$T/repos/widget" worktree add -q -b WG-1-recover "$RC_WT"
  RC_ALIAS="widget-wg-1-recover"
  printf 'recover spec\n' > "$T/spec.md"
  : > "$T/ps.txt"
  STUB="$T/herdr"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
RS="${RC_RS:?}"
echo "$1 $2 ${3:-}" >> "$RS/log"
case "$1 $2" in
  "pane get") cat "$RS/pane.json" ;;
  "pane process-info") cat "$RS/pinfo.json" ;;
  "agent list") cat "$RS/agents.json" ;;
  "workspace list") cat "$RS/ws.json" ;;
  "agent read") cat "$RS/read.txt" ;;
  "agent prompt")
    printf '%s' "$4" > "$RS/prompt.txt"
    case "$(cat "$RS/prompt_mode" 2>/dev/null || echo ok)" in
      ok) [ ! -f "$RS/turn_on_prompt" ] || cp "$RS/turn.txt" "$RS/read.txt"; echo '{"result":{"prompted":true}}' ;;
      not_ready) echo '{"error":{"code":"agent_not_ready","message":"not ready"}}' >&2; exit 1 ;;
      error) echo '{"error":{"code":"agent_prompt_stalled","message":"stalled"}}' >&2; exit 1 ;;
    esac ;;
  "agent start"|"pane send-keys"|"pane send-text"|"pane run"|"agent send-keys"|"pane report-agent"|"pane report-agent-session"|"pane release-agent"|"worktree create"|"agent rename")
    echo "$*" >> "$RS/forbidden"; echo '{}' ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$STUB"
  export RC_RS="$RS" CEL_FANOUT_HERDR="$STUB" CEL_FANOUT_PROC="$T/proc" CEL_FANOUT_PS="$T/ps.txt"
  export CEL_FANOUT_CONFIRM_SLEEP=0 CEL_FANOUT_CONFIRM_TRIES=2
  jq -n --arg a "$RC_ALIAS" '{result:{agents:[{agent:"omp",
      agent_session:{agent:"omp",kind:"path",source:"herdr:omp",value:"/nonexistent/session.jsonl"},
      agent_status:"idle", interactive_ready:false, launch_pending:true, name:$a,
      pane_id:"w1AN:p1", workspace_id:"w1AN", terminal_id:"term_a"}]}}' > "$RS/agents.json"
  printf '{"result":{"pane":{"pane_id":"w1AN:p1","terminal_id":"term_a","agent":"omp"}}}' > "$RS/pane.json"
  printf '{"result":{"process_info":{"pane_id":"w1AN:p1","shell_pid":5000,"foreground_process_group_id":5001,"foreground_processes":[{"pid":5001,"name":"omp"}]}}}' > "$RS/pinfo.json"
  jq -n --arg w "$RC_WT" '{result:{workspaces:[{workspace_id:"w1AN",worktree:{checkout_path:$w}}]}}' > "$RS/ws.json"
  printf 'ctx 0.0%%\n' > "$RS/read.txt"
  printf '● reading the spec now\n' > "$RS/turn.txt"
  : > "$RS/log"
  _rc_proc 5001 5000 777777 worker "$T" "$RC_ALIAS" "--model some-model"
}

# a fake /proc entry. The environment carries a fake credential on purpose:
# it must never be printed or recorded.
_rc_proc() { # pid ppid start role ws inbox cmdline
  local d="$T/proc/$1" i z=""
  mkdir -p "$d"
  for i in $(seq 1 17); do z="$z 0"; done
  printf '%s (omp) S %s%s %s 0 0\n' "$1" "$2" "$z" "$3" > "$d/stat"
  printf 'CEL_ROLE=%s\0CEL_WORKSPACE=%s\0CEL_INBOX_ME=%s\0OMP_GATEWAY_TOKEN=sekrit-token-value\0' "$4" "$5" "$6" > "$d/environ"
  # shellcheck disable=SC2086
  printf '%s\0' omp $7 > "$d/cmdline"
}

_rc_cleanup() { unset RC_RS CEL_FANOUT_HERDR CEL_FANOUT_PROC CEL_FANOUT_PS CEL_FANOUT_CRASH; rm -rf "$T"; }

_rc_register() { # [shell=N agent=N start=N profile=P] -> runs register, output in $RC_OUT, status in $RC_RC
  local shell=5000 agent=5001 start=777777 profile=bare kv
  for kv in "$@"; do
    case "$kv" in shell=*) shell="${kv#*=}";; agent=*) agent="${kv#*=}";; start=*) start="${kv#*=}";; profile=*) profile="${kv#*=}";; esac
  done
  RC_RC=0
  RC_OUT="$(cd "$T" && "$BIN" recover register widget WG-1-recover "$T/spec.md" \
    --profile "$profile" --pane w1AN:p1 --shell-pid "$shell" --agent-pid "$agent" --agent-start "$start" \
    --evidence "W710-style: pi pid 5001 under shell 5000, row absent, session path missing (operator-attested)" \
    --attest-legacy 2>&1)" || RC_RC=$?
}
_rc_continue() { RC_RC=0; RC_OUT="$(cd "$T" && "$BIN" recover continue WG-1-recover 2>&1)" || RC_RC=$?; }
_rc_ledger() { cat "$T/.cel/delegations.json" 2>/dev/null || printf 'absent'; }
_rc_n() { local n; n="$(grep -c "$1" "$RS/log" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }
_rc_row() { jq -c '.[] | select(.id == "WG-1-recover")' "$T/.cel/delegations.json"; }
_rc_ready() { # the agent finished starting: interactive_ready, no pending launch
  jq '.result.agents[0].interactive_ready = true | del(.result.agents[0].launch_pending)' "$RS/agents.json" > "$RS/a2" && mv "$RS/a2" "$RS/agents.json"
}
_rc_no_forbidden() { [ ! -s "$RS/forbidden" ] || { echo "forbidden herdr call: $(cat "$RS/forbidden")"; return 1; }; }
# a refusal changed nothing: same ledger bytes, no prompt, nothing forbidden
_rc_refused_untouched() { # <before-snapshot> <needle>
  [ "$RC_RC" -ne 0 ] || { echo "expected a refusal, got success: $RC_OUT"; return 1; }
  assert_contains "$RC_OUT" "$2" || return 1
  assert_eq "$(_rc_ledger)" "$1" || return 1
  assert_eq "$(_rc_n '^agent prompt')" 0 || return 1
  _rc_no_forbidden
}

# ---------------------------------------------------------------------------
test_inspect_is_read_only_and_reports_the_launch_pending_worker() {
  _rc_setup
  local out; out="$(cd "$T" && "$BIN" recover inspect widget WG-1-recover --pane w1AN:p1)"
  assert_eq "$(printf '%s' "$out" | jq -r '.agent.launch_pending')" true
  assert_eq "$(printf '%s' "$out" | jq -r '.ledger_row')" absent
  assert_eq "$(printf '%s' "$out" | jq -r '.session_file_exists')" false
  assert_eq "$(printf '%s' "$out" | jq -r '.foreground[0].start')" 777777
  assert_eq "$(_rc_ledger)" absent
  _rc_no_forbidden
  _rc_cleanup
}

test_register_records_the_absent_row_launch_pending_worker_truthfully() {
  _rc_setup
  _rc_register
  assert_eq "$RC_RC" 0 || { echo "$RC_OUT"; return 1; }
  local row; row="$(_rc_row)"
  assert_eq "$(printf '%s' "$row" | jq -r '.state')" unconfirmed          # no task is claimed running
  assert_eq "$(printf '%s' "$row" | jq -r '.alias')" "$RC_ALIAS"
  assert_eq "$(printf '%s' "$row" | jq -r '.worktree')" "$RC_WT"
  assert_eq "$(printf '%s' "$row" | jq -r '.recovery.provenance')" legacy-operator-attested
  assert_eq "$(printf '%s' "$row" | jq -r '.recovery.dispatch.phase')" registered
  assert_eq "$(printf '%s' "$row" | jq -r '.recovery.observed.session')" unknown
  # what nobody can prove is not claimed
  assert_eq "$(printf '%s' "$row" | jq -r '.recovery.unproven | index("session_file") != null and index("head_source") != null and index("original_start_time") != null')" true
  assert_eq "$(printf '%s' "$row" | jq -r 'has("start_sha") or has("head_source") or has("review")')" false
  assert_eq "$(printf '%s' "$row" | jq -r '.history | length')" 1
  assert_eq "$(printf '%s' "$row" | jq -r '.history[0].state')" unconfirmed
  # no second agent, no task, no keystrokes - and the credential never lands
  assert_eq "$(_rc_n '^agent prompt')" 0
  _rc_no_forbidden
  case "$(_rc_ledger)$RC_OUT" in *sekrit-token-value*) echo "the credential value leaked"; return 1 ;; esac
  _rc_cleanup
}

test_register_twice_is_idempotent_and_keeps_one_row() {
  _rc_setup
  _rc_register; assert_eq "$RC_RC" 0
  local first; first="$(_rc_ledger)"
  _rc_register
  assert_eq "$RC_RC" 0
  assert_contains "$RC_OUT" "already registered"
  assert_eq "$(_rc_ledger)" "$first"
  _rc_cleanup
}

test_register_refuses_every_changed_or_foreign_identity_with_zero_mutation() {
  local case_ before
  for case_ in shell agentpid start env_ws env_role inbox model profile status two_agents name pending branch pane_ws exists; do
    _rc_setup
    before="$(_rc_ledger)"
    case "$case_" in
      shell)     _rc_register shell=4999; local needle="shell is not pid" ;;
      agentpid)  _rc_register agent=5002; local needle="not in the pane's foreground" ;;
      start)     _rc_register start=777778; local needle="different start generation" ;;
      env_ws)    _rc_proc 5001 5000 777777 worker /somewhere/else "$RC_ALIAS" "--model some-model"; _rc_register; local needle="another workspace" ;;
      env_role)  _rc_proc 5001 5000 777777 console "$T" "$RC_ALIAS" "--model some-model"; _rc_register; local needle="CEL_ROLE=worker" ;;
      inbox)     _rc_proc 5001 5000 777777 worker "$T" "widget-wg-1-recov" "--model some-model"; _rc_register; local needle="canonical" ;;
      model)     _rc_proc 5001 5000 777777 worker "$T" "$RC_ALIAS" "--model other-model"; _rc_register; local needle="wrong model/profile" ;;
      profile)   _rc_register profile=swap; local needle="wrong profile" ;;
      status)    jq '.result.agents[0].agent_status = "working"' "$RS/agents.json" > "$RS/a2" && mv "$RS/a2" "$RS/agents.json"; _rc_register; local needle="not idle" ;;
      two_agents) jq '.result.agents += [.result.agents[0]]' "$RS/agents.json" > "$RS/a2" && mv "$RS/a2" "$RS/agents.json"; _rc_register; local needle="exactly one agent" ;;
      name)      jq '.result.agents[0].name = "someone-elses-worker"' "$RS/agents.json" > "$RS/a2" && mv "$RS/a2" "$RS/agents.json"; _rc_register; local needle="exactly one agent" ;;
      pending)   jq 'del(.result.agents[0].launch_pending)' "$RS/agents.json" > "$RS/a2" && mv "$RS/a2" "$RS/agents.json"; _rc_register; local needle="pending launch" ;;
      branch)    git -C "$RC_WT" checkout -q -b other-branch; _rc_register; local needle="no worktree for branch" ;;
      pane_ws)   jq '.result.workspaces[0].workspace_id = "wOTHER"' "$RS/ws.json" > "$RS/w2" && mv "$RS/w2" "$RS/ws.json"; _rc_register; local needle="not in the herdr workspace" ;;
      exists)    printf '[{"id":"WG-1-recover","state":"running","alias":"x","pane":"y"}]' > "$T/.cel/delegations.json" 2>/dev/null || { mkdir -p "$T/.cel"; printf '[{"id":"WG-1-recover","state":"running","alias":"x","pane":"y"}]' > "$T/.cel/delegations.json"; }
                 before="$(_rc_ledger)"; _rc_register; local needle="not this recovery" ;;
    esac
    _rc_refused_untouched "$before" "$needle" || { echo "case $case_"; _rc_cleanup; return 1; }
    _rc_cleanup
  done
}

test_register_refuses_while_the_original_delegate_or_start_is_still_alive() {
  _rc_setup
  printf '4242 /bin/bash /x/cel-fanout delegate widget WG-1-recover /s/spec.md --profile bare\n' > "$T/ps.txt"
  _rc_register
  _rc_refused_untouched absent "original launch may still complete" || { _rc_cleanup; return 1; }
  printf '4243 herdr agent start %s --kind omp --pane w1AN:p1 -- --model some-model\n' "$RC_ALIAS" > "$T/ps.txt"
  _rc_register
  _rc_refused_untouched absent "original launch may still complete" || { _rc_cleanup; return 1; }
  _rc_cleanup
}

test_register_requires_the_explicit_legacy_attestation_and_every_coordinate() {
  _rc_setup
  RC_OUT="$(cd "$T" && "$BIN" recover register widget WG-1-recover "$T/spec.md" --profile bare --pane w1AN:p1 \
    --shell-pid 5000 --agent-pid 5001 --agent-start 777777 --evidence x 2>&1)" && RC_RC=0 || RC_RC=$?
  _rc_refused_untouched absent "--attest-legacy" || { _rc_cleanup; return 1; }
  RC_OUT="$(cd "$T" && "$BIN" recover register widget WG-1-recover "$T/spec.md" --profile bare --pane w1AN:p1 \
    --attest-legacy --evidence x 2>&1)" && RC_RC=0 || RC_RC=$?
  _rc_refused_untouched absent "--shell-pid is required" || { _rc_cleanup; return 1; }
  _rc_cleanup
}

test_a_held_ledger_lock_is_refused_not_raced_for_register_and_continue() {
  _rc_setup
  mkdir -p "$T/.cel"
  ( exec 9>"$T/.cel/delegations.lock"; flock 9; sleep 4 ) &
  local holder=$!
  sleep 0.3
  _rc_register
  _rc_refused_untouched absent "lock is held" || { kill $holder 2>/dev/null; _rc_cleanup; return 1; }
  _rc_continue
  assert_contains "$RC_OUT" "lock is held"
  assert_eq "$(_rc_n '^agent prompt')" 0
  kill $holder 2>/dev/null; wait $holder 2>/dev/null || true
  _rc_cleanup
}

# ---------------------------------------------------------------------------
test_continue_refuses_a_still_pending_launch_and_names_the_upstream_prerequisite() {
  _rc_setup
  _rc_register; assert_eq "$RC_RC" 0
  local before; before="$(_rc_ledger)"
  _rc_continue
  _rc_refused_untouched "$before" "UPSTREAM PREREQUISITE" || { _rc_cleanup; return 1; }
  assert_eq "$(_rc_row | jq -r '.recovery.dispatch.phase')" registered
  assert_eq "$(_rc_row | jq -r '.state')" unconfirmed
  _rc_cleanup
}

test_continue_delivers_the_task_exactly_once_and_runs_only_on_evidence() {
  _rc_setup
  _rc_register; assert_eq "$RC_RC" 0
  _rc_ready; touch "$RS/turn_on_prompt"
  _rc_continue
  assert_eq "$RC_RC" 0 || { echo "$RC_OUT"; return 1; }
  assert_eq "$(_rc_n '^agent prompt')" 1
  _rc_no_forbidden
  local row; row="$(_rc_row)"
  assert_eq "$(printf '%s' "$row" | jq -r '.state')" running
  assert_eq "$(printf '%s' "$row" | jq -r '.recovery.dispatch.phase')" accepted
  assert_eq "$(printf '%s' "$row" | jq -r '[.history[].state] | join(",")')" "unconfirmed,running"
  # the same kickoff a delegated worker gets, for the registered id, to the
  # product's full orchestrator mailbox
  local p; p="$(cat "$RS/prompt.txt")"
  assert_contains "$p" "Your task spec is $T/spec.md"
  assert_contains "$p" "cel inbox send widget-orch"
  assert_contains "$p" "--workspace profiled"
  # a second continue is a report, never a second prompt
  _rc_continue
  assert_eq "$RC_RC" 0
  assert_contains "$RC_OUT" "already accepted"
  assert_eq "$(_rc_n '^agent prompt')" 1
  _rc_cleanup
}

test_continue_does_not_claim_running_without_task_evidence_and_never_resubmits() {
  _rc_setup
  _rc_register; assert_eq "$RC_RC" 0
  _rc_ready                       # prompt is accepted by herdr but nothing shows execution
  _rc_continue
  [ "$RC_RC" -ne 0 ] || { echo "claimed success without evidence"; return 1; }
  assert_eq "$(_rc_n '^agent prompt')" 1
  assert_eq "$(_rc_row | jq -r '.state')" unconfirmed
  assert_eq "$(_rc_row | jq -r '.recovery.dispatch.phase')" unconfirmed-acceptance
  _rc_continue
  assert_contains "$RC_OUT" "NOT resubmitting"
  assert_eq "$(_rc_n '^agent prompt')" 1                 # debt preserved, no duplicate paid work
  assert_eq "$(_rc_row | jq -r '.state')" unconfirmed
  # later the agent shows a turn: the re-check records it, still one prompt
  cp "$RS/turn.txt" "$RS/read.txt"
  _rc_continue
  assert_eq "$RC_RC" 0
  assert_eq "$(_rc_row | jq -r '.state')" running
  assert_eq "$(_rc_n '^agent prompt')" 1
  _rc_cleanup
}

test_an_unreadable_pane_is_not_acceptance_evidence() {
  _rc_setup
  _rc_register; _rc_ready
  : > "$RS/read.txt"
  _rc_continue
  [ "$RC_RC" -ne 0 ] || { echo "an unreadable pane was taken as proof"; return 1; }
  assert_eq "$(_rc_row | jq -r '.state')" unconfirmed
  _rc_cleanup
}

test_a_prompt_herdr_refuses_delivers_nothing_and_leaves_the_row_continuable() {
  _rc_setup
  _rc_register; _rc_ready
  printf 'not_ready' > "$RS/prompt_mode"
  _rc_continue
  [ "$RC_RC" -ne 0 ] || return 1
  assert_contains "$RC_OUT" "nothing was delivered"
  assert_eq "$(_rc_row | jq -r '.recovery.dispatch.phase')" registered
  printf 'ok' > "$RS/prompt_mode"; touch "$RS/turn_on_prompt"
  _rc_continue
  assert_eq "$RC_RC" 0
  assert_eq "$(_rc_row | jq -r '.state')" running
  _rc_cleanup
}

test_a_prompt_error_that_does_not_say_delivered_is_ambiguous_and_never_retried() {
  _rc_setup
  _rc_register; _rc_ready
  printf 'error' > "$RS/prompt_mode"
  _rc_continue
  assert_eq "$(_rc_row | jq -r '.recovery.dispatch.phase')" ambiguous
  printf 'ok' > "$RS/prompt_mode"
  _rc_continue
  [ "$RC_RC" -ne 0 ] || return 1
  assert_eq "$(_rc_n '^agent prompt')" 1
  assert_eq "$(_rc_row | jq -r '.state')" unconfirmed
  _rc_cleanup
}

# ---- crashes --------------------------------------------------------------
test_a_crash_right_after_registration_loses_nothing_and_a_retry_does_not_double() {
  _rc_setup
  RC_RC=0
  CEL_FANOUT_CRASH=after-register _rc_register
  [ "$RC_RC" -ne 0 ] || { echo "the crash point did not fire"; return 1; }
  assert_eq "$(_rc_row | jq -r '.state')" unconfirmed           # durable
  unset CEL_FANOUT_CRASH
  local first; first="$(_rc_ledger)"
  _rc_register
  assert_eq "$RC_RC" 0
  assert_contains "$RC_OUT" "already registered"
  assert_eq "$(_rc_ledger)" "$first"
  _rc_cleanup
}

test_a_crash_after_the_prompt_before_the_ack_is_read_as_maybe_delivered_not_resent() {
  _rc_setup
  _rc_register; _rc_ready; touch "$RS/turn_on_prompt"
  CEL_FANOUT_CRASH=after-prompt _rc_continue
  [ "$RC_RC" -ne 0 ] || { echo "the crash point did not fire"; return 1; }
  unset CEL_FANOUT_CRASH
  assert_eq "$(_rc_row | jq -r '.recovery.dispatch.phase')" submitting
  assert_eq "$(_rc_n '^agent prompt')" 1
  _rc_continue                                    # the retry only LOOKS
  assert_eq "$RC_RC" 0
  assert_contains "$RC_OUT" "nothing was sent now"
  assert_eq "$(_rc_n '^agent prompt')" 1
  assert_eq "$(_rc_row | jq -r '.state')" running
  _rc_cleanup
}

test_a_crash_before_the_prompt_keeps_the_debt_and_does_not_guess() {
  _rc_setup
  _rc_register; _rc_ready
  CEL_FANOUT_CRASH=before-prompt _rc_continue
  unset CEL_FANOUT_CRASH
  assert_eq "$(_rc_row | jq -r '.recovery.dispatch.phase')" submitting
  assert_eq "$(_rc_n '^agent prompt')" 0
  _rc_continue
  [ "$RC_RC" -ne 0 ] || return 1
  assert_eq "$(_rc_n '^agent prompt')" 0                 # unknown is not a licence to send
  assert_eq "$(_rc_row | jq -r '.state')" unconfirmed
  assert_eq "$(_rc_row | jq -r '.recovery.dispatch.phase')" unconfirmed-acceptance
  _rc_cleanup
}

# ---- consumers ------------------------------------------------------------
test_status_collect_release_and_reconcile_leave_an_unresolved_recovery_alone() {
  _rc_setup
  _rc_register
  local before; before="$(_rc_row | jq -S -c 'del(.history)')"
  local out rc=0
  out="$(cd "$T" && "$BIN" release WG-1-recover --discard 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "released an unresolved recovery"; return 1; }
  assert_contains "$out" "recovered launch whose dispatch is unresolved"
  rc=0; out="$(cd "$T" && "$BIN" collect WG-1-recover 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "collected an unresolved recovery"; return 1; }
  [ -d "$RC_WT" ] || { echo "the worktree went"; return 1; }
  # status and reconcile, with herdr unable to find the agent, must not move it
  cat > "$T/gh" <<'EOF'
#!/usr/bin/env bash
echo '[]'
EOF
  chmod +x "$T/gh"
  (cd "$T" && CEL_FANOUT_GH="$T/gh" "$BIN" status >/dev/null 2>&1) || true
  (cd "$T" && CEL_FANOUT_GH="$T/gh" "$BIN" reconcile >/dev/null 2>&1) || true
  assert_eq "$(_rc_row | jq -S -c 'del(.history)')" "$before"
  assert_eq "$(_rc_row | jq -r '.state')" unconfirmed
  assert_eq "$(_rc_n '^agent prompt')" 0
  _rc_no_forbidden
  _rc_cleanup
}

test_recover_is_not_a_worker_verb() {
  _rc_setup
  local out rc=0
  # guard_role_of reads the cwd: stand in a worker worktree
  out="$(cd "$RC_WT" && CEL_WORKTREES="$T/wt" "$BIN" recover register widget WG-1-recover "$T/spec.md" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "a worker ran recover"; return 1; }
  assert_contains "$out" "a worker does not recover"
  assert_eq "$(_rc_ledger)" absent
  _rc_cleanup
}
