# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/ws.sh"

_sandbox() { T="$(mktemp -d)"; CEL_REGISTRY="$T/registry.yaml"; }

test_ws_new_scaffolds_and_registers() {
  _sandbox
  printf '' | cmd_ws new t1 --kind hustle --org someone --merge humans-only \
    --path "$T/t1" --no-remote >/dev/null
  [ -f "$T/t1/workspace.yaml" ]
  assert_eq "$(ws_name "$T/t1")" "t1"
  assert_eq "$(ws_policy "$T/t1" merge)" "humans-only"
  assert_contains "$(cat "$T/t1/.gitignore")" "repos/"
  git -C "$T/t1" rev-parse HEAD >/dev/null
  assert_eq "$(registry_path t1)" "$T/t1"
  assert_eq "$(registry_remote t1)" ""
  rm -rf "$T"
}
test_ws_new_interviews_for_missing_answers() {
  _sandbox
  printf 't2\nhustle\nsomeone\nhumans-only\nn\n' | \
    cmd_ws new --path "$T/t2" >/dev/null
  assert_eq "$(ws_kind "$T/t2")" "hustle"
  rm -rf "$T"
}
test_ws_new_interview_empty_answers_take_defaults() {
  _sandbox
  printf 't3\n\n\n\n\n' | cmd_ws new --path "$T/t3" >/dev/null
  assert_eq "$(ws_kind "$T/t3")" "personal"
  assert_eq "$(ws_policy "$T/t3" merge)" "humans-only"
  rm -rf "$T"
}
test_ws_list_shows_local_only() {
  _sandbox
  printf '' | cmd_ws new t4 --kind hustle --org o --merge self \
    --path "$T/t4" --no-remote >/dev/null
  assert_contains "$(cmd_ws list)" "local-only"
  rm -rf "$T"
}
test_ws_sync_links_skills_and_renders_block() {
  _sandbox
  printf '' | cmd_ws new t5 --kind hustle --org o --merge self \
    --path "$T/t5" --no-remote >/dev/null
  mkdir -p "$T/t5/skills/deploy" "$T/t5/repos/widget"
  printf -- '---\nname: deploy\n---\n' > "$T/t5/skills/deploy/SKILL.md"
  git -C "$T/t5/repos/widget" init -q
  local tmpw; tmpw="$(mktemp)"
  yq -y '.repos = [{name: "widget", url: null, prefix: "WG", gate: "true"}]' \
    "$T/t5/workspace.yaml" > "$tmpw" && mv "$tmpw" "$T/t5/workspace.yaml"
  cmd_ws sync t5 >/dev/null
  [ -L "$T/t5/repos/widget/.claude/skills/deploy" ]
  assert_contains "$(cat "$T/t5/repos/widget/CLAUDE.md")" "cel:policy:begin"
  rm -rf "$T"
}
test_ws_env_command_prints_exports_and_is_silent_outside() {
  _sandbox
  printf '' | cmd_ws new t7 --kind hustle --org o --merge self \
    --path "$T/t7" --no-remote >/dev/null
  local tmpw; tmpw="$(mktemp)"
  yq -y '.env = {CLOUDFLARE_ACCOUNT_ID: "personal"}' "$T/t7/workspace.yaml" \
    > "$tmpw" && mv "$tmpw" "$T/t7/workspace.yaml"
  assert_contains "$(cmd_ws env t7)" "export CLOUDFLARE_ACCOUNT_ID='personal'"
  assert_contains "$(cat "$T/t7/.gitignore")" "env.local"
  assert_eq "$( (cd /tmp && cmd_ws env) )" ""
  rm -rf "$T"
}
# _ws_add dies via die() (exit 1) when the clone lacks workspace.yaml. Called
# directly, that exit would kill this whole test process (bash -c), not just
# fail the assertion - so run it in a subshell, per project convention for
# assert_fails targets that call die().
_ws_add_in_subshell() { ( _ws_add "$@" ); }
test_ws_add_requires_a_workspace_repo() {
  _sandbox
  local src; src="$(mktemp -d)"; git -C "$src" init -q
  git -C "$src" commit --allow-empty -qm x
  assert_fails _ws_add_in_subshell "$src" plain
  rm -rf "$T" "$src"
}

# ---------------------------------------------------------------- CEL-53
# THE FIRST COMMAND A NEWCOMER RUNS. `cel ws sync <name>` against a workspace
# that was never registered exited 1 with nothing on stdout and nothing on
# stderr: `registry_require` dies inside `$( )`, so the refusal was written
# into the dead subshell's captured output and thrown away. A person being
# onboarded has nobody to ask, so a mute failure is indistinguishable from
# "I typed it wrong" - which is exactly the moment self-diagnosis has to work.
# Every one of these asserts the OUTPUT, never only the status: a swallowed
# refusal is a silent exit, and a status-only assertion passes right through it.
_ws_stderr_of() { # <verb> [args...] -> prints stderr, returns the exit status
  ( cmd_ws "$@" ) 2>&1 >/dev/null
}

test_ws_sync_unregistered_says_so_and_names_cel_ws_add() {
  _sandbox
  local err rc=0
  err="$(_ws_stderr_of sync ghost)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$err" "ghost"
  assert_contains "$err" "not registered"
  assert_contains "$err" "cel ws add"
  rm -rf "$T"
}

test_ws_sibling_verbs_refuse_an_unregistered_name_out_loud() {
  _sandbox
  local v err rc
  for v in sync env up down reset status push; do
    rc=0
    err="$(_ws_stderr_of "$v" ghost)" || rc=$?
    assert_eq "$rc" 1 || { echo "cel ws $v exited 0 for an unregistered name"; return 1; }
    assert_contains "$err" "ghost" || { echo "cel ws $v said nothing about the workspace"; return 1; }
    assert_contains "$err" "cel ws add" || { echo "cel ws $v did not name the fix"; return 1; }
  done
  rm -rf "$T"
}

test_ws_registered_path_that_is_gone_reads_differently() {
  _sandbox
  printf '' | cmd_ws new alpha --kind personal --org someone --merge self \
    --path "$T/alpha" --no-remote >/dev/null
  rm -rf "$T/alpha"
  local err rc=0
  err="$(_ws_stderr_of sync alpha)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$err" "alpha"
  assert_contains "$err" "nothing is there"
  rm -rf "$T"
}

# ONE PLACE SECRETS LIVE. workspace.yaml's hint said env.local, the setup
# skill said ~/.zshenv and the checker read whatever the shell happened to
# hold: three answers to "where do I put my key" is zero answers. Asserted
# rather than read, because a reading is what let them drift apart.
test_the_secret_location_is_named_identically_everywhere() {
  local skill="$CEL_ROOT/plugins/celestial/skills/setup/SKILL.md"
  local help_; help_="$(bash "$CEL_ROOT/bin/cel" help 2>&1 || true)"
  assert_contains "$(cat "$skill")" "env.local"
  assert_contains "$help_" "env.local"
  assert_contains "$(cat "$CEL_ROOT/lib/install.sh")" "env.local"
  # ~/.zshenv survives only where it is the right answer - a box-wide
  # credential no workspace owns - and only when it says why on the spot.
  local line
  while IFS= read -r line; do
    case "$line" in *box-wide*) ;; *)
      echo "a bare ~/.zshenv mention with no box-wide justification: $line"
      return 1 ;;
    esac
  done < <(grep -n 'zshenv' "$skill" || true)
}

# AND IT MUST NOT WRITE ANYTHING ON THE WAY OUT. The swallowed refusal did not
# only go unseen - the caller carried on with the refusal TEXT as the
# workspace path, so `_ws_sync_one` ran `mkdir -p "$wsdir/repos"` and appended
# to `"$wsdir/.gitignore"`, creating a directory in the current working
# directory whose name was the colourised error message. One such directory
# was committed to this branch by a red test run before the fix, which is how
# it was found. A refusal creates nothing.
test_a_refused_verb_writes_nothing_into_the_working_directory() {
  _sandbox
  local cwd="$T/cwd"; mkdir -p "$cwd"
  ( cd "$cwd" && cmd_ws sync ghost ) >/dev/null 2>&1 || true
  assert_eq "$(find "$cwd" -mindepth 1 | wc -l)" "0"
  rm -rf "$T"
}
