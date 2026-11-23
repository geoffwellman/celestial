# shellcheck shell=bash
# --restart of core and of a solo lane standing in Rex, typed as the owner
# types it (no --session-backend, from a Herdr default), through the stateful
# fake Rex (tests/lib/fake-rex) with real runtime processes. A relaunch whose
# terminal never starts its runtime closes that terminal and says how to bring
# the agent back.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/run.sh"

_rr_setup() {
  RT="$(mktemp -d)"
  export CEL_REX_STATE="$RT/state" CEL_MANIFEST="$RT/agents.yaml" CEL_MANIFEST_CACHE="$RT/cache"
  export FAKE_REX_DIR="$RT/rex" CEL_REX_BIN="$RT/bin/rex" CEL_CORE_DIR="$RT/core" CEL_PROC_ROOT="$RT/proc"
  mkdir -p "$RT/bin" "$RT/ws/repos/widget" "$CEL_REX_STATE" "$CEL_PROC_ROOT"
  cat > "$CEL_MANIFEST" <<YAML
defaults:
  core: { runtime: omp }
agents:
  omp:
    bin: "$RT/bin/runtime"
    role_injection: { strategy: append_flag_file, flag: --append-system-prompt }
    resume: { flag: --resume, value: path }
YAML
  cat > "$RT/ws/workspace.yaml" <<'YAML'
name: alpha
runtime: { orchestrator: omp, worker: omp }
repos:
  - name: widget
    url: git@github.com:acme/widget.git
    mode: solo
policy: { merge: self, pr: required }
YAML
  # The fake Rex, except that while $FAKE_REX_DIR/sabotage names a mode a new
  # terminal runs something else: `nostart` never writes the launch's pid;
  # `deadpid` writes a pid that has already exited; `wedged` is `nostart`,
  # after which every Rex call hangs (a wedged server or client).
  cat > "$RT/bin/rex" <<'SH'
#!/bin/bash
mode="$(cat "$FAKE_REX_DIR/sabotage" 2>/dev/null)"
[ ! -e "$FAKE_REX_DIR/wedge" ] || exec sleep 8
if [ "${1:-}" = new ] && [ -n "$mode" ]; then
  args=(); for a in "$@"; do [ "$a" = -- ] && break; args+=("$a"); done
  case "$mode" in
    nostart) exec "$CEL_ROOT/tests/lib/fake-rex" "${args[@]}" -- /bin/true ;;
    wedged) "$CEL_ROOT/tests/lib/fake-rex" "${args[@]}" -- /bin/true; rc=$?; : > "$FAKE_REX_DIR/wedge"; exit "$rc" ;;
    deadpid) exec "$CEL_ROOT/tests/lib/fake-rex" "${args[@]}" -- /bin/sh -c '(exit 0) & p=$!; wait "$p"; printf "%s" "$p" > "$1"' sh "$CEL_REX_STATE/$2.json.pid" ;;
  esac
fi
exec "$CEL_ROOT/tests/lib/fake-rex" "$@"
SH
  printf '#!/bin/bash\nexec sleep 300\n' > "$RT/bin/runtime"
  cat > "$RT/bin/herdr" <<'SH'
#!/bin/bash
[ "$*" = 'agent list' ] || { echo 'unexpected Herdr action' >&2; exit 1; }
printf '{"result":{"agents":[]}}'
SH
  chmod +x "$RT/bin/"*
  RR_OLD_PATH="$PATH"; export PATH="$RT/bin:$PATH"
}
_rr_down() {
  local f p
  for f in "$CEL_REX_STATE"/*.json; do
    [ -f "$f" ] && _rex_live "$f" || continue
    kill "$(jq -r .pid "$f")" 2>/dev/null || true
  done
  for p in $(jq -r '.pids[]?' "$FAKE_REX_DIR/state.json" 2>/dev/null); do kill "$p" 2>/dev/null || true; done
  export PATH="$RR_OLD_PATH"
  unset CEL_REX_STATE CEL_MANIFEST CEL_MANIFEST_CACHE FAKE_REX_DIR CEL_REX_BIN CEL_CORE_DIR CEL_PROC_ROOT
  rm -rf "$RT"
}
_rr_terminals() { # sessions still holding a terminal
  jq '[.sessions[] | select([.windows[].layers[].blocks[]] | length > 0)] | length' "$FAKE_REX_DIR/state.json"
}
_rr_idle() { # <name>: a live receipt the restart may replace
  local f="$CEL_REX_STATE/$1.json" tmp
  _rex_live "$f" || { echo "$1 is not live in Rex"; return 1; }
  tmp="$(mktemp "$CEL_REX_STATE/.idle.XXXXXX")"
  jq '.agent_status = "idle"' "$f" > "$tmp" && mv "$tmp" "$f"
}

test_rex_core_restart_from_herdr_default_relaunches_in_rex() {
  _rr_setup
  local out old
  out="$(cmd_run core --session-backend rex --fresh 2>&1)" || { echo "$out"; _rr_down; return 1; }
  _rr_idle core || { _rr_down; return 1; }
  old="$(jq -r .pid "$CEL_REX_STATE/core.json")"
  out="$( (unset CEL_SESSION_BACKEND; cmd_run core --restart --fresh --dry-run) 2>&1)" || { echo "$out"; _rr_down; return 1; }
  assert_contains "$out" 'rex block close <owned terminal>; rex new core'
  assert_contains "$out" 'exec env CEL_ROLE=core'
  out="$( (unset CEL_SESSION_BACKEND; cmd_run core --restart --fresh) 2>&1)" || { echo "$out"; _rr_down; return 1; }
  _rex_live "$CEL_REX_STATE/core.json" || { echo "$out"; echo 'core is not live after its restart'; _rr_down; return 1; }
  [ "$(jq -r .pid "$CEL_REX_STATE/core.json")" != "$old" ] || { echo 'core was not relaunched'; _rr_down; return 1; }
  ! kill -0 "$old" 2>/dev/null || { echo 'the old core survived'; _rr_down; return 1; }
  _rr_down
}

test_rex_core_restart_whose_terminal_never_starts_closes_it_and_says_how_back() {
  _rr_setup
  local out rc=0
  out="$(cmd_run core --session-backend rex --fresh 2>&1)" || { echo "$out"; _rr_down; return 1; }
  _rr_idle core || { _rr_down; return 1; }
  printf nostart > "$FAKE_REX_DIR/sabotage"
  out="$( (unset CEL_SESSION_BACKEND; cmd_run core --restart --fresh) 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "a relaunch that never started reported success: $out"; _rr_down; return 1; }
  assert_contains "$out" 'opened but has not started its runtime'
  assert_contains "$out" 'its Rex terminal was closed'
  assert_contains "$out" 'Bring it back with: cel run core --session-backend rex'
  assert_eq "$(_rr_terminals)" 0
  [ ! -e "$CEL_REX_STATE/core.json.pending" ] && [ ! -e "$CEL_REX_STATE/core.json" ] || { echo 'launch markers left behind'; _rr_down; return 1; }
  # The terminal never ran its one-shot script, which deletes itself only when
  # run: the abandon removes it.
  ! compgen -G "$CEL_REX_STATE/.launch.*" >/dev/null || { echo 'the private launch script was left behind'; _rr_down; return 1; }
  # Nothing is left to refuse the line the restart named.
  rm -f "$FAKE_REX_DIR/sabotage"
  out="$( (unset CEL_SESSION_BACKEND; cmd_run core --session-backend rex --fresh) 2>&1)" || { echo "$out"; _rr_down; return 1; }
  _rex_live "$CEL_REX_STATE/core.json" || { echo 'core did not come back'; _rr_down; return 1; }
  _rr_down
}

# A WEDGED REX CANNOT STRETCH THE ABANDON. Every Rex call there is bounded by
# the abandon's own deadline (CEL_REX_ABANDON_POLLS x 0.2s), so a server or
# client that never answers ends the wait on time: the terminal is reported
# as not closed and the pending markers stay, refusing a blind retry.
test_rex_abandon_with_a_wedged_rex_ends_on_its_deadline() {
  _rr_setup
  local out rc=0 started took
  out="$(cmd_run core --session-backend rex --fresh 2>&1)" || { echo "$out"; _rr_down; return 1; }
  _rr_idle core || { _rr_down; return 1; }
  printf wedged > "$FAKE_REX_DIR/sabotage"
  started="$SECONDS"
  out="$( (unset CEL_SESSION_BACKEND; export CEL_REX_ABANDON_POLLS=5; cmd_run core --restart --fresh) 2>&1)" || rc=$?
  took=$((SECONDS - started))
  rm -f "$FAKE_REX_DIR/wedge"
  [ "$rc" != 0 ] || { echo "a relaunch that never started reported success: $out"; _rr_down; return 1; }
  # 5s waiting for the runtime's pid, then at most 1s of bounded Rex calls.
  [ "$took" -le 9 ] || { echo "the abandon waited ${took}s on a wedged Rex: $out"; _rr_down; return 1; }
  assert_contains "$out" 'opened but has not started its runtime'
  assert_contains "$out" 'its Rex terminal could not be closed'
  [ -e "$CEL_REX_STATE/core.json.pending" ] || { echo 'the pending marker of an unclosed terminal was removed'; _rr_down; return 1; }
  _rr_down
}

test_rex_lane_restart_whose_runtime_died_at_birth_closes_it_and_names_the_lane() {
  _rr_setup
  local out rc=0
  out="$(cd "$RT/ws" && cmd_run solo --product widget --lane ui --session-backend rex --fresh 2>&1)" || { echo "$out"; _rr_down; return 1; }
  _rr_idle widget-ui || { ls "$CEL_REX_STATE"; _rr_down; return 1; }
  printf deadpid > "$FAKE_REX_DIR/sabotage"
  out="$( (unset CEL_SESSION_BACKEND; cd "$RT/ws" && cmd_run solo --product widget --lane ui --restart --fresh) 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "a relaunch that died at birth reported success: $out"; _rr_down; return 1; }
  assert_contains "$out" 'exited during startup'
  assert_contains "$out" 'its Rex terminal was closed'
  assert_contains "$out" 'Bring it back with: cel run solo --product widget --lane ui --workspace alpha --session-backend rex'
  assert_eq "$(_rr_terminals)" 0
  _rr_down
}

test_rex_restart_recovery_line_without_a_recorded_relaunch_is_a_hand_restart() {
  local out
  out="$(_REX_RELAUNCH='' product=widget lane=ui solo_forced=1 wsdir=/nonexistent/alpha; ws_name() { printf alpha; }
    _run_restart_back orchestrator widget-ui)"
  assert_eq "$out" 'No relaunch line was recorded for widget-ui: restart it by hand with cel run solo --product widget --lane ui --workspace alpha --session-backend rex, adding the profile/model it ran on'
  out="$(_REX_RELAUNCH='' product=widget wsdir=/nonexistent/alpha; ws_name() { printf alpha; }
    _run_restart_back orchestrator widget-orch)"
  assert_eq "$out" 'No relaunch line was recorded for widget-orch: restart it by hand with cel run orchestrator --product widget --workspace alpha --session-backend rex, adding the profile/model it ran on'
  # An orchestrator's line always names a product; one this launch could not
  # determine is said so, never silently left out.
  out="$(_REX_RELAUNCH='' product='' wsdir=/nonexistent/alpha; ws_name() { printf alpha; }
    _run_restart_back orchestrator widget-orch)"
  assert_eq "$out" 'No relaunch line was recorded for widget-orch, and its product could not be determined: restart it by hand with cel run orchestrator --product <product> --workspace alpha --session-backend rex, naming its product and adding the profile/model it ran on'
  out="$(_REX_RELAUNCH=''; _run_restart_back core core)"
  assert_contains "$out" 'restart it by hand with cel core --session-backend rex'
  out="$(_REX_RELAUNCH='["run","core","--session-backend","rex"]'; _run_restart_back core core)"
  assert_eq "$out" 'Bring it back with: cel run core --session-backend rex'
}

# A DEAD RUNTIME SHIM IS REFUSED BEFORE ANYTHING MOVES. The runtime's bin is a
# mise shim with no version behind it (its npm package under a node that is
# no longer active): `command -v` finds it, and it dies at exec. A --restart
# that found out only after stopping the agent closed its terminal and left a
# dead relaunch behind. It is refused first: the live agent keeps running in
# its terminal, Rex is asked to close and open nothing, and a new launch
# opens no session.
_rr_dead_shim() { # the runtime's bin becomes a dead mise shim
  mkdir -p "$RT/mise"
  cat > "$RT/mise/mise" <<'SH'
#!/bin/bash
n="${0##*/}"
if [ "$n" != mise ]; then echo "mise ERROR No version is set for shim: $n" >&2; exit 1; fi
[ "${1:-}" = which ] && { echo "mise ERROR $2 is a mise bin however it is not currently active." >&2; exit 1; }
exit 2
SH
  chmod +x "$RT/mise/mise"
  ln -sfn "$RT/mise/mise" "$RT/bin/runtime"
}

test_rex_restart_with_a_dead_runtime_shim_stops_nothing() {
  _rr_setup
  local out rc=0 old calls
  out="$(cmd_run core --session-backend rex --fresh 2>&1)" || { echo "$out"; _rr_down; return 1; }
  _rr_idle core || { _rr_down; return 1; }
  old="$(jq -r .pid "$CEL_REX_STATE/core.json")"
  calls="$(wc -l < "$FAKE_REX_DIR/calls")"
  # the launch script has exec'd the runtime (it waits for its receipt first)
  local i; for ((i = 0; i < 100; i++)); do [ "$(cat "/proc/$old/comm" 2>/dev/null)" = sleep ] && break; sleep 0.1; done
  [ "$(cat "/proc/$old/comm" 2>/dev/null)" = sleep ] || { echo 'the runtime never started'; _rr_down; return 1; }
  _rr_dead_shim
  out="$( (unset CEL_SESSION_BACKEND; cmd_run core --restart --fresh) 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "a restart onto a dead shim reported success: $out"; _rr_down; return 1; }
  assert_contains "$out" "omp cannot start" || { _rr_down; return 1; }
  assert_contains "$out" "No version is set for shim: runtime" || { _rr_down; return 1; }
  assert_contains "$out" "Nothing was stopped, claimed or launched" || { _rr_down; return 1; }
  assert_contains "$out" "cel setup --agents omp" || { _rr_down; return 1; }
  _rex_live "$CEL_REX_STATE/core.json" || { echo 'the live agent was stopped'; _rr_down; return 1; }
  assert_eq "$(jq -r .pid "$CEL_REX_STATE/core.json")" "$old" || { _rr_down; return 1; }
  # Rex was not asked anything: no terminal closed, no session opened
  assert_eq "$(wc -l < "$FAKE_REX_DIR/calls")" "$calls" || { tail -n +"$((calls + 1))" "$FAKE_REX_DIR/calls"; _rr_down; return 1; }
  assert_eq "$(_rr_terminals)" 1 || { _rr_down; return 1; }
  _rr_down
}

test_rex_launch_with_a_dead_runtime_shim_opens_no_session() {
  _rr_setup
  _rr_dead_shim
  local out rc=0
  out="$(cd "$RT/ws" && cmd_run solo --product widget --session-backend rex --fresh 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "a launch onto a dead shim reported success: $out"; _rr_down; return 1; }
  assert_contains "$out" "No version is set for shim: runtime" || { _rr_down; return 1; }
  [ ! -s "$FAKE_REX_DIR/calls" ] || { echo "Rex was called:"; cat "$FAKE_REX_DIR/calls"; _rr_down; return 1; }
  ! compgen -G "$CEL_REX_STATE/*.json*" >/dev/null || { echo 'launch markers left behind'; ls "$CEL_REX_STATE"; _rr_down; return 1; }
  _rr_down
}

# The first claim of a session finds no claim file: that is said nothing
# about (it read as a missing session-claims directory on every launch).
test_first_session_claim_prints_nothing() {
  local t err rc=0
  t="$(mktemp -d)"
  err="$( (export CEL_ORCH_SESSIONS="$t/state/orch-sessions.json"; _run_session_claim /x/session.jsonl rex/s/b && _run_session_release /x/session.jsonl "$_RUN_SESSION_CLAIM_TOKEN") 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" 0 || { rm -rf "$t"; return 1; }
  assert_eq "$err" "" || { rm -rf "$t"; return 1; }
  err="$( (export CEL_ORCH_SESSIONS="$t/state/orch-sessions.json"; _run_session_release /x/other.jsonl tok) 2>&1 >/dev/null)"
  assert_eq "$err" "" || { rm -rf "$t"; return 1; }
  rm -rf "$t"
}
