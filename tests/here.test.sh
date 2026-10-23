# shellcheck shell=bash
# cel here: the in-agent /cel-* commands, scoped to the pane's own product.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/here.sh"

# Workspace `bundled`: product `bundle` over widget+gadget, implicit `lone`.
# The verbs' commands are recorded, not run.
_hws() {
  T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-products/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget" "$T/repos/gadget" "$T/repos/lone" "$T/.cel"
  export CEL_REGISTRY="$T/registry.yaml"
  printf 'workspaces:\n  bundled:\n    path: %s\n' "$T" > "$CEL_REGISTRY"
  _here_cel() { printf 'cel %s\n' "$*" >> "$T/calls"; }
  _here_fanout() { printf 'cel-fanout %s\n' "$*" >> "$T/calls"; }
}
# <role> <me> <verb> [args...] - as the agent of that role would run it
_as() {
  local role="$1" me="$2"; shift 2
  ( cd /tmp && CEL_ROLE="$role" CEL_INBOX_ME="$me" CEL_INBOX_WS=bundled cmd_here "$@" )
}

test_here_scopes_a_product_agent_to_its_own_product() {
  _hws
  _as orchestrator bundle-orch mode >/dev/null
  _as orchestrator bundle-orch status >/dev/null
  _as orchestrator bundle-orch decide >/dev/null
  _as orchestrator bundle-orch inbox >/dev/null
  assert_eq "$(sed -n 1p "$T/calls")" "cel mode bundle --workspace bundled"
  assert_eq "$(sed -n 2p "$T/calls")" "cel fleet --workspace bundled"
  assert_eq "$(sed -n 3p "$T/calls")" "cel decide list --workspace bundled --asker bundle-orch"
  assert_eq "$(sed -n 4p "$T/calls")" "cel inbox read --for bundle-orch --all-workspaces"
  rm -rf "$T"
}

# Core stands in no product: it names one (found through the registry), reads
# root's mail and every decision, and never reviews or lands.
test_here_core_names_a_product_and_reads_root() {
  _hws
  _as core "" mode >/dev/null 2>&1 && { echo "core switched a mode without naming a product"; rm -rf "$T"; return 1; }
  _as core "" mode lone solo >/dev/null
  _as core "" status >/dev/null
  _as core "" inbox >/dev/null
  _as core "" decide >/dev/null
  assert_eq "$(sed -n 1p "$T/calls")" "cel mode lone solo --workspace bundled"
  assert_eq "$(sed -n 2p "$T/calls")" "cel fleet"
  assert_eq "$(sed -n 3p "$T/calls")" "cel inbox read --for root --all-workspaces"
  assert_eq "$(sed -n 4p "$T/calls")" "cel decide list"
  assert_contains "$(_as core "" land 3 2>&1)" "core does not land"
  assert_contains "$(_as core "" review 3 2>&1)" "core does not start reviewers"
  rm -rf "$T"
}

test_here_core_must_disambiguate_a_product_in_two_workspaces() {
  _hws
  local U; U="$(mktemp -d)"
  yq -y '.name = "other"' "$T/workspace.yaml" > "$U/workspace.yaml"
  printf 'workspaces:\n  bundled:\n    path: %s\n  other:\n    path: %s\n' "$T" "$U" > "$CEL_REGISTRY"
  assert_contains "$(_as core "" mode bundle 2>&1)" "say which: <workspace>/bundle"
  _as core "" mode other/bundle >/dev/null
  assert_eq "$(cat "$T/calls")" "cel mode bundle --workspace other"
  rm -rf "$T" "$U"
}

test_here_is_refused_to_workers_and_reviewers() {
  _hws
  assert_contains "$(_as worker "" status 2>&1)" "for core and product agents"
  assert_contains "$(_as reviewer "" land 3 2>&1)" "for core and product agents"
  [ ! -s "$T/calls" ] || { echo "a worker ran: $(cat "$T/calls")"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A bare PR number means the product's one repo; a product of two must say
# which, and a repo outside the product is refused.
test_here_review_resolves_the_repo_within_the_product() {
  _hws
  assert_contains "$(_as orchestrator bundle-orch review 7 2>&1)" "say which: <repo>#7"
  assert_contains "$(_as orchestrator bundle-orch review lone#7 2>&1)" "lone is not a repo of bundle"
  assert_contains "$(_as orchestrator bundle-orch review 'widget#x' 2>&1)" "not a PR number"
  _as orchestrator bundle-orch review 'gadget#7' >/dev/null
  _as orchestrator lone-orch review 9 >/dev/null
  assert_eq "$(sed -n 1p "$T/calls")" "cel run reviewer --repo gadget --pr 7 --workspace bundled"
  assert_eq "$(sed -n 2p "$T/calls")" "cel run reviewer --repo lone --pr 9 --workspace bundled"
  rm -rf "$T"
}

# Landing takes the product's checked path: solo -> cel solo land; fleet ->
# cel-fanout land on the delegation whose branch is the PR's head.
test_here_land_takes_the_checked_path_for_the_mode() {
  _hws
  local B; B="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho ABC-3-fix\n' > "$B/gh"; chmod +x "$B/gh"
  printf '[{"id":"ABC-2-old","repo":"lone","branch":"ABC-2-old"},{"id":"ABC-3-fix","repo":"lone","branch":"ABC-3-fix"}]\n' > "$T/.cel/delegations.json"
  ws_repo_github_slug() { printf 'someone/%s' "$2"; }
  PATH="$B:$PATH" _as orchestrator lone-orch land 3 --gate-from-ci >/dev/null
  assert_eq "$(sed -n 1p "$T/calls")" "cel-fanout land ABC-3-fix --workspace bundled --gate-from-ci"
  printf '#!/usr/bin/env bash\necho ABC-9-stray\n' > "$B/gh"
  assert_contains "$(PATH="$B:$PATH" _as orchestrator lone-orch land 9 2>&1)" "has no delegation on the ledger"
  ws_build_mode() { printf solo; }
  _as solo lone-orch land 4 >/dev/null
  assert_eq "$(sed -n 2p "$T/calls")" "cel solo land lone#4 --workspace bundled"
  rm -rf "$T" "$B"
}

# A product agent acts on its own product only: naming a sibling (whose mode
# switch would restart that sibling's agent) is core's job.
test_here_a_product_agent_cannot_act_on_another_product() {
  _hws
  assert_contains "$(_as orchestrator bundle-orch mode lone solo 2>&1)" "acts on bundle only"
  assert_contains "$(_as solo bundle-orch status lone 2>&1)" "acts on bundle only"
  [ ! -s "$T/calls" ] || { echo "a sibling's product was touched: $(cat "$T/calls")"; rm -rf "$T"; return 1; }
  _as orchestrator bundle-orch mode bundled/bundle >/dev/null
  assert_eq "$(cat "$T/calls")" "cel mode bundle --workspace bundled"
  rm -rf "$T"
}

# /cel-restart never restarts inline (that would kill the turn that asked): it
# schedules the same waiter `cel mode` uses - for core, core's own.
test_here_restart_is_scheduled_for_the_end_of_the_turn() {
  _hws
  _rec() { printf '%s\n' "$*" >> "$T/launched"; }
  ( export CEL_MODE_LAUNCH=_rec; _as orchestrator bundle-orch restart ) >/dev/null
  ( export CEL_MODE_LAUNCH=_rec; _as core "" restart ) >/dev/null
  assert_contains "$(sed -n 1p "$T/launched")" "mode --restart-when-idle bundle --workspace bundled"
  assert_contains "$(sed -n 2p "$T/launched")" "here --restart-core-when-idle"
  rm -rf "$T"
}

# Core's waiter: two quiet polls, then `cel run core --restart`. It is core's
# alone: any other pane asking for it is refused.
test_here_core_waiter_restarts_core_after_two_quiet_polls() {
  _hws
  export CEL_CORE_DIR="$T/core"
  local seq="$T/statuses"; printf 'working\nidle\nidle\n' > "$seq"
  _here_core_status() { local s; s="$(head -1 "$seq")"; sed -i 1d "$seq"; printf '%s' "$s"; }
  cmd_run() { printf '%s\n' "$*" >> "$T/relaunched"; }
  assert_contains "$(_as orchestrator bundle-orch --restart-core-when-idle 2>&1)" "only core"
  [ ! -s "$T/relaunched" ] || { echo "a product agent relaunched core"; rm -rf "$T"; return 1; }
  ( CEL_MODE_POLL_SECS=0 CEL_ROLE=core cmd_here --restart-core-when-idle ) >/dev/null
  assert_eq "$(cat "$T/relaunched")" "core --restart"
  unset CEL_CORE_DIR
  rm -rf "$T"
}

# The extension registers /cel-* only for agents that own a product or the
# box, runs `cel here <verb>`, and posts the output without starting a turn.
test_here_commands_register_for_product_agents_and_core_only() {
  local role out
  for role in orchestrator core worker; do
    out="$(CEL_ROLE="$role" CEL_INBOX_HOOK=1 HOOK="$CEL_ROOT/tools/hooks/inbox.omp.ts" node --no-warnings - <<'JS'
(async () => {
  const cmds = {}; const sent = [];
  const pi = { on() {}, registerCommand(n, o) { cmds[n] = o; }, sendMessage(m, o) { sent.push({ m, o }); } };
  (await import(process.env.HOOK)).default(pi);
  if (cmds["cel-mode"]) await cmds["cel-mode"].handler("", { cwd: "/tmp", ui: { notify() {} } });
  console.log(JSON.stringify({ names: Object.keys(cmds).sort(), sent }));
  process.exit(0);
})();
JS
)"
    case "$role" in
      worker) assert_eq "$(jq -c .names <<< "$out")" "[]" ;;
      core)   assert_contains "$(jq -c .names <<< "$out")" '"cel-focus"'
              assert_eq "$(jq -r '.sent[0].o.triggerTurn' <<< "$out")" false
              # core named no product: the refusal is what reaches the conversation
              assert_contains "$(jq -r '.sent[0].m.content' <<< "$out")" "name a product" ;;
      *)      assert_eq "$(jq -c .names <<< "$out")" \
                '["cel-decide","cel-inbox","cel-land","cel-mode","cel-restart","cel-review","cel-status"]' ;;
    esac
  done
}
