# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"

test_expand_leading_tilde() {
  assert_eq "$(expand '~/.claude/skills')" "$HOME/.claude/skills"
}

test_expand_leaves_absolute_paths_alone() {
  assert_eq "$(expand '/opt/skills')" "/opt/skills"
}

test_expand_preserves_spaces() {
  assert_eq "$(expand '~/my skills')" "$HOME/my skills"
}

# Manifest values are data, not executable shell substitutions.
test_expand_does_not_execute_substitutions() {
  assert_eq "$(expand '$(echo pwned)')" '$(echo pwned)'
}

test_expand_does_not_glob() {
  assert_eq "$(expand '/etc/*')" '/etc/*'
}

test_have_finds_a_real_binary() {
  have sh || return 1
}

test_have_rejects_a_missing_binary() {
  assert_fails have definitely-not-a-real-binary-xyz
}

test_cel_root_points_at_the_repo() {
  [ -f "$CEL_ROOT/lib/common.sh" ] || return 1
}

test_repo_default_ref_uses_master_when_symbolic_default_is_absent() {
  local T; T="$(mktemp -d)"
  git -C "$T" init -q
  git -C "$T" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T" update-ref refs/remotes/origin/master HEAD
  assert_eq "$(repo_default_ref "$T")" origin/master
  rm -rf "$T"
}

test_repo_default_ref_refuses_dangling_authoritative_default() {
  local T; T="$(mktemp -d)"
  git -C "$T" init -q
  git -C "$T" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$T" update-ref refs/remotes/origin/main HEAD
  git -C "$T" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/missing
  assert_fails repo_default_ref "$T"
  rm -rf "$T"
}

# `exec {fd}>file 2>/dev/null` (or `exec 8>file 2>/dev/null`) does not just
# hush the open: an exec with no command makes every redirection permanent, so
# the rest of the process writes stderr to /dev/null. The open is braced -
# `{ exec {fd}>file; } 2>/dev/null` - wherever it is silenced.
# A process substitution (`exec {fd}< <(cmd 2>/dev/null)`) silences only cmd.
test_regression_no_exec_redirect_silences_stderr_for_the_rest_of_the_process() {
  local hits
  hits="$(cd "$CEL_ROOT" && git ls-files -z lib bin core tools tests/lib \
    | xargs -0 grep -nE '(^|[^{] )exec +(\{[A-Za-z_][A-Za-z0-9_]*\}|[0-9]+)[<>]+[^;&|]* 2>/dev/null' 2>/dev/null \
    | grep -vE '^[^:]+\.(md|json|css|html|mjs|js|py):|[<>]\(' || true)"
  assert_eq "$hits" ""
}
