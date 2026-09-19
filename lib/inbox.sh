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

_inbox_file()   { printf '%s/%s.jsonl' "$(_inbox_dir)" "$1"; }

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
  cel inbox prune [--workspace w] [--dry-run]
      archive mail addressed to a WORKER that no longer exists. Long-lived
      recipients (root, <repo>-orch) are never pruned - they come back.
  cel inbox count [--for <who>] [--workspace w|--all-workspaces]  unread count
  cel inbox watch [--for <who>] [--workspace w|--all-workspaces] [--parent <pid>]
      tail new items, one line each (what a Monitor background task runs -
      stdout is the notification). A decision or blocker also raises a desktop
      notification via herdr; set CEL_INBOX_NOTIFY=0 to silence it.
  cel inbox open [--for <who>] [--workspace w|--all-workspaces] [--json]
      UNRESOLVED decisions and blockers for that recipient - regardless of the
      read cursor. Reading a decision does not resolve it; only `resolve` does.
      A rolled-up item shows (×n, last HH:MM); --json carries count and
      last_ts. --all-workspaces prefixes each line [<ws>].
  cel inbox resolve <id> [--by <who>] [--workspace w]  close a decision/blocker
  cel inbox resolve --all [--from <who>] [--matching <substr>] [--kind k]
                    [--older-than <hours>] [--by <who>] [--workspace w]
      close every open item that matches every filter given. No filter means
      everything open for the reader; the count is printed either way.
  cel inbox whoami                                    who this pane is, by cwd

  kinds: status (default) | escalation | decision | blocked. A decision or
  blocker stays in `open` until someone resolves it, however much mail lands
  after it - a buried question is the failure this exists to prevent.
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
    local n
    for n in $(_inbox_all_ws); do
      _inbox_read_one "$n" "$who" "$all" "$json" | sed "s/^/[$n] /"
    done
    return 0
  fi
  _inbox_read_one "$(_inbox_ws "$ws")" "$who" "$all" "$json"
}

_inbox_read_one() { # <ws> <who> <all> <json>
  local ws="$1" who="$2" all="$3" json="$4"
  local f c last items
  f="$(_inbox_file "$ws")"; c="$(_inbox_cursor "$ws" "$who")"
  [ -f "$f" ] || return 0
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
  [ -n "$items" ] || return 0
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
  _inbox_count_one "$(_inbox_ws "$ws")" "$who"
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
      case "$kind" in decision|blocked) _inbox_notify "$kind" "$from" "$ws" "$msg" ;; esac
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
_inbox_open() { # [--for who] [--workspace w|--all-workspaces] [--json]
  local who="" ws="" json=0 every=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) who="$2"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      --all-workspaces) every=1; shift ;;
      --json) json=1; shift ;;
      *) die "cel inbox open: unknown argument '$1'" ;;
    esac
  done
  [ -n "$who" ] || who="$(_inbox_me)"
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
