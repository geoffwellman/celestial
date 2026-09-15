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
  trap 'builtin kill "$GC_PID" 2>/dev/null || true; wait "$GC_PID" 2>/dev/null || true; rm -rf "$T"' EXIT
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
