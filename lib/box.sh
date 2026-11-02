# shellcheck shell=bash
# lib/box.sh - the box itself is a resource the factory spends.
#
# Reports disk use by class and sweeps what the box can regenerate.
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
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/run.sh
. "${BASH_SOURCE[0]%/*}/run.sh"   # the reviewer registry, for the report

# The AGE column shown for the docker rows. The docker sweep itself has no age
# filter: it removes every unused image and all build cache.
_BOX_DOCKER_AGE_DAYS=14

# Overridable so the suite can drive the sweepers against a docker that is
# deliberately not resolvable - the "docker absent is a normal box" case - and
# so no test can ever reach the real daemon by accident. Production leaves it
# unset and resolves plain `docker` on PATH.
_box_docker_bin() { printf '%s' "${CEL_BOX_DOCKER:-docker}"; }

# The keep list. Re-pulling a base image to save nothing is a bad trade, so
# base images are exempt regardless of age.
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
# KiB/MiB/GiB; treating them alike overstates sizes by up to 10%.
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

# With a timeout (whole seconds) the query is bounded and an unanswered one -
# no `timeout` on the box, a daemon that hangs, a socket this user may not
# open - returns 1 instead of waiting or guessing.
_box_docker_df() { # [timeout-secs] -> the raw rows of `docker system df --format json`
  local -a cmd=("$(_box_docker_bin)" system df --format json)
  if [ -n "${1:-}" ]; then
    have timeout || return 1
    cmd=(timeout -k 2 "$1" "${cmd[@]}")
  fi
  "${cmd[@]}" 2>/dev/null
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
  rows="$(_box_docker_df)" || true
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

_box_docker_keep() { # <repository> <tag> -> 0 keep, 1 removable
  local repo="$1" tag="$2" pat
  while IFS= read -r pat; do
    # shellcheck disable=SC2053
    [[ "$repo:$tag" == $pat ]] && return 0
  done < <(_box_docker_keep_patterns)
  return 1
}

# What any container, running OR stopped, references. `docker container ls
# -a` prints a name (repo:tag, or bare repo meaning :latest) or an image id.
# A failed listing is NOT an empty one: it returns 1 with docker's error on
# stderr, and the sweep aborts rather than treating every image as unused.
_box_docker_in_use() {
  local out
  if ! out="$("$(_box_docker_bin)" container ls -a --format '{{.Image}}' 2>&1)"; then
    printf 'box: docker container ls failed: %s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

_box_docker_used() { # <in-use list> <id> <repo> <tag> -> 0 when referenced
  local ref short="${2#sha256:}"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      "$3:$4"|"$2") return 0 ;;
      sha256:*) [[ "$short" == "${ref#sha256:}"* || "${ref#sha256:}" == "$short"* ]] && return 0 ;;
    esac
    [ "$4" = latest ] && [ "$ref" = "$3" ] && return 0
    [[ "$ref" =~ ^[0-9a-f]{12,64}$ ]] && [[ "$short" == "$ref"* || "$ref" == "$short"* ]] && return 0
  done <<< "$1"
  return 1
}

# ONE SELECTION per sweep: the dry run prints it and the real run deletes it,
# so the two cannot disagree. An empty `{{.Parent}}` is no reason to keep:
# every BuildKit-built or pulled image has one.
_box_docker_plan() { # -> "image<TAB>id<TAB>bytes" lines, then "cache<TAB>-<TAB>bytes"; 1 when unknowable
  local used id repo tag size json
  local -A keep=() bytes=() order=()
  local -a ids=()
  used="$(_box_docker_in_use)" || return 1
  # Keep is decided per image ID: if ANY tag of an ID is keep-listed or in
  # use, the whole ID is kept. Each removable ID appears once.
  while IFS=$'\t' read -r id repo tag size; do
    [ -n "$id" ] || continue
    if [ -z "${order[$id]:-}" ]; then order[$id]=1; ids+=("$id"); bytes[$id]="$(_box_human_bytes "$size")"; fi
    if [ "$repo" != "<none>" ] && _box_docker_keep "$repo" "$tag"; then keep[$id]=1; continue; fi
    _box_docker_used "$used" "$id" "$repo" "$tag" && keep[$id]=1
  done < <("$(_box_docker_bin)" image ls --format json 2>/dev/null \
    | jq -r '[.ID, .Repository, .Tag, .Size] | @tsv' 2>/dev/null || true)
  for id in "${ids[@]}"; do
    [ -n "${keep[$id]:-}" ] && continue
    printf 'image\t%s\t%s\n' "$id" "${bytes[$id]}"
  done
  json="$(box_docker_json 2>/dev/null)" || json='{}'
  printf 'cache\t-\t%s\n' "$(printf '%s' "$json" | jq -r '(.build_cache.reclaimable // 0) | floor')"
}

_box_docker_images_reclaimable() { # -> bytes docker itself calls reclaimable
  local json; json="$(box_docker_json 2>/dev/null)" || { printf 0; return 0; }
  printf '%s' "$json" | jq -r '(.images.reclaimable // 0) | floor'
}

_box_reclaimed() { # <prune output> -> bytes, from docker's own summary line
  local line
  line="$(printf '%s\n' "$1" | sed -n 's/^Total reclaimed space: //p' | sed -n 1p)"
  [ -n "$line" ] || { printf 0; return 0; }
  _box_human_bytes "$line"
}

# A dry run calls nothing that can remove anything. Volumes are never
# touched, and containers are not pruned: a stopped container's image stays.
# A failed delete is a warning on stderr with docker's own error and exit 1,
# never a quiet "0 B freed".
_box_sweep_docker() { # <dry> -> bytes on stdout; exit 2 when absent, 1 on a failure
  # Dry: an UPPER BOUND (summed per-image sizes double-count shared layers).
  # Real: what docker says it freed - df delta for images, the prune's own
  # "Total reclaimed space" for build cache.
  local dry="${1:-0}" total=0 failed=0 kind id bytes err plan before after rmd=0
  have "$(_box_docker_bin)" || { printf 0; return 2; }
  "$(_box_docker_bin)" system df --format json >/dev/null 2>&1 || { printf 0; return 2; }
  plan="$(_box_docker_plan)" || { printf 0; return 1; }
  [ "$dry" -eq 1 ] || before="$(_box_docker_images_reclaimable)"
  while IFS=$'\t' read -r kind id bytes; do
    [ -n "$kind" ] || continue
    if [ "$dry" -eq 1 ]; then total=$(( total + bytes )); continue; fi
    case "$kind" in
      image)
        if err="$("$(_box_docker_bin)" image rm "$id" 2>&1 >/dev/null)"; then rmd=1
        else failed=1; printf 'box: docker image rm %s failed: %s\n' "$id" "$err" >&2; fi ;;
      cache)
        if err="$("$(_box_docker_bin)" builder prune --all --force 2>&1)"; then
          total=$(( total + $(_box_reclaimed "$err") ))
        else
          failed=1; printf 'box: docker builder prune failed: %s\n' "$err" >&2
        fi ;;
    esac
  done <<< "$plan"
  if [ "$rmd" -eq 1 ]; then
    after="$(_box_docker_images_reclaimable)"
    [ "$before" -gt "$after" ] && total=$(( total + before - after ))
  fi
  printf '%s' "$total"
  [ "$failed" -eq 0 ] || return 1
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
  local dry="${1:-0}" b rc=0 drc
  BOX_FREED_DOCKER=0 BOX_FREED_CACHES=0 BOX_FREED_OURS=0 BOX_DOCKER_SKIPPED=0 BOX_DOCKER_FAILED=0
  b="$(_box_sweep_docker "$dry")" && drc=0 || drc=$?
  if [ "$drc" -ne 2 ]; then
    BOX_FREED_DOCKER="${b:-0}"
    c_ok "box: docker $([ "$dry" -eq 1 ] && printf 'up to ')$(box_human "$BOX_FREED_DOCKER")$([ "$dry" -eq 1 ] && printf ' would be freed' || printf ' freed')"
    if [ "$drc" -ne 0 ]; then
      BOX_DOCKER_FAILED=1 rc=1
      c_warn "box: docker delete failed - see the docker error above"
    fi
  else
    BOX_DOCKER_SKIPPED=1
    c_warn "box: docker skipped - docker is not on PATH"
  fi
  b="$(_box_sweep_caches "$dry")"; BOX_FREED_CACHES="$b"
  c_ok "box: caches $(box_human "$b")$([ "$dry" -eq 1 ] && printf ' would be freed' || printf ' freed')"
  b="$(_box_sweep_ours "$dry")"; BOX_FREED_OURS="$b"
  c_ok "box: ours $(box_human "$b")$([ "$dry" -eq 1 ] && printf ' would be freed' || printf ' freed')"
  return "$rc"
}

box_summary_fragment() { # the per-class bytes cel gc appends to its own line
  printf ', box: docker %s, caches %s, ours %s' \
    "$([ "${BOX_DOCKER_SKIPPED:-0}" -eq 1 ] && printf skipped || box_human "${BOX_FREED_DOCKER:-0}")" \
    "$(box_human "${BOX_FREED_CACHES:-0}")" "$(box_human "${BOX_FREED_OURS:-0}")"
}

# ------------------------------------------------------------ the reviewers

# Idle reviewer panes can hold more than most disk rows, so they are reported.
#
# Bytes, not kB, so the number adds up with every other one here. A pane
# whose process cannot be read counts in the total as zero rather than
# vanishing from the count: how many there are is knowable from the registry
# alone, and a reader who sees the count knows the sweep has something to do.
box_reviewers_json() { # -> {count, bytes}
  local rows panes agents='{"result":{"agents":[]}}' agent backend n=0 total=0 pane info pid rss
  rows="$(reviewers_rows 2>/dev/null)" || rows='[]'
  panes="$(printf '%s' "$rows" | jq -r '.[].pane // empty' 2>/dev/null)"
  # The panes that are THERE, not only the registered ones: reviewers older
  # than the registry have no row.
  if have jq; then
    agents="$(cel_agent_list 2>/dev/null)" || agents='{"result":{"agents":[]}}'
    panes="$panes"$'\n'"$(reviewers_discover "$agents" | cut -f3)"
  fi
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    n=$(( n + 1 ))
    have jq || continue
    agent="$(printf '%s' "$agents" | jq -c --arg p "$pane" '[.result.agents[]? | select(.pane_id == $p)][0] // {}' 2>/dev/null)"
    backend="$(printf '%s' "$agent" | jq -r '.backend // "herdr"' 2>/dev/null)"
    if [ "$backend" = rex ] || [[ "$pane" == rex/* ]]; then
      pid="$(printf '%s' "$agent" | jq -r '.pid // empty' 2>/dev/null)"
    else
      have herdr || continue
      info="$(herdr pane process-info --pane "$pane" 2>/dev/null)" || continue
      pid="$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0].pid // empty' 2>/dev/null)" || continue
    fi
    case "$pid" in ''|*[!0-9]*) continue;; esac
    rss="$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)" || rss=""
    case "$rss" in ''|*[!0-9]*) continue;; esac
    total=$(( total + rss * 1024 ))
  done < <(printf '%s\n' "$panes" | sed '/^$/d' | sort -u)
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

# ------------------------------------------------------------ the diagnosis

# WHAT IS FILLING THE DISK RIGHT NOW, for an alert to append (AH-261103). The
# disk monitor's warning named the newest entries under home and /tmp; the
# 18 GiB/h drop that prompted this was Docker images and build cache in a
# root-owned /var/lib/docker, so the warning named nothing anybody could act
# on. At most two lines, both read-only and bounded:
#   docker: images <size> (<n> reclaimable), build cache ..., volumes ...
#   docker builds: <n> running - pid <pid> agent=<who> cwd=<dir>: <argv>; ...
# The first is left out when docker is absent, too slow, or not this user's
# to query: that is a normal box, not a finding. The second is left out when
# nothing is building and there is no docker to build with.

# The kernel's, unless a test points it at a fixture tree - the same variable
# lib/orphans.sh reads, so one export fakes both.
_box_proc() { printf '%s' "${CEL_PROC:-/proc}"; }

# Seconds `docker system df` may take before the diagnosis goes without it.
# An alert is waiting on this line, and a hung daemon must not hold it. Thirty
# because the plain query took 14 s on the loaded box on 2026-11-03, and a
# bound that drops the answer on exactly the busy box that needs it is no use.
_box_diag_timeout() {
  local t="${CEL_BOX_DIAG_TIMEOUT:-30}"
  case "$t" in ''|*[!0-9]*|0) t=30 ;; esac
  printf '%s' "$t"
}

# The line goes into a mailbox: forty parallel builds are one fact, and a
# build argv can carry a page of --build-arg flags.
_BOX_DIAG_BUILDS_MAX=5
_BOX_DIAG_ARGV_MAX=120

_box_diag_docker_line() { # -> the `docker:` line, or nothing with status 1
  have "$(_box_docker_bin)" || return 1
  have jq || return 1
  local rows img_s img_r bld_s bld_r vol_s vol_r
  rows="$(_box_docker_df "$(_box_diag_timeout)")" || return 1
  [ -n "$rows" ] || return 1
  IFS=$'\t' read -r img_s img_r <<< "$(_box_docker_row "$rows" Images)"
  IFS=$'\t' read -r bld_s bld_r <<< "$(_box_docker_row "$rows" "Build Cache")"
  IFS=$'\t' read -r vol_s vol_r <<< "$(_box_docker_row "$rows" "Local Volumes")"
  printf 'docker: images %s (%s reclaimable), build cache %s (%s reclaimable), volumes %s (%s reclaimable)\n' \
    "$(box_human "$img_s")" "$(box_human "$img_r")" \
    "$(box_human "$bld_s")" "$(box_human "$bld_r")" \
    "$(box_human "$vol_s")" "$(box_human "$vol_r")"
}

# `docker build`, its `image build` and `builder build` spellings, and
# `buildx build|b|bake` - from the CLI or from the docker-buildx plugin binary
# the CLI runs underneath it. Global options are skipped, with the value of
# the ones that take one, so `docker --context ci build` is still a build.
_box_is_docker_build() { # <argv...> -> 0 for a build
  case "${1##*/}" in docker|docker-buildx) ;; *) return 1 ;; esac
  shift
  local -a sub=()
  while [ $# -gt 0 ] && [ "${#sub[@]}" -lt 2 ]; do
    case "$1" in
      --config|-c|--context|-H|--host|-l|--log-level|--tlscacert|--tlscert|--tlskey|--builder)
        shift; [ $# -gt 0 ] && shift; continue ;;
      -*) shift; continue ;;
    esac
    sub+=("$1"); shift
  done
  case "${sub[0]:-} ${sub[1]:-}" in
    "build "*|"buildx build"|"buildx b"|"buildx bake"|"image build"|"builder build") return 0 ;;
  esac
  return 1
}

_box_ppid() { # <pid> -> its parent, from <proc>/<pid>/status
  local k v
  { while read -r k v; do
      [ "$k" = PPid: ] && { printf '%s' "$v"; return 0; }
    done < "$(_box_proc)/$1/status"; } 2>/dev/null || true
  return 1
}

# The pane a process stands in, read from its environment the way
# run_session_resumers reads it, and from its parents' when its own is
# unreadable or bare: a build started by an agent's shell tool inherits the
# agent's HERDR_PANE_ID, or its REX_SESSION and REX_BLOCK.
_box_diag_pane() { # <pid> -> herdr pane id or rex/<session>/<block>
  local p="$1" hops=0 item pane rs rb
  while [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] && [ "$hops" -lt 64 ]; do
    pane="" rs="" rb=""
    { while IFS= read -r -d '' item; do
        case "$item" in
          HERDR_PANE_ID=*) pane="${item#*=}" ;;
          REX_SESSION=*) rs="${item#*=}" ;;
          REX_BLOCK=*) rb="${item#*=}" ;;
        esac
      done < "$(_box_proc)/$p/environ"; } 2>/dev/null || true
    [ -z "$rs" ] || [ -z "$rb" ] || pane="rex/$rs/$rb"
    if [ -n "$pane" ]; then printf '%s' "$pane"; return 0; fi
    p="$(_box_ppid "$p")" || return 1
    hops=$((hops + 1))
  done
  return 1
}

# The owner of one build: the agent in its pane when the environment says
# which; otherwise the agent whose working directory most closely contains the
# build's, said as an inference; otherwise the bare pane, or nothing.
_box_diag_owner() { # <pane> <cwd> <roster pane<TAB>name<TAB>cwd lines>
  local pane="$1" cwd="$2" p n c best="" blen=0
  if [ -n "$pane" ]; then
    while IFS=$'\t' read -r p n c; do
      [ -n "$p" ] && [ "$p" = "$pane" ] && [ -n "$n" ] && { printf 'agent=%s' "$n"; return 0; }
    done <<< "$3"
  fi
  if [ -n "$cwd" ]; then
    while IFS=$'\t' read -r p n c; do
      [ -n "$n" ] && [ -n "$c" ] && [ "$c" != / ] || continue
      case "$cwd" in "$c"|"$c"/*) [ "${#c}" -gt "$blen" ] && { best="$n"; blen="${#c}"; } ;; esac
    done <<< "$3"
    [ -z "$best" ] || { printf 'agent=%s (by cwd)' "$best"; return 0; }
  fi
  if [ -n "$pane" ]; then printf 'agent=? pane=%s' "$pane"; else printf 'agent=?'; fi
}

_box_diag_builds_line() { # <docker-answered 0|1> -> the `docker builds:` line
  local proc d pid a0 parent roster="" item cwd cmd out="" shown=0
  local -a argv=() builds=() top=()
  local -A is_build=()
  proc="$(_box_proc)"
  for d in "$proc"/[0-9]*; do
    a0=""
    { read -r -d '' a0 < "$d/cmdline"; } 2>/dev/null || true
    case "${a0##*/}" in docker|docker-buildx) ;; *) continue ;; esac
    { mapfile -d '' -t argv < "$d/cmdline"; } 2>/dev/null || continue
    _box_is_docker_build "${argv[@]}" || continue
    pid="${d##*/}"
    is_build[$pid]=1
    builds+=("$pid")
  done
  # ONE BUILD, ONE ROW: `docker build` runs the docker-buildx plugin as its
  # child, and both argvs say build.
  for pid in "${builds[@]}"; do
    parent="$(_box_ppid "$pid")" || parent=""
    [ -n "$parent" ] && [ -n "${is_build[$parent]:-}" ] && continue
    top+=("$pid")
  done
  if [ "${#top[@]}" -eq 0 ]; then
    [ "$1" = 1 ] && printf 'docker builds: none running\n'
    return 0
  fi
  mapfile -t top < <(printf '%s\n' "${top[@]}" | sort -n)
  if have jq; then
    roster="$(cel_agent_list 2>/dev/null | jq -r '.result.agents[]?
      | [(.pane_id // ""), (.name // ""), ((.cwd // "") | sub(" \\(deleted\\)$"; ""))] | @tsv' 2>/dev/null)" || roster=""
  fi
  for pid in "${top[@]}"; do
    [ "$shown" -lt "$_BOX_DIAG_BUILDS_MAX" ] || break
    argv=()
    { mapfile -d '' -t argv < "$proc/$pid/cmdline"; } 2>/dev/null || true
    cmd="${argv[*]}"
    cmd="${cmd//[$'\n\t\r']/ }"
    [ "${#cmd}" -le "$_BOX_DIAG_ARGV_MAX" ] || cmd="${cmd:0:$_BOX_DIAG_ARGV_MAX}..."
    cwd="$(readlink "$proc/$pid/cwd" 2>/dev/null)" || cwd=""
    cwd="$(pane_cwd "$cwd")"
    item="pid $pid $(_box_diag_owner "$(_box_diag_pane "$pid")" "$cwd" "$roster") cwd=${cwd:-?}: $cmd"
    out="${out:+$out; }$item"
    shown=$((shown + 1))
  done
  [ "${#top[@]}" -le "$shown" ] || out="$out; +$(( ${#top[@]} - shown )) more"
  printf 'docker builds: %d running - %s\n' "${#top[@]}" "$out"
}

box_diag() { # -> at most two lines; always exits 0
  local answered=0
  _box_diag_docker_line && answered=1
  _box_diag_builds_line "$answered"
  return 0
}

cmd_box() { # space [--json] | diag
  local verb="${1:-space}"
  shift || true
  case "$verb" in
    space)
      case "${1:-}" in
        --json) box_space_json ;;
        '') _box_space_table ;;
        *) die "cel box space: unknown argument '$1' (want --json)" ;;
      esac ;;
    diag)
      [ $# -eq 0 ] || die "cel box diag: unknown argument '$1' (takes none)"
      box_diag ;;
    *) die "cel box: unknown subcommand '$verb' (want space or diag)" ;;
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
  # THE REMEDY BELONGS IN THE FINDING. Finished reviewers are closed by the
  # plain sweep, not by `--box`, so the remedy names that.
  remedy="cel gc --box clears it, cel box space shows the rest"
  case "${largest% *}" in
    "reviewer panes") remedy="cel gc closes every reviewer whose PR is merged or closed; cel box space shows the rest" ;;
  esac
  printf 'box: %s free (floor %sG) - largest reclaimable is %s; %s' \
    "$(box_human "$free")" "$floor" \
    "$(printf '%s' "${largest% *}") $(box_human "${largest##* }")" "$remedy"
}
