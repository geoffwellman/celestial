# shellcheck shell=bash
# lib/box.sh - the box itself is a resource the factory spends.
#
# The plane measured its machines and never its floor space, so the first
# symptom of a full disk was a build failing rather than a dashboard going
# amber, and the only remedy anyone had was a human remembering to run
# `docker system prune` by hand. Measured 2026-09-20: 144G of 193G used, of
# which `cel gc` knew about 9.3G (worker worktrees), Docker held ~74G with 41G
# of images, 8.7G of build cache and a 3.5G exited container reclaimable right
# then, and toolchain caches another 10G that regenerates on demand. The word
# "docker" did not appear anywhere in lib, bin, core or tools.
#
# THREE KINDS OF LITTER, AND THEY ARE NOT ALIKE:
#   ours         the factory made it (worktrees, ~/.cache/cel, scratch)
#   regenerable  toolchain and build caches; deleting costs a re-download
#   someones     restore dumps, dated backups, old checkouts - large,
#                irreplaceable, and NOT the janitor's to delete
#
# THE RULE THIS FILE ENCODES: a sweeper may delete only what the box can make
# again. Everything else is a number on a report.
#
# A sweeper NEVER takes a path from argv. Each one reads the policy table
# below, so there is no call shape that can be pointed at a home directory by
# mistake, and every removal goes through _box_rm, which refuses anything that
# is not inside a declared sweepable root.
[ -n "${_CEL_BOX:-}" ] && return 0
_CEL_BOX=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/run.sh
. "$(dirname "${BASH_SOURCE[0]}")/run.sh"   # the reviewer registry, for the report

# FOURTEEN DAYS on images and build cache. The working set on a real box is
# three to six days old and the superseded build tags are two weeks and older;
# seven days would evict an image somebody is still bisecting against, and
# thirty frees almost nothing extra. Exited containers carry no age filter at
# all: nothing depends on a dead container.
_BOX_DOCKER_AGE_DAYS=14
_BOX_DOCKER_UNTIL=336h   # the same 14 days in the units docker's filter wants

# Overridable so the suite can drive the sweepers against a docker that is
# deliberately not resolvable - the "docker absent is a normal box" case - and
# so no test can ever reach the real daemon by accident. Production leaves it
# unset and resolves plain `docker` on PATH.
_box_docker_bin() { printf '%s' "${CEL_BOX_DOCKER:-docker}"; }

# The keep list. Re-pulling a 13M base image to save nothing is a bad trade,
# however old the local copy is, so base images are exempt regardless of age.
# A repository containing a `/` with no local build history is a pull, not
# something this box made.
_box_docker_keep_patterns() { printf '%s\n' 'ubuntu:*' 'alpine:*'; }

# THE POLICY TABLE. class <TAB> path <TAB> age_days.
#
# Rooted at $HOME rather than at absolute literals so the suite can point a
# fixture home at it, and so a sweeper on a box with a relocated home is
# sweeping that home rather than somebody else's.
#
# Worktrees are deliberately NOT here. They stay in cmd_gc, whose logic
# carries PR-state and live-delegation vetoes that this file must not
# duplicate or weaken.
_box_policy() {
  cat <<EOS
regenerable	$HOME/.bun/install/cache	14
regenerable	$HOME/.npm/_cacache	14
regenerable	$HOME/.cache/uv	14
regenerable	$HOME/.cache/pip	14
regenerable	$HOME/.cache/ms-playwright	30
regenerable	$HOME/.cache/puppeteer	30
regenerable	$HOME/.cache/selenium	30
ours	$HOME/.cache/cel	7
ours	$HOME/.local/state/cel/scratch	3
someones	$HOME/restore	0
someones	$HOME/backups	0
EOS
}

_box_policy_class() { # <class> - the rows of one class only
  _box_policy | awk -F'\t' -v c="$1" '$1 == c'
}

# ------------------------------------------------------------------ measuring

# `-x` never crosses a filesystem and `-P` never follows a symlink: a cache
# directory that is a link to somebody's data drive must measure as the link,
# not as the drive. `-b` because a report in blocks is a report nobody can
# compare against `docker system df`.
_box_bytes() { # <path> -> bytes, 0 when absent or unreadable
  local n
  [ -e "$1" ] || { printf 0; return 0; }
  n="$(du -x -s -b -P -- "$1" 2>/dev/null | awk 'NR==1{print $1}')" || n=""
  case "$n" in ''|*[!0-9]*) n=0;; esac
  printf '%s' "$n"
}

# Docker prints sizes for humans ("8.7GB (21%)"), and every number this file
# reports has to add up with every other one, so they are converted once here.
# Docker uses decimal units for kB/MB/GB and binary ones only when it says
# KiB/MiB/GiB; treating them alike overstates a 41G image store by 10%.
_box_human_bytes() { # <human size> -> bytes
  printf '%s' "$1" | awk '
    { s = $0
      sub(/ *\(.*\)$/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", s)
      if (match(s, /^[0-9.]+/) == 0) { print 0; exit }
      n = substr(s, 1, RLENGTH) + 0
      u = substr(s, RLENGTH + 1); gsub(/[ \t]/, "", u)
      m = 1
      if (u == "kB" || u == "KB" || u == "k") m = 1000
      else if (u == "MB") m = 1000000
      else if (u == "GB") m = 1000000000
      else if (u == "TB") m = 1000000000000
      else if (u == "KiB") m = 1024
      else if (u == "MiB") m = 1048576
      else if (u == "GiB") m = 1073741824
      else if (u == "TiB") m = 1099511627776
      printf "%d\n", n * m + 0.5 }'
}

box_human() { # <bytes> -> the same units docker prints, for a human reader
  printf '%s' "$1" | awk '
    { b = $0 + 0
      split("B kB MB GB TB", u, " ")
      i = 1
      while (b >= 1000 && i < 5) { b /= 1000; i++ }
      if (i == 1) printf "%d %s\n", b, u[i]; else printf "%.1f %s\n", b, u[i] }'
}

# Direct children older than <days>, and ONLY direct children: a cache root is
# never removed, because a missing root is a tool that reinstalls itself
# rather than a cache that refills. `-newermt` rather than `-mtime`, which
# rounds to whole days and would sweep an entry a few hours short of its age.
_box_aged_entries() { # <root> <days>
  [ -d "$1" ] || return 0
  find "$1" -mindepth 1 -maxdepth 1 ! -newermt "$2 days ago" -print 2>/dev/null || true
}

_box_aged_bytes() { # <root> <days> -> bytes an age sweep of this root would free
  local total=0 e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    total=$(( total + $(_box_bytes "$e") ))
  done < <(_box_aged_entries "$1" "$2")
  printf '%s' "$total"
}

# Days since the most recent change anywhere under a path. This is what a
# reader wants next to a 15G dump: not the policy threshold, which is zero for
# anything the janitor may not touch, but how long it has been sitting there.
_box_age_days() { # <path> -> whole days, 0 when absent
  local newest now
  [ -e "$1" ] || { printf 0; return 0; }
  newest="$(find "$1" -printf '%T@\n' 2>/dev/null | sort -n | tail -1)" || newest=""
  case "$newest" in ''|*[!0-9.]*) printf 0; return 0;; esac
  newest="${newest%%.*}"
  now="$(date +%s)"
  printf '%s' $(( (now - newest) / 86400 ))
}

_box_free_bytes() { # free bytes on the filesystem holding $HOME
  local n
  n="$(df -P -B1 "$HOME" 2>/dev/null | awk 'NR==2{print $4}')" || n=""
  case "$n" in ''|*[!0-9]*) return 1;; esac
  printf '%s' "$n"
}

# ------------------------------------------------------------------- removing

# THE ONLY DELETION IN THIS FILE, and it checks the policy again rather than
# trusting its caller. A sweeper that has been handed a path is a sweeper
# somebody will one day hand a home directory.
_box_rm() { # <path>
  local p="$1" class root age ok=0
  while IFS=$'\t' read -r class root age; do
    [ -n "$root" ] || continue
    case "$class" in ours|regenerable) ;; *) continue;; esac
    [ "$p" = "$root" ] && continue    # never the root itself, only entries
    case "$p" in "$root"/*) ok=1; break;; esac
  done < <(_box_policy)
  [ "$ok" -eq 1 ] || { c_warn "box: refused to remove $p - not inside a sweepable root"; return 1; }
  if [ -n "${CEL_BOX_RM_LOG:-}" ]; then printf '%s\n' "$p" >> "$CEL_BOX_RM_LOG"; fi
  rm -rf -- "$p"
}

# ------------------------------------------------------------------ the docker

_box_docker_df() { # the raw rows of `docker system df --format json`
  "$(_box_docker_bin)" system df --format json 2>/dev/null || true
}

_box_docker_row() { # <rows> <Type> -> size<TAB>reclaimable in bytes
  local row size recl
  row="$(printf '%s\n' "$1" | jq -c --arg t "$2" 'select(.Type == $t)' 2>/dev/null | sed -n 1p)" || row=""
  if [ -z "$row" ]; then printf '0\t0'; return 0; fi
  size="$(_box_human_bytes "$(printf '%s' "$row" | jq -r '.Size // "0B"')")"
  recl="$(_box_human_bytes "$(printf '%s' "$row" | jq -r '.Reclaimable // "0B"')")"
  printf '%s\t%s' "$size" "$recl"
}

box_docker_json() { # the docker half of the report, or nothing when absent
  have "$(_box_docker_bin)" || return 1
  local rows img con vol bld
  rows="$(_box_docker_df)"
  [ -n "$rows" ] || return 1
  IFS=$'\t' read -r img_s img_r <<< "$(_box_docker_row "$rows" Images)"
  IFS=$'\t' read -r con_s con_r <<< "$(_box_docker_row "$rows" Containers)"
  IFS=$'\t' read -r vol_s vol_r <<< "$(_box_docker_row "$rows" "Local Volumes")"
  IFS=$'\t' read -r bld_s bld_r <<< "$(_box_docker_row "$rows" "Build Cache")"
  jq -n \
    --argjson is "$img_s" --argjson ir "$img_r" \
    --argjson cs "$con_s" --argjson cr "$con_r" \
    --argjson vs "$vol_s" --argjson vr "$vol_r" \
    --argjson bs "$bld_s" --argjson br "$bld_r" \
    '{images:{size:$is,reclaimable:$ir},
      containers:{size:$cs,reclaimable:$cr},
      volumes:{size:$vs,reclaimable:$vr},
      build_cache:{size:$bs,reclaimable:$br}}'
}

_box_docker_keep() { # <repository> <tag> <id> -> 0 keep, 1 removable
  local repo="$1" tag="$2" id="$3" pat parent
  while IFS= read -r pat; do
    # shellcheck disable=SC2053
    [[ "$repo:$tag" == $pat ]] && return 0
  done < <(_box_docker_keep_patterns)
  case "$repo" in
    */*)
      # A registry-qualified name with no local parent layer was pulled, not
      # built here: removing it buys a re-pull and nothing else.
      parent="$("$(_box_docker_bin)" image inspect -f '{{.Parent}}' "$id" 2>/dev/null || true)"
      [ -z "${parent//[[:space:]]/}" ] && return 0 ;;
  esac
  return 1
}

# `docker image prune` without `-a` only ever takes dangling layers, so the
# superseded build tags that are most of the 41G survive it. They are removed
# by name here instead, which is also the only way the keep list can exist at
# all: a prune filter cannot say "except the base images".
_box_docker_aged_images() { # -> id<TAB>bytes
  local cutoff line id repo tag created size when
  cutoff="$(date -d "$_BOX_DOCKER_AGE_DAYS days ago" +%s 2>/dev/null)" || return 0
  while IFS=$'\t' read -r id repo tag created size; do
    [ -n "$id" ] || continue
    [ "$repo" = "<none>" ] && continue   # dangling; the prune above owns those
    when="$(date -d "${created% UTC}" +%s 2>/dev/null)" || continue
    [ "$when" -lt "$cutoff" ] || continue
    _box_docker_keep "$repo" "$tag" "$id" && continue
    printf '%s\t%s\n' "$id" "$(_box_human_bytes "$size")"
  done < <("$(_box_docker_bin)" image ls --format json 2>/dev/null \
    | jq -r '[.ID, .Repository, .Tag, .CreatedAt, .Size] | @tsv' 2>/dev/null || true)
}

_box_reclaimed() { # <prune output> -> bytes, from docker's own summary line
  local line
  line="$(printf '%s\n' "$1" | sed -n 's/^Total reclaimed space: //p' | sed -n 1p)"
  [ -n "$line" ] || { printf 0; return 0; }
  _box_human_bytes "$line"
}

# THERE IS NO "PRUNE AND REPORT" PATH. A dry run asks `docker system df` what
# is reclaimable and calls nothing that can remove anything, because a sweeper
# that removes during a dry run is a sweeper whose dry run nobody trusts -
# and the first time it matters is the time somebody was checking.
_box_sweep_docker() { # <dry> -> bytes on stdout; exit 2 when docker is absent
  local dry="${1:-0}" freed=0 out id bytes json
  have "$(_box_docker_bin)" || { printf 0; return 2; }
  if [ "$dry" -eq 1 ]; then
    json="$(box_docker_json)" || { printf 0; return 2; }
    printf '%s' "$json" | jq -r '.images.reclaimable + .containers.reclaimable + .build_cache.reclaimable | floor'
    return 0
  fi
  out="$("$(_box_docker_bin)" container prune --force 2>/dev/null || true)"
  freed=$(( freed + $(_box_reclaimed "$out") ))
  out="$("$(_box_docker_bin)" image prune --force --filter "until=$_BOX_DOCKER_UNTIL" 2>/dev/null || true)"
  freed=$(( freed + $(_box_reclaimed "$out") ))
  while IFS=$'\t' read -r id bytes; do
    [ -n "$id" ] || continue
    "$(_box_docker_bin)" image rm "$id" >/dev/null 2>&1 || continue
    freed=$(( freed + bytes ))
  done < <(_box_docker_aged_images)
  out="$("$(_box_docker_bin)" builder prune --force --filter "until=$_BOX_DOCKER_UNTIL" 2>/dev/null || true)"
  freed=$(( freed + $(_box_reclaimed "$out") ))
  printf '%s' "$freed"
}

# ----------------------------------------------------------- the path sweepers

# Shared by the two sweepable classes. It takes a CLASS, never a path: the
# argument a caller can get wrong is the name of a policy row, and the worst a
# wrong one can do is sweep nothing.
_box_sweep_class() { # <class> <dry> -> bytes
  local class="$1" dry="${2:-0}" total=0 root age e n
  while IFS=$'\t' read -r _ root age; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      n="$(_box_bytes "$e")"
      if [ "$dry" -eq 1 ]; then total=$(( total + n )); continue; fi
      _box_rm "$e" || continue
      total=$(( total + n ))
    done < <(_box_aged_entries "$root" "$age")
  done < <(_box_policy_class "$class")
  printf '%s' "$total"
}

# Package manager caches and browser driver downloads: deleting one costs a
# re-download and never data.
#
# Each tool's own eviction is used where it HAS one that honours an age, and
# none of the three big ones does: `bun pm cache rm` and `npm cache clean
# --force` are all-or-nothing, which throws away the working set along with
# the stale part, and `uv cache prune` removes unreachable entries rather than
# old ones. Age on the entries is the only policy that keeps this week's
# downloads, so that is what this does.
_box_sweep_caches() { _box_sweep_class regenerable "${1:-0}"; }

# What the factory itself made. Worktrees are NOT here - see the policy table.
_box_sweep_ours() { _box_sweep_class ours "${1:-0}"; }

# ------------------------------------------------------------------- the sweep

# A CLASS THAT FOUND NOTHING SAYS SO RATHER THAN VANISHING, so "did it run?"
# is never a question the summary leaves open. Results also land in
# BOX_FREED_* for a caller that wants to put them in its own summary line.
box_sweep() { # <dry> -> one line per class on stdout
  local dry="${1:-0}" b
  BOX_FREED_DOCKER=0 BOX_FREED_CACHES=0 BOX_FREED_OURS=0 BOX_DOCKER_SKIPPED=0
  if b="$(_box_sweep_docker "$dry")"; then
    BOX_FREED_DOCKER="$b"
    c_ok "box: docker $(box_human "$b")$([ "$dry" -eq 1 ] && printf ' would be freed' || printf ' freed')"
  else
    BOX_DOCKER_SKIPPED=1
    c_warn "box: docker skipped - docker is not on PATH"
  fi
  b="$(_box_sweep_caches "$dry")"; BOX_FREED_CACHES="$b"
  c_ok "box: caches $(box_human "$b")$([ "$dry" -eq 1 ] && printf ' would be freed' || printf ' freed')"
  b="$(_box_sweep_ours "$dry")"; BOX_FREED_OURS="$b"
  c_ok "box: ours $(box_human "$b")$([ "$dry" -eq 1 ] && printf ' would be freed' || printf ' freed')"
  return 0
}

box_summary_fragment() { # the per-class bytes cel gc appends to its own line
  printf ', box: docker %s, caches %s, ours %s' \
    "$([ "${BOX_DOCKER_SKIPPED:-0}" -eq 1 ] && printf skipped || box_human "${BOX_FREED_DOCKER:-0}")" \
    "$(box_human "${BOX_FREED_CACHES:-0}")" "$(box_human "${BOX_FREED_OURS:-0}")"
}

# ------------------------------------------------------------ the reviewers

# 3 GB of idle reviewer panes is a bigger number than most of the disk rows
# above, and it was invisible: this report measured the floor and never the
# agents standing on it. `box memory low: 1.4G of 23G available` went into
# root's mailbox all day on 2026-09-21 and nothing anywhere could name the
# seven reviewer panes that were most of it.
#
# Bytes, not kB, so the number adds up with every other one here. A pane
# whose process cannot be read counts in the total as zero rather than
# vanishing from the count: how many there are is knowable from the registry
# alone, and a reader who sees the count knows the sweep has something to do.
box_reviewers_json() { # -> {count, bytes}
  local rows n=0 total=0 pane info pid rss
  rows="$(reviewers_rows 2>/dev/null)" || rows='[]'
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    n=$(( n + 1 ))
    have herdr && have jq || continue
    info="$(herdr pane process-info --pane "$pane" 2>/dev/null)" || continue
    pid="$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0].pid // empty' 2>/dev/null)" || continue
    case "$pid" in ''|*[!0-9]*) continue;; esac
    rss="$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)" || rss=""
    case "$rss" in ''|*[!0-9]*) continue;; esac
    total=$(( total + rss * 1024 ))
  done < <(printf '%s' "$rows" | jq -r '.[].pane // empty' 2>/dev/null)
  printf '{"count":%d,"bytes":%d}' "$n" "$total"
}

# -------------------------------------------------------------- the report

# EVERY NUMBER IS MEASURED, NEVER REMEMBERED. There is no cache file: a stale
# size is worse than a slow command, and the reader is a human who asked once.
_box_space_rows() { # class<TAB>path<TAB>bytes<TAB>reclaimable<TAB>age_days
  local class root age bytes recl
  while IFS=$'\t' read -r class root age; do
    [ -n "$root" ] || continue
    [ -e "$root" ] || continue
    bytes="$(_box_bytes "$root")"
    case "$class" in
      someones) recl=0 ;;   # irreplaceable: nothing here is reclaimable, ever
      *) recl="$(_box_aged_bytes "$root" "$age")" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$class" "$root" "$bytes" "$recl" "$(_box_age_days "$root")"
  done < <(_box_policy)
}

# Sorted by RECLAIMABLE, not total: a 15G dump nobody may touch is less
# interesting than 8.7G of build cache, and a table sorted by size buries the
# only rows anybody can act on.
box_space_json() {
  local rows docker reviewers
  rows="$(_box_space_rows)"
  docker="$(box_docker_json 2>/dev/null)" || docker=null
  reviewers="$(box_reviewers_json)"
  printf '%s\n' "$rows" | jq -R -s --argjson docker "${docker:-null}" --argjson reviewers "$reviewers" '
    [ split("\n")[] | select(length > 0) | split("\t")
      | {path: .[1], class: .[0], bytes: (.[2]|tonumber),
         reclaimable: (.[3]|tonumber), age_days: (.[4]|tonumber)} ]
    | sort_by(-.reclaimable)
    | {paths: ., docker: $docker, reviewers: $reviewers}'
}

_box_space_table() {
  local json; json="$(box_space_json)"
  printf '  %-12s %12s %12s %6s  %s\n' CLASS RECLAIMABLE TOTAL AGE PATH
  local class path bytes recl age
  while IFS=$'\t' read -r class path bytes recl age; do
    [ -n "$path" ] || continue
    printf '  %-12s %12s %12s %5sd  %s\n' \
      "$class" "$(box_human "$recl")" "$(box_human "$bytes")" "$age" "$path"
  done < <(printf '%s' "$json" | jq -r '.paths[] | [.class,.path,.bytes,.reclaimable,.age_days] | @tsv')
  # Docker rows only when there is a docker. Its absence is a normal box, not
  # a fault: the rows are simply not there and the command still exits 0.
  if printf '%s' "$json" | jq -e '.docker != null' >/dev/null 2>&1; then
    while IFS=$'\t' read -r name bytes recl; do
      printf '  %-12s %12s %12s %5sd  %s\n' \
        docker "$(box_human "$recl")" "$(box_human "$bytes")" "$_BOX_DOCKER_AGE_DAYS" "docker: $name"
    done < <(printf '%s' "$json" | jq -r '.docker | to_entries[] | [.key, .value.size, .value.reclaimable] | @tsv' \
      | sort -t$'\t' -k3 -nr)
  fi
  # The agents standing on the floor, always - zero is a measurement and an
  # absent row is not. The remedy is `cel gc`, which closes exactly the ones
  # whose pull request is finished and leaves the working ones alone.
  local rcount rbytes
  IFS=$'\t' read -r rcount rbytes < <(printf '%s' "$json" | jq -r '[.reviewers.count, .reviewers.bytes] | @tsv')
  printf '  %-12s %12s %12s %6s  %s\n' \
    reviewers "$(box_human "$rbytes")" "$(box_human "$rbytes")" "-" \
    "$rcount reviewer panes - cel gc closes the ones whose PR is merged or closed"
  # And the part the janitor may not touch, said in words rather than left as
  # a row somebody might read as a to-do list.
  local untouchable
  untouchable="$(printf '%s' "$json" | jq -r '.paths[] | select(.class == "someones") | [.path,.bytes,.age_days] | @tsv')"
  if [ -n "$untouchable" ]; then
    printf '\n  not the janitor'"'"'s to delete - reported only:\n'
    while IFS=$'\t' read -r path bytes age; do
      [ -n "$path" ] || continue
      printf '    %s  %s, untouched %s days - move it off the box or delete it yourself\n' \
        "$path" "$(box_human "$bytes")" "$age"
    done <<< "$untouchable"
  fi
  return 0
}

cmd_box() { # space [--json]
  local verb="${1:-space}"
  shift || true
  case "$verb" in
    space)
      case "${1:-}" in
        --json) box_space_json ;;
        '') _box_space_table ;;
        *) die "cel box space: unknown argument '$1' (want --json)" ;;
      esac ;;
    *) die "cel box: unknown subcommand '$verb' (want space)" ;;
  esac
}

# ONE LINE FOR cel doctor. A full disk should be diagnosed before it is a
# build failure, and the finding names the largest reclaimable class and the
# command that clears it - a diagnosis whose remedy the reader has to go and
# look up is half a diagnosis.
box_doctor_line() {
  local floor free json largest remedy
  floor="${CEL_BOX_FREE_FLOOR_GB:-20}"
  case "$floor" in ''|*[!0-9]*) return 0;; esac
  free="$(_box_free_bytes)" || return 0
  [ "$free" -lt $(( floor * 1000000000 )) ] || return 0
  json="$(box_space_json 2>/dev/null)" || return 0
  largest="$(printf '%s' "$json" | jq -r '
    ((.paths | map({name: .class, bytes: .reclaimable}))
      + (if .docker == null then [] else (.docker | to_entries | map({name: ("docker " + .key), bytes: .value.reclaimable})) end)
      + [{name: "reviewer panes", bytes: (.reviewers.bytes // 0)}])
    | sort_by(-.bytes) | .[0] // {name:"nothing", bytes:0}
    | "\(.name) \(.bytes)"')"
  # THE REMEDY BELONGS IN THE FINDING. When the largest reclaimable thing is
  # a pile of finished reviewers, `cel gc --box` is the wrong instruction:
  # the plain sweep is what closes them, and sending a reader to the docker
  # flag for a memory problem is how three gigabytes stayed put for a day.
  remedy="cel gc --box clears it, cel box space shows the rest"
  case "${largest% *}" in
    "reviewer panes") remedy="cel gc closes every reviewer whose PR is merged or closed; cel box space shows the rest" ;;
  esac
  printf 'box: %s free (floor %sG) - largest reclaimable is %s; %s' \
    "$(box_human "$free")" "$floor" \
    "$(printf '%s' "${largest% *}") $(box_human "${largest##* }")" "$remedy"
}
