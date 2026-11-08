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
  if [ -n "${FAKE_REX_DIR:-}" ]; then
    for p in $(jq -r '.pids[]?' "$FAKE_REX_DIR/state.json" 2>/dev/null); do kill "$p" 2>/dev/null || true; done
  fi
  unset CEL_REX_STATE CEL_REX_BIN CEL_PROC_ROOT CEL_MANIFEST CEL_MANIFEST_CACHE CEL_ORCH_SESSIONS OPENCODE_DB CEL_OPENCODE_AGENT CEL_OPENCODE_CONFIG_FILE AGENT_ROLE_FILE FAKE_REX_DIR
  _gwc_teardown
}

_ocl_wait_file() { local i; for ((i=0;i<100;i++)); do [ -f "$1" ] && return 0; sleep 0.1; done; return 1; }

# --restart OF A LIVE REX AGENT, AS THE OWNER TYPES IT: no --session-backend,
# in a workspace that names none (Herdr by default) - the incident's line.
# The stateful fake Rex (sessions > windows > blocks, real processes), the real
# launcher and the native fixture. widget-orch is left idle on ses_SavedNative.
_ocl_rex_live() {
  export FAKE_REX_DIR="$T/fake-rex" CEL_REX_BIN="$CEL_ROOT/tests/lib/fake-rex"
  _run_sessions_record "$T/repos/widget" ses_SavedNative
  local out tmp
  out="$(cd "$T" && cmd_run solo --product widget --session-backend rex 2>&1)" || { echo "$out"; return 1; }
  _ocl_wait_file "$CEL_REX_STATE/received-argv" || { echo "$out"; echo 'the first launch never reached its TUI'; return 1; }
  tmp="$(mktemp "$CEL_REX_STATE/.idle.XXXXXX")"
  jq '.agent_status = "idle"' "$CEL_REX_STATE/widget-orch.json" > "$tmp" && mv "$tmp" "$CEL_REX_STATE/widget-orch.json"
  rm -f "$CEL_REX_STATE/received-argv"
}
# The first launch's claim (taken for no pane) has done its job once the agent
# is live; a restart of that pane past the claim window is the owner's case.
_ocl_restart() { ( unset CEL_SESSION_BACKEND; export CEL_SESSION_CLAIM_SECS=0; cd "$T" && cmd_run solo --product widget --restart "$@" 2>&1 ); }
_ocl_rex_sessions_with_terminals() {
  jq '[.sessions[] | select([.windows[].layers[].blocks[]] | length > 0)] | length' "$FAKE_REX_DIR/state.json"
}

test_opencode_rex_restart_relaunches_through_one_guarded_launcher() {
  _ocl_setup
  _ocl_rex_live || { _ocl_down; return 1; }
  local old new out
  old="$(jq -r .pid "$CEL_REX_STATE/widget-orch.json")"
  out="$(_ocl_restart)" || { echo "$out"; _ocl_down; return 1; }
  _ocl_wait_file "$CEL_REX_STATE/received-argv" || { echo "$out"; echo 'the relaunch never reached its TUI'; _ocl_down; return 1; }
  assert_contains "$(cat "$CEL_REX_STATE/received-argv")" ses_SavedNative
  ! kill -0 "$old" 2>/dev/null || { echo 'the old runtime survived its restart'; _ocl_down; return 1; }
  _rex_live "$CEL_REX_STATE/widget-orch.json" || { echo 'the relaunched runtime is not live'; _ocl_down; return 1; }
  new="$(jq -r .pid "$CEL_REX_STATE/widget-orch.json")"
  [ "$new" != "$old" ] || { _ocl_down; return 1; }
  # The runtime the private script exec'd: one guarded launcher, then the
  # native executable and the argv the launcher admits.
  local -a argv; mapfile -d '' -t argv < "/proc/$new/cmdline"
  assert_eq "${argv[*]:1}" "$CEL_ROOT/tools/opencode/launch.mjs -- $T/bin/opencode --standalone --auto --session ses_SavedNative"
  _ocl_down
}

test_opencode_rex_restart_dry_run_prints_the_line_the_restart_runs() {
  _ocl_setup
  _ocl_rex_live || { _ocl_down; return 1; }
  local out launcher
  out="$(_ocl_restart --dry-run)" || { echo "$out"; _ocl_down; return 1; }
  launcher="$(opencode_launch_command)"
  assert_contains "$out" "${launcher}opencode --standalone --auto --session ses_SavedNative>"
  local rest="${out#*"$launcher"}"
  case "$rest" in *launch.mjs*) echo "a second launcher in the restart line: $out"; _ocl_down; return 1 ;; esac
  _ocl_assert_gateway_masked "$out" || { _ocl_down; return 1; }
  _ocl_down
}

# A gateway profile's launch words are shown masked, never the key file the
# real line reads or the session key it routes by.
_ocl_assert_gateway_masked() { # <dry-run output>
  assert_contains "$1" 'OMP_GATEWAY_TOKEN=****'
  assert_contains "$1" 'CEL_SESSION_ID=****'
  case "$1" in
    *api-key*|*fixture-key*|*CEL_SESSION_ID=widget-orch*) echo "a gateway secret word in the dry run: $1"; return 1 ;;
  esac
}

# THE REVERSE CASE: a workspace defaulting to Rex, its agent in a Herdr pane.
# The restart types its line into that pane, so the line carries the OpenCode
# launcher itself - exactly once - or OpenCode would start unguarded.
test_opencode_herdr_restart_in_rex_default_workspace_types_its_launcher() {
  _ocl_setup
  printf 'session_backend: rex\n' >> "$T/workspace.yaml"
  herdr() {
    [ "$1 $2" = 'agent list' ] || return 1
    jq -cn --arg cwd "$T/repos/widget" '{result:{agents:[{name:"widget-orch",pane_id:"w1:p1",agent_status:"idle",agent:"opencode",cwd:$cwd,agent_session:{value:"ses_SavedNative"}}]}}'
  }
  _run_sessions_record "$T/repos/widget" ses_SavedNative
  # The role a live agent was launched with, private (a dry run writes none).
  (umask 077; printf 'fixture role\n' > "$T/.cel/opencode/widget-orch/role-orchestrator.md")
  local out typed launcher
  out="$(_ocl_restart --dry-run)" || { echo "$out"; _ocl_down; return 1; }
  assert_contains "$out" 'herdr pane send-keys w1:p1'
  case "$out" in *'rex new'*|*'rex block close'*) echo "a Herdr pane restarted through Rex: $out"; _ocl_down; return 1 ;; esac
  typed="$(printf '%s\n' "$out" | grep '^herdr pane send-text w1:p1 ')" || { echo "$out"; _ocl_down; return 1; }
  launcher="$(opencode_launch_command)"
  assert_contains "$typed" "$launcher"
  case "${typed#*"$launcher"}" in *launch.mjs*) echo "a second launcher typed: $typed"; _ocl_down; return 1 ;; esac
  assert_contains "$out" 'agent start widget-orch --kind opencode --pane w1:p1 -- --standalone --auto --session ses_SavedNative'
  _ocl_assert_gateway_masked "$out" || { _ocl_down; return 1; }
  _ocl_down
}

test_opencode_rex_restart_refused_relaunch_never_stops_the_agent() {
  _ocl_setup
  _ocl_rex_live || { _ocl_down; return 1; }
  local old out rc=0
  old="$(jq -r .pid "$CEL_REX_STATE/widget-orch.json")"
  # A relaunch line with an argument the launcher refuses (here a --model).
  out="$(_run_retry_overlay_args() { [ "$1" != opencode ] || AGENT_ARGS=(--model ompgw-codex/gpt-6.1-sol "${AGENT_ARGS[@]}"); }
    _ocl_restart)" || rc=$?
  [ "$rc" != 0 ] || { echo "a refused relaunch reported success: $out"; _ocl_down; return 1; }
  assert_contains "$out" 'reason=unsupported_argument'
  assert_contains "$out" 'was NOT stopped'
  _rex_live "$CEL_REX_STATE/widget-orch.json" || { echo 'the agent was stopped for a refused relaunch'; _ocl_down; return 1; }
  assert_eq "$(jq -r .pid "$CEL_REX_STATE/widget-orch.json")" "$old"
  ! grep -q '^block close' "$FAKE_REX_DIR/calls" || { echo 'its terminal was closed'; _ocl_down; return 1; }
  assert_eq "$(jq '.sessions | length' "$FAKE_REX_DIR/state.json")" 1
  _ocl_down
}

test_opencode_rex_restart_failed_relaunch_leaves_no_dead_terminal() {
  _ocl_setup
  _ocl_rex_live || { _ocl_down; return 1; }
  local out rc=0
  # Admissible argv, but the native server dies: the launcher refuses after
  # the old agent was stopped (server_exited).
  out="$(export CEL_FIXTURE_SERVE=exit; _ocl_restart)" || rc=$?
  [ "$rc" != 0 ] || { echo "a failed relaunch reported success: $out"; _ocl_down; return 1; }
  assert_contains "$out" 'its Rex terminal was closed'
  assert_contains "$out" 'Bring it back with: cel run solo --product widget --workspace alpha --session-backend rex'
  assert_eq "$(_ocl_rex_sessions_with_terminals)" 0
  [ ! -e "$CEL_REX_STATE/widget-orch.json" ] || { echo 'a dead receipt was left behind'; _ocl_down; return 1; }
  _ocl_down
}

# A WEDGED REX CANNOT STRETCH THE SETTLE. A relaunch whose runtime died is
# reaped through Rex calls bounded by the reap's own deadline (20 polls x
# 0.2s): a Rex that never answers leaves its terminal reported as not closed
# (2) on time, never a wait without end.
test_opencode_rex_settle_with_a_wedged_rex_ends_on_its_deadline() {
  local d rc=0 started took
  d="$(mktemp -d)"
  printf '#!/bin/bash\nexec sleep 30\n' > "$d/rex"; chmod +x "$d/rex"
  (exit 0) & local dead=$!; wait "$dead"
  jq -n --argjson pid "$dead" '{name:"dead",pid:$pid,pid_start:"gone",rex_session:"session:s",rex_block:"block:b",pane_id:"rex/session:s/block:b",rex_scope:"session"}' > "$d/dead.json"
  started="$SECONDS"
  (export CEL_REX_STATE="$d" CEL_REX_BIN="$d/rex"; rex_launch_settle dead opencode) 2>/dev/null || rc=$?
  took=$((SECONDS - started))
  rm -rf "$d"
  assert_eq "$rc" 2
  [ "$took" -le 7 ] || { echo "the settle waited ${took}s on a wedged Rex"; return 1; }
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

_ocl_two_model_grant() {
  local role="$T/.cel/opencode/widget-orch/role-orchestrator.md"
  opencode_agent_args orchestrator 'original scoped role' 0 "$role" "${role%.md}.opencode.json" http://127.0.0.1:8317/v1 || return 1
  node --input-type=module - "$role" "$CEL_ROOT/tools/opencode/plugin" <<'JS' | opencode_write_config "${role%.md}.opencode.json"
import { pathToFileURL } from 'node:url';
const { resolveCatalog } = await import(pathToFileURL(process.env.CEL_ROOT + '/tools/opencode/catalog.mjs'));
const { scopedConfigInput } = await import(pathToFileURL(process.env.CEL_ROOT + '/tools/opencode/config.mjs'));
const sol = { id: 'gpt-6.1-sol', name: 'Sol 6.1', api: 'openai-responses', contextWindow: 500000, maxTokens: 128000,
  input: ['text', 'image'], reasoning: true, thinking: { mode: 'effort', efforts: ['medium'] } };
const opus = { id: 'claude-opus-5-5', name: 'Claude Opus 5.5', api: 'anthropic-messages', contextWindow: 1000000, maxTokens: 128000,
  input: ['text', 'image'], reasoning: true, thinking: { mode: 'anthropic-adaptive', efforts: ['low', 'medium', 'high', 'max'] } };
const source = (providerKey, model) => ({ providerKey, schemaVersion: 14, updatedAt: 100, authoritative: true, models: [model] });
const catalog = resolveCatalog([sol.id, opus.id], [source('openai-codex:0.159.0', sol), source('anthropic', opus)]);
console.log(JSON.stringify(scopedConfigInput({ agent: 'cel-orchestrator', roleFile: process.argv[2],
  pluginFile: process.argv[3], baseURL: 'http://127.0.0.1:8317/v1', catalog })));
JS
}

test_opencode_requested_selection_opus_uses_private_grant_and_same_native_session() {
  _ocl_setup
  _ocl_two_model_grant || { _ocl_down; return 1; }
  _run_sessions_record "$T/repos/widget" ses_SavedNative
  local out i config="$T/.cel/opencode/widget-orch/role-orchestrator.opencode.json" before
  before="$(cat "$config")"
  export CEL_FIXTURE_EVENTS="$T/native-events.jsonl"
  if ! out="$(cd "$T" && CEL_FIXTURE_TUI_EXIT=1 cmd_run solo --product widget --session-backend rex --restart --model ompgw-claude/claude-opus-5-5 --thinking medium 2>&1)"; then
    echo "$out"; _ocl_down; return 1
  fi
  for ((i=0;i<100;i++)); do [ -f "$CEL_REX_STATE/received-affinity" ] && break; sleep 0.1; done
  assert_eq "$(jq -r .agent_session.value "$CEL_REX_STATE/widget-orch.json")" ses_SavedNative
  assert_eq "$(cat "$CEL_REX_STATE/received-affinity")" widget-orch
  assert_eq "$(cat "$config")" "$before"
  assert_eq "$(jq -r '.model.providerID + "/" + .model.model + "/" + .model.variant' "$config")" ompgw-codex/gpt-6.1-sol/medium
  case "$(cat "$CEL_REX_STATE/received-argv")" in *--model*|*--thinking*) echo 'selection leaked into unsupported native flags'; _ocl_down; return 1;; esac
  # Admission grants the owner choice; native selection remains unchanged until
  # the actual TUI picker, rather than silently rewriting native storage.
  assert_eq "$(jq -sr 'map(select(.event == "tui"))[0].handoff.model | .providerID + "/" + .id + "/" + .variant' "$CEL_FIXTURE_EVENTS")" ompgw-codex/gpt-6.1-sol/medium
  for ((i=0;i<100;i++)); do
    jq -se 'any(.[]; .event == "server-stop")' "$CEL_FIXTURE_EVENTS" >/dev/null 2>&1 && break
    sleep 0.05
  done
  jq -se 'any(.[]; .event == "server-stop")' "$CEL_FIXTURE_EVENTS" >/dev/null || { _ocl_down; return 1; }
  _ocl_down
}

test_opencode_requested_selection_rejects_ungranted_tuple_before_role_or_launch_mutation() {
  _ocl_setup
  _ocl_two_model_grant || { _ocl_down; return 1; }
  _run_sessions_record "$T/repos/widget" ses_SavedNative
  local role="$T/.cel/opencode/widget-orch/role-orchestrator.md" model thinking out before
  before="$(cat "$role")"
  for model in ompgw-claude/claude-unknown ompgw-codex/omp/gpt-6.1-sol native/claude-opus-5-5 ompgw-claude/claude-opus-5-5; do
    thinking=medium; [ "$model" != ompgw-claude/claude-opus-5-5 ] || thinking=invalid
    if out="$(cd "$T" && cmd_run solo --product widget --session-backend rex --restart --model "$model" --thinking "$thinking" 2>&1)"; then
      echo "ungranted requested selection admitted: $model $thinking"; _ocl_down; return 1
    fi
    assert_contains "$out" 'not granted by the private canonical scope'
    assert_eq "$(cat "$role")" "$before"
    assert_eq "$(_run_sessions_last "$T/repos/widget")" ses_SavedNative
    [ ! -e "$CEL_REX_STATE/widget-orch.json" ] && [ ! -e "$CEL_REX_STATE/received-argv" ] || { _ocl_down; return 1; }
  done
  _ocl_down
}

test_opencode_requested_selection_legacy_grant_rejects_opus_and_keeps_sol_medium() {
  _ocl_setup
  local role="$T/.cel/opencode/widget-orch/role-orchestrator.md" out before
  opencode_agent_args orchestrator 'original scoped role' 0 "$role" "${role%.md}.opencode.json" http://127.0.0.1:8317/v1 || { _ocl_down; return 1; }
  before="$(cat "$role")"
  if out="$(cd "$T" && cmd_run solo --product widget --session-backend rex --restart --model ompgw-claude/claude-opus-5-5 --thinking medium 2>&1)"; then
    echo 'legacy Sol-only grant admitted Opus'; _ocl_down; return 1
  fi
  assert_contains "$out" 'not granted by the private canonical scope'
  assert_eq "$(cat "$role")" "$before"
  opencode_validate_requested_selection "$T" orchestrator "$role" "${role%.md}.opencode.json" ompgw-codex/gpt-6.1-sol medium || { _ocl_down; return 1; }
  if opencode_validate_requested_selection "$T" orchestrator "$role" "${role%.md}.opencode.json" ompgw-codex/gpt-6.1-sol high >/dev/null 2>&1; then
    echo 'legacy grant admitted another variant'; _ocl_down; return 1
  fi
  [ ! -e "$CEL_REX_STATE/widget-orch.json" ] && [ ! -e "$CEL_REX_STATE/received-argv" ] || { _ocl_down; return 1; }
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
