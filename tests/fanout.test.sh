# shellcheck shell=bash
# cel-fanout is an external binary (not a sourced lib), so every test shells
# out to it against a herdr stub that logs its argv and returns canned JSON.
source "$CEL_ROOT/lib/common.sh"
BIN="$CEL_ROOT/core/skills/fanout/bin/cel-fanout"

_fanout_setup() {
  T="$(mktemp -d)"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget"
  git -C "$T/repos/widget" init -q
  STUB_WT="$T/widget-worker"
  mkdir -p "$STUB_WT"
  git -C "$STUB_WT" init -q
  git -C "$STUB_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$STUB_WT" update-ref refs/remotes/origin/main HEAD
  git -C "$STUB_WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  STUB_REPO="$(git -C "$T/repos/widget" rev-parse --show-toplevel)"
  STUB_LOG="$T/stub.log"
  : > "$STUB_LOG"
  STUB="$T/herdr-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$STUB_LOG"
case "$1 $2" in
  "worktree create") echo '{"result":{"workspace_id":"wZ","pane_id":"wZ:p1","checkout_path":"'"$STUB_WT"'"}}';;
  "workspace list")  if [ -n "${STUB_NO_WS:-}" ]; then echo '{"result":{"workspaces":[]}}'; else echo '{"result":{"workspaces":[{"workspace_id":"wY","worktree":{"repo_root":"'"$STUB_REPO"'","is_linked_worktree":false}}]}}'; fi;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wC","label":"widget/workers"}}}';;
  "pane split")      echo '{"result":{"pane":{"pane_id":"wZ:p9"}}}';;
  "agent list")      if [ -n "${STUB_AGENTS_FAIL:-}" ]; then exit 1;
                     elif [ -n "${STUB_AGENTS_JSON:-}" ]; then printf '%s' "$STUB_AGENTS_JSON";
                     elif [ -n "${STUB_AGENTS_EMPTY:-}" ]; then echo '{"result":{"agents":[]}}';
                     else echo '{"result":{"agents":[{"pane_id":"wZ:p1","agent_status":"'"${STUB_STATUS:-idle}"'"}]}}'; fi;;
  *) echo '{}';;
esac
EOF
  chmod +x "$STUB"
  export CEL_FANOUT_HERDR="$STUB"
  export STUB_LOG STUB_WT STUB_REPO
  printf 'do the thing\n' > "$T/spec.md"
}

# A dead agent must not leave its row reading `running` forever: finished work
# would sit invisible and abandoned work would look healthy. Both were observed.
test_status_marks_finished_when_agent_gone_and_result_exists() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-FIN "$T/spec.md") > /dev/null
  mkdir -p "$STUB_WT/.agent" && printf 'done\n' > "$STUB_WT/.agent/result.md"
  local out; out="$(cd "$T" && STUB_AGENTS_EMPTY=1 "$BIN" status)"
  assert_contains "$out" "finished"
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "finished"
  rm -rf "$T"
}

test_status_marks_orphaned_when_agent_gone_and_no_result() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-ORPH "$T/spec.md") > /dev/null
  rm -f "$STUB_WT/.agent/result.md"
  local out; out="$(cd "$T" && STUB_AGENTS_EMPTY=1 "$BIN" status)"
  assert_contains "$out" "orphaned"
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "orphaned"
  rm -rf "$T"
}

# herdr being unreachable is not evidence anyone died: a failed agent list
# must leave running rows untouched instead of reconciling them all.
test_status_keeps_running_when_agent_list_fails() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-HERDRDOWN "$T/spec.md") > /dev/null
  mkdir -p "$STUB_WT/.agent" && printf 'done\n' > "$STUB_WT/.agent/result.md"
  (cd "$T" && STUB_AGENTS_FAIL=1 "$BIN" status) > /dev/null
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "running"
  rm -rf "$T"
}

# A row reconciled to finished/orphaned is settled: wait must return it
# instead of polling a pane that no longer exists.
test_wait_returns_reconciled_id() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-REC "$T/spec.md") > /dev/null
  mkdir -p "$STUB_WT/.agent" && printf 'done\n' > "$STUB_WT/.agent/result.md"
  (cd "$T" && STUB_AGENTS_EMPTY=1 "$BIN" status) > /dev/null
  local id; id="$(cd "$T" && "$BIN" wait --timeout 2000)"
  assert_eq "$id" "WG-REC"
  rm -rf "$T"
}

# A LIVE agent is always believed over the disk — a working agent that has
# already written a result.md is still working.
test_status_leaves_running_row_alone_while_agent_is_live() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-LIVE "$T/spec.md") > /dev/null
  mkdir -p "$STUB_WT/.agent" && printf 'done\n' > "$STUB_WT/.agent/result.md"
  (cd "$T" && STUB_STATUS=working "$BIN" status) > /dev/null
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "running"
  rm -rf "$T"
}

# A row the operator already dealt with is not re-opened by a missing agent.
test_status_does_not_reopen_a_collected_row() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-COLL "$T/spec.md") > /dev/null
  mkdir -p "$STUB_WT/.agent" && printf 'done\n' > "$STUB_WT/.agent/result.md"
  (cd "$T" && "$BIN" collect WG-COLL) > /dev/null
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "collected"
  (cd "$T" && STUB_AGENTS_EMPTY=1 "$BIN" status) > /dev/null
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "collected"
  rm -rf "$T"
}

# The worktree must be cut from the REMOTE default, never from whatever the
# checkout is parked on — a contaminated base put two stray commits onto seven
# ticket branches before this was fixed.
test_delegate_branches_from_origin_default_when_reachable() {
  _fanout_setup
  # Give the fixture repo a commit and an origin/main to branch from.
  git -C "$T/repos/widget" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T/repos/widget" update-ref refs/remotes/origin/main HEAD
  git -C "$T/repos/widget" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  (cd "$T" && "$BIN" delegate widget WG-BASE "$T/spec.md") > /dev/null
  local wc; wc="$(grep '^worktree create' "$STUB_LOG" | head -1)"
  assert_contains "$wc" "--base origin/main"
  rm -rf "$T"
}

# A master-only remote with no origin/HEAD must resolve to origin/master -
# hard-coding main here either picked an unrelated branch or dropped the base
# entirely. The resolved base must also reach the
# worker's pre-push check, or it validates against a ref that may not exist.
test_delegate_resolves_master_default_without_origin_head() {
  _fanout_setup
  git -C "$T/repos/widget" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T/repos/widget" update-ref refs/remotes/origin/master HEAD
  (cd "$T" && "$BIN" delegate widget WG-MASTER "$T/spec.md") > /dev/null
  local log; log="$(cat "$STUB_LOG")"
  assert_contains "$(grep '^worktree create' <<<"$log" | head -1)" "--base origin/master"
  assert_contains "$log" "git log --oneline origin/master..HEAD"
  rm -rf "$T"
}

# A branch that already exists on origin is continued from ORIGIN'S tip, not
# from whatever stale local ref shares its name - that reuse nearly
# force-pushed over an arm commit.
test_delegate_bases_existing_branch_on_origin_tip() {
  _fanout_setup
  git -C "$T/repos/widget" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T/repos/widget" update-ref refs/remotes/origin/main HEAD
  git -C "$T/repos/widget" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  # local WG-OLD parked at base; origin's copy one commit ahead
  git -C "$T/repos/widget" branch WG-OLD HEAD
  git -C "$T/repos/widget" -c user.email=t@t -c user.name=t commit -q --allow-empty -m ahead
  git -C "$T/repos/widget" update-ref refs/remotes/origin/WG-OLD HEAD
  (cd "$T" && "$BIN" delegate widget WG-OLD "$T/spec.md") > /dev/null
  assert_contains "$(grep '^worktree create' "$STUB_LOG" | head -1)" "--base origin/WG-OLD"
  rm -rf "$T"
}
# ...but a local ref that DIVERGED from origin's is unreconciled work on both
# sides: delegate must refuse with both shas, never silently pick one.
test_delegate_refuses_diverged_local_branch() {
  _fanout_setup
  git -C "$T/repos/widget" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T/repos/widget" update-ref refs/remotes/origin/main HEAD
  git -C "$T/repos/widget" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$T/repos/widget" -c user.email=t@t -c user.name=t commit -q --allow-empty -m origin-side
  git -C "$T/repos/widget" update-ref refs/remotes/origin/WG-DIV HEAD
  git -C "$T/repos/widget" checkout -q -b WG-DIV HEAD~1
  git -C "$T/repos/widget" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local-side
  git -C "$T/repos/widget" checkout -q -
  local out; out="$( (cd "$T" && "$BIN" delegate widget WG-DIV "$T/spec.md") 2>&1 )" && \
    { echo "delegate should have refused: $out"; return 1; }
  assert_contains "$out" "DIVERGED"
  assert_contains "$out" "$(git -C "$T/repos/widget" rev-parse refs/heads/WG-DIV)"
  assert_contains "$out" "$(git -C "$T/repos/widget" rev-parse refs/remotes/origin/WG-DIV)"
  rm -rf "$T"
}

# Offline or origin-less repos must still delegate — falling back to herdr's
# default is worse than a rebase, but refusing to delegate is worse than both.
test_delegate_omits_base_when_origin_unreachable() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-NOBASE "$T/spec.md") > /dev/null
  local wc; wc="$(grep '^worktree create' "$STUB_LOG" | head -1)"
  case "$wc" in *--base*) echo "unexpected --base with no origin: $wc"; return 1;; esac
  rm -rf "$T"
}


# `policy.pr_open: ready` flips the prompt to a ready-for-review PR and names the
# workspace reviewer - a draft is invisible to a reviewer bot that ignores drafts.
test_delegate_prompt_ready_pr_when_policy_says_so() {
  _fanout_setup
  yq -y -i '.policy.pr_open = "ready" | .policy.reviewer = "review-bot"' "$T/workspace.yaml"
  (cd "$T" && "$BIN" delegate widget WG-RDY "$T/spec.md") > /dev/null
  local pr; pr="$(cat "$STUB_LOG")"
  assert_contains "$pr" "READY FOR REVIEW"
  assert_contains "$pr" "requesting reviewer review-bot"
  if printf '%s' "$pr" | grep -q "DRAFT pull request"; then fail "ready policy still asked for a draft"; fi
  rm -rf "$T"
}

test_delegate_refuses_unknown_pr_open() {
  _fanout_setup
  yq -y -i '.policy.pr_open = "sometimes"' "$T/workspace.yaml"
  if (cd "$T" && "$BIN" delegate widget WG-BAD "$T/spec.md") > /dev/null 2>&1; then
    fail "unknown pr_open value was accepted"
  fi
  rm -rf "$T"
}

test_delegate_writes_ledger_and_calls_herdr_in_order() {
  _fanout_setup
  local id; id="$(cd "$T" && "$BIN" delegate widget WG-1-x "$T/spec.md")"
  assert_eq "$id" "WG-1-x"

  local log wc_line ast_line apr_line
  log="$(cat "$STUB_LOG")"
  wc_line="$(grep -n '^worktree create' <<<"$log" | head -1 | cut -d: -f1)"
  ast_line="$(grep -n '^agent start' <<<"$log" | head -1 | cut -d: -f1)"
  apr_line="$(grep -n '^agent prompt' <<<"$log" | head -1 | cut -d: -f1)"
  [ -n "$wc_line" ] || { echo "no worktree create call: $log"; return 1; }
  [ -n "$ast_line" ] || { echo "no agent start call: $log"; return 1; }
  [ -n "$apr_line" ] || { echo "no agent prompt call: $log"; return 1; }
  [ "$wc_line" -lt "$ast_line" ] || { echo "worktree create not before agent start: $log"; return 1; }
  [ "$ast_line" -lt "$apr_line" ] || { echo "agent start not before agent prompt: $log"; return 1; }

  # the agent name is herdr-legal (no slash/uppercase) and the multi-line role
  # body travels as a file path, not an inline argument
  assert_contains "$log" "agent start widget-wg-1-x"
  assert_contains "$log" "--append-system-prompt $T/.cel/role-worker.md"

  local ledger; ledger="$(cat "$T/.cel/delegations.json")"
  assert_eq "$(printf '%s' "$ledger" | jq -r '.[0].id')" "WG-1-x"
  assert_eq "$(printf '%s' "$ledger" | jq -r '.[0].state')" "running"
  assert_eq "$(printf '%s' "$ledger" | jq -r '.[0].repo')" "widget"
  rm -rf "$T"
}

test_delegate_outside_workspace_dies() {
  _fanout_setup
  ( cd /tmp && assert_fails "$BIN" delegate widget WG-1-x "$T/spec.md" )
  rm -rf "$T"
}

test_wait_returns_settled_id() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-1-x "$T/spec.md" >/dev/null)
  local id; id="$(cd "$T" && "$BIN" wait)"
  assert_eq "$id" "WG-1-x"
  rm -rf "$T"
}

test_collect_reads_result_md() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-1-x "$T/spec.md" >/dev/null)
  mkdir -p "$STUB_WT/.agent"
  printf '# Result\nall good\n' > "$STUB_WT/.agent/result.md"
  local out; out="$(cd "$T" && "$BIN" collect WG-1-x)"
  assert_contains "$out" "all good"
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "collected"
  rm -rf "$T"
}

test_collect_salvages_when_result_missing() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-1-x "$T/spec.md" >/dev/null)
  (cd "$T" && "$BIN" collect WG-1-x >/dev/null 2>&1)
  [ -f "$T/.cel/salvage-WG-1-x.txt" ] || { echo "no salvage file written"; return 1; }
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "salvaged"
  rm -rf "$T"
}

test_release_removes_worktree_and_marks() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-1-x "$T/spec.md" >/dev/null)
  (cd "$T" && "$BIN" release WG-1-x)
  assert_contains "$(cat "$STUB_LOG")" "worktree remove --workspace wZ"
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "released"

  (cd "$T" && "$BIN" delegate widget WG-2-x "$T/spec.md" >/dev/null)
  : > "$STUB_LOG"
  (cd "$T" && "$BIN" release WG-2-x --keep-worktree)
  case "$(cat "$STUB_LOG")" in
    *"worktree remove"*) echo "unexpected worktree remove with --keep-worktree"; return 1;;
  esac
  assert_eq "$(jq -r '.[1].state' "$T/.cel/delegations.json")" "released"
  rm -rf "$T"
}

test_status_lists_delegations() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-1-x "$T/spec.md" >/dev/null)
  local out; out="$(cd "$T" && "$BIN" status)"
  assert_contains "$out" "WG-1-x"
  assert_contains "$out" "widget"
  assert_contains "$out" "running"
  rm -rf "$T"
}

# ---- the ticket gate -------------------------------------------------------
# Work with no ticket is invisible: Linear attaches a PR to its ticket purely
# from the branch name, so an unticketed branch can never appear on the board.
# Measured on a live box, 15 of 15 agent-opened PRs carried no ticket, because
# "one ticket per work package" was advice while the mechanism took any name.

# ws-alpha declares `tickets: {system: none}`, so the gate must stay dormant
# there - these set it to linear explicitly.
_fanout_linear_setup() {
  _fanout_setup
  yq -y '.tickets.system = "linear"' "$T/workspace.yaml" > "$T/ws.tmp" 2>/dev/null \
    && mv "$T/ws.tmp" "$T/workspace.yaml"
  LINEAR_LOG="$T/linear.log"; : > "$LINEAR_LOG"
  LINEAR_STUB="$T/cel-linear-stub.sh"
  cat > "$LINEAR_STUB" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$LINEAR_LOG"
EOF
  chmod +x "$LINEAR_STUB"
  export CEL_FANOUT_LINEAR="$LINEAR_STUB" LINEAR_LOG
}

test_delegate_refuses_a_branch_with_no_ticket() {
  _fanout_linear_setup
  local out; out="$( (cd "$T" && "$BIN" delegate widget scratch-no-ticket "$T/spec.md") 2>&1 )" && {
    echo "delegate accepted an unticketed branch"; rm -rf "$T"; return 1; }
  assert_contains "$out" "names no WG ticket"
  assert_contains "$out" "cel-linear search"
  # and it must refuse BEFORE any side effect - no worktree was cut
  [ ! -s "$STUB_LOG" ] || { echo "gate ran after herdr was called"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_delegate_accepts_a_ticketed_branch_and_records_it() {
  _fanout_linear_setup
  (cd "$T" && "$BIN" delegate widget WG-12-do-the-thing "$T/spec.md") > /dev/null
  assert_eq "$(jq -r '.[0].ticket' "$T/.cel/delegations.json")" WG-12
  rm -rf "$T"
}

# The id is matched the way Linear matches it: anywhere in the name, any case.
# A colleague's `someone/wg-7-slug` links exactly as `WG-7-slug` does.
test_delegate_matches_a_ticket_id_anywhere_and_any_case() {
  _fanout_linear_setup
  (cd "$T" && "$BIN" delegate widget someone/wg-7-live "$T/spec.md") > /dev/null
  assert_eq "$(jq -r '.[0].ticket' "$T/.cel/delegations.json")" WG-7
  rm -rf "$T"
}

# In Progress must come from the mechanism, not from a worker remembering.
test_delegate_moves_the_ticket_to_in_progress() {
  _fanout_linear_setup
  (cd "$T" && "$BIN" delegate widget WG-12-x "$T/spec.md") > /dev/null
  assert_contains "$(cat "$LINEAR_LOG")" "state WG-12 In Progress"
  rm -rf "$T"
}

# The escape hatch has to exist, but it has to be DELIBERATE.
test_delegate_adhoc_opts_out_of_the_gate() {
  _fanout_linear_setup
  (cd "$T" && "$BIN" delegate widget scratch-throwaway "$T/spec.md" --adhoc) > /dev/null
  assert_eq "$(jq -r '.[0].ticket' "$T/.cel/delegations.json")" ""
  assert_eq "$(cat "$LINEAR_LOG")" ""
  rm -rf "$T"
}

# A workspace that does not use Linear must be completely unaffected.
test_delegate_gate_is_dormant_without_linear_tickets() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget scratch-local "$T/spec.md") > /dev/null
  assert_eq "$(jq -r '.[0].ticket' "$T/.cel/delegations.json")" ""
  rm -rf "$T"
}

# ---- team re-key (prefix aliases) ------------------------------------------
# A Linear team can be re-keyed (ABC -> ABCD) without renumbering its issues.
# Linear still resolves the old identifiers, but branches and worktrees cut
# before the rename keep their old names forever - so without aliases every
# in-flight branch would suddenly read as unticketed and be refused.
_fanout_rekey_setup() {
  _fanout_linear_setup
  yq -y '.repos[0].prefix = "WGT" | .repos[0].prefix_aliases = ["WG"]' \
    "$T/workspace.yaml" > "$T/ws.tmp" && mv "$T/ws.tmp" "$T/workspace.yaml"
}

test_prefixes_list_current_first_then_aliases() {
  # this suite otherwise only shells out to the binary, so the accessor has to
  # be pulled in explicitly
  source "$CEL_ROOT/lib/workspace.sh"
  _fanout_rekey_setup
  assert_eq "$(ws_repo_prefixes "$T" widget | tr '\n' ' ')" "WGT WG "
  rm -rf "$T"
}

test_delegate_accepts_a_branch_cut_before_the_rekey() {
  _fanout_rekey_setup
  (cd "$T" && "$BIN" delegate widget WG-12-old-name "$T/spec.md") > /dev/null
  # normalised to TODAY'S identifier, so every downstream state call speaks the
  # current key rather than a historical one
  assert_eq "$(jq -r '.[0].ticket' "$T/.cel/delegations.json")" WGT-12
  rm -rf "$T"
}

test_delegate_accepts_the_new_prefix_unchanged() {
  _fanout_rekey_setup
  (cd "$T" && "$BIN" delegate widget WGT-9-new "$T/spec.md") > /dev/null
  assert_eq "$(jq -r '.[0].ticket' "$T/.cel/delegations.json")" WGT-9
  rm -rf "$T"
}

# An alias must not become a loophole: a branch with no number is still no ticket.
test_rekey_aliases_do_not_weaken_the_gate() {
  _fanout_rekey_setup
  local out; out="$( (cd "$T" && "$BIN" delegate widget WGT-nonumber "$T/spec.md") 2>&1 )" && {
    echo "gate accepted a branch with no ticket number"; rm -rf "$T"; return 1; }
  assert_contains "$out" "names no WGT ticket"
  rm -rf "$T"
}

# Re-delegating a branch must REPLACE its ledger row, not add a second. The
# reader takes the first match, so a duplicate means every later collect and
# release acts on the STALE row - its worktree, its state, its model.
test_redelegating_replaces_the_ledger_row() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-DUP "$T/spec.md") > /dev/null
  (cd "$T" && "$BIN" delegate widget WG-DUP "$T/spec.md") > /dev/null
  assert_eq "$(jq -r '[.[] | select(.id=="WG-DUP")] | length' "$T/.cel/delegations.json")" 1
  # and the row that survived is the NEW one, in `running`
  assert_eq "$(jq -r '.[] | select(.id=="WG-DUP") | .state' "$T/.cel/delegations.json")" running
  rm -rf "$T"
}

# ---- an occupied worktree path ---------------------------------------------
# `herdr worktree create` cannot make a worktree where one exists; it returns a
# PLAIN workspace with no worktree metadata. herdr then has no repo_root to
# nest it under, so it shows at top level with no parent - "homeless" - while
# the ledger records it as though it were the worktree, and `release` later
# removes nothing. Re-delegation after an orphan is routine, so this compounded
# on a live box until several worktrees were stranded.
_fanout_existing_wt() {
  _fanout_setup
  git -C "$T/repos/widget" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T/repos/widget" worktree add -q -b WG-TAKEN "$T/taken" >/dev/null 2>&1
}

test_delegate_refuses_an_occupied_worktree_path() {
  _fanout_existing_wt
  local out; out="$( (cd "$T" && "$BIN" delegate widget WG-TAKEN "$T/spec.md") 2>&1 )" && {
    echo "delegate proceeded onto an occupied path"; rm -rf "$T"; return 1; }
  assert_contains "$out" "already exists"
  assert_contains "$out" "--reuse"
  # and nothing was recorded, so the ledger never points at a bare workspace
  [ ! -f "$T/.cel/delegations.json" ] || \
    assert_eq "$(jq -r '[.[] | select(.id=="WG-TAKEN")] | length' "$T/.cel/delegations.json")" 0
  rm -rf "$T"
}

# --reuse without a herdr workspace holding that path is still a hard failure:
# guessing would re-create the bare-workspace problem.
test_reuse_fails_when_no_workspace_holds_the_path() {
  _fanout_existing_wt
  local out; out="$( (cd "$T" && "$BIN" delegate widget WG-TAKEN "$T/spec.md" --reuse) 2>&1 )" && {
    echo "reuse invented a workspace"; rm -rf "$T"; return 1; }
  assert_contains "$out" "no herdr workspace holds it"
  rm -rf "$T"
}

# A create that comes back with no checkout path did not attach a worktree, and
# must fail loudly rather than be recorded as a delegation.
test_delegate_fails_when_create_attaches_no_worktree() {
  _fanout_setup
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$STUB_LOG"
case "$1 $2" in
  "worktree create") echo '{"result":{"workspace_id":"wBARE","pane_id":"wBARE:p1"}}';;
  "workspace list")  echo '{"result":{"workspaces":[{"workspace_id":"wY","worktree":{"repo_root":"'"$STUB_REPO"'","is_linked_worktree":false}}]}}';;
  *) echo '{}';;
esac
EOF
  chmod +x "$STUB"
  local out; out="$( (cd "$T" && "$BIN" delegate widget WG-BARE "$T/spec.md") 2>&1 )" && {
    echo "recorded a delegation with no worktree"; rm -rf "$T"; return 1; }
  assert_contains "$out" "did not attach a worktree"
  rm -rf "$T"
}

# ---- fail-closed release ---------------------------------------------------
# Three worktrees had their uncommitted work hand-salvaged to patches in one
# day because release removed whatever it was pointed at. Releasing is not
# landing: a worktree with unpushed commits or uncommitted changes is work,
# and destroying it needs the word for it.
_fanout_dirty_release() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-DIRTY "$T/spec.md") > /dev/null
  git -C "$STUB_WT" init -q
  printf 'unsaved\n' > "$STUB_WT/work.txt"
}
test_release_refuses_a_dirty_worktree() {
  _fanout_dirty_release
  local out; out="$( (cd "$T" && "$BIN" release WG-DIRTY) 2>&1 )" && {
    echo "release removed a dirty worktree"; rm -rf "$T"; return 1; }
  assert_contains "$out" "dirty=1"
  assert_contains "$out" "--discard"
  ! grep -q "^worktree remove" "$STUB_LOG" || { echo "herdr remove was called"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" running
  rm -rf "$T"
}
test_release_discard_is_explicit_and_logged() {
  _fanout_dirty_release
  local out; out="$( (cd "$T" && "$BIN" release WG-DIRTY --discard) 2>&1 )"
  assert_contains "$out" "DISCARDED"
  grep -q "^worktree remove" "$STUB_LOG" || { echo "discard did not remove"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" released
  rm -rf "$T"
}
# --keep-worktree never removes anything, so held work is not a reason to stop.
test_release_keep_worktree_ignores_held_work() {
  _fanout_dirty_release
  (cd "$T" && "$BIN" release WG-DIRTY --keep-worktree) > /dev/null
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" released
  rm -rf "$T"
}
test_release_of_a_clean_worktree_is_unchanged() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-CLEAN "$T/spec.md") > /dev/null
  (cd "$T" && "$BIN" release WG-CLEAN) > /dev/null
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" released
  rm -rf "$T"
}
# Unpushed commits count as held work even with a clean tree.
test_release_refuses_unpushed_commits() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-UNPUSHED "$T/spec.md") > /dev/null
  git -C "$STUB_WT" init -q && git -C "$STUB_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$STUB_WT" update-ref refs/remotes/origin/main HEAD
  git -C "$STUB_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m unpushed
  local out; out="$( (cd "$T" && "$BIN" release WG-UNPUSHED) 2>&1 )" && {
    echo "release removed unpushed commits"; rm -rf "$T"; return 1; }
  assert_contains "$out" "unpushed=1"
  rm -rf "$T"
}

# ---- land: the one merge path -----------------------------------------------
# Orchestrators are read-only over repositories; `land` is how a PR they judge
# ready actually merges, and it checks what a prompt cannot be trusted to:
# whose PR it is, the workspace's merge policy, review and checks.
_fanout_land_setup() { # <author> <review> <failing> [<draft>] [<state>]
  _fanout_setup
  yq -y '.policy.merge = "self"' "$T/workspace.yaml" > "$T/ws.tmp" && mv "$T/ws.tmp" "$T/workspace.yaml"
  (cd "$T" && "$BIN" delegate widget WG-LAND "$T/spec.md") > /dev/null
  GH_LOG="$T/gh.log"; : > "$GH_LOG"
  GH_STUB="$T/gh-stub.sh"
  cat > "$GH_STUB" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "api user") echo fleetbot;;
  "pr view")  echo '{"number":7,"author":{"login":"$1"},"reviewDecision":"$2","isDraft":${4:-false},"mergeable":"MERGEABLE","state":"${5:-OPEN}","statusCheckRollup":[{"conclusion":"$([ "$3" = 1 ] && echo FAILURE || echo SUCCESS)"}]}';;
  "pr merge") exit 0;;
  *) echo '{}';;
esac
EOF
  chmod +x "$GH_STUB"; export CEL_FANOUT_GH="$GH_STUB" GH_LOG
  # the fixture repo declares a gate, and land now refuses an unverified one:
  # a passing verdict by default, so tests about OTHER refusals still merge
  _fanout_verify_stub true
}
test_land_merges_an_approved_green_fleet_pr() {
  _fanout_land_setup fleetbot APPROVED 0
  (cd "$T" && "$BIN" land WG-LAND) > /dev/null
  grep -q "^pr merge 7" "$GH_LOG" || { echo "did not merge"; rm -rf "$T"; return 1; }
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" landed
  rm -rf "$T"
}
test_land_refuses_a_colleagues_pr() {
  _fanout_land_setup someone-else APPROVED 0
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )" && { echo "merged a colleague's PR"; rm -rf "$T"; return 1; }
  assert_contains "$out" "theirs to land"
  ! grep -q "^pr merge" "$GH_LOG" || { echo "merge was called"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_land_refuses_without_approval() {
  _fanout_land_setup fleetbot CHANGES_REQUESTED 0
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )" && { echo "merged unapproved"; rm -rf "$T"; return 1; }
  assert_contains "$out" "not approved"; rm -rf "$T"
}
test_land_refuses_a_red_gate() {
  _fanout_land_setup fleetbot APPROVED 1
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )" && { echo "merged with failing checks"; rm -rf "$T"; return 1; }
  assert_contains "$out" "failing check"; rm -rf "$T"
}
test_land_refuses_a_draft() {
  _fanout_land_setup fleetbot APPROVED 0 true
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )" && { echo "merged a draft"; rm -rf "$T"; return 1; }
  assert_contains "$out" "draft"; rm -rf "$T"
}
# policy.merge: humans-only is a hard stop regardless of how good the PR is.
test_land_refuses_under_humans_only_policy() {
  _fanout_land_setup fleetbot APPROVED 0
  yq -y '.policy.merge = "humans-only"' "$T/workspace.yaml" > "$T/ws.tmp" && mv "$T/ws.tmp" "$T/workspace.yaml"
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )" && { echo "merged under humans-only"; rm -rf "$T"; return 1; }
  assert_contains "$out" "humans-only"
  ! grep -q "^pr merge" "$GH_LOG" || { echo "merge was called"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# ---- scouts: knowledge, not a change -----------------------------------------
# Investigations were being forced into ad-hoc branches to get past the ticket
# gate, or done in an orchestrator's own checkout. A scout gets a disposable
# worktree, a role that forbids shipping, and a report as its deliverable.
test_scout_bypasses_the_ticket_gate_and_records_its_shape() {
  _fanout_linear_setup
  printf 'why is the build slow?\n' > "$T/why-slow.md"
  (cd "$T" && "$BIN" scout widget "$T/why-slow.md") > /dev/null
  local e; e="$(jq -c '.[0]' "$T/.cel/delegations.json")"
  assert_eq "$(printf '%s' "$e" | jq -r .shape)" scout
  assert_eq "$(printf '%s' "$e" | jq -r .ticket)" ""
  assert_contains "$(printf '%s' "$e" | jq -r .branch)" "scout-"
  assert_contains "$(printf '%s' "$e" | jq -r .branch)" "why-slow"
  # no ticket ever moves for a scout
  assert_eq "$(cat "$LINEAR_LOG")" ""
  # the scout role, not the worker role, and a report, not a PR
  local started; started="$(grep '^agent start' "$STUB_LOG" | head -1)"
  assert_contains "$started" "role-scout.md"
  assert_contains "$(grep '^agent prompt' "$STUB_LOG" | head -1)" "report.md"
  ! grep '^agent prompt' "$STUB_LOG" | grep -q "pull request" || { echo "scout told to open a PR"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_collect_of_a_scout_prints_the_report_and_marks_reported() {
  _fanout_setup
  printf 'brief\n' > "$T/look.md"
  (cd "$T" && "$BIN" scout widget "$T/look.md") > /dev/null
  local id; id="$(jq -r '.[0].id' "$T/.cel/delegations.json")"
  mkdir -p "$STUB_WT/.agent"; printf 'FINDING: it is the cache\n' > "$STUB_WT/.agent/report.md"
  local out; out="$(cd "$T" && "$BIN" collect "$id")"
  assert_contains "$out" "FINDING: it is the cache"
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" reported
  rm -rf "$T"
}
# The report makes the worktree dirty by design; that is not held work.
test_release_of_a_scout_ignores_its_dirty_report() {
  _fanout_setup
  printf 'brief\n' > "$T/look.md"
  (cd "$T" && "$BIN" scout widget "$T/look.md") > /dev/null
  local id; id="$(jq -r '.[0].id' "$T/.cel/delegations.json")"
  git -C "$STUB_WT" init -q; mkdir -p "$STUB_WT/.agent"; printf 'r\n' > "$STUB_WT/.agent/report.md"
  (cd "$T" && "$BIN" release "$id") > /dev/null
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" released
  # herdr has its own dirty-worktree refusal and knows nothing about scouts;
  # release decided the report is not held work, so it must tell herdr so.
  assert_contains "$(grep '^worktree remove' "$STUB_LOG")" "--force"
  rm -rf "$T"
}
test_status_shows_scouts_as_such() {
  _fanout_setup
  printf 'brief\n' > "$T/look.md"
  (cd "$T" && "$BIN" scout widget "$T/look.md") > /dev/null
  assert_contains "$(cd "$T" && STUB_AGENTS_EMPTY=1 "$BIN" status)" "scout"
  rm -rf "$T"
}

# ---- profile choice is recorded with its reason -------------------------------
test_delegate_records_why_a_profile_was_chosen() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-WHY "$T/spec.md" --because "design-heavy ticket") > /dev/null
  assert_eq "$(jq -r '.[0].profile_reason' "$T/.cel/delegations.json")" "design-heavy ticket"
  rm -rf "$T"
}

# A scout reads and reports; the CLI that ships tickets in bulk is often the
# wrong one for that (no web tools, shallow model). Binding role_profiles.scout
# means nobody has to remember --profile, and the ledger shows which model did
# the research. Without the binding a scout takes the worker's profile, as before.
_fanout_bind_profiles() { # [scout-binding]
  cat >> "$T/workspace.yaml" <<EOF
worker_profiles:
  cheap: { runtime: omp, model: worker-model, thinking: low }
  deep:  { runtime: omp, model: scout-model, thinking: high }
role_profiles:
  worker: cheap
${1:+  scout: $1}
EOF
}
test_scout_uses_its_own_role_binding() {
  _fanout_setup; _fanout_bind_profiles deep
  printf 'brief\n' > "$T/b.md"
  (cd "$T" && "$BIN" scout widget "$T/b.md") > /dev/null
  assert_eq "$(jq -r '.[0].profile' "$T/.cel/delegations.json")" deep
  assert_eq "$(jq -r '.[0].model' "$T/.cel/delegations.json")" scout-model
  assert_contains "$(grep '^agent start' "$STUB_LOG" | head -1)" "scout-model"
  rm -rf "$T"
}
test_scout_falls_back_to_the_worker_binding_when_unbound() {
  _fanout_setup; _fanout_bind_profiles
  printf 'brief\n' > "$T/b.md"
  (cd "$T" && "$BIN" scout widget "$T/b.md") > /dev/null
  assert_eq "$(jq -r '.[0].profile' "$T/.cel/delegations.json")" cheap
  rm -rf "$T"
}
test_ship_delegation_ignores_the_scout_binding() {
  _fanout_setup; _fanout_bind_profiles deep
  (cd "$T" && "$BIN" delegate widget WG-9 "$T/spec.md") > /dev/null
  assert_eq "$(jq -r '.[0].profile' "$T/.cel/delegations.json")" cheap
  rm -rf "$T"
}

# ---- the verdict in collect and land -------------------------------------------
# result.md is what the worker says happened; the verdict is what did. collect
# records it in the ledger, and land refuses a configured gate that did not pass.
_fanout_verify_stub() { # <gate-passed true|false>
  VSTUB="$T/verify-stub.sh"
  cat > "$VSTUB" <<EOF
#!/usr/bin/env bash
wt="\$1"; mkdir -p "\$wt/.agent"
printf '{"at":"x","gate":{"configured":true,"passed":$1},"tests":{"red_then_green":true},"diff":{"files":1},"checks":{"state":"SUCCESS"},"review":{"decision":"APPROVED"}}' > "\$wt/.agent/verdict.json"
echo "verdict gate:$([ "$1" = true ] && echo PASS || echo FAIL)"
EOF
  chmod +x "$VSTUB"; export CEL_FANOUT_VERIFY="$VSTUB"
}
test_collect_records_the_verdict_in_the_ledger() {
  _fanout_setup; _fanout_verify_stub true
  (cd "$T" && "$BIN" delegate widget WG-VER "$T/spec.md") > /dev/null
  mkdir -p "$STUB_WT/.agent"; printf 'done\n' > "$STUB_WT/.agent/result.md"
  local out; out="$(cd "$T" && "$BIN" collect WG-VER)"
  assert_contains "$out" "verdict gate:PASS"
  assert_eq "$(jq -r '.[0].verdict.gate' "$T/.cel/delegations.json")" true
  assert_eq "$(jq -r '.[0].verdict.red_then_green' "$T/.cel/delegations.json")" true
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}
test_land_refuses_a_failed_gate() {
  _fanout_land_setup fleetbot APPROVED 0
  _fanout_verify_stub false
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )" && { echo "landed with a failed gate"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  assert_contains "$out" "did not pass"
  ! grep -q "^pr merge" "$GH_LOG" || { echo "merge was called"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}
test_land_proceeds_when_the_gate_passes() {
  _fanout_land_setup fleetbot APPROVED 0
  _fanout_verify_stub true
  (cd "$T" && "$BIN" land WG-LAND) > /dev/null
  grep -q "^pr merge" "$GH_LOG" || { echo "did not merge with a passing gate"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}

# A worktree sits OUTSIDE the workspace tree, so a worker's pane starts with a
# bare login shell and no env.local. Any profile that depends on a provider key
# - every `isolated:` one by construction - then dies on its first call, while
# the orchestrator's own preflight passes because it can still read env.local.
# The env has to be loaded into the pane before the agent starts, and by
# SOURCING, so no secret is ever typed into a pane.
test_worker_pane_loads_the_workspace_env_before_the_agent_starts() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-ENV "$T/spec.md") > /dev/null
  local run_line start_line
  run_line="$(grep -n '^pane run' "$STUB_LOG" | head -1 | cut -d: -f1)"
  start_line="$(grep -n '^agent start' "$STUB_LOG" | head -1 | cut -d: -f1)"
  [ -n "$run_line" ] || { echo "workspace env was never loaded: $(cat "$STUB_LOG")"; rm -rf "$T"; return 1; }
  [ "$run_line" -lt "$start_line" ] || { echo "env loaded after the agent started"; rm -rf "$T"; return 1; }
  assert_contains "$(grep '^pane run' "$STUB_LOG" | head -1)" "ws env alpha"
  # the command is a source, never the values
  ! grep '^pane run' "$STUB_LOG" | grep -q 'API_KEY=' || { echo "a key was typed into the pane"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A worker that has written its result and gone IDLE is finished. The live-agent
# rule was meant to stop a BUSY agent being declared done; "still alive" stood in
# for "still working" and did not survive contact with a worker that finishes and
# waits. Its row read `running` with the work pushed and the PR open.
test_status_marks_finished_when_agent_is_idle_with_a_result() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-IDLE "$T/spec.md") > /dev/null
  mkdir -p "$STUB_WT/.agent" && printf 'done\n' > "$STUB_WT/.agent/result.md"
  (cd "$T" && STUB_STATUS=idle "$BIN" status) > /dev/null
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "finished"
  rm -rf "$T"
}
# ...but an idle agent that wrote nothing is still thinking or wedged, not
# orphaned: only a DEAD agent with no result is orphaned.
test_idle_agent_without_a_result_stays_running() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-IDLE2 "$T/spec.md") > /dev/null
  rm -f "$STUB_WT/.agent/result.md"
  (cd "$T" && STUB_STATUS=idle "$BIN" status) > /dev/null
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "running"
  rm -rf "$T"
}
# Blocked is waiting on a human, not finished, even with a result on disk.
test_blocked_agent_is_not_reconciled_to_finished() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-BLK "$T/spec.md") > /dev/null
  mkdir -p "$STUB_WT/.agent" && printf 'done\n' > "$STUB_WT/.agent/result.md"
  (cd "$T" && STUB_STATUS=blocked "$BIN" status) > /dev/null
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "running"
  rm -rf "$T"
}
# Reconciliation is a poll, so it only helps someone who runs status. The worker
# is also told to say so itself, to the orchestrator's mailbox - which it cannot
# derive, standing as it does in a worktree that resolves to its own name.
test_worker_is_told_to_report_to_the_orchestrator_mailbox() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-SAY "$T/spec.md") > /dev/null
  # the stub logs `echo "$@"`, so a multi-line prompt spans multiple log lines
  local log; log="$(cat "$STUB_LOG")"
  assert_contains "$log" "cel inbox send widget-orch"
  assert_contains "$log" "WG-SAY:"
  rm -rf "$T"
}
test_scout_is_told_to_report_to_the_orchestrator_mailbox() {
  _fanout_setup
  printf 'brief\n' > "$T/look.md"
  (cd "$T" && "$BIN" scout widget "$T/look.md") > /dev/null
  assert_contains "$(cat "$STUB_LOG")" "cel inbox send widget-orch"
  rm -rf "$T"
}

# The orchestrator mailbox must use the complete shared sanitiser, not half
# of the sanitiser - lowercase and substitute, but no 32-character truncation.
# A repo name past 27 characters therefore addressed an untruncated mailbox
# while the orchestrator answered to the truncated one, so every completion
# notice from that repo was filed where nobody reads.
test_the_orchestrator_mailbox_is_truncated_like_every_other_name() {
  local long=repository-with-a-very-long-name
  assert_eq "$(bash -c 'source "$1/lib/run.sh"; _run_agent_name "$2-orch"' _ "$CEL_ROOT" "$long")" \
            "$(bash -c 'source "$1/lib/inbox.sh"; _inbox_sanitise "$2-orch"' _ "$CEL_ROOT" "$long")"
}
# A workspace name is not validated against whitespace, and an unquoted two-word
# name reaches `cel ws env` as two arguments - of which it reads only the first.
# The lookup fails, eval of empty output still succeeds, and the agent starts
# with no credentials at all.
test_the_workspace_env_selector_is_shell_quoted() {
  _fanout_setup
  sed -i 's/^name: alpha$/name: two words/' "$T/workspace.yaml"
  (cd "$T" && "$BIN" delegate widget WG-Q "$T/spec.md") > /dev/null 2>&1 || true
  local line; line="$(grep '^pane run' "$STUB_LOG" | head -1)"
  assert_contains "$line" "ws env"
  ! printf '%s' "$line" | grep -q "ws env two words" \
    || { echo "unquoted multi-word workspace name reached the pane"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A worker stands in ~/.herdr/worktrees/..., where
# ws_current finds nothing, so an unqualified `cel inbox send` resolves the
# workspace to the literal `default` - a mailbox no orchestrator reads. The
# completion notice has to name the workspace, or the whole announcement is a
# no-op in exactly the silent way it was written to prevent.
test_the_completion_notice_names_the_workspace() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-WS "$T/spec.md") > /dev/null
  local log; log="$(cat "$STUB_LOG")"
  # AND IN THE POSITION THE PARSER ACCEPTS. `cel inbox send` takes <to> and
  # <message> positionally and flags only after them, so `--workspace` placed
  # before the message is read AS the message and the command dies with
  # "unknown argument". A prompt that cannot run is worth nothing.
  assert_contains "$log" "cel inbox send widget-orch"
  assert_contains "$log" "--workspace alpha --kind status"
  ! printf '%s' "$log" | grep -q "send widget-orch --workspace" \
    || { echo "--workspace precedes the message; the command would die"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_the_scouts_notice_names_the_workspace_too() {
  _fanout_setup
  printf 'brief\n' > "$T/b.md"
  (cd "$T" && "$BIN" scout widget "$T/b.md") > /dev/null
  assert_contains "$(cat "$STUB_LOG")" "--workspace alpha"
  rm -rf "$T"
}

test_release_refuses_unknown_base_and_detached_head() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-UNKNOWN "$T/spec.md") >/dev/null
  git -C "$STUB_WT" checkout -q -b task-without-remote
  git -C "$STUB_WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/missing
  local out
  if out="$(cd "$T" && "$BIN" release WG-UNKNOWN 2>&1)"; then echo "released with unknown base"; return 1; fi
  assert_contains "$out" "unknown=base"
  git -C "$STUB_WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$STUB_WT" checkout --detach -q
  if out="$(cd "$T" && "$BIN" release WG-UNKNOWN 2>&1)"; then echo "released detached HEAD"; return 1; fi
  assert_contains "$out" "unknown=branch"
  ! grep -q '^worktree remove' "$STUB_LOG" || { echo "destructive sink called"; return 1; }
  rm -rf "$T"
}

test_release_refuses_git_status_and_commit_comparison_errors() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-ERROR "$T/spec.md") >/dev/null
  local real_git; real_git="$(command -v git)"
  mkdir "$T/bin"
  cat > "$T/bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" $FAIL_GIT_COMMAND "*) exit 128;; esac
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$T/bin/git"
  local op out
  for op in status rev-list; do
    if out="$(cd "$T" && PATH="$T/bin:$PATH" REAL_GIT="$real_git" FAIL_GIT_COMMAND="$op" "$BIN" release WG-ERROR 2>&1)"; then
      echo "release ignored Git error"; return 1
    fi
    assert_contains "$out" "unknown="
  done
  ! grep -q '^worktree remove' "$STUB_LOG" || { echo "destructive sink called"; return 1; }
  rm -rf "$T"
}

test_scout_release_does_not_exempt_unrelated_dirty_files() {
  _fanout_setup
  (cd "$T" && "$BIN" scout widget "$T/spec.md") >/dev/null
  local id; id="$(jq -r '.[0].id' "$T/.cel/delegations.json")"
  mkdir -p "$STUB_WT/.agent"
  printf 'report\n' > "$STUB_WT/.agent/report.md"
  printf 'source work\n' > "$STUB_WT/source.txt"
  if (cd "$T" && "$BIN" release "$id" >/dev/null 2>&1); then echo "scout lost source work"; return 1; fi
  ! grep -q '^worktree remove' "$STUB_LOG" || { echo "destructive sink called"; return 1; }
  rm -rf "$T"
}

test_status_invalid_roster_does_not_reconcile_live_delegations() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-LIVE "$T/spec.md") >/dev/null
  local json
  for json in '{}' '{"result":{"agents":null}}' '{"result":{"agents":[{"pane_id":"wZ:p1"}]}}'; do
    (cd "$T" && STUB_AGENTS_JSON="$json" "$BIN" status) >/dev/null
    assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" running
  done
  rm -rf "$T"
}

test_fanout_ledger_replacement_is_atomic_even_with_foreign_tmpdir() {
  _fanout_setup
  mkdir -p "$T/bin" "$T/foreign"
  local real_mv; real_mv="$(command -v mv)"
  cat > "$T/bin/mv" <<'EOF'
#!/usr/bin/env bash
src="${@: -2:1}"; dst="${@: -1}"
if [ "$(dirname "$src")" != "$(dirname "$dst")" ]; then
  echo 'non-atomic cross-directory ledger replace' >&2; exit 96
fi
before="$(stat -c '%d:%i' "$src")"
"$REAL_MV" "$@" || exit
[ "$(stat -c '%d:%i' "$dst")" = "$before" ] || exit 97
EOF
  chmod +x "$T/bin/mv"
  local foreign="$T/foreign"
  [ ! -d /dev/shm ] || foreign=/dev/shm
  (cd "$T" && TMPDIR="$foreign" PATH="$T/bin:$PATH" REAL_MV="$real_mv" "$BIN" delegate widget WG-ATOMIC "$T/spec.md") >/dev/null
  assert_eq "$(jq -r '.[0].id' "$T/.cel/delegations.json")" WG-ATOMIC
  rm -rf "$T"
}

test_concurrent_fanout_writers_preserve_both_delegations() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-FIRST "$T/spec.md") >/dev/null &
  local first=$!
  (cd "$T" && "$BIN" delegate widget WG-SECOND "$T/spec.md") >/dev/null &
  local second=$!
  wait "$first"; wait "$second"
  assert_eq "$(jq -r 'map(.id) | sort | join(",")' "$T/.cel/delegations.json")" "WG-FIRST,WG-SECOND"
  rm -rf "$T"
}

test_fanout_failed_ledger_rename_preserves_rows_and_cleans_temp() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-RENAME "$T/spec.md") >/dev/null
  local before; before="$(cat "$T/.cel/delegations.json")"
  mkdir "$T/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/mv"
  chmod +x "$T/bin/mv"
  if (cd "$T" && STUB_AGENTS_EMPTY=1 PATH="$T/bin:$PATH" "$BIN" status >/dev/null 2>&1); then
    echo "failed ledger replacement reported success"; return 1
  fi
  assert_eq "$(cat "$T/.cel/delegations.json")" "$before"
  local f
  for f in "$T/.cel/delegations.json".tmp.*; do
    [ ! -e "$f" ] || { echo "failed replacement leaked temporary file"; return 1; }
  done
  rm -rf "$T"
}

# --- the worker cap ---------------------------------------------------------
# policy.workers was a sentence in the injected policy block and nothing else,
# so each orchestrator kept a private count - which only ever goes up, because
# delegating is an act it performs and finishing is an event nobody reports to
# it. Both directions were live on one day: an orchestrator holding four
# tickets as "blocked until a slot frees" with zero workers running, and
# nothing that would have stopped another from starting a fifth.
_cap_fill() { # <n> running rows for widget
  local i; for i in $(seq 1 "$1"); do
    (cd "$T" && "$BIN" delegate widget "WG-9$i" "$T/spec.md") > /dev/null 2>&1
    jq --arg id "WG-9$i" 'map(if .id == $id then .state = "running" else . end)' \
      "$T/.cel/delegations.json" > "$T/l.json" && mv "$T/l.json" "$T/.cel/delegations.json"
  done
}
test_delegate_refuses_past_the_worker_cap() {
  _fanout_setup
  _cap_fill 4
  local out; out="$( (cd "$T" && "$BIN" delegate widget WG-FIFTH "$T/spec.md") 2>&1 )" && {
    echo "a fifth worker was allowed past a cap of 4"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cap is 4"
  assert_contains "$out" "cel-fanout collect"
  rm -rf "$T"
}
test_a_freed_slot_allows_the_next_delegation() {
  _fanout_setup
  _cap_fill 4
  jq 'map(if .id == "WG-91" then .state = "collected" else . end)' \
    "$T/.cel/delegations.json" > "$T/l.json" && mv "$T/l.json" "$T/.cel/delegations.json"
  (cd "$T" && "$BIN" delegate widget WG-FIFTH "$T/spec.md") > /dev/null \
    || { echo "a freed slot was still refused"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# The cap is PER REPO: one repo at capacity must not block its neighbour.
test_the_cap_is_per_repo() {
  _fanout_setup
  mkdir -p "$T/repos/gadget" && git -C "$T/repos/gadget" init -q
  printf '  - name: gadget\n    url: git@github.com:someone/gadget.git\n    prefix: OT\n' >> "$T/workspace.yaml"
  _cap_fill 4
  # The stub only knows the widget repo, so gadget cannot complete a real
  # delegation here; what matters is that it is not refused BY THE CAP.
  local out; out="$( (cd "$T" && "$BIN" delegate gadget OT-1 "$T/spec.md") 2>&1 || true )"
  ! printf '%s' "$out" | grep -q "cap is" \
    || { echo "a full repo blocked a different one: $out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# And status says what is true, so nobody has to keep the number in their head.
test_status_reports_slots_per_repo() {
  _fanout_setup
  local out; out="$( (cd "$T" && STUB_AGENTS_EMPTY=1 "$BIN" status) 2>&1 )"
  assert_contains "$out" "slots widget"
  assert_contains "$out" "free"
  rm -rf "$T"
}

# ---- products: the orchestrator above a worker may own several repos --------
# cel-fanout is the only thing that spawns workers, and it encoded the old
# one-repo-one-orchestrator shape in three places: the mailbox it hands the
# worker, the cap it counts against, and the herdr workspace it nests the
# worktree under. With products declared, a worker in `widget` reports to
# `bundle-orch`, shares its cap with `gadget`, and nests under a pane that is
# not a git toplevel at all.
_fanout_products_setup() {
  _fanout_setup
  local r
  for r in gadget lone; do
    mkdir -p "$T/repos/$r"
    git -C "$T/repos/$r" init -q
  done
  STUB_REPO_GADGET="$(git -C "$T/repos/gadget" rev-parse --show-toplevel)"
  STUB_REPO_LONE="$(git -C "$T/repos/lone" rev-parse --show-toplevel)"
  yq -y -i '.repos += [{"name":"gadget","url":"git@github.com:someone/gadget.git","prefix":"OT"},
                       {"name":"lone","url":"git@github.com:someone/lone.git","prefix":"ABC"}]
            | .products = [{"name":"bundle","repos":["widget","gadget"],"workers":3}]' \
    "$T/workspace.yaml"
  mkdir -p "$T/products/bundle"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$STUB_LOG"
case "$1 $2" in
  "worktree create") echo '{"result":{"workspace_id":"wZ","pane_id":"wZ:p1","checkout_path":"'"$STUB_WT"'"}}';;
  "workspace list")  if [ -n "${STUB_NO_WS:-}" ]; then echo '{"result":{"workspaces":[]}}'; else echo '{"result":{"workspaces":[
      {"workspace_id":"wY","worktree":{"repo_root":"'"$STUB_REPO"'","is_linked_worktree":false}},
      {"workspace_id":"wG","worktree":{"repo_root":"'"$STUB_REPO_GADGET"'","is_linked_worktree":false}},
      {"workspace_id":"wL","worktree":{"repo_root":"'"$STUB_REPO_LONE"'","is_linked_worktree":false}}]}}'; fi;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wC","label":"widget/workers"}}}';;
  "pane list")       printf '%s' "${STUB_PANES_JSON:-{\"result\":{\"panes\":[]}}}";;
  "agent list")      echo '{"result":{"agents":[]}}';;
  *) echo '{}';;
esac
EOF
  chmod +x "$STUB"
  export STUB_REPO_GADGET STUB_REPO_LONE
}

test_delegate_reports_to_the_products_orchestrator() {
  _fanout_products_setup
  (cd "$T" && "$BIN" delegate widget WG-PROD "$T/spec.md") > /dev/null
  assert_contains "$(cat "$STUB_LOG")" "cel inbox send bundle-orch"
  rm -rf "$T"
}

# A repo in no declared product is its own product, in place, exactly as before.
test_delegate_for_an_undeclared_repo_keeps_its_own_mailbox() {
  _fanout_products_setup
  : > "$STUB_LOG"
  (cd "$T" && "$BIN" delegate lone ABC-1 "$T/spec.md") > /dev/null
  assert_contains "$(cat "$STUB_LOG")" "cel inbox send lone-orch"
  rm -rf "$T"
}

# The cap belongs to the ORCHESTRATOR, and one orchestrator now stands over
# several repos: counting per repo would let a product run cap x repos workers.
test_the_cap_counts_the_whole_product() {
  _fanout_products_setup
  (cd "$T" && "$BIN" delegate widget WG-P1 "$T/spec.md") > /dev/null
  (cd "$T" && "$BIN" delegate widget WG-P2 "$T/spec.md") > /dev/null
  (cd "$T" && "$BIN" delegate gadget OT-1 "$T/spec.md") > /dev/null
  local out; out="$( (cd "$T" && "$BIN" delegate widget WG-P4 "$T/spec.md") 2>&1 )" && {
    echo "a fourth worker was allowed past the product cap of 3"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cap is 3"
  # the same refusal from the product's OTHER repo
  out="$( (cd "$T" && "$BIN" delegate gadget OT-2 "$T/spec.md") 2>&1 )" && {
    echo "the cap did not apply across the product"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cap is 3"
  # ...and a repo outside the product is untouched by it
  out="$( (cd "$T" && "$BIN" delegate lone ABC-2 "$T/spec.md") 2>&1 || true )"
  ! printf '%s' "$out" | grep -q "cap is" \
    || { echo "a full product blocked an unrelated repo: $out"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_status_reports_slots_per_product() {
  _fanout_products_setup
  local out; out="$( (cd "$T" && "$BIN" status) 2>&1 )"
  assert_contains "$out" "slots bundle"
  assert_contains "$out" "(widget, gadget)"
  assert_contains "$out" "slots lone"
  rm -rf "$T"
}

# A declared product's orchestrator stands in <ws>/products/<name>, which is
# not a git toplevel - so the toplevel lookup finds the REPO orchestrator's
# workspace and nests every worker under the wrong parent.
# herdr will only cut a worktree of the repo a workspace OWNS, and offers no
# way to nest under an arbitrary parent (measured live, 2026-09-16: under a
# product pane it cut a worktree of the workspace-config repo). So a product
# pane is never the nest target - the repo's own workspace is, always.
test_delegate_nests_under_the_repo_workspace_even_when_a_product_pane_exists() {
  _fanout_products_setup
  export STUB_PANES_JSON='{"result":{"panes":[{"pane_id":"wP:p1","cwd":"'"$T"'/products/bundle","workspace_id":"wP"}]}}'
  (cd "$T" && "$BIN" delegate widget WG-NEST "$T/spec.md") > /dev/null
  assert_contains "$(grep '^worktree create' "$STUB_LOG" | head -1)" "--workspace wY"
  ! grep '^worktree create' "$STUB_LOG" | grep -q -- '--workspace wP' || { echo "nested under the product pane"; rm -rf "$T"; return 1; }
  unset STUB_PANES_JSON
  rm -rf "$T"
}
# When the repo's orchestrator has been retired in favour of a product one, no
# workspace holds the repo - a container is created so workers have a home.
test_delegate_creates_a_container_workspace_when_none_holds_the_repo() {
  _fanout_products_setup
  export STUB_NO_WS=1
  (cd "$T" && "$BIN" delegate widget WG-HOME "$T/spec.md") > /dev/null
  assert_contains "$(grep '^workspace create' "$STUB_LOG" | head -1)" "--label widget/workers"
  assert_contains "$(grep '^worktree create' "$STUB_LOG" | head -1)" "--workspace wC"
  unset STUB_NO_WS
  rm -rf "$T"
}

# ---- --workspace -----------------------------------------------------------
# An orchestrator standing in a product dir, or anywhere else, must be able to
# name its workspace instead of relying on where its cwd happens to be.
test_workspace_flag_resolves_the_ledger_from_an_unrelated_cwd() {
  _fanout_products_setup
  export CEL_REGISTRY="$T/registry.json"
  printf '{"workspaces":{"alpha":{"path":"%s","remote":null}}}\n' "$T" > "$CEL_REGISTRY"
  (cd /tmp && "$BIN" delegate widget WG-FLAG "$T/spec.md" --workspace alpha) > /dev/null
  assert_eq "$(jq -r '.[0].id' "$T/.cel/delegations.json")" WG-FLAG
  local out; out="$( (cd /tmp && "$BIN" status --workspace alpha) 2>&1 )"
  assert_contains "$out" "WG-FLAG"
  unset CEL_REGISTRY
  rm -rf "$T"
}

# ---- the review verdict as a ledger fact ------------------------------------
# On a repo whose PR author and reviewer are one GitHub account, GitHub refuses
# approval outright and a posted review reads as the owner talking to himself in
# public. The verdict has to live somewhere; the ledger is where.
test_review_records_the_verdict_on_the_row() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-REV "$T/spec.md") > /dev/null
  (cd "$T" && "$BIN" review WG-REV approved --by widget-pr-7-review --note "gate green") > /dev/null
  local r; r="$(jq -c '.[0].review' "$T/.cel/delegations.json")"
  assert_eq "$(printf '%s' "$r" | jq -r .verdict)" approved
  assert_eq "$(printf '%s' "$r" | jq -r .by)" widget-pr-7-review
  assert_eq "$(printf '%s' "$r" | jq -r .note)" "gate green"
  rm -rf "$T"
}

test_review_refuses_an_unknown_verdict() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-REV2 "$T/spec.md") > /dev/null
  local out; out="$( (cd "$T" && "$BIN" review WG-REV2 maybe --by r) 2>&1 )" && {
    echo "an unknown verdict was recorded"; rm -rf "$T"; return 1; }
  assert_contains "$out" "approved"
  rm -rf "$T"
}

# A ledger verdict satisfies land ONLY where GitHub approval is impossible -
# the PR's author is the account doing the reviewing. Otherwise GitHub stays
# the authority.
test_land_accepts_a_ledger_verdict_when_the_author_is_the_reviewer() {
  _fanout_land_setup fleetbot REVIEW_REQUIRED 0
  (cd "$T" && "$BIN" review WG-LAND approved --by widget-pr-7-review --note "gate green") > /dev/null
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )"
  grep -q "^pr merge 7" "$GH_LOG" || { echo "did not merge on a ledger verdict: $out"; rm -rf "$T"; return 1; }
  assert_contains "$out" "ledger"
  # the public record lives in the log, not in a comment nobody reads
  assert_contains "$(cat "$GH_LOG")" "Reviewed-by: widget-pr-7-review (approved)"
  assert_contains "$(cat "$GH_LOG")" "gate green"
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}

test_land_says_which_path_approved_it() {
  _fanout_land_setup fleetbot APPROVED 0
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )"
  assert_contains "$out" "GitHub"
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}

test_land_refuses_a_changes_verdict() {
  _fanout_land_setup fleetbot REVIEW_REQUIRED 0
  (cd "$T" && "$BIN" review WG-LAND changes --by widget-pr-7-review) > /dev/null
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )" && {
    echo "landed on a changes-requested verdict"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  assert_contains "$out" "not approved"
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}

test_status_shows_the_review_column() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-RCOL "$T/spec.md") > /dev/null
  assert_contains "$(cd "$T" && "$BIN" status)" "REVIEW"
  (cd "$T" && "$BIN" review WG-RCOL approved --by r) > /dev/null
  assert_contains "$(cd "$T" && "$BIN" status)" " ok "
  (cd "$T" && "$BIN" review WG-RCOL changes --by r) > /dev/null
  assert_contains "$(cd "$T" && "$BIN" status)" " chg "
  rm -rf "$T"
}

# ---- spikes: throwaway code that answers a question -------------------------
# A worker's deliverable is a PR, a scout's is a report and it may not write
# code. "Try it and tell me if it works" is neither, and was being run as one
# of them - either shipping unreviewed experiments or a scout reading code it
# should have been running.
test_spike_records_its_shape_and_is_forbidden_to_ship() {
  _fanout_linear_setup
  printf 'does the cache help?\n' > "$T/try-cache.md"
  (cd "$T" && "$BIN" spike widget "$T/try-cache.md") > /dev/null
  local e; e="$(jq -c '.[0]' "$T/.cel/delegations.json")"
  assert_eq "$(printf '%s' "$e" | jq -r .shape)" spike
  assert_eq "$(printf '%s' "$e" | jq -r .ticket)" ""
  local log; log="$(cat "$STUB_LOG")"
  assert_contains "$(grep '^agent start' "$STUB_LOG" | head -1)" "role-spike.md"
  assert_contains "$log" "report.md"
  ! printf '%s' "$log" | grep -q "pull request" || { echo "a spike was told to open a PR"; rm -rf "$T"; return 1; }
  assert_contains "$log" "never push"
  rm -rf "$T"
}

test_collect_of_a_spike_reports_without_running_the_verifier() {
  _fanout_setup
  printf 'brief\n' > "$T/try.md"
  (cd "$T" && "$BIN" spike widget "$T/try.md") > /dev/null
  local id; id="$(jq -r '.[0].id' "$T/.cel/delegations.json")"
  cat > "$T/verify-marker.sh" <<EOF
#!/usr/bin/env bash
touch "$T/verifier-ran"
EOF
  chmod +x "$T/verify-marker.sh"
  mkdir -p "$STUB_WT/.agent"; printf 'FINDING: the cache helps\n' > "$STUB_WT/.agent/report.md"
  local out; out="$(cd "$T" && CEL_FANOUT_VERIFY="$T/verify-marker.sh" "$BIN" collect "$id")"
  assert_contains "$out" "FINDING: the cache helps"
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" reported
  [ ! -f "$T/verifier-ran" ] || { echo "the verifier ran on a spike"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A spike's worktree is throwaway by definition: dirty and unpushed are the
# expected end state, not held work someone must be asked about. But what is
# thrown away is still said out loud.
test_release_of_a_dirty_spike_needs_no_discard_but_says_what_went() {
  _fanout_setup
  printf 'brief\n' > "$T/try.md"
  (cd "$T" && "$BIN" spike widget "$T/try.md") > /dev/null
  local id; id="$(jq -r '.[0].id' "$T/.cel/delegations.json")"
  printf 'experiment\n' > "$STUB_WT/scratch.txt"
  local out; out="$( (cd "$T" && "$BIN" release "$id") 2>&1 )"
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" released
  assert_contains "$out" "dirty=1"
  rm -rf "$T"
}

test_status_shows_spikes_as_such() {
  _fanout_setup
  printf 'brief\n' > "$T/try.md"
  (cd "$T" && "$BIN" spike widget "$T/try.md") > /dev/null
  assert_contains "$(cd "$T" && STUB_AGENTS_EMPTY=1 "$BIN" status)" "spike"
  rm -rf "$T"
}

# ---- a gate that ran out of time is not a gate that failed --------------------
# `timeout` returns 124 when it killed the command. Read as a failure, a green
# branch was recorded as gate:FAIL and land refused a verdict that did not
# exist. Unknown is not passed - but it is not failed either, and the two lead
# to opposite actions.
_fanout_verify_timeout_stub() { # [secs]
  VSTUB="$T/verify-timeout-stub.sh"
  local secs="${1:-600}"
  cat > "$VSTUB" <<EOF
#!/usr/bin/env bash
wt="\$1"; mkdir -p "\$wt/.agent"
printf '{"at":"x","gate":{"configured":true,"passed":null,"timed_out":true,"timeout_secs":$secs,"tail":"killed after ${secs}s - no verdict"},"tests":{"red_then_green":true},"diff":{"files":1},"checks":{"state":"SUCCESS"},"review":{"decision":"APPROVED"}}' > "\$wt/.agent/verdict.json"
echo "verdict gate:TIMEOUT(${secs}s)"
exit 2
EOF
  chmod +x "$VSTUB"; export CEL_FANOUT_VERIFY="$VSTUB"
}
test_collect_warns_and_records_a_timed_out_gate() {
  _fanout_setup; _fanout_verify_timeout_stub 600
  (cd "$T" && "$BIN" delegate widget WG-TO "$T/spec.md") > /dev/null
  mkdir -p "$STUB_WT/.agent"; printf 'done\n' > "$STUB_WT/.agent/result.md"
  local out; out="$( (cd "$T" && "$BIN" collect WG-TO) 2>&1 )"
  assert_contains "$out" "gate:TIMEOUT(600s)"
  assert_contains "$out" "--gate-timeout"
  assert_contains "$out" "CEL_VERIFY_GATE_TIMEOUT"
  assert_eq "$(jq -r '.[0].verdict.gate' "$T/.cel/delegations.json")" null
  assert_eq "$(jq -r '.[0].verdict.gate_timed_out' "$T/.cel/delegations.json")" true
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}
test_land_refuses_a_timed_out_gate_as_unknown_not_failed() {
  _fanout_land_setup fleetbot APPROVED 0
  _fanout_verify_timeout_stub 600
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND) 2>&1 )" && { echo "landed an unfinished gate"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  assert_contains "$out" "gate did not complete"
  assert_contains "$out" "CEL_VERIFY_GATE_TIMEOUT"
  assert_contains "$out" "--gate-from-ci"
  ! grep -q "^pr merge" "$GH_LOG" || { echo "merge was called"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}
# CI can only stand in for the gate if the checks that stood in are the ones the
# base branch is PROTECTED by. Any-green-check-will-do proves nothing: a docs
# build or a lint job going green says nothing about the suite.
_fanout_ci_gh_stub() { # <protection-json|empty to make it unreadable> <check-runs-json>
  cat > "$T/gh-stub.sh" <<STUB_EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "api user") echo fleetbot;;
  "pr view")  echo '{"number":7,"author":{"login":"fleetbot"},"reviewDecision":"APPROVED","isDraft":false,"mergeable":"MERGEABLE","state":"OPEN","headRefOid":"deadbeefcafe","baseRefName":"main","statusCheckRollup":[{"conclusion":"SUCCESS"}]}';;
  "pr merge") exit 0;;
  *) case "\$2" in
       */protection) [ -n '$1' ] || exit 1; printf '%s' '$1';;
       *check-runs)  printf '%s' '$2';;
       *) echo '{}';;
     esac;;
esac
STUB_EOF
  chmod +x "$T/gh-stub.sh"
}
test_gate_from_ci_lands_on_the_required_check_and_names_it() {
  _fanout_land_setup fleetbot APPROVED 0
  _fanout_verify_timeout_stub 600
  _fanout_ci_gh_stub '{"required_status_checks":{"contexts":["suite"]}}' \
    '{"check_runs":[{"name":"docs","conclusion":"success"},{"name":"suite","conclusion":"success"}]}'
  (cd "$T" && "$BIN" land WG-LAND --gate-from-ci) > /dev/null
  grep -q "^pr merge 7" "$GH_LOG" || { echo "did not merge with CI evidence"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  grep -q "Gate: CI (suite) on deadbeefcafe" "$GH_LOG" || { echo "merge body does not name the required check"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}
# The finding that produced this rule: an unrelated green check must not carry
# a merge while the check that actually gates the branch never ran.
test_gate_from_ci_refuses_when_the_required_check_is_absent() {
  _fanout_land_setup fleetbot APPROVED 0
  _fanout_verify_timeout_stub 600
  _fanout_ci_gh_stub '{"required_status_checks":{"contexts":["suite"]}}' \
    '{"check_runs":[{"name":"docs","conclusion":"success"}]}'
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND --gate-from-ci) 2>&1 )" && { echo "landed on an unrelated green check"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  assert_contains "$out" "suite"
  ! grep -q "^pr merge" "$GH_LOG" || { echo "merge was called"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}
test_gate_from_ci_refuses_a_required_check_that_failed_or_is_pending() {
  _fanout_land_setup fleetbot APPROVED 0
  _fanout_verify_timeout_stub 600
  _fanout_ci_gh_stub '{"required_status_checks":{"contexts":["suite"]}}' \
    '{"check_runs":[{"name":"docs","conclusion":"success"},{"name":"suite","status":"in_progress","conclusion":null}]}'
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND --gate-from-ci) 2>&1 )" && { echo "landed on a pending required check"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  assert_contains "$out" "suite"
  ! grep -q "^pr merge" "$GH_LOG" || { echo "merge was called"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}
# EVERY required context, not the first one that happens to be green.
test_gate_from_ci_requires_every_required_check() {
  _fanout_land_setup fleetbot APPROVED 0
  _fanout_verify_timeout_stub 600
  _fanout_ci_gh_stub '{"required_status_checks":{"contexts":["suite","lint"]}}' \
    '{"check_runs":[{"name":"suite","conclusion":"success"}]}'
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND --gate-from-ci) 2>&1 )" && { echo "landed with a missing required check"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  assert_contains "$out" "lint"
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}
# An unprotected base has no such thing as "the required check", so there is
# nothing for CI to stand in with. Same for protection this token cannot read:
# absence of evidence is not evidence.
test_gate_from_ci_refuses_when_protection_is_absent_or_unreadable() {
  _fanout_land_setup fleetbot APPROVED 0
  _fanout_verify_timeout_stub 600
  _fanout_ci_gh_stub '' '{"check_runs":[{"name":"suite","conclusion":"success"}]}'
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND --gate-from-ci) 2>&1 )" && { echo "landed without readable branch protection"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  assert_contains "$out" "protection"
  ! grep -q "^pr merge" "$GH_LOG" || { echo "merge was called"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}
test_gate_from_ci_refuses_protection_with_no_required_contexts() {
  _fanout_land_setup fleetbot APPROVED 0
  _fanout_verify_timeout_stub 600
  _fanout_ci_gh_stub '{"required_status_checks":{"contexts":[]}}' \
    '{"check_runs":[{"name":"suite","conclusion":"success"}]}'
  local out; out="$( (cd "$T" && "$BIN" land WG-LAND --gate-from-ci) 2>&1 )" && { echo "landed with no required contexts"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  assert_contains "$out" "requires no check"
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}
test_status_renders_a_timed_out_gate_as_TO() {
  _fanout_setup; _fanout_verify_timeout_stub 600
  (cd "$T" && "$BIN" delegate widget WG-TOS "$T/spec.md") > /dev/null
  mkdir -p "$STUB_WT/.agent"; printf 'done\n' > "$STUB_WT/.agent/result.md"
  (cd "$T" && "$BIN" collect WG-TOS) > /dev/null 2>&1
  local out; out="$(cd "$T" && STUB_AGENTS_EMPTY=1 "$BIN" status)"
  assert_contains "$out" "GATE"
  assert_contains "$out" "TO"
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
}

# ---- the ledger lock must not outlive the invocation that took it -----------
# On 2026-09-16 every `cel-fanout release` on a workspace blocked on flock of
# .cel/delegations.lock for an hour and a half. The holders were seven test
# servers a gate had booted: collect held the lock on an inherited descriptor,
# the verifier it spawned inherited that descriptor, the gate died, and the
# servers it had backgrounded did not. A lock whose owner is gone but whose
# descriptor is still open cannot be told apart from a lock in use, so nothing
# recovered - the fleet just waited. The descriptor must therefore be closed
# on every spawn out of the locked region.
test_collect_does_not_leak_the_ledger_lock_into_the_verifier() {
  _fanout_setup
  local vstub="$T/verify-leaky.sh" fds="$T/verifier-fds" spid="$T/sleeper.pid"
  cat > "$vstub" <<STUB
#!/usr/bin/env bash
wt="\$1"; mkdir -p "\$wt/.agent"
ls -l /proc/\$\$/fd > "$fds" 2>&1
# a server of the kind a gate boots: outlives the verifier, inherits its fds
sleep 60 >/dev/null 2>&1 &
echo \$! > "$spid"
printf '{"at":"x","gate":{"configured":true,"passed":true},"tests":{"red_then_green":true},"diff":{"files":1},"checks":{"state":"SUCCESS"},"review":{"decision":"APPROVED"}}' > "\$wt/.agent/verdict.json"
echo "verdict gate:PASS"
STUB
  chmod +x "$vstub"; export CEL_FANOUT_VERIFY="$vstub"
  (cd "$T" && "$BIN" delegate widget WG-LOCK "$T/spec.md") > /dev/null
  mkdir -p "$STUB_WT/.agent"; printf 'done\n' > "$STUB_WT/.agent/result.md"
  (cd "$T" && "$BIN" collect WG-LOCK) > /dev/null
  local sleeper; sleeper="$(cat "$spid")"
  # the child a gate leaves behind is still alive - that is the whole point
  kill -0 "$sleeper" 2>/dev/null || { echo "sleeper died before the assertion"; unset CEL_FANOUT_VERIFY; rm -rf "$T"; return 1; }
  local leaked=0
  grep -q 'delegations\.lock' "$fds" && leaked=1
  [ "$leaked" -eq 0 ] || { echo "verifier inherited the ledger lock:"; cat "$fds"; }
  local relocked=0
  flock -n "$T/.cel/delegations.lock" -c true && relocked=1
  kill "$sleeper" 2>/dev/null
  unset CEL_FANOUT_VERIFY; rm -rf "$T"
  assert_eq "$leaked" 0
  assert_eq "$relocked" 1
}

# The same proof at the level of the mechanism every locked region uses, and
# of its two halves: a child spawned through lock_spawn never sees the
# descriptor, the CALLER still holds the lock afterwards (a helper that closed
# it in the calling process would release a ledger mid-update), and a
# backgrounded spawn that closes the descriptor inline leaves the lock free
# the moment the region ends, even while the child runs on.
test_lock_spawn_children_do_not_hold_the_lock_open() {
  local D out; D="$(mktemp -d)"
  out="$(CEL_ROOT="$CEL_ROOT" LOCKFILE="$D/delegations.lock" bash -c '
    set -u
    . "$CEL_ROOT/lib/registry.sh"
    exec {fd}>"$LOCKFILE"
    flock "$fd"
    if lock_spawn "$fd" bash -c "ls -l /proc/\$\$/fd" | grep -q delegations.lock
      then echo leaked-into-child; else echo no-lock-fd; fi
    if flock -n "$LOCKFILE" -c true; then echo lost-the-lock; else echo still-mine; fi
    sleep 60 {fd}>&- &
    child=$!
    exec {fd}>&-
    kill -0 "$child" 2>/dev/null && echo alive
    if flock -n "$LOCKFILE" -c true; then echo relocked; else echo still-held; fi
    kill "$child" 2>/dev/null
  ' 2>&1)"
  rm -rf "$D"
  assert_contains "$out" no-lock-fd
  assert_contains "$out" still-mine
  assert_contains "$out" alive
  assert_contains "$out" relocked
}

# ── seed: the local files a fresh checkout does not have ─────────────────────
# A worktree is a fresh checkout, so every gitignored file the repo needs to
# RUN is missing from it. Seven worktrees were symlinked by hand in one
# evening before this existed.
_seed_yaml() { # appends a seed: block to the fixture's widget entry
  cat >> "$T/workspace.yaml" <<'YAML'
    seed:
      - apps/builder/.dev.vars
      - { path: apps/pf/src/wasm, copy: true }
YAML
  mkdir -p "$T/repos/widget/apps/builder" "$T/repos/widget/apps/pf/src/wasm"
  printf 'KEY=1\n' > "$T/repos/widget/apps/builder/.dev.vars"
  printf 'x\n' > "$T/repos/widget/apps/pf/src/wasm/mod.wasm"
  printf 'apps/builder/.dev.vars\napps/pf/src/wasm\n' > "$STUB_WT/.gitignore"
}

test_delegate_seeds_linked_and_copied_paths_and_tells_the_worker() {
  _fanout_setup; _seed_yaml
  (cd "$T" && "$BIN" delegate widget WG-SEED "$T/spec.md") > /dev/null
  assert_eq "$(readlink "$STUB_WT/apps/builder/.dev.vars")" "$T/repos/widget/apps/builder/.dev.vars"
  [ -d "$STUB_WT/apps/pf/src/wasm" ] && [ ! -L "$STUB_WT/apps/pf/src/wasm" ] \
    || { echo "the copied entry is not a real directory"; return 1; }
  assert_eq "$(cat "$STUB_WT/apps/pf/src/wasm/mod.wasm")" "x"
  local log; log="$(cat "$STUB_LOG")"
  assert_contains "$log" "Seeded local config, not yours to commit:"
  assert_contains "$log" "apps/builder/.dev.vars"
  assert_contains "$log" "apps/pf/src/wasm"
  rm -rf "$T"
}

# A repo without the file locally still gets its worker: a missing source is
# a warning, never a failed delegation.
test_delegate_warns_but_succeeds_when_a_seed_source_is_missing() {
  _fanout_setup; _seed_yaml
  rm -f "$T/repos/widget/apps/builder/.dev.vars"
  local out; out="$(cd "$T" && "$BIN" delegate widget WG-SEEDMISS "$T/spec.md")"
  assert_contains "$out" "apps/builder/.dev.vars"
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "running"
  [ ! -e "$STUB_WT/apps/builder/.dev.vars" ] || { echo "a missing source was seeded anyway"; return 1; }
  rm -rf "$T"
}

# --reuse hands back a worktree that may already hold the file. Overwriting
# it would throw away whatever the last run put there.
test_delegate_leaves_an_existing_seed_target_alone() {
  _fanout_setup; _seed_yaml
  mkdir -p "$STUB_WT/apps/builder"
  printf 'MINE=1\n' > "$STUB_WT/apps/builder/.dev.vars"
  (cd "$T" && "$BIN" delegate widget WG-SEEDKEEP "$T/spec.md") > /dev/null
  assert_eq "$(cat "$STUB_WT/apps/builder/.dev.vars")" "MINE=1"
  [ ! -L "$STUB_WT/apps/builder/.dev.vars" ] || { echo "an existing file was replaced by a link"; return 1; }
  rm -rf "$T"
}

# The seeded paths are gitignored BECAUSE they were missing from the checkout.
# One that git would track is a commit waiting to happen, so it is named.
test_delegate_warns_when_a_seeded_path_is_not_gitignored() {
  _fanout_setup; _seed_yaml
  : > "$STUB_WT/.gitignore"
  local out; out="$(cd "$T" && "$BIN" delegate widget WG-SEEDTRACK "$T/spec.md")"
  assert_contains "$out" "git would track"
  rm -rf "$T"
}

# ── try: a running instance of a ticket, on ports of its own ────────────────
_preview_yaml() {
  cat >> "$T/workspace.yaml" <<'YAML'
    preview:
      cmd: "pnpm --filter builder dev"
      env: { API_PORT: "{port}", UI_PORT: "{port+1}" }
      url: "http://localhost:{port+1}"
YAML
}

_occupy() { # <port> - hold it for the life of the test
  python3 - "$1" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1)
print("up", flush=True)
time.sleep(120)
PY
  OCCUPIER=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

test_try_steps_past_an_occupied_port_base_and_runs_in_a_new_pane() {
  _fanout_setup; _preview_yaml
  (cd "$T" && "$BIN" delegate widget WG-TRY "$T/spec.md") > /dev/null
  _occupy 48610 || { echo "could not occupy the base port"; return 1; }
  local out; out="$(cd "$T" && CEL_TRY_PORT_BASE=48610 "$BIN" try WG-TRY)"
  kill "$OCCUPIER" 2>/dev/null
  assert_eq "$(printf '%s' "$out" | tail -1)" "http://localhost:48621"
  local log; log="$(cat "$STUB_LOG")"
  assert_contains "$log" "pane split --pane wZ:p1 --direction down --cwd $STUB_WT --no-focus"
  assert_contains "$log" "pane run wZ:p9 env API_PORT=48620 UI_PORT=48621 pnpm --filter builder dev"
  assert_eq "$(jq -r '.[0].try.port' "$T/.cel/delegations.json")" "48620"
  assert_eq "$(jq -r '.[0].try.url' "$T/.cel/delegations.json")" "http://localhost:48621"
  assert_eq "$(jq -r '.[0].try.pane' "$T/.cel/delegations.json")" "wZ:p9"
  rm -rf "$T"
}

# Asking twice must not start a second instance on a second port - it is the
# same ticket, and the answer is the url it is already on.
test_try_twice_is_a_no_op_that_prints_the_same_url() {
  _fanout_setup; _preview_yaml
  (cd "$T" && "$BIN" delegate widget WG-TRY2 "$T/spec.md") > /dev/null
  local first; first="$(cd "$T" && CEL_TRY_PORT_BASE=48640 "$BIN" try WG-TRY2 | tail -1)"
  : > "$STUB_LOG"
  local second; second="$(cd "$T" && CEL_TRY_PORT_BASE=48640 "$BIN" try WG-TRY2 | tail -1)"
  assert_eq "$second" "$first"
  ! grep -q '^pane split' "$STUB_LOG" || { echo "a second pane was split"; return 1; }
  rm -rf "$T"
}

test_try_stop_closes_the_pane_and_clears_the_row() {
  _fanout_setup; _preview_yaml
  (cd "$T" && "$BIN" delegate widget WG-TRYSTOP "$T/spec.md") > /dev/null
  (cd "$T" && CEL_TRY_PORT_BASE=48660 "$BIN" try WG-TRYSTOP) > /dev/null
  : > "$STUB_LOG"
  (cd "$T" && "$BIN" try WG-TRYSTOP --stop) > /dev/null
  assert_contains "$(cat "$STUB_LOG")" "pane close wZ:p9"
  assert_eq "$(jq -r '.[0].try // "none"' "$T/.cel/delegations.json")" "none"
  rm -rf "$T"
}

# Releasing the worktree under a running preview would leave a pane pointing
# at a directory that no longer exists.
test_release_stops_a_running_try_first() {
  _fanout_setup; _preview_yaml
  (cd "$T" && "$BIN" delegate widget WG-TRYREL "$T/spec.md") > /dev/null
  (cd "$T" && CEL_TRY_PORT_BASE=48680 "$BIN" try WG-TRYREL) > /dev/null
  : > "$STUB_LOG"
  (cd "$T" && "$BIN" release WG-TRYREL --keep-worktree) > /dev/null
  assert_contains "$(cat "$STUB_LOG")" "pane close wZ:p9"
  assert_eq "$(jq -r '.[0].try // "none"' "$T/.cel/delegations.json")" "none"
  assert_eq "$(jq -r '.[0].state' "$T/.cel/delegations.json")" "released"
  rm -rf "$T"
}

test_status_shows_the_try_port() {
  _fanout_setup; _preview_yaml
  (cd "$T" && "$BIN" delegate widget WG-TRYCOL "$T/spec.md") > /dev/null
  local out; out="$(cd "$T" && STUB_STATUS=working "$BIN" status)"
  assert_contains "$out" "TRY"
  (cd "$T" && CEL_TRY_PORT_BASE=48700 "$BIN" try WG-TRYCOL) > /dev/null
  out="$(cd "$T" && STUB_STATUS=working "$BIN" status)"
  assert_contains "$out" "48700"
  rm -rf "$T"
}

# Refusals say WHICH thing is missing: guessing between "no worktree" and
# "this repo has no preview" is the whole cost of a bad message here.
test_try_refuses_without_a_worktree_or_a_preview_cmd() {
  _fanout_setup
  (cd "$T" && "$BIN" delegate widget WG-NOPREV "$T/spec.md") > /dev/null
  local out; out="$(cd "$T" && "$BIN" try WG-NOPREV 2>&1 || true)"
  assert_contains "$out" "preview.cmd"
  jq '[.[0] | .worktree = "/nonexistent/wt"]' "$T/.cel/delegations.json" > "$T/l.json"
  mv "$T/l.json" "$T/.cel/delegations.json"
  out="$(cd "$T" && "$BIN" try WG-NOPREV 2>&1 || true)"
  assert_contains "$out" "worktree"
  rm -rf "$T"
}
