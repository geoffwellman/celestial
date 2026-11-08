# shellcheck shell=bash
# Optional terminal backend. Records belong only to sessions Celestial creates;
# the Rex server's other sessions are never adopted, stopped or garbage-collected.
[ -n "${_CEL_REX:-}" ] && return 0
_CEL_REX=1
# shellcheck source=lib/opencode.sh
. "${BASH_SOURCE[0]%/*}/opencode.sh"

_rex_state() {
  if [ -n "${CEL_REX_STATE:-}" ]; then printf '%s' "$CEL_REX_STATE"
  elif [ -n "${CEL_TESTING:-}" ]; then printf '%s/cel-rex' "${TMPDIR:-/tmp}"
  else printf '%s/cel/rex' "${XDG_STATE_HOME:-$HOME/.local/state}"; fi
}
# No child - a Rex server, a terminal, apt, a relaunched agent - may inherit a
# launcher, admission or server-generation lock lease.
_rex_close_leases() {
  [ -z "${_RUN_ADMISSION_FD:-}" ] || exec {_RUN_ADMISSION_FD}>&-
  [ -z "${_REX_LAUNCH_FD:-}" ] || exec {_REX_LAUNCH_FD}>&-
  [ -z "${_REX_GEN_FD:-}" ] || exec {_REX_GEN_FD}>&-
}
_rex_cli() (
  _rex_close_leases
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

# WHERE A MANAGED AGENT'S TERMINAL LIVES. A product agent (and core, root, a
# lane) owns the session it opened: rex_scope "session". A reviewer or team
# member opens a WINDOW in its product agent's session instead - rex_scope
# "window", with rex_window and rex_host (that product agent) - so a product's
# whole team is one Rex session group. Either way the agent's own terminal is
# rex_block.
# A MISSING rex_scope IS "session", deliberately: every receipt written before
# scopes existed - each live product agent's and reviewer's - has none, and
# each of them did open a session of its own. Refusing them would hide every
# live agent from the roster. An unknown non-empty scope is still refused.
_REX_SCOPE_JQ='((.rex_scope // "session") as $s
  | if $s == "window" then (.rex_window | type == "string" and length > 0) and (.rex_host | type == "string" and length > 0)
    else $s == "session" end)'

rex_agent_list() { # same roster shape as Herdr; unknown observation never means idle
  local f rows='[]' row status
  for f in "$(_rex_state)"/*.json; do
    [ -f "$f" ] || continue
    _rex_receipt_valid "$f" || return 1
    row="$(jq -c . "$f" 2>/dev/null)" || return 1
    if _rex_live "$f"; then
      jq -e "all([.cwd,.agent,.agent_status,.rex_session,.rex_block,.workspace,.role][]; type == \"string\" and length > 0)
        and .backend == \"rex\" and .pane_id == (\"rex/\" + .rex_session + \"/\" + .rex_block) and $_REX_SCOPE_JQ" "$f" >/dev/null 2>&1 || return 1
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

_rex_preflight() { # name runtime; checked before anything is created
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

# A SUBAGENT'S TRANSCRIPT IS NEVER THE AGENT'S SESSION. omp runs task
# subagents inside the agent's own process - same PID, same hooks - and keeps
# each one's transcript in the parent session's own directory:
#   <sessions>/<stem>.jsonl           the agent's session
#   <sessions>/<stem>/<Task>.jsonl    a subagent it ran
# Recording one would make a restart resume the subagent. Claude's subagents
# never get here (its hook drops payloads carrying an agent_id); pi has no
# in-process subagents, and a separate process fails the reporter-PID check.
native_session_is_subagent() { # native session -> 0 for a subagent transcript
  case "$1" in /*/*.jsonl) [ -f "${1%/*}.jsonl" ] ;; *) return 1 ;; esac
}

# THE HOST SESSION A REVIEWER OR TEAM MEMBER JOINS: the session its product
# agent opened, and only when that is proven the same way any managed agent
# is - its own receipt (name, workspace, a product-agent role, a session of its
# own), its exact runtime generation live (PID + start time), and Rex itself
# reporting that runtime as the child of the receipt's terminal in that
# session. Anything less prints nothing, and the caller opens a session of its
# own as before: a window is never put into a session nobody can vouch for.
_rex_host_session() { # <host-agent> <wsdir> -> its session id
  local host="$1" ws="$2" f s b pid info
  [ -n "$host" ] && [ -n "$ws" ] || return 1
  f="$(_rex_file "$host")"
  [ -f "$f" ] && [ ! -L "$f" ] && _rex_receipt_valid "$f" && _rex_live "$f" || return 1
  jq -e --arg n "$host" --arg w "$ws" ".name == \$n and .backend == \"rex\" and .workspace == \$w
    and (.role == \"solo\" or .role == \"orchestrator\")
    and (.rex_session | type == \"string\" and length > 0) and (.rex_block | type == \"string\" and length > 0)
    and .pane_id == (\"rex/\" + .rex_session + \"/\" + .rex_block)
    and $_REX_SCOPE_JQ and (.rex_scope // \"session\") == \"session\"" "$f" >/dev/null 2>&1 || return 1
  IFS=$'\t' read -r s b pid < <(jq -r '[.rex_session, .rex_block, (.pid | tostring)] | @tsv' "$f")
  info="$(_rex_cli --autostart=false block call process '{}' -s "$s" -b "$b" 2>/dev/null)" || return 1
  jq -e --argjson p "$pid" '.child.pid == $p' <<<"$info" >/dev/null 2>&1 || return 1
  # Still that same generation after Rex answered.
  _rex_live "$f" || return 1
  printf '%s' "$s"
}

# THE NATIVE SESSION A LAUNCH NAMES, proven before anything is created: an
# explicit native resume argument only, never an archived conversation from
# another runtime cast into native identity. Sets _REX_NATIVE.
_rex_launch_native() { # runtime cwd args...
  local rt="$1" cwd="$2"; shift 2
  local a previous="" native_flag="" native_requested=0
  _REX_NATIVE=""
  case "$rt" in claude) native_flag=--resume ;; opencode) native_flag=--session ;; esac
  if [ -n "$native_flag" ]; then
    for a in "$@"; do
      if [ "$previous" = "$native_flag" ]; then _REX_NATIVE="$a"; fi
      case "$a" in "$native_flag") native_requested=1 ;; "$native_flag"=*) _REX_NATIVE="${a#*=}"; native_requested=1 ;; esac
      previous="$a"
    done
    [ -z "$_REX_NATIVE" ] || rex_native_session_valid "$rt" "$_REX_NATIVE" \
      || die "cel run: $rt native resume must name its exact native session identity"
  fi
  if [ "$rt" = opencode ] && [ "$native_requested" = 1 ]; then
    # A v2 --session may CREATE a missing ID. Direct callers must carry the
    # same prepared scope as cmd_run; never infer it from an old receipt.
    [ -n "${CEL_OPENCODE_AGENT:-}" ] && [ -n "${AGENT_ROLE_FILE:-}" ] && [ -n "${CEL_OPENCODE_CONFIG_FILE:-}" ] \
      || die 'cel run: OpenCode native resume requires the prepared scoped agent/config'
    opencode_validate_config "${CEL_OPENCODE_AGENT#cel-}" "$AGENT_ROLE_FILE" "$CEL_OPENCODE_CONFIG_FILE" \
      || die 'cel run: OpenCode native resume scope is not canonical'
    opencode_validate_session "$_REX_NATIVE" "$cwd" "$CEL_OPENCODE_AGENT" "${wsdir:-}" \
      || die 'cel run: refusing to publish an absent, mismatched, or unmigrated OpenCode native v2 root'
  fi
}

# The private launch script's environment: the workspace's declared env and
# env.local, not the Rex server's possibly stale login environment, then the
# launch identity pinned again.
_rex_launch_env() { # name cwd
  local name="$1" cwd="$2"
  printf 'export PATH=%q CEL_ROOT=%q\n' "$PATH" "$CEL_ROOT"
  if [ -f "${wsdir:-$cwd}/workspace.yaml" ]; then ws_env_exports "${wsdir:-$cwd}"; fi
  printf 'cd %q\nexport CEL_ROOT=%q\n' "$cwd" "$CEL_ROOT"
  printf 'export CEL_REX_STATE=%q\n' "$(_rex_state)"
  printf 'export CEL_SESSION_BACKEND=rex CEL_AGENT_NAME=%q CEL_REX_RECORD=%q\n' "$name" "$(_rex_file "$name")"
}

# THE LINE THE PRIVATE LAUNCH SCRIPT RUNS: the shared prefix, its runtime
# exec'd only AFTER any GitHub account guard ahead of `env` (keeping that
# guard's exit behavior), the OpenCode launcher, the executable, its argv. A
# dry run prints this (secret words masked) and a restart checks it before it
# stops anything, so neither can show or admit a line other than the one that
# runs. Mode `check` asks the OpenCode launcher to admit it and start nothing.
_rex_launch_line() { # runtime prefix executable run|check args...
  local rt="$1" prefix="$2" bin="$3" mode="$4"; shift 4
  printf '%s ' "${prefix/env CEL_ROLE=/exec env CEL_ROLE=}"
  if [ "$rt" = opencode ]; then
    if [ "$mode" = check ]; then opencode_launch_command check; else opencode_launch_command; fi
  fi
  printf '%q ' "$bin" "$@"
}

# NOTHING IS STOPPED FOR A LINE THAT WILL BE REFUSED. Before a restart stops
# a live agent, its relaunch's own script - the same environment, the same
# line - runs with the OpenCode launcher in --check mode: config, location
# and argv are admitted or refused exactly as the real launch would, and
# nothing native starts. Its refusal prints here, in the caller's terminal.
# Other runtimes have no launcher admission to ask.
rex_launch_check() { # name runtime cwd prefix args...
  local name="$1" rt="$2" cwd="$3" prefix="$4" bin d script rc=0; shift 4
  [ "$rt" = opencode ] || return 0
  _rex_launch_native "$rt" "$cwd" "$@"
  bin="$(command -v "$(agent_get "$rt" bin)")" || die "cel run: executable for $rt is unavailable"
  d="$(_rex_state)"; mkdir -p "$d"; chmod 700 "$d"
  # A private file, as the real script: env.local values never ride an argv.
  script="$(mktemp "$d/.check.XXXXXX")" || return 1
  chmod 700 "$script"
  { _rex_launch_env "$name" "$cwd"; _rex_launch_line "$rt" "$prefix" "$bin" check "$@"; printf '\n'; } > "$script"
  ( _rex_close_leases; exec /bin/bash "$script" ) </dev/null >&2 || rc=$?
  rm -f -- "$script"
  return "$rc"
}

# Callers name the product agent whose session a reviewer or member joins in
# _REX_HOST (and a member's feature in _REX_TEAM); without one the agent opens
# a session of its own.
_rex_launch() { # name runtime cwd label envprefix args...
  local name="$1" rt="$2" cwd="$3" label="$4" prefix="$5"; shift 5
  local _REX_NATIVE native
  _rex_launch_native "$rt" "$cwd" "$@"
  native="$_REX_NATIVE"
  local d file script resp session block pid start bin window="" host="${_REX_HOST:-}" host_session=""
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
    _rex_launch_env "$name" "$cwd"
    _rex_launch_line "$rt" "$prefix" "$bin" run "$@"; printf '\n'
  } > "$script"
  printf '%s\n' "$script" > "$file.pending"; chmod 600 "$file.pending"
  if [ -n "$host" ]; then
    host_session="$(_rex_host_session "$host" "${wsdir:-$cwd}")" \
      || c_warn "Rex: $host has no live session Celestial can prove is its own - $name opens in a session of its own"
  fi
  if [ -n "$host_session" ]; then
    if ! resp="$(_rex_cli window new -s "$host_session" "$name" --cwd "$cwd" --shell=none --keep-open --focus=false --json -- /bin/bash "$script")"; then
      die "cel run: Rex launch was not acknowledged; inspect rex window ls -s $host_session before retrying ($name)"
    fi
    session="$host_session"
    window="$(jq -er '.window_id | select(type == "string" and length > 0)' <<<"$resp")" || die 'Rex returned no window identity'
    block="$(jq -er '.block_ids[0] | select(type == "string" and length > 0)' <<<"$resp")" || die 'Rex returned no terminal identity'
  else
    host=""
    if ! resp="$(_rex_cli new "$name" --cwd "$cwd" --window "$label" --shell=none --keep-open --json -- /bin/bash "$script")"; then
      # A timeout can have created a session: keep the script and pid receipt,
      # and refuse a blind retry; do not destroy an unobserved session.
      die "cel run: Rex launch was not acknowledged; inspect rex ls before retrying ($name)"
    fi
    session="$(jq -er '.session_id' <<<"$resp")" || die 'Rex returned no session identity'
    block="$(jq -er '.initial_windows[0].block_ids[0]' <<<"$resp")" || die 'Rex returned no terminal identity'
    window="$(jq -r '.initial_windows[0].window_id // "" | strings' <<<"$resp")"
  fi
  local i
  for ((i=0;i<50;i++)); do [ -s "$file.pid" ] && break; sleep 0.1; done
  pid="$(cat "$file.pid" 2>/dev/null)"; [[ "$pid" =~ ^[0-9]+$ ]] || die "Rex session $session opened but has not started its runtime"
  start="$(_rex_pid_start "$pid")" || die "Rex session $session exited during startup; inspect rex capture -s $session -b $block"
  local tmp; tmp="$(mktemp "$d/.record.XXXXXX")"; chmod 600 "$tmp"
  jq -n --arg name "$name" --arg rt "$rt" --arg cwd "$cwd" --arg session "$session" --arg block "$block" \
    --argjson pid "$pid" --arg start "$start" --arg role "${env_role:-${role:-core}}" --arg workspace "${wsdir:-$cwd}" \
    --arg repo "${repo:-}" --arg pr "${pr:-}" --arg native "$native" --argjson relaunch "${_REX_RELAUNCH:-null}" \
    --arg window "$window" --arg host "$host" --arg team "${_REX_TEAM:-}" \
    '{name:$name,agent:$rt,cwd:$cwd,role:$role,workspace:$workspace,repo:$repo,pr:$pr,pane_id:("rex/"+$session+"/"+$block),backend:"rex",rex_session:$session,rex_block:$block,pid:$pid,pid_start:$start,agent_status:"working"}
      | if $host != "" then .rex_scope="window" | .rex_host=$host else .rex_scope="session" end
      | if $window != "" then .rex_window=$window else . end
      | if $team != "" then .team=$team else . end
      | if $native != "" then .agent_session={value:$native} else . end
      | if $relaunch != null then .relaunch=$relaunch else . end' > "$tmp"
  mv "$tmp" "$file"; rm -f "$file.pid" "$file.pending"
  exec {lock}>&-
  _REX_PANE="rex/$session/$block"
  if [ -n "$host" ]; then
    printf 'Rex window: %s in %s'"'"'s session %s\nTerminal: %s\n' "$window" "$host" "$session" "$block"
  else
    printf 'Rex session: %s\nTerminal: %s\n' "$session" "$block"
  fi
}

rex_agent_stop() { # pane id, stop only an exact owned terminal
  local pane="$1" f session block window
  for f in "$(_rex_state)"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r .pane_id "$f")" = "$pane" ] || continue
    # A retained terminal may have been repurposed after its runtime exited.
    # Without the original PID identity, clear bookkeeping only.
    if ! _rex_live "$f"; then rm -f "$f"; return 0; fi
    IFS=$'\t' read -r session block window < <(jq -r '[.rex_session, .rex_block, (.rex_window // "")] | @tsv' "$f")
    # Only this terminal closes, scoped to its recorded window when there is
    # one: never the session, which may hold a product's whole team or tabs
    # the owner added; an empty session shell is left intact too. (A window
    # whose last block closes goes with it.)
    _rex_cli block close -s "$session" ${window:+-w "$window"} "$block" || return 1
    local i
    for ((i=0;i<50;i++)); do _rex_live "$f" || { rm -f "$f"; return 0; }; sleep 0.1; done
    return 1
  done
  return 1
}

# A RELAUNCH IS UP ONCE ITS RUNTIME HAS CLEARED ITS OWN ADMISSION, not when
# Rex has opened a terminal for it. The private script starts the runtime only
# after its receipt is published, so every refusal comes after _rex_launch
# returns: an OpenCode launcher refuses after starting its private server
# (server_exited, guard_inactive, models_not_admitted ...) within its own
# deadlines (15s to readiness, 15s to model admission). So it is waited for -
# its TUI started, or the runtime gone. Other runtimes have no admission to
# wait for: alive after a second is up. A runtime gone takes its terminal with
# it (_rex_launch_reap): --keep-open would otherwise leave a dead session.
# 0 up, or still admitting when the wait ran out (never killed on a guess);
# 1 exited, its terminal closed; 2 exited, its terminal could not be closed.
rex_launch_settle() { # <name> <runtime>
  local f pid i polls=10 lock rc=0
  f="$(_rex_file "$1")"
  pid="$(jq -r .pid "$f" 2>/dev/null)" || return 2
  [ "$2" != opencode ] || polls="${CEL_REX_ADMIT_POLLS:-450}"
  for ((i = 0; i < polls; i++)); do
    _rex_live "$f" || break
    [ "$2" != opencode ] || ! opencode_launch_admitted "$pid" || return 0
    sleep 0.1
  done
  if _rex_live "$f"; then
    [ "$2" != opencode ] || c_warn "$1 is still running but its launcher has not admitted a TUI yet - look at it before relying on it"
    return 0
  fi
  exec {lock}>"$f.lock" || return 2
  if flock -n "$lock"; then _rex_launch_reap "$f" || rc=2; else rc=2; fi
  exec {lock}>&-
  [ "$rc" = 0 ] && return 1
  return 2
}

# CLOSE A DEAD LAUNCH'S OWN TERMINAL - the session it opened, or its window in
# a host's - once Rex reports its program finished and nothing else in it
# (_rex_close_owned's proofs), retried while Rex catches up with the exit. The
# OpenCode launcher's one refusal line (fixed vocabulary, never native or
# config text) is repeated first: the terminal that showed it is going.
_rex_launch_reap() { # <receipt>; the caller holds its lock. 0 closed
  local f="$1" s b i rc=3
  IFS=$'\t' read -r s b < <(jq -r '[.rex_session, .rex_block] | @tsv' "$f")
  { _rex_cli --autostart=false capture -s "$s" -b "$b" 2>/dev/null \
      | grep -o 'OpenCode guarded private launch refused (reason=[A-Za-z0-9_]*)' | tail -n 1 >&2; } || true
  for ((i = 0; i < 20 && rc == 3; i++)); do
    rc=0; _rex_close_owned "$f" || rc=$?
    [ "$rc" != 3 ] || sleep 0.1
  done
  [ "$rc" = 0 ]
}

# CLOSE ONE AGENT'S OWN CONTAINER - the window a reviewer or team member opened
# in its product agent's session, or the session an agent opened for itself -
# and nothing else. The caller proves WHO the agent is (role, team,
# workspace); this proves WHAT closes, first and again just before the close:
#   - the receipt's window (rex_scope window) or session holds exactly one
#     terminal, the receipt's block - a block or window anyone added makes it
#     not only this agent's, and it is protected;
#   - in that terminal Rex reports the receipt's exact live runtime as the
#     child, or - its runtime having exited (dead PID generation) - reports a
#     finished program and nothing running, so closing ends no program.
# Then the container closes, the runtime is seen gone, the container is seen
# absent from Rex, and only then the receipt goes. Never the host session.
# 0 closed; 3 protected, nothing closed; 1 closed but not seen through.
rex_agent_close() { # <receipt>
  local f="$1" lock rc=0
  [ -f "$f" ] && [ ! -L "$f" ] && _rex_receipt_valid "$f" || return 3
  jq -e "(.rex_session | type == \"string\" and length > 0) and (.rex_block | type == \"string\" and length > 0)
    and .pane_id == (\"rex/\" + .rex_session + \"/\" + .rex_block) and $_REX_SCOPE_JQ" "$f" >/dev/null 2>&1 || return 3
  exec {lock}>"$f.lock" || return 1
  flock -n "$lock" || { exec {lock}>&-; return 3; }
  _rex_close_owned "$f" || rc=$?
  exec {lock}>&-
  return "$rc"
}
_rex_container_proven() { # <receipt> <live 0|1>
  local f="$1" live="$2" scope s w b pid j info
  IFS=$'\t' read -r scope s w b pid < <(jq -r '[(.rex_scope // "session"), .rex_session, (.rex_window // "-"), .rex_block, (.pid | tostring)] | @tsv' "$f")
  if [ "$scope" = window ]; then
    j="$(_rex_cli --autostart=false window inspect "$w" -s "$s" --json 2>/dev/null)" || return 1
    jq -e --arg s "$s" --arg w "$w" --arg b "$b" '.session_id == $s and .window_id == $w
      and (.layers | length) == 1 and [.layers[].blocks[]?.block_id] == [$b]' <<<"$j" >/dev/null 2>&1 || return 1
  else
    j="$(_rex_cli --autostart=false session inspect "$s" --json 2>/dev/null)" || return 1
    jq -e --arg s "$s" --arg w "$w" --arg b "$b" '.session_id == $s and (.windows | length) == 1
      and ($w == "-" or .windows[0].window_id == $w) and (.windows[0].layers | length) == 1
      and [.windows[0].layers[].blocks[]?.block_id] == [$b]' <<<"$j" >/dev/null 2>&1 || return 1
    w="-"
  fi
  # Scoped to the window too: Rex answers only for a block that is in it.
  if [ "$w" != - ]; then
    info="$(_rex_cli --autostart=false block call process '{}' -s "$s" -w "$w" -b "$b" 2>/dev/null)" || return 1
  else
    info="$(_rex_cli --autostart=false block call process '{}' -s "$s" -b "$b" 2>/dev/null)" || return 1
  fi
  if [ "$live" = 1 ]; then
    jq -e --argjson p "$pid" '(.error // null) == null and .child.pid == $p' <<<"$info" >/dev/null 2>&1
  else
    # Rex omits child and foreground once the program has exited.
    jq -e '(.error // null) == null and (.child // null) == null and (.foreground // null) == null
      and (.last_exit | type == "object" and (.exit_code | type == "number"))' <<<"$info" >/dev/null 2>&1
  fi
}
_rex_container_present() { # <receipt> -> 0 present, 1 absent, 2 unknown
  local f="$1" scope s w j
  IFS=$'\t' read -r scope s w < <(jq -r '[(.rex_scope // "session"), .rex_session, (.rex_window // "-")] | @tsv' "$f")
  j="$(_rex_cli --autostart=false ls --json 2>/dev/null)" || return 2
  jq -e --arg s "$s" '[(.sessions? // .)[]? | .session_id] | index($s) != null' <<<"$j" >/dev/null 2>&1 || return 1
  [ "$scope" = window ] || return 0
  j="$(_rex_cli --autostart=false window ls -s "$s" --json 2>/dev/null)" || return 2
  jq -e --arg w "$w" '[.windows[]? | .window_id] | index($w) != null' <<<"$j" >/dev/null 2>&1
}
_rex_close_owned() { # <receipt>; rex_agent_close holds its lock
  local f="$1" live=0 scope s w i prc=0
  ! _rex_live "$f" || live=1
  _rex_container_proven "$f" "$live" || return 3
  IFS=$'\t' read -r scope s w < <(jq -r '[(.rex_scope // "session"), .rex_session, (.rex_window // "-")] | @tsv' "$f")
  # Again, just before the irreversible step.
  if [ "$live" = 1 ]; then _rex_live "$f" || live=0; fi
  _rex_container_proven "$f" "$live" || return 3
  if [ "$scope" = window ]; then
    _rex_cli --autostart=false window close -s "$s" "$w" >/dev/null 2>&1 || return 1
  else
    _rex_cli --autostart=false kill "$s" >/dev/null 2>&1 || return 1
  fi
  if [ "$live" = 1 ]; then
    for ((i = 0; i < 50; i++)); do _rex_live "$f" || break; sleep 0.1; done
    ! _rex_live "$f" || return 1
  fi
  _rex_container_present "$f" || prc=$?
  [ "$prc" = 1 ] || return 1
  rm -f -- "$f"
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
  # A subagent's turns are not the agent's: neither its transcript nor its
  # idle/working edges are recorded.
  ! native_session_is_subagent "$native" || return 0
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

# ── Rex server generations ───────────────────────────────────────────────────
# A Rex server restart - a package upgrade, `rex server stop`, a crash - ends
# every program in its sessions: every managed runtime dies at once and its
# receipt goes dead, so the roster simply stops listing it. Nothing else would
# notice. Every steward tick records which server instance answers and which
# managed runtimes are live under it (rex_generation_tick). When the instance
# changes, the runtimes that were live under the old one and whose receipts
# are still that same launch - not stopped or retired (both remove the
# receipt), not relaunched since (a new PID) - died with that server, and each
# is resumed ONCE through the `cel run` line its own launch recorded: the
# canonical door, with all its refusals, into its saved session, with its
# explicit profile/model/thinking (a lane keeps its remembered choices). The
# new generation is committed BEFORE any resume, so a failed or interrupted
# resume is reported, never retried behind anyone's back.
#
# The server that answers after a restart is not the one that went away: a
# client-autostarted server runs with --exit-empty and without the tailnet,
# and it restores the old sessions as empty shells under the same labels. So
# the restore (_rex_restore) closes those dead shells for the agents it is
# about to resume, makes sure a server answers (starting a persistent one if
# the last shell's close ended an exit-empty server), turns tailnet serving
# back on if the old server had it, and only then resumes.
#
# Rows: <outcome>\t<name>\t<workspace>\t<detail>, outcome one of
#   resumed        running again; detail is the session it resumed
#   failed         its relaunch ran and did not leave a live runtime
#   held           not resumed: no recorded relaunch line (reviewers never
#                  resume; older receipts), no saved session, a
#                  session record that disagrees with its receipt, no server
#   skipped        stopped, retired, relaunched or still running
#   server         a fact about the server (version/API revision, closed shells,
#                  tailnet restored, a server started)
#   server-failed  a server problem a person must fix (tailnet not restored)
_rex_generation_file() { printf '%s/server-generation' "$(_rex_state)"; }

_rex_server_status() { # -> the running server's status JSON; never starts one
  local s
  s="$(_rex_cli --autostart=false server status --json 2>/dev/null)" || return 1
  jq -ce 'select(type == "object" and (.instance_id | type) == "string" and (.instance_id | length) > 0)' <<<"$s" 2>/dev/null
}
_rex_server_instance() {
  local s; s="$(_rex_server_status)" || return 1
  jq -r .instance_id <<<"$s"
}
_rex_tailscale_of() { jq -r '.tailscale.state // "off"' <<<"$1"; } # <status-json>

_rex_live_generation() { # -> [{name,pid,pid_start}] of live launches; rc 1 when unreadable
  local f rows='[]'
  for f in "$(_rex_state)"/*.json; do
    [ -f "$f" ] || continue
    _rex_receipt_valid "$f" || return 1
    _rex_live "$f" || continue
    rows="$(jq -c --arg n "$(basename "$f" .json)" --slurpfile r "$f" \
      '. + [{name: $n, pid: $r[0].pid, pid_start: $r[0].pid_start}]' <<<"$rows")" || return 1
  done
  printf '%s' "$rows"
}

# What a later restore needs of this server: who it is, what it ran, whether
# it served the tailnet, and the launches live under it.
_rex_generation_commit() { # <status-json> <live-json>
  local tmp
  tmp="$(mktemp "$(_rex_state)/.generation.XXXXXX")" || return 1
  if jq -n --argjson s "$1" --arg at "$(date -u +%FT%TZ)" --argjson live "$2" \
       '{instance: $s.instance_id, rex_version: ($s.rex_version // ""), api_revision: ($s.api_revision // null),
         tailscale: ($s.tailscale.state // "off"), exit_empty: ($s.exit_empty // null), observed_at: $at, live: $live}' \
       > "$tmp" && mv -f "$tmp" "$(_rex_generation_file)"; then
    return 0
  fi
  rm -f "$tmp"; return 1
}

# One owner of a generation change at a time: the safety net and a managed
# upgrade both hold this for their whole run, and every child closes it.
_rex_generation_lock() {
  exec {_REX_GEN_FD}>>"$(_rex_generation_file).lock" || return 1
  flock -n "$_REX_GEN_FD" && return 0
  exec {_REX_GEN_FD}>&-; _REX_GEN_FD=""; return 1
}
_rex_generation_unlock() {
  [ -z "${_REX_GEN_FD:-}" ] || exec {_REX_GEN_FD}>&-
  _REX_GEN_FD=""
}

_rex_one_line() { tr '\t\n' '  ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-300; }

# Why a dead launch cannot come back through its own recorded line; empty when it can.
_rex_resume_veto() { # <receipt>
  local f="$1" role repo pr ws cwd want have
  if ! jq -e '.relaunch | type == "array" and length > 1 and all(.[]; type == "string")' "$f" >/dev/null 2>&1; then
    role="$(jq -r '.role // ""' "$f")"
    case "$role" in
      reviewer)
        repo="$(jq -r '.repo // ""' "$f")"; pr="$(jq -r '.pr // "" | tostring' "$f")"
        ws="$(ws_name "$(jq -r '.workspace // ""' "$f")" 2>/dev/null || true)"
        printf 'reviewers never resume - if %s#%s is still open: cel run reviewer --repo %s --pr %s%s' \
          "$repo" "$pr" "$repo" "$pr" "${ws:+ --workspace $ws}" ;;
      # A member's only door is cel team add (a one-time token), which is
      # the lead's: it opens the member as a window in the lead's session again.
      member)
        printf 'team members never resume - its lead retires and adds it again: cel team retire %s %s, then cel team add %s ...' \
          "$(jq -r '.team // "<feature>"' "$f")" "$(jq -r '.name // ""' "$f")" "$(jq -r '.team // "<feature>"' "$f")" ;;
      *) printf 'its launch predates recorded relaunch lines - resume it by hand once (cel run ... --restart), which records one' ;;
    esac
    return 0
  fi
  want="$(jq -r '.agent_session.value // ""' "$f")"
  if [ -z "$want" ]; then
    printf 'its runtime never reported a native session, so a relaunch would start a fresh conversation'
    return 0
  fi
  cwd="$(jq -r '.cwd // ""' "$f")"
  have="$(_run_sessions_last "$cwd")"
  [ "$have" = "$want" ] \
    || printf 'the saved session for %s is %s, not its receipt'"'"'s %s - refusing to resume into another conversation' \
      "$cwd" "${have:-nothing}" "$want"
}

# Runs the receipt's recorded `cel run` line. REX_AUTOSTART=false: a server
# started from a steward tick would live in the tick's cgroup and die with it.
_rex_relaunch() { # <receipt>
  local -a argv=()
  mapfile -d '' -t argv < <(jq -j '.relaunch[] | ., "\u0000"' "$1")
  [ "${#argv[@]}" -gt 1 ] || return 1
  (
    _rex_close_leases
    REX_AUTOSTART=false exec "$CEL_ROOT/bin/cel" "${argv[@]}"
  ) </dev/null
}

# A row when this launch is NOT to be relaunched; nothing when it is.
_rex_resume_check() { # <name> <pid> <pid-start>
  local name="$1" pid="$2" start="$3" f ws veto
  f="$(_rex_file "$name")"
  if [ ! -f "$f" ]; then
    printf 'skipped\t%s\t\tstopped or retired since (its receipt is gone)\n' "$name"; return 0
  fi
  if ! _rex_receipt_valid "$f"; then
    printf 'held\t%s\t\tits receipt is unreadable\n' "$name"; return 0
  fi
  ws="$(jq -r '.workspace // ""' "$f")"
  if [ "$(jq -r '.pid | tostring' "$f")" != "$pid" ] || [ "$(jq -r '.pid_start' "$f")" != "$start" ]; then
    printf 'skipped\t%s\t%s\trelaunched since\n' "$name" "$ws"; return 0
  fi
  if _rex_live "$f"; then
    printf 'skipped\t%s\t%s\tstill running\n' "$name" "$ws"; return 0
  fi
  if compgen -G "$(_rex_state)/retirements/$name-$pid-$start-*.json" >/dev/null; then
    printf 'skipped\t%s\t%s\tits retirement had begun\n' "$name" "$ws"; return 0
  fi
  veto="$(_rex_resume_veto "$f")"
  [ -z "$veto" ] || printf 'held\t%s\t%s\t%s\n' "$name" "$ws" "$(_rex_one_line <<<"$veto")"
}

_rex_relaunch_one() { # <name> <old-pid> -> resumed|failed row
  local name="$1" pid="$2" f ws out rc=0
  f="$(_rex_file "$name")"; ws="$(jq -r '.workspace // ""' "$f")"
  out="$(_rex_relaunch "$f" 2>&1)" || rc=$?
  if [ "$rc" = 0 ] && [ -f "$f" ] && _rex_receipt_valid "$f" && _rex_live "$f" \
     && [ "$(jq -r '.pid | tostring' "$f")" != "$pid" ]; then
    printf 'resumed\t%s\t%s\t%s\n' "$name" "$ws" "$(jq -r '.agent_session.value // ""' "$f" | _rex_one_line)"
  else
    out="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1 | _rex_one_line)"
    printf 'failed\t%s\t%s\t%s\n' "$name" "$ws" "${out:-its relaunch left no live runtime (exit $rc)}"
  fi
}

# RESTORED SHELLS: sessions labelled <name> in which no block runs a program.
# FAIL CLOSED: a session counts as dead only when at least one block was seen
# and every block's process report NAMES child and foreground as null. An
# empty or unreadable topology, an omitted key, or any error is alive.
_rex_session_dead() { # <session> -> 0 only when every block provably runs nothing
  local s="$1" j blocks b info seen=0
  j="$(_rex_cli --autostart=false session inspect "$s" --json 2>/dev/null)" || return 1
  blocks="$(jq -r '[.windows[]?.layers[]?.blocks[]?.block_id | select(type == "string" and length > 0)] | .[]' <<<"$j" 2>/dev/null)" || return 1
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    info="$(_rex_cli --autostart=false block call process '{}' -s "$s" -b "$b" 2>/dev/null)" || return 1
    jq -e 'type == "object" and has("child") and has("foreground") and .child == null and .foreground == null
      and ((has("error") | not) or .error == null)' <<<"$info" >/dev/null 2>&1 || return 1
    seen=$((seen + 1))
  done <<<"$blocks"
  [ "$seen" -gt 0 ]
}
_rex_close_dead_duplicates() { # <label> -> how many were closed
  local j s n=0
  j="$(_rex_cli --autostart=false ls --json 2>/dev/null)" || { printf 0; return 0; }
  for s in $(jq -r --arg l "$1" '(.sessions? // .)[]? | select(.label == $l) | .session_id' <<<"$j" 2>/dev/null); do
    _rex_session_dead "$s" || continue
    if _rex_cli --autostart=false kill "$s" >/dev/null 2>&1; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

# A SERVER THAT ANSWERS, serving the tailnet if the old one did. A server
# started here is persistent (not --exit-empty) and in its own scope. Prints
# server rows; sets _REX_STATUS and _REX_STARTED. rc 1 when none answers.
_rex_server_ready() { # <tailscale-state-before>
  local before="$1" s="" i state first
  _REX_STATUS=""; _REX_STARTED=0
  s="$(_rex_server_status)" || s=""
  if [ -z "$s" ]; then
    _rex_server_start "$before" >/dev/null 2>&1 || true
    _rex_wait_instance "" 1 >/dev/null || { printf 'server-failed\trex\t\tno Rex server answered, and starting one failed\n'; return 1; }
    s="$(_rex_server_status)" || { printf 'server-failed\trex\t\tthe started Rex server stopped answering\n'; return 1; }
    _REX_STARTED=1
    printf 'server\trex\t\tstarted a persistent Rex server (none was answering)\n'
  fi
  state="$(_rex_tailscale_of "$s")"
  if [ "$before" = running ] && [ "$state" != running ]; then
    first="$state"
    _rex_cli --autostart=false server tailscale on >/dev/null 2>&1 || true
    for ((i = 0; i < ${CEL_REX_SERVER_WAIT_TENTHS:-300}; i++)); do
      s="$(_rex_server_status)" || s=""
      state="$(_rex_tailscale_of "${s:-null}")"
      [ "$state" != running ] || break
      sleep 0.1
    done
    if [ "$state" = running ]; then
      printf 'server\ttailscale\t\ttailnet serving restored (the new server came up %s)\n' "$first"
    else
      printf 'server-failed\ttailscale\t\tthe old server served the tailnet; this one is still %s after rex server tailscale on\n' "$state"
    fi
    [ -n "$s" ] || return 1
  fi
  _REX_STATUS="$s"
}

# THE RESTORE after any restart. stdin: the launches live under the old server
# (<name> <pid> <pid-start>); <old> its generation record. Classifies them,
# closes the dead restored shells of the ones to resume, makes sure a server
# answers (again: closing the last shell ends an exit-empty server), commits
# the new generation, then resumes each one and confirms it stayed alive. With
# no server, nothing is committed, so the launches wait for the next one.
_rex_restore() { # <old-generation-json>
  local old="$1" name pid start row todo="" closed n attempt rows="" f ws outcome detail
  while IFS=$'\t' read -r name pid start; do
    [ -n "$name" ] || continue
    row="$(_rex_resume_check "$name" "$pid" "$start")"
    if [ -n "$row" ]; then printf '%s\n' "$row"; else todo+="$name"$'\t'"$pid"$'\n'; fi
  done
  for attempt in 1 2; do
    closed=""
    while IFS=$'\t' read -r name pid; do
      [ -n "$name" ] || continue
      n="$(_rex_close_dead_duplicates "$name")"
      [ "${n:-0}" = 0 ] || closed+="${closed:+, }$name ($n)"
    done <<<"$todo"
    [ -z "$closed" ] || printf 'server\tshells\t\tclosed dead restored sessions: %s\n' "$closed"
    if ! _rex_server_ready "$(jq -r '.tailscale // "off"' <<<"$old")"; then
      while IFS=$'\t' read -r name pid; do
        [ -z "$name" ] || printf 'held\t%s\t%s\tno Rex server answered; it resumes when one does\n' \
          "$name" "$(jq -r '.workspace // ""' "$(_rex_file "$name")")"
      done <<<"$todo"
      return 0
    fi
    # A server started here has restored the saved sessions once more.
    [ "$_REX_STARTED" = 1 ] || break
  done
  printf 'server\tversion\t\trex %s, API revision %s -> rex %s, API revision %s\n' \
    "$(jq -r 'if (.rex_version // "") == "" then "?" else .rex_version end' <<<"$old")" \
    "$(jq -r '.api_revision // "?"' <<<"$old")" \
    "$(jq -r '.rex_version // "?"' <<<"$_REX_STATUS")" "$(jq -r '.api_revision // "?"' <<<"$_REX_STATUS")"
  # ONCE needs the record first: without it a later tick would resume these
  # again, so nothing is relaunched when the generation cannot be written.
  local live=""
  if ! live="$(_rex_live_generation)" || ! _rex_generation_commit "$_REX_STATUS" "$live"; then
    while IFS=$'\t' read -r name pid; do
      [ -z "$name" ] || printf 'held\t%s\t%s\tthe new Rex server generation could not be recorded, so nothing was resumed\n' \
        "$name" "$(jq -r '.workspace // ""' "$(_rex_file "$name")")"
    done <<<"$todo"
    return 0
  fi
  while IFS=$'\t' read -r name pid; do
    [ -n "$name" ] || continue
    rows+="$(_rex_relaunch_one "$name" "$pid")"$'\n'
  done <<<"$todo"
  # A runtime that starts and then dies is a failure, not a resume.
  if grep -q '^resumed' <<<"$rows"; then sleep "${CEL_REX_RESUME_SETTLE_SECS:-15}"; fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r outcome name ws detail <<<"$row"
    f="$(_rex_file "$name")"
    if [ "$outcome" = resumed ] && ! { [ -f "$f" ] && _rex_receipt_valid "$f" && _rex_live "$f"; }; then
      row="$(printf 'failed\t%s\t%s\tit started, then exited within %ss' "$name" "$ws" "${CEL_REX_RESUME_SETTLE_SECS:-15}")"
    fi
    printf '%s\n' "$row"
  done <<<"$rows"
}

# THE SAFETY NET, for restarts nobody announced. Prints nothing unless the
# server instance changed since the last tick; then a header row
# "generation\t<old>\t<new>" and the restore's rows. No answering server is no
# evidence (and asking with autostart would start one), and the first
# observation has no previous generation to compare with.
rex_generation_tick() {
  local status cur now prev old
  [ -d "$(_rex_state)" ] && command -v "${CEL_REX_BIN:-rex}" >/dev/null 2>&1 || return 0
  _rex_generation_lock || return 0
  if ! status="$(_rex_server_status)"; then _rex_generation_unlock; return 0; fi
  cur="$(jq -r .instance_id <<<"$status")"
  if ! now="$(_rex_live_generation)"; then _rex_generation_unlock; return 2; fi
  prev="$(jq -c 'select(type == "object" and (.instance | type) == "string" and (.live | type) == "array")' \
    "$(_rex_generation_file)" 2>/dev/null || true)"
  old="$(jq -r '.instance // ""' <<<"${prev:-null}")"
  if [ -z "$prev" ] || [ "$old" = "$cur" ]; then
    _rex_generation_commit "$status" "$now" || { _rex_generation_unlock; return 1; }
    _rex_generation_unlock; return 0
  fi
  printf 'generation\t%s\t%s\n' "$old" "$cur"
  jq -r '.live[] | [.name, (.pid | tostring), .pid_start] | @tsv' <<<"$prev" | _rex_restore "$prev"
  _rex_generation_unlock
}

# ── keeping Rex current ──────────────────────────────────────────────────────
# The rex package comes from pkgs.superlogical.com, which unattended-upgrades
# does not cover, and upgrading it under live sessions killed every Rex agent
# once. rex_upgrade_round is the managed path: only when apt offers a NEWER rex
# from that origin, only when every live managed Rex agent is idle and can be
# resumed canonically (else the round is skipped and retried later - a busy
# agent is never restarted), it records them, upgrades, restarts the server if
# the package did not, resumes each one in its saved session and checks it is
# alive. The steward runs a round at most every 30 minutes.
#
# Seams for tests; the real ones touch apt, sudo and systemd, so a suite that
# forgot to replace one finds no candidate and changes nothing on the box.
_rex_apt_policy() { [ -n "${CEL_TESTING:-}" ] || LC_ALL=C apt-cache policy rex 2>/dev/null; }
_rex_apt_upgrade() { # <exact vetted version>
  [ -z "${CEL_TESTING:-}" ] || { echo 'refusing a real apt upgrade under tests' >&2; return 1; }
  [ -n "${1:-}" ] || return 1
  ( _rex_close_leases
    exec sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y -q "rex=$1" ) </dev/null
}
_rex_server_stop() {
  [ -z "${CEL_TESTING:-}" ] || [ -n "${CEL_REX_BIN:-}" ] || return 1
  _rex_cli --autostart=false server stop </dev/null
}
# A persistent server (not --exit-empty, unlike client autostart), serving the
# tailnet when the old one did, in its own transient scope - never the
# caller's cgroup: a server started from the steward's oneshot unit would be
# killed when the tick ends.
_rex_server_start() { # <tailscale-state-before>
  [ -z "${CEL_TESTING:-}" ] || return 1
  local -a flags=()
  [ "${1:-}" != running ] || flags=(--tailscale)
  ( _rex_close_leases
    exec systemd-run --user --scope --quiet --collect --unit "cel-rex-server-$(date +%s)" \
      -- "${CEL_REX_BIN:-rex}" server start "${flags[@]}" ) </dev/null
}

_REX_ORIGIN=pkgs.superlogical.com

# -> "<installed>\t<candidate>\t<origin-ok 0|1>" from apt's policy. The
# candidate counts only when one of its sources is https on exactly the
# origin host - never a host that merely contains the name.
_rex_policy_versions() {
  _rex_apt_policy | awk -v origin="$_REX_ORIGIN" '
    $1 == "Installed:" { inst = $2; next }
    $1 == "Candidate:" { cand = $2; next }
    /^ (\*\*\*)? +[^ ]+ +-?[0-9]+$/ { v = ($1 == "***") ? $2 : $1; next }
    $1 ~ /^-?[0-9]+$/ && $2 ~ /^https:\/\// {
      host = substr($2, 9); sub(/\/.*/, "", host)
      if (v == cand && host == origin) ok = 1
    }
    END { printf "%s\t%s\t%d\n", inst, cand, ok + 0 }'
}

# -> "<installed>\t<candidate>" when apt offers a newer rex from its own origin.
rex_upgrade_candidate() {
  local inst cand ok
  IFS=$'\t' read -r inst cand ok < <(_rex_policy_versions) || return 1
  [ -n "$inst" ] && [ "$inst" != "(none)" ] && [ -n "$cand" ] && [ "$cand" != "(none)" ] || return 1
  [ "$ok" = 1 ] && dpkg --compare-versions "$cand" gt "$inst" || return 1
  printf '%s\t%s\n' "$inst" "$cand"
}

# Every live managed Rex launch, with what the upgrade needs to know about it.
# Sets _REX_PLAN (TSV name/pid/pid-start), _REX_BUSY (names not idle),
# _REX_HELD ("name: why" for launches that could not be resumed) and
# _REX_FOREIGN (sessions on the server that are not a live managed launch: a
# server stop would end them, and nothing would bring them back). rc 1 when
# a receipt is unreadable, 2 when the server's session list is.
_rex_upgrade_plan() {
  local f name status veto managed='' j
  _REX_PLAN=""; _REX_BUSY=""; _REX_HELD=""; _REX_FOREIGN=""
  for f in "$(_rex_state)"/*.json; do
    [ -f "$f" ] || continue
    _rex_receipt_valid "$f" || return 1
    _rex_live "$f" || continue
    name="$(basename "$f" .json)"
    status="$(jq -r '.agent_status // "unknown"' "$f")"
    [ "$status" = idle ] || _REX_BUSY+="${_REX_BUSY:+, }$name ($status)"
    veto="$(_rex_resume_veto "$f")"
    [ -z "$veto" ] || _REX_HELD+="${_REX_HELD:+; }$name: $(_rex_one_line <<<"$veto")"
    _REX_PLAN+="$(jq -r --arg n "$name" '[$n, (.pid | tostring), .pid_start] | @tsv' "$f")"$'\n'
    managed+="$(jq -r '.rex_session // ""' "$f")"$'\n'
  done
  # No server answering has no sessions to end.
  _rex_server_status >/dev/null || return 0
  j="$(_rex_cli --autostart=false ls --json 2>/dev/null)" || return 2
  _REX_FOREIGN="$(jq -r --arg m "$managed" '($m | split("\n") | map(select(length > 0))) as $ids
    | [(.sessions? // .)[] | select(.session_id as $s | $ids | any(. == $s) | not)
       | "\(.label // "unlabelled") (\(.session_id))"] | sort | join(", ")' <<<"$j" 2>/dev/null)" || return 2
}

_rex_wait_instance() { # <instance-to-leave|""> <present 0|1> -> instance; bounded
  local i id
  for ((i = 0; i < ${CEL_REX_SERVER_WAIT_TENTHS:-300}; i++)); do
    id="$(_rex_server_instance || true)"
    if [ "$2" = 1 ] && [ -n "$id" ] && [ "$id" != "$1" ]; then printf '%s' "$id"; return 0; fi
    if [ "$2" = 0 ] && [ -z "$id" ]; then return 0; fi
    sleep 0.1
  done
  return 1
}

# One round. Output, first line:
#   (nothing)                      no newer rex from its origin
#   waiting\t<candidate>\t<why>    skipped (busy agents, a lock); the next round retries
#   blocked\t<candidate>\t<why>    skipped until a person acts (an agent that could
#                                  not be resumed, a session Celestial does not
#                                  manage, an unreadable receipt or session list)
#   failed\t<candidate>\t<why>     apt did not install it; nothing was stopped
#   upgraded\t<from>\t<to>\t<who restarted the server>
# then, after an upgrade, the restore's server and agent rows (see above).
rex_upgrade_round() {
  local versions inst cand old cur restarted out rc=0 deadline lock
  command -v "${CEL_REX_BIN:-rex}" >/dev/null 2>&1 || return 0
  versions="$(rex_upgrade_candidate)" || return 0
  IFS=$'\t' read -r inst cand <<<"$versions"
  mkdir -p "$(_rex_state)"; chmod 700 "$(_rex_state)"
  if ! _rex_generation_lock; then
    printf 'waiting\t%s\tanother Rex server change is in progress\n' "$cand"; return 0
  fi
  # Nothing changes before every live agent is idle and resumable. Busy
  # agents get a bounded wait; an unresumable one skips the round at once.
  deadline=$((SECONDS + ${CEL_REX_UPGRADE_IDLE_SECS:-120}))
  local prc
  while :; do
    prc=0; _rex_upgrade_plan || prc=$?
    if [ "$prc" != 0 ]; then
      _rex_generation_unlock
      if [ "$prc" = 2 ]; then printf 'blocked\t%s\tthe Rex session list is unreadable - nothing was changed\n' "$cand"
      else printf 'blocked\t%s\ta Rex receipt is unreadable - nothing was changed\n' "$cand"; fi
      return 0
    fi
    if [ -n "$_REX_HELD" ]; then
      _rex_generation_unlock
      printf 'blocked\t%s\tthese Rex agents could not be resumed after a server restart: %s\n' "$cand" "$_REX_HELD"; return 0
    fi
    # A server stop ends EVERY session, and only managed launches come back.
    if [ -n "$_REX_FOREIGN" ]; then
      _rex_generation_unlock
      printf 'blocked\t%s\tthe Rex server holds sessions Celestial does not manage, which a restart would end: %s\n' "$cand" "$_REX_FOREIGN"; return 0
    fi
    [ -n "$_REX_BUSY" ] || break
    if [ "$SECONDS" -ge "$deadline" ]; then
      _rex_generation_unlock
      printf 'waiting\t%s\tnot every Rex agent went idle within %ss: %s\n' "$cand" "${CEL_REX_UPGRADE_IDLE_SECS:-120}" "$_REX_BUSY"; return 0
    fi
    sleep "${CEL_REX_UPGRADE_POLL_SECS:-10}"
  done
  # No Celestial launch may start between the last idle check and the stop.
  exec {lock}>>"$(_rex_state)/launch.lock" || { _rex_generation_unlock; printf 'waiting\t%s\tlaunch admission is unavailable\n' "$cand"; return 0; }
  if ! flock -w 60 "$lock"; then
    exec {lock}>&-; _rex_generation_unlock
    printf 'waiting\t%s\tanother agent launch holds admission\n' "$cand"; return 0
  fi
  local _RUN_ADMISSION_FD="$lock"
  if ! _rex_upgrade_plan || [ -n "$_REX_HELD$_REX_BUSY$_REX_FOREIGN" ]; then
    exec {lock}>&-; _rex_generation_unlock
    printf 'waiting\t%s\tsomething changed at the last check: %s\n' "$cand" "${_REX_BUSY:-${_REX_HELD:-${_REX_FOREIGN:-unreadable inventory}}}"; return 0
  fi
  local oldstatus oldrec=""
  oldstatus="$(_rex_server_status || true)"
  old="$(jq -r '.instance_id // ""' <<<"${oldstatus:-null}")"
  # RECORDED BEFORE ANYTHING CAN END THEM: these exact launches, and what the
  # server was (version, API revision, tailnet), are the generation to restore.
  # If this run dies part-way, the safety net finds them dead under whichever
  # server answers next and restores them itself.
  if [ -n "$oldstatus" ]; then
    _rex_generation_commit "$oldstatus" "$(printf '%s' "$_REX_PLAN" \
      | jq -Rcs '[split("\n")[] | select(length > 0) | split("\t") | {name: .[0], pid: (.[1] | tonumber), pid_start: .[2]}]')" \
      || { exec {lock}>&-; _rex_generation_unlock; printf 'waiting\t%s\tcould not record the Rex agents to restore\n' "$cand"; return 0; }
    oldrec="$(cat "$(_rex_generation_file)")"
  fi
  # Exactly the version vetted above, never whatever apt resolves by then.
  out="$(_rex_apt_upgrade "$cand" 2>&1)" || rc=$?
  IFS=$'\t' read -r cur _ _ < <(_rex_policy_versions)
  if [ "$rc" != 0 ] || [ "$cur" != "$cand" ]; then
    exec {lock}>&-; _rex_generation_unlock
    printf 'failed\t%s\tapt did not install it (exit %s, installed %s): %s\n' "$cand" "$rc" "${cur:-?}" \
      "$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1 | _rex_one_line)"
    return 0
  fi
  # The package restarts only its system units; a per-user server keeps the
  # old binary until it is restarted, which is done here, never mid-turn, and
  # into a persistent server that serves the tailnet if the old one did.
  cur="$(_rex_server_instance || true)"
  if [ -n "$cur" ] && [ "$cur" != "$old" ]; then
    restarted="the server had already restarted"
  else
    restarted="cel restarted the server"
    if [ -n "$cur" ]; then
      _rex_server_stop >/dev/null 2>&1 || true
      _rex_wait_instance "$cur" 0 || true
    fi
    _rex_server_start "$(_rex_tailscale_of "${oldstatus:-null}")" >/dev/null 2>&1 || true
    _rex_wait_instance "$old" 1 >/dev/null || true
  fi
  exec {lock}>&-; unset _RUN_ADMISSION_FD
  [ -n "$oldrec" ] || oldrec='{}'
  printf 'upgraded\t%s\t%s\t%s\n' "$inst" "$cand" "$restarted"
  printf '%s' "$_REX_PLAN" | _rex_restore "$oldrec"
  _rex_generation_unlock
}

cmd_sessions() {
  case "${1:-}" in
    note)
      [ $# = 4 ] || die 'sessions note: pid state native-session'
      . "$CEL_ROOT/lib/run.sh"
      rex_session_note "$2" "$3" "$4" || return $?
      if [ -n "$4" ] && [ -n "${CEL_REX_RECORD:-}" ] && [ -f "$CEL_REX_RECORD" ]; then
        case "$(jq -r .role "$CEL_REX_RECORD")" in
          core|root|orchestrator|solo) _run_sessions_record "$(jq -r .cwd "$CEL_REX_RECORD")" "$4" "$(jq -r '.agent // empty' "$CEL_REX_RECORD")" ;;
        esac
      fi ;;
    retire-reviewer)
      shift
      . "$CEL_ROOT/lib/gc.sh"
      cmd_reviewer_retire "$@" ;;
    rex-upgrade)
      shift
      . "$CEL_ROOT/lib/steward.sh"
      case "${1:-}" in
        --check)
          local versions
          if versions="$(rex_upgrade_candidate)"; then
            printf 'rex %s is installed; %s is available from %s\n' "${versions%%$'\t'*}" "${versions#*$'\t'}" "$_REX_ORIGIN"
          else
            printf 'no newer rex from %s\n' "$_REX_ORIGIN"
          fi
          _rex_upgrade_plan || die 'cel sessions rex-upgrade: a Rex receipt or the Rex session list is unreadable'
          printf 'busy: %s\nnot resumable: %s\nunmanaged sessions a restart would end: %s\n' \
            "${_REX_BUSY:-none}" "${_REX_HELD:-none}" "${_REX_FOREIGN:-none}" ;;
        '') _steward_rex_upgrade ;;
        *) die 'usage: cel sessions rex-upgrade [--check]' ;;
      esac ;;
    --json) cel_agent_list ;;
    '') cel_agent_list | jq -r '.result.agents[] | [ .name, (.backend // "herdr"), .agent, (.agent_status // "unknown"), .pane_id ] | @tsv' ;;
    *) die 'usage: cel sessions [--json] | retire-reviewer <repo>#<pr> [--workspace W] [--dry-run] | rex-upgrade [--check]' ;;
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
