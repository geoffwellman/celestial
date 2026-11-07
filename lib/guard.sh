# shellcheck shell=bash
# Read-only coordinators, guarded builders.
#
# Coordinators (core, root, a cwd-derived orchestrator) read, plan and ask;
# they never write to a repository. Builders are solo agents: one per product,
# they write, open PRs and land them with `cel solo land`, which checks review
# of the exact head and CI. Reviewers stand outside any workspace (`other`).
#
# The guard limits the CAPABILITY, so a bad prompt - a misread request, a
# confusing inbox message, an invented instruction - produces a refusal, not
# a write.
#
# Sourced by tools/hooks/orchestrator-guard.sh (claude PreToolUse) and by the
# tests. Sources no other library, so the hook stays fast and cannot be taken
# down by unrelated library breakage.
[ -n "${_CEL_GUARD:-}" ] && return 0
_CEL_GUARD=1

# Which role a process is playing, from where it is standing. The SAME
# derivation lib/inbox.sh uses for mail identity, duplicated on purpose: the
# guard must not import inbox state to decide whether to block a command.
#   the core dir                  core         (coordinates; orchestrator-class,
#                                 minus the product agent's verbs)
#   <ws>/repos/<repo>[/...]       orchestrator (reads; the solo agent builds)
#   <ws>/products/<p>[/...]       orchestrator (same powers, same refusals,
#                                 different standpoint)
#   <ws>[/...not under repos]     root
#   anywhere else                 other        (not the plane's concern)
#
# CEL_ROLE=core in the environment says so outright, because core's cwd is a
# plain directory a human could also be standing in - path alone is not
# enough to be sure. CEL_ROLE=solo does the same for a solo agent: it stands
# exactly where an orchestrator stands (the product's directory), so only the
# launch can say which of the two it is. CEL_ROLE=member is a team member
# (`cel run member`): it stands in its team's directory or worktree, which
# path alone would read as root.
guard_role_of() { # <cwd>
  local p="$1"
  # A console launched before its retirement carries CEL_ROLE=console and
  # stands in the old console dir; it is guarded as core, never as `other`.
  case "${CEL_ROLE:-}" in core|console) printf core; return 0;; esac
  # worker|scout|spike are retired fan-out roles; a process still carrying one
  # stays restricted as solo, never `other`.
  case "${CEL_ROLE:-}" in solo|worker|scout|spike) printf solo; return 0;; esac
  case "${CEL_ROLE:-}" in member) printf member; return 0;; esac
  local core="${CEL_CORE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/core}"
  local cons="${XDG_DATA_HOME:-$HOME/.local/share}/cel/console"
  case "$p" in "$core"|"$core"/*|"$cons"|"$cons"/*) printf core; return 0;; esac
  local d="$p"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/workspace.yaml" ]; then
      case "$p" in
        "$d"/repos/*|"$d"/products/*) printf orchestrator;;
        *)            printf root;;
      esac
      return 0
    fi
    d="${d%/*}"
  done
  printf other
}

# allow | deny <reason>.
#
# The deny list is EXPLICIT VERBS paired with the thing they mutate, not a
# heuristic about "dangerous-looking" commands. The cost of a false deny is a
# coordinator that has to hand a typo fix to the solo agent; the cost of a
# false allow is an unreviewed write. When in doubt the list errs towards deny,
# and the refusal always says what to do instead.

# An orchestrator owns the STATE of its own checkout, never its authorship:
# nobody else stands over that checkout, so keeping `main` current in it (and
# moving onto a PR branch to run it locally, and back) is its job. Moving
# between refs that ALREADY EXIST creates nothing and discards nothing.
#
# The line: exactly one ref, no flag that creates (-b/-B/-c/-C/--orphan/
# --track/--detach), no `--` or path (that discards working-tree state), and
# nothing that reaches into ANOTHER checkout (-C, --git-dir, --work-tree, or
# a herdr worktree).
_guard_orch_owns_checkout() { # <command> -> 0 = allow
  local c="$1"
  c="${c#"${c%%[![:space:]]*}"}"
  # Reaching into another checkout is never this checkout's state.
  case "$c" in *" -C "*|*--git-dir*|*--work-tree*|*.herdr/worktrees*) return 1;; esac
  # The verb has to BE the command: in a chain, half of it goes unexamined.
  case "$c" in *"&"*|*"|"*|*";"*|*'`'*|*'$('*|*">"*|*"<"*) return 1;; esac
  local -a t
  read -r -a t <<<"$c"
  local n=${#t[@]}
  case "${t[0]:-} ${t[1]:-}" in
    "git checkout"|"git switch")
      [ "$n" -eq 3 ] || return 1
      local ref="${t[2]}"
      case "$ref" in -*|.|..|*/) return 1;; esac
      # An existing path is a discard (`git checkout src/x.ts`), not a move.
      [ -e "$ref" ] && return 1
      return 0;;
    "git branch")
      # Lowercase -d only: it refuses to delete unmerged work. -D/-m/-M do not.
      [ "$n" -eq 4 ] && [ "${t[2]}" = "-d" ] || return 1
      case "${t[3]}" in -*) return 1;; esac
      return 0;;
    "gh pr")
      case "${t[2]:-}" in
        checkout)
          # Explicit so that a later tightening of the gh rules below cannot
          # silently regress it.
          [ "$n" -eq 4 ] || return 1
          case "${t[3]}" in -*) return 1;; esac
          return 0;;
        edit)
          # A label is a workflow signal (preview deploy, triage), not PR
          # content. Any other flag is editing somebody else's pull request.
          [ "$n" -ge 5 ] || return 1
          case "${t[3]}" in -*) return 1;; esac
          local i=4
          while [ "$i" -lt "$n" ]; do
            case "${t[$i]}" in
              --add-label|--remove-label)
                i=$((i+1)); [ "$i" -lt "$n" ] || return 1
                case "${t[$i]}" in -*) return 1;; esac;;
              --add-label=*|--remove-label=*) ;;
              *) return 1;;
            esac
            i=$((i+1))
          done
          return 0;;
      esac
      return 1;;
  esac
  return 1
}

# THE COMMANDS A SHELL LINE WOULD RUN, one per line, each reduced to the verb
# that would execute. A substring test on the raw text is evaded by spacing,
# quotes, global options before the verb or a chain (`cd x && ...`), and
# refuses `grep "cel solo land"`. So the line is split where a new command
# starts (`;`, `&`, `|`, `(`, `)`, `$(`, backtick), quotes are dropped,
# whitespace is collapsed, and from the front of each piece go: env
# assignments, wrappers (bash/sh -c, env, command, exec, nohup, time, xargs,
# timeout N), a path in front of cel/gh/herdr/tea/curl, and the
# global options between a tool and its verb (`-C`/`--workspace` for cel,
# `-R`/`--repo` for gh). The rules then match the START of a piece only.
#
# A TRIPWIRE, NOT A SANDBOX (docs/architecture.md): a variable holding the
# command (`c=cel; $c solo land`) or a script file still runs. What this
# stops is the plausible mistake, spelled any of the ways an agent writes it.
_guard_segments() { # <command> -> one normalised command per line
  printf '%s' "$1" | tr '\t\r\n' '   ' \
    | sed -E 's/\$\(/;/g; s/[`();|&]+/\n/g' \
    | sed -E "s/[\"']//g; s/ +/ /g; s/^ //; s/ $//" \
    | sed -E ':a
        s#^[A-Za-z_][A-Za-z0-9_]*=[^ ]* ##; ta
        s#^(bash|sh|env|command|exec|nohup|time|xargs)( -[A-Za-z]+)* ##; ta
        s#^timeout( -[A-Za-z]+( [^ ]+)?)* [0-9.]+[smhd]? ##; ta' \
    | sed -E 's#^[^ ]*/(cel|gh|herdr|tea|curl|git)( |$)#\1\2#' \
    | sed -E ':b
        s#^cel (-C [^ ]+|--workspace[= ][^ ]+)( |$)#cel\2#; tb
        s#^gh (-R [^ ]+|--repo[= ][^ ]+)( |$)#gh\2#; tb'
}

# Does any command in the line start with one of these (extended) patterns?
_guard_starts() { # <command> <ERE...> -> 0 when one does
  local cmd="$1"; shift
  local seg p
  while IFS= read -r seg || [ -n "$seg" ]; do
    for p in "$@"; do
      [[ "$seg" =~ ^($p)( |$) ]] && return 0
    done
  done < <(_guard_segments "$cmd")
  return 1
}

# A FORGE CHANGED BY HAND: curl writing to a Forgejo (/api/v1/) or GitHub
# (api.github.com) API, `tea api` with anything but a plain GET, or one of
# tea's write verbs. `cel forge` and the land doors are the sanctioned paths;
# these are the same writes with every check skipped.
_guard_forge_raw_write() { # <command> -> 0 when a piece writes to a forge by hand
  local seg
  while IFS= read -r seg || [ -n "$seg" ]; do
    case "$seg" in
      curl|curl\ *) _guard_curl_writes "$seg" && return 0 ;;
      tea\ *) _guard_tea_writes "$seg" && return 0 ;;
    esac
  done < <(_guard_segments "$1")
  return 1
}

# curl at a forge API that writes: a request body in any spelling (-d@x, -dX,
# --data*, --json, -F/--form*, -T/--upload-file), a method other than GET or
# HEAD in any spelling (-X M, -XM, -sXM, --request[=]M), or options read from
# a file (-K/--config), which could carry either. Short options are walked
# letter by letter: one that takes a value ends its group (`-oFILE`).
_guard_curl_writes() { # <segment>
  local seg="$1" w c i j n method="" write=0
  [[ "$seg" == */api/v1/* || "$seg" == *api.github.com* ]] || return 1
  local -a t; read -r -a t <<<"$seg"; n=${#t[@]}
  for ((i = 1; i < n; i++)); do
    w="${t[i]}"
    case "$w" in
      --request=*) method="${w#--request=}" ;;
      --request) method="${t[i+1]:-}" ;;
      --data|--data[=-]*|--json|--json=*|--form|--form[=-]*|--upload-file|--upload-file=*|--config|--config=*) write=1 ;;
      --*) ;;
      -?*)
        for ((j = 1; j < ${#w}; j++)); do
          c="${w:j:1}"
          case "$c" in
            d|F|T|K) write=1; break ;;
            X) method="${w:j+1}"; [ -n "$method" ] || method="${t[i+1]:-}"; break ;;
            [HouAebcxwrmEyYzCDPQtU]) break ;;
          esac
        done ;;
    esac
  done
  [ "$write" = 0 ] || return 0
  case "${method^^}" in ""|GET|HEAD) return 1 ;; esac
  return 0
}

# tea: `tea api` unless it is a plain GET with no body, and the write verbs
# of pulls, releases, repos and branches - read past tea's own options (and
# the values of the ones that take one) to find the verb.
_guard_tea_writes() { # <segment>
  local -a t words=(); read -r -a t <<<"$1"
  local i n=${#t[@]} w
  for ((i = 1; i < n; i++)); do
    w="${t[i]}"
    case "$w" in
      --repo|-r|--login|-l|--remote|-R|--output|-o) i=$((i + 1)) ;;
      -*) ;;
      *) words+=("$w") ;;
    esac
  done
  case "${words[0]:-}" in
    api)
      local method=""
      for ((i = 1; i < n; i++)); do
        w="${t[i]}"
        case "$w" in
          -X|--method) method="${t[i+1]:-}" ;;
          --method=*) method="${w#--method=}" ;;
          -X?*) method="${w#-X}" ;;
          -f|-F|-d|--field|--field=*|--raw-field|--raw-field=*|--data|--data=*|--input|--input=*|-f?*|-F?*|-d?*) return 0 ;;
        esac
      done
      case "${method^^}" in ""|GET) return 1 ;; esac
      return 0 ;;
    pr|pulls|pull)
      case "${words[1]:-}" in merge|m|close|create|c|reopen|open|edit|e|approve|lgtm|a|reject|review) return 0 ;; esac ;;
    release|releases|r)
      case "${words[1]:-}" in create|c|delete|rm|edit|e) return 0 ;; esac ;;
    repo|repos)
      case "${words[1]:-}" in create|fork|delete|migrate|edit) return 0 ;; esac ;;
    branch|branches|b)
      case "${words[1]:-}" in protect|P|unprotect|U) return 0 ;; esac ;;
  esac
  return 1
}

# THE FORGE TOKEN IS NOBODY'S TO READ: ~/.config/cel/forge holds the API key
# lib/forge.sh sends to Forgejo. Any command naming that directory is refused
# for every role - reading, copying, listing, rewriting alike. A tripwire like
# the rest: a command that reaches it without naming it still runs.
_guard_names_forge_token() { # <command-or-path>
  [[ "$1" =~ cel/forge([^A-Za-z0-9_.-]|$) ]]
}
_GUARD_TOKEN_DENY='deny the forge API token (~/.config/cel/forge) is read by `cel forge` and the land doors only - no agent reads, copies or writes it'

# A TEAM MEMBER'S LAUNCH TOKEN IS NOBODY'S TO READ EITHER: cel team add writes
# <ws>/.cel/teams/<feature>/launch/<alias>.token and `cel run member` spends
# it, both inside one process. An agent that could read or write one could
# start a member past cel team add's admission. Matched on the literal
# spelling AND on every path a command names once resolved against the
# directories it may run in (_guard_walk, _guard_resolve): a member stands in
# its team directory, where `launch/x`, `members/../launch` and a symlink all
# reach the same files.
_guard_names_launch_token() { # <command-or-path> - the literal spelling
  [[ "$1" =~ \.cel/teams/[^/[:space:]]+/launch([^A-Za-z0-9_.-]|$) ]]
}
_guard_launch_path() { # <absolute path> -> 0 when it is a launch dir or in one
  [[ "$1" =~ /\.cel/teams/[^/]+/launch(/|$) ]]
}
_GUARD_LAUNCH_TOKEN_DENY='deny team launch tokens (<ws>/.cel/teams/<feature>/launch/) are written by cel team add and spent by its launcher only - no agent reads, lists or writes them'

# PATHS ARE COMPARED RESOLVED. _guard_norm makes a word absolute against a
# base and folds `.`, `..` and `//` without touching the disk, into _GN. A word
# whose value is not in the text - a variable, a glob, ~user, a substitution -
# has none: rc 1, and callers that need it refuse. _guard_resolve then follows
# existing symlinks (realpath -m), every path in one call.
_guard_norm() { # <base> <word> -> 0 and _GN, or 1
  local base="$1" w="$2" p part
  local -a out=()
  _GN=""
  case "$w" in ''|*'$'*|*'`'*|*'*'*|*'?'*|*'['*|*'{'*) return 1 ;; esac
  case "$w" in '~') w="$HOME" ;; '~/'*) w="$HOME/${w#'~/'}" ;; '~'*) return 1 ;; esac
  case "$w" in
    /*) p="$w" ;;
    *) [ -n "$base" ] && [ "$base" != '?' ] || return 1; p="$base/$w" ;;
  esac
  local IFS=/
  for part in $p; do
    case "$part" in
      ''|.) ;;
      ..) [ "${#out[@]}" -eq 0 ] || out=("${out[@]:0:${#out[@]}-1}") ;;
      *) out+=("$part") ;;
    esac
  done
  _GN="/${out[*]}"
}
_guard_resolve() { # <absolute path...> -> each with symlinks followed, one per line
  [ $# -gt 0 ] || return 0
  realpath -m -- "$@" 2>/dev/null || printf '%s\n' "$@"
}

# EVERY COMMAND IN THE LINE WITH THE DIRECTORIES IT MAY RUN IN: the pane's
# (_GUARD_CWD) and every directory a cd/pushd before it named - from each
# earlier candidate, and the earlier ones kept, since a subshell's cd may have
# ended. `?` is a directory that cannot be told (cd -, cd $X). File-descriptor
# duplications (2>&1, &>) are folded first so their `&` does not split a
# command. Sets _GW_SEG[i] and _GW_DIRS[i] (tab-separated).
_guard_walk() { # <command>
  local seg w d
  local -a dirs=("${_GUARD_CWD:-$PWD}") t nds
  _GW_SEG=(); _GW_DIRS=()
  while IFS= read -r seg || [ -n "$seg" ]; do
    [ -n "$seg" ] || continue
    _GW_SEG+=("$seg")
    _GW_DIRS+=("$(IFS=$'\t'; printf '%s' "${dirs[*]}")")
    case "$seg" in
      cd|"cd "*|pushd|"pushd "*|popd|"popd "*)
        read -r -a t <<< "$seg"
        w="${t[1]:-~}"; case "$w" in -[LPe@]) w="${t[2]:-~}" ;; esac
        [ "${t[0]}" != popd ] || w=-
        nds=()
        for d in "${dirs[@]}"; do
          if [ "$w" != - ] && _guard_norm "$d" "$w"; then nds+=("$_GN"); else nds+=('?'); fi
        done
        dirs+=("${nds[@]}") ;;
    esac
  done < <(_guard_segments "$(printf '%s' "$1" | sed -E 's/[0-9]*>&[0-9-]+/ /g; s/\|&/|/g; s/&>/>/g')")
}

# Does any word of the command, resolved, name a launch directory?
_guard_cmd_reaches_launch() { # <command> -> 0 when it does
  _guard_names_launch_token "$1" && return 0
  local i w c d r
  local -a t ds cands abs=()
  _guard_walk "$1"
  for i in "${!_GW_SEG[@]}"; do
    IFS=$'\t' read -r -a ds <<< "${_GW_DIRS[i]}"
    read -r -a t <<< "${_GW_SEG[i]}"
    for w in "${t[@]}"; do
      cands=("$w")
      [[ "$w" != *=* ]] || cands+=("${w#*=}")
      [[ "$w" != *[\<\>]* ]] || cands+=("${w##*[<>]}")
      for c in "${cands[@]}"; do
        [ -n "$c" ] && [[ "$c" != -* ]] || continue
        for d in "${ds[@]}"; do
          _guard_norm "$d" "$c" && abs+=("$_GN")
        done
      done
    done
  done
  [ "${#abs[@]}" -gt 0 ] || return 1
  for r in "${abs[@]}"; do _guard_launch_path "$r" && return 0; done
  while IFS= read -r r; do _guard_launch_path "$r" && return 0; done < <(_guard_resolve "${abs[@]}")
  return 1
}
_guard_path_reaches_launch() { # <file path> -> 0 when it is in a launch dir
  _guard_names_launch_token "$1" && return 0
  _guard_norm "${_GUARD_CWD:-$PWD}" "$1" || return 1
  _guard_launch_path "$_GN" || _guard_launch_path "$(_guard_resolve "$_GN")"
}

# A GIT WRITE anywhere in the line. `git -C <dir> commit`, `git --git-dir=x
# push`, `git -c k=v merge`: the verb is no longer adjacent to `git`, so those
# options are stripped before matching. Callers that care WHERE the write
# lands look at the original command, since -C is exactly how a command
# reaches into another checkout.
_guard_git_writes() { # <command> -> 0 when it writes to a git repository
  local norm
  norm="$(printf '%s' "$1" | sed -E 's/git( +-C +[^ ]+| +--git-dir=[^ ]+| +--work-tree=[^ ]+| +-c +[^ ]+)+/git/g')"
  case "$norm" in
    *git\ commit*|*git\ push*|*git\ merge*|*git\ rebase*|*git\ reset*|*git\ revert*|\
    *git\ cherry-pick*|*git\ am\ *|*git\ apply*|*git\ stash*|*git\ checkout*|*git\ switch*|\
    *git\ restore*|*git\ add\ *|*git\ rm\ *|*git\ mv\ *|*git\ tag\ *|*git\ worktree\ *|\
    *git\ branch\ -[dDmM]*|*git\ branch\ --delete*|*git\ branch\ --move*|*git\ clean*) return 0;;
  esac
  return 1
}

# A SOLO AGENT IS THE BUILDER: it edits, commits, pushes, opens PRs, makes its
# own git worktrees and runs its own subagents. What it does NOT do is start
# other Celestial agents or panes (a reviewer for its own PR excepted), review
# its own PR, or merge by hand: the solo merge door is `cel solo land`, which
# checks review of the exact head and CI.
_guard_solo() { # <command> -> allow | deny <reason>
  if _guard_starts "$1" 'cel run (orchestrator|root|console|core|solo)' 'cel (core|console)' 'herdr agent start' 'herdr worktree (create|open)'; then
    printf 'deny a solo agent starts no other Celestial agents or panes (only `cel run reviewer` for its own PR)'
    return 0
  fi
  if _guard_starts "$1" 'cel solo review'; then
    printf 'deny a solo agent does not review its own PR - its reviewer records the verdict'
    return 0
  fi
  if _guard_starts "$1" 'gh pr merge' 'gh api .*pulls/[0-9]+/merge' 'tea (pr|pulls|pull) (merge|m)' 'curl .*/pulls/[0-9]+/merge[^ ]*'; then
    printf 'deny a solo agent merges through `cel solo land <repo>#<pr>`, which checks policy, review of the exact head and CI before it merges'
    return 0
  fi
  # Nor does it change its forge by hand at all - close, delete, branch
  # protection, merge: `cel forge` opens PRs and `cel solo land` merges them.
  if _guard_forge_raw_write "$1"; then
    printf 'deny a solo agent changes its forge only through `cel forge` and `cel solo land`, never curl at its API or tea'
    return 0
  fi
  printf allow
}

# CORE COORDINATES; IT DOES NOT BUILD. It is orchestrator-class (every
# repository and GitHub write an orchestrator is refused, it is refused too),
# and on top of that the verbs that belong to a PRODUCT's agent are refused
# here, before guard_classify's blanket allow of `cel`: landing and review
# verdicts, starting reviewers, and the box's own configuration and release
# (`cel mode` is core's one config write, and it is a `cel` command, so it
# passes).
_guard_core() { # <command> -> deny <reason>, or nothing
  if _guard_starts "$1" 'cel solo (land|review)' 'cel spike'; then
    printf 'deny core coordinates; the product'"'"'s own agent builds, reviews and lands - ask it: cel inbox send <product>-orch "<what you want>" --workspace <w>'
    return 0
  fi
  if _guard_starts "$1" 'cel run (reviewer|root)' 'herdr agent start' 'herdr worktree (create|open|remove)'; then
    printf 'deny core starts product agents only (cel run orchestrator --product <p> --workspace <w>, add --restart to relaunch one); reviewers are the product agent'"'"'s'
    return 0
  fi
  if _guard_starts "$1" 'cel (learn|release|promote|update|setup)'; then
    printf 'deny core'"'"'s only configuration write is cel mode; box configuration, learnings and releases are the owner'"'"'s (or the celestial product agent'"'"'s)'
    return 0
  fi
}

# Shell writes to files under repos/ - the spellings an agent uses.
_guard_shell_edits_repos() { # <command> -> 0 when it edits under repos/
  case "$1" in
    *sed\ -i*repos/*|*perl\ -pi*repos/*|*\>\ *repos/*|*\>\>\ *repos/*|*tee\ *repos/*|\
    *rm\ *repos/*|*mv\ *repos/*|*cp\ *repos/*|*touch\ *repos/*|*mkdir\ *repos/*|*chmod\ *repos/*|\
    *truncate\ *repos/*|*install\ *repos/*|*rsync\ *repos/*|*ln\ *repos/*) return 0;;
  esac
  return 1
}

# ── team members (CEL_ROLE=member; lib/run.sh `cel run member`) ─────────────
# A member is scoped by its launch: CEL_TEAM (the feature), CEL_TEAM_ROLE,
# CEL_TEAM_MEMBER (its alias), CEL_WORKSPACE and, for a builder,
# CEL_TEAM_BRANCH. Without a whole scope everything is refused.
#
# A BUILDER writes its own worktree (<team>/wt/<alias>) and nothing else - a
# shell write may also go to /tmp - commits there, and pushes ONLY
# `git push origin <its branch>` (or HEAD:<its branch>). It opens no PR and
# lands nothing: the lead integrates. Every OTHER role reads repositories and
# writes only <team>/artifacts/<role>/ and <team>/notes/<alias>/ (a product
# member also brief.md and acceptance.yaml); team.json, events, verdicts,
# packets, contracts and launch/ change only through `cel team` verbs.
# No member merges, lands, starts or stops an agent or pane, reads a token or
# writes to a forge by hand, and git runs only from a list of known verbs: an
# unknown one may be an alias for anything.
_GUARD_TEAM_READONLY_ROLES=' product design qa platform release analyst '
_GUARD_MEMBER_NO_SCOPE='deny a team member without a whole launch scope (CEL_TEAM, CEL_TEAM_ROLE, CEL_TEAM_MEMBER, CEL_WORKSPACE, and a builder'"'"'s CEL_TEAM_BRANCH) has no scope - ask the lead to retire it and add it again (cel team add)'

_guard_member_scope() { # -> 0 and _GM_* set, or 1
  _GM_TEAM="${CEL_TEAM:-}" _GM_ROLE="${CEL_TEAM_ROLE:-}" _GM_ME="${CEL_TEAM_MEMBER:-}" _GM_BRANCH="${CEL_TEAM_BRANCH:-}"
  [[ "$_GM_TEAM" =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]] && [[ "$_GM_ME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    && [[ "${CEL_WORKSPACE:-}" == /* ]] || return 1
  if [ "$_GM_ROLE" = builder ]; then
    [[ "$_GM_BRANCH" =~ ^team/"$_GM_TEAM"/[A-Za-z0-9._-]+$ ]] || return 1
  else
    [[ "$_GUARD_TEAM_READONLY_ROLES" == *" $_GM_ROLE "* ]] || return 1
  fi
  local -a r
  mapfile -t r < <(_guard_resolve "$CEL_WORKSPACE/.cel/teams/$_GM_TEAM" "$CEL_WORKSPACE/.cel/teams/$_GM_TEAM/wt/$_GM_ME" "$CEL_WORKSPACE")
  _GM_TDIR="${r[0]:-}" _GM_WT="${r[1]:-}" _GM_WS="${r[2]:-}"
  [ -n "$_GM_TDIR" ] && [ -n "$_GM_WT" ] && [ -n "$_GM_WS" ]
}

# gh api with a write: a non-GET method or a request body.
_guard_gh_api_writes() { # <command>
  local seg w method="" i n
  while IFS= read -r seg || [ -n "$seg" ]; do
    case "$seg" in "gh api"|"gh api "*) ;; *) continue ;; esac
    local -a t; read -r -a t <<< "$seg"; n=${#t[@]}
    for ((i = 2; i < n; i++)); do
      w="${t[i]}"
      case "$w" in
        -X|--method) method="${t[i+1]:-}" ;;
        --method=*) method="${w#--method=}" ;;
        -X?*) method="${w#-X}" ;;
        -f|-F|--field|--field=*|--raw-field|--raw-field=*|--input|--input=*|-f?*|-F?*) return 0 ;;
      esac
    done
    case "${method^^}" in ""|GET) ;; *) return 0 ;; esac
  done < <(_guard_segments "$1")
  return 1
}

# May this member write this (absolute, resolved) path? <how>: tool for the
# native edit tools, bash for a shell write.
_guard_member_may_write() { # <path> <tool|bash>
  local p="$1"
  if [ "$2" = bash ]; then
    case "$p" in /dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/fd/*) return 0 ;; esac
  fi
  if [ "$_GM_ROLE" = builder ]; then
    case "$p" in
      "$_GM_WT/.git"|"$_GM_WT/.git/"*) return 1 ;;
      "$_GM_WT"|"$_GM_WT/"*) return 0 ;;
    esac
    # Scratch, but never the workspace - which may itself sit under /tmp.
    if [ "$2" = bash ]; then
      case "$p" in "$_GM_WS"|"$_GM_WS/"*) return 1 ;; /tmp/*|"${TMPDIR:-/tmp}"/*) return 0 ;; esac
    fi
    return 1
  fi
  case "$p" in
    "$_GM_TDIR/artifacts/$_GM_ROLE"|"$_GM_TDIR/artifacts/$_GM_ROLE/"*) return 0 ;;
    "$_GM_TDIR/notes/$_GM_ME"|"$_GM_TDIR/notes/$_GM_ME/"*) return 0 ;;
  esac
  if [ "$_GM_ROLE" = product ]; then
    case "$p" in "$_GM_TDIR/brief.md"|"$_GM_TDIR/acceptance.yaml") return 0 ;; esac
  fi
  return 1
}
_guard_member_where() { # -> where this member may write, for a refusal
  if [ "$_GM_ROLE" = builder ]; then
    printf 'a builder writes only in its own worktree, %s (a shell write also /tmp)' "$_GM_WT"
  else
    printf 'a %s team member writes only under %s/artifacts/%s/ and %s/notes/%s/%s - team.json, events, verdicts, packets, contracts and launch/ change only through cel team verbs' \
      "$_GM_ROLE" "$_GM_TDIR" "$_GM_ROLE" "$_GM_TDIR" "$_GM_ME" "$([ "$_GM_ROLE" != product ] || printf ' (and brief.md, acceptance.yaml)')"
  fi
}

# WHAT A SHELL COMMAND WRITES: its redirection targets and the file
# arguments of the commands that write files. `?` = it writes, but where
# cannot be told from the text (wget without -O, patch, tar x, unzip).
# Interpreters (python -c, node -e, a script) are not parsed: a tripwire.
_guard_seg_targets() { # <segment> -> one word per line
  local -a t a=() args pos
  read -r -a t <<< "$1"
  local i n=${#t[@]} w pre post cmd tgt inplace script
  for ((i = 0; i < n; i++)); do
    w="${t[i]}"
    if [[ "$w" == *'>'* ]]; then
      pre="${w%%>*}"; post="${w#*>}"; post="${post#>}"; post="${post#|}"
      [[ "$pre" =~ ^[0-9]*$ ]] || a+=("$pre")
      if [ -z "$post" ]; then i=$((i + 1)); post="${t[i]:-?}"; fi
      printf '%s\n' "$post"
    elif [[ "$w" == *'<'* ]]; then
      pre="${w%%<*}"; [ -z "$pre" ] || a+=("$pre")
      [ -n "${w##*<}" ] || i=$((i + 1))
    else
      a+=("$w")
    fi
  done
  [ "${#a[@]}" -gt 0 ] || return 0
  cmd="${a[0]##*/}"; args=("${a[@]:1}"); pos=(); n=${#args[@]}
  case "$cmd" in
    tee)
      for w in "${args[@]}"; do [[ "$w" == -* ]] || printf '%s\n' "$w"; done ;;
    cp|mv|install|ln|rsync)
      tgt=""
      for ((i = 0; i < n; i++)); do
        w="${args[i]}"
        case "$w" in
          -t|--target-directory) tgt="${args[i+1]:-?}"; i=$((i + 1)) ;;
          --target-directory=*) tgt="${w#*=}" ;;
          -S|--suffix|-m|--mode|-o|--owner|-g|--group) i=$((i + 1)) ;;
          -*) ;;
          *) pos+=("$w") ;;
        esac
      done
      if [ -n "$tgt" ]; then printf '%s\n' "$tgt"
      elif [ "${#pos[@]}" -ge 2 ]; then printf '%s\n' "${pos[${#pos[@]}-1]}"
      else printf '?\n'; fi ;;
    rm|rmdir|touch|mkdir|truncate|unlink|shred)
      for ((i = 0; i < n; i++)); do
        w="${args[i]}"
        case "$w" in
          -s|--size|-m|--mode|-r|--reference|-n|--iterations) i=$((i + 1)) ;;
          -*) ;;
          *) printf '%s\n' "$w" ;;
        esac
      done ;;
    chmod|chown|chgrp)
      for w in "${args[@]}"; do [[ "$w" == -* ]] || pos+=("$w"); done
      [[ " ${args[*]} " == *" --reference="* ]] || pos=("${pos[@]:1}")
      [ "${#pos[@]}" -eq 0 ] || printf '%s\n' "${pos[@]}" ;;
    sed|perl)
      inplace=0 script=0
      for ((i = 0; i < n; i++)); do
        w="${args[i]}"
        case "$w" in
          --in-place*) inplace=1 ;;
          -e|--expression|-f|--file) script=1; i=$((i + 1)) ;;
          --*) ;;
          -*)
            [[ "$w" != -*i* ]] || inplace=1
            if [ "$cmd" = perl ] && [[ "$w" == -*e ]]; then script=1; i=$((i + 1)); fi ;;
          *) pos+=("$w") ;;
        esac
      done
      if [ "$inplace" = 1 ]; then
        [ "$script" = 1 ] || pos=("${pos[@]:1}")
        if [ "${#pos[@]}" -gt 0 ]; then printf '%s\n' "${pos[@]}"; else printf '?\n'; fi
      fi ;;
    dd)
      for w in "${args[@]}"; do case "$w" in of=*) printf '%s\n' "${w#of=}" ;; esac; done ;;
    curl)
      for ((i = 0; i < n; i++)); do
        w="${args[i]}"
        case "$w" in
          -o|--output) printf '%s\n' "${args[i+1]:-?}"; i=$((i + 1)) ;;
          --output=*) printf '%s\n' "${w#*=}" ;;
          -O|--remote-name|--remote-name-all) printf '?\n' ;;
        esac
      done ;;
    wget)
      tgt='?'
      for ((i = 0; i < n; i++)); do
        w="${args[i]}"
        case "$w" in
          -O|--output-document) tgt="${args[i+1]:-?}"; i=$((i + 1)) ;;
          --output-document=*) tgt="${w#*=}" ;;
          -*O-) tgt=- ;;
          -*O?*) tgt="${w#*O}" ;;
        esac
      done
      [ "$tgt" = - ] || printf '%s\n' "$tgt" ;;
    patch|unzip) printf '?\n' ;;
    tar) if [[ " ${args[*]} " =~ \ (-?[A-Za-z]*x[A-Za-z]*|--extract|--get)\  ]]; then printf '?\n'; fi ;;
  esac
  return 0
}

# Every write target of the walked command, against every directory it may
# run in, must be one this member may write.
_guard_member_targets() { # (after _guard_walk) -> deny <reason>, or nothing
  local i t d k r
  local -a ds abs=() src=() res
  for i in "${!_GW_SEG[@]}"; do
    IFS=$'\t' read -r -a ds <<< "${_GW_DIRS[i]}"
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      if [ "$t" = '?' ]; then
        printf 'deny %s - and where `%s` writes cannot be told' "$(_guard_member_where)" "${_GW_SEG[i]}"; return 0
      fi
      for d in "${ds[@]}"; do
        _guard_norm "$d" "$t" || { printf 'deny %s - and where %s is (in `%s`) cannot be told' "$(_guard_member_where)" "$t" "${_GW_SEG[i]}"; return 0; }
        abs+=("$_GN"); src+=("$t")
      done
    done < <(_guard_seg_targets "${_GW_SEG[i]}")
  done
  [ "${#abs[@]}" -gt 0 ] || return 0
  mapfile -t res < <(_guard_resolve "${abs[@]}")
  for k in "${!abs[@]}"; do
    for r in "${res[k]:-${abs[k]}}"; do
      _guard_member_may_write "$r" bash \
        || { printf 'deny %s - not %s' "$(_guard_member_where)" "${src[k]}"; return 0; }
    done
  done
}

# git for a member: a known verb, known global options only, and for a
# builder a write only inside its own worktree.
_GUARD_GIT_READ=' status log diff show fetch rev-parse rev-list ls-files ls-tree ls-remote cat-file blame annotate grep describe shortlog merge-base name-rev show-ref for-each-ref version help count-objects check-ignore check-attr cherry range-diff whatchanged var diff-tree diff-files diff-index '
_GUARD_GIT_BUILD=' add commit restore rm mv checkout switch reset rebase merge cherry-pick revert apply am clean pull '
_guard_member_git() { # <segment> <dirs, tab-separated> -> deny <reason>, or nothing
  local seg="$1" w kv verb="" kind="" cdir="" i n d listing key builder=0
  local -a t args pos=() ds locs=() res
  [ "$_GM_ROLE" != builder ] || builder=1
  read -r -a t <<< "$seg"; n=${#t[@]}; i=1
  while [ "$i" -lt "$n" ]; do
    w="${t[i]}"
    case "$w" in
      -C) cdir="${t[i+1]:-}"; [ -n "$cdir" ] || { printf 'deny git -C names no directory'; return 0; }; i=$((i + 2)) ;;
      -c)
        kv="${t[i+1]:-}"
        if [ "$builder" = 1 ] && [[ "$kv" =~ ^(user\.(name|email)|commit\.gpgsign)= ]]; then i=$((i + 2))
        else printf 'deny a team member sets no git config on the command line (git -c %s): one can redirect a push or run a command' "${kv%%=*}"; return 0; fi ;;
      --no-pager|-P|-p|--paginate|--no-optional-locks|--literal-pathspecs|--no-replace-objects) i=$((i + 1)) ;;
      --version|--help|-h) return 0 ;;
      -*) printf 'deny git %s is not a git option a team member uses (no --git-dir, --work-tree, --exec-path or other global options)' "$w"; return 0 ;;
      *) verb="$w"; i=$((i + 1)); break ;;
    esac
  done
  [ -n "$verb" ] || return 0
  args=("${t[@]:i}")
  for w in "${args[@]}"; do
    case "$w" in
      --upload-pack*|--receive-pack*|--exec|--exec=*|--output|--output=*|--open-files-in-pager*|-O|-O?*|--ext-diff|--textconv)
        printf 'deny git %s %s: a team member runs no git option that writes a file or runs a command' "$verb" "$w"; return 0 ;;
    esac
    [[ "$w" == -* ]] || pos+=("$w")
  done
  case "$_GUARD_GIT_READ" in *" $verb "*) kind=read ;; esac
  if [ -z "$kind" ]; then
    case "$_GUARD_GIT_BUILD" in *" $verb "*) kind=write ;; esac
  fi
  if [ -z "$kind" ]; then
    case "$verb" in
      branch|tag)
        kind=read listing=0
        for w in "${args[@]}"; do
          case "$verb:$w" in
            *:-d|*:-f|*:--delete|*:--force|*:--create-reflog) kind=write ;;
            branch:-D|branch:-m|branch:-M|branch:-c|branch:-C|branch:-u|branch:-t|branch:--move|branch:--copy|branch:--set-upstream-to*|branch:--unset-upstream|branch:--edit-description|branch:--track*) kind=write ;;
            tag:-a|tag:-s|tag:-u|tag:-m|tag:-F|tag:--annotate|tag:--sign) kind=write ;;
            *:-l|*:--list|*:--contains*|*:--no-contains*|*:--merged*|*:--no-merged*|*:--points-at*) listing=1 ;;
          esac
        done
        [ "${#pos[@]}" -eq 0 ] || [ "$listing" = 1 ] || kind=write ;;
      remote)
        if [ "${#pos[@]}" -eq 0 ] || [ "${pos[0]}" = show ] || [ "${pos[0]}" = get-url ]; then kind=read
        else printf 'deny a team member never changes a git remote (git remote %s)' "${pos[0]}"; return 0; fi ;;
      stash) case "${pos[0]:-push}" in list|show) kind=read ;; *) kind=write ;; esac ;;
      reflog) case "${pos[0]:-show}" in show|exists) kind=read ;; *) kind=write ;; esac ;;
      worktree)
        [ "${pos[0]:-}" = list ] || { printf 'deny a team member makes no git worktree (git worktree %s): cel run member made its own' "${pos[0]:-}"; return 0; }
        kind=read ;;
      symbolic-ref)
        [ "${#pos[@]}" -le 1 ] || { printf 'deny a team member moves no symbolic ref'; return 0; }
        kind=read ;;
      config)
        if [[ " ${args[*]} " =~ \ (--get|--get-all|--get-regexp|--get-urlmatch|--list|-l|--show-origin|--show-scope|--name-only)\  ]] \
           || [ "${pos[0]:-}" = get ] || [ "${pos[0]:-}" = list ]; then
          kind=read
        else
          key="${pos[0]:-}"; [ "$key" != set ] || key="${pos[1]:-}"
          if [ "$builder" = 1 ] && [[ "$key" =~ ^user\.(name|email)$ ]] \
             && ! [[ " ${args[*]} " =~ \ (--global|--system|--file|-f|--blob|--worktree|--unset|--unset-all|--rename-section|--remove-section|--add|--replace-all)\  ]]; then
            kind=write
          else
            printf 'deny a team member changes no git config but a builder'"'"'s own user.name/user.email (git config %s): remote, push, alias and url settings redirect a push' "${key:-?}"; return 0
          fi
        fi ;;
      push) kind=push ;;
      *) printf 'deny git %s is not a git verb a team member may run - an unknown verb may be an alias for anything' "$verb"; return 0 ;;
    esac
  fi
  [ "$kind" != read ] || return 0
  [ "$builder" = 1 ] || { printf 'deny a %s team member reads repositories and never writes one (git %s) - a builder does' "$_GM_ROLE" "$verb"; return 0; }
  # Where: every directory the command may run in (and -C from it).
  IFS=$'\t' read -r -a ds <<< "$2"
  for d in "${ds[@]}"; do
    if [ -n "$cdir" ]; then
      _guard_norm "$d" "$cdir" || { printf 'deny %s - and which checkout git -C %s names cannot be told' "$(_guard_member_where)" "$cdir"; return 0; }
      locs+=("$_GN")
    else
      [ "$d" != '?' ] || { printf 'deny %s - and which checkout this git runs in cannot be told (after cd)' "$(_guard_member_where)"; return 0; }
      locs+=("$d")
    fi
  done
  mapfile -t res < <(_guard_resolve "${locs[@]}")
  for d in "${res[@]}"; do
    case "$d" in
      "$_GM_WT/.git"|"$_GM_WT/.git/"*) printf 'deny %s - not its .git' "$(_guard_member_where)"; return 0 ;;
      "$_GM_WT"|"$_GM_WT/"*) ;;
      *) printf 'deny %s - git %s would run in %s' "$(_guard_member_where)" "$verb" "$d"; return 0 ;;
    esac
  done
  [ "$kind" != push ] || _guard_builder_push "${args[@]}"
}

# A BUILDER'S PUSH, the one shape: `git push [options] origin <refspec>...`,
# every refspec its own branch (B, B:B, HEAD:B, refs/heads/B). The remote is
# literally `origin`; a push with no refspec follows config and is refused.
_guard_builder_push() { # <push arguments...> -> deny <reason>, or nothing
  local b="$_GM_BRANCH" w r src dst remote="" n=0
  local why="a builder pushes only its own branch: git push origin $b (or HEAD:$b)"
  for w in "$@"; do
    case "$w" in
      -u|--set-upstream|-f|--force|--force-with-lease|--force-with-lease=*|--force-if-includes|-q|--quiet|-v|--verbose|-n|--dry-run|--no-verify|--atomic|--porcelain|--progress|--no-progress) ;;
      -*) [[ "$w" =~ ^-[ufqvn]+$ ]] || { printf 'deny %s - not %s' "$why" "$w"; return 0; } ;;
      *)
        if [ -z "$remote" ]; then
          remote="$w"
          [ "$remote" = origin ] || { printf 'deny %s - the remote is origin, not %s' "$why" "$w"; return 0; }
        else
          n=$((n + 1)); r="${w#+}"
          if [[ "$r" == *:* ]]; then src="${r%%:*}"; dst="${r#*:}"; else src="$r"; dst="$r"; fi
          case "$src" in HEAD|"$b"|"refs/heads/$b") ;; *) printf 'deny %s - not from %s' "$why" "${src:-nothing (a delete)}"; return 0 ;; esac
          case "$dst" in "$b"|"refs/heads/$b") ;; *) printf 'deny %s - not to %s' "$why" "$dst"; return 0 ;; esac
        fi ;;
    esac
  done
  [ -n "$remote" ] && [ "$n" -gt 0 ] \
    || printf 'deny %s - name the remote and the branch: a push without a refspec follows config' "$why"
}

_guard_member() { # <command> -> allow | deny <reason>
  local cmd="$1" i seg d
  _guard_member_scope || { printf '%s' "$_GUARD_MEMBER_NO_SCOPE"; return 0; }
  # Every member, whatever its role.
  if _guard_starts "$cmd" 'cel run' 'cel (core|console)' 'cel ws (up|down|reset)' 'cel team (start|add|retire|close|cap)' \
       'herdr agent (start|stop)' 'herdr worktree' 'herdr pane (close|split|send-text|send-keys|run)' 'herdr (tab|workspace) (create|close)' 'rex new'; then
    printf 'deny a team member starts and stops no agents or panes and runs no lead verb - ask the lead (cel team event %s <type> --to <lead>)' "$_GM_TEAM"
    return 0
  fi
  if _guard_starts "$cmd" 'cel (solo|here) (land|review)' 'cel afk' 'gh pr merge' 'gh api .*pulls/[0-9]+/merge' \
       'tea (pr|pulls|pull) (merge|m)' 'curl .*/pulls/[0-9]+/merge[^ ]*'; then
    printf 'deny a team member never merges, lands or records a PR verdict - the lead integrates and lands (cel solo land); report with cel team event|verdict %s' "$_GM_TEAM"
    return 0
  fi
  if _guard_forge_raw_write "$cmd" || _guard_gh_api_writes "$cmd" \
     || _guard_starts "$cmd" 'cel forge pr create' 'gh pr (create|merge|close|ready|reopen|edit|review|comment)' \
          'gh issue (create|close|reopen|edit|comment|delete|transfer|lock|unlock|pin|unpin)' \
          'gh release (create|delete|edit|upload)' 'gh repo (create|delete|edit|fork|rename|archive|unarchive|sync)' \
          'gh run (rerun|cancel|delete)' 'gh workflow (run|enable|disable)'; then
    printf 'deny a team member writes to no forge - no PR, comment, review or API write; the lead opens and lands the integration PR, and members report with cel team event|verdict %s' "$_GM_TEAM"
    return 0
  fi
  # git reads its environment before its options: GIT_DIR, GIT_CONFIG_* and
  # the like would move a push or define an alias out of sight.
  if [[ "$cmd" =~ (^|[^A-Za-z0-9_])GIT_[A-Z0-9_]+= ]]; then
    printf 'deny a team member sets no GIT_* environment: it could point git at another repository or config'
    return 0
  fi
  _guard_walk "$cmd"
  for i in "${!_GW_SEG[@]}"; do
    seg="${_GW_SEG[i]}"
    case "$seg" in
      git|"git "*)
        d="$(_guard_member_git "$seg" "${_GW_DIRS[i]}")"
        [ -z "$d" ] || { printf '%s' "$d"; return 0; } ;;
    esac
    # Read-only roles: the cel verbs a member reports and previews with.
    [ "$_GM_ROLE" != builder ] || continue
    case "$seg" in cel|cel\ *) ;; *) continue ;; esac
    [[ "$seg" =~ ^cel\ (serve|inbox|budget|fleet|version|services|help)(\ |$) \
    || "$seg" =~ ^cel\ team\ (event|verdict|ack|status)(\ |$) \
    || "$seg" =~ ^cel\ forge\ (repo|whoami)(\ |$) \
    || "$seg" =~ ^cel\ forge\ pr\ (view|checks|reviews|list)(\ |$) \
    || "$seg" =~ ^cel\ decide\ (ask|list)(\ |$) \
    || "$seg" =~ ^cel\ learn\ list(\ |$) ]] && continue
    printf 'deny a %s team member runs only cel serve, inbox, budget, fleet, forge reads, decide ask|list and cel team event|verdict|ack|status - not: %s' "$_GM_ROLE" "$seg"
    return 0
  done
  d="$(_guard_member_targets)"
  [ -z "$d" ] || { printf '%s' "$d"; return 0; }
  printf allow
}

# The native edit tools for a member: the same places a shell write may go,
# minus /tmp for a builder. A relative path is the pane's (_GUARD_CWD).
_guard_member_path() { # <file_path> -> allow | deny <reason>
  local p="$1" r
  _guard_member_scope || { printf '%s' "$_GUARD_MEMBER_NO_SCOPE"; return 0; }
  _guard_norm "${_GUARD_CWD:-$PWD}" "$p" || { printf 'deny %s - and where %s is cannot be told' "$(_guard_member_where)" "$p"; return 0; }
  for r in "$(_guard_resolve "$_GN")"; do
    _guard_member_may_write "$r" tool || { printf 'deny %s - not %s' "$(_guard_member_where)" "$p"; return 0; }
  done
  printf allow
}

guard_classify() { # <role> <command>
  local role="$1" cmd="$2"
  # Every role, `other` included (a reviewer stands outside any workspace).
  if _guard_names_forge_token "$cmd"; then printf '%s' "$_GUARD_TOKEN_DENY"; return 0; fi
  if _guard_cmd_reaches_launch "$cmd"; then printf '%s' "$_GUARD_LAUNCH_TOKEN_DENY"; return 0; fi
  # cel team add's launcher is not a door any agent opens by hand - `other`
  # (a reviewer) included: a member is added, and admitted against the box
  # budget, by `cel team add`.
  if _guard_starts "$cmd" 'cel run member'; then
    printf 'deny cel run member is cel team add'"'"'s internal launcher - add a member with: cel team add <feature> <role> [--focus f] [--repo r]'
    return 0
  fi
  if [ "$role" = core ]; then
    local cd; cd="$(_guard_core "$cmd")"
    [ -z "$cd" ] || { printf '%s' "$cd"; return 0; }
  fi
  # `other` is not the plane's concern.
  case "$role" in solo) _guard_solo "$cmd"; return 0;; esac
  case "$role" in member) _guard_member "$cmd"; return 0;; esac
  case "$role" in other) printf allow; return 0;; esac

  # A forge changed by hand (curl at its API, tea): checked before the
  # sanctioned paths below, so `cel ...; curl -XPOST ...` is not waved through
  # on the strength of its first half.
  if _guard_forge_raw_write "$cmd"; then
    printf 'deny orchestrators do not change forge state directly - the product'"'"'s solo agent opens PRs and lands them (cel solo land)'
    return 0
  fi
  # The sanctioned write paths. These are the mechanism; refusing them would
  # refuse the orchestrator's actual job. Opening a PR is not among them: the
  # solo agent opens PRs, an orchestrator reads them.
  if _guard_starts "$cmd" 'cel forge pr create'; then
    printf 'deny the product'"'"'s solo agent opens pull requests; an orchestrator reads them (cel forge pr view|checks|reviews|list)'
    return 0
  fi
  case "$cmd" in
    cel-linear\ *|*\ cel-linear\ *|*/cel-linear\ *) printf allow; return 0;;
    cel\ *|*\ cel\ *|*/bin/cel\ *)                  printf allow; return 0;;
    *gh\ pr\ comment*|*gh\ pr\ review*|*gh\ issue\ comment*|*gh\ pr\ checks*) printf allow; return 0;;
  esac

  # The orchestrator's own checkout state: see _guard_orch_owns_checkout above.
  # Root is untouched - its rules below already allow git in its config repo
  # and deny anything reaching into repos/ or a herdr worktree.
  if [ "$role" = orchestrator ] && _guard_orch_owns_checkout "$cmd"; then
    printf allow; return 0
  fi

  # Repository mutation. An ORCHESTRATOR's cwd is a product checkout, so any
  # git write from it is a product write - denied, in its own checkout or a
  # herdr worktree alike. ROOT's cwd is the workspace directory, which is
  # itself a small git repo of config (workspace.yaml, layouts, notes) that
  # root and the owner legitimately commit to; so for root a git write is
  # denied only when the command reaches INTO a product checkout (repos/) or a
  # herdr worktree.
  if _guard_git_writes "$cmd"; then
    local product=1
    if [ "$role" = root ]; then
      product=0
      case "$cmd" in *repos/*|*.herdr/worktrees*|*\ -C\ *) product=1;; esac
    fi
    if [ "$product" -eq 1 ]; then
      printf 'deny orchestrators do not write to repositories - the product'"'"'s solo agent builds it, opens the PR and lands it (cel solo land)'
      return 0
    fi
  fi

  # Worktrees belong to the solo agent that builds in them. A direct
  # `herdr worktree remove --force` from a coordinator can destroy unlanded work.
  case "$cmd" in
    *herdr\ worktree\ remove*|*herdr\ worktree\ create*)
      printf 'deny herdr worktree is not called from an orchestrator pane; the product'"'"'s solo agent manages its own worktrees'
      return 0;;
  esac

  # Anything that changes GitHub state. Merging in particular has exactly one
  # path, and it is the one that checks whose PR it is.
  case "$cmd" in
    *gh\ pr\ merge*|*gh\ pr\ close*|*gh\ pr\ ready*|*gh\ pr\ edit*|*gh\ pr\ create*|*gh\ pr\ reopen*)
      printf 'deny the product'"'"'s solo agent opens and updates PRs and lands them (cel solo land), which checks review and CI'
      return 0;;
    *gh\ release\ *|*gh\ repo\ *|*gh\ api\ *-X\ *|*gh\ api\ *--method*|*gh\ api\ *\ -[fF]\ *|*gh\ api\ *--field*|*gh\ api\ *--raw-field*)
      printf 'deny orchestrators do not change GitHub state directly'
      return 0;;
  esac

  # Editing files under repos/ by shell. (The native edit tools are checked
  # separately by the hook, by path.)
  if _guard_shell_edits_repos "$cmd"; then
    printf 'deny orchestrators do not edit files under repos/ - the product'"'"'s solo agent does'
    return 0
  fi

  printf allow
}

# For the native edit tools (Edit/Write/MultiEdit/NotebookEdit), which never
# pass through a shell: a path under any workspace's repos/ is a repository
# write. Everything else - specs and notes under <ws>/.cel/, the workspace
# file, scratch - is the orchestrator's to write. The forge token is nobody's.
guard_classify_path() { # <role> <file_path>
  local role="$1" path="$2"
  if _guard_names_forge_token "$path"; then printf '%s' "$_GUARD_TOKEN_DENY"; return 0; fi
  if _guard_path_reaches_launch "$path"; then printf '%s' "$_GUARD_LAUNCH_TOKEN_DENY"; return 0; fi
  if [ "$role" = member ]; then _guard_member_path "$path"; return 0; fi
  # Core writes its own notes and nothing else: it has no workspace, so every
  # path outside its directory belongs to someone whose job it is not.
  if [ "$role" = core ]; then
    local core="${CEL_CORE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/core}"
    case "$path" in
      "$core"/*) printf allow; return 0;;
      *) printf 'deny core writes only its own notes (%s) - a product agent changes everything else; send it the request' "$core"; return 0;;
    esac
  fi
  case "$role" in solo|other) printf allow; return 0;; esac
  case "$path" in
    */repos/*) printf 'deny orchestrators do not edit files under repos/ - the product'"'"'s solo agent does'; return 0;;
  esac
  printf allow
}

# For the native read tools (Read, read): every role reads freely - except the
# forge token and the team launch tokens.
guard_classify_read() { # <role> <file_path>
  if _guard_names_forge_token "$2"; then printf '%s' "$_GUARD_TOKEN_DENY"; return 0; fi
  if _guard_path_reaches_launch "$2"; then printf '%s' "$_GUARD_LAUNCH_TOKEN_DENY"; return 0; fi
  printf allow
}
