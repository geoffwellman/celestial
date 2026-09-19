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

# A count is the RECIPIENT's backlog: the same number from any caller, and
# root's mail drained by the console counts as read.
test_inbox_count_is_the_recipients_backlog_and_the_console_reads_for_root() {
  _inbox_sandbox
  _inbox_send root "one" --workspace demo >/dev/null 2>&1
  _inbox_send root "two" --workspace demo >/dev/null 2>&1
  assert_eq "$(CEL_INBOX_ME=someone-else _inbox_count --for root --workspace demo)" "2"
  local last; last="$(jq -r 'select(.to=="root") | .id' "$CEL_INBOX_DIR/demo.jsonl" | tail -1)"
  printf '%s' "$last" > "$CEL_INBOX_DIR/demo.root.console.cursor"
  assert_eq "$(CEL_INBOX_ME=someone-else _inbox_count --for root --workspace demo)" "0"
  assert_eq "$(CEL_INBOX_ME=steward _inbox_count --for root --workspace demo)" "0"
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

# --- the console stands outside every workspace ------------------------------
# Identity comes from where an agent stands, and the console stands nowhere:
# its directory is not a workspace, so without a case of its own it fell
# through to "root" and drained the root orchestrator's mailbox - the same
# silent theft the products/ case was written to stop.
test_inbox_me_is_console_from_its_directory_or_its_role() {
  local C; C="$(mktemp -d)"
  assert_eq "$(CEL_INBOX_ME='' CEL_CONSOLE_DIR="$C" bash -c 'cd "$1"; source "$2/lib/inbox.sh"; _inbox_me' _ "$C" "$CEL_ROOT")" "console"
  mkdir -p "$C/sub"
  assert_eq "$(CEL_INBOX_ME='' CEL_CONSOLE_DIR="$C" bash -c 'cd "$1/sub"; source "$2/lib/inbox.sh"; _inbox_me' _ "$C" "$CEL_ROOT")" "console"
  assert_eq "$(CEL_INBOX_ME='' CEL_ROLE=console bash -c 'source "$1/lib/inbox.sh"; _inbox_me' _ "$CEL_ROOT")" "console"
  rm -rf "$C"
}

# TWO READERS OF ONE MAILBOX MUST NOT SHARE A CURSOR. "root" is the address
# orchestrators escalate to - the top, whoever is listening - and both a
# standing root pane and the console read it. One cursor between them means
# whichever looked first consumed the other's mail.
test_inbox_cursors_are_per_reader() {
  _inbox_sandbox
  ( CEL_INBOX_ME=root _inbox_send root "a question" --from games-orch --workspace demo ) >/dev/null 2>&1
  assert_contains "$(CEL_INBOX_ME=root _inbox_read --for root --workspace demo)" "a question"
  [ -f "$CEL_INBOX_DIR/demo.root.cursor" ] || { echo "no recipient cursor"; return 1; }
  assert_eq "$(CEL_INBOX_ME=root _inbox_read --for root --workspace demo)" ""
  # the console reads the same mailbox and still sees it, on its own cursor
  assert_contains "$(CEL_INBOX_ME=console _inbox_read --for root --workspace demo)" "a question"
  [ -f "$CEL_INBOX_DIR/demo.root.console.cursor" ] || { echo "no per-reader cursor"; return 1; }
  assert_eq "$(CEL_INBOX_ME=console _inbox_read --for root --workspace demo)" ""
  assert_eq "$(CEL_INBOX_ME=console _inbox_count --for root --workspace demo)" "0"
  rm -rf "$CEL_INBOX_DIR"
}

_inbox_registry_fixture() { # two registered workspaces, mail in each
  _inbox_sandbox; export CEL_INBOX_DIR
  REG="$(mktemp -d)"; export CEL_REGISTRY="$REG/registry.yaml"
  mkdir -p "$REG/alpha" "$REG/beta"
  printf 'workspaces:\n  alpha:\n    path: %s\n  beta:\n    path: %s\n' "$REG/alpha" "$REG/beta" > "$CEL_REGISTRY"
}
test_inbox_read_all_workspaces_prefixes_every_line() {
  _inbox_registry_fixture
  ( CEL_INBOX_ME=t _inbox_send root "from alpha" --workspace alpha ) >/dev/null 2>&1
  ( CEL_INBOX_ME=t _inbox_send root "from beta"  --workspace beta  ) >/dev/null 2>&1
  local out; out="$(CEL_INBOX_ME=console _inbox_read --for root --all-workspaces)"
  assert_contains "$out" "[alpha]"
  assert_contains "$out" "from alpha"
  assert_contains "$out" "[beta]"
  assert_contains "$out" "from beta"
  rm -rf "$CEL_INBOX_DIR" "$REG"
}
test_inbox_count_all_workspaces_sums_every_mailbox() {
  _inbox_registry_fixture
  ( CEL_INBOX_ME=t _inbox_send root "one" --workspace alpha ) >/dev/null 2>&1
  ( CEL_INBOX_ME=t _inbox_send root "two" --workspace beta  ) >/dev/null 2>&1
  ( CEL_INBOX_ME=t _inbox_send root "three" --workspace beta ) >/dev/null 2>&1
  assert_eq "$(CEL_INBOX_ME=console _inbox_count --for root --all-workspaces)" "3"
  rm -rf "$CEL_INBOX_DIR" "$REG"
}
# A decision landing in one workspace must not wait for the operator to be on
# that tab: the console tails every mailbox at once.
test_inbox_watch_all_workspaces_sees_a_new_line_from_either() {
  _inbox_registry_fixture
  local out; out="$(mktemp)"
  ( CEL_INBOX_ME=console CEL_INBOX_NOTIFY=0 timeout 5 bash -c 'source "$1/lib/inbox.sh"; _inbox_watch --for root --all-workspaces' _ "$CEL_ROOT" > "$out" 2>/dev/null & )
  sleep 1.5
  ( CEL_INBOX_ME=t _inbox_send root "late news" --workspace beta ) >/dev/null 2>&1
  sleep 2
  assert_contains "$(cat "$out")" "late news"
  assert_contains "$(cat "$out")" "[beta]"
  rm -f "$out"; rm -rf "$CEL_INBOX_DIR" "$REG"
}

# A decision or a blocker is the only mail worth interrupting a human for.
_inbox_notify_fixture() {
  _inbox_sandbox; export CEL_INBOX_DIR
  NB="$(mktemp -d)"; export PATH="$NB:$PATH" HERDR_ENV=1
  export NB_LOG="$NB/log"; : > "$NB_LOG"
  cat > "$NB/herdr" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NB_LOG"
EOS
  chmod +x "$NB/herdr"
}
_inbox_watch_then_send() { # <kind> <notify>
  ( CEL_INBOX_ME=root CEL_INBOX_NOTIFY="$2" timeout 5 bash -c 'source "$1/lib/inbox.sh"; _inbox_watch --for root --workspace demo' _ "$CEL_ROOT" >/dev/null 2>&1 & )
  sleep 1.5
  ( CEL_INBOX_ME=t _inbox_send root "needs you" --kind "$1" --workspace demo ) >/dev/null 2>&1
  sleep 2
}
test_watch_raises_a_notification_for_a_decision_only() {
  _inbox_notify_fixture
  _inbox_watch_then_send decision 1
  assert_contains "$(cat "$NB_LOG")" "notification show"
  : > "$NB_LOG"
  _inbox_watch_then_send status 1
  assert_eq "$(cat "$NB_LOG")" ""
  rm -rf "$NB" "$CEL_INBOX_DIR"
}
test_watch_notifications_can_be_switched_off() {
  _inbox_notify_fixture
  _inbox_watch_then_send decision 0
  assert_eq "$(cat "$NB_LOG")" ""
  rm -rf "$NB" "$CEL_INBOX_DIR"
}

# The console has no cwd to derive a workspace from, so every cel-linear
# subcommand takes --workspace and resolves the key from THAT workspace's
# env.local rather than from whatever the pane's shell happened to inherit.
test_cel_linear_workspace_flag_loads_that_workspaces_key() {
  local T; T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml" TMPDIR="$T" PATH="$T:$PATH"
  export LINEAR_TEST_DIR="$T" LINEAR_API_URL=https://linear.invalid/graphql
  unset LINEAR_API_KEY
  mkdir -p "$T/gadget"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/gadget/"
  printf 'export LINEAR_API_KEY=key-from-gadget\n' > "$T/gadget/env.local"
  printf 'workspaces:\n  gadget:\n    path: %s\n' "$T/gadget" > "$CEL_REGISTRY"
  cat > "$T/curl" <<'EOS'
#!/usr/bin/env bash
set -eu
while [ $# -gt 0 ]; do
  case "$1" in -H) case "$2" in @*) cat "${2#@}" > "$LINEAR_TEST_DIR/header";; esac; shift 2;; *) shift;; esac
done
cat >/dev/null
printf '{"data":{"viewer":{"name":"Example"}}}'
EOS
  chmod +x "$T/curl"
  ( cd "$T" && "$CEL_ROOT/core/skills/linear/bin/cel-linear" me --workspace gadget ) >/dev/null 2>&1
  assert_eq "$(cat "$T/header")" 'Authorization: key-from-gadget'
  rm -rf "$T"
}

# --- rollup: one open item per condition --------------------------------------
# Measured in a live mailbox: twenty-four open `blocked` items from the
# steward, all the same sentence about the same exhausted provider, one every
# four hours. The condition was one condition; the console showed it
# twenty-four times. A fingerprint makes the repeat an UPDATE on the item that
# is already open rather than another item nobody will read.
_inbox_raw() { # <ws> <id> <ts> <from> <kind> <message>
  local f="$CEL_INBOX_DIR/$1.jsonl"; mkdir -p "$CEL_INBOX_DIR"
  jq -nc --arg id "$2" --arg ts "$3" --arg from "$4" --arg kind "$5" --arg msg "$6" \
    '{id:$id, ts:$ts, to:"root", from:$from, kind:$kind, message:$msg}' >> "$f"
}

test_a_fingerprint_rolls_a_repeat_into_the_open_item() {
  _inbox_sandbox
  local a b
  a="$(_inbox_send root "deepseek credit is -0.24 (floor 1)" --from steward --kind blocked --fp quota-dry-deepseek --workspace demo 2>/dev/null)"
  b="$(_inbox_send root "deepseek credit is -0.31 (floor 1)" --from steward --kind blocked --fp quota-dry-deepseek --workspace demo 2>/dev/null)"
  # the repeat reports the id it rolled into, not a new one
  assert_eq "$b" "$a"
  local open; open="$(_inbox_open --for root --workspace demo)"
  assert_eq "$(printf '%s\n' "$open" | wc -l)" "1"
  assert_contains "$open" "×2, last "
  assert_contains "$open" "blocked from steward"
  local j; j="$(_inbox_open --for root --workspace demo --json)"
  assert_eq "$(printf '%s' "$j" | jq -r .count)" "2"
  assert_eq "$(printf '%s' "$j" | jq -r .last_ts)" \
    "$(jq -r 'select(.kind == "update") | .ts' "$CEL_INBOX_DIR/demo.jsonl" | tail -1)"
  # resolving the item takes its updates with it
  _inbox_resolve "$a" --by steward --workspace demo >/dev/null 2>&1
  assert_eq "$(_inbox_open --for root --workspace demo)" ""
  rm -rf "$CEL_INBOX_DIR"
}

# An update is ONE new line to the reader: the bell still rings, once per
# tick, rather than twelve rows deep.
test_read_shows_an_update_as_one_line_not_a_second_item() {
  _inbox_sandbox
  _inbox_send root "deepseek credit is -0.24" --from steward --kind blocked --fp quota-dry-deepseek --workspace demo >/dev/null 2>&1
  _inbox_send root "deepseek credit is -0.31" --from steward --kind blocked --fp quota-dry-deepseek --workspace demo >/dev/null 2>&1
  assert_eq "$(_inbox_count --for root --workspace demo)" "2"
  local out; out="$(_inbox_read --for root --workspace demo)"
  assert_eq "$(printf '%s\n' "$out" | wc -l)" "2"
  assert_contains "$out" "↻ steward (×2)"
  assert_eq "$(_inbox_count --for root --workspace demo)" "0"
  rm -rf "$CEL_INBOX_DIR"
}

# --- bulk resolve -------------------------------------------------------------
_resolve_all_fixture() {
  _inbox_sandbox
  _inbox_raw demo 100 "$(date -Is -d '10 hours ago')" steward blocked "quota is dry"
  _inbox_raw demo 200 "$(date -Is)"                    steward blocked "a stalled worker"
  _inbox_raw demo 300 "$(date -Is)"                    bundle-orch decision "ship v2 or wait?"
}
test_resolve_all_narrows_by_sender() {
  _resolve_all_fixture
  local out; out="$(_inbox_resolve --all --from steward --for root --by human --workspace demo 2>&1)"
  assert_contains "$out" "resolved 2"
  local open; open="$(_inbox_open --for root --workspace demo)"
  assert_contains "$open" "ship v2 or wait?"
  assert_eq "$(printf '%s\n' "$open" | wc -l)" "1"
  rm -rf "$CEL_INBOX_DIR"
}
test_resolve_all_narrows_by_matching_kind_and_age() {
  _resolve_all_fixture
  assert_contains "$(_inbox_resolve --all --matching "stalled" --for root --by human --workspace demo 2>&1)" "resolved 1"
  assert_contains "$(_inbox_open --for root --workspace demo)" "quota is dry"
  _resolve_all_fixture
  assert_contains "$(_inbox_resolve --all --kind decision --for root --by human --workspace demo 2>&1)" "resolved 1"
  assert_contains "$(_inbox_open --for root --workspace demo)" "quota is dry"
  _resolve_all_fixture
  assert_contains "$(_inbox_resolve --all --older-than 5 --for root --by human --workspace demo 2>&1)" "resolved 1"
  assert_contains "$(_inbox_open --for root --workspace demo)" "a stalled worker"
  rm -rf "$CEL_INBOX_DIR"
}
# No filter is allowed and means everything open for the reader - the count is
# printed, so the operator sees what one line just did.
test_resolve_all_with_no_filter_clears_the_reader() {
  _resolve_all_fixture
  assert_contains "$(_inbox_resolve --all --for root --by human --workspace demo 2>&1)" "resolved 3"
  assert_eq "$(_inbox_open --for root --workspace demo)" ""
  rm -rf "$CEL_INBOX_DIR"
}
# An update is not a separate thing to resolve: it goes with its item.
test_resolve_all_counts_a_rolled_up_item_once() {
  _inbox_sandbox
  _inbox_send root "dry" --from steward --kind blocked --fp q --workspace demo >/dev/null 2>&1
  _inbox_send root "dry" --from steward --kind blocked --fp q --workspace demo >/dev/null 2>&1
  assert_contains "$(_inbox_resolve --all --from steward --for root --by human --workspace demo 2>&1)" "resolved 1"
  assert_eq "$(_inbox_open --for root --workspace demo)" ""
  rm -rf "$CEL_INBOX_DIR"
}

# The console loops the workspaces itself today, but a chain (or a human) must
# be able to see everything waiting in ONE call.
test_inbox_open_all_workspaces_prefixes_every_line() {
  _inbox_registry_fixture
  ( CEL_INBOX_ME=t _inbox_send root "alpha question" --kind decision --workspace alpha ) >/dev/null 2>&1
  ( CEL_INBOX_ME=t _inbox_send root "beta blocker"   --kind blocked  --workspace beta  ) >/dev/null 2>&1
  local out; out="$(CEL_INBOX_ME=console _inbox_open --for root --all-workspaces)"
  assert_contains "$out" "[alpha]"
  assert_contains "$out" "alpha question"
  assert_contains "$out" "[beta]"
  assert_contains "$out" "beta blocker"
  rm -rf "$CEL_INBOX_DIR" "$REG"
}

# --- CEL-43: root is a mailbox nobody has to read ---------------------------
#
# Counted on one box on 2026-09-19: root had taken 553 messages since the 10th
# and 466 of them were `status`. Three faults, three groups of assertions -
# status stops being mail, a mailbox with no reader is a fault, and what is
# left gets ranked. NOTHING HERE DELETES A MESSAGE, so every test below ends
# by asserting the file is exactly as long as it was.
_inbox_lines() { wc -l < "$CEL_INBOX_DIR/${1:-demo}.jsonl" 2>/dev/null | tr -d ' ' || printf 0; }

# Rule 6 told every orchestrator to report ticket status to root, and that one
# instruction is the 466. The warning is the migration: a role file in the
# wild still does this, so the message is delivered and the sender is told.
test_status_to_root_warns_and_still_delivers() {
  _inbox_sandbox
  local err
  err="$( ( _inbox_send root "widget: ABC-9 landed" --from widget-orch --workspace demo >/dev/null ) 2>&1 )"
  assert_contains "$err" "status to root is not read by anyone; the ledger already carries it"
  assert_contains "$(_inbox_read --for root --workspace demo)" "widget: ABC-9 landed"
  local n; n="$(_inbox_lines)"
  err="$( ( _inbox_send root "ship or hold?" --kind decision --workspace demo >/dev/null ) 2>&1 )"
  case "$err" in *"not read by anyone"*) echo "warned about a decision"; return 1;; esac
  err="$( ( _inbox_send widget-orch "ABC-9 landed" --workspace demo >/dev/null ) 2>&1 )"
  case "$err" in *"not read by anyone"*) echo "warned about a non-root recipient"; return 1;; esac
  assert_eq "$(_inbox_lines)" "$((n + 2))"
  rm -rf "$CEL_INBOX_DIR"
}

# WHO IS ALIVE TO READ IT. A live pane whose alias matches the mailbox, a live
# console, or nobody - and "nobody" is what turns an unread escalation into a
# fault instead of silence.
_inbox_reader_fixture() {
  _inbox_sandbox
  RB="$(mktemp -d)"; PATH="$RB:$PATH"; export PATH
  export CEL_PROC_DIR="$RB/proc"; mkdir -p "$CEL_PROC_DIR"
  cat > "$RB/herdr" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "${STUB_AGENTS:-{\"result\":{\"agents\":[]}}}"
EOS
  chmod +x "$RB/herdr"
  export STUB_AGENTS='{"result":{"agents":[]}}'
}

test_inbox_reader_of_sees_a_pane_a_console_or_nobody() {
  _inbox_reader_fixture
  assert_eq "$(inbox_reader_of alpha root)" ""
  export STUB_AGENTS='{"result":{"agents":[{"name":"alpha-root"}]}}'
  assert_eq "$(inbox_reader_of alpha root)" "alpha-root"
  export STUB_AGENTS='{"result":{"agents":[{"name":"widget-orch"}]}}'
  assert_eq "$(inbox_reader_of alpha widget-orch)" "widget-orch"
  assert_eq "$(inbox_reader_of alpha root)" ""
  # the console watches every workspace's root mailbox at once (CEL-7), and
  # CEL-32's marker is what proves one is actually running
  mkdir -p "$CEL_PROC_DIR/4242"
  printf 'CEL_ROLE=console\0HOME=/tmp\0' > "$CEL_PROC_DIR/4242/environ"
  assert_eq "$(inbox_reader_of alpha root)" "console"
  rm -rf "$RB" "$CEL_INBOX_DIR"
}

# An escalation is by definition the kind that cannot wait, and it was the one
# kind that raised nothing: 72 of them landed in a mailbox with no reader.
test_watch_raises_a_notification_for_an_escalation_too() {
  _inbox_notify_fixture
  _inbox_watch_then_send escalation 1
  assert_contains "$(cat "$NB_LOG")" "notification show"
  rm -rf "$NB" "$CEL_INBOX_DIR"
}

# --- ranking what is left ---------------------------------------------------
# The model supplies ONE thing: a level per message. Counts, ages, ordering
# and the cut are the code's, so an unreachable model degrades to today's
# ordering rather than losing messages.
_triage_fixture() {
  _inbox_sandbox
  source "$CEL_ROOT/lib/triage.sh"
  TB="$(mktemp -d)"
  export CEL_TRIAGE_CACHE="$TB/cache" CEL_TRIAGE_CALLS="$TB/calls" CEL_TRIAGE_POST="$TB/post"
  : > "$CEL_TRIAGE_CALLS"
  # The stub answers from the message text itself: LEVEL<n> is the level it
  # returns and UNSURE drops the confidence under the floor, so one fixture
  # drives every ranking assertion below.
  cat > "$TB/post" <<'EOS'
#!/usr/bin/env bash
body="$(cat)"
printf '%s\n' "$body" >> "$CEL_TRIAGE_CALLS"
printf '%s' "$body" | jq -c '{answers: (.questions | to_entries
  | map({key: .key, value: {
      value: ((.value.instructions | capture("LEVEL(?<n>[0-9])") | .n | tonumber)),
      confidence: (if (.value.instructions | test("UNSURE")) then 0.1 else 0.9 end)}})
  | from_entries)}'
EOS
  chmod +x "$TB/post"
}
_triage_send() { # <kind> <text>
  ( _inbox_send root "$2" --kind "$1" --from widget-orch --workspace demo ) >/dev/null 2>&1
}

test_triage_orders_the_unread_by_the_models_level() {
  _triage_fixture
  _triage_send escalation "LEVEL3 the reviewer pane has been dead for two days"
  _triage_send status     "LEVEL1 ABC-9 gate is green"
  _triage_send decision   "LEVEL2 ship the bundle or hold"
  _triage_send status     "LEVEL0 nothing to do here"
  local n; n="$(_inbox_lines)"
  assert_eq "$(triage_ranked demo root | jq -r '.rank' | tr '\n' ' ')" "3 2 1 0 "
  assert_eq "$(_inbox_lines)" "$n"
  rm -rf "$TB" "$CEL_INBOX_DIR"
}

test_a_below_threshold_answer_keeps_its_kinds_default_rank() {
  _triage_fixture
  _triage_send blocked "UNSURE LEVEL0 the gate cannot run"
  local n; n="$(_inbox_lines)"
  assert_eq "$(triage_ranked demo root | jq -r '.rank')" "3"
  assert_eq "$(_inbox_lines)" "$n"
  rm -rf "$TB" "$CEL_INBOX_DIR"
}

# A message is scored ONCE. The console redraws every ten seconds; a score per
# draw is a provider bill per operator per day.
test_a_message_is_scored_once_however_often_it_is_drawn() {
  _triage_fixture
  _triage_send decision "LEVEL2 ship the bundle or hold"
  triage_ranked demo root >/dev/null
  triage_ranked demo root >/dev/null
  assert_eq "$(grep -c . "$CEL_TRIAGE_CALLS")" "1"
  rm -rf "$TB" "$CEL_INBOX_DIR"
}

# An unreachable model is today's ordering, not an error and not a loss.
test_an_unreachable_model_falls_back_to_the_kind_defaults() {
  _triage_fixture
  export CEL_TRIAGE_POST="$TB/nope"
  _triage_send status  "LEVEL3 a status message"
  _triage_send blocked "LEVEL0 a blocker"
  local n; n="$(_inbox_lines)"
  assert_eq "$(triage_ranked demo root | jq -r '.rank' | tr '\n' ' ')" "3 0 "
  assert_eq "$(_inbox_lines)" "$n"
  rm -rf "$TB" "$CEL_INBOX_DIR"
}

test_open_ranked_shows_the_top_three_and_then_how_many_more() {
  _triage_fixture
  _triage_send escalation "LEVEL3 the reviewer pane has been dead for two days"
  _triage_send decision   "LEVEL2 ship the bundle or hold"
  _triage_send status     "LEVEL1 ABC-9 gate is green"
  _triage_send status     "LEVEL0 nothing to do here"
  _triage_send status     "LEVEL0 nothing to do here either"
  local n out; n="$(_inbox_lines)"
  out="$(_inbox_open --for root --workspace demo --ranked)"
  assert_contains "$out" "the reviewer pane has been dead"
  assert_contains "$out" "ship the bundle or hold"
  assert_contains "$out" "and 2 more"
  case "$out" in *"nothing to do here either"*) echo "showed past the cut"; return 1;; esac
  assert_eq "$(_inbox_lines)" "$n"
  rm -rf "$TB" "$CEL_INBOX_DIR"
}
