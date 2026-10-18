# shellcheck shell=bash
# Pi and OMP must never share an agent root (CEL-AH-261018).
#
# OMP's startup migrates every Pi-style `--home-...--` session directory it
# finds under ITS root to a short name, with no liveness check. Pi caches its
# session file path and appends without re-creating the parent, so a Pi worker
# launched with OMP's root in PI_CODING_AGENT_DIR lost its session writes the
# moment any OMP started. These tests pin the consumer-visible invariants:
# fixture HOME and roots only, no credentials, no inference, no live session.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/run.sh"

_ar_setup() {
  T="$(mktemp -d)"
  export HOME="$T/home"; mkdir -p "$HOME"
  unset PI_CODING_AGENT_DIR CEL_PI_AGENT_DIR CEL_OMP_AGENT_DIR CEL_SESSION_ID OMP_GATEWAY_TOKEN
  export CEL_GATEWAY_STATE="$T/gwstate"; mkdir -p "$CEL_GATEWAY_STATE"
  printf 'fixture-key\n' >"$CEL_GATEWAY_STATE/api-key"
}
_ar_teardown() { rm -rf "$T"; }

# The launch words a pane is typed, built exactly as the launchers build them.
_ar_line() { # <runtime> [gateway-env words...]
  local rt="$1"; shift
  local -a GATEWAY_ENV=("$@")
  _run_launch_env worker "$T" /r.md "" "$rt"
}

test_agent_roots_pi_ignores_an_inherited_omp_root() {
  _ar_setup
  export PI_CODING_AGENT_DIR="$HOME/.omp/agent"
  assert_eq "$(gateway_pi_dir)" "$HOME/.pi/agent"
  local got; got="$(bash -c "$(_ar_line pi) printenv PI_CODING_AGENT_DIR")"
  assert_eq "$got" "$HOME/.pi/agent"
  got="$(bash -c "$(_ar_line omp) printenv PI_CODING_AGENT_DIR")"
  assert_eq "$got" "$HOME/.omp/agent"
  _ar_teardown
}

test_agent_roots_custom_pi_root_is_one_resolution_everywhere() {
  _ar_setup
  export CEL_PI_AGENT_DIR="$T/mypi"
  export PI_CODING_AGENT_DIR="$HOME/.omp/agent"      # leaked, must lose
  assert_eq "$(gateway_pi_dir)" "$T/mypi"
  assert_eq "$(bash -c "$(_ar_line pi) printenv PI_CODING_AGENT_DIR")" "$T/mypi"
  assert_eq "$(bash -c "$(_ar_line omp) printenv PI_CODING_AGENT_DIR")" "$HOME/.omp/agent"
  # the gateway model writer targets the same directory the child reads
  cat >"$T/gw" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  ready) exit 0 ;;
  models) printf '%s\n' '{"data":[{"id":"gpt-5.5","context_length":272000,"max_output_tokens":8192}]}' ;;
esac
EOS
  chmod +x "$T/gw"
  printf 'gateway:\n  port: 8317\n' >"$T/config.yaml"
  CEL_CONFIG_FILE="$T/config.yaml" CEL_GATEWAY_STUB="$T/gw" gateway_pi_models_write >/dev/null
  [ -f "$T/mypi/models.json" ] || { echo "models.json not written to the custom pi root"; _ar_teardown; return 1; }
  [ ! -e "$HOME/.omp/agent/models.json" ] || { echo "models.json written into omp's root"; _ar_teardown; return 1; }
  # doctor reads auth from that same directory
  mkdir -p "$T/mypi"; printf '{"anthropic":{"access":"x","expires":%s}}' "$(( ($(date +%s) + 86400) * 1000 ))" >"$T/mypi/auth.json"
  assert_eq "$(_doctor_auth_file)" "$T/mypi/auth.json"
  _ar_teardown
}
_doctor_auth_file() { source "$CEL_ROOT/lib/doctor.sh"; printf '%s/auth.json' "$(gateway_pi_dir)"; }

test_agent_roots_overlap_is_refused_without_mutation() {
  _ar_setup
  mkdir -p "$HOME/.omp/agent" "$T/alias-parent"
  ln -s "$HOME/.omp/agent" "$T/alias-parent/omp-alias"
  local before; before="$(find "$T" | sort | md5sum)"
  local c out
  for c in "$HOME/.omp/agent" "$T/alias-parent/omp-alias" "$HOME/.omp/agent/inner" "$HOME/.omp" "$T/alias-parent/omp-alias/../agent/x/.."; do
    out="$( ( export CEL_PI_AGENT_DIR="$c"; agent_roots_check pi ) 2>&1 )" \
      && { echo "overlap accepted: $c"; _ar_teardown; return 1; }
    assert_contains "$out" "CEL_PI_AGENT_DIR" || { _ar_teardown; return 1; }
    out="$( ( export CEL_PI_AGENT_DIR="$c"; PROFILE_VIA=native; _run_profile_gateway_setup pi w 0 1 ) 2>&1 )" \
      && { echo "launch setup accepted overlap: $c"; _ar_teardown; return 1; }
  done
  assert_eq "$(find "$T" | sort | md5sum)" "$before"
  # distinct roots pass, and so does the default pair
  ( export CEL_PI_AGENT_DIR="$T/mypi"; agent_roots_check pi ) || { _ar_teardown; return 1; }
  agent_roots_check omp || { _ar_teardown; return 1; }
  _ar_teardown
}

test_agent_roots_native_pi_and_omp_need_no_gateway() {
  _ar_setup
  rm -f "$CEL_GATEWAY_STATE/api-key"
  local -a GATEWAY_ENV=()
  PROFILE_VIA=native _run_profile_gateway_setup pi w 1 1 || { _ar_teardown; return 1; }
  PROFILE_VIA=native _run_profile_gateway_setup omp w 1 1 || { _ar_teardown; return 1; }
  assert_eq "${#GATEWAY_ENV[@]}" 0
  # required gateway with no key stays fail-closed
  assert_fails bash -c "source '$CEL_ROOT/lib/common.sh'; source '$CEL_ROOT/lib/run.sh'; HOME='$HOME' CEL_GATEWAY_STATE='$CEL_GATEWAY_STATE' PROFILE_VIA=gateway _run_profile_gateway_setup pi w 1 0"
  _ar_teardown
}

# The pane shell outlives the agent: nothing launch-only may remain in it.
test_agent_roots_launch_exports_do_not_survive_in_the_pane_shell() {
  _ar_setup
  local -a GATEWAY_ENV=()
  PROFILE_VIA=gateway _run_profile_gateway_setup pi child-a 1 0 child-a
  local line; line="$(_run_launch_env worker "$T" /r.md "" pi)"
  # the typed line, then the agent command, then a later command, all in ONE shell
  local out; out="$(env -u CEL_SESSION_ID -u PI_CODING_AGENT_DIR -u OMP_GATEWAY_TOKEN bash -c \
    "$line sh -c 'printf \"in-agent:%s|%s|%s\\n\" \"\$CEL_SESSION_ID\" \"\$OMP_GATEWAY_TOKEN\" \"\$PI_CODING_AGENT_DIR\"'
     printf 'after:%s|%s|%s\\n' \"\${CEL_SESSION_ID-unset}\" \"\${OMP_GATEWAY_TOKEN-unset}\" \"\${PI_CODING_AGENT_DIR-unset}\"")"
  assert_contains "$out" "in-agent:child-a|fixture-key|$HOME/.pi/agent"
  assert_contains "$out" "after:unset|unset|unset"
  # a second child in the same pane gets its own session id
  GATEWAY_ENV=(); PROFILE_VIA=gateway _run_profile_gateway_setup pi child-b 1 0 child-b
  line="$(_run_launch_env worker "$T" /r.md "" pi)"
  out="$(env -u CEL_SESSION_ID bash -c "$line printenv CEL_SESSION_ID")"
  assert_eq "$out" "child-b"
  # and no secret in the typed text itself
  case "$line" in *fixture-key*) echo "key value in the typed launch line"; _ar_teardown; return 1 ;; esac
  _ar_teardown
}

# THE INCIDENT, end to end, with the real Pi SessionManager and the real OMP
# binary in a network-less sandbox over a fixture HOME. Missing prerequisites
# are a loud SKIP, and a FAILURE under CEL_TEST_REQUIRE_REAL_RUNTIME=1 (the
# gate on a box that has them must set it): a skip is not proof.
_ar_real_prereq() { # sets _AR_PKG; returns 0 when runnable
  local pi_bin pkg
  pi_bin="$(command -v pi)" && command -v omp >/dev/null && have bwrap \
    && bwrap --ro-bind / / --unshare-net true 2>/dev/null || return 1
  pkg="$(dirname "$(readlink -f "$pi_bin")")"
  while [ "$pkg" != / ] && [ ! -f "$pkg/package.json" ]; do pkg="$(dirname "$pkg")"; done
  [ -f "$pkg/dist/index.js" ] || return 1
  _AR_PKG="$pkg"
}
# <pi-launch-prefix-or-empty> <PI_CODING_AGENT_DIR for the pi child if no prefix> -> JSON on stdout
_ar_real_run() {
  local pi_line="$1" pidir="$2" omp_line; omp_line="$(_run_launch_env worker "$T" /r.md "" omp)"
  local cwd="$HOME/work/proj-a"; mkdir -p "$cwd" "$cwd-other"
  cd "$cwd" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$T" PI_CODING_AGENT_DIR="$pidir" \
    OTHER="${omp_line}omp -p noop" \
    bwrap --ro-bind / / --dev /dev --proc /proc --bind "$T" "$T" --unshare-net --unshare-pid \
      bash -c "$pi_line node '$CEL_ROOT/tests/fixtures/pi-session-writer.mjs' '$_AR_PKG' '$cwd' \"\$OTHER\"" 2>&1
}
test_agent_roots_real_pi_survives_real_omp_start() {
  _ar_setup
  if ! _ar_real_prereq; then
    if [ "${CEL_TEST_REQUIRE_REAL_RUNTIME:-}" = 1 ]; then echo "real pi/omp/bwrap required but unavailable"; _ar_teardown; return 1; fi
    echo "SKIP (not proof): pi, omp or a network-denied sandbox is unavailable"; _ar_teardown; return 0
  fi
  # NEGATIVE CONTROL: the harness with pi handed omp's root (what the old
  # forwarding did) must reproduce the incident - omp ran and pi's append died.
  local ctl rc=0
  ctl="$(_ar_real_run "env " "$HOME/.omp/agent")" || rc=$?
  [ "$rc" -ne 0 ] && assert_contains "$ctl" '"err":"ENOENT' \
    || { printf '%s\n' "$ctl" >&2; echo "negative control did not reproduce the collision - the harness proves nothing"; _ar_teardown; return 1; }
  assert_contains "$ctl" '"other":' >/dev/null
  rm -rf "$HOME/.omp" "$HOME/.pi" "$HOME/work"
  # THE FIX: the canonical launch construction, under the same contaminated parent
  export PI_CODING_AGENT_DIR="$HOME/.omp/agent"
  local out; rc=0
  out="$(_ar_real_run "$(_run_launch_env worker "$T" /r.md "" pi)" "$HOME/.omp/agent")" || rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" >&2; echo "pi lost its session write after omp started"; _ar_teardown; return 1; fi
  assert_contains "$out" '"second":true'
  assert_contains "$out" '"first":true'
  assert_contains "$out" '"prefixKept":true'   # byte-for-byte prefix preserved
  local file; file="$(printf '%s' "$out" | jq -r .file)"
  # the exact file pi made is still where pi made it, under pi's root, intact
  case "$file" in "$HOME/.pi/agent/sessions/"*) ;; *) echo "pi session not under pi's root: $file"; _ar_teardown; return 1 ;; esac
  [ -f "$file" ] || { echo "pi session file vanished: $file"; _ar_teardown; return 1; }
  assert_eq "$(jq -r 'select(.type=="session") | .id' "$file" | head -1)" "$(printf '%s' "$out" | jq -r .id)"
  assert_eq "$(wc -l <"$file" | tr -d ' ')" 3
  # omp demonstrably ran and used only its own root
  [ -d "$HOME/.omp/agent/sessions" ] && [ -n "$(ls "$HOME/.omp/agent/sessions")" ] \
    || { echo "omp did not start in its own root - the run exercised nothing"; _ar_teardown; return 1; }
  ! ls "$HOME/.omp/agent/sessions" | grep -q "^--" || { echo "pi-style dir in omp's root"; _ar_teardown; return 1; }
  _ar_teardown
}

test_agent_roots_console_launch_refuses_overlap() {
  _ar_setup
  export CEL_PI_AGENT_DIR="$HOME/.omp/agent/pi"
  _run_console_default() { case "$1" in runtime) echo pi ;; *) echo "" ;; esac; }
  _run_console_dir() { echo "$T/console"; }
  local out; out="$( ( _run_console "" "" "" 1 1 ) 2>&1 )" && { echo "console accepted overlap"; _ar_teardown; return 1; }
  assert_contains "$out" "overlap"
  _ar_teardown
}

test_agent_roots_relative_and_odd_paths_are_made_absolute_and_checked() {
  _ar_setup
  mkdir -p "$T/cwd" "$HOME/.omp/agent" "$T/real"; ln -s "$T/real" "$T/link"
  cd "$T/cwd"
  # relative root: absolute in the pin, whatever cwd the child has
  export CEL_PI_AGENT_DIR="rel/pi"
  assert_eq "$(gateway_pi_dir)" "$T/cwd/rel/pi"
  local rel_line; rel_line="$(_ar_line pi)"
  assert_eq "$(cd / && bash -c "$rel_line printenv PI_CODING_AGENT_DIR")" "$T/cwd/rel/pi"
  # relative overlap with omp's root is still refused
  export CEL_PI_AGENT_DIR="../home/.omp/agent/x"
  agent_roots_check pi 2>/dev/null && { echo "relative overlap accepted"; _ar_teardown; return 1; }
  # whitespace survives the pin
  export CEL_PI_AGENT_DIR="$T/my pi dir"
  assert_eq "$(bash -c "$(_ar_line pi) printenv PI_CODING_AGENT_DIR")" "$T/my pi dir"
  # nonexistent path beneath a symlink ancestor resolves through the link
  ln -s "$HOME/.omp/agent" "$T/omplink"
  export CEL_PI_AGENT_DIR="$T/omplink/does/not/exist"
  agent_roots_check pi 2>/dev/null && { echo "overlap hidden behind symlink ancestor accepted"; _ar_teardown; return 1; }
  export CEL_PI_AGENT_DIR="$T/link/new"
  agent_roots_check pi || { _ar_teardown; return 1; }
  _ar_teardown
}

test_agent_roots_doctor_warns_on_an_ambient_pi_root() {
  _ar_setup
  source "$CEL_ROOT/lib/doctor.sh"
  export PI_CODING_AGENT_DIR="$HOME/.omp/agent"
  local out; out="$(doctor_agent_roots_lines 2>&1)" || { echo "an ambient value alone must warn, not fail"; _ar_teardown; return 1; }
  assert_contains "$out" "PI_CODING_AGENT_DIR"
  _ar_teardown
}

test_agent_roots_doctor_fails_on_overlap_and_passes_when_disjoint() {
  _ar_setup
  source "$CEL_ROOT/lib/doctor.sh"
  doctor_agent_roots_lines >/dev/null 2>&1 || { _ar_teardown; return 1; }
  export CEL_PI_AGENT_DIR="$HOME/.omp/agent/pi"
  local out; out="$(doctor_agent_roots_lines 2>&1)" && { echo "doctor passed an overlap"; _ar_teardown; return 1; }
  assert_contains "$out" "overlap"
  _ar_teardown
}
