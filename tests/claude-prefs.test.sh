# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/link.sh"

# link_claude_prefs writes into $HOME - every test runs it against a fake one.
_fake_home() { mktemp -d; }

test_prefs_merge_into_empty_settings() {
  local h; h="$(_fake_home)"
  HOME="$h" link_claude_prefs >/dev/null
  assert_eq "$(jq -r .outputStyle "$h/.claude/settings.json")" "Concise"
}
test_prefs_preserve_existing_keys() {
  local h; h="$(_fake_home)"
  mkdir -p "$h/.claude"
  echo '{"theme":"dark","hooks":{"Stop":[]}}' > "$h/.claude/settings.json"
  HOME="$h" CEL_ROOT="$CEL_ROOT" link_claude_prefs >/dev/null
  assert_eq "$(jq -r .theme "$h/.claude/settings.json")" "dark"
  assert_eq "$(jq -r '.hooks.Stop|length' "$h/.claude/settings.json")" "0"
}
test_prefs_preserve_existing_claude_hooks() {
  local h; h="$(_fake_home)"
  mkdir -p "$h/.claude"
  echo '{"hooks":{"Stop":[],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"existing"}]}]}}' > "$h/.claude/settings.json"
  HOME="$h" CEL_ROOT="$CEL_ROOT" link_claude_prefs >/dev/null
  assert_eq "$(jq -r '.hooks.Stop|length' "$h/.claude/settings.json")" "0"
  assert_eq "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$h/.claude/settings.json")" "existing"
  assert_contains "$(jq -c '.hooks.UserPromptSubmit' "$h/.claude/settings.json")" 'inbox-drain.sh'
  rm -rf "$h"
}
test_prefs_are_idempotent() {
  local h; h="$(_fake_home)"
  HOME="$h" link_claude_prefs >/dev/null
  local before; before="$(cat "$h/.claude/settings.json")"
  HOME="$h" link_claude_prefs >/dev/null
  assert_eq "$(cat "$h/.claude/settings.json")" "$before"
}
test_hud_config_is_a_symlink_to_the_plane() {
  local h; h="$(_fake_home)"
  HOME="$h" link_claude_prefs >/dev/null
  assert_eq "$(readlink "$h/.claude/plugins/claude-hud/config.json")" \
    "$CEL_ROOT/tools/claude/claude-hud.json"
}
test_claude_prompt_submit_hook_is_registered_in_global_settings() {
  local h; h="$(_fake_home)"
  HOME="$h" CEL_ROOT="$CEL_ROOT" link_claude_prefs >/dev/null
  local hooks; hooks="$(jq -c '.hooks.UserPromptSubmit' "$h/.claude/settings.json")"
  assert_contains "$hooks" 'inbox-drain.sh'
  rm -rf "$h"
}
test_prefs_preserve_existing_user_prompt_submit_hooks() {
  local h; h="$(_fake_home)"
  mkdir -p "$h/.claude"
  printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"user-hook"}]}]}}' > "$h/.claude/settings.json"
  HOME="$h" CEL_ROOT="$CEL_ROOT" link_claude_prefs >/dev/null
  local hooks; hooks="$(jq -c '.hooks.UserPromptSubmit' "$h/.claude/settings.json")"
  assert_eq "$(jq -r 'length' <<<"$hooks")" "2"
  assert_eq "$(jq -r '.[0].hooks[0].command' <<<"$hooks")" "user-hook"
  assert_contains "$(jq -r '.[1].hooks[0].command' <<<"$hooks")" 'inbox-drain.sh'
  HOME="$h" CEL_ROOT="$CEL_ROOT" link_claude_prefs >/dev/null
  assert_eq "$(jq -r '.hooks.UserPromptSubmit|length' "$h/.claude/settings.json")" "2"
  rm -rf "$h"
}
test_global_claude_prompt_submit_hook_works_without_cel_root() {
  local h root calls command out
  h="$(_fake_home)"
  root="$h/celestial plane"
  calls="$h/cel calls"
  mkdir -p "$root/tools/hooks" "$root/tools/claude" "$root/bin" "$h/home"
  cp "$CEL_ROOT/tools/claude/settings-prefs.json" "$root/tools/claude/settings-prefs.json"
  cp "$CEL_ROOT/tools/hooks/inbox-drain.sh" "$root/tools/hooks/inbox-drain.sh"
  : > "$root/tools/claude/claude-hud.json"
  cat > "$root/bin/cel" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$INBOX_CALLS"
printf 'test inbox message\n'
EOF
  chmod +x "$root/bin/cel"
  CEL_ROOT="$root" HOME="$h/home" link_claude_prefs >/dev/null
  command="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$h/home/.claude/settings.json")"
  out="$(env -u CEL_ROOT INBOX_CALLS="$calls" CEL_INBOX_ME=worker CEL_INBOX_WS=plane bash -c "$command")"
  assert_contains "$out" "test inbox message"
  assert_eq "$(cat "$calls")" "inbox read --for worker --workspace plane"
  rm -rf "$h"
}

test_claude_stop_hook_blocks_with_new_mail_as_reason() {
  local t; t="$(mktemp -d)"
  mkdir -p "$t/inbox" "$t/alpha"
  printf 'workspaces:\n  alpha:\n    path: %s\n' "$t/alpha" > "$t/registry.yaml"
  export CEL_INBOX_DIR="$t/inbox" CEL_INBOX_ME=widget-pr-12-review CEL_INBOX_WS=alpha CEL_REGISTRY="$t/registry.yaml"
  printf '%s\n' '{"id":"item-1","ts":"2026-10-15T12:00:00Z","from":"widget-orch","to":"widget-pr-12-review","kind":"message","message":"review the new commit"}' > "$t/inbox/alpha.jsonl"
  local out; out="$(CEL_ROOT="$CEL_ROOT" bash "$CEL_ROOT/tools/hooks/inbox-stop.sh" <<< '{}')"
  assert_eq "$(jq -r .decision <<<"$out")" "block"
  assert_contains "$(jq -r .reason <<<"$out")" "review the new commit"
  out="$(CEL_ROOT="$CEL_ROOT" bash "$CEL_ROOT/tools/hooks/inbox-stop.sh" <<< '{}')"
  assert_eq "$out" ""
  rm -rf "$t"
}

# An unresolved placeholder an older install left behind is removed; the
# user's own prompt hooks stay.
test_prefs_drop_an_unresolved_placeholder_hook() {
  local h; h="$(_fake_home)"
  mkdir -p "$h/.claude"
  echo '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"__CEL_INBOX_DRAIN_COMMAND__"}]},{"hooks":[{"type":"command","command":"mine"}]}]}}' > "$h/.claude/settings.json"
  HOME="$h" CEL_ROOT="$CEL_ROOT" link_claude_prefs >/dev/null
  local cmds; cmds="$(jq -r '[.hooks.UserPromptSubmit[].hooks[].command] | join("|")' "$h/.claude/settings.json")"
  case "$cmds" in *__CEL_*) echo "placeholder kept: $cmds"; rm -rf "$h"; return 1;; esac
  assert_contains "$cmds" "mine"
  assert_contains "$cmds" "inbox-drain.sh"
  rm -rf "$h"
}

# A user hook sharing an entry with the placeholder survives.
test_prefs_keep_a_user_hook_that_shares_an_entry_with_the_placeholder() {
  local h; h="$(_fake_home)"
  mkdir -p "$h/.claude"
  echo '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"__CEL_INBOX_DRAIN_COMMAND__"},{"type":"command","command":"mine-too"}]}]}}' > "$h/.claude/settings.json"
  HOME="$h" CEL_ROOT="$CEL_ROOT" link_claude_prefs >/dev/null
  local cmds; cmds="$(jq -r '[.hooks.UserPromptSubmit[].hooks[].command] | join("|")' "$h/.claude/settings.json")"
  case "$cmds" in *__CEL_*) echo "placeholder kept: $cmds"; rm -rf "$h"; return 1;; esac
  assert_contains "$cmds" "mine-too"
  rm -rf "$h"
}

# Claude's guard (tools/hooks/orchestrator-guard.sh) is registered as a
# PreToolUse hook naming the INSTALLED plane (the cel on PATH), never the
# checkout this code runs from.
_cp_installed() { # <root> -> an installed plane at <root>, its cel first on PATH
  mkdir -p "$1/bin" "$1/tools/hooks"
  printf '#!/bin/sh\n' > "$1/bin/cel"; chmod +x "$1/bin/cel"
  : > "$1/tools/hooks/orchestrator-guard.sh"
}
_cp_guard_entry() { # <root> -> the exact entry, compact and key-sorted
  local cmd; printf -v cmd 'bash %q' "$1/tools/hooks/orchestrator-guard.sh"
  jq -cS -n --arg c "$cmd" '{matcher: "Bash|Edit|Write|MultiEdit|NotebookEdit", hooks: [{type: "command", command: $c, timeout: 10}]}'
}
_cp_guard_entries() { # <settings> -> every PreToolUse entry naming the guard
  jq -cS '[.hooks.PreToolUse[]? | select(any(.hooks[]?; (.command // "") | test("orchestrator-guard")))]' "$1"
}
test_prefs_register_the_guard_in_a_fresh_home() {
  local T; T="$(mktemp -d)"; _cp_installed "$T/installed"
  HOME="$T/home" PATH="$T/installed/bin:$PATH" link_claude_prefs >/dev/null
  assert_eq "$(_cp_guard_entries "$T/home/.claude/settings.json")" "[$(_cp_guard_entry "$T/installed")]"
  rm -rf "$T"
}
test_prefs_guard_keeps_foreign_hooks_and_rerun_is_a_noop() {
  local T s; T="$(mktemp -d)"; _cp_installed "$T/installed"; s="$T/home/.claude/settings.json"
  mkdir -p "$T/home/.claude"
  echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"moshi-hook"}]},{"matcher":"*","hooks":[{"type":"command","command":"stackchan notify"},{"type":"command","command":"orca hook"}]}]}}' > "$s"
  HOME="$T/home" PATH="$T/installed/bin:$PATH" link_claude_prefs >/dev/null
  assert_eq "$(jq -r '[.hooks.PreToolUse[].hooks[].command] | .[0:3] | join("|")' "$s")" "moshi-hook|stackchan notify|orca hook"
  assert_eq "$(_cp_guard_entries "$s")" "[$(_cp_guard_entry "$T/installed")]"
  # a foreign hook added after ours stays after it: the re-run moves nothing
  jq '.hooks.PreToolUse += [{"matcher":"Edit","hooks":[{"type":"command","command":"later"}]}]' "$s" > "$s.t" && mv "$s.t" "$s"
  local before; before="$(cat "$s")"
  HOME="$T/home" PATH="$T/installed/bin:$PATH" link_claude_prefs >/dev/null
  assert_eq "$(cat "$s")" "$before"
  rm -rf "$T"
}
test_prefs_guard_replaces_a_stale_celestial_entry_only() {
  local T s; T="$(mktemp -d)"; _cp_installed "$T/installed"; s="$T/home/.claude/settings.json"
  mkdir -p "$T/home/.claude"
  # an older install's entry (a worktree path), sharing an entry with a user hook
  echo '{"hooks":{"PreToolUse":[{"matcher":"Bash|Edit|Write","hooks":[{"type":"command","command":"bash /old/wt/tools/hooks/orchestrator-guard.sh","timeout":10},{"type":"command","command":"mine"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"bash /older/tools/hooks/orchestrator-guard.sh"}]}]}}' > "$s"
  HOME="$T/home" PATH="$T/installed/bin:$PATH" link_claude_prefs >/dev/null
  assert_eq "$(_cp_guard_entries "$s")" "[$(_cp_guard_entry "$T/installed")]"
  assert_eq "$(jq -c '.hooks.PreToolUse[0]' "$s")" '{"hooks":[{"command":"mine","type":"command"}],"matcher":"Bash|Edit|Write"}'
  rm -rf "$T"
}
