# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/learn.sh"

# A workspace's learnings: tiered, decaying, budgeted, never deleted.
_lws() { T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"; export CEL_LEARN_TODAY=2026-09-12; }
_lsub() { ( "$@" ); }

test_add_and_list_round_trip() {
  _lws
  _learn_add "a runtime's vault beats the environment" --dir "$T" 2>/dev/null
  _learn_add "always keep this" --pin --dir "$T" 2>/dev/null
  _learn_add "the freeze ends friday" --perishable --dir "$T" 2>/dev/null
  local out; out="$(_learn_list --dir "$T")"
  assert_contains "$out" "always keep this"
  assert_contains "$out" "vault beats the environment  [aging 0d]"
  assert_contains "$out" "freeze ends friday  [perishable 0d]"
  # pinned lives in its own section, undated
  assert_contains "$(_learn_pinned "$T")" "always keep this"
  ! _learn_pinned "$T" | grep -q '<!--' || { echo "pinned entry carries a clock"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_stale_is_computed_per_tier() {
  _lws; _learn_init "$T"
  printf -- '- old aging <!--a:2026-08-01-->\n- fresh aging <!--a:2026-09-01-->\n- old perishable <!--p:2026-09-01-->\n- fresh perishable <!--p:2026-09-10-->\n' >> "$T/learnings.md"
  local out; out="$(_learn_list --dir "$T")"
  assert_contains "$out" "old aging  [aging 42d STALE]"
  assert_contains "$out" "fresh aging  [aging 11d]"
  assert_contains "$out" "old perishable  [perishable 11d STALE]"
  assert_contains "$out" "fresh perishable  [perishable 2d]"
  rm -rf "$T"
}

# Stale never means deleted: it moves to the archive with provenance.
test_stow_archives_stale_with_provenance_and_keeps_the_rest() {
  _lws; _learn_init "$T"
  printf -- '- old aging <!--a:2026-08-01-->\n- fresh aging <!--a:2026-09-01-->\n' >> "$T/learnings.md"
  _learn_stow --dir "$T" >/dev/null 2>&1
  local kept; kept="$(_learn_entries "$T")"
  assert_contains "$kept" "fresh aging"
  ! printf '%s' "$kept" | grep -q "old aging" || { echo "stale entry kept"; rm -rf "$T"; return 1; }
  local arc; arc="$(cat "$T/.cel/learnings-archive.md")"
  assert_contains "$arc" "old aging"
  assert_contains "$arc" "tier:a last:2026-08-01 reason:unreinforced 42d"
  rm -rf "$T"
}

test_pinned_survives_stow() {
  _lws
  _learn_add "standing rule" --pin --dir "$T" 2>/dev/null
  _learn_stow --dir "$T" >/dev/null 2>&1
  assert_contains "$(_learn_pinned "$T")" "standing rule"
  rm -rf "$T"
}

test_reinforce_refreshes_the_date_and_keeps_the_tier() {
  _lws; _learn_init "$T"
  printf -- '- keep me <!--p:2026-09-01-->\n' >> "$T/learnings.md"
  _learn_reinforce 1 --dir "$T" 2>/dev/null
  assert_contains "$(_learn_entries "$T")" "keep me <!--p:2026-09-12-->"
  ( assert_fails _lsub _learn_reinforce 9 --dir "$T" )
  rm -rf "$T"
}

# Over budget, stow archives aging entries OLDEST-REINFORCED first and stops
# as soon as the block fits. Pinned is never touched.
test_stow_enforces_the_budget_oldest_first() {
  _lws; _learn_init "$T"
  export CEL_LEARN_BUDGET=400
  _LEARN_BUDGET=400
  _learn_add "pinned rule that stays" --pin --dir "$T" 2>/dev/null
  local i; for i in 1 2 3 4 5 6; do
    printf -- '- fact number %s padding padding padding padding padding padding <!--a:2026-09-0%s-->\n' "$i" "$i" >> "$T/learnings.md"
  done
  _learn_stow --dir "$T" >/dev/null 2>&1
  local kept; kept="$(_learn_entries "$T")"
  # the oldest (09-01, 09-02, ...) went first; the newest survive
  assert_contains "$kept" "fact number 6"
  ! printf '%s' "$kept" | grep -q "fact number 1 " || { echo "oldest entry survived a budget cut"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/.cel/learnings-archive.md")" "reason:over budget"
  assert_contains "$(_learn_pinned "$T")" "pinned rule that stays"
  local blk; blk="$(_learn_render --dir "$T")"; [ "${#blk}" -le 400 ] || { echo "block still over budget: ${#blk}"; rm -rf "$T"; return 1; }
  unset CEL_LEARN_BUDGET; _LEARN_BUDGET=2500
  rm -rf "$T"
}

# The block agents get: pinned first, fresh entries newest-first, stale
# omitted, nothing at all when there is nothing to say.
test_render_shape_and_emptiness() {
  _lws
  assert_eq "$(_learn_render --dir "$T")" ""
  _learn_init "$T"
  _learn_add "a rule" --pin --dir "$T" 2>/dev/null
  printf -- '- older <!--a:2026-09-01-->\n- newer <!--a:2026-09-10-->\n- gone <!--a:2026-01-01-->\n' >> "$T/learnings.md"
  local blk; blk="$(_learn_render --dir "$T")"
  assert_contains "$blk" "## Workspace learnings"
  assert_contains "$blk" "- a rule"
  ! printf '%s' "$blk" | grep -q "gone" || { echo "stale entry rendered"; rm -rf "$T"; return 1; }
  # newest first
  [ "$(printf '%s' "$blk" | grep -n "newer" | cut -d: -f1)" -lt "$(printf '%s' "$blk" | grep -n "older" | cut -d: -f1)" ] || { echo "not newest first"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The policy block every agent receives carries the learnings, and only when
# there are any.
test_policy_block_carries_learnings_only_when_present() {
  source "$CEL_ROOT/lib/workspace.sh"
  _lws
  ! ws_policy_block "$T" | grep -q "Workspace learnings" || { echo "block present with no file"; rm -rf "$T"; return 1; }
  _learn_add "we learned this" --dir "$T" 2>/dev/null
  assert_contains "$(ws_policy_block "$T")" "we learned this"
  rm -rf "$T"
}
