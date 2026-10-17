# shellcheck shell=bash
# `cel-fanout recover` (AH-261017): canonical registration and ONE safe
# continuation of a worker whose launch was only partly recorded - a live agent
# in its pane, a correct worktree, and NO ledger row, because the delegating
# process died or timed out between `herdr agent start` and the ledger append
# (the 2026-10-17 W710 case). Sourced by cel-fanout, which supplies the ledger
# primitives (_ledger_*), $HERDR and the workspace helpers; this file only
# defines functions.
#
# WHAT THIS IS NOT. It is not an adoption verb and not a repair of the ledger:
#   - no raw row import: every field of the row is derived from the workspace,
#     the explicit original coordinate and what is OBSERVED now;
#   - no agent start, no Enter/Ctrl-C/send-keys, no report-agent / session
#     mutation, no pending-launch reset, no model fallback;
#   - nothing is claimed about history nobody can prove: original start time,
#     task delivery, model/tool success, the session file, approval and
#     head_source stay unknown and are listed as such in recovery.unproven.
#
# HERDR 0.9.1, what it does and does not give us (read from the installed
# binary and `herdr agent list`; nothing here was tried on a live worker):
#   - `agent list` reports name, pane_id, agent kind, agent_status,
#     interactive_ready, and launch_pending while a start is unconfirmed.
#   - `agent prompt` is the one supported way to hand a task to an existing
#     agent, and herdr itself refuses it (agent_not_ready / agent_launch_pending)
#     when the agent cannot take one. There is NO supported call that confirms
#     or clears a pending launch. So continuation is only attempted when herdr
#     reports the agent interactive_ready and not launch_pending; for a worker
#     still launch_pending the answer is a bounded refusal naming the upstream
#     prerequisite (a herdr surface that completes or reports the pending
#     launch), never a forced reset or an Enter.
[ -n "${_CEL_FANOUT_RECOVER:-}" ] && return 0
_CEL_FANOUT_RECOVER=1

# --- observation (read-only) ------------------------------------------------

# /proc, with a test root only under CEL_TESTING (a seam that could hide a live
# process must not exist in production).
_rec_proc() {
  if [ -n "${CEL_TESTING:-}" ] && [ -n "${CEL_FANOUT_PROC:-}" ]; then printf '%s' "$CEL_FANOUT_PROC"
  else printf '/proc'; fi
}
_rec_ps() {
  if [ -n "${CEL_TESTING:-}" ] && [ -n "${CEL_FANOUT_PS:-}" ]; then cat "$CEL_FANOUT_PS"
  else ps -eo pid=,args= 2>/dev/null; fi
}
# A test-only hard crash at a named point: SIGKILL, so no trap runs and no
# state is tidied - the same thing a power cut does.
_rec_crash_point() { # <name>
  if [ -n "${CEL_TESTING:-}" ] && [ "${CEL_FANOUT_CRASH:-}" = "$1" ]; then kill -9 $$; fi
  return 0
}

_rec_stat_field() { # <pid> <ppid|start> -> value, empty when unreadable
  local f; f="$(_rec_proc)/$1/stat"
  [ -r "$f" ] || return 0
  # field 2 is "(comm)" and may hold spaces: drop through the last ") "
  sed -E 's/^.*\) //' "$f" 2>/dev/null | awk -v k="$2" '{ if (k == "ppid") print $2; else print $20 }'
}
# One variable out of a process environment. Only ever asked for the names the
# launch line sets (CEL_ROLE, CEL_WORKSPACE, CEL_INBOX_ME); the rest of the
# environment - credentials included - is never read into a variable or printed.
_rec_env_get() { # <pid> <NAME>
  local f; f="$(_rec_proc)/$1/environ"
  [ -r "$f" ] || return 0
  tr '\0' '\n' < "$f" 2>/dev/null | grep -m1 "^$2=" | cut -d= -f2- || true
}
# EXACT argv elements, never a substring (gpt-5 must not match gpt-5.5):
# `--model <id>` or `--model=<id>` as the launch line spells it.
_rec_cmdline_model_is() { # <pid> <model>
  local f prev="" a; f="$(_rec_proc)/$1/cmdline"
  [ -r "$f" ] || return 1
  while IFS= read -r -d '' a; do
    if [ "$prev" = --model ] && [ "$a" = "$2" ]; then return 0; fi
    [ "$a" != "--model=$2" ] || return 0
    prev="$a"
  done < "$f"
  return 1
}
# Every argument the profile's launch contributes (model AND thinking level)
# must be a whole argv element of the live process, in the same order.
_rec_cmdline_has_args() { # <pid> <args...>
  local f; f="$(_rec_proc)/$1/cmdline"; shift
  [ -r "$f" ] || return 1
  local -a argv=(); local a
  while IFS= read -r -d '' a; do argv+=("$a"); done < "$f"
  local want i=0
  for want in "$@"; do
    while [ "$i" -lt "${#argv[@]}" ] && [ "${argv[$i]}" != "$want" ]; do i=$((i + 1)); done
    [ "$i" -lt "${#argv[@]}" ] || return 1
    i=$((i + 1))
  done
  return 0
}

# Is something that could still complete the ORIGINAL launch running? A live
# `cel-fanout delegate|scout|spike` for this branch, or a live `herdr agent
# start` for this alias, may yet append a row or start a second agent.
_rec_original_active() { # <branch> <alias> -> prints the offending line, returns 0 when active
  local line pid
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid="${line%% *}"; pid="${pid# }"
    [ "$pid" = "$$" ] && continue
    case "$line" in *" recover "*) continue ;; esac
    case "$line" in
      *cel-fanout*" delegate "*|*cel-fanout*" scout "*|*cel-fanout*" spike "*)
        case "$line" in *"$1"*) printf '%s' "${line:0:160}"; return 0 ;; esac ;;
      *"agent start $2"*) printf '%s' "${line:0:160}"; return 0 ;;
    esac
  done < <(_rec_ps)
  return 1
}

# Observe one pane through herdr's structured surfaces and the process table.
# Sets REC_* and dies with a refusal only for an unreadable surface; judging the
# facts is the caller's job.
_rec_observe() { # <pane> <alias>
  local pane="$1" alias="$2" g p l
  g="$("$HERDR" pane get "$pane" 2>/dev/null)" || die "recover: herdr cannot describe pane $pane - nothing changed"
  p="$("$HERDR" pane process-info --pane "$pane" 2>/dev/null)" || die "recover: herdr cannot report the processes of pane $pane - nothing changed"
  l="$("$HERDR" agent list 2>/dev/null)" || die "recover: herdr cannot list agents - nothing changed"
  REC_JSON="$(jq -n --argjson g "$g" --argjson p "$p" --argjson l "$l" --arg pane "$pane" --arg alias "$alias" '
    ($g.result.pane // {}) as $gp | ($p.result.process_info // {}) as $pp
    | [($l.result.agents // [])[] | select(.pane_id == $pane)] as $inpane
    | [($l.result.agents // [])[] | select(.name == $alias)] as $named
    | {pane_ok: (($gp.pane_id // "") == $pane and ($pp.pane_id // "") == $pane),
       terminal: ($gp.terminal_id // ""),
       shell_pid: ($pp.shell_pid // null),
       pgid: ($pp.foreground_process_group_id // null),
       fg_pids: [($pp.foreground_processes // [])[] | .pid],
       agents_in_pane: ($inpane | length),
       agents_named: ($named | length),
       agent: ($inpane[0] // null)}')" || die "recover: could not read herdr's answer for pane $pane - nothing changed"
}

# --- inspect (read-only) ----------------------------------------------------

cmd_recover_inspect() { # <repo> <branch> --workspace W --pane P
  [ $# -ge 2 ] || die "usage: cel-fanout recover inspect <repo> <branch> --pane <pane> [--workspace NAME]"
  local repo="$1" branch="$2"; shift 2
  local ws_opt="" pane=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws_opt="$2"; shift 2 ;;
      --pane)      pane="$2"; shift 2 ;;
      *) die "recover inspect: unknown argument: $1" ;;
    esac
  done
  [ -n "$pane" ] || die "recover inspect: --pane is required"
  local wsdir; wsdir="$(_fanout_wsdir "$ws_opt")"
  local alias; alias="$(_run_agent_name "$repo/$branch")"
  _rec_observe "$pane" "$alias"
  local gen="[]" pid
  for pid in $(printf '%s' "$REC_JSON" | jq -r '.fg_pids[]?'); do
    gen="$(printf '%s' "$gen" | jq -c --argjson pid "$pid" --arg st "$(_rec_stat_field "$pid" start)" --arg pp "$(_rec_stat_field "$pid" ppid)" \
      '. + [{pid:$pid, ppid:($pp|tonumber? // null), start:$st}]')"
  done
  local row; row="$(_ledger_entry "$wsdir" "$branch")"
  local active=false; _rec_original_active "$branch" "$alias" >/dev/null && active=true
  local sess exists=false
  sess="$(printf '%s' "$REC_JSON" | jq -r '.agent.agent_session.value // ""')"
  [ -z "$sess" ] || [ ! -e "$sess" ] || exists=true
  printf '%s' "$REC_JSON" | jq --argjson gen "$gen" --argjson row "${row:-null}" --argjson active "$active" --argjson sx "$exists" \
    '{pane_ok, terminal, shell_pid, foreground:$gen,
      agent: (if .agent then {name:.agent.name, kind:.agent.agent, status:.agent.agent_status,
        launch_pending:(.agent.launch_pending // false), interactive_ready:(.agent.interactive_ready // false)} else null end),
      session_file_exists:$sx, original_operation_active:$active,
      ledger_row: (if $row then {state:$row.state, recovery_phase:($row.recovery.dispatch.phase // null)} else "absent" end),
      note: "read-only; the session path is not proof of anything and is not recorded as such"}'
}

# --- register ---------------------------------------------------------------

# Every refusal is before any write: validation collects nothing durable.
cmd_recover_register() {
  [ $# -ge 3 ] || die "usage: cel-fanout recover register <repo> <branch> <spec-file> --profile NAME --pane PANE --shell-pid N --agent-pid N --agent-start TICKS --evidence TEXT --attest-legacy [--workspace NAME] [--adhoc]"
  local repo="$1" branch="$2" spec="$3"; shift 3
  local ws_opt="" profile="" pane="" shell_pid="" agent_pid="" agent_start="" evidence="" attest=0 adhoc=0 shape=ship
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace)    ws_opt="$2"; shift 2 ;;
      --profile)      profile="$2"; shift 2 ;;
      --pane)         pane="$2"; shift 2 ;;
      --shell-pid)    shell_pid="$2"; shift 2 ;;
      --agent-pid)    agent_pid="$2"; shift 2 ;;
      --agent-start)  agent_start="$2"; shift 2 ;;
      --evidence)     evidence="$2"; shift 2 ;;
      --attest-legacy) attest=1; shift ;;
      --adhoc)        adhoc=1; shift ;;
      --shape)        shape="$2"; shift 2 ;;
      *) die "recover register: unknown argument: $1" ;;
    esac
  done
  local m
  for m in profile pane shell_pid agent_pid agent_start evidence; do
    [ -n "${!m}" ] || die "recover register: --${m//_/-} is required (an explicit original coordinate and expected process identity; nothing is guessed)"
  done
  [ "$attest" -eq 1 ] || die "recover register: --attest-legacy is required - this records a legacy recovery whose original facts are observed and operator-attested, not proven"
  case "$shape" in ship|scout|spike) ;; *) die "recover register: --shape must be ship, scout or spike" ;; esac
  case "$shape" in scout|spike) adhoc=1 ;; esac
  case "$pane" in *[!A-Za-z0-9:_-]*|"") die "recover register: --pane is not a herdr pane id" ;; esac
  case "$shell_pid$agent_pid$agent_start" in *[!0-9]*) die "recover register: --shell-pid, --agent-pid and --agent-start must be numbers" ;; esac
  case "$evidence" in *$'\n'*) die "recover register: --evidence is one line" ;; esac
  [ "${#evidence}" -le 400 ] || die "recover register: --evidence is at most 400 characters (state the facts, never credentials)"

  local wsdir; wsdir="$(_fanout_wsdir "$ws_opt")"
  local repodir="$wsdir/repos/$repo"
  [ -d "$repodir" ] || die "recover register: repo '$repo' not found under $wsdir/repos"
  [ -f "$spec" ] || die "recover register: spec file not found: $spec"
  local abs_spec; abs_spec="$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")"
  local alias; alias="$(_run_agent_name "$repo/$branch")"
  local ws; ws="$(ws_name "$wsdir")"
  # THE STABLE RECOVERY IDENTITY: the same coordinate always yields the same id,
  # so a retried register (lost response, crash) is recognised, never doubled.
  local rid
  rid="$(printf '%s\n' "$ws" "$repo" "$branch" "$pane" "$shell_pid" "$agent_pid" "$agent_start" "$abs_spec" "$profile" | sha256sum | cut -c1-16)"

  # 1. the ledger, under the lock the entrypoint already holds
  local cur; cur="$(_ledger_entry "$wsdir" "$branch")"
  if [ -n "$cur" ]; then
    if [ "$(printf '%s' "$cur" | jq -r '.recovery.id // ""')" = "$rid" ]; then
      c_ok "$branch: already registered as recovery $rid (phase $(printf '%s' "$cur" | jq -r '.recovery.dispatch.phase // "registered"')) - nothing changed"
      printf '%s\n' "$branch"
      return 0
    fi
    die "recover register: the ledger already has a row for '$branch' (state $(printf '%s' "$cur" | jq -r '.state')) that is not this recovery - refusing; nothing changed"
  fi
  local clash
  clash="$(_ledger_read "$wsdir" | jq -r --arg a "$alias" --arg p "$pane" \
    '[.[] | select((.alias == $a or .pane == $p) and (.state | IN("running","unconfirmed","finished")))] | .[0].id // empty')"
  [ -z "$clash" ] || die "recover register: row '$clash' already holds this alias or pane - refusing a duplicate; nothing changed"

  # 2. the original operation must be over
  local live
  if live="$(_rec_original_active "$branch" "$alias")"; then
    die "recover register: the original launch may still complete (process: $live) - refusing while it runs; nothing changed"
  fi

  # 3. profile: what the worker was meant to be
  local rt model thinking
  rt="$(ws_runtime "$wsdir" worker)"; thinking="$(ws_thinking "$wsdir")"
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_ISOLATE="" PROFILE_VETO="" PROFILE_VIA=""
  profile_resolve "$wsdir" "$profile" "$rt"
  [ -z "$PROFILE_VETO" ] || die "recover register: profile '$profile' is vetoed - $PROFILE_VETO"
  rt="$PROFILE_RUNTIME"; thinking="$PROFILE_THINKING"; model="${PROFILE_MODEL:-}"
  [ -n "$model" ] || die "recover register: profile '$profile' names no model, so the running agent's model cannot be attested - refusing"

  # 4. the live pane, shell and agent
  _rec_observe "$pane" "$alias"
  local j="$REC_JSON"
  printf '%s' "$j" | jq -e '.pane_ok' >/dev/null || die "recover register: herdr's pane answers do not name $pane - refusing; nothing changed"
  [ "$(printf '%s' "$j" | jq -r '.shell_pid')" = "$shell_pid" ] || die "recover register: the pane's shell is not pid $shell_pid (identity changed) - refusing; nothing changed"
  printf '%s' "$j" | jq -e --argjson a "$agent_pid" '.fg_pids | index($a) != null' >/dev/null \
    || die "recover register: pid $agent_pid is not in the pane's foreground (identity changed) - refusing; nothing changed"
  [ "$(printf '%s' "$j" | jq -r '.agents_in_pane')" = 1 ] && [ "$(printf '%s' "$j" | jq -r '.agents_named')" = 1 ] \
    || die "recover register: herdr does not show exactly one agent named '$alias' in $pane - refusing as ambiguous; nothing changed"
  [ "$(printf '%s' "$j" | jq -r '.agent.name // ""')" = "$alias" ] || die "recover register: the agent in $pane is not named '$alias' (a colleague's pane?) - refusing; nothing changed"
  [ "$(printf '%s' "$j" | jq -r '.agent.agent // ""')" = "$rt" ] || die "recover register: the agent in $pane is a '$(printf '%s' "$j" | jq -r '.agent.agent // "?"')', profile '$profile' is runtime '$rt' - wrong profile; refusing, nothing changed"
  local st; st="$(printf '%s' "$j" | jq -r '.agent.agent_status // ""')"
  [ "$st" = idle ] || die "recover register: herdr reports the agent '$st', not idle - a task may be active; refusing, nothing changed"
  printf '%s' "$j" | jq -e '.agent.launch_pending == true' >/dev/null \
    || die "recover register: herdr does not report a pending launch for $alias - this verb recovers only a worker whose launch herdr still shows as unconfirmed; a started worker of unknown history is not adopted"

  # no task may already have run: the pane must be unstarted (a turn already on
  # screen would later be mistaken for evidence of OUR task)
  _rec_pane_unstarted "$alias" || die "recover register: the agent's pane is not provably unstarted (unreadable, a turn already on screen, or context above zero) - refusing; nothing changed"

  # the process: same generation, same parent, the workspace's own environment
  [ "$(_rec_stat_field "$agent_pid" start)" = "$agent_start" ] || die "recover register: pid $agent_pid has a different start generation than --agent-start $agent_start (pid reused or restarted) - refusing; nothing changed"
  [ "$(_rec_stat_field "$agent_pid" ppid)" = "$shell_pid" ] || die "recover register: pid $agent_pid is not a child of shell $shell_pid - refusing; nothing changed"
  [ "$(_rec_env_get "$agent_pid" CEL_ROLE)" = worker ] || die "recover register: the agent's environment does not carry CEL_ROLE=worker - refusing; nothing changed"
  [ "$(_rec_env_get "$agent_pid" CEL_WORKSPACE)" = "$wsdir" ] || die "recover register: the agent belongs to another workspace (CEL_WORKSPACE differs) - refusing; nothing changed"
  if [ -n "$(agent_inbox_hook "$rt" file)" ]; then
    # the FULL canonical identity: a truncated or re-normalised mailbox would
    # be a phantom nobody reads
    [ "$(_rec_env_get "$agent_pid" CEL_INBOX_ME)" = "$alias" ] \
      || die "recover register: the agent's inbox identity is not the canonical '$alias' - refusing; nothing changed"
  fi
  _rec_cmdline_model_is "$agent_pid" "$model" || die "recover register: the agent was not launched with exactly model '$model' (profile '$profile') - wrong model/profile; refusing, nothing changed"
  local -a PROFILE_ARGS=()
  profile_launch_args "$rt" "$model" "$thinking" "${PROFILE_ISOLATE:-}"
  if [ "${#PROFILE_ARGS[@]}" -gt 0 ]; then
    _rec_cmdline_has_args "$agent_pid" "${PROFILE_ARGS[@]}" \
      || die "recover register: the agent's launch arguments do not carry the profile's model and thinking level - wrong model/profile; refusing, nothing changed"
  fi

  # the worktree: where, on which branch, at what head
  local wt
  wt="$(git -C "$repodir" worktree list --porcelain 2>/dev/null \
    | awk -v b="refs/heads/$branch" '/^worktree /{p=substr($0,10)} /^branch /{if (substr($0,8)==b) {print p; exit}}')"
  [ -n "$wt" ] && [ -d "$wt" ] || die "recover register: no worktree for branch '$branch' in $repo - refusing; nothing changed"
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$branch" ] || die "recover register: $wt is not on branch '$branch' - refusing; nothing changed"
  local head; head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "recover register: cannot read the worktree head - refusing"
  local ews
  ews="$("$HERDR" workspace list 2>/dev/null | jq -r --arg p "$wt" '[.result.workspaces[] | select(.worktree.checkout_path == $p)][0].workspace_id // empty')"
  [ -n "$ews" ] && [ "${pane%%:*}" = "$ews" ] && [ "$(printf '%s' "$j" | jq -r '.agent.workspace_id // ""')" = "$ews" ] \
    || die "recover register: pane $pane is not in the herdr workspace of $wt - refusing; nothing changed"

  local ticket=""
  if [ "$(ws_ticket "$wsdir" system)" = linear ]; then
    ticket="$(_fanout_ticket_id "$wsdir" "$repo" "$branch")"
    [ -n "$ticket" ] || [ "$adhoc" -eq 1 ] || die "recover register: branch '$branch' names no ticket (pass --adhoc to skip deliberately)"
  fi
  local sess exists=false
  sess="$(printf '%s' "$j" | jq -r '.agent.agent_session.value // ""')"
  [ -z "$sess" ] || [ ! -e "$sess" ] || exists=true

  # 5. ONE atomic write, state `unconfirmed`: no task is claimed running.
  local entry
  entry="$(jq -n \
    --arg id "$branch" --arg repo "$repo" --arg branch "$branch" --arg alias "$alias" \
    --arg herdr_ws "$ews" --arg pane "$pane" --arg worktree "$wt" --arg spec "$abs_spec" \
    --arg now "$(_now_iso)" --arg profile "$profile" --arg runtime "$rt" --arg model "$model" \
    --arg thinking "$thinking" --arg ticket "$ticket" --arg provider "$(profile_provider "$model")" \
    --arg shape "$shape" --arg rid "$rid" --arg evidence "$evidence" --arg head "$head" \
    --arg term "$(printf '%s' "$j" | jq -r '.terminal')" --argjson shell "$shell_pid" \
    --argjson apid "$agent_pid" --arg astart "$agent_start" \
    --argjson ready "$(printf '%s' "$j" | jq '.agent.interactive_ready // false')" \
    --argjson sx "$exists" \
    '{id:$id, repo:$repo, branch:$branch, alias:$alias, herdr_ws:$herdr_ws, pane:$pane,
      worktree:$worktree, spec:$spec, state:"unconfirmed", created:$now,
      profile:$profile, runtime:$runtime, model:$model, thinking:$thinking, ticket:$ticket,
      provider:$provider, shape:$shape, profile_reason:"legacy recovery of an existing launch",
      launch:{phase:"recovered", at:$now},
      recovery:{id:$rid, provenance:"legacy-operator-attested", registered_at:$now, evidence:$evidence,
        observed:{terminal:$term, shell_pid:$shell, agent_pid:$apid, agent_start:$astart, head:$head,
                  herdr_status:"idle", launch_pending:true, interactive_ready:$ready,
                  session:(if $sx then "file-present-unverified" else "unknown" end)},
        unproven:["original_start_time","task_delivery","model_and_tool_success","session_file","approval","head_source"],
        dispatch:{phase:"registered"}}}')"
  _ledger_append "$wsdir" "$entry"
  _rec_crash_point after-register
  c_ok "$branch: registered as recovery $rid - state unconfirmed, no task delivered, nothing started. Continue with: cel-fanout recover continue $branch --workspace $ws"
  printf '%s\n' "$branch"
}

# --- continue ---------------------------------------------------------------

# Strict acceptance evidence: a readable pane that shows the agent took a turn.
# Unlike a normal dispatch, an unreadable pane is NOT evidence here: In
# Progress is claimed only from something actually seen.
_rec_accepted() { # <alias> <tries>
  local alias="$1" tries="${2:-5}" i text
  for (( i = 0; i < tries; i++ )); do
    [ "$i" -eq 0 ] || sleep "${CEL_FANOUT_CONFIRM_SLEEP:-2}"
    text="$("$HERDR" agent read "$alias" --source recent-unwrapped --lines 40 2>/dev/null || true)"
    [ -n "$text" ] || continue
    _liveness_has_turn "$text" && [ "$(liveness_pane_silence "$text")" != unstarted ] && return 0
  done
  return 1
}

# Provably unstarted: readable text, context at zero, no assistant turn.
_rec_pane_unstarted() { # <alias>
  local text; text="$("$HERDR" agent read "$1" --source recent-unwrapped --lines 40 2>/dev/null || true)"
  [ -n "$text" ] || return 1
  _liveness_has_turn "$text" && return 1
  _liveness_context_zero "$text"
}

_rec_set_phase() { # <wsdir> <id> <phase> [note]
  _ledger_patch "$1" "$2" '.recovery.dispatch = ((.recovery.dispatch // {}) + {phase:$ph, at:$at, note:$note})' \
    --arg ph "$3" --arg at "$(_now_iso)" --arg note "${4:-}"
}

_rec_mark_accepted() { # <wsdir> <id> <ticket> <shape>
  _rec_set_phase "$1" "$2" accepted "task evidence seen in the agent's pane"
  _ledger_patch "$1" "$2" '.launch = {phase:"dispatched", at:$at}' --arg at "$(_now_iso)"
  _ledger_update_state "$1" "$2" running
  [ "$4" != ship ] || _fanout_ticket_state "$3" "In Progress"
}

cmd_recover_continue() { # <id> [--workspace NAME]
  [ $# -ge 1 ] || die "usage: cel-fanout recover continue <id> [--workspace NAME]"
  local id="$1"; shift
  local ws_opt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws_opt="$2"; shift 2 ;;
      *) die "recover continue: unknown argument: $1" ;;
    esac
  done
  local wsdir; wsdir="$(_fanout_wsdir "$ws_opt")"
  local row; row="$(_ledger_entry "$wsdir" "$id")"
  [ -n "$row" ] || die "recover continue: no delegation with id '$id'"
  [ -n "$(printf '%s' "$row" | jq -r '.recovery.id // ""')" ] || die "recover continue: '$id' is not a recovered launch (it has no recovery record) - nothing changed"
  local phase alias pane wt repo branch shape ticket
  phase="$(printf '%s' "$row" | jq -r '.recovery.dispatch.phase // "registered"')"
  alias="$(printf '%s' "$row" | jq -r '.alias')"; pane="$(printf '%s' "$row" | jq -r '.pane')"
  wt="$(printf '%s' "$row" | jq -r '.worktree')"; repo="$(printf '%s' "$row" | jq -r '.repo')"
  branch="$(printf '%s' "$row" | jq -r '.branch')"; shape="$(printf '%s' "$row" | jq -r '.shape // "ship"')"
  ticket="$(printf '%s' "$row" | jq -r '.ticket // ""')"
  local tries="${CEL_FANOUT_CONFIRM_TRIES:-5}"

  case "$phase" in
    accepted)
      c_ok "$id: the task was already accepted - nothing sent"; return 0 ;;
    submitting|ambiguous|unconfirmed-acceptance)
      # A prompt MAY have been delivered. Never resubmit: only look, once.
      local seen=0
      _ledger_unlock                      # no lock across the bounded evidence wait
      _rec_accepted "$alias" "$tries" && seen=1
      _ledger_relock
      if [ "$seen" -eq 1 ]; then
        _rec_mark_accepted "$wsdir" "$id" "$ticket" "$shape"
        c_ok "$id: task evidence seen - accepted and recorded running; nothing was sent now"
        return 0
      fi
      _rec_set_phase "$wsdir" "$id" unconfirmed-acceptance "no task evidence yet; kept for the operator, never resubmitted"
      die "recover continue: $id: a task may or may not have been delivered (phase was $phase) and no execution evidence is visible yet. NOT resubmitting - that could pay for the work twice. The row stays 'unconfirmed' with its evidence; look at pane $pane and run this again to re-check"
      ;;
    registered) ;;
    *) die "recover continue: $id: unknown recovery phase '$phase' - nothing changed" ;;
  esac

  # --- phase registered: revalidate EVERYTHING against the record, then submit once
  local o; o="$(printf '%s' "$row" | jq -c '.recovery.observed')"
  _rec_observe "$pane" "$alias"
  local j="$REC_JSON"
  printf '%s' "$j" | jq -e --argjson o "$o" --arg alias "$alias" '
      .pane_ok and .terminal == $o.terminal and .shell_pid == $o.shell_pid
      and (.fg_pids | index($o.agent_pid) != null) and .agents_in_pane == 1 and .agents_named == 1
      and (.agent.name == $alias)' >/dev/null \
    || die "recover continue: $id: the pane, shell or agent is no longer the one that was registered - refusing; nothing sent"
  [ "$(_rec_stat_field "$(printf '%s' "$o" | jq -r '.agent_pid')" start)" = "$(printf '%s' "$o" | jq -r '.agent_start')" ] \
    || die "recover continue: $id: the agent process generation changed - refusing; nothing sent"
  [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$(printf '%s' "$o" | jq -r '.head')" ] \
    || die "recover continue: $id: the worktree head moved since registration - refusing; nothing sent"
  [ "$(printf '%s' "$j" | jq -r '.agent.agent_status // ""')" = idle ] \
    || die "recover continue: $id: herdr does not report the agent idle - refusing; nothing sent"
  if printf '%s' "$j" | jq -e '(.agent.launch_pending == true) or ((.agent.interactive_ready // false) != true)' >/dev/null; then
    die "recover continue: $id: herdr 0.9.1 still reports this agent launch_pending / not interactive_ready. No SUPPORTED completer was found in its exposed surfaces (agent.start/prompt/wait/explain/rename, pane.report_agent/report_agent_session/clear_agent_authority/release_agent) - that is what the installed binary shows, not proof the capability cannot exist; the only things that would change pending (report-agent, release-agent, Enter) are forbidden. UPSTREAM PREREQUISITE: (1) a diagnostic reason why the launch is pending, (2) a supported way to complete it or mark the agent ready with no keystrokes or metadata forgery, (3) prompt-delivery receipt semantics. THIS WORKER IS NOT RESUMED: the row is registered and unchanged, nothing was sent, no task is claimed"
  fi

  _rec_pane_unstarted "$alias" || die "recover continue: $id: the pane is no longer provably unstarted (a turn or context is already on screen) - an execution there could not be told from ours; refusing, nothing sent"

  local product orch_mailbox ws_sel check_base prompt
  product="$(ws_product_of_repo "$wsdir" "$repo")"
  orch_mailbox="$(_run_agent_name "$product-orch")"
  ws_sel="$(printf '%q' "$(ws_name "$wsdir")")"
  check_base="$(repo_default_ref "$wt" 2>/dev/null || true)"; [ -n "$check_base" ] || check_base="origin/main"
  prompt="$(_fanout_worker_prompt "$wsdir" "$shape" "$repo" "$branch" "$(printf '%s' "$row" | jq -r '.spec')" "" "$check_base" "$orch_mailbox" "$ws_sel")"

  # RECORD THE ATTEMPT BEFORE MAKING IT, durably: a crash after the prompt and
  # before the acknowledgement leaves `submitting`, which is read as "may have
  # been delivered" and is never resubmitted.
  _ledger_patch "$wsdir" "$id" '.recovery.dispatch = {phase:"submitting", attempt:1, at:$at, prompt_sha:$sha}' \
    --arg at "$(_now_iso)" --arg sha "$(printf '%s' "$prompt" | sha256sum | cut -c1-16)"
  _rec_crash_point before-prompt
  # no lock across the prompt and the wait for evidence
  _ledger_unlock
  local err rc=0
  err="$("$HERDR" agent prompt "$alias" "$prompt" 2>&1)" || rc=$?
  _rec_crash_point after-prompt
  if [ "$rc" -ne 0 ]; then
    _ledger_relock
    case "$err" in
      *agent_not_ready*|*agent_launch_pending*|*empty_agent_prompt*|*agent_not_running*|*agent_blocked*|*agent_name_not_found*)
        # herdr says in its own words that nothing was delivered
        _rec_set_phase "$wsdir" "$id" registered "herdr refused the prompt (nothing delivered): $(printf '%s' "$err" | head -1 | cut -c1-120)"
        die "recover continue: $id: herdr refused the prompt - nothing was delivered, the row is back to 'registered' and may be continued again once the agent is ready" ;;
      *)
        _rec_set_phase "$wsdir" "$id" ambiguous "herdr prompt returned an error with unknown delivery: $(printf '%s' "$err" | head -1 | cut -c1-120)"
        die "recover continue: $id: herdr's prompt call failed in a way that does not say whether the text arrived - marked ambiguous, NOT resubmitted; re-check with: cel-fanout recover continue $id" ;;
    esac
  fi
  local ok=0
  _rec_accepted "$alias" "$tries" && ok=1
  _ledger_relock
  # the world may have moved while unlocked: re-read before writing
  if [ "$ok" -eq 1 ]; then
    _rec_mark_accepted "$wsdir" "$id" "$ticket" "$shape"
    c_ok "$id: task delivered once and execution evidence seen - recorded running"
    return 0
  fi
  _rec_set_phase "$wsdir" "$id" unconfirmed-acceptance "prompt submitted once; no execution evidence yet"
  die "recover continue: $id: the task was submitted once but no execution evidence is visible yet. The row stays 'unconfirmed' (phase unconfirmed-acceptance); it is NOT resubmitted. Re-check with: cel-fanout recover continue $id"
}

# --- the consumers' view ----------------------------------------------------

# A launch that may hold a LIVE agent and is not settled: a recovered row whose
# dispatch is not accepted, or a delegate's receipt row still at starting /
# start-failed / started. Only rows still `unconfirmed` (or `running`) count -
# once an operator has abandoned or landed a row nothing here fences it, and
# `recover abandon` is the way out. Prints why, nothing when settled.
_rec_unresolved() { # <row-json>
  [ -n "$1" ] || return 0
  # launch debt fences EVERY state except the ones an operator or the factory has
  # already closed: a failed `delegate --reuse` leaves a finished/collected row
  # with launch.phase start-failed, and that row must not bypass the fence.
  printf '%s' "$1" | jq -r '(.state // "") as $st
    | if ($st | IN("abandoned","landed","released")) then empty
      elif ((.launch.phase // "") | IN("starting","start-failed","started")) then ("launch " + .launch.phase)
      elif .recovery != null and ($st | IN("unconfirmed","running")) then ((.recovery.dispatch.phase // "registered") | select(. != "accepted"))
      else empty end'
}
_rec_guard() { # <verb> <id> <row-json>
  local why; why="$(_rec_unresolved "$3")"
  if [ -z "$why" ] && [ "$(printf '%s' "$3" | jq -r '.replacement.role // ""')" = child ] && [ -n "${wsdir:-}" ]; then
    # a replacement child shares its source's worker and worktree: it cannot be
    # collected, released or landed out from under the source's unsettled launch
    local src_id src; src_id="$(printf '%s' "$3" | jq -r '.replacement.of // ""')"
    src="$(_ledger_entry "$wsdir" "$src_id" 2>/dev/null || true)"
    if [ -n "$src" ] && [ -n "$(_rec_unresolved "$src")" ]; then
      die "$1: $2 is a replacement whose source $src_id holds an UNSETTLED launch ($(_rec_unresolved "$src")) - the same worker and worktree may still be live. Nothing was changed; the worktree is untouched. The source must be settled first (see cel-fanout recover continue/abandon $src_id)"
    fi
  fi
  [ -n "$why" ] || return 0
  # What the operator can honestly do depends on whether `recover abandon`
  # would accept this row (definitive not-accepted only), so say which.
  local ph lph hint
  ph="$(printf '%s' "$3" | jq -r '.recovery.dispatch.phase // ""')"; lph="$(printf '%s' "$3" | jq -r '.launch.phase // ""')"
  if { [ -n "$ph" ] && [ "$ph" = registered ]; } || { [ -z "$ph" ] && [ "$lph" = start-failed ]; }; then
    hint="No task was ever submitted for it, so after you have looked at the pane: cel-fanout recover abandon $2 --reason '<what you found>' (it re-reads the pane and refuses unless it is provably unstarted)"
  elif [ -n "$ph" ]; then
    hint="A task may have been delivered. cel-fanout recover continue $2 only LOOKS for task evidence (never resubmits); abandon is refused for this phase"
  else
    hint="This is RETAINED UNCERTAIN DEBT with NO supported exit: the launch was interrupted at '$lph', so an agent may exist and a task may have been queued, and neither the absence of an agent nor an operator note proves otherwise (recover abandon refuses it, recover continue only handles registered recoveries). It stays until herdr provides a supported receipt for the start/dispatch, or the owner decides it by hand outside this tool"
  fi
  die "$1: $2 holds an UNSETTLED launch ($why) - a live agent may be in its pane and no task is proven. Nothing was changed; the worktree is untouched. $hint"
}

# The bounded way out for a row that must not be continued: records the
# operator's decision and the evidence, moves the row to `abandoned`, and
# touches nothing else - the agent, pane and worktree are left exactly as found.
cmd_recover_abandon() { # <id> --reason TEXT [--workspace NAME]
  [ $# -ge 1 ] || die "usage: cel-fanout recover abandon <id> --reason TEXT [--workspace NAME]"
  local id="$1"; shift
  local ws_opt="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws_opt="$2"; shift 2 ;;
      --reason)    reason="$2"; shift 2 ;;
      *) die "recover abandon: unknown argument: $1" ;;
    esac
  done
  [ -n "$reason" ] || die "recover abandon: --reason is required - say what you found"
  [ "${#reason}" -le 400 ] || die "recover abandon: --reason is at most 400 characters"
  local wsdir; wsdir="$(_fanout_wsdir "$ws_opt")"
  local row; row="$(_ledger_entry "$wsdir" "$id")"
  [ -n "$row" ] || die "recover abandon: no delegation with id '$id'"
  local st ph lph pane alias
  st="$(printf '%s' "$row" | jq -r '.state // ""')"
  ph="$(printf '%s' "$row" | jq -r '.recovery.dispatch.phase // ""')"; lph="$(printf '%s' "$row" | jq -r '.launch.phase // ""')"
  pane="$(printf '%s' "$row" | jq -r '.pane // ""')"; alias="$(printf '%s' "$row" | jq -r '.alias // ""')"
  # ONLY A DEFINITIVE "NO TASK WAS EVER SUBMITTED" MAY BE ABANDONED, and even
  # then only against fresh evidence. Definitive: a recovery row at `registered`
  # (no prompt attempt recorded) or a delegate launch at `start-failed` (the
  # start never completed, so no dispatch followed). NEVER definitive: launch
  # starting/started (the agent may exist and the process died anywhere after),
  # dispatch-unconfirmed, and recovery submitting/ambiguous/unconfirmed-acceptance
  # (a prompt MAY have been delivered). Those stay fenced, unknown, until
  # `recover continue` sees task evidence.
  local definitive=0
  if [ -n "$ph" ]; then [ "$ph" = registered ] && [ -z "$lph" -o "$lph" = recovered ] && definitive=1
  else [ "$lph" = start-failed ] && definitive=1; fi
  [ "$definitive" -eq 1 ] || die "recover abandon: $id is not DEFINITIVELY not-accepted (recovery phase '${ph:-none}', launch '${lph:-none}', state $st): a task may have been delivered or an agent may exist and be running. Not abandoned - the row and its evidence stay fenced and the outcome stays unknown. Look at the pane and run: cel-fanout recover continue $id (it only looks, never resubmits)"
  # FRESH EVIDENCE, now: the pane must be readable and show no turn and context
  # zero. The operator's --reason is a note, not evidence.
  [ -n "$pane" ] && [ -n "$alias" ] || die "recover abandon: $id names no pane or alias to check - not abandoned"
  _rec_pane_unstarted "$alias" || die "recover abandon: the agent's pane is not provably unstarted right now (unreadable, a turn on screen, or context above zero) - a task may be running. Not abandoned; the outcome stays unknown and the row stays fenced"
  _ledger_patch "$wsdir" "$id" '.abandon = {reason:$r, at:$at, prior_state:.state, prior_recovery_phase:(.recovery.dispatch.phase // null), prior_launch_phase:(.launch.phase // null)}
    | if .recovery != null then .recovery.dispatch = ((.recovery.dispatch // {}) + {phase:"abandoned", at:$at, note:$r}) else . end' \
    --arg r "$reason" --arg at "$(_now_iso)"
  _ledger_update_state "$wsdir" "$id" abandoned
  c_ok "$id: recorded abandoned (evidence kept in .abandon / .recovery). The agent, pane and worktree were NOT touched - release them yourself when you have looked"
}

cmd_recover() {
  local sub="${1:-}"; [ $# -eq 0 ] || shift
  case "$sub" in
    inspect)  cmd_recover_inspect "$@" ;;
    register) cmd_recover_register "$@" ;;
    continue) cmd_recover_continue "$@" ;;
    abandon)  cmd_recover_abandon "$@" ;;
    *) die "usage: cel-fanout recover inspect|register|continue|abandon ..." ;;
  esac
}
