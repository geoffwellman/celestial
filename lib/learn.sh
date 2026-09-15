# shellcheck shell=bash
# cel learn - what this workspace has found out, kept where agents read it.
#
# A software factory "must improve over time by observing itself". This plane
# was not: every hard-won fact of the last week - that a runtime's credential
# vault beats the environment, that `die` inside a pipeline exits only the
# subshell, that a tracker's state positions are per-type - lived in commit
# messages, and the project's own decisions page read "no decisions recorded".
# An agent starting a session knew none of it.
#
# `<ws>/learnings.md` is the fix, with firstmate's discipline so it cannot rot
# into a landfill:
#
#   ## Pinned        no clock, never decays, never evicted; changed only on
#                    purpose. Standing rules and the owner's preferences.
#   ## Learnings     - fact <!--a:YYYY-MM-DD-->   aging: stale after 30 days
#                    - fact <!--p:YYYY-MM-DD-->   perishable: stale after 7
#                    A stale entry must re-prove itself (`reinforce`) or it is
#                    moved to the cold archive with provenance. Stale never
#                    means deleted.
#
# A BUDGET bounds what is injected into every agent's policy block (2500
# chars): over budget, `stow` archives aging entries oldest-reinforced-first
# until under. Pinned is never archived; if pinned alone exceeds the budget
# that is a loud warning and a human decision.
[ -n "${_CEL_LEARN:-}" ] && return 0
_CEL_LEARN=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"

_LEARN_BUDGET="${CEL_LEARN_BUDGET:-2500}"
_LEARN_AGING_DAYS=30
_LEARN_PERISHABLE_DAYS=7

_learn_today() { printf '%s' "${CEL_LEARN_TODAY:-$(date +%F)}"; }
_learn_file()    { printf '%s/learnings.md' "$1"; }
_learn_archive() { printf '%s/.cel/learnings-archive.md' "$1"; }

_learn_days_since() { # <YYYY-MM-DD> -> integer days from today
  local a b
  a="$(date -d "$1" +%s 2>/dev/null || echo 0)"; b="$(date -d "$(_learn_today)" +%s 2>/dev/null || date +%s)"
  printf '%s' $(( (b - a) / 86400 ))
}

_learn_init() { # <wsdir>
  local f; f="$(_learn_file "$1")"
  [ -f "$f" ] && return 0
  printf '# Learnings\n\n## Pinned\n\n## Learnings\n' > "$f"
}

# Every entry line in the Learnings section, one per line, verbatim.
_learn_entries() { # <wsdir>
  local f; f="$(_learn_file "$1")"
  [ -f "$f" ] || return 0
  awk '/^## Learnings/{s=1; next} /^## /{s=0} s && /^- /{print}' "$f"
}
_learn_pinned() { # <wsdir>
  local f; f="$(_learn_file "$1")"
  [ -f "$f" ] || return 0
  awk '/^## Pinned/{s=1; next} /^## /{s=0} s && /^- /{print}' "$f"
}

# tier and date of one entry line: "a 2026-09-12" | "p 2026-09-12" | "u -"
_learn_meta() { # <line>
  local m
  m="$(printf '%s' "$1" | grep -oE '<!--[ap]:[0-9]{4}-[0-9]{2}-[0-9]{2}-->' | head -1 || true)"
  [ -n "$m" ] || { printf 'u -'; return 0; }
  printf '%s %s' "${m:4:1}" "${m:6:10}"
}
_learn_stale() { # <line> -> 0 if stale
  local t d age; read -r t d <<<"$(_learn_meta "$1")"
  [ "$t" = u ] && return 1
  age="$(_learn_days_since "$d")"
  case "$t" in
    a) [ "$age" -ge "$_LEARN_AGING_DAYS" ];;
    p) [ "$age" -ge "$_LEARN_PERISHABLE_DAYS" ];;
    *) return 1;;
  esac
}
_learn_fact() { printf '%s' "$1" | sed -E 's/^- //; s/ *<!--[ap]:[0-9-]+-->$//'; }

cmd_learn() {
  local sub="${1:-list}"; shift 2>/dev/null || true
  case "$sub" in
    add)       _learn_add "$@";;
    list)      _learn_list "$@";;
    reinforce) _learn_reinforce "$@";;
    stow)      _learn_stow "$@";;
    render)    _learn_render "$@";;
    help|--help|-h) _learn_usage;;
    *) c_err "cel learn: unknown subcommand '$sub'"; _learn_usage; return 2;;
  esac
}

_learn_usage() {
  cat <<'EOS'
cel learn - durable, evidence-backed facts about this workspace, kept where agents read them

  cel learn add "<fact>" [--pin|--perishable]   record one (default: aging, 30d)
  cel learn list                                numbered, with tier, age and STALE
  cel learn reinforce <n>                       today's evidence confirms entry n
  cel learn stow                                archive stale entries; enforce the budget
  cel learn render [--dir <ws>]                 the block agents get (budgeted)

Record a fact when you discover one: a runtime quirk, a provider behaviour, a
team convention, a decision and why. NOT task status - that is the ledger and
the inbox. Pinned is for standing rules; perishable for things with a known
expiry. Stale never means deleted: pruned entries go to .cel/learnings-archive.md.
EOS
}

_learn_wsdir() { # [--dir d] -> wsdir, consuming the flag from LEARN_ARGS
  local d="${LEARN_DIR:-}"
  [ -n "$d" ] || d="$(ws_current 2>/dev/null)" || die "cel learn: not inside a workspace (or pass --dir <workspace>)"
  printf '%s' "$d"
}
_learn_parse_dir() { # sets LEARN_DIR from --dir, echoes remaining args count via LEARN_REST array
  LEARN_DIR=""; LEARN_REST=()
  while [ $# -gt 0 ]; do
    case "$1" in --dir) LEARN_DIR="$2"; shift 2;; *) LEARN_REST+=("$1"); shift;; esac
  done
}

_learn_add() { # "<fact>" [--pin|--perishable] [--dir d]
  _learn_parse_dir "$@"; set -- "${LEARN_REST[@]+"${LEARN_REST[@]}"}"
  local fact="" tier=a
  while [ $# -gt 0 ]; do
    case "$1" in
      --pin) tier=pin; shift;;
      --perishable) tier=p; shift;;
      -*) die "cel learn add: unknown argument '$1'";;
      *) fact="$1"; shift;;
    esac
  done
  [ -n "$fact" ] || die 'usage: cel learn add "<fact>" [--pin|--perishable]'
  case "$fact" in *$'\n'*) die "cel learn add: one fact, one line";; esac
  local d; d="$(_learn_wsdir)"; _learn_init "$d"
  local f; f="$(_learn_file "$d")"
  if [ "$tier" = pin ]; then
    # insert at the end of the Pinned section
    awk -v line="- $fact" '
      /^## Pinned/{print; inp=1; next}
      inp && /^## /{print line; inp=0}
      {print}
      END{if(inp) print line}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    c_ok "pinned: $fact" >&2
  else
    printf -- '- %s <!--%s:%s-->\n' "$fact" "$tier" "$(_learn_today)" >> "$f"
    c_ok "learned ($([ "$tier" = p ] && echo perishable || echo aging)): $fact" >&2
  fi
}

_learn_list() { # [--dir d]
  _learn_parse_dir "$@"
  local d; d="$(_learn_wsdir)"
  local f; f="$(_learn_file "$d")"
  [ -f "$f" ] || { c_warn "no learnings yet - cel learn add \"<fact>\""; return 0; }
  local n=0 line t dt tag
  printf 'Pinned\n'
  while IFS= read -r line; do [ -n "$line" ] && printf '  %s\n' "$(_learn_fact "$line")"; done < <(_learn_pinned "$d")
  printf 'Learnings\n'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n+1)); read -r t dt <<<"$(_learn_meta "$line")"
    case "$t" in a) tag="aging $(_learn_days_since "$dt")d";; p) tag="perishable $(_learn_days_since "$dt")d";; *) tag="undated";; esac
    _learn_stale "$line" && tag="$tag STALE"
    printf '  %2d. %s  [%s]\n' "$n" "$(_learn_fact "$line")" "$tag"
  done < <(_learn_entries "$d")
  local blk; blk="$(_learn_render --dir "$d")"
  printf 'block: %s of %s chars\n' "${#blk}" "$_LEARN_BUDGET"
}

_learn_reinforce() { # <n> [--dir d]
  _learn_parse_dir "$@"; set -- "${LEARN_REST[@]+"${LEARN_REST[@]}"}"
  [ $# -ge 1 ] || die "usage: cel learn reinforce <n>"
  local want="$1" d f
  d="$(_learn_wsdir)"; f="$(_learn_file "$d")"
  [ -f "$f" ] || die "cel learn reinforce: no learnings file"
  local today; today="$(_learn_today)"
  awk -v want="$want" -v today="$today" '
    /^## Learnings/{s=1; print; next} /^## /{s=0}
    s && /^- /{ n++; if (n==want) { if ($0 ~ /<!--[ap]:[0-9-]+-->$/) sub(/<!--([ap]):[0-9-]+-->$/, "<!--" substr($0, match($0,/<!--[ap]:/)+4, 1) ":" today "-->"); else $0 = $0 " <!--a:" today "-->"; hit=1 } }
    {print}
    END{ if(!hit) exit 3 }' "$f" > "$f.tmp" || { rm -f "$f.tmp"; die "cel learn reinforce: no entry $want"; }
  mv "$f.tmp" "$f"
  c_ok "reinforced entry $want as of $today" >&2
}

# Move one entry to the cold archive, with provenance. Stale never means deleted.
_learn_archive_line() { # <wsdir> <line> <reason>
  local a; a="$(_learn_archive "$1")"
  mkdir -p "$(dirname "$a")"
  [ -f "$a" ] || printf '# Learnings archive\n\nPruned from learnings.md; never counted against the budget; grep-able.\n\n' > "$a"
  local t dt; read -r t dt <<<"$(_learn_meta "$2")"
  printf -- '- %s  <!-- archived:%s tier:%s last:%s reason:%s -->\n' "$(_learn_fact "$2")" "$(_learn_today)" "$t" "$dt" "$3" >> "$a"
}

_learn_stow() { # [--dir d]
  _learn_parse_dir "$@"
  local d; d="$(_learn_wsdir)"
  local f; f="$(_learn_file "$d")"
  [ -f "$f" ] || { c_ok "nothing to stow"; return 0; }
  local line keep=() archived=0
  # 1. decay
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if _learn_stale "$line"; then
      local t dt; read -r t dt <<<"$(_learn_meta "$line")"
      _learn_archive_line "$d" "$line" "unreinforced $(_learn_days_since "$dt")d ($([ "$t" = p ] && echo perishable || echo aging))"
      archived=$((archived+1))
    else keep+=("$line"); fi
  done < <(_learn_entries "$d")
  # 2. budget: oldest-reinforced aging first, undated last, pinned never
  local blk
  _learn_write_entries "$d" "${keep[@]+"${keep[@]}"}"
  blk="$(_learn_render --dir "$d" --full)"
  while [ "${#blk}" -gt "$_LEARN_BUDGET" ] && [ "${#keep[@]}" -gt 0 ]; do
    local victim="" vi=-1 i vdate="9999-99-99"
    for i in "${!keep[@]}"; do
      local t dt; read -r t dt <<<"$(_learn_meta "${keep[$i]}")"
      [ "$t" = u ] && dt="9999-99-98"      # undated evicted after every dated one
      if [[ "$dt" < "$vdate" ]]; then vdate="$dt"; vi=$i; victim="${keep[$i]}"; fi
    done
    [ "$vi" -ge 0 ] || break
    _learn_archive_line "$d" "$victim" "over budget ($_LEARN_BUDGET chars)"
    archived=$((archived+1))
    unset 'keep[vi]'; keep=("${keep[@]+"${keep[@]}"}")
    _learn_write_entries "$d" "${keep[@]+"${keep[@]}"}"
    blk="$(_learn_render --dir "$d" --full)"
  done
  if [ "${#blk}" -gt "$_LEARN_BUDGET" ]; then
    c_err "pinned learnings alone are ${#blk} chars, over the $_LEARN_BUDGET budget - pinned is never archived automatically; trim ## Pinned by hand"
  fi
  c_ok "stow: $archived archived, $((${#keep[@]})) kept, block ${#blk}/$_LEARN_BUDGET chars"
}

# Rewrite ONLY the Learnings section with the given entries; Pinned untouched.
_learn_write_entries() { # <wsdir> <lines...>
  local d="$1"; shift
  local f; f="$(_learn_file "$d")"
  local tmp; tmp="$(mktemp)"
  awk '/^## Learnings/{print; exit} {print}' "$f" > "$tmp"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$tmp"; done
  mv "$tmp" "$f"
}

# The block agents receive. Pinned first, then non-stale entries newest
# first; truncated to the budget by dropping the OLDEST entries (render-time
# only - stow is what archives). Empty output when there is nothing to say,
# so the policy block can append it unconditionally.
_learn_render() { # [--dir d] [--full]
  local full=0 a; local -a rest=()
  for a in "$@"; do case "$a" in --full) full=1;; *) rest+=("$a");; esac; done
  _learn_parse_dir "${rest[@]+"${rest[@]}"}"
  local d; d="${LEARN_DIR:-$(ws_current 2>/dev/null || true)}"
  [ -n "$d" ] || return 0
  local f; f="$(_learn_file "$d")"
  [ -f "$f" ] || return 0
  local pinned entries line out=""
  pinned="$(_learn_pinned "$d")"
  entries="$(while IFS= read -r line; do [ -n "$line" ] && ! _learn_stale "$line" && printf '%s\n' "$line"; done < <(_learn_entries "$d") \
             | awk '{ m=match($0,/<!--[ap]:([0-9-]+)-->/); d=(m?substr($0,m+5,10):"0000-00-00"); print d "\t" $0 }' | sort -r | cut -f2-)"
  [ -n "$pinned$entries" ] || return 0
  out=$'## Workspace learnings\n'
  out+=$'Facts this workspace has established. Trust them over general assumptions; if one proves wrong, say so and run `cel learn` to correct it.\n'
  [ -n "$pinned" ] && while IFS= read -r line; do [ -n "$line" ] && out+="- $(_learn_fact "$line")"$'\n'; done <<<"$pinned"
  local body=""
  [ -n "$entries" ] && while IFS= read -r line; do
    [ -n "$line" ] || continue
    local add="- $(_learn_fact "$line")"$'\n'
    # --full is what stow measures against: the truncated view would always
    # fit the budget by construction and nothing would ever be archived
    [ "$full" -eq 1 ] || [ $(( ${#out} + ${#body} + ${#add} )) -le "$_LEARN_BUDGET" ] || break
    body+="$add"
  done <<<"$entries"
  printf '%s%s' "$out" "$body"
}
