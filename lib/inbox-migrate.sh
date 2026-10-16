# shellcheck shell=bash
# cel inbox migrate - recover a mailbox the old sanitiser split (AH-261017).
#
# Until AH-261017 the alias sanitiser stripped a trailing dash and THEN cut to
# 32 characters, so a name whose 32nd character is a dash was `abc-` the first
# time and `abc` the second. A worker's mail sent by full name reached `abc-`;
# mail sent to its own alias (already 32 characters) was normalised again and
# filed under the 31-character phantom `abc`, which nothing reads. The rule is
# fixed (cel_alias_norm); this is the one-time repair of mail that already
# landed on the wrong side.
#
# WHAT IT DOES. For every legacy name S that has a canonical target T:
#   * rewrites `to` from S to T in the mailbox file, keeping the original in
#     `legacy_to`; ids, timestamps, senders, bodies and order are untouched;
#   * merges S's reader cursors into T's. A cursor is a high-water mark of ids
#     (plus holes, see lib/inbox.sh), so a merged mark would hide older mail
#     that the reader never saw - those ids are recorded as holes and
#     delivered once.
#
# WHEN IT REFUSES. A migration is a statement that S and T are one identity,
# and the data cannot prove that - only disprove it. So:
#   * T must be a PROVEN identity: a live herdr agent or a worktree whose alias
#     it is. (A sender name or a cursor is self-asserted - anyone can type
#     `--from X` or `read --for X` - so those never count as proof.)
#   * S must show NO trace at all (agent, worktree, sends, cursor). Any trace
#     is a collision: two real recipients, `unsafe`, nothing touched.
#   * absence of a trace is still not proof: a genuine recipient that is dead
#     and silent looks exactly like a phantom. Such a pair is `unverified` and
#     is migrated only when the operator names it with --only <S>, which is
#     the explicit attestation that S is the truncation of T.
#   * no roster to ask => refuse. Dry run unless --apply.
#
# CRASH SAFETY. --apply is a journalled operation: the mailbox and cursors are
# copied to <inbox>/migrate-backup/, then a journal (<ws>.migrate.pending)
# records the decision. If the process dies at ANY point, the next lock holder
# - a send, a read, or `migrate --apply` - finishes it first, before touching
# the mailbox (lib/inbox.sh `_inbox_append` / `_inbox_read_one`):
#   * the file rewrite is redone from the backed-up original unless the
#     journal says it finished (nobody can have written to a half-rewritten
#     file, because every writer finishes the journal first);
#   * each cursor is replaced by ONE atomic rename of a file that carries its
#     mark, its holes and a `#merged S` note, so a retry never folds S in twice
#     and a reader's already-delivered mail is never delivered again.
# The mailbox file is rewritten IN PLACE (never renamed: a sender waiting on
# the old inode would append to a file nobody reads) from the first changed
# byte, so a `tail -F` watcher sees growth rather than truncation; if the
# rewrite is SHORTER (re-serialising a line with escapes) the file is truncated
# to the new size.

_inbox_migrate_usage() {
  cat <<'EOS'
cel inbox migrate --workspace <w> [--apply] [--only <legacy-name>]
  Find mailboxes split by the old alias sanitiser (a 31-character name beside
  its 32-character canonical alias, or a name that is not canonical) and, with
  --apply --only <legacy-name>, merge that one into the canonical mailbox:
  mail, original ids and every reader's unread position are kept. Without
  --apply nothing is changed and the plan is printed. The canonical name must
  be a live agent or own a worktree; a legacy name with any trace of its own
  is `unsafe`; one with no trace is `unverified` (absence is not proof) and is
  migrated only when named with --only. Refusals exit 1 and change nothing.
  The original mailbox and cursors are copied to
  <inbox>/migrate-backup/<w>.<time>/ first; a killed run is finished by the
  next send, read or migrate.
EOS
}

# one cursor file -> "<recipient>\t<reader>" ; reader is empty for the
# recipient's own cursor. Names never contain a dot, the workspace prefix is
# stripped, anything else is not a cursor this knows how to read.
_inbox_mig_coord() { # <ws> <file>
  local b="${2##*/}" r rd
  b="${b#"$1."}"; b="${b%.cursor}"
  case "$b" in
    *.*.*|'') return 1 ;;
    *.*) r="${b%%.*}"; rd="${b#*.}" ;;
    *) r="$b"; rd="" ;;
  esac
  [ "$rd" = "$r" ] && rd=""
  printf '%s\t%s\n' "$r" "$rd"
}

_inbox_mig_cursor_file() { # <ws> <recipient> <reader|"">
  if [ -n "$3" ]; then printf '%s/%s.%s.%s.cursor' "$(_inbox_dir)" "$1" "$2" "$3"
  else printf '%s/%s.%s.cursor' "$(_inbox_dir)" "$1" "$2"; fi
}

# TEST SEAM ONLY (CEL_TESTING): die here, as a kill -9 would.
_inbox_mig_fail() { [ -n "${CEL_TESTING:-}" ] && [ "${CEL_INBOX_MIGRATE_FAIL:-}" = "$1" ] && exit 99; return 0; }

# What shows <name> is an identity here? One reason per line, none = no trace.
#   proof (counts for the target):   a live herdr agent, a worktree it owns
#   traces only (refuse the source): a sender name, a cursor held as a reader -
#   both are typed by whoever runs the command, so they can disprove a
#   phantom but never prove a target.
_inbox_mig_proof() { # <name> <roster> <worktree-aliases>
  printf '%s\n' "$2" | grep -qxF "$1" && echo "a live herdr agent"
  printf '%s\n' "$3" | grep -qxF "$1" && echo "owns a worktree"
  return 0
}
_inbox_mig_traces() { # <name> <froms> <cursor-coords>
  printf '%s\n' "$2" | grep -qxF "$1" && echo "has sent mail as itself"
  printf '%s\n' "$3" | awk -F'\t' -v n="$1" '$2 == n || ($1 == n && $2 == "")' | grep -q . && echo "holds a cursor as a reader"
  return 0
}

_inbox_migrate() {
  local ws="" apply=0 only=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws="$2"; shift 2 ;;
      --apply) apply=1; shift ;;
      --only) only="$2"; shift 2 ;;
      -h|--help) _inbox_migrate_usage; return 0 ;;
      *) die "cel inbox migrate: unknown argument '$1'" ;;
    esac
  done
  ws="$(_inbox_ws_here "$ws")" || {
    c_err "cel inbox migrate: standing here names no workspace - pass --workspace <name>" >&2; return 2; }
  local f dir pend; f="$(_inbox_file "$ws")"; dir="$(_inbox_dir)"; pend="$dir/$ws.migrate.pending"
  [ -f "$f" ] || { printf 'no mailbox for %s - nothing to migrate\n' "$ws"; return 0; }
  have jq || die "cel inbox migrate needs jq"

  # The lock is taken first on --apply, so the plan is made against the state
  # that is then changed. The roster is asked before it: it can be slow, and
  # who is alive does not depend on the instant.
  local roster="" roster_ok=1
  roster="$(_inbox_roster)" || roster_ok=0

  local lkfd=""
  if [ "$apply" -eq 1 ] && have flock; then
    exec {lkfd}>>"$f" || die "cel inbox migrate: cannot open $f"
    flock "$lkfd"
  fi
  if [ -f "$pend" ]; then
    if [ "$apply" -eq 1 ]; then
      _inbox_migrate_resume "$ws"; printf '%s: finished an interrupted migration\n' "$ws"
    else
      printf '%s: an interrupted migration is pending; any send, read or `migrate --apply` finishes it\n' "$ws"
    fi
  fi

  local coords="" cf co
  for cf in "$dir/$ws".*.cursor; do
    [ -f "$cf" ] || continue
    co="$(_inbox_mig_coord "$ws" "$cf")" || continue
    coords="$coords$co"$'\n'
  done
  local tos froms wt wtal=""
  tos="$( { jq -Rr 'try (fromjson | objects | .to | strings) catch empty' "$f"
            printf '%s' "$coords" | awk -F'\t' '{print $1; if ($2 != "") print $2}'; } | sort -u | grep -v '^$' || true)"
  froms="$(jq -Rr 'try (fromjson | objects | .from | strings) catch empty' "$f" | sort -u)"
  for wt in "${HOME:-/nonexistent}"/.herdr/worktrees/*/*; do
    [ -d "$wt" ] || continue
    wtal="$wtal$(cel_alias_norm "$(basename "$(dirname "$wt")")-$(basename "$wt")")"$'\n'
  done

  # Candidates: a name that is not canonical, or a 31-character name whose
  # one-dash extension is a known name.
  local -a src=() tgt=()
  local n norm t
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    norm="$(cel_alias_norm "$n")"
    if [ "$norm" != "$n" ]; then
      [ -n "$norm" ] && { src+=("$n"); tgt+=("$norm"); }
    elif [ "${#n}" -eq 31 ] && [ "${n%-}" = "$n" ]; then
      t="$n-"
      if printf '%s\n%s\n%s\n' "$tos" "$froms" "$roster" | grep -qxF "$t"; then src+=("$n"); tgt+=("$t"); fi
    fi
  done <<< "$tos"
  if [ "${#src[@]}" -eq 0 ]; then
    [ -z "$lkfd" ] || exec {lkfd}>&-
    printf '%s: no split mailboxes - nothing to migrate\n' "$ws"; return 0
  fi

  local i s why pt ts bad=0 nmsg ncur label
  local -a ok=()
  printf '%s: %s legacy mailbox name(s)\n' "$ws" "${#src[@]}"
  for i in "${!src[@]}"; do
    s="${src[$i]}"; t="${tgt[$i]}"; why=""; label=""
    nmsg="$(jq -Rr --arg s "$s" 'try (fromjson | objects | select(.to == $s) | 1) catch empty' "$f" | grep -c . || true)"
    ncur="$(printf '%s' "$coords" | awk -F'\t' -v s="$s" '$1 == s' | grep -c . || true)"
    ts="$( { _inbox_mig_proof "$s" "$roster" "$wtal"; _inbox_mig_traces "$s" "$froms" "$coords"; } | paste -sd, -)"
    pt="$(_inbox_mig_proof "$t" "$roster" "$wtal" | paste -sd, -)"
    if [ "$roster_ok" -eq 0 ]; then why="cannot verify who is alive (herdr roster unavailable)"
    elif [ -n "$ts" ] && [ -n "$pt" ]; then why="both '$s' ($ts) and '$t' ($pt) are real identities - two recipients, not one"
    elif [ -n "$ts" ]; then why="'$s' is a real identity ($ts) and '$t' is not proven to be one"
    elif [ -z "$pt" ]; then why="'$t' is not proven to exist (no live agent, no worktree)"
    fi
    if [ -n "$why" ]; then
      bad=1; printf '  %s -> %s: %s message(s), %s cursor(s) [unsafe: %s; left untouched]\n' "$s" "$t" "$nmsg" "$ncur" "$why"
    elif [ "$only" = "$s" ]; then
      ok+=("$i"); printf '  %s -> %s: %s message(s), %s cursor(s) [attested with --only; %s is %s]\n' "$s" "$t" "$nmsg" "$ncur" "$t" "$pt"
    else
      bad=1; printf '  %s -> %s: %s message(s), %s cursor(s) [unverified: %s is %s, and %s shows no trace of its own - but absence of a trace is not proof it is the same worker; name it with --only %s to attest; left untouched]\n' \
        "$s" "$t" "$nmsg" "$ncur" "$t" "$pt" "$s" "$s"
    fi
  done
  if [ "${#ok[@]}" -eq 0 ] || [ "$apply" -eq 0 ]; then
    [ -z "$lkfd" ] || exec {lkfd}>&-
    [ "$apply" -eq 1 ] || { printf 'dry run - nothing changed\n'; return 0; }
    return "$bad"
  fi

  # ---- apply, all under the lock -------------------------------------------
  local map="{}" bak
  for i in "${ok[@]}"; do map="$(jq -c --arg s "${src[$i]}" --arg t "${tgt[$i]}" '. + {($s): $t}' <<< "$map")"; done
  bak="$dir/migrate-backup/$ws.$(date +%s)"
  mkdir -p "$bak"
  cp -p "$f" "$bak/"
  for cf in "$dir/$ws".*.cursor; do [ -f "$cf" ] && cp -p "$cf" "$bak/"; done
  printf 'map %s\nbak %s\n' "$map" "$bak" > "$pend.tmp" && mv "$pend.tmp" "$pend"
  _inbox_mig_fail pending
  _inbox_migrate_run "$ws"
  rm -f "$pend"
  [ -z "$lkfd" ] || exec {lkfd}>&-
  printf 'migrated %s pair(s); original mailbox and cursors saved in %s\n' "${#ok[@]}" "$bak"
  return "$bad"
}

# Finish a journalled migration. The caller holds the mailbox lock.
_inbox_migrate_resume() { # <ws>
  local pend; pend="$(_inbox_dir)/$1.migrate.pending"
  [ -f "$pend" ] || return 0
  _inbox_migrate_run "$1"
  rm -f "$pend"
}

# Both phases are safe to repeat; see the header. The journal holds the map,
# the backup directory and, once the file is done, a `file-done` line.
_inbox_migrate_run() { # <ws>
  local ws="$1" dir f pend map bak tmp first old new
  dir="$(_inbox_dir)"; f="$(_inbox_file "$ws")"; pend="$dir/$ws.migrate.pending"
  map="$(sed -n 's/^map //p' "$pend")"; bak="$(sed -n 's/^bak //p' "$pend")"

  # ---- 1. the mailbox
  if ! grep -qx 'file-done' "$pend"; then
    # a killed rewrite left a mixture; no writer has touched it since (every
    # writer finishes this journal first), so the backup IS the original
    cmp -s "$bak/$ws.jsonl" "$f" || cat "$bak/$ws.jsonl" > "$f"
    tmp="$(mktemp)"
    jq -Rr --argjson map "$map" '
      . as $raw
      | (try fromjson catch null) as $m
      | if ($m | type) == "object" and ($m.to | type) == "string" and ($map | has($m.to))
        then ($m | .legacy_to = .to | .to = $map[.to] | tojson)
        else $raw end' "$f" > "$tmp"
    first="$(cmp "$f" "$tmp" 2>/dev/null | sed -n 's/.*byte \([0-9]*\),.*/\1/p')" || true
    old="$(wc -c < "$f")"; new="$(wc -c < "$tmp")"
    if [ -n "$first" ] || [ "$old" -ne "$new" ]; then
      [ -n "$first" ] || first=$(( old + 1 ))      # only a final newline was added
      # forward, in two halves, so the test seam can die in the middle
      local len=$(( new - first + 1 )) half
      half=$(( len / 2 ))
      tail -c +"$first" "$tmp" | head -c "$half" \
        | dd of="$f" bs=4096 seek=$(( first - 1 )) oflag=seek_bytes conv=notrunc status=none
      _inbox_mig_fail file-partial
      tail -c +"$(( first + half ))" "$tmp" \
        | dd of="$f" bs=4096 seek=$(( first - 1 + half )) oflag=seek_bytes conv=notrunc status=none
      # a SHORTER rewrite (escapes re-serialised) leaves the old tail behind
      [ "$new" -ge "$old" ] || truncate -s "$new" "$f"
    fi
    rm -f "$tmp"
    _inbox_mig_fail file
    echo file-done >> "$pend"
  fi

  # ---- 2. cursors: one atomic rename each, then the legacy files go
  local coords="" cf co r rd key tgts g first_group=1
  local -A groups=()
  for cf in "$dir/$ws".*.cursor; do
    [ -f "$cf" ] || continue
    co="$(_inbox_mig_coord "$ws" "$cf")" || continue
    coords="$coords$co"$'\n'
  done
  tgts="$(jq -r '[.[]] | unique[]' <<< "$map")"
  while IFS=$'\t' read -r r rd; do
    [ -n "$r" ] || continue
    key="$(jq -r --arg r "$r" '.[$r] // empty' <<< "$map")"
    [ -n "$key" ] || { printf '%s\n' "$tgts" | grep -qxF "$r" && key="$r"; }
    [ -n "$key" ] || continue          # not part of any migrated pair
    [ "$rd" = "$key" ] && rd=""        # reading its own mailbox
    groups["$key"$'\t'"$rd"]=1
  done <<< "$coords"
  local tname reader
  for g in "${!groups[@]}"; do
    tname="${g%%$'\t'*}"; reader="${g#*$'\t'}"
    _inbox_mig_group "$ws" "$f" "$map" "$tname" "$reader" "$first_group"
    first_group=0
  done
  _inbox_mig_fail cursors
}

# One (target, reader) cursor: fold in every legacy name not yet folded.
_inbox_mig_group() { # <ws> <file> <map> <target> <reader|""> <first>
  local ws="$1" f="$2" map="$3" t="$4" rd="$5" first="$6"
  local tfile k h merged="" members="" sep="" n cfile l line
  local -a lines=() todo=() srcs=()
  tfile="$(_inbox_mig_cursor_file "$ws" "$t" "$rd")"
  if [ -f "$tfile" ]; then
    mapfile -t lines < "$tfile"
    members="$(jq -nc --arg r "$t" --arg k "${lines[0]:-}" --argjson h "$(printf '%s\n' "${lines[@]:1}" | jq -Rn '[inputs | select(test("^[0-9]+$"))]')" \
      '{r: $r, k: $k, h: $h}')"
    sep=","
    for l in "${lines[@]:1}"; do case "$l" in '#merged '*) merged="$merged ${l#'#merged '} " ;; esac; done
  fi
  mapfile -t srcs < <(jq -r --arg t "$t" 'to_entries[] | select(.value == $t) | .key' <<< "$map")
  for n in "${srcs[@]}"; do
    case "$merged" in *" $n "*) continue ;; esac     # already folded in: never twice
    todo+=("$n")
    cfile="$(_inbox_mig_cursor_file "$ws" "$n" "$rd")"
    [ -f "$cfile" ] || continue
    mapfile -t lines < "$cfile"
    members="$members$sep$(jq -nc --arg r "$n" --arg k "${lines[0]:-}" --argjson h "$(printf '%s\n' "${lines[@]:1}" | jq -Rn '[inputs | select(test("^[0-9]+$"))]')" '{r: $r, k: $k, h: $h}')"
    sep=","
  done
  if [ "${#todo[@]}" -gt 0 ]; then
    members="[$members]"
    local newk holes out
    newk="$(jq -r 'map(.k) | max // ""' <<< "$members")"
    holes="$(jq -Rr --argjson mem "$members" --argjson srcs "$(printf '%s\n' "${todo[@]}" | jq -R . | jq -sc .)" \
        --arg t "$t" --arg k "$newk" '
      def un($m; $id): ($id > $m.k) or ($m.h | index($id) != null);
      (try fromjson catch null) | objects | select(.kind != "resolution")
      | select(.id <= $k)
      | . as $x
      | (if (($x.legacy_to // "") | IN($srcs[])) then $x.legacy_to else $x.to end) as $r
      | select(
          if $x.to == "all"
          then all($mem[]; un(.; $x.id))
          elif ($r == $t) or ($r | IN($srcs[]))
          then (([$mem[] | select(.r == $r)] | first) as $m | $m == null or un($m; $x.id))
          else false end)
      | .id' "$f")"
    out="$(mktemp "$tfile.XXXXXX")"
    { printf '%s\n' "$newk"
      [ -z "$holes" ] || printf '%s\n' "$holes"
      for l in $merged "${todo[@]}"; do printf '#merged %s\n' "$l"; done
    } > "$out"
    mv "$out" "$tfile"                                 # the one atomic step
    [ "$first" -ne 1 ] || _inbox_mig_fail cursor-1
  fi
  # the legacy cursors have been folded in (now, or on an earlier pass)
  for n in "${srcs[@]}"; do rm -f "$(_inbox_mig_cursor_file "$ws" "$n" "$rd")"; done
}
