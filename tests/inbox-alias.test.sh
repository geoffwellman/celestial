# shellcheck shell=bash
# AH-261017: mailbox identities are idempotent, and a mailbox that was split by
# the old sanitiser can be recovered without losing or replaying a message.
#
# Everything here drives the real `cel inbox` CLI against a throwaway
# CEL_INBOX_DIR and HOME. The synthetic worker is widget-platform /
# workstream-0042-chat-launch: its full name is cut by the 32-character limit
# exactly between two words, so the established alias ends in a dash.
source "$CEL_ROOT/lib/common.sh"

FULL="widget-platform-workstream-0042-chat-launch"
CANON="widget-platform-workstream-0042-"     # 32 characters, ends in a dash
PHANTOM="widget-platform-workstream-0042"    # what the old sanitiser made of CANON

_ia_cel() { bash "$CEL_ROOT/bin/cel" "$@"; }

_ia_setup() {
  IA="$(mktemp -d)"
  export HOME="$IA/home" CEL_INBOX_DIR="$IA/inbox" XDG_RUNTIME_DIR="$IA/run"
  mkdir -p "$HOME" "$CEL_INBOX_DIR" "$XDG_RUNTIME_DIR" "$IA/bin"
  unset CEL_INBOX_ME CEL_INBOX_WS HERDR_ENV
  export PATH="$IA/bin:$PATH"
  assert_eq "${#CANON}" "32" || return 1
}

_ia_roster() { # <name>...   a herdr that reports these agents live
  local names="" n
  for n in "$@"; do names="$names${names:+,}{\"name\":\"$n\"}"; done
  printf '#!/usr/bin/env bash\necho %s\n' "'{\"result\":{\"agents\":[$names]}}'" > "$IA/bin/herdr"
  chmod +x "$IA/bin/herdr"
}

_ia_tos() { jq -r .to "$CEL_INBOX_DIR/demo.jsonl" | sort -u | tr '\n' ' '; }

# --- one normalisation rule -------------------------------------------------

test_alias_normalisation_is_idempotent_and_keeps_established_aliases() {
  local s once twice
  for s in "$FULL" "widget-platform/workstream-0042-chat-launch" "Widget-Platform-Workstream-0042-" \
           "$CANON" "$PHANTOM" "abc--" "abc-" "---abc" "9lives/x" "a very (long) name with spaces and symbols-----------"; do
    once="$(bash -c 'source "$1/lib/common.sh"; source "$1/lib/inbox.sh"; _inbox_sanitise "$2"' _ "$CEL_ROOT" "$s")"
    twice="$(bash -c 'source "$1/lib/common.sh"; source "$1/lib/inbox.sh"; _inbox_sanitise "$2"' _ "$CEL_ROOT" "$once")"
    assert_eq "$twice" "$once" || { echo "not idempotent for [$s]"; return 1; }
    [ "${#once}" -le 32 ] || { echo "too long: $once"; return 1; }
  done
  # the 32-character alias herdr already holds is NOT trimmed to 31
  assert_eq "$(bash -c 'source "$1/lib/common.sh"; source "$1/lib/inbox.sh"; _inbox_sanitise "$2"' _ "$CEL_ROOT" "$FULL")" \
            "widget-platform-workstream-0042-"
}

test_alias_rule_is_one_rule_across_inbox_run_and_steward() {
  local s a b c
  for s in "$FULL" "widget-platform/workstream-0042-chat-launch" "$CANON"; do
    a="$(bash -c 'source "$1/lib/common.sh"; source "$1/lib/inbox.sh"; _inbox_sanitise "$2"' _ "$CEL_ROOT" "$s")"
    b="$(bash -c 'source "$1/lib/common.sh"; source "$1/lib/run.sh"; _run_agent_name "$2"' _ "$CEL_ROOT" "$s")"
    c="$(bash -c 'source "$1/lib/common.sh"; source "$1/lib/steward.sh"; _steward_agent_name "$2"' _ "$CEL_ROOT" "$s")"
    assert_eq "$b" "$a" && assert_eq "$c" "$a" || { echo "policies diverge for [$s]"; return 1; }
  done
}

# --- the incident, through the CLI -------------------------------------------

test_full_name_and_canonical_alias_reach_the_same_worker_mailbox() {
  _ia_setup || return 1
  _ia_cel inbox send "$FULL" "via the full name" --from orch --workspace demo >/dev/null 2>&1
  _ia_cel inbox send "$CANON" "via the alias" --from orch --workspace demo >/dev/null 2>&1
  assert_eq "$(_ia_tos)" "$CANON " || { echo "mail split across mailboxes"; return 1; }
  # explicit identity and a cwd-derived one are the same reader
  assert_eq "$(CEL_INBOX_ME="$CANON" _ia_cel inbox count --workspace demo 2>/dev/null)" "2"
  mkdir -p "$HOME/.herdr/worktrees/widget-platform/workstream-0042-chat-launch"
  assert_eq "$(cd "$HOME/.herdr/worktrees/widget-platform/workstream-0042-chat-launch" \
    && _ia_cel inbox whoami)" "$CANON"
  assert_eq "$(cd "$HOME/.herdr/worktrees/widget-platform/workstream-0042-chat-launch" \
    && _ia_cel inbox count --workspace demo 2>/dev/null)" "2"
  # delivered once: first read gets both, the second gets nothing
  local out; out="$(CEL_INBOX_ME="$CANON" _ia_cel inbox read --workspace demo 2>/dev/null)"
  assert_contains "$out" "via the full name"
  assert_contains "$out" "via the alias"
  assert_eq "$(CEL_INBOX_ME="$CANON" _ia_cel inbox read --workspace demo 2>/dev/null)" ""
  assert_eq "$(CEL_INBOX_ME="$CANON" _ia_cel inbox count --workspace demo 2>/dev/null)" "0"
  rm -rf "$IA"
}

test_reading_for_the_full_name_finds_the_canonical_mailbox() {
  _ia_setup || return 1
  _ia_cel inbox send "$CANON" "hello" --from orch --workspace demo >/dev/null 2>&1
  assert_eq "$(_ia_cel inbox count --for "$FULL" --workspace demo 2>/dev/null)" "1"
  assert_contains "$(_ia_cel inbox read --for "$FULL" --workspace demo 2>/dev/null)" "hello"
  assert_eq "$(_ia_tos)" "$CANON " || return 1
  ls "$CEL_INBOX_DIR" | grep -q "^demo\.$PHANTOM\." && { echo "phantom cursor created"; return 1; }
  rm -rf "$IA"
}

test_watch_delivers_to_the_canonical_alias_whichever_way_it_was_sent() {
  _ia_setup || return 1
  _ia_cel inbox send "$CANON" "seed" --from orch --workspace demo >/dev/null 2>&1
  ( CEL_INBOX_ME="$CANON" timeout 6 bash "$CEL_ROOT/bin/cel" inbox watch --workspace demo >"$IA/watch.out" 2>/dev/null & )
  sleep 2
  _ia_cel inbox send "$FULL" "by full name" --from orch --workspace demo >/dev/null 2>&1
  _ia_cel inbox send "$CANON" "by alias" --from orch --workspace demo >/dev/null 2>&1
  sleep 2.5
  local out; out="$(cat "$IA/watch.out")"
  assert_contains "$out" "by full name"
  assert_contains "$out" "by alias"
  assert_eq "$(printf '%s\n' "$out" | grep -c 'by full name')" "1"
  rm -rf "$IA"
}

# --- recovering a mailbox the old sanitiser split ---------------------------

_ia_id() { printf '17921580000000000%02d' "$1"; }

# Both sides of the split in one file, each reader at a different place:
#   c = sent to the real name, p = sent to the phantom, b = broadcast
#   ids: 01 c1, 02 p1, 03 c2, 04 p2, 05 c3, 06 p3, 07 b1, 08 other, 09 p4 (unterminated tail)
_ia_split_fixture() {
  _ia_setup || return 1
  local f="$CEL_INBOX_DIR/demo.jsonl" i to name
  for spec in "1 $CANON c1" "2 $PHANTOM p1" "3 $CANON c2" "4 $PHANTOM p2" "5 $CANON c3" \
              "6 $PHANTOM p3" "7 all b1" "8 someone-else o1"; do
    set -- $spec; i="$1"; to="$2"; name="$3"
    jq -nc --arg id "$(_ia_id "$i")" --arg to "$to" --arg m "$name" \
      '{id:$id, ts:"2026-10-17T00:00:00+00:00", to:$to, from:"orch", kind:"status", message:$m, cwd:"/x", pane:""}' >> "$f"
  done
  jq -nc --arg id "$(_ia_id 9)" --arg to "$PHANTOM" \
    '{id:$id, ts:"2026-10-17T00:00:00+00:00", to:$to, from:"orch", kind:"status", message:"p4", cwd:"/x", pane:""}' | tr -d '\n' >> "$f"
  # the worker has read up to c2; a second reader ("rdr") up to c3; someone else is untouched
  printf '%s' "$(_ia_id 3)" > "$CEL_INBOX_DIR/demo.$CANON.cursor"
  printf '%s' "$(_ia_id 5)" > "$CEL_INBOX_DIR/demo.$CANON.rdr.cursor"
  printf '%s' "$(_ia_id 8)" > "$CEL_INBOX_DIR/demo.someone-else.cursor"
  _ia_roster "$CANON"
  cp "$f" "$IA/before.jsonl"
}

_ia_msgs() { # <reader>  -> the messages that reader receives, in order, space separated
  CEL_INBOX_ME="$1" _ia_cel inbox read --for "$CANON" --workspace demo --json 2>/dev/null | jq -r 'select(.message != null) | .message' | tr '\n' ' '
}

test_migrate_is_a_dry_run_unless_applied() {
  _ia_split_fixture || return 1
  local sum; sum="$(cd "$CEL_INBOX_DIR" && find . -type f | sort | xargs cksum)"
  local out; out="$(_ia_cel inbox migrate --workspace demo 2>&1)"
  assert_contains "$out" "$PHANTOM"
  assert_contains "$out" "$CANON"
  assert_eq "$(cd "$CEL_INBOX_DIR" && find . -type f | sort | xargs cksum)" "$sum" || { echo "dry run changed state"; return 1; }
  rm -rf "$IA"
}

test_migrate_keeps_every_message_and_each_readers_unread_exactly_once() {
  _ia_split_fixture || return 1
  _ia_cel inbox migrate --workspace demo --apply >"$IA/mig.out" 2>&1 || { cat "$IA/mig.out"; return 1; }
  local f="$CEL_INBOX_DIR/demo.jsonl"
  # every message, same ids, same bodies; nobody addressed to the phantom any more
  assert_eq "$(jq -r .id "$f" | tr '\n' ' ')" "$(jq -r .id "$IA/before.jsonl" | tr '\n' ' ')" || { echo "ids changed"; return 1; }
  assert_eq "$(jq -r .message "$f" | tr '\n' ' ')" "$(jq -r .message "$IA/before.jsonl" | tr '\n' ' ')" || return 1
  ! jq -e "select(.to == \"$PHANTOM\")" "$f" >/dev/null 2>&1 || { echo "phantom still addressed"; return 1; }
  # the worker (cursor at c2) gets what it never read, INCLUDING the phantom mail older than its cursor
  assert_eq "$(_ia_msgs "$CANON")" "p1 p2 c3 p3 b1 p4 " || return 1
  assert_eq "$(_ia_msgs "$CANON")" "" || { echo "redelivered"; return 1; }
  # the other reader of the same mailbox: read c3 already, never saw any phantom mail
  assert_eq "$(_ia_msgs rdr)" "p1 p2 p3 b1 p4 " || return 1
  assert_eq "$(_ia_msgs rdr)" "" || return 1
  # an unrelated recipient is untouched
  assert_eq "$(cat "$CEL_INBOX_DIR/demo.someone-else.cursor")" "$(_ia_id 8)"
  assert_eq "$(_ia_cel inbox count --for someone-else --workspace demo 2>/dev/null)" "0"
  # a second apply has nothing left to do
  local sum; sum="$(cksum < "$f")"
  _ia_cel inbox migrate --workspace demo --apply >/dev/null 2>&1
  assert_eq "$(cksum < "$f")" "$sum"
  rm -rf "$IA"
}

test_migrate_count_and_unread_views_agree_before_anyone_reads() {
  _ia_split_fixture || return 1
  _ia_cel inbox migrate --workspace demo --apply >/dev/null 2>&1 || return 1
  assert_eq "$(CEL_INBOX_ME="$CANON" _ia_cel inbox count --workspace demo 2>/dev/null)" "6"
  assert_eq "$(CEL_INBOX_ME=rdr _ia_cel inbox count --for "$CANON" --workspace demo 2>/dev/null)" "5"
  # a look does not consume
  CEL_INBOX_ME="$CANON" _ia_cel inbox read --all --workspace demo >/dev/null 2>&1
  assert_eq "$(CEL_INBOX_ME="$CANON" _ia_cel inbox count --workspace demo 2>/dev/null)" "6"
  rm -rf "$IA"
}

test_migrate_survives_sends_and_reads_running_through_it() {
  _ia_split_fixture || return 1
  local got="$IA/got" i
  : > "$got"
  printf '\n' >> "$CEL_INBOX_DIR/demo.jsonl"   # a torn tail would swallow the first live send
  # a reader polling the whole time, and a sender adding mail to the real name
  ( for i in $(seq 1 25); do
      CEL_INBOX_ME="$CANON" _ia_cel inbox read --workspace demo --json 2>/dev/null | jq -r 'select(.message != null) | .message' >> "$got"
      sleep 0.05
    done ) &
  local rpid=$!
  ( for i in $(seq 1 12); do
      _ia_cel inbox send "$CANON" "live$i" --from orch --workspace demo >/dev/null 2>&1
      sleep 0.07
    done ) &
  local spid=$!
  sleep 0.3
  _ia_cel inbox migrate --workspace demo --apply >"$IA/mig.out" 2>&1 || { cat "$IA/mig.out"; return 1; }
  wait "$rpid" "$spid"
  CEL_INBOX_ME="$CANON" _ia_cel inbox read --workspace demo --json 2>/dev/null | jq -r 'select(.message != null) | .message' >> "$got"
  local want="p1 p2 c3 p3 b1 p4 live1 live2 live3 live4 live5 live6 live7 live8 live9 live10 live11 live12"
  assert_eq "$(sort "$got" | tr '\n' ' ')" "$(printf '%s\n' $want | sort | tr '\n' ' ')" \
    || { echo "a message was lost or delivered twice"; return 1; }
  assert_eq "$(grep -c . "$CEL_INBOX_DIR/demo.jsonl")" "$(( 9 + 12 ))" || { echo "messages lost from the file"; return 1; }
  rm -rf "$IA"
}

# --- identity collisions fail safe -------------------------------------------

test_migrate_refuses_when_the_shorter_name_is_a_live_identity_too() {
  _ia_split_fixture || return 1
  _ia_roster "$CANON" "$PHANTOM"          # a genuine 31-character agent exists as well
  local rc=0
  _ia_cel inbox migrate --workspace demo --apply >"$IA/mig.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "applied an ambiguous migration"; return 1; }
  assert_contains "$(cat "$IA/mig.out")" "$PHANTOM"
  cmp -s "$IA/before.jsonl" "$CEL_INBOX_DIR/demo.jsonl" || { echo "file changed"; return 1; }
  assert_contains "$(cat "$IA/mig.out")" "unsafe" || return 1
  assert_eq "$(cat "$CEL_INBOX_DIR/demo.$CANON.cursor")" "$(_ia_id 3)"
  # the genuine 31-character recipient still gets exactly its own mail
  assert_eq "$(_ia_cel inbox count --for "$PHANTOM" --workspace demo 2>/dev/null)" "5"
  rm -rf "$IA"
}

test_migrate_refuses_when_the_shorter_name_has_sent_mail_as_itself() {
  _ia_split_fixture || return 1
  printf '\n' >> "$CEL_INBOX_DIR/demo.jsonl"   # finish the torn tail first
  jq -nc --arg id "$(_ia_id 10)" --arg from "$PHANTOM" \
    '{id:$id, ts:"2026-10-17T00:00:00+00:00", to:"orch", from:$from, kind:"status", message:"from the short one"}' \
    >> "$CEL_INBOX_DIR/demo.jsonl"
  cp "$CEL_INBOX_DIR/demo.jsonl" "$IA/before.jsonl"
  local rc=0
  _ia_cel inbox migrate --workspace demo --apply >"$IA/mig.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "applied despite a sender identity"; return 1; }
  cmp -s "$IA/before.jsonl" "$CEL_INBOX_DIR/demo.jsonl" || { echo "file changed"; return 1; }
  assert_contains "$(cat "$IA/mig.out")" "unsafe" || return 1
  rm -rf "$IA"
}

test_migrate_refuses_when_neither_name_has_identity_evidence() {
  _ia_split_fixture || return 1
  _ia_roster                                  # nobody alive
  rm -f "$CEL_INBOX_DIR/demo.$CANON.cursor" "$CEL_INBOX_DIR/demo.$CANON.rdr.cursor"
  cp "$CEL_INBOX_DIR/demo.jsonl" "$IA/before.jsonl"
  local rc=0
  _ia_cel inbox migrate --workspace demo --apply >"$IA/mig.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "guessed an association"; return 1; }
  cmp -s "$IA/before.jsonl" "$CEL_INBOX_DIR/demo.jsonl" || { echo "file changed"; return 1; }
  assert_contains "$(cat "$IA/mig.out")" "unsafe" || return 1
  rm -rf "$IA"
}

test_migrate_refuses_without_a_roster() {
  _ia_split_fixture || return 1
  printf '#!/usr/bin/env bash\nexit 1\n' > "$IA/bin/herdr"; chmod +x "$IA/bin/herdr"
  local rc=0
  _ia_cel inbox migrate --workspace demo --apply >"$IA/mig.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "applied with no way to check who is alive"; return 1; }
  cmp -s "$IA/before.jsonl" "$CEL_INBOX_DIR/demo.jsonl" || { echo "file changed"; return 1; }
  assert_contains "$(cat "$IA/mig.out")" "unsafe" || return 1
  rm -rf "$IA"
}
