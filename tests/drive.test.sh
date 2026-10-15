# shellcheck shell=bash
# CEL-120: the drive core - read an orchestrator's conversation from its
# session file and send to it only through the mailbox, with a receipt.
FX="$CEL_ROOT/tests/fixtures/drive"
TR="$CEL_ROOT/tools/drive/transcript.mjs"

_tr() { # <js body using T (the module)> -> stdout
  TR="$TR" FX="$FX" node --no-warnings --input-type=module -e "
const T = await import(process.env.TR);
import fs0 from 'node:fs';
// secret-shaped values are assembled here, never committed whole (public-tree hygiene)
const SECRETS = { '@SK@': 's' + 'k-abcdefghijklmnopqrstuvwxyz123456', '@GHP@': 'gh' + 'p_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789', '@HEX@': '0123456789abcdef'.repeat(2) };
const fs = { ...fs0, readFileSync: (p, e) => { const t = fs0.readFileSync(p, e); return typeof t === 'string' ? t.replace(/@SK@|@GHP@|@HEX@/g, (m) => SECRETS[m]) : t; } };
$1"
}

test_drive_omp_follows_active_leaf_and_folds() {
  command -v node >/dev/null || return 0
  local out
  out="$(_tr 'const ev = T.parseText(fs.readFileSync(process.env.FX + "/omp.jsonl","utf8"), "omp");
console.log(JSON.stringify(ev));')"
  # the abandoned branch b1 is not on the last leaf's ancestor chain
  case "$out" in *"abandoned branch"*) echo "showed a dead branch"; return 1;; esac
  assert_eq "$(jq -r 'map(.kind)|join(",")' <<<"$out")" "user,thinking,assistant,tool,compaction,system,assistant"
  assert_eq "$(jq -r '.[] | select(.kind=="thinking") | .fold' <<<"$out")" "true"
  assert_eq "$(jq -r '.[] | select(.kind=="tool") | .tool.summary' <<<"$out")" "bash: ls -la /tmp/alpha"
  assert_eq "$(jq -r '.[] | select(.kind=="tool") | .tool.isError' <<<"$out")" "true"
  assert_eq "$(jq -r '.[] | select(.kind=="tool") | .fold' <<<"$out")" "true"
  assert_eq "$(jq -r '.[] | select(.kind=="compaction") | .text' <<<"$out")" "we built half a widget"
  assert_contains "$(jq -r '.[] | select(.kind=="system") | .text' <<<"$out")" "[1700000000000000001]"
  # dropped kinds never surface
  case "$out" in *credential*|*model_usage*|*tool_execution*) echo "leaked a dropped entry"; return 1;; esac
}

test_drive_redacts_secret_shaped_strings() {
  command -v node >/dev/null || return 0
  local out
  out="$(_tr 'const ev = T.parseText(fs.readFileSync(process.env.FX + "/omp.jsonl","utf8"), "omp");
console.log(ev[ev.length-1].text);')"
  local s; for s in sk-abcdefghijklmnop ghp_ABCDEFGH hunter2hunter2 abc.def-ghi_jkl123 0123456789abcdef0123; do
    case "$out" in *"$s"*) echo "leaked $s"; return 1;; esac
  done
  assert_contains "$out" "WIDGET_API_KEY="
  assert_contains "$out" "Bearer "
  assert_eq "$(_tr 'console.log(T.redact("xox"+"b-1234-5678-abcdefgh AKI"+"AABCDEFGHIJKLMNOP password=letmein123 plain words"))')" \
    "[redacted] [redacted] password=[redacted] plain words"
}

test_drive_claude_runtime_normalises() {
  command -v node >/dev/null || return 0
  local out
  out="$(_tr 'console.log(JSON.stringify(T.parseText(fs.readFileSync(process.env.FX + "/claude.jsonl","utf8"), "claude")));')"
  assert_eq "$(jq -r 'map(.kind)|join(",")' <<<"$out")" "user,assistant,tool"
  assert_eq "$(jq -r '.[2].tool.summary' <<<"$out")" "Read: /tmp/gadget.txt"
  assert_eq "$(jq -r '.[2].tool.isError' <<<"$out")" "false"
}

test_drive_pi_1_2_session_parses_inbox_wake_event() {
  command -v node >/dev/null || return 0
  local out
  out="$(_tr 'console.log(JSON.stringify(T.parseText(fs.readFileSync(process.env.FX + "/pi-1.2.0.jsonl","utf8"), "pi")));')"
  assert_eq "$(jq -r 'map(.kind)|join(",")' <<<"$out")" "system,tool,assistant"
  assert_eq "$(jq -r '.[0].source' <<<"$out")" "cel-inbox"
  assert_contains "$(jq -r '.[0].text' <<<"$out")" "Pi 1.2.0 fixture inbox proof request"
  assert_eq "$(jq -r '.[1].tool.name' <<<"$out")" "bash"
  assert_eq "$(jq -r '.[1].tool.isError' <<<"$out")" "false"
  assert_contains "$(jq -r '.[2].text' <<<"$out")" "inbox confirmed it was queued"


}
test_drive_tailer_partial_line_swap_and_shrink() {
  command -v node >/dev/null || return 0
  local d; d="$(mktemp -d)"
  local out
  out="$(D="$d" _tr 'const p = process.env.D + "/s.jsonl";
fs.writeFileSync(p, "{\"type\":\"a\"}\n{\"type\":\"b\",\"par");
const t = new T.Tailer(p);
const r = [];
r.push(t.poll().map(l => JSON.parse(l).type).join(""));        // a  (b is partial)
fs.appendFileSync(p, "t\":1}\n");
r.push(t.poll().map(l => JSON.parse(l).type).join(""));        // b
r.push(String(t.poll().length));                               // 0
fs.writeFileSync(p + ".new", "{\"type\":\"c\"}\n"); fs.renameSync(p + ".new", p);
r.push(t.poll().map(l => JSON.parse(l).type).join("") + (t.reset ? "!" : ""));  // c! (swap)
fs.writeFileSync(p, "");
r.push(String(t.poll().length) + (t.reset ? "!" : ""));         // 0! (shrink)
fs.appendFileSync(p, "{\"type\":\"d\"}\n");
r.push(t.poll().map(l => JSON.parse(l).type).join(""));        // d
console.log(r.join(" "));')"
  rm -rf "$d"
  assert_eq "$out" "a b 0 c! 0! d"
}

test_drive_tail_of_a_13mb_file_reads_only_new_bytes() {
  command -v node >/dev/null || return 0
  local d; d="$(mktemp -d)"
  local out
  out="$(D="$d" _tr 'const p = process.env.D + "/big.jsonl";
const line = JSON.stringify({type:"message",id:"x",parentId:null,message:{role:"assistant",content:[{type:"text",text:"y".repeat(400)}]}}) + "\n";
const fd = fs.openSync(p, "w"); const chunk = line.repeat(1000);
while (fs.fstatSync(fd).size < 13e6) fs.writeSync(fd, chunk); fs.closeSync(fd);
const t = new T.Tailer(p);
const cold = t.poll(); const coldBytes = t.bytesRead;
fs.appendFileSync(p, line);
const more = t.poll();
console.log([coldBytes <= 2.1e6, cold.every(l => l.startsWith("{")), more.length, t.bytesRead - coldBytes].join(" "));')"
  rm -rf "$d"
  # cold start reads at most ~2 MB and drops the first partial line; a poll after one append reads that line only
  assert_eq "$out" "true true 1 $(( $(jq -nc '{type:"message",id:"x",parentId:null,message:{role:"assistant",content:[{type:"text",text:("y"*400)}]}}' | wc -c) ))"
}

# ---- CLI: list / tail / send / receipt against a stubbed herdr ----
_drive_fixture() { # -> sets T; herdr stub prints canned agent+pane lists
  T="$(mktemp -d)"; mkdir -p "$T/bin" "$T/inbox" "$T/ws/alpha/repos/widget"
  cp "$FX/omp.jsonl" "$T/session.jsonl"
  cat > "$T/agents.json" <<EOF
{"id":"cli:agent:list","result":{"agents":[
 {"agent":"omp","agent_session":{"kind":"path","value":"$T/session.jsonl"},"agent_status":"idle","cwd":"$T/ws/alpha/repos/widget","name":"widget-orch","pane_id":"w1:p1"},
 {"agent":"pi","agent_status":"working","cwd":"/tmp","name":"WG-7-worker","pane_id":"w1:p2"}]}}
EOF
  cat > "$T/panes.json" <<EOF
{"id":"cli:pane:list","result":{"panes":[{"pane_id":"w1:p1","label":"widget orchestrator","agent_status":"idle"}]}}
EOF
  cat > "$T/bin/herdr" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/herdr.log"
case "\$1 \$2" in
  "agent list") cat "$T/agents.json";;
  "pane list") cat "$T/panes.json";;
  *) exit 9;;
esac
EOF
  chmod +x "$T/bin/herdr"
  printf 'workspaces:\n  alpha:\n    path: %s\n' "$T/ws/alpha" > "$T/registry.yaml"
}
_cel() { PATH="$T/bin:$PATH" CEL_INBOX_DIR="$T/inbox" CEL_REGISTRY="$T/registry.yaml" "$CEL_ROOT/bin/cel" "$@"; }

test_drive_list_reads_herdr_not_fleet() {
  command -v node >/dev/null || return 0
  _drive_fixture
  local out; out="$(_cel drive list --json)"
  assert_eq "$(jq -r 'length' <<<"$out")" "1"
  assert_eq "$(jq -r '.[0].name' <<<"$out")" "widget-orch"
  assert_eq "$(jq -r '.[0].workspace' <<<"$out")" "alpha"
  assert_eq "$(jq -r '.[0].product' <<<"$out")" "widget"
  assert_eq "$(jq -r '.[0].runtime' <<<"$out")" "omp"
  assert_eq "$(jq -r '.[0].session' <<<"$out")" "$T/session.jsonl"
  assert_eq "$(jq -r '.[0].label' <<<"$out")" "widget orchestrator"
  if grep -q fleet "$T/herdr.log"; then echo "touched fleet"; rm -rf "$T"; return 1; fi
  rm -rf "$T"
}

test_drive_tail_json_and_since() {
  command -v node >/dev/null || return 0
  _drive_fixture
  local out; out="$(_cel drive tail widget-orch --json)"
  assert_eq "$(jq -sr 'map(.kind)|join(",")' <<<"$out")" "user,thinking,assistant,tool,compaction,system,assistant"
  out="$(_cel drive tail widget-orch --json --since x1)"
  assert_eq "$(jq -sr 'map(.id)|join(",")' <<<"$out")" "a4"
  out="$(_cel drive tail widget-orch)"
  assert_contains "$out" "build the widget"
  rm -rf "$T"
}

test_drive_tail_follow_sees_new_turns_and_session_swap() {
  command -v node >/dev/null || return 0
  _drive_fixture
  CEL_DRIVE_POLL_MS=100 _cel drive tail widget-orch --json --follow --since a4 > "$T/out" 2>&1 &
  local pid=$!
  sleep 1.5
  printf '%s\n' '{"type":"message","id":"n1","parentId":"a4","message":{"role":"user","content":"next widget"}}' >> "$T/session.jsonl"
  sleep 1
  printf '%s\n' '{"type":"message","id":"z1","parentId":null,"message":{"role":"user","content":"fresh session"}}' > "$T/new.jsonl"
  sed -i "s#$T/session.jsonl#$T/new.jsonl#" "$T/agents.json"
  sleep 1.5
  pkill -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  assert_contains "$(cat "$T/out")" "next widget"
  assert_contains "$(cat "$T/out")" "fresh session"
  rm -rf "$T"
}

test_drive_send_is_owner_mail_with_three_receipt_states() {
  command -v node >/dev/null || return 0
  _drive_fixture
  local id; id="$(_cel drive send widget-orch "ship WG-9" --json 2>/dev/null | jq -r .id)"
  [ -n "$id" ] && [ "$id" != null ] || { echo "no id"; rm -rf "$T"; return 1; }
  # mail, from owner, kind owner - and never a keystroke into a pane
  assert_eq "$(jq -r 'select(.id=="'"$id"'") | "\(.from) \(.kind) \(.to)"' "$T/inbox/alpha.jsonl")" "owner owner widget-orch"
  if grep -Eq 'prompt|send-keys|send-text' "$T/herdr.log"; then echo "typed into a pane"; rm -rf "$T"; return 1; fi
  assert_eq "$(_cel drive receipt "$id" --json | jq -r .state)" "queued"
  _cel inbox read --for widget-orch --workspace alpha >/dev/null 2>&1
  assert_eq "$(_cel drive receipt "$id" --json | jq -r .state)" "delivered"
  printf '{"type":"custom_message","id":"y1","parentId":"a4","customType":"cel-inbox","display":true,"content":"[%s] ship WG-9"}\n' "$id" >> "$T/session.jsonl"
  assert_eq "$(_cel drive receipt "$id" --json | jq -r .state)" "in-conversation"
  rm -rf "$T"
}

test_drive_send_refuses_an_unknown_orchestrator() {
  command -v node >/dev/null || return 0
  _drive_fixture
  assert_fails _cel drive send nobody-orch "hi"
  [ ! -s "$T/inbox/alpha.jsonl" ] || { echo "mailed a stranger"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Review of #146: a secret cut in half by the 80-char tool summary must still
# be masked - redact first, then clip - and JSON and quoted forms count too.
test_drive_redacts_before_clipping_tool_summaries() {
  command -v node >/dev/null || return 0
  local out
  out="$(_tr 'const tok = "gh" + "p_" + "A".repeat(36);
const line = JSON.stringify({type:"message",id:"q1",parentId:null,message:{role:"assistant",content:[{type:"toolCall",id:"t9",name:"bash",arguments:{command:"x".repeat(60) + " " + tok}}]}});
console.log(T.parseText(line, "omp")[0].tool.summary);')"
  case "$out" in *ghp_*|*AAAA*) echo "clipped secret leaked: $out"; return 1;; esac
  assert_contains "$out" "bash: "
}

test_drive_redacts_json_and_quoted_secret_forms() {
  command -v node >/dev/null || return 0
  local out
  out="$(_tr 'console.log(T.redact(String.raw`{"token":"tok123 value", "apiKey": "abc def", "password":"pw1"} WIDGET_SECRET="a b c" export GADGET_TOKEN='"'"'x y'"'"' api_key = "spaced out"`));')"
  local s; for s in tok123 "abc def" pw1 "a b c" "x y" "spaced out"; do
    case "$out" in *"$s"*) echo "leaked '$s' in: $out"; return 1;; esac
  done
  assert_contains "$out" '"token":"[redacted]"'
  assert_contains "$out" '"apiKey": "[redacted]"'
  assert_contains "$out" 'WIDGET_SECRET=[redacted]'
}
