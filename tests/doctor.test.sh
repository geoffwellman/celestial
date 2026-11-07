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

# A box with a gateway in its config and nothing in services.d is a gateway
# nobody is watching, and doctor is where that gets said out loud.
test_doctor_says_the_gateway_is_not_supervised() {
  _doctor_setup
  cel_config_set gateway gateway_port 47411
  assert_contains "$(doctor_box_services_line)" "cel gateway install"
  printf '{"name":"cel-auth-gateway","port":47411}\n' > "$CEL_SERVICES_D/cel-auth-gateway.json"
  ! printf '%s' "$(doctor_box_services_line)" | grep -q "not supervised" \
    || { echo "doctor calls a supervised gateway unsupervised"; _doctor_teardown; return 1; }
  _doctor_teardown
}

test_doctor_reports_ledgered_and_unledgered_servers() {
  local t
  t="$(mktemp -d)"
  export CEL_SERVE_STATE="$t/state" CEL_SERVE_SYSTEMCTL="$t/systemctl" CEL_SERVE_PROC_DATA=''
  mkdir -p "$CEL_SERVE_STATE"
  printf '%s\n' '{"name":"demo","unit":"cel-serve-demo","owner":"worker","workspace":"alpha","started_at":100,"ttl_seconds":3600,"port":5173}' > "$CEL_SERVE_STATE/demo.json"
  printf '%s\n' '[{"pid":1234,"memory_mb":70,"age_seconds":500,"managed":false}]' > "$t/adopt.json"
  export CEL_SERVE_ADOPT_DATA="$(cat "$t/adopt.json")"
  cat > "$CEL_SERVE_SYSTEMCTL" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *ControlGroup*) printf '/user.slice/cel-serve-demo.service\n';;
esac
EOF
  chmod +x "$CEL_SERVE_SYSTEMCTL"
  local out; out="$(doctor_serve_line)"
  assert_contains "$out" "preview servers: 1 ledgered, 1 unledgered" || { rm -rf "$t"; return 1; }
  assert_contains "$out" "cel serve list" || { rm -rf "$t"; return 1; }
  # a count and a pointer, never the inventory itself
  assert_eq "$(printf '%s\n' "$out" | grep -c .)" 1 || { rm -rf "$t"; return 1; }
  case "$out" in *pid:1234*) echo "doctor listed an unledgered server: $out"; rm -rf "$t"; return 1 ;; esac
  unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_SERVE_PROC_DATA CEL_SERVE_ADOPT_DATA
  rm -rf "$t"
}

# ----------------------------------------------------------------
# DOCTOR JUDGES A WORKSPACE WITH ITS OWN ENV LOADED. A `setup:` check such as
# `test -n "$WIDGET_KEY"` reads a value from that workspace's gitignored
# env.local; in a bare login shell it would fail on a correctly configured box.
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

# A CHECKOUT NOBODY TOLD YOU WAS STALE. Every conclusion drawn from a stale
# `$ws/repos/<repo>` is about the wrong tree: one line, the count, the cure.
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
  # the remedy names the remote and branch it counted against
  assert_contains "$out" "git -C $T/clone pull --ff-only origin main"
  rm -rf "$T"
}

# The remedy it gives actually brings the checkout level with the default
# branch, even when the branch tracks some other upstream.
test_doctor_remedy_for_a_stale_default_branch_clears_the_finding() {
  _doctor_repo_fixture 2
  git -C "$T/clone" config branch.main.merge refs/heads/elsewhere
  local out cmd; out="$(doctor_checkout_behind_line "$T/clone" alpha/widget)"
  cmd="${out#* - }"
  eval "$cmd" >/dev/null 2>&1 || { echo "remedy failed: $cmd"; rm -rf "$T"; return 1; }
  assert_eq "$(doctor_checkout_behind_line "$T/clone" alpha/widget)" ""
  rm -rf "$T"
}

# A feature branch is behind the default branch by design, and pulling it
# would not change that: no finding - and no network, so an unreachable
# origin changes nothing (any fetch or remote query would print UNKNOWN).
test_doctor_says_nothing_about_a_checkout_on_a_feature_branch() {
  _doctor_repo_fixture 3
  git -C "$T/clone" checkout -q -b feature
  git -C "$T/clone" remote set-url origin "$T/unreachable"
  local out
  out="$(doctor_checkout_behind_line "$T/clone" alpha/widget)" \
    || { echo "the check itself failed on a feature branch"; rm -rf "$T"; return 1; }
  assert_eq "$out" "" || { rm -rf "$T"; return 1; }
  git -C "$T/clone" checkout -q --detach
  assert_eq "$(doctor_checkout_behind_line "$T/clone" alpha/widget)" ""
  rm -rf "$T"
}

# The default branch is read from the local origin/HEAD, never asked of the
# network; without it the check says it cannot tell, and how to fix that.
test_doctor_without_a_local_origin_head_says_so_without_asking_the_network() {
  _doctor_repo_fixture 3
  git -C "$T/clone" remote set-head origin -d
  git -C "$T/clone" remote set-url origin "$T/unreachable"
  local out; out="$(doctor_checkout_behind_line "$T/clone" alpha/widget)"
  assert_contains "$out" "UNKNOWN" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "git -C $T/clone remote set-head origin --auto"
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

# ----------------------------------------------------------------
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

# The ssh alias check matches the declared alias as a literal, standalone
# Host token, never a regex: a dot is not any character, and a wildcard Host
# pattern is not the entry.
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

# Leaked inbox watchers are invisible until something counts them. Doctor
# counts watchers and samples the box's fork rate, and says so in red over a
# bound.
test_doctor_exec_load_is_quiet_green_under_the_bound() {
  _doctor_watch_count() { printf 4; }
  _doctor_fork_rate() { printf 30; }
  local out; out="$(doctor_exec_load_line)"; local rc=$?
  assert_eq "$rc" "0"
  assert_contains "$out" "inbox watchers: 4"
  assert_contains "$out" "30/sec"
}
test_doctor_exec_load_is_red_over_the_bound() {
  _doctor_watch_count() { printf 182; }
  _doctor_fork_rate() { printf 30; }
  assert_fails doctor_exec_load_line
  _doctor_watch_count() { printf 4; }
  _doctor_fork_rate() { printf 600; }
  assert_fails doctor_exec_load_line
}
# A sample length that is not a whole number of seconds is not a divisor: zero
# and fractions fall back to the default sample instead of breaking doctor.
test_regression_doctor_fork_rate_survives_a_zero_or_fractional_sample_length() {
  local s r
  for s in 0 0.5 junk; do
    r="$(CEL_DOCTOR_FORK_SECS="$s" _doctor_fork_rate 2>/dev/null)"
    [[ "$r" =~ ^[0-9]+$ ]] || { echo "CEL_DOCTOR_FORK_SECS=$s gave '$r'"; return 1; }
  done
}
_doctor_pi_fixture() {
  _doctor_setup
  export CEL_REGISTRY="$T/registry.yaml"
  export CEL_PI_AGENT_DIR="$T/pi"
  mkdir -p "$T/ws" "$T/pi"
  cat >"$T/registry.yaml" <<EOF
workspaces:
  alpha:
    path: $T/ws
    remote: null
EOF
  cat >"$T/ws/workspace.yaml" <<'EOF'
name: alpha
runtime: { worker: pi }
worker_profiles:
  default: { runtime: pi, model: claude-opus-4 }
EOF
}

test_doctor_reports_expired_pi_anthropic_credential_with_relogin_fix() {
  _doctor_pi_fixture
  printf '{"anthropic":{"access":"fixture-token","expires":1}}\n' >"$T/pi/auth.json"
  local out; out="$(doctor_pi_anthropic_lines "$T/ws" alpha)"
  assert_contains "$out" "expired"
  assert_contains "$out" "pi /login"
  assert_contains "$out" "via: gateway"
  _doctor_teardown
}

test_doctor_reports_valid_pi_anthropic_credential() {
  _doctor_pi_fixture
  printf '{"anthropic":{"access":"fixture-token","expires":4102444800000}}\n' >"$T/pi/auth.json"
  assert_contains "$(doctor_pi_anthropic_lines "$T/ws" alpha)" "valid"
  _doctor_teardown
}

test_doctor_ignores_pi_login_for_reviewer_only_profile_routed_via_gateway() {
  _doctor_pi_fixture
  cat >"$T/ws/workspace.yaml" <<'EOF'
name: alpha
runtime: { worker: pi }
review: { runtime: pi, model: sonnet }
role_profiles: { reviewer: review-pi }
worker_profiles:
  review-pi: { runtime: pi, model: claude-opus-5-5 }
EOF
  printf '{"anthropic":{"access":"fixture-token","expires":1}}\n' >"$T/pi/auth.json"
  local out; out="$(doctor_pi_anthropic_lines "$T/ws" alpha)"
  case "$out" in
    *"pi Anthropic credential"*) echo "doctor incorrectly requires pi login for gateway-routed reviewer"; _doctor_teardown; return 1 ;;
  esac
  _doctor_teardown
}

test_doctor_keeps_pi_login_warning_when_reviewer_profile_is_shared_with_worker() {
  _doctor_pi_fixture
  cat >"$T/ws/workspace.yaml" <<'EOF'
name: alpha
runtime: { worker: pi }
review: { runtime: pi, model: sonnet }
role_profiles: { reviewer: review-pi, worker: review-pi }
worker_profiles:
  review-pi: { runtime: pi, model: claude-opus-5-5 }
EOF
  printf '{"anthropic":{"access":"fixture-token","expires":1}}\n' >"$T/pi/auth.json"
  local out; out="$(doctor_pi_anthropic_lines "$T/ws" alpha)"
  assert_contains "$out" "pi Anthropic credential expired"
  _doctor_teardown
}

test_doctor_check_workspaces_runs_github_account_check() {
  _doctor_setup
  mkdir -p "$T/ws"
  printf 'name: alpha\ngithub: { user: fixture-account }\n' >"$T/ws/workspace.yaml"
  printf 'repos/\nspikes/\n.cel/\n' >"$T/ws/.gitignore"
  local out
  out="$(
    (
      registry_names() { printf 'alpha\n'; }
      registry_path() { printf '%s' "$T/ws"; }
      registry_remote() { printf 'https://example.invalid/alpha'; }
      fleet_mail_doctor_line() { return 0; }
      doctor_pi_anthropic_lines() { return 0; }
      doctor_github_account() { printf 'github-account-check %s\n' "$1"; }
      ws_repo_names() { return 0; }
      ws_layout() { return 0; }
      doctor_setup_lines() { return 0; }
      doctor_ws_local_summary() { return 0; }
      doctor_ws_local_lines() { return 0; }
      doctor_ws_contract_lines() { return 0; }
      ws_runtime() { printf 'bash'; }
      agent_get() { printf 'bash'; }
      check_workspaces
    ) 2>&1
  )"
  assert_contains "$out" "github-account-check alpha"
  _doctor_teardown
}
