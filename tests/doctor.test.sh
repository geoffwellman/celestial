# shellcheck shell=bash
# `cel doctor` - the box services line.
#
# Nothing here touches the live box: CEL_SERVICES_D is a fixture directory and
# the gateway config is a fixture file.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/doctor.sh"

_doctor_setup() {
  T="$(mktemp -d)"
  export CEL_SERVICES_D="$T/services.d"
  export CEL_CONFIG_FILE="$T/config.yaml"
  mkdir -p "$CEL_SERVICES_D"
}
_doctor_teardown() { rm -rf "$T"; unset CEL_SERVICES_D CEL_CONFIG_FILE; }

# One line: how many the box declares and how many are actually answering.
test_doctor_counts_box_services() {
  _doctor_setup
  printf '{"name":"cel-auth-broker","port":47311,"health":"/"}\n' > "$CEL_SERVICES_D/cel-auth-broker.json"
  local out; out="$(doctor_box_services_line)"
  assert_contains "$out" "box services: 1 declared"
  assert_contains "$out" "healthy"
  _doctor_teardown
}

# The failure this ticket exists for: a box with a gateway in its config and
# nothing in services.d is a gateway nobody is watching, and doctor is where
# that gets said out loud.
test_doctor_says_the_gateway_is_not_supervised() {
  _doctor_setup
  cel_config_set gateway gateway_port 47411
  assert_contains "$(doctor_box_services_line)" "cel gateway install"
  printf '{"name":"cel-auth-gateway","port":47411}\n' > "$CEL_SERVICES_D/cel-auth-gateway.json"
  ! printf '%s' "$(doctor_box_services_line)" | grep -q "not supervised" \
    || { echo "doctor calls a supervised gateway unsupervised"; _doctor_teardown; return 1; }
  _doctor_teardown
}

# ---------------------------------------------------------------- CEL-53
# DOCTOR USED TO JUDGE A WORKSPACE WITHOUT READING IT. Each workspace's
# `setup:` checks ran in a bare login shell, so `test -n "$WIDGET_KEY"` failed
# on a correctly configured box - the value lives in that workspace's
# gitignored env.local and nothing had sourced it. A newcomer saw red lines
# against work they had done correctly and learned the tool cannot be trusted,
# which is the worst thing doctor can teach on day one.
_setup_ws() { # <dir> <yaml-setup-block>
  mkdir -p "$1"
  cat > "$1/workspace.yaml" <<'YAML'
name: fixture
kind: personal
setup:
  - name: widget key
    check: 'test -n "$WIDGET_KEY"'
    hint: put WIDGET_KEY in env.local
YAML
}

test_doctor_setup_check_reads_the_workspace_env_local() {
  _doctor_setup
  _setup_ws "$T/alpha"
  printf 'export WIDGET_KEY=abc123\n' > "$T/alpha/env.local"
  local out; out="$(doctor_setup_lines "$T/alpha" alpha)" || { echo "doctor_setup_lines failed"; _doctor_teardown; return 1; }
  assert_eq "$out" ""
  _doctor_teardown
}

test_doctor_setup_check_with_the_value_absent_still_fails() {
  _doctor_setup
  _setup_ws "$T/alpha"
  local out; out="$(doctor_setup_lines "$T/alpha" alpha)"
  assert_contains "$out" "widget key"
  assert_contains "$out" "unmet"
  assert_contains "$out" "env.local"
  _doctor_teardown
}

# A value that is MISSING and an env that could not be READ are different
# findings. Reporting the second as the first sends someone to add a key they
# already added.
test_doctor_says_when_the_env_could_not_be_read_at_all() {
  _doctor_setup
  _setup_ws "$T/alpha"
  printf 'export WIDGET_KEY=(\n' > "$T/alpha/env.local"   # unparseable
  local out; out="$(doctor_setup_lines "$T/alpha" alpha)"
  assert_contains "$out" "could not be read"
  case "$out" in *unmet*) echo "an unreadable env is reported as a missing value"; _doctor_teardown; return 1;; esac
  _doctor_teardown
}

# Two workspaces, one variable, two values: doctor runs each check in a
# subshell, so neither the first workspace's env nor doctor's own leaks.
test_doctor_workspace_envs_do_not_leak_into_each_other() {
  _doctor_setup
  _setup_ws "$T/alpha"; printf 'export WIDGET_KEY=alpha\n' > "$T/alpha/env.local"
  _setup_ws "$T/beta";  printf 'export WIDGET_KEY=beta\n'  > "$T/beta/env.local"
  local tmp
  for w in alpha beta; do
    tmp="$(mktemp)"
    yq -y --arg v "$w" '.setup[0].check = ("test \"$WIDGET_KEY\" = " + $v)' \
      "$T/$w/workspace.yaml" > "$tmp" && mv "$tmp" "$T/$w/workspace.yaml"
  done
  local a b
  a="$(doctor_setup_lines "$T/alpha" alpha)" || { echo "doctor_setup_lines failed"; _doctor_teardown; return 1; }
  b="$(doctor_setup_lines "$T/beta" beta)" || { echo "doctor_setup_lines failed"; _doctor_teardown; return 1; }
  assert_eq "$a" ""
  assert_eq "$b" ""
  assert_eq "${WIDGET_KEY:-}" ""
  _doctor_teardown
}

# A CHECKOUT NOBODY TOLD YOU WAS STALE. The orchestrator's `$ws/repos/<repo>`
# sat 18 commits behind origin/main for a whole day on 2026-09-21 and every
# conclusion drawn from it - a benchmark, two reviews - was wrong about the
# wrong tree. This is the cheap half of that: one line, the count, the cure.
_doctor_repo_fixture() { # -> $T/clone, behind origin/main by $1 commits
  T="$(mktemp -d)"
  local g=(git -c user.email=t@t -c user.name=t) i
  git -C "$T" init -q -b main "$T/origin" >/dev/null 2>&1 || { mkdir -p "$T/origin"; git -C "$T/origin" init -q -b main; }
  "${g[@]}" -C "$T/origin" commit -q --allow-empty -m base
  git clone -q "$T/origin" "$T/clone"
  for i in $(seq 1 "${1:-0}"); do
    "${g[@]}" -C "$T/origin" commit -q --allow-empty -m "ahead $i"
  done
}

test_doctor_says_how_far_behind_a_checkout_is() {
  _doctor_repo_fixture 3
  local out; out="$(doctor_checkout_behind_line "$T/clone" alpha/widget)"
  assert_contains "$out" "3 commits behind"
  assert_contains "$out" "alpha/widget"
  assert_contains "$out" "git -C $T/clone pull --ff-only"
  rm -rf "$T"
}

test_doctor_says_nothing_about_a_current_checkout() {
  _doctor_repo_fixture 0
  local out
  out="$(doctor_checkout_behind_line "$T/clone" alpha/widget)" \
    || { echo "the check itself failed on a healthy checkout"; return 1; }
  assert_eq "$out" ""
  rm -rf "$T"
}

# A checkout that cannot be asked is UNKNOWN and says so. Silence here would
# read as "up to date", which is the failure this whole check exists for.
test_doctor_calls_an_unaskable_checkout_unknown() {
  _doctor_repo_fixture 0
  git -C "$T/clone" remote remove origin
  assert_contains "$(doctor_checkout_behind_line "$T/clone" alpha/widget)" "UNKNOWN"
  rm -rf "$T"
}

# ---------------------------------------------------------------- CEL-59
# AN AFK MODE THAT STAYS ON BECAUSE NOBODY TURNED IT OFF is how a fortnight of
# unattended merges happens. `--until` expires on its own, and doctor is where
# an AFK left on past that hour is said out loud - the operator who thinks
# they are driving must not be surprised by an agent acting.
_doctor_afk_fixture() { T="$(mktemp -d)"; export CEL_AFK_STATE="$T/afk"; }
_doctor_afk_teardown() { rm -rf "$T"; unset CEL_AFK_STATE; }

test_doctor_says_nothing_about_a_live_afk() {
  _doctor_afk_fixture
  source "$CEL_ROOT/lib/afk.sh"
  cmd_afk on --until '+8h' --reason 'asleep' >/dev/null
  assert_contains "$(doctor_afk_line)" "AFK on until"
  case "$(doctor_afk_line)" in *expired*) echo "doctor calls a live AFK expired"; _doctor_afk_teardown; return 1;; esac
  _doctor_afk_teardown
}

test_doctor_reports_an_afk_left_on_past_its_until() {
  _doctor_afk_fixture
  source "$CEL_ROOT/lib/afk.sh"
  cmd_afk on --until '2020-01-01T00:00:00Z' >/dev/null
  local out; out="$(doctor_afk_line)"
  assert_contains "$out" "expired"
  assert_contains "$out" "cel afk off"
  _doctor_afk_teardown
}

test_doctor_is_silent_when_afk_was_never_armed() {
  _doctor_afk_fixture
  source "$CEL_ROOT/lib/afk.sh"
  assert_eq "$(doctor_afk_line)" ""
  _doctor_afk_teardown
}

# CEL-79: the ssh alias check matches the declared alias as a literal,
# standalone Host token. It used to interpolate it into a regex, so a dot
# matched any character, and a wildcard Host pattern was taken as the entry.
_doctor_ssh_fixture() { # <ssh-config-body>
  T="$(mktemp -d)"
  mkdir -p "$T/home/.ssh" "$T/bin"
  printf '%s\n' "$1" > "$T/home/.ssh/config"
  printf 'name: alpha\ngithub:\n  user: acct-b\n  ssh_host: gh.acct-b\n' > "$T/workspace.yaml"
  printf '#!/usr/bin/env bash\necho "Logged in to github.com account acct-b (keyring)"\n' > "$T/bin/gh"
  chmod +x "$T/bin/gh"
}
_doctor_ssh_run() { HOME="$T/home" PATH="$T/bin:$PATH" doctor_github_account alpha "$T" 2>&1; }

test_doctor_ssh_alias_accepts_the_literal_host_token() {
  _doctor_ssh_fixture $'Host other gh.acct-b\n  HostName github.com'
  local out rc=0; out="$(_doctor_ssh_run)" || rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "ssh alias gh.acct-b"
  rm -rf "$T"
}
test_doctor_ssh_alias_is_not_a_regex() {
  _doctor_ssh_fixture $'Host ghXacct-b\n  HostName github.com'
  assert_fails _doctor_ssh_run
  rm -rf "$T"
}
test_doctor_ssh_alias_is_not_satisfied_by_a_wildcard_pattern() {
  _doctor_ssh_fixture $'Host gh.*\n  HostName github.com'
  assert_fails _doctor_ssh_run
  rm -rf "$T"
}
# ssh matches Host patterns case-insensitively, and so does this check.
test_doctor_ssh_alias_matches_regardless_of_case() {
  _doctor_ssh_fixture $'host GH.Acct-B\n  HostName github.com'
  local rc=0; _doctor_ssh_run >/dev/null || rc=$?
  assert_eq "$rc" 0
  rm -rf "$T"
}
