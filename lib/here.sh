# shellcheck shell=bash
# cel here - the commands an agent's owner types inside its pane.
#
# One small set, the same in core, orchestrators and solo agents: /cel-mode,
# /cel-status, /cel-inbox, /cel-decide, /cel-review, /cel-land, /cel-restart
# (and /cel-focus in core). The runtimes register them as thin wrappers over
# `cel here <verb>` (tools/hooks/inbox.omp.ts for omp and pi, tools/claude/
# commands for Claude), and every verb here is in turn a thin wrapper over a
# `cel` command - the CLI stays the single implementation. What this file adds
# is WHO is asking: a verb is scoped to the pane's own product (from its
# launch identity, CEL_INBOX_ME/CEL_INBOX_WS) unless a product is named.
#
# The `cel-` prefix is deliberate: omp has built-in /review and /restart and
# Claude Code built-in /status and /review, so the plain names would be
# shadowed in some runtime; one prefixed set behaves the same everywhere.
[ -n "${_CEL_HERE:-}" ] && return 0
_CEL_HERE=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/mode.sh
. "${BASH_SOURCE[0]%/*}/mode.sh"

_here_usage() {
  cat <<'EOF'
usage: cel here <verb> [args]   (inside an agent: /cel-<verb>)
  mode [<product>] [solo|fleet]  show or switch the product's mode (restart at end of turn)
  status [<product>]             cel fleet for the product's workspace (core: the whole box)
  inbox                          unread mail now, without waiting for the hook
  decide                         open owner questions (core: all; others: your own)
  review [<repo>#]<pr>           start a reviewer pane for a PR
  land [<repo>#]<pr> [flags]     merge through this mode's checked path
                                 (fleet: cel-fanout land <id> [flags]; solo: cel solo land)
  restart                        restart this agent on its own session at end of turn
  focus <product>                core only: bring that product's agent forward
EOF
}

# The commands each verb wraps, as functions: the seam tests/here.test.sh
# replaces to see exactly what a verb would run.
_here_cel() { "$CEL_ROOT/bin/cel" "$@"; }
_here_fanout() { ( cd "$HERE_WSDIR" && "$CEL_ROOT/core/skills/fanout/bin/cel-fanout" "$@" ); }

# Who is asking: HERE_ROLE (core|orchestrator|solo|root|other), and for a
# product agent HERE_WSDIR and HERE_PRODUCT. Never guesses a product for core.
_here_identity() {
  HERE_ROLE="${CEL_ROLE:-other}" HERE_WSDIR="" HERE_PRODUCT=""
  case "$HERE_ROLE" in
    core|root) ;;
    orchestrator|solo)
      [ -n "${CEL_INBOX_WS:-}" ] && HERE_WSDIR="$(registry_path "$CEL_INBOX_WS" 2>/dev/null || true)"
      [ -n "$HERE_WSDIR" ] || HERE_WSDIR="$(ws_current 2>/dev/null || true)"
      [ -n "$HERE_WSDIR" ] && HERE_PRODUCT="$(_mode_product "$HERE_WSDIR")"
      [ -n "$HERE_PRODUCT" ] || die "cel here: cannot tell which product this pane is (CEL_INBOX_ME=${CEL_INBOX_ME:-unset}, CEL_INBOX_WS=${CEL_INBOX_WS:-unset})" ;;
    *) die "cel here: these commands are for core and product agents (this pane's role is ${CEL_ROLE:-not a Celestial agent})" ;;
  esac
}

# A product named on the command line: `<product>` or `<ws>/<product>`. Its
# workspace is the one registered workspace that declares it; two that both
# do must be told apart by the caller. Sets HERE_WSDIR and HERE_PRODUCT.
_here_named_product() { # <[ws/]product>
  local want="$1" ws="" n d hits=()
  case "$want" in */*) ws="${want%%/*}"; want="${want#*/}" ;; esac
  if [ -n "$ws" ]; then
    d="$(registry_require "$ws")"
    ws_product_names "$d" | grep -qxF "$want" || die "cel here: workspace $ws has no product '$want'"
    HERE_WSDIR="$d" HERE_PRODUCT="$want"; return 0
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    d="$(registry_path "$n" 2>/dev/null)" || continue
    ws_product_names "$d" 2>/dev/null | grep -qxF "$want" && hits+=("$d")
  done < <(registry_names 2>/dev/null)
  case "${#hits[@]}" in
    0) die "cel here: no registered workspace has a product named '$want' (cel fleet)" ;;
    1) HERE_WSDIR="${hits[0]}" HERE_PRODUCT="$want" ;;
    *) die "cel here: '$want' is a product in several workspaces - say which: <workspace>/$want" ;;
  esac
}

# The product a verb is about: the named one, else the pane's own. Core has
# no own product, so it must name one. A product agent acts on ITS product
# only - naming another (to switch its mode, which restarts that agent) is
# core's job, not a sibling's.
_here_target() { # [<[ws/]product>]
  if [ -n "${1:-}" ]; then
    case "$HERE_ROLE" in
      core|root) _here_named_product "$1"; return 0 ;;
    esac
    [ "$1" = "$HERE_PRODUCT" ] || [ "$1" = "$(ws_name "$HERE_WSDIR")/$HERE_PRODUCT" ] \
      || die "cel here: this pane is $HERE_PRODUCT's agent and acts on $HERE_PRODUCT only - ask core about '$1'"
    return 0
  fi
  [ -n "$HERE_PRODUCT" ] || die "cel here: name a product (core stands in no product)"
}

# `[<repo>#]<pr>` within the target product: a bare number means the
# product's one repo; a product of several repos must name it. Sets
# HERE_REPO and HERE_PR (globals, not output: die prints to stdout, and a
# refusal inside `$( )` would be swallowed).
_here_pr_ref() { # <ref>
  local ref="$1"
  case "$ref" in
    *#*) HERE_REPO="${ref%%#*}"; HERE_PR="${ref#*#}" ;;
    *) HERE_PR="$ref"
       local -a rs; mapfile -t rs < <(ws_product_repos "$HERE_WSDIR" "$HERE_PRODUCT")
       [ "${#rs[@]}" -eq 1 ] || die "cel here: $HERE_PRODUCT has several repos (${rs[*]}) - say which: <repo>#$HERE_PR"
       HERE_REPO="${rs[0]}" ;;
  esac
  case "$HERE_PR" in ''|*[!0-9]*) die "cel here: '$ref' is not a PR number" ;; esac
  grep -qxF "$HERE_REPO" <<< "$(ws_product_repos "$HERE_WSDIR" "$HERE_PRODUCT")" \
    || die "cel here: $HERE_REPO is not a repo of $HERE_PRODUCT"
}

# The delegation that owns a fleet PR: its head branch, matched on the
# ledger. Sets HERE_ID.
_here_ledger_id() { # <repo> <pr>
  local slug branch
  slug="$(ws_repo_github_slug "$HERE_WSDIR" "$1")" || die "cel here: no GitHub slug for $1"
  branch="$(gh pr view "$2" --repo "$slug" --json headRefName --jq .headRefName 2>/dev/null)" \
    || die "cel here: could not read $slug#$2"
  HERE_ID="$(jq -r --arg r "$1" --arg b "$branch" \
        '[.[] | select(.repo == $r and .branch == $b) | .id] | last // empty' \
        "$HERE_WSDIR/.cel/delegations.json" 2>/dev/null)"
  [ -n "$HERE_ID" ] || die "cel here: $slug#$2 (branch $branch) has no delegation on the ledger - cel-fanout land lands only what the fleet delegated"
}

# Core restarts itself the way `cel mode` restarts a product agent: detached,
# once it has been quiet for two polls, on its own session.
_here_core_status() {
  have herdr && have jq || return 2
  local roster; roster="$(herdr agent list 2>/dev/null)" || return 2
  printf '%s' "$roster" | jq -er --arg c "$(_run_core_dir)" \
    '[.result.agents[]? | select(.name == "core" and (.cwd // "") == $c)][0].agent_status // empty' 2>/dev/null \
    || return 1
}
_here_core_relaunch() { cmd_run core --restart; }
_here_core_restart_when_idle() {
  _mode_when_quiet "$(_run_core_dir)/restart.lock" core "start it with cel core" \
    -- _here_core_status -- _here_core_relaunch
}

cmd_here() {
  local verb="${1:-}"; [ $# -eq 0 ] || shift
  case "$verb" in
    ''|-h|--help|help) _here_usage; return 0 ;;
  esac
  _here_identity
  local who="${HERE_ROLE}"
  # The waiter `/cel-restart` schedules for core (lib/mode.sh _mode_detach
  # runs it with CEL_ROLE=core). Not a verb any other pane may call.
  if [ "$verb" = --restart-core-when-idle ]; then
    [ "$who" = core ] || die "cel here: only core's own restart runs its waiter"
    _here_core_restart_when_idle; return $?
  fi
  case "$verb" in
    mode)
      local p="" m="" a
      for a in "$@"; do case "$a" in solo|fleet) m="$a" ;; *) p="$a" ;; esac; done
      _here_target "$p"
      _here_cel mode "$HERE_PRODUCT" ${m:+"$m"} --workspace "$(ws_name "$HERE_WSDIR")" ;;
    status)
      if [ -n "${1:-}" ] || [ -n "$HERE_PRODUCT" ]; then
        _here_target "${1:-}"
        _here_cel fleet --workspace "$(ws_name "$HERE_WSDIR")"
      else
        _here_cel fleet
      fi ;;
    inbox)
      local me="${CEL_INBOX_ME:-}"
      [ "$who" = core ] && me=root
      [ -n "$me" ] || die "cel here inbox: this pane has no mailbox identity (CEL_INBOX_ME)"
      _here_cel inbox read --for "$me" --all-workspaces ;;
    decide)
      if [ "$who" = core ] || [ "$who" = root ]; then
        _here_cel decide list
      else
        _here_cel decide list --workspace "$(ws_name "$HERE_WSDIR")" --asker "${CEL_INBOX_ME:-$(_run_agent_name "$HERE_PRODUCT/orch")}"
      fi ;;
    review)
      [ "$who" != core ] || die "cel here review: core does not start reviewers - ask the product's agent"
      [ -n "${1:-}" ] || die "usage: cel here review [<repo>#]<pr>"
      _here_target ""
      _here_pr_ref "$1"
      _here_cel run reviewer --repo "$HERE_REPO" --pr "$HERE_PR" --workspace "$(ws_name "$HERE_WSDIR")" ;;
    land)
      [ "$who" != core ] || die "cel here land: core does not land PRs - the product's agent does"
      [ -n "${1:-}" ] || die "usage: cel here land [<repo>#]<pr> [cel-fanout land flags]"
      _here_target ""
      local ref="$1"; shift
      _here_pr_ref "$ref"
      local ws; ws="$(ws_name "$HERE_WSDIR")"
      if [ "$(ws_build_mode "$HERE_WSDIR" "$HERE_PRODUCT")" = solo ]; then
        [ $# -eq 0 ] || die "cel here land: cel solo land takes no extra flags (got: $*)"
        _here_cel solo land "$HERE_REPO#$HERE_PR" --workspace "$ws"
      else
        _here_ledger_id "$HERE_REPO" "$HERE_PR"
        _here_fanout land "$HERE_ID" --workspace "$ws" "$@"
      fi ;;
    restart)
      local rc=0
      if [ "$who" = core ]; then
        _mode_detach cel-core-restart env CEL_ROLE=core "$CEL_ROOT/bin/cel" here --restart-core-when-idle || rc=$?
        case "$rc" in
          0) printf 'core restarts on its own session once this turn ends\n' ;;
          3) printf 'a restart of core is already pending\n' ;;
          *) die "cel here restart: could not schedule it - run: cel core --restart" ;;
        esac
      elif [ "$who" = root ]; then
        die "cel here restart: run cel run root --restart from another pane"
      else
        # A lane restarts itself, never the product's main agent.
        local me; me="$(_run_agent_name "$HERE_PRODUCT/${CEL_LANE:-orch}")"
        _mode_schedule_restart "$HERE_WSDIR" "$HERE_PRODUCT" ${CEL_LANE:+"$CEL_LANE"} || rc=$?
        case "$rc" in
          0) printf '%s restarts on its own session once this turn ends\n' "$me" ;;
          3) printf 'a restart of %s is already pending\n' "$me" ;;
          *) die "cel here restart: could not schedule it - run: cel run solo --product $HERE_PRODUCT${CEL_LANE:+ --lane $CEL_LANE} --restart" ;;
        esac
      fi ;;
    focus)
      [ "$who" = core ] || die "cel here focus: core's command - your pane is already in front of you"
      [ -n "${1:-}" ] || die "usage: cel here focus <product>"
      _here_target "$1"
      herdr agent focus "$(_run_agent_name "$HERE_PRODUCT/orch")" ;;
    *) _here_usage >&2; die "cel here: unknown verb '$verb'" ;;
  esac
}
