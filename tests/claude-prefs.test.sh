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
test_claude_inbox_delivery_hook_is_registered_for_idle_turns() {
  local h; h="$(_fake_home)"
  HOME="$h" CEL_ROOT="$CEL_ROOT" link_claude_prefs >/dev/null
  local hooks; hooks="$(jq -c '.hooks.UserPromptSubmit' "$h/.claude/settings.json")"
  assert_contains "$hooks" 'inbox-drain.sh'
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
