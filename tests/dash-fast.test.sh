# shellcheck shell=bash
# The dashboard parses each file once and keeps it, reading only an
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

# An append that splits a multibyte character between two
# writes is decoded whole, and an unreadable inbox is an error, not calm
test_dash_store_keeps_a_split_multibyte_line_whole_and_throws_on_unreadable() {
  local T; T="$(mktemp -d)"
  local out; out="$(_df_node "
import { createStore } from '$CEL_ROOT/tools/dash/store.mjs';
import { appendFileSync, writeFileSync, mkdirSync } from 'node:fs';
const f = '$T/alpha.jsonl'; const s = createStore();
writeFileSync(f, '{\"m\":\"a\"}\n');
s.jsonl(f);
const line = Buffer.from('{\"m\":\"\u00e9t\u00e9\"}\n');
appendFileSync(f, line.subarray(0, 8));
s.jsonl(f);
appendFileSync(f, line.subarray(8));
const got = s.jsonl(f).map((r) => r.m).join(',');
mkdirSync('$T/beta.jsonl');
let threw = false; try { s.jsonl('$T/beta.jsonl'); } catch { threw = true; }
console.log(got + '|' + threw);
")"
  assert_eq "$out" "a,été|true"
  rm -rf "$T"
}

# An upstream cache is stale-while-revalidate, like v2's `slow`: the first
# ask waits; past its TTL an ask gets the last good answer at once while ONE
# refresh runs behind it; a failed refresh keeps the last good answer.
test_dash_cached_serves_stale_at_once_and_refreshes_once_behind() {
  local out; out="$(_df_node "
import { createCached } from '$CEL_ROOT/tools/dash/cached.mjs';
const { cached } = createCached();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let calls = 0, next = 'one', gate = null;
const fn = async () => { calls++; if (gate) await gate; return next; };
const ask = () => cached('k', 50, fn, 'empty');
const first = await ask();
await sleep(70);
next = 'two'; let open; gate = new Promise((r) => { open = r; });
const t0 = Date.now();
const [a, b, c] = await Promise.all([ask(), ask(), ask()]);
const quick = Date.now() - t0 < 30;
const during = calls;
open(); await sleep(10);
const after = await ask();
console.log([first, a, b, c, quick, during, after, calls].join('|'));
")"
  assert_eq "$out" "one|one|one|one|true|2|two|2"
}

test_dash_cached_failed_refresh_keeps_the_last_good_answer() {
  local out; out="$(_df_node "
import { createCached } from '$CEL_ROOT/tools/dash/cached.mjs';
const { cached } = createCached();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let mode = 'ok', calls = 0;
const fn = async () => { calls++; if (mode === 'undef') return undefined; if (mode === 'throw') throw new Error('x'); return 'good'; };
const ask = () => cached('k', 30, fn, 'empty');
const r = [await ask()];
mode = 'undef'; await sleep(40); r.push(await ask()); await sleep(5); r.push(await ask());
mode = 'throw'; await sleep(40); r.push(await ask()); await sleep(5); r.push(await ask());
const cold = createCached().cached('k', 30, async () => undefined, 'empty');
r.push(await cold, calls);
console.log(r.join('|'));
")"
  assert_eq "$out" "good|good|good|good|good|empty|3"
}

# An answer older than ten budgets is not served at once: the ask waits for a
# fresh read, as a first ask does - and still keeps it if that read fails.
test_dash_cached_answer_past_ten_ttls_waits_for_a_fresh_read() {
  local out; out="$(_df_node "
import { createCached } from '$CEL_ROOT/tools/dash/cached.mjs';
const { cached } = createCached();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let next = 'old', fail = false;
const fn = async () => { await sleep(20); if (fail) return undefined; return next; };
const ask = () => cached('k', 10, fn, 'empty');
const r = [await ask()];
await sleep(30); next = 'mid'; r.push(await ask());
await sleep(25); r.push(await ask());
await sleep(120); next = 'new'; r.push(await ask());
await sleep(120); fail = true; r.push(await ask());
console.log(r.join('|'));
")"
  assert_eq "$out" "old|old|mid|new|new"
}
