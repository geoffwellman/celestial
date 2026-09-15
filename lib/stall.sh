# shellcheck shell=bash
# Dead workers.
#
# A worker whose provider stream dies leaves its pane sitting on a retry
# prompt. herdr reports that pane as `idle` - the SAME word it reports for a
# worker waiting for input, and for one between turns. Nothing escalated, the
# Linear ticket kept saying In Progress, and on 2026-09-14 three workers died
# on the identical error:
#
#   ✘ server_error: Upstream error from Together: Stream error: h2 protocol
#     error: error reading a body from connection
#   ↻ F5 to Retry
#
# One of them sat that way for roughly fifteen hours with its branch never
# pushed, so the work existed only in a local worktree - which the gc reaper
# removes. Root found all three by hand, and only because the owner asked.
#
# WHY THE INBOX WATCHERS COULD NOT SEE IT: the orchestrators watch the
# celestial inbox, and a dead worker sends no mail. That is the point. An
# inbox-only watcher is structurally blind to producer failure - it can only
# see agents alive enough to report. Liveness has to be observed from OUTSIDE
# the agent, which is what this file does.
#
# Everything here is a pure function of (pane text, worktree, clock) so the
# real failure can be replayed in a test rather than described.
[ -n "${_CEL_STALL:-}" ] && return 0
_CEL_STALL=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Markers that mean THIS TURN IS OVER AND WENT NOWHERE. Matched against the
# tail of a pane, case-insensitively.
#
# Deliberately narrow. A pane is full of text an agent merely PRINTED - a
# worker reading a log, quoting an error, or writing a test for one - and a
# marker that fires on "server_error" appearing anywhere would report a
# healthy worker as dead. These are shapes the RUNTIME emits when it has
# stopped: a retry affordance, a fatal transport error, a crashed process.
_STALL_MARKERS='F5 to Retry|↻ *Retry|server_error|Stream error|h2 protocol error|Upstream error from|context deadline exceeded|ECONNRESET|socket hang up|panic: |fatal error: |Killed *$|command not found'

# "" when the tail looks like ordinary work, else the marker that matched.
stall_marker() { # <pane-text>
  local hit
  hit="$(printf '%s' "$1" | grep -oiE "$_STALL_MARKERS" | tail -1 || true)"
  [ -n "$hit" ] && printf '%s' "$hit"
  return 0
}

# Seconds since anything in the worktree was last written, or "" when that
# cannot be established (no worktree, unreadable).
#
# THE WORK ITSELF IS THE EVIDENCE. herdr exposes no last-activity timestamp -
# only `state_change_seq`, a counter that also moves when a pane is merely
# focused and resets when herdr restarts - so liveness is read from the thing
# a working agent cannot help but touch: files. An agent that is editing,
# running tests, or committing writes something; one sitting on a retry prompt
# writes nothing at all.
#
# .git is pruned except for its index and HEAD: the object store churns during
# fetches that no agent asked for, while the index and HEAD move exactly when
# the agent stages or commits. Heavy generated trees are pruned too - a
# node_modules install is not the agent working, and walking one is slow
# enough to matter in a five-minute sweep.
stall_quiet_secs() { # <worktree>
  local wt="$1" newest now
  [ -d "$wt" ] || return 0
  newest="$( { find "$wt" \
        \( -name .git -o -name node_modules -o -name .next -o -name dist \
           -o -name build -o -name target -o -name .venv -o -name __pycache__ \) -prune \
        -o -type f -printf '%T@\n' 2>/dev/null
      stat -c '%Y' "$wt/.git/index" "$wt/.git/HEAD" 2>/dev/null
    } | sort -rn | head -1 )"
  [ -n "$newest" ] || return 0
  newest="${newest%%.*}"
  now="$(date +%s)"
  printf '%s' "$(( now - newest ))"
}

# What would be LOST if this worktree went away right now.
#   ""                     nothing - everything is pushed and clean
#   "unpushed=K dirty=M"   K commits the remote has never seen, M dirty files
# Mirrors cel-fanout's own release check, on purpose: the number that decides
# whether losing this worktree costs work should be computed the same way by
# whoever is asking.
# `.agent/` is excluded: result.md and verdict.json are the worker's REPORT,
# written at the end and never committed, so counting them made every finished
# worker look like one holding work at risk. Three did on the first live run.
# The incident's at-risk files were a chrome wrapper and two untracked modules -
# code - and those still count.
stall_work_at_risk() { # <worktree>
  local wt="$1" br dirty unpushed base
  [ -d "$wt" ] || return 0
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null | grep -v ' \.agent/' | grep -c . || true)"
  br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  unpushed=0
  if [ -n "$br" ] && [ "$br" != HEAD ]; then
    if git -C "$wt" rev-parse --verify -q "origin/$br" >/dev/null 2>&1; then
      unpushed="$(git -C "$wt" rev-list --count "origin/$br..HEAD" 2>/dev/null || printf 0)"
    else
      # No remote branch AT ALL - the 404 case from the incident. Everything
      # this worktree has ever committed is unpushed.
      base="$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf 'origin/main')"
      git -C "$wt" rev-parse --verify -q "$base" >/dev/null 2>&1 \
        && unpushed="$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || printf 0)" \
        || unpushed=0
    fi
  fi
  [ "${dirty:-0}" -gt 0 ] || [ "${unpushed:-0}" -gt 0 ] \
    && printf 'unpushed=%s dirty=%s' "${unpushed:-0}" "${dirty:-0}"
  return 0
}

stall_branch_pushed() { # <worktree> -> yes|no|?
  local wt="$1" br
  [ -d "$wt" ] || { printf '?'; return 0; }
  br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [ -n "$br" ] && [ "$br" != HEAD ] || { printf '?'; return 0; }
  git -C "$wt" rev-parse --verify -q "origin/$br" >/dev/null 2>&1 \
    && printf 'yes' || printf 'no'
}

# THE THRESHOLDS, and why they are not one number.
#
# `idle` alone is never the signal - a healthy worker between turns is idle,
# and reporting on that would make the watcher noise, which is how watchers
# get ignored. What varies is how much corroboration the age has to supply:
#
#   marker + 15m quiet   A fatal marker is already strong evidence; the age
#                        only rules out a retry that is about to succeed and a
#                        turn that happens to be printing an error it caught.
#                        Fifteen minutes is longer than any single model turn
#                        and shorter than a coffee.
#   vanished, any age    The agent is off the roster with its ledger row still
#                        `running`. There is nothing left to wait for.
#   no marker + 3h       Quiet this long with no explanation is worth a word,
#                        but it is the weakest case - a worker CAN legitimately
#                        sit blocked on a human - so it is reported, not
#                        escalated, and only once.
: "${CEL_STALL_MARKER_SECS:=900}"
: "${CEL_STALL_QUIET_SECS:=10800}"

# The verdict for one delegation.
#   dead-<marker>   a fatal marker, quiet long enough to believe it
#   vanished        no agent on the roster at all
#   quiet           no marker, but nothing has moved in a very long time
#   ""              alive, or not yet conclusive
stall_verdict() { # <live-status> <pane-text> <quiet-secs> [has-result 0|1]
  local live="$1" text="$2" quiet="${3:-}" done_="${4:-0}"
  case "$live" in
    ''|'-'|gone) printf 'vanished'; return 0 ;;
    working)     return 0 ;;   # busy is busy, whatever its pane says
  esac
  # A WORKER THAT WROTE ITS RESULT IS FINISHED, NOT STALLED. It has reached the
  # last instruction it was given - write .agent/result.md and stop - so of
  # course it is idle and of course nothing has been written since. Reporting
  # that as a stall is how a watcher earns its reputation for crying wolf: on
  # the first live run this sweep flagged three finished workers,
  # each with a pushed branch and an open PR. `cel-fanout status` reconciles
  # these to `finished`; they are its business, not this one's.
  [ "$done_" = 1 ] && return 0
  local marker; marker="$(stall_marker "$text")"
  if [ -n "$marker" ]; then
    [ -n "$quiet" ] && [ "$quiet" -ge "$CEL_STALL_MARKER_SECS" ] \
      && { printf 'dead-%s' "$marker"; return 0; }
    return 0
  fi
  [ -n "$quiet" ] && [ "$quiet" -ge "$CEL_STALL_QUIET_SECS" ] && printf 'quiet'
  return 0
}

# Loud when delay costs the WORK, not merely time. A stalled worker whose
# branch is pushed can be re-delegated at leisure; one holding commits the
# remote has never seen is a gc sweep away from losing them outright - which
# is exactly what nearly happened on 2026-09-14.
stall_severity() { # <verdict> <work-at-risk>
  [ -n "$1" ] || return 0
  [ -n "$2" ] && printf 'loud' || printf 'normal'
}

# The escalation line. These four facts - ticket, pane, how long, and what is
# at risk - are precisely what root had to gather by hand, so the message
# carries them rather than asking the reader to go and look.
stall_message() { # <verdict> <ticket> <pane> <quiet-secs> <pushed> <at-risk> <branch>
  local verdict="$1" ticket="$2" pane="$3" quiet="$4" pushed="$5" risk="$6" branch="$7"
  local age="unknown"
  [ -n "$quiet" ] && age="$(( quiet / 60 ))m"
  local what
  case "$verdict" in
    vanished) what="its agent is GONE from the roster (ledger still says running)" ;;
    quiet)    what="nothing has been written for $age and it is not working" ;;
    dead-*)   what="its pane is dead on '${verdict#dead-}' and nothing has been written for $age" ;;
    *)        what="stalled" ;;
  esac
  printf 'STALLED WORKER %s (%s): %s. branch %s pushed=%s%s. %s' \
    "${ticket:-untracked}" "${pane:-no-pane}" "$what" "${branch:-?}" "$pushed" \
    "${risk:+ - UNLANDED $risk}" \
    "$([ -n "$risk" ] \
        && printf 'THE WORK IS AT RISK: it exists only in this worktree and gc removes uncommitted worktrees. Salvage it BEFORE re-delegating: cel-fanout collect, or commit and push from the worktree.' \
        || printf 'Its work is pushed, so it is safe to release and re-delegate.')"
}
