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
# launch can say which of the two it is.
guard_role_of() { # <cwd>
  local p="$1"
  # A console launched before its retirement carries CEL_ROLE=console and
  # stands in the old console dir; it is guarded as core, never as `other`.
  case "${CEL_ROLE:-}" in core|console) printf core; return 0;; esac
  [ "${CEL_ROLE:-}" = solo ] && { printf solo; return 0; }
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
    | sed -E 's#^[^ ]*/(cel|gh|herdr|tea|curl)( |$)#\1\2#' \
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

guard_classify() { # <role> <command>
  local role="$1" cmd="$2"
  # Every role, `other` included (a reviewer stands outside any workspace).
  if _guard_names_forge_token "$cmd"; then printf '%s' "$_GUARD_TOKEN_DENY"; return 0; fi
  if [ "$role" = core ]; then
    local cd; cd="$(_guard_core "$cmd")"
    [ -z "$cd" ] || { printf '%s' "$cd"; return 0; }
  fi
  # `other` is not the plane's concern.
  case "$role" in solo) _guard_solo "$cmd"; return 0;; esac
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
  # `git -C <dir> commit`, `git --git-dir=x push`, `git -c k=v merge`: the verb
  # is no longer adjacent to `git`, so those options are stripped before
  # matching. The ORIGINAL command is still what the root/product check below
  # looks at, since -C is exactly how a command reaches into repos/.
  local norm
  norm="$(printf '%s' "$cmd" | sed -E 's/git( +-C +[^ ]+| +--git-dir=[^ ]+| +--work-tree=[^ ]+| +-c +[^ ]+)+/git/g')"
  local git_write=0
  case "$norm" in
    *git\ commit*|*git\ push*|*git\ merge*|*git\ rebase*|*git\ reset*|*git\ revert*|\
    *git\ cherry-pick*|*git\ am\ *|*git\ apply*|*git\ stash*|*git\ checkout*|*git\ switch*|\
    *git\ restore*|*git\ add\ *|*git\ rm\ *|*git\ mv\ *|*git\ tag\ *|*git\ worktree\ *|\
    *git\ branch\ -[dDmM]*|*git\ branch\ --delete*|*git\ branch\ --move*|*git\ clean*) git_write=1;;
  esac
  if [ "$git_write" -eq 1 ]; then
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
  case "$cmd" in
    *sed\ -i*repos/*|*perl\ -pi*repos/*|*\>\ *repos/*|*\>\>\ *repos/*|*tee\ *repos/*|\
    *rm\ *repos/*|*mv\ *repos/*|*cp\ *repos/*|*touch\ *repos/*|*mkdir\ *repos/*|*chmod\ *repos/*|\
    *truncate\ *repos/*|*install\ *repos/*|*rsync\ *repos/*|*ln\ *repos/*)
      printf 'deny orchestrators do not edit files under repos/ - the product'"'"'s solo agent does'
      return 0;;
  esac

  printf allow
}

# For the native edit tools (Edit/Write/MultiEdit/NotebookEdit), which never
# pass through a shell: a path under any workspace's repos/ is a repository
# write. Everything else - specs and notes under <ws>/.cel/, the workspace
# file, scratch - is the orchestrator's to write. The forge token is nobody's.
guard_classify_path() { # <role> <file_path>
  local role="$1" path="$2"
  if _guard_names_forge_token "$path"; then printf '%s' "$_GUARD_TOKEN_DENY"; return 0; fi
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
# forge token.
guard_classify_read() { # <role> <file_path>
  if _guard_names_forge_token "$2"; then printf '%s' "$_GUARD_TOKEN_DENY"; return 0; fi
  printf allow
}
