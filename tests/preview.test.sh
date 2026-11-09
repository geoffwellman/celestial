# shellcheck shell=bash
# cel preview: an open PR's head, run from the repo's preview: block with no
# provider keys, as a ledgered cel serve server. systemd, gh and the network
# are stubs; git is real (a bare origin carrying refs/pull/7/head).
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/preview.sh"

_pv_setup() {
  T="$(mktemp -d)"
  local o="$T/origin.git" w="$T/seedrepo"
  git init -q --bare "$o"; git --git-dir="$o" symbolic-ref HEAD refs/heads/main
  git init -q "$w"; git -C "$w" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$w" push -q "$o" HEAD:refs/heads/main
  printf 'pr work\n' > "$w/app.txt"; git -C "$w" add app.txt
  git -C "$w" -c user.email=t@t -c user.name=t commit -q -m pr
  git -C "$w" push -q "$o" HEAD:refs/pull/7/head
  PV_HEAD="$(git -C "$w" rev-parse HEAD)"
  mkdir -p "$T/ws/repos"
  git clone -q "$o" "$T/ws/repos/widget"
  cat > "$T/ws/workspace.yaml" <<'YAML'
name: alpha
repos:
  - name: widget
    url: git@github.com:acme/widget.git
    preview:
      setup: "echo setup-ran > {data}/setup"
      seed: "echo seeded > {data}/seed"
      cmd: "env > {data}/env.txt; echo {port}/{host} > {data}/args"
      env: { MODE: mock, API: "http://{host}:{port+1}" }
      url: "http://{host}:{port}/app"
YAML
  export CEL_SERVE_STATE="$T/state" CEL_PREVIEW_GH="$T/gh" CEL_SERVE_SYSTEMD_RUN="$T/systemd-run" \
    CEL_SERVE_SYSTEMCTL="$T/systemctl" CEL_PREVIEW_HOST=127.0.0.1 CEL_PREVIEW_PORT_BASE=46100
  cat > "$T/gh" <<EOF
#!/usr/bin/env bash
st="\$(cat "$T/pr-state" 2>/dev/null || echo OPEN)"
case "\$*" in
  *"--jq .state"*) echo "\$st" ;;
  *) printf '{"state":"%s","headRefOid":"%s"}\n' "\$st" "\$(cat "$T/pr-head")" ;;
esac
EOF
  printf '%s' "$PV_HEAD" > "$T/pr-head"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/systemd-calls"\n' "$T" > "$T/systemd-run"
  # is-active answers from $T/active (absent: inactive), like systemd
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/systemctl-calls"\ncase "$*" in *is-active*) [ -f "%s/active" ];; esac\n' "$T" "$T" > "$T/systemctl"
  chmod +x "$T/gh" "$T/systemd-run" "$T/systemctl"
}
_pv_down() {
  unset CEL_SERVE_STATE CEL_PREVIEW_GH CEL_SERVE_SYSTEMD_RUN CEL_SERVE_SYSTEMCTL CEL_PREVIEW_HOST CEL_PREVIEW_PORT_BASE
  rm -rf "$T"
}
_pv_wt() { printf '%s/ws/.cel/previews/preview-widget-pr7' "$T"; }

test_preview_checks_out_the_pr_head_and_runs_with_no_provider_keys() {
  _pv_setup
  local out
  out="$(cd "$T/ws" && OPENROUTER_API_KEY=sk-live GH_TOKEN=ghp-x cmd_preview widget#7 --no-wait 2>&1)" \
    || { printf '%s\n' "$out"; _pv_down; return 1; }
  local wt; wt="$(_pv_wt)"
  assert_eq "$(git -C "$wt" rev-parse HEAD)" "$PV_HEAD"
  assert_eq "$(printf '%s' "$out" | tail -1)" "http://127.0.0.1:46100/app"
  assert_contains "$(cat "$T/systemd-calls")" "--unit=cel-serve-preview-widget-pr7"
  assert_eq "$(jq -r .port "$CEL_SERVE_STATE/preview-widget-pr7.json")" "46100"
  # the unit's script, run as the unit would, under a caller full of keys
  OPENROUTER_API_KEY=sk-live GH_TOKEN=ghp-x OMP_GATEWAY_TOKEN=gw bash "$wt.state/run.sh"
  local d="$wt.state/data"
  assert_eq "$(cat "$d/setup")" "setup-ran"
  assert_eq "$(cat "$d/seed")" "seeded"
  assert_eq "$(cat "$d/args")" "46100/127.0.0.1"
  if grep -qE 'OPENROUTER_API_KEY|GH_TOKEN|OMP_GATEWAY_TOKEN' "$d/env.txt"; then
    echo "a caller key reached the preview"; cat "$d/env.txt"; _pv_down; return 1
  fi
  assert_contains "$(cat "$d/env.txt")" "MODE=mock"
  assert_contains "$(cat "$d/env.txt")" "API=http://127.0.0.1:46101"
  assert_contains "$(cat "$d/env.txt")" "PORT=46100"
  _pv_down
}

test_preview_on_the_tailnet_also_prints_localhost_and_forwards_it() {
  _pv_setup
  local out
  out="$(cd "$T/ws" && CEL_PREVIEW_HOST=100.64.0.9 cmd_preview widget#7 --no-wait 2>&1)" || { printf '%s\n' "$out"; _pv_down; return 1; }
  assert_contains "$out" "http://100.64.0.9:46100/app"
  assert_eq "$(printf '%s' "$out" | tail -1)" "http://localhost:46100"
  assert_contains "$(cat "$(_pv_wt).state/run.sh")" "tools/preview/forward.mjs"
  _pv_down
}

# the forwarder itself, against 127.0.0.2 standing in for the tailnet address
_pv_free_port() { node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }

test_preview_forward_exits_visibly_when_the_app_never_answers() {
  command -v node >/dev/null || return 0
  local port err rc=0
  port="$(_pv_free_port)"
  err="$(CEL_PREVIEW_FORWARD_TRIES=3 CEL_PREVIEW_FORWARD_DELAY_MS=20 \
    timeout 5 node "$CEL_ROOT/tools/preview/forward.mjs" "$port" 127.0.0.2 2>&1 >/dev/null)" || rc=$?
  # 124 would mean it took 127.0.0.1 anyway and sat there forwarding to nothing
  assert_eq "$rc" "1"
  assert_contains "$err" "127.0.0.2:$port never answered"
}

test_preview_forward_relays_once_the_app_answers() {
  command -v node >/dev/null || return 0
  local out
  out="$(FWD="$CEL_ROOT/tools/preview/forward.mjs" timeout 10 node -e '
const net = require("net"), { spawn } = require("child_process");
// the readiness probe of the forwarder connects and drops at once, resetting a
// socket this side already wrote to - that reset is expected, not a failure
const up = net.createServer((c) => { c.on("error", () => {}); c.end("hello"); }).listen(0, "127.0.0.2", () => {
  const port = up.address().port;
  // The forwarder must not inherit stdout: an orphan would hold the $(...)
  // pipe open past `timeout` and turn a 10 s failure into the 120 s test limit.
  const f = spawn(process.execPath, [process.env.FWD, String(port), "127.0.0.2"], { env: { ...process.env, CEL_PREVIEW_FORWARD_DELAY_MS: "20" }, stdio: ["ignore", "ignore", "inherit"] });
  const stop = setTimeout(() => done("no forward (8s)"), 8000);
  const done = (s) => { clearTimeout(stop); console.log(s); f.kill(); up.close(); };
  const attempt = (n) => {
    const c = net.connect(port, "127.0.0.1"); let b = "";
    c.on("data", (d) => (b += d)); c.on("end", () => done(b));
    c.on("error", () => (n ? setTimeout(() => attempt(n - 1), 50) : done("no forward")));
  };
  attempt(100);
});')"
  assert_eq "$out" "hello"
}

test_preview_of_the_same_head_reuses_the_running_one() {
  _pv_setup
  (cd "$T/ws" && cmd_preview widget#7 --no-wait >/dev/null 2>&1)
  local out; out="$(cd "$T/ws" && cmd_preview widget#7 --no-wait 2>&1)"
  assert_contains "$out" "already previewing"
  assert_eq "$(grep -c -- '--unit=' "$T/systemd-calls")" "1"
  _pv_down
}

test_preview_refuses_a_closed_pr_a_repo_without_a_block_and_a_tracked_env_file() {
  _pv_setup
  echo MERGED > "$T/pr-state"
  local out rc=0
  out="$(cd "$T/ws" && cmd_preview widget#7 --no-wait 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "previewed a merged PR"; _pv_down; return 1; }
  assert_contains "$out" "is MERGED"
  echo OPEN > "$T/pr-state"
  printf 'name: alpha\nrepos:\n  - name: widget\n    url: git@github.com:acme/widget.git\n' > "$T/ws/workspace.yaml"
  rc=0; out="$(cd "$T/ws" && cmd_preview widget#7 --no-wait 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "previewed with no preview.cmd"; _pv_down; return 1; }
  assert_contains "$out" "declares no preview.cmd"
  _pv_down
  _pv_setup
  local w="$T/seedrepo"
  printf 'KEY=1\n' > "$w/.env"; git -C "$w" add .env
  git -C "$w" -c user.email=t@t -c user.name=t commit -q -m env
  git -C "$w" push -q -f "$T/origin.git" HEAD:refs/pull/7/head
  git -C "$w" rev-parse HEAD > "$T/pr-head"
  rc=0; out="$(cd "$T/ws" && cmd_preview widget#7 --no-wait 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "previewed a checkout that tracks .env"; _pv_down; return 1; }
  assert_contains "$out" "tracks .env"
  [ ! -d "$(_pv_wt)" ] || { echo "refused checkout left on disk"; _pv_down; return 1; }
  [ ! -f "$CEL_SERVE_STATE/preview-widget-pr7.json" ] || { echo "refused preview started a server"; _pv_down; return 1; }
  _pv_down
}

test_preview_stop_removes_server_checkout_and_ref() {
  _pv_setup
  (cd "$T/ws" && cmd_preview widget#7 --no-wait >/dev/null 2>&1)
  local out; out="$(cmd_preview widget#7 --stop 2>&1)"
  assert_contains "$out" "stopped the preview of widget#7"
  assert_contains "$(cat "$T/systemctl-calls")" "cel-serve-preview-widget-pr7"
  [ ! -f "$CEL_SERVE_STATE/preview-widget-pr7.json" ] || { echo "server record left"; _pv_down; return 1; }
  [ ! -d "$(_pv_wt)" ] || { echo "checkout left"; _pv_down; return 1; }
  ! git -C "$T/ws/repos/widget" rev-parse -q --verify refs/cel/preview/preview-widget-pr7 >/dev/null \
    || { echo "ref left"; _pv_down; return 1; }
  assert_eq "$(preview_list_json)" "[]"
  _pv_down
}

test_preview_sweep_stops_merged_prs_and_keeps_open_ones() {
  _pv_setup
  (cd "$T/ws" && cmd_preview widget#7 --no-wait >/dev/null 2>&1)
  preview_sweep >/dev/null 2>&1
  [ -d "$(_pv_wt)" ] || { echo "open PR's preview was removed"; _pv_down; return 1; }
  assert_eq "$(preview_list_json | jq -r '.[0].running')" "true"
  echo MERGED > "$T/pr-state"
  preview_sweep >/dev/null 2>&1
  [ ! -d "$(_pv_wt)" ] || { echo "merged PR's preview kept"; _pv_down; return 1; }
  [ ! -f "$CEL_SERVE_STATE/preview-widget-pr7.json" ] || { echo "merged PR's server kept"; _pv_down; return 1; }
  _pv_down
}

# A partial, empty or corrupt record removes nothing but itself: a missing
# key read as "null" or "" must never become a path relative to the caller.
test_preview_teardown_of_a_broken_record_touches_nothing_on_disk() {
  _pv_setup
  mkdir -p "$CEL_SERVE_STATE/previews" "$T/cwd/null.state" "$T/cwd/.state" "$T/cwd/null"
  local rec
  for rec in '{}' '' 'not json' '{"repodir":"relative","worktree":"/tmp/elsewhere"}'; do
    printf '%s' "$rec" > "$CEL_SERVE_STATE/previews/preview-widget-pr7.json"
    (cd "$T/cwd" && _preview_teardown preview-widget-pr7 >/dev/null 2>&1)
    [ -d "$T/cwd/null.state" ] && [ -d "$T/cwd/.state" ] && [ -d "$T/cwd/null" ] \
      || { echo "record '$rec' removed a cwd-relative path"; _pv_down; return 1; }
    [ ! -f "$CEL_SERVE_STATE/previews/preview-widget-pr7.json" ] || { echo "record '$rec' kept"; _pv_down; return 1; }
  done
  _pv_down
}

# The steward must not tear down a preview that is still starting: its record
# exists (so a refusal can clean up) before its server does.
test_preview_sweep_leaves_a_starting_preview_alone() {
  _pv_setup
  mkdir -p "$CEL_SERVE_STATE/previews" "$(_pv_wt)"
  jq -n --arg r "$T/ws/repos/widget" --arg w "$(_pv_wt)" \
    '{name:"preview-widget-pr7",repodir:$r,worktree:$w}' > "$CEL_SERVE_STATE/previews/preview-widget-pr7.json"
  preview_sweep >/dev/null 2>&1
  [ -d "$(_pv_wt)" ] || { echo "sweep removed a starting preview"; _pv_down; return 1; }
  touch -d '-20 minutes' "$CEL_SERVE_STATE/previews/preview-widget-pr7.json"
  preview_sweep >/dev/null 2>&1
  [ ! -d "$(_pv_wt)" ] || { echo "sweep kept a start that died"; _pv_down; return 1; }
  _pv_down
}

# A new head replaces the running preview: the old unit is stopped and its
# failed state cleared before the same unit name is started again
# (systemd-run refuses a name still loaded), and a start that fails leaves
# nothing recorded.
test_preview_restart_on_a_new_head_clears_the_unit_and_a_failed_start_rolls_back() {
  _pv_setup
  (cd "$T/ws" && cmd_preview widget#7 --no-wait >/dev/null 2>&1)
  local w="$T/seedrepo"
  printf 'v2\n' > "$w/app.txt"; git -C "$w" -c user.email=t@t -c user.name=t commit -qam v2
  git -C "$w" push -q -f "$T/origin.git" HEAD:refs/pull/7/head; git -C "$w" rev-parse HEAD > "$T/pr-head"
  : > "$T/systemctl-calls"
  (cd "$T/ws" && cmd_preview widget#7 --no-wait >/dev/null 2>&1) || { cat "$T/systemctl-calls"; _pv_down; return 1; }
  local calls; calls="$(cat "$T/systemctl-calls")"
  assert_contains "$calls" "stop cel-serve-preview-widget-pr7.service"
  assert_contains "$calls" "reset-failed cel-serve-preview-widget-pr7.service"
  assert_contains "$(cat "$T/systemd-calls")" "CollectMode=inactive-or-failed"
  assert_eq "$(git -C "$(_pv_wt)" rev-parse HEAD)" "$(cat "$T/pr-head")"
  # a unit that is somehow still running refuses the start, and rolls back
  touch "$T/active"
  printf 'v3\n' > "$w/app.txt"; git -C "$w" -c user.email=t@t -c user.name=t commit -qam v3
  git -C "$w" push -q -f "$T/origin.git" HEAD:refs/pull/7/head; git -C "$w" rev-parse HEAD > "$T/pr-head"
  rm -f "$CEL_SERVE_STATE/preview-widget-pr7.json"   # its record lost, the unit still up
  local out rc=0; out="$(cd "$T/ws" && cmd_preview widget#7 --no-wait 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || { echo "started over a running unit: $out"; _pv_down; return 1; }
  assert_contains "$out" "nothing is left running or recorded"
  [ ! -f "$CEL_SERVE_STATE/previews/preview-widget-pr7.json" ] || { echo "failed start left a preview record"; _pv_down; return 1; }
  [ ! -d "$(_pv_wt)" ] || { echo "failed start left its checkout"; _pv_down; return 1; }
  _pv_down
}

# A QA AGENT'S PREVIEW IS ITS OWN: `--qa <focus>` gives it a name, unit,
# checkout and record of its own beside anyone's plain preview of the PR,
# `--head` pins it to the head the agent was started for, and retirement
# (preview_qa_stop) removes that one and nothing else.
test_preview_for_a_qa_agent_is_its_own_and_pinned_to_its_head() {
  _pv_setup
  local out qa="$T/ws/.cel/previews/preview-widget-pr7-qa-browser"
  out="$(cd "$T/ws" && cmd_preview widget#7 --qa browser --head 0123456789abcdef0123456789abcdef01234567 --no-wait 2>&1)" \
    && { echo "a preview of another head started: $out"; _pv_down; return 1; }
  assert_contains "$out" "is at ${PV_HEAD:0:12}, not 0123456789ab" || { _pv_down; return 1; }
  [ ! -e "$qa" ] || { echo "a refused preview left a checkout"; _pv_down; return 1; }
  out="$(cd "$T/ws" && cmd_preview widget#7 --qa speed --no-wait 2>&1)" && { _pv_down; return 1; }
  assert_contains "$out" "no qa focus 'speed' - have: browser exploratory mobile-device" || { _pv_down; return 1; }
  (cd "$T/ws" && cmd_preview widget#7 --no-wait >/dev/null 2>&1) || { _pv_down; return 1; }
  out="$(cd "$T/ws" && CEL_INBOX_ME=widget-pr-7-qa-browser cmd_preview widget#7 --qa browser --head "$PV_HEAD" --no-wait 2>&1)" \
    || { printf '%s\n' "$out"; _pv_down; return 1; }
  assert_eq "$(git -C "$qa" rev-parse HEAD)" "$PV_HEAD" || { _pv_down; return 1; }
  assert_contains "$(cat "$T/systemd-calls")" "--unit=cel-serve-preview-widget-pr7-qa-browser" || { _pv_down; return 1; }
  assert_eq "$(jq -r .qa "$CEL_SERVE_STATE/previews/preview-widget-pr7-qa-browser.json")" browser || { _pv_down; return 1; }
  assert_eq "$(jq -r .owner "$CEL_SERVE_STATE/preview-widget-pr7-qa-browser.json")" widget-pr-7-qa-browser || { _pv_down; return 1; }
  # its app runs with a private, empty HOME of its own (the plain one keeps the real one)
  bash "$qa.state/run.sh" >/dev/null 2>&1; bash "$(_pv_wt).state/run.sh" >/dev/null 2>&1
  assert_contains "$(cat "$qa.state/data/env.txt")" "HOME=$qa.state/home" || { _pv_down; return 1; }
  [ -d "$qa.state/home" ] && [ -z "$(ls -A "$qa.state/home")" ] || { echo "the qa HOME is not private and empty"; _pv_down; return 1; }
  assert_contains "$(cat "$(_pv_wt).state/data/env.txt")" "HOME=$HOME" || { _pv_down; return 1; }
  preview_qa_stop widget 7 browser >/dev/null 2>&1
  [ ! -e "$qa" ] || { echo "the qa checkout outlived its retirement"; _pv_down; return 1; }
  [ ! -f "$CEL_SERVE_STATE/previews/preview-widget-pr7-qa-browser.json" ] || { echo "the qa preview record outlived it"; _pv_down; return 1; }
  [ -d "$(_pv_wt)" ] && [ -f "$CEL_SERVE_STATE/previews/preview-widget-pr7.json" ] || { echo "retiring the qa agent took the plain preview"; _pv_down; return 1; }
  # and --stop with --qa stops that one only
  (cd "$T/ws" && cmd_preview widget#7 --qa browser --no-wait >/dev/null 2>&1) || { _pv_down; return 1; }
  out="$(cmd_preview widget#7 --qa browser --stop 2>&1)"
  assert_contains "$out" "stopped the browser QA preview of widget#7" || { _pv_down; return 1; }
  [ ! -e "$qa" ] && [ -d "$(_pv_wt)" ] || { _pv_down; return 1; }
  _pv_down
}
# A QA PREVIEW THAT WILL NOT STOP IS NOT FORGOTTEN: retirement's stop fails
# loudly and keeps the record and checkout; the steward's sweep stops it once
# no live agent bears its owner's name, and leaves it while one does.
test_preview_qa_stop_failure_is_retried_by_the_sweep() {
  _pv_setup
  local qa="$T/ws/.cel/previews/preview-widget-pr7-qa-browser"
  (cd "$T/ws" && CEL_INBOX_ME=widget-pr-7-qa-browser cmd_preview widget#7 --qa browser --no-wait >/dev/null 2>&1) || { _pv_down; return 1; }
  local real_stop; real_stop="$(declare -f serve_stop)"
  serve_stop() { return 1; }
  preview_qa_stop widget 7 browser >/dev/null 2>&1 && { echo "a failed stop reported success"; _pv_down; return 1; }
  [ -d "$qa" ] && [ -f "$CEL_SERVE_STATE/previews/preview-widget-pr7-qa-browser.json" ] || { echo "a failed stop dropped the record"; _pv_down; return 1; }
  eval "$real_stop"
  cel_agent_list() { printf '{"result":{"agents":[{"name":"widget-pr-7-qa-browser","pane_id":"w1:p1"}]}}'; }
  preview_sweep >/dev/null 2>&1
  [ -d "$qa" ] || { echo "the sweep stopped a live QA agent's preview"; _pv_down; return 1; }
  cel_agent_list() { printf '{"result":{"agents":[]}}'; }
  local out; out="$(preview_sweep 2>&1)"
  assert_contains "$out" "its QA agent widget-pr-7-qa-browser is gone" || { _pv_down; return 1; }
  [ ! -e "$qa" ] && [ ! -f "$CEL_SERVE_STATE/previews/preview-widget-pr7-qa-browser.json" ] || { echo "the sweep left the orphaned QA preview"; _pv_down; return 1; }
  _pv_down
}
