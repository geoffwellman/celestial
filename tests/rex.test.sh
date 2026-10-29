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
  unset CEL_REX_STATE CEL_REX_BIN CEL_MANIFEST CEL_MANIFEST_CACHE CEL_REX_RECORD
  rm -rf "$RT"
}

test_rex_run_preserves_role_inbox_args_and_working_directory() {
  _rext_setup
  local out rc=0
  out="$(cd "$RT/ws" && cmd_run orchestrator --repo widget --session-backend rex --fresh 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "$out"; _rext_down; return 1; }
  local i
  for ((i=0;i<50;i++)); do [ -f "$CEL_REX_STATE/observed" ] && break; sleep 0.1; done
  assert_eq "$(cat "$CEL_REX_STATE/observed")" "$(printf 'orchestrator\nwidget-orch\nrex\n%s' "$RT/ws/repos/widget")"
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
  local pid; pid="$(jq -r .pid "$CEL_REX_RECORD")"
  rex_session_note "$pid" idle /tmp/native-session.jsonl
  assert_eq "$(rex_agent_list | jq -r '.result.agents[0].agent_status')" idle
  assert_eq "$(rex_agent_list | jq -r '.result.agents[0].agent_session.value')" /tmp/native-session.jsonl
  if rex_session_note 1 working; then echo 'other process updated the record'; _rext_down; return 1; fi
  rex_agent_stop rex/session:test/block:test
  assert_eq "$(rex_agent_list | jq '.result.agents|length')" 0
  _rext_down
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

test_rex_worker_creates_its_own_new_branch_without_switching_the_shared_checkout() {
  _rext_setup
  local repo="$RT/ws/repos/widget"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  local out
  if (cd "$RT/ws" && CEL_REX_BIN="$RT/missing-rex" cmd_run worker --repo widget --branch WG-7-example --session-backend rex >/dev/null 2>&1); then
    echo 'worker launched without Rex'; _rext_down; return 1
  fi
  if git -C "$repo" show-ref --verify --quiet refs/heads/WG-7-example; then
    echo 'missing backend left a worker branch behind'; _rext_down; return 1
  fi
  if ! out="$(cd "$RT/ws" && cmd_run worker --repo widget --branch WG-7-example --session-backend rex 2>&1)"; then
    echo "$out"; _rext_down; return 1
  fi
  local wt; wt="$(jq -r .cwd "$CEL_REX_STATE/widget-wg-7-example.json")"
  assert_eq "$(git -C "$wt" branch --show-current)" WG-7-example
  assert_eq "$(git -C "$repo" branch --show-current)" main
  assert_eq "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$repo" rev-parse main)"
  rex_agent_stop "$(jq -r .pane_id "$CEL_REX_STATE/widget-wg-7-example.json")"
  printf 'keep this edit\n' > "$wt/local-work.txt"
  if ! out="$(cd "$RT/ws" && cmd_run worker --repo widget --branch WG-7-example --session-backend rex 2>&1)"; then
    echo "$out"; _rext_down; return 1
  fi
  assert_eq "$(cat "$wt/local-work.txt")" 'keep this edit'
  _rext_down
}
