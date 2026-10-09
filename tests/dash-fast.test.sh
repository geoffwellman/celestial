# shellcheck shell=bash
# CEL-116: the dashboard parses each file once and keeps it, reading only an
# inbox's appended tail; and the doctor's probe waits long enough, on a cheap
# endpoint, that a busy box does not call a running dashboard DOWN.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/dash.sh"

_df_node() { node --input-type=module -e "$1"; }

test_dash_store_reads_the_appended_tail_and_reloads_a_rewrite() {
  local T; T="$(mktemp -d)"
  local out; out="$(_df_node "
import { createStore } from '$CEL_ROOT/tools/dash/store.mjs';
import { appendFileSync, writeFileSync } from 'node:fs';
const f = '$T/alpha.jsonl'; const s = createStore();
writeFileSync(f, '{\"n\":1}\n{\"n\":2}\n');
const a = s.jsonl(f).length;
const same = s.jsonl(f) === s.jsonl(f);
appendFileSync(f, '{\"n\":3}\n{\"n\":');
const b = s.jsonl(f).map((r) => r.n).join(',');
appendFileSync(f, '4}\n');
const c = s.jsonl(f).map((r) => r.n).join(',');
writeFileSync(f, '{\"n\":9}\n');
const d = s.jsonl(f).map((r) => r.n).join(',');
console.log([a, same, b, c, d].join('|'));
")"
  assert_eq "$out" "2|true|1,2,3|1,2,3,4|9"
  rm -rf "$T"
}

test_dash_store_json_follows_the_file() {
  local T; T="$(mktemp -d)"
  local out; out="$(_df_node "
import { createStore } from '$CEL_ROOT/tools/dash/store.mjs';
import { writeFileSync } from 'node:fs';
const f = '$T/delegations.json'; const s = createStore();
const miss = s.json(f);
writeFileSync(f, '[{\"branch\":\"ABC-1\"}]');
const a = s.json(f).length;
writeFileSync(f, '[{\"branch\":\"ABC-1\"},{\"branch\":\"ABC-2\"}]');
console.log([miss, a, s.json(f).length].join('|'));
")"
  assert_eq "$out" "|1|2"
  rm -rf "$T"
}

test_dash_doctor_probe_is_patient_and_cheap() {
  local T; T="$(mktemp -d)"
  local port; port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  # a busy dashboard: answers /api/session after 4 s, and nothing else at all
  python3 -c '
import http.server,sys,time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        if s.path != "/api/session": s.send_response(404); s.end_headers(); return
        time.sleep(4); s.send_response(200); s.end_headers(); s.wfile.write(b"{}")
    def log_message(*a): pass
http.server.ThreadingHTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()' "$port" &
  local pid=$!
  local i; for i in $(seq 1 30); do _dash_port_free 127.0.0.1 "$port" || break; sleep 0.2; done
  local rc=0; _dash_answers 127.0.0.1 "$port" || rc=$?
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  assert_eq "$rc" "0"
  # and the doctor and --ensure both ask through it, never /api/state
  assert_eq "$(grep -c 'api/state' "$CEL_ROOT/lib/dash.sh" || true)" "0"
  rm -rf "$T"
}
