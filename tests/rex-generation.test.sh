# shellcheck shell=bash
# Rex server restarts (the safety net) and the managed rex upgrade, against a
# fake Rex server, fake apt and a fake `cel` that plays the canonical launch.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/steward.sh"

_rg_setup() {
  RT="$(mktemp -d)"
  export CEL_REX_STATE="$RT/state" CEL_REX_BIN="$RT/bin/rex" CEL_ORCH_SESSIONS="$RT/sessions.json"
  export CEL_INBOX_DIR="$RT/inbox" CEL_REGISTRY="$RT/registry.yaml" CEL_STEWARD_STATE="$RT/steward-state"
  export CEL_REX_RESUME_SETTLE_SECS=0 CEL_REX_SERVER_WAIT_TENTHS=20 REXT_LOG="$RT/relaunched" CEL_INBOX_NOTIFY=0
  export REXT_SRV="$RT/srv" REXT_CALLS="$RT/calls"
  _STEWARD_STATE="$CEL_STEWARD_STATE"
  mkdir -p "$RT/bin" "$RT/celroot/bin" "$RT/ws" "$CEL_REX_STATE" "$CEL_INBOX_DIR" "$REXT_SRV/sess"
  # The plane as installed, except `cel` itself (below).
  local e
  for e in "$CEL_ROOT"/*; do [ "${e##*/}" = bin ] || ln -s "$e" "$RT/celroot/${e##*/}"; done
  printf 'name: alpha\nrepos: [{name: widget}]\n' > "$RT/ws/workspace.yaml"
  printf 'workspaces:\n  alpha: {path: "%s/ws"}\n' "$RT" > "$CEL_REGISTRY"
  printf '{}' > "$CEL_ORCH_SESSIONS"
  # The old server: tailnet on, API revision 0, persistent.
  printf instance-A > "$REXT_SRV/instance"; printf running > "$REXT_SRV/tailscale"
  printf 0 > "$REXT_SRV/api"; printf v1 > "$REXT_SRV/version"; printf false > "$REXT_SRV/exit_empty"
  # The Rex server. Sessions are files <id>: "<label>\t<block>\t<runtime pid|>".
  # An --exit-empty server exits when its last session closes.
  cat > "$RT/bin/rex" <<'SH'
#!/bin/bash
[ "$1" = --autostart=false ] || { echo "autostart was not refused: $*" >&2; exit 9; }
shift
S="$REXT_SRV"
[ -s "$S/instance" ] || exit 1
case "$*" in
  'server status --json')
    jq -n --arg i "$(cat "$S/instance")" --arg t "$(cat "$S/tailscale")" --argjson a "$(cat "$S/api")" \
      --arg v "$(cat "$S/version")" --argjson e "$(cat "$S/exit_empty")" \
      '{instance_id:$i, rex_version:$v, api_revision:$a, exit_empty:$e, tailscale:{state:$t}}' ;;
  'server tailscale on') echo 'tailscale on' >> "$REXT_CALLS"; printf running > "$S/tailscale" ;;
  'ls --json')
    for f in "$S"/sess/*; do [ -f "$f" ] || continue
      IFS=$'\t' read -r l b p < "$f"; jq -nc --arg s "${f##*/}" --arg l "$l" '{session_id:$s,label:$l}'
    done | jq -sc '{sessions: .}' ;;
  'session inspect '*' --json')
    f="$S/sess/$3"; [ -f "$f" ] || exit 1
    IFS=$'\t' read -r l b p < "$f"
    # block "none": a session whose topology shows no block at all
    if [ "$b" = none ]; then jq -n --arg s "$3" '{session_id:$s, windows:[{window_id:"w", layers:[{blocks:[]}]}]}'
    else jq -n --arg s "$3" --arg b "$b" '{session_id:$s, windows:[{window_id:"w", layers:[{blocks:[{block_id:$b}]}]}]}'; fi ;;
  'block call process {} -s '*)
    f="$S/sess/$6"; [ -f "$f" ] || exit 1
    IFS=$'\t' read -r l b p < "$f"
    # blocks "omits"/"errors": reports that do not name child and foreground
    # as null, or carry an error
    if [ "$b" = omits ]; then printf '{"last_exit":{"exit_code":0}}\n'
    elif [ "$b" = errors ]; then printf '{"child":null,"foreground":null,"error":{"code":"internal"}}\n'
    elif [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then jq -n --argjson p "$p" '{child:{pid:$p},foreground:{pid:$p},last_exit:null}'
    else printf '{"child":null,"foreground":null,"last_exit":{"exit_code":0}}\n'; fi ;;
  'kill '*)
    echo "kill $2" >> "$REXT_CALLS"; rm -f "$S/sess/$2"
    if [ "$(cat "$S/exit_empty")" = true ] && [ -z "$(ls "$S/sess")" ]; then : > "$S/instance"; fi ;;
  *) exit 1 ;;
esac
SH
  # `cel run ...`: the canonical launch, played: a NEW runtime in a new Rex
  # session under the same receipt, as _rex_launch would publish it. It needs a
  # running server (REX_AUTOSTART=false). Product "broken" is refused.
  cat > "$RT/celroot/bin/cel" <<'SH'
#!/bin/bash
printf '%s|%s\n' "${REX_AUTOSTART:-}" "$*" >> "$REXT_LOG"
product="" lane=""
while [ $# -gt 0 ]; do
  case "$1" in --product) product="$2"; shift 2 ;; --lane) lane="$2"; shift 2 ;; *) shift ;; esac
done
[ -s "$REXT_SRV/instance" ] || { echo 'Error: no Rex server is running' >&2; exit 1; }
[ "$product" != broken ] || { echo 'cel run: the launch was refused' >&2; exit 1; }
name="$product-${lane:-orch}"
sleep 300 >/dev/null 2>&1 &
pid=$!
printf '%s\tblock:new\t%s\n' "$name" "$pid" > "$REXT_SRV/sess/session:new-$name"
s="$(cat "/proc/$pid/stat")"; s="${s##*) }"; set -- $s
jq --argjson p "$pid" --arg s "${20}" '.pid=$p | .pid_start=$s | .agent_status="working"' \
  "$CEL_REX_STATE/$name.json" > "$CEL_REX_STATE/$name.tmp" && mv "$CEL_REX_STATE/$name.tmp" "$CEL_REX_STATE/$name.json"
SH
  chmod +x "$RT/bin/rex" "$RT/celroot/bin/cel"
  # A server cel starts: persistent, a new instance, the newer API, and (to
  # prove the fallback) without the tailnet. It restores what was saved.
  _rex_server_start() {
    echo "start ${1:-}" >> "$REXT_CALLS"
    printf off > "$REXT_SRV/tailscale"; printf 10 > "$REXT_SRV/api"; printf v2 > "$REXT_SRV/version"
    printf false > "$REXT_SRV/exit_empty"; printf 'instance-cel%s' "$RANDOM" > "$REXT_SRV/instance"
  }
}

_rg_down() {
  local f
  for f in "$CEL_REX_STATE"/*.json; do
    if [ -f "$f" ] && _rex_live "$f"; then kill "$(jq -r .pid "$f")" 2>/dev/null || true; fi
  done
  [ -z "${RG_PIDS:-}" ] || kill $RG_PIDS 2>/dev/null || true
  unset CEL_REX_STATE CEL_REX_BIN CEL_ORCH_SESSIONS CEL_INBOX_DIR CEL_REGISTRY CEL_STEWARD_STATE REXT_LOG REXT_SRV REXT_CALLS
  rm -rf "$RT"
}

_rg_detached_sleep() { sleep 300 >/dev/null 2>&1 & printf '%s' "$!"; }

# A live managed launch in its own Rex session: a real process, its receipt
# and (when resumable) its relaunch line and saved session.
_rg_agent() { # <name> <role> <status> [relaunch-json]
  local name="$1" role="$2" status="$3" relaunch="${4:-null}" cwd="$RT/ws/products/${1%-*}" pid start
  mkdir -p "$cwd"
  # Detached (reparented), as a runtime under a Rex server is: nothing here
  # has to reap it, so a killed one is gone rather than a lingering zombie.
  pid="$(_rg_detached_sleep)"
  RG_PIDS="${RG_PIDS:-} $pid"
  start="$(_rex_pid_start "$pid")"
  printf '%s\tblock:%s\t%s\n' "$name" "$name" "$pid" > "$REXT_SRV/sess/session:$name"
  jq -n --arg n "$name" --arg role "$role" --arg st "$status" --arg cwd "$cwd" --arg ws "$RT/ws" \
    --argjson pid "$pid" --arg start "$start" --argjson relaunch "$relaunch" --arg sess "$RT/sessions/$name.jsonl" \
    '{name:$n,agent:"omp",cwd:$cwd,role:$role,workspace:$ws,repo:"widget",pr:"7",backend:"rex",
      rex_session:("session:" + $n),rex_block:("block:" + $n),pane_id:("rex/session:" + $n + "/block:" + $n),pid:$pid,pid_start:$start,
      agent_status:$st,agent_session:{value:$sess}}
     | if $relaunch != null then .relaunch=$relaunch else . end' > "$CEL_REX_STATE/$name.json"
  _run_sessions_record "$cwd" "$RT/sessions/$name.jsonl" omp
}
_rg_line() { printf '%s\0' run orchestrator --product "$1" --workspace alpha --session-backend rex --model m1 | jq -Rsc 'split("\u0000") | .[:-1]'; }

# Everything the server ran ends with it. The server that answers next is a
# client autostart: --exit-empty, no tailnet, API revision 10, and its old
# sessions restored as empty shells under the same labels. "" = none answers.
_rg_server_restart() { # <new-instance|"">
  local f i l b p
  for f in "$CEL_REX_STATE"/*.json; do
    if [ -f "$f" ]; then kill "$(jq -r .pid "$f")" 2>/dev/null || true; fi
  done
  for f in "$CEL_REX_STATE"/*.json; do
    for ((i = 0; i < 100; i++)); do { [ -f "$f" ] && _rex_live "$f"; } || break; sleep 0.05; done
  done
  for f in "$REXT_SRV"/sess/*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r l b p < "$f"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then kill "$p"; fi
    printf '%s\t%s\t\n' "$l" "$b" > "$f"
  done
  printf off > "$REXT_SRV/tailscale"; printf 10 > "$REXT_SRV/api"; printf v2 > "$REXT_SRV/version"
  printf true > "$REXT_SRV/exit_empty"; printf '%s' "$1" > "$REXT_SRV/instance"
}

test_rex_server_restart_resumes_each_previously_live_agent_exactly_once() {
  _rg_setup
  _rg_agent alpha-orch solo idle "$(_rg_line alpha)"
  _rg_agent broken-orch orchestrator idle "$(_rg_line broken)"
  _rg_agent stopped-orch solo idle "$(_rg_line stopped)"
  _rg_agent retiring-orch solo idle "$(_rg_line retiring)"
  _rg_agent widget-pr-7-review reviewer idle
  local out
  out="$(CEL_ROOT="$RT/celroot" rex_generation_tick)"
  assert_eq "$out" ""   # the first observation has nothing to compare with
  # Deliberate ends before the restart: a stop removes the receipt, a
  # retirement writes its prepared packet first.
  kill "$(jq -r .pid "$CEL_REX_STATE/stopped-orch.json")"; rm -f "$CEL_REX_STATE/stopped-orch.json"
  mkdir -p "$CEL_REX_STATE/retirements"
  : > "$CEL_REX_STATE/retirements/retiring-orch-$(jq -r .pid "$CEL_REX_STATE/retiring-orch.json")-$(jq -r .pid_start "$CEL_REX_STATE/retiring-orch.json")-u.json"
  _rg_server_restart instance-B

  out="$(CEL_ROOT="$RT/celroot" rex_generation_tick)"
  assert_eq "$(sed -n 1p <<<"$out")" "$(printf 'generation\tinstance-A\tinstance-B')"
  assert_contains "$out" "$(printf 'resumed\talpha-orch\t%s\t%s' "$RT/ws" "$RT/sessions/alpha-orch.jsonl")"
  assert_contains "$out" "$(printf 'failed\tbroken-orch\t%s\tcel run: the launch was refused' "$RT/ws")"
  assert_contains "$out" "$(printf 'skipped\tstopped-orch\t\tstopped or retired since')"
  assert_contains "$out" "$(printf 'skipped\tretiring-orch\t%s\tits retirement had begun' "$RT/ws")"
  assert_contains "$out" "$(printf 'held\twidget-pr-7-review\t%s\treviewers never resume' "$RT/ws")"
  # The server is described before and after; the API revision was 0.
  assert_contains "$out" "$(printf 'server\tversion\t\trex v1, API revision 0 -> rex v2, API revision 10')"
  # Only the two with a canonical line were run, through their own line,
  # and never allowed to start a Rex server inside the caller's cgroup.
  assert_eq "$(cat "$REXT_LOG")" "$(printf 'false|run orchestrator --product alpha --workspace alpha --session-backend rex --model m1\nfalse|run orchestrator --product broken --workspace alpha --session-backend rex --model m1')"
  _rex_live "$CEL_REX_STATE/alpha-orch.json" || { echo 'resumed agent is not alive'; _rg_down; return 1; }

  # ONCE: later ticks, the failed one included, never resume again.
  out="$(CEL_ROOT="$RT/celroot" rex_generation_tick)$(CEL_ROOT="$RT/celroot" rex_generation_tick)"
  assert_eq "$out" ""
  assert_eq "$(wc -l < "$REXT_LOG" | tr -d ' ')" 2
  _rg_down
}

# The restarted server serves the tailnet again because the old one did, and
# the restored shells of the agents being resumed are closed - only the dead
# ones: a session under the same label still running a program is kept.
test_rex_restart_restores_tailnet_and_closes_only_dead_restored_shells() {
  _rg_setup
  _rg_agent alpha-orch solo idle "$(_rg_line alpha)"
  _rg_agent widget-pr-7-review reviewer idle
  CEL_ROOT="$RT/celroot" rex_generation_tick >/dev/null
  _rg_server_restart instance-B
  # A second restored shell, and a same-label session somebody is running.
  printf 'alpha-orch\tblock:2\t\n' > "$REXT_SRV/sess/session:shell2"
  local other; other="$(_rg_detached_sleep)"; RG_PIDS="$RG_PIDS $other"
  printf 'alpha-orch\tblock:3\t%s\n' "$other" > "$REXT_SRV/sess/session:busy"
  local out; out="$(CEL_ROOT="$RT/celroot" rex_generation_tick)"
  assert_contains "$out" "$(printf 'server\tshells\t\tclosed dead restored sessions: alpha-orch (2)')"
  assert_contains "$out" "$(printf 'server\ttailscale\t\ttailnet serving restored (the new server came up off)')"
  assert_contains "$out" "$(printf 'resumed\talpha-orch')"
  assert_eq "$(cat "$REXT_CALLS")" "$(printf 'kill session:alpha-orch\nkill session:shell2\ntailscale on')"
  assert_eq "$(cat "$REXT_SRV/tailscale")" running
  [ -f "$REXT_SRV/sess/session:busy" ] || { echo 'closed a session running a program'; _rg_down; return 1; }
  # The held reviewer's restored shell is evidence, not ours to close.
  [ -f "$REXT_SRV/sess/session:widget-pr-7-review" ] || { echo 'closed a held agent'"'"'s shell'; _rg_down; return 1; }
  _rg_down
}

# Closing the last restored shell ends an --exit-empty server; the restore
# starts a persistent one (serving the tailnet) before any resume.
test_rex_restart_never_resumes_into_an_exited_exit_empty_server() {
  _rg_setup
  _rg_agent alpha-orch solo idle "$(_rg_line alpha)"
  CEL_ROOT="$RT/celroot" rex_generation_tick >/dev/null
  _rg_server_restart instance-B
  local out; out="$(CEL_ROOT="$RT/celroot" rex_generation_tick)"
  assert_eq "$(cat "$REXT_CALLS")" "$(printf 'kill session:alpha-orch\nstart running\ntailscale on')"
  assert_contains "$out" "$(printf 'server\trex\t\tstarted a persistent Rex server')"
  assert_contains "$out" "$(printf 'resumed\talpha-orch')"
  assert_eq "$(cat "$REXT_SRV/exit_empty")" false
  assert_eq "$(cat "$REXT_LOG")" 'false|run orchestrator --product alpha --workspace alpha --session-backend rex --model m1'
  # The generation now is the server cel started: the next tick is quiet.
  assert_eq "$(CEL_ROOT="$RT/celroot" rex_generation_tick)" ""
  _rg_down
}

# A receipt whose saved session disagrees, or that never reported one, is
# held rather than relaunched into a different or fresh conversation.
test_rex_restart_never_resumes_into_another_conversation() {
  _rg_setup
  _rg_agent alpha-orch solo idle "$(_rg_line alpha)"
  _rg_agent beta-orch solo idle "$(_rg_line beta)"
  CEL_ROOT="$RT/celroot" rex_generation_tick >/dev/null
  _run_sessions_record "$RT/ws/products/alpha" "$RT/sessions/someone-else.jsonl" omp
  jq 'del(.agent_session)' "$CEL_REX_STATE/beta-orch.json" > "$RT/b" && mv "$RT/b" "$CEL_REX_STATE/beta-orch.json"
  _rg_server_restart instance-B
  local out; out="$(CEL_ROOT="$RT/celroot" rex_generation_tick)"
  assert_contains "$out" "$(printf 'held\talpha-orch\t%s\tthe saved session' "$RT/ws")"
  assert_contains "$out" "$(printf 'held\tbeta-orch\t%s\tits runtime never reported a native session' "$RT/ws")"
  [ ! -e "$REXT_LOG" ] || { echo "relaunched: $(cat "$REXT_LOG")"; _rg_down; return 1; }
  _rg_down
}

# ONCE needs its record: if the new generation cannot be written, nothing is
# relaunched (a later tick would resume it a second time) and it is held.
test_rex_restart_resumes_nothing_when_the_generation_cannot_be_recorded() {
  _rg_setup
  _rg_agent alpha-orch solo idle "$(_rg_line alpha)"
  CEL_ROOT="$RT/celroot" rex_generation_tick >/dev/null
  _rg_server_restart instance-B
  _rex_generation_commit() { return 1; }
  local out; out="$(CEL_ROOT="$RT/celroot" rex_generation_tick)"
  assert_contains "$out" "$(printf 'held\talpha-orch\t%s\tthe new Rex server generation could not be recorded' "$RT/ws")"
  if grep -q '^resumed' <<<"$out"; then echo "resumed without a record: $out"; _rg_down; return 1; fi
  [ ! -e "$REXT_LOG" ] || { echo "relaunched: $(cat "$REXT_LOG")"; _rg_down; return 1; }
  _rg_down
}

# Only a report that NAMES child and foreground as null, for at least one
# block, is a dead shell. Omitted keys, an error, an empty topology, a live
# child or an unreadable session are all alive - never closed.
test_rex_dead_session_check_fails_closed() {
  _rg_setup
  local live; live="$(_rg_detached_sleep)"; RG_PIDS="$live"
  printf 'a\tblock:1\t\n' > "$REXT_SRV/sess/s-dead"
  printf 'a\tomits\t\n' > "$REXT_SRV/sess/s-omits"
  printf 'a\terrors\t\n' > "$REXT_SRV/sess/s-errors"
  printf 'a\tnone\t\n' > "$REXT_SRV/sess/s-empty"
  printf 'a\tblock:2\t%s\n' "$live" > "$REXT_SRV/sess/s-live"
  _rex_session_dead s-dead || { echo 'a named-null report was not dead'; _rg_down; return 1; }
  local s
  for s in s-omits s-errors s-empty s-live s-missing; do
    if _rex_session_dead "$s"; then echo "$s counted as dead"; _rg_down; return 1; fi
  done
  assert_eq "$(_rex_close_dead_duplicates a)" 1
  assert_eq "$(cat "$REXT_CALLS")" 'kill s-dead'
  _rg_down
}

# The steward says it once: one summary to root, one note per resumed agent.
test_steward_reports_a_rex_restart_once_to_root_and_notes_resumed_agents() {
  _rg_setup
  _rg_agent alpha-orch solo idle "$(_rg_line alpha)"
  _rg_agent widget-pr-7-review reviewer idle
  CEL_ROOT="$RT/celroot" _steward_rex_generation >/dev/null 2>&1
  _rg_server_restart instance-B
  CEL_ROOT="$RT/celroot" _steward_rex_generation >/dev/null 2>&1
  CEL_ROOT="$RT/celroot" _steward_rex_generation >/dev/null 2>&1
  local f="$CEL_INBOX_DIR/alpha.jsonl" msg
  assert_eq "$(jq -s '[.[] | select(.to == "root")] | length' "$f")" 1
  assert_eq "$(jq -rs '.[] | select(.to == "root") | .kind' "$f")" blocked
  msg="$(jq -rs '.[] | select(.to == "root") | .message' "$f")"
  assert_contains "$msg" 'Resumed in their saved sessions and alive: alpha-orch.'
  assert_contains "$msg" 'Not resumed: widget-pr-7-review (reviewers never resume'
  assert_contains "$msg" 'Rex server: '
  assert_contains "$msg" 'API revision 0 -> rex v2, API revision 10'
  assert_eq "$(jq -s '[.[] | select(.to == "alpha-orch")] | length' "$f")" 1
  assert_eq "$(jq -s '[.[] | select(.to == "widget-pr-7-review")] | length' "$f")" 0
  _rg_down
}

# ── the managed upgrade ──────────────────────────────────────────────────────
_rg_apt() { # installed candidate [origin]
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-https://pkgs.superlogical.com/rex/apt}" > "$RT/apt"
  _rex_apt_policy() {
    local i c o; IFS=$'\t' read -r i c o < "$RT/apt"
    printf 'rex:\n  Installed: %s\n  Candidate: %s\n  Version table:\n' "$i" "$c"
    printf '     1.16.1-1 -1\n        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages\n'
    printf '     %s 1001\n        500 %s snapshot/main amd64 Packages\n' "$c" "$o"
    printf ' *** %s 1001\n        100 /var/lib/dpkg/status\n' "$i"
  }
  _rex_apt_upgrade() {
    echo "apt $1" >> "$REXT_CALLS"
    local i c o; IFS=$'\t' read -r i c o < "$RT/apt"
    printf '%s\t%s\t%s\n' "$c" "$c" "$o" > "$RT/apt"
    [ -z "${RG_PACKAGE_RESTARTS:-}" ] || _rg_server_restart instance-pkg
  }
  # `rex server stop` ends everything; the saved sessions come back as shells.
  _rex_server_stop() { echo stop >> "$REXT_CALLS"; _rg_server_restart ""; }
}

test_rex_upgrade_waits_for_idle_agents_then_upgrades_restarts_and_resumes_once() {
  _rg_setup
  _rg_apt 0.0.1-gaaa 0.0.2-gbbb
  _rg_agent alpha-orch solo working "$(_rg_line alpha)"
  local out
  # A busy agent: the round is skipped within its bound and nothing happens.
  out="$(CEL_REX_UPGRADE_IDLE_SECS=0 CEL_ROOT="$RT/celroot" rex_upgrade_round)"
  assert_contains "$out" "$(printf 'waiting\t0.0.2-gbbb\tnot every Rex agent went idle')"
  [ ! -e "$REXT_CALLS" ] || { echo "changed the box with a busy agent: $(cat "$REXT_CALLS")"; _rg_down; return 1; }
  _rex_live "$CEL_REX_STATE/alpha-orch.json" || { echo 'busy agent was stopped'; _rg_down; return 1; }

  jq '.agent_status="idle"' "$CEL_REX_STATE/alpha-orch.json" > "$RT/a" && mv "$RT/a" "$CEL_REX_STATE/alpha-orch.json"
  out="$(CEL_ROOT="$RT/celroot" rex_upgrade_round)"
  assert_eq "$(sed -n 1p <<<"$out")" "$(printf 'upgraded\t0.0.1-gaaa\t0.0.2-gbbb\tcel restarted the server')"
  assert_contains "$out" "$(printf 'resumed\talpha-orch\t%s' "$RT/ws")"
  assert_contains "$out" "$(printf 'server\tversion\t\trex v1, API revision 0 -> rex v2, API revision 10')"
  # stop, a persistent server asked to serve the tailnet, the restored shell
  # closed, the tailnet verified (and turned on when the flag did not take).
  assert_eq "$(cat "$REXT_CALLS")" "$(printf 'apt 0.0.2-gbbb\nstop\nstart running\nkill session:alpha-orch\ntailscale on')"
  assert_eq "$(cat "$REXT_SRV/tailscale")" running
  assert_eq "$(cat "$REXT_LOG")" 'false|run orchestrator --product alpha --workspace alpha --session-backend rex --model m1'
  _rex_live "$CEL_REX_STATE/alpha-orch.json" || { echo 'resumed agent is not alive'; _rg_down; return 1; }
  # The safety net sees the planned restart as already handled, and the
  # next round finds nothing newer: one resume, one upgrade.
  out="$(CEL_ROOT="$RT/celroot" rex_generation_tick)$(CEL_ROOT="$RT/celroot" rex_upgrade_round)"
  assert_eq "$out" ""
  assert_eq "$(wc -l < "$REXT_LOG" | tr -d ' ')" 1
  assert_eq "$(wc -l < "$REXT_CALLS" | tr -d ' ')" 5
  _rg_down
}

# The package (or anything) restarted the server into a client autostart:
# not restarted again, but its last restored shell closing ends it, so a
# persistent one is started before the resume.
test_rex_upgrade_after_a_package_restart_keeps_a_server_up_for_the_resume() {
  _rg_setup
  _rg_apt 0.0.1-gaaa 0.0.2-gbbb
  _rg_agent alpha-orch solo idle "$(_rg_line alpha)"
  local out; out="$(RG_PACKAGE_RESTARTS=1 CEL_ROOT="$RT/celroot" rex_upgrade_round)"
  assert_eq "$(sed -n 1p <<<"$out")" "$(printf 'upgraded\t0.0.1-gaaa\t0.0.2-gbbb\tthe server had already restarted')"
  assert_eq "$(cat "$REXT_CALLS")" "$(printf 'apt 0.0.2-gbbb\nkill session:alpha-orch\nstart running\ntailscale on')"
  assert_contains "$out" "$(printf 'resumed\talpha-orch')"
  _rg_down
}

# An agent the restart could not bring back (a reviewer) blocks the round
# before anything changes; so does any doubt about the candidate.
test_rex_upgrade_refuses_unresumable_agents_and_foreign_or_older_candidates() {
  _rg_setup
  _rg_apt 0.0.1-gaaa 0.0.2-gbbb
  _rg_agent widget-pr-7-review reviewer idle
  local out; out="$(CEL_ROOT="$RT/celroot" rex_upgrade_round)"
  assert_contains "$out" "$(printf 'blocked\t0.0.2-gbbb\tthese Rex agents could not be resumed')"
  [ ! -e "$REXT_CALLS" ] || { echo "changed the box: $(cat "$REXT_CALLS")"; _rg_down; return 1; }
  kill "$(jq -r .pid "$CEL_REX_STATE/widget-pr-7-review.json")"; rm -f "$CEL_REX_STATE/widget-pr-7-review.json"
  _rg_apt 0.0.1-gaaa 1.16.1-1 http://archive.ubuntu.com/ubuntu
  assert_eq "$(CEL_ROOT="$RT/celroot" rex_upgrade_round)" ""
  # The origin is the exact https host, not a name that merely contains it.
  _rg_apt 0.0.1-gaaa 0.0.2-gbbb https://pkgs.superlogical.com.lookalike.example/rex/apt
  assert_eq "$(CEL_ROOT="$RT/celroot" rex_upgrade_round)" ""
  _rg_apt 0.0.1-gaaa 0.0.2-gbbb http://pkgs.superlogical.com/rex/apt
  assert_eq "$(CEL_ROOT="$RT/celroot" rex_upgrade_round)" ""
  _rg_apt 0.0.2-gbbb 0.0.1-gaaa
  assert_eq "$(CEL_ROOT="$RT/celroot" rex_upgrade_round)" ""
  [ ! -e "$REXT_CALLS" ] || { echo "changed the box: $(cat "$REXT_CALLS")"; _rg_down; return 1; }
  _rg_down
}

# A server stop ends EVERY session. One the owner opened outside Celestial
# would not come back, so the round is skipped and says which.
test_rex_upgrade_refuses_while_the_server_holds_unmanaged_sessions() {
  _rg_setup
  _rg_apt 0.0.1-gaaa 0.0.2-gbbb
  _rg_agent alpha-orch solo idle "$(_rg_line alpha)"
  local owner; owner="$(_rg_detached_sleep)"; RG_PIDS="$RG_PIDS $owner"
  printf 'notes\tblock:n\t%s\n' "$owner" > "$REXT_SRV/sess/session:owner"
  local out; out="$(CEL_ROOT="$RT/celroot" rex_upgrade_round)"
  assert_eq "$out" "$(printf 'blocked\t0.0.2-gbbb\tthe Rex server holds sessions Celestial does not manage, which a restart would end: notes (session:owner)')"
  [ ! -e "$REXT_CALLS" ] || { echo "changed the box: $(cat "$REXT_CALLS")"; _rg_down; return 1; }
  _rex_live "$CEL_REX_STATE/alpha-orch.json" || { echo 'managed agent was stopped'; _rg_down; return 1; }
  # Once it is gone, the same round goes ahead.
  rm -f "$REXT_SRV/sess/session:owner"
  assert_contains "$(CEL_ROOT="$RT/celroot" rex_upgrade_round)" "$(printf 'upgraded\t0.0.1-gaaa\t0.0.2-gbbb')"
  _rg_down
}

# The line recorded at launch is the one a resume runs: role, product,
# workspace, Rex, and only the choices the owner named.
test_rex_receipt_records_its_canonical_relaunch_line() {
  local T; T="$(mktemp -d)"
  export CEL_REX_STATE="$T/state" CEL_REX_BIN="$T/bin/rex" CEL_MANIFEST="$T/agents.yaml" CEL_MANIFEST_CACHE="$T/cache"
  mkdir -p "$T/bin" "$T/ws/repos/widget" "$CEL_REX_STATE"
  cat > "$CEL_MANIFEST" <<YAML
agents:
  omp:
    bin: "$T/bin/runtime"
    role_injection: { strategy: append_flag_file, flag: --append-system-prompt }
    model_flag: --model
    resume: { flag: --resume, value: path }
YAML
  cat > "$T/ws/workspace.yaml" <<'YAML'
name: alpha
runtime: { orchestrator: omp, worker: omp }
repos:
  - name: widget
    url: git@github.com:acme/widget.git
policy: { merge: self, pr: required }
YAML
  cat > "$T/bin/rex" <<'SH'
#!/bin/bash
[ "$1" = new ] || exit 1
while [ "$1" != -- ]; do shift; done; shift
"$@" >/dev/null 2>&1 &
printf '{"session_id":"session:t","initial_windows":[{"block_ids":["block:t"]}]}'
SH
  printf '#!/bin/bash\nexec sleep 300\n' > "$T/bin/runtime"
  printf '#!/bin/bash\nprintf %s\n' "'{\"result\":{\"agents\":[]}}'" > "$T/bin/herdr"
  chmod +x "$T/bin/"*
  local out rc=0 line
  out="$(cd "$T/ws" && PATH="$T/bin:$PATH" cmd_run orchestrator --repo widget --session-backend rex --fresh --model m1 2>&1)" || rc=$?
  line="$(jq -c '.relaunch' "$CEL_REX_STATE/widget-orch.json" 2>/dev/null)"
  kill "$(jq -r .pid "$CEL_REX_STATE/widget-orch.json" 2>/dev/null)" 2>/dev/null
  unset CEL_REX_STATE CEL_REX_BIN CEL_MANIFEST CEL_MANIFEST_CACHE
  rm -rf "$T"
  [ "$rc" = 0 ] || { echo "$out"; return 1; }
  assert_eq "$line" '["run","orchestrator","--product","widget","--workspace","alpha","--session-backend","rex","--model","m1"]'
}
