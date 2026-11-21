# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/run.sh"

_rext_setup() {
  RT="$(mktemp -d)"
  export CEL_REX_STATE="$RT/state" CEL_REX_BIN="$RT/bin/rex" CEL_MANIFEST="$RT/agents.yaml" CEL_MANIFEST_CACHE="$RT/cache"
  mkdir -p "$RT/bin" "$RT/ws/repos/widget" "$CEL_REX_STATE"
  cat > "$CEL_MANIFEST" <<YAML
agents:
  omp:
    bin: "$RT/bin/runtime"
    role_injection: { strategy: append_flag_file, flag: --append-system-prompt }
    model_flag: --model
    resume: { flag: --resume, value: path }
YAML
  cat > "$RT/ws/workspace.yaml" <<'YAML'
name: alpha
runtime: { orchestrator: omp, worker: omp }
env: { REX_FIXTURE_SETTING: "declared workspace value" }
repos:
  - name: widget
    url: git@github.com:acme/widget.git
policy: { merge: self, pr: required }
YAML
  printf 'REX_LOCAL_SETTING="local workspace value"\n' > "$RT/ws/env.local"
  cat > "$RT/bin/rex" <<'SH'
#!/bin/bash
case "$1" in
  new)
    shift
    cwd=""
    while [ "$1" != -- ]; do
      if [ "$1" = --cwd ]; then cwd="$2"; shift 2; else shift; fi
    done; shift
    (cd "$cwd" && exec "$@") >/dev/null 2>&1 &
    printf '{"session_id":"session:test","initial_windows":[{"block_ids":["block:test"]}]}' ;;
  block)
    # tests create exactly one runtime under this fixture root
    for f in "$CEL_REX_STATE"/*.json; do [ -f "$f" ] || continue; kill "$(jq -r .pid "$f")"; done ;;
  *) exit 1 ;;
esac
SH
  cat > "$RT/bin/runtime" <<'SH'
#!/bin/bash
printf '%s\n' "$CEL_ROLE" "$CEL_INBOX_ME" "$CEL_SESSION_BACKEND" "$PWD" > "$CEL_REX_STATE/observed"
printf '%s\n' "$@" > "$CEL_REX_STATE/args"
printf '%s\n' "$REX_FIXTURE_SETTING" "$REX_LOCAL_SETTING" > "$CEL_REX_STATE/workspace-env"
printf '%s' "$PATH" > "$CEL_REX_STATE/path.tmp" && mv "$CEL_REX_STATE/path.tmp" "$CEL_REX_STATE/path"
exec sleep 300
SH
  cat > "$RT/bin/herdr" <<'SH'
#!/bin/bash
[ "$*" = 'agent list' ] || { echo 'unexpected Herdr action' >&2; exit 1; }
printf '{"result":{"agents":[]}}'
SH
  chmod +x "$RT/bin/"*
  REX_OLD_PATH="$PATH"; export PATH="$RT/bin:$PATH"
}
_rext_down() {
  local f
  for f in "$CEL_REX_STATE"/*.json; do
    [ -f "$f" ] && _rex_live "$f" || continue
    [ "$(jq -r .pid "$f")" = "$$" ] || kill "$(jq -r .pid "$f")" 2>/dev/null
  done
  export PATH="$REX_OLD_PATH"
  unset CEL_REX_STATE CEL_REX_BIN CEL_MANIFEST CEL_MANIFEST_CACHE CEL_REX_RECORD \
    CEL_AGENT_SYSTEMD_RUN CEL_AGENT_SYSTEMCTL CEL_MEMINFO CEL_CONFIG_FILE
  rm -rf "$RT"
}

test_rex_run_preserves_role_inbox_args_and_working_directory() {
  _rext_setup
  local out rc=0
  out="$(cd "$RT/ws" && cmd_run orchestrator --repo widget --session-backend rex --fresh 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; _rext_down; return 1; }
  local i
  for ((i=0;i<50;i++)); do [ -f "$CEL_REX_STATE/observed" ] && break; sleep 0.1; done
  assert_eq "$(cat "$CEL_REX_STATE/observed")" "$(printf 'solo\nwidget-orch\nrex\n%s' "$RT/ws/repos/widget")"
  assert_contains "$(cat "$CEL_REX_STATE/args")" '--append-system-prompt'
  assert_eq "$(cat "$CEL_REX_STATE/workspace-env")" "$(printf 'declared workspace value\nlocal workspace value')"
  assert_eq "$(cel_agent_list | jq -r '.result.agents[0].pane_id')" 'rex/session:test/block:test'
  # Admission is shared: a Rex agent blocks a duplicate Herdr launch too.
  if (cd "$RT/ws" && cmd_run orchestrator --repo widget --session-backend herdr --dry-run >/dev/null 2>&1); then
    echo 'duplicate admitted across terminal backends'; _rext_down; return 1
  fi
  _rext_down
}

test_rex_native_state_updates_only_the_same_launched_process() {
  _rext_setup
  _rex_launch widget-orch omp "$RT/ws/repos/widget" widget 'env CEL_ROLE=orchestrator' >/dev/null
  export CEL_REX_RECORD="$CEL_REX_STATE/widget-orch.json"
  local pid original self="${BASHPID:-$$}" start
  pid="$(jq -r .pid "$CEL_REX_RECORD")"
  original="$(cat "$CEL_REX_RECORD")"
  if rex_session_note "$pid" idle /tmp/forged.jsonl; then
    echo 'parent could impersonate its runtime by knowing the PID'; _rext_down; return 1
  fi
  # A receipt naming this test shell lets its real child hook report, without
  # replacing the ancestry check or inventing an unrelated reporter process.
  start="$(_rex_pid_start "$self")"
  jq --argjson p "$self" --arg s "$start" '.pid=$p | .pid_start=$s' <<<"$original" > "$CEL_REX_RECORD"
  rex_session_note "$self" idle /tmp/native-session.jsonl
  assert_eq "$(rex_agent_list | jq -r '.result.agents[0].agent_status')" idle
  assert_eq "$(rex_agent_list | jq -r '.result.agents[0].agent_session.value')" /tmp/native-session.jsonl
  if rex_session_note 1 working; then echo 'other process updated the record'; return 1; fi
  printf '%s\n' "$original" > "$CEL_REX_RECORD"
  rex_agent_stop rex/session:test/block:test
  assert_eq "$(rex_agent_list | jq '.result.agents|length')" 0
  _rext_down
}

# omp runs task subagents in the lane's own process, so the hook can report a
# subagent's transcript - a file inside the parent session's own directory.
# The receipt must never record that as the lane's session.
test_rex_omp_subagent_transcript_is_never_captured_as_the_session() {
  _rext_setup
  local self="${BASHPID:-$$}" parent sub cwd="$RT/ws/repos/widget"
  parent="$RT/sessions/2026-11-02T00-00-00-000Z_01abc.jsonl"
  sub="${parent%.jsonl}/WidgetSyncTask.jsonl"
  mkdir -p "${parent%.jsonl}"; : > "$parent"; : > "$sub"
  export CEL_REX_RECORD="$CEL_REX_STATE/widget-solo.json" CEL_ORCH_SESSIONS="$RT/sessions.json"
  jq -n --argjson pid "$self" --arg start "$(_rex_pid_start "$self")" --arg w "$cwd" \
    '{name:"widget-solo",pid:$pid,pid_start:$start,cwd:$w,workspace:$w,role:"solo",agent:"omp",backend:"rex",rex_session:"session:test",rex_block:"block:test",pane_id:"rex/session:test/block:test",agent_status:"idle"}' > "$CEL_REX_RECORD"
  cmd_sessions note "$self" working "$parent" || { rm -f "$CEL_REX_RECORD"; _rext_down; return 1; }
  cmd_sessions note "$self" idle "$sub" || { rm -f "$CEL_REX_RECORD"; _rext_down; return 1; }
  local value status last
  value="$(jq -r .agent_session.value "$CEL_REX_RECORD")"; status="$(jq -r .agent_status "$CEL_REX_RECORD")"
  last="$(_run_sessions_last "$cwd")"
  rm -f "$CEL_REX_RECORD"; unset CEL_ORCH_SESSIONS; _rext_down
  assert_eq "$value" "$parent"
  # the subagent finishing is not the lane going idle
  assert_eq "$status" working
  assert_eq "$last" "$parent"
}

test_rex_dead_pid_receipt_does_not_claim_a_live_session() {
  _rext_setup
  jq -n --argjson p "$$" '{name:"widget-orch",pid:$p,pid_start:"incorrect",pane_id:"rex/session:test/block:test"}' > "$CEL_REX_STATE/widget-orch.json"
  assert_eq "$(rex_agent_list | jq '.result.agents|length')" 0
  _rext_down
}

test_rex_workspace_default_and_explicit_override_are_independent_of_runtime() {
  _rext_setup
  printf '\nsession_backend: rex\n' >> "$RT/ws/workspace.yaml"
  local out
  out="$(cd "$RT/ws" && cmd_run orchestrator --repo widget --dry-run --fresh 2>&1)"
  assert_contains "$out" 'rex new widget-orch'
  out="$(cd "$RT/ws" && cmd_run orchestrator --repo widget --session-backend herdr --dry-run --fresh 2>&1)"
  assert_contains "$out" 'herdr agent start widget-orch --kind omp'
  if (cd "$RT/ws" && cmd_run orchestrator --repo widget --session-backend typo --dry-run >/dev/null 2>&1); then
    echo 'unknown terminal backend accepted'; _rext_down; return 1
  fi
  _rext_down
}

test_rex_reviewer_identity_is_bound_to_workspace_repo_and_pr() {
  _rext_setup
  local pid="$$" start; start="$(_rex_pid_start "$pid")"
  jq -n --argjson pid "$pid" --arg s "$start" --arg w "$RT/ws" \
    '{name:"widget-pr-7-review",role:"reviewer",workspace:$w,repo:"widget",pr:"7",pid:$pid,pid_start:$s}' > "$CEL_REX_STATE/widget-pr-7-review.json"
  CEL_SESSION_BACKEND=rex cel_assert_reviewer_identity widget-pr-7-review "$RT/ws" widget 7
  if (CEL_SESSION_BACKEND=rex cel_assert_reviewer_identity widget-pr-7-review "$RT/ws" widget 8 >/dev/null 2>&1); then
    echo 'reviewer admitted for another PR'; _rext_down; return 1
  fi
  if (CEL_SESSION_BACKEND=rex cel_assert_reviewer_identity widget-pr-7-review "$RT/other" widget 7 >/dev/null 2>&1); then
    echo 'reviewer admitted for another workspace'; _rext_down; return 1
  fi
  # Do not signal this test process during fixture teardown.
  rm -f "$CEL_REX_STATE/widget-pr-7-review.json"
  _rext_down
}

test_rex_native_session_map_keeps_concurrent_product_updates() {
  local d; d="$(mktemp -d)"
  export CEL_ORCH_SESSIONS="$d/sessions.json"
  local i; local -a children=()
  for i in 1 2 3 4 5 6 7 8; do
    _run_sessions_record "/product/$i" "/session/$i" & children+=("$!")
  done
  for i in "${children[@]}"; do wait "$i" || return 1; done
  for i in 1 2 3 4 5 6 7 8; do assert_eq "$(_run_sessions_last "/product/$i")" "/session/$i"; done
  unset CEL_ORCH_SESSIONS; rm -rf "$d"
}

_rext_wait_file() { # bounded barrier for the concurrent launch fixture
  local i
  for ((i=0;i<500;i++)); do [ -f "$1" ] && return 0; sleep 0.01; done
  return 1
}

test_rex_concurrent_herdr_start_waits_for_publication_then_refuses_duplicate() (
  _rext_setup
  first=""; second=""
  trap 'kill "${first:-}" "${second:-}" 2>/dev/null || true; _rext_down' EXIT
  export REXT_REAL_REX="$CEL_REX_BIN"
  cat > "$RT/bin/paused-rex" <<'SH'
#!/bin/bash
if [ "$1" = new ]; then
  : > "$CEL_REX_STATE/new-entered"
  for ((i=0;i<500;i++)); do [ -f "$CEL_REX_STATE/release-new" ] && break; sleep 0.01; done
  [ -f "$CEL_REX_STATE/release-new" ] || exit 1
fi
exec "$REXT_REAL_REX" "$@"
SH
  chmod +x "$RT/bin/paused-rex"
  export CEL_REX_BIN="$RT/bin/paused-rex"
  cd "$RT/ws" || return 1
  cmd_run orchestrator --repo widget --session-backend rex --fresh > "$RT/first.out" 2>&1 &
  first=$!
  _rext_wait_file "$CEL_REX_STATE/new-entered" || { echo 'Rex launch never reached the publication barrier'; return 1; }
  [ ! -f "$CEL_REX_STATE/widget-orch.json" ] || { echo 'fixture did not hold the pre-publication window'; return 1; }

  # Observe the second command reaching the real lock, without replacing the
  # lock or admission decision. The first child predates this wrapper.
  flock() {
    : > "$CEL_REX_STATE/second-attempt"
    command flock "$@" || return $?
    : > "$CEL_REX_STATE/second-granted"
  }
  cmd_run orchestrator --repo widget --session-backend herdr --fresh > "$RT/second.out" 2>&1 &
  second=$!
  _rext_wait_file "$CEL_REX_STATE/second-attempt" || { echo 'Herdr start did not attempt admission'; return 1; }
  [ ! -f "$CEL_REX_STATE/second-granted" ] || { echo 'Herdr start crossed admission before Rex publication'; return 1; }
  kill -0 "$second" 2>/dev/null || { echo 'Herdr start exited instead of waiting for publication'; return 1; }

  : > "$CEL_REX_STATE/release-new"
  wait "$first" || { cat "$RT/first.out"; return 1; }
  first=""
  _rext_wait_file "$CEL_REX_STATE/second-granted" || { echo 'launch lock stayed held after Rex publication'; return 1; }
  if wait "$second"; then echo 'concurrent Herdr duplicate was admitted'; return 1; fi
  second=""
  assert_contains "$(cat "$RT/second.out")" 'already live'
  assert_eq "$(rex_agent_list | jq '.result.agents | length')" 1
)

test_rex_unknown_inventory_refuses_launch_and_preserves_corrupt_receipts() {
  _rext_setup
  printf '#!/bin/bash\nprintf "{}"\n' > "$RT/bin/herdr"
  chmod +x "$RT/bin/herdr"
  if cel_agent_list >/dev/null 2>&1; then echo 'invalid Herdr response became empty roster'; _rext_down; return 1; fi
  if (cd "$RT/ws" && cmd_run orchestrator --repo widget --session-backend rex --fresh >/dev/null 2>&1); then
    echo 'launched with unknown Herdr inventory'; _rext_down; return 1
  fi
  printf '{broken' > "$CEL_REX_STATE/widget-orch.json"
  if rex_agent_list >/dev/null 2>&1; then echo 'corrupt Rex receipt became absent agent'; _rext_down; return 1; fi
  if (_rex_launch widget-orch omp "$RT/ws/repos/widget" widget 'env CEL_ROLE=orchestrator' >/dev/null 2>&1); then
    echo 'replaced corrupt receipt'; _rext_down; return 1
  fi
  assert_eq "$(cat "$CEL_REX_STATE/widget-orch.json")" '{broken'
  rm -f "$CEL_REX_STATE/widget-orch.json"
  _rext_down
}

test_rex_live_receipt_without_turn_state_is_unknown_not_absent() {
  _rext_setup
  jq -n --argjson pid "$$" --arg start "$(_rex_pid_start "$$")" --arg w "$RT/ws" \
    '{name:"widget-orch",pid:$pid,pid_start:$start,cwd:$w,workspace:$w,role:"orchestrator",agent:"omp",backend:"rex",rex_session:"session:test",rex_block:"block:test",pane_id:"rex/session:test/block:test"}' > "$CEL_REX_STATE/widget-orch.json"
  if rex_agent_list >/dev/null 2>&1; then
    echo 'incomplete live record was treated as a trustworthy inventory'; _rext_down; return 1
  fi
  rm -f "$CEL_REX_STATE/widget-orch.json"
  _rext_down
}

test_rex_claude_receipt_captures_only_an_explicit_native_resume_uuid() {
  _rext_setup
  cat >> "$CEL_MANIFEST" <<YAML
  claude:
    bin: "$RT/bin/runtime"
YAML
  local native=6b90062c-f7b9-4cf4-859c-6bba6e90df1d
  _rex_launch widget-orch claude "$RT/ws/repos/widget" widget 'env CEL_ROLE=orchestrator' --resume "$native" >/dev/null
  assert_eq "$(jq -r .agent_session.value "$CEL_REX_STATE/widget-orch.json")" "$native"
  rex_agent_stop rex/session:test/block:test
  _rex_launch widget-orch claude "$RT/ws/repos/widget" widget 'env CEL_ROLE=orchestrator' >/dev/null
  assert_eq "$(jq 'has("agent_session")' "$CEL_REX_STATE/widget-orch.json")" false
  _rext_down
}

# THE AGENT'S PATH IS THE PLANE'S, whoever launches it. The steward is a
# systemd user unit: its PATH is a login shell's plus mise and ~/.local/bin,
# never the owner's rc and its `cel shellenv`, so $CEL_ROOT/bin is not on it.
_rext_steward_path() { printf '%s' "$RT/bin:$HOME/.local/bin:/usr/bin:/bin"; }
_rext_path_of_runtime() { # -> the launched runtime's PATH, once it has started
  local i
  for ((i=0;i<50;i++)); do [ -f "$CEL_REX_STATE/path" ] && break; sleep 0.1; done
  cat "$CEL_REX_STATE/path" 2>/dev/null
}
_rext_assert_plane_path() { # <runtime PATH>
  assert_eq "${1%%:*}" "$CEL_ROOT/bin" || return 1
  assert_contains ":$1:" ":$HOME/.local/bin:" || return 1
  assert_contains ":$1:" ":$RT/bin:" || return 1
  local dup; dup="$(tr : '\n' <<<"$1" | sort | uniq -d)"
  [ -z "$dup" ] || { echo "duplicated on the agent's PATH: $dup"; return 1; }
}

test_rex_launch_from_a_caller_without_the_plane_on_path_puts_it_first() {
  _rext_setup
  local out rc=0
  out="$(cd "$RT/ws" && PATH="$(_rext_steward_path)" cmd_run orchestrator --repo widget --session-backend rex --fresh 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; _rext_down; return 1; }
  _rext_assert_plane_path "$(_rext_path_of_runtime)" || { _rext_down; return 1; }
  _rext_down
}

# A RESUME IS A LAUNCH: after a Rex restart or the managed upgrade the steward
# runs the receipt's recorded line (_rex_relaunch, the real `cel`), and the
# agent it brings back gets its PATH from the same builder as any `cel run`.
test_rex_resume_by_the_steward_puts_the_plane_on_path_first() {
  _rext_setup
  export CEL_REGISTRY="$RT/registry.yaml"
  printf 'workspaces:\n  alpha: {path: "%s/ws"}\n' "$RT" > "$CEL_REGISTRY"
  local out rc=0 f="$CEL_REX_STATE/widget-orch.json" old i
  out="$(cd "$RT/ws" && cmd_run orchestrator --repo widget --session-backend rex --fresh 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; unset CEL_REGISTRY; _rext_down; return 1; }
  _rext_path_of_runtime >/dev/null
  assert_eq "$(jq -r '.relaunch | length > 1' "$f")" true || { unset CEL_REGISTRY; _rext_down; return 1; }
  # The server went away and took the runtime with it.
  old="$(jq -r .pid "$f")"; kill "$old"
  for ((i=0;i<50;i++)); do _rex_live "$f" || break; sleep 0.1; done
  rm -f "$CEL_REX_STATE/path"
  out="$(cd / && PATH="$(_rext_steward_path)" _rex_relaunch "$f" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; unset CEL_REGISTRY; _rext_down; return 1; }
  _rext_assert_plane_path "$(_rext_path_of_runtime)" || { unset CEL_REGISTRY; _rext_down; return 1; }
  [ "$(jq -r .pid "$f")" != "$old" ] || { echo 'the resume did not relaunch the agent'; unset CEL_REGISTRY; _rext_down; return 1; }
  unset CEL_REGISTRY
  _rext_down
}

# ── each agent in a scope of its own ─────────────────────────────────────────
# 2026-11-21: one agent's test binary grew to 18 GB inside the Rex server's
# scope; the kernel killed it, and systemd then stopped that whole scope - the
# server and every agent. These stand in for systemd-run and systemctl, so the
# suite never reaches the live user manager.
# The systemctl stand-in answers show-environment with <rc>; a file
# `setprop.rc` in the state dir makes set-property exit with its contents, and
# `systemctl.hang` makes show-environment never answer.
_rext_scope_stubs() { # <rc of `systemctl --user show-environment`>
  cat > "$RT/bin/fake-systemd-run" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$CEL_REX_STATE/systemd-run.args"
printf '%s' "$$" > "$CEL_REX_STATE/systemd-run.pid"
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
SH
  cat > "$RT/bin/fake-systemctl" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "\$CEL_REX_STATE/systemctl.calls"
case "\$*" in
  *show-environment*) [ ! -e "\$CEL_REX_STATE/systemctl.hang" ] || exec sleep 30; exit ${1:-0} ;;
  *set-property*) [ ! -e "\$CEL_REX_STATE/setprop.rc" ] || exit "\$(cat "\$CEL_REX_STATE/setprop.rc")" ;;
esac
exit 0
SH
  chmod +x "$RT/bin/fake-systemd-run" "$RT/bin/fake-systemctl"
  printf 'MemTotal:       16777216 kB\nMemAvailable:    8388608 kB\nSwapTotal:       4194304 kB\n' > "$RT/meminfo"
  export CEL_AGENT_SYSTEMD_RUN="$RT/bin/fake-systemd-run" CEL_AGENT_SYSTEMCTL="$RT/bin/fake-systemctl" \
    CEL_MEMINFO="$RT/meminfo" CEL_CONFIG_FILE="$RT/config.yaml"
}
_rext_wait_runtime() {
  local i
  for ((i=0;i<50;i++)); do [ -f "$CEL_REX_STATE/observed" ] && return 0; sleep 0.1; done
  return 1
}

# Defaults from the box's RAM (16 GiB) and swap (4 GiB): one agent 40% of RAM
# and 25% of swap, every agent together 85% (hard) and 75% (throttle).
test_rex_launch_runs_the_agent_in_a_scope_of_its_own_under_cel_agents_slice() {
  _rext_setup
  _rext_scope_stubs 0
  local out rc=0 args
  out="$(cd "$RT/ws" && cmd_run orchestrator --repo widget --session-backend rex --fresh 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; _rext_down; return 1; }
  _rext_wait_runtime || { echo 'the scoped runtime never started'; _rext_down; return 1; }
  args="$(cat "$CEL_REX_STATE/systemd-run.args" 2>/dev/null)"
  assert_contains "$args" "$(printf -- '--user\n--scope\n')" || { _rext_down; return 1; }
  assert_contains "$args" "$(printf -- '--slice\ncel-agents.slice\n')" || { _rext_down; return 1; }
  assert_contains "$args" "$(printf -- '--unit\ncel-agent-widget-orch-')" || { _rext_down; return 1; }
  assert_contains "$args" "$(printf -- '-p\nOOMPolicy=continue\n')" || { _rext_down; return 1; }
  assert_contains "$args" "$(printf -- '-p\nMemoryMax=6553M\n')" || { _rext_down; return 1; }
  assert_contains "$args" "$(printf -- '-p\nMemorySwapMax=1024M\n--\n/bin/bash\n')" || { _rext_down; return 1; }
  # The whole box's agents share one parent with its own ceiling.
  assert_contains "$(cat "$CEL_REX_STATE/systemctl.calls")" \
    '--user set-property --runtime cel-agents.slice MemoryMax=13926M MemoryHigh=12288M' || { _rext_down; return 1; }
  # systemd-run --scope execs in place: the process it put in the scope IS
  # the runtime the receipt names, so PID identity is unchanged.
  assert_eq "$(cat "$CEL_REX_STATE/systemd-run.pid")" "$(jq -r .pid "$CEL_REX_STATE/widget-orch.json")" || { _rext_down; return 1; }
  _rex_live "$CEL_REX_STATE/widget-orch.json" || { echo 'receipt does not name the live runtime'; _rext_down; return 1; }
  _rext_down
}

test_rex_launch_without_a_user_manager_falls_back_to_the_server_cgroup_with_a_warning() {
  _rext_setup
  _rext_scope_stubs 1
  local out rc=0
  out="$(cd "$RT/ws" && cmd_run orchestrator --repo widget --session-backend rex --fresh 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; _rext_down; return 1; }
  _rext_wait_runtime || { echo 'the fallback launch never started its runtime'; _rext_down; return 1; }
  assert_contains "$out" "widget-orch runs inside the Rex server's own cgroup (no systemd user manager answers)" || { _rext_down; return 1; }
  [ ! -e "$CEL_REX_STATE/systemd-run.args" ] || { echo 'systemd-run ran without a user manager'; _rext_down; return 1; }
  _rex_live "$CEL_REX_STATE/widget-orch.json" || { echo 'fallback receipt does not name the live runtime'; _rext_down; return 1; }
  _rext_down
  # No systemd-run at all: the same fallback, saying so.
  _rext_setup
  _rext_scope_stubs 0
  export CEL_AGENT_SYSTEMD_RUN="$RT/bin/no-such-systemd-run"
  _rex_agent_scope widget-orch > "$RT/scope.out" 2>&1
  assert_eq "${#_REX_SCOPE[@]}" 0 || { _rext_down; return 1; }
  assert_contains "$(cat "$RT/scope.out")" '(systemd-run is not installed)' || { _rext_down; return 1; }
  _rext_down
}

test_rex_agent_scope_limits_and_oom_policy_follow_box_config() {
  _rext_setup
  _rext_scope_stubs 0
  cat > "$CEL_CONFIG_FILE" <<'YAML'
agent_memory:
  max_mb: 2048
  swap_max_mb: 0
  slice_max_mb: 8192
  slice_high_mb: 7168
  oom_policy: kill
YAML
  _rex_agent_scope widget-orch > "$RT/scope.out" 2>&1
  local words; words="$(printf '%s\n' "${_REX_SCOPE[@]}")"
  assert_contains "$words" "$(printf -- '-p\nOOMPolicy=kill\n-p\nMemoryMax=2048M\n-p\nMemorySwapMax=0M\n--')" || { _rext_down; return 1; }
  assert_contains "$(cat "$CEL_REX_STATE/systemctl.calls")" 'set-property --runtime cel-agents.slice MemoryMax=8192M MemoryHigh=7168M' || { _rext_down; return 1; }
  # A value that is not a whole number of MB, or an unknown policy, is the default.
  cat > "$CEL_CONFIG_FILE" <<'YAML'
agent_memory:
  max_mb: lots
  oom_policy: explode
YAML
  _rex_agent_scope widget-orch > "$RT/scope.out" 2>&1
  words="$(printf '%s\n' "${_REX_SCOPE[@]}")"
  assert_contains "$words" "$(printf -- '-p\nOOMPolicy=continue\n-p\nMemoryMax=6553M\n')" || { _rext_down; return 1; }
  # A throttle above the ceiling is no pair: both slice values are the defaults.
  cat > "$CEL_CONFIG_FILE" <<'YAML'
agent_memory:
  slice_max_mb: 8000
  slice_high_mb: 9000
YAML
  : > "$CEL_REX_STATE/systemctl.calls"
  _rex_agent_scope widget-orch > "$RT/scope.out" 2>&1
  assert_contains "$(cat "$CEL_REX_STATE/systemctl.calls")" 'set-property --runtime cel-agents.slice MemoryMax=13926M MemoryHigh=12288M' || { _rext_down; return 1; }
  _rext_down
}

# The box-wide ceiling is a second line of defence: a manager that refuses it
# (a bad value, no memory controller) still gives the agent its own scope.
test_rex_refused_slice_limits_warn_and_the_agent_still_gets_its_own_scope() {
  _rext_setup
  _rext_scope_stubs 0
  printf 1 > "$CEL_REX_STATE/setprop.rc"
  local out rc=0 args
  out="$(cd "$RT/ws" && cmd_run orchestrator --repo widget --session-backend rex --fresh 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; _rext_down; return 1; }
  _rext_wait_runtime || { echo 'the scoped runtime never started'; _rext_down; return 1; }
  assert_contains "$out" "refused cel-agents.slice's limits (MemoryMax=13926M MemoryHigh=12288M) - widget-orch still gets a scope of its own" || { _rext_down; return 1; }
  args="$(cat "$CEL_REX_STATE/systemd-run.args" 2>/dev/null)"
  assert_contains "$args" "$(printf -- '--scope\n')" || { _rext_down; return 1; }
  assert_contains "$args" "$(printf -- '-p\nOOMPolicy=continue\n-p\nMemoryMax=6553M\n')" || { _rext_down; return 1; }
  _rex_live "$CEL_REX_STATE/widget-orch.json" || { echo 'receipt does not name the live runtime'; _rext_down; return 1; }
  _rext_down
}

# A wedged user manager cannot hang a launch: the call is bounded, and no
# answer is no manager.
test_rex_hung_user_manager_times_out_and_the_launch_still_goes_through() {
  _rext_setup
  _rext_scope_stubs 0
  : > "$CEL_REX_STATE/systemctl.hang"
  local out rc=0 started=$SECONDS
  out="$(cd "$RT/ws" && CEL_AGENT_MANAGER_TIMEOUT=1 cmd_run orchestrator --repo widget --session-backend rex --fresh 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; _rext_down; return 1; }
  [ $((SECONDS - started)) -lt 20 ] || { echo "the launch waited $((SECONDS - started))s on a hung manager"; _rext_down; return 1; }
  _rext_wait_runtime || { echo 'the launch never started its runtime'; _rext_down; return 1; }
  assert_contains "$out" "widget-orch runs inside the Rex server's own cgroup (no systemd user manager answers)" || { _rext_down; return 1; }
  [ ! -e "$CEL_REX_STATE/systemd-run.args" ] || { echo 'systemd-run ran against a hung manager'; _rext_down; return 1; }
  _rext_down
}

# A RESUME IS A LAUNCH: the steward's relaunch after a server restart puts the
# agent in a scope of its own too.
test_rex_resume_by_the_steward_runs_the_agent_in_its_own_scope() {
  _rext_setup
  _rext_scope_stubs 0
  export CEL_REGISTRY="$RT/registry.yaml"
  printf 'workspaces:\n  alpha: {path: "%s/ws"}\n' "$RT" > "$CEL_REGISTRY"
  local out rc=0 f="$CEL_REX_STATE/widget-orch.json" old i
  out="$(cd "$RT/ws" && cmd_run orchestrator --repo widget --session-backend rex --fresh 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; unset CEL_REGISTRY; _rext_down; return 1; }
  _rext_wait_runtime || { unset CEL_REGISTRY; _rext_down; return 1; }
  old="$(jq -r .pid "$f")"; kill "$old"
  for ((i=0;i<50;i++)); do _rex_live "$f" || break; sleep 0.1; done
  rm -f "$CEL_REX_STATE/systemd-run.args" "$CEL_REX_STATE/systemd-run.pid" "$CEL_REX_STATE/observed"
  out="$(cd / && PATH="$(_rext_steward_path)" _rex_relaunch "$f" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; unset CEL_REGISTRY; _rext_down; return 1; }
  _rext_wait_runtime || { echo 'the resume never started its runtime'; unset CEL_REGISTRY; _rext_down; return 1; }
  [ "$(jq -r .pid "$f")" != "$old" ] || { echo 'the resume did not relaunch the agent'; unset CEL_REGISTRY; _rext_down; return 1; }
  assert_contains "$(cat "$CEL_REX_STATE/systemd-run.args" 2>/dev/null)" "$(printf -- '--slice\ncel-agents.slice\n')" || { unset CEL_REGISTRY; _rext_down; return 1; }
  assert_eq "$(cat "$CEL_REX_STATE/systemd-run.pid")" "$(jq -r .pid "$f")" || { unset CEL_REGISTRY; _rext_down; return 1; }
  unset CEL_REGISTRY
  _rext_down
}

# The server's own scope keeps running when the kernel kills a process in it:
# a scope's default OOMPolicy is `stop`, which ended every agent on 2026-11-21.
test_rex_server_starts_in_its_own_scope_with_oom_policy_continue() {
  local words
  words="$(_rex_server_start_argv running)"
  assert_contains "$words" "$(printf 'systemd-run\n--user\n--scope\n')" || return 1
  assert_contains "$words" "$(printf -- '--unit\ncel-rex-server-')" || return 1
  assert_contains "$words" "$(printf -- '-p\nOOMPolicy=continue\n--\n')" || return 1
  assert_contains "$words" "$(printf 'server\nstart\n--tailscale')" || return 1
  words="$(_rex_server_start_argv off)"
  case "$words" in *--tailscale*) echo 'a server that did not serve the tailnet came back serving it'; return 1 ;; esac
}
