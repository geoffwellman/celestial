# shellcheck shell=bash
# cel gateway rotate-key - replace the gateway's client key with no downtime.
#
# THE KEY IS FIXED IN EVERY RUNNING AGENT. `cel run` hands it over at launch
# (OMP_GATEWAY_TOKEN, rendered from the api-key file by lib/run.sh
# _run_gateway_env) and a process environment cannot be changed from outside,
# so the old key must keep working until the last agent holding it has been
# restarted. CLIProxyAPI accepts a LIST of api-keys and reloads config.yaml
# when it changes; that is the whole method:
#
#   --stage   mint api-key.next, list old + new in config.yaml, prove both get
#             200 from /v1/models, then make api-key the new key (the old one
#             kept in api-key.previous). New launches get the new key; nothing
#             running is touched.
#   --status  which keys the config accepts, every live process still holding
#             the old key (by /proc environ, compared by sha256), and the
#             restart that hands each one the new key - root and core last.
#   --finish  refused while anyone holds the old key (unless --force); then
#             drop it from config.yaml, prove old 401 / new 200 and delete
#             api-key.previous.
#   --abort   before --finish: the old key becomes the only key again.
#
# OWNER ONLY. --stage, --finish and --abort refuse a process that carries an
# agent launch's marks, or has one above it; --status is open to agents (and
# lib/guard.sh refuses the other three to every agent pane as well).
#
# NO KEY IS EVER PRINTED. Keys move through 0600 files and curl's stdin, are
# compared by sha256, and are named by the first 12 hex digits of that hash.
[ -n "${_CEL_GATEWAY_ROTATE:-}" ] && return 0
_CEL_GATEWAY_ROTATE=1
# shellcheck source=lib/gateway.sh
. "${BASH_SOURCE[0]%/*}/gateway.sh"
# shellcheck source=lib/review-policy.sh
. "${BASH_SOURCE[0]%/*}/review-policy.sh"   # review_focus_valid: an extra reviewer's focus

# How long the gateway gets to pick up a rewritten config.yaml, in seconds.
_gwr_wait() { printf '%s' "${CEL_GATEWAY_ROTATE_WAIT:-30}"; }

# A key's sha256 (the whole hex digest), the key on stdin.
_gwr_fp() { sha256sum | cut -c1-64; }
_gwr_fp_of() { printf '%s' "$1" | _gwr_fp; }

# A key from one of the gateway's key files: a regular file of yours, not a
# link, unreadable to group and others. Nothing is minted or repaired here.
_gwr_read_key() { # <file>
  local f="$1"
  [ -f "$f" ] && [ ! -L "$f" ] && [ -s "$f" ] && [ -O "$f" ] || return 1
  case "$(stat -c %a "$f" 2>/dev/null)" in [4-7]00) ;; *) return 1 ;; esac
  tr -d '\r\n' < "$f"
}

# The sha256 of the key in one of those files; 1 when there is none.
_gwr_file_fp() { # <file>
  local k
  k="$(_gwr_read_key "$1")" || return 1
  _gwr_fp_of "$k"
}

# Write <file> atomically, 0600, the key on stdin: a launch that reads it at
# any instant gets a whole key, the old one or the new one.
_gwr_write_key() { # <file>
  local f="$1" tmp
  tmp="$(mktemp "$(dirname "$f")/.api-key.XXXXXX")" || return 1
  chmod 600 "$tmp"
  if ! cat > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  mv -f -- "$tmp" "$f"
}

# The HTTP status GET /v1/models answers one key with; 000 when nothing
# answered. The bearer rides curl's stdin, never its argv.
_gwr_http_code() { # <key>
  local code
  code="$(printf 'Authorization: Bearer %s\n' "$1" \
    | curl -s -o /dev/null -w '%{http_code}' -m 5 --noproxy '*' "$(gateway_url)/v1/models" -H @- 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

# Wait for the gateway to answer <key> with <code>, up to _gwr_wait seconds
# (it reloads config.yaml on its own). Prints the last status seen.
_gwr_await() { # <key> <code>
  local code deadline=$((SECONDS + $(_gwr_wait)))
  while :; do
    code="$(_gwr_http_code "$1")"
    if [ "$code" = "$2" ]; then printf '%s' "$code"; return 0; fi
    if [ "$SECONDS" -ge "$deadline" ]; then printf '%s' "$code"; return 1; fi
    sleep 0.5
  done
}

# Wait for <key1> to get <code1>, then <key2> <code2>. Prints the last status
# each key got, "<c1> <c2>": when the first wait fails the second key is
# probed once, so a failure reports what both keys get now, not an earlier
# answer.
_gwr_await_both() { # <key1> <code1> <key2> <code2>
  local c1 c2
  if c1="$(_gwr_await "$1" "$2")"; then
    if c2="$(_gwr_await "$3" "$4")"; then printf '%s %s' "$c1" "$c2"; return 0; fi
  else
    c2="$(_gwr_http_code "$3")"
  fi
  printf '%s %s' "$c1" "$c2"
  return 1
}

# The keys config.yaml lists, one per line - fed to a hash, never printed.
_gwr_config_keys() {
  local f; f="$(gateway_config_file)"
  [ -r "$f" ] || return 0
  awk '/^api-keys:/ { on = 1; next }
       on && /^  - / { s = $0; sub(/^  - "?/, "", s); sub(/"?[[:space:]]*$/, "", s); print s; next }
       on { on = 0 }' "$f"
}

# The proc root to read: /proc, or CEL_PROC_DIR (the fixture a test builds)
# only under this checkout's own suite - cel_under_suite (lib/common.sh)
# decides that from the process's ancestry, never from a variable, the same
# seam lib/identity.sh uses. So nothing an agent exports skips or redirects
# the owner-only check or the holder scan.
_gwr_proc() {
  if [ -n "${CEL_PROC_DIR:-}" ] && cel_under_suite; then printf '%s' "$CEL_PROC_DIR"; else printf /proc; fi
}

# THE CRASH SEAM: CEL_GATEWAY_ROTATE_CRASH_AFTER=<step> SIGKILLs the verb
# right after that file operation, so the suite can prove every point a kill
# can land on stays recoverable. Honoured only under this checkout's own
# tests/run.sh (cel_under_suite, as _gwr_proc), never for the variable alone.
_gwr_step() { # <step>
  [ -n "${CEL_GATEWAY_ROTATE_CRASH_AFTER:-}" ] && [ "$CEL_GATEWAY_ROTATE_CRASH_AFTER" = "$1" ] || return 0
  cel_under_suite || return 0
  kill -KILL "$BASHPID"
}

# config.yaml listing the current api-key alone, the rotation files left on
# disk. --finish and --abort rewrite and prove the config FIRST and delete
# api-key.previous / api-key.next LAST, so a kill at any point leaves the
# files saying what is still to do (_gateway_accepted_keys lists whatever key
# files exist; here the two rotation files read as absent).
_gwr_config_write_current_only() {
  ( _gateway_key_previous_file() { printf /dev/null; }
    _gateway_key_next_file() { printf /dev/null; }
    _gateway_config_write )
}

# The sha256s of the keys in the key files, and of the keys config.yaml
# lists: sorted, one per line. They differ only when something was cut short.
_gwr_files_fps() {
  local f fp
  for f in "$(_gateway_key_previous_file)" "$(_gateway_key_file)" "$(_gateway_key_next_file)"; do
    fp="$(_gwr_file_fp "$f")" && printf '%s\n' "$fp"
  done | sort -u
}
_gwr_config_fps() {
  local k
  while IFS= read -r k; do
    [ -z "$k" ] || printf '%s\n' "$(_gwr_fp_of "$k")"
  done < <(_gwr_config_keys) | sort -u
}

# --- who holds a key -------------------------------------------------------

# Every live process of this user whose environment carries OMP_GATEWAY_TOKEN
# with sha256 <fp>, one row per LAUNCH: the topmost holder of a chain (its
# parent does not hold the key) stands for the descendants that inherited it,
# so an agent's tool shells and helpers are counted, not listed. A detached
# helper (setsid, a double fork) is a launch of its own. Tab-separated, "-"
# for an empty field:
#   pid role name ws product team cwd comm procs
_gwr_holders() { # <sha256>
  local fp="$1" proc d pid item tok role name ws product team member wsdir st root n cwd comm
  proc="$(_gwr_proc)"
  [ -n "$proc" ] && [ -d "$proc" ] || return 0
  local -A hold=() parent=() info=() procs=()
  for d in "$proc"/[0-9]*; do
    pid="${d##*/}"
    [[ "$pid" =~ ^[0-9]+$ ]] && [ -O "$d" ] || continue
    tok="" role="" name="" ws="" product="" team="" member="" wsdir=""
    { while IFS= read -r -d '' item; do
        case "$item" in
          OMP_GATEWAY_TOKEN=*) tok="${item#*=}" ;;
          CEL_ROLE=*)          role="${item#*=}" ;;
          CEL_INBOX_ME=*)      name="${item#*=}" ;;
          CEL_INBOX_WS=*)      ws="${item#*=}" ;;
          CEL_PRODUCT=*)       product="${item#*=}" ;;
          CEL_TEAM=*)          team="${item#*=}" ;;
          CEL_TEAM_MEMBER=*)   member="${item#*=}" ;;
          CEL_WORKSPACE=*)     wsdir="${item#*=}" ;;
        esac
      done; } 2>/dev/null < "$d/environ" || continue
    [ -n "$tok" ] || continue
    [ "$(_gwr_fp_of "$tok")" = "$fp" ] || { tok=""; continue; }
    tok=""
    st=""
    { IFS= read -r st; } 2>/dev/null < "$d/stat" || true
    st="${st##*) }"; st="${st#* }"
    hold[$pid]=1
    parent[$pid]="${st%% *}"
    [ -n "$ws" ] || ws="${wsdir##*/}"
    info[$pid]="${role:--}"$'\t'"${name:-${member:--}}"$'\t'"${ws:--}"$'\t'"${product:--}"$'\t'"${team:--}"
  done
  for pid in "${!hold[@]}"; do
    root="$pid" n=0
    while [ -n "${hold[${parent[$root]:-x}]:-}" ] && [ "$n" -lt 64 ]; do
      root="${parent[$root]}"; n=$((n + 1))
    done
    procs[$root]=$(( ${procs[$root]:-0} + 1 ))
  done
  for root in "${!procs[@]}"; do
    cwd="$(readlink "$proc/$root/cwd" 2>/dev/null)" || cwd=""
    comm=""
    { IFS= read -r comm; } 2>/dev/null < "$proc/$root/comm" || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$root" "${info[$root]}" "${cwd:--}" "${comm:--}" "${procs[$root]}"
  done | sort -n
}

# The restart that hands one launch the new key, as "<order>\t<line>": a
# command, or a `#` note for what is not restarted by a command. Product agents
# and lanes first, then reviewers, team members and anything else; root and
# core LAST - the coordinator is the one still able to reach everyone while
# the others restart.
_gwr_plan_row() { # role name ws product team cwd comm
  local role="$1" name="$2" ws="$3" product="$4" team="$5" cwd="$6" comm="$7" wsopt="" p lane repo pr
  [ "$ws" = - ] || wsopt=" --workspace $ws"
  case "$role" in
    core|console) printf '9\tcel core --restart' ;;
    root) printf '8\tcel run root%s --restart' "$wsopt" ;;
    orchestrator|solo)
      p="$product"
      [ "$p" != - ] || p="${name%-orch}"
      lane=""
      case "$cwd" in */.cel/solo/"$p"/lane-*) lane="${cwd##*/lane-}"; lane="${lane%%/*}" ;; esac
      if [ -z "$lane" ] && [ "$name" != "$p-orch" ] && [ "${name#"$p"-}" != "$name" ]; then
        lane="${name#"$p"-}"
      fi
      if [ -n "$lane" ]; then
        printf '1\tcel run solo --product %s --lane %s%s --restart' "$p" "$lane" "$wsopt"
      else
        printf '1\tcel run orchestrator --product %s%s --restart' "$p" "$wsopt"
      fi ;;
    reviewer)
      # an extra reviewer is <repo>-pr-<n>-review-<focus>, a QA agent
      # <repo>-pr-<n>-qa-<focus> (both cut to 32), and the focus is named
      # only when the name still spells a whole one
      local core="$name" focus=""
      if [[ "$name" =~ ^(.+-pr-[0-9]+)-qa-(.+)$ ]]; then
        core="${BASH_REMATCH[1]}-review"
        ! review_focus_valid "${BASH_REMATCH[2]}" qa || focus=" --qa ${BASH_REMATCH[2]}"
      elif [[ "$name" =~ ^(.+-pr-[0-9]+-review)-(.+)$ ]]; then
        core="${BASH_REMATCH[1]}"
        ! review_focus_valid "${BASH_REMATCH[2]}" || focus=" --focus ${BASH_REMATCH[2]}"
      fi
      repo="${core%-pr-*-review}"; pr="${core##*-pr-}"; pr="${pr%-review}"
      printf '2\t# finishes its round on its own - cel gc closes it once its verdict is recorded; a later round on %s#%s gets a fresh reviewer (cel run reviewer --repo %s --pr %s%s%s) after it has closed' \
        "$repo" "$pr" "$repo" "$pr" "$focus" "$wsopt" ;;
    member)
      printf '3\t# a team member never resumes: its lead retires it and adds it again (cel team retire %s %s, then cel team add %s <role>)' \
        "$team" "$name" "$team" ;;
    *) printf '4\t# not a Celestial agent launch (%s, in %s): stop or restart it by hand' "$comm" "$cwd" ;;
  esac
}

# The holder table and the restart plan for holder rows.
_gwr_print_holders() { # <rows>
  local pid role name ws product team cwd comm procs
  printf '    %-28s %-8s %-13s %-6s %s\n' NAME PID ROLE PROCS COMMAND
  while IFS=$'\t' read -r pid role name ws product team cwd comm procs; do
    [ -n "$pid" ] || continue
    printf '    %-28s %-8s %-13s %-6s %s\n' "$name" "$pid" "$role" "$procs" "$comm"
  done <<< "$1"
}
_gwr_print_plan() { # <rows>
  local pid role name ws product team cwd comm procs row order line i=0
  local -A who=()
  local -a lines=()
  while IFS=$'\t' read -r pid role name ws product team cwd comm procs; do
    [ -n "$pid" ] || continue
    row="$(_gwr_plan_row "$role" "$name" "$ws" "$product" "$team" "$cwd" "$comm")"
    [ -n "${who[$row]:-}" ] || lines+=("$row")
    who[$row]="${who[$row]:+${who[$row]}, }$name (pid $pid)"
  done <<< "$1"
  [ "${#lines[@]}" -gt 0 ] || return 0
  while IFS= read -r row; do
    line="${row#*$'\t'}"
    case "$line" in
      '#'*) printf '       %s: %s\n' "${who[$row]}" "${line#\# }" ;;
      *) i=$((i + 1)); printf '    %d. %s\n         for %s\n' "$i" "$line" "${who[$row]}" ;;
    esac
  done < <(printf '%s\n' "${lines[@]}" | sort -s -t $'\t' -k1,1n)
}

# --- the verbs ---------------------------------------------------------------

# none, staged, or interrupted - a --stage or an --abort cut short. That is
# api-key.next without api-key.previous (a --stage killed before the switch),
# or api-key.previous holding the very key api-key holds: a --stage killed
# between keeping the old key and moving the new one over api-key
# (api-key.next still accepted), or an --abort killed after putting the old
# key back in api-key (until it rewrote config.yaml, the new key is still
# accepted from no key file; api-key.next only if one was left over).
# A staged rotation may still carry a leftover api-key.next: --finish
# removes it.
_gwr_state() { # -> none | staged | interrupted
  local prev cur
  if [ -e "$(_gateway_key_previous_file)" ]; then
    prev="$(_gwr_file_fp "$(_gateway_key_previous_file)")" || prev=""
    cur="$(_gwr_file_fp "$(_gateway_key_file)")" || cur=""
    if [ -n "$prev" ] && [ "$prev" = "$cur" ]; then printf interrupted; else printf staged; fi
  elif [ -e "$(_gateway_key_next_file)" ]; then printf interrupted
  else printf none; fi
}

# What the config accepts, each key named by role and fingerprint.
_gwr_print_accepted() { # <state>
  local k fp label prev="" cur="" next="" n=0 out=""
  prev="$(_gwr_file_fp "$(_gateway_key_previous_file)")" || prev=""
  cur="$(_gwr_file_fp "$(_gateway_key_file)")" || cur=""
  next="$(_gwr_file_fp "$(_gateway_key_next_file)")" || next=""
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    fp="$(_gwr_fp_of "$k")"; k=""
    case "$fp" in
      "$cur") if [ "$1" = staged ]; then label=new; else label=current; fi ;;
      "$prev") label=old ;;
      "$next") label=next ;;
      *) label="UNKNOWN (in no key file)" ;;
    esac
    n=$((n + 1))
    out="${out:+$out, }$label (sha256 ${fp:0:12})"
  done < <(_gwr_config_keys)
  printf '  config     accepts %d key(s): %s\n' "$n" "${out:-none}"
}

# The INTERRUPTED line, read from what config.yaml accepts against the key
# files - never from which files exist alone. It names the keys the config
# accepts, the rotation files left over, the verb cut short when the state
# tells (a --stage never leaves api-key.previous without api-key.next
# accepted, nor a key in no key file; an --abort rewrites the config before it
# removes a file), and the fix.
_gwr_print_interrupted() {
  local fp prev="" cur="" next="" cur_acc=0 next_acc=0 unknown=0 who acc fix
  local -a parts=()
  prev="$(_gwr_file_fp "$(_gateway_key_previous_file)")" || prev=""
  cur="$(_gwr_file_fp "$(_gateway_key_file)")" || cur=""
  next="$(_gwr_file_fp "$(_gateway_key_next_file)")" || next=""
  while IFS= read -r fp; do
    [ -n "$fp" ] || continue
    if [ "$fp" = "$cur" ]; then cur_acc=1
    elif [ -n "$next" ] && [ "$fp" = "$next" ]; then next_acc=1
    elif [ "$fp" != "$prev" ]; then unknown=$((unknown + 1)); fi
  done < <(_gwr_config_fps)
  if [ -e "$(_gateway_key_previous_file)" ]; then
    if [ "$unknown" = 0 ] && [ "$next_acc" = 1 ]; then who="a --stage"; else who="an --abort"; fi
  elif [ "$unknown" = 0 ] && [ "$next_acc" = 1 ]; then who="a --stage"
  else who="a rotation step"; fi
  [ "$cur_acc" = 0 ] || parts+=("the current key")
  [ "$next_acc" = 0 ] || parts+=("api-key.next")
  if [ "$unknown" = 1 ]; then parts+=("a key that is in no key file")
  elif [ "$unknown" -gt 1 ]; then parts+=("$unknown keys that are in no key file"); fi
  case "${#parts[@]}" in
    0) acc="config.yaml accepts no key" ;;
    1) acc="config.yaml accepts ${parts[0]}" ;;
    2) acc="config.yaml accepts ${parts[0]} and ${parts[1]}" ;;
    *) acc="config.yaml accepts ${parts[0]}, ${parts[1]} and ${parts[2]}" ;;
  esac
  [ "$cur_acc" = 1 ] || acc="$acc, not the current key"
  [ -z "$next" ] || [ "$next_acc" = 1 ] || acc="$acc; api-key.next is left over and not accepted"
  [ ! -e "$(_gateway_key_previous_file)" ] || acc="$acc; api-key.previous is left over, holding the key api-key holds"
  if [ "$who" = "an --abort" ]; then fix="cel gateway rotate-key --abort again clears it"
  else fix="cel gateway rotate-key --abort clears it"; fi
  [ "$unknown" = 0 ] || fix="$fix and stops accepting the key in no key file (cel gateway refresh also stops accepting it)"
  case "$who" in
    "a --stage")       fix="$fix, then --stage again" ;;
    "a rotation step") fix="$fix, then --stage again to rotate" ;;
  esac
  printf '  rotation   INTERRUPTED - %s was cut short: %s. Fix: %s\n' "$who" "$acc" "$fix"
}

_gwr_status() {
  if ! gateway_installed; then c_warn "no gateway on this box - cel gateway install"; return 0; fi
  local state old new next rows count procs
  state="$(_gwr_state)"
  case "$state" in
    none)        printf '  rotation   none - the current key is the only key\n' ;;
    interrupted) _gwr_print_interrupted ;;
    staged)      printf '  rotation   staged - the gateway accepts the old and the new key; new launches get the new key\n' ;;
  esac
  _gwr_print_accepted "$state"
  if [ "$state" != interrupted ] && [ "$(_gwr_config_fps)" != "$(_gwr_files_fps)" ]; then
    printf '  MISMATCH   config.yaml does not accept exactly the keys in the key files. Fix: a --finish cut short completes with cel gateway rotate-key --finish again; otherwise cel gateway refresh rewrites config.yaml from the key files\n'
  fi
  if [ "$state" = staged ] && next="$(_gwr_file_fp "$(_gateway_key_next_file)")"; then
    printf '  leftover   api-key.next (sha256 %s) is still accepted - cel gateway rotate-key --finish removes it\n' "${next:0:12}"
  fi
  if [ "$state" != staged ]; then
    new="$(_gwr_file_fp "$(_gateway_key_file)")" || new=""
    if [ -n "$new" ]; then
      rows="$(_gwr_holders "$new")"
      count="$(_gwr_count "$rows")"
      printf '  holders    %s launch(es) hold the current key\n' "$count"
    fi
    [ "$state" = interrupted ] || printf '  start one  cel gateway rotate-key --stage (owner only, from your own shell)\n'
    return 0
  fi
  old="$(_gwr_file_fp "$(_gateway_key_previous_file)")" \
    || die "cel gateway rotate-key: api-key.previous is not a private (0600) file of yours - nothing can be said about who holds it"
  new="$(_gwr_file_fp "$(_gateway_key_file)")" || new=""
  [ -z "$new" ] || printf '  holders    %s launch(es) already hold the new key\n' "$(_gwr_count "$(_gwr_holders "$new")")"
  rows="$(_gwr_holders "$old")"
  count="$(_gwr_count "$rows")"
  if [ "$count" -eq 0 ]; then
    printf '\n  Nobody holds the old key. Next: cel gateway rotate-key --finish\n'
    return 0
  fi
  procs="$(printf '%s\n' "$rows" | awk -F '\t' 'NF { n += $9 } END { print n + 0 }')"
  printf '\n  Still on the OLD key: %s launch(es), %s process(es)\n' "$count" "$procs"
  _gwr_print_holders "$rows"
  printf '\n  Restart plan - each once it is idle (--restart refuses a working agent without --force); root and core last:\n'
  _gwr_print_plan "$rows"
  printf '\n  A launch still listed after its agent restarted is a detached helper that inherited the key: stop it by pid.\n'
  printf '  Then: cel gateway rotate-key --status shows nobody, and cel gateway rotate-key --finish\n'
}

_gwr_count() { # <rows> -> how many
  local line n=0
  while IFS= read -r line; do [ -z "$line" ] || n=$((n + 1)); done <<< "$1"
  printf '%s' "$n"
}

_gwr_stage() {
  local cur new codes code_old code_new
  case "$(_gwr_state)" in
    staged) die "cel gateway rotate-key --stage: a rotation is already staged - cel gateway rotate-key --status, then --finish or --abort; nothing changed" ;;
    interrupted) die "cel gateway rotate-key --stage: an interrupted --stage left its rotation files - cel gateway rotate-key --abort clears it; nothing changed" ;;
  esac
  cur="$(_gwr_read_key "$(_gateway_key_file)")" \
    || die "cel gateway rotate-key --stage: no private (0600) api-key of yours in $(gateway_state_dir) - cel gateway install; nothing changed"
  gateway_ready \
    || die "cel gateway rotate-key --stage: the gateway is not answering on $(gateway_url) - it must load the new key before any launch is handed it; nothing changed"
  code_old="$(_gwr_http_code "$cur")"
  [ "$code_old" = 200 ] \
    || die "cel gateway rotate-key --stage: the current key gets HTTP $code_old from /v1/models, not 200 - nothing changed"
  _gateway_mint_secret "$(_gateway_key_next_file)"
  chmod 600 "$(_gateway_key_next_file)"
  new="$(_gwr_read_key "$(_gateway_key_next_file)")" \
    || die "cel gateway rotate-key --stage: could not mint api-key.next - cel gateway rotate-key --abort clears what is left"
  _gwr_step minted
  _gateway_config_write
  _gwr_step config-listed
  if ! codes="$(_gwr_await_both "$new" 200 "$cur" 200)"; then
    read -r code_new code_old <<< "$codes"
    rm -f -- "$(_gateway_key_next_file)"
    _gateway_config_write
    die "cel gateway rotate-key --stage: the gateway did not accept both keys within $(_gwr_wait)s (old: HTTP ${code_old:-000}, new: HTTP ${code_new:-000}) - api-key.next removed and config.yaml back to the current key alone; nothing else changed"
  fi
  read -r code_new code_old <<< "$codes"
  c_ok "the gateway accepts both keys: old (sha256 $(_gwr_fp_of "$cur" | cut -c1-12)) HTTP $code_old, new (sha256 $(_gwr_fp_of "$new" | cut -c1-12)) HTTP $code_new"
  # The switch: the old key is kept beside the new one first, then the new
  # key becomes the file every launch reads - one rename, so a launch reads
  # a whole key, old or new, and the config accepts both throughout.
  printf '%s' "$cur" | _gwr_write_key "$(_gateway_key_previous_file)" \
    || die "cel gateway rotate-key --stage: could not write api-key.previous - both keys stay accepted; cel gateway rotate-key --abort undoes the stage"
  _gwr_step previous-written
  mv -f -- "$(_gateway_key_next_file)" "$(_gateway_key_file)" \
    || die "cel gateway rotate-key --stage: could not move api-key.next over api-key - both keys stay accepted and launches still get the old key; cel gateway rotate-key --abort undoes the stage"
  cur="" new=""
  c_ok "api-key now holds the new key: every launch from here gets it; the old key stays accepted (api-key.previous) until --finish"
  printf '\n'
  _gwr_status
}

_gwr_finish() { # <force 0|1>
  local force="$1" old new fp rows count codes code_old code_new
  case "$(_gwr_state)" in
    none) die "cel gateway rotate-key --finish: no rotation is staged - cel gateway rotate-key --stage starts one" ;;
    interrupted) die "cel gateway rotate-key --finish: an interrupted --stage never handed api-key the new key, so there is nothing to finish - cel gateway rotate-key --abort clears it, then --stage again; nothing changed" ;;
  esac
  old="$(_gwr_read_key "$(_gateway_key_previous_file)")" \
    || die "cel gateway rotate-key --finish: api-key.previous is not a private (0600) file of yours - nothing changed"
  new="$(_gwr_read_key "$(_gateway_key_file)")" \
    || die "cel gateway rotate-key --finish: api-key is not a private (0600) file of yours - nothing changed"
  fp="$(_gwr_fp_of "$old")"
  rows="$(_gwr_holders "$fp")"
  count="$(_gwr_count "$rows")"
  if [ "$count" -gt 0 ]; then
    if [ "$force" != 1 ]; then
      c_err "cel gateway rotate-key --finish: $count launch(es) still hold the old key - dropping it now would 401 them:"
      _gwr_print_holders "$rows"
      printf '  Restart them first (cel gateway rotate-key --status prints the plan), or --finish --force to cut them off. Nothing changed.\n'
      return 1
    fi
    c_warn "--force: $count launch(es) still on the old key are cut off (HTTP 401) until they are restarted:"
    _gwr_print_holders "$rows"
  fi
  gateway_ready \
    || die "cel gateway rotate-key --finish: the gateway is not answering on $(gateway_url) - nothing changed"
  # The config first, proven; the files last. Killed anywhere before the
  # last delete, api-key.previous is still there: --status reports the
  # rotation staged (and the config short of the old key), and --finish
  # runs again.
  _gwr_config_write_current_only
  _gwr_step config-rewritten
  if ! codes="$(_gwr_await_both "$old" 401 "$new" 200)"; then
    read -r code_old code_new <<< "$codes"
    _gateway_config_write
    old="" new=""
    die "cel gateway rotate-key --finish: the gateway did not drop the old key within $(_gwr_wait)s (old: HTTP ${code_old:-000}, new: HTTP ${code_new:-000}) - config.yaml accepts both keys again; the rotation is still staged"
  fi
  read -r code_old code_new <<< "$codes"
  old="" new=""
  if [ -e "$(_gateway_key_next_file)" ]; then
    rm -f -- "$(_gateway_key_next_file)"
    _gwr_step next-removed
  fi
  rm -f -- "$(_gateway_key_previous_file)"
  _gwr_step previous-removed
  c_ok "rotation finished: the old key gets HTTP $code_old, the new key HTTP $code_new; api-key.previous deleted"
}

# Back to the old key alone, from a staged rotation or an interrupted stage.
# api-key gets the old key back first (a kill there reads as an interrupted
# stage: api-key.previous == api-key), then the config lists it alone and is
# proven, and the rotation files go last - --abort again finishes any of it.
_gwr_abort() { # <force 0|1>
  local force="$1" state old new="" rows count codes code_old code_new
  state="$(_gwr_state)"
  [ "$state" != none ] || die "cel gateway rotate-key --abort: no rotation to abort"
  if [ "$state" = staged ]; then
    old="$(_gwr_read_key "$(_gateway_key_previous_file)")" \
      || die "cel gateway rotate-key --abort: api-key.previous is not a private (0600) file of yours - nothing changed"
    new="$(_gwr_read_key "$(_gateway_key_file)")" \
      || die "cel gateway rotate-key --abort: api-key is not a private (0600) file of yours - nothing changed"
    # Abort cuts off whatever started since --stage, the mirror of --finish.
    rows="$(_gwr_holders "$(_gwr_fp_of "$new")")"
    count="$(_gwr_count "$rows")"
    if [ "$count" -gt 0 ]; then
      if [ "$force" != 1 ]; then
        c_err "cel gateway rotate-key --abort: $count launch(es) started since --stage hold the new key - aborting would 401 them:"
        _gwr_print_holders "$rows"
        printf '  --abort --force restores the old key anyway; restart those afterwards and they get the old key back. Nothing changed.\n'
        return 1
      fi
      c_warn "--force: $count launch(es) on the new key are cut off (HTTP 401) until they are restarted:"
      _gwr_print_holders "$rows"
    fi
    printf '%s' "$old" | _gwr_write_key "$(_gateway_key_file)" \
      || die "cel gateway rotate-key --abort: could not write api-key - nothing changed"
    _gwr_step api-key-restored
  else
    old="$(_gwr_read_key "$(_gateway_key_file)")" \
      || die "cel gateway rotate-key --abort: api-key is not a private (0600) file of yours - nothing changed"
    new="$(_gwr_read_key "$(_gateway_key_next_file)")" || new=""
  fi
  _gwr_config_write_current_only
  _gwr_step config-rewritten
  if [ -n "$new" ]; then
    codes="$(_gwr_await_both "$old" 200 "$new" 401)" || {
      read -r code_old code_new <<< "$codes"
      old="" new=""
      die "cel gateway rotate-key --abort: api-key holds the old key and config.yaml lists it alone, but the gateway answers old HTTP ${code_old:-000}, new HTTP ${code_new:-000} after $(_gwr_wait)s - cel gateway status, then cel gateway rotate-key --abort again"
    }
    read -r code_old code_new <<< "$codes"
  else
    code_old="$(_gwr_await "$old" 200)" \
      || die "cel gateway rotate-key --abort: config.yaml lists the current key alone, but it gets HTTP $code_old within $(_gwr_wait)s - cel gateway status, then cel gateway rotate-key --abort again"
  fi
  old="" new=""
  rm -f -- "$(_gateway_key_next_file)"
  _gwr_step next-removed
  rm -f -- "$(_gateway_key_previous_file)"
  _gwr_step previous-removed
  if [ "$state" = staged ]; then
    c_ok "rotation aborted: the old key is the only key again (HTTP $code_old; the new one HTTP $code_new)"
  else
    c_ok "the interrupted stage is cleared: the current key is the only key (HTTP $code_old)"
  fi
}

# OWNER ONLY: a process carrying an agent launch's marks, or with one above
# it, is refused - shedding the variables (env -u, env -i) does not shed the
# launch it runs under. The ancestors are read from _gwr_proc, with shell
# builtins only. lib/identity.sh's cel_launch_identity is not this check: it
# proves an agent acts AS its launch and passes a process with no identity,
# where this refuses every agent, whatever identity it claims or sheds.
_GWR_AGENT_MARKS='CEL_ROLE CEL_ROLE_FILE CEL_INBOX_ME CEL_SESSION_ID CEL_TEAM_MEMBER OMP_GATEWAY_TOKEN CLAUDECODE OMPCODE'
_gwr_owner_only() { # <verb>
  local v proc pid="$PPID" n=0 item st
  local refuse="cel gateway rotate-key $1: rotating the gateway key is the owner's action, from the owner's own shell"
  for v in $_GWR_AGENT_MARKS; do
    [ -z "${!v+set}" ] || die "$refuse - this process carries $v, an agent launch's mark; nothing changed (cel gateway rotate-key --status is open to agents)"
  done
  proc="$(_gwr_proc)"
  while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ "$n" -lt 64 ]; do
    v=""
    { while IFS= read -r -d '' item; do
        case " $_GWR_AGENT_MARKS " in *" ${item%%=*} "*) v="${item%%=*}"; break ;; esac
      done; } 2>/dev/null < "$proc/$pid/environ" || true
    [ -z "$v" ] || die "$refuse - it runs under an agent launch (pid $pid carries $v); nothing changed (cel gateway rotate-key --status is open to agents)"
    st=""
    { IFS= read -r st; } 2>/dev/null < "$proc/$pid/stat" || break
    st="${st##*) }"; st="${st#* }"; pid="${st%% *}"
    n=$((n + 1))
  done
  return 0
}

_gwr_usage() {
  cat <<'EOS'
cel gateway rotate-key - replace the gateway client key with no downtime

  cel gateway rotate-key [--status]  which keys the config accepts, every live
                                     process still on the old key (by name and
                                     pid) and the restart plan; agents may read
  cel gateway rotate-key --stage     owner: mint a new key, accept old + new,
                                     prove both answer, hand new launches the new key
  cel gateway rotate-key --finish [--force]
                                     owner: refused while anything holds the old
                                     key (--force cuts it off); drop it, prove
                                     old 401 / new 200
  cel gateway rotate-key --abort [--force]
                                     owner, before --finish: the old key becomes
                                     the only key again (--force: even with
                                     launches already on the new key)
EOS
}

gateway_rotate_key() { # [--status | --stage | --finish [--force] | --abort [--force]]
  local verb="" force=0 a lock fd rc=0
  for a in "$@"; do
    case "$a" in
      --status|--stage|--finish|--abort)
        [ -z "$verb" ] || die "cel gateway rotate-key: one of --status, --stage, --finish or --abort"
        verb="${a#--}" ;;
      --force) force=1 ;;
      -h|--help|help) _gwr_usage; return 0 ;;
      *) die "cel gateway rotate-key: unknown argument '$a' (cel gateway rotate-key --help)" ;;
    esac
  done
  [ -n "$verb" ] || verb=status
  if [ "$force" = 1 ] && [ "$verb" != finish ] && [ "$verb" != abort ]; then
    die "cel gateway rotate-key: --force goes with --finish or --abort"
  fi
  if [ "$verb" = status ]; then _gwr_status; return 0; fi
  _gwr_owner_only "--$verb"
  gateway_installed || die "cel gateway rotate-key --$verb: no gateway on this box - cel gateway install"
  have curl || die "cel gateway rotate-key --$verb: curl is not on PATH"
  mkdir -p "$(gateway_state_dir)"
  lock="$(gateway_state_dir)/rotate-key.lock"
  exec {fd}>"$lock"
  flock -n "$fd" || die "cel gateway rotate-key --$verb: another rotate-key is running ($lock)"
  case "$verb" in
    stage)  _gwr_stage || rc=$? ;;
    finish) _gwr_finish "$force" || rc=$? ;;
    abort)  _gwr_abort "$force" || rc=$? ;;
  esac
  exec {fd}>&-
  return "$rc"
}
