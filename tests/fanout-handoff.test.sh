# shellcheck shell=bash
# `cel-fanout handoff` (CEL-retained-runtime-handoff-261018): retained-worktree
# runtime handoff. Real temporary git worktrees (committed, ahead, diverged,
# dirty and untracked bytes), a real ledger and a real operation store; only
# herdr and /proc are fixtures. The herdr stub is STATEFUL: `agent stop` removes
# the agent and its process, `agent start` creates a new one with the argv and
# environment the launcher actually typed, so what is asserted is what the
# consumer sees (ledger, operation store, source bytes, counted herdr calls),
# not echoes. Every test drives the real cel-fanout.
source "$CEL_ROOT/lib/common.sh"
BIN="$CEL_ROOT/core/skills/fanout/bin/cel-fanout"

_h_setup() { # [no-stop]  - herdr's schema lists agent.stop unless "no-stop"
  T="$(mktemp -d)"; T="$(cd "$T" && pwd)"
  cp "$CEL_ROOT/tests/fixtures/ws-profiles/workspace.yaml" "$T/"
  # the replacement profile: a different harness, exact model + thinking
  sed -i 's|^  bare:      { runtime: omp, model: some-model }|  bare:      { runtime: omp, model: some-model }\n  pitarget:  { runtime: pi, model: claude-sonnet-5-5, thinking: medium }|' "$T/workspace.yaml"
  RS="$T/rs"; mkdir -p "$RS" "$T/proc" "$T/repos/widget"
  git -C "$T/repos/widget" init -q -b main
  git -C "$T/repos/widget" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  H_WT="$T/wt/WG-1-handoff"
  git -C "$T/repos/widget" worktree add -q -b WG-1-handoff "$H_WT"
  git -C "$H_WT" config user.email t@t; git -C "$H_WT" config user.name t
  echo "tracked v1" > "$H_WT/a.txt"; git -C "$H_WT" add a.txt; git -C "$H_WT" commit -q -m "add a"
  H_ALIAS="widget-wg-1-handoff"
  printf 'handoff spec\n' > "$T/spec.md"
  : > "$T/ps.txt"; : > "$T/ss.txt"
  STUB="$T/herdr"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
RS="${H_RS:?}"; PROC="${CEL_FANOUT_PROC:?}"
echo "$*" >> "$RS/log"
mode() { cat "$RS/$1" 2>/dev/null || echo "${2:-ok}"; }
setagent() { # kind pid start  -> agents/pane/pinfo/proc
  local kind="$1" pid="$2"
  jq -n --arg a "$ALIAS" --arg k "$kind" '{result:{agents:[{agent:$k, agent_session:{agent:$k,kind:"path",source:"x",value:"'"$RS"'/session.jsonl"},
     agent_status:"idle", interactive_ready:true, name:$a, pane_id:"w1AN:p1", workspace_id:"w1AN", terminal_id:"term_a"}]}}' > "$RS/agents.json"
  jq -n --arg k "$kind" '{result:{pane:{pane_id:"w1AN:p1",terminal_id:"term_a",agent:$k}}}' > "$RS/pane.json"
  jq -n --argjson p "$pid" '{result:{process_info:{pane_id:"w1AN:p1",shell_pid:5000,foreground_process_group_id:$p,foreground_processes:[{pid:$p,name:"agent"}]}}}' > "$RS/pinfo.json"
}
noagent() {
  echo '{"result":{"agents":[]}}' > "$RS/agents.json"
  echo '{"result":{"pane":{"pane_id":"w1AN:p1","terminal_id":"term_a"}}}' > "$RS/pane.json"
  echo '{"result":{"process_info":{"pane_id":"w1AN:p1","shell_pid":5000,"foreground_process_group_id":5000,"foreground_processes":[{"pid":5000,"name":"zsh"}]}}}' > "$RS/pinfo.json"
}
ALIAS="$(cat "$RS/alias")"
case "$1 $2" in
  "--version "*) echo "herdr 0.9.1" ;;
  "api schema") cat "$RS/schema.json" ;;
  "pane get") cat "$RS/pane.json" ;;
  "pane process-info") cat "$RS/pinfo.json" ;;
  "agent list") cat "$RS/agents.json" ;;
  "workspace list") cat "$RS/ws.json" ;;
  "agent read")
    if [ "$(mode read_mode)" = changing ]; then n="$(cat "$RS/readn" 2>/dev/null || echo 0)"; echo $((n+1)) > "$RS/readn"; echo "working step $n"; else cat "$RS/read.txt"; fi ;;
  "agent stop")
    echo "$3" >> "$RS/stops"
    case "$(mode stop_mode)" in
      ok) rm -rf "$PROC/5001"; noagent; [ ! -f "$RS/append_on_stop" ] || cat "$RS/append_on_stop" >> "$RS/session.jsonl"; [ ! -f "$RS/rewrite_on_stop" ] || cat "$RS/rewrite_on_stop" > "$RS/session.jsonl"; echo '{"result":{"stopped":true}}' ;;
      lost) echo '{"result":{"stopped":true}}' ;;           # reply claims success, nothing happened
      error) echo '{"error":{"code":"agent_stop_timeout","message":"timed out"}}' >&2; exit 1 ;;
    esac ;;
  "pane send-text") printf '%s' "$4" > "$RS/sendtext" ;;
  "agent start")
    echo "$*" >> "$RS/starts"
    case "$(mode start_mode)" in
      fail) echo '{"error":{"code":"agent_start_timeout"}}' >&2; exit 1 ;;
      ok|failafter)
        kind="$5"; shift 8   # agent start NAME --kind K --pane P --
        d="$PROC/6001"; mkdir -p "$d"
        z=""; for i in $(seq 1 17); do z="$z 0"; done
        printf '6001 (agent) S 5000%s 888888 0 0\n' "$z" > "$d/stat"
        { for t in $(cat "$RS/sendtext" 2>/dev/null); do case "$t" in CEL_*=*|OMP_*=*) printf '%s\0' "$t" ;; esac; done; } > "$d/environ"
        if [ -f "$RS/cmdline_override" ]; then printf '%s\0' "$kind" $(cat "$RS/cmdline_override") > "$d/cmdline"; else printf '%s\0' "$kind" "$@" > "$d/cmdline"; fi
        setagent "$kind" 6001
        printf 'ctx 0.0%%\n' > "$RS/read.txt"
        [ "$(mode start_mode)" != failafter ] || { echo '{"error":{"code":"agent_start_timeout"}}' >&2; exit 1; } ;;
    esac ;;
  "agent prompt")
    printf '%s' "$4" > "$RS/prompt.txt"; echo x >> "$RS/prompts"
    case "$(mode prompt_mode)" in
      ok) cp "$RS/turn.txt" "$RS/read.txt"; echo '{"result":{"prompted":true}}' ;;
      noturn) echo '{"result":{"prompted":true}}' ;;
      notool) printf 'ctx 1.0%%\n● I will look at it\n' > "$RS/read.txt"; echo '{"result":{"prompted":true}}' ;;
      unknown) echo '{"error":{"code":"agent_prompt_stalled"}}' >&2; exit 1 ;;
    esac ;;
  "pane run"|"pane send-keys"|"agent send-keys"|"pane close"|"pane release-agent"|"pane report-agent"|"pane report-agent-session"|"agent rename"|"worktree create"|"pane rename"|"tab rename")
    echo "$*" >> "$RS/other" ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$STUB"
  printf '%s' "$H_ALIAS" > "$RS/alias"
  export H_RS="$RS" CEL_FANOUT_HERDR="$STUB" CEL_FANOUT_PROC="$T/proc" CEL_FANOUT_PS="$T/ps.txt" CEL_FANOUT_SS="$T/ss.txt"
  export CEL_FANOUT_CONFIRM_SLEEP=0 CEL_FANOUT_CONFIRM_TRIES=2 CEL_FANOUT_QUIET_SECS=0 CEL_PANE_READY_POLL_MS=1 CEL_PANE_READY_MS=2000
  _h_schema "${1:-stop}"
  jq -n --arg w "$H_WT" '{result:{workspaces:[{workspace_id:"w1AN",worktree:{checkout_path:$w}}]}}' > "$RS/ws.json"
  printf 'ctx 3.0%%\n' > "$RS/read.txt"
  printf 'ctx 4.0%%\n● Read(%s)\n● continuing the task\n' "$T/spec.md" > "$RS/turn.txt"
  printf '%s\n' "$(jq -nc --arg c "$H_WT" '{type:"session",version:3,id:"00000000-0000-0000-0000-000000000001",cwd:$c}')" '{"type":"message","message":{"role":"user","content":"old session bytes"}}' > "$RS/session.jsonl"
  : > "$RS/log"
  # the OLD omp agent: pid 5001 under shell 5000
  ( ALIAS="$H_ALIAS"; RS="$RS"
    jq -n --arg a "$H_ALIAS" --arg s "$RS/session.jsonl" '{result:{agents:[{agent:"omp", agent_session:{agent:"omp",kind:"path",source:"x",value:$s},
       agent_status:"idle", interactive_ready:true, name:$a, pane_id:"w1AN:p1", workspace_id:"w1AN", terminal_id:"term_a"}]}}' > "$RS/agents.json"
    printf '{"result":{"pane":{"pane_id":"w1AN:p1","terminal_id":"term_a","agent":"omp"}}}' > "$RS/pane.json"
    printf '{"result":{"process_info":{"pane_id":"w1AN:p1","shell_pid":5000,"foreground_process_group_id":5001,"foreground_processes":[{"pid":5001,"name":"omp"}]}}}' > "$RS/pinfo.json" )
  _h_proc 5000 1 100 zsh; _h_proc 5001 5000 777777 omp
  mkdir -p "$T/.cel"
  jq -n --arg wt "$H_WT" --arg spec "$T/spec.md" --arg a "$H_ALIAS" \
    '[{id:"WG-1-handoff", repo:"widget", branch:"WG-1-handoff", alias:$a, herdr_ws:"w1AN", pane:"w1AN:p1", worktree:$wt, spec:$spec,
       state:"running", created:"2026-10-17T00:00:00Z", profile:"bare", runtime:"omp", model:"some-model", thinking:"xhigh", ticket:"", provider:"",
       shape:"ship", launch:{phase:"dispatched", at:"2026-10-17T00:00:00Z"},
       review:{verdict:"approved", head:"oldhead", head_source:"explicit"},
       history:[{state:"running", at:"2026-10-17T00:00:00Z", by:"orchestrator"}]}]' > "$T/.cel/delegations.json"
}
_h_schema() { # stop | no-stop | stop-nofence
  local req='{"properties":{"method":{"const":"agent.start"}}},{"properties":{"method":{"const":"agent.prompt"}}},{"properties":{"method":{"const":"pane.close"}}}'
  local defs='{}'
  case "$1" in
    stop)         req="$req"',{"properties":{"method":{"const":"agent.stop"},"params":{"$ref":"#/schemas/request/$defs/AgentStopParams"}}}'
                  defs='{"AgentStopParams":{"properties":{"name":{},"expected_pid":{},"expected_start":{}}}}' ;;
    stop-nofence) req="$req"',{"properties":{"method":{"const":"agent.stop"},"params":{"$ref":"#/schemas/request/$defs/AgentStopParams"}}}'
                  defs='{"AgentStopParams":{"properties":{"name":{}}}}' ;;
  esac
  printf '{"protocol":22,"schemas":{"request":{"oneOf":[%s],"$defs":%s}}}' "$req" "$defs" > "$RS/schema.json"
}
_h_proc() { # pid ppid start comm
  local d="$T/proc/$1" i z=""
  mkdir -p "$d"
  for i in $(seq 1 17); do z="$z 0"; done
  printf '%s (%s) S %s%s %s 0 0\n' "$1" "$4" "$2" "$z" "$3" > "$d/stat"
  case "$4" in omp) printf 'CEL_ROLE=worker\0CEL_WORKSPACE=%s\0CEL_INBOX_ME=%s\0OMP_GATEWAY_TOKEN=sekrit-token-value\0' "$T" "$H_ALIAS" > "$d/environ"
                   printf '%s\0' omp --model some-model --thinking xhigh > "$d/cmdline" ;;
               *) : > "$d/environ"; printf '%s\0' "$4" > "$d/cmdline" ;; esac
}
_h_cleanup() { unset H_RS CEL_FANOUT_HERDR CEL_FANOUT_PROC CEL_FANOUT_PS CEL_FANOUT_SS CEL_FANOUT_CRASH; rm -rf "$T"; }

_h_ledger() { cat "$T/.cel/delegations.json" 2>/dev/null; }
_h_row() { jq -c '.[] | select(.id == "WG-1-handoff")' "$T/.cel/delegations.json"; }
_h_n() { local n; n="$(grep -c "$1" "$RS/log" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }
_h_lines() { local n; n="$(wc -l < "$RS/$1" 2>/dev/null || true)"; printf '%s' "${n:-0}" | tr -d ' '; }
_h_inspect() { # [profile] -> $H_PLAN
  H_PLAN="$(cd "$T" && "$BIN" handoff inspect WG-1-handoff --pane w1AN:p1 --profile "${1:-pitarget}" 2>&1)" || true
}
# the exact apply line inspect emits, run for real
_h_apply() { # [extra args]  -> H_RC/H_OUT
  local p; p="$H_PLAN"
  H_RC=0
  H_OUT="$(cd "$T" && "$BIN" handoff apply WG-1-handoff --profile "${H_PROFILE:-pitarget}" --pane w1AN:p1 \
    --shell-pid "$(printf '%s' "$p" | jq -r '.plan.runtime.shell_pid')" --agent-pid "$(printf '%s' "$p" | jq -r '.plan.runtime.agent_pid')" \
    --agent-start "$(printf '%s' "$p" | jq -r '.plan.runtime.agent_start')" --head "$(printf '%s' "$p" | jq -r '.plan.source.head')" \
    --source-digest "$(printf '%s' "$p" | jq -r '.plan.source.digest')" --evidence "inspected; idle, no children, source bound" "$@" 2>&1)" || H_RC=$?
}
# bytes of every local work file + private evidence, for byte-identical preservation
_h_bytes() { (cd "$H_WT" && { git rev-parse HEAD; git status --porcelain=v1 --untracked-files=all; find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum; }) | sha256sum; }
_h_dirty() { echo "tracked v2 (uncommitted)" > "$H_WT/a.txt"; echo "untracked work" > "$H_WT/new.txt"; mkdir -p "$H_WT/.agent"; echo "private evidence" > "$H_WT/.agent/result.md"; }
_h_refused_untouched() { # <ledger-before> <bytes-before> <needle>
  [ "$H_RC" -ne 0 ] || { echo "expected a refusal, got success: $H_OUT"; return 1; }
  assert_contains "$H_OUT" "$3" || return 1
  assert_eq "$(_h_ledger)" "$1" || return 1
  assert_eq "$(_h_bytes)" "$2" || return 1
  [ ! -s "$RS/stops" ] && [ ! -s "$RS/starts" ] && [ ! -s "$RS/prompts" ] && [ ! -s "$RS/other" ] || { echo "a herdr mutation happened: stops=$(cat "$RS/stops" 2>/dev/null) starts=$(cat "$RS/starts" 2>/dev/null)"; return 1; }
  [ ! -d "$T/.cel/handoffs" ] || [ -z "$(ls "$T/.cel/handoffs"/*.json 2>/dev/null)" ] || { echo "an operation record was written by a refusal"; return 1; }
}

# ---------------------------------------------------------------------------
test_inspect_is_read_only_and_reports_source_runtime_and_the_cross_harness_truth() {
  _h_setup; _h_dirty
  local l b; l="$(_h_ledger)"; b="$(_h_bytes)"
  _h_inspect
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" true || { echo "$H_PLAN"; return 1; }
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.plan.source.dirty_and_untracked')" 3
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.plan.context.mode')" cross-harness-context-transfer
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.plan.context.lossless_native_resume')" false
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.plan.runtime.session.exists')" true
  assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.apply_command')" "--source-digest"
  assert_eq "$(_h_ledger)" "$l"; assert_eq "$(_h_bytes)" "$b"
  [ ! -d "$T/.cel/handoffs" ] || { echo "inspect wrote an operation store"; return 1; }
  [ ! -s "$RS/stops" ] && [ ! -s "$RS/starts" ] && [ ! -s "$RS/prompts" ] && [ ! -s "$RS/other" ] || return 1
  _h_cleanup
}

test_701_name_held_old_runtime_is_retired_once_and_exactly_one_new_agent_starts() {
  _h_setup; _h_dirty
  local before_bytes; before_bytes="$(_h_bytes)"
  _h_inspect; _h_apply
  assert_eq "$H_RC" 0 || { echo "$H_OUT"; return 1; }
  assert_eq "$(_h_lines stops)" 1; assert_eq "$(_h_lines starts)" 1; assert_eq "$(_h_lines prompts)" 1
  # the replacement is the pi target on exactly the profile's model and thinking
  grep -q -- "--model" "$T/proc/6001/cmdline" && tr '\0' ' ' < "$T/proc/6001/cmdline" | grep -q -- "--model claude-sonnet-5-5 --thinking medium" || { tr '\0' ' ' < "$T/proc/6001/cmdline"; return 1; }
  [ ! -d "$T/proc/5001" ] || { echo "the old process still exists"; return 1; }
  local row; row="$(_h_row)"
  assert_eq "$(printf '%s' "$row" | jq -r '.state')" running
  assert_eq "$(printf '%s' "$row" | jq -r '.runtime')" pi
  assert_eq "$(printf '%s' "$row" | jq -r '.model')" claude-sonnet-5-5
  assert_eq "$(printf '%s' "$row" | jq -r '.handoff.phase')" done
  assert_eq "$(printf '%s' "$row" | jq -r '.handoff.prior.runtime')" omp
  assert_eq "$(printf '%s' "$row" | jq -r '.id')" WG-1-handoff                       # the same delegation
  assert_eq "$(jq 'length' "$T/.cel/delegations.json")" 1                            # no second row
  # no stale approval travels to the new owner; it is kept as evidence only
  assert_eq "$(printf '%s' "$row" | jq -r 'has("review")')" false
  assert_eq "$(printf '%s' "$row" | jq -r '.handoff.prior_review.verdict')" approved
  assert_eq "$(printf '%s' "$row" | jq -r '.handoff.review_carried')" false
  # the source and the private evidence are byte-identical
  assert_eq "$(_h_bytes)" "$before_bytes"
  assert_eq "$(cat "$H_WT/.agent/result.md")" "private evidence"
  # the old session stays where it was; the old pane text and a brief were preserved
  [ -f "$RS/session.jsonl" ] || return 1
  local op; op="$(ls "$T/.cel/handoffs"/*.json | head -1)"
  [ -s "${op%.json}.pane-before.txt" ] && [ -s "${op%.json}.brief.md" ] || { echo "evidence copies missing"; return 1; }
  assert_contains "$(cat "${op%.json}.brief.md")" "NOT a lossless native session resume"
  # the task prompt names the brief and the spec
  assert_contains "$(cat "$RS/prompt.txt")" "${op%.json}.brief.md"
  assert_contains "$(cat "$RS/prompt.txt")" "$T/spec.md"
  # forbidden mechanisms were never used: no pane close, keys, release-agent, rename
  [ ! -s "$RS/other" ] || [ "$(grep -vc '^pane run' "$RS/other")" = 0 ] || { echo "forbidden call: $(cat "$RS/other")"; return 1; }
  case "$(_h_ledger)$H_OUT$(cat "$op")" in *sekrit-token-value*) echo "credential leaked"; return 1 ;; esac
  _h_cleanup
}

test_replaying_a_completed_or_lost_response_discovers_the_same_operation() {
  _h_setup; _h_dirty
  _h_inspect; _h_apply; assert_eq "$H_RC" 0
  local ledger; ledger="$(_h_ledger)"
  _h_apply                                  # the retried request, same arguments
  assert_eq "$H_RC" 0 || { echo "$H_OUT"; return 1; }
  assert_contains "$H_OUT" "already complete"
  assert_eq "$(_h_ledger)" "$ledger"
  assert_eq "$(_h_lines stops)" 1; assert_eq "$(_h_lines starts)" 1; assert_eq "$(_h_lines prompts)" 1
  assert_eq "$(ls "$T/.cel/handoffs"/*.json | wc -l | tr -d ' ')" 1
  _h_cleanup
}

test_a_crash_at_every_point_resumes_the_same_operation_without_doubles_or_keeps_debt() {
  # expected outcome per crash point: done = the replay completes; debt = the
  # honest answer is "unknown", so it stays unresolved and is NEVER repeated
  local spec point want i
  for spec in ho-after-record:done ho-after-admit:done ho-before-stop:done ho-after-stop:done ho-before-start:debt ho-after-start:done ho-before-prompt:debt ho-after-prompt:done; do
    point="${spec%%:*}"; want="${spec##*:}"
    _h_setup; _h_dirty
    _h_inspect
    export CEL_FANOUT_CRASH="$point"; _h_apply; unset CEL_FANOUT_CRASH
    [ "$H_RC" -ne 0 ] || { echo "$point: the crash point did not fire"; return 1; }
    assert_eq "$(_h_row | jq -r '.handoff.phase != "done"')" true || { echo "$point"; return 1; }
    local debt; debt="$(basename "$(ls "$T/.cel/handoffs"/*.json | head -1)" .json)"
    for i in 1 2; do _h_apply --reissue-retire; [ "$H_RC" -ne 0 ] || break; done
    assert_eq "$(_h_row | jq -r '.handoff.id')" "$debt" || return 1
    assert_eq "$(ls "$T/.cel/handoffs"/*.json | wc -l | tr -d ' ')" 1 || return 1
    [ "$(_h_lines starts)" -le 1 ] && [ "$(_h_lines prompts)" -le 1 ] && [ "$(_h_lines stops)" -le 2 ] \
      || { echo "$point: doubled launch: starts=$(_h_lines starts) prompts=$(_h_lines prompts) stops=$(_h_lines stops)"; return 1; }
    if [ "$want" = done ]; then
      assert_eq "$H_RC" 0 || { echo "$point: $H_OUT"; return 1; }
      assert_eq "$(_h_row | jq -r '.handoff.phase')" done || { echo "$point"; return 1; }
      assert_eq "$(_h_row | jq -r '.state')" running
    else
      [ "$H_RC" -ne 0 ] || { echo "$point: should stay debt"; return 1; }
      assert_eq "$(_h_row | jq -r '.state')" unconfirmed
      assert_eq "$(_h_row | jq -r '.handoff.phase != "done"')" true
    fi
    _h_cleanup
  done
}

test_without_the_stop_primitive_nothing_is_retired_and_the_missing_call_is_named() {
  _h_setup no-stop; _h_dirty
  local l b; l="$(_h_ledger)"; b="$(_h_bytes)"
  _h_inspect
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" false
  assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "EXACT MISSING PRIMITIVE: agent.stop"
  assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "pane.close destroys the shell"
  H_PLAN="$(printf '%s' "$H_PLAN")"
  _h_apply
  _h_refused_untouched "$l" "$b" "agent.stop" || return 1
  _h_cleanup
}

test_711_ahead_and_diverged_dirty_work_is_classified_by_git_and_preserved_byte_identically() {
  _h_setup; _h_dirty
  # remote ref is an ancestor of HEAD: AHEAD
  git -C "$H_WT" update-ref refs/remotes/origin/WG-1-handoff "$(git -C "$H_WT" rev-parse HEAD~1)"
  local b; b="$(_h_bytes)"
  _h_inspect
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.plan.source.relation')" ahead
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.plan.source.ahead')" 1
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" true || { echo "$H_PLAN"; return 1; }
  _h_apply; assert_eq "$H_RC" 0 || { echo "$H_OUT"; return 1; }
  assert_eq "$(_h_bytes)" "$b"
  _h_cleanup
  # TRUE divergence: a remote commit that is not an ancestor
  _h_setup; _h_dirty
  local other; other="$(git -C "$H_WT" -c user.email=t@t -c user.name=t commit-tree -p HEAD~1 -m remote-only "$(git -C "$H_WT" rev-parse HEAD~1^{tree})")"
  git -C "$H_WT" update-ref refs/remotes/origin/WG-1-handoff "$other"
  b="$(_h_bytes)"
  _h_inspect
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.plan.source.relation')" diverged
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" true || { echo "$H_PLAN"; return 1; }
  _h_apply; assert_eq "$H_RC" 0 || { echo "$H_OUT"; return 1; }
  assert_eq "$(_h_bytes)" "$b"                                   # no reset, stash, checkout, rebase
  assert_eq "$(git -C "$H_WT" rev-parse refs/remotes/origin/WG-1-handoff)" "$other"   # no fetch or push
  assert_eq "$(git -C "$H_WT" stash list | wc -l | tr -d ' ')" 0
  _h_cleanup
}

test_705_unknown_launch_debt_refuses_every_mutation_and_names_the_prerequisite() {
  _h_setup; _h_dirty
  (cd "$T" && "$BIN" handoff hold WG-1-handoff --kind launch-unknown --evidence "reuse timed out UNKNOWN; launcher pid never captured; later absence of a launcher proves nothing" >/dev/null)
  local l b; l="$(_h_ledger)"; b="$(_h_bytes)"
  _h_inspect
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" false
  assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "UPSTREAM PREREQUISITE"
  H_RC=0; H_OUT="$(cd "$T" && "$BIN" handoff apply WG-1-handoff --profile pitarget --pane w1AN:p1 --shell-pid 5000 --agent-pid 5001 \
    --agent-start 777777 --head "$(git -C "$H_WT" rev-parse HEAD)" --source-digest "$(printf '%s' "$H_PLAN" | jq -r '.plan.source.digest')" --evidence x 2>&1)" || H_RC=$?
  _h_refused_untouched "$l" "$b" "launch whose outcome is UNKNOWN" || return 1
  # absence and null fields do not settle it, and no sibling verb will either
  for v in "collect WG-1-handoff" "release WG-1-handoff" "handback WG-1-handoff msg --by me"; do
    local out; out="$(cd "$T" && "$BIN" $v 2>&1)" && { echo "$v succeeded"; return 1; }
    assert_contains "$out" "UNSETTLED launch" || { echo "$v: $out"; return 1; }
  done
  out="$(cd "$T" && "$BIN" recover abandon WG-1-handoff --reason "it is gone" 2>&1)" && { echo "abandon succeeded"; return 1; }
  assert_contains "$out" "never abandoned"
  assert_eq "$(_h_ledger)" "$l"
  # it stays visible and unchanged
  assert_eq "$(cd "$T" && "$BIN" handoff status WG-1-handoff | jq -r '.hold.kind')" launch-unknown
  _h_cleanup
}

test_a_row_with_a_delegate_launch_debt_is_refused_not_retired() {
  _h_setup
  jq '.[0].launch = {phase:"starting", at:"2026-10-18T00:00:00Z"} | .[0].state = "unconfirmed"' "$T/.cel/delegations.json" > "$T/l2" && mv "$T/l2" "$T/.cel/delegations.json"
  _h_inspect
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" false
  assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "unsettled launch or operation (launch starting)"
  _h_cleanup
}

test_apply_refuses_stale_busy_and_changed_state_with_zero_mutation() {
  local c needle
  for c in head digest dirty_edit pid start busy_status child listener preview draft changing pending_launch name two_agents role ws foreground active_launch lock; do
    _h_setup; _h_dirty
    _h_inspect
    case "$c" in
      head)       git -C "$H_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m moved; needle="stale snapshot" ;;
      digest)     echo "someone edited" >> "$H_WT/new.txt"; needle="stale snapshot" ;;
      dirty_edit) echo "late private edit" >> "$H_WT/.agent/result.md"; needle="stale snapshot" ;;
      pid)        _h_proc 5002 5000 777777 omp; jq '.result.process_info.foreground_processes = [{pid:5002,name:"omp"}]' "$RS/pinfo.json" > "$RS/p2" && mv "$RS/p2" "$RS/pinfo.json"; needle="the agent is pid 5002" ;;
      start)      _h_proc 5001 5000 777999 omp; needle="start generation" ;;
      busy_status) jq '.result.agents[0].agent_status = "working"' "$RS/agents.json" > "$RS/a2" && mv "$RS/a2" "$RS/agents.json"; needle="not idle" ;;
      child)      _h_proc 5100 5001 800000 sleep; needle="live descendant" ;;
      listener)   printf 'LISTEN 0 511 127.0.0.1:8335 0.0.0.0:* users:(("node",pid=5001,fd=20))\n' > "$T/ss.txt"; needle="listening socket" ;;
      preview)    jq '.[0].try = {port: 8334, url:"http://x"}' "$T/.cel/delegations.json" > "$T/l2" && mv "$T/l2" "$T/.cel/delegations.json"
                  ( python3 -c 'import socket,time;s=socket.socket();s.bind(("127.0.0.1",8334));s.listen(1);time.sleep(20)' & echo $! > "$T/py.pid" ) ; sleep 0.5; needle="preview" ;;
      draft)      printf 'ctx 3.0%%\n──────────\nhalf typed message\n' > "$RS/read.txt"; needle="draft" ;;
      changing)   echo changing > "$RS/read_mode"; needle="not-quiescent" ;;
      pending_launch) jq '.result.agents[0].launch_pending = true' "$RS/agents.json" > "$RS/a2" && mv "$RS/a2" "$RS/agents.json"; needle="pending launch" ;;
      name)       jq '.result.agents[0].name = "someone-elses-worker"' "$RS/agents.json" > "$RS/a2" && mv "$RS/a2" "$RS/agents.json"; needle="exactly one agent" ;;
      two_agents) jq '.result.agents += [.result.agents[0]]' "$RS/agents.json" > "$RS/a2" && mv "$RS/a2" "$RS/agents.json"; needle="exactly one agent" ;;
      role)       _h_proc 5001 5000 777777 omp; printf 'CEL_ROLE=console\0CEL_WORKSPACE=%s\0' "$T" > "$T/proc/5001/environ"; needle="CEL_ROLE=worker" ;;
      ws)         printf 'CEL_ROLE=worker\0CEL_WORKSPACE=/elsewhere\0' > "$T/proc/5001/environ"; needle="another workspace" ;;
      foreground) jq '.result.process_info.foreground_processes += [{pid:5050,name:"vim"}]' "$RS/pinfo.json" > "$RS/p2" && mv "$RS/p2" "$RS/pinfo.json"; needle="not exactly the agent" ;;
      active_launch) printf '4242 /bin/bash /x/cel-fanout delegate widget WG-1-handoff /s/spec.md --reuse\n' > "$T/ps.txt"; needle="may still start an agent" ;;
      lock)       exec 9>"$T/.cel/delegations.lock"; flock -n 9; needle="lock is held" ;;
    esac
    local l b; l="$(_h_ledger)"; b="$(_h_bytes)"
    _h_apply
    [ "$c" != lock ] || exec 9>&-
    [ "$c" != preview ] || kill "$(cat "$T/py.pid")" 2>/dev/null || true
    _h_refused_untouched "$l" "$b" "$needle" || { echo "case $c"; _h_cleanup; return 1; }
    _h_cleanup
  done
}

test_contention_a_second_attempt_and_a_competing_operation_are_refused() {
  _h_setup; _h_dirty
  _h_inspect
  # a different plan (different bound HEAD) for the same delegation, left pending
  export CEL_FANOUT_CRASH=ho-after-admit; _h_apply; unset CEL_FANOUT_CRASH
  local opid; opid="$(_h_row | jq -r '.handoff.id')"
  # a competitor with a different profile binds a different operation: refused until the first is settled
  local l; l="$(_h_ledger)"
  H_PROFILE=bare _h_apply
  [ "$H_RC" -ne 0 ] || { echo "a competitor was admitted"; return 1; }
  assert_contains "$H_OUT" "operation"
  assert_eq "$(_h_ledger)" "$l"
  assert_eq "$(ls "$T/.cel/handoffs"/*.json | wc -l | tr -d ' ')" 1
  [ ! -s "$RS/stops" ] && [ ! -s "$RS/starts" ] || return 1
  # per-target lock: a live attempt blocks a second one
  exec 8>"$T/.cel/handoffs/WG-1-handoff.lock"; flock -n 8
  _h_apply
  exec 8>&-
  [ "$H_RC" -ne 0 ] && assert_contains "$H_OUT" "holds the target lock" || { echo "$H_OUT"; return 1; }
  # the original, once the competitors are out of the way, still completes
  _h_apply
  assert_eq "$H_RC" 0 || { echo "$H_OUT"; return 1; }
  assert_eq "$(_h_row | jq -r '.handoff.id')" "$opid"
  _h_cleanup
}

test_retirement_that_is_not_confirmed_stays_debt_and_never_starts_anything() {
  local m
  for m in lost error; do
    _h_setup; _h_dirty
    echo "$m" > "$RS/stop_mode"
    _h_inspect; _h_apply
    [ "$H_RC" -ne 0 ] || { echo "$m: succeeded"; return 1; }
    assert_contains "$H_OUT" "retirement is NOT confirmed"
    assert_eq "$(_h_row | jq -r '.handoff.phase')" retire-unconfirmed
    assert_eq "$(_h_lines starts)" 0
    # the old runtime and all the source are still there
    [ -d "$T/proc/5001" ] || return 1
    # replay only observes; it does not stop again without --reissue-retire
    _h_apply
    [ "$H_RC" -ne 0 ] && assert_contains "$H_OUT" "NOT repeated" || { echo "$H_OUT"; return 1; }
    assert_eq "$(_h_lines stops)" 1
    # --reissue-retire against the SAME unchanged identity, once herdr works again
    echo ok > "$RS/stop_mode"
    _h_apply --reissue-retire
    assert_eq "$H_RC" 0 || { echo "$m: $H_OUT"; return 1; }
    assert_eq "$(_h_lines stops)" 2; assert_eq "$(_h_lines starts)" 1
    _h_cleanup
  done
}

test_a_partial_start_keeps_debt_and_never_launches_a_second_agent() {
  _h_setup; _h_dirty
  # herdr's start fails cleanly: no agent exists, the start is NEVER retried
  echo fail > "$RS/start_mode"
  _h_inspect; _h_apply
  [ "$H_RC" -ne 0 ] || { echo "succeeded"; return 1; }
  assert_eq "$(_h_row | jq -r '.handoff.phase')" start-failed
  assert_eq "$(_h_row | jq -r '.launch.phase')" start-failed
  assert_eq "$(_h_lines starts)" 1; assert_eq "$(_h_lines prompts)" 0
  echo ok > "$RS/start_mode"                                  # herdr would now succeed - still no second start
  _h_apply; _h_apply
  assert_contains "$H_OUT" "NOT restarted"
  assert_eq "$(_h_lines starts)" 1; assert_eq "$(_h_lines prompts)" 0
  assert_eq "$(_h_row | jq -r '.state')" unconfirmed        # never claimed running
  local out; out="$(cd "$T" && "$BIN" release WG-1-handoff --discard 2>&1)" && { echo "release succeeded"; return 1; }
  assert_contains "$out" "UNSETTLED launch"
  [ -d "$H_WT" ] && [ "$(cat "$H_WT/.agent/result.md")" = "private evidence" ] || return 1
  _h_cleanup
  # herdr's start times out AFTER the agent exists: the first call is debt,
  # the replay ADOPTS that one verified agent (no second start) and prompts once
  _h_setup; _h_dirty
  echo failafter > "$RS/start_mode"
  _h_inspect; _h_apply
  [ "$H_RC" -ne 0 ] || { echo "failafter: succeeded"; return 1; }
  assert_eq "$(_h_row | jq -r '.handoff.phase')" start-failed
  assert_eq "$(_h_lines prompts)" 0
  _h_apply
  assert_eq "$H_RC" 0 || { echo "$H_OUT"; return 1; }
  assert_eq "$(_h_lines starts)" 1; assert_eq "$(_h_lines prompts)" 1
  _h_cleanup
}

test_a_started_replacement_that_is_the_wrong_model_is_never_prompted() {
  _h_setup; _h_dirty
  _h_inspect
  # the stub starts a pi whose argv carries a DIFFERENT model than the profile's
  echo "--model wrong-model --thinking medium" > "$RS/cmdline_override"
  _h_apply
  [ "$H_RC" -ne 0 ] || { echo "succeeded"; return 1; }
  assert_contains "$H_OUT" "not the requested runtime"
  assert_eq "$(_h_row | jq -r '.handoff.phase')" started-unverified
  assert_eq "$(_h_lines prompts)" 0
  _h_cleanup
}

test_an_ack_is_not_running_unproven_acceptance_stays_debt_and_is_never_resubmitted() {
  local m
  for m in noturn notool; do
    _h_setup; _h_dirty
    echo "$m" > "$RS/prompt_mode"
    _h_inspect; _h_apply
    [ "$H_RC" -ne 0 ] || { echo "$m: succeeded"; return 1; }
    assert_eq "$(_h_row | jq -r '.handoff.phase')" unconfirmed-acceptance
    assert_eq "$(_h_row | jq -r '.state')" unconfirmed
    assert_eq "$(_h_lines prompts)" 1
    _h_apply
    assert_eq "$(_h_lines prompts)" 1                         # looked, never resubmitted
    # the evidence arrives later: a re-run promotes it, still one prompt
    cp "$RS/turn.txt" "$RS/read.txt"
    _h_apply
    assert_eq "$H_RC" 0 || { echo "$H_OUT"; return 1; }
    assert_eq "$(_h_lines prompts)" 1
    assert_eq "$(_h_row | jq -r '.state')" running
    _h_cleanup
  done
}

test_an_ambiguous_prompt_error_is_never_resubmitted() {
  _h_setup; _h_dirty
  echo unknown > "$RS/prompt_mode"
  _h_inspect; _h_apply
  assert_contains "$H_OUT" "ambiguous"
  assert_eq "$(_h_row | jq -r '.handoff.phase')" ambiguous
  _h_apply; _h_apply
  assert_eq "$(_h_lines prompts)" 1
  _h_cleanup
}

test_apply_requires_every_coordinate_of_an_inspected_plan() {
  _h_setup
  H_OUT="$(cd "$T" && "$BIN" handoff apply WG-1-handoff --profile pitarget --pane w1AN:p1 2>&1)" && H_RC=0 || H_RC=$?
  assert_eq "$([ "$H_RC" -ne 0 ] && echo yes)" yes
  assert_contains "$H_OUT" "--shell-pid is required"
  assert_eq "$(_h_n '^agent stop')" 0
  _h_cleanup
}

test_a_worker_may_not_run_handoff() {
  _h_setup
  mkdir -p "$T/wtroot/widget/WG-9-x"
  H_OUT="$(cd "$T" && CEL_WORKTREES="$T/wtroot" bash -c 'cd "$CEL_WORKTREES/widget/WG-9-x" && "$0" handoff inspect WG-1-handoff --pane w1AN:p1 --workspace profiled' "$BIN" 2>&1)" && H_RC=0 || H_RC=$?
  [ "$H_RC" -ne 0 ] || { echo "a worker ran handoff"; return 1; }
  _h_cleanup
}

test_real_installed_herdr_capability_discovery_is_read_only_and_truthful() {
  have herdr || { echo "herdr not installed - skipped"; return 0; }
  local out
  out="$(HERDR=herdr bash -c 'source "$1/lib/common.sh"; source "$1/lib/fanout_handoff.sh"; _ho_caps' _ "$CEL_ROOT" 2>&1)" || true
  assert_eq "$(printf '%s' "$out" | jq -r '.schema')" true || { echo "$out"; return 1; }
  # truthful: agent.stop is reported exactly when the installed schema lists it
  local listed=false
  herdr api schema --json 2>/dev/null | grep -q '"const": "agent.stop"' && listed=true
  assert_eq "$(printf '%s' "$out" | jq -r '.agent_stop')" "$listed"
  assert_eq "$(printf '%s' "$out" | jq -r '.agent_start')" true
}

test_status_names_the_phase_and_the_exact_next_action() {
  _h_setup; _h_dirty
  export CEL_FANOUT_CRASH=ho-after-admit; _h_inspect; _h_apply; unset CEL_FANOUT_CRASH
  local s; s="$(cd "$T" && "$BIN" handoff status WG-1-handoff)"
  assert_eq "$(printf '%s' "$s" | jq -r '.operation.phase')" admitted
  assert_contains "$(printf '%s' "$s" | jq -r '.next_action')" "handoff apply"
  assert_eq "$(printf '%s' "$s" | jq -r '.operation.binding.source_digest')" "$(printf '%s' "$H_PLAN" | jq -r '.plan.source.digest')"
  _h_cleanup
}

test_a_missing_session_file_refuses_retirement_even_with_a_valid_archive() {
  _h_setup; _h_dirty
  rm -f "$RS/session.jsonl"                      # the Pi ENOENT shape: tail may be memory-only
  printf 'exported tail\n' > "$T/export.jsonl"
  local l b; l="$(_ho_l=$(_h_ledger); printf '%s' "$_ho_l")"; b="$(_h_bytes)"
  _h_inspect
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" false
  assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "may live only in memory"
  H_PLAN="$(cd "$T" && "$BIN" handoff inspect WG-1-handoff --pane w1AN:p1 --profile pitarget --preserved-export "$T/export.jsonl")"
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" false
  assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "REFUSED even with a valid archive"
  _h_apply --preserved-export "$T/export.jsonl"
  _h_refused_untouched "$l" "$b" "session-tail" || return 1
  _h_cleanup
}

test_an_unsettled_last_tool_call_in_the_session_file_refuses_retirement() {
  _h_setup; _h_dirty
  printf '%s\n' '{"type":"session","id":"u1","cwd":"x"}' '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"32a954d9","name":"bash"}]}}' > "$RS/session.jsonl"
  local l b; l="$(_h_ledger)"; b="$(_h_bytes)"
  _h_inspect
  assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "unsettled-tool"
  _h_apply
  _h_refused_untouched "$l" "$b" "unsettled-tool" || return 1
  # a settled last entry (a tool RESULT) is not refused, and the proof level stays honest
  printf '%s\n' '{"type":"session","id":"u1","cwd":"x"}' '{"type":"message","message":{"role":"toolResult","toolCallId":"32a954d9","content":[]}}' > "$RS/session.jsonl"
  _h_inspect
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" true || { echo "$H_PLAN"; return 1; }
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.plan.runtime.session.memory_tail_proof')" none
  _h_cleanup
}

_h_working_session() { # <uuid> [cwd] -> the old runtime's OWN recorded session file, rewritten as a pi session
  printf '%s\n' "$(jq -nc --arg id "$1" --arg c "${2:-$H_WT}" '{type:"session",version:3,id:$id,cwd:$c}')" '{"type":"message","message":{"role":"user","content":"hi"}}' > "$RS/session.jsonl"
  printf '%s' "$RS/session.jsonl"
}

test_explicit_working_session_selection_is_bound_launched_and_verified() {
  _h_setup; _h_dirty
  local ws sha; ws="$(_h_working_session 11111111-2222-3333-4444-555555555555)"; sha="$(sha256sum "$ws" | cut -c1-64)"
  H_PLAN="$(cd "$T" && "$BIN" handoff inspect WG-1-handoff --pane w1AN:p1 --profile pitarget --resume-session "$ws")"
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" true || { echo "$H_PLAN"; return 1; }
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.plan.resume_session.uuid')" 11111111-2222-3333-4444-555555555555
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.plan.resume_session.sha256')" "$sha"
  assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.plan.context.session_selection')" explicit-working-session
  _h_apply --resume-session "$ws" --resume-sha "$sha"
  assert_eq "$H_RC" 0 || { echo "$H_OUT"; return 1; }
  # the real argv carries --session <that exact file>; nothing was copied or renamed
  tr '\0' ' ' < "$T/proc/6001/cmdline" | grep -q -- "--session $ws " || { tr '\0' ' ' < "$T/proc/6001/cmdline"; return 1; }
  assert_eq "$(_h_row | jq -r '.handoff.session.uuid')" 11111111-2222-3333-4444-555555555555
  assert_contains "$(_h_row | jq -r '.handoff.session.continuity')" "model-side continuity is not claimed"
  assert_eq "$(sha256sum "$ws" | cut -c1-64)" "$sha"
  _h_cleanup
}

test_working_session_selection_refuses_what_it_cannot_verify_with_zero_mutation() {
  local c needle
  for c in wrong_cwd archive no_header relative not_pi changed copy hardlink symlink unsettled unparseable; do
    _h_setup; _h_dirty
    local ws prof=pitarget extra=""; ws="$(_h_working_session 11111111-2222-3333-4444-555555555555)"
    case "$c" in
      wrong_cwd) ws="$(_h_working_session 22222222-2222-3333-4444-555555555555 /somewhere/else)"; needle="no cwd guessing" ;;
      archive)   cp "$ws" "$T/arch.jsonl"; extra="--preserved-export $T/arch.jsonl"; ws="$T/arch.jsonl"; needle="not the old runtime's own session file" ;;
      no_header) printf 'not json\n' > "$ws"; needle="no session header" ;;
      relative)  ws="work.jsonl"; needle="existing absolute session file" ;;
      not_pi)    prof=bare; needle="only known for the pi runtime" ;;
      copy)      cp "$ws" "$T/copy.jsonl"; ws="$T/copy.jsonl"; needle="not the old runtime's own session file" ;;
      hardlink)  ln "$ws" "$T/hard.jsonl"; ws="$T/hard.jsonl"; needle="not the old runtime's own session file" ;;
      symlink)   ln -s "$ws" "$T/sym.jsonl"; ws="$T/sym.jsonl"; needle="not the old runtime's own session file" ;;
      unsettled) printf '%s\n' "$(head -n 1 "$ws")" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1"},{"type":"toolCall","id":"c2"}]}}' '{"type":"message","message":{"role":"toolResult","toolCallId":"c1"}}' > "$ws"; needle="1 tool call(s) without a result" ;;
      unparseable) printf '%s\n' "$(head -n 1 "$ws")" '{"type":"message","mess' > "$ws"; needle="not valid JSON" ;;
      changed)   needle="" ;;
    esac
    local l b; l="$(_h_ledger)"; b="$(_h_bytes)"
    if [ "$c" = changed ]; then
      H_PLAN="$(cd "$T" && "$BIN" handoff inspect WG-1-handoff --pane w1AN:p1 --profile pitarget --resume-session "$ws")"
      assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" true || { echo "$H_PLAN"; return 1; }
      echo '{"type":"message","message":{"role":"user","content":"late"}}' >> "$ws"   # edited after the plan
      H_PROFILE=pitarget _h_apply --resume-session "$ws" --resume-sha "$(printf '%s' "$H_PLAN" | jq -r '.plan.resume_session.sha256')"
      [ "$H_RC" -ne 0 ] || { echo "changed session was launched"; return 1; }
      assert_contains "$H_OUT" "stale-session"
      assert_eq "$(_h_lines starts)" 0
    else
      H_PLAN="$(cd "$T" && "$BIN" handoff inspect WG-1-handoff --pane w1AN:p1 --profile "$prof" --resume-session "$ws" $extra)"
      assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" false || { echo "$c: $H_PLAN"; return 1; }
      assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "$needle" || { echo "$c"; return 1; }
      l="$(_h_ledger)"; b="$(_h_bytes)"
      H_PROFILE="$prof" _h_apply --resume-session "$ws" --resume-sha deadbeef $extra
      _h_refused_untouched "$l" "$b" "$needle" || { echo "case $c"; return 1; }
    fi
    _h_cleanup
  done
}

test_unknown_session_fails_closed_and_parallel_or_garbled_tails_are_unsettled() {
  _h_setup; _h_dirty
  # herdr reports NO session for the agent
  jq 'del(.result.agents[0].agent_session)' "$RS/agents.json" > "$RS/a2" && mv "$RS/a2" "$RS/agents.json"
  local l b; l="$(_h_ledger)"; b="$(_h_bytes)"
  _h_inspect
  assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "session-unknown"
  _h_apply
  _h_refused_untouched "$l" "$b" "session-unknown" || return 1
  _h_cleanup
  local tail
  for tail in parallel garbled later_entry; do
    _h_setup
    case "$tail" in
      parallel)    printf '%s\n' '{"type":"session","id":"u"}' '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"a"},{"type":"toolCall","id":"b"}]}}' '{"type":"message","message":{"role":"toolResult","toolCallId":"a"}}' > "$RS/session.jsonl" ;;
      garbled)     printf '%s\n' '{"type":"session","id":"u"}' '{"type":"message","message":{"role":"assistant","conte' > "$RS/session.jsonl" ;;
      later_entry) printf '%s\n' '{"type":"session","id":"u"}' '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"a"}]}}' '{"type":"model_change","model":"x"}' > "$RS/session.jsonl" ;;
    esac
    _h_inspect
    assert_eq "$(printf '%s' "$H_PLAN" | jq -r '.applicable')" false || { echo "$tail: $H_PLAN"; return 1; }
    assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "unsettled-tool" || { echo "$tail"; return 1; }
    _h_cleanup
  done
}

test_the_capability_gate_requires_the_fenced_contract_not_a_method_name() {
  _h_setup stop-nofence; _h_dirty
  local l b; l="$(_h_ledger)"; b="$(_h_bytes)"
  _h_inspect
  assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "agent.stop is listed"
  assert_contains "$(printf '%s' "$H_PLAN" | jq -r '.refusals | join(" ")')" "retire by name alone"
  _h_apply
  _h_refused_untouched "$l" "$b" "retire by name alone" || return 1
  _h_cleanup
}

test_stop_is_fenced_by_the_bound_generation() {
  _h_setup; _h_dirty
  _h_inspect; _h_apply
  assert_eq "$H_RC" 0 || { echo "$H_OUT"; return 1; }
  assert_contains "$(grep '^agent stop' "$RS/log")" "--expected-pid 5001 --expected-start 777777"
  _h_cleanup
}

test_settle_is_unavailable_without_a_launch_receipt_and_changes_nothing() {
  _h_setup
  (cd "$T" && "$BIN" handoff hold WG-1-handoff --kind launch-unknown --evidence "unknown" >/dev/null)
  local l; l="$(_h_ledger)"
  local out rc=0; out="$(cd "$T" && "$BIN" handoff settle WG-1-handoff 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "settled"; return 1; }
  assert_contains "$out" "UNAVAILABLE"
  assert_contains "$out" "launch id"
  assert_eq "$(_h_ledger)" "$l"
  # closed rows cannot be held
  jq '.[0].state = "released"' "$T/.cel/delegations.json" > "$T/l2" && mv "$T/l2" "$T/.cel/delegations.json"
  rc=0; out="$(cd "$T" && "$BIN" handoff hold WG-1-handoff --kind launch-unknown --evidence "x" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] && assert_contains "$out" "is closed"
  _h_cleanup
}

test_a_shutdown_append_to_the_resume_session_is_accepted_but_rewrites_and_unsettled_tails_are_not() {
  local c
  for c in append rewrite unsettled; do
    _h_setup; _h_dirty
    local ws sha; ws="$(_h_working_session 11111111-2222-3333-4444-555555555555)"; sha="$(sha256sum "$ws" | cut -c1-64)"
    case "$c" in
      append)    echo '{"type":"message","message":{"role":"assistant","content":"flushed on exit"}}' > "$RS/append_on_stop" ;;
      rewrite)   printf '%s\n' '{"type":"session","version":3,"id":"11111111-2222-3333-4444-555555555555","cwd":"'"$H_WT"'"}' '{"type":"message","message":{"role":"user","content":"REWRITTEN"}}' > "$RS/rewrite_on_stop" ;;
      unsettled) echo '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"z1"}]}}' > "$RS/append_on_stop" ;;
    esac
    H_PLAN="$(cd "$T" && "$BIN" handoff inspect WG-1-handoff --pane w1AN:p1 --profile pitarget --resume-session "$ws")"
    _h_apply --resume-session "$ws" --resume-sha "$sha"
    if [ "$c" = append ]; then
      assert_eq "$H_RC" 0 || { echo "$H_OUT"; return 1; }
      assert_eq "$(_h_lines starts)" 1
      assert_eq "$(_h_row | jq -r '.handoff.phase')" done
    else
      [ "$H_RC" -ne 0 ] || { echo "$c: started"; return 1; }
      assert_contains "$H_OUT" "cannot be resumed"
      assert_eq "$(_h_lines starts)" 0
      assert_eq "$(_h_row | jq -r '.handoff.phase')" retired        # durable debt, replayable, not 'starting'
    fi
    _h_cleanup
  done
}
