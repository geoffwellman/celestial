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
