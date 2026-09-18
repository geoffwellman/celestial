# shellcheck shell=bash
# What a worker actually costs, and what the box has left.
#
# The owner, 2026-09-18: "how are we monitoring memory for the workers and can
# that be visualised in the console too?" Nothing did. herdr exposes no pid for
# a pane, so there was no handle on a worker's processes at all, and the box -
# 24 GB, sitting at 17 GB used with agents up - only ever announced its state
# by having the kernel kill something, which is never the thing you would have
# chosen. A runaway test server or a forgotten session was invisible until then.
#
# THE CWD IS THE HANDLE. Every process whose working directory is under a
# worker's worktree is that worker's: the shell, the agent, its tools and its
# test runs. Measured on this box, summing `VmRSS` over that set gives 370 MB
# for a worker mid-gate - the number an operator wants - in under 50 ms for the
# whole box. It is an attribution, not a containment boundary: a process that
# chdirs elsewhere leaves the tree, which is the honest answer rather than a
# guess, and the alternative (walking parent pids from a pane nobody can name)
# has no starting point.
#
# RSS IS SUMMED, NOT SHARED-CORRECTED. Two agents sharing a node binary have
# its pages counted twice, so the total reads slightly high. That is deliberate:
# PSS costs a read of /proc/<pid>/smaps_rollup per process and the question here
# is "which tree is the big one", which ordering answers and precision does not.
[ -n "${_CEL_MEMORY:-}" ] && return 0
_CEL_MEMORY=1

# ONE WALK PER READ. `cel fleet` asks about every worker, every orchestrator
# and the box; a walk per question turned a 50 ms read into one that scaled
# with the number of workers - exactly the cost profile the view exists to
# expose. The snapshot is a plain string (rss-kB TAB cwd per line) so a caller
# fills it once and every later sum is arithmetic.
MEM_SNAPSHOT="${MEM_SNAPSHOT:-}"

# Every process of THIS USER with a readable cwd. Other users' processes are
# skipped rather than reported as zero: readlink on their `cwd` fails by
# permission, and a box with two people's agents on it must not have one of
# them measuring the other.
#
# Pids vanish mid-walk constantly - a gate run is dozens of short-lived
# processes - so every read tolerates the file having gone between the listing
# and the open. A walk that died on a vanished pid would fail most of the time
# it ran.
mem_tree_list() {
  # TWO processes for the whole box, not two per pid. The first cut ran
  # readlink and awk for each of ~900 processes: 4.5 seconds, most of the
  # console's 12-second start. `ls -l` prints every cwd link in one go
  # (owner in column 3 - only this user's processes are ours to read), and
  # one awk over every status file gives every RSS, keyed by the pid in the
  # file name. Processes that vanish between the two reads simply drop out.
  local me; me="$(id -un)"
  {
    # `|| true` on both: other users' cwd links are unreadable and a pid can
    # vanish mid-read, and either makes ls or awk exit non-zero - which under
    # set -e and pipefail killed the whole fleet call, silently, exit 2.
    { ls -l /proc/[0-9]*/cwd 2>/dev/null || true; } | awk -v me="$me" '$3 == me { i = NF - 2; p = $i; sub(/.*\/proc\//, "", p); sub(/\/cwd$/, "", p); print "C\t" p "\t" $NF }'
    # grep -s, not awk over the files: gawk aborts the whole run when one
    # status file has vanished between the glob and the open, and on this box
    # one always has - the first cut counted 375 of 660 processes.
    { grep -Hs '^VmRSS:' /proc/[0-9]*/status || true; } | awk -F'[:[:space:]]+' '{ p = $1; sub(/^\/proc\//, "", p); sub(/\/status$/, "", p); print "R\t" p "\t" $3 }'
  } | awk -F'\t' '
    $1 == "C" { cwd[$2] = $3 }
    $1 == "R" { rss[$2] = $3 }
    END { for (p in cwd) if (p in rss && cwd[p] != "") printf "%s\t%s\n", rss[p], cwd[p] }'
}

mem_tree_snapshot() { MEM_SNAPSHOT="$(mem_tree_list)"; }
mem_tree_snapshot_clear() { MEM_SNAPSHOT=""; }

# Sum a snapshot on stdin for one directory, in whole megabytes.
#
# The prefix test is `$2 == d` or `index($2, d "/") == 1`, NEVER a bare prefix
# match: `/w/onetwo` starts with `/w/one`, and worktree names on this box
# differ by exactly that much (`ABC-4` and `ABC-49-slug`). Attributing one
# worker's memory to another is worse than reporting none, because the wrong
# row is the one someone would act on.
mem_tree_sum() { # <dir> < snapshot -> mb
  local dir="${1:-}"
  dir="${dir%/}"
  [ -n "$dir" ] || { printf 0; return 0; }
  awk -F'\t' -v d="$dir" '
    $2 == d || index($2, d "/") == 1 { kb += $1 }
    END { printf "%d", kb / 1024 }'
}

mem_tree_rss_mb() { # <dir> -> mb
  local dir="${1:-}"
  [ -n "$dir" ] || { printf 0; return 0; }
  if [ -n "$MEM_SNAPSHOT" ]; then
    printf '%s\n' "$MEM_SNAPSHOT" | mem_tree_sum "$dir"
  else
    mem_tree_list | mem_tree_sum "$dir"
  fi
}

# `total_mb available_mb used_pct` from /proc/meminfo. AVAILABLE, not free:
# free is the number that panics people (this box shows a few hundred MB free
# and 7 GB available, because the page cache is doing its job), and available
# is the kernel's own estimate of what a new process could actually have.
#
# CEL_MEMINFO exists for the suite: a test may not arrange a box at 5%
# available, and the steward's whole behaviour hangs on that number.
#
# An unreadable meminfo is UNKNOWN and prints zeroes. Every caller is a view
# or a warning, and none of them may turn "could not ask" into a crisis: the
# steward checks for a total before it says anything at all.
mem_box() { # -> total_mb available_mb used_pct
  awk '
    /^MemTotal:/     { t = $2 }
    /^MemAvailable:/ { a = $2 }
    END {
      if (t + 0 <= 0) { print "0 0 0"; exit }
      printf "%d %d %d\n", t / 1024, a / 1024, (t - a) * 100 / t
    }' "${CEL_MEMINFO:-/proc/meminfo}" 2>/dev/null || printf '0 0 0\n'
}

# Megabytes as an operator says them out loud: `370M`, `6.9G`, `24G`. One
# decimal under ten gigabytes because 6G and 6.9G are a gigabyte apart, none
# above it because nobody says "24.0 gigs".
mem_human() { # <mb>
  local mb="${1:-0}"
  [[ "$mb" =~ ^[0-9]+$ ]] || mb=0
  if [ "$mb" -lt 1024 ]; then printf '%dM' "$mb"; return 0; fi
  awk -v mb="$mb" 'BEGIN { g = mb / 1024; printf (g >= 10 ? "%.0fG" : "%.1fG"), g }'
}
