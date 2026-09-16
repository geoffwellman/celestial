# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/inbox.sh"

_inbox_sandbox() { CEL_INBOX_DIR="$(mktemp -d)"; }
# die() is exit: run a function in a subshell so assert_fails sees a status
_inbox_sub() { ( "$@" ); }

# An item is delivered ONCE per recipient: the cursor is what makes a Monitor
# and the catch-up hook safe to run against the same mailbox.
test_inbox_read_is_once_per_recipient() {
  _inbox_sandbox
  _inbox_send root "first" --from w1:p1 --workspace demo >/dev/null 2>&1
  _inbox_send root "second" --from w1:p1 --workspace demo >/dev/null 2>&1
  local out; out="$(_inbox_read --for root --workspace demo)"
  assert_contains "$out" "first"
  assert_contains "$out" "second"
  assert_eq "$(_inbox_read --for root --workspace demo)" ""
  assert_eq "$(_inbox_count --for root --workspace demo)" "0"
  # a different recipient has its own cursor and has read nothing
  _inbox_send games-orch "yours" --workspace demo >/dev/null 2>&1
  assert_eq "$(_inbox_count --for games-orch --workspace demo)" "1"
  assert_eq "$(_inbox_count --for root --workspace demo)" "0"
  rm -rf "$CEL_INBOX_DIR"
}

test_inbox_addresses_all_and_filters_by_recipient() {
  _inbox_sandbox
  _inbox_send all "broadcast" --workspace demo >/dev/null 2>&1
  _inbox_send someone-else "not yours" --workspace demo >/dev/null 2>&1
  local out; out="$(_inbox_read --for root --workspace demo)"
  assert_contains "$out" "broadcast"
  ! printf '%s' "$out" | grep -q 'not yours' || { echo "read another agent's mail"; return 1; }
  rm -rf "$CEL_INBOX_DIR"
}

# --all re-reads without disturbing the cursor: what a human runs to look.
test_inbox_all_does_not_consume() {
  _inbox_sandbox
  _inbox_send root "keep me" --workspace demo >/dev/null 2>&1
  assert_contains "$(_inbox_read --for root --workspace demo --all)" "keep me"
  assert_eq "$(_inbox_count --for root --workspace demo)" "1"
  rm -rf "$CEL_INBOX_DIR"
}

test_inbox_count_is_zero_for_an_empty_mailbox() {
  _inbox_sandbox
  assert_eq "$(_inbox_count --for root --workspace nothing-here)" "0"
  rm -rf "$CEL_INBOX_DIR"
}

# The message body survives quoting hostile enough to break a shell append.
test_inbox_survives_quotes_and_newlines() {
  _inbox_sandbox
  _inbox_send root "it's \"quoted\" and has a \$dollar" --workspace demo >/dev/null 2>&1
  assert_contains "$(_inbox_read --for root --workspace demo)" 'it'"'"'s "quoted" and has a $dollar'
  rm -rf "$CEL_INBOX_DIR"
}

# ---- decisions are a ledger, not a queue ----------------------------------
# `read` moves a cursor; a question that needs an answer must not be buried by
# the next status message. A decision or blocker stays OPEN until a resolution
# record names it, however many reads happen in between.
test_open_decision_survives_being_read() {
  _inbox_sandbox
  local id; id="$(_inbox_send root "ship v2 or wait?" --kind decision --from games-orch --workspace demo 2>/dev/null)"
  _inbox_send root "fyi build green" --from games-orch --workspace demo >/dev/null 2>&1
  _inbox_read --for root --workspace demo >/dev/null      # consumes both
  assert_eq "$(_inbox_count --for root --workspace demo)" "0"
  local open; open="$(_inbox_open --for root --workspace demo)"
  assert_contains "$open" "ship v2 or wait?"
  assert_contains "$open" "$id"
  rm -rf "$CEL_INBOX_DIR"
}
test_resolve_clears_it_and_only_it() {
  _inbox_sandbox
  local a b
  a="$(_inbox_send root "q1" --kind decision --workspace demo 2>/dev/null)"
  b="$(_inbox_send root "q2" --kind blocked --workspace demo 2>/dev/null)"
  _inbox_resolve "$a" --by human --workspace demo >/dev/null 2>&1
  local open; open="$(_inbox_open --for root --workspace demo)"
  ! printf '%s' "$open" | grep -q "q1" || { echo "resolved decision still open"; return 1; }
  assert_contains "$open" "q2"
  assert_contains "$open" "$b"
  rm -rf "$CEL_INBOX_DIR"
}
test_status_mail_never_appears_in_open() {
  _inbox_sandbox
  _inbox_send root "just a status" --workspace demo >/dev/null 2>&1
  _inbox_send root "an escalation" --kind escalation --workspace demo >/dev/null 2>&1
  assert_eq "$(_inbox_open --for root --workspace demo)" ""
  rm -rf "$CEL_INBOX_DIR"
}
# Resolution records are bookkeeping: they must never show up as mail.
test_resolutions_are_invisible_to_read_and_count() {
  _inbox_sandbox
  local a; a="$(_inbox_send root "q" --kind decision --workspace demo 2>/dev/null)"
  _inbox_read --for root --workspace demo >/dev/null
  _inbox_resolve "$a" --by human --workspace demo >/dev/null 2>&1
  assert_eq "$(_inbox_count --for root --workspace demo)" "0"
  assert_eq "$(_inbox_read --for root --workspace demo)" ""
  rm -rf "$CEL_INBOX_DIR"
}
test_resolve_refuses_an_unknown_or_non_decision_id() {
  _inbox_sandbox
  local s; s="$(_inbox_send root "status" --workspace demo 2>/dev/null)"
  assert_fails _inbox_sub _inbox_resolve "$s" --workspace demo
  assert_fails _inbox_sub _inbox_resolve 000 --workspace demo
  rm -rf "$CEL_INBOX_DIR"
}
test_send_rejects_an_unknown_kind() {
  _inbox_sandbox
  assert_fails _inbox_sub _inbox_send root "x" --kind urgent --workspace demo
  rm -rf "$CEL_INBOX_DIR"
}

# ---- the Stop hook -----------------------------------------------------------
# Blocks ONCE when decisions are open, then lets the next stop through - a
# guard that could loop would be worse than the buried decision it prevents.
_hook_env() { # run the hook with a fake cel that reports N open decisions
  local n="$1" bin; bin="$(mktemp -d)"
  cat > "$bin/cel" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "inbox whoami") echo tester;;
  "inbox open")   for i in \$(seq 1 $n); do echo "[\$i] decision from x: q\$i"; done;;
esac
EOF
  chmod +x "$bin/cel"
  # the hook resolves cel from CEL_ROOT/bin/cel
  mkdir -p "$bin/root/bin"; cp "$bin/cel" "$bin/root/bin/cel"
  HOOK_ROOT="$bin/root"; HOOK_TMP="$(mktemp -d)"
}
test_stop_hook_blocks_once_then_passes() {
  _hook_env 2
  local err
  err="$(CEL_ROOT="$HOOK_ROOT" TMPDIR="$HOOK_TMP" bash "$CEL_ROOT/tools/hooks/inbox-guard.sh" 2>&1 >/dev/null)" && { echo "did not block with 2 open"; return 1; }
  assert_contains "$err" "2 unresolved"
  assert_contains "$err" "cel inbox open"
  CEL_ROOT="$HOOK_ROOT" TMPDIR="$HOOK_TMP" bash "$CEL_ROOT/tools/hooks/inbox-guard.sh" >/dev/null 2>&1 || { echo "blocked a second time in the same turn"; return 1; }
  rm -rf "$HOOK_ROOT" "$HOOK_TMP"
}
test_stop_hook_passes_with_nothing_open() {
  _hook_env 0
  CEL_ROOT="$HOOK_ROOT" TMPDIR="$HOOK_TMP" bash "$CEL_ROOT/tools/hooks/inbox-guard.sh" >/dev/null 2>&1 || { echo "blocked with nothing open"; return 1; }
  rm -rf "$HOOK_ROOT" "$HOOK_TMP"
}
test_stop_hook_fails_open_without_cel() {
  CEL_ROOT="$(mktemp -d)" bash "$CEL_ROOT/tools/hooks/inbox-guard.sh" >/dev/null 2>&1 || { echo "failed closed with no cel"; return 1; }
}

# A pane derives its own mailbox with _inbox_sanitise - lowercased, cut to 32
# characters - but the sender wrote whatever string it had to hand, and the two
# agreed only by luck. Observed in a live inbox: fifty-odd messages across a
# dozen phantom mailboxes, several of them the same recipient spelled two ways.
test_the_recipient_is_normalised_at_send_time() {
  local T; T="$(mktemp -d)"; export CEL_INBOX_DIR="$T"
  cel_inbox_send() { ( CEL_INBOX_ME=tester _inbox_send "$@" --workspace w ); }
  cel_inbox_send 'widget-WG-20-Faithful-Integrity' 'upper and long' >/dev/null
  cel_inbox_send 'widget-wg-20-faithful-integrity' 'already canonical' >/dev/null
  # both land in ONE mailbox, the one the recipient will actually look in
  local tos; tos="$(jq -r '.to' "$T/w.jsonl" | sort -u)"
  assert_eq "$(printf '%s\n' "$tos" | wc -l)" "1"
  assert_eq "$tos" "$(_inbox_sanitise 'widget-wg-20-faithful-integrity')"
  rm -rf "$T"
}
# ...and a recipient addressed in full still reaches a pane that answers to the
# truncated form, which is every worker with a long branch name.
test_an_overlong_recipient_reaches_the_pane_that_truncates() {
  local T; T="$(mktemp -d)"; export CEL_INBOX_DIR="$T"
  ( CEL_INBOX_ME=tester _inbox_send 'product-platform-wg-46-terminal-transcript-durability' 'hi' --workspace w ) >/dev/null
  local to; to="$(jq -r '.to' "$T/w.jsonl")"
  assert_eq "$to" "$(CEL_INBOX_ME='' bash -c 'source "$1/lib/inbox.sh"; _inbox_sanitise "product-platform-wg-46-terminal-transcript-durability"' _ "$CEL_ROOT")"
  [ "${#to}" -le 32 ] || { echo "recipient not truncated: $to"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
# The broadcast address is not a pane name and must survive untouched.
test_the_broadcast_address_is_left_alone() {
  local T; T="$(mktemp -d)"; export CEL_INBOX_DIR="$T"
  ( CEL_INBOX_ME=tester _inbox_send all 'everyone' --workspace w ) >/dev/null
  assert_eq "$(jq -r '.to' "$T/w.jsonl")" "all"
  rm -rf "$T"
}

# --- prune ------------------------------------------------------------------
_prune_fixture() { # a mailbox with mail for a live worker, a dead one, and root
  T="$(mktemp -d)"; export CEL_INBOX_DIR="$T"
  ( CEL_INBOX_ME=t _inbox_send widget-wg-1-live  'to the living' --workspace w ) >/dev/null
  ( CEL_INBOX_ME=t _inbox_send widget-wg-2-dead  'to the departed' --workspace w ) >/dev/null
  ( CEL_INBOX_ME=t _inbox_send root              'to root' --workspace w ) >/dev/null
  ( CEL_INBOX_ME=t _inbox_send widget-orch       'to the orchestrator' --workspace w ) >/dev/null
  STUB="$T/herdr"; cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
echo '{"result":{"agents":[{"name":"widget-wg-1-live"}]}}'
EOS
  chmod +x "$STUB"; export PATH="$T:$PATH"
}
test_prune_archives_mail_for_workers_that_no_longer_exist() {
  _prune_fixture
  _inbox_prune --workspace w >/dev/null
  local left; left="$(jq -r '.to' "$T/w.jsonl" | sort -u | tr '\n' ' ')"
  assert_contains "$left" "widget-wg-1-live"
  assert_contains "$left" "root"
  assert_contains "$left" "widget-orch"
  ! printf '%s' "$left" | grep -q "wg-2-dead" || { echo "dead worker's mail kept"; rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/w.archive.jsonl")" "to the departed"
  rm -rf "$T"
}
# Root and the orchestrators are restarted routinely - a compaction, a model
# change, a crash - and mail sent while one was down is what it most needs on
# the way back up.
test_prune_never_touches_root_or_an_orchestrator() {
  _prune_fixture
  _inbox_prune --workspace w >/dev/null
  assert_contains "$(cat "$T/w.jsonl")" "to root"
  assert_contains "$(cat "$T/w.jsonl")" "to the orchestrator"
  rm -rf "$T"
}
# herdr being unreachable is not evidence that everyone died.
test_prune_refuses_when_the_roster_is_unreadable() {
  _prune_fixture
  printf '#!/usr/bin/env bash\necho "{}"\n' > "$T/herdr"; chmod +x "$T/herdr"
  _inbox_prune --workspace w >/dev/null 2>&1
  assert_contains "$(cat "$T/w.jsonl")" "to the departed"
  rm -rf "$T"
}
test_prune_dry_run_changes_nothing() {
  _prune_fixture
  local before; before="$(wc -l < "$T/w.jsonl")"
  _inbox_prune --workspace w --dry-run >/dev/null
  assert_eq "$(wc -l < "$T/w.jsonl")" "$before"
  rm -rf "$T"
# A PRODUCT orchestrator stands in <ws>/products/<p>, not in a repo checkout,
# and until it was taught that coordinate it drained root's mailbox - the same
# silent theft of root's mail the repos/ case was written to stop. Identity
# still comes from the PATH: no workspace.yaml lookup, no env plumbing.

_inbox_ws_fixture() { # a workspace dir with a product and a repo, in $IT
  IT="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$IT/"
  mkdir -p "$IT/products/bundle/notes" "$IT/repos/lone"
}
test_inbox_me_is_the_product_orchestrator_under_products() {
  _inbox_ws_fixture
  assert_eq "$(cd "$IT/products/bundle" && _inbox_me)" "bundle-orch"
  assert_eq "$(cd "$IT/products/bundle/notes" && _inbox_me)" "bundle-orch"
  rm -rf "$IT"
}
test_inbox_me_still_knows_repos_and_root() {
  _inbox_ws_fixture
  assert_eq "$(cd "$IT/repos/lone" && _inbox_me)" "lone-orch"
  assert_eq "$(cd "$IT" && _inbox_me)" "root"
  rm -rf "$IT"
}
