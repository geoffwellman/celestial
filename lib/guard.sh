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
# Sourced by tools/hooks/orchestrator-guard.sh (claude PreToolUse) and by the
# tests. Depends on nothing but common.sh so the hook stays fast and cannot be
# taken down by unrelated library breakage.
[ -n "${_CEL_GUARD:-}" ] && return 0
_CEL_GUARD=1

# Which role a process is playing, from where it is standing. The SAME
# derivation lib/inbox.sh uses for mail identity, duplicated on purpose: the
# guard must not import inbox state to decide whether to block a command.
#   ~/.herdr/worktrees/...        worker       (writes are its whole job)
#   <ws>/repos/<repo>[/...]       orchestrator (reads, delegates, lands)
#   <ws>/products/<p>[/...]       orchestrator (a product orchestrator: same
#                                 powers, same refusals, different standpoint)
#   <ws>[/...not under repos]     root
#   anywhere else                 other        (not the plane's concern)
guard_role_of() { # <cwd>
  local p="$1" wt="${CEL_WORKTREES:-$HOME/.herdr/worktrees}"
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
guard_classify() { # <role> <command>
  local role="$1" cmd="$2"
  case "$role" in worker|other) printf allow; return 0;; esac

  # The sanctioned write paths. These are the mechanism; refusing them would
  # refuse the orchestrator's actual job.
  case "$cmd" in
    cel-fanout\ *|*\ cel-fanout\ *|*/cel-fanout\ *) printf allow; return 0;;
    cel-linear\ *|*\ cel-linear\ *|*/cel-linear\ *) printf allow; return 0;;
    cel\ *|*\ cel\ *|*/bin/cel\ *)                  printf allow; return 0;;
    *gh\ pr\ comment*|*gh\ pr\ review*|*gh\ issue\ comment*|*gh\ pr\ checks*) printf allow; return 0;;
  esac

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
  case "$role" in worker|other) printf allow; return 0;; esac
  case "$path" in
    */repos/*) printf 'deny orchestrators do not edit files under repos/ - a worker in a worktree does'; return 0;;
  esac
  printf allow
}
