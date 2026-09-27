# shellcheck shell=bash
# A fake box for orchestrator restart tests: a herdr that answers from a
# roster file and records what it was told, and a /proc of our own making
# (CEL_PROC_ROOT). `herdr agent start` writes the new process into that /proc
# from the launch line it was given, so a test can read back exactly what
# would have run.
orch_stub_setup() { # <orchestrator-runtime> -> T, PROC, HLOG
  T="$(mktemp -d)"; PROC="$T/proc"; HLOG="$T/herdr.log"
  mkdir -p "$T/ws/repos/widget" "$T/bin" "$PROC"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/ws/"
  printf 'runtime: { root: %s, orchestrator: %s, worker: omp }\n' "$1" "$1" >> "$T/ws/workspace.yaml"
  sed -i '/^runtime: { root: claude/d' "$T/ws/workspace.yaml"
  printf 'workspaces:\n  alpha: {path: "%s/ws"}\n' "$T" > "$T/registry.yaml"
  export CEL_REGISTRY="$T/registry.yaml" CEL_PROC_ROOT="$PROC" CEL_CACHE="$T/cache" \
         CEL_ORCH_SESSIONS="$T/sessions.json" CEL_RESTART_WAIT=2 CEL_RESTART_SLEEP=0
  export ORCH_STUB_T="$T"
  cat > "$T/bin/herdr" <<'STUB'
#!/usr/bin/env bash
T="$ORCH_STUB_T"
printf '%s\n' "$*" >> "$T/herdr.log"
case "$1 $2" in
  "agent list")
    if [ -f "$T/gone" ]; then printf '{"result":{"agents":[]}}\n'; else cat "$T/roster.json"; fi ;;
  "pane send-keys") touch "$T/gone" ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:t1"}}}\n' "$3" ;;
  "pane process-info")
    # the pane's own shell is pid 50; herdr's foreground list is left empty so
    # the resolver has to walk the fixture /proc from that shell down
    if [ -f "$T/no-pane-info" ]; then exit 1; fi
    printf '{"result":{"process_info":{"shell_pid":50,"foreground_processes":[]}}}\n' ;;
  "pane send-text") printf '%s' "$4" > "$T/envprefix" ;;
  "agent start")
    shift 2; name="$1"; shift; kind=""; while [ "$1" != -- ]; do [ "$1" = --kind ] && kind="$2"; shift; done; shift
    d="$CEL_PROC_ROOT/9999"; mkdir -p "$d"
    printf '%s\0' "$kind" "$@" > "$d/cmdline"
    tr ' ' '\n' < "$T/envprefix" | grep '^CEL_' | tr '\n' '\0' > "$d/environ"
    printf '%s\n' "$name" > "$T/started" ;;
esac
exit 0
STUB
  chmod +x "$T/bin/herdr"; PATH="$T/bin:$PATH"
}

orch_stub_roster() { # <name> <cwd> <status> <session|""> [runtime]
  local sess='null'
  [ -z "$4" ] || sess="{\"kind\":\"path\",\"value\":\"$4\"}"
  printf '{"result":{"agents":[{"agent":"%s","name":"%s","cwd":"%s","pane_id":"w1:p1","agent_status":"%s","agent_session":%s}]}}\n' \
    "${5:-omp}" "$1" "$2" "$3" "$sess" > "$T/roster.json"
}

orch_stub_proc() { # <pid> <me> <wsdir> <argv...>  (child of the pane shell, pid 50)
  local pid="$1" me="$2" ws="$3"; shift 3
  mkdir -p "$PROC/$pid" "$PROC/50"
  printf 'Name:\tomp\nPPid:\t50\n' > "$PROC/$pid/status"
  [ -f "$PROC/50/status" ] || printf 'Name:\tbash\nPPid:\t1\n' > "$PROC/50/status"
  ln -sfn "${ORCH_STUB_CWD:-$T/ws/repos/widget}" "$PROC/$pid/cwd"
  printf '%s\0' "$@" > "$PROC/$pid/cmdline"
  printf 'CEL_ROLE=orchestrator\0CEL_WORKSPACE=%s\0CEL_INBOX_ME=%s\0' "$ws" "$me" > "$PROC/$pid/environ"
}

orch_stub_teardown() {
  chmod -R u+rwX "$T" 2>/dev/null || true
  rm -rf "$T"
  unset CEL_CACHE CEL_REGISTRY CEL_PROC_ROOT CEL_ORCH_SESSIONS CEL_RESTART_WAIT CEL_RESTART_SLEEP ORCH_STUB_T
}

orch_stub_roster_two() { # <cwd> <name-of-first|""> <name-of-second|""> - two omp agents in one cwd
  printf '{"result":{"agents":[
    {"agent":"omp","name":"%s","cwd":"%s","pane_id":"w1:p1","agent_status":"idle","agent_session":{"value":"%s/first.jsonl"}},
    {"agent":"omp","name":"%s","cwd":"%s","pane_id":"w2:p1","agent_status":"idle","agent_session":{"value":"%s/second.jsonl"}}]}}\n' \
    "$2" "$1" "$T" "$3" "$1" "$T" > "$T/roster.json"
}
