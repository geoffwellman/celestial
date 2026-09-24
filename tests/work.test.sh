# shellcheck shell=bash
# The WORK ITEM: the thing being made, as it moves from ticket to worktree to
# PR to merged to released. Every fact here comes from a fixture workspace, a
# fixture ledger, a fixture mailbox and stubbed `gh` and `cel-linear` - the
# join and the stage ordering are what is under test, never the network.
source "$CEL_ROOT/lib/work.sh"

_work_setup() { # builds a workspace with a ledger, a mailbox and stubs
  T="$(mktemp -d)"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  mkdir -p "$T/.cel" "$T/inbox" "$T/cache" "$T/bin" "$T/state"
  export CEL_CACHE="$T/cache" CEL_INBOX_DIR="$T/inbox"
  export CEL_AFK_STATE="$T/state/afk" CEL_REVIEWERS_STATE="$T/state/reviewers.json"
  export CEL_WORK_GH="$T/bin/gh" CEL_WORK_LINEAR="$T/bin/cel-linear"
  STUB_LOG="$T/stub.log"; : > "$STUB_LOG"
  cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$STUB_LOG"
[ -n "\${STUB_GH_FAIL:-}" ] && exit 1
cat "\${STUB_PRS:-$T/prs.json}" 2>/dev/null || echo '[]'
EOF
  cat > "$T/bin/cel-linear" <<EOF
#!/usr/bin/env bash
echo "linear \$*" >> "$STUB_LOG"
[ -n "\${STUB_LINEAR_FAIL:-}" ] && exit 1
cat "\${STUB_TIX:-$T/tix.jsonl}" 2>/dev/null || true
EOF
  chmod +x "$T/bin/gh" "$T/bin/cel-linear"
  printf '[]\n' > "$T/prs.json"
  : > "$T/tix.jsonl"
  printf '[]\n' > "$T/.cel/delegations.json"
  export STUB_LOG
}

_work_ledger() { printf '%s\n' "$1" > "$T/.cel/delegations.json"; }
_work_send()   { printf '%s\n' "$1" >> "$T/inbox/alpha.jsonl"; }

# --- 1. the ledger reads back a history even for rows written before it ----



test_a_row_with_no_history_reads_back_a_synthesised_one_and_disk_keeps_none() {
  _work_setup
  _work_ledger '[{"id":"WG-1-x","state":"released","created":"2026-01-01T00:00:00Z",
                  "verdict":{"at":"2026-01-02T00:00:00Z"},
                  "review":{"at":"2026-01-03T00:00:00Z","decision":"approved"}}]'
  local h; h="$(work_ledger_json "$T" | jq -c '.[0].history')"
  assert_contains "$h" '"state":"created"'
  assert_contains "$h" "2026-01-01T00:00:00Z"
  assert_contains "$h" "2026-01-02T00:00:00Z"
  assert_contains "$h" "2026-01-03T00:00:00Z"
  # never written back
  assert_eq "$(jq -r '.[0] | has("history")' "$T/.cel/delegations.json")" false
  rm -rf "$T"
}

# --- 2. the join ------------------------------------------------------------

test_join_keys_on_the_ticket_id_from_branch_delegation_and_pr_head() {
  _work_setup
  _work_ledger '[{"id":"wg-49-slug","repo":"widget","branch":"WG-49-retry","state":"running",
                  "created":"2026-01-01T00:00:00Z","ticket":"WG-49"}]'
  printf '%s\n' '[{"number":66,"title":"retry","headRefName":"WG-49-retry","state":"OPEN",
    "reviewDecision":"","statusCheckRollup":[],"createdAt":"2026-01-02T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}]' > "$T/prs.json"
  printf '%s\n' '{"identifier":"WG-49","title":"gateway retry","url":"http://x/WG-49","state":"In Progress","updatedAt":"2026-01-02T01:00:00Z"}' > "$T/tix.jsonl"
  local items; items="$(work_items "$T")"
  assert_eq "$(printf '%s\n' "$items" | wc -l)" 1
  assert_eq "$(printf '%s' "$items" | jq -r '.key')" WG-49
  assert_eq "$(printf '%s' "$items" | jq -r '.delegation.id')" wg-49-slug
  assert_eq "$(printf '%s' "$items" | jq -r '.pr.number')" 66
  assert_eq "$(printf '%s' "$items" | jq -r '.ticket.state')" "In Progress"
  assert_eq "$(printf '%s' "$items" | jq -r '.title')" "gateway retry"
  rm -rf "$T"
}

test_join_does_not_match_a_shorter_ticket_number_inside_a_longer_one() {
  _work_setup
  _work_ledger '[{"id":"d1","repo":"widget","branch":"WG-4-small","state":"running",
                  "created":"2026-01-01T00:00:00Z","ticket":"WG-4"}]'
  printf '%s\n' '[{"number":66,"title":"big","headRefName":"WG-49-retry","state":"OPEN",
    "reviewDecision":"","statusCheckRollup":[],"createdAt":"2026-01-02T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}]' > "$T/prs.json"
  local items; items="$(work_items "$T")"
  assert_eq "$(printf '%s\n' "$items" | wc -l)" 2
  assert_eq "$(printf '%s\n' "$items" | jq -r 'select(.key == "WG-4") | .pr // "none"')" none
  rm -rf "$T"
}

test_an_unticketed_delegation_keys_on_its_own_id_and_says_so() {
  _work_setup
  _work_ledger '[{"id":"adhoc-slug","repo":"widget","branch":"adhoc-slug","state":"running",
                  "created":"2026-01-01T00:00:00Z","ticket":""}]'
  local items; items="$(work_items "$T")"
  assert_eq "$(printf '%s' "$items" | jq -r '.key')" adhoc-slug
  assert_eq "$(printf '%s' "$items" | jq -r '.keyed_on')" delegation
  assert_eq "$(printf '%s' "$items" | jq -r '.ticket // "none"')" none
  rm -rf "$T"
}

# --- 3. the stage -----------------------------------------------------------

_stage() { work_stage "$1"; }

test_stage_released_beats_merged() {
  _work_setup
  assert_eq "$(_stage '{"delegation":{"state":"released"},"pr":{"state":"MERGED"}}')" released
  assert_eq "$(_stage '{"delegation":{"state":"landed"},"pr":{"state":"MERGED"}}')" merged
  rm -rf "$T"
}

test_stage_landing_needs_an_approved_green_pr() {
  _work_setup
  assert_eq "$(_stage '{"pr":{"state":"OPEN","review":"APPROVED","checks":"SUCCESS"}}')" landing
  assert_eq "$(_stage '{"pr":{"state":"OPEN","review":"APPROVED","checks":"FAILURE"}}')" review
  assert_eq "$(_stage '{"pr":{"state":"OPEN","review":"","checks":"SUCCESS"}}')" review
  rm -rf "$T"
}

# Celestial's reviewer records its verdict in the ledger and never posts a
# GitHub review, so reviewDecision is empty; `cel-fanout land` accepts the
# ledger verdict plus a passed gate, and so must the stage.
test_stage_landing_reads_the_ledger_review_and_gate() {
  _work_setup
  assert_eq "$(_stage '{"pr":{"state":"OPEN","review":"","checks":"SUCCESS"},
    "delegation":{"state":"collected","review":{"verdict":"approved"},"verdict":{"gate":true}}}')" landing
  # no durable approval
  assert_eq "$(_stage '{"pr":{"state":"OPEN","review":"","checks":"SUCCESS"},
    "delegation":{"state":"collected","review":{"verdict":"changes"},"verdict":{"gate":true}}}')" review
  assert_eq "$(_stage '{"pr":{"state":"OPEN","review":"","checks":"SUCCESS"},
    "delegation":{"state":"collected","review":null,"verdict":{"gate":true}}}')" review
  # approved, but the gate did not pass
  assert_eq "$(_stage '{"pr":{"state":"OPEN","review":"","checks":"SUCCESS"},
    "delegation":{"state":"collected","review":{"verdict":"approved"},"verdict":{"gate":false}}}')" review
  assert_eq "$(_stage '{"pr":{"state":"OPEN","review":"","checks":"SUCCESS"},
    "delegation":{"state":"collected","review":{"verdict":"approved"},"verdict":{"gate":null,"gate_outcome":"no_verdict"}}}')" review
  # approved and gated, but a red check is still a refusal at land
  assert_eq "$(_stage '{"pr":{"state":"OPEN","review":"","checks":"FAILURE"},
    "delegation":{"state":"collected","review":{"verdict":"approved"},"verdict":{"gate":true}}}')" review
  # merged precedence unchanged
  assert_eq "$(_stage '{"pr":{"state":"MERGED","review":""},
    "delegation":{"state":"landed","review":{"verdict":"approved"},"verdict":{"gate":true}}}')" merged
  rm -rf "$T"
}

test_events_carry_ticket_created_and_updated_in_order() {
  _work_setup
  _work_ledger '[{"id":"WG-49-x","repo":"widget","branch":"WG-49-x","ticket":"WG-49","state":"running",
                  "created":"2026-01-03T00:00:00Z"}]'
  printf '[]\n' > "$T/prs.json"
  printf '%s\n' '{"identifier":"WG-49","title":"retry","url":"http://x","state":"In Progress","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-04T00:00:00Z"}' > "$T/tix.jsonl"
  local it; it="$(work_items "$T")"
  local tev; tev="$(printf '%s' "$it" | jq -c '[.events[] | select(.source == "ticket")]')"
  assert_eq "$(printf '%s' "$tev" | jq -r 'length')" 2
  assert_eq "$(printf '%s' "$tev" | jq -r '.[0].at + " " + .[0].what')" "2026-01-01T00:00:00Z created"
  assert_eq "$(printf '%s' "$tev" | jq -r '.[1].at')" 2026-01-04T00:00:00Z
  assert_contains "$(printf '%s' "$tev" | jq -r '.[1].what')" updated
  assert_eq "$(printf '%s' "$it" | jq -r '.ticket.created')" 2026-01-01T00:00:00Z
  assert_eq "$(printf '%s' "$it" | jq -r '.events | map(.at) | (. == sort)')" true
  rm -rf "$T"
}

test_stage_building_ready_and_backlog() {
  _work_setup
  assert_eq "$(_stage '{"delegation":{"state":"running"}}')" building
  assert_eq "$(_stage '{"delegation":{"state":"collected"}}')" building
  assert_eq "$(_stage '{"delegation":{"state":"unconfirmed"}}')" building
  assert_eq "$(_stage '{"ticket":{"state":"Todo"}}')" ready
  assert_eq "$(_stage '{"ticket":{"state":"Backlog"}}')" backlog
  rm -rf "$T"
}

test_a_gate_with_no_verdict_does_not_render_as_failed() {
  _work_setup
  _work_ledger '[{"id":"WG-7-x","repo":"widget","branch":"WG-7-x","ticket":"WG-7","state":"collected",
                  "created":"2026-01-01T00:00:00Z",
                  "verdict":{"gate":null,"gate_outcome":"no_verdict","at":"2026-01-02T00:00:00Z"}}]'
  local item; item="$(work_items "$T")"
  assert_eq "$(printf '%s' "$item" | jq -r '.delegation.verdict.gate_outcome')" no_verdict
  assert_eq "$(printf '%s' "$item" | jq -r '.stage')" building
  local out; out="$(cmd_work "$T" 2>&1)"
  case "$out" in *failed*) printf 'a no-verdict gate rendered as failed: %s\n' "$out" >&2; return 1;; esac
  rm -rf "$T"
}

# --- 4. the events ----------------------------------------------------------

test_events_carry_every_source_including_mail_older_than_a_day() {
  _work_setup
  _work_ledger '[{"id":"WG-49-x","repo":"widget","branch":"WG-49-x","ticket":"WG-49","state":"landed",
                  "created":"2026-01-01T00:00:00Z",
                  "history":[{"state":"running","at":"2026-01-01T00:00:00Z","by":"orchestrator"},
                             {"state":"landed","at":"2026-01-05T00:00:00Z","by":"orchestrator"}]}]'
  printf '%s\n' '[{"number":66,"title":"retry","headRefName":"WG-49-x","state":"MERGED",
    "reviewDecision":"APPROVED","statusCheckRollup":[],"createdAt":"2026-01-02T00:00:00Z",
    "mergedAt":"2026-01-05T00:00:00Z","updatedAt":"2026-01-05T00:00:00Z"}]' > "$T/prs.json"
  printf '%s\n' '{"identifier":"WG-49","title":"retry","url":"http://x","state":"Done","updatedAt":"2026-01-04T00:00:00Z"}' > "$T/tix.jsonl"
  # a message from 2020: the old timeline windowed to 24 hours and lost it
  _work_send '{"id":"1","ts":"2020-01-01T00:00:00Z","to":"alpha-orch","from":"w1","kind":"status","message":"WG-49: done"}'
  local ev; ev="$(work_items "$T" | jq -c '.events')"
  assert_contains "$ev" '"source":"worktree"'
  assert_contains "$ev" '"source":"pr"'
  assert_contains "$ev" '"source":"ticket"'
  assert_contains "$ev" '"source":"mail"'
  assert_contains "$ev" '2020-01-01T00:00:00Z'
  # newest last
  assert_eq "$(printf '%s' "$ev" | jq -r 'map(.at) | (. == sort)')" true
  rm -rf "$T"
}

test_events_include_the_afk_acts_and_the_reviewer_registry() {
  _work_setup
  _work_ledger '[{"id":"WG-49-x","repo":"widget","branch":"WG-49-x","ticket":"WG-49","state":"landed",
                  "created":"2026-01-01T00:00:00Z"}]'
  mkdir -p "$T/state/afk"
  printf '%s\n' '{"at":"2026-01-05T02:00:00Z","act":"land","authorisation":"pre-auth 2","detail":"widget #66 WG-49-x"}' \
    > "$T/state/afk/log.jsonl"
  printf '%s\n' '[{"repo":"widget","pr":66,"pane":"wZ:p2","agent":"widget-pr-66-review","started_at":"2026-01-03T00:00:00Z"}]' \
    > "$T/state/reviewers.json"
  printf '%s\n' '[{"number":66,"title":"retry","headRefName":"WG-49-x","state":"MERGED",
    "reviewDecision":"APPROVED","statusCheckRollup":[],"createdAt":"2026-01-02T00:00:00Z",
    "mergedAt":"2026-01-05T00:00:00Z","updatedAt":"2026-01-05T00:00:00Z"}]' > "$T/prs.json"
  local ev; ev="$(work_items "$T" | jq -c '.events')"
  assert_contains "$ev" '"source":"afk"'
  assert_contains "$ev" '"source":"reviewer"'
  rm -rf "$T"
}

# --- 5. the verbs -----------------------------------------------------------

_two_items() {
  _work_ledger '[{"id":"WG-49-x","repo":"widget","branch":"WG-49-x","ticket":"WG-49","state":"running",
                  "created":"2026-01-01T00:00:00Z","worker":"wZ:p1","profile":"opus-pi",
                  "history":[{"state":"running","at":"2026-01-01T00:00:00Z","by":"orchestrator"}]},
                 {"id":"WG-51-y","repo":"widget","branch":"WG-51-y","ticket":"WG-51","state":"landed",
                  "created":"2026-01-02T00:00:00Z",
                  "history":[{"state":"landed","at":"2026-01-06T00:00:00Z","by":"orchestrator"}]}]'
  printf '%s\n' '[{"number":66,"title":"the console answers","headRefName":"WG-51-y","state":"MERGED",
    "reviewDecision":"APPROVED","statusCheckRollup":[],"createdAt":"2026-01-03T00:00:00Z",
    "mergedAt":"2026-01-06T00:00:00Z","updatedAt":"2026-01-06T00:00:00Z"}]' > "$T/prs.json"
  printf '%s\n' '{"identifier":"WG-49","title":"gateway retry","url":"http://x","state":"In Progress","updatedAt":"2026-01-02T00:00:00Z"}' > "$T/tix.jsonl"
}

test_cel_work_groups_by_stage_and_names_the_next_action() {
  _work_setup; _two_items
  local out; out="$(cmd_work "$T")"
  assert_contains "$out" "building"
  assert_contains "$out" "merged"
  assert_contains "$out" "WG-49"
  assert_contains "$out" "gateway retry"
  assert_contains "$out" "collect"     # the next action for building
  assert_contains "$out" "release"     # the next action for merged
  rm -rf "$T"
}

test_cel_work_one_key_renders_one_item_with_its_events() {
  _work_setup; _two_items
  local out; out="$(cmd_work "$T" WG-51)"
  assert_contains "$out" "WG-51"
  assert_contains "$out" "#66"
  assert_contains "$out" "pr"
  case "$out" in *WG-49*) printf 'one item rendered another: %s\n' "$out" >&2; return 1;; esac
  assert_eq "$(cmd_work "$T" WG-51 --json | jq -r '.key')" WG-51
  rm -rf "$T"
}

test_cel_history_groups_by_item_with_a_spine_newest_group_first() {
  _work_setup; _two_items
  local out; out="$(cmd_history "$T" --since 99999d)"
  assert_contains "$out" "alpha - work history"
  assert_contains "$out" "+- WG-51"
  assert_contains "$out" "+- WG-49"
  assert_contains "$out" "|"
  # WG-51 moved most recently, so its group is first
  local first second
  first="$(printf '%s\n' "$out" | grep -n '+- WG-51' | head -1 | cut -d: -f1)"
  second="$(printf '%s\n' "$out" | grep -n '+- WG-49' | head -1 | cut -d: -f1)"
  [ "$first" -lt "$second" ] || { printf 'groups are not ordered by most recent event\n' >&2; return 1; }
  assert_eq "$(cmd_history "$T" --since 99999d --json | jq -r '.[0].key')" WG-51
  assert_eq "$(cmd_history "$T" --since 99999d --key WG-49 --json | jq -r 'length')" 1
  rm -rf "$T"
}

# --- 6. the cache and the failures -----------------------------------------

test_the_cache_is_written_once_for_two_runs_and_fresh_bypasses_it() {
  _work_setup; _two_items
  work_items "$T" >/dev/null
  work_items "$T" >/dev/null
  assert_eq "$(grep -c '^gh ' "$STUB_LOG")" 1
  work_items "$T" --fresh >/dev/null
  assert_eq "$(grep -c '^gh ' "$STUB_LOG")" 2
  [ -f "$CEL_CACHE/work-alpha.json" ] || { printf 'no cache file was written\n' >&2; return 1; }
  rm -rf "$T"
}

test_with_gh_and_linear_both_failing_the_ledger_and_mail_parts_still_render() {
  _work_setup; _two_items
  _work_send '{"id":"1","ts":"2026-01-04T00:00:00Z","to":"alpha-orch","from":"w1","kind":"status","message":"WG-49: building"}'
  local out; out="$(STUB_GH_FAIL=1 STUB_LINEAR_FAIL=1 cmd_work "$T" --fresh)"
  assert_contains "$out" "WG-49"
  local ev; ev="$(STUB_GH_FAIL=1 STUB_LINEAR_FAIL=1 work_items "$T" --fresh | jq -sc 'map(.events) | add')"
  assert_contains "$ev" '"source":"mail"'
  assert_contains "$ev" '"source":"worktree"'
  rm -rf "$T"
}

# A STAMP IS A MOMENT, NOT A STRING. The ledger writes UTC and the mailbox
# writes local time with an offset, so ordering the text put every message ten
# hours late: the first real read of this box showed mail announcing a merge
# sitting BELOW the merge it announced.
test_events_order_on_the_moment_not_the_text_across_timezones() {
  _work_setup
  _work_ledger '[{"id":"WG-49-x","repo":"widget","branch":"WG-49-x","ticket":"WG-49","state":"landed",
                  "created":"2026-01-01T00:00:00Z",
                  "history":[{"state":"landed","at":"2026-01-05T04:00:00Z","by":"orchestrator"}]}]'
  # 2026-01-05T13:00:00+10:00 is 03:00Z - BEFORE the landing, though its text sorts after
  _work_send '{"id":"1","ts":"2026-01-05T13:00:00+10:00","to":"alpha-orch","from":"w1","kind":"status","message":"WG-49: pushed"}'
  local order; order="$(work_items "$T" | jq -r '.events | map(.source) | join(",")')"
  assert_eq "$order" "mail,worktree"
  rm -rf "$T"
}

# NO WORKSPACE NAMED IS EVERY WORKSPACE - even when run from inside one.
test_cel_work_with_no_workspace_lists_every_workspace_even_from_inside_one() {
  _work_setup
  local A="$T/wsa" B="$T/wsb"
  mkdir -p "$A/.cel" "$B/.cel"
  cp "$T/workspace.yaml" "$A/"; cp "$T/workspace.yaml" "$B/"
  printf '[{"id":"WG-7-x","repo":"widget","branch":"WG-7-x","ticket":"WG-7","state":"running","created":"2026-01-01T00:00:00Z"}]' > "$A/.cel/delegations.json"
  printf '[{"id":"WG-8-y","repo":"widget","branch":"WG-8-y","ticket":"WG-8","state":"running","created":"2026-01-01T00:00:00Z"}]' > "$B/.cel/delegations.json"
  local oldreg="${CEL_REGISTRY:-}"
  export CEL_REGISTRY="$T/registry.yaml"
  printf 'workspaces:\n  wsa:\n    path: %s\n  wsb:\n    path: %s\n' "$A" "$B" > "$CEL_REGISTRY"
  local out; out="$(cd "$A" && cmd_work --json)"
  CEL_REGISTRY="$oldreg"
  assert_contains "$out" WG-7
  assert_contains "$out" WG-8
  rm -rf "$T"
}

test_work_items_json_carries_no_internal_sort_field() {
  _work_setup
  _work_ledger '[{"id":"WG-7-x","repo":"widget","branch":"WG-7-x","ticket":"WG-7","state":"running","created":"2026-01-01T00:00:00Z"}]'
  assert_eq "$(work_items "$T" | jq -r 'has("last_sec")')" false
  rm -rf "$T"
}

# A lowercase branch names the same ticket: abc-49-fix is ABC-49.
test_join_matches_a_lowercase_ticket_prefix_and_keys_on_uppercase() {
  _work_setup
  _work_ledger '[{"id":"wg-49-fix","repo":"widget","branch":"wg-49-fix","state":"running",
                  "created":"2026-01-01T00:00:00Z","ticket":""}]'
  printf '%s\n' '[{"number":66,"title":"retry","headRefName":"wg-49-fix","state":"OPEN",
    "reviewDecision":"","statusCheckRollup":[],"createdAt":"2026-01-02T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}]' > "$T/prs.json"
  printf '%s\n' '{"identifier":"WG-49","title":"gateway retry","url":"http://x/WG-49","state":"In Progress","updatedAt":"2026-01-02T01:00:00Z"}' > "$T/tix.jsonl"
  local items; items="$(work_items "$T")"
  assert_eq "$(printf '%s\n' "$items" | wc -l)" 1
  assert_eq "$(printf '%s' "$items" | jq -r '.key')" WG-49
  assert_eq "$(printf '%s' "$items" | jq -r '.ticket.id')" WG-49
  assert_eq "$(printf '%s' "$items" | jq -r '.delegation.id')" wg-49-fix
  assert_eq "$(printf '%s' "$items" | jq -r '.pr.number')" 66
  rm -rf "$T"
}

# Two repos can both have a PR #7. A reviewer or an AFK act on one of them is
# not part of the other's story.
test_reviewer_and_afk_events_join_on_repo_and_pr_number() {
  _work_setup
  cat >> "$T/workspace.yaml" <<'YAML'
  - name: gadget
    url: git@github.com:someone/gadget.git
    prefix: ABC
    gate: bun test
YAML
  printf '[{"number":7,"title":"w","headRefName":"WG-1-w","state":"OPEN","reviewDecision":"","statusCheckRollup":[],"createdAt":"2026-01-02T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}]' > "$T/prs-widget.json"
  printf '[{"number":7,"title":"g","headRefName":"ABC-2-g","state":"OPEN","reviewDecision":"","statusCheckRollup":[],"createdAt":"2026-01-02T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}]' > "$T/prs-gadget.json"
  cat > "$T/bin/gh" <<GH
#!/usr/bin/env bash
case "\$*" in *someone/gadget*) cat "$T/prs-gadget.json";; *) cat "$T/prs-widget.json";; esac
GH
  chmod +x "$T/bin/gh"
  printf '[{"repo":"widget","pr":"7","pane":"p1","agent":"widget-pr-7-review","started_at":"2026-01-03T00:00:00Z"}]' > "$CEL_REVIEWERS_STATE"
  mkdir -p "$CEL_AFK_STATE"
  printf '%s\n' '{"at":"2026-01-04T00:00:00Z","act":"land","authorisation":"a1","detail":"someone/widget#7 (WG-1-w) - approved"}' > "$CEL_AFK_STATE/log.jsonl"
  local items; items="$(work_items "$T" --fresh)"
  local w g
  w="$(printf '%s\n' "$items" | jq -c 'select(.key == "WG-1") | .events')"
  g="$(printf '%s\n' "$items" | jq -c 'select(.key == "ABC-2") | .events')"
  assert_contains "$w" '"source":"reviewer"'
  assert_contains "$w" '"source":"afk"'
  case "$g" in *'"reviewer"'*|*'"afk"'*) printf 'gadget #7 took widget #7 events: %s\n' "$g" >&2; return 1;; esac
  rm -rf "$T"
}

# --json IS ONE DOCUMENT: across workspaces it is one array, each item carrying
# its ws - never one array per workspace, concatenated.
test_history_json_across_workspaces_is_one_valid_document() {
  _work_setup
  local A="$T/wsa" B="$T/wsb"
  mkdir -p "$A/.cel" "$B/.cel"
  cp "$T/workspace.yaml" "$A/"; sed 's/^name: alpha/name: beta/' "$T/workspace.yaml" > "$B/workspace.yaml"
  printf '[{"id":"WG-7-x","repo":"widget","branch":"WG-7-x","ticket":"WG-7","state":"running","created":"2026-01-01T00:00:00Z"}]' > "$A/.cel/delegations.json"
  printf '[{"id":"WG-8-y","repo":"widget","branch":"WG-8-y","ticket":"WG-8","state":"running","created":"2026-01-02T00:00:00Z"}]' > "$B/.cel/delegations.json"
  local oldreg="${CEL_REGISTRY:-}"
  export CEL_REGISTRY="$T/registry.yaml"
  printf 'workspaces:\n  alpha:\n    path: %s\n  beta:\n    path: %s\n' "$A" "$B" > "$CEL_REGISTRY"
  local out; out="$(cd "$T" && cmd_history --since 99999d --json)"
  CEL_REGISTRY="$oldreg"
  assert_eq "$(printf '%s' "$out" | jq -s 'length')" 1
  assert_eq "$(printf '%s' "$out" | jq -r 'type')" array
  assert_eq "$(printf '%s' "$out" | jq -r 'map(.ws) | sort | join(",")')" alpha,beta
  assert_eq "$(printf '%s' "$out" | jq -r 'map(.key) | join(",")')" WG-8,WG-7
  rm -rf "$T"
}
