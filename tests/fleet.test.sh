# shellcheck shell=bash
# `cel fleet` - the whole box in one read. Every assertion here is a number an
# operator would otherwise have gathered by visiting each workspace in turn,
# so the fixture is a miniature box: two workspaces, a ledger, a worktree, a
# mailbox and a herdr stub.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/fleet.sh"

# The pane text from the 2026-09-14 incident, copied (not sourced) from
# tests/stall.test.sh on purpose: a shared helper between two suites makes a
# change in one silently move the other's evidence.
_fleet_death() {
  printf '%s\n' \
    '  Running tests...' \
    '✘ server_error: Upstream error from Together: Stream error: h2 protocol error: error reading a body from connection' \
    '↻ F5 to Retry'
}

_fleet_ws_yaml() { # <name> <repo>...
  local name="$1"
  shift
  cat <<EOF
name: $name
kind: hustle
org: someone
tickets: { system: none, adhoc: "AH-<yymmdd>" }
policy: { merge: humans-only, pr: required, workers: 4, reviewer: null }
runtime: { root: claude, orchestrator: claude, worker: omp }
tools: []
repos:
EOF
  local r
  for r in "$@"; do
    printf -- '  - name: %s\n    url: git@github.com:someone/%s.git\n    prefix: WG\n    gate: bun test\n' "$r" "$r"
  done
}

_fleet_setup() {
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml"
  export CEL_INBOX_DIR="$T/inbox"
  mkdir -p "$T/inbox" "$T/alpha/.cel" "$T/beta/.cel" "$T/bin"

  cat >"$CEL_REGISTRY" <<EOF
workspaces:
  alpha: { path: $T/alpha, remote: null }
  beta: { path: $T/beta, remote: null }
EOF
  _fleet_ws_yaml alpha widget gadget >"$T/alpha/workspace.yaml"
  _fleet_ws_yaml beta gadget >"$T/beta/workspace.yaml"

  # The running worker's worktree: a real git repo, because unlanded work is
  # measured with git and a stub would prove nothing.
  WT="$T/wt-widget"
  mkdir -p "$WT"
  git -C "$WT" init -q -b main
  git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$WT" update-ref refs/remotes/origin/main HEAD
  git -C "$WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$WT" checkout -q -b widget-work
  git -C "$WT" update-ref refs/remotes/origin/widget-work HEAD

  cat >"$T/alpha/.cel/delegations.json" <<EOF
[{"id":"one","repo":"widget","branch":"widget-work","pane":"wA:p2","worktree":"$WT","state":"running","ticket":""},
 {"id":"two","repo":"widget","branch":"widget-old","pane":"wA:p3","worktree":"$T/gone","state":"collected","ticket":""}]
EOF
  printf '[]\n' >"$T/beta/.cel/delegations.json"

  # One unread message for root, in alpha only.
  printf '%s\n' '{"id":"1","ts":"2026-09-16T00:00:00+00:00","to":"root","from":"widget-orch","kind":"status","message":"hello","cwd":"/","pane":""}' \
    >"$T/inbox/alpha.jsonl"

  cat >"$T/bin/herdr" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_HERDR_FAIL:-}" ] && exit 1
case "$1 $2" in
  "agent list") printf '%s\n' '{"result":{"agents":[
      {"name":"widget-orch","agent_status":"idle","pane_id":"wA:p1"},
      {"name":"widget-widget-work","agent_status":"idle","pane_id":"wA:p2"}]}}' ;;
  "pane read")  printf '%s\n' "${STUB_PANE_TEXT:-reading src and running the gate}" ;;
  *) printf '%s\n' '{}' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
  PATH="$T/bin:$PATH"
}
_fleet_teardown() { rm -rf "$T"; }

test_fleet_prints_a_block_per_workspace_and_a_line_per_repo() {
  _fleet_setup
  local out
  out="$(cmd_fleet)"
  assert_contains "$out" "alpha"
  assert_contains "$out" "beta"
  assert_contains "$out" "widget"
  assert_contains "$out" "gadget"
  # the orchestrator herdr knows about is LIVE; the one it does not is a dash
  assert_contains "$out" "$(printf 'widget')"
  case "$out" in *"widget"*"orch LIVE"*) ;; *)
    echo "widget was not LIVE: $out"
    _fleet_teardown
    return 1
    ;;
  esac
  case "$out" in *"gadget"*"orch -"*) ;; *)
    echo "gadget was not '-': $out"
    _fleet_teardown
    return 1
    ;;
  esac
  assert_contains "$out" "workers 1/4"
  _fleet_teardown
}

# Root's mail is per workspace: the point of the view is that nobody has to
# remember which mailbox they last looked at.
test_fleet_counts_root_mail_per_workspace() {
  _fleet_setup
  local doc
  doc="$(cmd_fleet --json)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[] | select(.name=="alpha") | .root.unread')" "1"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[] | select(.name=="beta")  | .root.unread')" "0"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[] | select(.name=="alpha") | .root.open')" "0"
  assert_contains "$(cmd_fleet --workspace alpha)" "1 unread"
  _fleet_teardown
}

# The incident replayed through the fleet view: a dead pane plus a worktree
# nothing has written to for two hours is one stalled worker.
test_fleet_reports_a_dead_pane_as_stalled() {
  _fleet_setup
  find "$WT" -exec touch -d '2 hours ago' {} + 2>/dev/null || true
  local out
  out="$(STUB_PANE_TEXT="$(_fleet_death)" cmd_fleet --workspace alpha)"
  assert_contains "$out" "stalled 1"
  _fleet_teardown
}

# Unlanded is what would be LOST, not what is merely unfinished.
test_fleet_reports_uncommitted_work_as_unlanded() {
  _fleet_setup
  assert_contains "$(cmd_fleet --workspace alpha)" "unlanded 0"
  printf 'work\n' >"$WT/scratch.txt"
  assert_contains "$(cmd_fleet --workspace alpha)" "unlanded 1"
  _fleet_teardown
}

test_fleet_json_carries_the_same_numbers_and_workspace_limits_the_scope() {
  _fleet_setup
  printf 'work\n' >"$WT/scratch.txt"
  local doc
  doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces | length')" "1"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].name')" "alpha"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units | length')" "2"
  local u
  u="$(printf '%s' "$doc" | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch')" "LIVE"
  assert_eq "$(printf '%s' "$u" | jq -r '.workers')" "1"
  assert_eq "$(printf '%s' "$u" | jq -r '.cap')" "4"
  assert_eq "$(printf '%s' "$u" | jq -r '.stalled')" "0"
  assert_eq "$(printf '%s' "$u" | jq -r '.unlanded')" "1"
  _fleet_teardown
}

# herdr being unreachable is not evidence that anyone died: the read still
# completes, every orchestrator reads as unknown, and nothing is convicted.
test_fleet_survives_herdr_being_down() {
  _fleet_setup
  find "$WT" -exec touch -d '2 hours ago' {} + 2>/dev/null || true
  local doc
  doc="$(STUB_HERDR_FAIL=1 cmd_fleet --json)"
  assert_eq "$(printf '%s' "$doc" | jq -r '[.workspaces[].units[].orch] | unique | join(",")')" "-"
  assert_eq "$(printf '%s' "$doc" | jq -r '[.workspaces[].units[].stalled] | add')" "0"
  _fleet_teardown
}

test_fleet_rejects_unknown_arguments() {
  _fleet_setup
  assert_fails bash -c "source '$CEL_ROOT/lib/fleet.sh'; cmd_fleet --nonsense"
  _fleet_teardown
}
