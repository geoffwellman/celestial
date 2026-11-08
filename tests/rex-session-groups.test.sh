# shellcheck shell=bash
# A product's team is one Rex session group: reviewers and team members open as
# windows in the product agent's own session, proven first, and retire by
# closing only their own window. Real receipts, real runtime processes and
# real /proc generations; only the Rex server is a fixture (tests/lib/fake-rex,
# sessions > windows > blocks with the real CLI's JSON shapes).
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/run.sh"

_sg_setup() {
  RT="$(mktemp -d)"
  export CEL_REX_STATE="$RT/state" CEL_REX_BIN="$RT/bin/rex" CEL_MANIFEST="$RT/agents.yaml" CEL_MANIFEST_CACHE="$RT/cache"
  export FAKE_REX_DIR="$RT/rex"
  WS="$RT/ws"
  mkdir -p "$RT/bin" "$WS/repos/widget" "$CEL_REX_STATE"
  cat > "$CEL_MANIFEST" <<YAML
agents:
  omp:
    bin: "$RT/bin/runtime"
    role_injection: { strategy: append_flag_file, flag: --append-system-prompt }
    model_flag: --model
YAML
  cat > "$WS/workspace.yaml" <<'YAML'
name: alpha
runtime: { orchestrator: omp }
repos:
  - name: widget
    url: git@github.com:acme/widget.git
policy: { merge: self, pr: required }
YAML
  ln -s "$CEL_ROOT/tests/lib/fake-rex" "$RT/bin/rex"
  printf '#!/bin/bash\nexec sleep 300\n' > "$RT/bin/runtime"
  cat > "$RT/bin/herdr" <<'SH'
#!/bin/bash
[ "$*" = 'agent list' ] || { echo 'unexpected Herdr action' >&2; exit 1; }
printf '{"result":{"agents":[]}}'
SH
  chmod +x "$RT/bin/runtime" "$RT/bin/herdr"
  SG_OLD_PATH="$PATH"; export PATH="$RT/bin:$PATH"
}
_sg_down() {
  local f
  for f in "$CEL_REX_STATE"/*.json; do
    [ -f "$f" ] && _rex_live "$f" || continue
    kill "$(jq -r .pid "$f")" 2>/dev/null || true
  done
  for f in $(jq -r '.pids[]?' "$FAKE_REX_DIR/state.json" 2>/dev/null); do kill "$f" 2>/dev/null || true; done
  export PATH="$SG_OLD_PATH"
  unset CEL_REX_STATE CEL_REX_BIN CEL_MANIFEST CEL_MANIFEST_CACHE FAKE_REX_DIR FAKE_REX_CHILD_PID
  rm -rf "$RT"
}

# The product agent, as cel run solo publishes it: its own session.
_sg_host() { # [name] [workspace]
  ( env_role=solo wsdir="${2:-$WS}"
    _rex_launch "${1:-widget-orch}" omp "$WS/repos/widget" widget "env CEL_ROLE=solo" ) >/dev/null
}
_sg_reviewer() { # [host] -> launch output (stdout+stderr)
  ( env_role=reviewer wsdir="$WS" repo=widget pr=7 _REX_HOST="${1-widget-orch}"
    _rex_launch widget-pr-7-review omp "$WS/repos/widget" "widget PR 7" "env CEL_ROLE=reviewer" ) 2>&1
}
_sg_member() { # <alias> [team in its env] -> launch output
  ( env_role=member wsdir="$WS" _REX_HOST=widget-orch _REX_TEAM=login
    _rex_launch "$1" omp "$WS/repos/widget" "$1" \
      "env CEL_ROLE=member CEL_WORKSPACE=$WS CEL_TEAM=${2:-login} CEL_TEAM_MEMBER=$1" ) 2>&1
}
_sg_team() {
  mkdir -p "$WS/.cel/teams/login"
  jq -n '{feature:"login",product:"widget",lead:"widget-orch",state:"open",members:[]}' > "$WS/.cel/teams/login/team.json"
}
_sg_field() { jq -r "$2" "$CEL_REX_STATE/$1.json"; }
_sg_windows() { # <session> -> window labels, one per line
  jq -r --arg s "$1" '.sessions[] | select(.session_id == $s) | .windows[].label' "$FAKE_REX_DIR/state.json"
}
_sg_sessions() { jq -r '.sessions | length' "$FAKE_REX_DIR/state.json"; }

test_rex_reviewer_opens_as_a_window_in_its_product_session() {
  _sg_setup
  _sg_host
  local host out
  host="$(_sg_field widget-orch .rex_session)"
  assert_eq "$(_sg_field widget-orch .rex_scope)" session
  out="$(_sg_reviewer)" || { echo "$out"; _sg_down; return 1; }
  assert_contains "$out" "Rex window: "
  assert_contains "$out" "in widget-orch's session $host"
  # one session, two windows: the product agent's and the reviewer's
  assert_eq "$(_sg_sessions)" 1
  assert_eq "$(_sg_windows "$host")" "$(printf 'widget\nwidget-pr-7-review')"
  assert_eq "$(_sg_field widget-pr-7-review .rex_session)" "$host"
  assert_eq "$(_sg_field widget-pr-7-review '[.rex_scope, .rex_host] | @tsv')" "$(printf 'window\twidget-orch')"
  assert_eq "$(_sg_field widget-pr-7-review .rex_window)" \
    "$(jq -r --arg s "$host" '.sessions[] | select(.session_id == $s) | .windows[1].window_id' "$FAKE_REX_DIR/state.json")"
  # created unfocused, labelled with its alias, in that exact session
  grep -qx "window new -s $host widget-pr-7-review --cwd $WS/repos/widget --shell=none --keep-open --focus=false --json -- /bin/bash .*" "$FAKE_REX_DIR/calls" \
    || { echo 'reviewer window was not created unfocused in the host session'; cat "$FAKE_REX_DIR/calls"; _sg_down; return 1; }
  # the shared roster lists both, the reviewer with its window identity
  local roster; roster="$(cel_agent_list)"
  assert_eq "$(jq -r '.result.agents | length' <<<"$roster")" 2
  assert_eq "$(jq -r '.result.agents[] | select(.name == "widget-pr-7-review") | [.pane_id, .rex_scope, .rex_host] | @tsv' <<<"$roster")" \
    "$(printf 'rex/%s/%s\twindow\twidget-orch' "$host" "$(_sg_field widget-pr-7-review .rex_block)")"
  _sg_down
}

# No provable product session: today's behaviour, a session of its own, said
# in one line. Every proof fails closed: no receipt, a dead generation, a
# terminal Rex shows running another process, another workspace, a host that
# is itself only a window.
test_rex_guest_falls_back_to_its_own_session_when_the_host_is_unproven() {
  _sg_setup
  local out case
  for case in absent dead repurposed workspace guest; do
    rm -rf "$FAKE_REX_DIR" "$CEL_REX_STATE"; mkdir -p "$CEL_REX_STATE"; unset FAKE_REX_CHILD_PID
    case "$case" in
      absent) ;;
      dead) _sg_host; jq '.pid_start = "0"' "$CEL_REX_STATE/widget-orch.json" > "$RT/r" && mv "$RT/r" "$CEL_REX_STATE/widget-orch.json" ;;
      repurposed) _sg_host; export FAKE_REX_CHILD_PID=$$ ;;
      workspace) _sg_host widget-orch "$RT/other-ws" ;;
      guest) _sg_host other-orch
        ( env_role=solo wsdir="$WS" _REX_HOST=other-orch _rex_launch widget-orch omp "$WS/repos/widget" widget "env CEL_ROLE=solo" ) >/dev/null 2>&1
        assert_eq "$(_sg_field widget-orch .rex_scope)" window ;;
    esac
    out="$(_sg_reviewer)" || { echo "$case: $out"; _sg_down; return 1; }
    assert_contains "$out" 'widget-orch has no live session Celestial can prove is its own - widget-pr-7-review opens in a session of its own' \
      || { echo "case $case"; _sg_down; return 1; }
    assert_eq "$(_sg_field widget-pr-7-review '.rex_scope + "/" + (.rex_host // "-")')" session/- || { echo "case $case"; _sg_down; return 1; }
    grep -q '^window new' "$FAKE_REX_DIR/calls" && [ "$case" != guest ] \
      && { echo "$case: a window was opened in an unproven session"; _sg_down; return 1; }
    kill "$(_sg_field widget-pr-7-review .pid)" 2>/dev/null || true
    for f in "$CEL_REX_STATE"/*.json; do kill "$(jq -r .pid "$f")" 2>/dev/null || true; done
  done
  _sg_down
}

# A dry run shows which door a reviewer will take.
test_rex_reviewer_dry_run_names_the_product_session() {
  _sg_setup
  _sg_host
  cat >> "$CEL_MANIFEST" <<YAML
  pi:
    bin: "$RT/bin/runtime"
    role_injection: { strategy: append_flag_file, flag: --append-system-prompt }
    model_flag: --model
YAML
  cat >> "$WS/workspace.yaml" <<'YAML'
session_backend: rex
review: { model: sonnet }
YAML
  export CEL_REVIEWERS_STATE="$RT/reviewers.json" CEL_BUDGET_MAX_LIVE_AGENTS=99
  boxguard_admit() { return 0; }
  # a reviewer's model goes through this box's gateway: a fixture one
  export CEL_CONFIG_FILE="$RT/gateway-config" CEL_GATEWAY_STATE="$RT/gateway" CEL_GATEWAY_STUB="$RT/gateway-stub"
  printf 'gateway:\n  port: 8317\n' > "$CEL_CONFIG_FILE"
  mkdir -p "$RT/gateway/auth"; printf '{}' > "$RT/gateway/auth/claude-aaaaaa11-someone@example.invalid.json"
  cat > "$CEL_GATEWAY_STUB" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  ready) exit 0 ;;
  models) printf '%s\n' '{"data":[{"id":"claude-sonnet-5-5"}]}' ;;
esac
EOS
  chmod +x "$CEL_GATEWAY_STUB"
  local out host; host="$(_sg_field widget-orch .rex_session)"
  out="$(cd "$WS" && cmd_run reviewer --repo widget --pr 7 --dry-run 2>&1)" || { echo "$out"; _sg_down; return 1; }
  assert_contains "$out" "rex window new -s $host widget-pr-7-review"
  kill "$(_sg_field widget-orch .pid)"; sleep 0.2
  out="$(cd "$WS" && cmd_run reviewer --repo widget --pr 7 --dry-run 2>&1)" || { echo "$out"; _sg_down; return 1; }
  assert_contains "$out" '(widget-orch has no provable live Rex session: widget-pr-7-review opens in a session of its own)'
  assert_contains "$out" 'rex new widget-pr-7-review'
  unset CEL_REVIEWERS_STATE CEL_BUDGET_MAX_LIVE_AGENTS CEL_CONFIG_FILE CEL_GATEWAY_STATE CEL_GATEWAY_STUB
  _sg_down
}

# Retiring a member closes ITS window - never the lead's session, the lead's
# window or another member's - and only after proving who it is.
test_rex_member_retire_closes_only_its_own_window() {
  _sg_setup
  _sg_host; _sg_team
  _sg_member widget-login-qa >/dev/null || { _sg_down; return 1; }
  _sg_member widget-login-design >/dev/null || { _sg_down; return 1; }
  local host qa_pid qa_win lead_pid out
  host="$(_sg_field widget-orch .rex_session)"; qa_win="$(_sg_field widget-login-qa .rex_window)"
  qa_pid="$(_sg_field widget-login-qa .pid)"; lead_pid="$(_sg_field widget-orch .pid)"
  assert_eq "$(_sg_field widget-login-qa '[.rex_scope, .rex_host, .team, .role] | @tsv')" "$(printf 'window\twidget-orch\tlogin\tmember')"
  assert_eq "$(_sg_windows "$host")" "$(printf 'widget\nwidget-login-qa\nwidget-login-design')"
  out="$(member_retire "$WS" login widget-login-qa 2>&1)" || { echo "$out"; _sg_down; return 1; }
  assert_contains "$out" 'closed widget-login-qa (its Rex window'
  assert_eq "$(grep '^window close' "$FAKE_REX_DIR/calls")" "window close -s $host $qa_win"
  grep -q '^kill ' "$FAKE_REX_DIR/calls" && { echo 'a session was killed'; _sg_down; return 1; }
  assert_eq "$(_sg_windows "$host")" "$(printf 'widget\nwidget-login-design')"
  [ ! -e "$CEL_REX_STATE/widget-login-qa.json" ] || { echo 'receipt kept after a proven close'; _sg_down; return 1; }
  ! kill -0 "$qa_pid" 2>/dev/null || { echo 'member runtime survived'; _sg_down; return 1; }
  kill -0 "$lead_pid" || { echo 'the lead died'; _sg_down; return 1; }
  _rex_live "$CEL_REX_STATE/widget-login-design.json" || { echo 'the other member died'; _sg_down; return 1; }
  _sg_down
}

# Unprovable is protected: nothing closes.
test_rex_member_retire_protects_an_unprovable_window() {
  _sg_setup
  _sg_host; _sg_team
  local case out host w pid
  host="$(_sg_field widget-orch .rex_session)"
  for case in extended env repurposed; do
    rm -f "$CEL_REX_STATE/widget-login-qa.json"
    if [ "$case" = env ]; then _sg_member widget-login-qa other >/dev/null; else _sg_member widget-login-qa >/dev/null; fi
    w="$(_sg_field widget-login-qa .rex_window)"; pid="$(_sg_field widget-login-qa .pid)"
    case "$case" in
      # the owner split the member's window: not only the member's any more
      extended) jq --arg w "$w" '(.sessions[].windows[] | select(.window_id == $w) | .layers[0].blocks) += [{block_id:"block:owner"}]' \
                  "$FAKE_REX_DIR/state.json" > "$RT/s" && mv "$RT/s" "$FAKE_REX_DIR/state.json" ;;
      repurposed) export FAKE_REX_CHILD_PID=$$ ;;
    esac
    out="$(member_retire "$WS" login widget-login-qa 2>&1)" && { echo "$case: retired an unproven member: $out"; _sg_down; return 1; }
    assert_contains "$out" 'nothing closed' || { echo "case $case"; _sg_down; return 1; }
    kill -0 "$pid" || { echo "$case: member runtime was stopped"; _sg_down; return 1; }
    _sg_windows "$host" | grep -qx widget-login-qa || { echo "$case: window closed"; _sg_down; return 1; }
    [ -f "$CEL_REX_STATE/widget-login-qa.json" ] || { echo "$case: receipt dropped"; _sg_down; return 1; }
    grep -q '^window close\|^kill ' "$FAKE_REX_DIR/calls" && { echo "$case: closed something"; _sg_down; return 1; }
    unset FAKE_REX_CHILD_PID
    kill "$pid"; sleep 0.2
    # the extended window still holds the owner's block: never closed
    jq --arg w "$w" '(.sessions[].windows) |= map(select(.window_id != $w))' "$FAKE_REX_DIR/state.json" > "$RT/s" && mv "$RT/s" "$FAKE_REX_DIR/state.json"
  done
  _sg_down
}

# A member whose runtime exited leaves a finished window; it closes only when
# Rex shows nothing runs there, and the lead's session stays.
test_rex_member_retire_closes_an_exited_members_finished_window() {
  _sg_setup
  _sg_host; _sg_team
  _sg_member widget-login-qa >/dev/null
  local host pid out
  host="$(_sg_field widget-orch .rex_session)"; pid="$(_sg_field widget-login-qa .pid)"
  kill "$pid"; for ((i=0;i<50;i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  out="$(member_retire "$WS" login widget-login-qa 2>&1)" || { echo "$out"; _sg_down; return 1; }
  assert_contains "$out" 'closed its finished Rex window'
  assert_eq "$(_sg_windows "$host")" widget
  [ ! -e "$CEL_REX_STATE/widget-login-qa.json" ] || { echo 'receipt kept'; _sg_down; return 1; }
  _sg_down
}

# Stopping a guest (cel ws down) closes its terminal only, in its window.
test_rex_stop_closes_only_the_guest_terminal() {
  _sg_setup
  _sg_host
  _sg_reviewer >/dev/null
  local host; host="$(_sg_field widget-orch .rex_session)"
  rex_agent_stop "$(_sg_field widget-pr-7-review .pane_id)" || { _sg_down; return 1; }
  grep -q "^block close -s $host -w window:" "$FAKE_REX_DIR/calls" || { echo 'block close was not window-scoped'; _sg_down; return 1; }
  assert_eq "$(_sg_windows "$host")" widget
  _rex_live "$CEL_REX_STATE/widget-orch.json" || { echo 'the product agent died'; _sg_down; return 1; }
  _sg_down
}

# After a Rex server restart the product agent comes back in a new session
# (its recorded line); a reviewer or member never resumes from its receipt,
# and its door - cel run reviewer, cel team add - opens it as a window in the
# product agent's NEW session, not the dead one.
test_rex_guest_relaunch_after_restart_opens_in_the_resumed_product_session() {
  _sg_setup
  _sg_host; _sg_reviewer >/dev/null
  local old new
  old="$(_sg_field widget-orch .rex_session)"
  assert_contains "$(_rex_resume_veto "$CEL_REX_STATE/widget-pr-7-review.json")" 'reviewers never resume'
  # the server goes away: every runtime with it, and the new server's
  # restored sessions are shells (here: none at all)
  kill "$(_sg_field widget-orch .pid)" "$(_sg_field widget-pr-7-review .pid)"; sleep 0.2
  printf '{"sessions":[],"pids":{},"n":100}' > "$FAKE_REX_DIR/state.json"
  _sg_host
  new="$(_sg_field widget-orch .rex_session)"
  [ "$new" != "$old" ] || { echo 'fixture did not move the product agent'; _sg_down; return 1; }
  _sg_reviewer >/dev/null || { _sg_down; return 1; }
  assert_eq "$(_sg_field widget-pr-7-review '[.rex_scope, .rex_session] | @tsv')" "$(printf 'window\t%s' "$new")"
  assert_eq "$(_sg_windows "$new")" "$(printf 'widget\nwidget-pr-7-review')"
  # a member's receipt says how it comes back
  jq -n '{name:"widget-login-qa",role:"member",team:"login",pid:2,pid_start:"x"}' > "$RT/m.json"
  assert_contains "$(_rex_resume_veto "$RT/m.json")" 'team members never resume - its lead retires and adds it again: cel team retire login widget-login-qa'
  _sg_down
}

# A window-scoped receipt must name its window and host; the roster fails
# closed on one that does not.
test_rex_roster_refuses_an_incomplete_window_receipt() {
  _sg_setup
  _sg_host; _sg_reviewer >/dev/null
  cel_agent_list >/dev/null || { _sg_down; return 1; }
  local f="$CEL_REX_STATE/widget-pr-7-review.json"
  jq 'del(.rex_window)' "$f" > "$RT/r" && cp "$RT/r" "$f"
  if rex_agent_list >/dev/null 2>&1; then echo 'window receipt without its window was listed'; _sg_down; return 1; fi
  jq '.rex_scope = "pane"' "$CEL_REX_STATE/widget-orch.json" > "$RT/r" && cp "$RT/r" "$CEL_REX_STATE/widget-orch.json"
  jq '.rex_window = "w"' "$f" > "$RT/r" && cp "$RT/r" "$f"
  if rex_agent_list >/dev/null 2>&1; then echo 'unknown scope was listed'; _sg_down; return 1; fi
  _sg_down
}

# Receipts written before scopes existed - every live product agent and
# reviewer at upgrade - carry no rex_scope or rex_window. They are session
# scoped: listed, and a proven host a reviewer can join.
test_rex_pre_scope_receipt_lists_as_session_scope_and_hosts() {
  _sg_setup
  _sg_host
  local f="$CEL_REX_STATE/widget-orch.json" host
  jq 'del(.rex_scope, .rex_window)' "$f" > "$RT/r" && cp "$RT/r" "$f"
  host="$(_sg_field widget-orch .rex_session)"
  assert_eq "$(rex_agent_list | jq -r '.result.agents[] | select(.name == "widget-orch") | (.rex_scope // "absent")')" absent
  assert_eq "$(_rex_host_session widget-orch "$WS")" "$host"
  _sg_reviewer >/dev/null || { _sg_down; return 1; }
  assert_eq "$(_sg_field widget-pr-7-review '[.rex_scope, .rex_session] | @tsv')" "$(printf 'window\t%s' "$host")"
  assert_eq "$(rex_agent_list | jq '.result.agents | length')" 2
  _sg_down
}
