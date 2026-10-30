# shellcheck shell=bash
# Optional terminal backend. Records belong only to sessions Celestial creates;
# the Rex server's other sessions are never adopted, stopped or garbage-collected.
[ -n "${_CEL_REX:-}" ] && return 0
_CEL_REX=1

_rex_state() {
  if [ -n "${CEL_REX_STATE:-}" ]; then printf '%s' "$CEL_REX_STATE"
  elif [ -n "${CEL_TESTING:-}" ]; then printf '%s/cel-rex' "${TMPDIR:-/tmp}"
  else printf '%s/cel/rex' "${XDG_STATE_HOME:-$HOME/.local/state}"; fi
}
_rex_cli() (
  # Server autostart and its terminals must never retain launcher locks.
  [ -z "${_RUN_ADMISSION_FD:-}" ] || exec {_RUN_ADMISSION_FD}>&-
  [ -z "${_REX_LAUNCH_FD:-}" ] || exec {_REX_LAUNCH_FD}>&-
  exec "${CEL_REX_BIN:-rex}" "$@"
)
_rex_file() { printf '%s/%s.json' "$(_rex_state)" "$1"; }
_rex_pid_start() { local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1; s="${s##*) }"; set -- $s; printf '%s' "${20}"; }
_rex_receipt_valid() {
  jq -e 'type == "object" and (.name | type == "string") and (.pid | type == "number") and .pid > 1 and (.pid_start | type == "string" and length > 0)' "$1" >/dev/null 2>&1
}
_rex_live() { # record -> prove this is the same process, not a reused PID
  local pid start
  pid="$(jq -r '.pid // empty' "$1")"; start="$(jq -r '.pid_start // empty' "$1")"
  [ -n "$pid" ] && [ -n "$start" ] && [ "$(_rex_pid_start "$pid")" = "$start" ]
}

rex_agent_list() { # same roster shape as Herdr; unknown observation never means idle
  local f rows='[]' row status
  for f in "$(_rex_state)"/*.json; do
    [ -f "$f" ] || continue
    _rex_receipt_valid "$f" || return 1
    row="$(jq -c . "$f" 2>/dev/null)" || return 1
    if _rex_live "$f"; then
      jq -e 'all([.cwd,.agent,.agent_status,.rex_session,.rex_block,.workspace,.role][]; type == "string" and length > 0)
        and .backend == "rex" and .pane_id == ("rex/" + .rex_session + "/" + .rex_block)' "$f" >/dev/null 2>&1 || return 1
      rows="$(jq --argjson r "$row" '. + [$r]' <<<"$rows")"
    fi
  done
  jq -cn --argjson a "$rows" '{result:{agents:$a}}'
}

# All launch/status/admission consumers share this observation; Herdr remains
# unchanged when there are no managed Rex sessions.
cel_agent_list() {
  local h='{"result":{"agents":[]}}' r
  if have herdr; then
    h="$(herdr agent list 2>/dev/null)" || return 1
  fi
  jq -e '.result.agents | type == "array"' >/dev/null 2>&1 <<<"$h" || return 1
  local -a files=("$(_rex_state)"/*.json)
  if [ ! -f "${files[0]:-}" ]; then printf '%s\n' "$h"; return 0; fi
  r="$(rex_agent_list)" || return 1
  jq -cn --argjson h "$h" --argjson r "$r" '$h | .result.agents += $r.result.agents'
}

_rex_preflight() { # name runtime; no mutation before provisioning a worker checkout
  local file; file="$(_rex_file "$1")"
  command -v "${CEL_REX_BIN:-rex}" >/dev/null || die 'cel run: rex is not on PATH'
  command -v "$(agent_get "$2" bin)" >/dev/null || die "cel run: executable for $2 is unavailable"
  if [ -f "$file" ]; then _rex_receipt_valid "$file" || die "cel run: unreadable Rex receipt for $1; refusing to replace it"; fi
  if [ -f "$file" ] && _rex_live "$file"; then die "cel run: $1 already runs in Rex"; fi
  [ ! -e "$file.pending" ] && [ ! -e "$file.pid" ] || die "cel run: previous Rex launch for $1 is unresolved; inspect rex ls before retrying ($file.pending)"
}

rex_native_session_valid() { # runtime native id
  case "$1" in
    claude) [[ "$2" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ;;
    opencode) [[ "$2" =~ ^ses_[A-Za-z0-9]+$ ]] ;;
    *) return 1 ;;
  esac
}

_rex_launch() { # name runtime cwd label envprefix args...
  local name="$1" rt="$2" cwd="$3" label="$4" prefix="$5"; shift 5
  # Capture only an explicit native resume argument, never cast an archived
  # conversation from another runtime into native identity.
  local native="" a previous="" native_flag=""
  case "$rt" in claude) native_flag=--resume ;; opencode) native_flag=--session ;; esac
  if [ -n "$native_flag" ]; then
    for a in "$@"; do
      if [ "$previous" = "$native_flag" ]; then native="$a"; fi
      case "$a" in "$native_flag"=*) native="${a#*=}" ;; esac
      previous="$a"
    done
    [ -z "$native" ] || rex_native_session_valid "$rt" "$native" \
      || die "cel run: $rt native resume must name its exact native session identity"
  fi
  local d file script resp session block pid start bin
  d="$(_rex_state)"; mkdir -p "$d"; chmod 700 "$d"
  file="$(_rex_file "$name")"
  local lock
  exec {lock}>"$file.lock"
  flock -n "$lock" || die "cel run: another Rex launch owns $name"
  local _REX_LAUNCH_FD="$lock"
  _rex_preflight "$name" "$rt"
  rm -f "$file"
  bin="$(command -v "$(agent_get "$rt" bin)")"
  script="$(mktemp "$d/.launch.XXXXXX")"; chmod 700 "$script"
  # No secret values in the roster or Rex command arguments. The private
  # one-shot script deletes itself once the terminal has opened it.
  {
    printf '#!/bin/bash\nset -e\nrm -f -- %q\n' "$script"
    printf 'printf "%%s" "$$" > %q\n' "$file.pid"
    # Wait for the parent to publish the identity before runtime hooks fire.
    printf 'for ((i=0;i<100;i++)); do [ -f %q ] && break; sleep 0.1; done\n' "$file"
    printf '[ -f %q ] || exit 1\n' "$file"
    printf 'export PATH=%q CEL_ROOT=%q\n' "$PATH" "$CEL_ROOT"
    # Load this workspace's declared env and env.local, not the Rex server's
    # possibly stale login environment. Pin launch identity again afterwards.
    if [ -f "${wsdir:-$cwd}/workspace.yaml" ]; then ws_env_exports "${wsdir:-$cwd}"; fi
    printf 'cd %q\nexport CEL_ROOT=%q\n' "$cwd" "$CEL_ROOT"
    printf 'export CEL_REX_STATE=%q\n' "$d"
    printf 'export CEL_SESSION_BACKEND=rex CEL_AGENT_NAME=%q CEL_REX_RECORD=%q\n' "$name" "$file"
    # The shared prefix may have a GitHub account guard before `env`.
    # Exec the runtime only AFTER that guard, retaining its exit behavior.
    printf '%s %q ' "${prefix/env CEL_ROLE=/exec env CEL_ROLE=}" "$bin"
    printf '%q ' "$@"; printf '\n'
  } > "$script"
  printf '%s\n' "$script" > "$file.pending"; chmod 600 "$file.pending"
  if ! resp="$(_rex_cli new "$name" --cwd "$cwd" --window "$label" --shell=none --keep-open --json -- /bin/bash "$script")"; then
    # A timeout can have created a session: keep the script and pid receipt,
    # and refuse a blind retry; do not destroy an unobserved session.
    die "cel run: Rex launch was not acknowledged; inspect rex ls before retrying ($name)"
  fi
  session="$(jq -er '.session_id' <<<"$resp")" || die 'Rex returned no session identity'
  block="$(jq -er '.initial_windows[0].block_ids[0]' <<<"$resp")" || die 'Rex returned no terminal identity'
  local i
  for ((i=0;i<50;i++)); do [ -s "$file.pid" ] && break; sleep 0.1; done
  pid="$(cat "$file.pid" 2>/dev/null)"; [[ "$pid" =~ ^[0-9]+$ ]] || die "Rex session $session opened but has not started its runtime"
  start="$(_rex_pid_start "$pid")" || die "Rex session $session exited during startup; inspect rex capture -s $session -b $block"
  local tmp; tmp="$(mktemp "$d/.record.XXXXXX")"; chmod 600 "$tmp"
  jq -n --arg name "$name" --arg rt "$rt" --arg cwd "$cwd" --arg session "$session" --arg block "$block" \
    --argjson pid "$pid" --arg start "$start" --arg role "${env_role:-${role:-core}}" --arg workspace "${wsdir:-$cwd}" \
    --arg repo "${repo:-}" --arg pr "${pr:-}" --arg native "$native" \
    '{name:$name,agent:$rt,cwd:$cwd,role:$role,workspace:$workspace,repo:$repo,pr:$pr,pane_id:("rex/"+$session+"/"+$block),backend:"rex",rex_session:$session,rex_block:$block,pid:$pid,pid_start:$start,agent_status:"working"}
      | if $native != "" then .agent_session={value:$native} else . end' > "$tmp"
  mv "$tmp" "$file"; rm -f "$file.pid" "$file.pending"
  exec {lock}>&-
  _REX_PANE="rex/$session/$block"
  printf 'Rex session: %s\nTerminal: %s\n' "$session" "$block"
}

rex_agent_stop() { # pane id, stop only an exact owned terminal/session
  local pane="$1" f session block
  for f in "$(_rex_state)"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r .pane_id "$f")" = "$pane" ] || continue
    # A retained terminal may have been repurposed after its runtime exited.
    # Without the original PID identity, clear bookkeeping only.
    if ! _rex_live "$f"; then rm -f "$f"; return 0; fi
    session="$(jq -r .rex_session "$f")"; block="$(jq -r .rex_block "$f")"
    _rex_cli block close -s "$session" "$block" || return 1
    # We created one terminal per session; never kill a session the owner
    # subsequently added tabs to; leave the empty session shell intact too.
    local i
    for ((i=0;i<50;i++)); do _rex_live "$f" || { rm -f "$f"; return 0; }; sleep 0.1; done
    return 1
  done
  return 1
}

# Prove the reporting process descends from this exact launch. An environment
# label or a caller-supplied PID alone does not establish runtime provenance.
rex_reporter_pid() { # -> managed runtime PID, only for its own descendants
  local f="${CEL_REX_RECORD:-}" target p="${BASHPID:-$$}" depth=0 k v
  [ -n "$f" ] && [ -f "$f" ] && _rex_receipt_valid "$f" && _rex_live "$f" || return 1
  target="$(jq -r .pid "$f")"
  while [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] && [ "$depth" -lt 64 ]; do
    if [ "$p" = "$target" ]; then printf '%s' "$target"; return 0; fi
    v=""
    while read -r k v; do [ "$k" != PPid: ] || break; done < "/proc/$p/status" 2>/dev/null
    p="$v"; depth=$((depth+1))
  done
  return 1
}

# Runtime hooks report native session identity and turn state. Validate the
# reporting PID against the launch receipt; no caller can mark another live
# session idle by guessing its name.
rex_session_note() { # pid state [native session file/id]
  local pid="$1" state="$2" native="${3:-}" f="${CEL_REX_RECORD:-}" tmp reporter lock
  [ -n "$f" ] && [ -f "$f" ] || return 0
  reporter="$(rex_reporter_pid)" || return 1
  [ "$reporter" = "$pid" ] || return 1
  exec {lock}>"$f.note.lock" || return 1
  flock "$lock" || { exec {lock}>&-; return 1; }
  [ "$(jq -r .pid "$f")" = "$pid" ] && _rex_live "$f" || { exec {lock}>&-; return 1; }
  case "$state" in idle|working|blocked) ;; *) exec {lock}>&-; return 1 ;; esac
  tmp="$(mktemp "$(_rex_state)/.note.XXXXXX")" || { exec {lock}>&-; return 1; }
  chmod 600 "$tmp"
  local rc=0
  jq --arg s "$state" --arg n "$native" '.agent_status=$s | if $n != "" then .agent_session={value:$n} else . end' "$f" > "$tmp" && mv "$tmp" "$f" || rc=$?
  rm -f "$tmp"
  exec {lock}>&-
  return "$rc"
}

cmd_sessions() {
  case "${1:-}" in
    note)
      [ $# = 4 ] || die 'sessions note: pid state native-session'
      . "$CEL_ROOT/lib/run.sh"
      rex_session_note "$2" "$3" "$4" || return $?
      if [ -n "$4" ] && [ -n "${CEL_REX_RECORD:-}" ] && [ -f "$CEL_REX_RECORD" ]; then
        case "$(jq -r .role "$CEL_REX_RECORD")" in
          core|root|orchestrator|solo) _run_sessions_record "$(jq -r .cwd "$CEL_REX_RECORD")" "$4" ;;
        esac
      fi ;;
    --json) cel_agent_list ;;
    '') cel_agent_list | jq -r '.result.agents[] | [ .name, (.backend // "herdr"), .agent, (.agent_status // "unknown"), .pane_id ] | @tsv' ;;
    *) die 'usage: cel sessions [--json]' ;;
  esac
}

rex_current_agent() { # exact managed Rex ancestor; never trust a backend env label
  local f p k v target depth
  for f in "$(_rex_state)"/*.json; do
    [ ! -f "$f" ] || _rex_receipt_valid "$f" || return 2
    [ -f "$f" ] && _rex_live "$f" || continue
    target="$(jq -r .pid "$f")"; p="$$"; depth=0
    while [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] && [ "$depth" -lt 64 ]; do
      if [ "$p" = "$target" ]; then cat "$f"; return 0; fi
      v=""
      while read -r k v; do [ "$k" != PPid: ] || break; done < "/proc/$p/status" 2>/dev/null
      p="$v"; depth=$((depth+1))
    done
  done
  return 1
}

cel_assert_reviewer_identity() { # by workspace repo pr
  local identity rc=0
  identity="$(rex_current_agent)" || rc=$?
  if [ "$rc" = 0 ]; then
    jq -e --arg by "$1" --arg ws "$2" --arg repo "${3:-}" --arg pr "${4:-}" \
      '.role == "reviewer" and .name == $by and .workspace == $ws and .repo == $repo and (.pr | tostring) == $pr' <<<"$identity" >/dev/null \
      || die 'only this PR reviewer may record its Rex verdict'
    return 0
  fi
  [ "$rc" != 2 ] || die 'Rex session identity is unreadable; no verdict recorded'
  [ "${CEL_SESSION_BACKEND:-}" != rex ] || die 'cannot prove the calling Rex reviewer identity; no verdict recorded'
  return 0
}
