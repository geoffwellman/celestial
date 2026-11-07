# shellcheck shell=bash
# `cel ws up|down|reset|status` - a workspace has a declared shape and the
# plane can put it back.
#
# Central case: an agent whose herdr NAME was cleared on restart must read as
# live-but-unnamed and be renamed, never as dead and started again on top.
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
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"term_%s"}}}\n' "$3" "$3" ;;
  "pane process-info")
    printf '{"result":{"process_info":{"pane_id":"%s","shell_pid":77,"foreground_process_group_id":77,"foreground_processes":[{"pid":77,"name":"zsh"}]}}}\n' "$4" ;;
  "pane list")
    shift 2
    printf '{"result":{"panes":%s}}\n' \
      "$(jq -c --arg ws "$(_arg --workspace "$@")" '[.[] | select(.workspace_id == $ws) | .tabs[] | {pane_id, tab_id, cwd, label: (.pane_label // null)}]' "$W")" ;;
  "tab rename")
    shift 2; _log "tab rename $*"
    jq -c --arg t "$1" --arg l "$2" 'map(.tabs |= map(if .tab_id == $t then .label = $l else . end))' \
      "$W" >"$W.tmp" && mv "$W.tmp" "$W"
    printf '{}\n' ;;
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

# A solo worktree of product `bundle` on branch WG-1-x, linked from the repo
# at <base> (built by _wslife_worktree). Prints its path.
_wslife_solo() { # <base>
  local wt="$T/alpha/.cel/solo/bundle/WG-1-x"
  git -C "$1" checkout -q main
  mkdir -p "${wt%/*}"
  git -C "$1" worktree add -q "$wt" WG-1-x
  printf '%s' "$wt"
}

# --- the shape, declared ----------------------------------------------------

test_layout_accessors_read_the_block_and_default_to_today() {
  _wslife_setup
  assert_eq "$(ws_layout_declared "$T/alpha" orchestrators)" "auto"
  assert_eq "$(ws_layout_panes "$T/alpha" | head -1)" "$(printf 'dash\t.\tcel dash --ensure')"
  assert_eq "$(ws_layout_panes "$T/alpha" | wc -l)" "2"
  # A workspace with no layout: block means manual orchestrators, no extra
  # panes, and no root layout id.
  local bare="$T/bare"; mkdir -p "$bare"; printf 'name: bare\n' >"$bare/workspace.yaml"
  assert_eq "$(ws_orchestrator_mode "$bare" any | cut -f1)" "manual"
  assert_eq "$(ws_layout_panes "$bare")" ""
  # The scalar form (`layout: dev`) is the herdr workspace-manager layout
  # `cel run root` applies, and must coexist with the map form.
  printf 'name: bare\nlayout: dev\n' >"$bare/workspace.yaml"
  assert_eq "$(ws_layout "$bare")" "dev"
  assert_eq "$(ws_layout_declared "$T/alpha" id)" ""
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

test_up_never_renames_a_rex_identity_through_herdr() {
  _wslife_setup
  cel_agent_list() {
    jq -n --arg d "$T/alpha/products/bundle" '{result:{agents:[{name:"retained-name",pane_id:"rex/session:owned/block:owned",backend:"rex",agent_status:"idle",cwd:$d,agent:"omp"}]}}'
  }
  cmd_ws_up alpha >/dev/null
  case "$(cat "$STUB_DIR/calls.log")" in
    *rex/*|*'agent start bundle-orch'*) echo 'Rex identity was sent to Herdr or duplicated'; _wslife_teardown; return 1;;
  esac
  _wslife_teardown
}

# --- down -------------------------------------------------------------------

test_down_refuses_with_unlanded_work_named_and_force_proceeds() {
  _wslife_setup
  _wslife_worktree "$T/wt"
  local wt; wt="$(_wslife_solo "$T/wt")"
  printf 'work\n' >"$wt/scratch.txt"
  cmd_ws_up alpha >/dev/null
  : >"$STUB_DIR/calls.log"

  local out; out="$( (cmd_ws_down alpha) 2>&1 )" && {
    echo "down proceeded over unlanded work"; _wslife_teardown; return 1; }
  assert_contains "$out" "WG-1-x"
  assert_eq "$(cat "$STUB_DIR/calls.log")" ""

  out="$(cmd_ws_down alpha --force)"
  assert_contains "$out" "closed"
  assert_contains "$(cat "$STUB_DIR/calls.log")" "workspace close"
  # NEITHER PATH IS A CLEAN-UP. `down` is about PANES, never worktrees.
  ! grep -q 'worktree remove' "$STUB_DIR/calls.log" \
    || { echo "down removed a worktree"; _wslife_teardown; return 1; }
  [ -d "$wt" ] || { echo "down removed the solo worktree"; _wslife_teardown; return 1; }
  _wslife_teardown
}

test_down_stops_only_managed_rex_roles_owned_by_the_exact_workspace() {
  _wslife_setup
  rex_agent_list() {
    jq -n --arg ws "$T/alpha" '{result:{agents:(
      (["root","orchestrator","solo","lane","reviewer","worker"] | map(. as $role |
        {name:$role,role:$role,backend:"rex",workspace:$ws,pane_id:("rex/session:"+$role+"/block:"+$role)}))
      + [{name:"core",role:"core",backend:"rex",workspace:$ws,pane_id:"rex/session:core/block:core"},
         {name:"foreign",role:"worker",backend:"rex",workspace:($ws+"-other"),pane_id:"rex/session:foreign/block:foreign"},
         {name:"nested",role:"worker",backend:"rex",workspace:($ws+"/nested"),pane_id:"rex/session:nested/block:nested"},
         {name:"unowned",role:"worker",backend:"herdr",workspace:$ws,pane_id:"w:p1"}])}}'
  }
  rex_agent_stop() { printf '%s\n' "$1" >> "$T/rex-stops"; }
  cmd_ws_down alpha >/dev/null
  assert_eq "$(wc -l < "$T/rex-stops")" 6
  local role
  for role in root orchestrator solo lane reviewer worker; do
    assert_contains "$(cat "$T/rex-stops")" "rex/session:$role/block:$role"
  done
  assert_eq "$(cat "$STUB_DIR/calls.log")" ''
  _wslife_teardown
}

test_down_preserves_rex_agents_when_held_work_refuses_teardown() {
  _wslife_setup
  _wslife_worktree "$T/wt"
  local wt; wt="$(_wslife_solo "$T/wt")"
  printf 'work\n' > "$wt/scratch.txt"
  rex_agent_list() { printf discovery >> "$T/rex-calls"; return 1; }
  rex_agent_stop() { printf stop >> "$T/rex-calls"; }
  local out
  if out="$(cmd_ws_down alpha 2>&1)"; then
    echo 'workspace teardown bypassed held work'; _wslife_teardown; return 1
  fi
  assert_contains "$out" 'still has work that is neither pushed nor landed'
  [ ! -e "$T/rex-calls" ] || { echo 'Rex teardown began before the held-work check'; return 1; }
  _wslife_teardown
}

test_down_refuses_before_herdr_closes_when_rex_discovery_fails() {
  _wslife_setup
  rex_agent_list() { return 1; }
  if (cmd_ws_down alpha) >/dev/null 2>&1; then
    echo 'workspace teardown ignored failed Rex discovery'; _wslife_teardown; return 1
  fi
  assert_eq "$(cat "$STUB_DIR/calls.log")" ''
  _wslife_teardown
}

test_reset_does_not_start_up_after_a_rex_stop_failure() {
  _wslife_setup
  rex_agent_list() {
    jq -n --arg ws "$T/alpha" '{result:{agents:[{name:"owned",role:"solo",backend:"rex",workspace:$ws,pane_id:"rex/session:owned/block:owned"}]}}'
  }
  rex_agent_stop() { printf '%s\n' "$1" >> "$T/rex-stops"; return 1; }
  cmd_ws_up() { printf up >> "$T/up"; }
  if (cmd_ws_reset alpha) >/dev/null 2>&1; then
    echo 'reset succeeded after a Rex stop failure'; _wslife_teardown; return 1
  fi
  assert_eq "$(cat "$T/rex-stops")" rex/session:owned/block:owned
  [ ! -e "$T/up" ] || { echo 'reset launched despite a failed stop'; return 1; }
  assert_eq "$(cat "$STUB_DIR/calls.log")" ''
  _wslife_teardown
}

# FAN-OUT WAS RETIRED: `down` reads no delegation ledger. A ledger that cannot
# be read at all (here a directory where the file would be) changes nothing.
test_down_ignores_the_retired_delegation_ledger() {
  _wslife_setup
  cmd_ws_up alpha >/dev/null
  : >"$STUB_DIR/calls.log"
  mkdir -p "$T/alpha/.cel/delegations.json"
  printf '[{"id":"SENTINEL","state":"running"}]\n' > "$T/alpha/.cel/delegations.json/sentinel"
  local out; out="$(cmd_ws_down alpha)" || { _wslife_teardown; return 1; }
  assert_contains "$out" "closed"
  _wslife_teardown
}

# NOTHING HELD IS A YES: a workspace whose solo worktrees are clean closes its
# panes without --force.
test_down_proceeds_when_nothing_is_held() {
  _wslife_setup
  _wslife_worktree "$T/wt"
  _wslife_solo "$T/wt" >/dev/null
  cmd_ws_up alpha >/dev/null
  : >"$STUB_DIR/calls.log"
  local out; out="$(cmd_ws_down alpha)"
  assert_contains "$out" "closed"
  assert_contains "$(cat "$STUB_DIR/calls.log")" "workspace close"
  _wslife_teardown
}

test_reset_is_down_then_up_in_order() {
  _wslife_setup
  # Nothing held: reset must not refuse itself.
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

# --- ONE FACT, ONE READER ---------------------------------------------------
# `up`, `status` and the steward must resolve a product's orchestrator mode
# through ws_orchestrator_mode alone. A string `layout:` (a herdr layout id)
# says nothing about orchestrators, and a product's own `orchestrator: auto`
# must still be able to turn one ON.

_wslife_string_layout_yaml() { # a herdr layout id, plus a product opting IN
  cat <<'YAML'
name: alpha
kind: personal
org: someone
layout: dev
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
  - name: gizmo
    url: git@github.com:someone/gizmo.git
    prefix: GZ
YAML
}

# The three shapes of silence must resolve the SAME mode.
test_orchestrator_mode_has_one_default_whatever_shape_the_layout_has() {
  _wslife_setup
  local a="$T/none" b="$T/str" c="$T/obj" d
  mkdir -p "$a" "$b" "$c"
  printf 'name: none\n'                    >"$a/workspace.yaml"
  printf 'name: str\nlayout: dev\n'        >"$b/workspace.yaml"
  printf 'name: obj\nlayout:\n  panes: []\n' >"$c/workspace.yaml"
  for d in "$a" "$b" "$c"; do
    assert_eq "$(ws_orchestrator_mode "$d" bundle)" "$(printf 'manual\tdefault')"
  done
  _wslife_teardown
}

# A per-product declaration that cannot turn something ON is a trap.
test_a_product_may_opt_in_to_auto_and_not_only_out() {
  _wslife_setup
  _wslife_string_layout_yaml >"$T/alpha/workspace.yaml"
  assert_eq "$(ws_orchestrator_mode "$T/alpha" bundle)" "$(printf 'auto\tproduct')"
  assert_eq "$(ws_orchestrator_mode "$T/alpha" gadget)" "$(printf 'manual\tproduct')"
  assert_eq "$(wslife_orchestrators "$T/alpha")" "bundle"
  # ...and the other direction still holds: manual and none beat a
  # workspace-wide auto, and an undeclared product inherits the layout.
  _wslife_ws_yaml | sed 's/    orchestrator: manual/    orchestrator: none/' \
    >"$T/alpha/workspace.yaml"
  assert_eq "$(ws_orchestrator_mode "$T/alpha" gadget)" "$(printf 'none\tproduct')"
  assert_eq "$(wslife_orchestrators "$T/alpha")" "bundle"
  _wslife_ws_yaml | grep -v 'orchestrator: auto$' >"$T/alpha/workspace.yaml"
  assert_eq "$(ws_orchestrator_mode "$T/alpha" bundle)" "$(printf 'auto\tlayout')"
  _wslife_teardown
}

# `layout: <string>` plus a product declaring `orchestrator: auto`: `up`
# starts it, and every surface says where the mode came from.
test_up_and_status_name_the_source_of_the_effective_mode() {
  _wslife_setup
  _wslife_string_layout_yaml >"$T/alpha/workspace.yaml"
  local dry st; dry="$(cmd_ws_up alpha --dry-run)"
  assert_contains "$dry" "would start"
  assert_contains "$dry" "auto via product"
  assert_eq "$(cat "$STUB_DIR/calls.log")" ""

  st="$(cmd_ws_status alpha)"
  assert_contains "$st" "declared auto via product"
  assert_contains "$st" "declared manual via product"
  assert_eq "$(printf '%s' "$(cmd_ws_status alpha --json)" | jq -r \
    '.workspaces[0].members[] | select(.name=="bundle-orch") | .source')" "product"

  cmd_ws_up alpha >/dev/null
  assert_contains "$(cat "$STUB_DIR/calls.log")" "agent start bundle-orch"
  ! grep -q 'agent start gadget-orch' "$STUB_DIR/calls.log" \
    || { echo "a manual product was started"; _wslife_teardown; return 1; }
  _wslife_teardown
}

# herdr tabs default to a bare number. `up` names any numbered tab in
# a workspace it owns from what is in it - here, the agent living there.
test_up_names_a_numbered_tab_from_what_is_in_it() {
  _wslife_setup
  cmd_ws_up alpha >/dev/null
  local id; id="$(jq -r '.[0].workspace_id' "$STUB_DIR/workspaces.json")"
  jq -c --arg id "$id" 'map(if .workspace_id == $id then .tabs += [{tab_id: ($id + ":t9"), label: "3", pane_id: ($id + ":p9"), cwd: "/tmp"}] else . end)' \
    "$STUB_DIR/workspaces.json" >"$STUB_DIR/w.tmp" && mv "$STUB_DIR/w.tmp" "$STUB_DIR/workspaces.json"
  _wslife_put_agent widget-wg-1-x "$id:p9" /tmp
  : >"$STUB_DIR/calls.log"
  cmd_ws_up alpha >/dev/null
  assert_eq "$(grep -c '^tab rename' "$STUB_DIR/calls.log")" 1
  assert_contains "$(cat "$STUB_DIR/calls.log")" "tab rename $id:t9 widget-wg-1-x"
  _wslife_teardown
}
