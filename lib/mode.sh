# shellcheck shell=bash
# cel mode - how a product is built: `fleet` or `solo`.
#
# FLEET is the factory: an orchestrator plans and judges, workers build in
# delegated worktrees, everything is on the ledger. SOLO is one agent that
# plans, builds and ships the product itself, with whatever its runtime offers
# (its own worktrees and subagents included) and none of the fan-out. Neither
# is better; the owner picks per product, and sometimes per week.
#
# The setting lives in workspace.yaml (lib/workspace.sh ws_build_mode), so a
# restart, `cel ws up` and `cel update --restart-orchestrators` all start the
# right kind of agent without anyone remembering a flag. Changing it here also
# restarts the product's live agent into the new role on the SAME session, so
# the conversation carries over. The restart waits for the agent to finish its
# turn: an agent can switch its own mode, and its reply is not cut off.
[ -n "${_CEL_MODE:-}" ] && return 0
_CEL_MODE=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"
# shellcheck source=lib/run.sh
. "${BASH_SOURCE[0]%/*}/run.sh"

# Which product a bare `cel mode` means. An agent launched for a product
# carries its mailbox (`<product>-orch`) from the launch, which is the most
# reliable answer from inside its pane; a person standing in a product or repo
# directory means that one; a workspace of one product means that one.
_mode_product() { # <wsdir> -> product, or nothing
  local wsdir="$1" p rel
  if [ -n "${CEL_INBOX_ME:-}" ] && [ "${CEL_INBOX_ME%-orch}" != "$CEL_INBOX_ME" ] \
     && { [ -z "${CEL_INBOX_WS:-}" ] || [ "$CEL_INBOX_WS" = "$(ws_name "$wsdir")" ]; }; then
    p="${CEL_INBOX_ME%-orch}"
    ws_product_names "$wsdir" | grep -qxF "$p" && { printf '%s' "$p"; return 0; }
  fi
  rel="${PWD#"$wsdir"/}"
  case "$rel" in
    products/*) p="${rel#products/}"; printf '%s' "${p%%/*}"; return 0 ;;
    repos/*)    p="${rel#repos/}"; ws_product_of_repo "$wsdir" "${p%%/*}"; return 0 ;;
  esac
  local -a ps; mapfile -t ps < <(ws_product_names "$wsdir")
  [ "${#ps[@]}" -eq 1 ] && printf '%s' "${ps[0]}"
  return 0
}

# Write `mode` on the product's own entry: products[] for a declared product,
# repos[] for an implicit one - the same place ws_build_mode reads.
#
# AS ONE LINE, NOT A ROUND-TRIP. workspace.yaml is written by hand and
# commented heavily; `yq -Y` re-emitted the vhs file with 284 lines changed
# (comments moved, alignment and flow style lost) to set one key. So the text
# is edited in place: inside the block of the `- name: <product>` item under
# the right top-level key, an existing `mode:` line is replaced, otherwise one
# is inserted right after the name line at the item's key indentation. A
# flow-style item (`- { name: x }`) is refused rather than rewritten.
#
# The result must equal the original with exactly this one key set, compared
# as plain data, or nothing is written. The write replaces the file a symlink
# points at, never the link, and keeps a missing final newline missing.
_mode_write() { # <wsdir> <product> <mode>
  local f tmp key
  f="$(readlink -f "$1/workspace.yaml")" || return 1
  if ws_product_declared "$1" "$2"; then key=products; else key=repos; fi
  tmp="$(mktemp "$f.cel-mode.XXXXXX")" || return 1
  if awk -v sect="$key" -v name="$2" -v mode="$3" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    function noise(s) { return s ~ /^[ \t]*$/ || s ~ /^[ \t]*#/ }
    function strip(v) { sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
                        if (v ~ /^".*"$/ || v ~ /^\x27.*\x27$/) v = substr(v, 2, length(v) - 2)
                        return v }
    { L[NR] = $0 }
    END {
      # 1. the `- name: <name>` line of the item, inside the top-level section
      insect = 0; s = 0
      for (i = 1; i <= NR; i++) {
        # a top-level key opens or closes the section; a `- ` at column 0 is an
        # item of an unindented sequence (`products:\n- name: a`), not a key
        if (!noise(L[i]) && ind(L[i]) == 0 && L[i] !~ /^-/) insect = (L[i] ~ ("^" sect ":[ \t]*(#.*)?$"))
        if (!insect) continue
        if (L[i] ~ /^[ \t]*-[ \t]*\{/ && L[i] ~ ("name:[ \t]*[\"\x27]?" name "[\"\x27]?[ \t]*[,}]")) exit 3
        if (L[i] ~ /^[ \t]*-[ \t]+name:/) {
          v = L[i]; sub(/^[ \t]*-[ \t]+name:[ \t]*/, "", v)
          if (strip(v) == name) { s = i; break }
        }
      }
      if (!s) exit 3
      dash = ind(L[s]); match(L[s], /^[ \t]*-[ \t]+/); pad = sprintf("%" RLENGTH "s", "")
      # 2. the item ends at the next real line at or left of its dash
      e = NR + 1
      for (i = s + 1; i <= NR; i++) if (!noise(L[i]) && ind(L[i]) <= dash) { e = i; break }
      # 3. replace its own `mode:` line, keeping a trailing comment, else insert
      m = 0
      for (i = s + 1; i < e; i++) if (L[i] ~ ("^" pad "mode:")) { m = i; break }
      for (i = 1; i <= NR; i++) {
        if (i == m) {
          c = ""; if (match(L[i], /[ \t]+#.*$/)) c = substr(L[i], RSTART)
          print pad "mode: " mode c; continue
        }
        print L[i]
        if (i == s && !m) print pad "mode: " mode
      }
    }' "$f" > "$tmp" \
     && { [ -z "$(tail -c1 "$f")" ] || truncate -s -1 "$tmp"; } \
     && [ "$(yq -cS --arg k "$key" --arg n "$2" --arg m "$3" \
            '(.[$k][] | select(.name == $n)).mode = $m' "$f")" = "$(yq -cS . "$tmp")" ]; then
    chmod --reference="$f" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$f"
  else
    rm -f -- "$tmp"; return 1
  fi
}

# THE PRODUCT'S OWN AGENT, by name AND directory. Any agent standing in the
# product directory is not enough: for an implicit product that directory is
# the repo checkout, where a human's own pane may stand too, and restarting it
# would be restarting the wrong thing. Prints its status; returns 1 when no
# such agent is live and 2 when herdr could not be asked - silence from the
# observer is not evidence that the agent is gone.
_mode_agent_status() { # <wsdir> <product>
  local name cwd roster
  name="$(_run_agent_name "$2/orch")"; cwd="$(ws_product_dir "$1" "$2")"
  have herdr && have jq || return 2
  roster="$(herdr agent list 2>/dev/null)" || return 2
  printf '%s' "$roster" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 || return 2
  printf '%s' "$roster" | jq -er --arg n "$name" --arg c "$cwd" \
    '[.result.agents[] | select(.name == $n and (.cwd // "") == $c)][0].agent_status // empty' 2>/dev/null \
    || return 1
}

# The restart, detached from whoever asked: when the product's own agent runs
# `cel mode`, it is mid-turn, and restarting it then would kill the turn that
# asked. A transient user unit outlives the caller and has its own cgroup (a
# plain `setsid` would die with a steward tick's unit - lib/dash.sh); without
# systemd it falls back to setsid.
#
# ONE PENDING RESTART PER PRODUCT, AND IT IS NEVER STOPPED. Stopping an earlier
# waiter could kill a restart already half done (exit keys sent, relaunch not
# yet), leaving the pane dead. A pending one is left alone instead: the
# relaunch reads `mode:` when it fires, so a solo->fleet->solo flip lands on
# the latest word anyway. The waiter also holds a per-product lock, so the
# setsid fallback cannot double-restart either.
_mode_unit() { # <ws> <product>
  printf 'cel-mode-%s-%s' "$1" "$2" | tr -c 'A-Za-z0-9_.-' '-'
}
_mode_schedule_restart() { # <wsdir> <product> -> 0 scheduled, 3 one already pending
  local ws; ws="$(ws_name "$1")"
  local -a cmd=("$CEL_ROOT/bin/cel" mode --restart-when-idle "$2" --workspace "$ws")
  if [ -n "${CEL_TESTING:-}" ] && [ -n "${CEL_MODE_LAUNCH:-}" ]; then
    "$CEL_MODE_LAUNCH" "${cmd[@]}"; return $?
  fi
  local unit; unit="$(_mode_unit "$ws" "$2")"
  if have systemd-run && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user is-active --quiet "$unit.service" 2>/dev/null && return 3
    local -a envs=(--setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=CEL_ROOT="$CEL_ROOT")
    [ -z "${HERDR_SOCKET_PATH:-}" ] || envs+=(--setenv=HERDR_SOCKET_PATH="$HERDR_SOCKET_PATH")
    [ -z "${CEL_REGISTRY:-}" ] || envs+=(--setenv=CEL_REGISTRY="$CEL_REGISTRY")
    systemd-run --user --quiet --collect --unit "$unit" "${envs[@]}" "${cmd[@]}" && return 0
  fi
  setsid nohup "${cmd[@]}" >/dev/null 2>&1 < /dev/null &
}

# The waiter itself. Restarts the product's agent once it has been `idle` or
# `done` for two consecutive polls - a turn has gaps between tool calls, and
# one quiet sample in the middle of one is not the end of it. Anything else is
# not quiet: `working` is a turn, and `blocked` is a pending approval the owner
# has not answered, which a restart would throw away. The relaunch never
# passes --force, so `cel run --restart` itself still refuses a working agent.
# Gives up after a bound and says so: a waiter must never outlive its reason.
_mode_restart_when_idle() { # <wsdir> <product>
  local wsdir="$1" product="$2" status rc quiet=0 waited=0
  local poll="${CEL_MODE_POLL_SECS:-5}" limit="${CEL_MODE_WAIT_SECS:-7200}"
  local lock="$wsdir/.cel/mode-restart-$product.lock"
  mkdir -p "$wsdir/.cel"
  exec 8>"$lock"
  flock -n 8 || { c_warn "cel mode: a restart of $product is already pending"; return 0; }
  while [ "$waited" -lt "$limit" ]; do
    rc=0; status="$(_mode_agent_status "$wsdir" "$product")" || rc=$?
    case "$rc" in
      1) c_warn "cel mode: $product-orch is not live any more - the new mode applies at its next launch"; return 0 ;;
      2) quiet=0 ;;   # the observer stuttered: ask again, decide nothing
      *) case "$status" in idle|done) quiet=$((quiet + 1)) ;; *) quiet=0 ;; esac ;;
    esac
    if [ "$quiet" -ge 2 ]; then
      # From the workspace directory, so no registry lookup stands between the
      # waiter and the one launch path that picks the role from `mode:`.
      ( cd "$wsdir" && cmd_run orchestrator --product "$product" --restart )
      return $?
    fi
    sleep "$poll"; waited=$((waited + poll))
  done
  c_err "cel mode: $product was not idle within ${limit}s - not restarted; the new mode applies at its next launch"
  return 1
}

cmd_mode() { # [product] [solo|fleet] [--workspace w] [--no-restart]
  local product="" want="" workspace="" restart=1 when_idle=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) workspace="$2"; shift 2 ;;
      --no-restart) restart=0; shift ;;
      --restart-when-idle) when_idle=1; shift ;;
      solo|fleet) want="$1"; shift ;;
      -h|--help)
        printf 'usage: cel mode [<product>] [solo|fleet] [--workspace <w>] [--no-restart]\n'
        return 0 ;;
      -*) die "cel mode: unknown argument '$1'" ;;
      *) [ -z "$product" ] || die "cel mode: one product at a time (got '$product' and '$1')"
         product="$1"; shift ;;
    esac
  done

  local wsdir
  if [ -n "$workspace" ]; then
    wsdir="$(registry_require "$workspace")"
  elif ! wsdir="$(ws_current)"; then
    [ -n "${CEL_INBOX_WS:-}" ] || die "cel mode: not inside a workspace (cd into one, or pass --workspace <name>)"
    wsdir="$(registry_require "$CEL_INBOX_WS")"
  fi
  [ -n "$product" ] || product="$(_mode_product "$wsdir")"
  [ -n "$product" ] || die "cel mode: which product? ($(ws_product_names "$wsdir" | paste -sd' ' -))"
  ws_product_names "$wsdir" | grep -qxF "$product" \
    || die "cel mode: '$product' is not a product of workspace '$(ws_name "$wsdir")' ($(ws_product_names "$wsdir" | paste -sd' ' -))"

  if [ "$when_idle" -eq 1 ]; then
    _mode_restart_when_idle "$wsdir" "$product"; return $?
  fi

  local have_mode; have_mode="$(ws_build_mode "$wsdir" "$product")"
  if [ -z "$want" ]; then
    printf '%s: %s\n' "$product" "$have_mode"
    return 0
  fi
  if [ "$have_mode" = "$want" ]; then
    c_ok "$product is already $want"
    return 0
  fi

  # Fleet work in flight has an orchestrator to collect, review and land it.
  # A solo agent has none of that machinery, so the work would be stranded.
  if [ "$want" = solo ]; then
    local live; live="$(ws_product_live_delegations "$wsdir" "$product")"
    if [ -n "$live" ]; then
      c_err "cel mode: $product still has fleet work in flight - land or release it first (cel-fanout status):"
      printf '%s\n' "$live" | sed 's/^/    /' >&2
      return 1
    fi
  fi

  _mode_write "$wsdir" "$product" "$want" \
    || die "cel mode: could not set mode on '$product' in $wsdir/workspace.yaml - the entry is in a layout this edits only by hand (a flow-style \`{ name: ... }\` item), or the edit would have changed more than that key. Nothing was written; add \`mode: $want\` to its entry yourself"
  [ "$(ws_build_mode "$wsdir" "$product")" = "$want" ] \
    || die "cel mode: wrote $wsdir/workspace.yaml but it still reads '$(ws_build_mode "$wsdir" "$product")' for $product"
  c_ok "$product: $have_mode -> $want (workspace.yaml)"

  local rc=0; _mode_agent_status "$wsdir" "$product" >/dev/null || rc=$?
  if [ "$rc" -eq 1 ]; then
    printf '  %s-orch is not live - %s starts as %s at its next launch\n' "$product" "$product" "$want"
  elif [ "$restart" -eq 0 ]; then
    printf '  %s-orch keeps its current role until it is restarted (--no-restart)\n' "$product"
  else
    # rc 2 (herdr unreadable) still schedules: the waiter asks again, and it is
    # the waiter, not this call, that decides whether anything is restarted.
    rc=0; _mode_schedule_restart "$wsdir" "$product" || rc=$?
    case "$rc" in
      0) printf '  %s-orch restarts as %s on the same session once it is idle\n' "$product" "$want" ;;
      3) printf '  a restart of %s-orch is already pending; it will start it as %s\n' "$product" "$want" ;;
      *) die "cel mode: could not schedule the restart - run: cel run orchestrator --product $product --restart" ;;
    esac
  fi
}
