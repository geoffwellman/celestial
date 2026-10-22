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
# as plain data, or nothing is written.
_mode_write() { # <wsdir> <product> <mode>
  local f="$1/workspace.yaml" tmp key
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
        if (!noise(L[i]) && ind(L[i]) == 0) insect = (L[i] ~ ("^" sect ":[ \t]*(#.*)?$"))
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
     && [ "$(yq -cS --arg k "$key" --arg n "$2" --arg m "$3" \
            '(.[$k][] | select(.name == $n)).mode = $m' "$f")" = "$(yq -cS . "$tmp")" ]; then
    chmod --reference="$f" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$f"
  else
    rm -f -- "$tmp"; return 1
  fi
}

# The restart, detached from whoever asked: when the product's own agent runs
# `cel mode`, it is mid-turn, and restarting it then would kill the turn that
# asked. A transient user unit outlives the caller and has its own cgroup (a
# plain `setsid` would die with a steward tick's unit - lib/dash.sh); without
# systemd it falls back to setsid. Any earlier pending switch for the same
# product is replaced, so the last word wins.
_mode_unit() { # <ws> <product>
  printf 'cel-mode-%s-%s' "$1" "$2" | tr -c 'A-Za-z0-9_.-' '-'
}
_mode_schedule_restart() { # <wsdir> <product>
  local ws; ws="$(ws_name "$1")"
  local -a cmd=("$CEL_ROOT/bin/cel" mode --restart-when-idle "$2" --workspace "$ws")
  if [ -n "${CEL_TESTING:-}" ] && [ -n "${CEL_MODE_LAUNCH:-}" ]; then
    "$CEL_MODE_LAUNCH" "${cmd[@]}"; return $?
  fi
  local unit; unit="$(_mode_unit "$ws" "$2")"
  if have systemd-run && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user stop "$unit.service" >/dev/null 2>&1 || true
    systemd-run --user --quiet --collect --unit "$unit" \
      --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=CEL_ROOT="$CEL_ROOT" \
      "${cmd[@]}" && return 0
  fi
  setsid nohup "${cmd[@]}" >/dev/null 2>&1 < /dev/null &
}

# The waiter itself. Polls the agent standing in the product directory and
# restarts it once it has been out of `working` for two consecutive polls - a
# turn has gaps between tool calls, and one idle sample in the middle of one
# is not the end of it. Gives up after a bound and says so in the journal: a
# waiter must never outlive the reason it was started.
_mode_restart_when_idle() { # <wsdir> <product>
  local wsdir="$1" product="$2" cwd occ status quiet=0 waited=0
  local poll="${CEL_MODE_POLL_SECS:-5}" limit="${CEL_MODE_WAIT_SECS:-7200}"
  cwd="$(ws_product_dir "$wsdir" "$product")"
  while [ "$waited" -lt "$limit" ]; do
    occ="$(_run_live_agent_in_cwd "$cwd")"
    [ -n "$occ" ] || { c_warn "cel mode: no agent is live for $product any more - the new mode applies at its next launch"; return 0; }
    status="$(printf '%s' "$occ" | cut -f3)"
    if [ "$status" = working ]; then quiet=0; else quiet=$((quiet + 1)); fi
    if [ "$quiet" -ge 2 ]; then
      # From the workspace directory, so no registry lookup stands between the
      # waiter and the one launch path that picks the role from `mode:`.
      ( cd "$wsdir" && cmd_run orchestrator --product "$product" --restart )
      return $?
    fi
    sleep "$poll"; waited=$((waited + poll))
  done
  c_err "cel mode: $product was still working after ${limit}s - not restarted; the new mode applies at its next launch"
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

  _mode_write "$wsdir" "$product" "$want" || die "cel mode: could not write $wsdir/workspace.yaml"
  [ "$(ws_build_mode "$wsdir" "$product")" = "$want" ] \
    || die "cel mode: wrote $wsdir/workspace.yaml but it still reads '$(ws_build_mode "$wsdir" "$product")' for $product"
  c_ok "$product: $have_mode -> $want (workspace.yaml)"

  local occ; occ="$(_run_live_agent_in_cwd "$(ws_product_dir "$wsdir" "$product")")"
  if [ -z "$occ" ]; then
    printf '  no agent is live for %s - it starts as %s at its next launch\n' "$product" "$want"
  elif [ "$restart" -eq 0 ]; then
    printf '  %s is live and keeps its current role until it is restarted (--no-restart)\n' "$product"
  else
    _mode_schedule_restart "$wsdir" "$product" \
      || die "cel mode: could not schedule the restart - run: cel run orchestrator --product $product --restart"
    printf '  %s restarts as %s on the same session once its current turn ends\n' "$product" "$want"
  fi
}
