# shellcheck shell=bash
# NPM GLOBALS FOLLOW THE ACTIVE NODE. An npm-installed agent lives under the
# node that installed it (mise: installs/node/<version>/lib/node_modules). A
# new node release moving mise's `lts` alias leaves its shim on PATH with
# nothing behind it: `command -v pi` still succeeds, and running it prints
# "No version is set for shim: pi". `cel setup` and `cel update` reinstall
# such an agent under the active node - at the release the old node still
# holds when that is newer than the pin, never lower - and keep a working
# one; `cel doctor` names every dead shim with the command that fixes it.
#
# mise, npm and the tools are stubs in a scratch HOME: nothing is downloaded
# or installed for real, and the box's own mise is never reached.

_ng_setup() {
  T="$(mktemp -d)"; LOG="$T/log"; : > "$LOG"
  export HOME="$T/home" NG_T="$T"
  # the box's own mise data dir is never read
  unset MISE_DATA_DIR
  # the shim-check record (lib/common.sh) lands in a runtime dir of the test's
  export XDG_RUNTIME_DIR="$T/run"; mkdir -m 700 "$XDG_RUNTIME_DIR"
  MISE="$HOME/.local/share/mise"
  local old="$MISE/installs/node/24.20.0" pkg
  export NG_ACTIVE="$MISE/installs/node/24.22.3"
  mkdir -p "$T/bin" "$T/mise" "$MISE/shims" "$old/bin" "$NG_ACTIVE/bin" "$NG_ACTIVE/lib/node_modules"
  # mise's aliases are symlinks to a real release directory
  ln -s ./24.22.3 "$MISE/installs/node/lts"
  # The old node still holds pi 1.5.0 and graphite's gt 1.8.6.
  for pkg in @earendil-works/pi-coding-agent:1.5.0:pi:dist/cli.js @withgraphite/graphite-cli:1.8.6:gt:graphite.js; do
    IFS=: read -r name ver bin main <<< "$pkg"
    mkdir -p "$(dirname "$old/lib/node_modules/$name/$main")"
    printf '{"name":"%s","version":"%s"}\n' "$name" "$ver" > "$old/lib/node_modules/$name/package.json"
    : > "$old/lib/node_modules/$name/$main"
    ln -s "../lib/node_modules/$name/$main" "$old/bin/$bin"
  done
  ln -s ../lib/node_modules/@withgraphite/graphite-cli/graphite.js "$old/bin/graphite"
  # mise: as a shim (argv0 is the tool) it runs the tool only when the active
  # node holds it; as itself it answers `which`, `current node` and `reshim`.
  # While $NG_T/hang exists every call hangs (a wedged mise); in the
  # directory named by $NG_T/hang-in only `which` hangs; while
  # $NG_T/hang-version-<tool> exists that one shim hangs when run. A
  # directory whose .mise.toml pins another node resolves nothing.
  cat > "$T/mise/mise" <<'SH'
#!/usr/bin/env bash
name="${0##*/}"
[ ! -e "$NG_T/hang" ] || exec sleep 60
node=24.22.3; active=1
if [ -f "$PWD/.mise.toml" ]; then
  node="$(sed -n 's/^node = "\(.*\)"$/\1/p' "$PWD/.mise.toml")"
  [ "$node" = 24.22.3 ] || active=0
fi
if [ "$name" != mise ]; then
  [ ! -e "$NG_T/hang-version-$name" ] || exec sleep 60
  [ "$active" = 1 ] && [ -x "$NG_ACTIVE/bin/$name" ] && exec "$NG_ACTIVE/bin/$name" "$@"
  echo "mise ERROR No version is set for shim: $name" >&2
  echo "Set a global default version with one of the following:" >&2
  exit 1
fi
printf 'mise %s\n' "$*" >> "$NG_T/log"
case "$1" in
  which) [ "$(cat "$NG_T/hang-in" 2>/dev/null)" != "$PWD" ] || exec sleep 60
         [ "$active" = 1 ] && [ -x "$NG_ACTIVE/bin/$2" ] && { printf '%s\n' "$NG_ACTIVE/bin/$2"; exit 0; }
         echo "mise ERROR $2 is a mise bin however it is not currently active." >&2; exit 1 ;;
  current) printf '%s\n' "$node"; exit 0 ;;
  reshim) exit 0 ;;
esac
exit 2
SH
  chmod +x "$T/mise/mise"
  ln -s "$T/mise/mise" "$T/bin/mise"
  local s; for s in pi gt graphite; do ln -s "$T/mise/mise" "$MISE/shims/$s"; done
  # npm under the active node: `install -g <pkg>@<version>` puts a working
  # tool into the active node's bin.
  cat > "$T/bin/npm" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'prefix -g') printf '%s\n' "$NG_ACTIVE" ;;
  'root -g') printf '%s\n' "$NG_ACTIVE/lib/node_modules" ;;
  'install -g '*)
    printf 'npm %s\n' "$*" >> "$NG_T/log"
    [ ! -e "$NG_T/npm.fail" ] || exit 1
    spec="${*: -1}"; pkg="${spec%@*}"; ver="${spec##*@}"
    mkdir -p "$NG_ACTIVE/lib/node_modules/$pkg"
    printf '{"name":"%s","version":"%s"}\n' "$pkg" "$ver" > "$NG_ACTIVE/lib/node_modules/$pkg/package.json"
    case "$pkg" in @earendil-works/pi-coding-agent) bin=pi ;; *) exit 0 ;; esac
    printf '#!/usr/bin/env bash\ncase "$1" in --version) echo %s ;; update) echo "pi $*" >> "%s" ;; esac\n' "$ver" "$NG_T/log" > "$NG_ACTIVE/bin/$bin"
    chmod +x "$NG_ACTIVE/bin/$bin" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$T/bin/npm"
  ln -s "$(type -P yq)" "$T/bin/yq"; ln -s "$(type -P jq)" "$T/bin/jq"
  export CEL_MANIFEST="$T/agents.yaml" CEL_MANIFEST_CACHE="$T/cache"
  cat > "$CEL_MANIFEST" <<'YAML'
agents:
  pi:
    bin: pi
    version: 1.4.0
    npm_package: '@earendil-works/pi-coding-agent'
    install: 'npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@$CEL_INSTALL_VERSION"'
    update: { command: 'pi update --self' }
    required: false
base_tools:
  node: { version: lts }
YAML
  # the shims come first, as `eval "$(cel shellenv)"` orders them
  export PATH="$MISE/shims:$T/bin:/usr/bin:/bin"
  source "$CEL_ROOT/lib/common.sh"
  source "$CEL_ROOT/lib/manifest.sh"
  source "$CEL_ROOT/lib/install.sh"
  NG_REPO="$CEL_ROOT"; CEL_ROOT="$T/cel"; mkdir -p "$CEL_ROOT"
}

_ng_working_pi() { # <version>: the active node already holds pi
  mkdir -p "$NG_ACTIVE/lib/node_modules/@earendil-works/pi-coding-agent"
  printf '#!/usr/bin/env bash\n[ "$1" != --version ] || echo %s\n' "$1" > "$NG_ACTIVE/bin/pi"
  chmod +x "$NG_ACTIVE/bin/pi"
}

test_a_dead_mise_shim_is_not_a_working_tool() {
  _ng_setup
  have pi || { echo "the shim is not on PATH"; return 1; }
  shim_dead pi || { echo "a shim with no version behind it was called working"; return 1; }
  assert_eq "$SHIM_ERR" "No version is set for shim: pi" || return 1
  _ng_working_pi 1.5.0
  if shim_dead pi; then echo "a working shim was called dead: $SHIM_ERR"; return 1; fi
  # an absent tool, and one that is not a shim, are not dead shims
  if shim_dead no-such-tool; then echo "an absent tool was called a dead shim"; return 1; fi
  if shim_dead npm; then echo "a plain executable was called a dead shim"; return 1; fi
  rm -rf "$T"
}

test_stranded_release_is_read_from_real_node_directories() {
  _ng_setup
  assert_eq "$(npm_stranded @earendil-works/pi-coding-agent)" "1.5.0	24.20.0" || return 1
  assert_eq "$(npm_bin_owner gt)" "@withgraphite/graphite-cli	1.8.6	24.20.0" || return 1
  assert_eq "$(npm_stranded no-such-package)" "" || return 1
  rm -rf "$T"
}

# The release the old node still holds, when newer than the pin.
test_setup_reinstalls_a_dead_shim_agent_at_the_stranded_release() {
  _ng_setup
  install_agents >/dev/null 2>&1 || { cat "$LOG"; echo "install_agents failed"; return 1; }
  assert_contains "$(cat "$LOG")" 'npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.5.0' || return 1
  assert_contains "$(cat "$LOG")" 'mise reshim' || return 1
  assert_eq "$(pi --version)" 1.5.0 || return 1
  rm -rf "$T"
}

test_setup_reinstalls_a_dead_shim_agent_at_the_pin_when_nothing_newer_is_stranded() {
  _ng_setup
  rm -rf "$MISE/installs/node/24.20.0/lib/node_modules/@earendil-works"
  install_agents >/dev/null 2>&1 || { cat "$LOG"; return 1; }
  assert_contains "$(cat "$LOG")" '@earendil-works/pi-coding-agent@1.4.0' || return 1
  rm -rf "$T"
}

test_setup_retains_a_working_agent_whatever_its_release() {
  _ng_setup
  _ng_working_pi 1.6.2
  local out; out="$(install_agents 2>&1)" || { echo "$out"; return 1; }
  if grep -q '^npm install' "$LOG"; then echo "a working agent was reinstalled"; cat "$LOG"; return 1; fi
  assert_contains "$out" "retained" || return 1
  rm -rf "$T"
}

test_setup_fails_loudly_when_the_reinstall_fails() {
  _ng_setup
  : > "$T/npm.fail"
  local out
  if out="$(install_agents 2>&1)"; then echo "a failed reinstall reported success"; return 1; fi
  assert_contains "$out" "cel setup --agents pi" || return 1
  rm -rf "$T"
}

# cel update: the agent is put back under the active node BEFORE its own
# updater runs, so the updater is not run through a dead shim.
test_update_repairs_a_dead_shim_before_running_the_agent_updater() {
  _ng_setup
  export CEL_CONFIG_FILE="$T/config.yaml" CEL_UPDATE_DIR="$T/update"
  source "$NG_REPO/lib/update.sh"
  gateway_refresh() { :; }
  local out rc=0 ni pu
  out="$(_update_components 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { echo "$out"; cat "$LOG"; return 1; }
  ni="$(grep -n '^npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.5.0$' "$LOG" | cut -d: -f1)"
  pu="$(grep -n '^pi update --self$' "$LOG" | cut -d: -f1)"
  [ -n "$ni" ] && [ -n "$pu" ] && [ "$ni" -lt "$pu" ] || { echo "no reinstall before the updater"; cat "$LOG"; return 1; }
  assert_contains "$out" "pi 1.5.0" || { echo "$out"; return 1; }
  rm -rf "$T"
}

test_update_never_runs_an_updater_through_a_dead_shim() {
  _ng_setup
  export CEL_CONFIG_FILE="$T/config.yaml" CEL_UPDATE_DIR="$T/update"
  source "$NG_REPO/lib/update.sh"
  : > "$T/npm.fail"
  local out rc=0
  out="$(_update_agents 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "a dead agent was reported current: $out"; return 1; }
  assert_contains "$out" "No version is set for shim: pi" || return 1
  assert_contains "$out" "cel setup --agents pi" || return 1
  if grep -q '^pi update' "$LOG"; then echo "the updater ran through a dead shim"; return 1; fi
  rm -rf "$T"
}

# An agent this box never installed is cel setup's to install, not update's.
test_update_leaves_a_never_installed_agent_to_setup() {
  _ng_setup
  export CEL_CONFIG_FILE="$T/config.yaml" CEL_UPDATE_DIR="$T/update"
  source "$NG_REPO/lib/update.sh"
  rm -f "$MISE/shims/pi"
  rm -rf "$MISE/installs/node/24.20.0/lib/node_modules/@earendil-works"
  local out; out="$(_update_agents 2>&1)" || true
  assert_contains "$out" "pi not installed - cel setup installs it" || { echo "$out"; return 1; }
  if grep -q '^npm install' "$LOG"; then echo "update installed an agent the box never had"; return 1; fi
  rm -rf "$T"
}

# Doctor: an agent whose shim is dead is an error naming it, the shim's own
# error, the release its old node holds and the fix; a working one shows its
# version; one whose --version fails is an error too.
test_doctor_names_a_dead_agent_shim_and_its_fix() {
  _ng_setup
  source "$NG_REPO/lib/doctor.sh"
  local out rc=0
  out="$(doctor_agent_bin_line pi 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "a dead agent shim left doctor green: $out"; return 1; }
  assert_contains "$out" "pi: pi is a dead mise shim (No version is set for shim: pi, checked in the global mise context from $HOME)" || return 1
  assert_contains "$out" "@earendil-works/pi-coding-agent 1.5.0 is installed under node 24.20.0 only" || return 1
  assert_contains "$out" "Fix: cel setup --agents pi (reinstalls @earendil-works/pi-coding-agent@1.5.0 under the active node)" || return 1
  _ng_working_pi 1.5.0
  rc=0; out="$(doctor_agent_bin_line pi 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { echo "$out"; return 1; }
  assert_contains "$out" "pi (1.5.0)" || return 1
  printf '#!/bin/sh\necho "broken install" >&2; exit 3\n' > "$NG_ACTIVE/bin/pi"
  rc=0; out="$(doctor_agent_bin_line pi 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "a failing --version left doctor green: $out"; return 1; }
  assert_contains "$out" "--version exits non-zero (broken install)" || return 1
  assert_contains "$out" "cel setup --agents pi" || return 1
  rm -rf "$T"
}

# Another tool's dead shims (graphite's gt and graphite here) are one warning
# naming the exact install that puts them back; agent bins are not repeated.
test_doctor_warns_on_another_tools_dead_shims_with_the_exact_install() {
  _ng_setup
  source "$NG_REPO/lib/doctor.sh"
  local out rc=0
  out="$(doctor_shim_lines 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { echo "another tool's shim failed doctor: $out"; return 1; }
  assert_contains "$out" "graphite, gt: dead mise shim (No version is set for shim: graphite)" || { echo "$out"; return 1; }
  assert_contains "$out" "@withgraphite/graphite-cli 1.8.6 is installed under node 24.20.0 only. Fix: npm install -g @withgraphite/graphite-cli@1.8.6" || return 1
  case "$out" in *"shim: pi"*) echo "an agent bin was reported twice: $out"; return 1 ;; esac
  rm -rf "$T"
}

# An npm tool the plane installs (externals.yaml npm_tools) is a failure,
# fixed by cel setup.
test_doctor_fails_on_a_plane_npm_tools_dead_shim() {
  _ng_setup
  source "$NG_REPO/lib/doctor.sh"
  local old="$MISE/installs/node/24.20.0" integrity
  mkdir -p "$old/lib/node_modules/rea-agents/dist"
  printf '{"name":"rea-agents","version":"6.10.1"}\n' > "$old/lib/node_modules/rea-agents/package.json"
  ln -s ../lib/node_modules/rea-agents/dist/cli.js "$old/bin/rea"
  ln -s "$T/mise/mise" "$MISE/shims/rea"
  integrity="sha512-$(printf 'A%.0s' $(seq 86))=="
  cat > "$CEL_ROOT/externals.yaml" <<YAML
npm_tools:
  rea:
    package: rea-agents
    version: 6.10.1
    integrity: $integrity
    license: MIT
    source: morluto/rea
    bin: rea
    register: { clients: [omp], tool_catalog_profile: hot-cold }
YAML
  local out rc=0
  out="$(doctor_shim_lines 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "a dead plane npm tool left doctor green: $out"; return 1; }
  assert_contains "$out" "rea: dead mise shim (No version is set for shim: rea) - rea-agents 6.10.1 is installed under node 24.20.0 only. Fix: cel setup" || { echo "$out"; return 1; }
  rm -rf "$T"
}

test_doctor_runs_the_agent_and_shim_checks() {
  source "$CEL_ROOT/lib/doctor.sh"
  assert_contains "$(declare -f cmd_doctor)" doctor_agent_bin_line || return 1
  assert_contains "$(declare -f cmd_doctor)" doctor_shim_lines
}

# A HUNG MISE IS "CANNOT TELL", NEVER "DEAD". Each shim check is bounded
# (CEL_SHIM_CHECK_SECS, 5 by default, 1 here) and a timeout answers 2; once
# `mise which` has timed out in a directory, later checks from there in the
# same command answer at once - also across the $(...) subshells callers
# use - while another directory is still asked.
test_a_hung_mise_is_cannot_tell_within_the_bound() {
  _ng_setup
  : > "$T/hang"
  export CEL_SHIM_CHECK_SECS=1
  # as doctor, setup and update do before their first $(...)
  shim_record_open || { echo "no record opened"; return 1; }
  local rc out started took
  # the first timeout happens inside $(...), as doctor's callers make it
  started="$SECONDS"
  out="$(shim_dead pi; printf '%s|%s' "$?" "$SHIM_ERR")"
  took=$((SECONDS - started))
  assert_eq "$out" "2|mise did not answer within 1s" || return 1
  [ "$took" -le 4 ] || { echo "the check took ${took}s"; return 1; }
  started="$SECONDS"
  rc="$(shim_dead gt; printf '%s' "$?")"
  assert_eq "$rc" 2 || return 1
  rc=0; shim_dead graphite || rc=$?
  assert_eq "$rc" 2 || return 1
  [ $((SECONDS - started)) -le 1 ] || { echo "a later check waited again after a timeout recorded in a subshell"; return 1; }
  rm -rf "$T"
}

test_a_mise_hang_in_one_directory_does_not_stop_checks_in_another() {
  _ng_setup
  export CEL_SHIM_CHECK_SECS=1
  mkdir -p "$T/stuck"
  (cd "$T/stuck" && pwd -P) > "$T/hang-in"
  local rc=0
  shim_dead pi "$T/stuck" || rc=$?
  assert_eq "$rc" 2 || return 1
  rc=0; shim_dead pi "$HOME" || rc=$?
  assert_eq "$rc" 0 || { echo "a hang in another directory decided this one ($rc: $SHIM_ERR)"; return 1; }
  assert_eq "$SHIM_ERR" "No version is set for shim: pi" || return 1
  rm -rf "$T"
}

# A shim that hangs when run is that one shim's "cannot tell": mise answered,
# so the next shim is still checked.
test_a_hung_shim_version_is_that_shims_cannot_tell_only() {
  _ng_setup
  export CEL_SHIM_CHECK_SECS=1
  : > "$T/hang-version-gt"
  local rc=0 started="$SECONDS"
  shim_dead gt || rc=$?
  assert_eq "$rc" 2 || return 1
  assert_eq "$SHIM_ERR" "the gt shim did not answer within 1s" || return 1
  rc=0; shim_dead pi || rc=$?
  assert_eq "$rc" 0 || { echo "a hung gt stopped the pi check ($rc: $SHIM_ERR)"; return 1; }
  rm -rf "$T"
}

# 137 is also a plain SIGKILL (out of memory), so it is never called "timed
# out" alone.
test_a_killed_check_is_reported_as_killed() {
  _ng_setup
  assert_eq "$(_shim_bound_reason mise 137 5)" "mise was killed (timed out after 5s, or out of memory)" || return 1
  assert_eq "$(_shim_bound_reason mise 124 5)" "mise did not answer within 5s" || return 1
  rm -rf "$T"
}

test_a_hung_mise_never_triggers_a_reinstall() {
  _ng_setup
  : > "$T/hang"
  export CEL_SHIM_CHECK_SECS=1
  local out rc=0
  out="$(install_agents 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { echo "$out"; return 1; }
  assert_contains "$out" "pi: could not tell whether pi runs (mise did not answer within 1s) - retained" || return 1
  if grep -q '^npm install' "$LOG"; then echo "a hung mise triggered a reinstall"; return 1; fi
  rm -rf "$T"
}

# cel update neither reinstalls nor runs the updater (which would only go
# through the hung mise), and the agent not updated fails the update.
test_a_hung_mise_skips_the_agent_and_fails_the_update() {
  _ng_setup
  export CEL_CONFIG_FILE="$T/config.yaml" CEL_UPDATE_DIR="$T/update" CEL_SHIM_CHECK_SECS=1
  source "$NG_REPO/lib/update.sh"
  : > "$T/hang"
  local out rc=0 started="$SECONDS"
  out="$(_update_agents 2>&1)" || rc=$?
  [ $((SECONDS - started)) -le 6 ] || { echo "update waited $((SECONDS - started))s on a hung mise"; return 1; }
  [ "$rc" != 0 ] || { echo "an agent not updated left the update green: $out"; return 1; }
  assert_contains "$out" "pi NOT updated: mise did not settle whether pi runs" || { echo "$out"; return 1; }
  if grep -q '^npm install\|^pi update' "$LOG"; then echo "update acted on a hung mise"; cat "$LOG"; return 1; fi
  rm -rf "$T"
}

test_a_hung_mise_never_refuses_a_launch() {
  _ng_setup
  source "$NG_REPO/lib/run.sh"
  : > "$T/hang"
  export CEL_SHIM_CHECK_SECS=1
  local err rc=0
  err="$( (_run_runtime_runnable pi "$T") 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" 0 || { echo "a hung mise refused the launch: $err"; return 1; }
  assert_contains "$err" "could not tell whether pi runs (mise did not answer within 1s) - launching anyway" || return 1
  rm -rf "$T"
}

test_a_hung_mise_is_a_doctor_warning_not_a_failure() {
  _ng_setup
  source "$NG_REPO/lib/doctor.sh"
  : > "$T/hang"
  export CEL_SHIM_CHECK_SECS=1
  shim_record_open || { echo "no record opened"; return 1; }
  local out rc=0
  out="$(doctor_agent_bin_line pi 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { echo "$out"; return 1; }
  assert_contains "$out" "pi: could not tell whether pi runs (mise did not answer within 1s)" || return 1
  rc=0; out="$(doctor_shim_lines 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { echo "$out"; return 1; }
  assert_contains "$out" "2 of 2 mise shims not checked (mise did not answer within 1s): graphite gt" || return 1
  rm -rf "$T"
}

# One shim hanging leaves doctor checking the rest, and it says how many
# went unchecked.
test_doctor_keeps_checking_after_one_shim_hangs() {
  _ng_setup
  source "$NG_REPO/lib/doctor.sh"
  export CEL_SHIM_CHECK_SECS=1
  : > "$T/hang-version-gt"
  local out rc=0
  out="$(doctor_shim_lines 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { echo "$out"; return 1; }
  assert_contains "$out" "graphite: dead mise shim (No version is set for shim: graphite)" || { echo "$out"; return 1; }
  assert_contains "$out" "1 of 2 mise shims not checked (the gt shim did not answer within 1s): gt" || { echo "$out"; return 1; }
  rm -rf "$T"
}

# WHICH DIRECTORY IS ASKED. Setup, update and doctor ask in the global mise
# context ($HOME) whatever directory they run from - here a project whose
# .mise.toml pins another node - so a working pi is neither reported dead
# nor reinstalled. cel run asks from the launch's own directory and refuses
# there, naming that directory and its node, the install that works there,
# and that cel setup repairs only the global node.
test_setup_and_doctor_ask_the_global_context_and_cel_run_the_launch_dir() {
  _ng_setup
  source "$NG_REPO/lib/doctor.sh"
  source "$NG_REPO/lib/run.sh"
  _ng_working_pi 1.5.0
  mkdir -p "$T/proj"
  printf '[tools]\nnode = "20.19.4"\n' > "$T/proj/.mise.toml"
  local out rc=0 proj
  proj="$(cd "$T/proj" && pwd -P)"
  out="$(cd "$T/proj" && doctor_agent_bin_line pi 2>&1)" || rc=$?
  assert_eq "$rc" 0 || { echo "doctor judged pi by the caller's project: $out"; return 1; }
  out="$(cd "$T/proj" && install_agents 2>&1)" || { echo "$out"; return 1; }
  assert_contains "$out" "retained" || return 1
  if grep -q '^npm install' "$LOG"; then echo "setup reinstalled pi because of the caller's project"; return 1; fi
  rc=0; out="$(cd "$T" && (_run_runtime_runnable pi "$T/proj") 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "a launch into the project was not refused"; return 1; }
  assert_contains "$out" "pi cannot start in $proj" || { echo "$out"; return 1; }
  assert_contains "$out" "selects node 20.19.4, which lacks it" || return 1
  assert_contains "$out" "cel setup / cel update repair only the global node, so they would change nothing here" || return 1
  assert_contains "$out" "Fix: cd $proj && npm install -g --ignore-scripts \"@earendil-works/pi-coding-agent@1.5.0\"" || return 1
  case "$out" in *"Fix: cel setup"*) echo "the refusal offered cel setup for a project node: $out"; return 1 ;; esac
  rm -rf "$T"
}

# Dead in the global context too: cel setup is the fix, as before.
test_cel_run_refusal_names_cel_setup_when_the_global_node_is_dead_too() {
  _ng_setup
  source "$NG_REPO/lib/run.sh"
  local out rc=0
  out="$( (_run_runtime_runnable pi "$T") 2>&1)" || rc=$?
  [ "$rc" != 0 ] || return 1
  assert_contains "$out" "Fix: cel setup --agents pi (or cel update)" || { echo "$out"; return 1; }
  rm -rf "$T"
}

# THE HANG RECORD IS PRIVATE: a mktemp -d directory (0700) under the user's
# own XDG_RUNTIME_DIR, else under TMPDIR, opened by the command's top-level
# shell and shared by its $(...) subshells.
test_the_hang_record_is_a_private_directory_of_this_command() {
  _ng_setup
  shim_record_open || { echo "no record opened"; return 1; }
  case "$_SHIM_HUNG_DIR" in "$XDG_RUNTIME_DIR"/cel-shim.$$.*) ;; *) echo "record at $_SHIM_HUNG_DIR"; return 1 ;; esac
  assert_eq "$(stat -c '%a %U' "$_SHIM_HUNG_DIR")" "700 $(id -un)" || return 1
  # a subshell opens none of its own: it uses the command's
  assert_eq "$(_SHIM_HUNG_DIR=''; shim_record_open; printf '%s|%s' "$?" "$_SHIM_HUNG_DIR")" "1|" || return 1
  rm -rf "$T"
}

test_the_hang_record_falls_back_to_tmpdir_without_an_own_runtime_dir() {
  _ng_setup
  local d
  for d in / "$T/runlink"; do
    [ "$d" = / ] || ln -s "$T/run" "$d"
    [ "$d" != / ] || [ ! -O / ] || continue   # root owns / - not a foreign dir then
    shim_record_close; export XDG_RUNTIME_DIR="$d"
    shim_record_open || { echo "no record opened with XDG_RUNTIME_DIR=$d"; return 1; }
    case "$_SHIM_HUNG_DIR" in "${TMPDIR:-/tmp}"/cel-shim.*) ;; *) echo "XDG_RUNTIME_DIR=$d: record at $_SHIM_HUNG_DIR"; return 1 ;; esac
    assert_eq "$(stat -c '%a' "$_SHIM_HUNG_DIR")" 700 || return 1
  done
  shim_record_close
  rm -rf "$T"
}

# A fixed-name file in TMPDIR - the old record's name, here a symlink to a
# forged "hung" line - is neither trusted nor written through.
test_a_planted_fixed_name_record_is_never_trusted_or_written_through() {
  _ng_setup
  export CEL_SHIM_CHECK_SECS=1
  local key forged
  key="$(pwd -P)"
  printf '%s\tforged hang\n' "$key" > "$T/forged"
  forged="$(cat "$T/forged")"
  ln -s "$T/forged" "${TMPDIR:-/tmp}/cel-shim-hung.$$.$(_shim_pid_start $$)"
  local rc=0
  shim_dead pi || rc=$?
  assert_eq "$rc" 0 || { echo "a planted record decided the check ($rc: $SHIM_ERR)"; return 1; }
  : > "$T/hang"
  rc=0; shim_dead pi || rc=$?
  assert_eq "$rc" 2 || return 1
  assert_eq "$(cat "$T/forged")" "$forged" || { echo "the planted symlink was written through"; return 1; }
  [ -L "${TMPDIR:-/tmp}/cel-shim-hung.$$.$(_shim_pid_start $$)" ] || { echo "a symlink was removed through"; return 1; }
  rm -f "${TMPDIR:-/tmp}/cel-shim-hung.$$.$(_shim_pid_start $$)"
  rm -rf "$T"
}

# A record directory that is no longer this user's private directory - here
# swapped for a symlink to a forged record - is cannot-tell: mise is not
# asked, nothing is read from it and nothing is written through it.
test_a_swapped_record_directory_is_cannot_tell_and_never_written() {
  _ng_setup
  export CEL_SHIM_CHECK_SECS=1
  shim_record_open || return 1
  mkdir "$T/evil"; printf '%s\tforged hang\n' "$(pwd -P)" > "$T/evil/hung"
  rm -rf -- "$_SHIM_HUNG_DIR"; ln -s "$T/evil" "$_SHIM_HUNG_DIR"
  : > "$LOG"
  local rc=0
  shim_dead pi || rc=$?
  assert_eq "$rc" 2 || return 1
  assert_contains "$SHIM_ERR" "is not a private directory of this user" || return 1
  if grep -q '^mise which' "$LOG"; then echo "mise was asked through an untrusted record"; return 1; fi
  : > "$T/hang"; rc=0; shim_dead gt || rc=$?
  assert_eq "$rc" 2 || return 1
  assert_eq "$(wc -l < "$T/evil/hung")" 1 || { echo "the swapped record was written through"; return 1; }
  rm -f "$_SHIM_HUNG_DIR"; _SHIM_HUNG_DIR=""
  rm -rf "$T"
}

test_a_symlinked_record_file_is_cannot_tell_and_never_written() {
  _ng_setup
  export CEL_SHIM_CHECK_SECS=1
  shim_record_open || return 1
  printf 'elsewhere\tforged\n' > "$T/target"
  ln -s "$T/target" "$_SHIM_HUNG_DIR/hung"
  local rc=0
  : > "$T/hang"; shim_dead pi || rc=$?
  assert_eq "$rc" 2 || return 1
  assert_contains "$SHIM_ERR" "is not a private directory of this user" || return 1
  assert_eq "$(cat "$T/target")" "elsewhere	forged" || { echo "the symlinked record was written through"; return 1; }
  rm -rf "$T"
}

test_a_foreign_record_directory_is_cannot_tell() {
  _ng_setup
  [ ! -O / ] || { rm -rf "$T"; return 0; }   # as root nothing here is foreign
  local rc=0
  _SHIM_HUNG_DIR=/
  shim_dead pi || rc=$?
  _SHIM_HUNG_DIR=""
  assert_eq "$rc" 2 || return 1
  assert_contains "$SHIM_ERR" "/ is not a private directory of this user" || return 1
  rm -rf "$T"
}

# Removed when the shell that opened it exits, and that shell's own EXIT
# trap still runs; what a shell that died left behind goes at the next open,
# while a live command's record stays.
test_the_hang_record_is_removed_at_exit_and_stale_ones_at_the_next_open() {
  _ng_setup
  local out d live dead
  out="$(bash -c 'source "$1/lib/common.sh"; trap "echo old-trap" EXIT; shim_record_open || exit 9; echo "$_SHIM_HUNG_DIR"' _ "$NG_REPO")" || { echo "$out"; return 1; }
  d="$(sed -n 1p <<< "$out")"
  assert_eq "$(sed -n 2p <<< "$out")" old-trap || { echo "the shell's own EXIT trap was lost: $out"; return 1; }
  case "$d" in "$XDG_RUNTIME_DIR"/cel-shim.*) ;; *) echo "record at $d"; return 1 ;; esac
  [ ! -e "$d" ] || { echo "the record outlived its shell"; return 1; }
  dead="$XDG_RUNTIME_DIR/cel-shim.4194305.1.abcdef"; mkdir -m 700 "$dead"
  : > "${TMPDIR:-/tmp}/cel-shim-hung.4194305.1"
  live="$XDG_RUNTIME_DIR/cel-shim.$PPID.$(_shim_pid_start "$PPID").abcdef"; mkdir -m 700 "$live"
  shim_record_open || return 1
  [ ! -e "$dead" ] || { echo "a dead command's record was kept"; return 1; }
  [ ! -e "${TMPDIR:-/tmp}/cel-shim-hung.4194305.1" ] || { echo "an old fixed-name record was kept"; return 1; }
  [ -d "$live" ] || { echo "a live command's record was removed"; return 1; }
  shim_record_close
  rm -rf "$T"
}
