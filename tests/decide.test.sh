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
# ask refuses a question with no real context; every fixture gives one
# (a later --context in "$@" wins).
DECIDE_CTX="The widget build broke after the alpha merge and the beta release waits on it. Option one ships today with a known gap; option two waits a day. I recommend one; if nobody answers, beta slips."
_ask_as() { # <asker> <ws> args...
  local who="$1" ws="$2"; shift 2
  CEL_INBOX_ME="$who" cmd_decide ask --workspace "$ws" --context "$DECIDE_CTX" "$@" 2>/dev/null
}

test_ask_then_list_shows_it_once_with_the_recommendation() {
  _decide_fixture
  local id
  id="$(_ask_as alpha-orch alpha --title "pick a style" \
    --option "flat::quick, plain" --option "glossy::slower, prettier" \
    --recommend 2 --blocks "the landing page" --context "docs/style.md - $DECIDE_CTX")"
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
# An agent's own questions: --workspace and --asker narrow the list.
test_list_narrows_to_a_workspace_and_an_asker() {
  _decide_fixture
  _ask_as alpha-orch alpha --title "alpha's question" --option "a::x" >/dev/null
  _ask_as bundle-orch bundle --title "bundle's question" --option "b::y" >/dev/null
  _ask_as other-orch bundle --title "other's question" --option "c::z" >/dev/null
  local out
  out="$(cmd_decide list --workspace bundle --asker bundle-orch 2>/dev/null)"
  assert_contains "$out" "bundle's question"
  case "$out" in *"alpha's question"*|*"other's question"*) echo "filter let others through: $out"; rm -rf "$T"; return 1;; esac
  assert_eq "$(cmd_decide list --json --workspace bundle 2>/dev/null | wc -l | tr -d ' ')" 2
  assert_contains "$(cmd_decide list --asker nobody-orch 2>&1)" "no open owner decisions from nobody-orch"
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

# A mistyped --workspace must not invent a mailbox nobody lists.
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

# An urgent question sorts first on the dashboard; the flag has to
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

# A re-ask that does not repeat --urgent is not a downgrade;
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

# --- the asker closes its own question ---------------------------------------
# A question settled in chat, made moot by a merge, or replaced by a newer one
# can be closed by the orchestrator that asked it, not only by the owner.
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

# A same-title re-ask updates in place and would silently leave the superseded
# question open. Refused, nothing written.
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

# The owner's history shows why a question went away.
test_withdraw_reason_is_in_the_resolution_message() {
  _decide_fixture
  local id; id="$(_ask_as alpha-orch alpha --title "why gone?")"
  CEL_INBOX_ME=alpha-orch cmd_decide withdraw "$id" --why "merged in another PR" >/dev/null 2>&1
  assert_contains "$(jq -r 'select(.kind == "resolution") | .message' "$CEL_INBOX_DIR/alpha.jsonl")" "merged in another PR"
  rm -rf "$T"
}

# --- a decision carries enough context to decide from the card ---------------
test_cel113_ask_refuses_without_context() {
  _decide_fixture
  local out
  out="$(CEL_INBOX_ME=alpha-orch cmd_decide ask --workspace alpha --title "no ctx" --option "a::x" 2>&1)" \
    && { echo "ask with no context was accepted"; rm -rf "$T"; return 1; }
  assert_contains "$out" "--context"
  assert_contains "$out" "recommend"
  assert_eq "$(cmd_decide list --json 2>/dev/null | grep -c 'no ctx' || true)" "0"
  rm -rf "$T"
}
test_cel113_ask_refuses_thin_or_bare_url_context() {
  _decide_fixture
  assert_fails env CEL_INBOX_ME=alpha-orch bash -c 'source "$CEL_ROOT/lib/common.sh"; source "$CEL_ROOT/lib/decide.sh"; cmd_decide ask --workspace alpha --title "thin" --context "see the PR"' 
  assert_fails env CEL_INBOX_ME=alpha-orch bash -c 'source "$CEL_ROOT/lib/common.sh"; source "$CEL_ROOT/lib/decide.sh"; cmd_decide ask --workspace alpha --title "url" --context "https://example.com/widget/pull/12345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890"'
  assert_eq "$(cmd_decide list --json 2>/dev/null | wc -l | tr -d ' ')" "0"
  rm -rf "$T"
}
test_cel113_ask_accepts_real_context_with_a_url_on_top() {
  _decide_fixture
  local id; id="$(_ask_as alpha-orch alpha --title "ctx ok" --context "$DECIDE_CTX https://example.com/widget/pull/7")"
  [ -n "$id" ] || { echo "real context was refused"; rm -rf "$T"; return 1; }
  # re-asking the same title still updates the one record in place
  local id2; id2="$(_ask_as alpha-orch alpha --title "ctx ok" --context "$DECIDE_CTX and more")"
  assert_eq "$id2" "$id"
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -r 'select(.title=="ctx ok") | .context')" "$DECIDE_CTX and more"
  rm -rf "$T"
}

# --pr links a question to the PR it blocks, repeatable, kept on the
# record so the steward stops calling that PR a worker finding.
test_ask_pr_links_are_stored_on_the_record() {
  _decide_fixture
  _ask_as alpha-orch alpha --title "top up" --pr "widget#7" --pr "gadget#3" >/dev/null
  local j; j="$(cmd_decide list --json 2>/dev/null)"
  assert_eq "$(printf '%s\n' "$j" | jq -r '[.prs[].ref] | join(",")')" "widget#7,gadget#3"
  if (_ask_as alpha-orch alpha --title "bad" --pr "widget7" >/dev/null); then echo "bad --pr accepted"; return 1; fi
  if (_ask_as alpha-orch alpha --title "bad" --pr "a#1#2" >/dev/null); then echo "a#1#2 accepted"; return 1; fi
  if (_ask_as alpha-orch alpha --title "bad" --pr >/dev/null); then echo "missing --pr value accepted"; return 1; fi
  rm -rf "$T"
}

# A re-ask is the current word on which PRs wait - dropping
# --pr unlinks them - and every repo URL form resolves to a PR link.
test_reask_without_pr_unlinks_and_ssh_urls_resolve() {
  _decide_fixture
  printf 'name: alpha\nrepos:\n  - {name: widget, url: "ssh://git@github.com/someone/widget.git"}\n' > "$T/alpha/workspace.yaml"
  _ask_as alpha-orch alpha --title "top up" --pr "widget#7" >/dev/null
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -r '.prs[0].url')" "https://github.com/someone/widget/pull/7"
  _ask_as alpha-orch alpha --title "top up" >/dev/null
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -c '.prs')" "[]"
  rm -rf "$T"
}

# --- routing a question to the people who hold its role (B.4, C4) -----------
# alpha declares people; bundle declares none (every workspace on the box today).
#   sam: owner everywhere; jo: qa for atlas; ann: design for atlas.
_decide_people_fixture() {
  _decide_fixture
  cat > "$T/alpha/workspace.yaml" <<'YML'
name: alpha
repos:
  - {name: atlas-web}
products:
  - name: atlas
    repos: [atlas-web]
people:
  - id: sam
    login: sam-example
    roles: [owner]
  - id: jo
    login: jo-example
    products: {atlas: [qa]}
  - id: ann
    login: ann-example
    products: {atlas: [design]}
YML
}
_decide_me() { # <id|""> - this login's person in alpha
  if [ -n "$1" ]; then printf 'me: %s\n' "$1" > "$T/alpha/workspace.local.yaml"
  else rm -f "$T/alpha/workspace.local.yaml"; fi
}
_decide_rec() { # <id> -> the decision record as filed in alpha
  jq -c --arg id "$1" 'select(.id == $id and .kind == "decision")' "$CEL_INBOX_DIR/alpha.jsonl"
}

test_route_goes_to_the_role_holders_of_the_askers_product() {
  _decide_people_fixture
  local id r; id="$(_ask_as atlas-orch alpha --title "ship the qa build?" --topic qa)"
  r="$(_decide_rec "$id")"
  assert_eq "$(jq -r .topic <<< "$r")" "qa" || { rm -rf "$T"; return 1; }
  assert_eq "$(jq -c .route <<< "$r")" '{"role":"qa","product":"atlas","people":["jo"]}' || { rm -rf "$T"; return 1; }
  # `to` is unchanged, so every existing reader keeps working
  assert_eq "$(jq -r .to <<< "$r")" "owner" || { rm -rf "$T"; return 1; }
  # a lane's mailbox (<p>-<lane>) and a launch's CEL_PRODUCT name the product too
  id="$(_ask_as atlas-ui alpha --title "which palette?" --topic design)"
  assert_eq "$(_decide_rec "$id" | jq -c .route.people)" '["ann"]' || { rm -rf "$T"; return 1; }
  id="$(CEL_PRODUCT=atlas _ask_as root alpha --title "pick qa env" --topic qa)"
  assert_eq "$(_decide_rec "$id" | jq -r .route.product)" "atlas" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_route_falls_back_to_the_owners_and_defaults_to_topic_owner() {
  _decide_people_fixture
  local id; id="$(_ask_as atlas-orch alpha --title "cut a release?" --topic release)"
  assert_eq "$(_decide_rec "$id" | jq -c .route)" '{"role":"release","product":"atlas","people":["sam"]}' || { rm -rf "$T"; return 1; }
  id="$(_ask_as atlas-orch alpha --title "no topic given")"
  assert_eq "$(_decide_rec "$id" | jq -r '.topic + " " + (.route.people | join(","))')" "owner sam" || { rm -rf "$T"; return 1; }
  # merge maps to approver: nobody holds it, so the owners again
  id="$(_ask_as atlas-orch alpha --title "merge it?" --topic merge)"
  assert_eq "$(_decide_rec "$id" | jq -r '.route.role + " " + (.route.people | join(","))')" "approver sam" || { rm -rf "$T"; return 1; }
  local out; out="$(CEL_INBOX_ME=atlas-orch cmd_decide ask --workspace alpha --context "$DECIDE_CTX" --title bad --topic legal 2>&1)" \
    && { echo "an unknown topic was accepted"; rm -rf "$T"; return 1; }
  assert_contains "$out" "--topic must be one of product qa design release merge owner" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# THE BOX TODAY: no people: anywhere, and the owner answers everything from
# the dashboard. Nothing about that changes: no route, --by is still free
# text, anyone may answer or drop, and nothing new is refused.
test_without_people_nothing_is_routed_and_answering_is_unchanged() {
  _decide_fixture
  local id r; id="$(_ask_as bundle-orch bundle --title "unrouted" --topic qa --option "a::x")"
  r="$(jq -c --arg id "$id" 'select(.id == $id)' "$CEL_INBOX_DIR/bundle.jsonl")"
  assert_eq "$(jq -r 'has("route")' <<< "$r")" "false" || { rm -rf "$T"; return 1; }
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -c '[.me, .mine, .answerable]')" '[null,true,true]' || { rm -rf "$T"; return 1; }
  CEL_INBOX_ME=console cmd_decide answer "$id" 1 --by dashboard >/dev/null 2>&1 || { echo "the dashboard's answer was refused"; rm -rf "$T"; return 1; }
  assert_contains "$(jq -c 'select(.kind == "resolution")' "$CEL_INBOX_DIR/bundle.jsonl")" '"by":"dashboard"' || { rm -rf "$T"; return 1; }
  id="$(_ask_as bundle-orch bundle --title "drop me")"
  CEL_INBOX_ME=ana cmd_decide drop "$id" --why moot --by dashboard >/dev/null 2>&1 || { echo "drop was refused"; rm -rf "$T"; return 1; }
  assert_eq "$(cmd_decide list --json 2>/dev/null)" "" || { rm -rf "$T"; return 1; }
  # the same with people: declared but nobody holding the role, nor an owner
  printf 'name: bundle\npeople:\n  - {id: kim, roles: [design]}\n' > "$T/bundle/workspace.yaml"
  id="$(_ask_as bundle-orch bundle --title "still unrouted" --topic qa)"
  assert_eq "$(jq -c --arg id "$id" 'select(.id == $id) | has("route")' "$CEL_INBOX_DIR/bundle.jsonl")" "false" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_answer_by_must_be_this_logins_person() {
  _decide_people_fixture
  local id out; id="$(_ask_as atlas-orch alpha --title "qa q" --topic qa --option "a::x")"
  _decide_me jo
  out="$(cmd_decide answer "$id" 1 --by bob 2>&1)" && { echo "a foreign --by was accepted"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cel decide answer: --by bob is not this login's person (me: jo) - an answer is recorded under who gave it" || { rm -rf "$T"; return 1; }
  out="$(cmd_decide drop "$id" --why x --by bob 2>&1)" && { echo "a foreign --by dropped it"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cel decide drop: --by bob is not this login's person (me: jo)" || { rm -rf "$T"; return 1; }
  # a holder answers, as itself, with or without --by
  cmd_decide answer "$id" 1 --by jo >/dev/null 2>&1 || { echo "the holder was refused"; rm -rf "$T"; return 1; }
  assert_contains "$(jq -c 'select(.kind == "resolution")' "$CEL_INBOX_DIR/alpha.jsonl")" '"by":"jo"' || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_a_non_holder_is_refused_and_an_owner_override_is_recorded() {
  _decide_people_fixture
  local id out; id="$(_ask_as atlas-orch alpha --title "qa q" --topic qa --option "a::x")"
  _decide_me ann
  out="$(cmd_decide answer "$id" 1 2>&1)" && { echo "a non-holder answered"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cel decide answer: $id is routed to qa for atlas (jo); this login is ann - only they or an owner answer it" || { rm -rf "$T"; return 1; }
  ( cmd_decide drop "$id" --why x >/dev/null 2>&1 ) && { echo "a non-holder dropped it"; rm -rf "$T"; return 1; }
  # a login that names no person cannot answer a routed question
  _decide_me ""
  out="$(cmd_decide answer "$id" 1 --by dashboard 2>&1)" && { echo "a me-less login answered a routed question"; rm -rf "$T"; return 1; }
  assert_contains "$out" "this login names no person" || { rm -rf "$T"; return 1; }
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -r .title)" "qa q" || { rm -rf "$T"; return 1; }
  # an owner may answer anyone's question; the record says it was an override
  _decide_me sam
  cmd_decide answer "$id" 1 >/dev/null 2>&1 || { echo "the owner was refused"; rm -rf "$T"; return 1; }
  assert_contains "$(jq -c 'select(.kind == "resolution")' "$CEL_INBOX_DIR/alpha.jsonl")" '"by":"sam (owner)"' || { rm -rf "$T"; return 1; }
  assert_contains "$(cmd_inbox read --for atlas-orch --workspace alpha --all 2>/dev/null)" 'from sam (owner)' || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# An agent never answers or drops an owner question, whatever --by says and
# whatever its shell exports. Core keeps relaying, only on an unrouted one.
test_an_agent_is_refused_and_core_relays_only_unrouted() {
  _decide_people_fixture
  local id out; id="$(_ask_as atlas-orch alpha --title "qa q" --topic qa --option "a::x")"
  _decide_me jo
  out="$(CEL_ROLE=solo cmd_decide answer "$id" 1 2>&1)" && { echo "an agent answered"; rm -rf "$T"; return 1; }
  assert_contains "$out" "cel decide answer: an agent does not answer an owner question - atlas-orch waits for a person" || { rm -rf "$T"; return 1; }
  ( CEL_ROLE=solo cmd_decide drop "$id" --why x >/dev/null 2>&1 ) && { echo "an agent dropped"; rm -rf "$T"; return 1; }
  ( CEL_ROLE=core cmd_decide answer "$id" 1 >/dev/null 2>&1 ) && { echo "core answered a routed question"; rm -rf "$T"; return 1; }
  # the role its LAUNCH carries counts, not what its shell now says
  local P="$T/proc"; mkdir -p "$P/$PPID" "$P/4242"
  printf '%s\0' CEL_ROLE=solo CEL_PRODUCT=atlas > "$P/4242/environ"
  printf '4242 (omp) S 1 1 1' > "$P/4242/stat"
  printf '%s\0' HOME=/h > "$P/$PPID/environ"
  printf '%s (bash) S 4242 1 1' "$PPID" > "$P/$PPID/stat"
  ( CEL_PROC_DIR="$P" cmd_decide answer "$id" 1 >/dev/null 2>&1 ) && { echo "an agent that unset CEL_ROLE answered"; rm -rf "$T"; return 1; }
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -r 'select(.workspace == "alpha") | .title')" "qa q" || { rm -rf "$T"; return 1; }
  # core relays the owner's word on an unrouted question, as today
  local u; u="$(_ask_as bundle-orch bundle --title "unrouted" --option "a::x")"
  CEL_ROLE=core cmd_decide answer "$u" 1 >/dev/null 2>&1 || { echo "core could not relay an unrouted answer"; rm -rf "$T"; return 1; }
  # the asking agent still withdraws its own routed question
  CEL_ROLE=solo CEL_INBOX_ME=atlas-orch cmd_decide withdraw "$id" --why "settled" >/dev/null 2>&1 || { echo "the asker could not withdraw"; rm -rf "$T"; return 1; }
  assert_eq "$(cmd_decide list --json 2>/dev/null)" "" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_list_narrows_to_mine_a_person_and_a_topic() {
  _decide_people_fixture
  _ask_as atlas-orch alpha --title "for jo" --topic qa >/dev/null
  _ask_as atlas-orch alpha --title "for ann" --topic design >/dev/null
  _ask_as bundle-orch bundle --title "for anyone" >/dev/null
  _decide_me jo
  # mine: routed to me, or to nobody (anyone may answer those)
  assert_eq "$(cmd_decide list --json --mine 2>/dev/null | jq -r .title | sort | tr '\n' ,)" "for anyone,for jo," || { rm -rf "$T"; return 1; }
  assert_eq "$(cmd_decide list --json --for ann 2>/dev/null | jq -r .title | sort | tr '\n' ,)" "for ann,for anyone," || { rm -rf "$T"; return 1; }
  assert_eq "$(cmd_decide list --json --topic design 2>/dev/null | jq -r .title)" "for ann" || { rm -rf "$T"; return 1; }
  # an unrouted question with no --topic is topic owner
  assert_eq "$(cmd_decide list --json --topic owner 2>/dev/null | jq -r .title)" "for anyone" || { rm -rf "$T"; return 1; }
  assert_contains "$(cmd_decide list --mine 2>/dev/null)" "routed to qa for atlas (jo)" || { rm -rf "$T"; return 1; }
  # what this login may answer, said per record for the dashboard
  assert_eq "$(cmd_decide list --json 2>/dev/null | jq -r 'select(.workspace == "alpha") | "\(.title)=\(.me) \(.mine) \(.answerable)"' | sort | tr '\n' ,)" \
    "for ann=jo false false,for jo=jo true true," || { rm -rf "$T"; return 1; }
  _decide_me ""
  local out; out="$(cmd_decide list --mine 2>&1)" && { echo "--mine with no me listed something"; rm -rf "$T"; return 1; }
  assert_contains "$out" "names no person" || { rm -rf "$T"; return 1; }
  ( cmd_decide list --topic legal >/dev/null 2>&1 ) && { echo "list took an unknown topic"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
