# shellcheck shell=bash
# `cel spike` scaffolds a disposable repo under spikes/ - no manifest entry,
# disposable by construction. `cel promote` moves a spike into repos/ and
# registers it in workspace.yaml.
[ -n "${_CEL_SPIKE:-}" ] && return 0
_CEL_SPIKE=1
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"

# One question per unknown; Enter accepts the visible default. Reads stdin so
# tests can feed answers; an empty read (EOF) also takes the default. A
# private copy: lib/ws.sh owns the canonical one and these two tasks run in
# parallel, so neither sources the other.
_ask() { # <question> <default>
  local a=""
  if [ -t 0 ]; then read -r -p "  $1${2:+ [$2]}: " a || true
  else read -r a || true; fi
  printf '%s' "${a:-$2}"
}

cmd_spike() { # <name>
  local name="${1:-}" wsdir dir
  [ -n "$name" ] || die "usage: cel spike <name>"
  wsdir="$(ws_current)" || die "not inside a workspace"
  dir="$wsdir/spikes/$name"
  [ -e "$dir" ] && die "spike '$name' already exists"
  mkdir -p "$dir"
  git -C "$dir" init -q
  ws_link_skills "$wsdir" "$dir"
  ws_render_claude_block "$wsdir" "$dir"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "feat: spike $name scaffolded by cel spike"
}

cmd_promote() { # <name> [--no-remote] [--prefix P] [--gate G]
  local name="${1:-}" wsdir src dest no_remote=0 prefix="" gate="" org url="" tmp
  shift || true
  [ -n "$name" ] || die "usage: cel promote <name> [--no-remote] [--prefix P] [--gate G]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-remote) no_remote=1; shift;;
      --prefix) prefix="${2:-}"; shift 2;;
      --gate) gate="${2:-}"; shift 2;;
      *) die "unknown flag: $1";;
    esac
  done
  wsdir="$(ws_current)" || die "not inside a workspace"
  src="$wsdir/spikes/$name"
  dest="$wsdir/repos/$name"
  [ -d "$src" ] || die "no such spike: $name (cel spike $name first)"
  mkdir -p "$wsdir/repos"
  mv "$src" "$dest"

  if [ "$no_remote" -eq 1 ]; then
    url=""
  else
    org="$(ws_org "$wsdir")"
    have gh || die "gh is required to create a remote (or pass --no-remote)"
    gh repo create "$org/$name" --private --source "$dest" --push
    url="git@github.com:$org/$name.git"
  fi

  [ -n "$prefix" ] || prefix="$(_ask "prefix" "$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | cut -c1-3)")"
  [ -n "$gate" ] || gate="$(_ask "gate" "")"

  tmp="$(mktemp)"
  yq -y --arg n "$name" --arg u "$url" --arg p "$prefix" --arg g "$gate" \
    '.repos = (.repos // []) + [{name: $n,
       url: (if $u == "" then null else $u end),
       prefix: (if $p == "" then null else $p end),
       gate: (if $g == "" then null else $g end)}]' \
    "$wsdir/workspace.yaml" > "$tmp" && mv "$tmp" "$wsdir/workspace.yaml"

  ws_link_skills "$wsdir" "$dest"
  ws_render_claude_block "$wsdir" "$dest"
}
