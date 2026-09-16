# shellcheck shell=bash
# Read-only orchestrators.
#
# The agents that DECIDE what happens to a codebase are not the agents that
# can CHANGE it: root and the sub-orchestrators plan, delegate, supervise and
# judge; workers in worktrees write; anything that lands on main goes through
# `cel-fanout land`, which checks policy before it merges.
#
# On 2026-09-11 a steward prompt reading "PR #1309 is APPROVED - action it
# now" led an orchestrator to merge a colleague's PR and push two commits to
# another colleague's branch. The prompt was fixed (--author @me). This fixes
# the CAPABILITY: the next bad prompt - a misread ticket, a confusing inbox
# message, an invented instruction - produces a refusal, not an incident.
#
# A second, quieter reason: every change an orchestrator makes in its own
# checkout is invisible to the factory - no ticket, no worker, no ledger row,
# no PR. Several hundred uncommitted files were found in one orchestrator
# checkout the day this was written. With the guard on, "all work goes through
# a delegated worker" is a property of the system rather than a request.
#
# THE CONSOLE IS THE OTHER WAY ROUND: an allowlist, not a deny list. An
# orchestrator's job is broad - it reads anything, writes specs, drives the
# whole factory - and its genuinely dangerous verbs are few, so naming them is
# both possible and honest. The console's job is narrow: it routes, and its
# entire vocabulary is a handful of `cel` commands the operator could have
# typed. Everything outside that vocabulary is a mistake by definition, so the
# list that must be complete is the list of things it MAY do, and a command
# nobody thought about is refused rather than waved through.
#
# Sourced by tools/hooks/orchestrator-guard.sh (claude PreToolUse) and by the
# tests. Depends on nothing but common.sh so the hook stays fast and cannot be
# taken down by unrelated library breakage.
[ -n "${_CEL_GUARD:-}" ] && return 0
_CEL_GUARD=1

# Which role a process is playing, from where it is standing. The SAME
# derivation lib/inbox.sh uses for mail identity, duplicated on purpose: the
# guard must not import inbox state to decide whether to block a command.
#   ~/.herdr/worktrees/...        worker       (writes are its whole job)
#   the console dir               console      (routes; allowlisted)
#   <ws>/repos/<repo>[/...]       orchestrator (reads, delegates, lands)
#   <ws>/products/<p>[/...]       orchestrator (a product orchestrator: same
#                                 powers, same refusals, different standpoint)
#   <ws>[/...not under repos]     root
#   anywhere else                 other        (not the plane's concern)
#
# CEL_ROLE=console in the environment says so outright, because unlike every
# other role the console's cwd is a plain directory a human could also be
# standing in - path alone is not enough to be sure.
guard_role_of() { # <cwd>
  local p="$1" wt="${CEL_WORKTREES:-$HOME/.herdr/worktrees}"
  [ "${CEL_ROLE:-}" = console ] && { printf console; return 0; }
  local cons="${CEL_CONSOLE_DIR:-$HOME/.local/share/cel/console}"
  case "$p" in "$cons"|"$cons"/*) printf console; return 0;; esac
  case "$p" in "$wt"/*) printf worker; return 0;; esac
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
# heuristic about "dangerous-looking" commands. The cost of a false deny is an
# orchestrator that has to delegate a typo fix; the cost of a false allow is
# the incident above. When in doubt the list errs towards deny, and the
# refusal always says what to do instead.
# The console's allowlist. Matched against the command with leading whitespace
# stripped, so the verb has to BE the command rather than appear somewhere in
# it: `git log` is reading, `cd x && git commit` is not, and a deny list that
# only looked for "git commit" would pass the second half of a chain it never
# examined. The refusal names the sanctioned route when there is an obvious
# one, because "no" without "instead" is how an agent starts improvising.
_guard_console() { # <command>
  local c="$1"
  c="${c#"${c%%[![:space:]]*}"}"
  case "$c" in
    cel\ *|*/bin/cel\ *|cel-fanout\ *|*/cel-fanout\ *|cel-linear\ *|*/cel-linear\ *)
      printf allow; return 0;;
    gh\ pr\ view*|gh\ pr\ list*|gh\ pr\ checks*|gh\ pr\ comment*|gh\ pr\ diff*|\
    gh\ issue\ view*|gh\ issue\ list*)
      printf allow; return 0;;
    herdr\ agent\ list*|herdr\ agent\ get*|herdr\ agent\ read*|herdr\ agent\ prompt*|\
    herdr\ agent\ focus*|herdr\ agent\ wait*|herdr\ pane\ read*|herdr\ pane\ list*|\
    herdr\ workspace\ list*|herdr\ notification\ show*)
      printf allow; return 0;;
    cat\ *|ls|ls\ *|grep\ *|jq\ *|yq\ *|head\ *|tail\ *|wc\ *|date|date\ *|\
    echo\ *|printf\ *|pwd|which\ *)
      printf allow; return 0;;
    git\ log*|git\ status*|git\ diff*|git\ show*)
      printf allow; return 0;;
  esac
  local hint="ask the orchestrator that owns it, or route it with cel inbox send"
  case "$c" in
    *git\ commit*|*git\ push*|*git\ add\ *|*git\ rebase*|*git\ merge*) hint="delegate it";;
    *gh\ pr\ merge*|*gh\ pr\ ready*|*gh\ pr\ close*) hint="landing a PR is the owning orchestrator's cel-fanout land";;
    *herdr\ worktree\ *) hint="worktree lifecycle is cel-fanout delegate / release";;
    *repos/*|*products/*) hint="a worker does that";;
  esac
  printf 'deny the console routes; it does not build - %s' "$hint"
}

# An orchestrator owns the STATE of its own checkout, never its authorship.
# Until this was added, `gh pr checkout 1393` was allowed by omission while
# `git checkout main` was denied: an orchestrator could move ONTO a PR branch
# to run it locally and could not move back, and one product orchestrator told
# its owner its checkout "goes back to main when the PR merges". Nobody else
# stands over that checkout, so keeping `main` current in it is its job.
# Moving between refs that ALREADY EXIST creates nothing and discards nothing;
# every incident at the top of this file is authorship - a merged colleague's
# PR, pushed commits, hundreds of uncommitted files - and none of them is a
# branch switch.
#
# The line: exactly one ref, no flag that creates (-b/-B/-c/-C/--orphan/
# --track/--detach), no `--` or path (that discards working-tree state), and
# nothing that reaches into ANOTHER checkout (-C, --git-dir, --work-tree, or
# a worker's worktree - that one is the worker's).
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
          # Allowed by omission before this existed; explicit so that a later
          # tightening of the gh rules below cannot silently regress it.
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

guard_classify() { # <role> <command>
  local role="$1" cmd="$2"
  case "$role" in console) _guard_console "$cmd"; return 0;; esac
  case "$role" in worker|other) printf allow; return 0;; esac

  # The sanctioned write paths. These are the mechanism; refusing them would
  # refuse the orchestrator's actual job.
  case "$cmd" in
    cel-fanout\ *|*\ cel-fanout\ *|*/cel-fanout\ *) printf allow; return 0;;
    cel-linear\ *|*\ cel-linear\ *|*/cel-linear\ *) printf allow; return 0;;
    cel\ *|*\ cel\ *|*/bin/cel\ *)                  printf allow; return 0;;
    *gh\ pr\ comment*|*gh\ pr\ review*|*gh\ issue\ comment*|*gh\ pr\ checks*) printf allow; return 0;;
  esac

  # The orchestrator's own checkout state: see _guard_orch_owns_checkout above.
  # Root is untouched - its rules below already allow git in its config repo
  # and deny anything reaching into repos/ or a worker's worktree.
  if [ "$role" = orchestrator ] && _guard_orch_owns_checkout "$cmd"; then
    printf allow; return 0
  fi

  # Repository mutation. An ORCHESTRATOR's cwd is a product checkout, so any
  # git write from it is a product write - denied, in its own checkout or a
  # worker's worktree alike. ROOT's cwd is the workspace directory, which is
  # itself a small git repo of config (workspace.yaml, layouts, notes) that
  # root and the owner's own assistant legitimately commit to; so for root a
  # git write is denied only when the command reaches INTO a product checkout
  # (repos/) or a worker's worktree. This mirrors firstmate's rule, which
  # guards `projects/`, not the supervisor's own home.
  # `git -C <dir> commit`, `git --git-dir=x push`, `git -c k=v merge`: the verb
  # is no longer adjacent to `git`, and a substring match on "git commit" lets
  # it straight through - an evasion route wide enough to write to a product
  # repo from any pane. Strip those options out before matching. The ORIGINAL
  # command is still what the root/product check below looks at, since -C is
  # exactly how a command reaches into repos/.
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
      printf 'deny orchestrators do not write to repositories - delegate it (cel-fanout delegate) or land it (cel-fanout land)'
      return 0
    fi
  fi

  # Worktree and workspace lifecycle goes through cel-fanout (release refuses
  # to destroy unlanded work; delegate refuses an occupied path). A direct
  # `herdr worktree remove --force` from an orchestrator pane skips every one
  # of those checks - observed the day this was added, from root, on a
  # worktree that happened to be clean.
  case "$cmd" in
    *herdr\ worktree\ remove*|*herdr\ worktree\ create*)
      printf 'deny worktree lifecycle goes through cel-fanout (delegate / release), which refuses to destroy unlanded work; herdr worktree is not called directly from an orchestrator pane'
      return 0;;
  esac

  # Anything that changes GitHub state. Merging in particular has exactly one
  # path, and it is the one that checks whose PR it is.
  case "$cmd" in
    *gh\ pr\ merge*|*gh\ pr\ close*|*gh\ pr\ ready*|*gh\ pr\ edit*|*gh\ pr\ create*|*gh\ pr\ reopen*)
      printf 'deny merges go through `cel-fanout land <id>`, which checks policy and ownership; workers open and update PRs'
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
      printf 'deny orchestrators do not edit files under repos/ - a worker in a worktree does'
      return 0;;
  esac

  printf allow
}

# For the native edit tools (Edit/Write/MultiEdit/NotebookEdit), which never
# pass through a shell: a path under any workspace's repos/ is a repository
# write. Everything else - specs and notes under <ws>/.cel/, the workspace
# file, scratch - is the orchestrator's to write.
guard_classify_path() { # <role> <file_path>
  local role="$1" path="$2"
  # The console writes its own notes and nothing else: it has no workspace, so
  # every path outside its directory belongs to someone whose job it is not.
  if [ "$role" = console ]; then
    local cons="${CEL_CONSOLE_DIR:-$HOME/.local/share/cel/console}"
    case "$path" in
      "$cons"/*) printf allow; return 0;;
      *) printf 'deny the console routes; it does not build - a worker does that'; return 0;;
    esac
  fi
  case "$role" in worker|other) printf allow; return 0;; esac
  case "$path" in
    */repos/*) printf 'deny orchestrators do not edit files under repos/ - a worker in a worktree does'; return 0;;
  esac
  printf allow
}
