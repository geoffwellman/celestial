# shellcheck shell=bash
# Reads workspace.yaml and renders everything derived from it: the policy block
# injected into agents, the CLAUDE.md block rendered into repos, and the
# per-repo skill symlinks. A "wsdir" is the directory holding workspace.yaml.
[ -n "${_CEL_WORKSPACE:-}" ] && return 0
_CEL_WORKSPACE=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"

# shellcheck source=lib/yaml.sh
. "${BASH_SOURCE[0]%/*}/yaml.sh"


_wsy() { # _wsy <wsdir> <program>  - yq over the workspace file, "" for absent
  _yqr -r "$2 // \"\" | tostring" "$1/workspace.yaml"
}

ws_current() {
  local d; d="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || return 1
  while [ "$d" != "/" ]; do
    [ -f "$d/workspace.yaml" ] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

ws_name()   { _wsy "$1" '.name'; }
ws_kind()   { _wsy "$1" '.kind'; }
ws_org()    { _wsy "$1" '.org'; }
# THE LAYOUT, IN TWO SHAPES THAT MUST NOT COLLIDE. A scalar `layout: dev`
# names the herdr workspace-manager layout `cel run root` applies; a map
# declares what should be running in the workspace:
#
#   layout:
#     orchestrators: auto      # auto | manual | none
#     panes:
#       - { label: dash, cwd: ., cmd: cel dash --ensure }
#
# A map has no workspace-manager id unless it says `id:`, and a scalar declares
# no shape. Each accessor answers for its own shape and returns nothing for the
# other, so herdr is never handed a block of yaml as a layout name.
ws_layout() { # <wsdir> - the workspace-manager layout id, or ""
  _yqr -r '.layout as $l
    | (if ($l | type) == "string" then $l
       elif ($l | type) == "object" then ($l.id // "")
       else "" end) | tostring' "$1/workspace.yaml"
}

# WHAT SILENCE MEANS, IN ONE PLACE. A workspace with no `layout:` block behaves
# as `orchestrators: manual` and no extra panes. The default lives here so
# `up`, `status`, the steward and the doctor line agree. A string layout, an
# object layout without the key, and no layout at all all answer this same
# word - and a product's own `orchestrator:` can still overrule it.
ws_orchestrators_default() { printf 'manual'; }

# The DECLARED value of a layout key, or "" when the block is absent, is a
# scalar layout id, or simply does not say. No default: a caller that needs to
# tell "declared manual" from "said nothing" has to be able to see the silence.
ws_layout_declared() { # <wsdir> <key>
  _yqr -r --arg k "$2" '.layout as $l
    | (if ($l | type) == "object" then ($l[$k] // "") else "" end) | tostring' "$1/workspace.yaml"
}

# One declared pane per line as `label\tcwd\tcmd`, IN FILE ORDER: the order is
# the declaration - a dashboard above its notes - and a set would lose it.
# `cwd` defaults to the workspace dir itself; an absent `cmd` is an empty pane.
ws_layout_panes() { # <wsdir>
  _yqr -r '.layout as $l
    | (if ($l | type) == "object" then ($l.panes // []) else [] end)
    | .[] | [(.label // ""), (.cwd // "."), (.cmd // "")] | @tsv' "$1/workspace.yaml"
}
ws_ticket() { _yqr -r --arg k "$2" '.tickets[$k] // "" | tostring' "$1/workspace.yaml"; }
ws_policy() { _yqr -r --arg k "$2" '.policy[$k]  // "" | tostring' "$1/workspace.yaml"; }

# Default runtime: claude, unless workspace.yaml's `runtime:` names one per role.
ws_runtime() {
  local r
  r="$(_yqr -r --arg k "$2" '.runtime[$k] // ""' "$1/workspace.yaml")"
  printf '%s' "${r:-claude}"
}

# Read through the merge: workspace.local.yaml may override env: per box.
ws_env_names() { _yqr_ws -r '.env // {} | keys[]' "$1"; }
ws_env_get()   { _yqr_ws -r --arg k "$2" '.env[$k] // "" | tostring' "$1"; }

# Workspace env as eval-able shell: the committed `env:` map first, then a
# source of the gitignored env.local so secrets and per-box overrides win.
# Values are single-quoted and keys validated, so a stray yaml entry can never
# inject shell into the caller's eval.
ws_env_exports() { # <wsdir>
  local d="$1" k v
  for k in $(ws_env_names "$d"); do
    if ! printf '%s' "$k" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
      # stdout is eval'd by the caller, so the warning must ride stderr
      c_warn "workspace env: skipping invalid variable name '$k'" >&2
      continue
    fi
    v="$(ws_env_get "$d" "$k")"
    v=${v//"'"/"'\\''"}
    printf "export %s='%s'\n" "$k" "$v"
  done
  if [ -f "$d/env.local" ]; then
    # `set -a` around the source so a plain `KEY=value` line is exported too.
    # env.local is SOURCED, and without export an assignment makes a shell
    # variable that child processes do not inherit - so the key would be
    # visible to your shell and invisible to every agent launched from it.
    # That failure is silent and looks like a bad key rather than a missing
    # export, so the file is treated as what it is: an environment file.
    # Restored rather than left on, so nothing after this is auto-exported.
    local p="$d/env.local"; p=${p//"'"/"'\\''"}
    printf 'set -a; . %s; set +a\n' "'$p'"
  fi
}

# The `review:` block configures local PR reviewer panes (cel run reviewer).
ws_review() { _yqr -r --arg k "$2" '.review[$k] // "" | tostring' "$1/workspace.yaml"; }

# Where a reviewer's verdict is published. On a public repo whose only GitHub
# identity is the owner's, a reviewer agent posting a review is the owner
# reviewing his own PR in public - and GitHub refuses the approval anyway. So
# the review is recorded with `cel solo review` and reported by inbox, and `github` is
# opt-in for repos where the reviewer has an identity of its own (a GitHub App
# or a second account). The default lives HERE and nowhere else: a second
# copy of it in a role file or a launch path is how the two drift apart.
ws_review_post() { # <wsdir>
  local p; p="$(ws_review "$1" post)"
  [ "$p" = "github" ] && { printf 'github\n'; return 0; }
  printf 'inbox\n'
}

# Every ticket prefix this repo answers to, CURRENT ONE FIRST then any
# `prefix_aliases`. Aliases exist because a Linear team can be re-keyed
# (ABC -> ABCD) without renumbering its issues: Linear still resolves the old
# identifiers, but branches and worktrees cut before the rename keep their old
# names forever. Without the alias every in-flight branch would suddenly read
# as unticketed and be nagged by the steward.
ws_repo_prefixes() { # <wsdir> <repo>
  _yqr -r --arg n "$2" '.repos // [] | map(select(.name == $n))[0] as $r
    | ([$r.prefix // empty] + ($r.prefix_aliases // [])) | .[]' "$1/workspace.yaml"
}

ws_repo_names() { _yqr -r '.repos // [] | .[].name' "$1/workspace.yaml"; }
ws_repo_get() {
  _yqr -r --arg n "$2" --arg k "$3" \
    '.repos // [] | map(select(.name == $n))[0][$k] // "" | tostring' \
    "$1/workspace.yaml"
}

# Whether this repo's work goes through a PR. A repo entry's `pr:` overrides
# `policy.pr` for that repo alone. A value outside required|none is a config
# error - guessing would either open PRs nobody reviews or push unreviewed
# work to a repo that wanted review.
ws_repo_pr() { # <wsdir> <repo> -> required|none
  local v; v="$(ws_repo_get "$1" "$2" pr)"
  [ -n "$v" ] || v="$(ws_policy "$1" pr)"
  case "${v:-required}" in
    required|none) printf '%s' "${v:-required}" ;;
    *) die "workspace.yaml pr for repo $2 must be required or none (got: $v)" ;;
  esac
}

# THE ONE REMOTE-URL GRAMMAR. Every place that reads a repo's identity out of
# a remote url parses it here, so GitHub's slug and a Forgejo repo's
# descriptor can never disagree about what a url says. Three spellings, as
# git writes them:
#
#   <user>@<host>:<owner>/<name>[.git]                scp
#   ssh://<user>@<host>[:<port>]/<owner>/<name>[.git] ssh
#   https://<host>[:<port>]/<owner>/<name>[.git]      https
#
# Nothing is normalised: no case folding, no extra path segments, no userinfo
# on https, no plain http. The path must be exactly owner/name, so a lookalike
# such as https://gitlab.com/github.com/o/r has host gitlab.com, not a slug.
# Sets FORGE_URL_SCHEME, FORGE_URL_USER, FORGE_URL_HOST, FORGE_URL_PORT and
# FORGE_URL_PATH (owner/name, one trailing .git removed); a caller that wants
# them kept to itself declares them `local` first.
forge_url_parse() { # <url>
  FORGE_URL_SCHEME="" FORGE_URL_USER="" FORGE_URL_HOST="" FORGE_URL_PORT="" FORGE_URL_PATH=""
  local u="$1" path
  if [[ "$u" =~ ^https://([A-Za-z0-9.-]+)(:([0-9]+))?/(.*)$ ]]; then
    FORGE_URL_SCHEME=https FORGE_URL_HOST="${BASH_REMATCH[1]}" FORGE_URL_PORT="${BASH_REMATCH[3]}" path="${BASH_REMATCH[4]}"
  elif [[ "$u" =~ ^ssh://([A-Za-z0-9._-]+)@([A-Za-z0-9._-]+)(:([0-9]+))?/(.*)$ ]]; then
    FORGE_URL_SCHEME=ssh FORGE_URL_USER="${BASH_REMATCH[1]}" FORGE_URL_HOST="${BASH_REMATCH[2]}"
    FORGE_URL_PORT="${BASH_REMATCH[4]}" path="${BASH_REMATCH[5]}"
  elif [[ "$u" != *://* && "$u" =~ ^([A-Za-z0-9._-]+)@([A-Za-z0-9._-]+):(.*)$ ]]; then
    FORGE_URL_SCHEME=scp FORGE_URL_USER="${BASH_REMATCH[1]}" FORGE_URL_HOST="${BASH_REMATCH[2]}" path="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  path="${path%.git}"
  [[ "$path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  FORGE_URL_PATH="$path"
}

# `owner/name` from a GitHub remote url - SSH (git@github.com:o/r.git,
# ssh://git@github.com/o/r) or HTTPS. Fails on anything that is not GitHub,
# so a caller that needs `gh --repo` refuses rather than guesses.
github_slug_from_url() { # <url> [ssh-alias-host] -> owner/name
  # The host is matched EXACTLY: a substring match turned
  # git@evilgithub.com:o/r and https://evil.github.com/o/r into slugs.
  # A workspace's declared `github.ssh_host` is github.com under an
  # ~/.ssh/config alias, so `git@<alias>:o/r` is accepted - that exact host
  # only, passed by the caller that read the declaration. Never a pattern:
  # `github-*` would let any lookalike alias name a GitHub slug. No port and
  # no user other than git: github.com is reached exactly one way.
  local alias="${2:-}"
  local FORGE_URL_SCHEME FORGE_URL_USER FORGE_URL_HOST FORGE_URL_PORT FORGE_URL_PATH
  forge_url_parse "$1" || return 1
  case "$FORGE_URL_SCHEME" in
    scp)   [ "$FORGE_URL_USER" = git ] || return 1
           [ "$FORGE_URL_HOST" = github.com ] || { [ -n "$alias" ] && [ "$FORGE_URL_HOST" = "$alias" ]; } || return 1 ;;
    ssh)   [ "$FORGE_URL_USER" = git ] && [ "$FORGE_URL_HOST" = github.com ] && [ -z "$FORGE_URL_PORT" ] || return 1 ;;
    https) [ "$FORGE_URL_HOST" = github.com ] && [ -z "$FORGE_URL_PORT" ] || return 1 ;;
    *)     return 1 ;;
  esac
  printf '%s' "$FORGE_URL_PATH"
}

# A repo's GitHub identity: its declared url, else the checkout's origin.
# The workspace-local name is a nickname and is never used as a slug.
ws_repo_github_slug() { # <wsdir> <repo> [repodir] -> owner/name
  local url
  url="$(ws_repo_get "$1" "$2" url)"
  local alias; alias="$(ws_github_ssh_host "$1")"
  if [ -n "$url" ] && github_slug_from_url "$url" "$alias"; then return 0; fi
  [ -n "${3:-}" ] || return 1
  url="$(git -C "$3" remote get-url origin 2>/dev/null)" || return 1
  github_slug_from_url "$url" "$alias"
}

# THE WORKSPACE'S GITHUB ACCOUNT.
#
#   github:
#     user: acct-b              # the gh account this workspace acts as
#     ssh_host: github-acct-b   # optional ~/.ssh/config Host alias with its key
#
# gh keeps several accounts per host but only ONE is active, box-wide, in
# ~/.config/gh/hosts.yml. `gh auth switch` for one workspace would silently
# re-identify every agent, steward sweep and land in every other workspace,
# so nothing here ever switches: the override is GH_TOKEN,
# which beats hosts.yml for one process only. Absent block = box default.
ws_github_user()     { _wsy "$1" '.github.user'; }
ws_github_ssh_host() { _wsy "$1" '.github.ssh_host'; }

# The one fix text, so the refusal at launch, at a plane call and in doctor
# all tell the human the same two commands.
ws_github_fix() { # <user>
  printf "gh account '%s' is not logged in on this box - run: gh auth login (as %s), then check with: gh auth status" "$1" "$1"
}

# Is the declared account usable? True with no block. The token goes to
# /dev/null: this answers yes/no and never holds the value.
ws_github_ready() { # <wsdir> [gh-binary]
  local user; user="$(ws_github_user "$1")"
  [ -n "$user" ] || return 0
  "${2:-gh}" auth token --user "$user" >/dev/null 2>&1
}

# Every gh call the plane makes ON BEHALF OF a workspace goes through here.
# GH_TOKEN is set for this one invocation - never exported, never written, so
# the next workspace in the same steward tick starts clean. FAIL CLOSED: a
# declared account that cannot produce a token refuses the call rather than
# falling back to the active account, because acting as the wrong identity is
# the whole bug. THE BINARY IS THE BOX'S: gh is run with the account's token,
# so it is cel_gh_bin's (lib/common.sh: the system directories, then this
# user's ~/.local/bin, never the caller's PATH). A gh installed only under
# the home directory is the least-bad case - it cannot be told from one
# planted over it - and a gh found nowhere there refuses the call.
# CEL_WS_GH_BIN, the stub seam callers pass on (cel forge's CEL_FORGE_GH,
# land's GH, afk's CEL_AFK_GH), is honoured only under this checkout's own
# suite (cel_under_suite); anywhere else it names nothing.
ws_gh() { # <wsdir> <gh args...>
  local wsdir="$1"; shift
  local bin user tok
  bin="$(cel_gh_bin "${CEL_WS_GH_BIN:-}")" || { printf 'gh %s refused: no trusted gh\n' "$*" >&2; return 1; }
  user="$(ws_github_user "$wsdir")"
  if [ -z "$user" ]; then "$bin" "$@"; return; fi
  tok="$("$bin" auth token --user "$user" 2>/dev/null)" || tok=""
  if [ -z "$tok" ]; then
    printf '%s refused: %s\n' "gh $*" "$(ws_github_fix "$user")" >&2
    return 1
  fi
  GH_TOKEN="$tok" "$bin" "$@"
}

# What a pane evaluates for itself, in two halves: a GUARD typed at the head
# of the launch line and the env WORD beside the other launch variables. The
# token is produced by gh inside the pane and never passes through cel, a
# launch line, a log or scrollback (the OMP_GATEWAY_TOKEN pattern in
# lib/run.sh). FAIL CLOSED IN THE PANE: cel's own readiness check and this
# evaluation are separate moments, and auth can vanish between them - so the
# agent's start is CHAINED on the token command succeeding with a non-empty
# value. On failure the pane prints the fix and the agent never runs; an empty
# or placeholder GH_TOKEN would mean "the active account" or a silent 401.
# The value sits in an UNEXPORTED shell variable of the pane for the agent's
# `env` to pass on; it is never in the text typed or shown.
ws_github_launch_guard() { # <wsdir> -> `_cel_gh_tok=... || {fix; false;} && ` or nothing
  local user; user="$(ws_github_user "$1")"
  [ -n "$user" ] || return 0
  printf '{ _cel_gh_tok="$(gh auth token --user %q)" && [ -n "$_cel_gh_tok" ]; } || { printf "%%s\\n" %q >&2; false; } && ' \
    "$user" "cel: refusing to start: $(ws_github_fix "$user")"
}
ws_github_env_word() { # <wsdir> -> `GH_TOKEN="$_cel_gh_tok"` or nothing
  [ -n "$(ws_github_user "$1")" ] || return 0
  printf 'GH_TOKEN="$_cel_gh_tok"'
}

# Where git should reach a repo: the canonical url, rewritten onto the SSH
# alias when the workspace declares one. workspace.yaml keeps github.com.
ws_github_clone_url() { # <wsdir> <url>
  local host url="$2"; host="$(ws_github_ssh_host "$1")"
  case "$url" in
    git@github.com:*) [ -z "$host" ] || url="git@$host:${url#git@github.com:}" ;;
  esac
  printf '%s' "$url"
}

# A REPO'S FORGE: which provider serves it, at which host, and how git dials it.
#
#   repos:
#     - name: widget
#       url: git@code.example.net:acme/widget.git
#       forge: forgejo          # optional: github | forgejo
#       host: code.example.net  # optional: the web/API host, when the url's
#                               # host is an ~/.ssh/config alias; written
#                               # http://<host> when that forge serves plain
#                               # HTTP only (an internal box) - never implied
#
# The url - declared, else the checkout's origin - is the identity. GitHub is
# whatever github_slug_from_url accepts (github.com, or this workspace's
# github.ssh_host alias), so this and ws_repo_github_slug cannot disagree.
# Any other host is Forgejo only when the repo says so, by `forge: forgejo` or
# a `host:` of its own: an undeclared host is refused, never guessed, so
# git@evilgithub.com:o/r is nobody's repo. A declaration the url contradicts
# (forge: github on another host, an https url to a host other than `host:`,
# Forgejo behind the GitHub account's alias) is refused too.
#
# Prints one JSON object: provider, host (web/API host, no scheme), owner,
# repo, ssh_host (what git dials - the alias when one is declared), web_url,
# and api_url (the repository's API root). Both urls are https unless the
# repo's own `host:` says http://.
forge_repo() { # <wsdir> <repo> [repodir]
  local wsdir="$1" repo="$2" repodir="${3:-}" url forge host gh_alias provider web_host ssh_host api url_web web_scheme=https
  local FORGE_URL_SCHEME FORGE_URL_USER FORGE_URL_HOST FORGE_URL_PORT FORGE_URL_PATH
  url="$(ws_repo_get "$wsdir" "$repo" url)" || return 1
  if [ -z "$url" ] && [ -n "$repodir" ]; then
    url="$(git -C "$repodir" remote get-url origin 2>/dev/null)" || url=""
  fi
  [ -n "$url" ] || { _forge_repo_no "$repo" "it declares no url and has no origin remote - nothing names its forge"; return 1; }
  forge_url_parse "$url" \
    || { _forge_repo_no "$repo" "'$url' is not a remote url this plane reads (git@host:owner/name, ssh://git@host[:port]/owner/name or https://host[:port]/owner/name)"; return 1; }
  forge="$(ws_repo_get "$wsdir" "$repo" forge)"
  host="$(ws_repo_get "$wsdir" "$repo" host)"
  gh_alias="$(ws_github_ssh_host "$wsdir")"
  case "$forge" in
    github|forgejo) provider="$forge" ;;
    "")
      if github_slug_from_url "$url" "$gh_alias" >/dev/null; then provider=github
      elif [ -n "$host" ]; then provider=forgejo
      else
        _forge_repo_no "$repo" "cannot tell which forge serves $FORGE_URL_HOST - declare forge: forgejo (and host: <web host> when $FORGE_URL_HOST is an ssh alias) on the repo"
        return 1
      fi ;;
    *) _forge_repo_no "$repo" "forge: must be github or forgejo (got: $forge)"; return 1 ;;
  esac

  if [ "$provider" = github ]; then
    github_slug_from_url "$url" "$gh_alias" >/dev/null \
      || { _forge_repo_no "$repo" "forge: github, but '$url' is not a github.com remote (or this workspace's github.ssh_host alias)"; return 1; }
    [ -z "$host" ] || [ "$host" = github.com ] \
      || { _forge_repo_no "$repo" "forge github is github.com - host: $host contradicts it"; return 1; }
    web_host=github.com ssh_host="${gh_alias:-github.com}"
    api="https://api.github.com/repos/$FORGE_URL_PATH"
  else
    [ "$FORGE_URL_HOST" != github.com ] \
      || { _forge_repo_no "$repo" "forge: forgejo, but '$url' is on github.com"; return 1; }
    [ -z "$gh_alias" ] || [ "$FORGE_URL_HOST" != "$gh_alias" ] \
      || { _forge_repo_no "$repo" "$FORGE_URL_HOST is this workspace's GitHub ssh alias (github.ssh_host), not a Forgejo host"; return 1; }
    url_web="$FORGE_URL_HOST${FORGE_URL_PORT:+:$FORGE_URL_PORT}"
    # Plain HTTP is a declaration, never a fallback: only `host: http://...`
    # on the repo itself, and only beside an ssh url (an https url already
    # says how its host is reached).
    case "$host" in
      http://*)  web_scheme=http; host="${host#http://}"
                 [ "$FORGE_URL_SCHEME" != https ] \
                   || { _forge_repo_no "$repo" "host: http://$host contradicts the https url '$url'"; return 1; } ;;
      https://*) host="${host#https://}" ;;
    esac
    host="${host%/}"
    if [ -n "$host" ]; then
      # An https url names the web host itself; only an ssh url may reach the
      # forge under another name (its alias).
      [ "$FORGE_URL_SCHEME" != https ] || [ "$url_web" = "$host" ] \
        || { _forge_repo_no "$repo" "host: $host contradicts the url's host $url_web"; return 1; }
      web_host="$host"
    elif [ "$FORGE_URL_SCHEME" = https ]; then web_host="$url_web"
    else web_host="$FORGE_URL_HOST"
    fi
    # A dotted host name: an undotted ssh host is an alias, and an alias
    # names no web or API endpoint.
    [[ "$web_host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+(:[0-9]+)?$ ]] \
      || { _forge_repo_no "$repo" "'$web_host' is not a web host name (an ssh alias?) - declare host: <the Forgejo web host> on the repo"; return 1; }
    [ "${web_host%%:*}" != github.com ] \
      || { _forge_repo_no "$repo" "host: github.com is GitHub, not Forgejo"; return 1; }
    case "$FORGE_URL_SCHEME" in https) ssh_host="${web_host%%:*}" ;; *) ssh_host="$FORGE_URL_HOST" ;; esac
    api="$web_scheme://$web_host/api/v1/repos/$FORGE_URL_PATH"
  fi
  jq -nc --arg p "$provider" --arg h "$web_host" --arg o "${FORGE_URL_PATH%%/*}" --arg r "${FORGE_URL_PATH#*/}" \
    --arg s "$ssh_host" --arg w "$web_scheme://$web_host/$FORGE_URL_PATH" --arg a "$api" \
    '{provider:$p, host:$h, owner:$o, repo:$r, ssh_host:$s, web_url:$w, api_url:$a}'
}
_forge_repo_no() { # <repo> <reason>
  printf "forge: repo '%s': %s\n" "$1" "$2" >&2
}

# The workspace a checkout belongs to. A herdr worktree lives OUTSIDE its
# workspace (~/.herdr/worktrees/...), so ws_current finds nothing from it - but
# its common git dir is the workspace's repos/<r>/.git, which does.
ws_of_checkout() { # <dir> -> wsdir, or fail
  local c; c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  ws_current "$(dirname "$c")"
}

# RELEASE: how this repo is released, if it is at all.
#
#   release:
#     workflow: release.yaml     # file name in .github/workflows/
#     input: bump                # the dispatch input's NAME
#     accepts: [major, minor, patch]   # or the literal word `semver`
#     tag: "v{version}"          # how the resulting tag is named
#     version_file: VERSION      # what `status` reads as "current"
#     changelog: changelog.d/    # fragment dir, for --dry-run's pending section
#
# The plane owns none of these semantics on purpose: products release in
# different ways (a bump input deriving the version from the newest tag, an
# exact version with a VERSION file, plain tags, nothing at all), so none is
# assumed. A repo with no block is NOT releasable, and says so first.
#
# A list value (`accepts`) comes back space separated so `case` and `for` both
# work on it without the caller learning jq.
ws_repo_release() { # <wsdir> <repo> <key>
  _yqr -r --arg n "$2" --arg k "$3" \
    '.repos // [] | map(select(.name == $n))[0].release[$k] // ""
     | if type == "array" then map(tostring) | join(" ") else tostring end' \
    "$1/workspace.yaml"
}

# Releasable means there is something to dispatch. A block carrying everything
# but a `workflow` names no run, so it is not a release declaration however
# much else it holds.
ws_repo_releasable() { # <wsdir> <repo>
  [ -n "$(ws_repo_release "$1" "$2" workflow)" ]
}

# SEED: the gitignored local files a worktree needs before it can RUN. A
# worktree is a fresh checkout, so every file git was told to ignore - the keys
# file, a built wasm directory - is simply absent. Declared per repo:
#
#   seed:
#     - apps/builder/.dev.vars                  # symlinked (the common case)
#     - { path: apps/pf/src/wasm, copy: true }   # copied, for what a link cannot be
#
# One entry per line as `<path>\t<link|copy>`; absent prints nothing. A plain
# string is a link because that is what a shared secret wants: edit it once in
# the checkout and every worktree sees it. `copy` exists for directories a
# build rewrites in place, where a link would write back into the checkout.
ws_repo_seed() { # <wsdir> <repo>
  _yqr -r --arg n "$2" '.repos // [] | map(select(.name == $n))[0].seed // []
    | .[]
    | if type == "string" then . + "\tlink"
      else ((.path // "") + (if .copy then "\tcopy" else "\tlink" end)) end' \
    "$1/workspace.yaml"
}

# PREVIEW: how to run this repo from a worktree, on ports nobody else holds.
#
#   preview:
#     cmd: "pnpm --filter builder dev"
#     env: { API_PORT: "{port}", UI_PORT: "{port+1}" }
#     url: "http://localhost:{port+1}"
#
# `{port}` and `{port+N}` are substituted by `cel preview`, which allocates
# the block. Values are returned RAW, placeholders and all: substitution needs
# the allocated base, which only the caller has.
ws_repo_preview() { # <wsdir> <repo> <cmd|url>
  _yqr -r --arg n "$2" --arg k "$3" \
    '.repos // [] | map(select(.name == $n))[0].preview[$k] // "" | tostring' \
    "$1/workspace.yaml"
}

ws_repo_preview_env() { # <wsdir> <repo> - one KEY=VALUE per line, raw
  _yqr -r --arg n "$2" '.repos // [] | map(select(.name == $n))[0].preview.env // {}
    | to_entries[] | "\(.key)=\(.value)"' "$1/workspace.yaml"
}

# PRODUCTS. A product is one or more repos with one orchestrator, so work that
# crosses repos of one system needs no extra hop. A repo named in no declared
# product is its own IMPLICIT product, in place, so a workspace without a
# `products:` block behaves as one orchestrator per repo.
#
# A repo named in two declared products is a config error that belongs to
# `cel doctor`, not here: these helpers just resolve the FIRST declaration so
# the same file always produces the same panes.

ws_product_names() { # <wsdir> - declared in file order, then implicit ones
  _yqr -r '(.products // []) as $ps
    | ([$ps[].repos // []] | flatten) as $used
    | (($ps | map(.name)) + ((.repos // [] | map(.name)) - $used))[]' \
    "$1/workspace.yaml"
}

ws_product_repos() { # <wsdir> <product> - an implicit product is its own repo
  local r
  r="$(_yqr -r --arg p "$2" '.products // [] | map(select(.name == $p))[0].repos // [] | .[]' \
    "$1/workspace.yaml")"
  [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
  printf '%s\n' "$2"
}

ws_product_of_repo() { # <wsdir> <repo> - its product, else the repo itself
  _yqr -r --arg n "$2" '.products // []
    | map(select((.repos // []) | index($n)))[0].name // $n | tostring' \
    "$1/workspace.yaml"
}

ws_product_declared() { # <wsdir> <product> - 0 declared, 1 implicit or unknown
  [ "$(_yqr -r --arg p "$2" '(.products // []) | map(select(.name == $p)) | length' \
    "$1/workspace.yaml")" != "0" ]
}

ws_product_get() { # <wsdir> <product> <key>
  _yqr -r --arg p "$2" --arg k "$3" \
    '.products // [] | map(select(.name == $p))[0][$k] // "" | tostring' \
    "$1/workspace.yaml"
}

# THE EFFECTIVE ORCHESTRATOR MODE FOR ONE PRODUCT, AND WHERE IT CAME FROM.
# `up`, `status`, the dry run and the steward all ask this and nothing else,
# so they cannot derive the mode by different routes and disagree.
#
# Precedence: products[].orchestrator, then layout.orchestrators, then the
# default. Any of auto|manual|none wins at each level - a product may opt IN,
# not only out. The source is returned beside the mode so a reader can tell
# which file said so.
ws_orchestrator_mode() { # <wsdir> <product> -> "<mode>\t<product|layout|default>"
  local own lay
  own="$(ws_product_get "$1" "$2" orchestrator)"
  case "$own" in auto|manual|none) printf '%s\tproduct' "$own"; return 0 ;; esac
  lay="$(ws_layout_declared "$1" orchestrators)"
  case "$lay" in auto|manual|none) printf '%s\tlayout' "$lay"; return 0 ;; esac
  printf '%s\tdefault' "$(ws_orchestrators_default)"
}

# HOW A PRODUCT IS BUILT. `solo`: one agent that plans, builds and ships
# itself, with whatever its own runtime offers - its own worktrees and
# subagents included. Not to be confused with ws_orchestrator_mode above,
# which says whether `cel ws up` starts the product's agent at all.
#
# Declared on the product (`products[].mode`) or, for an implicit product, on
# its repo (`repos[].mode`). Absent means solo. A legacy `mode: fleet` reads
# back as written so launchers can refuse it (fan-out is retired); any other
# value is printed as written too, for callers to refuse rather than guess.
ws_build_mode() { # <wsdir> <product> -> solo | fleet | <invalid value>
  local m
  if ws_product_declared "$1" "$2"; then
    m="$(ws_product_get "$1" "$2" mode)"
  else
    m="$(ws_repo_get "$1" "$2" mode)"
  fi
  printf '%s' "${m:-solo}"
}

# Where a solo agent keeps its own git worktrees (its role says so), and the
# ones that exist: a directory there is a worktree when it carries a `.git`
# file. Read by fleet (how many), and by gc (which may go).
ws_solo_dir() { printf '%s/.cel/solo/%s' "$1" "$2"; }   # <wsdir> <product>
ws_solo_worktrees() { # <wsdir> <product> -> one path per line
  local d
  for d in "$(ws_solo_dir "$1" "$2")"/*/; do
    [ -f "${d}.git" ] && printf '%s\n' "${d%/}"
  done
  return 0
}

# Where that product's orchestrator stands. A declared product has no checkout
# of its own - it is the directory ABOVE its repos' worktrees - so it gets a
# products/ dir; an implicit one keeps standing in its repo, unchanged.
ws_product_dir() { # <wsdir> <product>
  if ws_product_declared "$1" "$2"; then
    printf '%s' "$1/products/$2"
  else
    printf '%s' "$1/repos/$2"
  fi
}

# The single source for every injection surface: cel run and the rendered
# CLAUDE.md block both call this, so policy is worded exactly once. Every
# product is built solo, so the block describes the solo build. The optional
# product argument names the product (repos, worktree dir, mailbox); without
# it the block is worded for whichever product's agent reads it.
ws_policy_block() { # <wsdir> [product]
  local d="$1" product="${2:-}" name kind org tsys tadhoc merge pr r
  local p="${product:-<product>}"
  name="$(ws_name "$d")"; kind="$(ws_kind "$d")"; org="$(ws_org "$d")"
  tsys="$(ws_ticket "$d" system)"; tadhoc="$(ws_ticket "$d" adhoc)"
  merge="$(ws_policy "$d" merge)"; pr="$(ws_policy "$d" pr)"
  printf '## Workspace policy\n'
  printf -- '- workspace: %s (kind: %s, org: %s)\n' "$name" "${kind:-unset}" "${org:-unset}"
  if [ -n "$product" ]; then
    printf -- '- product: %s (repos: %s) - cross-repo sequencing inside this product is yours; there is no tier above you for it\n' \
      "$product" "$(ws_product_repos "$d" "$product" | paste -sd, - | sed 's/,/, /g')"
  fi
  printf -- '- build mode: solo - you build and ship this product yourself. Your own runtime is yours to use in full - your own git worktrees (under %s/.cel/solo/%s/), your subagents in parallel, several branches and PRs at once\n' \
    "$d" "$p"
  if [ "$tsys" = "none" ]; then
    printf -- '- tickets: none - never invent ticket references; ad-hoc refs look like %s\n' "${tadhoc:-AH-<yymmdd>}"
  elif [ "$tsys" = "linear" ]; then
    printf -- '- tickets: linear (use the linear skill; MCP tools if present, else `cel-linear`). ONE ticket per work package, and SEARCH BEFORE CREATE - never start work on a ticket someone else has In Progress. THE BRANCH NAME CARRIES THE TICKET ID (`<PREFIX>-<n>-<slug>`): Linear links a PR to its ticket from the branch name alone. Nothing moves your tickets for you: set In Progress when you start, In Review when the PR opens, and Done when it merges (`cel-linear state`). Ad-hoc refs (%s) are for throwaway work only\n' "${tadhoc:-unset}"
  else
    printf -- '- tickets: %s; ad-hoc refs look like %s\n' "${tsys:-unset}" "${tadhoc:-unset}"
  fi
  if [ "$merge" = "self" ]; then
    printf -- '- merge: self - land your own PR with `cel solo land <repo>#<n>` once its review has approved the current head and the required checks are green (it checks both, and merges only that head); never `gh pr merge`\n'
  else
    printf -- '- merge: humans-only - open a PR and stop; only humans merge\n'
  fi
  local pr_open; pr_open="$(ws_policy "$d" pr_open)"
  if [ "${pr_open:-draft}" = "ready" ]; then
    printf -- '- pr: %s, opened READY FOR REVIEW (never draft; a draft is invisible to the reviewer)\n' "${pr:-required}"
  else
    printf -- '- pr: %s, opened as a draft\n' "${pr:-required}"
  fi
  # Reviewers always run on pi (lib/run.sh: idle inbox delivery), whatever
  # review.runtime says, so the policy names pi - not the ignored field.
  local rrt rmodel
  rrt="$(ws_review "$d" runtime)"; rmodel="$(ws_review "$d" model)"
  if [ -n "$rrt$rmodel" ]; then
    printf -- '- pr review: after opening a PR, start its reviewer with `cel run reviewer --repo <repo> --pr <n>` (pi%s, one pane per PR); it sends findings to you (`%s-orch`). Fix them on the same branch, push, and tell it the new head to re-review\n' \
      "${rmodel:+ model $rmodel}" "$p"
    if [ "$(ws_review_post "$d")" = "github" ]; then
      printf -- '- review verdicts: recorded by the reviewer with `cel solo review <repo>#<n> <approved|changes> --head <reviewed-commit-sha> --by <reviewer-alias> --note "<one line>"`, reported by inbox, and posted as a GitHub review\n'
    else
      printf -- '- review verdicts: recorded by the reviewer with `cel solo review <repo>#<n> <approved|changes> --head <reviewed-commit-sha> --by <reviewer-alias> --note "<one line>"` and reported by inbox; GitHub is **not** posted to\n'
    fi
  fi
  local lt rpr
  for r in $(ws_repo_names "$d"); do
    lt="$(ws_repo_get "$d" "$r" linear_team)"
    rpr=""
    [ "$(ws_repo_pr "$d" "$r")" != none ] \
      || rpr='; pr: none - commit on a branch, then rebase onto origin/main and push to main (fast-forward only, never force); no PR'
    printf -- '- repo %s: branch prefix %s, gate `%s`%s%s\n' \
      "$r" "$(ws_repo_get "$d" "$r" prefix)" "$(ws_repo_get "$d" "$r" gate)" \
      "${lt:+, linear team $lt}" "$rpr"
  done
  # What this workspace has learned, budgeted (lib/learn.sh). Rendered by a
  # CHILD `cel learn render` rather than by sourcing learn.sh here: learn.sh
  # sources this file for ws_current, and a source cycle for a paragraph is a
  # bad trade. Empty output when there is nothing to say.
  local learned
  learned="$("$CEL_ROOT/bin/cel" learn render --dir "$d" 2>/dev/null || true)"
  [ -z "$learned" ] || printf '\n%s' "$learned"
}

ws_render_role() { # <wsdir> <rolefile> [product]
  [ -f "$2" ] || die "role file not found: $2"
  cat "$2"; printf '\n'; ws_policy_block "$1" "${3:-}"
}

# Replace-or-append the marked block. Body travels via the environment, not
# awk -v: -v would interpret backslash escapes inside the rendered text.
ws_render_claude_block() { # <wsdir> <targetdir>
  local f="$2/CLAUDE.md" block
  block="$(BODY="$(ws_policy_block "$1")" \
    awk '{ if ($0 == "{{POLICY_BLOCK}}") printf "%s\n", ENVIRON["BODY"]; else print }' \
    "$CEL_ROOT/templates/CLAUDE.md.tmpl")"
  if [ -f "$f" ] && grep -q 'cel:policy:begin' "$f"; then
    BLK="$block" awk '
      /cel:policy:begin/ { inblk=1; printf "%s\n", ENVIRON["BLK"]; next }
      /cel:policy:end/   { inblk=0; next }
      !inblk { print }' "$f" > "$f.cel-tmp" && mv "$f.cel-tmp" "$f"
  else
    { [ -f "$f" ] && cat "$f" && printf '\n'; printf '%s\n' "$block"; } \
      > "$f.cel-tmp" && mv "$f.cel-tmp" "$f"
  fi
}

# Workspace skills are scoped: linked into this workspace's checkouts only, and
# the links are gitignored - they point into $HOME and must never be committed.
ws_link_skills() { # <wsdir> <targetdir>
  local s t="$2/.claude/skills"
  mkdir -p "$t"
  # Self-heal: a skill deleted from the workspace must take its repo links
  # with it, or the dangling link keeps shadowing the plane copy of the same
  # name. Only links into THIS workspace's skills dir are ours to prune.
  for s in "$t"/*; do
    [ -L "$s" ] && [ ! -e "$s" ] || continue
    case "$(readlink "$s")" in "$1"/skills/*) rm -f "$s";; esac
  done
  for s in "$1"/skills/*/; do
    [ -f "$s/SKILL.md" ] || continue
    ln -sfn "${s%/}" "$t/$(basename "${s%/}")"
  done
  grep -qxF '.claude/skills' "$2/.gitignore" 2>/dev/null \
    || printf '.claude/skills\n' >> "$2/.gitignore"
}
