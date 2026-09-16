# shellcheck shell=bash
# cel console - the plane's own interface.
#
# This file is the thin bash edge of a node program: it resolves the config,
# exports what the process needs and execs it. The console itself is
# tools/console/console.mjs.
#
# It is the ONE cel command that is not a script the agents also run, because
# it is the one thing an operator looks at rather than calls. `cel run console
# --agent` still starts the old Claude pane for people who want to talk to a
# full agent; this is the default and the thing the README leads with.
[ -n "${_CEL_CONSOLE:-}" ] && return 0
_CEL_CONSOLE=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

console_tool_dir() { printf '%s' "${CEL_CONSOLE_TOOL_DIR:-$CEL_ROOT/tools/console}"; }

# The console is the first thing on this plane with node_modules, because the
# TUI is ink. Presence is decided by the ONE package that actually gets
# imported: a node_modules directory that exists but is half-installed (an
# interrupted npm, a partial copy) must read as missing, not as fine.
console_deps_ok() { # [tool-dir]
  local d="${1:-$(console_tool_dir)}"
  [ -f "$d/node_modules/ink/package.json" ]
}

# One line, naming the fix. An operator who typed `cel console` has no reason
# to know it is a React app, and ERR_MODULE_NOT_FOUND is not an instruction.
console_deps_hint() { # [tool-dir]
  local d="${1:-$(console_tool_dir)}"
  printf 'cel console needs its UI dependencies: (cd %s && npm ci --ignore-scripts) - or run cel setup' "$d"
}

console_install_deps() { # [tool-dir]
  local d="${1:-$(console_tool_dir)}"
  [ -f "$d/package.json" ] || return 0
  have npm || { c_warn "npm is not on PATH - cel console's UI deps were not installed"; return 0; }
  # --ignore-scripts, the same posture as every other third-party install on
  # this box: a lock file pins WHAT is fetched, and lifecycle scripts are the
  # part of an npm install that a pin does not constrain.
  ( cd "$d" && npm ci --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 ) \
    || { c_warn "cel console UI deps failed to install - run: (cd $d && npm ci --ignore-scripts)"; return 0; }
  c_ok "console UI deps (ink)"
}

cmd_console() { # [--refresh SECS] [--render-once] [--run "<cmd>"] [--translate "<text>"]
  have node || die "cel console: node is not on PATH"
  local dir; dir="$(console_tool_dir)"

  # The non-interactive modes are deliberately allowed WITHOUT the ink install:
  # --render-once and --translate are what the tests drive and what a pipe
  # wants, and neither draws anything.
  local interactive=1 a
  for a in "$@"; do
    case "$a" in --render-once|--translate|--run) interactive=0 ;; esac
  done
  if [ "$interactive" -eq 1 ] && ! console_deps_ok "$dir"; then
    c_err "$(console_deps_hint "$dir")"
    exit 1
  fi

  # CEL_ROLE is what lib/guard.sh and lib/inbox.sh read to know who is asking:
  # the console's cwd is wherever the operator happened to be standing, so the
  # path cannot answer it (lib/guard.sh guard_role_of says so outright).
  export CEL_ROLE=console
  export CEL_ROOT
  export CEL_BIN="${CEL_BIN:-$CEL_ROOT/bin/cel}"
  # The program is always the plane's own; CEL_CONSOLE_TOOL_DIR moves only
  # where the dependencies are looked for, which is what the tests vary.
  exec node "$CEL_ROOT/tools/console/console.mjs" "$@"
}
