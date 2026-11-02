# shellcheck shell=bash
# What a worker actually costs, and what the box has left.
#
# THE CWD IS THE HANDLE. herdr exposes no pid for a pane, so every process
# whose working directory is under a worker's worktree is that worker's: the
# shell, the agent, its tools and its test runs. It is an attribution, not a
# containment boundary: a process that chdirs elsewhere leaves the tree.
#
# PSS, NOT RSS, WHERE READABLE: summed RSS counts every shared page once per
# process mapping it. RSS is the fallback where smaps_rollup is unreadable.
[ -n "${_CEL_MEMORY:-}" ] && return 0
_CEL_MEMORY=1

# ONE /proc WALK PER SNAPSHOT: a fleet read asks about every worker, and a walk
# per question scales with the worker count. The snapshot is a plain string
# (kB TAB cwd per line, PSS or RSS) so every later sum is arithmetic.
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
  # A fixed number of processes for the whole box, never per pid (per-pid forks
  # took seconds). `ls -l` prints every cwd link with its owner in column 3 -
  # only this user's processes are ours to read. Vanished pids drop out.
  local me; me="$(id -un)" proc="${CEL_PROC:-/proc}"
  {
    # `|| true` on both: unreadable cwd links and vanished pids make ls/awk
    # exit non-zero, which under set -e and pipefail kills the fleet call.
    # The glob is the top level only: `task/<tid>` entries are threads, each
    # repeating its whole process's memory, and are never walked.
    { ls -l "$proc"/[0-9]*/cwd 2>/dev/null || true; } | awk -v me="$me" '$3 == me { i = NF - 2; p = $i; sub(/\/cwd$/, "", p); sub(/.*\//, "", p); print "C\t" p "\t" $NF }'
    # grep -s, not awk over the files: gawk aborts the whole run when one
    # status file vanishes between the glob and the open.
    { grep -Hs '^VmRSS:' "$proc"/[0-9]*/status || true; } | awk -F'[:[:space:]]+' '{ p = $1; sub(/\/status$/, "", p); sub(/.*\//, "", p); print "R\t" p "\t" $3 }'
    # PSS where the kernel offers it; a tree's PSS sum is what it costs.
    { grep -Hs '^Pss:' "$proc"/[0-9]*/smaps_rollup || true; } | awk -F'[:[:space:]]+' '{ p = $1; sub(/\/smaps_rollup$/, "", p); sub(/.*\//, "", p); print "P\t" p "\t" $3 }'
  } | awk -F'\t' '
    $1 == "C" { cwd[$2] = $3 }
    $1 == "R" { rss[$2] = $3 }
    $1 == "P" { pss[$2] = $3 }
    END { for (p in cwd) if (cwd[p] != "") { if (p in pss) printf "%s\t%s\n", pss[p], cwd[p]; else if (p in rss) printf "%s\t%s\n", rss[p], cwd[p] } }'
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

# Named rss for the published fields (rss_mb etc.); the value is PSS, RSS fallback.
mem_tree_rss_mb() { # <dir> -> mb (PSS, RSS fallback)
  local dir="${1:-}"
  [ -n "$dir" ] || { printf 0; return 0; }
  if [ -n "$MEM_SNAPSHOT" ]; then
    printf '%s\n' "$MEM_SNAPSHOT" | mem_tree_sum "$dir"
  else
    mem_tree_list | mem_tree_sum "$dir"
  fi
}

# `total_mb available_mb used_pct` from /proc/meminfo. AVAILABLE, not free:
# free excludes reclaimable page cache; available is the kernel's estimate of
# what a new process could actually have.
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
