# shellcheck shell=bash
# cel inbox - agent-to-agent messages that cannot hijack a human's keyboard.
#
# `herdr agent prompt` types into the target pane's composer, where it would
# concatenate with a human's half-typed draft. Routine traffic goes to a FILE
# instead: one JSONL per workspace, one read cursor per recipient. Runtime-
# specific extensions or persistent monitors may surface it while idle;
# Claude's UserPromptSubmit/Stop hooks only run at turn boundaries and do not
# wake idle sessions. Nothing here types into a pane, escalations included.
[ -n "${_CEL_INBOX:-}" ] && return 0
_CEL_INBOX=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"
# shellcheck source=lib/rex.sh
. "${BASH_SOURCE[0]%/*}/rex.sh"

_inbox_dir() { printf '%s' "${CEL_INBOX_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/inbox}"; }

# Which mailbox: the current workspace, or --workspace. Box state, not repo
# content, so it lives beside the registry rather than in the workspace repo.
_inbox_ws() { # [name]
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  # The launch names the workspace (run.sh exports CEL_INBOX_WS), so a worker
  # standing outside every workspace still sends to its orchestrator's.
  if [ -n "${CEL_INBOX_WS:-}" ]; then printf '%s' "$CEL_INBOX_WS"; return 0; fi
  local d; d="$(ws_current 2>/dev/null)" || { printf 'default'; return 0; }
  local n; n="$(ws_name "$d")"; printf '%s' "${n:-default}"
}

# WHO AM I? Every pane drains its OWN mailbox: draining another's advances
# that reader's cursor and it silently loses mail. Identity comes from where
# the agent is standing, which needs no env plumbing through herdr:
#   <ws>                        -> root
#   <ws>/products/<product>     -> <product>-orch
#   <ws>/repos/<repo>           -> <repo>-orch
#   ~/.herdr/worktrees/<r>/<b>  -> <r>-<b>   (the worker alias cel run gave it)
#   the console directory       -> console   (also CEL_ROLE=console)
#   the core directory          -> root      (also CEL_ROLE=core): core IS the
#                                  reader of root's mailbox in every workspace
# The console stands outside every workspace, so it has its own rule rather
# than falling through to root. No workspace.yaml lookup on purpose: the path
# IS the answer.
_inbox_me() {
  # An explicit identity goes through the same rule as every other name: a
  # canonical alias is unchanged (the rule is idempotent), and one that was
  # typed rather than derived still lands in the mailbox mail is sent to.
  [ -n "${CEL_INBOX_ME:-}" ] && { _inbox_sanitise "$CEL_INBOX_ME"; return 0; }
  local p wt rest repo branch d c
  p="$PWD"
  [ "${CEL_ROLE:-}" = core ] && { printf 'root'; return 0; }
  [ "${CEL_ROLE:-}" = console ] && { printf 'console'; return 0; }
  c="${CEL_CORE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/core}"
  { [ "$p" = "$c" ] || [ "${p#"$c/"}" != "$p" ]; } && { printf 'root'; return 0; }
  c="${CEL_CONSOLE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/console}"
  { [ "$p" = "$c" ] || [ "${p#"$c/"}" != "$p" ]; } && { printf 'console'; return 0; }
  wt="$HOME/.herdr/worktrees"
  if [ "${p#"$wt/"}" != "$p" ]; then
    rest="${p#"$wt/"}"
    repo="${rest%%/*}"
    rest="${rest#"$repo"}"; rest="${rest#/}"
    branch="${rest%%/*}"
    if [ -n "$repo" ] && [ -n "$branch" ]; then
      _inbox_sanitise "$repo-$branch"; return 0
    fi
  fi
  d="$(ws_current 2>/dev/null)" || { _inbox_pane_name; return 0; }
  if [ "${p#"$d/products/"}" != "$p" ]; then
    rest="${p#"$d/products/"}"
    repo="${rest%%/*}"
    if [ -n "$repo" ]; then _inbox_sanitise "$repo-orch"; return 0; fi
  fi
  if [ "${p#"$d/repos/"}" != "$p" ]; then
    rest="${p#"$d/repos/"}"
    repo="${rest%%/*}"
    if [ -n "$repo" ]; then _inbox_sanitise "$repo-orch"; return 0; fi
  fi
  printf 'root'
}

# Outside any workspace there is no role to infer, and defaulting to "root"
# would have a stray pane impersonate the root orchestrator. Fall back to the
# name a HUMAN sees in herdr's sidebar - a label, not a coordinate - because
# these strings end up in front of people.
_inbox_pane_name() {
  local id="${HERDR_WORKSPACE_ID:-}" label=""
  if [ -n "$id" ] && have herdr && have jq; then
    label="$(herdr workspace list 2>/dev/null \
      | jq -r --arg w "$id" '.result.workspaces[]? | select(.workspace_id == $w) | .label // empty' \
      | sed -n 1p)"
  fi
  [ -n "$label" ] || label="${HERDR_PANE_ID:-unknown}"
  _inbox_sanitise "$label"
}

# The rule cel run names herdr agents by, so a mailbox name matches the pane:
# one function (cel_alias_norm, lib/common.sh), idempotent.
_inbox_sanitise() { cel_alias_norm "$1"; }

# The same question as _inbox_ws, asked by a reader that must not guess: the
# workspace named on the command line, or the one this cwd stands in, or rc 1
# because standing here names none. `default` is a fine fallback for a SEND
# (the message is kept somewhere and the sender is told where), and a terrible
# one for a READ: it opens a mailbox nothing writes to and calls it empty.
_inbox_ws_here() { # [name] -> <ws>, rc 1 when the cwd derives nothing
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  local d; d="$(ws_current 2>/dev/null)" || return 1
  local n; n="$(ws_name "$d")"
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# A `die` inside `$( )` kills only the subshell and the caller carries on with
# an empty string. This prints and returns; the caller returns 2 from its own
# frame, where a non-zero status is visible.
_inbox_no_workspace() { # <subcommand>
  c_err "cel inbox $1: standing here names no workspace, so there is no mailbox to read - this is not 'no mail'" >&2
  c_err "  name one with --workspace <name>, or read them all with --all-workspaces (cel ws list)" >&2
}

_inbox_file()   { printf '%s/%s.jsonl' "$(_inbox_dir)" "$1"; }

# Is <ws> a workspace this box knows? Registered, or already holding a mailbox
# file (a workspace can take mail before it is registered, and a fixture has
# no registry at all). Anything else is a --workspace typo.
_inbox_ws_known() { # <ws>
  [ -f "$(_inbox_file "$1")" ] && return 0
  _inbox_all_ws | grep -qxF "$1"
}

# Has <who> EVER been a mailbox in <ws>? A `--for` typo names a recipient that
# is empty by construction, which must not read as "no mail". Evidence is a
# message ever addressed to the name, or a cursor left by a past read. `root`,
# `console` and `all` are addresses, not agents, and exist by definition.
_inbox_known() { # <ws> <who>
  # The workspace is checked before the reader: root/console/all exist by
  # definition, but only in a workspace that exists.
  _inbox_ws_known "$1" || return 1
  case "$2" in root|console|all) return 0 ;; esac
  local c; for c in "$(_inbox_dir)/$1.$2.cursor" "$(_inbox_dir)/$1.$2."*.cursor; do
    [ -f "$c" ] && return 0
  done
  local f; f="$(_inbox_file "$1")"
  [ -f "$f" ] || return 1
  jq -e --arg who "$2" 'select(.to == $who)' "$f" >/dev/null 2>&1
}

# MAIL YOU HAVE, ELSEWHERE. One `<ws>:<count>` line per other registered
# workspace holding unread mail for this reader. Counted through
# inbox_unread_json, which looks without touching a cursor: nobody asked to
# read those mailboxes and a cursor moved on their behalf is mail lost.
_inbox_elsewhere() { # <ws> <who>
  local n c
  for n in $(_inbox_all_ws); do
    [ "$n" = "$1" ] && continue
    c="$(inbox_unread_json "$n" "$2" | grep -c . || true)"
    [ "${c:-0}" -gt 0 ] && printf '%s:%s\n' "$n" "$c"
  done
  return 0
}

# WHAT NOTHING LOOKS LIKE, SAID OUT LOUD. The text goes to stderr on purpose:
# stdout is the drain hook's and the console's channel and carries MESSAGES,
# so a no-mail sentence there would be injected into every turn as if someone
# had said it. --json is asked for deliberately, so its state object is stdout.
#
# Returns 2 for a workspace that does not exist, matching the refusal for a
# cwd that names no workspace: both ask about a mailbox that cannot exist,
# and a shell caller sees only $?.
_inbox_empty_report() { # <ws> <who> <json> -> 2 when the workspace is unknown
  local ws="$1" who="$2" json="$3" state=empty lines="" where="" n c
  if ! _inbox_ws_known "$ws"; then state=no_workspace
  elif ! _inbox_known "$ws" "$who"; then state=no_mailbox
  fi
  lines="$(_inbox_elsewhere "$ws" "$who")"
  if [ "$json" -eq 1 ]; then
    jq -nc --arg state "$state" --arg reader "$who" --arg ws "$ws" \
      --argjson elsewhere "$(printf '%s' "$lines" | jq -R -s 'split("\n") | map(select(length > 0))
        | map(split(":") | {workspace: .[0], unread: (.[1] | tonumber)})')" \
      '{state: $state, reader: $reader, workspace: $ws, unread: 0, elsewhere: $elsewhere}'
    [ "$state" = no_workspace ] && return 2
    return 0
  fi
  if [ "$state" = no_workspace ]; then
    c_warn "$who: no workspace named '$ws' is registered here, so there is no mailbox to be empty (cel ws list)" >&2
  elif [ "$state" = no_mailbox ]; then
    c_warn "$who: no mailbox by that name in $ws - nothing has ever been addressed to it (a --for typo reads empty forever)" >&2
  else
    c_ok "$who: no unread mail in $ws" >&2
  fi
  if [ -n "$lines" ]; then
    while IFS=: read -r n c; do
      [ -n "$n" ] || continue
      where="${where:+$where, }$c in $n"
    done <<< "$lines"
    c_warn "  but $who has unread mail elsewhere: $where (cel inbox read --all-workspaces)" >&2
  fi
  [ "$state" = no_workspace ] && return 2
  return 0
}

# --- WHO IS ALIVE TO READ THIS MAILBOX -------------------------------------
#
# `root` is a NAME - the top, whoever is listening - and may have no live
# reader at all. "Nobody is reading this" is a FACT the box states, rather
# than a silence every watcher mistakes for calm.

# Every managed agent, one name per line. Failure is not the same as nobody
# being alive: do not infer absence when either backend could not answer.
_inbox_roster() {
  # A caller that already holds the roster (cel fleet) passes it in; asking
  # herdr again per workspace costs seconds of each read under load.
  if [ -n "${_INBOX_ROSTER_OK:-}" ]; then
    [ "$_INBOX_ROSTER_OK" = 1 ] || return 1
    printf '%s\n' "${_INBOX_ROSTER_HELD:-}"; return 0
  fi
  have jq || return 1
  local out
  out="$(cel_agent_list 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '.result.agents[]?.name // empty'
}

# The console stands outside every workspace and has no pane alias, so the
# roster cannot see it. Its CEL_ROLE=console marker can: `cel console` exports
# it, and /proc/<pid>/environ is fixed at exec, so it survives a
# runtime that rewrites its own argv (the reason lib/gc.sh reads environ too).
# CEL_PROC_DIR is the seam a test drives this through; nothing else moves it.
_inbox_console_live() {
  # One grep over every environ, not forks per process: per-pid forks cost
  # seconds on a loaded box. -z makes NUL the record separator, so -x still
  # matches a whole variable.
  local d="${CEL_PROC_DIR:-/proc}"
  grep -qszx 'CEL_ROLE=console' "$d"/[0-9]*/environ 2>/dev/null
}

# The herdr agent name that would be standing in a mailbox: the inverse of
# _inbox_me. Kept here beside the derivation it inverts, because the two
# drifting apart is how a live pane reads as nobody.
_inbox_agent_want() { # <mailbox> <ws>
  case "$1" in
    root) _inbox_sanitise "$2-root" ;;
    *) printf '%s' "$1" ;;    # an orchestrator's and a worker's mailbox IS its alias
  esac
}

# Who is alive to read <mailbox> in <ws>, or nothing. Returns 2 when herdr
# could not be asked: unknown is not the same as nobody, and a caller that
# raises an alarm on this must not raise it on a transport failure.
inbox_reader_of() { # <ws> <mailbox> -> reader name, or empty
  local ws="$1" box="$2" roster want
  roster="$(_inbox_roster)" || return 2
  if printf '%s\n' "$roster" | grep -qxF "$box"; then printf '%s' "$box"; return 0; fi
  # Core reads root's mail in every workspace, under its own pane name.
  if [ "$box" = root ] && printf '%s\n' "$roster" | grep -qxF core; then printf 'core'; return 0; fi
  want="$(_inbox_agent_want "$box" "$ws")"
  if [ -n "$want" ] && printf '%s\n' "$roster" | grep -qxF "$want"; then printf '%s' "$want"; return 0; fi
  # The console drains every workspace's ROOT mailbox and no other, so it is
  # a reader of root and is not evidence for anybody else's.
  if [ "$box" = root ] && _inbox_console_live; then printf 'console'; return 0; fi
  return 0
}

# The unread items for a recipient WITHOUT touching a cursor: looking is not
# reading. The steward, triage and inbox_mail_json share it so they agree on
# what unread means; _inbox_count_one also honours the caller's per-reader
# cursor.
inbox_unread_json() { # <ws> <who>
  local f cs
  f="$(_inbox_file "$1")"
  [ -f "$f" ] || return 0
  cs="$(_inbox_cursors_json "$(_inbox_dir)/$1.$2.cursor" \
          $([ "$2" = root ] && printf '%s' "$(_inbox_dir)/$1.root.console.cursor"))"
  jq -c --arg who "$2" --argjson cs "$cs" "$_INBOX_UNREAD_DEF"'
    select(.kind != "resolution") | select(.to == $who or .to == "all")
     | select(unread($cs))' "$f" 2>/dev/null
}

# A CURSOR IS A HIGH-WATER MARK PLUS HOLES. Ids are fixed-width digits, so a
# reader has read everything at or below its mark - except the few messages
# `cel inbox migrate` merged in from a split mailbox that sit BELOW the mark
# and were never read by that reader. The cursor FILE is one atomic unit:
#   line 1      the mark (all a plain cursor ever held, no trailing newline)
#   digit lines ids below the mark that are still unread (the holes)
#   #merged X   migration bookkeeping: legacy name X is already folded in
# so a mark and its holes can never be written apart. Without a migration
# the file is one line: the plain mark.
#
# One JSON array of {k, h} for the cursor files that exist; empty array means
# nothing was ever read. A message is unread when EVERY listed cursor says so
# (the furthest-along reader wins, hole-aware). Builtins only:
# `cel fleet` counts the processes it starts.
_inbox_cursors_json() { # <cursor-file>...
  local c out="" sep="" lines l h
  for c in "$@"; do
    [ -f "$c" ] || continue
    lines=(); mapfile -t lines < "$c"
    h=""
    for l in "${lines[@]:1}"; do
      [[ "$l" =~ ^[0-9]+$ ]] && h="$h${h:+,}\"$l\""
    done
    # the mark is digits (ids); anything else is escaped by jq, never trusted
    if [[ "${lines[0]:-}" =~ ^[0-9]*$ ]]; then
      out="$out$sep{\"k\":\"${lines[0]:-}\",\"h\":[$h]}"
    else
      out="$out$sep$(jq -nc --arg k "${lines[0]}" --argjson h "[$h]" '{k: $k, h: $h}')"
    fi
    sep=","
  done
  printf '[%s]' "$out"
}
_INBOX_UNREAD_DEF='def unread($cs): . as $m
  | ($cs | length) == 0
    or ([$cs[] | (($m.id > .k) or (.h | index($m.id) != null))] | all);'


# How long the OLDEST unread item has waited, in seconds; 0 when there is
# none. The age of the newest says how busy the senders are; the age of the
# oldest says how far behind the reader is, which is the question.
inbox_oldest_unread_secs() { # <ws> <who> [kinds-regex]
  local ts
  ts="$(inbox_unread_json "$1" "$2" \
    | jq -r --arg k "${3:-}" 'select($k == "" or (.kind | test($k))) | .ts' 2>/dev/null | sed -n 1p)"
  [ -n "$ts" ] || { printf '0'; return 0; }
  local then now
  then="$(date -d "$ts" +%s 2>/dev/null || printf 0)"
  now="$(date +%s)"
  [ "$then" -gt 0 ] || { printf '0'; return 0; }
  printf '%s' "$(( now - then ))"
}

# The three facts every view of this box needs about one mailbox, as one JSON
# object so text and --json cannot drift apart.
inbox_mail_json() { # <ws> [who]
  local ws="$1" who="${2:-root}" n secs reader
  n="$(inbox_unread_json "$ws" "$who" | grep -c . || true)"
  [ -n "$n" ] || n=0
  secs="$(inbox_oldest_unread_secs "$ws" "$who")"
  reader="$(inbox_reader_of "$ws" "$who" 2>/dev/null || true)"
  jq -nc --argjson n "${n:-0}" --argjson secs "${secs:-0}" --arg reader "$reader" \
    '{to_root_unread: $n, oldest_secs: $secs, reader: $reader}'
}

# ONE CURSOR PER READER, NOT PER MAILBOX. A mailbox such as root can have
# several readers (a root pane, the console); a shared cursor would let
# whichever looked first consume the other's mail. When the reader IS the
# recipient the plain <ws>.<who>.cursor name is used.
_inbox_cursor() { # <ws> <recipient>
  local reader; reader="$(_inbox_me)"
  if [ -n "$reader" ] && [ "$reader" != "$2" ]; then
    printf '%s/%s.%s.%s.cursor' "$(_inbox_dir)" "$1" "$2" "$reader"
  else
    printf '%s/%s.%s.cursor' "$(_inbox_dir)" "$1" "$2"
  fi
}

# Every registered workspace, for the console: mailboxes are per workspace and
# the console belongs to none of them, so it drains them all. Output lines are
# prefixed [<ws>] because "a decision from games-orch" means nothing without
# knowing which box it came from.
_inbox_all_ws() { registry_names 2>/dev/null || true; }
# The sweep --all-workspaces makes, plus the mailbox --workspace named beside it
# when the registry does not list it: an orchestrator launched for a workspace
# the registry has not caught up with still reads its home mailbox.
_inbox_every_ws() { # [extra-ws]
  local all; all="$(_inbox_all_ws)"
  [ -n "$all" ] && printf '%s\n' "$all"
  [ -n "${1:-}" ] && ! printf '%s\n' "$all" | grep -qxF "$1" && printf '%s\n' "$1"
  return 0
}

# THE MAILBOX LOCK. Append is atomic enough for one line under O_APPEND, but
# two senders can still interleave partial writes on some filesystems, and a
# look-then-write (a fingerprint roll-up, a prune) must not interleave with
# anyone at all - so every writer runs under a flock on the mailbox file itself
# when flock is available. <cmd> runs with the mailbox open for append on fd 9.
# The lock is the file's INODE: a writer that replaced the mailbox would leave
# a waiting sender appending to the old, unlinked one, so nobody replaces it -
# a rewrite goes in place.
_inbox_with_lock() { # <file> <cmd...>
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  # A MIGRATION THAT WAS KILLED HALF WAY (cel inbox migrate) leaves a pending
  # journal; whoever takes the lock next finishes it BEFORE touching the file,
  # so nothing is ever appended to a half-rewritten mailbox.
  local pend="${f%.jsonl}.migrate.pending"
  if have flock; then
    ( flock 9
      [ ! -f "$pend" ] || _inbox_migrate_resume "$(basename "${f%.jsonl}")"
      "$@" ) 9>>"$f"
  else
    [ ! -f "$pend" ] || _inbox_migrate_resume "$(basename "${f%.jsonl}")"
    "$@" 9>>"$f"
  fi
}

_inbox_append() { # <file> <json-line>
  _inbox_with_lock "$1" _inbox_write_line "$2"
}
_inbox_write_line() { printf '%s\n' "$1" >&9; }  # under _inbox_with_lock

cmd_inbox() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    send)  _inbox_send "$@";;
    read)  _inbox_read "$@";;
    count) _inbox_count "$@";;
    watch) _inbox_watch "$@";;
    open)  _inbox_open "$@";;
    resolve) _inbox_resolve "$@";;
    prune) _inbox_prune "$@";;
    migrate) _inbox_migrate "$@";;
    whoami) _inbox_me; printf '\n';;
    help|--help|-h) _inbox_usage;;
    *) c_err "cel inbox: unknown subcommand '$sub'"; _inbox_usage; return 2;;
  esac
}

_inbox_usage() {
  cat <<'EOS'
cel inbox - messages between agents that never type into a pane

  cel inbox send <to> <message> [--from x] [--workspace w] [--kind status|escalation] [--fp <key>]
      --fp is a CONDITION KEY. While an item with that key is still open, a
      repeat is recorded as an update on it instead of a second item - the
      same sentence said twenty-four times is one condition, not twenty-four.
  cel inbox read [--for <who>] [--workspace w|--all-workspaces] [--all] [--json]
      unread items; marks them read (cursor), --all is a look that does not.
      --for defaults to WHO YOU ARE, derived from your cwd: a workspace root
      is "root", <ws>/repos/<repo> and <ws>/products/<p> are "<name>-orch",
      a worktree is its worker alias, the console dir is "console". Override
      with CEL_INBOX_ME.
      --all-workspaces reads every registered mailbox, each line prefixed
      [<ws>]. The cursor is per READER, so the console reading root's mail
      does not consume it from under a root pane.
      --workspace beside --all-workspaces adds that mailbox to the sweep
      when the registry does not list it (read, count, watch, open).
      NOTHING IS SAID OUT LOUD: with no unread mail the reader is told which
      identity and which workspace it just asked about, whether that mailbox
      has ever existed, and whether the same reader has mail in another
      workspace. A cwd that names no workspace is REFUSED, not answered with
      emptiness - pass --workspace or --all-workspaces. --json carries the
      three states as {state: empty|no_mailbox|no_workspace, elsewhere: [...]}.
  cel inbox prune [--workspace w] [--dry-run]
      archive mail addressed to a WORKER that no longer exists. Long-lived
      recipients (root, <repo>-orch) are never pruned - they come back.
  cel inbox count [--for <who>] [--workspace w|--all-workspaces]  unread count
      stdout is the number; the state behind a 0 is said on stderr.
  cel inbox watch [--for <who>] [--workspace w|--all-workspaces] [--parent <pid>]
      tail new items, one line each for a runtime task that monitors stdout.
      The command itself does not wake an agent. Decisions/blockers also raise
      a desktop notification via herdr; set CEL_INBOX_NOTIFY=0 to silence it.
  cel inbox open [--for <who>] [--workspace w|--all-workspaces] [--json] [--ranked]
      UNRESOLVED decisions and blockers for that recipient - regardless of the
      read cursor. Reading a decision does not resolve it; only `resolve` does.
      A rolled-up item shows (×n, last HH:MM); --json carries count and
      last_ts. --all-workspaces prefixes each line [<ws>].
      --ranked asks a different question of the same mailbox: of the UNREAD
      mail, what needs a person now. A decision model scores each message once
      (lib/triage.sh) and the top `inbox.top_n` are shown, then `and N more`.
      Looking, not reading: the cursor does not move.
  cel inbox resolve <id> [--by <who>] [--workspace w]  close a decision/blocker
  cel inbox resolve --all [--from <who>] [--matching <substr>] [--kind k]
                    [--older-than <hours>] [--by <who>] [--workspace w]
      close every open item that matches every filter given. No filter means
      everything open for the reader; the count is printed either way.
  cel inbox migrate --workspace w [--apply] [--only <legacy-name>]
      repair a mailbox the old alias sanitiser split in two (a 31-character
      name beside its 32-character alias): merges mail AND each reader's
      unread position, only on identity evidence, dry run unless --apply.
      Mail is addressed by the canonical alias or by the full repo-branch
      name - both reach the same mailbox.
  cel inbox whoami                                    who this pane is, by cwd

  kinds: status (default) | escalation | decision | blocked. A decision or
  blocker stays in `open` until someone resolves it, however much mail lands
  after it - a buried question is the failure this exists to prevent.
  MAIL TO root IS FOR A PERSON: escalation, decision, blocked. Ticket status
  belongs in the ledger (`cel-fanout status`), which every view already reads;
  `--kind status` to root warns and still sends.
EOS
}

# Mail to a worker that no longer exists can never be read: a worker mailbox
# is named for one worktree on one branch. Left in place it is permanent
# noise in every backlog report.
#
# Archived rather than deleted: it is the record of what was said to a worker
# that never heard it - evidence for why a ticket stalled.
#
# ROOT AND ORCHESTRATORS ARE NEVER PRUNED. They are restarted routinely, and
# mail sent while one was down is the mail it most needs on the way back up.
_inbox_prune() { # [--workspace w] [--dry-run]
  local ws="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "cel inbox prune: unknown argument '$1'" ;;
    esac
  done
  ws="$(_inbox_ws "$ws")"
  local f; f="$(_inbox_file "$ws")"
  [ -f "$f" ] || { c_ok "no mailbox for $ws"; return 0; }

  local live
  live="$(_inbox_roster)" || { c_warn "agent discovery unavailable - refusing to prune on no evidence"; return 0; }
  [ -n "$live" ] || { c_warn "agent discovery returned no agents - refusing to prune on no evidence"; return 0; }
  # A dry run writes nothing and takes nothing; a real prune holds the mailbox
  # lock from its read to its rewrite, so mail sent meanwhile waits for it and
  # lands in the rewritten mailbox instead of under it.
  if [ "$dry" -eq 1 ]; then _inbox_prune_run "$ws" "$live" 1; return; fi
  _inbox_with_lock "$f" _inbox_prune_run "$ws" "$live" 0
}

_inbox_prune_run() { # <ws> <live roster> <dry 0|1>
  local ws="$1" dry="$3" f keep archive n_a livej
  f="$(_inbox_file "$ws")"
  livej="$(printf '%s\n' "$2" | jq -Rn '[inputs | select(. != "")]')" || return 1
  # One jq pass per side rather than one per line: the lock is held throughout.
  # Lines are passed through raw, never re-serialised.
  local def='def rcpt: (((try fromjson catch null) | objects | .to) // "") | tostring;
    def kept: rcpt as $t | ($t == "" or $t == "all" or $t == "root" or $t == "console"
      or ($t | endswith("-orch")) or any($live[]; . == $t));'
  keep="$(mktemp "$(_inbox_dir)/.prune.XXXXXX")"; archive="$(mktemp "$(_inbox_dir)/.prune.XXXXXX")"
  if ! jq -rR --argjson live "$livej" "$def"' select(. != "") | select(kept)' "$f" > "$keep" \
    || ! jq -rR --argjson live "$livej" "$def"' select(. != "") | select(kept | not)' "$f" > "$archive"; then
    rm -f "$keep" "$archive"; c_err "$ws: could not read the mailbox - nothing pruned"; return 1
  fi

  n_a="$(grep -c . "$archive" 2>/dev/null || printf 0)"
  if [ "$n_a" -eq 0 ]; then
    rm -f "$keep" "$archive"; c_ok "$ws: nothing to prune"; return 0
  fi
  if [ "$dry" -eq 1 ]; then
    printf '%s\n' "would archive $n_a message(s), by recipient:"
    jq -r '.to' "$archive" | sort | uniq -c | sort -rn | head -20
    rm -f "$keep" "$archive"; return 0
  fi
  cat "$archive" >> "$(_inbox_dir)/$ws.archive.jsonl"
  # In place, not mv: senders waiting on the lock hold this inode.
  cat "$keep" > "$f"
  rm -f "$keep" "$archive"
  c_ok "$ws: archived $n_a message(s) addressed to workers that no longer exist -> $ws.archive.jsonl"
}

# The id of the OPEN item carrying this condition key, or nothing. Resolved
# items do not count: a condition that came back is news again.
# Any kind: a `status` with an fp rolls up too, though it stays out of
# `cel inbox open` (it asks nobody for anything).
_inbox_open_fp() { # <ws> <fp> [from] [to]
  local f; f="$(_inbox_file "$1")"
  [ -f "$f" ] || return 0
  [ -n "${2:-}" ] || return 0
  jq -r -s --arg fp "$2" --arg from "${3:-}" --arg to "${4:-}" '
    ([.[] | select(.kind == "resolution") | .ref]) as $done
    | [ .[]
        | select((.fp // "") == $fp)
        | select(.kind != "update" and .kind != "resolution")
        | select($from == "" or .from == $from)
        | select($to == "" or .to == $to)
        | select([.id] | inside($done) | not) ]
    | last | (.id // empty)' "$f" 2>/dev/null
}

_inbox_send() { # <to> <message> [--from x] [--workspace w] [--kind k] [--fp key]
  [ $# -ge 2 ] || die "usage: cel inbox send <to> <message> [--from x] [--kind status|escalation] [--fp key]"
  # THE RECIPIENT IS NORMALISED THE SAME WAY IT NORMALISES ITSELF
  # (_inbox_sanitise), so a sender careless about case or length still
  # reaches the mailbox the pane actually reads.
  local to="$1" message="$2"; shift 2
  case "$to" in
    all) ;;                       # the broadcast address, left alone
    # Core's pane is named core but its mailbox is root: a message to the
    # coordinator by its pane name reaches the mailbox it reads.
    core) to=root ;;
    *) to="$(_inbox_sanitise "$to")" ;;
  esac
  local from="" ws="" kind=status fp=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      --kind) kind="$2"; shift 2 ;;
      --fp) fp="$2"; shift 2 ;;
      *) die "cel inbox send: unknown argument '$1'" ;;
    esac
  done
  # `owner` is mail a person typed via `cel drive send`: the orchestrator
  # should know a person is waiting, not automation.
  case "$kind" in status|escalation|decision|blocked|owner) ;;
    *) die "cel inbox send: --kind must be status, escalation, decision, blocked or owner (got '$kind')";; esac
  # STATUS TO ROOT IS WRITE-ONLY TELEMETRY: ticket status already lives in the
  # ledger (`cel fleet`, `cel-fanout status`, the dashboard). Mail to root is
  # for something a person must answer, decide or unblock. Warned, not
  # refused, so role files that still do it keep working.
  if [ "$to" = root ] && [ "$kind" = status ]; then
    c_warn "status to root is not read by anyone; the ledger already carries it" >&2
  fi
  ws="$(_inbox_ws "$ws")"
  [ -n "$from" ] || from="$(_inbox_me)"
  # ONE OPEN ITEM PER CONDITION. While an item with this fp is still open, a
  # repeat becomes an update ON it: one new line for the reader (the bell
  # rings once), still one thing to resolve. The lookup and the append hold
  # one mailbox lock, so two senders of one condition cannot both find it
  # absent and open two items.
  _inbox_with_lock "$(_inbox_file "$ws")" _inbox_send_locked "$ws" "$to" "$from" "$kind" "$message" "$fp"
}

_inbox_send_locked() { # <ws> <to> <from> <kind> <message> <fp>  - under _inbox_with_lock
  local ws="$1" to="$2" from="$3" kind="$4" message="$5" fp="$6" id line ref=""
  id="$(date +%s%N)"
  [ -n "$fp" ] && ref="$(_inbox_open_fp "$ws" "$fp" "$from" "$to")"
  if [ -n "$ref" ]; then
    line="$(jq -nc --arg id "$id" --arg ts "$(date -Is)" --arg to "$to" --arg from "$from" \
      --arg ref "$ref" --arg msg "$message" \
      '{id: $id, ts: $ts, to: $to, from: $from, kind: "update", ref: $ref, message: $msg}')"
    _inbox_write_line "$line"
    c_ok "rolled up into $ref for $to in $ws" >&2
    printf '%s\n' "$ref"
    return 0
  fi
  line="$(jq -nc --arg id "$id" --arg ts "$(date -Is)" --arg to "$to" --arg from "$from" \
    --arg kind "$kind" --arg msg "$message" --arg cwd "$PWD" \
    --arg pane "${HERDR_PANE_ID:-}" --arg fp "$fp" \
    '{id: $id, ts: $ts, to: $to, from: $from, kind: $kind, message: $msg, cwd: $cwd, pane: $pane}
     | if $fp == "" then . else . + {fp: $fp} end')"
  _inbox_write_line "$line"
  c_ok "queued for $to in $ws" >&2
  printf '%s\n' "$id"
}

# Unread = after the recipient's cursor. Reading MOVES the cursor, so an item
# is delivered once even when a Monitor and the prompt hook both look.
_inbox_read() { # [--for who] [--workspace w|--all-workspaces] [--all] [--json]
  local who="" ws="" all=0 json=0 every=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) who="$(_inbox_sanitise "$2")"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      --all-workspaces) every=1; shift ;;
      --all) all=1; shift ;;
      --json) json=1; shift ;;
      *) die "cel inbox read: unknown argument '$1'" ;;
    esac
  done
  [ -n "$who" ] || who="$(_inbox_me)"
  if [ "$every" -eq 1 ]; then
    local n out="" one
    for n in $(_inbox_every_ws "$ws"); do
      one="$(_inbox_read_one "$n" "$who" "$all" "$json" quiet | sed "s/^/[$n] /")"
      [ -n "$one" ] || continue
      printf '%s\n' "$one"; out=1
    done
    [ -n "$out" ] || c_ok "$who: no unread mail in any registered workspace" >&2
    return 0
  fi
  local wsname
  wsname="$(_inbox_ws_here "$ws")" || { _inbox_no_workspace read
    [ "$json" -eq 1 ] && jq -nc --arg reader "$who" \
      '{state: "no_workspace", reader: $reader, workspace: null, unread: 0, elsewhere: []}'
    return 2; }
  _inbox_read_one "$wsname" "$who" "$all" "$json"
}

_inbox_read_one() { # <ws> <who> <all> <json> [quiet]
  local ws="$1" who="$2" all="$3" json="$4" quiet="${5:-}"
  local f c last items
  f="$(_inbox_file "$ws")"; c="$(_inbox_cursor "$ws" "$who")"
  # Nothing here is not nothing anywhere, and an absent file is not an empty
  # one: both go through the report so the reader learns which it was, and
  # inherit its status so an unknown workspace is non-zero. The per-workspace
  # sweep stays quiet - it has already looked everywhere.
  [ -f "$f" ] || { [ -n "$quiet" ] && return 0; _inbox_empty_report "$ws" "$who" "$json"; return $?; }
  # THE WHOLE READ HOLDS THE MAILBOX LOCK that senders and `cel inbox migrate`
  # take, so a read is entirely before or entirely after a migration - never a
  # cursor decided against one layout and written against another. (--all is a
  # look and takes nothing.)
  local lkfd=""
  if [ "$all" -eq 0 ] && have flock && { exec {lkfd}>>"$f"; } 2>/dev/null; then
    flock "$lkfd" || true
  else lkfd=""; fi
  # finish a migration that was killed half way before looking at anything
  [ "$all" -eq 1 ] || [ ! -f "${f%.jsonl}.migrate.pending" ] || _inbox_migrate_resume "$ws"
  local cs="[]"; [ "$all" -eq 0 ] && cs="$(_inbox_cursors_json "$c")"
  # An update is ONE new line, rendered as the repeat it is rather than as a
  # second full item: the reader needs to know the condition is still true,
  # not to read the same paragraph again.
  items="$(jq -cs --arg who "$who" --argjson cs "$cs" "$_INBOX_UNREAD_DEF"'
    . as $all
    | [ .[] | select(.kind != "resolution")
        | select(.to == $who or .to == "all")
        | select(unread($cs)) ]
    | map(if .kind == "update"
          then (.ref as $r | .id as $i
                | . + {count: (1 + ([$all[] | select(.kind == "update" and .ref == $r and .id <= $i)] | length))})
          else . end)
    | .[]' "$f" 2>/dev/null)"
  if [ -z "$items" ]; then
    [ -z "$lkfd" ] || exec {lkfd}>&-
    [ -n "$quiet" ] && return 0
    _inbox_empty_report "$ws" "$who" "$json"; return $?
  fi
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$items"
  else
    printf '%s\n' "$items" | jq -r 'if .kind == "update"
      then "\u21bb \(.from) (\u00d7\(.count)): \(.message)"
      else "[\(.ts[11:16]) \(.kind) from \(.from)] \(.message)" end'
  fi
  # --all is a LOOK, not a read: a human eyeballing the mailbox must not
  # consume items the recipient has not seen. Only a real read advances.
  [ "$all" -eq 1 ] && return 0
  mkdir -p "$(dirname "$c")"
  # The mark never moves back: a delivery made only of held-back (hole)
  # messages is older than the mark and must not rewind it.
  local newk oldk=""; [ -f "$c" ] && { read -r oldk < "$c" || true; }
  newk="$(printf '%s\n' "$items" | jq -r '.id' | tail -1)"
  [ "$oldk" \> "$newk" ] && newk="$oldk"
  printf '%s' "$newk" > "$c"
  # (one plain line: every hole this cursor had was just delivered)
  [ -z "$lkfd" ] || exec {lkfd}>&-
}

_inbox_count() { # [--for who] [--workspace w|--all-workspaces]
  local who="" ws="" every=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) who="$(_inbox_sanitise "$2")"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      --all-workspaces) every=1; shift ;;
      *) die "cel inbox count: unknown argument '$1'" ;;
    esac
  done
  [ -n "$who" ] || who="$(_inbox_me)"
  if [ "$every" -eq 1 ]; then
    # a hook wants ONE number: the operator has one attention, not one per box
    local n total=0
    for n in $(_inbox_every_ws "$ws"); do
      total=$(( total + $(_inbox_count_one "$n" "$who") ))
    done
    printf '%s\n' "$total"; return 0
  fi
  local wsname
  wsname="$(_inbox_ws_here "$ws")" || { _inbox_no_workspace count; return 2; }
  # STDOUT STAYS A NUMBER. The steward and the hooks do arithmetic on this, so
  # the sentence that tells a human which of the three states they are in goes
  # to stderr beside it rather than into the sum.
  local n; n="$(_inbox_count_one "$wsname" "$who")"
  printf '%s\n' "$n"
  [ "$n" -eq 0 ] || return 0
  _inbox_empty_report "$wsname" "$who" 0
}

_inbox_count_one() { # <ws> <who>
  local ws="$1" who="$2"
  local f cs
  f="$(_inbox_file "$ws")"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  # THE RECIPIENT'S BACKLOG, NOT THE CALLER'S. Three cursors can each prove
  # the mail was read: the recipient's own, the caller's per-reader one (a
  # Monitor that read on the recipient's behalf), and for root the console's.
  # The furthest along wins - ids are fixed-width digits, so string order is
  # time order.
  cs="$(_inbox_cursors_json "$(_inbox_dir)/$ws.$who.cursor" "$(_inbox_cursor "$ws" "$who")" \
          $([ "$who" = root ] && printf '%s' "$(_inbox_dir)/$ws.root.console.cursor"))"
  jq -c --arg who "$who" --argjson cs "$cs" "$_INBOX_UNREAD_DEF"'
    select(.kind != "resolution") | select(.to == $who or .to == "all") | select(unread($cs))' "$f" 2>/dev/null \
    | wc -l | tr -d ' '
}

# What a runtime-provided persistent monitor may run: one compact line per
# new item. This command does not wake agents itself and does not mark items
# read, so the recipient's prompt hook can still catch up.
_inbox_watch() { # [--workspace w|--all-workspaces] [--for who] [--parent <pid>]
  local ws="" who="" every=0 parent=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws="$2"; shift 2 ;;
      --all-workspaces) every=1; shift ;;
      --for) who="$(_inbox_sanitise "$2")"; shift 2 ;;
      --parent) parent="$2"; shift 2 ;;
      *) die "cel inbox watch: unknown argument '$1'" ;;
    esac
  done
  [ -n "$who" ] || who="$(_inbox_me)"
  # ONE WATCH PER PARENT AND READER, enforced by a lock: a restarted hook or a
  # console started twice must not leave two tailing the same mailbox. A short
  # wait covers the old watcher still exiting; anything still holding the lock
  # after that is a live duplicate, and this one exits quietly.
  if [ -n "$parent" ] && have flock; then
    local lkd="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cel-inbox-watch"
    mkdir -p "$lkd" 2>/dev/null || true
    local lkfd
    # braced: a bare `exec ... 2>/dev/null` silences every later stderr write
    if { exec {lkfd}>>"$lkd/$(_inbox_sanitise "$who").$parent.lock"; } 2>/dev/null; then
      flock -w "${CEL_INBOX_WATCH_LOCK_WAIT:-1}" "$lkfd" || return 0
    fi
  fi
  # The watcher follows the pid it was told owns it and goes when that pid
  # goes, so a parent that exits uncleanly cannot leave it tailing a dead
  # pane's mailbox (the console also kills the group: tools/console/watcher.mjs).
  #
  # FOLLOWING THE PARENT IS THE TAIL'S OWN JOB (`--pid`), NOT A SIDE PROCESS'S.
  # It used to be a subshell forking `sleep` every five seconds - the one
  # process in the tree that forked forever, so the one a transient fork
  # failure killed: bash gives up after its retries and the subshell exits
  # without sending the group kill it existed for. The rest of the tree then
  # had nothing watching the parent, and when the agent died its watcher was
  # reparented to init until the steward reaped it. Now the parent is
  # followed by the pipeline's first element, which never forks: the parent
  # goes, tail exits, jq and the line loop read EOF and `wait` below returns.
  # Every element ends the watch by dying, so none can die and leave the rest
  # of it unwatched.
  local follow=()
  [ -n "$parent" ] && follow=(-s "${CEL_WATCH_PARENT_POLL:-1}" --pid="$parent")
  # ONE TAIL FOR EVERY MAILBOX: tail follows all the files at once and names
  # each on a `==> file <==` header; one jq carries the current workspace
  # across lines. Every agent hook runs a watcher, so a pipeline per
  # workspace multiplies process counts across the box.
  local names n f files=() single=""
  local only=""
  if [ "$every" -eq 0 ]; then single="$(_inbox_ws "$ws")"; names="$single"
  else
    names="$(_inbox_every_ws "$ws")"
    # tail prints no `==>` header for a single file: name it here instead
    [ "$(printf '%s\n' "$names" | grep -c .)" -eq 1 ] && only="$names"
  fi
  for n in $names; do
    f="$(_inbox_file "$n")"; mkdir -p "$(dirname "$f")"; touch "$f"; files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  local tfd tpid
  exec {tfd}< <(exec tail -n 0 -F "${follow[@]}" "${files[@]}" 2>/dev/null)
  tpid=$!
  # Two processes, not three: jq and the line loop are the pipeline's own
  # elements, with no wrapper subshell around them.
  jq -nRr --unbuffered --arg who "$who" --arg dir "$(_inbox_dir)/" "$_INBOX_WATCH_JQ" <&"$tfd" \
    | _inbox_watch_lines "$who" "$single" "$only" &
  local fmt=$!
  exec {tfd}<&-
  # shellcheck disable=SC2064
  trap "kill $tpid 2>/dev/null; trap - EXIT; exit 130" INT TERM
  # shellcheck disable=SC2064
  trap "kill $tpid 2>/dev/null" EXIT
  wait "$fmt"
}

# Fields first, formatting in the shell: the notification needs the kind and
# the sender, and re-parsing a rendered line to get them back is how a
# message containing a colon becomes a notification from nobody.
_INBOX_WATCH_JQ='
    foreach inputs as $l ({ws: "", m: null};
      if ($l | startswith("==> ")) then
        {ws: ($l | ltrimstr("==> ") | rtrimstr(" <==") | ltrimstr($dir) | rtrimstr(".jsonl")), m: null}
      else .m = (($l | fromjson?) // null) end;
      select(.m | type == "object") | .ws as $ws | .m
      | select(.kind != "resolution") | select(.to == $who or .to == "all")
      | [("w:" + $ws), .kind, .from, ((.message // "") | tostring | gsub("\n"; " "))] | @tsv)'
_inbox_watch_lines() { # <who> <single-ws|""> <only-ws|""> < ws\tkind\tfrom\tmsg
  local who="$1" single="$2" only="$3" ws kind from msg prefix
  while IFS=$'\t' read -r ws kind from msg; do
      prefix=""; ws="${ws#w:}"  # never an empty first field: tab is IFS whitespace
      if [ -n "$single" ]; then ws="$single"
      else [ -n "$ws" ] || ws="$only"; prefix="[$ws] "; fi
      printf '%sINBOX %s from %s: %s  (cel inbox read --for %s)\n' "$prefix" "$kind" "$from" "$msg" "$who"
      # The kinds that cannot wait for someone to read this pane also raise a
      # desktop notification.
      case "$kind" in escalation|decision|blocked) _inbox_notify "$kind" "$from" "$ws" "$msg" ;; esac
    done
}

# A DECISION MUST NOT WAIT FOR THE OPERATOR TO CHANGE TABS. stdout reaches
# only whatever reads this pane, so the kinds that block someone also raise a
# desktop notification. Best-effort in every direction: no herdr, no
# HERDR_ENV, or a failing call must never kill the watch that is the only
# delivery path.
_inbox_notify() { # <kind> <from> <ws> <message>
  [ "${CEL_INBOX_NOTIFY:-1}" = 0 ] && return 0
  [ "${HERDR_ENV:-}" = "1" ] || return 0
  have herdr || return 0
  herdr notification show "$1 from $2 ($3)" --body "$(printf '%.120s' "$4")" >/dev/null 2>&1 || true
}

# DECISIONS ARE A LEDGER, NOT A QUEUE. `read` moves a cursor; that is right for
# status traffic and wrong for a question that needs an answer - a per-turn
# read of the latest mail buries an earlier still-open decision under later
# unrelated items, and the recipient never sees it again. So a decision or
# blocker stays OPEN, regardless of the cursor, until a `resolution` record
# names its id. Resolutions are appended (the file is append-only and has
# many writers), never edited in.
_inbox_open() { # [--for who] [--workspace w|--all-workspaces] [--json] [--ranked]
  local who="" ws="" json=0 every=0 ranked=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) who="$(_inbox_sanitise "$2")"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      --all-workspaces) every=1; shift ;;
      --json) json=1; shift ;;
      --ranked) ranked=1; shift ;;
      *) die "cel inbox open: unknown argument '$1'" ;;
    esac
  done
  [ -n "$who" ] || who="$(_inbox_me)"
  # RANKED IS A DIFFERENT QUESTION ABOUT THE SAME MAILBOX: not "what is still
  # open" but "of what I have not read, what needs me now". It runs over the
  # UNREAD set and is a look - the cursor does not move.
  if [ "$ranked" -eq 1 ]; then
    # shellcheck source=lib/triage.sh
    . "${BASH_SOURCE[0]%/*}/triage.sh"
    if [ "$every" -eq 1 ]; then
      local m
      for m in $(_inbox_every_ws "$ws"); do
        triage_render "$m" "$who" "$json" | sed "s/^/[$m] /"
      done
      return 0
    fi
    triage_render "$(_inbox_ws "$ws")" "$who" "$json"
    return 0
  fi
  # Everything waiting on one reader, in ONE call: "what is waiting on me" is
  # not a per-workspace question.
  if [ "$every" -eq 1 ]; then
    local n
    for n in $(_inbox_every_ws "$ws"); do
      _inbox_open_one "$n" "$who" "$json" | sed "s/^/[$n] /"
    done
    return 0
  fi
  _inbox_open_one "$(_inbox_ws "$ws")" "$who" "$json"
}

# The open items for one reader, each carrying how many times its condition has
# been reported (`count`, 1 when it was said once) and when it was last said.
_inbox_open_one() { # <ws> <who> <json>
  local ws="$1" who="$2" json="$3"
  local f; f="$(_inbox_file "$ws")"
  [ -f "$f" ] || return 0
  local items
  items="$(jq -cs --arg who "$who" '
      . as $all
      | ([.[] | select(.kind == "resolution") | .ref]) as $done
      | [ .[] | select(.kind == "decision" or .kind == "blocked")
          | select(.to == $who or .to == "all")
          | select([.id] | inside($done) | not) ]
      | map(.id as $i
            | ([$all[] | select(.kind == "update" and .ref == $i)]) as $u
            | . + {count: (1 + ($u | length)),
                   last_ts: (($u | map(.ts) | max) // .ts)})
      | .[]' "$f" 2>/dev/null)"
  [ -n "$items" ] || return 0
  if [ "$json" -eq 1 ]; then printf '%s\n' "$items"
  else printf '%s\n' "$items" | jq -r 'if (.count // 1) > 1
    then "[\(.id)] \(.ts[0:16]) \(.kind) from \(.from) (\u00d7\(.count), last \(.last_ts[11:16])): \(.message)"
    else "[\(.id)] \(.ts[0:16]) \(.kind) from \(.from): \(.message)" end'; fi
}

# One resolution record. The file is append-only and has many writers, so a
# closed item is a later line naming it, never an edit in place.
_inbox_append_resolution() { # <file> <ref> <to> <by>
  _inbox_append "$1" "$(jq -nc --arg id "$(date +%s%N)" --arg ts "$(date -Is)" --arg ref "$2" \
    --arg by "$4" --arg to "$3" \
    '{id: $id, ts: $ts, kind: "resolution", ref: $ref, by: $by, to: $to, message: ("resolved by " + $by)}')"
}

# Bulk resolve: resolving by id fits an answer to one question, not a mailbox
# of a watcher's repeats. Every filter given must match; none given means
# everything open for the reader, allowed on purpose - the count is printed
# so the operator sees exactly what the line did.
_inbox_resolve_all() { # [--from w] [--matching s] [--kind k] [--older-than h] [--for w] [--by w] [--workspace w]
  local who="" ws="" by="" from="" matching="" kind="" older=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --matching) matching="$2"; shift 2 ;;
      --kind) kind="$2"; shift 2 ;;
      --older-than) older="$2"; shift 2 ;;
      --for) who="$(_inbox_sanitise "$2")"; shift 2 ;;
      --by) by="$2"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      *) die "cel inbox resolve: unknown argument '$1'" ;;
    esac
  done
  case "$kind" in ''|decision|blocked) ;;
    *) die "cel inbox resolve: --kind must be decision or blocked (got '$kind')";; esac
  ws="$(_inbox_ws "$ws")"
  [ -n "$who" ] || who="$(_inbox_me)"
  [ -n "$by" ] || by="$(_inbox_me)"
  local f; f="$(_inbox_file "$ws")"
  [ -f "$f" ] || { c_ok "resolved 0 (by $by)"; return 0; }
  local cutoff=""
  [ -n "$older" ] && cutoff="$(date -Is -d "$older hours ago" 2>/dev/null || true)"
  local n=0 id to
  while IFS=$'\t' read -r id to; do
    [ -n "$id" ] || continue
    _inbox_append_resolution "$f" "$id" "$to" "$by"
    n=$((n + 1))
  done < <(_inbox_open_one "$ws" "$who" 1 \
    | jq -r --arg from "$from" --arg m "$matching" --arg k "$kind" --arg cut "$cutoff" '
        select($from == "" or .from == $from)
        | select($m == "" or (.message | contains($m)))
        | select($k == "" or .kind == $k)
        | select($cut == "" or (.ts < $cut))
        | [.id, .to] | @tsv')
  c_ok "resolved $n (by $by)"
}

_inbox_resolve() { # <id> [--by who] [--workspace w] | --all [filters]
  [ $# -ge 1 ] || die "usage: cel inbox resolve <id> [--by <who>] [--workspace w]"
  if [ "$1" = --all ]; then shift; _inbox_resolve_all "$@"; return $?; fi
  local id="$1"; shift
  local by="" ws=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) by="$2"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      *) die "cel inbox resolve: unknown argument '$1'" ;;
    esac
  done
  ws="$(_inbox_ws "$ws")"
  [ -n "$by" ] || by="$(_inbox_me)"
  local f; f="$(_inbox_file "$ws")"
  [ -f "$f" ] || die "cel inbox resolve: no mailbox for $ws"
  local target
  target="$(jq -c --arg id "$id" 'select(.id == $id and (.kind == "decision" or .kind == "blocked"
           or ((.fp // "") != "" and .kind != "update" and .kind != "resolution")))' "$f" 2>/dev/null | sed -n 1p || true)"
  [ -n "$target" ] || die "cel inbox resolve: no open decision or blocker with id $id in $ws"
  local to; to="$(printf '%s' "$target" | jq -r .to)"
  _inbox_append_resolution "$f" "$id" "$to" "$by"
  c_ok "resolved $id (by $by)" >&2
}

# shellcheck source=lib/inbox-migrate.sh
. "${BASH_SOURCE[0]%/*}/inbox-migrate.sh"
