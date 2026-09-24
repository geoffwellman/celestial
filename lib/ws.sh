# shellcheck shell=bash
# cel ws list|new|add|sync|push|up|down|reset|status - the workspace commands. Dispatch
# wiring lives in bin/cel (Task 8); this file is command logic only.
[ -n "${_CEL_WS:-}" ] && return 0
_CEL_WS=1
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/wslife.sh
. "$(dirname "${BASH_SOURCE[0]}")/wslife.sh"

# The three lines every workspace root ignores: cloned repos, disposable
# spikes, and the fanout ledger - none of them belong in the workspace's own
# git history.
_WS_GITIGNORE_LINES="repos/
spikes/
.cel/
env.local"

# One question per unknown; Enter accepts the visible default. Reads stdin so
# tests can feed answers; an empty read (EOF) also takes the default.
_ask() { # <question> <default>
  local a=""
  if [ -t 0 ]; then read -r -p "  $1${2:+ [$2]}: " a || true
  else read -r a || true; fi
  printf '%s' "${a:-$2}"
}

# A REFUSAL THAT NOBODY EVER SAW. `registry_require` ends in `die`, and every
# caller wrote `wsdir="$(registry_require "$n")"` - so the process that died
# was the command substitution's subshell, its message went into the captured
# stdout that the caller then threw away, and the caller carried on with an
# empty path and exited 1 with an empty terminal. The owner's teammate met
# that on their FIRST command on 2026-09-21: `cel ws sync <name>` for a
# workspace nobody had registered, exit 1, no stdout, no stderr. Being
# onboarded is exactly the moment you cannot tell "I did it wrong" from "it is
# broken", and there is nobody to ask.
#
# So the check happens in the CALLER's process, never inside `$( )`, and the
# message rides stderr - the refusal is not the command's output, and a
# caller redirecting stdout must still see why it stopped.
_ws_die() { c_err "$*" >&2; exit 1; }

# Resolves a workspace name into $_WS_DIR, or refuses out loud. Call it as a
# statement - `_ws_require "$n"; d="$_WS_DIR"` - never as `$(_ws_require ...)`,
# which is the bug this exists to end.
_ws_require() { # <name>
  local p; p="$(registry_path "$1" 2>/dev/null || true)"
  [ -n "$p" ] || _ws_die "workspace '$1' is not registered - register it with: cel ws add <git-url> ('cel ws list' shows the ones that are)"
  [ -d "$p" ] || _ws_die "workspace '$1' is registered at $p but nothing is there - re-register it with: cel ws add <git-url>, or restore that path"
  _WS_DIR="$p"
}

# The name a verb was given, ignoring its flags. Only used for the verbs whose
# flags take no values (--dry-run, --force, --json), so the first bare word is
# the workspace.
_ws_name_arg() {
  local a
  for a in "$@"; do
    case "$a" in -*) ;; *) printf '%s' "$a"; return 0 ;; esac
  done
  return 0
}

cmd_ws() {
  local sub="${1:-list}"; shift || true
  # One gate for every verb that takes a workspace name, in this process, before
  # dispatch - including the lifecycle verbs, whose own `registry_require` calls
  # sit inside `$( )` in lib/wslife.sh. A name that cannot be resolved is
  # refused here, by name, with the command that would fix it. One silent verb
  # is enough to lose the next newcomer.
  case "$sub" in
    sync|push|env|up|down|reset|status)
      local _n; _n="$(_ws_name_arg "$@")"
      [ -z "$_n" ] || _ws_require "$_n"
      ;;
  esac
  case "$sub" in
    list) _ws_list;;
    new) _ws_new "$@";;
    add) _ws_add "$@";;
    sync) _ws_sync "$@";;
    push) _ws_push "$@";;
    env) _ws_env "$@";;
    # CEL-44: the lifecycle verbs. `up` reconciles a workspace to its declared
    # shape and is safe to run twice; `down` and `reset` stop things, and
    # refuse over work that is neither pushed nor landed.
    up) cmd_ws_up "$@";;
    down) cmd_ws_down "$@";;
    reset) cmd_ws_reset "$@";;
    status) cmd_ws_status "$@";;
    *) die "unknown: cel ws $sub (list|new|add|sync|push|env|up|down|reset|status)";;
  esac
}

# ------------------------------------------------------------------- list
_ws_list() {
  printf '  %-14s %-10s %-34s %-40s %s\n' NAME KIND PATH REMOTE REPOS
  local n path remote repos
  for n in $(registry_names); do
    path="$(registry_path "$n")"
    remote="$(registry_remote "$n")"
    [ -n "$remote" ] || remote="local-only"
    repos="$(ws_repo_names "$path" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    printf '  %-14s %-10s %-34s %-40s %s\n' \
      "$n" "$(ws_kind "$path" 2>/dev/null)" "$path" "$remote" "${repos:--}"
  done
}

# -------------------------------------------------------------------- new
_ws_new() {
  local name="" kind="" org="" merge="" path="" remote_flag="" ans
  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="$2"; shift 2;;
      --org) org="$2"; shift 2;;
      --merge) merge="$2"; shift 2;;
      --path) path="$2"; shift 2;;
      --remote) remote_flag="yes"; shift;;
      --no-remote) remote_flag="no"; shift;;
      *) positional+=("$1"); shift;;
    esac
  done
  name="${positional[0]:-}"

  # Interview: exactly the five unknowns, in this fixed order. Flags that
  # already answer a question skip it.
  [ -n "$name" ] || name="$(_ask "workspace name" "")"
  [ -n "$name" ] || die "cel ws new: a workspace name is required"
  [ -n "$kind" ] || kind="$(_ask "kind" "personal")"
  [ -n "$org" ] || org="$(_ask "org" "")"
  [ -n "$merge" ] || merge="$(_ask "merge policy" "humans-only")"
  if [ -z "$remote_flag" ]; then
    ans="$(_ask "create a GitHub remote now?" "n")"
    case "$ans" in y|Y|yes|Yes) remote_flag="yes";; *) remote_flag="no";; esac
  fi

  local wsdir="${path:-$(expand "$HOME/ws/$name")}"
  [ -e "$wsdir" ] && die "workspace path already exists: $wsdir"

  mkdir -p "$wsdir/repos" "$wsdir/spikes" "$wsdir/skills" "$wsdir/docs"
  : > "$wsdir/skills/.gitkeep"

  cat > "$wsdir/workspace.yaml" <<YAML
name: $name
kind: $kind
org: $org
tickets: { system: none, adhoc: "AH-<yymmdd>" }
policy: { merge: $merge, pr: required, workers: 4, reviewer: null }
runtime: { root: claude, orchestrator: claude, worker: omp }
tools: []
env: {}                       # exported into every shell that starts in this workspace. SECRETS GO IN env.local (gitignored, never committed) - that is the one place this workspace's keys live, and the only one cel doctor and cel ws env read
repos: []
YAML

  printf '%s\n' "$_WS_GITIGNORE_LINES" > "$wsdir/.gitignore"

  cat > "$wsdir/docs/conventions.md" <<DOC
# Conventions

Branches follow the \`<PREFIX>-<n>-slug\` scheme: a short ticket prefix, an
incrementing number, and a brief slug. Merge policy for this workspace is
\`$merge\` - see \`workspace.yaml\` for the authoritative policy block.
DOC

  git -C "$wsdir" init -q
  git -C "$wsdir" add -A
  git -C "$wsdir" -c user.name="cel" -c user.email="cel@localhost" \
    commit -q -m "feat: workspace $name scaffolded by cel ws new"

  registry_add "$name" "$wsdir" ""

  if [ "$remote_flag" = "yes" ]; then
    cmd_ws push "$name"
  fi
}

# -------------------------------------------------------------------- add
_ws_add() {
  local url="$1" name="${2:-}"
  [ -n "$name" ] || name="$(basename "$url" .git)"
  name="${name#ws-}"
  local wsdir; wsdir="$(expand "$HOME/ws/$name")"
  [ -e "$wsdir" ] && die "workspace path already exists: $wsdir"

  # Clone to a staging dir first: a bad clone (no workspace.yaml) must never
  # leave debris at the real destination.
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$url" "$tmp/clone"
  if [ ! -f "$tmp/clone/workspace.yaml" ]; then
    rm -rf "$tmp"
    die "clone of $url has no workspace.yaml - not a cel workspace"
  fi
  mkdir -p "$(dirname "$wsdir")"
  mv "$tmp/clone" "$wsdir"
  rm -rf "$tmp"

  registry_add "$name" "$wsdir" "$url"
  _ws_sync "$name"
}

# ------------------------------------------------------------------- sync
_ws_sync() {
  local names
  if [ $# -gt 0 ]; then names="$1"; else names="$(registry_names)"; fi
  local n
  for n in $names; do
    _ws_sync_one "$n"
  done
}

_ws_sync_one() {
  local n="$1" wsdir line r url t
  _ws_require "$n"; wsdir="$_WS_DIR"

  while IFS= read -r line; do
    grep -qxF "$line" "$wsdir/.gitignore" 2>/dev/null \
      || printf '%s\n' "$line" >> "$wsdir/.gitignore"
  done <<< "$_WS_GITIGNORE_LINES"

  mkdir -p "$wsdir/repos"
  for r in $(ws_repo_names "$wsdir"); do
    url="$(ws_repo_get "$wsdir" "$r" url)"
    if [ ! -d "$wsdir/repos/$r" ]; then
      if [ -n "$url" ]; then
        # Over the workspace's SSH alias when it declares one (CEL-70): the
        # push key is whatever github.com resolves to, independent of gh.
        # workspace.yaml keeps the canonical github.com url.
        git clone -q "$(ws_github_clone_url "$wsdir" "$url")" "$wsdir/repos/$r"
      else
        c_warn "workspace '$n': repo '$r' has no url and no local clone; skipping"
        continue
      fi
    fi
    # A checkout cloned before `ssh_host` was declared still points at plain
    # github.com, i.e. the default key; move exactly that origin onto the alias.
    if [ -n "$url" ] && [ -n "$(ws_github_ssh_host "$wsdir")" ] \
       && [ "$(git -C "$wsdir/repos/$r" remote get-url origin 2>/dev/null || true)" = "$url" ]; then
      git -C "$wsdir/repos/$r" remote set-url origin "$(ws_github_clone_url "$wsdir" "$url")" \
        || c_warn "workspace '$n': could not point $r's origin at $(ws_github_ssh_host "$wsdir")"
    fi
    ws_link_skills "$wsdir" "$wsdir/repos/$r"
    ws_render_claude_block "$wsdir" "$wsdir/repos/$r"
  done

  if [ -f "$wsdir/externals.yaml" ]; then
    install_externals "$wsdir/externals.yaml" || return
  fi

  # A linear-ticketed workspace gets Linear's OFFICIAL remote MCP registered
  # for claude sessions (user scope, idempotent, OAuth on first tool use).
  # Other runtimes use the linear skill's cel-linear shim instead - one ticket
  # surface, two transports.
  if [ "$(ws_ticket "$wsdir" system)" = "linear" ] && have claude; then
    if ! claude mcp get linear >/dev/null 2>&1; then
      claude mcp add --transport http --scope user linear https://mcp.linear.app/mcp >/dev/null 2>&1 \
        && c_ok "registered Linear MCP for claude (OAuth prompt on first use)" \
        || c_warn "could not register the Linear MCP - run by hand: claude mcp add --transport http --scope user linear https://mcp.linear.app/mcp"
    fi
  fi

  for t in $(yq -r '.tools // [] | .[]' "$wsdir/workspace.yaml" 2>/dev/null); do
    have "$t" || c_warn "workspace '$n': tool '$t' is not on PATH"
  done
}

# -------------------------------------------------------------------- env
# Prints eval-able exports for a workspace: `eval "$(cel ws env)"`. Silent
# success outside any workspace, so shellenv's hook can call it from every
# new shell without a guard.
_ws_env() {
  local wsdir
  if [ $# -gt 0 ]; then
    _ws_require "$1"; wsdir="$_WS_DIR"
  else
    wsdir="$(ws_current)" || return 0
  fi
  ws_env_exports "$wsdir"
}

# -------------------------------------------------------------------- push
# The only function in this file that touches gh.
_ws_push() {
  local name="$1" path org remote
  have gh || die "cel ws push: gh is required"
  _ws_require "$name"; path="$_WS_DIR"
  # The workspace repo is created AS the workspace's own account when it
  # declares one (CEL-70) - never the box's active account by default.
  if [ -n "$(ws_github_user "$path")" ]; then
    ws_github_ready "$path" || die "cel ws push: $(ws_github_fix "$(ws_github_user "$path")")"
  else
    gh auth status >/dev/null 2>&1 || die "cel ws push: gh is not authenticated"
  fi
  remote="$(registry_remote "$name")"
  [ -z "$remote" ] || die "workspace '$name' already has a remote: $remote"
  org="$(ws_org "$path")"
  [ -n "$org" ] || die "workspace '$name' has no org set in workspace.yaml"
  ws_gh "$path" repo create "$org/ws-$name" --private --source="$path" --push
  registry_set_remote "$name" "git@github.com:$org/ws-$name.git"
}
