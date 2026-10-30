# shellcheck shell=bash
# Read-only observations, not launch-policy or guard-enforcement verdicts.
[ -n "${_CEL_RUN_EVIDENCE:-}" ] && return 0
_CEL_RUN_EVIDENCE=1

_run_evidence_start() { # proc root, PID -> kernel start identity
  local s rest
  IFS= read -r s < "$1/$2/stat" 2>/dev/null || return 1
  rest="${s##*) }"
  local -a fields=()
  read -r -a fields <<< "$rest"
  [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${fields[19]}"
}

_run_evidence_rex_owned() { # runtime name pane cwd pid start
  local f mode
  [[ "$2" != */* && "$2" != . && "$2" != .. && -n "$2" ]] || return 1
  declare -F _rex_file >/dev/null && declare -F _rex_receipt_valid >/dev/null \
    && declare -F _rex_live >/dev/null || return 1
  f="$(_rex_file "$2")"
  [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || return 1
  mode="$(stat -c '%a' -- "$f" 2>/dev/null)" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022) == 0 )) || return 1
  _rex_receipt_valid "$f" && _rex_live "$f" || return 1
  jq -e --arg rt "$1" --arg name "$2" --arg pane "$3" --arg cwd "$4" \
    --argjson pid "$5" --arg start "$6" '
    .agent == $rt and .name == $name and .backend == "rex"
    and .pane_id == $pane and .cwd == $cwd and .pid == $pid and .pid_start == $start
    and (.rex_session | type == "string" and length > 0)
    and (.rex_block | type == "string" and length > 0)
    and .pane_id == ("rex/" + .rex_session + "/" + .rex_block)
  ' "$f" >/dev/null 2>&1
}

_run_evidence_watcher() { # proc root, native PID, cwd; bounded direct children only
  local root="$1" pid="$2" cwd="$3" children="" child start after i parents value
  local -a ids=() args=()
  [ -r "$root/$pid/task/$pid/children" ] || return 1
  # The runtime hook spawns bash directly, not a shell-wrapper descendant.
  # Never scan every process or treat a descendant's guessed --parent as proof.
  IFS= read -r -n 8192 children < "$root/$pid/task/$pid/children" || true
  [ "${#children}" -lt 8192 ] || return 1
  read -r -a ids <<< "$children"
  [ "${#ids[@]}" -le 128 ] || return 1
  for child in "${ids[@]}"; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    _run_ppid "$child"; [ "$_RUN_PPID" = "$pid" ] || continue
    [ "$root/$child/cwd" -ef "$cwd" ] || continue
    start="$(_run_evidence_start "$root" "$child")" || continue
    args=()
    mapfile -d '' -t args < "$root/$child/cmdline" 2>/dev/null || continue
    [ "${#args[@]}" -ge 6 ] || continue
    [ "${args[0]##*/}" = bash ] && [ "${args[1]}" = "$CEL_ROOT/bin/cel" ] \
      && [ "${args[2]}" = inbox ] && [ "${args[3]}" = watch ] || continue
    parents=0; value=""
    for ((i=4; i<${#args[@]}; i++)); do
      case "${args[$i]}" in
        --parent) parents=$((parents+1)); i=$((i+1)); value="${args[$i]:-}" ;;
        --workspace|--for) i=$((i+1)); [ -n "${args[$i]:-}" ] || break ;;
        --all-workspaces) ;;
        *) break ;;
      esac
    done
    [ "$i" -eq "${#args[@]}" ] && [ "$parents" = 1 ] && [ "$value" = "$pid" ] || continue
    _run_ppid "$child"; [ "$_RUN_PPID" = "$pid" ] || continue
    after="$(_run_evidence_start "$root" "$child")" || continue
    [ "$start" = "$after" ] || continue
    return 0
  done
  return 1
}

run_runtime_evidence() { # runtime name pane cwd pid -> evidence states and NUL-preserving ARGV_VALUES array
  local runtime="$1" name="$2" pane="$3" cwd="$4" pid="$5" root start after i flag file bare_pi=1
  local -a argv=()
  RUN_EVIDENCE_ARGV=unknown
  RUN_EVIDENCE_INBOX=unknown
  RUN_EVIDENCE_DETAIL="native runtime evidence unavailable"
  RUN_EVIDENCE_ARGV_VALUES=()
  case "$runtime" in pi|omp|opencode|claude|codex) ;; *) return 0 ;; esac
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 0
  root="$(_run_proc_root)"
  [ "$root/$pid/cwd" -ef "$cwd" ] || { RUN_EVIDENCE_DETAIL="native cwd identity unavailable or mismatched"; return 0; }
  start="$(_run_evidence_start "$root" "$pid")" || return 0
  mapfile -d '' -t argv < "$root/$pid/cmdline" 2>/dev/null || return 0
  [ "${#argv[@]}" -gt 0 ] || return 0
  if [[ "$pane" = rex/* ]] && ! _run_evidence_rex_owned "$runtime" "$name" "$pane" "$cwd" "$pid" "$start"; then
    if [ "$runtime" = pi ] && [ "${argv[0]##*/}" = pi ]; then
      RUN_EVIDENCE_ARGV=rewritten
      for ((i=1; i<${#argv[@]}; i++)); do
        [ -z "${argv[$i]}" ] || RUN_EVIDENCE_ARGV=unknown
      done
    fi
    RUN_EVIDENCE_DETAIL="owned Rex receipt identity unavailable or mismatched"
    return 0
  fi
  RUN_EVIDENCE_ARGV=observable
  # Native title rewriting zero-fills the old argv storage; those trailing
  # NULs appear as empty mapfile entries, not real surviving launch flags.
  for ((i=1; i<${#argv[@]}; i++)); do
    [ -z "${argv[$i]}" ] || bare_pi=0
  done
  if [ "$runtime" = pi ] && [ "$bare_pi" = 1 ] && [ "${argv[0]##*/}" = pi ]; then
    RUN_EVIDENCE_ARGV=rewritten
    RUN_EVIDENCE_DETAIL="bare Pi argv is rewritten; inbox and launch flags are unknown"
    if _run_evidence_watcher "$root" "$pid" "$cwd"; then
      RUN_EVIDENCE_INBOX=ok
      RUN_EVIDENCE_DETAIL="direct native child inbox watcher observed with exact parent PID; no guard or whole-launch proof"
    fi
  elif [ "$runtime" = pi ] || [ "$runtime" = omp ]; then
    flag="$(agent_inbox_hook "$runtime" flag 2>/dev/null)" || flag=""
    file="$(agent_inbox_hook "$runtime" file 2>/dev/null)" || file=""
    if [ -n "$flag" ] && [ -n "$file" ]; then
      RUN_EVIDENCE_INBOX=stripped
      RUN_EVIDENCE_DETAIL="observable native argv is missing the inbox hook"
      for ((i=0; i<${#argv[@]}; i++)); do
        if { [ "${argv[$i]}" = "$flag" ] && [ "${argv[$((i+1))]:-}" = "$CEL_ROOT/$file" ]; } \
          || [ "${argv[$i]}" = "$flag=$CEL_ROOT/$file" ]; then
          RUN_EVIDENCE_INBOX=ok
          RUN_EVIDENCE_DETAIL="inbox hook present in observable native argv; no guard or whole-launch proof"
          break
        fi
      done
    else
      RUN_EVIDENCE_DETAIL="runtime inbox hook declaration unavailable"
    fi
  else
    RUN_EVIDENCE_DETAIL="$runtime has no Pi/OMP inbox extension requirement"
  fi
  after="$(_run_evidence_start "$root" "$pid")" || after=""
  if [ "$start" != "$after" ]; then
    RUN_EVIDENCE_ARGV=unknown; RUN_EVIDENCE_INBOX=unknown
    RUN_EVIDENCE_DETAIL="native PID identity changed during observation"
  elif [ "$RUN_EVIDENCE_ARGV" = observable ]; then
    RUN_EVIDENCE_ARGV_VALUES=("${argv[@]}")
  fi
}
