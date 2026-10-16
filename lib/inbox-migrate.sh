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
#     (plus a `.holes` sidecar), so a merged mark would hide older mail that
#     the reader never saw - those ids are recorded as holes and delivered
#     once, then the sidecar goes away.
#
# WHEN IT REFUSES. A migration is a statement that S and T are one identity.
# It is made only on trusted evidence, never on the shape of the names:
#   T must be PROVEN a live or past identity (a live herdr agent, a worktree
#   whose alias it is, a sender, or a cursor it holds as reader), and S must
#   show NONE of those - a genuine 31-character recipient with its own agent,
#   worktree, sends or cursor is a different identity and keeps its mailbox.
#   Anything else (both proven, neither proven, no roster to ask) is reported
#   `unsafe` and left exactly as it is. Dry run unless --apply.
#
# CONCURRENCY. --apply holds the same flock that senders and `cel inbox read`
# hold, so a send waits, a read is wholly before or wholly after, and nothing
# is overwritten without the lock. The file is rewritten IN PLACE (never
# renamed: a sender waiting on the old inode would append to a file nobody
# reads) and only from the first changed byte, so a `tail -F` watcher sees the
# file grow rather than truncate. Cursors are written before the file, which
# makes a crash in between recoverable by running the migration again.

_inbox_migrate_usage() {
  cat <<'EOS'
cel inbox migrate --workspace <w> [--apply] [--only <legacy-name>]
  Find mailboxes split by the old alias sanitiser (a 31-character name beside
  its 32-character canonical alias, or a name that is not canonical) and, with
  --apply, merge each into the canonical mailbox: mail, original ids and every
  reader's unread position are kept. Without --apply nothing is changed and
  the plan is printed. A pair is migrated only on identity evidence; otherwise
  it is reported `unsafe` and left alone (exit 1). The original mailbox and
  cursors are copied to <inbox>/migrate-backup/<w>.<time>/ first.
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

# Why is <name> a known identity here? One reason per line, none = no proof.
_inbox_mig_evidence() { # <ws> <name> <roster> <froms> <worktree-aliases> <cursor-coords>
  local ws="$1" n="$2"
  printf '%s\n' "$3" | grep -qxF "$n" && echo "a live herdr agent"
  printf '%s\n' "$4" | grep -qxF "$n" && echo "has sent mail as itself"
  printf '%s\n' "$5" | grep -qxF "$n" && echo "owns a worktree"
  printf '%s\n' "$6" | awk -F'\t' -v n="$n" '$2 == n || ($1 == n && $2 == "")' | grep -q . && echo "holds a cursor as a reader"
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
  local f dir; f="$(_inbox_file "$ws")"; dir="$(_inbox_dir)"
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
  # one-dash extension is a known identity.
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

  local i s why evs evt unsafe=0 nmsg ncur
  local -a ok=() mapargs=()
  printf '%s: %s legacy mailbox name(s)\n' "$ws" "${#src[@]}"
  for i in "${!src[@]}"; do
    s="${src[$i]}"; t="${tgt[$i]}"; why=""
    nmsg="$(jq -Rr --arg s "$s" 'try (fromjson | objects | select(.to == $s) | 1) catch empty' "$f" | grep -c . || true)"
    ncur="$(printf '%s' "$coords" | awk -F'\t' -v s="$s" '$1 == s' | grep -c . || true)"
    evs="$(_inbox_mig_evidence "$ws" "$s" "$roster" "$froms" "$wtal" "$coords" | paste -sd, -)"
    evt="$(_inbox_mig_evidence "$ws" "$t" "$roster" "$froms" "$wtal" "$coords" | paste -sd, -)"
    if [ "$roster_ok" -eq 0 ]; then why="cannot verify who is alive (herdr roster unavailable)"
    elif [ -n "$only" ] && [ "$only" != "$s" ]; then why="skipped (--only $only)"
    elif [ -n "$evs" ] && [ -n "$evt" ]; then why="both '$s' ($evs) and '$t' ($evt) are real identities - two recipients, not one"
    elif [ -n "$evs" ]; then why="'$s' is a real identity ($evs) and '$t' is not shown to be one"
    elif [ -z "$evt" ]; then why="no identity evidence for '$t' (no live agent, worktree, sender or cursor) - cannot tell '$s' is its truncation"
    fi
    if [ -z "$why" ]; then
      ok+=("$i"); printf '  %s -> %s: %s message(s), %s cursor(s) [safe: %s]\n' "$s" "$t" "$nmsg" "$ncur" "$evt"
    elif [ "${why#skipped}" != "$why" ]; then
      printf '  %s -> %s: %s\n' "$s" "$t" "$why"
    else
      unsafe=1; printf '  %s -> %s: %s message(s), %s cursor(s) [unsafe: %s; left untouched]\n' "$s" "$t" "$nmsg" "$ncur" "$why"
    fi
  done
  if [ "${#ok[@]}" -eq 0 ] || [ "$apply" -eq 0 ]; then
    [ -z "$lkfd" ] || exec {lkfd}>&-
    [ "$apply" -eq 1 ] || printf 'dry run - nothing changed; --apply migrates the safe pair(s)\n'
    return "$unsafe"
  fi

  # ---- apply, all under the lock -------------------------------------------
  local map="{}" tmp bak
  for i in "${ok[@]}"; do map="$(jq -c --arg s "${src[$i]}" --arg t "${tgt[$i]}" '. + {($s): $t}' <<< "$map")"; done
  bak="$dir/migrate-backup/$ws.$(date +%s)"
  mkdir -p "$bak"
  cp -p "$f" "$bak/"
  for cf in "$dir/$ws".*.cursor "$dir/$ws".*.cursor.holes; do [ -f "$cf" ] && cp -p "$cf" "$bak/"; done

  # 1. cursors first (see the header: a crash after this is re-runnable)
  local -A groups=()
  local r rd key tgts
  tgts="$(jq -r '[.[]] | unique[]' <<< "$map")"
  while IFS=$'\t' read -r r rd; do
    [ -n "$r" ] || continue
    key="$(jq -r --arg r "$r" '.[$r] // empty' <<< "$map")"
    [ -n "$key" ] || { printf '%s\n' "$tgts" | grep -qxF "$r" && key="$r"; }
    [ -n "$key" ] || continue          # not part of any migrated pair
    [ "$rd" = "$key" ] && rd=""        # reading its own mailbox
    groups["$key"$'\t'"$rd"]=1
  done <<< "$coords"
  local g tgt_name reader members msrc cfile k h mem merged_k holes oldfiles
  for g in "${!groups[@]}"; do
    tgt_name="${g%%$'\t'*}"; reader="${g#*$'\t'}"
    members="["; msrc=""; oldfiles=""
    # members: the target's own cursor and every mapped source's, for this reader
    for n in "$tgt_name" $(jq -r --arg t "$tgt_name" 'to_entries[] | select(.value == $t) | .key' <<< "$map"); do
      cfile="$(_inbox_mig_cursor_file "$ws" "$n" "$reader")"
      [ -f "$cfile" ] || continue
      k="$(cat "$cfile")"; h="[]"; [ -s "$cfile.holes" ] && h="$(jq -Rn '[inputs | select(length > 0)]' "$cfile.holes")"
      members="$members$msrc$(jq -nc --arg r "$n" --arg k "$k" --argjson h "$h" '{r: $r, k: $k, h: $h}')"; msrc=","
      [ "$n" = "$tgt_name" ] || oldfiles="$oldfiles$cfile "
    done
    members="$members]"
    [ "$members" != "[]" ] || continue
    # the unread set of the merged reader, below the merged mark, becomes holes
    merged_k="$(jq -r 'map(.k) | max' <<< "$members")"
    holes="$(jq -Rr --argjson mem "$members" --argjson map "$map" --arg t "$tgt_name" --arg k "$merged_k" '
      def unread($m; $id): ($id > $m.k) or ($m.h | index($id) != null);
      (try fromjson catch null) | objects | select(.kind != "resolution")
      | select(.id <= $k)
      | . as $x
      | select(
          if .to == "all"
          then all($mem[]; unread(.; $x.id))
          elif (.to == $t) or ($map[.to] == $t)
          then (([$mem[] | select(.r == $x.to)] | first) as $m | $m == null or unread($m; $x.id))
          else false end)
      | .id' "$f")"
    cfile="$(_inbox_mig_cursor_file "$ws" "$tgt_name" "$reader")"
    printf '%s' "$merged_k" > "$cfile"
    if [ -n "$holes" ]; then printf '%s\n' "$holes" > "$cfile.holes"; else rm -f "$cfile.holes"; fi
    for cf in $oldfiles; do rm -f "$cf" "$cf.holes"; done
  done

  # 2. the mailbox, in place, from the first byte that changes
  tmp="$(mktemp)"
  jq -Rr --argjson map "$map" '
    . as $raw
    | (try fromjson catch null) as $m
    | if ($m | type) == "object" and ($m.to | type) == "string" and ($map | has($m.to))
      then ($m | .legacy_to = .to | .to = $map[.to] | tojson)
      else $raw end' "$f" > "$tmp"
  local first
  first="$(cmp "$f" "$tmp" 2>/dev/null | sed -n 's/.*byte \([0-9]*\),.*/\1/p')" || true
  if [ -n "$first" ]; then
    tail -c +"$first" "$tmp" | dd of="$f" bs=4096 seek=$(( first - 1 )) oflag=seek_bytes conv=notrunc status=none
  elif ! cmp -s "$f" "$tmp"; then
    # one is a prefix of the other: only a pure append (the final newline)
    tail -c +"$(( $(wc -c < "$f") + 1 ))" "$tmp" | dd of="$f" bs=4096 seek="$(wc -c < "$f")" oflag=seek_bytes conv=notrunc status=none
  fi
  rm -f "$tmp"
  [ -z "$lkfd" ] || exec {lkfd}>&-
  printf 'migrated %s pair(s); original mailbox and cursors saved in %s\n' "${#ok[@]}" "$bak"
  return "$unsafe"
}
