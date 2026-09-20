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
