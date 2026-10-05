# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/decide.sh"

# Two registered workspaces and a mailbox dir, nothing from the live box.
_decide_fixture() {
  T="$(mktemp -d)"
  export HOME="$T/home"; mkdir -p "$HOME"
  export CEL_REGISTRY="$T/registry.yaml"
  export CEL_INBOX_DIR="$T/inbox"; mkdir -p "$CEL_INBOX_DIR"
  mkdir -p "$T/alpha" "$T/bundle"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n  bundle: {path: "%s/bundle"}\n' "$T" "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\n' > "$T/alpha/workspace.yaml"
  printf 'name: bundle\n' > "$T/bundle/workspace.yaml"
}
_ask_as() { # <asker> <ws> args...
  local who="$1" ws="$2"; shift 2
  CEL_INBOX_ME="$who" cmd_decide ask --workspace "$ws" "$@" 2>/dev/null
}

test_ask_then_list_shows_it_once_with_the_recommendation() {
  _decide_fixture
  local id
  id="$(_ask_as alpha-orch alpha --title "pick a style" \
    --option "flat::quick, plain" --option "glossy::slower, prettier" \
    --recommend 2 --blocks "the landing page" --context "docs/style.md")"
  [ -n "$id" ] || { echo "ask printed no id"; return 1; }
  local out; out="$(cmd_decide list 2>/dev/null)"
  assert_eq "$(printf '%s\n' "$out" | grep -c 'pick a style' || true)" "1"
  assert_contains "$out" "alpha"
  assert_contains "$out" "alpha-orch"
  assert_contains "$out" "glossy"
  assert_contains "$out" "the landing page"
  assert_contains "$out" "docs/style.md"
  local j; j="$(cmd_decide list --json 2>/dev/null)"
  assert_eq "$(printf '%s\n' "$j" | jq -r '.recommended')" "2"
  assert_eq "$(printf '%s\n' "$j" | jq -r '.workspace')" "alpha"
  assert_eq "$(printf '%s\n' "$j" | jq -r '.asker')" "alpha-orch"
  rm -rf "$T"
}

test_reasking_the_same_title_updates_rather_than_duplicates() {
  _decide_fixture
  local a b
  a="$(_ask_as alpha-orch alpha --title "pick a name" --option "ana::short")"
  b="$(_ask_as alpha-orch alpha --title "pick a name" --option "ana::short" --option "bob::shorter")"
  assert_eq "$b" "$a"
  local j; j="$(cmd_decide list --json 2>/dev/null)"
  assert_eq "$(printf '%s\n' "$j" | grep -c . || true)" "1"
  assert_eq "$(printf '%s\n' "$j" | jq -r '.options | length')" "2"
  # a different asker with the same title is a different question
  _ask_as bundle-orch alpha --title "pick a name" >/dev/null
  assert_eq "$(cmd_decide list --json 2>/dev/null | grep -c . || true)" "2"
  rm -rf "$T"
}

test_answer_resolves_and_delivers_only_to_the_asker() {
  _decide_fixture
  CEL_INBOX_ME=w cmd_inbox send gadget-orch "unrelated" --workspace bundle >/dev/null 2>&1
  local before; before="$(cmd_inbox read --for gadget-orch --workspace bundle --all 2>/dev/null)"
  local id; id="$(_ask_as gadget-orch bundle --title "merge now?" --option "yes::ship" --option "no::wait")"
  CEL_INBOX_ME=console cmd_decide answer "$id" 1 >/dev/null 2>&1
  assert_eq "$(cmd_decide list --json 2>/dev/null)" ""
  local mail; mail="$(cmd_inbox read --for gadget-orch --workspace bundle --all --json 2>/dev/null | jq -c 'select(.message | startswith("ANSWER to"))')"
  assert_contains "$mail" 'ANSWER to \"merge now?\": yes'
  assert_eq "$(printf '%s' "$mail" | jq -r .kind)" "status"
  # nobody else got it, and earlier mail is untouched
  assert_eq "$(cmd_inbox read --for root --workspace bundle --all 2>/dev/null)" ""
  assert_contains "$(cmd_inbox read --for gadget-orch --workspace bundle --all 2>/dev/null)" "$before"
  # the answerer is recorded
  assert_contains "$(jq -c 'select(.kind == "resolution")' "$CEL_INBOX_DIR/bundle.jsonl")" '"by":"console"'
  # free text is an answer too
  id="$(_ask_as gadget-orch bundle --title "colour?")"
  CEL_INBOX_ME=ana cmd_decide answer "$id" "teal, like the logo" >/dev/null 2>&1
  assert_contains "$(cmd_inbox read --for gadget-orch --workspace bundle --all 2>/dev/null)" 'teal, like the logo'
  rm -rf "$T"
}

test_drop_resolves_and_tells_the_asker() {
  _decide_fixture
  local id; id="$(_ask_as alpha-orch alpha --title "old question")"
  CEL_INBOX_ME=ana cmd_decide drop "$id" --why "superseded" >/dev/null 2>&1
  assert_eq "$(cmd_decide list --json 2>/dev/null)" ""
  local mail; mail="$(cmd_inbox read --for alpha-orch --workspace alpha --all 2>/dev/null)"
  assert_contains "$mail" "old question"
  assert_contains "$mail" "superseded"
  rm -rf "$T"
}

test_migrate_dry_run_lists_only_reminders_and_apply_keeps_real_decisions() {
  _decide_fixture
  local f="$CEL_INBOX_DIR/alpha.jsonl"
  printf '%s\n' \
    '{"id":"1","ts":"2020-01-01T00:00:00Z","from":"steward","to":"root","kind":"blocked","message":"steward: you have 3 UNRESOLVED decision(s)/blocker(s)"}' \
    '{"id":"2","ts":"2020-01-01T00:00:00Z","from":"alpha-orch","to":"root","kind":"decision","message":"which vendor?"}' \
    '{"id":"3","ts":"2020-01-01T00:00:00Z","from":"steward","to":"root","kind":"blocked","message":"REMINDER for ana: recap"}' \
    '{"id":"4","ts":"2020-01-01T00:00:00Z","from":"steward","to":"root","kind":"blocked","message":"STALLED WORKER widget (w:p9)"}' > "$f"
  local out; out="$(cmd_decide migrate 2>/dev/null)"
  assert_contains "$out" "UNRESOLVED"
  assert_contains "$out" "REMINDER"
  if printf '%s' "$out" | grep -q 'which vendor\|STALLED'; then echo "migrate listed a real item"; return 1; fi
  # the dry run wrote nothing
  assert_eq "$(jq -c 'select(.kind == "resolution")' "$f")" ""
  cmd_decide migrate --apply >/dev/null 2>&1
  local open; open="$(cmd_inbox open --for root --workspace alpha 2>/dev/null)"
  assert_contains "$open" "which vendor"
  assert_contains "$open" "STALLED WORKER"
  if printf '%s' "$open" | grep -q 'UNRESOLVED\|REMINDER'; then echo "reminder still open"; return 1; fi
  rm -rf "$T"
}

# Review on #117: a mistyped --workspace must not invent a mailbox nobody lists.
test_ask_refuses_an_unknown_workspace() {
  _decide_fixture
  assert_fails eval '( _ask_as alpha-orch alhpa --title x )'
  [ ! -e "$CEL_INBOX_DIR/alhpa.jsonl" ] || { echo "created a mailbox for a typo"; return 1; }
  rm -rf "$T"
}

# Two orchestrator processes re-asking at once still leave one record.
test_concurrent_reasks_leave_one_record() {
  _decide_fixture
  local i; for i in 1 2 3 4 5 6; do _ask_as alpha-orch alpha --title "same q" >/dev/null & done; wait
  assert_eq "$(cmd_decide list --json 2>/dev/null | grep -c . || true)" "1"
  rm -rf "$T"
}

# All-digit text is an option number only when such an option exists, and
# --text forces free text either way.
test_numeric_free_text_is_an_answer() {
  _decide_fixture
  local id; id="$(_ask_as alpha-orch alpha --title "which year?" --option "now::fast")"
  CEL_INBOX_ME=ana cmd_decide answer "$id" 2026 >/dev/null 2>&1
  assert_contains "$(cmd_inbox read --for alpha-orch --workspace alpha --all 2>/dev/null)" ': 2026'
  id="$(_ask_as alpha-orch alpha --title "how many?" --option "one::x")"
  CEL_INBOX_ME=ana cmd_decide answer "$id" --text 1 >/dev/null 2>&1
  assert_contains "$(cmd_inbox read --for alpha-orch --workspace alpha --all 2>/dev/null)" '"how many?": 1 '
  rm -rf "$T"
}

# Two answers racing (double-click, two tabs) resolve once and tell the asker once.
test_concurrent_answers_resolve_once() {
  _decide_fixture
  local id; id="$(_ask_as alpha-orch alpha --title "race" --option "a::x")"
  local i; for i in 1 2 3 4 5; do ( CEL_INBOX_ME=ana cmd_decide answer "$id" 1 >/dev/null 2>&1 ) & done; wait
  assert_eq "$(jq -c 'select(.kind == "resolution")' "$CEL_INBOX_DIR/alpha.jsonl" | grep -c . || true)" "1"
  assert_eq "$(jq -c 'select(.to == "alpha-orch")' "$CEL_INBOX_DIR/alpha.jsonl" | grep -c . || true)" "1"
  rm -rf "$T"
}

# --option is strict: a number naming no option is refused, not taken as text.
test_answer_option_flag_refuses_a_missing_option() {
  _decide_fixture
  local id; id="$(_ask_as alpha-orch alpha --title "q" --option "a::x")"
  assert_fails eval "( CEL_INBOX_ME=ana cmd_decide answer $id --option 9 >/dev/null 2>&1 )"
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -r .title)" "q"
  CEL_INBOX_ME=ana cmd_decide answer "$id" --option 1 >/dev/null 2>&1
  assert_contains "$(cmd_inbox read --for alpha-orch --workspace alpha --all 2>/dev/null)" '"q": a '
  rm -rf "$T"
}

# CEL-99: an urgent question sorts first on the dashboard; the flag has to
# survive the round trip through the mailbox, and a re-ask can raise it.
test_urgent_flag_round_trips_and_defaults_off() {
  _decide_fixture
  _ask_as alpha-orch alpha --title "calm one" --option "a::x" >/dev/null
  _ask_as alpha-orch alpha --title "hot one" --option "a::x" --urgent >/dev/null
  local j; j="$(cmd_decide list --json 2>/dev/null)"
  assert_eq "$(printf '%s\n' "$j" | jq -r 'select(.title == "calm one") | .urgent')" "false"
  assert_eq "$(printf '%s\n' "$j" | jq -r 'select(.title == "hot one") | .urgent')" "true"
  _ask_as alpha-orch alpha --title "calm one" --option "a::x" --urgent >/dev/null
  j="$(cmd_decide list --json 2>/dev/null)"
  assert_eq "$(printf '%s\n' "$j" | jq -r 'select(.title == "calm one") | .urgent')" "true"
  assert_contains "$(cmd_decide list 2>/dev/null)" "URGENT"
  rm -rf "$T"
}

# Review on #125: a re-ask that does not repeat --urgent is not a downgrade;
# the flag stays until the question is answered.
test_reask_without_urgent_keeps_it_urgent() {
  _decide_fixture
  _ask_as alpha-orch alpha --title "hot one" --option "a::x" --urgent >/dev/null
  _ask_as alpha-orch alpha --title "hot one" --option "a::y" >/dev/null
  local j; j="$(cmd_decide list --json 2>/dev/null)"
  assert_eq "$(printf '%s\n' "$j" | jq -r '.urgent')" "true"
  assert_eq "$(printf '%s\n' "$j" | jq -r '.options[0].tradeoff')" "y"
  rm -rf "$T"
}

# --- CEL-101: the asker closes its own question ------------------------------
# Some open questions were settled in an orchestrator's chat, made moot by a
# merge, or replaced by a newer one; only the owner could close them.
test_withdraw_by_the_asker_resolves_it() {
  _decide_fixture
  local id; id="$(_ask_as alpha-orch alpha --title "still needed?")"
  CEL_INBOX_ME=alpha-orch cmd_decide withdraw "$id" --why "settled in chat" >/dev/null 2>&1
  assert_eq "$(cmd_decide list --json 2>/dev/null)" ""
  local r; r="$(jq -c --arg id "$id" 'select(.kind == "resolution" and .ref == $id)' "$CEL_INBOX_DIR/alpha.jsonl")"
  assert_contains "$r" '"withdrawn":"settled in chat"'
  assert_contains "$r" '"by":"alpha-orch"'
  rm -rf "$T"
}

test_withdraw_by_anyone_else_is_refused() {
  _decide_fixture
  local id; id="$(_ask_as alpha-orch alpha --title "mine to close")"
  assert_fails eval "( CEL_INBOX_ME=bundle-orch cmd_decide withdraw '$id' --why nope >/dev/null 2>&1 )"
  # identity is derived, never a parameter
  assert_fails eval "( CEL_INBOX_ME=bundle-orch cmd_decide withdraw '$id' --why nope --by alpha-orch >/dev/null 2>&1 )"
  assert_fails eval "( CEL_INBOX_ME=alpha-orch cmd_decide withdraw '$id' >/dev/null 2>&1 )"
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -r .title)" "mine to close"
  rm -rf "$T"
}

test_ask_supersedes_closes_the_old_one_and_links_it() {
  _decide_fixture
  local old new; old="$(_ask_as alpha-orch alpha --title "old shape")"
  new="$(_ask_as alpha-orch alpha --title "new shape" --supersedes "$old")"
  [ -n "$new" ] && [ "$new" != "$old" ] || { echo "no new id"; return 1; }
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -r .title)" "new shape"
  local r; r="$(jq -c --arg id "$old" 'select(.kind == "resolution" and .ref == $id)' "$CEL_INBOX_DIR/alpha.jsonl")"
  assert_eq "$(printf '%s' "$r" | jq -r .superseded_by)" "$new"
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -r .supersedes)" "$old"
  # another asker's question cannot be superseded
  local theirs; theirs="$(_ask_as bundle-orch alpha --title "theirs")"
  assert_fails eval "( _ask_as alpha-orch alpha --title 'grab' --supersedes '$theirs' )"
  assert_contains "$(cmd_decide list --json 2>/dev/null | jq -r .title)" "theirs"
  rm -rf "$T"
}

# Review on #127: a same-title re-ask updates in place and would have
# silently left the superseded question open. Refused, nothing written.
test_supersedes_with_a_same_title_reask_is_refused() {
  _decide_fixture
  local a b; a="$(_ask_as alpha-orch alpha --title "first")"
  b="$(_ask_as alpha-orch alpha --title "second")"
  local before; before="$(wc -l < "$CEL_INBOX_DIR/alpha.jsonl")"
  assert_fails eval "( _ask_as alpha-orch alpha --title second --supersedes '$a' )"
  assert_fails eval "( _ask_as alpha-orch alpha --title first --supersedes '$a' )"
  assert_eq "$(wc -l < "$CEL_INBOX_DIR/alpha.jsonl")" "$before"
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -r .title | sort | tr '\n' ,)" "first,second,"
  rm -rf "$T"
}

# Review on #127: the owner's history shows why a question went away.
test_withdraw_reason_is_in_the_resolution_message() {
  _decide_fixture
  local id; id="$(_ask_as alpha-orch alpha --title "why gone?")"
  CEL_INBOX_ME=alpha-orch cmd_decide withdraw "$id" --why "merged in another PR" >/dev/null 2>&1
  assert_contains "$(jq -r 'select(.kind == "resolution") | .message' "$CEL_INBOX_DIR/alpha.jsonl")" "merged in another PR"
  rm -rf "$T"
}
