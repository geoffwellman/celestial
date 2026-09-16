# shellcheck shell=bash
# Output helpers and small predicates. Sourced by every other lib and by bin/cel.
[ -n "${_CEL_COMMON:-}" ] && return 0
_CEL_COMMON=1

# Honour an inherited CEL_ROOT (the test runner exports one); otherwise resolve
# from this file's location, following symlinks so `cel` works via ~/.local/bin.
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CEL_ROOT

c_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
c_warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
c_hd()   { printf '\n\033[1m%s\033[0m\n' "$*"; }

have()   { command -v "$1" >/dev/null 2>&1; }
die()    { c_err "$*"; exit 1; }

# Expand a leading ~ only. Deliberately NOT `eval echo`: manifest paths are data
# edited by humans, and eval would make them a command-injection surface and
# mangle any path containing spaces or glob characters.
expand() {
  local p="$1"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  printf '%s' "$p"
}

# yq must be the PYTHON build (kislyuk, jq syntax). The Go build (mikefarah)
# parses the same file differently and returns different results silently.
# Capture, do not pipe: under `set -o pipefail` a `grep -q` short-circuit
# SIGPIPEs yq and the non-zero exit made every build look like the wrong one.
yq_ok() {
  local v
  have yq || return 1
  v="$(yq --version 2>&1)" || return 1
  case "$v" in *[Mm]ikefarah*) return 1;; esac
  return 0
}

# Resolve the locally known origin default; never guess past a broken
# authoritative origin/HEAD. Reuse main/master only when that symbolic ref
# is absent, and require a real commit before returning any answer.
repo_default_ref() { # <repository-dir> -> verified origin ref, or failure
  local ref rc
  if ref="$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    case "$ref" in origin/*) ;; *) return 1;; esac
    git -C "$1" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || return 1
    printf '%s' "$ref"
    return 0
  else
    rc=$?
    [ "$rc" -eq 1 ] || return 1
  fi
  # A direct ref called origin/HEAD is malformed, not an absent symbolic ref.
  if git -C "$1" show-ref --verify --quiet refs/remotes/origin/HEAD; then
    return 1
  else
    rc=$?
    [ "$rc" -eq 1 ] || return 1
  fi
  for ref in origin/main origin/master; do
    if git -C "$1" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s' "$ref"
      return 0
    fi
  done
  return 1
}
