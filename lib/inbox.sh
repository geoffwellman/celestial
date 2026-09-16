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
#   <ws>/repos/<repo>           -> <repo>-orch
#   ~/.herdr/worktrees/<r>/<b>  -> <r>-<b>   (the worker alias cel run gave it)
_inbox_me() {
  [ -n "${CEL_INBOX_ME:-}" ] && { printf '%s' "$CEL_INBOX_ME"; return 0; }
  local p wt rest repo branch d
  p="$PWD"
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
      | head -1)"
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
_inbox_cursor() { printf '%s/%s.%s.cursor' "$(_inbox_dir)" "$1" "$2"; }

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

  cel inbox send <to> <message> [--from x] [--workspace w] [--kind status|escalation]
  cel inbox read [--for <who>] [--workspace w] [--all] [--json]
      unread items; marks them read (cursor), --all is a look that does not.
      --for defaults to WHO YOU ARE, derived from your cwd: a workspace root
      is "root", <ws>/repos/<repo> is "<repo>-orch", a worktree is its
      worker alias. Override with CEL_INBOX_ME.
  cel inbox prune [--workspace w] [--dry-run]
      archive mail addressed to a WORKER that no longer exists. Long-lived
      recipients (root, <repo>-orch) are never pruned - they come back.
  cel inbox count [--for <who>] [--workspace w]      unread count, for hooks
  cel inbox watch [--for <who>] [--workspace w]      tail new items, one line each
      (what a Monitor background task runs - stdout is the notification)
  cel inbox open [--for <who>] [--workspace w] [--json]
      UNRESOLVED decisions and blockers for that recipient - regardless of the
      read cursor. Reading a decision does not resolve it; only `resolve` does.
  cel inbox resolve <id> [--by <who>] [--workspace w]  close a decision/blocker
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
      ''|all|root|*-orch) printf '%s\n' "$line" >> "$keep"; continue ;;
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

_inbox_send() { # <to> <message> [--from x] [--workspace w] [--kind k]
  [ $# -ge 2 ] || die "usage: cel inbox send <to> <message> [--from x] [--kind status|escalation]"
  # THE RECIPIENT IS NORMALISED THE SAME WAY IT NORMALISES ITSELF.
  #
  # A pane derives its own mailbox with _inbox_sanitise - lowercased and cut to
  # 32 characters - but the sender wrote whatever string it had to hand, and
  # the two only agreed by luck. A branch named ABC-20-faithful-integrity
  # produced `product-games-ABC-20-faithful-integrity`, while the worker
  # itself answered to the lowercased 32-character form, so the message sat in
  # a mailbox with almost the right name that nobody would ever open. Found in
  # the vhs inbox on 2026-09-15: 50-odd messages across a dozen phantom
  # mailboxes, several of them the same recipient spelled two ways.
  #
  # Normalising here makes the address canonical at the point of sending, so a
  # caller can be careless about case and length and still be delivered.
  local to="$1" message="$2"; shift 2
  case "$to" in
    all) ;;                       # the broadcast address, left alone
    *) to="$(_inbox_sanitise "$to")" ;;
  esac
  local from="" ws="" kind=status
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      --kind) kind="$2"; shift 2 ;;
      *) die "cel inbox send: unknown argument '$1'" ;;
    esac
  done
  case "$kind" in status|escalation|decision|blocked) ;;
    *) die "cel inbox send: --kind must be status, escalation, decision or blocked (got '$kind')";; esac
  ws="$(_inbox_ws "$ws")"
  [ -n "$from" ] || from="$(_inbox_me)"
  local id line
  id="$(date +%s%N)"
  line="$(jq -nc --arg id "$id" --arg ts "$(date -Is)" --arg to "$to" --arg from "$from" \
    --arg kind "$kind" --arg msg "$message" --arg cwd "$PWD" \
    --arg pane "${HERDR_PANE_ID:-}" \
    '{id: $id, ts: $ts, to: $to, from: $from, kind: $kind, message: $msg, cwd: $cwd, pane: $pane}')"
  _inbox_append "$(_inbox_file "$ws")" "$line"
  c_ok "queued for $to in $ws" >&2
  printf '%s\n' "$id"
}

# Unread = after the recipient's cursor. Reading MOVES the cursor, so an item
# is delivered once even when a Monitor and the prompt hook both look.
_inbox_read() { # [--for who] [--workspace w] [--all] [--json]
  local who="" ws="" all=0 json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) who="$2"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      --all) all=1; shift ;;
      --json) json=1; shift ;;
      *) die "cel inbox read: unknown argument '$1'" ;;
    esac
  done
  ws="$(_inbox_ws "$ws")"
  [ -n "$who" ] || who="$(_inbox_me)"
  local f c last items
  f="$(_inbox_file "$ws")"; c="$(_inbox_cursor "$ws" "$who")"
  [ -f "$f" ] || return 0
  last=""; [ "$all" -eq 0 ] && [ -f "$c" ] && last="$(cat "$c")"
  items="$(jq -c --arg who "$who" --arg last "$last" \
    'select(.kind != "resolution") | select(.to == $who or .to == "all") | select($last == "" or (.id > $last))' "$f" 2>/dev/null)"
  [ -n "$items" ] || return 0
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$items"
  else
    printf '%s\n' "$items" | jq -r '"[\(.ts[11:16]) \(.kind) from \(.from)] \(.message)"'
  fi
  # --all is a LOOK, not a read: a human eyeballing the mailbox must not
  # consume items the recipient has not seen. Only a real read advances.
  [ "$all" -eq 1 ] && return 0
  mkdir -p "$(dirname "$c")"
  printf '%s' "$(printf '%s\n' "$items" | jq -r '.id' | tail -1)" > "$c"
}

_inbox_count() { # [--for who] [--workspace w]
  local who="" ws=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) who="$2"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      *) die "cel inbox count: unknown argument '$1'" ;;
    esac
  done
  ws="$(_inbox_ws "$ws")"
  [ -n "$who" ] || who="$(_inbox_me)"
  local f c last
  f="$(_inbox_file "$ws")"; c="$(_inbox_cursor "$ws" "$who")"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  last=""; [ -f "$c" ] && last="$(cat "$c")"
  jq -c --arg who "$who" --arg last "$last" \
    'select(.kind != "resolution") | select(.to == $who or .to == "all") | select($last == "" or (.id > $last))' "$f" 2>/dev/null \
    | wc -l | tr -d ' '
}

# What a Monitor background task runs: one compact line per NEW item, so each
# arrives as a single notification. Deliberately does not mark items read -
# the recipient's own `cel inbox read` does that, and a monitor that consumed
# the cursor would starve the catch-up hook.
_inbox_watch() { # [--workspace w] [--for who]
  local ws="" who=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws="$2"; shift 2 ;;
      --for) who="$2"; shift 2 ;;
      *) die "cel inbox watch: unknown argument '$1'" ;;
    esac
  done
  ws="$(_inbox_ws "$ws")"
  [ -n "$who" ] || who="$(_inbox_me)"
  local f; f="$(_inbox_file "$ws")"
  mkdir -p "$(dirname "$f")"; touch "$f"
  tail -n 0 -F "$f" 2>/dev/null | jq -r --unbuffered --arg who "$who" \
    'select(.kind != "resolution") | select(.to == $who or .to == "all")
     | "INBOX \(.kind) from \(.from): \(.message)  (cel inbox read --for \($who))"'
}

# DECISIONS ARE A LEDGER, NOT A QUEUE. `read` moves a cursor; that is right for
# status traffic and wrong for a question that needs an answer - a per-turn
# read of the latest mail buries an earlier still-open decision under later
# unrelated items, and the recipient never sees it again. So a decision or
# blocker stays OPEN, regardless of the cursor, until a `resolution` record
# names its id. Resolutions are appended (the file is append-only and has
# many writers), never edited in.
_inbox_open() { # [--for who] [--workspace w] [--json]
  local who="" ws="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) who="$2"; shift 2 ;;
      --workspace) ws="$2"; shift 2 ;;
      --json) json=1; shift ;;
      *) die "cel inbox open: unknown argument '$1'" ;;
    esac
  done
  ws="$(_inbox_ws "$ws")"
  [ -n "$who" ] || who="$(_inbox_me)"
  local f; f="$(_inbox_file "$ws")"
  [ -f "$f" ] || return 0
  local items
  items="$(jq -cs --arg who "$who" '
      ([.[] | select(.kind == "resolution") | .ref]) as $done
      | .[] | select(.kind == "decision" or .kind == "blocked")
      | select(.to == $who or .to == "all")
      | select([.id] | inside($done) | not)' "$f" 2>/dev/null)"
  [ -n "$items" ] || return 0
  if [ "$json" -eq 1 ]; then printf '%s\n' "$items"
  else printf '%s\n' "$items" | jq -r '"[\(.id)] \(.ts[0:16]) \(.kind) from \(.from): \(.message)"'; fi
}

_inbox_resolve() { # <id> [--by who] [--workspace w]
  [ $# -ge 1 ] || die "usage: cel inbox resolve <id> [--by <who>] [--workspace w]"
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
  target="$(jq -c --arg id "$id" 'select(.id == $id and (.kind == "decision" or .kind == "blocked"))' "$f" 2>/dev/null | head -1 || true)"
  [ -n "$target" ] || die "cel inbox resolve: no open decision or blocker with id $id in $ws"
  local to; to="$(printf '%s' "$target" | jq -r .to)"
  _inbox_append "$f" "$(jq -nc --arg id "$(date +%s%N)" --arg ts "$(date -Is)" --arg ref "$id" \
    --arg by "$by" --arg to "$to" \
    '{id: $id, ts: $ts, kind: "resolution", ref: $ref, by: $by, to: $to, message: ("resolved by " + $by)}')"
  c_ok "resolved $id (by $by)" >&2
}
