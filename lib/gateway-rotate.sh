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
      repo="${name%-pr-*-review}"; pr="${name##*-pr-}"; pr="${pr%-review}"
      printf '2\t# finishes its round on its own - cel gc closes it once its verdict is recorded; a later round on %s#%s gets a fresh reviewer (cel run reviewer --repo %s --pr %s%s) after it has closed' \
        "$repo" "$pr" "$repo" "$pr" "$wsopt" ;;
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

_gwr_state() { # -> none | staged | interrupted
  if [ -e "$(_gateway_key_previous_file)" ]; then printf staged
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
      "$prev") label=old ;;
      "$cur") if [ "$1" = staged ]; then label=new; else label=current; fi ;;
      "$next") label=next ;;
      *) label="UNKNOWN (in no key file)" ;;
    esac
    n=$((n + 1))
    out="${out:+$out, }$label (sha256 ${fp:0:12})"
  done < <(_gwr_config_keys)
  printf '  config     accepts %d key(s): %s\n' "$n" "${out:-none}"
}

_gwr_status() {
  if ! gateway_installed; then c_warn "no gateway on this box - cel gateway install"; return 0; fi
  local state old new rows count procs
  state="$(_gwr_state)"
  case "$state" in
    none)        printf '  rotation   none - the current key is the only key\n' ;;
    interrupted) printf '  rotation   an interrupted --stage left api-key.next behind - cel gateway rotate-key --abort clears it\n' ;;
    staged)      printf '  rotation   staged - the gateway accepts the old and the new key; new launches get the new key\n' ;;
  esac
  _gwr_print_accepted "$state"
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
  local cur new code_old code_new
  case "$(_gwr_state)" in
    staged) die "cel gateway rotate-key --stage: a rotation is already staged - cel gateway rotate-key --status, then --finish or --abort; nothing changed" ;;
    interrupted) die "cel gateway rotate-key --stage: an interrupted --stage left api-key.next - cel gateway rotate-key --abort clears it; nothing changed" ;;
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
  _gateway_config_write
  if ! code_new="$(_gwr_await "$new" 200)" || ! code_old="$(_gwr_await "$cur" 200)"; then
    rm -f -- "$(_gateway_key_next_file)"
    _gateway_config_write
    die "cel gateway rotate-key --stage: the gateway did not accept both keys within $(_gwr_wait)s (old: HTTP ${code_old:-000}, new: HTTP ${code_new:-000}) - api-key.next removed and config.yaml back to the current key alone; nothing else changed"
  fi
  c_ok "the gateway accepts both keys: old (sha256 $(_gwr_fp_of "$cur" | cut -c1-12)) HTTP $code_old, new (sha256 $(_gwr_fp_of "$new" | cut -c1-12)) HTTP $code_new"
  # The switch: the old key is kept beside the new one first, then the new
  # key becomes the file every launch reads - one rename, so a launch reads
  # a whole key, old or new, and the config accepts both throughout.
  printf '%s' "$cur" | _gwr_write_key "$(_gateway_key_previous_file)" \
    || die "cel gateway rotate-key --stage: could not write api-key.previous - both keys stay accepted; cel gateway rotate-key --abort undoes the stage"
  mv -f -- "$(_gateway_key_next_file)" "$(_gateway_key_file)" \
    || die "cel gateway rotate-key --stage: could not move api-key.next over api-key - both keys stay accepted and launches still get the old key; cel gateway rotate-key --abort undoes the stage"
  cur="" new=""
  c_ok "api-key now holds the new key: every launch from here gets it; the old key stays accepted (api-key.previous) until --finish"
  printf '\n'
  _gwr_status
}

_gwr_finish() { # <force 0|1>
  local force="$1" old new fp rows count code_old code_new
  case "$(_gwr_state)" in
    none) die "cel gateway rotate-key --finish: no rotation is staged - cel gateway rotate-key --stage starts one" ;;
    interrupted) die "cel gateway rotate-key --finish: an interrupted --stage left api-key.next - cel gateway rotate-key --abort clears it" ;;
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
  rm -f -- "$(_gateway_key_previous_file)"
  _gateway_config_write
  if ! code_old="$(_gwr_await "$old" 401)" || ! code_new="$(_gwr_await "$new" 200)"; then
    printf '%s' "$old" | _gwr_write_key "$(_gateway_key_previous_file)" || true
    _gateway_config_write
    old="" new=""
    die "cel gateway rotate-key --finish: the gateway did not drop the old key within $(_gwr_wait)s (old: HTTP ${code_old:-000}, new: HTTP ${code_new:-000}) - api-key.previous restored and both keys accepted again; the rotation is still staged"
  fi
  old="" new=""
  c_ok "rotation finished: the old key gets HTTP $code_old, the new key HTTP $code_new; api-key.previous deleted"
}

_gwr_abort() { # <force 0|1>
  local force="$1" old new rows count code_old code_new
  case "$(_gwr_state)" in
    none) die "cel gateway rotate-key --abort: no rotation to abort" ;;
    interrupted)
      old="$(_gwr_read_key "$(_gateway_key_file)")" \
        || die "cel gateway rotate-key --abort: api-key is not a private (0600) file of yours - nothing changed"
      rm -f -- "$(_gateway_key_next_file)"
      _gateway_config_write
      code_old="$(_gwr_await "$old" 200)" \
        || die "cel gateway rotate-key --abort: api-key.next removed, but the current key gets HTTP $code_old within $(_gwr_wait)s - cel gateway status"
      old=""
      c_ok "the interrupted stage is cleared: the current key is the only key (HTTP $code_old)"
      return 0 ;;
  esac
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
  rm -f -- "$(_gateway_key_next_file)"
  printf '%s' "$old" | _gwr_write_key "$(_gateway_key_file)" \
    || die "cel gateway rotate-key --abort: could not write api-key - nothing changed"
  rm -f -- "$(_gateway_key_previous_file)"
  _gateway_config_write
  if ! code_old="$(_gwr_await "$old" 200)" || ! code_new="$(_gwr_await "$new" 401)"; then
    old="" new=""
    die "cel gateway rotate-key --abort: api-key is the old key again and config.yaml lists it alone, but the gateway answers old HTTP ${code_old:-000}, new HTTP ${code_new:-000} after $(_gwr_wait)s - cel gateway status"
  fi
  old="" new=""
  c_ok "rotation aborted: the old key is the only key again (HTTP $code_old; the new one HTTP $code_new)"
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
