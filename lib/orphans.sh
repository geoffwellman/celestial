# shellcheck shell=bash
# What the plane started and nobody owns any more.
#
# The owner, 2026-09-19: "the agents are leaving other processes laying around
# hogging memory other than the harness itself". A walk of the box found, all
# reparented to init: thirteen `cel inbox watch` trees from consoles that had
# exited, four of them days old; fifty-six `/bin/sh .../bin/long-running` test
# fixtures whose worktree had been deleted nine days earlier; 173 bare pane
# shells on ptys whose herdr pane was gone, 4-8 MB each; and gate runners
# whose suite had been killed. Roughly a gigabyte, and none of it was
# mentioned anywhere: the steward's memory sweep (CEL-22) groups by pane, so a
# process with no pane is a process it cannot see. `celestial-orch 1.7G` was
# the headline while the orphans went unnamed.
#
# A WORKER SESSION IS NOT AN ORPHAN. A pi or omp session for a row the ledger
# calls finished or landed has an owner - the orchestrator - and `release
# --all --merged` plus the memory sweep already cover it. This file is only
# for the classes with NO owner at all, and the cost of being wrong is a
# killed session mid-gate, so every rule here is written to fail towards
# keeping a process: an unreadable pane list keeps every shell, a parent that
# is not init keeps the process, an unknown class is not a class.
[ -n "${_CEL_ORPHANS:-}" ] && return 0
_CEL_ORPHANS=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"

# The kernel's, unless a test points it at a fixture tree. A real /proc cannot
# be arranged into "a watcher whose console exited nine days ago" without
# leaving exactly the litter this file removes.
_orphans_proc() { printf '%s' "${CEL_PROC:-/proc}"; }

# TERM then KILL is not a formality: fifty-six of the fixtures on the box were
# `trap ''`-style processes that a TERM alone never moved.
_orphans_grace() { printf '%s' "${CEL_ORPHAN_GRACE:-5}"; }

# The ptys herdr says it owns, one per line, plus a marker line when the
# question could not be asked at all. UNKNOWN IS NOT EMPTY: herdr restarts,
# and a sweep that read a failed pane list as "no panes" would kill all 173
# shells on the box the one time it mattered.
_orphans_pane_ttys() { # -> tty per line, or nothing with status 1 when unknown
  have herdr || return 1
  have jq || return 1
  local out
  out="$(herdr pane list 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -er '
    .result.panes | if type == "array" then
      map(.tty // .pty // .pty_path // empty) | join("\n")
    else error("no pane list") end' 2>/dev/null || return 1
}

# Everything the plane must never touch, whatever else is true of it.
#
# THE FIRST CUT OF THIS WAS DEAD CODE, and the review caught it. It matched
# the strings `cel-auth-gateway`, `cel-auth-broker` and `/services.d/`
# against the cmdline - but lib/gateway.sh declares those services as
# `omp auth-broker serve --bind 127.0.0.1:47311`, and a service's NAME
# appears in its declaration, never in its argv. Not one of the three
# substrings occurs in any process on this box, so the protection the spec
# asked for protected nothing: the door to every subscription the plane owns
# survived the sweep because its cwd happened to exist. A rule that is safe
# by luck is a rule that fails the first time the luck changes.
#
# So a box service is identified the way the box identifies one - by the
# declaration in services.d, resolved to a pid - and the cmdline test below
# is only a second line of defence, matched against the line gateway.sh
# ACTUALLY launches.
_orphans_protected() { # <args>
  case " $1 " in
    *"bg-spare"*|*"bg-pty-host"*) return 0 ;;
    # The real launch lines, for a box whose services.d has not been written
    # yet (a fresh install, or a gateway started by hand while it is set up).
    *" auth-broker "*|*" auth-gateway "*) return 0 ;;
    *"/services.d/"*) return 0 ;;
    *" cel steward"*|*"/cel steward"*) return 0 ;;
    *"cel gc"*) return 0 ;;
  esac
  return 1
}

# Where the box keeps its service declarations and their state. Read through
# the same environment variables lib/services.sh uses, so a test points both
# at a fixture with one export and the live box is never consulted.
_orphans_services_d() {
  printf '%s' "${CEL_SERVICES_D:-${XDG_CONFIG_HOME:-$HOME/.config}/cel/services.d}"
}
_orphans_services_state() {
  printf '%s' "${CEL_SERVICES_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/services}"
}

# Who is actually listening on a port. `ss` first because it is iproute2 and
# on every box this runs on; `lsof` second because it is the one that is
# there when `ss` has been stripped out of a container image. NEITHER BEING
# PRESENT IS UNKNOWN, not "nobody": the caller must fall back to the other
# identities rather than conclude a service has no pid.
_orphans_port_pids() { # <port> -> pid per line
  local port="${1:-0}"
  [ "$port" -gt 0 ] 2>/dev/null || return 0
  if have ss; then
    ss -lntpH "sport = :$port" 2>/dev/null \
      | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
    return 0
  fi
  if have lsof; then
    lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null | sort -u
    return 0
  fi
  return 0
}

# Every pid that belongs to a declared box service.
#
# Two identities, deliberately both: the port answers "what is serving this
# right now", which is the true one, and the state file answers for a service
# that is restarting, wedged, or listening somewhere this box cannot ask
# about - the moment when a sweep is most likely to be running and most
# likely to be wrong. A declaration that resolves to neither yields nothing
# and the process is judged on its own merits, which is the honest answer.
_orphans_service_pids() { # -> pid per line
  local dir state f name port url pid
  dir="$(_orphans_services_d)"
  state="$(_orphans_services_state)"
  have jq || return 0
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .json)"
    url="$(jq -r '.url // ""' "$f" 2>/dev/null || true)"
    port="$(jq -r '.port // ""' "$f" 2>/dev/null || true)"
    if [ -z "$port" ] || [ "$port" = null ]; then
      port="${url##*:}"; port="${port%%/*}"
    fi
    case "$port" in ''|*[!0-9]*) port=0 ;; esac
    _orphans_port_pids "$port"
    if [ -f "$state/$name.json" ]; then
      pid="$(jq -r '.pid // 0' "$state/$name.json" 2>/dev/null || printf 0)"
      case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
      [ "$pid" -gt 1 ] && printf '%s\n' "$pid"
    fi
  done
  return 0
}

# Those pids and everything under them. A service that forks a worker did not
# stop being a service - though in practice a live child has a live parent
# and the ppid-1 rule has already kept it; this closes the case where a
# service's own child was reparented while the service is still up.
_orphans_service_tree() { # <pid-ppid map> -> pid per line
  local roots; roots="$(_orphans_service_pids)"
  [ -n "$roots" ] || return 0
  printf '%s\n' "$roots"
  printf '%s\n' "$1" | awk -v roots="$roots" '
    BEGIN { n = split(roots, r, "\n"); for (i = 1; i <= n; i++) if (r[i] != "") keep[r[i]] = 1 }
    { pid[NR] = $1; parent[NR] = $2; rows = NR }
    END {
      # A bounded closure: the tree is at most as deep as it has rows, and a
      # /proc that has gone circular must not hang a sweep that kills things.
      for (pass = 0; pass < 8; pass++)
        for (i = 1; i <= rows; i++)
          if ((parent[i] in keep) && !(pid[i] in keep)) { keep[pid[i]] = 1; print pid[i] }
    }'
  return 0
}

# One row per orphan: class, pid, rss in kB, age in seconds, cwd, args.
#
# The age comes from the mtime of /proc/<pid>, which the kernel sets to the
# process's start time - the same number `ps -o lstart` prints, without a
# second tool and without parsing the clock ticks in `stat`.
orphans_list() { # -> class<TAB>pid<TAB>rss_kb<TAB>age_s<TAB>cwd<TAB>args
  local proc me now ttys ttys_known=1 d pid
  proc="$(_orphans_proc)"
  me="$(id -u)"
  now="$(date +%s)"
  ttys="$(_orphans_pane_ttys)" || ttys_known=0

  # NO SUBPROCESS PER PID (CEL-90). At a load of 25-30 this walk forked an
  # awk, a tr, two readlinks and a stat for each of ~800 processes and took
  # 28 s on its own - more than the console's whole 20 s budget, and growing
  # with the very process count it was measuring. Every per-pid fact is now
  # read with bash builtins, and the two symlinks bash cannot read are
  # resolved for the few candidates in ONE batched `find` after the walk.
  local -A st_name st_ppid st_uid st_rss
  local -a order=()
  local parents=$'\n' pidmap="" key val rest n p u r
  for d in "$proc"/[0-9]*; do
    [ -d "$d" ] || continue
    pid="${d##*/}"; n="" p="" u="" r=0
    while IFS=$'\t' read -r key val rest; do
      case "$key" in
        Name:) n="$val" ;;
        PPid:) p="$val" ;;
        Uid:) u="$val" ;;
        VmRSS:) r="${val#"${val%%[! ]*}"}"; r="${r%% *}" ;;
      esac
    done <"$d/status" 2>/dev/null || true
    [ -n "$p" ] || continue
    order+=("$pid")
    st_name[$pid]="$n"; st_ppid[$pid]="$p"; st_uid[$pid]="$u"; st_rss[$pid]="${r:-0}"
    parents="$parents$p"$'\n'
    pidmap="$pidmap$pid $p"$'\n'
  done

  # THE BOX'S OWN SERVICES, BY IDENTITY. Resolved once for the whole walk:
  # asking `ss` per candidate would be a subprocess per process on the box.
  local services; services=$'\n'"$(_orphans_service_tree "$pidmap")"$'\n'

  # The candidates: ours, reparented to init, not this shell, not a service,
  # with an argv that is not protected. Classification is unchanged below.
  local -a cands=() links=()
  local -A st_args
  local args part
  for pid in "${order[@]}"; do
    [ "${st_uid[$pid]}" = "$me" ] || continue
    [ "${st_ppid[$pid]}" = 1 ] || continue
    [ "$pid" = "$$" ] && continue
    case "$services" in *$'\n'"$pid"$'\n'*) continue ;; esac
    args=""
    while IFS= read -r -d '' part || [ -n "$part" ]; do args="$args$part "; done <"$proc/$pid/cmdline" 2>/dev/null || true
    args="${args% }"
    [ -n "$args" ] || continue
    _orphans_protected "$args" && continue
    st_args[$pid]="$args"
    cands+=("$pid")
    links+=("$proc/$pid/cwd")
    if [ -L "$proc/$pid/fd/0" ]; then links+=("$proc/$pid/fd/0"); fi
  done
  [ "${#cands[@]}" -gt 0 ] || return 0

  local -A link_of
  local path target
  while IFS=$'\t' read -r path target; do
    link_of[$path]="$target"
  done < <(find "${links[@]}" -maxdepth 0 -type l -printf '%p\t%l\n' 2>/dev/null || true)

  local up="" upr
  if [ -r "$proc/uptime" ]; then
    read -r upr _ <"$proc/uptime" 2>/dev/null || upr=""
    up="${upr%%.*}"
  fi

  for pid in "${cands[@]}"; do
    d="$proc/$pid"
    local name="${st_name[$pid]}" rss="${st_rss[$pid]}" args="${st_args[$pid]}"
    local cwd="${link_of[$d/cwd]:-}"

    local class=""
    # a. the watcher a console armed and never killed.
    case "$args" in
      *cel*" watch"*|*cel*" watch") class=watcher ;;
    esac
    # d. the gate runner whose suite was killed, and cel-verify with it.
    if [ -z "$class" ]; then
      case "$args" in
        *"tests/run.sh"*|*cel-verify*) class=runner ;;
      esac
    fi
    # b. the fixture whose directory is gone. Three shapes of the same fact:
    # the kernel's `(deleted)` suffix, a per-run `cel-tests.*` directory that
    # the runner removed, and a worktree that `cel gc` took away underneath a
    # process that was still in it.
    if [ -z "$class" ] && [ -n "$cwd" ]; then
      case "$cwd" in
        *" (deleted)") class=fixture ;;
        *) [ -d "$cwd" ] || class=fixture ;;
      esac
    fi
    if [ -z "$class" ]; then
      local exe="${args%% *}"
      case "$exe" in
        /tmp/*/bin/*) [ -d "${exe%/*}" ] || class=fixture ;;
      esac
    fi
    # c. the pane shell whose pane is gone. A shell with ARGUMENTS is running
    # something; only a bare login shell qualifies, it must have no children
    # of its own, and the pane list must have been readable - see above.
    if [ -z "$class" ] && [ "$ttys_known" -eq 1 ]; then
      case "$name" in
        zsh|bash|sh)
          case "$args" in
            *" "*) ;;
            *)
              local tty="${link_of[$d/fd/0]:-}"
              case "$tty" in
                /dev/pts/*)
                  case $'\n'"$ttys"$'\n' in
                    *$'\n'"$tty"$'\n'*) ;;
                    *) case "$parents" in *$'\n'"$pid"$'\n'*) ;; *) class=shell ;; esac ;;
                  esac ;;
              esac ;;
          esac ;;
      esac
    fi
    [ -n "$class" ] || continue

    local age started="" statl
    # THE START TIME, not the mtime of the directory: on this box every
    # /proc/<pid> reports the same mtime, so an age column built on it said
    # "47289s" for a process started a minute ago and for one four days old.
    # Field 22 of `stat` is the start time in clock ticks since boot, and
    # /proc/uptime is how far since boot it is now. Read with builtins; a
    # fixture tree has neither, so the directory mtime remains the fallback.
    if [ -n "$up" ] && [ -r "$d/stat" ]; then
      statl=""
      IFS= read -r statl <"$d/stat" 2>/dev/null || true
      statl="${statl##*) }"
      local -a f=()
      read -r -a f <<<"$statl"
      if [ "${#f[@]}" -ge 20 ] && [[ "${f[19]}" =~ ^[0-9]+$ ]]; then
        started=$(( now - up + f[19] / 100 ))
      fi
    fi
    [ -n "$started" ] || started="$(stat -c %Y "$d" 2>/dev/null || printf '%s' "$now")"
    age=$(( now - started )); [ "$age" -ge 0 ] || age=0
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$class" "$pid" "${rss:-0}" "$age" "${cwd:-}" "$args"
  done
}

# `count rss_mb` for a set of rows on stdin - the two numbers every view of
# this wants and the only two any of them agree on.
orphans_totals() { # < rows -> "<count> <mb>"
  awk -F'\t' '{ n += 1; kb += $3 } END { printf "%d %d\n", n, kb / 1024 }'
}

# ONE LINE, NEVER ONE PER PID. Thirteen watchers and fifty-six fixtures posted
# individually is a mailbox nobody reads, which is how the litter survived
# four days of the steward running every five minutes.
orphans_reaped_line() { # < rows [verb] -> "reaped 6 orphans (2 watchers, ...), 410 MB"
  awk -F'\t' -v verb="${1:-reaped}" '
    { n += 1; kb += $3; c[$1] += 1 }
    END {
      if (n == 0) exit 0
      order = "watcher fixture shell runner"
      split(order, k, " ")
      parts = ""
      for (i = 1; i <= 4; i++) {
        if (!(k[i] in c)) continue
        parts = parts (parts == "" ? "" : ", ") c[k[i]] " " k[i] (c[k[i]] == 1 ? "" : "s")
      }
      printf "%s %d orphan%s (%s), %d MB\n", verb, n, (n == 1 ? "" : "s"), parts, kb / 1024
    }'
}

# The kill itself.
#
# A watcher, a fixture and a dead gate runner are all processes that should
# have exited already, so they get TERM, a grace, then KILL. A SHELL IS NOT:
# HUP is what a closing terminal sends and what a shell is written to handle,
# so it gets the signal its own exit path expects first, and TERM only if it
# stays. Nothing here ever sends KILL to a shell - a login shell that survives
# both is a shell doing something, and this file would rather leave 8 MB on
# the box than be the thing that lost it.
_orphans_kill() { # <class> <pid>
  local class="$1" pid="$2" i grace
  [ "$pid" -gt 1 ] 2>/dev/null || return 0
  grace="$(_orphans_grace)"
  if [ "$class" = shell ]; then
    kill -HUP "$pid" 2>/dev/null || return 0
    for ((i = 0; i < grace * 10; i++)); do
      kill -0 "$pid" 2>/dev/null || return 0
      sleep 0.1
    done
    kill -TERM "$pid" 2>/dev/null || true
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || return 0
  for ((i = 0; i < grace * 10; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
}

# Print the rows, then reap them. The rows come first on purpose: an operator
# who runs this wants to see WHAT was taken, and the summary line alone is not
# something anyone can check afterwards.
orphans_reap() { # [--dry-run] -> rows + one summary line
  local dry=0
  [ "${1:-}" = --dry-run ] && dry=1
  local rows; rows="$(orphans_list)"
  [ -n "$rows" ] || return 0
  local class pid rss age cwd args
  while IFS=$'\t' read -r class pid rss age cwd args; do
    [ -n "$class" ] || continue
    printf '  %-8s %-7s %6s MB  %5ss  %s\n' "$class" "$pid" "$((rss / 1024))" "$age" "$args"
    [ "$dry" -eq 1 ] || _orphans_kill "$class" "$pid"
  done <<<"$rows"
  printf '%s\n' "$rows" | orphans_reaped_line "$([ "$dry" -eq 1 ] && printf 'would reap' || printf reaped)"
}

# `cel doctor` says it in one line, and says nothing when there is nothing -
# a check that speaks every run is a check people stop reading.
orphans_doctor_line() {
  local n mb
  read -r n mb <<<"$(orphans_list | orphans_totals)"
  [ "${n:-0}" -gt 0 ] || return 0
  printf 'orphans: %s processes, %s MB - cel gc --orphans\n' "$n" "$mb"
}
