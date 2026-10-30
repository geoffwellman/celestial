# shellcheck shell=bash
# Canonical parent-launch boundaries, with a no-model child runtime. Actual
# OpenCode protocol/session consumers are exercised by the isolated native proof.
source "$CEL_ROOT/tests/lib/gateway-codex-fixture.sh"

_ocl_setup() {
  _gwc_setup
  export CEL_REX_STATE="$T/rex-state" CEL_REX_BIN="$T/bin/rex" CEL_PROC_ROOT="$T/proc"
  export CEL_MANIFEST="$T/agents.yaml" CEL_MANIFEST_CACHE="$T/manifest-cache" CEL_ORCH_SESSIONS="$T/native-sessions.json"
  mkdir -p "$CEL_REX_STATE" "$CEL_PROC_ROOT" "$T/repos/widget"
  cat > "$CEL_MANIFEST" <<YAML
agents:
  opencode:
    bin: "$T/bin/opencode"
    role_injection: {strategy: agent_file, dir: "$T/unused-global"}
    model_flag: --model
    launch_args: [--auto]
    resume: {flag: --session, value: id}
YAML
  cat > "$T/workspace.yaml" <<YAML
name: alpha
runtime: {orchestrator: opencode}
env: {CEL_ORCH_SESSIONS: "$CEL_ORCH_SESSIONS"}
repos:
  - name: widget
    mode: solo
    role_profiles: {solo: scoped}
worker_profiles:
  scoped: {runtime: opencode, model: ompgw-codex/gpt-6.1-sol, thinking: medium, via: gateway}
YAML
  cat > "$T/gwstub" <<'SH'
#!/bin/bash
case "$1" in ready) exit 0;; models) printf '%s' '{"data":[{"id":"gpt-6.1-sol"}]}';; esac
SH
  cat > "$T/bin/rex" <<'SH'
#!/bin/bash
[ "$1" = new ] || exit 1
shift
while [ "$1" != -- ]; do
  if [ "$1" = --cwd ]; then cwd="$2"; shift 2; else shift; fi
done; shift
(cd "$cwd" && exec "$@") >/dev/null 2>&1 &
printf '{"session_id":"session:fixture","initial_windows":[{"block_ids":["block:fixture"]}]}'
SH
  cat > "$T/bin/opencode" <<'SH'
#!/bin/bash
set -e
native=ses_HolderFixture previous=""
for arg in "$@"; do
  [ "$previous" != --session ] || native="$arg"
  previous="$arg"
done
"$CEL_ROOT/bin/cel" sessions note "$$" working "$native"
printf '%s\n' "$CEL_SESSION_ID" > "$CEL_REX_STATE/received-affinity"
exec sleep 300
SH
  chmod +x "$T/gwstub" "$T/bin/"*
  herdr() { [ "$1 $2" = 'agent list' ] && printf '{"result":{"agents":[]}}'; }
  local role="$T/.cel/opencode/widget-orch/role-orchestrator.md"
  jq -n --arg role "$role" --arg plugin "$CEL_ROOT/tools/hooks/celestial.opencode.mjs" '{agent:"cel-orchestrator",roleFile:$role,pluginFile:$plugin,modelID:"gpt-6.1-sol",transport:"gateway",baseURL:"http://127.0.0.1:8317/v1",route:"{env:CEL_SESSION_ID}",limit:{context:500000,output:128000}}' \
    | opencode_write_config "${role%.md}.opencode.json"
  printf 'Use a new native context, not the archived OMP file.\n' > "$T/handoff.md"
}
_ocl_down() {
  local f p
  for f in "$CEL_REX_STATE"/*.json; do
    [ -f "$f" ] && _rex_live "$f" || continue
    p="$(jq -r .pid "$f")"; [ "$p" = "$$" ] || kill "$p" 2>/dev/null || true
  done
  unset CEL_REX_STATE CEL_REX_BIN CEL_PROC_ROOT CEL_MANIFEST CEL_MANIFEST_CACHE CEL_ORCH_SESSIONS
  _gwc_teardown
}

test_opencode_parent_launch_owns_affinity_and_tracks_title_rewritten_native_holder() {
  _ocl_setup
  local out
  if ! out="$(cd "$T" && CEL_SESSION_ID=core-affinity cmd_run solo --product widget --session-backend rex --fresh --handoff "$T/handoff.md" 2>&1)"; then
    echo "$out"; _ocl_down; return 1
  fi
  local i
  for ((i=0;i<100;i++)); do [ -f "$CEL_REX_STATE/received-affinity" ] && break; sleep 0.1; done
  assert_eq "$(cat "$CEL_REX_STATE/received-affinity")" widget-orch
  local pid; pid="$(jq -r .pid "$CEL_REX_STATE/widget-orch.json")"
  assert_eq "$(run_session_resumers)" "$(printf 'ses_HolderFixture\t%s\trex/session:fixture/block:fixture' "$pid")"
  _ocl_down
}

test_opencode_native_resume_rejects_legacy_context_without_rewriting_it() {
  _ocl_setup
  local original out rc
  for original in /archive/old-omp.jsonl 6b90062c-f7b9-4cf4-859c-6bba6e90df1d; do
    _run_sessions_record "$T/repos/widget" "$original"
    rc=0
    out="$(AGENT_ARGS=(); _run_resume_resolve orchestrator widget-orch "$T/repos/widget" opencode '' 1 0 0 1 relaunch adopt 2>&1)" || rc=$?
    [ "$rc" != 0 ] || { echo 'cross-format context admitted'; _ocl_down; return 1; }
    assert_contains "$out" '--fresh --handoff'
    assert_eq "$(_run_sessions_last "$T/repos/widget")" "$original"
  done
  _run_sessions_record "$T/repos/widget" ses_SavedNative
  local AGENT_ARGS=() RESUME_SESSION='' RESTART_PANE=''
  _run_resume_resolve orchestrator widget-orch "$T/repos/widget" opencode '' 1 0 0 1 relaunch adopt >/dev/null 2>&1
  assert_eq "$RESUME_SESSION" ses_SavedNative
  assert_eq "${AGENT_ARGS[*]}" '--session ses_SavedNative'
  _ocl_down
}

test_opencode_rex_receipt_captures_only_actual_native_session_argument() {
  _ocl_setup
  _rex_launch widget-orch opencode "$T/repos/widget" fixture 'env CEL_ROLE=solo' --session ses_ActualNative >/dev/null
  assert_eq "$(jq -r .agent_session.value "$CEL_REX_STATE/widget-orch.json")" ses_ActualNative
  if (_rex_launch another opencode "$T/repos/widget" fixture 'env CEL_ROLE=solo' --session /archive/old-omp.jsonl >/dev/null 2>&1); then
    echo 'Rex accepted a non-native OpenCode session'; _ocl_down; return 1
  fi
  [ ! -f "$CEL_REX_STATE/another.json" ] || { echo 'invalid native identity recorded'; _ocl_down; return 1; }
  _ocl_down
}
