# shellcheck shell=bash
# cel ws list|new|add|sync|push - the workspace-lifecycle commands. Dispatch
# wiring lives in bin/cel (Task 8); this file is command logic only.
[ -n "${_CEL_WS:-}" ] && return 0
_CEL_WS=1
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"

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

cmd_ws() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list) _ws_list;;
    new) _ws_new "$@";;
    add) _ws_add "$@";;
    sync) _ws_sync "$@";;
    push) _ws_push "$@";;
    env) _ws_env "$@";;
    *) die "unknown: cel ws $sub (list|new|add|sync|push|env)";;
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
env: {}                       # exported into every shell that starts in this workspace; secrets go in env.local (gitignored)
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
  wsdir="$(registry_require "$n")"

  while IFS= read -r line; do
    grep -qxF "$line" "$wsdir/.gitignore" 2>/dev/null \
      || printf '%s\n' "$line" >> "$wsdir/.gitignore"
  done <<< "$_WS_GITIGNORE_LINES"

  mkdir -p "$wsdir/repos"
  for r in $(ws_repo_names "$wsdir"); do
    url="$(ws_repo_get "$wsdir" "$r" url)"
    if [ ! -d "$wsdir/repos/$r" ]; then
      if [ -n "$url" ]; then
        git clone -q "$url" "$wsdir/repos/$r"
      else
        c_warn "workspace '$n': repo '$r' has no url and no local clone; skipping"
        continue
      fi
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
    wsdir="$(registry_require "$1")"
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
  gh auth status >/dev/null 2>&1 || die "cel ws push: gh is not authenticated"
  path="$(registry_require "$name")"
  remote="$(registry_remote "$name")"
  [ -z "$remote" ] || die "workspace '$name' already has a remote: $remote"
  org="$(ws_org "$path")"
  [ -n "$org" ] || die "workspace '$name' has no org set in workspace.yaml"
  gh repo create "$org/ws-$name" --private --source="$path" --push
  registry_set_remote "$name" "git@github.com:$org/ws-$name.git"
}
