# shellcheck shell=bash
# Canonical parent-launch boundaries, with a no-model child runtime. Actual
# OpenCode protocol/session consumers are exercised by the isolated native proof.
source "$CEL_ROOT/tests/lib/gateway-codex-fixture.sh"

_ocl_native_store() { # optional stored-identity patch, optional migration phase
  local patch="${1:-}"
  [ -n "$patch" ] || patch='{}'
  python3 - "$OPENCODE_DB" "$T/repos/widget" "$patch" "${2:-completed}" <<'PY'
import json, sqlite3, sys
database, directory, patch, phase = sys.argv[1:]
row = dict(id="ses_SavedNative", parent_id=None, directory=directory, workspace_id=None,
           agent="cel-orchestrator", model={"providerID":"ompgw-codex","id":"gpt-6.1-sol","variant":"medium"})
row.update(json.loads(patch))
if isinstance(row["model"], dict):
    row["model"] = json.dumps(row["model"])
with sqlite3.connect(database) as db:
    db.execute("CREATE TABLE IF NOT EXISTS session_v2 (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, workspace_id TEXT, agent TEXT, model TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS session (id TEXT PRIMARY KEY)")
    db.execute("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
    db.execute("DELETE FROM session_v2")
    db.execute("INSERT INTO session_v2 VALUES (:id, :parent_id, :directory, :workspace_id, :agent, :model)", row)
    db.execute("DELETE FROM kv")
    if phase != "missing":
        db.execute("INSERT INTO kv VALUES (?, ?)", ("migration.v1-v2", json.dumps({"phase": phase})))
PY
}

_ocl_setup() {
  _gwc_setup
  export CEL_REX_STATE="$T/rex-state" CEL_REX_BIN="$T/bin/rex" CEL_PROC_ROOT="$T/proc"
  export CEL_MANIFEST="$T/agents.yaml" CEL_MANIFEST_CACHE="$T/manifest-cache" CEL_ORCH_SESSIONS="$T/native-sessions.json" OPENCODE_DB="$T/native.db"
  mkdir -p "$CEL_REX_STATE" "$CEL_PROC_ROOT" "$T/repos/widget"
  cat > "$CEL_MANIFEST" <<YAML
agents:
  opencode:
    bin: "$T/bin/opencode"
    role_injection: {strategy: agent_file, dir: "$T/unused-global"}
    launch_args: [--standalone, --auto]
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
  cat > "$T/bin/opencode" <<'JS'
#!/usr/bin/env node
import(process.env.CEL_ROOT + '/tests/lib/opencode-runtime-fixture.mjs').then(module => module.runFixture());
JS
  chmod +x "$T/gwstub" "$T/bin/"*
  herdr() { [ "$1 $2" = 'agent list' ] && printf '{"result":{"agents":[]}}'; }
  local role="$T/.cel/opencode/widget-orch/role-orchestrator.md"
  jq -n --arg role "$role" --arg plugin "$CEL_ROOT/tools/opencode/plugin" '{agent:"cel-orchestrator",roleFile:$role,pluginFile:$plugin,modelID:"gpt-6.1-sol",transport:"gateway",baseURL:"http://127.0.0.1:8317/v1",route:"{env:CEL_SESSION_ID}",limit:{context:500000,output:128000}}' \
    | opencode_write_config "${role%.md}.opencode.json"
  printf 'Use a new native context, not the archived OMP file.\n' > "$T/handoff.md"
  _ocl_native_store
}
_ocl_down() {
  local f p
  for f in "$CEL_REX_STATE"/*.json; do
    [ -f "$f" ] && _rex_live "$f" || continue
    p="$(jq -r .pid "$f")"; [ "$p" = "$$" ] || kill "$p" 2>/dev/null || true
  done
  unset CEL_REX_STATE CEL_REX_BIN CEL_PROC_ROOT CEL_MANIFEST CEL_MANIFEST_CACHE CEL_ORCH_SESSIONS OPENCODE_DB CEL_OPENCODE_AGENT CEL_OPENCODE_CONFIG_FILE AGENT_ROLE_FILE
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
  assert_eq "$(jq -r .holderPID "$CEL_REX_STATE/received-reporter")" "$pid"
  [ "$(jq -r .childPID "$CEL_REX_STATE/received-reporter")" != "$pid" ] || { _ocl_down; return 1; }
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
  local role="$T/.cel/opencode/widget-orch/role-orchestrator.md" prefix session_backend=rex
  opencode_agent_args orchestrator fixture 0 "$role" "${role%.md}.opencode.json" http://127.0.0.1:8317/v1 || { _ocl_down; return 1; }
  prefix="$(_run_launch_env solo "$T" "$role" widget-orch opencode)"
  _rex_launch widget-orch opencode "$T/repos/widget" fixture "$prefix" --standalone --auto --session ses_SavedNative >/dev/null
  assert_eq "$(jq -r .agent_session.value "$CEL_REX_STATE/widget-orch.json")" ses_SavedNative
  if (_rex_launch another opencode "$T/repos/widget" fixture 'env CEL_ROLE=solo' --session /archive/old-omp.jsonl >/dev/null 2>&1); then
    echo 'Rex accepted a non-native OpenCode session'; _ocl_down; return 1
  fi
  [ ! -f "$CEL_REX_STATE/another.json" ] || { echo 'invalid native identity recorded'; _ocl_down; return 1; }
  _ocl_down
}

test_opencode_native_resume_requires_existing_matching_migrated_root() {
  _ocl_setup
  local patch out rc original
  original=ses_SavedNative
  _run_sessions_record "$T/repos/widget" "$original"
  for patch in \
    '{"id":"ses_DifferentNative"}' \
    '{"parent_id":"ses_ParentNative"}' \
    '{"directory":"/different-native-root"}' \
    '{"directory":""}' \
    '{"workspace_id":"wrk_other"}' \
    '{"agent":"cel-other"}' \
    '{"model":{"providerID":"openai","id":"gpt-6.1-sol","variant":"medium"}}' \
    '{"model":{"providerID":"ompgw-codex","id":"gpt-6.1-sol","variant":"high"}}' \
    '{"model":{"providerID":"ompgw-codex","id":"gpt-6.1-sol"}}' \
    '{"model":{"providerID":"ompgw-codex","id":"other-model","variant":"medium"}}' \
    '{"model":"malformed fixture-only-secret"}'; do
    _ocl_native_store "$patch" || { _ocl_down; return 1; }
    rc=0
    out="$(AGENT_ARGS=(); _run_resume_resolve orchestrator widget-orch "$T/repos/widget" opencode '' 1 0 0 1 relaunch adopt 2>&1)" || rc=$?
    [ "$rc" != 0 ] || { echo "admitted wrong native root: $patch"; _ocl_down; return 1; }
    assert_contains "$out" 'not a ready matching native v2 root'
    case "$out" in *fixture-only-secret*) echo 'preflight leaked stored content'; _ocl_down; return 1;; esac
    assert_eq "$(_run_sessions_last "$T/repos/widget")" "$original"
    [ ! -f "$CEL_REX_STATE/received-argv" ] || { _ocl_down; return 1; }
  done
  local phase
  for phase in missing sessions corrupt; do
    _ocl_native_store '{}' "$phase" || { _ocl_down; return 1; }
    if opencode_validate_session "$original" "$T/repos/widget" cel-orchestrator >/dev/null 2>&1; then
      echo "admitted unfinished native migration: $phase"; _ocl_down; return 1
    fi
  done
  _ocl_native_store || { _ocl_down; return 1; }
  opencode_validate_session "$original" "$T/repos/widget" cel-orchestrator || { _ocl_down; return 1; }
  _ocl_down
}

test_opencode_native_resume_readonly_store_errors_never_create_or_relaunch() {
  _ocl_setup
  _run_sessions_record "$T/repos/widget" ses_SavedNative
  local stored="$OPENCODE_DB" file out rc
  for file in "$T/missing-native.db" "$T/corrupt-native.db"; do
    [ "$file" != "$T/corrupt-native.db" ] || printf 'unreadable fixture-only-secret' > "$file"
    rc=0
    out="$(OPENCODE_DB="$file"; AGENT_ARGS=(); _run_resume_resolve orchestrator widget-orch "$T/repos/widget" opencode '' 1 0 0 0 relaunch adopt 2>&1)" || rc=$?
    [ "$rc" != 0 ] || { echo 'unreadable store admitted'; _ocl_down; return 1; }
    case "$out" in *fixture-only-secret*) echo 'preflight leaked database content'; _ocl_down; return 1;; esac
    assert_eq "$(_run_sessions_last "$T/repos/widget")" ses_SavedNative
  done
  [ ! -e "$T/missing-native.db" ] || { echo 'preflight created absent native storage'; _ocl_down; return 1; }
  [ ! -e "$CEL_REX_STATE/widget-orch.json" ] || { echo 'preflight launched a native child'; _ocl_down; return 1; }
  OPENCODE_DB="$stored"
  _ocl_down
}

test_opencode_existing_native_resume_uses_private_server_and_scoped_selection() {
  _ocl_setup
  _run_sessions_record "$T/repos/widget" ses_SavedNative
  local out i
  if ! out="$(cd "$T" && cmd_run solo --product widget --session-backend rex --restart 2>&1)"; then
    echo "$out"; _ocl_down; return 1
  fi
  for ((i=0;i<100;i++)); do [ -f "$CEL_REX_STATE/received-affinity" ] && break; sleep 0.1; done
  assert_eq "$(jq -r .agent_session.value "$CEL_REX_STATE/widget-orch.json")" ses_SavedNative
  assert_contains "$(cat "$CEL_REX_STATE/received-argv")" '--server'
  assert_contains "$(cat "$CEL_REX_STATE/received-argv")" 'ses_SavedNative'
  assert_eq "$(cat "$CEL_REX_STATE/received-affinity")" widget-orch
  assert_eq "$(jq -r .holderPID "$CEL_REX_STATE/received-reporter")" "$(jq -r .pid "$CEL_REX_STATE/widget-orch.json")"
  [ "$(jq -r .childPID "$CEL_REX_STATE/received-reporter")" != "$(jq -r .pid "$CEL_REX_STATE/widget-orch.json")" ] || { _ocl_down; return 1; }
  _ocl_down
}

test_opencode_native_preflight_uses_launch_workspace_storage_overlay() {
  _ocl_setup
  local stored="$OPENCODE_DB"
  mkdir -p "$T/overlay"
  cat > "$T/overlay/workspace.yaml" <<YAML
name: alpha
env: {OPENCODE_DB: "$stored"}
YAML
  OPENCODE_DB="$T/not-the-launched-store.db" opencode_validate_session ses_SavedNative "$T/repos/widget" cel-orchestrator "$T/overlay" || { _ocl_down; return 1; }
  [ ! -e "$T/not-the-launched-store.db" ] || { _ocl_down; return 1; }
  _ocl_down
}

test_opencode_native_preflight_resolves_default_xdg_store_without_starting_runtime() {
  _ocl_setup
  local data="$T/private-xdg"
  mkdir -p "$data/opencode"
  OPENCODE_DB="$data/opencode/opencode.db" _ocl_native_store || { _ocl_down; return 1; }
  (unset OPENCODE_DB; XDG_DATA_HOME="$data" opencode_validate_session ses_SavedNative "$T/repos/widget" cel-orchestrator) || { _ocl_down; return 1; }
  [ ! -e "$CEL_REX_STATE/received-argv" ] || { _ocl_down; return 1; }
  _ocl_down
}

test_opencode_native_preflight_refuses_before_live_receipt_record_or_restart() {
  _ocl_setup
  local out rc=0
  _run_sessions_record "$T/repos/widget" ses_SavedNative
  out="$(
    _run_orch_agent() { printf 'widget-orch\trex/session:fixture/block:fixture\tidle\tses_AbsentNative\n'; }
    _run_sessions_record() { touch "$T/record-attempted"; }
    AGENT_ARGS=()
    _run_resume_resolve orchestrator widget-orch "$T/repos/widget" opencode '' 1 0 0 0 relaunch adopt 2>&1
  )" || rc=$?
  [ "$rc" != 0 ] || { echo 'absent live native root admitted'; _ocl_down; return 1; }
  assert_contains "$out" 'not a ready matching native v2 root'
  [ ! -e "$T/record-attempted" ] || { echo 'receipt mutated before admission'; _ocl_down; return 1; }
  [ ! -e "$CEL_REX_STATE/received-argv" ] || { echo 'child relaunched before admission'; _ocl_down; return 1; }
  assert_eq "$(_run_sessions_last "$T/repos/widget")" ses_SavedNative
  _ocl_down
}

test_opencode_direct_rex_resume_cannot_publish_missing_native_id() {
  _ocl_setup
  local role="$T/.cel/opencode/widget-orch/role-orchestrator.md" prefix session_backend=rex
  opencode_agent_args orchestrator fixture 0 "$role" "${role%.md}.opencode.json" http://127.0.0.1:8317/v1 || { _ocl_down; return 1; }
  prefix="$(_run_launch_env solo "$T" "$role" widget-orch opencode)"
  if (_rex_launch absent opencode "$T/repos/widget" fixture "$prefix" --standalone --auto --session ses_AbsentNative >/dev/null 2>&1); then
    echo 'direct Rex launch admitted a nonexistent native session'; _ocl_down; return 1
  fi
  [ ! -e "$CEL_REX_STATE/absent.json" ] && [ ! -e "$CEL_REX_STATE/absent.json.lock" ] && [ ! -e "$CEL_REX_STATE/received-argv" ] || { _ocl_down; return 1; }
  _ocl_down
}

test_opencode_native_preflight_rejects_directory_alias_adoption() {
  _ocl_setup
  ln -s "$T/repos/widget" "$T/widget-alias"
  if opencode_validate_session ses_SavedNative "$T/widget-alias" cel-orchestrator >/dev/null 2>&1; then
    echo 'native root adopted through a different location alias'; _ocl_down; return 1
  fi
  _ocl_down
}
