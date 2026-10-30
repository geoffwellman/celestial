# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/rex.sh"

_claude_native_setup() {
  CN_ROOT="$CEL_ROOT"; CN_DIR="$(mktemp -d)"
  mkdir -p "$CN_DIR/root/bin" "$CN_DIR/state" "$CN_DIR/cwd"
  ln -s "$CN_ROOT/lib" "$CN_DIR/root/lib"
  ln -s "$CN_ROOT/tools" "$CN_DIR/root/tools"
  cat > "$CN_DIR/root/bin/cel" <<'SH'
#!/bin/bash
if [ "$1 $2" = 'inbox read' ]; then
  [ ! -f "$CN_DIR/mail" ] || { cat "$CN_DIR/mail"; : > "$CN_DIR/mail"; }
  exit 0
fi
[ "$1 $2" = 'sessions note' ] || exit 1
shift
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/rex.sh"
cmd_sessions "$@"
SH
  chmod +x "$CN_DIR/root/bin/cel"
  export CN_DIR CEL_REX_STATE="$CN_DIR/state" CEL_REX_RECORD="$CN_DIR/state/lane.json" CEL_ORCH_SESSIONS="$CN_DIR/sessions.json"
  local pid="${BASHPID:-$$}" start
  start="$(_rex_pid_start "$pid")"
  jq -n --argjson pid "$pid" --arg start "$start" --arg cwd "$CN_DIR/cwd" \
    '{name:"product-lane",agent:"claude",role:"solo",backend:"rex",workspace:$cwd,cwd:$cwd,pid:$pid,pid_start:$start,agent_status:"working"}' > "$CEL_REX_RECORD"
  CN_NATIVE=6b90062c-f7b9-4cf4-859c-6bba6e90df1d
}
_claude_native_input() {
  jq -cn --arg n "$CN_NATIVE" --arg cwd "$CN_DIR/cwd" --arg event "$1" '{session_id:$n,cwd:$cwd,hook_event_name:$event,source:"startup"}'
}
_claude_native_hook() {
  CEL_ROOT="$CN_DIR/root" bash "$CN_ROOT/tools/hooks/claude-session.sh" "${2:-}" <<<"$(_claude_native_input "$1")"
}
_claude_native_down() {
  rm -rf "$CN_DIR"
  unset CN_DIR CEL_REX_STATE CEL_REX_RECORD CEL_ORCH_SESSIONS
}

test_claude_native_hooks_use_real_session_and_runtime_ancestry() {
  _claude_native_setup
  local out
  out="$(_claude_native_hook SessionStart)"
  assert_eq "$out" ''
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" idle
  assert_eq "$(jq -r .agent_session.value "$CEL_REX_RECORD")" "$CN_NATIVE"
  assert_eq "$(jq -r --arg cwd "$CN_DIR/cwd" '.[$cwd]' "$CEL_ORCH_SESSIONS")" "$CN_NATIVE"
  _claude_native_hook UserPromptSubmit
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" working
  _claude_native_hook Stop idle
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" idle
  CEL_ROOT="$CN_DIR/root" bash "$CN_ROOT/tools/hooks/claude-session.sh" <<<"$(jq '.source="compact"' <<<"$(_claude_native_input SessionStart)")"
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" working
  _claude_native_down
}

test_claude_stop_keeps_working_for_mail_then_reports_idle_without_composer_writes() {
  _claude_native_setup
  local out
  printf 'mail arriving during the turn\n' > "$CN_DIR/mail"
  out="$(CEL_ROOT="$CN_DIR/root" bash "$CN_ROOT/tools/hooks/inbox-stop.sh" <<<"$(_claude_native_input Stop)")"
  assert_eq "$(jq -r .decision <<<"$out")" block
  assert_contains "$(jq -r .reason <<<"$out")" 'mail arriving during the turn'
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" working
  out="$(CEL_ROOT="$CN_DIR/root" bash "$CN_ROOT/tools/hooks/inbox-stop.sh" <<<"$(_claude_native_input Stop)")"
  assert_eq "$out" ''
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" idle
  _claude_native_down
}

test_claude_native_hook_ignores_invalid_foreign_and_subagent_identity() {
  _claude_native_setup
  local original payload
  original="$(cat "$CEL_REX_RECORD")"
  payload="$(_claude_native_input SessionStart)"
  CEL_ROOT="$CN_DIR/root" bash "$CN_ROOT/tools/hooks/claude-session.sh" <<<"$(jq '.agent_id="subagent"' <<<"$payload")"
  assert_eq "$(cat "$CEL_REX_RECORD")" "$original"
  CEL_ROOT="$CN_DIR/root" bash "$CN_ROOT/tools/hooks/claude-session.sh" <<<"$(jq '.cwd="/"' <<<"$payload")"
  assert_eq "$(cat "$CEL_REX_RECORD")" "$original"
  CEL_ROOT="$CN_DIR/root" bash "$CN_ROOT/tools/hooks/claude-session.sh" <<<"$(jq '.session_id="not-native"' <<<"$payload")"
  assert_eq "$(cat "$CEL_REX_RECORD")" "$original"
  CEL_ROOT="$CN_DIR/root" bash "$CN_ROOT/tools/hooks/claude-session.sh" <<<'not-json'
  assert_eq "$(cat "$CEL_REX_RECORD")" "$original"
  # A real but unrelated PID cannot be impersonated with an environment label.
  sleep 60 & local unrelated=$!
  local start; start="$(_rex_pid_start "$unrelated")"
  jq --argjson pid "$unrelated" --arg start "$start" '.pid=$pid | .pid_start=$start' <<<"$original" > "$CEL_REX_RECORD"
  _claude_native_hook SessionStart
  assert_eq "$(jq -r .agent_status "$CEL_REX_RECORD")" working
  assert_eq "$(jq 'has("agent_session")' "$CEL_REX_RECORD")" false
  kill "$unrelated"; wait "$unrelated" 2>/dev/null || true
  _claude_native_down
}
