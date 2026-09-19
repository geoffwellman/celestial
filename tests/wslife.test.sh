# shellcheck shell=bash
# `cel ws up|down|reset|status` - a workspace has a declared shape and the
# plane can put it back.
#
# The incident this suite is written against (2026-09-19): one orchestrator's
# herdr workspace was gone, another's pane held a LIVE agent whose herdr NAME
# had been cleared on restart, and every surface that resolves an orchestrator
# by its alias reported `orch -` for both. A nameless agent read as a dead one,
# and the cure for a dead one is to start another - on top of the live one.
#
# Every herdr call goes through a STATEFUL stub: `up` has to be idempotent, and
# idempotence cannot be proved against a stub that forgets what it was asked to
# create. The stub logs only MUTATIONS, so "the second up changed nothing" is
# an empty file rather than a diff of reads.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/wslife.sh"

_wslife_ws_yaml() {
  cat <<'YAML'
name: alpha
kind: personal
org: someone
tickets: { system: none, adhoc: "AH-<yymmdd>" }
policy: { merge: self, pr: required, workers: 4, reviewer: null }
runtime: { root: claude, orchestrator: claude, worker: omp }
layout:
  orchestrators: auto
  panes:
    - label: dash
      cwd: .
      cmd: cel dash --ensure
    - label: notes
      cwd: .
products:
  - name: bundle
    repos: [widget]
    orchestrator: auto
  - name: gadget
    repos: [gizmo]
    orchestrator: manual
repos:
  - name: widget
    url: git@github.com:someone/widget.git
    prefix: WG
    gate: bun test
  - name: gizmo
    url: git@github.com:someone/gizmo.git
    prefix: GZ
    gate: bun test
YAML
}

# The stub keeps its world in two json files: the herdr workspaces that exist
# (with their panes and each pane's cwd) and the agents in them.
_wslife_setup() {
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml"
  export STUB_DIR="$T/stub"
  mkdir -p "$T/alpha/.cel" "$T/alpha/repos/widget" "$T/alpha/repos/gizmo" "$T/bin" "$STUB_DIR"
  _wslife_ws_yaml >"$T/alpha/workspace.yaml"
  cat >"$CEL_REGISTRY" <<EOF
workspaces:
  alpha: { path: $T/alpha, remote: null }
EOF
  printf '[]\n' >"$STUB_DIR/workspaces.json"
  printf '[]\n' >"$STUB_DIR/agents.json"
  : >"$STUB_DIR/calls.log"

  cat >"$T/bin/herdr" <<'EOF'
#!/usr/bin/env bash
S="$STUB_DIR"
W="$S/workspaces.json"; A="$S/agents.json"
_log() { printf '%s\n' "$*" >>"$S/calls.log"; }
_arg() { # <flag> <argv...>
  local want="$1"; shift
  while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { printf '%s' "${2:-}"; return 0; }; shift; done
}
_next_id() { printf 'w%s' "$(( $(jq 'length' "$W") + 1 ))"; }
_set() { jq "$1" "$2" >"$2.tmp" && mv "$2.tmp" "$2"; }
case "$1 $2" in
  "workspace list")
    printf '{"result":{"workspaces":%s}}\n' "$(jq -c '[.[] | {workspace_id, label, cwd}]' "$W")" ;;
  "workspace create")
    shift 2; _log "workspace create $*"
    id="$(_next_id)"
    jq -c --arg id "$id" --arg label "$(_arg --label "$@")" --arg cwd "$(_arg --cwd "$@")" \
      '. + [{workspace_id: $id, label: $label, cwd: $cwd,
             tabs: [{tab_id: ($id + ":t1"), label: $label, pane_id: ($id + ":p1"), cwd: $cwd}]}]' \
      "$W" >"$W.tmp" && mv "$W.tmp" "$W"
    printf '{"result":{"workspace_id":"%s","pane_id":"%s:p1"}}\n' "$id" "$id" ;;
  "workspace close")
    shift 2; _log "workspace close $*"
    jq -c --arg id "$1" 'map(select(.workspace_id != $id))' "$W" >"$W.tmp" && mv "$W.tmp" "$W"
    jq -c --arg id "$1" 'map(select((.pane_id | startswith($id + ":")) | not))' "$A" >"$A.tmp" && mv "$A.tmp" "$A"
    printf '{}\n' ;;
  "tab list")
    shift 2
    printf '{"result":{"tabs":%s}}\n' \
      "$(jq -c --arg ws "$(_arg --workspace "$@")" '[.[] | select(.workspace_id == $ws) | .tabs[]]' "$W")" ;;
  "tab create")
    shift 2; _log "tab create $*"
    ws="$(_arg --workspace "$@")"; label="$(_arg --label "$@")"; cwd="$(_arg --cwd "$@")"
    pane="$ws:p$(( $(jq --arg ws "$ws" '[.[] | select(.workspace_id == $ws) | .tabs[]] | length' "$W") + 1 ))"
    jq -c --arg ws "$ws" --arg label "$label" --arg cwd "$cwd" --arg pane "$pane" \
      'map(if .workspace_id == $ws
           then .tabs += [{tab_id: ($pane + "t"), label: $label, pane_id: $pane, cwd: $cwd}] else . end)' \
      "$W" >"$W.tmp" && mv "$W.tmp" "$W"
    printf '{"result":{"root_pane":{"pane_id":"%s"}}}\n' "$pane" ;;
  "agent list")
    printf '{"result":{"agents":%s}}\n' "$(cat "$A")" ;;
  "agent start")
    shift 2; _log "agent start $*"
    name="$1"; pane="$(_arg --pane "$@")"
    cwd="$(jq -r --arg p "$pane" '[.[] | .tabs[] | select(.pane_id == $p) | .cwd][0] // ""' "$W")"
    jq -c --arg n "$name" --arg p "$pane" --arg cwd "$cwd" \
      '. + [{name: $n, agent_status: "idle", pane_id: $p, cwd: $cwd, agent: "claude"}]' \
      "$A" >"$A.tmp" && mv "$A.tmp" "$A"
    printf '{}\n' ;;
  "agent rename")
    shift 2; _log "agent rename $*"
    jq -c --arg p "$1" --arg n "$2" 'map(if .pane_id == $p then .name = $n else . end)' \
      "$A" >"$A.tmp" && mv "$A.tmp" "$A"
    printf '{}\n' ;;
  "pane run"|"pane send-text")
    shift 2; _log "pane $* "; printf '{}\n' ;;
  *) printf '{}\n' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
  PATH="$T/bin:$PATH"
}

_wslife_teardown() { rm -rf "$T"; }

# An agent that is alive in a directory, with or without a herdr name: the
# fixture for both the rename path and the duplicate refusal.
_wslife_put_agent() { # <name|-> <pane> <cwd>
  local name="$1"
  [ "$name" != "-" ] || name=""
  jq -c --arg n "$name" --arg p "$2" --arg cwd "$3" \
    '. + [{name: (if $n == "" then null else $n end), agent_status: "idle", pane_id: $p, cwd: $cwd, agent: "claude"}]' \
    "$STUB_DIR/agents.json" >"$STUB_DIR/agents.json.tmp" \
    && mv "$STUB_DIR/agents.json.tmp" "$STUB_DIR/agents.json"
}

# A worktree with real commits, because "unlanded" is measured with git and a
# stub would prove nothing.
_wslife_worktree() { # <path>
  local wt="$1"
  mkdir -p "$wt"
  git -C "$wt" init -q -b main
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$wt" update-ref refs/remotes/origin/main HEAD
  git -C "$wt" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$wt" checkout -q -b WG-1-x
}

_wslife_ledger() { # <worktree>
  cat >"$T/alpha/.cel/delegations.json" <<EOF
[{"id":"one","repo":"widget","branch":"WG-1-x","pane":"wZ:p2","worktree":"$1","state":"running","ticket":"WG-1"}]
EOF
}

# --- the shape, declared ----------------------------------------------------

test_layout_accessors_read_the_block_and_default_to_today() {
  _wslife_setup
  assert_eq "$(ws_layout_get "$T/alpha" orchestrators)" "auto"
  assert_eq "$(ws_layout_panes "$T/alpha" | head -1)" "$(printf 'dash\t.\tcel dash --ensure')"
  assert_eq "$(ws_layout_panes "$T/alpha" | wc -l)" "2"
  # A workspace with no layout: block is exactly what it is today - manual
  # orchestrators, no extra panes, and the root layout id unchanged.
  local bare="$T/bare"; mkdir -p "$bare"; printf 'name: bare\n' >"$bare/workspace.yaml"
  assert_eq "$(ws_layout_get "$bare" orchestrators)" "manual"
  assert_eq "$(ws_layout_panes "$bare")" ""
  # The old scalar form (`layout: dev`) is the herdr workspace-manager layout
  # `cel run root` applies, and must survive the block arriving beside it.
  printf 'name: bare\nlayout: dev\n' >"$bare/workspace.yaml"
  assert_eq "$(ws_layout "$bare")" "dev"
  assert_eq "$(ws_layout_get "$T/alpha" id)" ""
  assert_eq "$(ws_layout "$T/alpha")" ""
  _wslife_teardown
}

# --- up ---------------------------------------------------------------------

test_up_creates_the_workspace_its_panes_in_order_and_only_auto_orchestrators() {
  _wslife_setup
  local out; out="$(cmd_ws_up alpha)"
  assert_contains "$out" "workspace alpha"
  assert_contains "$out" "created"
  assert_contains "$out" "pane dash"
  assert_contains "$out" "pane notes"
  assert_contains "$out" "orchestrator bundle-orch"
  # gadget declares `orchestrator: manual`: the workspace-wide switch does not
  # overrule a product that says it starts by hand.
  ! printf '%s' "$out" | grep -q 'gadget-orch.*start' \
    || { echo "a manual product was started: $out"; _wslife_teardown; return 1; }
  # Panes in declared order.
  local dash notes
  dash="$(grep -n 'tab create.*--label dash' "$STUB_DIR/calls.log" | cut -d: -f1)"
  notes="$(grep -n 'tab create.*--label notes' "$STUB_DIR/calls.log" | cut -d: -f1)"
  [ -n "$dash" ] && [ -n "$notes" ] && [ "$dash" -lt "$notes" ] \
    || { echo "panes were not created in declared order"; _wslife_teardown; return 1; }
  assert_contains "$(cat "$STUB_DIR/calls.log")" "agent start bundle-orch"

  # RUNNING IT TWICE DOES NOTHING THE SECOND TIME.
  : >"$STUB_DIR/calls.log"
  out="$(cmd_ws_up alpha)"
  assert_contains "$out" "already right"
  assert_contains "$out" "already live"
  assert_eq "$(cat "$STUB_DIR/calls.log")" ""
  _wslife_teardown
}

test_up_renames_a_live_unnamed_agent_only_in_a_cwd_it_owns() {
  _wslife_setup
  # The live orchestrator herdr forgot the name of, and a stranger in a
  # directory this workspace does not own.
  _wslife_put_agent - wQ:p1 "$T/alpha/products/bundle"
  _wslife_put_agent - wQ:p9 "$T/elsewhere"
  local out; out="$(cmd_ws_up alpha)"
  assert_contains "$out" "renamed"
  assert_contains "$(cat "$STUB_DIR/calls.log")" "agent rename wQ:p1 bundle-orch"
  ! grep -q 'agent rename wQ:p9' "$STUB_DIR/calls.log" \
    || { echo "renamed an agent in a cwd this workspace does not own"; _wslife_teardown; return 1; }
  # AND A MANUAL PRODUCT IS RENAMED TOO. `orchestrators: manual` says the
  # plane does not start them, not that a live one may stay invisible.
  _wslife_put_agent - wQ:p2 "$T/alpha/products/gadget"
  cmd_ws_up alpha >/dev/null
  assert_contains "$(cat "$STUB_DIR/calls.log")" "agent rename wQ:p2 gadget-orch"
  ! grep -q 'agent start gadget-orch' "$STUB_DIR/calls.log" \
    || { echo "a manual product was started"; _wslife_teardown; return 1; }
  # A rename is not a start: the live agent keeps its pane.
  ! grep -q 'agent start bundle-orch' "$STUB_DIR/calls.log" \
    || { echo "started a second orchestrator over a live one"; _wslife_teardown; return 1; }
  _wslife_teardown
}

# --- down -------------------------------------------------------------------

test_down_refuses_with_unlanded_work_named_and_force_proceeds() {
  _wslife_setup
  _wslife_worktree "$T/wt"
  _wslife_ledger "$T/wt"
  printf 'work\n' >"$T/wt/scratch.txt"
  cmd_ws_up alpha >/dev/null
  : >"$STUB_DIR/calls.log"
  local before; before="$(cat "$T/alpha/.cel/delegations.json")"

  local out; out="$( (cmd_ws_down alpha) 2>&1 )" && {
    echo "down proceeded over unlanded work"; _wslife_teardown; return 1; }
  assert_contains "$out" "WG-1-x"
  assert_eq "$(cat "$STUB_DIR/calls.log")" ""

  out="$(cmd_ws_down alpha --force)"
  assert_contains "$out" "closed"
  assert_contains "$(cat "$STUB_DIR/calls.log")" "workspace close"
  # NEITHER PATH IS A CLEAN-UP. `down` is about PANES: removing a worktree or
  # editing the ledger is `cel-fanout release`'s job and stays there.
  ! grep -q 'worktree remove' "$STUB_DIR/calls.log" \
    || { echo "down removed a worktree"; _wslife_teardown; return 1; }
  assert_eq "$(cat "$T/alpha/.cel/delegations.json")" "$before"
  _wslife_teardown
}

test_reset_is_down_then_up_in_order() {
  _wslife_setup
  cmd_ws_up alpha >/dev/null
  : >"$STUB_DIR/calls.log"
  local out; out="$(cmd_ws_reset alpha)"
  local close open
  close="$(grep -n 'workspace close' "$STUB_DIR/calls.log" | head -1 | cut -d: -f1)"
  open="$(grep -n 'workspace create' "$STUB_DIR/calls.log" | head -1 | cut -d: -f1)"
  [ -n "$close" ] && [ -n "$open" ] && [ "$close" -lt "$open" ] \
    || { echo "reset was not down-then-up: $(cat "$STUB_DIR/calls.log")"; _wslife_teardown; return 1; }
  assert_contains "$out" "closed"
  assert_contains "$out" "created"
  _wslife_teardown
}

# --- status -----------------------------------------------------------------

test_status_is_up_dry_run_in_table_form() {
  _wslife_setup
  local st dry
  st="$(cmd_ws_status alpha)"
  dry="$(cmd_ws_up alpha --dry-run)"
  assert_contains "$st" "orchestrator bundle-orch"
  assert_contains "$st" "declared auto"
  assert_contains "$st" "live no"
  assert_contains "$st" "(would start)"
  assert_contains "$dry" "would start"
  # A dry run is a preview: nothing on the box moved.
  assert_eq "$(cat "$STUB_DIR/calls.log")" ""
  # And once it is up, the same row reads live.
  cmd_ws_up alpha >/dev/null
  st="$(cmd_ws_status alpha)"
  assert_contains "$st" "live yes"
  # --json carries the same rows for whatever reads it next.
  local doc; doc="$(cmd_ws_status alpha --json)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].name')" "alpha"
  assert_eq "$(printf '%s' "$doc" | jq -r \
    '.workspaces[0].members[] | select(.name=="bundle-orch") | .live')" "yes"
  _wslife_teardown
}

# --- a nameless agent is a fault, not an absence ----------------------------

test_doctor_names_the_unnamed_agent_and_says_nothing_otherwise() {
  _wslife_setup
  assert_eq "$(wslife_doctor_lines)" ""
  _wslife_put_agent - wQ:p1 "$T/alpha/products/bundle"
  local line; line="$(wslife_doctor_lines)"
  assert_contains "$line" "alpha: an agent is running in products/bundle with no herdr name"
  assert_contains "$line" "cel ws up alpha renames it"
  # A correctly named orchestrator is not a fault.
  printf '[]\n' >"$STUB_DIR/agents.json"
  _wslife_put_agent bundle-orch wQ:p1 "$T/alpha/products/bundle"
  assert_eq "$(wslife_doctor_lines)" ""
  _wslife_teardown
}
