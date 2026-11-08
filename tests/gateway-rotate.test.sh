# shellcheck shell=bash
# `cel gateway rotate-key` - the client key replaced with no downtime.
#
# Nothing here touches the live gateway, its key files or a live agent: the
# gateway is an HTTP stub on a free loopback port that answers /v1/models
# 200 only for a bearer listed under `api-keys:` in the fixture config.yaml,
# re-read on every request (CLIProxyAPI reloads the file on change), and the
# processes holding a key are a fake /proc (CEL_PROC_DIR) of environ, stat,
# comm and cwd entries. Every output is checked for both key values.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/gateway-rotate.sh"

_rk_setup() {
  T="$(mktemp -d)"
  # An agent's marks would refuse the owner-only verbs: the runner drops
  # CEL_* and OMP_GATEWAY_TOKEN, the harness markers are dropped here.
  unset CLAUDECODE OMPCODE CEL_GATEWAY_STUB
  export CEL_CONFIG_FILE="$T/cel.yaml" CEL_GATEWAY_STATE="$T/state" CEL_PROC_DIR="$T/proc"
  export CEL_GATEWAY_ROTATE_WAIT=5
  mkdir -p "$CEL_PROC_DIR"
  _gateway_claude_cli_version() { return 1; }
  cat >"$T/stub.py" <<'PY'
import http.server, os, re, sys, threading
cfg, portfile = sys.argv[1], sys.argv[2]
def keys():
    try:
        text = open(cfg).read()
    except OSError:
        return []
    out, on = [], False
    for line in text.splitlines():
        if line.startswith('api-keys:'):
            on = True
            continue
        if on:
            m = re.match(r'^  - "?([^"]*)"?\s*$', line)
            if m:
                out.append(m.group(1))
                continue
            on = False
    return out
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/healthz':
            code = 200
        elif self.path == '/v1/models':
            a = self.headers.get('Authorization', '')
            code = 200 if a.startswith('Bearer ') and a[7:] in keys() else 401
        else:
            code = 404
        self.send_response(code)
        self.end_headers()
        self.wfile.write(b'{"data":[]}' if code == 200 else b'{}')
    def log_message(self, *a):
        pass
s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
open(portfile + '.tmp', 'w').write(str(s.server_port))
os.rename(portfile + '.tmp', portfile)
# A dead man's switch: a stub a killed test leaves behind ends itself.
threading.Timer(60, lambda: os._exit(0)).start()
s.serve_forever()
PY
  python3 "$T/stub.py" "$CEL_GATEWAY_STATE/config.yaml" "$T/port" >/dev/null 2>&1 &
  STUB_PID=$!
  local i=0
  while [ ! -s "$T/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  printf 'gateway:\n  port: %s\n' "$(cat "$T/port")" >"$CEL_CONFIG_FILE"
  _gateway_config_write
  OLD="$(cat "$CEL_GATEWAY_STATE/api-key")"
  : >"$T/outs"
}
_rk_teardown() {
  kill "$STUB_PID" 2>/dev/null || true
  rm -rf "$T"
}

# Run the verb as `cel gateway rotate-key` would, its exit contained; every
# output is appended to $T/outs (callers run this in a $(...) subshell) for
# the no-key-printed check.
_rk() { # <args...> -> output; status of the verb
  local out rc=0
  out="$( (cmd_gateway rotate-key "$@") 2>&1)" || rc=$?
  printf '%s\n' "$out" >>"$T/outs"
  printf '%s' "$out"
  return "$rc"
}

# The HTTP status the stub answers one key with.
_rk_code() { # <key>
  printf 'Authorization: Bearer %s\n' "$1" \
    | curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$(cat "$T/port")/v1/models" -H @-
}

# The keys config.yaml lists, in order, by sha256 (never compared as values
# in an assertion message).
_rk_config_fps() {
  local k
  while IFS= read -r k; do printf '%s\n' "$(_gwr_fp_of "$k")"; done < <(_gwr_config_keys)
}

# A fake process: <pid> <ppid> <comm> <cwd> [K=V ...] as its environ.
_rk_proc() {
  local pid="$1" ppid="$2" comm="$3" cwd="$4" d; shift 4
  d="$CEL_PROC_DIR/$pid"; mkdir -p "$d"
  printf '%s (%s) S %s 0 0 0\n' "$pid" "$comm" "$ppid" >"$d/stat"
  printf '%s\n' "$comm" >"$d/comm"
  ln -s "$cwd" "$d/cwd"
  if [ $# -gt 0 ]; then printf '%s\0' "$@" >"$d/environ"; else : >"$d/environ"; fi
}

# NO KEY VALUE IS EVER PRINTED, by any verb, on success or refusal.
_rk_no_key_printed() {
  local k outs; outs="$(cat "$T/outs")"
  [ -n "$outs" ] || { echo "no output was recorded"; return 1; }
  for k in "$OLD" "${NEW:-}"; do
    [ -n "$k" ] || continue
    case "$outs" in *"$k"*) echo "a key value reached the output"; return 1 ;; esac
  done
}

test_rotate_stage_accepts_both_keys_and_hands_new_launches_the_new_key() {
  _rk_setup
  local out; out="$(_rk --stage)" || { echo "$out"; _rk_teardown; return 1; }
  NEW="$(cat "$CEL_GATEWAY_STATE/api-key")"
  [ -n "$NEW" ] && [ "$NEW" != "$OLD" ] || { echo "api-key was not replaced"; _rk_teardown; return 1; }
  assert_eq "$(_gwr_fp_of "$(cat "$CEL_GATEWAY_STATE/api-key.previous")")" "$(_gwr_fp_of "$OLD")"
  [ ! -e "$CEL_GATEWAY_STATE/api-key.next" ] || { echo "api-key.next left behind"; _rk_teardown; return 1; }
  assert_eq "$(stat -c %a "$CEL_GATEWAY_STATE/api-key")" 600
  assert_eq "$(stat -c %a "$CEL_GATEWAY_STATE/api-key.previous")" 600
  # two valid keys, the old one listed first
  assert_eq "$(_rk_code "$OLD")" 200
  assert_eq "$(_rk_code "$NEW")" 200
  assert_eq "$(_rk_config_fps | tr '\n' ' ')" "$(_gwr_fp_of "$OLD") $(_gwr_fp_of "$NEW") "
  assert_contains "$out" "the gateway accepts both keys"
  assert_contains "$out" "rotation   staged"
  # a refresh mid-rotation (cel update) keeps both keys
  _gateway_config_write
  assert_eq "$(_rk_code "$OLD")" 200
  assert_eq "$(_rk_code "$NEW")" 200
  # a launch from here carries the NEW key: the launcher's own env words
  local got
  got="$( source "$CEL_ROOT/lib/run.sh"
          GATEWAY_ENV=()
          _run_gateway_env pi pi-agent
          bash -c "env ${GATEWAY_ENV[*]} printenv OMP_GATEWAY_TOKEN" | tr -d '\n' | _gwr_fp )"
  assert_eq "$got" "$(_gwr_fp_of "$NEW")"
  # a second stage over a staged rotation changes nothing
  out="$(_rk --stage)" && { echo "a second stage succeeded"; _rk_teardown; return 1; }
  assert_contains "$out" "already staged"
  assert_eq "$(_gwr_fp_of "$(cat "$CEL_GATEWAY_STATE/api-key")")" "$(_gwr_fp_of "$NEW")"
  _rk_no_key_printed || { _rk_teardown; return 1; }
  _rk_teardown
}

test_rotate_status_finds_old_key_holders_by_hash_with_a_restart_plan() {
  _rk_setup
  _rk --stage >/dev/null || { _rk_teardown; return 1; }
  NEW="$(cat "$CEL_GATEWAY_STATE/api-key")"
  local ws=/w/plane
  # a product agent and the tool shell it spawned: one launch, two processes
  _rk_proc 100 1 omp "$ws/products/celestial" CEL_ROLE=solo CEL_INBOX_ME=celestial-orch CEL_INBOX_WS=plane \
    CEL_PRODUCT=celestial CEL_WORKSPACE=$ws "OMP_GATEWAY_TOKEN=$OLD"
  _rk_proc 101 100 bash "$ws/products/celestial" CEL_ROLE=solo CEL_INBOX_ME=celestial-orch CEL_INBOX_WS=plane \
    CEL_PRODUCT=celestial "OMP_GATEWAY_TOKEN=$OLD"
  # a solo lane, a reviewer, core and a workspace root
  _rk_proc 200 1 omp "$ws/.cel/solo/celestial/lane-disk-cleanup" CEL_ROLE=solo CEL_INBOX_ME=celestial-disk-cleanup \
    CEL_INBOX_WS=plane CEL_PRODUCT=celestial "OMP_GATEWAY_TOKEN=$OLD"
  _rk_proc 300 1 pi /w/reviews/celestial-pr-270 CEL_ROLE=reviewer CEL_INBOX_ME=celestial-pr-270-review \
    CEL_INBOX_WS=plane "OMP_GATEWAY_TOKEN=$OLD"
  _rk_proc 400 1 omp /home/u/.local/share/cel/core CEL_ROLE=core CEL_INBOX_ME=root "OMP_GATEWAY_TOKEN=$OLD"
  _rk_proc 450 1 omp "$ws" CEL_ROLE=root CEL_INBOX_ME=root CEL_INBOX_WS=plane "OMP_GATEWAY_TOKEN=$OLD"
  # launched after the stage: the new key - not a holder of the old one
  _rk_proc 500 1 omp /w/widget CEL_ROLE=solo CEL_INBOX_ME=widget-orch CEL_INBOX_WS=widgets CEL_PRODUCT=widget \
    "OMP_GATEWAY_TOKEN=$NEW"
  # no key at all, and a key that is neither
  _rk_proc 600 1 zsh /home/u
  _rk_proc 700 1 node /tmp CEL_INBOX_ME=stranger "OMP_GATEWAY_TOKEN=not-a-gateway-key"
  local out; out="$(_rk --status)" || { echo "$out"; _rk_teardown; return 1; }
  assert_contains "$out" "accepts 2 key(s): old (sha256 $(_gwr_fp_of "$OLD" | cut -c1-12)), new (sha256 $(_gwr_fp_of "$NEW" | cut -c1-12))"
  assert_contains "$out" "1 launch(es) already hold the new key"
  assert_contains "$out" "Still on the OLD key: 5 launch(es), 6 process(es)"
  local name
  for name in celestial-orch celestial-disk-cleanup celestial-pr-270-review root; do
    assert_contains "$out" "$name" || { _rk_teardown; return 1; }
  done
  case "$out" in *widget-orch*|*stranger*|*" 101 "*) echo "a non-holder or a child was listed: $out"; _rk_teardown; return 1 ;; esac
  assert_contains "$out" "cel run orchestrator --product celestial --workspace plane --restart"
  assert_contains "$out" "cel run solo --product celestial --lane disk-cleanup --workspace plane --restart"
  assert_contains "$out" "cel run reviewer --repo celestial --pr 270 --workspace plane"
  assert_contains "$out" "cel run root --workspace plane --restart"
  assert_contains "$out" "cel core --restart"
  # root and core last, core the very last step
  local plan; plan="$(printf '%s\n' "$out" | sed -n '/Restart plan/,$p')"
  assert_eq "$(printf '%s\n' "$plan" | grep -E '^    [0-9]+\. ' | tail -2 | sed -E 's/^ +[0-9]+\. //')" \
    "cel run root --workspace plane --restart
cel core --restart"
  _rk_no_key_printed || { _rk_teardown; return 1; }
  _rk_teardown
}

test_rotate_status_is_open_to_agents_and_says_when_nothing_is_staged() {
  _rk_setup
  _rk_proc 100 1 omp /w CEL_ROLE=solo CEL_INBOX_ME=celestial-orch "OMP_GATEWAY_TOKEN=$OLD"
  local out; out="$(CEL_ROLE=solo CEL_INBOX_ME=celestial-orch _rk)" || { echo "$out"; _rk_teardown; return 1; }
  assert_contains "$out" "rotation   none"
  assert_contains "$out" "accepts 1 key(s): current (sha256 $(_gwr_fp_of "$OLD" | cut -c1-12))"
  assert_contains "$out" "1 launch(es) hold the current key"
  _rk_no_key_printed || { _rk_teardown; return 1; }
  _rk_teardown
}

test_rotate_finish_refuses_while_old_key_holders_remain_then_drops_the_old_key() {
  _rk_setup
  _rk --stage >/dev/null || { _rk_teardown; return 1; }
  NEW="$(cat "$CEL_GATEWAY_STATE/api-key")"
  _rk_proc 100 1 omp /w CEL_ROLE=solo CEL_INBOX_ME=celestial-orch CEL_INBOX_WS=plane "OMP_GATEWAY_TOKEN=$OLD"
  local out
  out="$(_rk --finish)" && { echo "finish ran over a holder: $out"; _rk_teardown; return 1; }
  assert_contains "$out" "1 launch(es) still hold the old key"
  assert_contains "$out" "celestial-orch"
  # nothing changed: both keys accepted, the previous key kept
  [ -s "$CEL_GATEWAY_STATE/api-key.previous" ] || { echo "previous dropped"; _rk_teardown; return 1; }
  assert_eq "$(_rk_code "$OLD")" 200
  assert_eq "$(_rk_code "$NEW")" 200
  # the holder restarted (gone from /proc): finish drops the old key
  rm -rf "${CEL_PROC_DIR:?}/100"
  out="$(_rk --finish)" || { echo "$out"; _rk_teardown; return 1; }
  assert_contains "$out" "rotation finished"
  [ ! -e "$CEL_GATEWAY_STATE/api-key.previous" ] || { echo "api-key.previous kept"; _rk_teardown; return 1; }
  assert_eq "$(_rk_config_fps | tr '\n' ' ')" "$(_gwr_fp_of "$NEW") "
  assert_eq "$(_rk_code "$OLD")" 401
  assert_eq "$(_rk_code "$NEW")" 200
  out="$(_rk --status)"
  assert_contains "$out" "rotation   none"
  _rk_no_key_printed || { _rk_teardown; return 1; }
  _rk_teardown
}

test_rotate_finish_force_cuts_off_remaining_holders() {
  _rk_setup
  _rk --stage >/dev/null || { _rk_teardown; return 1; }
  NEW="$(cat "$CEL_GATEWAY_STATE/api-key")"
  _rk_proc 100 1 omp /w CEL_ROLE=solo CEL_INBOX_ME=celestial-orch "OMP_GATEWAY_TOKEN=$OLD"
  local out; out="$(_rk --finish --force)" || { echo "$out"; _rk_teardown; return 1; }
  assert_contains "$out" "cut off"
  assert_eq "$(_rk_code "$OLD")" 401
  assert_eq "$(_rk_code "$NEW")" 200
  _rk_no_key_printed || { _rk_teardown; return 1; }
  _rk_teardown
}

test_rotate_abort_restores_the_old_key_as_the_only_key() {
  _rk_setup
  _rk --stage >/dev/null || { _rk_teardown; return 1; }
  NEW="$(cat "$CEL_GATEWAY_STATE/api-key")"
  # a launch since the stage holds the new key: abort would 401 it
  _rk_proc 500 1 omp /w/widget CEL_ROLE=solo CEL_INBOX_ME=widget-orch "OMP_GATEWAY_TOKEN=$NEW"
  local out
  out="$(_rk --abort)" && { echo "abort ran over a new-key holder: $out"; _rk_teardown; return 1; }
  assert_contains "$out" "widget-orch"
  assert_eq "$(_gwr_fp_of "$(cat "$CEL_GATEWAY_STATE/api-key")")" "$(_gwr_fp_of "$NEW")"
  rm -rf "${CEL_PROC_DIR:?}/500"
  out="$(_rk --abort)" || { echo "$out"; _rk_teardown; return 1; }
  assert_contains "$out" "rotation aborted"
  assert_eq "$(_gwr_fp_of "$(cat "$CEL_GATEWAY_STATE/api-key")")" "$(_gwr_fp_of "$OLD")"
  assert_eq "$(stat -c %a "$CEL_GATEWAY_STATE/api-key")" 600
  [ ! -e "$CEL_GATEWAY_STATE/api-key.previous" ] && [ ! -e "$CEL_GATEWAY_STATE/api-key.next" ] \
    || { echo "a rotation file was left behind"; _rk_teardown; return 1; }
  assert_eq "$(_rk_config_fps | tr '\n' ' ')" "$(_gwr_fp_of "$OLD") "
  assert_eq "$(_rk_code "$OLD")" 200
  assert_eq "$(_rk_code "$NEW")" 401
  _rk_no_key_printed || { _rk_teardown; return 1; }
  _rk_teardown
}

test_rotate_abort_clears_an_interrupted_stage() {
  _rk_setup
  _gateway_mint_secret "$CEL_GATEWAY_STATE/api-key.next"
  NEW="$(cat "$CEL_GATEWAY_STATE/api-key.next")"
  _gateway_config_write
  assert_eq "$(_rk_code "$NEW")" 200
  local out
  out="$(_rk --stage)" && { echo "staged over an interrupted stage"; _rk_teardown; return 1; }
  assert_contains "$out" "--abort clears it"
  out="$(_rk --abort)" || { echo "$out"; _rk_teardown; return 1; }
  [ ! -e "$CEL_GATEWAY_STATE/api-key.next" ] || { echo "api-key.next kept"; _rk_teardown; return 1; }
  assert_eq "$(_rk_code "$OLD")" 200
  assert_eq "$(_rk_code "$NEW")" 401
  _rk_no_key_printed || { _rk_teardown; return 1; }
  _rk_teardown
}

test_rotate_refuses_every_agent_mark_and_an_agent_launch_above_it() {
  _rk_setup
  local v out
  for v in CEL_ROLE CEL_INBOX_ME CEL_SESSION_ID CEL_TEAM_MEMBER OMP_GATEWAY_TOKEN CLAUDECODE OMPCODE; do
    out="$(export "$v=x"; _rk --stage)" && { echo "$v: stage ran for an agent"; _rk_teardown; return 1; }
    assert_contains "$out" "the owner's action" || { _rk_teardown; return 1; }
    out="$(export "$v=x"; _rk --finish --force)" && { echo "$v: finish ran for an agent"; _rk_teardown; return 1; }
    out="$(export "$v=x"; _rk --abort --force)" && { echo "$v: abort ran for an agent"; _rk_teardown; return 1; }
  done
  # the marks shed (env -u), but the launch above still carries them
  _rk_proc "$PPID" 1 omp /w CEL_ROLE=solo CEL_INBOX_ME=celestial-orch
  out="$(_rk --stage)" && { echo "stage ran under an agent launch"; _rk_teardown; return 1; }
  assert_contains "$out" "runs under an agent launch (pid $PPID carries CEL_ROLE)"
  rm -rf "${CEL_PROC_DIR:?}/$PPID"
  # nothing changed by any refusal
  [ ! -e "$CEL_GATEWAY_STATE/api-key.next" ] && [ ! -e "$CEL_GATEWAY_STATE/api-key.previous" ] \
    || { echo "a refused verb left a rotation file"; _rk_teardown; return 1; }
  assert_eq "$(_gwr_fp_of "$(cat "$CEL_GATEWAY_STATE/api-key")")" "$(_gwr_fp_of "$OLD")"
  assert_eq "$(_rk_config_fps | tr '\n' ' ')" "$(_gwr_fp_of "$OLD") "
  _rk_no_key_printed || { _rk_teardown; return 1; }
  _rk_teardown
}

test_rotate_stage_refuses_a_gateway_that_is_down() {
  _rk_setup
  kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null || true
  local out
  out="$(_rk --stage)" && { echo "staged with no gateway answering"; _rk_teardown; return 1; }
  assert_contains "$out" "not answering"
  [ ! -e "$CEL_GATEWAY_STATE/api-key.next" ] || { echo "minted against a dead gateway"; _rk_teardown; return 1; }
  _rk_no_key_printed || { _rk_teardown; return 1; }
  _rk_teardown
}
