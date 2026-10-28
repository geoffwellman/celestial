# shellcheck shell=bash
# cel preview: run an open pull request's head on this box so someone can try
# it before it merges - any agent, any repo that declares how it previews.
#
#   cel preview <repo>#<pr> [--port N] [--ttl 8h] [--workspace W] [--no-wait]
#   cel preview <repo>#<pr> --stop
#   cel preview --list [--json]
#
# The repo says how in workspace.yaml - the same `preview:` block
# `cel-fanout try` reads, with two optional steps added:
#
#   repos:
#     - name: widget
#       preview:
#         setup: "bun install --frozen-lockfile"     # in the checkout, every start
#         seed:  "cp -a ~/widget-data {data}"         # fills the preview's own data dir
#         cmd:   "bun run dev -- --mock --host {host} --port {port} --data {data}"
#         env:   { MODE: mock }
#         url:   "http://{host}:{port}"
#
# {port}, {port+N}, {host} (the box's tailnet address) and {data} are
# substituted in all of them.
#
# NO SPEND BY CONSTRUCTION. Every step runs under `env -i`: the caller's
# environment - provider keys, gateway tokens, GH_TOKEN, the workspace env -
# never reaches it; only PATH, HOME, LANG and the block's own env do. A
# checkout that TRACKS a .env or .dev.vars file is refused, because the app
# would load its keys from disk instead. This is environment containment, not
# network isolation: a repo whose cmd reaches a paid API with no key in its
# environment must say --mock (or its equivalent) in that cmd.
#
# Each preview is a `cel serve` server (a systemd unit, memory-accounted, TTL
# and idle reaping by the steward), so it is never one of the "unledgered"
# servers. The steward also stops a preview whose PR is closed or merged, and
# removes its checkout.
[ -n "${_CEL_PREVIEW:-}" ] && return 0
_CEL_PREVIEW=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/serve.sh
. "${BASH_SOURCE[0]%/*}/serve.sh"

_preview_state() { printf '%s/previews' "$(_serve_state)"; }
_preview_gh() { "${CEL_PREVIEW_GH:-gh}" "$@"; }
_preview_host() { # the address a phone or laptop on the tailnet reaches
  if [ -n "${CEL_PREVIEW_HOST:-}" ]; then printf '%s' "$CEL_PREVIEW_HOST"; return; fi
  # shellcheck source=lib/dash.sh
  . "${BASH_SOURCE[0]%/*}/dash.sh"
  dash_host
}
_preview_port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
# A block of ten from 4600 - away from `cel-fanout try`'s 4400 - because a
# preview is often several processes ({port+N}).
_preview_alloc_port() {
  local base="${CEL_PREVIEW_PORT_BASE:-4600}" i ok
  while [ "$base" -le 65525 ]; do
    ok=1
    for i in 0 1 2 3 4 5 6 7 8 9; do _preview_port_free $((base + i)) || { ok=0; break; }; done
    [ "$ok" -eq 1 ] && { printf '%s' "$base"; return 0; }
    base=$((base + 10))
  done
  return 1
}
_preview_subst() { # <string> <port> <host> <data>
  local s="$1" n
  while [[ "$s" =~ \{port\+([0-9]+)\} ]]; do n="${BASH_REMATCH[1]}"; s="${s//\{port+$n\}/$(($2 + n))}"; done
  s="${s//\{port\}/$2}"; s="${s//\{host\}/$3}"
  printf '%s' "${s//\{data\}/$4}"
}
_preview_name() { # <repo> <pr> -> a cel serve name (<=48 chars)
  local r; r="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-')"
  r="preview-${r:0:30}-pr$2"
  printf '%s' "${r:0:48}"
}
_preview_meta() { printf '%s/%s.json' "$(_preview_state)" "$1"; }

_preview_wsdir() { # [workspace] -> wsdir
  if [ -n "${1:-}" ]; then registry_require "$1"
  else ws_current || die "cel preview: not inside a workspace - cd into one, or pass --workspace <name>"
  fi
}

# Stop one preview and remove what it made: the server, its checkout, its
# data and the fetched ref. Quiet about pieces already gone. A record that is
# partial, empty or corrupt removes NOTHING on disk: the checkout path must be
# absolute and end in .cel/previews/<name>, and the repo absolute, before any
# rm or git runs - a missing key read as "null" or "" would otherwise be a
# path relative to wherever the caller stands.
_preview_teardown() { # <name>
  local name="$1" meta repodir wt
  meta="$(_preview_meta "$name")"
  [ -f "$(_serve_file "$name")" ] && { serve_stop "$name" >/dev/null 2>&1 || c_warn "cel preview: could not stop $name"; }
  [ -f "$meta" ] || return 0
  repodir="$(jq -r '.repodir // empty' "$meta" 2>/dev/null || true)"
  wt="$(jq -r '.worktree // empty' "$meta" 2>/dev/null || true)"
  if [[ "$repodir" == /* ]] && [[ "$wt" == /*/.cel/previews/"$name" ]]; then
    if [ -d "$wt" ]; then
      git -C "$repodir" worktree remove --force "$wt" 2>/dev/null || rm -rf -- "$wt"
      git -C "$repodir" worktree prune 2>/dev/null || true
    fi
    rm -rf -- "$wt.state"
    git -C "$repodir" update-ref -d "refs/cel/preview/$name" 2>/dev/null || true
  else
    c_warn "cel preview: $name's record names no checkout of its own - removed the record only"
  fi
  rm -f -- "$meta"
}

preview_start() { # <wsdir> <repo> <pr> <port|0> <ttl-seconds> <wait 0|1>
  local wsdir="$1" repo="$2" pr="$3" port="$4" ttl="$5" wait="$6"
  local cmd; cmd="$(ws_repo_preview "$wsdir" "$repo" cmd)"
  [ -n "$cmd" ] || die "cel preview: repo '$repo' declares no preview.cmd in workspace.yaml - add
    preview: { cmd: \"<how to start it, with --mock>\", url: \"http://{host}:{port}\" }
  under that repo (optional: setup, seed, env)."
  local repodir="$wsdir/repos/$repo"
  [ -d "$repodir" ] || die "cel preview: no checkout of '$repo' at $repodir"
  local slug; slug="$(ws_repo_github_slug "$wsdir" "$repo" "$repodir")" \
    || die "cel preview: cannot tell which GitHub repo '$repo' is"
  local info state head
  info="$(_preview_gh pr view "$pr" --repo "$slug" --json state,headRefOid 2>/dev/null)" \
    || die "cel preview: $slug#$pr not found"
  state="$(jq -r .state <<<"$info")"; head="$(jq -r .headRefOid <<<"$info")"
  [ "$state" = OPEN ] || die "cel preview: $slug#$pr is $state - only an open PR is previewed"

  local name meta wt data
  name="$(_preview_name "$repo" "$pr")"; meta="$(_preview_meta "$name")"
  wt="$wsdir/.cel/previews/$name"; data="$wt.state/data"
  # The same head already running is the same preview: the answer is its url.
  if [ -f "$meta" ] && [ "$(jq -r .head "$meta")" = "$head" ] && [ -f "$(_serve_file "$name")" ]; then
    c_ok "$repo#$pr is already previewing ${head:0:12}"
    jq -r '.urls[]' "$meta"; return 0
  fi
  # A moved head (or a dead server) starts over from the new head.
  _preview_teardown "$name"

  git -C "$repodir" fetch -q origin "+refs/pull/$pr/head:refs/cel/preview/$name" \
    || die "cel preview: could not fetch $slug#$pr"
  [ "$(git -C "$repodir" rev-parse "refs/cel/preview/$name")" = "$head" ] \
    || die "cel preview: fetched head is not the PR's head ${head:0:12} - the PR moved; run it again"
  mkdir -p "$wsdir/.cel/previews"
  git -C "$repodir" worktree add -q --detach "$wt" "$head" \
    || die "cel preview: could not check out ${head:0:12} at $wt"
  # recorded now, so a refusal below (or a failed start) can find and remove it
  mkdir -p "$(_preview_state)"
  jq -n --arg name "$name" --arg repodir "$repodir" --arg worktree "$wt" \
    '{name:$name,repodir:$repodir,worktree:$worktree}' > "$meta"
  local secrets
  secrets="$(git -C "$wt" ls-files | grep -E '(^|/)(\.env(\..*)?|\.dev\.vars)$' | grep -vE '\.(example|sample|template)$' || true)"
  if [ -n "$secrets" ]; then
    _preview_teardown "$name"
    die "cel preview: $slug#$pr tracks $(printf '%s' "$secrets" | head -1) - the app would load keys from it; refusing"
  fi

  if [ "$port" = 0 ]; then
    port="$(_preview_alloc_port)" || die "cel preview: no free block of 10 ports from ${CEL_PREVIEW_PORT_BASE:-4600}"
  else
    _preview_port_free "$port" || die "cel preview: port $port is in use"
  fi
  local host; host="$(_preview_host)"
  mkdir -p "$wt.state"
  # THE RUN SCRIPT, written once and run by the unit: setup, seed, a
  # localhost forward when the app listens on the tailnet address (remote
  # clients such as Moshi reach the box's localhost through ssh), then the cmd.
  local run="$wt.state/run.sh" k v kv step
  {
    printf '#!/bin/bash\nset -e\ncd %q\n' "$wt"
    printf 'mkdir -p %q\n' "$data"
    printf 'exec env -i PATH=%q HOME=%q LANG=C.UTF-8 TERM=dumb CEL_PREVIEW=1 PORT=%q' "$PATH" "$HOME" "$port"
    while IFS= read -r kv; do
      [ -n "$kv" ] || continue
      k="${kv%%=*}"; v="${kv#*=}"
      [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { c_warn "cel preview: skipping preview.env entry $k"; continue; }
      printf ' %s=%q' "$k" "$(_preview_subst "$v" "$port" "$host" "$data")"
    done < <(ws_repo_preview_env "$wsdir" "$repo")
    printf ' bash -c %q\n' "$(
      for step in setup seed; do
        v="$(ws_repo_preview "$wsdir" "$repo" "$step")"
        [ -z "$v" ] || printf '%s\n' "$(_preview_subst "$v" "$port" "$host" "$data")"
      done
      if [ "$host" != 127.0.0.1 ] && [ "$host" != localhost ]; then
        printf 'node %q %q %q &\n' "$CEL_ROOT/tools/preview/forward.mjs" "$port" "$host"
      fi
      # the last line, not exec'd: a cmd may be several statements
      printf '%s\n' "$(_preview_subst "$cmd" "$port" "$host" "$data")"
    )"
  } > "$run"
  chmod 700 "$run"

  local url; url="$(_preview_subst "$(ws_repo_preview "$wsdir" "$repo" url)" "$port" "$host" "$data")"
  [ -n "$url" ] || url="http://$host:$port"
  local -a urls=("$url")
  [ "$host" = 127.0.0.1 ] || [ "$host" = localhost ] || urls+=("http://localhost:$port")

  CEL_SERVE_WORKTREE="$wt" serve_start "$name" "${CEL_INBOX_ME:-$(id -un)}" "$(ws_name "$wsdir")" "$ttl" "$port" -- "$run" \
    || { _preview_teardown "$name"; die "cel preview: could not start the server"; }
  jq -n --arg name "$name" --arg repo "$repo" --arg slug "$slug" --argjson pr "$pr" --arg head "$head" \
    --arg repodir "$repodir" --arg worktree "$wt" --arg wsdir "$wsdir" --argjson port "$port" \
    --args '{name:$name,repo:$repo,slug:$slug,pr:$pr,head:$head,repodir:$repodir,worktree:$worktree,wsdir:$wsdir,port:$port,urls:$ARGS.positional}' \
    "${urls[@]}" > "$meta"

  if [ "$wait" = 1 ]; then
    local i code=000 limit="${CEL_PREVIEW_WAIT:-300}"
    for ((i = 0; i < limit; i += 2)); do
      code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$url" 2>/dev/null || true)"
      case "$code" in 2*|3*|401|403|404) break ;; esac
      sleep 2
    done
    case "$code" in
      2*|3*|401|403|404) c_ok "$repo#$pr (${head:0:12}) is up" ;;
      *) c_warn "cel preview: $url did not answer in ${limit}s - journalctl --user -u cel-serve-$name" ;;
    esac
  else
    c_ok "$repo#$pr (${head:0:12}) starting - journalctl --user -u cel-serve-$name"
  fi
  # LAST LINES: the urls, which are the point of having run this.
  printf '%s\n' "${urls[@]}"
}

preview_list_json() {
  local f out='[]' name
  for f in "$(_preview_state)"/*.json; do
    [ -f "$f" ] || continue
    name="$(jq -r .name "$f")"
    out="$(jq --slurpfile m "$f" --arg up "$([ -f "$(_serve_file "$name")" ] && echo 1)" \
      '. + [$m[0] + {running: ($up == "1")}]' <<<"$out")"
  done
  printf '%s\n' "$out"
}

# Steward: a preview of a PR that is no longer open is stopped and its
# checkout removed; one whose server the steward already reaped (TTL, idle,
# gone) has its checkout removed. An unreadable PR state changes nothing.
preview_sweep() {
  local f name slug pr state
  for f in "$(_preview_state)"/*.json; do
    [ -f "$f" ] || continue
    name="$(jq -r '.name // empty' "$f" 2>/dev/null || true)"
    [ -n "$name" ] || continue
    # A record without .head is a `cel preview` still starting (its server
    # is not recorded yet): left alone for 10 minutes, then treated as dead.
    if ! jq -e '.head' "$f" >/dev/null 2>&1 && [ -n "$(find "$f" -mmin -10 2>/dev/null)" ]; then continue; fi
    if [ ! -f "$(_serve_file "$name")" ]; then _preview_teardown "$name"; continue; fi
    slug="$(jq -r .slug "$f")"; pr="$(jq -r .pr "$f")"
    state="$(_preview_gh pr view "$pr" --repo "$slug" --json state --jq .state 2>/dev/null || true)"
    case "$state" in
      CLOSED|MERGED)
        _preview_teardown "$name"
        c_ok "steward: stopped preview of $slug#$pr - the PR is $state" ;;
    esac
  done
}

cmd_preview() {
  local target="" port=0 ttl=28800 ws="" stop=0 list=0 json=0 wait=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) port="${2:-}"; shift 2; [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || die "cel preview: bad --port" ;;
      --ttl) ttl="${2:-}"; shift 2; ttl="${ttl%h}"; [[ "$ttl" =~ ^[1-9][0-9]*$ ]] || die "cel preview: --ttl wants hours (8h)"; ttl=$((ttl * 3600)) ;;
      --workspace) ws="${2:-}"; shift 2 ;;
      --stop) stop=1; shift ;;
      --list) list=1; shift ;;
      --json) json=1; shift ;;
      --no-wait) wait=0; shift ;;
      -*) die "cel preview: unknown option $1" ;;
      *) [ -z "$target" ] || die "cel preview: one <repo>#<pr> at a time"; target="$1"; shift ;;
    esac
  done
  if [ "$list" -eq 1 ]; then
    if [ "$json" -eq 1 ]; then preview_list_json; return; fi
    preview_list_json | jq -r '.[] | [ "\(.repo)#\(.pr)", .head[0:12], (if .running then "running" else "stopped" end), .urls[0] ] | @tsv' \
      | while IFS=$'\t' read -r a b c d; do printf '%-28s %-13s %-8s %s\n' "$a" "$b" "$c" "$d"; done
    return
  fi
  [[ "$target" =~ ^([A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
    || die "usage: cel preview <repo>#<pr> [--port N] [--ttl 8h] [--no-wait] | <repo>#<pr> --stop | --list"
  local repo="${BASH_REMATCH[1]}" pr="${BASH_REMATCH[2]}"
  if [ "$stop" -eq 1 ]; then
    local name; name="$(_preview_name "$repo" "$pr")"
    [ -f "$(_preview_meta "$name")" ] || [ -f "$(_serve_file "$name")" ] || { c_warn "no preview of $repo#$pr"; return 0; }
    _preview_teardown "$name"; c_ok "stopped the preview of $repo#$pr"; return 0
  fi
  local wsdir; wsdir="$(_preview_wsdir "$ws")"
  preview_start "$wsdir" "$repo" "$pr" "$port" "$ttl" "$wait"
}
