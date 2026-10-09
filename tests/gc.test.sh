# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/registry.sh"
source "$CEL_ROOT/lib/gc.sh"

# _gc_landed_clean is the gate on deleting no-PR worktrees: it must demand
# BOTH that HEAD is already in origin's default and that nothing is
# uncommitted - either alone is potential work loss.
_gc_fixture() { # -> T with repo + origin/main at HEAD
  T="$(mktemp -d)"
  git -C "$T" init -q
  git -C "$T" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T" update-ref refs/remotes/origin/main HEAD
  git -C "$T" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
test_landed_clean_accepts_ancestor_with_clean_tree() {
  _gc_fixture
  _gc_landed_clean "$T"
  rm -rf "$T"
}
test_landed_clean_rejects_unique_commits() {
  _gc_fixture
  git -C "$T" -c user.email=t@t -c user.name=t commit -q --allow-empty -m extra
  assert_fails _gc_landed_clean "$T"
  rm -rf "$T"
}
test_landed_clean_rejects_dirty_tree() {
  _gc_fixture
  printf 'x' > "$T/uncommitted.txt"
  assert_fails _gc_landed_clean "$T"
  rm -rf "$T"
}

# Real linked worktrees, with only the external discovery/destructive sinks
# stubbed. A claimed deletion is observed even though no fixture is removed.
_gc_managed_fixture() {
  T="$(mktemp -d)"
  export HOME="$T/home" CEL_REGISTRY="$T/registry.yaml"
  GC_WS="$T/workspace"; GC_WT="$HOME/.herdr/worktrees/widget/task"
  mkdir -p "$GC_WS/.cel" "$T/repo" "$(dirname "$GC_WT")"
  git -C "$T/repo" init -q
  git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T/repo" update-ref refs/remotes/origin/main HEAD
  git -C "$T/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$T/repo" worktree add -q -b task "$GC_WT"
  registry_add demo "$GC_WS" ""
  jq -n --arg w "$GC_WT" '[{id:"task",worktree:$w,state:"collected"}]' > "$GC_WS/.cel/delegations.json"
  GC_PR=MERGED; GC_STATUS=idle; GC_DISCOVERY_FAIL=""; GC_AGENTS='{"result":{"agents":[]}}'
  GC_SINK="$T/sink"; : > "$GC_SINK"
  herdr() {
    case "$1 $2" in
      "workspace list") [ "$GC_DISCOVERY_FAIL" != workspace ] || return 1
        printf '{"result":{"workspaces":[{"workspace_id":"w1"}]}}';;
      "pane list") [ "$GC_DISCOVERY_FAIL" != pane ] || return 1
        jq -n --arg w "$GC_WT" --arg s "$GC_STATUS" '{result:{panes:[{pane_id:"w1:p1",cwd:$w,agent_status:$s}]}}';;
      "pane process-info")
        jq -n --argjson pid "${GC_PID:-0}" --argjson shell "$$" \
          '{result:{process_info:{pane_id:"w1:p1",shell_pid:$shell,foreground_process_group_id:$pid,foreground_processes:[{pid:$pid}]}}}';;
      "agent list") [ "$GC_DISCOVERY_FAIL" != agent ] || return 1
        printf '%s' "$GC_AGENTS";;
      "worktree remove") printf 'herdr remove\n' >> "$GC_SINK";;
      *) return 1;;
    esac
  }
  gh() {
    [ "$GC_PR" != UNKNOWN ] || return 1
    case "$1 $2" in
      "pr list")
        if [ "$GC_PR" = NONE ]; then printf '[]'; else
          jq -n --arg s "$GC_PR" '[{state:$s,updatedAt:"2026-01-01T00:00:00Z"}]'
        fi;;
      "pr view")
        if [ "$3" = --json ] && [ "$4" = state ]; then
          [ "$GC_PR" != NONE ] || return 1
          printf '%s' "$GC_PR"
        else
          jq -n --arg s "$GC_PR" '{state:$s,headRefOid:"not-the-local-head"}'
        fi;;
      *) return 1;;
    esac
  }
  git() {
    case " $* " in *" worktree remove "*) printf 'git remove\n' >> "$GC_SINK"; return 0;; esac
    command git "$@"
  }
}

test_gc_removes_only_proven_settled_clean_worktrees() {
  _gc_managed_fixture
  cmd_gc >/dev/null
  assert_eq "$(cat "$GC_SINK")" "herdr remove"
  rm -rf "$T"
}

test_gc_vetoes_running_delegations_for_every_pr_state_and_orphans() {
  _gc_managed_fixture
  jq '.[0].state = "running"' "$GC_WS/.cel/delegations.json" > "$T/next"
  mv "$T/next" "$GC_WS/.cel/delegations.json"
  for GC_PR in MERGED CLOSED NONE; do cmd_gc >/dev/null; done
  herdr() {
    case "$1 $2" in
      "workspace list") printf '{"result":{"workspaces":[]}}';;
      "agent list") printf '{"result":{"agents":[]}}';;
      "worktree remove") printf 'herdr remove\n' >> "$GC_SINK";;
      *) return 1;;
    esac
  }
  _gc_has_process() { return 1; }
  for GC_PR in MERGED CLOSED NONE; do cmd_gc >/dev/null; done
  assert_eq "$(cat "$GC_SINK")" ""
  rm -rf "$T"
}

test_gc_vetoes_unknown_discovery_instead_of_discovering_orphans() {
  _gc_managed_fixture
  for GC_DISCOVERY_FAIL in workspace pane agent; do cmd_gc >/dev/null; done
  assert_eq "$(cat "$GC_SINK")" ""
  rm -rf "$T"
}

test_gc_vetoes_malformed_or_unlisted_ledger_state() {
  _gc_managed_fixture
  for json in '{' '{}' '[]' '[{"worktree":null,"state":"running"}]'; do
    printf '%s' "$json" > "$GC_WS/.cel/delegations.json"
    cmd_gc >/dev/null
  done
  assert_eq "$(cat "$GC_SINK")" ""
  rm -rf "$T"
}

test_gc_merged_and_closed_prs_do_not_erase_dirty_or_new_commits() {
  _gc_managed_fixture
  printf 'new work\n' > "$GC_WT/work.txt"
  for GC_PR in MERGED CLOSED; do cmd_gc >/dev/null; done
  git -C "$GC_WT" add work.txt
  git -C "$GC_WT" -c user.email=t@t -c user.name=t commit -qm work
  for GC_PR in MERGED CLOSED; do cmd_gc >/dev/null; done
  assert_eq "$(cat "$GC_SINK")" ""
  rm -rf "$T"
}

test_gc_keeps_work_during_delegate_admission_lock() {
  _gc_managed_fixture
  local fd; exec {fd}>"$GC_WS/.cel/delegations.lock"; flock "$fd"
  cmd_gc >/dev/null
  assert_eq "$(cat "$GC_SINK")" ""
  exec {fd}>&-
  rm -rf "$T"
}

_gc_idle_fixture() {
  _gc_managed_fixture
  # Control only the uptime read. A fresh CI host may not yet have two
  # hours of uptime to backdate into; process ownership stays real /proc.
  GC_UPTIME=10000
  read() {
    if [[ "$(readlink /proc/self/fd/0)" == /proc/uptime ]]; then
      builtin read "$@" <<< "$GC_UPTIME 0"
    else
      builtin read "$@"
    fi
  }
  CEL_MANIFEST="$T/agents.yaml"
  printf 'agents:\n  bash:\n    role_injection: {strategy: append_flag_file, flag: --role-file}\n' > "$CEL_MANIFEST"
  printf 'worker role\n' > "$GC_WS/.cel/role-worker.md"
  # The test owns this process. It blocks on a FIFO without a busy loop or
  # descendants; production identity reads its real /proc argv/env/stat.
  mkfifo "$T/input"
  exec {GC_INPUT}<>"$T/input"
  printf 'read -r line\n' > "$T/agent.sh"
  HERDR_PANE_ID=w1:p1 bash "$T/agent.sh" --role-file "$GC_WS/.cel/role-worker.md" < "$T/input" &
  GC_PID=$!
  # -9, and no bare `wait`: a fixture that ignores TERM (the pi case this
  # ticket is about) would otherwise hang the whole suite - it hung it for
  # three hours once.
  trap 'builtin kill -9 "$GC_PID" 2>/dev/null || true; rm -rf "$T"' EXIT
  GC_AGENTS="$(jq -n --arg d "$PWD" '{result:{agents:[{pane_id:"w1:p1",name:"widget-task",agent:"bash",cwd:$d,agent_status:"idle",terminal_id:"term-1",state_change_seq:4,agent_session:{value:"session-1"}}]}}')"
  pgrep() { printf '%s\n' "$GC_PID"; }
  kill() { printf '%s\n' "$*" >> "$GC_SINK"; }
  reaped=0
}

_gc_age_observation() {
  GC_UPTIME=$((GC_UPTIME + 7200))
}

test_gc_reaps_only_after_observed_idle_duration_for_exact_owned_process() {
  _gc_idle_fixture
  # Wait for the child to exec bash without using elapsed time as evidence.
  local i identity=""
  for ((i=0;i<100;i++)); do
    identity="$(_gc_process_identity "$GC_PID" "$GC_AGENTS" demo)" && break
    sleep 0.01
  done
  [ -n "$identity" ] || { echo "test process did not start"; return 1; }
  _gc_reap 1 0 "$GC_AGENTS" demo
  assert_eq "$(cat "$GC_SINK")" ""
  _gc_age_observation
  _gc_reap 1 0 "$GC_AGENTS" demo
  assert_eq "$(cat "$GC_SINK")" "-TERM $GC_PID"
}

test_gc_old_working_process_never_loses_its_veto() {
  _gc_idle_fixture
  local i
  for ((i=0;i<100;i++)); do _gc_process_identity "$GC_PID" "$GC_AGENTS" demo >/dev/null && break; sleep 0.01; done
  _gc_reap 1 0 "$GC_AGENTS" demo
  _gc_age_observation
  GC_AGENTS="$(printf '%s' "$GC_AGENTS" | jq '.result.agents[0].agent_status = "working"')"
  _gc_reap 1 0 "$GC_AGENTS" demo
  assert_eq "$(cat "$GC_SINK")" ""
  assert_eq "$(jq '.idle | length' "$HOME/.local/state/cel/gc-idle.json")" 0
}

test_gc_resume_sequence_and_unknown_identity_reset_idle_observation() {
  _gc_idle_fixture
  local i
  for ((i=0;i<100;i++)); do _gc_process_identity "$GC_PID" "$GC_AGENTS" demo >/dev/null && break; sleep 0.01; done
  _gc_reap 1 0 "$GC_AGENTS" demo
  _gc_age_observation
  GC_AGENTS="$(printf '%s' "$GC_AGENTS" | jq '.result.agents[0].state_change_seq += 2')"
  _gc_reap 1 0 "$GC_AGENTS" demo
  assert_eq "$(cat "$GC_SINK")" ""
  GC_AGENTS="$(printf '%s' "$GC_AGENTS" | jq '.result.agents[0].pane_id = "different-pane"')"
  _gc_reap 1 0 "$GC_AGENTS" demo
  assert_eq "$(jq '.idle | length' "$HOME/.local/state/cel/gc-idle.json")" 0
}

test_gc_never_reaps_day_old_working_or_hand_started_tmp_processes() {
  _gc_managed_fixture
  GC_PR=OPEN
  GC_AGENTS='{"result":{"agents":[{"pane_id":"w9:p1","cwd":"/tmp/manual-agent","agent_status":"working"}]}}'
  pgrep() { printf '987654321\n'; }
  readlink() {
    case "$*" in */proc/987654321/cwd*) printf '/tmp/manual-agent';; *) command readlink "$@";; esac
  }
  ps() { printf '172800\n'; }
  kill() { printf '%s\n' "$*" >> "$GC_SINK"; }
  cmd_gc --reap 1 >/dev/null
  assert_eq "$(cat "$GC_SINK")" ""
  rm -rf "$T"
}

test_gc_unknown_ownership_does_not_reuse_an_old_idle_clock() {
  _gc_idle_fixture
  local i
  for ((i=0;i<100;i++)); do _gc_process_identity "$GC_PID" "$GC_AGENTS" demo >/dev/null && break; sleep 0.01; done
  _gc_reap 1 0 "$GC_AGENTS" demo
  _gc_age_observation
  rm "$GC_WS/.cel/role-worker.md"
  _gc_reap 1 0 "$GC_AGENTS" demo
  assert_eq "$(cat "$GC_SINK")" ""
  assert_eq "$(jq '.idle | length' "$HOME/.local/state/cel/gc-idle.json")" 0
}

test_gc_squash_merge_accepts_only_the_exact_clean_merged_head() {
  _gc_managed_fixture
  git -C "$GC_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m feature
  local merged_head; merged_head="$(git -C "$GC_WT" rev-parse HEAD)"
  gh() {
    case "$1 $2" in
      "pr list") printf '[{"state":"MERGED","updatedAt":"2026-01-01T00:00:00Z"}]';;
      "pr view") jq -n --arg h "$merged_head" '{state:"MERGED",headRefOid:$h}';;
      *) return 1;;
    esac
  }
  cmd_gc >/dev/null
  assert_eq "$(cat "$GC_SINK")" "herdr remove"
  : > "$GC_SINK"
  git -C "$GC_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m later
  cmd_gc >/dev/null
  assert_eq "$(cat "$GC_SINK")" ""
  rm -rf "$T"
}

test_gc_names_preserved_unlanded_work() {
  _gc_managed_fixture
  GC_PR=NONE
  GIT_AUTHOR_DATE='2000-01-01T00:00:00+0000' GIT_COMMITTER_DATE='2000-01-01T00:00:00+0000' \
    git -C "$GC_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m unlanded
  local out; out="$(cmd_gc)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" "$GC_WT"
  rm -rf "$T"
}

test_gc_running_delegation_veto_follows_symlinked_parent_of_process_cwd() {
  local checkout; checkout="$(mktemp -d)"
  mkdir "$checkout/nested"
  cd "$checkout/nested"
  _gc_idle_fixture
  local i identity=""
  for ((i=0;i<100;i++)); do
    identity="$(_gc_process_identity "$GC_PID" "$GC_AGENTS" demo)" && break
    sleep 0.01
  done
  [ -n "$identity" ] || { echo "test process did not start"; return 1; }
  _gc_reap 1 0 "$GC_AGENTS" demo
  _gc_age_observation
  ln -s "$checkout" "$T/checkout-alias"
  jq -n --arg w "$T/checkout-alias" '[{worktree:$w,state:"running"}]' > "$GC_WS/.cel/delegations.json"
  _gc_reap 1 0 "$GC_AGENTS" demo
  assert_eq "$(cat "$GC_SINK")" ""
  assert_eq "$(jq '.idle | length' "$HOME/.local/state/cel/gc-idle.json")" 0
}

# --- the launch environment, not argv -------------------------------------
# pi rewrites its own argv (process.title): /proc/<pid>/cmdline of a live pi
# worker is `pi` and padding, so the role path the old identity gate looked
# for is never there and every pi worker on the box read as unidentified -
# 0 reaped, 0 removed, for weeks. The launcher's own variables survive that
# rewrite because /proc/<pid>/environ is fixed at exec.
_gc_env_fixture() {
  _gc_managed_fixture
  GC_UPTIME=10000
  read() {
    if [[ "$(readlink /proc/self/fd/0)" == /proc/uptime ]]; then
      builtin read "$@" <<< "$GC_UPTIME 0"
    else
      builtin read "$@"
    fi
  }
  CEL_MANIFEST="$T/agents.yaml"
  { printf 'agents:\n'
    printf '  bash:\n    role_injection: {strategy: append_flag_file, flag: --role-file}\n'
    printf '  pi:\n    role_injection: {strategy: append_flag_file, flag: --append-system-prompt}\n    signal: int\n'
  } > "$CEL_MANIFEST"
  printf 'worker role\n' > "$GC_WS/.cel/role-worker.md"
  # A real process whose comm is `pi` and whose argv holds no role path: a
  # copy of bash under that name reproduces the rewrite without pi installed.
  mkdir -p "$T/bin"
  cp "$(command -v bash)" "$T/bin/pi"
  mkfifo "$T/input"
  exec {GC_INPUT}<>"$T/input"
  printf 'read -r line\n' > "$T/agent.sh"
  GC_AGENTS="$(jq -n --arg d "$PWD" '{result:{agents:[{pane_id:"w1:p1",name:"widget-task",agent:"pi",cwd:$d,agent_status:"idle",terminal_id:"term-1",state_change_seq:4,agent_session:{value:"session-1"}}]}}')"
  pgrep() { printf '%s\n' "$GC_PID"; }
  reaped=0
}

_gc_spawn_pi() { # <marked 0|1>
  # --default-signal=INT: the runner starts each test asynchronously, so this
  # shell has SIGINT IGNORED and every child would inherit that. The fixture
  # would then survive the INT the reap depends on for a reason that has
  # nothing to do with the code under test.
  if [ "$1" -eq 1 ]; then
    env --default-signal=INT HERDR_PANE_ID=w1:p1 CEL_ROLE=worker \
        CEL_ROLE_FILE="$GC_WS/.cel/role-worker.md" CEL_WORKSPACE="$GC_WS" \
        "$T/bin/pi" "$T/agent.sh" < "$T/input" &
  else
    env --default-signal=INT HERDR_PANE_ID=w1:p1 "$T/bin/pi" "$T/agent.sh" < "$T/input" &
  fi
  GC_PID=$!
  trap 'builtin kill -9 "$GC_PID" 2>/dev/null || true; rm -rf "$T"' EXIT
  local i
  for ((i=0;i<200;i++)); do
    [ "$(cat "/proc/$GC_PID/comm" 2>/dev/null)" = pi ] && return 0
    sleep 0.01
  done
  echo "test process did not start"; return 1
}

test_gc_identity_accepts_the_launch_environment_when_argv_is_rewritten() {
  _gc_env_fixture
  _gc_spawn_pi 1 || return 1
  local identity; identity="$(_gc_process_identity "$GC_PID" "$GC_AGENTS" demo)" \
    || { echo "an environment-marked pi worker was not identified"; return 1; }
  assert_contains "$identity" "$GC_WS/.cel/role-worker.md"
}

test_gc_identity_rejects_a_runtime_carrying_neither_marker() {
  _gc_env_fixture
  _gc_spawn_pi 0 || return 1
  assert_fails _gc_process_identity "$GC_PID" "$GC_AGENTS" demo
}

# The environment is evidence only when it MATCHES: a role file outside the
# registered workspace, a root/orchestrator role, or a workspace the registry
# does not know proves nothing, and the argv fallback finds nothing either.
_gc_spawn_pi_env() { # <role-file> <workspace>
  env --default-signal=INT HERDR_PANE_ID=w1:p1 CEL_ROLE=worker \
      CEL_ROLE_FILE="$1" CEL_WORKSPACE="$2" \
      "$T/bin/pi" "$T/agent.sh" < "$T/input" &
  GC_PID=$!
  trap 'builtin kill -9 "$GC_PID" 2>/dev/null || true; rm -rf "$T"' EXIT
  local i
  for ((i=0;i<200;i++)); do
    [ "$(cat "/proc/$GC_PID/comm" 2>/dev/null)" = pi ] && return 0
    sleep 0.01
  done
  echo "test process did not start"; return 1
}

test_gc_identity_rejects_a_mismatched_launch_environment() {
  _gc_env_fixture
  mkdir -p "$T/elsewhere/.cel"
  printf 'worker role\n' > "$T/elsewhere/.cel/role-worker.md"
  printf 'root role\n' > "$GC_WS/.cel/role-root.md"
  _gc_spawn_pi_env "$T/elsewhere/.cel/role-worker.md" "$GC_WS" || return 1
  assert_fails _gc_process_identity "$GC_PID" "$GC_AGENTS" demo || return 1
  builtin kill -9 "$GC_PID" 2>/dev/null || true
  _gc_spawn_pi_env "$GC_WS/.cel/role-worker.md" "$T/elsewhere" || return 1
  assert_fails _gc_process_identity "$GC_PID" "$GC_AGENTS" demo || return 1
  builtin kill -9 "$GC_PID" 2>/dev/null || true
  _gc_spawn_pi_env "$GC_WS/.cel/role-root.md" "$GC_WS" || return 1
  assert_fails _gc_process_identity "$GC_PID" "$GC_AGENTS" demo
}

# Older omp and claude panes were launched before the variables existed and
# must keep working until they restart, so the argv scan stays as a fallback.
test_gc_identity_still_accepts_the_legacy_argv_stamp() {
  _gc_idle_fixture
  local i identity=""
  for ((i=0;i<200;i++)); do
    identity="$(_gc_process_identity "$GC_PID" "$GC_AGENTS" demo)" && break
    sleep 0.01
  done
  assert_contains "$identity" "$GC_WS/.cel/role-worker.md"
}

# A live agent whose herdr session id is null (observed on two omp panes)
# could never pass the gate. The environment proof stands in for it; nothing
# stands in for it when there is no proof.
test_gc_null_agent_session_passes_only_with_the_launch_environment() {
  _gc_env_fixture
  GC_AGENTS="$(printf '%s' "$GC_AGENTS" | jq '.result.agents[0].agent_session.value = null')"
  _gc_spawn_pi 1 || return 1
  _gc_process_identity "$GC_PID" "$GC_AGENTS" demo >/dev/null \
    || { echo "a null session refused an environment-marked worker"; return 1; }
  builtin kill -9 "$GC_PID" 2>/dev/null || true
  _gc_spawn_pi 0 || return 1
  assert_fails _gc_process_identity "$GC_PID" "$GC_AGENTS" demo
}

# pi ignores SIGTERM, so an identified idle pi would have been "reaped" and
# still be running. INT first, then TERM after the grace, and never -9: a
# worker holding a half-written commit is worth more than a tidy process list.
test_gc_reaps_a_pi_that_ignores_term_but_exits_on_int() {
  _gc_env_fixture
  CEL_GC_GRACE=1
  printf 'trap "" TERM\nread -r line\n' > "$T/agent.sh"
  _gc_spawn_pi 1 || return 1
  local i
  for ((i=0;i<200;i++)); do _gc_process_identity "$GC_PID" "$GC_AGENTS" demo >/dev/null && break; sleep 0.01; done
  _gc_reap 1 0 "$GC_AGENTS" demo
  _gc_age_observation
  # NOT in a command substitution: _gc_reap's counters are what is asserted,
  # and a subshell would throw them away.
  _gc_reap 1 0 "$GC_AGENTS" demo > "$T/reap.out"
  assert_contains "$(cat "$T/reap.out")" "reaped idle plane pid $GC_PID"
  assert_eq "$reaped" 1
}

test_gc_reports_a_stubborn_worker_rather_than_killing_it() {
  _gc_env_fixture
  CEL_GC_GRACE=1
  printf 'trap "" TERM INT\nwhile :; do read -r line; done\n' > "$T/agent.sh"
  _gc_spawn_pi 1 || return 1
  local i
  for ((i=0;i<200;i++)); do _gc_process_identity "$GC_PID" "$GC_AGENTS" demo >/dev/null && break; sleep 0.01; done
  _gc_reap 1 0 "$GC_AGENTS" demo
  _gc_age_observation
  _gc_reap 1 0 "$GC_AGENTS" demo > "$T/reap.out" 2>&1
  assert_contains "$(cat "$T/reap.out")" "did not exit"
  assert_eq "$reaped" 0
  assert_eq "${GC_KEPT[stubborn]:-0}" 1
  [ -d "/proc/$GC_PID" ] || { echo "GC killed a worker it could not stop politely"; return 1; }
}

# One number for every kept row made a completely blind GC print the same
# line as an idle one, which is why the argv breakage ran for weeks.
test_gc_kept_line_renders_reasons_in_order_and_omits_zeros() {
  _gc_keep_reset
  GC_KEPT=([live]=12 [unlanded]=9 [unidentified]=12)
  assert_eq "$(_gc_kept_line summary)" " (12 live, 9 unlanded, 12 unidentified)"
  _gc_keep_reset
  assert_eq "$(_gc_kept_line summary)" ""
  _gc_keep_reset
  GC_KEPT=([unidentified]=3)
  assert_eq "$(_gc_kept_line doctor)" "gc: 3 worktrees unidentified - cel gc --dry-run to see them"
  _gc_keep_reset
  assert_eq "$(_gc_kept_line doctor)" ""
}

test_gc_names_the_directories_it_could_not_identify() {
  _gc_managed_fixture
  GC_AGENTS="$(jq -n --arg d "$GC_WT" '{result:{agents:[{pane_id:"w1:p1",cwd:$d,agent_status:"idle"}]}}')"
  GC_PID=0
  local out; out="$(cmd_gc)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" "1 unidentified"
  assert_contains "$out" "$GC_WT"
  rm -rf "$T"
}

# ------------------------------------------------------------- cel gc --box
# The box is a resource the factory spends. `cel gc` is unchanged by default;
# --box runs the box sweepers AFTER the worktree pass, because a freed
# worktree may be the last reference to a cache entry.

_gc_box_fixture() {
  _gc_managed_fixture
  export CEL_BOX_RM_LOG="$T/box-removed"
  : > "$CEL_BOX_RM_LOG"
  mkdir -p "$HOME/.bun/install/cache" "$HOME/.cache/cel" "$HOME/restore"
  printf 'aged\n' > "$HOME/.bun/install/cache/old-package"
  touch -d '60 days ago' "$HOME/.bun/install/cache/old-package"
  printf 'irreplaceable\n' > "$HOME/restore/profile-dump.tar"
  touch -d '400 days ago' "$HOME/restore/profile-dump.tar"
  # NEVER the real docker: this fixture drives the box sweepers, and a
  # resolvable docker here would prune the box the suite is running on.
  export CEL_BOX_DOCKER=cel-no-such-docker
}

test_gc_without_box_sweeps_no_box_litter_at_all() {
  _gc_box_fixture
  local out; out="$(cmd_gc)"
  assert_eq "$(cat "$GC_SINK")" "herdr remove"
  assert_eq "$(cat "$CEL_BOX_RM_LOG")" ""
  case "$out" in *box:*) printf 'plain cel gc mentioned the box sweep\n' >&2; return 1;; esac
  rm -rf "$T"
}

test_gc_box_sweeps_after_the_worktree_pass_and_counts_every_class() {
  _gc_box_fixture
  local out; out="$(cmd_gc --box)"
  assert_eq "$(cat "$GC_SINK")" "herdr remove"
  assert_contains "$out" "worktrees removed"
  assert_contains "$out" "box:"
  assert_contains "$out" caches
  assert_contains "$out" ours
  assert_contains "$(cat "$CEL_BOX_RM_LOG")" "$HOME/.bun/install/cache/old-package"
  rm -rf "$T"
}

# Docker absent is a normal box: the class is reported as skipped, never as
# zero bytes freed, and never as a failure.
test_gc_box_reports_docker_skipped_when_docker_is_not_on_path() {
  _gc_box_fixture
  local out; out="$(cmd_gc --box)"
  assert_contains "$out" "docker"
  assert_contains "$out" "skipped"
  rm -rf "$T"
}

# --dry-run covers the new work exactly as it covers the old.
test_gc_box_dry_run_reports_bytes_and_removes_nothing() {
  _gc_box_fixture
  local out; out="$(cmd_gc --box --dry-run)"
  assert_contains "$out" "box:"
  assert_eq "$(cat "$CEL_BOX_RM_LOG")" ""
  assert_eq "$(cat "$GC_SINK")" ""
  [ -e "$HOME/.bun/install/cache/old-package" ] || { printf 'dry run removed a cache entry\n' >&2; return 1; }
  rm -rf "$T"
}

# Class-three paths are NEVER swept by any flag, including --box with --reap.
test_gc_box_never_touches_a_class_three_path_even_with_reap() {
  _gc_box_fixture
  cmd_gc --box --reap 12 >/dev/null 2>&1 || true
  case "$(cat "$CEL_BOX_RM_LOG")" in
    *"$HOME/restore"*) printf 'gc --box --reap took a class-three path\n' >&2; return 1;;
  esac
  [ -e "$HOME/restore/profile-dump.tar" ] || { printf 'the dump is gone\n' >&2; return 1; }
  rm -rf "$T"
}

test_gc_rejects_unknown_arguments_and_names_box() {
  assert_fails cmd_gc --sweep-everything
  local out; out="$(cmd_gc --nope 2>&1 || true)"
  assert_contains "$out" "--box"
}

# ------------------------------------------------------- the reviewer pass
# A reviewer exists to review one pull request, and when that pull request
# closes the reviewer is done. Not idle-for-a-while, not probably-finished -
# done, by a fact about the world. Cleanup never looked at them because a
# reviewer runs in the orchestrator's own checkout, not under ~/.herdr/worktrees.
_gc_reviewer_fixture() {
  T="$(mktemp -d)"
  export HOME="$T/home" CEL_REVIEWERS_STATE="$T/reviewers.json"
  mkdir -p "$HOME"
  GC_SINK="$T/sink"; : > "$GC_SINK"
  GC_PR_STATE=MERGED
  GC_REVIEW_STATUS=idle
  reviewers_record widget 71 w1:p3 widget-pr-71-review
  herdr() {
    case "$1 $2" in
      "pane close") printf 'close %s\n' "$3" >> "$GC_SINK";;
      *) return 1;;
    esac
  }
  gh() {
    [ "$GC_PR_STATE" != UNKNOWN ] || return 1
    jq -n --arg s "$GC_PR_STATE" '{state:$s}'
  }
}

_gc_reviewer_agents() { # the herdr roster this reviewer's pane appears in
  jq -n --arg s "$GC_REVIEW_STATUS" \
    '{result:{agents:[{pane_id:"w1:p3",name:"widget-pr-71-review",cwd:"/w/repos/widget",agent_status:$s}]}}'
}

test_gc_closes_a_reviewer_whose_pr_is_merged_or_closed() {
  local state
  for state in MERGED CLOSED; do
    _gc_reviewer_fixture
    GC_PR_STATE="$state"
    _gc_reviewers 0 "$(_gc_reviewer_agents)" >/dev/null
    assert_eq "$(cat "$GC_SINK")" "close w1:p3"
    assert_eq "$(reviewers_rows | jq -r length)" 0
    rm -rf "$T"
  done
}

# A reviewer waiting a day for a worker to push is doing its job.
test_gc_leaves_an_open_prs_reviewer_alone_however_old_the_row() {
  _gc_reviewer_fixture
  GC_PR_STATE=OPEN
  reviewers_write "$(reviewers_rows | jq -c '[.[] | .started_at = 1]')"
  _gc_reviewers 0 "$(_gc_reviewer_agents)" >/dev/null
  assert_eq "$(cat "$GC_SINK")" ""
  assert_eq "$(reviewers_rows | jq -r length)" 1
  rm -rf "$T"
}

# This file's whole history is bugs where "could not tell" was read as
# "nothing there".
test_gc_keeps_a_reviewer_whose_pr_state_cannot_be_read_and_names_it() {
  _gc_reviewer_fixture
  GC_PR_STATE=UNKNOWN
  local out; out="$(_gc_reviewers 0 "$(_gc_reviewer_agents)" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_eq "$(reviewers_rows | jq -r length)" 1
  assert_contains "$out" "widget#71"
  rm -rf "$T"
}

# A reviewer mid-sentence on a PR that merged a second ago keeps its pane.
test_gc_never_closes_a_working_reviewer_even_on_a_merged_pr() {
  _gc_reviewer_fixture
  GC_REVIEW_STATUS=working
  _gc_reviewers 0 "$(_gc_reviewer_agents)" >/dev/null 2>&1
  assert_eq "$(cat "$GC_SINK")" ""
  assert_eq "$(reviewers_rows | jq -r length)" 1
  rm -rf "$T"
}

test_gc_reviewer_dry_run_closes_nothing_and_says_what_it_would_close() {
  _gc_reviewer_fixture
  local out; out="$(_gc_reviewers 1 "$(_gc_reviewer_agents)")"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_eq "$(reviewers_rows | jq -r length)" 1
  assert_contains "$out" "widget#71"
  assert_contains "$out" MERGED
  rm -rf "$T"
}

# A pane that has gone by other means leaves a row behind; a stale row must
# not make `cel gc` fail, and must not survive the sweep either.
test_gc_drops_a_reviewer_row_whose_pane_is_already_gone() {
  _gc_reviewer_fixture
  _gc_reviewers 0 '{"result":{"agents":[]}}' >/dev/null
  assert_eq "$(cat "$GC_SINK")" ""
  assert_eq "$(reviewers_rows | jq -r length)" 0
  rm -rf "$T"
}

# The summary counts reviewers beside worktrees, and says so when there were
# none: a sweep that reports nothing is indistinguishable from one that never
# looked.
test_gc_summary_counts_reviewers_closed_even_when_there_were_none() {
  _gc_managed_fixture
  export CEL_REVIEWERS_STATE="$T/reviewers.json"
  local out; out="$(cmd_gc)"
  assert_contains "$out" "0 reviewers closed"
  rm -rf "$T"
}

# THE REGISTRY IS AN INDEX, NOT THE DEFINITION OF EXISTENCE. The first cut of
# this pass read only the rows `cel run reviewer` writes, so on the box that
# produced this ticket it reported "0 reviewers closed" with seven idle
# reviewer panes sitting in front of it: every one of them predated the
# registry. A reviewer pane is recognisable by the name cel run gives it
# (<repo>-pr-<n>-review), and an unrecorded one gets exactly the same rules.
test_gc_closes_an_unrecorded_reviewer_pane_found_by_its_name() {
  _gc_reviewer_fixture
  reviewers_write '[]'
  _gc_reviewers 0 "$(_gc_reviewer_agents)" >/dev/null
  assert_eq "$(cat "$GC_SINK")" "close w1:p3"
  assert_eq "$(reviewers_rows | jq -r length)" 0
  rm -rf "$T"
}

# An unrecorded reviewer that is still needed is ADOPTED rather than left
# unknown: the index catches up, so the next `cel run reviewer` for that PR
# reuses the pane instead of splitting another.
test_gc_adopts_an_unrecorded_reviewer_whose_pr_is_still_open() {
  _gc_reviewer_fixture
  reviewers_write '[]'
  GC_PR_STATE=OPEN
  _gc_reviewers 0 "$(_gc_reviewer_agents)" >/dev/null
  assert_eq "$(cat "$GC_SINK")" ""
  assert_eq "$(reviewers_find widget 71 | jq -r .pane)" w1:p3
  rm -rf "$T"
}

# The vetoes are not weaker for a pane nobody recorded.
test_gc_never_closes_a_working_or_unreadable_unrecorded_reviewer() {
  _gc_reviewer_fixture
  reviewers_write '[]'
  GC_REVIEW_STATUS=working
  _gc_reviewers 0 "$(_gc_reviewer_agents)" >/dev/null 2>&1
  assert_eq "$(cat "$GC_SINK")" ""
  GC_REVIEW_STATUS=idle GC_PR_STATE=UNKNOWN
  reviewers_write '[]'
  local out; out="$(_gc_reviewers 0 "$(_gc_reviewer_agents)" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" "widget#71"
  rm -rf "$T"
}

# A recorded reviewer and the same pane on the roster are ONE reviewer: the
# pane must not be closed twice or counted twice.
test_gc_counts_a_recorded_and_discovered_pane_once() {
  _gc_reviewer_fixture
  _gc_reviewers 0 "$(_gc_reviewer_agents)" >/dev/null
  assert_eq "$(cat "$GC_SINK")" "close w1:p3"
  assert_eq "$reviewers_closed" 1
  rm -rf "$T"
}

# LAST WRITE WINS IS A LOST ROW. The sweep reads the registry once, then
# spends seconds in `gh` per reviewer; a `cel run reviewer` that records a
# brand-new row in that window was silently erased by the sweep's final
# write, and the next call for that PR split a duplicate pane - defeating
# the one-reviewer-per-PR guarantee this very pass exists to give. The write
# back merges under a lock instead of overwriting from a stale snapshot.
test_gc_does_not_erase_a_reviewer_recorded_while_it_was_sweeping() {
  _gc_reviewer_fixture
  gh() {
    # `cel run reviewer --pr 99` lands while this sweep is mid-flight.
    reviewers_record gadget 99 w1:p9 gadget-pr-99-review
    jq -n --arg s "$GC_PR_STATE" '{state:$s}'
  }
  _gc_reviewers 0 "$(_gc_reviewer_agents)" >/dev/null
  assert_eq "$(cat "$GC_SINK")" "close w1:p3"
  assert_eq "$(reviewers_find gadget 99 | jq -r .pane)" w1:p9
  assert_fails reviewers_find widget 71
  rm -rf "$T"
}

# ------------------------------------------------- the finished-worker pass
# CEL-80. On 2026-09-25, 13 of 23 live worker panes belonged to delegations
# already landed or finished - panes `done` for days, never closed, because
# workers nest as tabs in their repo's workspace and the worktree pass only
# ever looked at workspaces whose first pane sat in a worktree. The ledger
# knows which pane each delegation ran in; that is where this pass starts.
_gc_done_fixture() { # <state> <agent-status>
  T="$(mktemp -d)"
  export HOME="$T/home" CEL_REGISTRY="$T/registry.yaml"
  GC_WS="$T/workspace"; GC_WT="$HOME/.herdr/worktrees/widget/abc-1-task"
  mkdir -p "$GC_WS/.cel" "$T/repo" "$(dirname "$GC_WT")"
  git -C "$T/repo" init -q
  git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T/repo" update-ref refs/remotes/origin/main HEAD
  git -C "$T/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$T/repo" worktree add -q -b abc-1-task "$GC_WT"
  registry_add demo "$GC_WS" ""
  jq -n --arg w "$GC_WT" --arg s "$1" \
    '[{id:"ABC-1-task",repo:"widget",branch:"abc-1-task",pane:"w9:p2",worktree:$w,state:$s,history:[]}]' \
    > "$GC_WS/.cel/delegations.json"
  GC_AGENTS="$(jq -nc --arg w "$GC_WT" --arg s "$2" \
    '{result:{agents:[{pane_id:"w9:p2",name:"widget-abc-1-task",cwd:$w,agent_status:$s}]}}')"
  GC_PR=MERGED
  GC_SINK="$T/sink"; : > "$GC_SINK"
  herdr() {
    case "$1 $2" in
      "pane close") printf 'close %s\n' "$3" >> "$GC_SINK";;
      *) return 1;;
    esac
  }
  gh() {
    [ "$GC_PR" != UNKNOWN ] || return 1
    case "$1 $2" in
      "pr list") jq -n --arg s "$GC_PR" '[{state:$s,updatedAt:"2026-01-01T00:00:00Z"}]';;
      *) return 1;;
    esac
  }
}

test_gc_closes_a_done_pane_whose_delegation_landed() {
  _gc_done_fixture landed done
  local out; out="$(_gc_done_panes 0 "$GC_AGENTS" demo 2>&1)"
  assert_eq "$(cat "$GC_SINK")" "close w9:p2"
  assert_contains "$out" 'closed 1 done panes'
  rm -rf "$T"
}

test_gc_keeps_a_working_pane_even_when_its_delegation_landed() {
  _gc_done_fixture landed working
  local out; out="$(_gc_done_panes 0 "$GC_AGENTS" demo 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" 'kept 1: 1 working'
  rm -rf "$T"
}

# `finished` with its PR merged is `landed` that nobody wrote down yet: it is
# reconciled first, and then it qualifies like any other landed row.
test_gc_reconciles_finished_and_merged_to_landed_then_closes_it() {
  _gc_done_fixture finished idle
  _gc_done_panes 0 "$GC_AGENTS" demo >/dev/null 2>&1
  assert_eq "$(jq -r '.[0].state' "$GC_WS/.cel/delegations.json")" landed
  assert_eq "$(jq -r '.[0].history[-1].by' "$GC_WS/.cel/delegations.json")" gc
  assert_eq "$(cat "$GC_SINK")" "close w9:p2"
  rm -rf "$T"
}

test_gc_keeps_a_done_pane_over_dirty_work() {
  _gc_done_fixture landed done
  printf 'x' > "$GC_WT/uncommitted.txt"
  local out; out="$(_gc_done_panes 0 "$GC_AGENTS" demo 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" '1 dirty'
  rm -rf "$T"
}

test_gc_keeps_a_done_pane_whose_pr_is_open_or_unreadable() {
  local s
  for s in OPEN UNKNOWN; do
    _gc_done_fixture landed done
    GC_PR="$s"
    _gc_done_panes 0 "$GC_AGENTS" demo >/dev/null 2>&1
    assert_eq "$(cat "$GC_SINK")" ""
    rm -rf "$T"
  done
}

# A pane id herdr has reused for something else is not this delegation's.
test_gc_never_closes_a_pane_now_somewhere_else() {
  _gc_done_fixture landed done
  GC_AGENTS="$(printf '%s' "$GC_AGENTS" | jq -c '.result.agents[0].cwd = "/elsewhere"')"
  _gc_done_panes 0 "$GC_AGENTS" demo >/dev/null 2>&1
  assert_eq "$(cat "$GC_SINK")" ""
  rm -rf "$T"
}

test_gc_done_pane_dry_run_says_what_it_would_close_and_closes_nothing() {
  _gc_done_fixture finished done
  local out; out="$(_gc_done_panes 1 "$GC_AGENTS" demo 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" 'would close'
  assert_eq "$(jq -r '.[0].state' "$GC_WS/.cel/delegations.json")" finished
  rm -rf "$T"
}

# THE EMPTY PANES (CEL-84). A worker that quit leaves its shell behind; 36
# such panes cluttered the owner's pane picker on 2026-09-27. Only a bare
# shell in a clean worker checkout (or a deleted one) is empty - a service,
# an editor, an owner's shell and a layout's pane are all kept.
_gc_empty_fixture() {
  _gc_shell_children() { :; }   # the stub shell has no children
  T="$(mktemp -d)"
  export HOME="$T/home"
  mkdir -p "$T/repo" "$HOME/.herdr/worktrees/widget" "$HOME/ws/alpha"
  git -C "$T/repo" init -q
  git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T/repo" update-ref refs/remotes/origin/main HEAD
  GC_WT="$HOME/.herdr/worktrees/widget/task"
  git -C "$T/repo" worktree add -q -b task "$GC_WT"
  git -C "$GC_WT" update-ref refs/remotes/origin/task HEAD
  mkdir -p "$GC_WT/.pi" "$GC_WT/.agent"; : > "$GC_WT/.agent/result.md"
  GC_SINK="$T/sink"; : > "$GC_SINK"
  GC_PANES='{"result":{"panes":[]}}'
  declare -gA GC_PROC=()
  herdr() {
    case "$1 $2" in
      "pane process-info")
        local p="$4" n="${GC_PROC[$4]:-zsh}"
        if [ "$n" = zsh ]; then
          jq -n --arg p "$p" '{result:{process_info:{pane_id:$p,shell_pid:10,foreground_process_group_id:10,foreground_processes:[{pid:10,name:"zsh",argv:["/usr/bin/zsh"]}]}}}'
        else
          jq -n --arg p "$p" --arg n "$n" '{result:{process_info:{pane_id:$p,shell_pid:10,foreground_process_group_id:20,foreground_processes:[{pid:20,name:$n,argv:[$n]}]}}}'
        fi;;
      "pane close") printf 'close %s\n' "$3" >> "$GC_SINK";;
      *) return 1;;
    esac
  }
}
_gc_empty_pane() { # <id> <cwd> [label]
  GC_PANES="$(printf '%s' "$GC_PANES" | jq -c --arg p "$1" --arg c "$2" --arg l "${3:-}" \
    '.result.panes += [{pane_id:$p,cwd:$c,agent_status:"unknown"} + (if $l == "" then {} else {label:$l} end)]')"
}

test_gc_closes_an_idle_shell_in_a_clean_worktree() {
  _gc_empty_fixture; _gc_empty_pane w1:p1 "$GC_WT"
  local out; out="$(_gc_idle_panes 0 "$GC_PANES" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" "close w1:p1"
  rm -rf "$T"
}
test_gc_keeps_an_idle_shell_over_dirty_work() {
  _gc_empty_fixture; _gc_empty_pane w1:p1 "$GC_WT"; : > "$GC_WT/wip.txt"
  local out; out="$(_gc_idle_panes 0 "$GC_PANES" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" "1 dirty"
  rm -rf "$T"
}
test_gc_keeps_an_idle_shell_over_unpushed_commits() {
  _gc_empty_fixture; _gc_empty_pane w1:p1 "$GC_WT"
  git -C "$GC_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m wip
  _gc_idle_panes 0 "$GC_PANES" >/dev/null 2>&1
  assert_eq "$(cat "$GC_SINK")" ""
  rm -rf "$T"
}
test_gc_keeps_a_service_running_in_a_worktree_pane() {
  _gc_empty_fixture; _gc_empty_pane w1:p1 "$GC_WT"; GC_PROC[w1:p1]=gadget-server
  local out; out="$(_gc_idle_panes 1 "$GC_PANES" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" "running gadget-server"
  rm -rf "$T"
}
test_gc_keeps_an_owner_shell_outside_the_worktrees() {
  _gc_empty_fixture; _gc_empty_pane w1:p1 "$HOME/ws/alpha"
  local out; out="$(_gc_idle_panes 0 "$GC_PANES" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" "1 owner shell"
  rm -rf "$T"
}
test_gc_keeps_a_service_outside_the_worktrees() {
  _gc_empty_fixture; _gc_empty_pane w1:p1 "$HOME/ws/alpha"; GC_PROC[w1:p1]=widget-proxy
  local out; out="$(_gc_idle_panes 0 "$GC_PANES" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" "1 service"
  rm -rf "$T"
}
test_gc_closes_an_idle_shell_in_a_deleted_directory() {
  _gc_empty_fixture; _gc_empty_pane w1:p1 "$HOME/.herdr/worktrees/widget/gone"
  _gc_idle_panes 0 "$GC_PANES" >/dev/null 2>&1
  assert_eq "$(cat "$GC_SINK")" "close w1:p1"
  rm -rf "$T"
}
test_gc_keeps_a_layout_declared_pane() {
  _gc_empty_fixture; _gc_empty_pane w1:p1 "$GC_WT" notes
  local out; out="$(_gc_idle_panes 0 "$GC_PANES" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" "1 declared"
  rm -rf "$T"
}
test_gc_never_touches_a_pane_with_an_agent() {
  _gc_empty_fixture; _gc_empty_pane w1:p1 "$GC_WT"
  GC_PANES="$(printf '%s' "$GC_PANES" | jq -c '.result.panes[0].agent = "pi"')"
  _gc_idle_panes 0 "$GC_PANES" >/dev/null 2>&1
  assert_eq "$(cat "$GC_SINK")" ""
  rm -rf "$T"
}
test_gc_idle_pane_dry_run_lists_closes_and_keeps_with_reasons() {
  _gc_empty_fixture
  _gc_empty_pane w1:p1 "$GC_WT"; _gc_empty_pane w1:p2 "$HOME/ws/alpha"
  local out; out="$(_gc_idle_panes 1 "$GC_PANES" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" "would close empty pane w1:p1"
  assert_contains "$out" "kept pane w1:p2"
  assert_contains "$out" "owner shell"
  rm -rf "$T"
}

# A shell with a background or stopped job ('sleep 100 &', a ^Z'd editor)
# looks bare from the foreground group alone; its children say otherwise.
test_gc_keeps_a_shell_with_a_background_child() {
  _gc_empty_fixture; _gc_empty_pane w1:p1 "$GC_WT"
  _gc_shell_children() { printf 'sleep\n'; }
  local out; out="$(_gc_idle_panes 1 "$GC_PANES" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" "running sleep"
  rm -rf "$T"
}
# A deleted directory outside the worker checkouts was the owner's.
test_gc_keeps_a_shell_in_a_deleted_directory_outside_the_worktrees() {
  _gc_empty_fixture; _gc_empty_pane w1:p1 "$HOME/ws/alpha/gone"
  local out; out="$(_gc_idle_panes 0 "$GC_PANES" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_contains "$out" "1 owner shell"
  rm -rf "$T"
}

# CEL-88. The dry run and the real run go through ONE selection; only the
# final delete differs. A stub docker with an in-use image, an unused image
# and a stopped container's image; build cache on the side.
_gc_docker_stub() {
  _gc_box_fixture
  mkdir -p "$T/dbin"
  export GC_DOCKER_LOG="$T/docker.argv" GC_DOCKER_FAIL=""
  : > "$GC_DOCKER_LOG"
  cat > "$T/dbin/docker" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GC_DOCKER_LOG"
case "$1 $2" in
  "system df")
    [ "$GC_DOCKER_FAIL" = df ] && exit 1
    n="$(wc -l < "${GC_DOCKER_LOG%.argv}.rm" 2>/dev/null || echo 0)"
    printf '{"Type":"Images","Size":"4GB","Reclaimable":"%sGB"}\n' "$(( 3 - n ))"
    printf '%s\n' '{"Type":"Build Cache","Size":"2GB","Reclaimable":"2GB"}' ;;
  "container ls")
    [ "$GC_DOCKER_FAIL" = ls ] && { printf 'Error: daemon hiccup\n' >&2; exit 1; }
    printf '%s\n' 'widget:live' 'sha256:ssss11112222' ;;
  "image ls")
    printf '%s\n' '{"ID":"sha256:aaaa","Repository":"widget","Tag":"live","CreatedAt":"2025-01-01 00:00:00 +0000 UTC","Size":"1GB"}'
    printf '%s\n' '{"ID":"sha256:ssss11112222","Repository":"widget","Tag":"stopped","CreatedAt":"2025-01-01 00:00:00 +0000 UTC","Size":"1GB"}'
    printf '%s\n' '{"ID":"sha256:aaaa","Repository":"widget","Tag":"old","CreatedAt":"2025-01-01 00:00:00 +0000 UTC","Size":"1GB"}'
    printf '%s\n' '{"ID":"sha256:uuuu","Repository":"ghcr.io/example/gadget","Tag":"older","CreatedAt":"2025-01-01 00:00:00 +0000 UTC","Size":"1GB"}'
    printf '%s\n' '{"ID":"sha256:uuuu","Repository":"ghcr.io/example/gadget","Tag":"old","CreatedAt":"2025-01-01 00:00:00 +0000 UTC","Size":"1GB"}' ;;
  "image inspect") printf 'Error: template parsing error\n' >&2; exit 1 ;;
  "image rm")
    [ "$GC_DOCKER_FAIL" = rm ] && { printf 'Error: conflict: unable to remove\n' >&2; exit 1; }
    printf '%s\n' "$3" >> "${GC_DOCKER_LOG%.argv}.rm"; printf 'Deleted: %s\n' "$3" ;;
  "builder prune")
    [ "$GC_DOCKER_FAIL" = builder ] && { printf 'Error: builder broke\n' >&2; exit 1; }
    printf 'Total reclaimed space: 2GB\n' ;;
  *) printf 'Total reclaimed space: 0B\n' ;;
esac
EOS
  chmod +x "$T/dbin/docker"
  export CEL_BOX_DOCKER="$T/dbin/docker"
}

_gc_docker_line() { printf '%s\n' "$1" | grep -o 'box: docker [^,]*' | sed -n 1p | sed 's/ would be freed\| freed//'; }

test_gc_box_docker_dry_run_and_real_run_plan_the_same_selection() {
  _gc_docker_stub
  local dry real
  dry="$(cmd_gc --box --dry-run)"
  assert_eq "$(grep -cE 'image rm|prune' "$GC_DOCKER_LOG")" 0
  # Summed virtual sizes overstate shared layers: an upper bound, said so.
  assert_contains "$dry" "docker up to 3"
  real="$(cmd_gc --box)"
  # The real figure is docker's own: 1 GB of images by df delta + 2 GB cache.
  assert_contains "$real" "box: docker 3"
  case "$real" in *"docker 0 B"*) printf 'real run freed nothing: %s\n' "$real" >&2; return 1;; esac
  rm -rf "$T"
}

# A tag in use keeps its whole image ID; an ID with two unused tags is removed once.
test_gc_box_docker_decides_keep_per_image_id_and_dedupes() {
  _gc_docker_stub
  cmd_gc --box >/dev/null
  assert_eq "$(grep -c 'image rm' "$GC_DOCKER_LOG")" 1
  assert_eq "$(grep 'image rm' "$GC_DOCKER_LOG")" "image rm sha256:uuuu"
  rm -rf "$T"
}

# An unknown in-use list is not an empty one.
test_gc_box_docker_aborts_when_container_listing_fails() {
  _gc_docker_stub
  GC_DOCKER_FAIL=ls
  local out rc=0
  out="$(cmd_gc --box 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { printf 'exit 0 with an unknown in-use list\n' >&2; return 1; }
  assert_contains "$out" "daemon hiccup"
  assert_eq "$(grep -cE 'image rm|prune' "$GC_DOCKER_LOG")" 0
  rm -rf "$T"
}

test_gc_box_docker_real_run_prunes_unused_and_never_in_use() {
  _gc_docker_stub
  cmd_gc --box >/dev/null
  assert_contains "$(grep 'image rm' "$GC_DOCKER_LOG")" uuuu
  assert_contains "$(cat "$GC_DOCKER_LOG")" "builder prune"
  case "$(grep 'image rm' "$GC_DOCKER_LOG")" in
    *aaaa*|*ssss*) printf 'removed an in-use image\n' >&2; return 1;;
  esac
  case "$(cat "$GC_DOCKER_LOG")" in *volume*|*"container prune"*) printf 'touched volumes/containers\n' >&2; return 1;; esac
  rm -rf "$T"
}

test_gc_box_docker_failure_warns_with_the_error_and_exits_nonzero() {
  _gc_docker_stub
  GC_DOCKER_FAIL=builder
  local out rc=0
  out="$(cmd_gc --box 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { printf 'exit 0 on a failed docker delete\n' >&2; return 1; }
  assert_contains "$out" "builder broke"
  rm -rf "$T"
}

# THE FOLDER IS GONE, THE PR IS NOT (CEL-89). When a review checkout is
# removed herdr reports the pane's cwd with a literal ` (deleted)` suffix, and
# the parse that read the repo from that cwd produced `widget-pr-41 (deleted)`:
# GitHub knew no such repo, the fail-safe kept the reviewer, and five
# reviewers of merged PRs stacked up on the owner's box, warned about every tick.
_gc_deleted_reviewer_fixture() {
  T="$(mktemp -d)"
  export HOME="$T/home" CEL_REVIEWERS_STATE="$T/reviewers.json" CEL_REGISTRY="$T/registry.yaml"
  mkdir -p "$HOME" "$T/ws/repos/widget"
  printf 'name: demo\n' > "$T/ws/workspace.yaml"
  git -C "$T/ws/repos/widget" init -q
  git -C "$T/ws/repos/widget" remote add origin git@github.com:acme/widget.git
  registry_add demo "$T/ws" ""
  reviewers_write '[]'
  GC_SINK="$T/sink"; : > "$GC_SINK"; GC_GH="$T/gh"; : > "$GC_GH"; GC_MAIL="$T/mail"; : > "$GC_MAIL"
  GC_PR_STATE=MERGED
  herdr() {
    case "$1 $2" in
      "pane close") printf 'close %s\n' "$3" >> "$GC_SINK";;
      *) return 1;;
    esac
  }
  gh() {
    printf '%s\n' "$*" >> "$GC_GH"
    case "$*" in *"(deleted)"*|*"widget-pr-"*) return 1;; esac
    [ "$GC_PR_STATE" != UNKNOWN ] || return 1
    jq -n --arg s "$GC_PR_STATE" '{state:$s}'
  }
  cmd_inbox() { printf '%s\n' "$*" >> "$GC_MAIL"; }
}

_gc_deleted_reviewer_agents() {
  jq -n --arg c "$HOME/.local/state/cel/reviews/widget-pr-41 (deleted)" \
    '{result:{agents:[{pane_id:"w1:p5",name:"widget-pr-41-review",cwd:$c,agent_status:"idle"}]}}'
}

test_gc_closes_an_idle_reviewer_of_a_merged_pr_whose_folder_is_deleted() {
  _gc_deleted_reviewer_fixture
  _gc_reviewers 0 "$(_gc_deleted_reviewer_agents)" >/dev/null 2>&1
  assert_eq "$(cat "$GC_SINK")" "close w1:p5"
  assert_contains "$(cat "$GC_GH")" "--repo acme/widget"
  rm -rf "$T"
}

test_gc_keeps_a_deleted_folder_reviewer_whose_pr_is_open() {
  _gc_deleted_reviewer_fixture
  GC_PR_STATE=OPEN
  _gc_reviewers 0 "$(_gc_deleted_reviewer_agents)" >/dev/null 2>&1
  assert_eq "$(cat "$GC_SINK")" ""
  assert_eq "$(reviewers_find widget 41 | jq -r .pane)" w1:p5
  rm -rf "$T"
}

test_gc_keeps_an_unreadable_deleted_folder_reviewer_with_one_warning() {
  _gc_deleted_reviewer_fixture
  GC_PR_STATE=UNKNOWN
  local out; out="$(_gc_reviewers 0 "$(_gc_deleted_reviewer_agents)" 2>&1)"
  assert_eq "$(cat "$GC_SINK")" ""
  assert_eq "$(printf '%s\n' "$out" | grep -c UNKNOWN)" 1
  assert_contains "$out" "widget#41"
  case "$out" in *"(deleted)"*) printf 'warning names the deleted suffix: %s\n' "$out"; return 1;; esac
  assert_eq "$(cat "$GC_MAIL")" ""
  rm -rf "$T"
}

# Kept as UNKNOWN for a day is a thing root should hear about - once, not on
# every tick after it.
test_gc_reports_a_reviewer_unknown_for_a_day_to_root_once() {
  _gc_deleted_reviewer_fixture
  GC_PR_STATE=UNKNOWN
  mkdir -p "$HOME/.local/state/cel"
  jq -n --argjson t "$(( $(date +%s) - 90000 ))" '{"w1:p5 widget#41":{since:$t}}' \
    > "$HOME/.local/state/cel/gc-reviewer-unknown.json"
  _gc_reviewers 0 "$(_gc_deleted_reviewer_agents)" >/dev/null 2>&1
  _gc_reviewers 0 "$(_gc_deleted_reviewer_agents)" >/dev/null 2>&1
  assert_eq "$(grep -c . "$GC_MAIL")" 1
  assert_contains "$(cat "$GC_MAIL")" "--kind blocked"
  assert_contains "$(cat "$GC_MAIL")" "w1:p5"
  assert_eq "$(cat "$GC_SINK")" ""
  rm -rf "$T"
}

# A pane id herdr has reused is somebody else's reviewer: its UNKNOWN clock
# must not be inherited.
test_gc_unknown_clock_is_keyed_by_pane_and_reviewer() {
  _gc_deleted_reviewer_fixture
  GC_PR_STATE=UNKNOWN
  mkdir -p "$HOME/.local/state/cel"
  jq -n --argjson t "$(( $(date +%s) - 90000 ))" '{"w1:p5 gadget#9":{since:$t}, "w1:p5":{since:$t}}' \
    > "$HOME/.local/state/cel/gc-reviewer-unknown.json"
  _gc_reviewers 0 "$(_gc_deleted_reviewer_agents)" >/dev/null 2>&1
  assert_eq "$(cat "$GC_MAIL")" ""
  rm -rf "$T"
}

# A report that did not go out was not made: the next tick tries again.
test_gc_unknown_report_retries_when_the_send_fails() {
  _gc_deleted_reviewer_fixture
  GC_PR_STATE=UNKNOWN
  mkdir -p "$HOME/.local/state/cel"
  jq -n --argjson t "$(( $(date +%s) - 90000 ))" '{"w1:p5 widget#41":{since:$t}}' \
    > "$HOME/.local/state/cel/gc-reviewer-unknown.json"
  cmd_inbox() { printf '%s\n' "$*" >> "$GC_MAIL"; return 1; }
  _gc_reviewers 0 "$(_gc_deleted_reviewer_agents)" >/dev/null 2>&1
  cmd_inbox() { printf '%s\n' "$*" >> "$GC_MAIL"; }
  _gc_reviewers 0 "$(_gc_deleted_reviewer_agents)" >/dev/null 2>&1
  _gc_reviewers 0 "$(_gc_deleted_reviewer_agents)" >/dev/null 2>&1
  assert_eq "$(grep -c . "$GC_MAIL")" 2
  rm -rf "$T"
}

# ------------------------------------- a live reviewer keeps its checkout
# CEL-94: review checkouts were deleted while their reviewer was mid-review -
# herdr showed the pane's cwd as "(deleted)" and the reviewer fell back to a
# /tmp clone. Liveness is asked of the herdr roster AT THE MOMENT OF DELETION,
# never of the reviewer registry: a row can name a pane id that is gone while
# a newer pane for the same PR is working in the very same directory.
_gc_live_checkout_fixture() { # roster comes from GC_ROSTER
  _gc_reviewer_fixture
  export CEL_REVIEW_DIR="$T/reviews"
  CO="$T/reviews/widget-pr-71"; mkdir -p "$CO/src"; : > "$CO/src/file"
  reviewers_record widget 71 w1:p3 widget-pr-71-review "$CO" "" ""
  GC_ROSTER='{"result":{"agents":[]}}'
  herdr() {
    case "$1 $2" in
      "pane close") printf 'close %s\n' "$3" >> "$GC_SINK";;
      "agent list") printf '%s' "$GC_ROSTER";;
      *) return 1;;
    esac
  }
}

test_gc_keeps_a_checkout_a_live_pane_is_standing_in_though_its_row_pane_is_gone() {
  _gc_live_checkout_fixture
  GC_ROSTER="$(jq -nc --arg c "$CO/src" \
    '{result:{agents:[{pane_id:"w1:p9",name:"widget-pr-71-review",cwd:$c,agent_status:"working"}]}}')"
  _gc_reviewers 0 '{"result":{"agents":[]}}' >/dev/null 2>&1
  [ -e "$CO/src/file" ] || { echo "a live reviewer's checkout was deleted"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_gc_releases_the_checkout_once_no_pane_stands_in_it() {
  _gc_live_checkout_fixture
  _gc_reviewers 0 '{"result":{"agents":[]}}' >/dev/null 2>&1
  [ ! -e "$CO" ] || { echo "an orphaned checkout survived gc"; rm -rf "$T"; return 1; }
  assert_eq "$(reviewers_rows | jq -r length)" 0
  rm -rf "$T"
}

# A relaunch for the same PR used to drop the directory before re-creating it,
# whatever was working in it.
test_relaunch_never_deletes_a_checkout_a_live_pane_stands_in() {
  _gc_live_checkout_fixture
  GC_ROSTER="$(jq -nc --arg c "$CO (deleted)" \
    '{result:{agents:[{pane_id:"w1:p9",name:"someone",cwd:$c,agent_status:"working"}]}}')"
  assert_fails reviewer_checkout_make "$T/nope" widget 71 deadbeef
  [ -e "$CO/src/file" ] || { echo "a relaunch deleted a live checkout"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Sourcery on #119: a roster reply that parses but is not a roster must not
# read as "nobody here", and an adopted row (no checkout field) still has its
# checkout released once its pane is gone.
test_a_malformed_roster_keeps_the_checkout() {
  _gc_live_checkout_fixture
  GC_ROSTER='{"oops":true}'
  _gc_reviewers 0 '{"result":{"agents":[]}}' >/dev/null 2>&1
  [ -e "$CO/src/file" ] || { echo "deleted on an unreadable roster"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_an_adopted_rows_checkout_is_released_when_its_pane_is_gone() {
  _gc_live_checkout_fixture
  reviewers_record widget 71 w1:p3 widget-pr-71-review
  _gc_reviewers 0 '{"result":{"agents":[]}}' >/dev/null 2>&1
  [ ! -e "$CO" ] || { echo "an adopted reviewer's checkout outlived it"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# CEL-111: one /proc pass per gc run, not one per worktree - the per-worktree
# readlink of every pid on the box was 666 execs in 15 seconds.
test_gc_has_process_reads_proc_once_per_run() {
  local B; B="$(mktemp -d)"
  printf '#!/bin/sh\necho x >> "%s/count"\nexec /usr/bin/readlink "$@"\n' "$B" > "$B/readlink"
  chmod +x "$B/readlink"
  _gc_cwd_reset
  local here; here="$(pwd -P)"
  PATH="$B:$PATH"
  _gc_has_process "$here" || { echo "missed own cwd"; return 1; }
  local first; first="$(wc -l < "$B/count")"
  _gc_has_process "/nonexistent/one" || true
  _gc_has_process "/nonexistent/two" || true
  assert_eq "$(wc -l < "$B/count")" "$first"
  rm -rf "$B"
}
