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
