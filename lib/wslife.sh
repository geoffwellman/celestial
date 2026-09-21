# shellcheck shell=bash
# cel ws up|down|reset|status - a workspace has a declared shape, and the
# plane can put it back.
#
# The owner, 2026-09-19: "so there is no way to open or close a workspace from
# the console? or reset it to the appropriate layout and initial setup - there
# should be. I can't restart the alpha session." Three gaps behind that
# sentence, and this file answers all three:
#
#   1. A workspace declared no shape, so there was nothing to return it TO.
#      `layout:` in workspace.yaml now says what should be running in it
#      (lib/workspace.sh: ws_layout_get, ws_layout_panes).
#   2. Nothing could open or close one. `up` RECONCILES - idempotent, never
#      destructive - and `down` closes the panes it owns.
#   3. A nameless agent was invisible. herdr cleared a live orchestrator's
#      name when it restarted; every surface resolves one by its alias on the
#      roster, so a LIVE product read as dead - and the answer to a dead
#      orchestrator is to start another, on top of the one that is running.
#      `up` renames it instead, which is the whole reason this is a reconcile
#      and not a launcher.
#
# WHAT THIS FILE NEVER DOES: remove a worktree, or write the delegation
# ledger. `down` is about PANES. Work is landed and let go by `cel-fanout
# release`, which knows what a scout is, what --discard means and how to log
# the loss - and a second path to the same destruction is how one of them ends
# up without the refusals.
[ -n "${_CEL_WSLIFE:-}" ] && return 0
_CEL_WSLIFE=1
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/run.sh
. "$(dirname "${BASH_SOURCE[0]}")/run.sh"      # cmd_run, _run_agent_name, _run_live_agent_in_cwd
# shellcheck source=lib/stall.sh
. "$(dirname "${BASH_SOURCE[0]}")/stall.sh"    # stall_work_at_risk

# One line per action taken AND per thing already right. A reconcile that only
# printed what it changed would look like it had done nothing on the run that
# matters most - the second one.
_wslife_say() { # <what> <action>
  printf '  %-30s %s\n' "$1" "$2"
}

_wslife_ws_json() { herdr workspace list 2>/dev/null || printf ''; }

_wslife_ws_id() { # <workspace-list-json> <label>
  [ -n "$1" ] || return 0
  printf '%s' "$1" | jq -r --arg l "$2" \
    '[.result.workspaces[]? | select((.label // "") == $l) | .workspace_id][0] // empty' 2>/dev/null || true
}

_wslife_tab_labels() { # <ws_id>
  [ -n "$1" ] || return 0
  herdr tab list --workspace "$1" 2>/dev/null \
    | jq -r '.result.tabs[]? | .label // ""' 2>/dev/null || true
}

# The herdr workspace that stands for the cel workspace itself: its label is
# the workspace's name, so `up` can find the one it made last time rather than
# making a second one beside it.
_wslife_label() { printf '%s' "$1"; }

# WHICH PRODUCTS WANT AN ORCHESTRATOR. One resolver answers, per product:
# `layout.orchestrators` is the workspace-wide switch (auto | manual | none),
# `products[].orchestrator` overrides it in EITHER direction, and silence -
# in any of its three shapes - means manual, which starts nothing. See
# ws_orchestrator_mode in lib/workspace.sh for the incident behind that.
wslife_orchestrators() { # <wsdir>
  local p mode
  for p in $(ws_product_names "$1"); do
    IFS=$'\t' read -r mode _ <<< "$(ws_orchestrator_mode "$1" "$p")"
    [ "$mode" = auto ] || continue
    printf '%s\n' "$p"
  done
}

# The worktrees under this workspace that still hold something - and whether
# the ledger could be read at all. Read exactly the way `cel-fanout release`
# reads them (lib/stall.sh) so the two refusals cannot disagree about what
# "unlanded" means - a `down` that let go of work `release` would have refused
# is the same loss by another door.
#
# FAIL CLOSED WHEN IT CANNOT SEE. Every way of failing to READ the ledger once
# produced an empty result, indistinguishable from "nothing is held", so the
# refusal never fired over a missing, unreadable or malformed ledger - the
# exact stranding it exists to prevent, with no warning at all. So a read that
# cannot be trusted returns 3 with the reason on stdout; only a ledger that was
# actually read returns 0, with one line per worktree at risk (empty when it
# genuinely holds nothing).
_wslife_held_work() { # <wsdir> -> lines; return 0 read ok, 3 cannot tell
  local led="$1/.cel/delegations.json" branch wt risk rows
  if [ ! -e "$led" ]; then
    printf 'no delegation ledger at %s\n' "$led"; return 3
  fi
  if [ ! -r "$led" ]; then
    printf 'the delegation ledger %s is not readable\n' "$led"; return 3
  fi
  # Parse once, and treat a parse failure as "cannot tell", never as empty: a
  # jq that ends `|| true` swallows a malformed ledger into a silent yes.
  if ! rows="$(jq -r '.[]? | select(((.state // "") | IN("running","finished","collected","blocked")))
                     | [(.branch // ""), (.worktree // "")] | @tsv' "$led" 2>/dev/null)"; then
    printf 'the delegation ledger %s is not valid JSON\n' "$led"; return 3
  fi
  while IFS=$'\t' read -r branch wt; do
    [ -n "$wt" ] || continue
    risk="$(stall_work_at_risk "$wt" 2>/dev/null || true)"
    [ -n "$risk" ] || continue
    printf '    %s (%s) at %s\n' "${branch:-?}" "$risk" "$wt"
  done <<< "$rows"
  return 0
}

# --------------------------------------------------------------------- up
cmd_ws_up() { # <name> [--dry-run]
  local name="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      -*) die "cel ws up: unknown argument '$1'" ;;
      *) name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "cel ws up: a workspace name is required"
  local wsdir; wsdir="$(registry_require "$name")"
  have herdr || die "cel ws up: herdr is not on PATH"
  have jq    || die "cel ws up: jq is not on PATH"

  local label ws_id
  label="$(_wslife_label "$name")"
  ws_id="$(_wslife_ws_id "$(_wslife_ws_json)" "$label")"
  if [ -n "$ws_id" ]; then
    _wslife_say "workspace $name" "already right ($ws_id)"
  elif [ "$dry" -eq 1 ]; then
    _wslife_say "workspace $name" "would create (cwd $wsdir)"
  else
    local resp
    resp="$(herdr workspace create --cwd "$wsdir" --label "$label")" \
      || die "cel ws up: herdr workspace create failed"
    ws_id="$(printf '%s' "$resp" | jq -r '.. | .workspace_id? // empty' | head -1)"
    _wslife_say "workspace $name" "created ($ws_id)"
  fi

  # The declared panes, in declared order: the order IS the declaration.
  local labels pane_label pane_cwd pane_cmd
  labels="$(_wslife_tab_labels "$ws_id")"
  while IFS=$'\t' read -r pane_label pane_cwd pane_cmd; do
    [ -n "$pane_label" ] || continue
    if printf '%s\n' "$labels" | grep -qxF "$pane_label"; then
      _wslife_say "pane $pane_label" "already right"
      continue
    fi
    if [ "$dry" -eq 1 ]; then
      _wslife_say "pane $pane_label" "would open${pane_cmd:+ ($pane_cmd)}"
      continue
    fi
    local cwd resp pane
    cwd="$wsdir/${pane_cwd#./}"; cwd="${cwd%/.}"
    resp="$(herdr tab create --workspace "$ws_id" --cwd "$cwd" --label "$pane_label" --no-focus)" \
      || die "cel ws up: herdr tab create failed for pane '$pane_label'"
    pane="$(printf '%s' "$resp" | jq -r '.. | .pane_id? // empty' | head -1)"
    # An empty pane when no cmd is declared: a pane is a place to work, and a
    # workspace that insisted on a command for every one of them would be a
    # workspace nobody could declare a scratch pane in.
    [ -z "$pane_cmd" ] || herdr pane run "$pane" "$pane_cmd" >/dev/null 2>&1 \
      || c_warn "pane '$pane_label' opened but '$pane_cmd' could not be typed into it"
    _wslife_say "pane $pane_label" "created${pane_cmd:+ ($pane_cmd)}"
  done < <(ws_layout_panes "$wsdir")

  # The orchestrators. A live agent in the product's own directory IS its
  # orchestrator, named or not - see _run_live_agent_in_cwd.
  #
  # THE RENAME IS NOT GATED ON THE AUTO SWITCH. `orchestrators: manual` says
  # the plane does not START them; it does not say a live one should stay
  # invisible. A workspace that launches its orchestrators by hand is exactly
  # the workspace where herdr losing a name goes unnoticed longest.
  local p alias dir occupant oname opane wanted mode src
  wanted="$(wslife_orchestrators "$wsdir")"
  for p in $(ws_product_names "$wsdir"); do
    alias="$(_run_agent_name "$p-orch")"
    dir="$(ws_product_dir "$wsdir" "$p")"
    IFS=$'\t' read -r mode src <<< "$(ws_orchestrator_mode "$wsdir" "$p")"
    occupant="$(_run_live_agent_in_cwd "$dir")"
    if [ -z "$occupant" ] && ! printf '%s\n' "$wanted" | grep -qxF "$p"; then
      # A dry run is where the operator goes to ask why nothing starts, so it
      # says the mode AND where the mode came from rather than saying nothing.
      [ "$dry" -eq 0 ] || _wslife_say "orchestrator $alias" "$mode via $src - nothing starts it"
      continue
    fi
    if [ -n "$occupant" ]; then
      IFS=$'\t' read -r oname opane _ <<< "$occupant"
      if [ "$oname" = "$alias" ]; then
        _wslife_say "orchestrator $alias" "already live ($opane)"
      elif [ "$dry" -eq 1 ]; then
        _wslife_say "orchestrator $alias" "would rename ${oname/#-/<unnamed>} in $opane"
      else
        herdr agent rename "$opane" "$alias" >/dev/null 2>&1 \
          || { c_warn "could not rename $opane to $alias"; continue; }
        _wslife_say "orchestrator $alias" "renamed from ${oname/#-/<unnamed>} ($opane)"
      fi
      continue
    fi
    if [ "$dry" -eq 1 ]; then
      _wslife_say "orchestrator $alias" "would start ($mode via $src, cwd $dir)"
      continue
    fi
    cmd_run orchestrator --product "$p" --workspace "$name" >/dev/null \
      || { c_warn "orchestrator $alias did not start"; continue; }
    _wslife_say "orchestrator $alias" "started ($mode via $src)"
  done
}

# ------------------------------------------------------------------- down
cmd_ws_down() { # <name> [--force]
  local name="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) die "cel ws down: unknown argument '$1'" ;;
      *) name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "cel ws down: a workspace name is required"
  local wsdir; wsdir="$(registry_require "$name")"
  have herdr || die "cel ws down: herdr is not on PATH"
  have jq    || die "cel ws down: jq is not on PATH"

  # FAIL CLOSED, exactly as `cel-fanout release` does. Closing a pane does not
  # destroy a worktree, but it does take away the agent that was about to push
  # it, and an operator who meant "tidy up" would never learn which branch they
  # had stranded. The refusal NAMES them - and a ledger it CANNOT read is not a
  # quiet yes: a guard that cannot see does not wave you through, it says why it
  # cannot tell and stops.
  local held rc=0
  held="$(_wslife_held_work "$wsdir")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$force" -eq 0 ]; then
      die "cel ws down: $name - cannot tell what work is at risk:
    $held
  Closing the panes might strand unpushed work, and you would never see which.
  Fix the ledger, or say you mean it:
    cel ws down $name --force
  (nothing here removes a worktree or touches the ledger - that is cel-fanout release)"
    fi
    c_warn "cel ws down --force with a ledger it cannot read:
    $held"
  elif [ -n "$held" ] && [ "$force" -eq 0 ]; then
    die "cel ws down: $name still has work that is neither pushed nor landed:
$held
  Closing the panes strands it. Land it, push it, or say you mean it:
    cel ws down $name --force
  (nothing here removes a worktree or touches the ledger - that is cel-fanout release)"
  elif [ -n "$held" ]; then
    c_warn "cel ws down --force over unlanded work:
$held"
  fi

  local list p alias id closed=0
  list="$(_wslife_ws_json)"
  # The agents go with their panes: herdr closes a workspace by closing the
  # panes in it, and an orchestrator is a process in a pane.
  for p in $(ws_product_names "$wsdir"); do
    alias="$(_run_agent_name "$p-orch")"
    id="$(_wslife_ws_id "$list" "$p/orch")"
    [ -n "$id" ] || { _wslife_say "orchestrator $alias" "not open"; continue; }
    herdr workspace close "$id" >/dev/null 2>&1 \
      || { c_warn "could not close $id ($alias)"; continue; }
    _wslife_say "orchestrator $alias" "closed ($id)"
    closed=$((closed + 1))
  done
  id="$(_wslife_ws_id "$list" "$(_wslife_label "$name")")"
  if [ -n "$id" ]; then
    herdr workspace close "$id" >/dev/null 2>&1 \
      || die "cel ws down: could not close the herdr workspace $id"
    _wslife_say "workspace $name" "closed ($id)"
  else
    _wslife_say "workspace $name" "not open"
  fi
  return 0
}

# ------------------------------------------------------------------ reset
# Down then up, with the same refusals: a reset that skipped the unlanded
# check would be the destructive path with a friendlier name.
cmd_ws_reset() { # <name> [--force]
  local name="" force=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=(--force); shift ;;
      -*) die "cel ws reset: unknown argument '$1'" ;;
      *) name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "cel ws reset: a workspace name is required"
  cmd_ws_down "$name" "${force[@]}"
  cmd_ws_up "$name"
}

# ----------------------------------------------------------------- status
# `up --dry-run` in table form, and the two are one computation on purpose: a
# status that disagreed with what `up` would do is worse than no status.
_wslife_members() { # <wsdir> <name> -> kind\tname\tdeclared\tlive\taction\tsource
  local wsdir="$1" name="$2" list ws_id labels
  list="$(_wslife_ws_json)"
  ws_id="$(_wslife_ws_id "$list" "$(_wslife_label "$name")")"
  printf 'workspace\t%s\tyes\t%s\t%s\t-\n' "$name" \
    "$([ -n "$ws_id" ] && printf yes || printf no)" \
    "$([ -n "$ws_id" ] && printf '-' || printf 'would create')"

  labels="$(_wslife_tab_labels "$ws_id")"
  local pane_label pane_cwd pane_cmd live
  while IFS=$'\t' read -r pane_label pane_cwd pane_cmd; do
    [ -n "$pane_label" ] || continue
    if printf '%s\n' "$labels" | grep -qxF "$pane_label"; then live=yes; else live=no; fi
    printf 'pane\t%s\tyes\t%s\t%s\t-\n' "$pane_label" "$live" \
      "$([ "$live" = yes ] && printf '-' || printf 'would open')"
  done < <(ws_layout_panes "$wsdir")

  local p alias dir occupant oname
  for p in $(ws_product_names "$wsdir"); do
    alias="$(_run_agent_name "$p-orch")"
    dir="$(ws_product_dir "$wsdir" "$p")"
    # ONE RESOLVER, AND IT SAYS WHERE THE ANSWER CAME FROM. This table used to
    # merge the layout mode with the product's own value by a rule of its own,
    # which is how `status` and the steward came to disagree in public.
    local declared source
    IFS=$'\t' read -r declared source <<< "$(ws_orchestrator_mode "$wsdir" "$p")"
    occupant="$(_run_live_agent_in_cwd "$dir")"
    oname=""; [ -z "$occupant" ] || IFS=$'\t' read -r oname _ <<< "$occupant"
    if [ -z "$occupant" ]; then
      live=no
    elif [ "$oname" = "$alias" ]; then
      live=yes
    else
      live=unnamed
    fi
    # A rename is offered whatever the switch says (see cmd_ws_up); only the
    # START belongs to `auto`.
    local action='-'
    case "$live" in
      unnamed) action='would rename' ;;
      no) [ "$declared" = auto ] && action='would start' ;;
    esac
    printf 'orchestrator\t%s\t%s\t%s\t%s\t%s\n' "$alias" "$declared" "$live" "$action" "$source"
  done
}

cmd_ws_status() { # [<name>] [--json]
  local name="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -*) die "cel ws status: unknown argument '$1'" ;;
      *) name="$1"; shift ;;
    esac
  done
  have jq || die "cel ws status: jq is not on PATH"
  local names; if [ -n "$name" ]; then names="$name"; else names="$(registry_names)"; fi

  local n wsdir rows kind mname declared live action source blocks=""
  for n in $names; do
    wsdir="$(registry_require "$n")"
    rows="$(_wslife_members "$wsdir" "$n")"
    if [ "$json" -eq 1 ]; then
      blocks="$blocks$(printf '%s\n' "$rows" | jq -R -s --arg name "$n" \
        'split("\n") | map(select(length > 0) | split("\t"))
         | map({kind: .[0], name: .[1], declared: .[2], live: .[3], action: .[4], source: .[5]})
         | {name: $name, members: .}')
"
      continue
    fi
    printf '%s\n' "$n"
    while IFS=$'\t' read -r kind mname declared live action source; do
      [ -n "$kind" ] || continue
      # The SOURCE rides beside the mode, in the same column: "declared
      # manual" told the owner nothing about which of three files said so.
      local shown="$declared"
      [ "$source" = '-' ] || shown="$declared via $source"
      printf '  %-12s %-22s declared %-18s live %-8s %s\n' \
        "$kind" "$mname" "$shown" "$live" \
        "$([ "$action" = '-' ] && printf '' || printf '(%s)' "$action")"
    done <<< "$rows"
  done
  [ "$json" -eq 0 ] || printf '%s' "$blocks" | jq -sc '{workspaces: .}'
  return 0
}

# ------------------------------------------------------- the doctor's line
# A nameless agent is a FAULT, not an absence, and the fault has a cure that
# fits on one line. Silent when there is nothing to say: a doctor that prints
# a paragraph about every healthy workspace is a doctor people stop reading.
wslife_doctor_lines() {
  have herdr && have jq || return 0
  local n wsdir p dir occupant oname
  for n in $(registry_names); do
    wsdir="$(registry_path "$n")"
    [ -f "$wsdir/workspace.yaml" ] || continue
    for p in $(ws_product_names "$wsdir" 2>/dev/null); do
      dir="$(ws_product_dir "$wsdir" "$p")"
      occupant="$(_run_live_agent_in_cwd "$dir")"
      [ -n "$occupant" ] || continue
      IFS=$'\t' read -r oname _ <<< "$occupant"
      [ "$oname" = "-" ] || continue
      printf '%s: an agent is running in %s with no herdr name - cel ws up %s renames it\n' \
        "$n" "${dir#"$wsdir"/}" "$n"
    done
  done
}
