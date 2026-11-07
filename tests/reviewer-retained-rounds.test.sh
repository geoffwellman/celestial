# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/run.sh"

_rrp_setup() {
  RRP_T="$(mktemp -d)"
  export HOME="$RRP_T/home" CEL_REVIEW_DIR="$RRP_T/reviews" CEL_REX_STATE="$RRP_T/rex"
  export CEL_REVIEWERS_STATE="$RRP_T/reviewers.json" CEL_REGISTRY="$RRP_T/registry.yaml" CEL_CONFIG_FILE="$RRP_T/no-config"
  RRP_WS="$RRP_T/workspace"; RRP_REPO="$RRP_WS/repos/widget"
  mkdir -p "$HOME" "$RRP_REPO" "$CEL_REX_STATE" "$CEL_REVIEW_DIR"
  cat > "$RRP_WS/workspace.yaml" <<'YAML'
name: demo
runtime: {orchestrator: pi}
review: {runtime: pi, model: fixture/native}
repos:
  - name: widget
    url: git@github.com:acme/widget.git
YAML
  registry_add demo "$RRP_WS" ''
  git -C "$RRP_REPO" init -q
  printf 'reviewed source\n' > "$RRP_REPO/source.txt"
  git -C "$RRP_REPO" add source.txt
  git -C "$RRP_REPO" -c user.email=fixture@example.invalid -c user.name=Fixture commit -qm base
  RRP_HEAD="$(git -C "$RRP_REPO" rev-parse HEAD)"
  printf '{"result":{"agents":[]}}\n' > "$RRP_T/roster.json"
  cel_agent_list() { cat "$RRP_T/roster.json"; }
}
_rrp_down() { rm -rf "$RRP_T"; }

test_reviewer_fresh_round_preserves_prior_checkout_and_unsaved_artifacts() {
  _rrp_setup
  local base round
  base="$(reviewer_checkout_path widget 71)"
  git -C "$RRP_REPO" worktree add -q --detach "$base" "$RRP_HEAD"
  printf 'private review evidence\n' > "$base/private-evidence.txt"
  round="$(reviewer_checkout_make "$RRP_REPO" widget 71 "$RRP_HEAD")"
  [ "$round" != "$base" ] || { _rrp_down; return 1; }
  assert_eq "$(cat "$base/private-evidence.txt")" 'private review evidence'
  assert_eq "$(git -C "$base" rev-parse HEAD)" "$RRP_HEAD"
  assert_eq "$(git -C "$round" rev-parse HEAD)" "$RRP_HEAD"
  assert_eq "$(git -C "$RRP_REPO" worktree list --porcelain | grep -c '^worktree ')" 3
  _rrp_down
}

test_reviewer_unnamed_retained_round_blocks_duplicate_even_without_original_path() {
  _rrp_setup
  local base round
  base="$(reviewer_checkout_path widget 71)"; round="$base.round.fixture"
  git -C "$RRP_REPO" worktree add -q --detach "$round" "$RRP_HEAD"
  printf 'active review evidence\n' > "$round/private-evidence.txt"
  jq -n --arg cwd "$round" '{result:{agents:[{name:"",agent:"pi",backend:"herdr",pane_id:"window:review",cwd:$cwd,agent_status:"working"}]}}' > "$RRP_T/roster.json"
  assert_fails reviewer_checkout_make "$RRP_REPO" widget 71 "$RRP_HEAD"
  assert_eq "$(git -C "$RRP_REPO" worktree list --porcelain | grep -c '^worktree ')" 2
  assert_eq "$(cat "$round/private-evidence.txt")" 'active review evidence'
  [ ! -e "$base" ] || { _rrp_down; return 1; }
  _rrp_down
}

test_reviewer_unnamed_round_recovery_records_actual_checkout_not_prior_base() {
  _rrp_setup
  local base round row
  base="$(reviewer_checkout_path widget 71)"; round="$base.round.fixture"
  git -C "$RRP_REPO" worktree add -q --detach "$round" "$RRP_HEAD"
  jq -n --arg cwd "$round" '{result:{agents:[{name:"",agent:"pi",backend:"herdr",pane_id:"window:review",cwd:$cwd,agent_status:"idle"}]}}' > "$RRP_T/roster.json"
  cmd_run reviewer --repo widget --pr 71 --workspace demo >/dev/null
  row="$(reviewers_find "$RRP_WS" widget 71)"
  assert_eq "$(jq -r .checkout <<< "$row")" "$round"
  assert_eq "$(jq -r .pane <<< "$row")" window:review
  assert_eq "$(git -C "$RRP_REPO" worktree list --porcelain | grep -c '^worktree ')" 2
  _rrp_down
}

test_reviewer_malformed_round_inventory_cannot_authorize_checkout_creation() {
  _rrp_setup
  printf '{"result":{"agents":[{"name":"","pane_id":"window:unknown","cwd":7}]}}\n' > "$RRP_T/roster.json"
  assert_fails reviewer_checkout_make "$RRP_REPO" widget 71 "$RRP_HEAD"
  assert_eq "$(git -C "$RRP_REPO" worktree list --porcelain | grep -c '^worktree ')" 1
  [ ! -e "$(reviewer_checkout_path widget 71)" ] || { _rrp_down; return 1; }
  _rrp_down
}
