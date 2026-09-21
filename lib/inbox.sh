# shellcheck shell=bash
# cel inbox - agent-to-agent messages that cannot hijack a human's keyboard.
#
# `herdr agent prompt` types into the target pane's composer, so a status
# report arriving while the operator is mid-sentence concatenates with their
# draft and Enter submits the mash-up. Observed repeatedly on the root
# orchestrator, which is where humans type most.
#
# So routine traffic goes to a FILE instead: one JSONL per workspace, one
# read cursor per recipient. Delivery is out-of-band - a Monitor background
# task on the file wakes the recipient with a notification (no keystrokes),
# and a UserPromptSubmit hook drains anything missed on the human's next
# turn. Nothing here ever touches a pane; escalations that genuinely need to
# interrupt still use `herdr agent prompt`, deliberately and rarely.
[ -n "${_CEL_INBOX:-}" ] && return 0
_CEL_INBOX=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"

_inbox_dir() { printf '%s' "${CEL_INBOX_DIR:-$HOME/.local/share/cel/inbox}"; }

# Which mailbox: the current workspace, or --workspace. Box state, not repo
# content, so it lives beside the registry rather than in the workspace repo.
_inbox_ws() { # [name]
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  local d; d="$(ws_current 2>/dev/null)" || { printf 'default'; return 0; }
  local n; n="$(ws_name "$d")"; printf '%s' "${n:-default}"
}

# WHO AM I? Every pane must drain its OWN mailbox: a hook that assumed "root"
# meant a project orchestrator's session drained root's queue and advanced
# root's cursor, so root silently lost mail it had never seen. Identity comes
# from where the agent is standing, which is unambiguous and needs no env
# plumbing through herdr:
#   <ws>                        -> root
#   <ws>/products/<product>     -> <product>-orch
#   <ws>/repos/<repo>           -> <repo>-orch
#   ~/.herdr/worktrees/<r>/<b>  -> <r>-<b>   (the worker alias cel run gave it)
#   the console directory       -> console   (also CEL_ROLE=console)
# The console stands OUTSIDE every workspace - it is the operator's one pane
# over the whole box - so there is no coordinate to derive and it fell through
# to "root", draining the root orchestrator's mailbox: the same silent theft
# the products/ case below was written to stop.
# A product orchestrator stands in <ws>/products/<p> rather than a repo
# checkout; before it had a coordinate of its own it fell through to "root"
# and drained root's mailbox - exactly the loss the repos/ case was written
# to stop. No workspace.yaml lookup here on purpose: the path IS the answer.
_inbox_me() {
  [ -n "${CEL_INBOX_ME:-}" ] && { printf '%s' "$CEL_INBOX_ME"; return 0; }
  local p wt rest repo branch d c
  p="$PWD"
  [ "${CEL_ROLE:-}" = console ] && { printf 'console'; return 0; }
  c="${CEL_CONSOLE_DIR:-$HOME/.local/share/cel/console}"
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

# same rules as cel run's agent aliases, so a mailbox name matches the pane
_inbox_sanitise() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-')"
  n="${n#"${n%%[a-z]*}"}"; n="${n%-}"
  printf '%.32s' "$n"
}

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

# CEL-53's lesson, applied again: a `die` inside `$( )` kills the subshell and
# the caller carries on with an empty string, so the refusal never reaches the
# terminal that needed it. This prints and returns; the caller returns 2 from
# its own frame, where a non-zero status is visible.
_inbox_no_workspace() { # <subcommand>
  c_err "cel inbox $1: standing here names no workspace, so there is no mailbox to read - this is not 'no mail'" >&2
  c_err "  name one with --workspace <name>, or read them all with --all-workspaces (cel ws list)" >&2
}

_inbox_file()   { printf '%s/%s.jsonl' "$(_inbox_dir)" "$1"; }

# Has this name EVER been a mailbox here? A `--for` typo invents a recipient,
# and an invented recipient is empty by construction - which read exactly like
# a mailbox somebody was keeping up with. Evidence is a message ever addressed
# to the name, or a cursor left by a past read. `root` and `console` exist by
# definition: they are addresses, not agents, and are correct before their
# first message.
_inbox_known() { # <ws> <who>
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
_inbox_empty_report() { # <ws> <who> <json>
  local ws="$1" who="$2" json="$3" state=empty lines="" where="" n c
  _inbox_known "$ws" "$who" || state=no_mailbox
  lines="$(_inbox_elsewhere "$ws" "$who")"
  if [ "$json" -eq 1 ]; then
    jq -nc --arg state "$state" --arg reader "$who" --arg ws "$ws" \
      --argjson elsewhere "$(printf '%s' "$lines" | jq -R -s 'split("\n") | map(select(length > 0))
        | map(split(":") | {workspace: .[0], unread: (.[1] | tonumber)})')" \
      '{state: $state, reader: $reader, workspace: $ws, unread: 0, elsewhere: $elsewhere}'
    return 0
  fi
  if [ "$state" = no_mailbox ]; then
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
}

# --- WHO IS ALIVE TO READ THIS MAILBOX -------------------------------------
#
# When the plan retired standing root agents, `root` survived as a NAME - the
# top, whoever is listening - with the console as the intended listener. A
# console that is not running listens to nothing. Counted on one box on
# 2026-09-19: root had taken 553 messages since the 10th, 72 of them
# escalations, into a mailbox nothing was obliged to open; one of them, still
# unread, said a reviewer pane had been dead for two days.
#
# So "nobody is reading this" becomes a FACT the box can state, rather than a
# silence every watcher mistakes for calm.

# Every pane herdr can see, one name per line. Fails (rc 1) when herdr could
# not answer at all, which is NOT the same as "nobody is alive" - the same
# rule prune, the steward and cel-fanout all learned the hard way.
_inbox_roster() {
  have herdr || return 1
  have jq || return 1
  local out
  out="$(herdr agent list 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e '.result.agents' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r '.result.agents[]?.name // empty'
}

# The console stands outside every workspace and has no pane alias, so the
# roster cannot see it. CEL-32's marker can: `cel console` exports
# CEL_ROLE=console, and /proc/<pid>/environ is fixed at exec, so it survives a
# runtime that rewrites its own argv (the reason lib/gc.sh reads environ too).
# CEL_PROC_DIR is the seam a test drives this through; nothing else moves it.
_inbox_console_live() {
  local d="${CEL_PROC_DIR:-/proc}" p
  for p in "$d"/[0-9]*; do
    [ -r "$p/environ" ] || continue
    if tr '\0' '\n' < "$p/environ" 2>/dev/null | grep -qx 'CEL_ROLE=console'; then return 0; fi
  done
  return 1
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
  want="$(_inbox_agent_want "$box" "$ws")"
  if [ -n "$want" ] && printf '%s\n' "$roster" | grep -qxF "$want"; then printf '%s' "$want"; return 0; fi
  # The console drains every workspace's ROOT mailbox and no other (CEL-7), so
  # it is a reader of root and is not evidence for anybody else's.
  if [ "$box" = root ] && _inbox_console_live; then printf 'console'; return 0; fi
  return 0
}

# The unread items for a recipient WITHOUT touching a cursor: looking is not
# reading. Everything that reports on a backlog - fleet, doctor, the steward,
# the ranking - reads through here, so they cannot disagree about what unread
# means.
inbox_unread_json() { # <ws> <who>
  local f c last cand
  f="$(_inbox_file "$1")"
  [ -f "$f" ] || return 0
  last=""
  for cand in "$(_inbox_dir)/$1.$2.cursor" \
              $([ "$2" = root ] && printf '%s' "$(_inbox_dir)/$1.root.console.cursor"); do
    [ -f "$cand" ] || continue
    c="$(cat "$cand")"
    [ "$c" \> "$last" ] && last="$c"
  done
  jq -c --arg who "$2" --arg last "$last" \
    'select(.kind != "resolution") | select(.to == $who or .to == "all")
     | select($last == "" or (.id > $last))' "$f" 2>/dev/null
}

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

# ONE CURSOR PER READER, NOT PER MAILBOX. "root" is the address orchestrators
# escalate to - the top, whoever is listening - and it now has two readers: a
# standing root pane and the console that watches every workspace at once.
# Sharing one cursor means whichever looked first consumed the other's mail,
# which is exactly the loss the cursor was introduced to prevent. When the
# reader IS the recipient the name is unchanged, so existing cursors keep
# their place.
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

# Append is atomic enough for one line under O_APPEND, but two senders can
# still interleave partial writes on some filesystems, so serialise on a lock
# when flock is available.
_inbox_append() { # <file> <json-line>
  local f="$1" line="$2"
  mkdir -p "$(dirname "$f")"
  if have flock; then
    ( flock 9; printf '%s\n' "$line" >&9 ) 9>>"$f"
  else
    printf '%s\n' "$line" >> "$f"
  fi
}

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
      tail new items, one line each (what a Monitor background task runs -
      stdout is the notification). A decision or blocker also raises a desktop
      notification via herdr; set CEL_INBOX_NOTIFY=0 to silence it.
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
  cel inbox whoami                                    who this pane is, by cwd

  kinds: status (default) | escalation | decision | blocked. A decision or
  blocker stays in `open` until someone resolves it, however much mail lands
  after it - a buried question is the failure this exists to prevent.
  MAIL TO root IS FOR A PERSON: escalation, decision, blocked. Ticket status
  belongs in the ledger (`cel-fanout status`), which every view already reads;
  `--kind status` to root warns and still sends.
EOS
}

# Mail to a worker that no longer exists can never be read by anyone: a worker
# mailbox is named for one worktree on one branch, and when that agent is gone
# the name refers to nobody. Left in place it is permanent noise - the steward
# reports the backlog every tick, and a watcher that always has something to
# say is a watcher people stop reading. Observed 2026-09-15 in a live inbox:
# 31 recipients holding unread mail, every one of them a dead worker, and not
# a single live agent behind.
#
# Archived rather than deleted: it is the record of what was said to a worker
# that never heard it, which is exactly the evidence you want when asking why
# a ticket stalled.
#
# ROOT AND ORCHESTRATORS ARE NEVER PRUNED. They are restarted routinely - a
# compaction, a model change, a crash - and mail sent while one was down is
# the mail it most needs on the way back up.
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

  local live; live="$(herdr agent list 2>/dev/null | jq -r '.result.agents[].name // empty' | sort -u || true)"
  # herdr unreachable is not evidence that everyone died - the same rule the
  # steward and cel-fanout both learned.
  [ -n "$live" ] || { c_warn "herdr returned no agents - refusing to prune on no evidence"; return 0; }

  local keep archive n_a
  keep="$(mktemp)"; archive="$(mktemp)"
  local line to
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    to="$(printf '%s' "$line" | jq -r '.to // ""')"
    case "$to" in
      ''|all|root|console|*-orch) printf '%s\n' "$line" >> "$keep"; continue ;;
    esac
    if printf '%s\n' "$live" | grep -qxF "$to"; then
      printf '%s\n' "$line" >> "$keep"
    else
      printf '%s\n' "$line" >> "$archive"
    fi
  done < "$f"

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
  mv "$keep" "$f"
  rm -f "$archive"
  c_ok "$ws: archived $n_a message(s) addressed to workers that no longer exist -> $ws.archive.jsonl"
}

# The id of the OPEN item carrying this condition key, or nothing. Resolved
# items do not count: a condition that came back is news again.
_inbox_open_fp() { # <ws> <fp> [from] [to]
  local f; f="$(_inbox_file "$1")"
  [ -f "$f" ] || return 0
  [ -n "${2:-}" ] || return 0
  jq -r -s --arg fp "$2" --arg from "${3:-}" --arg to "${4:-}" '
    ([.[] | select(.kind == "resolution") | .ref]) as $done
    | [ .[]
        | select((.fp // "") == $fp)
        | select(.kind == "decision" or .kind == "blocked")
        | select($from == "" or .from == $from)
        | select($to == "" or .to == $to)
        | select([.id] | inside($done) | not) ]
    | last | (.id // empty)' "$f" 2>/dev/null
}

_inbox_send() { # <to> <message> [--from x] [--workspace w] [--kind k] [--fp key]
  [ $# -ge 2 ] || die "usage: cel inbox send <to> <message> [--from x] [--kind status|escalation] [--fp key]"
  # THE RECIPIENT IS NORMALISED THE SAME WAY IT NORMALISES ITSELF.
  #
  # A pane derives its own mailbox with _inbox_sanitise - lowercased and cut to
  # 32 characters - but the sender wrote whatever string it had to hand, and
  # the two only agreed by luck. A branch named ABC-20-faithful-integrity
  # produced `product-games-ABC-20-faithful-integrity`, while the worker
  # itself answered to the lowercased 32-character form, so the message sat in
  # a mailbox with almost the right name that nobody would ever open. Found in
  # a live inbox on 2026-09-15: 50-odd messages across a dozen phantom
  # mailboxes, several of them the same recipient spelled two ways.
  #
  # Normalising here makes the address canonical at the point of sending, so a
  # caller can be careless about case and length and still be delivered.
  local to="$1" message="$2"; shift 2
  case "$to" in
    all) ;;                       # the broadcast address, left alone
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
  case "$kind" in status|escalation|decision|blocked) ;;
    *) die "cel inbox send: --kind must be status, escalation, decision or blocked (got '$kind')";; esac
  # STATUS TO ROOT IS WRITE-ONLY TELEMETRY. Of the 553 messages root's mailbox
  # took on one box between 10 and 19 September, 466 were `status` - one
  # instruction in core/roles/project-orchestrator.md told every orchestrator
  # to report every ticket there, and the same facts were already in the
  # ledger and rendered by `cel fleet`, `cel-fanout status` and the dashboard.
  # Mail to root is for something a person must answer, decide or unblock.
  #
  # WARNED, NOT REFUSED: a role file somewhere in the wild still does this,
  # and a refusal would break it mid-flight. The message still arrives.
  if [ "$to" = root ] && [ "$kind" = status ]; then
    c_warn "status to root is not read by anyone; the ledger already carries it" >&2
  fi
  ws="$(_inbox_ws "$ws")"
  [ -n "$from" ] || from="$(_inbox_me)"
  local id line ref=""
  id="$(date +%s%N)"
  # ONE OPEN ITEM PER CONDITION. The steward reopens its window every four
  # hours and posted a fresh blocker each time, so one exhausted provider
  # filled a mailbox with twenty-four copies of one sentence and the console
  # showed twenty-four rows where one was true. While the item it already
  # posted is still open, the repeat becomes an update ON that item: still one
  # new line for the reader (the bell rings, once), still one thing to resolve.
  [ -n "$fp" ] && ref="$(_inbox_open_fp "$ws" "$fp" "$from" "$to")"
  if [ -n "$ref" ]; then
    line="$(jq -nc --arg id "$id" --arg ts "$(date -Is)" --arg to "$to" --arg from "$from" \
      --arg ref "$ref" --arg msg "$message" \
      '{id: $id, ts: $ts, to: $to, from: $from, kind: "update", ref: $ref, message: $msg}')"
    _inbox_append "$(_inbox_file "$ws")" "$line"
    c_ok "rolled up into $ref for $to in $ws" >&2
    printf '%s\n' "$ref"
    return 0
  fi
  line="$(jq -nc --arg id "$id" --arg ts "$(date -Is)" --arg to "$to" --arg from "$from" \
    --arg kind "$kind" --arg msg "$message" --arg cwd "$PWD" \
    --arg pane "${HERDR_PANE_ID:-}" --arg fp "$fp" \
    '{id: $id, ts: $ts, to: $to, from: $from, kind: $kind, message: $msg, cwd: $cwd, pane: $pane}
     | if $fp == "" then . else . + {fp: $fp} end')"
  _inbox_append "$(_inbox_file "$ws")" "$line"
  c_ok "queued for $to in $ws" >&2
  printf '%s\n' "$id"
}

# Unread = after the recipient's cursor. Reading MOVES the cursor, so an item
# is delivered once even when a Monitor and the prompt hook both look.
_inbox_read() { # [--for who] [--workspace w|--all-workspaces] [--all] [--json]
  local who="" ws="" all=0 json=0 every=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) who="$2"; shift 2 ;;
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
    for n in $(_inbox_all_ws); do
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
  # one: both go through the report so the reader learns which it was. The
  # per-workspace sweep stays quiet - it has already looked everywhere.
  [ -f "$f" ] || { [ -n "$quiet" ] || _inbox_empty_report "$ws" "$who" "$json"; return 0; }
  last=""; [ "$all" -eq 0 ] && [ -f "$c" ] && last="$(cat "$c")"
  # An update is ONE new line, rendered as the repeat it is rather than as a
  # second full item: the reader needs to know the condition is still true,
  # not to read the same paragraph again.
  items="$(jq -cs --arg who "$who" --arg last "$last" '
    . as $all
    | [ .[] | select(.kind != "resolution")
        | select(.to == $who or .to == "all")
        | select($last == "" or (.id > $last)) ]
    | map(if .kind == "update"
          then (.ref as $r | .id as $i
                | . + {count: (1 + ([$all[] | select(.kind == "update" and .ref == $r and .id <= $i)] | length))})
          else . end)
    | .[]' "$f" 2>/dev/null)"
  [ -n "$items" ] || { [ -n "$quiet" ] || _inbox_empty_report "$ws" "$who" "$json"; return 0; }
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
  printf '%s' "$(printf '%s\n' "$items" | jq -r '.id' | tail -1)" > "$c"
}

_inbox_count() { # [--for who] [--workspace w|--all-workspaces]
  local who="" ws="" every=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) who="$2"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      --all-workspaces) every=1; shift ;;
      *) die "cel inbox count: unknown argument '$1'" ;;
    esac
  done
  [ -n "$who" ] || who="$(_inbox_me)"
  if [ "$every" -eq 1 ]; then
    # a hook wants ONE number: the operator has one attention, not one per box
    local n total=0
    for n in $(_inbox_all_ws); do
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
  [ "$n" -eq 0 ] && _inbox_empty_report "$wsname" "$who" 0
  return 0
}

_inbox_count_one() { # <ws> <who>
  local ws="$1" who="$2"
  local f c last
  f="$(_inbox_file "$ws")"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  # THE RECIPIENT'S BACKLOG, NOT THE CALLER'S. A count asked from a shell or
  # the steward used the caller's own per-reader cursor, so every caller saw
  # a different number and the steward nagged about "root: 537 unread" that
  # the console had drained days earlier. The recipient's own cursor is the
  # measure - and for root, whose mail the console drains when no root pane
  # exists (CEL-7), the console's cursor counts too: whichever is further.
  # Three cursors can each prove the mail was read: the recipient's own, the
  # caller's per-reader one (a Monitor that read on the recipient's behalf),
  # and for root the console's. The furthest along wins - ids are fixed-width
  # digits, so string order is time order.
  local cand
  last=""
  for cand in "$(_inbox_dir)/$ws.$who.cursor" "$(_inbox_cursor "$ws" "$who")" \
              $([ "$who" = root ] && printf '%s' "$(_inbox_dir)/$ws.root.console.cursor"); do
    [ -f "$cand" ] || continue
    c="$(cat "$cand")"
    [ "$c" \> "$last" ] && last="$c"
  done
  jq -c --arg who "$who" --arg last "$last" \
    'select(.kind != "resolution") | select(.to == $who or .to == "all") | select($last == "" or (.id > $last))' "$f" 2>/dev/null \
    | wc -l | tr -d ' '
}

# What a Monitor background task runs: one compact line per NEW item, so each
# arrives as a single notification. Deliberately does not mark items read -
# the recipient's own `cel inbox read` does that, and a monitor that consumed
# the cursor would starve the catch-up hook.
_inbox_watch() { # [--workspace w|--all-workspaces] [--for who] [--parent <pid>]
  local ws="" who="" every=0 parent=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws="$2"; shift 2 ;;
      --all-workspaces) every=1; shift ;;
      --for) who="$2"; shift 2 ;;
      --parent) parent="$2"; shift 2 ;;
      *) die "cel inbox watch: unknown argument '$1'" ;;
    esac
  done
  [ -n "$who" ] || who="$(_inbox_me)"
  # BELT AND BRACES FOR A CONSOLE THAT DID NOT GET TO KILL US. A walk of the
  # box on 2026-09-19 found thirteen of these trees reparented to init, four
  # of them days old: every console that exited uncleanly left one tailing a
  # mailbox for a pane that no longer existed. The console now kills the group
  # on every exit path (tools/console/watcher.mjs), and this is the half that
  # survives the path nobody thought of - the watcher follows the pid it was
  # told owns it, and goes when that pid goes. Signalling our own process
  # group, not just this pid, because the work is a `tail | jq` pipeline.
  if [ -n "$parent" ]; then
    ( while kill -0 "$parent" 2>/dev/null; do sleep "${CEL_WATCH_PARENT_POLL:-5}"; done
      kill -TERM -- "-$$" 2>/dev/null || kill -TERM "$$" 2>/dev/null ) &
  fi
  if [ "$every" -eq 0 ]; then _inbox_watch_one "$(_inbox_ws "$ws")" "$who" ""; return 0; fi
  # One tail per workspace, merged onto this stdout. The children are killed on
  # the way out: a console restarted a few times otherwise leaves a tail per
  # mailbox per restart, all writing to a pane that no longer exists.
  local n pids=""
  for n in $(_inbox_all_ws); do
    _inbox_watch_one "$n" "$who" "[$n] " &
    pids="$pids $!"
  done
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2064
  trap "kill $pids 2>/dev/null; trap - EXIT; exit 130" INT TERM
  # shellcheck disable=SC2064
  trap "kill $pids 2>/dev/null" EXIT
  wait
}

_inbox_watch_one() { # <ws> <who> <prefix>
  local ws="$1" who="$2" prefix="$3"
  local f; f="$(_inbox_file "$ws")"
  mkdir -p "$(dirname "$f")"; touch "$f"
  # Fields first, formatting in the shell: the notification needs the kind and
  # the sender, and re-parsing a rendered line to get them back is how a
  # message containing a colon becomes a notification from nobody.
  tail -n 0 -F "$f" 2>/dev/null | jq -r --unbuffered --arg who "$who" \
    'select(.kind != "resolution") | select(.to == $who or .to == "all")
     | [.kind, .from, (.message | gsub("\n"; " "))] | @tsv' \
  | while IFS=$'\t' read -r kind from msg; do
      printf '%sINBOX %s from %s: %s  (cel inbox read --for %s)\n' "$prefix" "$kind" "$from" "$msg" "$who"
      # An ESCALATION is by definition the kind that cannot wait, and it was
      # the one kind that raised nothing: 72 of them landed in root's mailbox
      # in nine days with no signal anywhere else.
      case "$kind" in escalation|decision|blocked) _inbox_notify "$kind" "$from" "$ws" "$msg" ;; esac
    done
}

# A DECISION MUST NOT WAIT FOR THE OPERATOR TO CHANGE TABS. stdout is a
# notification only to whatever is reading this pane; a question addressed to
# the top of the tree, landing in a workspace nobody is looking at, sat unseen
# for hours. So the two kinds that block someone also raise a desktop
# notification. Best-effort in every direction: no herdr, no HERDR_ENV, or a
# failing call must never kill the watch that is the only delivery path.
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
      --for) who="$2"; shift 2 ;;
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
  # UNREAD set, after the two fixes above have cut the volume, and it is a
  # look - the cursor does not move.
  if [ "$ranked" -eq 1 ]; then
    # shellcheck source=lib/triage.sh
    . "$(dirname "${BASH_SOURCE[0]}")/triage.sh"
    if [ "$every" -eq 1 ]; then
      local m
      for m in $(_inbox_all_ws); do
        triage_render "$m" "$who" "$json" | sed "s/^/[$m] /"
      done
      return 0
    fi
    triage_render "$(_inbox_ws "$ws")" "$who" "$json"
    return 0
  fi
  # Everything waiting on one reader, in ONE call. The console loops the
  # registry itself today; a chain or a human has no such loop, and "what is
  # waiting on me" is not a per-workspace question.
  if [ "$every" -eq 1 ]; then
    local n
    for n in $(_inbox_all_ws); do
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

# CLEANING THE INBOX IS ONE LINE, NOT TWENTY-FOUR. Resolving by id is right
# for an answer to one question and absurd for a mailbox full of a watcher's
# repeats: root's held twenty-eight items that were four conditions. Every
# filter given must match; none given means everything open for the reader,
# which is allowed on purpose - the count is printed so the operator sees
# exactly what the line did.
_inbox_resolve_all() { # [--from w] [--matching s] [--kind k] [--older-than h] [--for w] [--by w] [--workspace w]
  local who="" ws="" by="" from="" matching="" kind="" older=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --matching) matching="$2"; shift 2 ;;
      --kind) kind="$2"; shift 2 ;;
      --older-than) older="$2"; shift 2 ;;
      --for) who="$2"; shift 2 ;;
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
  target="$(jq -c --arg id "$id" 'select(.id == $id and (.kind == "decision" or .kind == "blocked"))' "$f" 2>/dev/null | sed -n 1p || true)"
  [ -n "$target" ] || die "cel inbox resolve: no open decision or blocker with id $id in $ws"
  local to; to="$(printf '%s' "$target" | jq -r .to)"
  _inbox_append_resolution "$f" "$id" "$to" "$by"
  c_ok "resolved $id (by $by)" >&2
}
