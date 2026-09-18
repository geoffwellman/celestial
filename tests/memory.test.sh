# shellcheck shell=bash
# lib/memory.sh - the only thing on this box that can say what a worker costs.
#
# A fixture `/proc` is not possible: the kernel owns it, and a directory of
# fake `status` files would prove that awk works rather than that the walk
# finds a real process. So the tree functions are driven against a REAL child
# whose cwd is a temporary directory - the exact relationship the walk exists
# to measure - and `mem_box` is driven against a fixture meminfo through
# `CEL_MEMINFO`, because a box at 5% available is not something a test may
# arrange.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/memory.sh"

# 24 GB total, ~6.9 GB available: this box, mid-afternoon, with agents up.
_mem_meminfo() { # <total-kb> <available-kb>
  printf 'MemTotal:       %s kB\nMemFree:         123456 kB\nMemAvailable:   %s kB\nBuffers:          1000 kB\n' "$1" "$2"
}

test_mem_box_reads_total_available_and_the_percentage_used() {
  local T; T="$(mktemp -d)"
  _mem_meminfo 25165824 7235174 >"$T/meminfo"
  local total avail used
  read -r total avail used <<<"$(CEL_MEMINFO="$T/meminfo" mem_box)"
  assert_eq "$total" "24576"
  assert_eq "$avail" "7065"
  assert_eq "$used" "71"
  rm -rf "$T"
}

# A meminfo that cannot be read is UNKNOWN, and unknown must not render as a
# box with no memory at all - every caller here is a view, and a view that
# invents "0 MB total" would have the steward reporting a box in crisis
# because a file moved.
test_mem_box_reports_zeroes_rather_than_failing_when_meminfo_is_absent() {
  local out
  out="$(CEL_MEMINFO=/nonexistent/meminfo mem_box)"
  assert_eq "$out" "0 0 0"
}

# The unit an operator says out loud. 370M, not 370.4M; 24G, not 24.0G - and
# one decimal below ten, because 6G and 6.9G are a gigabyte apart.
test_mem_human_reads_the_way_an_operator_says_it() {
  assert_eq "$(mem_human 370)" "370M"
  assert_eq "$(mem_human 1023)" "1023M"
  assert_eq "$(mem_human 7065)" "6.9G"
  assert_eq "$(mem_human 24576)" "24G"
  assert_eq "$(mem_human 0)" "0M"
  assert_eq "$(mem_human '')" "0M"
}

# THE MEASUREMENT ITSELF, against a process that really exists. Every process
# whose cwd is under a worker's worktree is that worker's - the shell, the
# agent, its tools and its test runs - which is the whole premise of the
# ticket, so it is proved rather than asserted in a comment.
test_mem_tree_rss_mb_counts_a_real_child_and_leaves_a_sibling_at_zero() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/mine/sub" "$T/sibling"
  local pid
  ( cd "$T/mine/sub" && exec sleep 300 ) &
  pid=$!
  # shellcheck disable=SC2064
  trap "kill $pid 2>/dev/null || true" EXIT INT TERM

  local i=0
  while [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" != "$T/mine/sub" ] && [ "$i" -lt 100 ]; do
    sleep 0.05; i=$((i + 1))
  done
  assert_eq "$(readlink "/proc/$pid/cwd")" "$T/mine/sub"

  local kb mb
  kb="$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status")"
  mb="$(mem_tree_rss_mb "$T/mine")"
  # A NESTED cwd belongs to the tree above it: a gate run happens in a
  # subdirectory of the worktree and is still the worker's memory.
  [ "$mb" -ge "$((kb / 1024))" ] || { echo "tree reported ${mb}M, under the child's ${kb}kB"; kill "$pid"; rm -rf "$T"; return 1; }
  # ...and a directory beside it is not: prefix matching that answered "yes"
  # for /tmp/x-2 when asked about /tmp/x would attribute one worker's memory
  # to another, which is worse than reporting none.
  assert_eq "$(mem_tree_rss_mb "$T/sibling")" "0"
  assert_eq "$(mem_tree_rss_mb "$T/min")" "0"
  assert_eq "$(mem_tree_rss_mb '')" "0"
  # The walk saw the process at all - without this the assertions above pass
  # on an empty list.
  assert_contains "$(mem_tree_list)" "$T/mine/sub"

  kill "$pid" 2>/dev/null || true
  trap - EXIT INT TERM
  rm -rf "$T"
}

# The sum is arithmetic over a cwd → rss list, and the list is built ONCE per
# fleet read. Driving the sum directly is how the megabyte arithmetic is
# proved without needing a process that happens to be 2 GB.
test_mem_tree_sum_adds_every_process_under_the_directory() {
  local list
  list="$(printf '%s\n' \
    $'1048576\t/w/one' \
    $'524288\t/w/one/sub' \
    $'2097152\t/w/two' \
    $'4096\t/w/onetwo')"
  assert_eq "$(printf '%s\n' "$list" | mem_tree_sum /w/one)" "1536"
  assert_eq "$(printf '%s\n' "$list" | mem_tree_sum /w/one/)" "1536"
  assert_eq "$(printf '%s\n' "$list" | mem_tree_sum /w/two)" "2048"
  assert_eq "$(printf '%s\n' "$list" | mem_tree_sum /w/three)" "0"
}

# ONE WALK PER FLEET READ, not one per worker: the whole box costs under 50 ms
# once and 40 ms again for every worker after that. The snapshot is the
# mechanism, so the snapshot is what is asserted - a second call must not go
# back to /proc.
test_mem_tree_snapshot_is_reused_by_every_later_read() {
  mem_tree_snapshot
  assert_contains "$MEM_SNAPSHOT" "/"
  MEM_SNAPSHOT="$(printf '%s\n' $'2097152\t/w/snap')"
  assert_eq "$(mem_tree_rss_mb /w/snap)" "2048"
  mem_tree_snapshot_clear
  assert_eq "$MEM_SNAPSHOT" ""
  assert_eq "$(mem_tree_rss_mb /w/snap)" "0"
}
