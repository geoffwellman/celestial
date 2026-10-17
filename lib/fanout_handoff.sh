# shellcheck shell=bash
# `cel-fanout handoff` (CEL-retained-runtime-handoff-261018): move a RETAINED
# worktree's execution to ONE replacement runtime on a named profile, as an
# admitted, replayable state transition - never a printed manual recipe.
#
# Sourced by cel-fanout, which supplies the ledger primitives (_ledger_*),
# $HERDR and the workspace helpers, and by lib/fanout_recover.sh's helpers
# (_rec_observe, _rec_proc, _rec_stat_field, _rec_env_get, _rec_cmdline_*,
# _rec_accepted, _rec_pane_unstarted, _rec_crash_point). This file only defines
# functions.
#
#   handoff inspect <id> --pane P [--profile NAME]        read-only plan + refusals
#   handoff apply   <id> --profile NAME --pane P --shell-pid N --agent-pid N
#                        --agent-start TICKS --head SHA --source-digest HEX
#                        --evidence TEXT [--reissue-retire]
#   handoff status  <id|opid>                             the operation and its next action
#   handoff hold    <id> --kind launch-unknown --evidence TEXT
#
# WHAT IT GUARANTEES
#   - Inspect writes nothing. Apply re-reads EVERYTHING immediately before the
#     first mutation and refuses with zero mutation on a stale snapshot, a busy
#     or non-quiescent agent, a changed identity, a live child or listener, an
#     unsettled launch, a competing operation, or a missing herdr primitive.
#   - The operation is ADMITTED (durable record + ledger mark + per-target
#     lock) before the old runtime is retired, and every later step records its
#     phase BEFORE the call it describes. A lost response or replay finds the
#     same operation by its stable id and continues from its phase: it never
#     retires twice, starts twice or prompts twice.
#   - Retirement is `herdr agent stop <alias>`, ONLY when the installed herdr's
#     API schema lists `agent.stop`. herdr 0.9.1 does not (see README): there the
#     answer is a refusal naming the exact missing call, never a raw kill, a
#     keypress, `pane close` (which takes the shell and every child with it), an
#     alias rename or a ledger edit.
#   - The source is never touched: no reset, stash, checkout, rebase, fetch or
#     push. Source evidence (HEAD, remote classification, dirty and untracked
#     bytes) is bound into the operation id and re-verified byte for byte.
#   - Cross-harness is NOT lossless native resume. The replacement starts a fresh
#     session and is given the spec, a handoff brief and a copy of the old pane
#     text; the old session path/digest is kept as evidence. Same-harness native
#     session resume is not performed by this verb either, and is said so.
[ -n "${_CEL_FANOUT_HANDOFF:-}" ] && return 0
_CEL_FANOUT_HANDOFF=1

_ho_dir()  { printf '%s/.cel/handoffs' "$1"; }
_ho_file() { printf '%s/%s.json' "$(_ho_dir "$1")" "$2"; }

_ho_write() { # <wsdir> <opid> <json>  (atomic)
  local d f tmp; d="$(_ho_dir "$1")"; f="$(_ho_file "$1" "$2")"
  mkdir -p "$d" || return 1
  tmp="$(mktemp "$f.tmp.XXXXXX")" || return 1
  if printf '%s' "$3" | jq -ce 'if type == "object" then . else error("bad op") end' > "$tmp"; then
    mv -f -- "$tmp" "$f"
  else rm -f -- "$tmp"; return 1; fi
}
_ho_read() { local f; f="$(_ho_file "$1" "$2")"; [ -f "$f" ] && jq -c . "$f" || true; }

# The phase a step is ABOUT to attempt (or just finished) goes to the operation
# record AND the ledger row, so every existing consumer sees the debt.
_ho_phase() { # <wsdir> <opid> <row-id> <phase> <note> [extra-jq-object]
  local wsdir="$1" opid="$2" id="$3" ph="$4" note="$5" extra="${6:-}" op at
  [ -n "$extra" ] || extra='{}'
  at="$(_now_iso)"
  op="$(_ho_read "$wsdir" "$opid")"
  [ -n "$op" ] || die "handoff: operation $opid has no record - refusing to continue blind"
  _ho_write "$wsdir" "$opid" "$(printf '%s' "$op" | jq -c --arg ph "$ph" --arg at "$at" --arg note "$note" --argjson x "$extra" \
    '. + $x + {phase:$ph, phases:((.phases // []) + [{phase:$ph, at:$at, note:$note}])}')" \
    || die "handoff: could not write the operation record - nothing further was attempted"
  _ledger_patch "$wsdir" "$id" '.handoff = ((.handoff // {}) + {id:$op, phase:$ph, at:$at, note:$note})' \
    --arg op "$opid" --arg ph "$ph" --arg at "$at" --arg note "$note"
}

# an operation for this ledger id that is not finished
_ho_pending_other() { # <wsdir> <id> <own-opid> -> prints opid, returns 0 if one exists
  local d f o
  d="$(_ho_dir "$1")"; [ -d "$d" ] || return 1
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    o="$(jq -r --arg id "$2" --arg own "$3" 'select(.row_id == $id and .opid != $own and .phase != "done") | .opid' "$f" 2>/dev/null || true)"
    [ -z "$o" ] || { printf '%s' "$o"; return 0; }
  done
  return 1
}

# THE PER-TARGET LOCK is a directory owned by pid + process start generation,
# NOT a file descriptor: an fd would be inherited by every herdr child (and by
# anything that daemonised), and a leaked inherited fd holds the lock for ever.
# A holder that is dead, or whose pid was reused (different start generation),
# is stale and is taken over; a live holder is never. Released at exit.
HO_LOCK_DIR=""; HO_LOCK_HOLDER=""
_ho_real_start() { sed -E 's/^.*\) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
_ho_lock_acquire() { # <wsdir> <id>
  local d owner pid start cur
  d="$(_ho_dir "$1")/$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_').lock.d"
  mkdir -p "$(_ho_dir "$1")"
  if mkdir "$d" 2>/dev/null; then :
  else
    owner="$(cat "$d/owner" 2>/dev/null || true)"; pid="${owner%% *}"; start="${owner#* }"
    case "$pid" in ''|*[!0-9]*) pid="" ;; esac
    if [ -n "$pid" ] && [ "$(_ho_real_start "$pid")" = "$start" ] && [ -n "$start" ]; then HO_LOCK_HOLDER="$pid"; return 1; fi
    rm -rf "$d"; mkdir "$d" 2>/dev/null || { HO_LOCK_HOLDER="unknown"; return 1; }
  fi
  printf '%s %s' "$$" "$(_ho_real_start "$$")" > "$d/owner"
  HO_LOCK_DIR="$d"
  trap '_ho_lock_release' EXIT
  return 0
}
_ho_lock_release() { [ -z "$HO_LOCK_DIR" ] || { [ "$(cut -d' ' -f1 "$HO_LOCK_DIR/owner" 2>/dev/null)" != "$$" ] || rm -rf "$HO_LOCK_DIR"; }; }

# --- observation helpers (read-only) ---------------------------------------

# Everything under <pid> in the process table. /proc is a fixture root only
# under CEL_TESTING (see _rec_proc).
_ho_descendants() { # <pid> -> one pid per line
  local proc d pid stat rest p changed=1 root="$1"
  proc="$(_rec_proc)"
  local -A pp=() seen=()
  for d in "$proc"/[0-9]*; do
    [ -r "$d/stat" ] || continue
    pid="${d##*/}"; stat="$(<"$d/stat")" 2>/dev/null || continue
    rest="${stat##*) }"; set -- $rest; p="${2:-}"
    [ -z "$p" ] || pp[$pid]="$p"
  done
  seen[$root]=1
  while [ "$changed" -eq 1 ]; do
    changed=0
    for pid in "${!pp[@]}"; do
      [ -z "${seen[$pid]:-}" ] || continue
      if [ -n "${seen[${pp[$pid]}]:-}" ]; then seen[$pid]=1; changed=1; fi
    done
  done
  for pid in "${!seen[@]}"; do [ "$pid" = "$root" ] || printf '%s\n' "$pid"; done | sort -n
}

# Listening sockets owned by any of the given pids. Unanswerable is a refusal,
# never "no listeners".
_ho_listeners() { # <pid...> -> lines; returns 2 when the table cannot be read
  local ss p out=""
  if [ -n "${CEL_TESTING:-}" ] && [ -n "${CEL_FANOUT_SS:-}" ]; then ss="$(cat "$CEL_FANOUT_SS")" || return 2
  else have ss || return 2; ss="$(ss -Hltnp 2>/dev/null)" || return 2; fi
  for p in "$@"; do
    out="$out$(printf '%s\n' "$ss" | grep -E "pid=$p[,)]" || true)"
  done
  printf '%s' "$out"
}

# One digest over every byte that is local work: HEAD, tracked changes, every
# untracked file, and the private .agent/ evidence. Paths and content hashes -
# the bytes themselves are never printed.
_ho_source_digest() { # <worktree> -> "<hex> <dirty-count>"
  local wt="$1" p h list dig n
  list="$( { git -C "$wt" diff --name-only -z HEAD 2>/dev/null | tr '\0' '\n'
             git -C "$wt" ls-files -z --others --exclude-standard 2>/dev/null | tr '\0' '\n'
             [ ! -d "$wt/.agent" ] || (cd "$wt" && find .agent -type f 2>/dev/null)
           } | sed '/^$/d' | LC_ALL=C sort -u)"
  dig="$({
    printf 'HEAD %s\n' "$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ -L "$wt/$p" ]; then h="link:$(readlink "$wt/$p")"
      elif [ -f "$wt/$p" ]; then h="$(git -C "$wt" hash-object --no-filters -- "$p" 2>/dev/null)"
      else h=absent; fi
      printf '%s\t%s\n' "$p" "$h"
    done <<< "$list"
  } | sha256sum | cut -c1-64)"
  n="$(printf '%s\n' "$list" | sed '/^$/d' | wc -l | tr -d ' ')"
  printf '%s %s' "$dig" "$n"
}

# Does the installed herdr offer the lifecycle primitive? Read from its own
# schema, not assumed. Prints a JSON object.
# herdr 0.9.1 has NO documented fenced, process-only agent-retirement call and
# this tool does not guess one. In production `agent_stop` is therefore always
# false: apply refuses before it mutates anything and names the missing
# primitive. The retire/start/prompt machinery after it is exercised only
# through a TEST ADAPTER (CEL_TESTING + CEL_FANOUT_STOP_ADAPTER), a seam that
# cannot exist in production, and proves this tool's logic - not herdr.
_ho_stop_adapter() { [ -n "${CEL_TESTING:-}" ] && [ -n "${CEL_FANOUT_STOP_ADAPTER:-}" ] && printf '%s' "$CEL_FANOUT_STOP_ADAPTER"; }
_ho_caps() {
  local sch none='{"schema":false,"agent_stop":false,"agent_stop_listed":false,"agent_start":false,"agent_prompt":false,"launch_receipt":false}' ad=false
  _ho_stop_adapter >/dev/null && ad=true
  sch="$("$HERDR" api schema --json 2>/dev/null)" || { printf '%s' "$none"; return 0; }
  printf '%s' "$sch" | jq -c --argjson ad "$ad" '
    ([.. | objects | .const? // empty | strings]) as $m
    | {schema:($m | length > 0), agent_stop_listed:($m | index("agent.stop") != null), agent_stop:$ad,
       agent_start:($m | index("agent.start") != null), agent_prompt:($m | index("agent.prompt") != null),
       launch_receipt:(($m | map(select(test("^agent\\.(launch_status|launch\\.status|start_status)$"))) | length) > 0)}' 2>/dev/null \
    || printf '%s' "$none"
}

_ho_agent_text() { "$HERDR" agent read "$1" --source recent-unwrapped --lines 60 2>/dev/null || true; }

# Unsettled tool use in a persisted session. Prints why, nothing when settled.
# Fails CLOSED: an unreadable or unparseable tail is "unsettled". The LAST
# assistant message's tool-call ids must ALL have a matching result after it
# (parallel calls: N calls need N results).
_ho_session_unsettled() { # <file>
  local f="$1" total win
  total="$(wc -l < "$f" 2>/dev/null | tr -d ' ')"; total="${total:-0}"
  win="$(tail -n 400 "$f" 2>/dev/null | sed '/^[[:space:]]*$/d')" || { printf 'the session file cannot be read'; return 0; }
  [ -n "$win" ] || { printf 'the session file is empty'; return 0; }
  [ "$total" -le 400 ] || win="$(printf '%s\n' "$win" | tail -n +2)"          # the cut first line may be partial
  printf '%s\n' "$win" | tail -n 1 | jq -e . >/dev/null 2>&1 || { printf 'the last line of the session file is not valid JSON (a write may be in progress)'; return 0; }
  printf '%s\n' "$win" | jq -s -r --argjson big "$([ "$total" -gt 400 ] && echo true || echo false)" '
    def calltypes: ["toolUse","tool_use","toolCall","tool_call"];
    def msg: (.message // .);
    def calls: [(msg | .content // [])[]? | select(type == "object" and ((.type // "") as $t | calltypes | index($t))) | (.id // "?")];
    def results: [ (.message.toolCallId // .toolCallId // empty),
                   ((msg | .content // [])[]? | select(type == "object") | (.tool_use_id // .toolCallId // empty)) ];
    ([to_entries[] | select((.value | msg | .role? // "") == "assistant")] | last) as $a
    | if $a == null then (if $big then "no assistant message in the last 400 lines of a longer session - tool state cannot be told" else empty end)
      else ($a.value | calls) as $c
        | ([ .[($a.key + 1):][] | results[] ]) as $r
        | ($c - $r) as $open
        | if ($open | length) > 0 then "the last assistant message has " + ($open | length | tostring) + " tool call(s) without a result (" + ($open | join(",")) + ")" else empty end
      end' 2>/dev/null || printf 'the session tail could not be analysed'
}

# --- the one gather used by inspect AND by apply's revalidation -------------

HO_EXPORT=""; HO_RESUME=""; HO_RESUME_SHA=""
HO_WHY=()
_ho_no() { HO_WHY+=("$1"); }

# Sets HO_SNAP (json) and HO_WHY (refusals). Never writes. Expected
# coordinates (apply) are compared when non-empty; inspect passes none.
#   args: <wsdir> <row-id> <pane> <profile-or-empty> <own-opid-or-empty> [expect: shell agent start head digest]
_ho_gather() {
  local wsdir="$1" id="$2" pane="$3" profile="$4" own="$5" e_shell="${6:-}" e_agent="${7:-}" e_start="${8:-}" e_head="${9:-}" e_digest="${10:-}"
  HO_WHY=(); HO_SNAP="{}"
  local row; row="$(_ledger_entry "$wsdir" "$id")"
  if [ -z "$row" ]; then _ho_no "no-row: no delegation '$id'"; return 0; fi
  local alias repo branch rwt wt state
  alias="$(printf '%s' "$row" | jq -r '.alias // ""')"; repo="$(printf '%s' "$row" | jq -r '.repo // ""')"
  branch="$(printf '%s' "$row" | jq -r '.branch // ""')"; rwt="$(printf '%s' "$row" | jq -r '.worktree // ""')"
  state="$(printf '%s' "$row" | jq -r '.state // ""')"
  case "$state" in abandoned|landed|released) _ho_no "row-closed: the row is $state - a closed delegation is not handed to a new runtime" ;; esac
  [ -n "$pane" ] || pane="$(printf '%s' "$row" | jq -r '.pane // ""')"

  # debt: held launch, unsettled launch, a different operation
  local hold; hold="$(printf '%s' "$row" | jq -r '.handoff_hold.kind // empty')"
  if [ -n "$hold" ]; then
    _ho_no "launch-debt: this delegation carries an operator hold ($hold, $(printf '%s' "$row" | jq -r '.handoff_hold.at // "?"')): $(printf '%s' "$row" | jq -r '.handoff_hold.evidence // ""'). A launch whose outcome is UNKNOWN may still complete in this pane, and neither a missing launcher process nor null ledger launch fields prove otherwise. It is settled only by a supported herdr launch receipt (UPSTREAM PREREQUISITE: an API that reports the outcome of an agent.start by launch id, and a supported cancel) - this tool cannot and will not mark it cancelled or not-started"
  fi
  local why; why="$(_rec_unresolved "$row")"
  if [ -n "$why" ] && { [ -z "$own" ] || [ "$(printf '%s' "$row" | jq -r '.handoff.id // ""')" != "$own" ]; }; then
    _ho_no "launch-debt: the ledger row holds an unsettled launch or operation ($why) - see cel-fanout recover / handoff status; nothing here may settle it by absence"
  fi
  local other; if other="$(_ho_pending_other "$wsdir" "$id" "$own")"; then
    _ho_no "pending-operation: handoff $other for $id is not finished - it blocks every competitor until it is settled (cel-fanout handoff status $other)"
  fi
  if _rec_original_active "$branch" "$alias" >/dev/null; then
    _ho_no "launch-active: a cel-fanout delegate/scout/spike for this branch or a herdr agent start for $alias is running - it may still start an agent"
  fi

  # worktree + source
  local head="" cur="" class=none ahead=0 behind=0 rsha="" digest="" dirty=0
  if [ -z "$rwt" ] || [ ! -d "$rwt" ]; then _ho_no "worktree-missing: the row's worktree is not on disk"
  else
    wt="$(cd "$rwt" && pwd -P)"
    cur="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [ "$cur" = "$branch" ] || _ho_no "worktree-branch: $wt is on '${cur:-?}', the row is '$branch'"
    head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
    [ -n "$head" ] || _ho_no "source-unreadable: cannot read HEAD of $wt"
    rsha="$(git -C "$wt" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}" 2>/dev/null || true)"
    if [ -z "$rsha" ]; then class=no-remote-ref
    elif [ "$rsha" = "$head" ]; then class=in-sync
    elif git -C "$wt" merge-base --is-ancestor "$head" "$rsha" 2>/dev/null; then class=behind
    elif git -C "$wt" merge-base --is-ancestor "$rsha" "$head" 2>/dev/null; then class=ahead
    else class=diverged; fi
    if [ -n "$rsha" ]; then
      read -r ahead behind < <(git -C "$wt" rev-list --left-right --count "$head...$rsha" 2>/dev/null || echo "0 0")
    fi
    read -r digest dirty <<< "$(_ho_source_digest "$wt")"
    [ -z "$e_head" ] || [ "$e_head" = "$head" ] || _ho_no "source-moved: HEAD is ${head:0:12}, the plan was ${e_head:0:12} (stale snapshot)"
    [ -z "$e_digest" ] || [ "$e_digest" = "$digest" ] || _ho_no "source-changed: the dirty/untracked bytes differ from the plan's digest (stale snapshot or live edits)"
  fi

  # herdr: pane, agent, processes
  local obs="" terminal="" shell_pid="" agent_pid="" start="" okind="" ostatus="" sess="" sess_exists=false sess_sha="" nfg=0
  if obs="$( _rec_observe "$pane" "$alias" 2>/dev/null && printf '%s' "$REC_JSON" )" && [ -n "$obs" ]; then
    printf '%s' "$obs" | jq -e '.pane_ok' >/dev/null || _ho_no "pane-identity: herdr's answers do not name $pane"
    terminal="$(printf '%s' "$obs" | jq -r '.terminal')"; shell_pid="$(printf '%s' "$obs" | jq -r '.shell_pid // ""')"
    nfg="$(printf '%s' "$obs" | jq -r '.fg_pids | length')"
    [ "$(printf '%s' "$obs" | jq -r '.agents_in_pane')" = 1 ] && [ "$(printf '%s' "$obs" | jq -r '.agents_named')" = 1 ] \
      || _ho_no "agent-identity: herdr does not show exactly one agent named '$alias' in $pane (a different or absent owner)"
    [ "$(printf '%s' "$obs" | jq -r '.agent.name // ""')" = "$alias" ] || _ho_no "agent-identity: the agent in $pane is not named '$alias'"
    okind="$(printf '%s' "$obs" | jq -r '.agent.agent // ""')"; ostatus="$(printf '%s' "$obs" | jq -r '.agent.agent_status // ""')"
    [ "$ostatus" = idle ] || _ho_no "busy: herdr reports the agent '${ostatus:-?}', not idle - a working or blocked agent is never retired"
    printf '%s' "$obs" | jq -e '(.agent.launch_pending // false) == true' >/dev/null \
      && _ho_no "launch-pending: herdr reports a pending launch for $alias - an unsettled launch is not retired or repeated"
    printf '%s' "$obs" | jq -e '(.agent.interactive_ready // false) == true' >/dev/null || _ho_no "not-ready: herdr does not report the agent interactive_ready"
    sess="$(printf '%s' "$obs" | jq -r '.agent.agent_session.value // ""')"
    if [ -z "$sess" ]; then
      _ho_no "session-unknown: herdr reports no session for $alias, so the runtime's persisted history and any memory-only tail cannot be located - REFUSED (fails closed); nothing is retired"
    elif [ ! -f "$sess" ]; then
      # (the Pi ENOENT case) the newest entries may exist ONLY in memory. A named
      # archive (--preserved-export) is evidence only and NEVER unlocks retirement.
      _ho_no "session-tail: herdr's recorded session file ($sess) is not on disk, so the runtime's newest entries may live only in memory. REFUSED even with a valid archive${HO_EXPORT:+ ($HO_EXPORT)}: an export does not prove quiescence, settled tool use or the post-export tail, and no supported herdr call proves them. Nothing is retired"
    else
      sess_exists=true; sess_sha="$(sha256sum "$sess" | cut -c1-64)"
      local un; un="$(_ho_session_unsettled "$sess")"
      [ -z "$un" ] || _ho_no "unsettled-tool: $un - retirement would lose or orphan it"
    fi
    if [ "$nfg" -eq 1 ]; then agent_pid="$(printf '%s' "$obs" | jq -r '.fg_pids[0]')"
    else _ho_no "busy: the pane's foreground holds $nfg processes, not exactly the agent - something else is running there"; fi
  else
    _ho_no "herdr-unreadable: herdr cannot describe pane $pane, its processes or its agents - no trustworthy capability, nothing is retired"
  fi
  if [ -n "$agent_pid" ]; then
    start="$(_rec_stat_field "$agent_pid" start)"
    [ -n "$start" ] || _ho_no "process-unreadable: pid $agent_pid has no readable start generation"
    [ -z "$e_shell" ] || [ "$e_shell" = "$shell_pid" ] || _ho_no "identity-changed: the pane's shell is pid ${shell_pid:-?}, the plan was $e_shell"
    [ -z "$e_agent" ] || [ "$e_agent" = "$agent_pid" ] || _ho_no "identity-changed: the agent is pid $agent_pid, the plan was $e_agent"
    [ -z "$e_start" ] || [ "$e_start" = "$start" ] || _ho_no "identity-changed: pid $agent_pid has start generation $start, the plan was $e_start (pid reused or restarted)"
    [ "$(_rec_stat_field "$agent_pid" ppid)" = "$shell_pid" ] || _ho_no "identity-changed: pid $agent_pid is not a child of shell ${shell_pid:-?}"
    [ "$(_rec_env_get "$agent_pid" CEL_ROLE)" = worker ] || _ho_no "ownership: the agent process does not carry CEL_ROLE=worker - not a plane worker this tool may retire"
    [ "$(_rec_env_get "$agent_pid" CEL_WORKSPACE)" = "$wsdir" ] || _ho_no "ownership: the agent belongs to another workspace"
    local kids; kids="$(_ho_descendants "$agent_pid")"
    if [ -n "$kids" ]; then _ho_no "live-child: the agent has live descendant process(es) $(printf '%s' "$kids" | tr '\n' ' ')- unknown children are never terminated; stop or hand them off first"; fi
    local lst rc=0
    # shellcheck disable=SC2086
    lst="$(_ho_listeners "$agent_pid" $kids)" || rc=$?
    if [ "$rc" -ne 0 ]; then _ho_no "listeners-unknown: the listening-socket table cannot be read - a preview owned by this agent cannot be ruled out"
    elif [ -n "$lst" ]; then _ho_no "listener: the agent (or a child) owns a listening socket: $(printf '%s' "$lst" | head -1 | cut -c1-120)"; fi
  fi
  local tryport; tryport="$(printf '%s' "$row" | jq -r '.try.port // empty')"
  if [ -n "$tryport" ] && ! _port_free "$tryport" 2>/dev/null; then
    _ho_no "preview: the row's preview on port $tryport is listening - a protected service is never terminated or orphaned (cel-fanout try $id --stop first, deliberately)"
  fi

  # quiescence: readable, no unsent draft, output unchanged across a short interval
  local t1 t2
  t1="$(_ho_agent_text "$alias")"
  if [ -z "$t1" ]; then _ho_no "unreadable: the agent's output cannot be read - quiescence cannot be proven (idle labels alone are not proof)"
  else
    if _liveness_pending_text "$t1"; then _ho_no "draft: unsent text sits in the agent's composer - a draft or pending input would be lost"; fi
    [ "${CEL_FANOUT_QUIET_SECS:-2}" = 0 ] || sleep "${CEL_FANOUT_QUIET_SECS:-2}"
    t2="$(_ho_agent_text "$alias")"
    [ "$t1" = "$t2" ] || _ho_no "not-quiescent: the agent's output changed during the quiescence window - it is doing something"
  fi

  local caps; caps="$(_ho_caps)"
  printf '%s' "$caps" | jq -e '.agent_stop' >/dev/null || _ho_no "capability-missing: the installed herdr ($("$HERDR" --version 2>/dev/null | head -1)) has no DOCUMENTED, fenced process-only retirement call$(printf '%s' "$caps" | jq -e '.agent_stop_listed' >/dev/null && echo ' (an agent.stop method is listed, but its contract is not documented to this tool and it is not guessed)'). Nothing end-to-end exists on this herdr. EXACT MISSING PRIMITIVE: a per-agent stop that takes the agent identity AND a generation fence (so a replaced agent is never retired by name) - end ONE agent process by identity, release its name, keep the pane, its shell, the worktree and every other process. pane.close destroys the shell and every child; pane.release_agent/clear_agent_authority only forget authority (the process keeps running and the name stays held); the alias cannot be renamed around uniqueness. Nothing was retired"
  printf '%s' "$caps" | jq -e '.agent_start and .agent_prompt' >/dev/null || _ho_no "capability-missing: herdr lacks agent.start/agent.prompt"

  # target profile
  local trt="" tmodel="" tthinking="" tprov=""
  if [ -n "$profile" ]; then
    local rt0; rt0="$(ws_runtime "$wsdir" worker)"
    local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_ISOLATE="" PROFILE_VETO="" PROFILE_VIA=""
    if ! ( profile_resolve "$wsdir" "$profile" "$rt0" >/dev/null 2>&1 ); then _ho_no "profile: '$profile' does not resolve"
    else
      profile_resolve "$wsdir" "$profile" "$rt0" >/dev/null 2>&1 || true
      if [ -n "$PROFILE_VETO" ]; then _ho_no "profile: '$profile' is vetoed - $PROFILE_VETO"
      elif [ -z "${PROFILE_MODEL:-}" ]; then _ho_no "profile: '$profile' names no model, so the replacement's model cannot be verified"
      else trt="$PROFILE_RUNTIME"; tmodel="$PROFILE_MODEL"; tthinking="$PROFILE_THINKING"; tprov="$(profile_provider "$tmodel")"; fi
    fi
  fi

  local resume_json="null"
  if [ -n "${HO_RESUME:-}" ]; then
    local rpath="$HO_RESUME" rhdr rid rcwd
    if [ "$trt" != pi ]; then _ho_no "resume-unavailable: explicit --session selection is only known for the pi runtime (its --session <path> contract); the target is '${trt:-unresolved}'. UNAVAILABLE, nothing changed"
    elif [ "${rpath#/}" = "$rpath" ] || [ ! -f "$rpath" ] || [ ! -s "$rpath" ]; then _ho_no "resume-session: $rpath is not an existing absolute session file"
    elif [ -z "$sess" ] || [ ! -f "$sess" ]; then _ho_no "resume-unavailable: the old runtime's recorded session file is unknown or missing, and the only resumable file is that exact one - a copy or archive cannot be certified as its continuation. UNAVAILABLE, nothing changed"
    elif [ -L "$rpath" ] || [ "$rpath" != "$(readlink -f "$rpath")" ] || [ "$rpath" != "$(readlink -f "$sess")" ]; then
      _ho_no "resume-session: $rpath is not the old runtime's own session file ($sess) by its real path - symlinks, hardlinks and copies/archives are refused (a copy cannot be proven to be its continuation, and a pi append would modify an archive)"
    elif [ -n "${HO_EXPORT:-}" ] && [ "$rpath" -ef "$HO_EXPORT" ]; then _ho_no "resume-session: $rpath is the preserved archive - an archive stays immutable and is never the working session"
    else
      local un2; un2="$(_ho_session_unsettled "$rpath")"
      rhdr="$(head -n 1 "$rpath" 2>/dev/null || true)"
      rid="$(printf '%s' "$rhdr" | jq -r 'select(.type == "session") | .id // empty' 2>/dev/null || true)"
      rcwd="$(printf '%s' "$rhdr" | jq -r 'select(.type == "session") | .cwd // empty' 2>/dev/null || true)"
      if [ -z "$rid" ]; then _ho_no "resume-session: $rpath has no session header with an id - not a verifiable pi session"
      elif [ "$rcwd" != "${wt:-}" ]; then _ho_no "resume-session: the session header cwd (${rcwd:-none}) is not the retained worktree (${wt:-?}) - no cwd guessing"
      elif [ -n "$un2" ]; then _ho_no "resume-unsettled: the selected session cannot be resumed: $un2"
      else resume_json="$(jq -n --arg p "$rpath" --arg id "$rid" --arg cwd "$rcwd" --arg sha "$(sha256sum "$rpath" | cut -c1-64)" --arg lines "$(wc -l < "$rpath" | tr -d ' ')" --arg ino "$(stat -c '%d:%i' "$rpath")" --arg bytes "$(stat -c %s "$rpath")" \
          '{path:$p, uuid:$id, cwd:$cwd, sha256:$sha, lines:($lines|tonumber), inode:$ino, bytes:($bytes|tonumber), source:"the old runtime'"'"'s own recorded session file"}')"; fi
    fi
  fi
  if [ "$resume_json" != null ] && [ -n "$HO_RESUME_SHA" ] && [ "$(printf '%s' "$resume_json" | jq -r .sha256)" != "$HO_RESUME_SHA" ]; then
    _ho_no "stale-session: the selected working session's bytes differ from the plan (sha256 changed) - a different file than the one inspected"
  fi
  local ctx=cross-harness
  [ "$okind" != "$trt" ] || ctx=same-harness
  HO_SNAP="$(jq -n --arg id "$id" --arg alias "$alias" --arg repo "$repo" --arg branch "$branch" --arg pane "$pane" \
    --arg wt "${wt:-}" --arg terminal "$terminal" --arg shell "$shell_pid" --arg apid "$agent_pid" --arg start "$start" \
    --arg okind "$okind" --arg ostatus "$ostatus" --arg head "$head" --arg class "$class" --arg ahead "$ahead" --arg behind "$behind" \
    --arg remote "$rsha" --arg digest "$digest" --argjson dirty "${dirty:-0}" --arg sess "$sess" --argjson sx "$sess_exists" --arg ssha "$sess_sha" \
    --argjson resume "$resume_json" --argjson caps "$caps" --arg profile "$profile" --arg trt "$trt" --arg tmodel "$tmodel" --arg tthinking "$tthinking" --arg tprov "$tprov" --arg ctx "$ctx" \
    '{row_id:$id, alias:$alias, repo:$repo, branch:$branch, pane:$pane, worktree:$wt,
      runtime:{terminal:$terminal, shell_pid:$shell, agent_pid:$apid, agent_start:$start, kind:$okind, herdr_status:$ostatus,
               session:{path:$sess, exists:$sx, sha256:$ssha, memory_tail_proof:"none"}},
      source:{head:$head, remote_ref:$remote, relation:$class, ahead:($ahead|tonumber? // 0), behind:($behind|tonumber? // 0),
              dirty_and_untracked:$dirty, digest:$digest},
      capabilities:$caps, resume_session:$resume,
      target:{profile:$profile, runtime:$trt, model:$tmodel, thinking:$tthinking, provider:$tprov},
      context:{mode:(if $ctx == "same-harness" then "same-harness-fresh-session" else "cross-harness-context-transfer" end),
               lossless_native_resume:false,
               session_selection:(if $resume == null then "fresh" else "explicit-working-session" end),
               note:"unless an explicit working session is named (--resume-session, pi only, bound by sha/uuid/cwd), the replacement starts a fresh session; it gets the spec, a handoff brief and a copy of the old pane text. The old session path and digest are kept as evidence, not resumed."}}')"
}

_ho_opid() { # <ws> <id> <wt> <alias> <pane> <shell> <agent> <start> <head> <digest> <profile> <spec>
  printf '%s\n' "$@" | sha256sum | cut -c1-16
}

# --- inspect ----------------------------------------------------------------

cmd_handoff_inspect() {
  [ $# -ge 1 ] || die "usage: cel-fanout handoff inspect <id> --pane <pane> [--profile NAME] [--workspace NAME]"
  local id="$1"; shift
  local ws_opt="" pane="" profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws_opt="$2"; shift 2 ;;
      --pane)      pane="$2"; shift 2 ;;
      --profile)   profile="$2"; shift 2 ;;
      --preserved-export) HO_EXPORT="$2"; shift 2 ;;
      --resume-session) HO_RESUME="$2"; shift 2 ;;
      --resume-sha)     HO_RESUME_SHA="$2"; shift 2 ;;
      *) die "handoff inspect: unknown argument: $1" ;;
    esac
  done
  local wsdir; wsdir="$(_fanout_wsdir "$ws_opt")"
  _ho_gather "$wsdir" "$id" "$pane" "$profile" ""
  local row spec why_json
  row="$(_ledger_entry "$wsdir" "$id")"; spec="$(printf '%s' "$row" | jq -r '.spec // ""')"
  why_json="$(printf '%s\n' "${HO_WHY[@]:-}" | sed '/^$/d' | jq -R . | jq -sc .)"
  local ws; ws="$(ws_name "$wsdir")"
  local cmd=""
  if [ "${#HO_WHY[@]}" -eq 0 ] && [ -n "$profile" ]; then
    cmd="$(printf '%s' "$HO_SNAP" | jq -r --arg id "$id" --arg p "$profile" --arg ws "$ws" \
      '"cel-fanout handoff apply \($id) --workspace \($ws) --profile \($p) --pane \(.pane) --shell-pid \(.runtime.shell_pid) --agent-pid \(.runtime.agent_pid) --agent-start \(.runtime.agent_start) --head \(.source.head) --source-digest \(.source.digest) --evidence \"<what you checked>\"\(if .resume_session then " --resume-session \(.resume_session.path) --resume-sha \(.resume_session.sha256)" else "" end)"')"
  fi
  printf '%s' "$HO_SNAP" | jq --argjson why "$why_json" --arg cmd "$cmd" --arg spec "$spec" \
    '{read_only:true, applicable:(($why|length) == 0), refusals:$why, spec:$spec, plan:., apply_command:(if $cmd == "" then null else $cmd end)}'
}

# --- hold -------------------------------------------------------------------

cmd_handoff_hold() { # <id> --kind launch-unknown --evidence TEXT
  [ $# -ge 1 ] || die "usage: cel-fanout handoff hold <id> --kind launch-unknown --evidence TEXT [--workspace NAME]"
  local id="$1"; shift
  local ws_opt="" kind="" evidence=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws_opt="$2"; shift 2 ;;
      --kind)      kind="$2"; shift 2 ;;
      --evidence)  evidence="$2"; shift 2 ;;
      *) die "handoff hold: unknown argument: $1" ;;
    esac
  done
  [ "$kind" = launch-unknown ] || die "handoff hold: --kind must be launch-unknown (the only debt this records: a launch attempt whose outcome nobody observed)"
  [ -n "$evidence" ] && [ "${#evidence}" -le 400 ] || die "handoff hold: --evidence is required, at most 400 characters (state the facts, never credentials)"
  local wsdir; wsdir="$(_fanout_wsdir "$ws_opt")"
  local row; row="$(_ledger_entry "$wsdir" "$id")"
  [ -n "$row" ] || die "handoff hold: no delegation with id '$id'"
  case "$(printf '%s' "$row" | jq -r '.state // ""')" in abandoned|landed|released) die "handoff hold: $id is closed ($(printf '%s' "$row" | jq -r .state)) - nothing to hold" ;; esac
  if [ -n "$(printf '%s' "$row" | jq -r '.handoff_hold.kind // empty')" ]; then
    c_ok "$id: already held ($(printf '%s' "$row" | jq -r '.handoff_hold.kind')) - nothing changed"; return 0
  fi
  _ledger_patch "$wsdir" "$id" '.handoff_hold = {kind:$k, at:$at, evidence:$e, by:$by, settled:false}' \
    --arg k "$kind" --arg at "$(_now_iso)" --arg e "$evidence" --arg by "$(_ledger_mover)"
  c_ok "$id: launch debt recorded ($kind). Retirement, restart, collect, release, land and handback now refuse it. There is no supported exit yet: it is settled only by a herdr launch receipt (outcome of agent.start by launch id) - this tool will not mark it cancelled or not-started from absence."
}

# --- settle -----------------------------------------------------------------

# The ONLY exit from a hold: a launch receipt from herdr. It activates only when
# the installed herdr's schema offers a launch-receipt query; none does in
# 0.9.1, so this refuses with zero mutation and names the exact prerequisite.
# Never settled by an absent process, null ledger fields, GC, or an operator note.
cmd_handoff_settle() { # <id>
  [ $# -ge 1 ] || die "usage: cel-fanout handoff settle <id> [--workspace NAME]"
  local id="$1"; shift
  local ws_opt=""
  while [ $# -gt 0 ]; do
    case "$1" in --workspace) ws_opt="$2"; shift 2 ;; *) die "handoff settle: unknown argument: $1" ;; esac
  done
  local wsdir; wsdir="$(_fanout_wsdir "$ws_opt")"
  local row; row="$(_ledger_entry "$wsdir" "$id")"
  [ -n "$row" ] || die "handoff settle: no delegation with id '$id'"
  [ -n "$(printf '%s' "$row" | jq -r '.handoff_hold.kind // empty')" ] || die "handoff settle: $id carries no hold - nothing to settle"
  local caps; caps="$(_ho_caps)"
  printf '%s' "$caps" | jq -e '.launch_receipt' >/dev/null \
    || die "handoff settle: UNAVAILABLE - the installed herdr ($("$HERDR" --version 2>/dev/null | head -1)) has no launch-receipt query (the outcome of an agent.start by launch id) and no supported cancel. The hold stays: an absent process, null ledger launch fields, GC or a note do not settle an unknown launch. Held rows keep occupying delegate worker slots. Nothing changed. UPSTREAM PREREQUISITE: agent.start returns a launch id; a query by id reports started|failed|cancelled|pending (+pane/pid); a supported cancel for pending ids"
  die "handoff settle: herdr lists a launch-receipt method, but its request/response contract is not implemented by this tool yet - refusing to guess it. Nothing changed"
}

# --- status -----------------------------------------------------------------

_ho_next() { # <phase> <opid> <id>
  case "$1" in
    done) printf 'nothing - the replacement owns the worktree' ;;
    admitting) printf 're-run apply (same arguments): it re-marks the interrupted admission, nothing irreversible had happened' ;;
    admitted) printf 'cel-fanout handoff apply %s ... (same arguments) retires the old runtime' "$3" ;;
    retiring|retire-unconfirmed) printf 'the stop request may or may not have reached herdr. Re-run apply: it only OBSERVES; once the old agent is gone it continues. If the old agent is still present and unchanged, add --reissue-retire (re-validated identity, one more agent.stop)' ;;
    retired) printf 're-run apply (same arguments): it starts the replacement once' ;;
    starting|start-failed) printf 'an agent MAY exist in the pane (a herdr start can time out after it began). NOT restarted. Look at the pane; re-run apply to adopt a verified agent. A start herdr never confirms is retained debt until herdr offers a launch receipt' ;;
    started|started-unverified) printf 're-run apply: it verifies the process identity (model, thinking, role env) then prompts once; a mismatch stays refused' ;;
    prompting|ambiguous|unconfirmed-acceptance) printf 'a task MAY have been delivered. NEVER resubmitted. Re-run apply to look for assistant turn + tool evidence' ;;
    *) printf 'unknown phase - cel-fanout handoff status' ;;
  esac
}

cmd_handoff_status() { # <id|opid>
  [ $# -ge 1 ] || die "usage: cel-fanout handoff status <id|opid> [--workspace NAME]"
  local key="$1"; shift
  local ws_opt=""
  while [ $# -gt 0 ]; do
    case "$1" in --workspace) ws_opt="$2"; shift 2 ;; *) die "handoff status: unknown argument: $1" ;; esac
  done
  local wsdir; wsdir="$(_fanout_wsdir "$ws_opt")"
  local op opid="$key" row hold
  op="$(_ho_read "$wsdir" "$key")"
  if [ -z "$op" ]; then
    row="$(_ledger_entry "$wsdir" "$key")"
    opid="$(printf '%s' "$row" | jq -r '.handoff.id // empty')"
    hold="$(printf '%s' "$row" | jq -c '.handoff_hold // null')"
    [ -z "$opid" ] || op="$(_ho_read "$wsdir" "$opid")"
    if [ -z "$op" ]; then
      [ -n "$row" ] || die "handoff status: no operation or delegation '$key'"
      jq -n --argjson hold "$hold" '{operation:null, hold:$hold}'
      return 0
    fi
  fi
  printf '%s' "$op" | jq --arg next "$(_ho_next "$(printf '%s' "$op" | jq -r .phase)" "$opid" "$(printf '%s' "$op" | jq -r .row_id)")" \
    '{operation:., next_action:$next}'
}

# --- the brief --------------------------------------------------------------

_ho_brief() { # <wsdir> <opid> <row> <snap> <profile>
  local wsdir="$1" opid="$2" row="$3" snap="$4" profile="$5" f
  f="$(_ho_dir "$wsdir")/$opid.brief.md"
  {
    printf '# Handoff brief %s\n\n' "$opid"
    printf 'You are the REPLACEMENT execution owner of `%s` (branch `%s`) in this worktree. The previous runtime (%s) has been retired; you are the only owner now.\n\n' \
      "$(printf '%s' "$snap" | jq -r .row_id)" "$(printf '%s' "$snap" | jq -r .branch)" "$(printf '%s' "$snap" | jq -r .runtime.kind)"
    printf '## Task\nYour spec: %s\nRead it fully. The task is unchanged; this is a continuation, not a restart.\n\n' "$(printf '%s' "$row" | jq -r .spec)"
    printf '## Source state you inherit (do NOT reset, stash, checkout or rebase it)\n'
    printf -- '- HEAD %s; relation to origin/%s: %s (ahead %s, behind %s)\n' "$(printf '%s' "$snap" | jq -r .source.head)" "$(printf '%s' "$snap" | jq -r .branch)" \
      "$(printf '%s' "$snap" | jq -r .source.relation)" "$(printf '%s' "$snap" | jq -r .source.ahead)" "$(printf '%s' "$snap" | jq -r .source.behind)"
    printf -- '- %s dirty/untracked path(s) are the previous owner'"'"'s uncommitted work - keep them; `git status` shows them\n' "$(printf '%s' "$snap" | jq -r .source.dirty_and_untracked)"
    printf -- '- the private .agent/ directory, including any .agent/result.md, is the previous owner'"'"'s evidence: read it, do not delete it\n\n'
    printf '## Context transfer (truthful)\n'
    printf -- '- mode: %s - NOT a lossless native session resume; you start with a fresh session\n' "$(printf '%s' "$snap" | jq -r .context.mode)"
    printf -- '- the previous session file (evidence only): %s\n' "$(printf '%s' "$snap" | jq -r '.runtime.session.path // "unknown"')"
    printf -- '- a copy of the previous runtime'"'"'s recent pane text: %s\n' "$(_ho_dir "$wsdir")/$opid.pane-before.txt"
    printf -- '- any review or gate approval of the previous source state is NOT carried over; it must be re-earned on what you finish with\n\n'
    printf '## Profile\nYou run on profile `%s` (%s).\n' "$profile" "$(printf '%s' "$snap" | jq -r '.target.model')"
  } > "$f"
  printf '%s' "$f"
}

# --- acceptance (strict) ----------------------------------------------------

# The assistant took a turn AND a tool call visibly ran without an error mark.
# A turn alone is not enough here: the model's say-so is not execution.
_ho_tool_evidence() { # <pane-text>
  printf '%s' "$1" | grep -E '^[[:space:]]*[⏺●✳✻✶][[:space:]]*(Read|Bash|Write|Edit|Grep|Glob|Search|Fetch|Task|read|bash|write|edit|grep|find|ls)\b' \
    | grep -viE 'error|failed|denied|refused' | grep -q .
}
_ho_accepted() { # <alias> <tries>
  local alias="$1" tries="${2:-5}" i text
  for (( i = 0; i < tries; i++ )); do
    [ "$i" -eq 0 ] || sleep "${CEL_FANOUT_CONFIRM_SLEEP:-2}"
    text="$("$HERDR" agent read "$alias" --source recent-unwrapped --lines 60 2>/dev/null || true)"
    [ -n "$text" ] || continue
    _liveness_has_turn "$text" && [ "$(liveness_pane_silence "$text")" != unstarted ] && _ho_tool_evidence "$text" && return 0
  done
  return 1
}

# --- apply ------------------------------------------------------------------

# Is the old runtime gone and the SAME shell back in the foreground?
_ho_retired_now() { # <op-json>
  local op="$1" alias pane apid astart shell term l probe
  alias="$(printf '%s' "$op" | jq -r .alias)"; pane="$(printf '%s' "$op" | jq -r .pane)"
  apid="$(printf '%s' "$op" | jq -r .binding.agent_pid)"; astart="$(printf '%s' "$op" | jq -r .binding.agent_start)"
  shell="$(printf '%s' "$op" | jq -r .binding.shell_pid)"; term="$(printf '%s' "$op" | jq -r .binding.terminal)"
  l="$("$HERDR" agent list 2>/dev/null)" || return 1
  printf '%s' "$l" | jq -e --arg a "$alias" '[(.result.agents // [])[] | select(.name == $a)] | length == 0' >/dev/null || return 1
  [ "$(_rec_stat_field "$apid" start)" != "$astart" ] || return 1       # the old generation is gone
  _RUN_HERDR="$HERDR"
  probe="$(_run_pane_probe "$pane")"
  [ "$probe" = "$term:$shell"$'\t'ready ]
}

# One agent in the pane, named for the alias, that is NOT the old generation.
# Sets HO_NEW_PID / HO_NEW_START / HO_NEW_READY.
_ho_find_new() { # <op-json>
  local op="$1" alias pane shell apid astart obs
  alias="$(printf '%s' "$op" | jq -r .alias)"; pane="$(printf '%s' "$op" | jq -r .pane)"
  shell="$(printf '%s' "$op" | jq -r .binding.shell_pid)"
  apid="$(printf '%s' "$op" | jq -r .binding.agent_pid)"; astart="$(printf '%s' "$op" | jq -r .binding.agent_start)"
  HO_NEW_PID=""; HO_NEW_START=""; HO_NEW_READY=0
  obs="$( _rec_observe "$pane" "$alias" 2>/dev/null && printf '%s' "$REC_JSON" )" || return 1
  printf '%s' "$obs" | jq -e --arg a "$alias" --argjson sh "$shell" '.pane_ok and .shell_pid == $sh and .agents_in_pane == 1 and .agents_named == 1 and .agent.name == $a' >/dev/null || return 1
  [ "$(printf '%s' "$obs" | jq -r '.fg_pids | length')" = 1 ] || return 1
  HO_NEW_PID="$(printf '%s' "$obs" | jq -r '.fg_pids[0]')"
  HO_NEW_START="$(_rec_stat_field "$HO_NEW_PID" start)"
  [ -n "$HO_NEW_START" ] || return 1
  if [ "$HO_NEW_PID" = "$apid" ] && [ "$HO_NEW_START" = "$astart" ]; then return 1; fi   # still the old one
  if printf '%s' "$obs" | jq -e '.agent.agent_status == "idle" and (.agent.interactive_ready // false) and ((.agent.launch_pending // false) | not)' >/dev/null; then HO_NEW_READY=1; fi
  HO_NEW_KIND="$(printf '%s' "$obs" | jq -r '.agent.agent // ""')"
  return 0
}

_ho_cmdline_adjacent() { # <pid> <a> <b>: argv has a immediately followed by b
  local f prev="" x; f="$(_rec_proc)/$1/cmdline"
  [ -r "$f" ] || return 1
  while IFS= read -r -d '' x; do
    [ "$prev" = "$2" ] && [ "$x" = "$3" ] && return 0
    prev="$x"
  done < "$f"
  return 1
}

# The replacement is the process the profile asked for: exact model and
# thinking arguments, the workspace, the role and the canonical inbox identity.
_ho_verify_new() { # <op-json> <wsdir>
  local op="$1" wsdir="$2" pid="$HO_NEW_PID" shell rt model thinking alias why=""
  shell="$(printf '%s' "$op" | jq -r .binding.shell_pid)"; alias="$(printf '%s' "$op" | jq -r .alias)"
  rt="$(printf '%s' "$op" | jq -r .target.runtime)"; model="$(printf '%s' "$op" | jq -r .target.model)"; thinking="$(printf '%s' "$op" | jq -r .target.thinking)"
  [ "$HO_NEW_KIND" = "$rt" ] || why="the new agent is a '$HO_NEW_KIND', the profile is runtime '$rt'"
  [ -n "$why" ] || [ "$(_rec_stat_field "$pid" ppid)" = "$shell" ] || why="pid $pid is not a child of the pane's shell"
  [ -n "$why" ] || [ "$(_rec_env_get "$pid" CEL_ROLE)" = worker ] || why="the new agent does not carry CEL_ROLE=worker"
  [ -n "$why" ] || [ "$(_rec_env_get "$pid" CEL_WORKSPACE)" = "$wsdir" ] || why="the new agent belongs to another workspace"
  if [ -z "$why" ] && [ -n "$(agent_inbox_hook "$rt" file)" ] && [ "$(_rec_env_get "$pid" CEL_INBOX_ME)" != "$alias" ]; then why="the new agent's inbox identity is not '$alias'"; fi
  [ -n "$why" ] || _rec_cmdline_model_is "$pid" "$model" || why="the new agent was not launched with exactly model '$model'"
  if [ -z "$why" ]; then
    local -a PROFILE_ARGS=()
    profile_launch_args "$rt" "$model" "$thinking" "${PROFILE_ISOLATE:-}"
    if [ "${#PROFILE_ARGS[@]}" -gt 0 ]; then
      _rec_cmdline_has_args "$pid" "${PROFILE_ARGS[@]}" || why="the new agent's launch arguments do not carry the profile's model and thinking level"
    fi
  fi
  if [ -z "$why" ]; then
    local rs; rs="$(printf '%s' "$op" | jq -r '.resume_session.path // empty')"
    if [ -n "$rs" ]; then _ho_cmdline_adjacent "$pid" --session "$rs" || why="the new agent was not launched with --session $rs"; fi
  fi
  printf '%s' "$why"
}

# After the old runtime is gone its session may have grown (a shutdown flush).
# Accept ONLY an append-only extension: the admitted bytes must be an exact
# prefix, and the extended file must have no unsettled tool call. Prints why not.
_ho_resume_recheck() { # <op-json>
  local op="$1" rs wb wsha cur
  rs="$(printf '%s' "$op" | jq -r '.resume_session.path // empty')"; [ -n "$rs" ] || return 0
  wb="$(printf '%s' "$op" | jq -r '.resume_session.bytes')"; wsha="$(printf '%s' "$op" | jq -r '.resume_session.sha256')"
  [ -f "$rs" ] || { printf 'the file %s is gone' "$rs"; return 0; }
  cur="$(stat -c %s "$rs")"
  [ "$cur" -ge "$wb" ] || { printf 'the file shrank (%s < %s admitted bytes)' "$cur" "$wb"; return 0; }
  [ "$(head -c "$wb" "$rs" | sha256sum | cut -c1-64)" = "$wsha" ] || { printf 'the admitted bytes are no longer an exact prefix (the file was rewritten, not appended to)'; return 0; }
  local un; un="$(_ho_session_unsettled "$rs")"
  [ -z "$un" ] || printf 'after retirement it has unsettled tool use: %s' "$un"
}

_ho_start_runtime() { # <wsdir> <op-json>   (dies on failure; the caller records the phase)
  local wsdir="$1" op="$2" id alias pane profile shape rt model thinking
  id="$(printf '%s' "$op" | jq -r .row_id)"; alias="$(printf '%s' "$op" | jq -r .alias)"; pane="$(printf '%s' "$op" | jq -r .pane)"
  profile="$(printf '%s' "$op" | jq -r .target.profile)"; rt="$(printf '%s' "$op" | jq -r .target.runtime)"
  model="$(printf '%s' "$op" | jq -r .target.model)"; thinking="$(printf '%s' "$op" | jq -r .target.thinking)"
  shape="$(printf '%s' "$op" | jq -r '.shape // "ship"')"
  local rt0; rt0="$(ws_runtime "$wsdir" worker)"
  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_ISOLATE="" PROFILE_VETO="" PROFILE_VIA=""
  profile_resolve "$wsdir" "$profile" "$rt0"
  [ -z "$PROFILE_VETO" ] || die "handoff: profile '$profile' is vetoed - $PROFILE_VETO"
  local rolefile="$CEL_ROOT/core/roles/worker.md" roletag=worker
  case "$shape" in scout) rolefile="$CEL_ROOT/core/roles/scout.md"; roletag=scout ;; spike) rolefile="$CEL_ROOT/core/roles/spike.md"; roletag=spike ;; esac
  local body; body="$(ws_render_role "$wsdir" "$rolefile")"
  local AGENT_ARGS=() AGENT_ROLE_FILE=""
  _run_agent_args "$rt" "$roletag" "$body" 0 "$wsdir"
  local -a PROFILE_ARGS=()
  profile_launch_args "$rt" "$model" "$thinking" "${PROFILE_ISOLATE:-}"
  [ "${#PROFILE_ARGS[@]}" -eq 0 ] || AGENT_ARGS=("${PROFILE_ARGS[@]}" "${AGENT_ARGS[@]}")
  _run_keep_model_args "$rt"
  _run_inbox_hook_args "$rt"
  local rs rssha; rs="$(printf '%s' "$op" | jq -r '.resume_session.path // empty')"
  if [ -n "$rs" ]; then
    # the old runtime may flush on shutdown: only an append-only extension of the
    # admitted bytes with settled tool calls is acceptable
    rssha="$(_ho_resume_recheck "$op")"
    [ -z "$rssha" ] || die "handoff: the selected working session cannot be resumed: $rssha"
    [ "$rt" = pi ] || die "handoff: explicit session selection is only known for pi"
    AGENT_ARGS=(--session "$rs" "${AGENT_ARGS[@]}")
  fi
  local -a launch_args=()
  mapfile -t launch_args < <(agent_launch_args "$rt")
  [ "${#launch_args[@]}" -eq 0 ] || AGENT_ARGS=("${launch_args[@]}" "${AGENT_ARGS[@]}")
  local inbox_me=""; [ -z "$(agent_inbox_hook "$rt" file)" ] || inbox_me="$alias"
  local -a GATEWAY_ENV=()
  _run_profile_gateway_setup "$rt" "$alias" 1 1 "$alias"
  local launch_prefix; launch_prefix="$(_run_launch_env "$roletag" "$wsdir" "$AGENT_ROLE_FILE" "$inbox_me")"
  local gateway_required=0
  if [ "${#GATEWAY_ENV[@]}" -gt 0 ]; then launch_prefix="${GATEWAY_ENV[*]}; $launch_prefix"; gateway_required=1; fi

  # the SAME readiness gate as delegate, bound to the retained shell: a terminal
  # or shell that changed since admission is somebody else's pane
  _RUN_HERDR="$HERDR"
  local want_ident; want_ident="$(printf '%s' "$op" | jq -r '.binding.terminal + ":" + (.binding.shell_pid|tostring)')"
  _run_pane_await_shell "$pane" "$want_ident"
  local pane_ident="$_RUN_PANE_IDENT"
  local envline; envline="$(printf 'eval "$(%s ws env %q)"' "$CEL_ROOT/bin/cel" "$(ws_name "$wsdir")")"
  if ! _ledger_spawn "$HERDR" pane run "$pane" "$envline" > /dev/null 2>&1; then
    c_warn "could not load the workspace env into $pane - a profile needing a provider key will fail there"
  fi
  _run_pane_await_shell "$pane" "$pane_ident"
  _RUN_STAGED=0
  if ! _ledger_spawn "$HERDR" pane send-text "$pane" "$launch_prefix" > /dev/null 2>&1; then
    [ "$gateway_required" != 1 ] || die "handoff: could not stage gateway credentials in pane $pane"
    c_warn "could not mark $pane with its role environment - cel gc will not recognise it"
  else
    _RUN_STAGED=1
    _run_pane_recheck "$pane" "$pane_ident"
  fi
  _RUN_AGENT_QUIET=1 _RUN_AGENT_SPAWN=_ledger_spawn _run_agent_start "$pane" "$alias" "$rt" "${AGENT_ARGS[@]}"
}

_ho_prompt_text() { # <wsdir> <row-json> <op-json>
  local wsdir="$1" row="$2" op="$3" repo branch shape wt product orch ws_sel base base_prompt
  repo="$(printf '%s' "$row" | jq -r .repo)"; branch="$(printf '%s' "$row" | jq -r .branch)"; shape="$(printf '%s' "$row" | jq -r '.shape // "ship"')"
  wt="$(printf '%s' "$row" | jq -r .worktree)"
  product="$(ws_product_of_repo "$wsdir" "$repo")"; orch="$(_run_agent_name "$product-orch")"
  ws_sel="$(printf '%q' "$(ws_name "$wsdir")")"
  base="$(repo_default_ref "$wt" 2>/dev/null || true)"; [ -n "$base" ] || base="origin/main"
  base_prompt="$(_fanout_worker_prompt "$wsdir" "$shape" "$repo" "$branch" "$(printf '%s' "$row" | jq -r .spec)" "" "$base" "$orch" "$ws_sel")"
  printf 'You are the replacement owner of an existing worktree (handoff %s). FIRST read the handoff brief %s - it says what you inherit and that the previous owner'"'"'s uncommitted work and private .agent/ files must be kept. Then continue the task:\n\n%s' \
    "$(printf '%s' "$op" | jq -r .opid)" "$(printf '%s' "$op" | jq -r .brief)" "$base_prompt"
}

_ho_complete() { # <wsdir> <opid> <id>
  local wsdir="$1" opid="$2" id="$3" op; op="$(_ho_read "$wsdir" "$opid")"
  _ledger_patch "$wsdir" "$id" '
      .handoff = ((.handoff // {}) + {session:$sess, prior:{runtime:.runtime, model:.model, thinking:.thinking, profile:.profile, provider:.provider}, prior_review:(.review // null), review_carried:false})
    | .profile = $p | .runtime = $rt | .model = $m | .thinking = $th | .provider = $pv
    | .profile_reason = ("handoff " + $op + ": retained-runtime handoff")
    | del(.review) | .launch = {phase:"dispatched", at:$at}' \
    --arg p "$(printf '%s' "$op" | jq -r .target.profile)" --arg rt "$(printf '%s' "$op" | jq -r .target.runtime)" \
    --arg m "$(printf '%s' "$op" | jq -r .target.model)" --arg th "$(printf '%s' "$op" | jq -r .target.thinking)" \
    --arg pv "$(printf '%s' "$op" | jq -r .target.provider)" --arg op "$opid" --arg at "$(_now_iso)" \
    --argjson sess "$(printf '%s' "$op" | jq -c 'if .resume_session then (.resume_session + {continuity:"process launched on this exact session file; model-side continuity is not claimed"}) else {selection:"fresh"} end')"
  _ledger_update_state "$wsdir" "$id" running
  _ho_phase "$wsdir" "$opid" "$id" done "replacement owns the worktree: assistant turn and tool activity seen"
}

cmd_handoff_apply() {
  [ $# -ge 1 ] || die "usage: cel-fanout handoff apply <id> --profile NAME --pane P --shell-pid N --agent-pid N --agent-start TICKS --head SHA --source-digest HEX --evidence TEXT [--reissue-retire] [--workspace NAME]"
  local id="$1"; shift
  local ws_opt="" profile="" pane="" shell="" apid="" astart="" head="" digest="" evidence="" reissue=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace)     ws_opt="$2"; shift 2 ;;
      --profile)       profile="$2"; shift 2 ;;
      --pane)          pane="$2"; shift 2 ;;
      --shell-pid)     shell="$2"; shift 2 ;;
      --agent-pid)     apid="$2"; shift 2 ;;
      --agent-start)   astart="$2"; shift 2 ;;
      --head)          head="$2"; shift 2 ;;
      --source-digest) digest="$2"; shift 2 ;;
      --evidence)      evidence="$2"; shift 2 ;;
      --reissue-retire) reissue=1; shift ;;
      --preserved-export) HO_EXPORT="$2"; shift 2 ;;
      --resume-session) HO_RESUME="$2"; shift 2 ;;
      --resume-sha)     HO_RESUME_SHA="$2"; shift 2 ;;
      *) die "handoff apply: unknown argument: $1" ;;
    esac
  done
  local m
  for m in profile:profile pane:pane shell:shell-pid apid:agent-pid astart:agent-start head:head digest:source-digest evidence:evidence; do
    local v="${m%%:*}"
    [ -n "${!v}" ] || die "handoff apply: --${m##*:} is required - apply is bound to an inspected plan (run: cel-fanout handoff inspect $id --pane <pane> --profile <profile>); nothing is guessed"
  done
  if [ -n "$HO_RESUME" ] && [ -z "$HO_RESUME_SHA" ]; then die "handoff apply: --resume-session needs --resume-sha <sha256 from the inspected plan> - the working session is bound by content"; fi
  case "$shell$apid$astart" in *[!0-9]*) die "handoff apply: --shell-pid, --agent-pid and --agent-start must be numbers" ;; esac
  case "$pane" in *[!A-Za-z0-9:_-]*) die "handoff apply: --pane is not a herdr pane id" ;; esac
  [ "${#evidence}" -le 400 ] && case "$evidence" in *$'\n'*) false ;; esac || die "handoff apply: --evidence is one line of at most 400 characters"
  local wsdir; wsdir="$(_fanout_wsdir "$ws_opt")"
  local row; row="$(_ledger_entry "$wsdir" "$id")"
  [ -n "$row" ] || die "handoff apply: no delegation with id '$id'"

  # THE PER-TARGET LOCK: held, never released, until this process ends. A second
  # attempt on the same target cannot interleave, even while the ledger lock is
  # let go for a bounded wait.
  mkdir -p "$(_ho_dir "$wsdir")"
  _ho_lock_acquire "$wsdir" "$id" || die "handoff apply: another handoff attempt for $id holds the target lock (live pid $HO_LOCK_HOLDER) - refusing to interleave; nothing changed"

  local abs_wt spec alias
  abs_wt="$(cd "$(printf '%s' "$row" | jq -r '.worktree')" 2>/dev/null && pwd -P || true)"
  spec="$(printf '%s' "$row" | jq -r '.spec // ""')"; alias="$(printf '%s' "$row" | jq -r '.alias // ""')"
  local opid
  opid="$(_ho_opid "$(ws_name "$wsdir")" "$id" "$abs_wt" "$alias" "$pane" "$shell" "$apid" "$astart" "$head" "$digest" "$profile" "$spec" "${HO_RESUME:-}")"
  local op; op="$(_ho_read "$wsdir" "$opid")"
  local phase=""; [ -z "$op" ] || phase="$(printf '%s' "$op" | jq -r .phase)"

  if [ "$phase" = admitting ]; then
    # a crash between the operation record and the ledger mark: nothing
    # irreversible happened yet, so re-mark idempotently (the retire step
    # revalidates everything again before it stops anything)
    _ledger_patch "$wsdir" "$id" '.handoff = {id:$op, phase:"admitted", at:$at}' --arg op "$opid" --arg at "$(_now_iso)"
    _ledger_update_state "$wsdir" "$id" unconfirmed
    _ho_phase "$wsdir" "$opid" "$id" admitted "re-marked after an interrupted admission"
    op="$(_ho_read "$wsdir" "$opid")"; phase=admitted
  fi
  if [ "$phase" = done ]; then c_ok "$id: handoff $opid is already complete - nothing changed"; return 0; fi

  # ---- REVALIDATE, immediately before the first mutation (fresh operation) ---
  if [ -z "$op" ]; then
    _ho_gather "$wsdir" "$id" "$pane" "$profile" "" "$shell" "$apid" "$astart" "$head" "$digest"
    if [ "${#HO_WHY[@]}" -gt 0 ]; then
      local w; printf 'handoff apply: REFUSED - nothing was changed (no operation recorded, no ledger write, no herdr mutation):\n' >&2
      for w in "${HO_WHY[@]}"; do printf '  - %s\n' "$w" >&2; done
      exit 1
    fi
    local snap="$HO_SNAP" brief shape
    shape="$(printf '%s' "$row" | jq -r '.shape // "ship"')"
    # ---- ADMIT: durable evidence and ownership BEFORE anything irreversible ----
    local d; d="$(_ho_dir "$wsdir")"
    _ho_agent_text "$alias" > "$d/$opid.pane-before.txt"
    brief="$(_ho_brief "$wsdir" "$opid" "$row" "$snap" "$profile")"
    op="$(jq -n --arg opid "$opid" --arg id "$id" --argjson snap "$snap" --arg brief "$brief" --arg ev "$evidence" \
        --argjson arch "$(if [ -n "${HO_EXPORT:-}" ] && [ -f "$HO_EXPORT" ]; then jq -n --arg p "$HO_EXPORT" --arg sha "$(sha256sum "$HO_EXPORT" | cut -c1-64)" '{path:$p, sha256:$sha, role:"immutable-archive-evidence", proves_quiescence:false}'; else echo null; fi)" \
        --arg shape "$shape" --arg at "$(_now_iso)" --arg by "$(_ledger_mover)" --arg spec "$spec" --arg ws "$(ws_name "$wsdir")" \
        --argjson prior "$(printf '%s' "$row" | jq -c '{state, runtime, model, thinking, profile, review:(.review // null), launch:(.launch // null)}')" \
        '{opid:$opid, row_id:$id, workspace:$ws, alias:$snap.alias, pane:$snap.pane, worktree:$snap.worktree, spec:$spec, shape:$shape,
          created:$at, by:$by, evidence:$ev, brief:$brief,
          binding:{terminal:$snap.runtime.terminal, shell_pid:($snap.runtime.shell_pid|tonumber), agent_pid:($snap.runtime.agent_pid|tonumber),
                   agent_start:$snap.runtime.agent_start, old_kind:$snap.runtime.kind, session:$snap.runtime.session,
                   head:$snap.source.head, remote_ref:$snap.source.remote_ref, relation:$snap.source.relation,
                   ahead:$snap.source.ahead, behind:$snap.source.behind, dirty_and_untracked:$snap.source.dirty_and_untracked,
                   source_digest:$snap.source.digest},
          target:$snap.target, context:$snap.context, resume_session:$snap.resume_session, archive:$arch, prior_row:$prior,
          phase:"admitting", phases:[]}')"
    _ho_write "$wsdir" "$opid" "$op" || die "handoff apply: could not write the operation record - nothing changed"
    _rec_crash_point ho-after-record
    _ledger_patch "$wsdir" "$id" '.handoff = {id:$op, phase:"admitted", at:$at}' --arg op "$opid" --arg at "$(_now_iso)"
    _ledger_update_state "$wsdir" "$id" unconfirmed
    _ho_phase "$wsdir" "$opid" "$id" admitted "bound to ${apid}@${astart}, HEAD ${head:0:12}, source ${digest:0:12}, profile $profile"
    _rec_crash_point ho-after-admit
    phase=admitted
    op="$(_ho_read "$wsdir" "$opid")"
    c_ok "$id: handoff $opid admitted (source relation: $(printf '%s' "$snap" | jq -r .source.relation), $(printf '%s' "$snap" | jq -r .source.dirty_and_untracked) dirty/untracked path(s) bound)"
  else
    c_ok "$id: handoff $opid found at phase $phase - continuing the SAME operation"
  fi

  local tries="${CEL_FANOUT_CONFIRM_TRIES:-5}"

  # ---- RETIRE ---------------------------------------------------------------
  case "$phase" in
    admitted|retiring|retire-unconfirmed)
      local do_stop=0
      if [ "$phase" = admitted ]; then do_stop=1
      else
        if _ho_retired_now "$op"; then
          _ho_phase "$wsdir" "$opid" "$id" retired "observed: the old agent is gone and the same shell is back in the foreground"
          phase=retired
        elif [ "$reissue" -eq 1 ]; then
          # one more stop is allowed only against the SAME unchanged identity
          _ho_gather "$wsdir" "$id" "$pane" "$profile" "$opid" "$shell" "$apid" "$astart" "$head" "$digest"
          if [ "${#HO_WHY[@]}" -gt 0 ]; then
            local w; printf 'handoff apply: --reissue-retire REFUSED - the old runtime is not the unchanged, quiescent identity (nothing sent):\n' >&2
            for w in "${HO_WHY[@]}"; do printf '  - %s\n' "$w" >&2; done
            exit 1
          fi
          do_stop=1
        else
          die "handoff apply: $opid: the old agent is still present (phase $phase). The stop request may not have been delivered or may still be taking effect. NOT repeated. Next: $(_ho_next "$phase" "$opid" "$id")"
        fi
      fi
      if [ "$do_stop" -eq 1 ]; then
        # the revalidation is repeated against the live world once more, right
        # before the call, so a change since admission cannot be retired
        _ho_gather "$wsdir" "$id" "$pane" "$profile" "$opid" "$shell" "$apid" "$astart" "$head" "$digest"
        if [ "${#HO_WHY[@]}" -gt 0 ]; then
          local w; printf 'handoff apply: the world changed after admission - NOT retiring (operation %s stays admitted; re-run once it is quiescent again):\n' "$opid" >&2
          for w in "${HO_WHY[@]}"; do printf '  - %s\n' "$w" >&2; done
          exit 1
        fi
        _ho_phase "$wsdir" "$opid" "$id" retiring "agent stop requested for $alias (${apid}@${astart})"
        _rec_crash_point ho-before-stop
        _ledger_unlock
        local err rc=0
        err="$("$(_ho_stop_adapter)" agent stop "$alias" 2>&1)" || rc=$?
        _rec_crash_point ho-after-stop
        local i gone=0
        for (( i = 0; i < tries; i++ )); do
          [ "$i" -eq 0 ] || sleep "${CEL_FANOUT_CONFIRM_SLEEP:-2}"
          if _ho_retired_now "$op"; then gone=1; break; fi
        done
        _ledger_relock
        if [ "$gone" -ne 1 ]; then
          _ho_phase "$wsdir" "$opid" "$id" retire-unconfirmed "agent stop returned rc=$rc ($(printf '%s' "$err" | head -1 | cut -c1-100)); the old agent is still visible or the shell is not back in the foreground"
          die "handoff apply: $opid: retirement is NOT confirmed (herdr agent stop rc=$rc: $(printf '%s' "$err" | head -1 | cut -c1-100)). Durable debt retired-unknown: nothing was started. Next: $(_ho_next retire-unconfirmed "$opid" "$id")"
        fi
        _ho_phase "$wsdir" "$opid" "$id" retired "old runtime retired by herdr agent stop; the pane shell, worktree, session and private artifacts are untouched"
        phase=retired
      fi
      op="$(_ho_read "$wsdir" "$opid")" ;;
  esac

  # ---- START ----------------------------------------------------------------
  case "$phase" in
    retired)
      # the source, the pane and the name must still be exactly what was admitted
      local wt; wt="$(printf '%s' "$op" | jq -r .worktree)"
      [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$(printf '%s' "$op" | jq -r .binding.head)" ] \
        || die "handoff apply: $opid: the worktree HEAD moved since admission - NOT starting a replacement on different source; operation stays retired (debt)"
      [ "$(_ho_source_digest "$wt" | cut -d' ' -f1)" = "$(printf '%s' "$op" | jq -r .binding.source_digest)" ] \
        || die "handoff apply: $opid: the dirty/untracked bytes changed since admission - NOT starting; operation stays retired (debt)"
      local rr; rr="$(_ho_resume_recheck "$op")"
      [ -z "$rr" ] || die "handoff apply: $opid: the old runtime is retired but the selected session cannot be resumed: $rr. NOT starting; the operation stays 'retired' (debt) and may be re-run once the file is an append-only extension with settled tool calls"
      _ho_phase "$wsdir" "$opid" "$id" starting "starting $(printf '%s' "$op" | jq -r .target.model) in the retained shell (never retried: a herdr start can time out after the agent exists)"
      _rec_crash_point ho-before-start
      local ok=1
      ( _ho_start_runtime "$wsdir" "$op" ) || ok=0
      _rec_crash_point ho-after-start
      if [ "$ok" -ne 1 ]; then
        _ho_phase "$wsdir" "$opid" "$id" start-failed "herdr agent start failed or timed out - an agent may still exist in the pane"
        _ledger_patch "$wsdir" "$id" '.launch = {phase:"start-failed", at:$at, note:"handoff start failed or timed out - an agent may exist; not retried"}' --arg at "$(_now_iso)"
        die "handoff apply: $opid: the replacement start did not complete - NOT retried. The old runtime is already retired and the worktree is intact. An agent MAY exist in $pane. Next: $(_ho_next start-failed "$opid" "$id")"
      fi
      phase=started
      _ho_phase "$wsdir" "$opid" "$id" started "herdr agent start returned; identity not yet verified" ;;
    starting|start-failed)
      # A start herdr never confirmed may have produced an agent. If exactly one
      # new agent named for the alias is now visible, it is ADOPTED (its identity
      # is verified before anything is sent); otherwise nothing is started again.
      if _ho_find_new "$op"; then
        _ho_phase "$wsdir" "$opid" "$id" started "adopted: exactly one new agent named $alias is visible in $pane after an unconfirmed start; identity is verified before any prompt"
        phase=started
      else
        die "handoff apply: $opid: phase $phase - the replacement start was never confirmed and no verifiable new agent is visible, so an agent MAY exist or still appear in $pane. NOT restarted (that could create a second owner). Next: $(_ho_next "$phase" "$opid" "$id")"
      fi ;;
  esac

  # ---- VERIFY the replacement, then PROMPT ONCE -------------------------------
  case "$phase" in
    started|started-unverified)
      if ! _ho_find_new "$op"; then
        _ho_phase "$wsdir" "$opid" "$id" started-unverified "no single new agent named $alias is visible in $pane"
        die "handoff apply: $opid: no verifiable replacement agent is visible in $pane yet - nothing was prompted. Next: $(_ho_next started-unverified "$opid" "$id")"
      fi
      local why; why="$(_ho_verify_new "$op" "$wsdir")"
      if [ -n "$why" ]; then
        _ho_phase "$wsdir" "$opid" "$id" started-unverified "$why"
        die "handoff apply: $opid: the replacement is not the requested runtime ($why) - refusing to prompt it; durable debt, nothing was sent"
      fi
      if [ "$HO_NEW_READY" -ne 1 ]; then
        _ho_phase "$wsdir" "$opid" "$id" started-unverified "the new agent is not idle/interactive_ready (or herdr reports launch_pending)"
        die "handoff apply: $opid: herdr does not yet report the replacement ready - nothing was prompted. Re-run when it is"
      fi
      _rec_pane_unstarted "$alias" || { _ho_phase "$wsdir" "$opid" "$id" started-unverified "the new pane is not provably unstarted"; die "handoff apply: $opid: the replacement's pane already shows a turn or context - a task there could not be told from ours; not prompting"; }
      local row2 prompt
      row2="$(_ledger_entry "$wsdir" "$id")"
      prompt="$(_ho_prompt_text "$wsdir" "$row2" "$op")"
      _ho_phase "$wsdir" "$opid" "$id" prompting "task prompt being submitted ONCE" \
        "$(jq -n --arg sha "$(printf '%s' "$prompt" | sha256sum | cut -c1-16)" --argjson p "$HO_NEW_PID" --arg s "$HO_NEW_START" '{new:{agent_pid:$p, agent_start:$s}, prompt_sha:$sha}')"
      _rec_crash_point ho-before-prompt
      _ledger_unlock
      local perr prc=0
      perr="$("$HERDR" agent prompt "$alias" "$prompt" 2>&1)" || prc=$?
      _rec_crash_point ho-after-prompt
      if [ "$prc" -ne 0 ]; then
        _ledger_relock
        case "$perr" in
          *agent_not_ready*|*agent_launch_pending*|*empty_agent_prompt*|*agent_not_running*|*agent_blocked*|*agent_name_not_found*)
            _ho_phase "$wsdir" "$opid" "$id" started "herdr refused the prompt (nothing delivered): $(printf '%s' "$perr" | head -1 | cut -c1-100)"
            die "handoff apply: $opid: herdr refused the prompt - nothing was delivered; the operation is back at 'started' and may be re-run" ;;
          *)
            _ho_phase "$wsdir" "$opid" "$id" ambiguous "herdr prompt failed with unknown delivery: $(printf '%s' "$perr" | head -1 | cut -c1-100)"
            die "handoff apply: $opid: the prompt call failed in a way that does not say whether the text arrived - marked ambiguous, NEVER resubmitted. Next: $(_ho_next ambiguous "$opid" "$id")" ;;
        esac
      fi
      local seen=0
      _ho_accepted "$alias" "$tries" && seen=1
      _ledger_relock
      if [ "$seen" -eq 1 ]; then
        _ho_complete "$wsdir" "$opid" "$id"
        c_ok "$id: handoff $opid complete - $(printf '%s' "$op" | jq -r .target.model) now owns the retained worktree (assistant turn and tool activity seen); prior review approval was NOT carried over"
        printf '%s\n' "$id"; return 0
      fi
      _ho_phase "$wsdir" "$opid" "$id" unconfirmed-acceptance "prompt submitted once; no assistant turn with tool activity yet"
      die "handoff apply: $opid: the task was submitted once but no assistant turn with tool activity is visible. Durable debt; NEVER resubmitted. Next: $(_ho_next unconfirmed-acceptance "$opid" "$id")" ;;
    prompting|ambiguous|unconfirmed-acceptance)
      local seen2=0
      _ledger_unlock
      _ho_accepted "$alias" "$tries" && seen2=1
      _ledger_relock
      if [ "$seen2" -eq 1 ]; then
        _ho_complete "$wsdir" "$opid" "$id"
        c_ok "$id: handoff $opid complete - task evidence seen; nothing was sent now"
        printf '%s\n' "$id"; return 0
      fi
      _ho_phase "$wsdir" "$opid" "$id" unconfirmed-acceptance "re-checked: no assistant turn with tool activity yet"
      die "handoff apply: $opid: a task may or may not have been delivered and no execution evidence is visible yet. NOT resubmitting. Next: $(_ho_next unconfirmed-acceptance "$opid" "$id")" ;;
    *) die "handoff apply: $opid: unknown phase '$phase' - nothing changed" ;;
  esac
}

cmd_handoff() {
  # the pane-evidence greps match multibyte turn/tool glyphs: pin a UTF-8 locale,
  # or a C-locale caller would never see acceptance evidence (safe but stuck)
  export LC_ALL=C.UTF-8
  local sub="${1:-}"; [ $# -eq 0 ] || shift
  case "$sub" in
    inspect) cmd_handoff_inspect "$@" ;;
    apply)   cmd_handoff_apply "$@" ;;
    status)  cmd_handoff_status "$@" ;;
    hold)    cmd_handoff_hold "$@" ;;
    settle)  cmd_handoff_settle "$@" ;;
    *) die "usage: cel-fanout handoff inspect|apply|status|hold|settle ..." ;;
  esac
}
