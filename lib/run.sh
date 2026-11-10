# shellcheck shell=bash
# cel run - start an agent pane for a role, wired to a workspace via herdr.
# Architecture and trust boundaries: docs/architecture.md.
[ -n "${_CEL_RUN:-}" ] && return 0
_CEL_RUN=1
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/forge.sh
. "${BASH_SOURCE[0]%/*}/forge.sh"   # forge_pr_view: a reviewer's PR facts, on either forge
# shellcheck source=lib/manifest.sh
. "${BASH_SOURCE[0]%/*}/manifest.sh"
# shellcheck source=lib/profiles.sh
. "${BASH_SOURCE[0]%/*}/profiles.sh"
# shellcheck source=lib/gateway.sh
. "${BASH_SOURCE[0]%/*}/gateway.sh"
# shellcheck source=lib/boxguard.sh
. "${BASH_SOURCE[0]%/*}/boxguard.sh"
# shellcheck source=lib/rex.sh
. "${BASH_SOURCE[0]%/*}/rex.sh"
# shellcheck source=lib/opencode.sh
. "${BASH_SOURCE[0]%/*}/opencode.sh"
# shellcheck source=lib/run-evidence.sh
. "${BASH_SOURCE[0]%/*}/run-evidence.sh"
# shellcheck source=lib/reviewer-retirement.sh
. "${BASH_SOURCE[0]%/*}/reviewer-retirement.sh"
# shellcheck source=lib/budget.sh
. "${BASH_SOURCE[0]%/*}/budget.sh"     # budget_admit: the box-wide live agent budget
# shellcheck source=lib/review-policy.sh
. "${BASH_SOURCE[0]%/*}/review-policy.sh"   # review.extra: the extra reviewers a PR needs
# shellcheck source=lib/preview.sh
. "${BASH_SOURCE[0]%/*}/preview.sh"   # preview_qa_stop: a retired QA agent's preview goes with it

# PANE LABELS. The agent name is sanitised and cut to 32 characters, which
# is unreadable in the sidebar, so every pane the plane starts also gets
# herdr's free-text label. The cap is for readability, not a herdr limit.
CEL_PANE_LABEL_MAX=40

_pane_label_cap() { # <label> -> label cut on a word boundary with an ellipsis
  local LC_ALL=C.UTF-8 s="$1" max="$CEL_PANE_LABEL_MAX"
  if [ "${#s}" -le "$max" ]; then printf '%s' "$s"; return 0; fi
  local cut="${s:0:$((max - 1))}"
  # Back off to the last whole word, unless that leaves nothing to read.
  case "${s:$((max - 1)):1}" in
    " ") ;;
    *) [ "${cut% *}" = "$cut" ] || cut="${cut% *}" ;;
  esac
  cut="${cut%"${cut##*[! ]}"}"
  printf '%s…' "${cut% ·}"
}

pane_label() { # <reviewer|solo|root|direct> <args...>
  local kind="$1"; shift
  local l
  case "$kind" in
    reviewer)    l="review · $1 #$2" ;;
    root)        l="$1 root" ;;
    *)           l="$1 $kind" ;;
  esac
  _pane_label_cap "$l"
}

# After the pane exists and before the agent starts. A label is a nicety: a
# failed rename warns and the launch goes on.
pane_label_set() { # <pane> <label> [herdr-command...]
  local pane="$1" label="$2"; shift 2
  [ $# -gt 0 ] || set -- herdr
  "$@" pane rename "$pane" "$label" >/dev/null 2>&1 \
    || c_warn "could not label pane $pane '$label' - it starts unlabelled"
  return 0
}

# TABS TOO: herdr names a tab with a bare number, so a tab that holds one
# agent carries the same text as its pane. Not for a reviewer: its tab is
# shared and keeps "PR reviewer". Same rule as the pane: warn, go on.
tab_label_set() { # <pane> <label> [herdr-command...]
  local pane="$1" label="$2" tab; shift 2
  [ $# -gt 0 ] || set -- herdr
  tab="$("$@" pane get "$pane" 2>/dev/null | jq -r '.result.pane.tab_id // empty' 2>/dev/null || true)"
  if [ -z "$tab" ] || ! "$@" tab rename "$tab" "$label" >/dev/null 2>&1; then
    c_warn "could not label the tab of pane $pane '$label' - it keeps its number"
  fi
  return 0
}

# Where a role's body is written for a runtime that injects it from a file.
# A DECLARED product gets its own directory so two products' orchestrators
# never overwrite each other's role body; an implicit one keeps the original
# path so nothing about an existing workspace moves.
#
# The filename must keep ending in `role-orchestrator.md`: lib/gc.sh tells a
# long-lived agent from a stray one by that substring in the cmdline, and a
# renamed file would have the reaper collecting orchestrators.
_run_role_file() { # <wsdir> <tag> [product]
  local wsdir="$1" tag="$2" p="${3:-}"
  if [ -n "$p" ] && ws_product_declared "$wsdir" "$p"; then
    printf '%s' "$wsdir/.cel/products/$p/role-$tag.md"
  else
    printf '%s' "$wsdir/.cel/role-$tag.md"
  fi
}

# KEEP THE MODEL THE LAUNCH NAMED: omp prewalk would swap to the box's `smol`
# model after the first write, and the session's model provenance would lie.
# Every omp launch goes through here; prepends --no-prewalk to AGENT_ARGS.
_run_keep_model_args() { # <runtime>
  [ "$1" != omp ] || AGENT_ARGS=(--no-prewalk "${AGENT_ARGS[@]}")
}

# WAIT OUT A SPENT BUDGET: a pool-wide 429 asks for a retry longer than omp's
# default retry.maxDelayMs, so core, root and the orchestrators get a --config
# overlay that waits in-process. Workers do not: one asleep for hours holds a slot.
_run_retry_overlay_args() { # <runtime> <role>
  [ "$1" = omp ] || return 0
  case "$2" in core|root|orchestrator) ;; *) return 0 ;; esac
  AGENT_ARGS=("--config=$CEL_ROOT/core/omp-orchestrator.yml" "${AGENT_ARGS[@]}")
}

# Fills the global AGENT_ARGS array per the runtime's role_injection strategy
# in agents.yaml. File writes are real side effects, so they are skipped on a dry
# run - only the herdr command line is ever a preview.
#
# AGENT_ROLE_FILE is set to the path the role travelled as, or emptied: the
# launch environment below carries it, and `cel gc` proves ownership with it.
_run_agent_args() { # <runtime> <tag> <body> <dry-run 0|1> <wsdir> [rolefile]
  local rt="$1" tag="$2" body="$3" dry="$4" wsdir="$5" rolefile="${6:-}" strategy
  AGENT_ROLE_FILE=""
  strategy="$(agent_injection "$rt" strategy)"
  case "$strategy" in
    append_flag)
      AGENT_ARGS=("$(agent_injection "$rt" flag)" "$body")
      ;;
    append_flag_file)
      # herdr agent start types the launch line into a shell pane and refuses
      # any argument it cannot encode on one line (newlines, control chars),
      # so a multi-line role body travels as a file and only its path goes on
      # the command line.
      local file="${rolefile:-$wsdir/.cel/role-$tag.md}" temporary
      if [ "$dry" -eq 0 ]; then
        mkdir -p "$(dirname "$file")" || return 1
        temporary="$(mktemp "$(dirname "$file")/.role.XXXXXX")" || return 1
        if ! printf '%s\n' "$body" > "$temporary" || ! mv -f -- "$temporary" "$file"; then
          rm -f -- "$temporary"; return 1
        fi
      fi
      AGENT_ARGS=("$(agent_injection "$rt" flag)" "$file")
      AGENT_ROLE_FILE="$file"
      ;;
    prompt_arg)
      c_warn "runtime $rt injects the role as a prompt argument - it may not survive compaction"
      AGENT_ARGS=("$body")
      ;;
    agent_file)
      if [ "$rt" = opencode ]; then
        [ "${PROFILE_VIA:-}" = gateway ] || die 'cel run: OpenCode requires the prepared scoped gateway configuration'
        local scoped="${rolefile:-$wsdir/.cel/opencode/role-$tag.md}"
        opencode_agent_args "$tag" "$body" "$dry" "$scoped" "${scoped%.md}.opencode.json" \
          || die 'cel run: scoped OpenCode role/config is not prepared'
        return 0
      fi
      local dir file
      dir="$(expand "$(agent_injection "$rt" dir)")"
      file="$dir/cel-$tag.md"
      if [ "$dry" -eq 0 ]; then
        mkdir -p "$dir"
        { printf -- '---\ndescription: celestial plane %s (materialised by cel run)\n---\n' "$tag"
          printf '%s\n' "$body"; } > "$file"
      fi
      AGENT_ARGS=(--agent "cel-$tag")
      AGENT_ROLE_FILE="$file"
      ;;
    *)
      die "cel run: runtime '$rt' has no known role_injection strategy"
      ;;
  esac
}

# Prepend the runtime's inbox hook (agents.yaml inbox_hook) to AGENT_ARGS, if
# it has one, so every role launched gets the same delivery.
_run_inbox_hook_args() { # <runtime>  (mutates caller's AGENT_ARGS)
  local hflag hfile
  hflag="$(agent_inbox_hook "$1" flag)"; hfile="$(agent_inbox_hook "$1" file)"
  if [ -n "$hflag" ] && [ -n "$hfile" ]; then
    AGENT_ARGS=("$hflag" "$CEL_ROOT/$hfile" "${AGENT_ARGS[@]}")
  fi
}

# A HELPER STARTS CLEAN. A reviewer or team member inherits its pane's shell
# (the caller's environment, plus the workspace's env and env.local that the
# shell or a Rex launch script loads), and a reviewer pane once ran with the
# owner's CLOUDFLARE_API_TOKEN in it for a debug trace to print. So their
# launch line ends in a scrub, run in the pane after every K=V word and
# before the runtime: each inherited variable whose NAME looks like a
# credential is unset, except the names this launch line sets itself (the
# gateway key and session id when gateway-routed, the workspace account's
# GH_TOKEN, the role marks) and LAUNCH_ENV_KEEP (the provider key a direct
# profile authenticates with - _run_provider_key_env). Values never pass
# through the scrub: its argv holds names only. Matched case-insensitively.
# Product agents and core are not scrubbed (docs/architecture.md, "Launch
# environment by role").
_RUN_SECRET_NAMES='*_TOKEN|*_TOKENS|*_API_KEY|*_KEY|*_KEYS|*_SECRET|*_SECRETS|*_PASSWORD|*_PASSWD|*_PASS|*_CREDENTIAL|*_CREDENTIALS|*_PAT|*_DSN|DATABASE_URL|*_DATABASE_URL|AWS_*|CLOUDFLARE_*|CF_API_*|OPENROUTER_*'
_run_launch_scrub() { # <keep-name...> -> ` bash -c '<scrub>' cel-launch-clean '<keep>'` for the end of an env prefix
  local n keep=""
  for n in "$@"; do
    [[ "$n" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && keep="$keep $n"
  done
  # No single quote inside: the whole program is one single-quoted word in the
  # pane, whatever its shell.
  printf "bash -c 'k=\" \$1 \"; shift; for n in \$(compgen -e); do case \$k in *\" \$n \"*) continue ;; esac; shopt -s nocasematch; case \$n in %s) unset \"\$n\" ;; esac; shopt -u nocasematch; done; exec \"\$@\"' cel-launch-clean '%s'" \
    "$_RUN_SECRET_NAMES" "${keep# }"
}

# A REVIEWER'S GIT IS PINNED AT LAUNCH. The guard (lib/guard.sh
# _guard_reviewer_git) reads the words of a git command; git also reads its
# environment and every repository config it finds. So, after the scrub, a
# reviewer's runtime starts without the variables that name a program, a
# repository or config (env -u: git takes an empty GIT_EXTERNAL_DIFF as a
# program to run), with cat as its pager, and with config in the environment
# (GIT_CONFIG_COUNT - command-line scope, above any repository's own):
# safe.bareRepository=explicit, so a bare-repository-shaped directory a PR
# commits is never discovered from the cwd and its config never read;
# core.fsmonitor=false; core.pager=cat. diff.external is not set: an empty
# value is a program named "" and breaks every git diff, and the only config
# a reviewer's git can read is its own checkout's and the owner's.
_RUN_REVIEWER_GIT_UNSET='GIT_EXTERNAL_DIFF GIT_SSH GIT_SSH_COMMAND GIT_PROXY_COMMAND GIT_EXEC_PATH GIT_DIR GIT_WORK_TREE GIT_NAMESPACE GIT_CONFIG_PARAMETERS GIT_CONFIG'
_run_reviewer_git_env() { # -> `env -u ... K=V ...` for the end of a reviewer's prefix
  local n out=env
  for n in $_RUN_REVIEWER_GIT_UNSET; do out="$out -u $n"; done
  printf '%s GIT_PAGER=cat PAGER=cat GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=explicit GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false GIT_CONFIG_KEY_2=core.pager GIT_CONFIG_VALUE_2=cat' "$out"
}

# The one credential a direct (non-gateway) profile authenticates with: its
# model's provider `key_env` (agents.yaml providers). Nothing for a gateway
# route, a provider signed in through its CLI, or a model naming no provider
# (the runtime's own sign-in decides).
_run_provider_key_env() { # <model> <via> -> KEY_ENV name, or nothing
  [ "$2" != gateway ] || return 0
  local prov; prov="$(profile_provider "$1")"
  [ -n "$prov" ] || return 0
  [ "$(provider_get "$prov" auth)" != cli ] || return 0
  provider_get "$prov" key_env
}

# THE LAUNCHER MARKS ITS CHILDREN in /proc/<pid>/environ, fixed at exec, which
# `cel gc` reads to prove ownership (pi rewrites its argv). As an `env K=V ...`
# prefix, not an `export`: an export would outlive the agent in the pane's shell.
# A reviewer's or member's prefix ends in the scrub above (_run_launch_scrub).
_run_launch_env() { # <role> <wsdir> [rolefile] [inbox-me] [runtime] -> `env K=V K=V K=V `
  local role="$1" wsdir="$2" file="${3:-}" me="${4:-}" runtime="${5:-}" out
  printf -v out 'env CEL_ROLE=%q CEL_WORKSPACE=%q' "$role" "$wsdir"
  # THE AGENT ROOT IS PINNED, never inherited. pi and omp both read
  # PI_CODING_AGENT_DIR, so whichever value the pane's shell happens to carry
  # would otherwise decide where a harness keeps its sessions, and omp renames
  # pi's. The resolved root of THIS runtime is the only value either gets.
  case "$runtime" in
    pi)  printf -v out '%s PI_CODING_AGENT_DIR=%q' "$out" "$(gateway_pi_dir)" ;;
    omp) printf -v out '%s PI_CODING_AGENT_DIR=%q' "$out" "$(gateway_omp_dir)" ;;
  esac
  # Gateway credentials and the per-agent session key (_run_profile_gateway_setup
  # fills GATEWAY_ENV in the caller): the same launch-scoped K=V words, so they
  # exist only in the launched process and never in the pane's shell.
  local gw sets=""
  for gw in ${GATEWAY_ENV[@]+"${GATEWAY_ENV[@]}"} ${LAUNCH_ENV_EXTRA[@]+"${LAUNCH_ENV_EXTRA[@]}"}; do
    out="$out $gw"; sets="$sets ${gw%%=*}"
  done
  # WHOSE MAILBOX: `cel inbox` derives the reader from cwd, which an agent can
  # leave; root and orchestrators carry their identity from the launch instead.
  [ -z "$me" ] || printf -v out '%s CEL_INBOX_ME=%q CEL_INBOX_WS=%q' "$out" "$me" "$(ws_name "$wsdir")"
  # A runtime whose role is injected as a prompt argument has no file to name;
  # the other two still say whose the process is.
  [ -z "$file" ] || printf -v out '%s CEL_ROLE_FILE=%q' "$out" "$file"
  # ...and, for a workspace with `github.user`, the account it acts as: the
  # token is a substitution the PANE evaluates (lib/workspace.sh), never a value.
  # The guard goes AHEAD of `env`, so the agent's start is chained on it.
  local ghw="" ghg=""
  if [ -f "$wsdir/workspace.yaml" ]; then
    ghw="$(ws_github_env_word "$wsdir")"; ghg="$(ws_github_launch_guard "$wsdir")"
  fi
  [ -z "$ghw" ] || { out="$ghg$out $ghw"; sets="$sets ${ghw%%=*}"; }
  local oc_cmd=""
  if [ "$runtime" = opencode ] && [ -n "${CEL_OPENCODE_CONFIG_FILE:-}" ]; then
    out="$(opencode_launch_guard "$CEL_OPENCODE_CONFIG_FILE")$out $(opencode_launch_env)"
    [ "${session_backend:-herdr}" = rex ] || oc_cmd="$(opencode_launch_command)"
  fi
  case "$role" in
    reviewer|member)
      # shellcheck disable=SC2086  # $sets is a word list on purpose
      out="$out $(_run_launch_scrub $sets ${LAUNCH_ENV_KEEP[@]+"${LAUNCH_ENV_KEEP[@]}"})" ;;
  esac
  [ "$role" != reviewer ] || out="$out $(_run_reviewer_git_env)"
  [ -z "$oc_cmd" ] || out="$out $oc_cmd"
  printf '%s ' "$out"
}

# WHEN IS A PANE SAFE TO TYPE INTO. `herdr agent start` needs an "available
# shell": the pane's interactive shell owns the foreground. A fresh pane is still
# reading its rc files, and text typed then is never submitted. So nothing is
# typed until CEL_PANE_READY_STABLE consecutive probes inside CEL_PANE_READY_MS
# see no agent, the same terminal and shell, and a foreground of the shell alone
# (its process group, no other process). A terminal or shell that changes under
# us is somebody else's pane now: refuse, never wait it out.
# Probe output is one line: "<terminal_id>:<shell_pid>\t<verdict>", verdict one of
# ready | agent | busy | unavailable. Pane text is never read.
_run_pane_probe() { # <pane>
  local pane="$1" g p
  g="$("${_RUN_HERDR:-herdr}" pane get "$pane" 2>/dev/null)" && p="$("${_RUN_HERDR:-herdr}" pane process-info --pane "$pane" 2>/dev/null)" \
    || { printf ':\tunavailable\n'; return 0; }
  printf '%s\n%s\n' "$g" "$p" | jq -rs --arg pane "$pane" '
    (.[0].result.pane // {}) as $g | (.[1].result.process_info // {}) as $p
    | (($g.terminal_id // "") + ":" + (($p.shell_pid // "") | tostring)) as $id
    | (if ($g.pane_id // "") != $pane or ($p.pane_id // "") != $pane
          or ($g.terminal_id // "") == "" or ($p.shell_pid | type) != "number"
          or ($p.foreground_process_group_id | type) != "number"
          or (($p.foreground_processes // []) | length) == 0 then "unavailable"
       elif ($g.agent // null) != null then "agent"
       elif $p.foreground_process_group_id != $p.shell_pid
            or any($p.foreground_processes[]; .pid != $p.shell_pid) then "busy"
       else "ready" end) as $v
    | $id + "\t" + $v' 2>/dev/null || printf ':\tunavailable\n'
}

_run_ms_sleep() { local ms="$1" s; printf -v s '%d.%03d' $((ms / 1000)) $((ms % 1000)); sleep "$s"; }

_RUN_PANE_IDENT=""
_run_pane_await_shell() { # <pane> [expected-ident]: returns only for a stable ready shell, else dies
  local pane="$1" total="${CEL_PANE_READY_MS:-30000}" poll="${CEL_PANE_READY_POLL_MS:-250}"
  local need="${CEL_PANE_READY_STABLE:-3}" t0 out ident verdict base="${2:-}" streak=0 why=unavailable
  t0=$((${EPOCHREALTIME/./} / 1000))
  while :; do
    out="$(_run_pane_probe "$pane")"; ident="${out%%$'\t'*}"; verdict="${out#*$'\t'}"
    case "$verdict" in
      ready|agent|busy)
        if [ -z "$base" ]; then base="$ident"
        elif [ "$ident" != "$base" ]; then
          die "cel run: pane $pane changed owner while waiting for its shell (terminal or shell replaced) - nothing was typed and no agent was started; check the pane and re-run"
        fi ;;
    esac
    if [ "$verdict" = ready ]; then
      streak=$((streak + 1))
      if [ "$streak" -ge "$need" ]; then _RUN_PANE_IDENT="$base"; return 0; fi
    else
      streak=0; why="$verdict"
    fi
    if [ $(( ${EPOCHREALTIME/./} / 1000 - t0 )) -ge "$total" ]; then
      case "$why" in
        agent) why="an agent already runs in it" ;;
        busy)  why="a command other than the shell holds its foreground" ;;
        *)     why="herdr did not report its terminal and process state" ;;
      esac
      die "cel run: pane $pane shell does not own the foreground after $((total / 1000))s ($why) - nothing was typed, no agent was started, no launch was recorded. Re-run once the pane is idle"
    fi
    _run_ms_sleep "$poll"
  done
}

# Gateway credentials and role markers share one typed shell prefix;
# `pane run` executes in a child context, so its exports disappear before
# agent start. The prefix is staged only into a pane proven to be an available
# shell, and the pane is re-checked afterwards: anything that moved while the
# text was going in leaves it UNSUBMITTED and fails the launch. Ordinary role
# marks stay best effort when herdr refuses the text itself; gateway
# credentials are required.
_RUN_STAGED=0
_run_mark_launch() { # <pane> <env-prefix> [required]
  local pane="$1" prefix="$2" required="${3:-0}" out
  _RUN_STAGED=0
  [ -n "$pane" ] && [ -n "$prefix" ] || return 0
  _run_pane_await_shell "$pane"
  local ident="$_RUN_PANE_IDENT"
  if ! "${_RUN_HERDR:-herdr}" pane send-text "$pane" "$prefix" >/dev/null 2>&1; then
    [ "$required" != 1 ] || die "cel run: could not stage gateway credentials in pane $pane"
    c_warn "could not mark $pane with its role environment - cel gc will not recognise it"
    return 0
  fi
  _RUN_STAGED=1
  _run_pane_recheck "$pane" "$ident"
}

_run_pane_recheck() { # <pane> <ident>: the pane is still the same ready shell after typing
  [ "$(_run_pane_probe "$1")" = "$2"$'\t'ready ] && return 0
  die "cel run: pane $1 changed after the launch line was typed into it - no agent was started and nothing was submitted or retried. The typed text (contents withheld) is still pending at that pane's prompt: close the pane, or clear its line yourself"
}

# One agent start, never retried. A failure after the prefix was staged must
# not look like a launch: say where the unsubmitted text is and stop - no Enter,
# no second attempt, no clearing of input that may by now be somebody else's.
_run_agent_start() { # <pane> <name> <kind> <agent-args...>
  local pane="$1" name="$2" kind="$3" out; shift 3
  if out="$(${_RUN_AGENT_SPAWN:-} "${_RUN_HERDR:-herdr}" agent start "$name" --kind "$kind" --pane "$pane" -- "$@" 2>&1)"; then
    [ -n "${_RUN_AGENT_QUIET:-}" ] || printf '%s\n' "$out"
    return 0
  fi
  out="$(printf '%s' "$out" | head -1 | cut -c1-200 | sed -E 's/(OMP_GATEWAY_TOKEN|CEL_SESSION_ID)=[^ ]*/\1=****/g')"
  if [ "$_RUN_STAGED" -eq 1 ]; then
    die "cel run: herdr could not start $name in pane $pane (${out:-no detail}) - NOT retried, nothing recorded. The launch line (contents withheld) was typed into that pane but never submitted; it is still pending at the prompt. Close the pane or clear its line, then re-run"
  fi
  die "cel run: herdr could not start $name in pane $pane (${out:-no detail}) - not retried, nothing recorded"
}

# The herdr-workspace-manager CLI ships inside the plugin and is not put on
# PATH by `herdr plugin install`, so fall back to its install location.
_run_wsm_bin() {
  if have herdr-workspace-manager; then
    command -v herdr-workspace-manager
    return 0
  fi
  local b
  for b in "$HOME"/.config/herdr/plugins/github/herdr-plugin-workspace-manager-*/bin/herdr-workspace-manager; do
    [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

# Layouts resolve WORKSPACE FIRST: a workspace's own layouts.yml (beside
# workspace.yaml, like the externals.yaml overlay) beats the plane's generic
# file, so workspace content never has to live in the public plane repo. The
# wsm CLI takes exactly one config file, so resolution picks whichever file
# defines the id - no merging.
_run_layout_config() { # <wsdir> <layout-id> -> config path, or fail
  local f
  for f in "$1/layouts.yml" "$CEL_ROOT/tools/herdr/layouts/config.yml"; do
    [ -f "$f" ] && grep -q "id: $2\$" "$f" && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# Applies the workspace's declared layout (workspace.yaml `layout:`) to a
# freshly created herdr workspace, and prints the pane the root agent should
# start in. The apply REPLACES the workspace's first tab, so it must run
# before agent start; its JSON hands back the new panes as handles, and t0p0
# (first pane, first tab) is where the agent belongs. Standalone the CLI does
# not resolve the plugin's config dir, so the config path travels explicitly.
_run_apply_layout() { # <layout> <ws_id> <wsdir> <fallback-pane> -> pane id
  local layout="$1" ws_id="$2" wsdir="$3" fallback="$4"
  local wsm out pane cfg
  if ! wsm="$(_run_wsm_bin)"; then
    c_warn "workspace declares layout '$layout' but herdr-workspace-manager is not installed - layout skipped"
    printf '%s' "$fallback"; return 0
  fi
  if ! cfg="$(_run_layout_config "$wsdir" "$layout")"; then
    c_warn "layout '$layout' not defined in $wsdir/layouts.yml or the plane config - skipped"
    printf '%s' "$fallback"; return 0
  fi
  if ! out="$(HERDR_WSM_CONFIG="$cfg" \
              HERDR_WSM_WORKSPACE="$ws_id" HERDR_WSM_CWD="$wsdir" \
              "$wsm" apply "$layout" 2>&1)"; then
    c_warn "layout '$layout' failed to apply: $(printf '%s' "$out" | tail -1)"
    printf '%s' "$fallback"; return 0
  fi
  pane="$(printf '%s' "$out" | tail -1 | jq -r '.handles.t0p0 // empty' 2>/dev/null)"
  [ -n "$pane" ] && printf '%s' "$pane" || printf '%s' "$fallback"
}

# Reviewer and team-member panes live in the CALLER's herdr view (the product
# agent runs `cel run reviewer` / `cel team add` from its own pane), in tabs
# with one label per kind: "PR reviewer", or "team <feature>" - one per
# feature. Panes are smart-sized: each new pane splits the tab's current
# largest pane along its longer visual edge. Six panes fill a tab; the seventh
# opens a fresh tab with the same label and the count restarts. No new
# workspace: the pane opens in <cwd>, the agent's own directory.
_RUN_REVIEW_TAB_CAP=6
_run_tab_pane() { # <tab-label> <cwd> <who: reviewer|member> -> pane id
  local label="$1" cwd="$2" who="$3" ws="${HERDR_WORKSPACE_ID:-}" tab pane resp n first
  [ -n "$ws" ] || die "cel run $who: not inside a herdr pane (no HERDR_WORKSPACE_ID)"
  # newest tab with the label: earlier ones are already full
  tab="$(herdr tab list --workspace "$ws" \
         | jq -r --arg l "$label" '.result.tabs[] | select(.label == $l) | .tab_id' | tail -1)"
  n=0
  if [ -n "$tab" ]; then
    read -r n first < <(herdr pane list --workspace "$ws" \
      | jq -r --arg t "$tab" '[.result.panes[] | select(.tab_id == $t)]
                              | "\(length) \(.[0].pane_id // "")"')
  fi
  if [ -z "$tab" ] || [ "$n" -ge "$_RUN_REVIEW_TAB_CAP" ]; then
    resp="$(herdr tab create --workspace "$ws" --label "$label" --cwd "$cwd" --no-focus)" \
      || die "cel run $who: tab create failed"
    pane="$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id // empty')"
  else
    # Largest pane by area gets the split, along its longer visual edge - a
    # terminal cell is roughly twice as tall as it is wide, hence the 2x.
    local target dir
    read -r target dir < <(herdr pane layout --pane "$first" \
      | jq -r '.result.layout.panes | max_by(.rect.width * .rect.height)
               | "\(.pane_id) \(if .rect.width >= 2 * .rect.height then "right" else "down" end)"')
    [ -n "$target" ] || die "cel run $who: could not read the $label tab layout"
    resp="$(herdr pane split --pane "$target" --direction "$dir" --cwd "$cwd" --no-focus)" \
      || die "cel run $who: pane split failed"
    pane="$(printf '%s' "$resp" | jq -r '.result.pane.pane_id // empty')"
  fi
  [ -n "$pane" ] || die "cel run $who: no pane id in herdr response"
  printf '%s' "$pane"
}

# THE TREE A REVIEWER READS is a checkout of its own, DETACHED at the PR's head:
# the orchestrator's checkout has no relationship to the PR and drifts. A linked
# worktree of the orchestrator's clone costs a fetch, not a clone; detached, it
# has no branch to push.
_run_review_dir() { printf '%s' "${CEL_REVIEW_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cel/reviews}"; }

# An extra agent (--focus, --qa) has a checkout of its own beside the plain
# reviewer's: <repo>-pr-<n>-<kind>-<focus>, the slot its alias ends in.
reviewer_checkout_path() { # <repo> <pr> [focus] [kind]
  printf '%s/%s-pr-%s%s' "$(_run_review_dir)" "$1" "$2" "${3:+-${4:-review}-$3}"
}

# What the repo's forge says this PR is, asked once at launch: the head we
# are about to check out and the base branch the diff is against. Both
# travel into the brief, because a review whose "main" is a directory is not
# a review. GitHub or Forgejo alike (lib/forge.sh), as the workspace's own
# account there; the forge's reason for a refusal goes to stderr.
_run_reviewer_pr_facts() { # <wsdir> <repo> <pr> -> head<TAB>base
  local out
  out="$(forge_pr_view "$1" "$2" "$3")" || return 1
  printf '%s' "$out" | jq -re 'if (.head_sha | type) == "string" and .head_sha != "" then [.head_sha, (.base_ref // "")] | @tsv else error("no head") end' 2>/dev/null
}

# The PR head reaches a fork's commits too, which is why this fetches
# `pull/<n>/head` rather than the branch name: a contributor's branch does not
# exist in origin at all. GitHub and Forgejo both serve that ref.
reviewer_checkout_make() { # <repodir> <repo> <pr> <head> [focus] [kind] -> path
  local repodir="$1" repo="$2" pr="$3" head="$4" path reserved=0 who
  path="$(reviewer_checkout_path "$repo" "$pr" "${5:-}" "${6:-}")"
  # A new pathname is not duplicate admission. Check the whole retained
  # round namespace even when the original checkout no longer exists.
  if who="$(_reviewer_checkout_occupant "$path")"; then
    c_warn "kept $path: pane ${who%%$'\t'*} is standing in it"
    return 1
  fi
  mkdir -p "$(dirname "$path")" || return 1
  if [ -e "$path" ]; then
    path="$(mktemp -d "$path.round.XXXXXX")" || return 1
    reserved=1
  fi
  git -C "$repodir" fetch -q origin "pull/$pr/head" 2>/dev/null || true
  if ! git -C "$repodir" worktree add -q --detach "$path" "$head" 2>/dev/null; then
    [ "$reserved" = 0 ] || rmdir -- "$path" 2>/dev/null || true
    return 1
  fi
  printf '%s' "$path"
}

# WHO IS STANDING IN THIS CHECKOUT, asked of the herdr roster at the moment
# it matters. The reviewer registry says who was recorded; only the roster
# says who is there, so no delete is ever decided from the registry.
#
# A roster that cannot be read is an occupied directory: deleting someone's
# working tree is not a risk worth taking to save a few megabytes until the
# next sweep. No herdr at all means no panes, so nothing can stand there.
_reviewer_checkout_occupant() { # path -> pane<TAB>name<TAB>managed-checkout; 0 = occupied/unknown
  local path="${1%/}" roster match rc=0
  roster="$(cel_agent_list 2>/dev/null)" || { printf 'unknown\troster unreadable'; return 0; }
  [ -n "$roster" ] || { printf 'unknown\troster unreadable'; return 0; }
  # A reply that parses but is not a roster is as unreadable as no reply.
  printf '%s' "$roster" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 \
    || { printf 'unknown\troster unreadable'; return 0; }
  match="$(printf '%s' "$roster" | jq -er --arg c "$path" '
      if any(.result.agents[]?; (.cwd | type) != "string" or .cwd == "") then error("unknown native cwd") else . end
      | [.result.agents[]? | . as $a | ((.cwd // "") | sub(" \\(deleted\\)$"; "")) as $d
       | select($d == $c or ($d | startswith($c + "/")) or ($d | startswith($c + ".round.")))
       | {pane_id: $a.pane_id, name: $a.name,
          cwd: (if $d == $c or ($d | startswith($c + "/")) then $c
                else $c + ".round." + ($d | ltrimstr($c + ".round.") | split("/")[0]) end)}]
      | if length > 1 then [{pane_id:"unknown",name:"multiple native occupants",cwd:$c}] else . end
      | .[0] // empty
      | [((.pane_id // "") | if . == "" then "unknown" else . end), ((.name // "") | if . == "" then "-" else . end), .cwd] | @tsv' 2>/dev/null)" || rc=$?
  case "$rc" in
    0) printf '%s' "$match" ;;
    4) return 1 ;;
    *) printf 'unknown\troster unreadable' ;;
  esac
}

_reviewer_worktree_drop() { # <repodir> <path>; fails, deleting nothing, while a pane stands in it
  [ -n "${2:-}" ] || return 0
  [ -e "$2" ] || [ -n "$1" ] || return 0
  local who
  if [ -e "$2" ] && rex_reviewer_checkout_preserved "$2"; then
    c_warn "kept $2: retained native reviewer evidence"
    return 1
  fi
  if [ -e "$2" ] && who="$(_reviewer_checkout_occupant "$2")"; then
    c_warn "kept $2: pane ${who%%$'\t'*} is standing in it"
    return 1
  fi
  git -C "$1" worktree remove --force "$2" >/dev/null 2>&1 || rm -rf -- "$2"
  git -C "$1" worktree prune >/dev/null 2>&1 || true
  return 0
}

# A reviewer's checkout goes with its pane: whatever closes the reviewer calls
# this - `cel gc` does, right after the pane goes, naming the pane so the row
# is the one it closed whichever workspace recorded it. More than one row
# answering is not a checkout anyone can name, so nothing is dropped.
# A QA AGENT'S PREVIEW GOES WITH IT TOO: the server it ran the PR's head in
# is stopped and that preview's own checkout removed (lib/preview.sh
# preview_qa_stop) - a preview nobody drives any more is memory and disk.
reviewer_checkout_release() { # <repo> <pr> [pane] [focus] [kind]
  local rows row path repodir kind
  rows="$(reviewers_rows)" || return 0
  row="$(printf '%s' "$rows" | jq -c --arg r "$1" --arg p "$2" --arg pane "${3:-}" --arg f "${4:-}" --arg k "${5:-review}" \
    '[.[] | select(.repo == $r and ((.pr | tostring) == $p) and ($pane == "" or .pane == $pane)
                   and ($pane != "" or ((.focus // "") == $f and (.kind // "review") == $k)))]
     | if length == 1 then .[0] else empty end')" || return 0
  [ -n "$row" ] || return 0
  kind="$(printf '%s' "$row" | jq -r '.kind // "review"')"
  # A preview that will not stop keeps its record; the steward's preview_sweep
  # stops it once no live agent bears this one's name (lib/preview.sh).
  [ "$kind" != qa ] || preview_qa_stop "$1" "$2" "$(printf '%s' "$row" | jq -r '.focus // ""')" \
    || c_warn "the QA preview of $1#$2 did not stop - its record is kept and the steward's preview sweep stops it once $(printf '%s' "$row" | jq -r '.agent // "its agent"') is gone"
  path="$(printf '%s' "$row" | jq -r '.checkout // ""')"
  repodir="$(printf '%s' "$row" | jq -r '.repodir // ""')"
  # A row `cel gc` adopted carries no checkout; the path is derived from repo,
  # PR, focus and kind alone. Retained Rex evidence and occupants still veto
  # the drop.
  [ -n "$path" ] || path="$(reviewer_checkout_path "$1" "$2" "$(printf '%s' "$row" | jq -r '.focus // ""')" "$kind")"
  [ -e "$path" ] || return 0
  # Kept while anything stands in it; the next sweep releases it once the
  # pane has gone. The row may already be dropped by then - the gone-pane
  # pass drops it - so a kept checkout's path is not lost: a live pane in it
  # is a reviewer the next sweep adopts and records again.
  _reviewer_worktree_drop "$repodir" "$path" || return 0
  rm -rf -- "$path"
  return 0
}

# WHAT THE REVIEWER IS TOLD IT IS READING. Appended to the role body so the
# facts arrive with the agent rather than in whatever an orchestrator happens
# to type: the head SHA, the base it compares against, and the command that
# tells it the head has moved - reviewing an older head is fine, silently is not.
_run_reviewer_brief() { # <repo> <pr> <head> <base> <path>
  cat <<EOF

## This review
You are reading a checkout of your own, detached at this pull request's head.
It is not the orchestrator's working copy and nothing moves it under you.

- repo: \`$1\`, pull request: #$2
- head you are reading: \`$3\` (in \`$5\`)
- base you compare against: \`origin/$4\` - say "origin/$4", never "main" as a
  directory, and anchor every claim about the base to that ref.

Before you conclude anything, check the head has not moved:
\`cel forge pr view $1#$2 --json\` (its \`head_sha\`). If it differs from \`$3\`, say so
in your verdict - you are reviewing an older head, which is a fact about the
review, not a detail. Nothing here is a branch, so there is nothing to push.
EOF
}

# WHOSE PR THIS IS AND HOW IT SHIPS: the product's solo agent wrote it, so
# the reviewer's verdict and findings go to that agent, and the PR lands with
# `cel solo land` on exactly the head that verdict approved.
_run_reviewer_solo_brief() { # <wsdir> <repo> <pr> [focus] [kind]
  local product; product="$(ws_product_of_repo "$1" "$2")"
  # Findings go to whoever owns the repo's PRs (ws_repo_pr_owner): the lane a
  # repo declares (repos[].lane), whoever started this reviewer; else the solo
  # agent that asked for it - the product's main agent, or the lane that
  # opened the PR.
  local starter="" author me="<your alias>" fflag="" verdicts="approved|changes" ev=""
  [ "${CEL_ROLE:-}" = solo ] && [ -n "${CEL_INBOX_ME:-}" ] && starter="$CEL_INBOX_ME"
  author="$(ws_repo_pr_owner "$1" "$2" "$starter")"
  if [ "${5:-review}" = qa ]; then
    me="$(review_alias "$2" "$3" "$4" qa)"; fflag=" --qa $4"; verdicts="approved|changes|blocked"
    ev=" --evidence <file> [--evidence <file>]..."
  elif [ -n "${4:-}" ]; then
    me="$(review_alias "$2" "$3" "$4")"; fflag=" --focus $4"
  fi
  cat <<EOF

## Whose PR this is
\`$product\` is built by its solo agents. This PR is \`$author\`'s. So:
- record your verdict with
  \`cel solo review $2#$3 <$verdicts> --head <reviewed-sha> --by $me$fflag$ev --note "<one line>"\`
  (the full 40-character SHA you read; an approval must equal
  the PR's current head);
- send findings and your verdict to \`$author\` by \`cel inbox send\`.
It merges with \`cel solo land $2#$3\`, which honours only your recorded
approval of the exact head it merges.
EOF
}

# AN EXTRA REVIEWER IS TOLD WHAT IT IS: one specialist beside the PR's plain
# reviewer, under its own alias, with its focus pack
# (core/roles/focus/reviewer/<focus>.md, front matter dropped).
_run_reviewer_focus_brief() { # <repo> <pr> <focus>
  local me plain
  me="$(review_alias "$1" "$2" "$3")"; plain="$(review_alias "$1" "$2")"
  cat <<EOF

## Focus: $3
You are an EXTRA reviewer of this pull request, started for one focus. The
PR's plain reviewer, \`$plain\`, reviews the whole change; you judge it through
the focus below, and your verdict is about that. Your alias is \`$me\`, not
\`$plain\`: sign with it, and record your verdict with \`--focus $3\` - land
counts it only from you, at the head you name.

EOF
  _run_focus_pack "$(review_focus_dir)/$3.md"
}
_run_focus_pack() { awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$1"; }

# A QA AGENT IS TOLD EXACTLY HOW TO RUN THIS HEAD: the preview command pinned
# to the head it was started for (lib/preview.sh, `--qa` gives it a preview
# of its own), whether the repo declares a preview at all, where its
# screenshots go and how they are named, and its qa focus pack
# (core/roles/focus/qa/<focus>.md).
_run_qa_brief() { # <wsdir> <repo> <pr> <focus> <head>
  local wsdir="$1" repo="$2" pr="$3" focus="$4" head="$5" me plain shots preview
  me="$(review_alias "$repo" "$pr" "$focus" qa)"; plain="$(review_alias "$repo" "$pr")"
  shots="$wsdir/.cel/reviews/pr-$pr/qa-$focus.shots"
  preview="$(ws_repo_preview "$wsdir" "$repo" cmd 2>/dev/null || true)"
  cat <<EOF

## QA: $focus
You are the $focus QA agent of $repo#$pr, beside its code reviewer \`$plain\`.
Your alias is \`$me\`: sign with it, and record with \`--qa $focus\` - land
counts your verdict only from you, at the head you name.

Run THIS head, \`$head\`, and nothing else:
- start it: \`cel preview $repo#$pr --qa $focus --head $head --workspace $(ws_name "$wsdir")\`
  - its own server and its own detached checkout of that head, under
  \`$wsdir/.cel/previews/\`; the last lines it prints are the URLs. A refusal
  that the PR moved means a new head: say so to the author, do not test it.
- stop it when you are done: \`cel preview $repo#$pr --qa $focus --stop\`
  (retiring you stops it too).
EOF
  if [ -z "$preview" ]; then
    cat <<EOF
- $repo declares NO \`preview:\` block in workspace.yaml, so \`cel preview\`
  refuses. Do not start the app by hand outside it (a hand-started app gets
  your environment and keys). Record \`blocked\` with
  \`--note "$repo declares no preview: block - add preview: { cmd, url } to workspace.yaml"\`
  and tell the author.
EOF
  fi
  cat <<EOF

Evidence: save screenshots (or recordings, console logs) under
\`$shots/\`, each file named with the head, e.g. \`login-${head:0:12}.png\`, and
pass each one to \`cel solo review\` with \`--evidence\`. \`approved\` and
\`changes\` need at least one; \`blocked\` needs \`--note\` saying why.

EOF
  _run_focus_pack "$(review_focus_dir qa)/$focus.md"
}

# A PR'S REVIEWERS, PLAIN AND EXTRA. `cel run reviewer --repo r --pr n`
# starts (or reuses) the plain reviewer, then every extra agent the review
# policy requires for the files the PR touches now (lib/review-policy.sh) -
# extra reviewers (`--focus`) and QA agents (`--qa`) alike, each through the
# same single launch, so each is admitted against the box budget, reused
# when live and recorded like any reviewer - and says which extra ones it
# started and why. A malformed policy refuses before anything starts; a dry
# run asks the forge nothing, so it previews the plain reviewer and names
# what the policy could add.
_run_reviewer_set() { # <wsdir> <repo> <pr> <dry-run> <cel run reviewer args...>
  local wsdir="$1" repo="$2" pr="$3" dry="$4" entries req f k why rc=0
  shift 4
  entries="$(review_extra_entries "$wsdir" "$repo" 2>&1)" \
    || die "cel run reviewer: $entries - nothing started"
  ( _run_reviewer_one "$@" ) || return $?
  [ "$entries" != '[]' ] || return 0
  local names; names="$(jq -r '[.[] | (if .kind == "qa" then "qa " else "" end) + .focus] | join(", ")' <<<"$entries")"
  if [ "$dry" = 1 ]; then
    printf "extra reviewers: review.extra may add %s - which ones %s#%s needs is read from the files it touches at launch (a dry run asks the forge nothing)\n" \
      "$names" "$repo" "$pr"
    return 0
  fi
  req="$(review_extra_required "$wsdir" "$repo" "$pr" 2>&1)" \
    || die "cel run reviewer: the plain reviewer is up, but $req; start them with --focus or --qa once it answers"
  if [ "$req" = '[]' ]; then
    c_ok "no extra reviewer for $repo#$pr: no file it touches matches review.extra ($names)"
    return 0
  fi
  while IFS=$'\t' read -r k f why; do
    if [ "$k" = qa ]; then
      c_ok "$f QA agent for $repo#$pr: $why"
      ( _run_reviewer_one "$@" --qa "$f" ) || rc=$?
    else
      c_ok "$f reviewer for $repo#$pr: $why"
      ( _run_reviewer_one "$@" --focus "$f" ) || rc=$?
    fi
  done < <(jq -r "$_REVIEW_JQ_WHY"'.[] | [.kind, .focus, review_why] | @tsv' <<<"$req")
  return "$rc"
}
_run_reviewer_one() { local _run_review_one=1; _cmd_run reviewer "$@"; }

# A LANE'S NAME MUST BE ITS OWN. The pane name and mailbox are
# `<product>-<lane>` after cel_alias_norm, which truncates at 32 characters -
# so a long pair, or one that spells another agent's alias (`<q>-orch` of a
# product `<product>-<x>`, `<repo>-direct`, `<repo>-pr-<n>-review`,
# `<ws>-root`), would share a pane name and mailbox with that agent while its
# directory differs, and nothing else would notice.
_run_lane_name_free() { # <wsdir> <product> <lane>
  local want="$2-$3" name q r
  name="$(_run_agent_name "$2/$3")"
  [ "$name" = "$want" ] || die "cel run solo --lane: '$3' makes the agent name '$name', not '$want' (names are cut to 32 characters) - use a shorter lane name"
  [ "$name" != "$(_run_agent_name "$(ws_name "$1")/root")" ] || die "cel run solo --lane: '$name' is the workspace root's name"
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    [ "$name" != "$(_run_agent_name "$q/orch")" ] || die "cel run solo --lane: '$name' is product $q's agent - pick another lane name"
  done < <(ws_product_names "$1")
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$name" in
      "$r-direct"|"$r"-pr-*-review|"$r"-pr-*-review-*|"$r"-pr-*-qa-*) die "cel run solo --lane: '$name' is the name of $r's $( [ "$name" = "$r-direct" ] && echo direct pane || echo reviewer) - pick another lane name" ;;
    esac
  done < <(ws_repo_names "$1")
  return 0
}

# What a lane is told on top of the solo role: its name, that the product has
# other agents working in the same repos, and how not to collide with them.
_run_lane_brief() { # <product> <lane> <agent-name>
  cat <<EOF

## You are a lane
You are \`$3\`, lane \`$2\` of \`$1\`. The owner runs more than one solo agent
on this product, each on its own goal - yours is the one the owner gives you
in this pane or sends to your mailbox, \`$3\` (read it with \`cel inbox read\`;
a brief may be waiting there from before you started). Wherever the role says
\`$1-orch\`, read \`$3\`: that is your pane name and mailbox. \`$1-orch\` and
any other \`$1-*\` lane are peers working in the same repos.
- Work only through your own branches and worktrees (under
  \`.cel/solo/$1/\`), and only on your goal.
- Before a change that touches files another lane is likely to touch, tell it
  by \`cel inbox send <its name> "..."\`; rebase rather than overwrite.
- Land only your own PRs.
EOF
}

# A FRESH CLAUDE LANE GETS A FIRST TURN. Claude's mail arrives through its
# UserPromptSubmit hook (tools/hooks/inbox-drain.sh), which runs only when a
# turn is submitted, so a brief sent before the lane started would sit unread.
# This rides on the command line as Claude's first prompt: one line, no option
# syntax, and the hook attaches what is waiting.
_run_lane_kickoff() { # <product> <lane> <agent-name>
  printf 'You have just started as %s, lane %s of %s. Any mail already waiting in your inbox is attached to this message; if it gives your goal, start on it. If nothing is attached, run cel inbox read once, and if there is still no goal, say so in one line and wait for the owner.' "$3" "$2" "$1"
}

# CLAUDE CODE ASKS BEFORE IT WORKS IN A FOLDER IT HAS NOT SEEN, and a lane's
# directory is always new to it; the prompt's default answer is "No, exit".
# So projects[<dir>].hasTrustDialogAccepted is set in
# ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json for exactly that directory - as given
# and as resolved - and nothing else in the file changes. Claude serialises its
# writes with the lock DIRECTORY <file>.lock (proper-lockfile), so this takes
# the same lock, writes a private temporary file and renames it over. A lock
# held past the wait, or a file that is not a JSON object, is refused rather
# than overwritten.
_run_claude_config_file() { printf '%s/.claude.json' "${CLAUDE_CONFIG_DIR:-$HOME}"; }

_run_claude_trust_dir() { # <dir>
  local given="$1" real f target lock tmp="" waited=0 wait_ms="${CEL_CLAUDE_LOCK_WAIT_MS:-5000}" rc=0
  real="$(cd "$given" 2>/dev/null && pwd -P)" || return 1
  f="$(_run_claude_config_file)"; lock="$f.lock"; target="$f"
  if [ -L "$f" ]; then target="$(readlink -f -- "$f")" || return 1; fi
  mkdir -p "$(dirname "$f")" || return 1
  until mkdir "$lock" 2>/dev/null; do
    [ "$waited" -lt "$wait_ms" ] || return 1
    _run_ms_sleep 50; waited=$((waited + 50))
  done
  local dirs filter='
    if type != "object" or ((.projects // {}) | type) != "object" then error("not a Claude Code config")
    else .projects = (reduce $dirs[] as $d ((.projects // {}); .[$d] = ((.[$d] // {}) + {hasTrustDialogAccepted: true}))) end'
  dirs="$(jq -cn --arg a "$given" --arg b "$real" '[$a, $b] | unique')"
  if [ ! -e "$target" ]; then
    tmp="$(mktemp "$target.tmp.XXXXXX")" && jq -n --argjson dirs "$dirs" "{} | $filter" > "$tmp" \
      && mv -f -- "$tmp" "$target" || rc=1
  elif jq -e --argjson dirs "$dirs" '. as $c | type == "object" and all($dirs[]; . as $d | $c.projects[$d].hasTrustDialogAccepted? == true)' \
         "$target" >/dev/null 2>&1; then
    : # already trusted: the file is left exactly as it is
  else
    # An empty input gives empty output, which must never replace the file.
    tmp="$(mktemp "$target.tmp.XXXXXX")" && jq --argjson dirs "$dirs" "$filter" "$target" > "$tmp" 2>/dev/null \
      && [ -s "$tmp" ] && chmod --reference="$target" "$tmp" && mv -f -- "$tmp" "$target" || rc=1
  fi
  [ -z "$tmp" ] || rm -f -- "$tmp"
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

# THE REVIEWER REGISTRY. A reviewer needs its own record, or nothing can know
# it is finished and its idle pane outlives its PR.
#
# It is box-level state, so it lives
# where the rest of the box's state does, beside gc-kept.json - and because it
# is box-level, a row is keyed by WORKSPACE + repo + PR: two workspaces may
# both hold a `widget` with a #12, and they are two reviews.
_reviewers_state() { printf '%s' "${CEL_REVIEWERS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/cel/reviewers.json}"; }

# A missing file is an empty registry. A file that does not parse as rows is
# UNKNOWN, not empty: status 2 and nothing printed. Admission refuses on it -
# an empty answer would let a second reviewer in beside one whose row was in
# that file - and only `cel gc`, which rebuilds the index from the live
# roster, writes over it (reviewers_update --recover).
reviewers_rows() { # -> JSON array; 2 = the file exists and is not a registry
  local f
  f="$(_reviewers_state)"
  [ -e "$f" ] || { printf '[]'; return 0; }
  jq -ce 'if type == "array" and all(.[];
      (.repo | type == "string") and (.pane | type == "string") and (.pr != null))
    then . else error("not a reviewer registry") end' "$f" 2>/dev/null || return 2
}

# WHICH WORKSPACE A ROW BELONGS TO. Rows written before the key carried a
# workspace still say where they were cut from: `repodir` is
# <workspace>/repos/<repo>. A row without even that ($here) belongs to the
# asking workspace only when no OTHER registered workspace has the repo: a
# workspace without it cannot have launched the reviewer, and with two
# candidates the row is nobody's - never matched, never replaced by a record,
# left for `cel gc` to attribute from the live process.
# A ROW IS ONE REVIEWER: workspace, repo, PR, focus ("" for the plain
# reviewer, the focus of an extra one - `cel run reviewer --focus`) and kind
# (`review`, absent on the row, or `qa` for a QA agent - `--qa`).
_REVIEWERS_JQ_SCOPE='
  def rv_ws: . as $x | ("/repos/" + ($x.repo // "")) as $tail
    | if (($x.workspace // "") | type == "string" and length > 0) then $x.workspace
      elif (($x.repodir // "") | type == "string" and endswith($tail) and length > ($tail | length))
        then ($x.repodir | .[0:(length - ($tail | length))])
      else null end;
  def rv_key($ws; $here; $r; $p; $f; $k): .repo == $r and ((.pr | tostring) == $p) and ((.focus // "") == $f)
    and ((.kind // "review") == $k)
    and (rv_ws as $w | if $w == null then $here else $w == $ws end);'

_reviewers_here() { # <wsdir> <repo> -> true|false: may a workspace-less row be this workspace's?
  local names ws d
  [ -d "$1/repos/$2" ] || { printf false; return 0; }
  # A workspace registry that cannot be read cannot rule the others out.
  names="$(registry_names 2>/dev/null)" || { printf false; return 0; }
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    d="$(registry_path "$ws" 2>/dev/null)" || { printf false; return 0; }
    [ -n "$d" ] && ! [ "$d" -ef "$1" ] || continue
    [ ! -d "$d/repos/$2" ] || { printf false; return 0; }
  done <<< "$names"
  printf true
}

# WHAT A HERDR PANE'S AGENT WAS LAUNCHED AS, proven from the process: its
# runtime carries the launch line's env (_run_launch_env) in
# /proc/<pid>/environ, fixed at exec. Only a pid in the pane's foreground group
# that carries this pane's HERDR_PANE_ID and the expected CEL_ROLE counts.
# Prints the named variables' values, tab-separated, when every such pid
# carries all of them and they agree; nothing otherwise (no proof, or two
# different answers). The proc root is CEL_PROC_DIR only under this
# checkout's own suite (cel_under_suite).
_run_pane_launch_env() { # <pane> <role> <VAR...> -> values<TAB>..., or nothing
  local pane="$1" role="$2" info pid item k v line found="" proc=/proc; shift 2
  local -A env
  have herdr || return 0
  info="$(herdr pane process-info --pane "$pane" 2>/dev/null)" || return 0
  if [ -n "${CEL_PROC_DIR:-}" ] && cel_under_suite; then proc="$CEL_PROC_DIR"; fi
  for pid in $(printf '%s' "$info" | jq -r --arg p "$pane" \
      '.result.process_info | select(.pane_id == $p) | .foreground_processes[]?.pid | select(type == "number")' 2>/dev/null); do
    env=()
    while IFS= read -r -d '' item; do
      case "$item" in *=*) env["${item%%=*}"]="${item#*=}" ;; esac
    done < <({ cat "$proc/$pid/environ"; } 2>/dev/null)
    [ "${env[HERDR_PANE_ID]:-}" = "$pane" ] && [ "${env[CEL_ROLE]:-}" = "$role" ] || continue
    line=""
    for k in "$@"; do
      v="${env[$k]:-}"
      [ -n "$v" ] || continue 2
      line="$line${line:+$'\t'}$v"
    done
    [ -z "$found" ] || [ "$found" = "$line" ] || return 0
    found="$line"
  done
  printf '%s' "$found"
}

# WHICH WORKSPACE A LIVE REVIEWER WAS LAUNCHED FOR, proven from the process,
# never guessed from a name or a box-wide checkout path. A Rex reviewer's
# receipt records it (validated by rex_agent_list); a Herdr reviewer's runtime
# carries CEL_WORKSPACE with CEL_ROLE=reviewer (_run_pane_launch_env). No
# proof, or two different answers, prints nothing.
reviewer_pane_workspace() { # <agents-json> <pane> -> workspace directory, or nothing
  local pane="$2" row
  row="$(printf '%s' "$1" | jq -c --arg p "$pane" \
    '[.result.agents[]? | select(.pane_id == $p)] | if length == 1 then .[0] else empty end' 2>/dev/null)" || return 0
  [ -n "$row" ] || return 0
  if [[ "$pane" == rex/* ]] || printf '%s' "$row" | jq -e '.backend == "rex"' >/dev/null 2>&1; then
    printf '%s' "$row" | jq -r 'select(.backend == "rex" and .role == "reviewer"
      and (.workspace | type == "string" and length > 0)) | .workspace' 2>/dev/null
    return 0
  fi
  _run_pane_launch_env "$pane" reviewer CEL_WORKSPACE
}

# A LIVE REVIEWER FOUND BY NAME OR CHECKOUT IS REUSED ONLY WHEN IT IS THIS
# WORKSPACE'S. Its alias and checkout path are box-wide, so another
# workspace's review of the same repo and PR answers to both. Proven to be
# another workspace's: refused. Unproven, while another registered workspace
# also has the repo: refused too - which of them it serves is unknown.
_run_reviewer_owned() { # <agents-json> <pane> <wsdir> <repo> <pr>; dies unless reusable
  local owner
  owner="$(reviewer_pane_workspace "$1" "$2")"
  if [ -n "$owner" ]; then
    [ "$owner" -ef "$3" ] || [ "$owner" = "$3" ] \
      || die "cel run reviewer: the live reviewer for $4#$5 in pane $2 belongs to workspace $owner, not this one; no checkout changed"
    return 0
  fi
  [ "$(_reviewers_here "$3" "$4")" = true ] \
    || die "cel run reviewer: the live reviewer for $4#$5 in pane $2 cannot be proven to be this workspace's, and another workspace has $4; no checkout changed"
}

reviewers_write() { # <json-array> - the whole file, under the lock
  reviewers_update --argjson rows "$1" '$rows'
}

_reviewers_write_raw() { # <json-array> - the write itself; callers hold the lock
  local f tmp
  f="$(_reviewers_state)"
  mkdir -p "$(dirname "$f")" || return 1
  tmp="$(mktemp "$f.tmp.XXXXXX")" || return 1
  printf '%s\n' "$1" > "$tmp" && mv -f -- "$tmp" "$f" || { rm -f -- "$tmp"; return 1; }
}

# EVERY READ-MODIFY-WRITE OF THE REGISTRY HAPPENS HERE, UNDER A LOCK. The
# rename is atomic but the read before it is not, and `cel gc` holds rows for
# seconds of `gh` calls: unlocked, last write wins and a row is lost.
#
# A registry somebody else is holding is REFUSED, never clobbered: the
# caller is told, and the worst case is a reviewer that is not indexed,
# which the gc pass discovers and adopts anyway. So is a registry that does
# not parse - except under --recover, the gc pass that has just read the live
# roster: it moves the unreadable file aside, as evidence, and starts the
# index again from what it found.
reviewers_update() { # [--recover] [jq-args...] <filter>
  local f lock fd="" rows next rc=0 recover=0 aside
  [ "${1:-}" != --recover ] || { recover=1; shift; }
  f="$(_reviewers_state)"; lock="$f.lock"
  mkdir -p "$(dirname "$f")" || return 1
  # The braces scope the silencing to the open: `exec {fd}>"$lock" 2>/dev/null`
  # would point this whole process's stderr at /dev/null from here on.
  if have flock && { exec {fd}>"$lock"; } 2>/dev/null; then
    if ! flock -w "${CEL_REVIEWERS_LOCK_WAIT:-10}" "$fd"; then
      exec {fd}>&-
      c_warn "the reviewer registry is held by another writer - not updated"
      return 1
    fi
  else
    fd=""
  fi
  if rows="$(reviewers_rows)"; then
    :
  elif [ "$recover" = 1 ]; then
    aside="$f.corrupt-$(date -u +%Y%m%dT%H%M%SZ)"
    if mv -f -- "$f" "$aside"; then
      c_warn "the reviewer registry $f did not parse - moved aside to $aside and rebuilt from the live roster"
      rows='[]'
    else
      rc=1
    fi
  else
    c_warn "the reviewer registry $f does not parse - not updated (cel gc rebuilds it from the live roster)"
    rc=1
  fi
  if [ "$rc" = 0 ]; then
    if next="$(printf '%s' "$rows" | jq -c "$@")"; then
      _reviewers_write_raw "$next" || rc=1
    else
      rc=1
    fi
  fi
  if [ -n "$fd" ]; then flock -u "$fd"; exec {fd}>&-; fi
  return "$rc"
}

# 0 with the row; 1 when this workspace has no reviewer recorded for the PR
# (and focus and kind); 2 when the registry cannot be read - which is not "none".
reviewers_find() { # <wsdir> <repo> <pr> [focus] [kind] -> the row
  local rows row
  rows="$(reviewers_rows)" || return 2
  row="$(printf '%s' "$rows" | jq -c --arg ws "$1" --argjson here "$(_reviewers_here "$1" "$2")" \
    --arg r "$2" --arg p "$3" --arg f "${4:-}" --arg k "${5:-review}" "$_REVIEWERS_JQ_SCOPE"'
    [.[] | select(rv_key($ws; $here; $r; $p; $f; $k))][0] // empty')" || return 2
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

# Replaces any row for the same workspace+repo+PR+focus+kind rather than
# appending: one pull request has one reviewer per focus, and two rows for it
# are two panes nobody can tell apart. A legacy row for the same key is
# replaced too - that is its migration - while another workspace's row is
# never touched.
#
# The checkout, the clone it was cut from and the head it was cut at are
# carried with the row because the sweep that closes the reviewer is the only
# thing left that can remove the worktree, and it knows nothing else about it.
reviewers_record() { # <wsdir> <repo> <pr> <pane> <agent> [checkout] [repodir] [head] [focus] [kind]
  reviewers_update --arg ws "$1" --argjson here "$(_reviewers_here "$1" "$2")" \
    --arg r "$2" --arg p "$3" --arg pane "$4" --arg a "$5" \
    --arg co "${6:-}" --arg rd "${7:-}" --arg head "${8:-}" --arg f "${9:-}" --arg k "${10:-review}" \
    --argjson t "$(date +%s)" \
    "$_REVIEWERS_JQ_SCOPE"'
    map(select(rv_key($ws; $here; $r; $p; $f; $k) | not))
     + [{workspace:$ws, repo:$r, pr:$p, pane:$pane, agent:$a, started_at:$t,
         checkout:$co, repodir:$rd, head:$head} + (if ($pane | startswith("rex/")) then {backend:"rex"} else {} end)
        + (if $f != "" then {focus:$f} else {} end)
        + (if $k != "review" then {kind:$k} else {} end)]'
}

reviewers_drop() { # <wsdir> <repo> <pr> [focus] [kind]
  reviewers_update --arg ws "$1" --argjson here "$(_reviewers_here "$1" "$2")" \
    --arg r "$2" --arg p "$3" --arg f "${4:-}" --arg k "${5:-review}" "$_REVIEWERS_JQ_SCOPE"'
    map(select(rv_key($ws; $here; $r; $p; $f; $k) | not))'
}

# THE REGISTRY IS AN INDEX, NOT THE DEFINITION OF EXISTENCE. A reviewer with no
# row still has the NAME `cel run reviewer` gave it (_run_agent_name of
# "<repo>/pr-<n>-review", "<repo>/pr-<n>-review-<focus>" for an extra one,
# "<repo>/pr-<n>-qa-<focus>" for a QA agent), so the roster says which panes
# are reviewers and for which pull request.
#
# The repo comes from the pane's cwd when there is one: the agent name has
# been through the herdr name sanitiser (lowercased, truncated to 32) and is
# not reliably the repo's real name, while a reviewer's cwd is its checkout.
# So does an extra agent's focus, which a cut name may have lost the end of.
# The kind column is empty for the plain reviewer.
reviewers_discover() { # <agents-json> -> repo<TAB>pr<TAB>pane<TAB>agent<TAB>status<TAB>backend<TAB>focus<TAB>kind
  local name pane cwd status pr repo backend focus kind rest
  while IFS=$'\t' read -r name pane cwd status backend; do
    [ -n "$name" ] && [ -n "$pane" ] || continue
    pr="${name##*-pr-}"; pr="${pr%%-*}"
    case "$pr" in ''|*[!0-9]*) continue;; esac
    rest="${name#*-pr-"$pr"-}"
    kind="${rest%%-*}" focus=""
    [ "$rest" = "$kind" ] || focus="${rest#*-}"
    [ -n "$focus" ] || [ "$kind" = qa ] || kind=""
    cwd="$(pane_cwd "$cwd")"
    repo="${cwd##*/}"
    # A reviewer's own checkout is <reviews>/<repo>-pr-<n>, an extra one's
    # <reviews>/<repo>-pr-<n>-<kind>-<focus>: the folder name carries the PR
    # (and kind and focus), and the repo is what precedes it.
    case "$repo" in
      *-pr-"$pr"-review-*|*-pr-"$pr"-qa-*)
        rest="${repo##*-pr-"$pr"-}"; kind="${rest%%-*}"
        focus="${rest#*-}"; focus="${focus%%.round.*}"
        repo="${repo%-pr-"$pr"-"$kind"-*}" ;;
      *-pr-"$pr".round.*) repo="${repo%-pr-"$pr".round.*}" ;;
      *-pr-"$pr") repo="${repo%-pr-"$pr"}" ;;
    esac
    [ -n "$repo" ] || repo="${name%-pr-*}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$pr" "$pane" "$name" "$status" "${backend:-herdr}" "$focus" "$kind"
  done < <(printf '%s' "${1:-}" | jq -r '.result.agents[]?
    | select(((.name // "") | test("^.+-pr-[0-9]+-(review(-[a-z0-9_-]*)?|qa(-[a-z0-9_-]*)?)$")) and ((.pane_id // "") != ""))
    | [(.name // ""), .pane_id, (.cwd // ""), (.agent_status // "unknown"), (.backend // "herdr")] | @tsv' 2>/dev/null)
  return 0
}

# herdr agent names must match [a-z][a-z0-9_-]{0,31} - no slash, no uppercase.
# The readable `repo/role` form survives as the herdr workspace label; this is
# only what the agent answers to.
_run_agent_name() { # <alias>
  cel_alias_norm "$1"   # the one rule, lib/common.sh
}

# WHO IS ALREADY STANDING HERE. An orchestrator's identity in this plane is a
# DIRECTORY, not a name: herdr can lose a name on restart, and a live pane read
# as dead invites a second one on top of it. Status 2 when the roster cannot be
# read: callers refuse admission rather than guess the directory is empty.
#
# A NAMELESS AGENT REPORTS ITS NAME AS `-`, never as an empty field: tab is an
# IFS whitespace character, so a leading empty column collapses under `read`
# and the pane id would arrive in the name's place.
_run_live_agent_in_cwd() { # <cwd> -> name<TAB>pane<TAB>status, or nothing
  local cwd="$1" roster
  have jq || return 0
  roster="$(cel_agent_list 2>/dev/null)" || return 2
  [ -n "$roster" ] || return 0
  printf '%s' "$roster" | jq -r --arg c "$cwd" \
    '[.result.agents[]? | select((.cwd // "") == $c)
      | select((.agent_status // "") != "")][0] // empty
     | [((.name // "") | if . == "" then "-" else . end),
        (.pane_id // ""), (.agent_status // "")] | @tsv' 2>/dev/null || true
}

# Renders AGENT_ARGS for a --dry-run preview: whichever element IS the body
# verbatim is replaced with its length, everything else prints as-is.
_run_dry_agent_args() {
  local out=() a
  for a in "${AGENT_ARGS[@]}"; do
    if [ "$a" = "$RUN_BODY" ]; then
      out+=("<body:${#RUN_BODY} chars>")
    else
      out+=("$a")
    fi
  done
  printf '%s' "${out[*]}"
}

# --- core: the box's coordinator ------------------------------------------
# Core is the one agent that is not IN a workspace. It coordinates across all
# of them, so resolving a workspace for it would be arbitrary: whichever
# directory the operator happened to start it from would silently become the
# default for every command that takes a --workspace. It gets a directory of
# its own instead, outside every checkout, where its notes and its role file
# live and where the guard lets it write. `cel run console` (and `cel run
# core`) start the same pane; its alias is `core` and its mailbox is `root`
# in every workspace.
_run_core_dir() { printf '%s' "${CEL_CORE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cel/core}"; }

# No policy block. Every other role's body ends with the workspace's policy
# because the workspace is the thing it is bound to; core is bound to the box,
# and a policy block from an arbitrary workspace would read as authority it
# does not have.
_run_core_body() { cat "$CEL_ROOT/core/roles/core.md"; }

# Core's launch settings come from agents.yaml `defaults.core`.
_run_core_default() { # <runtime|model|thinking|via>
  manifest_default core | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
}

# ONE READER OF ROOT'S MAIL. Core reads `root` in every workspace under the
# recipient's own cursor (<ws>.root.cursor) - the cursor a standing <ws>-root
# pane also reads by - so core and a root pane would take each other's mail.
# Core replaces root (the plan retires `cel run root`); until then each
# refuses to start while the other is live, --force excepted.
_run_live_names() { # -> one live herdr agent name per line
  have jq || return 0
  { cel_agent_list 2>/dev/null || rex_agent_list; } | jq -r '.result.agents[]?.name // empty' 2>/dev/null
  return 0
}
_run_core() { # <profile> <model-opt> <thinking-opt> <dry-run> <restart> <fresh> <force> <pane-opt>
  local profile="$1" model_opt="$2" thinking_opt="$3" dry="$4" restart="$5" fresh="$6" force="$7" pane_opt="$8"
  [ -z "$profile" ] || die "cel core: --profile is meaningless without a workspace (profiles are bound per workspace) - use --model/--thinking"
  have jq || die "cel core: jq is not on PATH"

  local cwd runtime model thinking via
  cwd="$(_run_core_dir)"
  runtime="$(_run_core_default runtime)"
  [ -n "$runtime" ] || die "cel core: agents.yaml declares no defaults.core.runtime"
  model="$(_run_core_default model)"; thinking="$(_run_core_default thinking)"; via="$(_run_core_default via)"
  [ -z "$model_opt" ]    || model="$model_opt"
  [ -z "$thinking_opt" ] || thinking="$thinking_opt"

  # ONE CORE PER BOX. Two would both drain root's mail and answer it twice.
  # The same refusal as an orchestrator's, on a dry run too.
  if [ "$force" -eq 0 ] && [ "$restart" -eq 0 ]; then
    local occupant oname opane
    occupant="$(_run_live_agent_in_cwd "$cwd")" || die 'cel core: agent inventory is unreadable; refusing duplicate admission'
    if [ -n "$occupant" ]; then
      IFS=$'\t' read -r oname opane _ <<< "$occupant"
      [ "$oname" != "-" ] || oname="<unnamed>"
      die "cel core: core is already live (pane ${opane:-?}, name $oname) - there is one per box
  Go to it:        herdr agent focus ${opane:-<pane>}
  Restart it:      cel core --restart
  Or say you mean it: cel core --force"
    fi
  fi
  if [ "$force" -eq 0 ]; then
    local roots; roots="$(_run_live_names | grep -- '-root$' | tr '\n' ' ' || true)"
    [ -z "$roots" ] || die "cel core: root agents are live (${roots% }) - core reads root's mail by the same cursor, so the two would take each other's messages. Core replaces them: close them first, or pass --force"
  fi

  # THROUGH THE GATEWAY when defaults.core says so: the same omp route an
  # orchestrator's `via: gateway` profile takes, fail-closed on a veto.
  local PROFILE_MODEL="$model" PROFILE_VIA="" PROFILE_VETO="" PROFILE_NOTE=""
  local PROFILE_GATEWAY_ACCOUNTS=0 PROFILE_ISOLATE="" PROFILE_THINKING="" PROFILE_WSDIR=""
  if [ "$via" = gateway ]; then
    [ "$runtime" = omp ] || die "cel core: defaults.core says via: gateway, which core supports on omp only (runtime is $runtime)"
    PROFILE_VIA=gateway
    _profile_gateway_route_omp core
    [ -z "$PROFILE_VETO" ] || die "cel core: $PROFILE_VETO"
    model="$PROFILE_MODEL"
  fi

  [ "$dry" -eq 1 ] || mkdir -p "$cwd"

  local RUN_BODY; RUN_BODY="$(_run_core_body)"
  local AGENT_ARGS=() AGENT_ROLE_FILE=""
  # The role file keeps the `role-*.md` shape on purpose: lib/gc.sh tells a
  # long-lived agent from a stray one by that substring in the cmdline, and
  # core is the longest-lived pane on the box.
  _run_agent_args "$runtime" core "$RUN_BODY" "$dry" "$cwd" "$cwd/role-core.md"

  local -a PROFILE_ARGS=()
  profile_launch_args "$runtime" "$model" "$thinking"
  [ "${#PROFILE_ARGS[@]}" -eq 0 ] || AGENT_ARGS=("${PROFILE_ARGS[@]}" "${AGENT_ARGS[@]}")

  # The same guard hook as the orchestrators; lib/guard.sh holds core's rules.
  local gflag gfile
  gflag="$(agent_guard_hook "$runtime" flag)"; gfile="$(agent_guard_hook "$runtime" file)"
  if [ -n "$gflag" ] && [ -n "$gfile" ]; then
    AGENT_ARGS=("$gflag" "$CEL_ROOT/$gfile" "${AGENT_ARGS[@]}")
  fi
  _run_inbox_hook_args "$runtime"
  _run_keep_model_args "$runtime"
  _run_retry_overlay_args "$runtime" core

  local -a launch_args=()
  mapfile -t launch_args < <(agent_launch_args "$runtime")
  [ "${#launch_args[@]}" -eq 0 ] || AGENT_ARGS=("${launch_args[@]}" "${AGENT_ARGS[@]}")

  # Core resumes its conversation across a restart, as root and the
  # orchestrators do.
  local RESUME_SESSION="" RESTART_PANE=""
  _run_resume_resolve core core "$cwd" "$runtime" "$pane_opt" "$restart" "$fresh" "$force" "$dry" \
    "cel core" "or restart it in place: cel core --restart"

  # Mail: `root` in every workspace (the inbox hook sweeps them all when the
  # identity is explicit).
  local -a GATEWAY_ENV=()
  _run_profile_gateway_setup "$runtime" core "$((1 - dry))" "$((1 - dry))"
  local envprefix dry_envprefix prefix_required=0
  # The line a restart types or scripts is built for its pane's host.
  _run_restart_backend "$RESTART_PANE" || true
  envprefix="$(_run_launch_env core "$cwd" "$AGENT_ROLE_FILE" root "$runtime")"
  dry_envprefix="$envprefix"
  if [ "${#GATEWAY_ENV[@]}" -gt 0 ]; then
    prefix_required=1
    dry_envprefix="$(GATEWAY_ENV=("OMP_GATEWAY_TOKEN=****" "CEL_SESSION_ID=****"); _run_launch_env core "$cwd" "$AGENT_ROLE_FILE" root "$runtime")"
  fi

  local _REX_RELAUNCH; _REX_RELAUNCH="$(_run_rex_relaunch)"
  local label=celestial/core
  if [ -n "$RESTART_PANE" ]; then
    _run_restart_in_place core "$RESTART_PANE" "$label" "$envprefix" "$dry_envprefix" "$prefix_required" "$dry" core "$runtime" "$cwd"
    return $?
  fi
  if [ "${session_backend:-herdr}" = rex ]; then
    if [ "$dry" = 1 ]; then
      printf 'rex new core --cwd %s --shell=none -- <private launch script: %s%s>\n' "$cwd" "$(_rex_launch_line "$runtime" "$dry_envprefix" "$runtime" run)" "$(_run_dry_agent_args)"
    else
      _rex_launch core "$runtime" "$cwd" "$label" "$envprefix" "${AGENT_ARGS[@]}" || return $?
    fi
    return 0
  fi

  local -a CREATE_ARGS=(workspace create --cwd "$cwd" --label "$label")
  if [ "$dry" -eq 1 ]; then
    printf 'herdr %s\n' "${CREATE_ARGS[*]}"
    printf 'herdr pane send-text <pane> %s\n' "$dry_envprefix"
    printf 'herdr agent start core --kind %s --pane <pane> -- %s\n' \
      "$runtime" "$(_run_dry_agent_args)"
    return 0
  fi

  have herdr || die "cel run: herdr is not on PATH"
  local resp ws_id pane_id
  resp="$(herdr "${CREATE_ARGS[@]}")"
  ws_id="$(printf '%s' "$resp" | jq -r '.. | .workspace_id? // empty' | head -1)"
  pane_id="$(printf '%s' "$resp" | jq -r '.. | .pane_id? // empty' | head -1)"
  [ -n "$pane_id" ] && [ "$pane_id" != "null" ] || pane_id="${ws_id}:p1"
  _run_mark_launch "$pane_id" "$envprefix" "$prefix_required"
  _run_agent_start "$pane_id" core "$runtime" "${AGENT_ARGS[@]}"
}

# THE LINE THAT BRINGS AN AGENT BACK, recorded in its Rex receipt: after a Rex
# server restart or a managed rex upgrade (lib/rex.sh) the agent is resumed by
# running exactly this, so it comes back through the same door - same role,
# product, lane and workspace, its saved session (a launch over a dead agent
# resumes the last recorded one) and the profile/model/thinking the owner
# named. Never --restart: if anything is live there by then, the duplicate
# refusal stops the relaunch rather than killing a turn. A lane remembers its
# own profile and model beside its role file, so they are left to that memory.
# Reads the caller's (cmd_run / _run_core) resolved locals; prints a JSON array.
_run_rex_relaunch() {
  local -a line=(run)
  case "$role" in
    core) line+=(core) ;;
    root) line+=(root) ;;
    *) if [ "${solo_forced:-0}" = 1 ]; then line+=(solo); else line+=(orchestrator); fi
       line+=(--product "$product")
       [ -z "${lane:-}" ] || line+=(--lane "$lane") ;;
  esac
  [ "$role" = core ] || line+=(--workspace "${workspace:-$(ws_name "$wsdir")}")
  line+=(--session-backend rex)
  if [ -z "${lane:-}" ]; then
    [ -z "${profile_opt:-}" ] || line+=(--profile "$profile_opt")
    [ -z "${model_opt:-}" ] || line+=(--model "$model_opt")
  fi
  [ -z "${thinking_opt:-}" ] || line+=(--thinking "$thinking_opt")
  # Not `jq --args`: jq still parses a `--model` after it as its own option.
  printf '%s\0' "${line[@]}" | jq -Rsc 'split("\u0000") | .[:-1]'
}

# --- resuming root and the orchestrators -----------------------------------
# A restart keeps the conversation: a resume always names the exact session
# recorded for the pane, never omp's --continue, which takes the newest
# session in the cwd - not necessarily this agent's.

# The last session seen for each root/orchestrator DIRECTORY - identity here
# is a directory, not a name (see _run_live_agent_in_cwd) - so an
# orchestrator that died can be brought back into its own conversation.
# Each entry is {session, runtime}: only the runtime that wrote a session can
# resume it. Older entries are a bare session string.
_run_sessions_file() {
  if [ -n "${CEL_ORCH_SESSIONS:-}" ]; then printf '%s' "$CEL_ORCH_SESSIONS"
  elif [ -n "${CEL_TESTING:-}" ]; then printf '%s' "${TMPDIR:-/tmp}/cel-orch-sessions.json"
  else printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/cel/orch-sessions.json"; fi
}

_run_sessions_record() ( # <cwd> <session> [runtime]; lock the whole shared map update
  local f tmp cur fd
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  ! native_session_is_subagent "$2" || return 0
  f="$(_run_sessions_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  exec {fd}>"$f.lock" || return 0
  flock -w 10 "$fd" || return 0
  cur="$(jq -c 'if type == "object" then . else {} end' "$f" 2>/dev/null)" || cur='{}'
  [ -n "$cur" ] || cur='{}'
  tmp="$(mktemp "$f.tmp.XXXXXX" 2>/dev/null)" || return 0
  if printf '%s' "$cur" | jq -c --arg c "$1" --arg s "$2" --arg r "${3:-}" '.[$c] = {session: $s, runtime: $r}' > "$tmp"; then
    mv -f -- "$tmp" "$f"
  else
    rm -f -- "$tmp"
  fi
  return 0
)

_run_sessions_last() { # <cwd> -> session, or nothing
  jq -r --arg c "$1" '.[$c] // empty | if type == "object" then (.session // empty) else . end' "$(_run_sessions_file)" 2>/dev/null || true
}

_run_sessions_last_runtime() { # <cwd> -> runtime that recorded it, or nothing
  jq -r --arg c "$1" '.[$c] // empty | if type == "object" then (.runtime // empty) else empty end' "$(_run_sessions_file)" 2>/dev/null || true
}

# Remember the session of every live root/orchestrator in a roster. Cheap, so
# the steward calls it every tick: the record is what makes "resume the last
# session" possible after the agent is gone.
run_sessions_note_roster() { # <agents-json>
  local cwd sess rt
  while IFS=$'\t' read -r cwd sess rt; do
    [ -n "$cwd" ] && [ -n "$sess" ] && _run_sessions_record "$cwd" "$sess" "$rt"
  done < <(printf '%s' "${1:-}" | jq -r '.result.agents[]?
    | select((.name // "") | test("(-orch|-root)$|^core$"))
    | select((.agent_session.value // "") != "")
    | [(.cwd // ""), .agent_session.value, (.agent // "")] | @tsv' 2>/dev/null)
  return 0
}

# The live agent for a root/orchestrator, BY HERDR NAME. Choosing by cwd alone
# can pick another session in another pane, so cwd+runtime is a fallback ONLY
# when exactly one agent there matches; several is an ambiguity the operator
# settles with --pane. A missing name or session is `-` so tab-splitting keeps columns.
#
# Status: 0 found (one row), 1 none, 3 ambiguous (every candidate row),
# 4 the named --pane holds an agent under ANOTHER name (that row) - which is
# never relaunched: that pane is not this orchestrator.
_run_orch_agent() { # <name> <cwd> <runtime> [pane] -> name<TAB>pane<TAB>status<TAB>session<TAB>runtime
  local roster rows n
  roster="$(cel_agent_list 2>/dev/null)" || return 2
  rows="$(printf '%s' "$roster" | jq -r --arg n "$1" --arg c "$2" --arg r "$3" --arg p "${4:-}" '
    def row: [((.name // "") | if . == "" then "-" else . end), .pane_id,
              (.agent_status // "unknown"),
              ((.agent_session.value // "") | if . == "" then "-" else . end),
              ((.agent // "") | if . == "" then "-" else . end)] | @tsv;
    [.result.agents[]? | select((.pane_id // "") != "")] as $a
    | if $p != "" then ($a[] | select(.pane_id == $p) | row)
      elif ([$a[] | select(.name == $n)] | length) > 0 then ([$a[] | select(.name == $n)][0] | row)
      else ($a[] | select((.cwd // "") == $c and (.agent // "") == $r) | row) end' 2>/dev/null)" || rows=""
  [ -n "$rows" ] || return 1
  printf '%s\n' "$rows"
  if [ -n "${4:-}" ]; then
    n="$(printf '%s' "$rows" | cut -f1)"
    [ "$n" = "-" ] || [ "$n" = "$1" ] || return 4
    return 0
  fi
  [ "$(printf '%s\n' "$rows" | wc -l)" -eq 1 ] || return 3
  return 0
}

_run_resume_identity_check() { # runtime candidate cwd scoped-agent [wsdir]
  [ "$1" = opencode ] && [ -n "$2" ] || return 0
  rex_native_session_valid "$1" "$2" \
    || die 'cel run: saved context is not an OpenCode native session; preserve it and use --fresh --handoff for the migration'
  # v2 --session creates an absent ID. Prove this exact existing root in the
  # same store before recording it, claiming it, or stopping a live holder.
  opencode_validate_session "$2" "$3" "$4" "${5:-}" \
    || die 'cel run: saved OpenCode context is not a ready matching native v2 root; preserve it and use --fresh --handoff only for an intended migration'
}

# A RUNTIME SWITCH NEVER RESUMES: one runtime cannot resume another's session,
# so the launch starts fresh, says so, and leaves the old session where it is.
# OpenCode is not switched here: its migration is explicit (--fresh --handoff;
# _run_resume_identity_check). The recorded runtime decides; a record without
# one (older map entries, a roster row naming no agent) is judged by the shape
# this runtime resumes.
_run_resume_foreign() { # <runtime> <session> <recorded-runtime|""> <agent-name> -> 0: start fresh
  local rt="$1" s="$2" was="$3"
  [ "$rt" != opencode ] || return 1
  if [ -z "$was" ]; then
    [ -n "$s" ] || return 1
    case "$(agent_resume "$rt" value)" in
      path) [[ "$s" != /* ]] || return 1 ;;
      id) [[ "$s" = */* ]] || { [ "$rt" = claude ] && ! rex_native_session_valid claude "$s"; } || return 1 ;;
      *) return 1 ;;
    esac
    was="another runtime"
  fi
  [ "$was" != "$rt" ] || return 1
  printf '  %s last ran on %s - %s cannot resume that session; starting fresh%s\n' \
    "$4" "$was" "$rt" "${s:+ (it stays at $s)}" >&2
}

# A subagent transcript recorded before capture refused them stands for the
# session that ran it - the file beside its directory.
_run_resume_parent_session() { # <session> -> the session to resume
  if native_session_is_subagent "$1"; then
    printf '  %s is a subagent transcript - using its parent session\n' "$1" >&2
    printf '%s' "${1%/*}.jsonl"
  else
    printf '%s' "$1"
  fi
}

# RESUME. Root, core and the product agents carry their conversation across a
# restart; reviewers never do - each is one PR.
# Sets RESUME_SESSION and RESTART_PANE in the caller and appends the resume
# flag to its AGENT_ARGS.
_run_resume_resolve() { # <role> <agent-name> <cwd> <runtime> <pane-opt> <restart> <fresh> <force> <dry-run> <relaunch-cmd> <adopt-hint> [wsdir]
  local role="$1" agent_name="$2" cwd="$3" runtime="$4" pane_opt="$5"
  local restart="$6" fresh="$7" force="$8" dry_run="$9" relaunch="${10}" adopt="${11}" resume_wsdir="${12:-}"
  RESUME_SESSION=""; RESTART_PANE=""
  local live="" lname lpane lstatus lsession lruntime lrc=1
  if have jq; then
    live="$(_run_orch_agent "$agent_name" "$cwd" "$runtime" "$pane_opt")" && lrc=0 || lrc=$?
  fi
  case "$lrc" in
    0) ;;
    2) die "cel run $role: agent inventory is unreadable; refusing to infer that the session is absent" ;;
    3)
      if [ "$restart" -eq 1 ]; then
        c_err "cel run $role --restart: no agent is named $agent_name and $(printf '%s\n' "$live" | wc -l | tr -d ' ') $runtime agents share $cwd - refusing to guess which is the $role:" >&2
        printf '%s\n' "$live" | awk -F '\t' '{ printf "    pane %s  name %s  status %s  session %s\n", $2, $1, $3, $4 }' >&2
        die "  pass the right one: $relaunch --restart --pane <pane>"
      fi
      live="" ;;
    4)
      die "cel run $role --restart: pane $pane_opt runs $(printf '%s' "$live" | cut -f1), not $agent_name - it will not be renamed or relaunched" ;;
    *)
      [ -z "$pane_opt" ] || die "cel run $role --restart: no agent is live in pane $pane_opt"
      live="" ;;
  esac
  if [ -n "$live" ]; then
    IFS=$'\t' read -r lname lpane lstatus lsession lruntime <<< "$live"
    [ "$lsession" != "-" ] || lsession=""
    [ "$lruntime" != "-" ] || lruntime=""
    [ -z "$lsession" ] || lsession="$(_run_resume_parent_session "$lsession")"
    if [ "$fresh" = 0 ] && _run_resume_foreign "$runtime" "$lsession" "$lruntime" "$agent_name"; then fresh=1; fi
    [ "$fresh" = 1 ] || _run_resume_identity_check "$runtime" "$lsession" "$cwd" "cel-$role" "$resume_wsdir"
    [ "$dry_run" = 1 ] || _run_sessions_record "$cwd" "$lsession" "$lruntime"
  fi
  if [ "$restart" -eq 1 ]; then
    if [ -z "$live" ]; then
      printf '  no live agent for %s in %s - launching it\n' "$agent_name" "$cwd" >&2
    else
      # Never kill a turn in progress by default: the owner may be mid-way
      # through something the plane cannot see.
      if [ "$lstatus" = working ] && [ "$force" -eq 0 ]; then
        die "cel run $role --restart: $agent_name (pane $lpane) is working - a restart now would kill its turn. Wait for it to go idle, or pass --force"
      fi
      case "$lpane" in rex/*)
        if [ "$fresh" = 0 ] && [ -z "$lsession" ]; then
          die 'cel run: Rex runtime has not reported its native session identity; refusing to discard its conversation (use --fresh only when intended)'
        fi ;;
      esac
      RESTART_PANE="$lpane"
      [ "$fresh" -eq 1 ] || RESUME_SESSION="$lsession"
    fi
  fi
  # Over a dead or absent agent, come back into the last recorded session.
  if [ "$fresh" -eq 0 ] && [ -z "$RESUME_SESSION" ] && [ -z "$live" ]; then
    RESUME_SESSION="$(_run_sessions_last "$cwd")"
    [ -z "$RESUME_SESSION" ] || RESUME_SESSION="$(_run_resume_parent_session "$RESUME_SESSION")"
    if _run_resume_foreign "$runtime" "$RESUME_SESSION" "$(_run_sessions_last_runtime "$cwd")" "$agent_name"; then
      RESUME_SESSION=""; fresh=1
    fi
  fi
  # Both live receipts and dead-registry lookup pass the same native boundary.
  _run_resume_identity_check "$runtime" "$RESUME_SESSION" "$cwd" "cel-$role" "$resume_wsdir"
  # NEVER A SECOND PROCESS ON ONE SESSION FILE, whether or not herdr still has
  # a name for the pane resuming it. The pane being restarted is the expected
  # resumer; a runtime that cannot resume starts fresh and is no second resumer.
  if [ "$role" != root ] && [ -n "$RESUME_SESSION" ] && [ "$force" -eq 0 ] \
     && [ -n "$(agent_resume "$runtime" flag)" ]; then
    local rs rpid rpane others="" holders
    holders="$(run_session_resumers)" || die 'cel run: native session ownership is unreadable; refusing a duplicate writer'
    while IFS=$'\t' read -r rs rpid rpane; do
      [ "$rs" = "$RESUME_SESSION" ] || continue
      [ -n "$RESTART_PANE" ] && [ "$rpane" = "$RESTART_PANE" ] && continue
      others+="    pane $rpane  pid $rpid"$'\n'
    done <<< "$holders"
    if [ -n "$others" ]; then
      c_err "cel run $role: another live process is already resuming $RESUME_SESSION:" >&2
      printf '%s' "$others" >&2
      die "  two processes on one session answer mail twice. Close that pane ($adopt), or pass --force"
    fi
    # and claim it, so a launch racing this one before either agent is in
    # /proc is refused too. A preview claims nothing.
    if [ "$dry_run" -eq 0 ]; then
      local crc=0
      _run_session_claim "$RESUME_SESSION" "$RESTART_PANE" || crc=$?
      case "$crc" in
        0) ;;
        1) die "cel run $role: another launch claimed $RESUME_SESSION in the last ${CEL_SESSION_CLAIM_SECS:-60}s - two processes on one session answer mail twice. Wait and check the panes, or pass --force" ;;
        *) die "cel run $role: the session claim store is unavailable (its lock is held or unwritable) - refusing a possible second writer on $RESUME_SESSION. Retry, or pass --force" ;;
      esac
      _RUN_CLAIMED_SESSION="$RESUME_SESSION" _RUN_CLAIMED_SESSION_TOKEN="$_RUN_SESSION_CLAIM_TOKEN"
      trap '_run_session_release_on_failure $?' EXIT
    fi
  fi
  if [ -n "$RESUME_SESSION" ]; then
    local rflag; rflag="$(agent_resume "$runtime" flag)"
    if [ -n "$rflag" ]; then
      AGENT_ARGS+=("$rflag" "$RESUME_SESSION")
      printf '  resuming %s from %s\n' "$agent_name" "$RESUME_SESSION" >&2
    else
      printf '  runtime %s cannot resume a session - %s is starting fresh\n' "$runtime" "$agent_name" >&2
      RESUME_SESSION=""
    fi
  elif [ "$fresh" -eq 0 ]; then
    printf '  no previous session recorded for %s - starting fresh\n' "$agent_name" >&2
  fi
  return 0
}

# A RESTART KEEPS ITS PANE'S HOST. The backend a launch names (flag, else
# CEL_SESSION_BACKEND, else the workspace's session_backend, else herdr)
# applies to new sessions only, so a restart's line is built for the host of
# the pane it replaces. The two hosts' lines differ: a Herdr pane is typed the
# OpenCode launcher in its env prefix (_run_launch_env), a Rex script adds its
# own (_rex_launch_line). A Rex agent restarted from a workspace defaulting to
# Herdr once got both - `node launch.mjs -- node launch.mjs -- opencode ...`,
# refused by the outer launcher (unsupported_argument) after the agent was
# already stopped. Sets the caller's session_backend; 0 when it changed.
_run_restart_backend() { # <restart-pane>
  local host
  case "$1" in '') return 1 ;; rex/*) host=rex ;; *) host=herdr ;; esac
  [ "${session_backend:-herdr}" != "$host" ] || return 1
  session_backend="$host"
}

# THE LINE THAT BRINGS A STOPPED AGENT BACK: its recorded relaunch line
# (_run_rex_relaunch, the caller's _REX_RELAUNCH). Without one, never a bare
# `cel`: the hand restart, named as far as this launch knows it. An
# orchestrator's line always names its product - one this launch could not
# determine is said so, with a placeholder, never silently left out.
_run_restart_back() { # <role> <agent-name> -> one sentence
  local line r="$1" unknown="" naming=""
  if line="$(jq -er 'select(type == "array" and length > 0 and all(.[]; type == "string")) | join(" ")' <<<"${_REX_RELAUNCH:-}" 2>/dev/null)"; then
    printf 'Bring it back with: cel %s' "$line"; return 0
  fi
  if [ "$r" = core ]; then line='cel core'
  else
    if [ "$r" = orchestrator ]; then
      [ -n "${product:-}" ] || { unknown=', and its product could not be determined'; naming='naming its product and '; }
      line=" --product ${product:-<product>}"
    else line="${product:+ --product $product}"
    fi
    [ "${solo_forced:-0}" != 1 ] || r=solo
    line="cel run $r$line${lane:+ --lane $lane}${wsdir:+ --workspace $(ws_name "$wsdir")}"
  fi
  printf 'No relaunch line was recorded for %s%s: restart it by hand with %s --session-backend rex, %sadding the profile/model it ran on' "$2" "$unknown" "$line" "$naming"
}

# RESTART IN PLACE: exit the agent in its pane, leaving the pane and its
# shell, and start the current launch line there under the same name.
# A Rex agent is stopped only once its relaunch line has passed its own
# launcher's admission (rex_launch_check): a line that would be refused leaves
# the agent running. A relaunch that still fails - its terminal never started
# the runtime (_rex_launch), or the runtime died before admission
# (rex_launch_settle) - takes its terminal with it, and the restart says so
# and how to bring the agent back.
_run_restart_in_place() { # <role> <pane> <label> <envprefix> <dry-envprefix> <prefix-required> <dry-run> <agent-name> <runtime> <cwd>
  local role="$1" pane="$2" label="$3" envprefix="$4" dry_envprefix="$5" prefix_required="$6"
  local dry_run="$7" agent_name="$8" runtime="$9" cwd="${10}"
  case "$pane" in rex/*)
    if [ "$dry_run" = 1 ]; then
      printf 'rex block close <owned terminal>; rex new %s --cwd %s --shell=none -- <private launch script: %s%s>\n' \
        "$agent_name" "$cwd" "$(_rex_launch_line "$runtime" "$dry_envprefix" "$runtime" run)" "$(_run_dry_agent_args)"
      return 0
    fi
    local back src=0
    back="$(_run_restart_back "$role" "$agent_name")"
    rex_launch_check "$agent_name" "$runtime" "$cwd" "$envprefix" "${AGENT_ARGS[@]}" \
      || die "cel run $role --restart: the relaunch line of $agent_name was refused by its launcher - $agent_name was NOT stopped and still runs in $pane"
    rex_agent_stop "$pane" || die "cel run: could not stop Rex terminal $pane"
    _rex_launch "$agent_name" "$runtime" "$cwd" "$label" "$envprefix" "${AGENT_ARGS[@]}" || src=$?
    [ "$src" != 0 ] || { rex_launch_settle "$agent_name" "$runtime" || src=$?; }
    case "$src" in
      0) return 0 ;;
      1) c_err "cel run $role --restart: $agent_name was stopped and its relaunch failed during startup; its Rex terminal was closed and nothing of $agent_name is running. $back" ;;
      *) c_err "cel run $role --restart: $agent_name was stopped and its relaunch failed during startup, and its Rex terminal could not be closed - close it (rex ls) first. $back" ;;
    esac
    return 1 ;;
  esac
  if [ "$dry_run" -eq 1 ]; then
    printf 'herdr pane send-keys %s esc ctrl+c ctrl+c\n' "$pane"
    printf 'herdr pane send-text %s %s\n' "$pane" "$dry_envprefix"
    printf 'herdr agent start %s --kind %s --pane %s -- %s\n' \
      "$agent_name" "$runtime" "$pane" "$(_run_dry_agent_args)"
    return 0
  fi
  herdr pane send-keys "$pane" esc ctrl+c ctrl+c >/dev/null 2>&1 \
    || die "cel run $role --restart: could not send the exit keys to pane $pane"
  _run_restart_wait "$pane" \
    || die "cel run $role --restart: $agent_name is still running in $pane - exit it by hand and re-run"
  pane_label_set "$pane" "$label"
  tab_label_set "$pane" "$label"
  _run_mark_launch "$pane" "$envprefix" "$prefix_required"
  _RUN_AGENT_QUIET=1 _run_agent_start "$pane" "$agent_name" "$runtime" "${AGENT_ARGS[@]}"
  _run_restart_confirm "$pane" "$cwd" "$runtime" "$agent_name" "${AGENT_ARGS[@]}"
}

_run_proc_root() { printf '%s' "${CEL_PROC_ROOT:-/proc}"; }

_run_cmdline() { # <pid> -> argv, one per line
  tr '\0' '\n' < "$(_run_proc_root)/$1/cmdline" 2>/dev/null || true
}

# The runtimes that resume a session, by the basename of argv[0] or (for a
# script run by node/bun) argv[1].
_run_is_agent_argv() { # <cmdline-file>
  local -a v=() ; local a n
  mapfile -d '' -t v < "$1" 2>/dev/null || return 1
  for a in "${v[0]:-}" "${v[1]:-}"; do
    n="${a##*/}"; n="${n%% *}"
    case "$n" in omp|pi|claude|codex|opencode|omp.*|pi.*|cli.js|cli.mjs) return 0 ;; esac
  done
  return 1
}

# WHO IS RESUMING WHICH SESSION FILE. herdr's roster cannot see a nameless
# pane's session, but /proc can: every live agent whose argv says `--resume
# <file>` (or `--resume=`, `--session`), with the pane it stands in
# (HERDR_PANE_ID from its environ; `-` when it has none).
run_session_resumers() { # -> native session<TAB>pid<TAB>pane, one per live holder
  local d pid prev a sess pane item f anc hops held
  local -A managed=() managed_pane=() cand=() cand_pane=()
  # Native hooks know the current conversation even when a runtime rewrites
  # argv, or Claude clears to a new UUID after its original --resume.
  for f in "$(_rex_state)"/*.json; do
    [ -f "$f" ] || continue
    _rex_receipt_valid "$f" || return 1
    _rex_live "$f" || continue
    sess="$(jq -r '.agent_session.value // empty' "$f")"
    [ -n "$sess" ] || continue
    pid="$(jq -r .pid "$f")"; pane="$(jq -r .pane_id "$f")"
    managed[$pid]="$sess" managed_pane[$pid]="$pane"
    printf '%s\t%s\t%s\n' "$sess" "$pid" "$pane"
  done
  for d in "$(_run_proc_root)"/[0-9]*; do
    pid="${d##*/}"
    [ -z "${managed[$pid]:-}" ] || continue
    [ -r "$d/cmdline" ] || continue
    sess="" prev=""
    while IFS= read -r -d '' a; do
      case "$a" in
        --resume=*) sess="${a#--resume=}" ;;
        --session=*) sess="${a#--session=}" ;;
        *) { [ "$prev" = --resume ] || [ "$prev" = --session ]; } && sess="$a" ;;
      esac
      [ -n "$sess" ] && break
      prev="$a"
    done < "$d/cmdline" 2>/dev/null
    [ -n "$sess" ] || continue
    # an AGENT resuming it, owned by this user - not a grep or an editor that
    # merely has the path in its argv
    [ -O "$d/cmdline" ] || continue
    _run_is_agent_argv "$d/cmdline" || continue
    pane="-"
    local rex_session="" rex_block=""
    while IFS= read -r -d '' item; do
      case "$item" in
        HERDR_PANE_ID=*) pane="${item#*=}" ;;
        REX_SESSION=*) rex_session="${item#*=}" ;;
        REX_BLOCK=*) rex_block="${item#*=}" ;;
      esac
    done < "$d/environ" 2>/dev/null
    [ -z "$rex_session" ] || [ -z "$rex_block" ] || pane="rex/$rex_session/$rex_block"
    cand[$pid]="$sess" cand_pane[$pid]="$pane"
  done
  # ONE HOLDER, ONE ROW. OpenCode's launcher starts its TUI with the same
  # --session in the same pane, so the child's argv names the session too. A
  # descendant on the same session AND pane is that writer, not a second one;
  # a descendant in another pane (say, a shell tool running `cel run`) is not.
  for pid in "${!cand[@]}"; do
    sess="${cand[$pid]}" pane="${cand_pane[$pid]}" anc="$pid" hops=0 held=""
    while _run_ppid "$anc"; anc="$_RUN_PPID"; [ -n "$anc" ] && [ "$anc" -gt 1 ] 2>/dev/null && [ "$hops" -lt 64 ]; do
      if { [ "${managed[$anc]:-}" = "$sess" ] && [ "${managed_pane[$anc]}" = "$pane" ]; } \
        || { [ "${cand[$anc]:-}" = "$sess" ] && [ "${cand_pane[$anc]}" = "$pane" ]; }; then held=1; break; fi
      hops=$((hops+1))
    done
    [ -n "$held" ] || printf '%s\t%s\t%s\n' "$sess" "$pid" "${cand_pane[$pid]}"
  done
  return 0
}

# CLAIMING A SESSION. Two launches that overlap both see an empty /proc -
# neither agent has started yet. The check and a short-lived claim are taken
# under one flock, so the second launch inside the window
# (CEL_SESSION_CLAIM_SECS, default 60) sees the first one's claim. A lock that
# cannot be had is a claim store that cannot be read: it refuses (rc 2), never
# claims unlocked.
#
# The claim names the pane it was taken for: `--restart` of that same pane is
# the pane replacing itself, not a second resumer. It also carries a token
# unique to the launch that took it (left in _RUN_SESSION_CLAIM_TOKEN), so a
# release removes that launch's own claim and never a newer one.
_run_session_claim_file() { # <session> -> path of its claim file
  local dir key
  dir="$(dirname "$(_run_sessions_file)")/session-claims"
  key="$(printf '%s' "$1" | sha1sum | cut -c1-16)"
  printf '%s/%s' "$dir" "$key"
}

# Opens and takes the claim directory's lock on fd $_RUN_CLAIM_FD, in THIS
# shell (a command substitution would drop the lock as it returned); 1 when
# the lock cannot be opened or had within CEL_SESSION_CLAIM_LOCK_WAIT seconds.
# A box without flock(1) claims unlocked, as before the lock existed: the
# missing binary is not a held lock.
_RUN_CLAIM_FD=""
_run_session_claim_lock() { # <claim file>
  _RUN_CLAIM_FD=""
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 1
  have flock || return 0
  { exec {_RUN_CLAIM_FD}>"$(dirname "$1")/.lock"; } 2>/dev/null || { _RUN_CLAIM_FD=""; return 1; }
  flock -w "${CEL_SESSION_CLAIM_LOCK_WAIT:-10}" "$_RUN_CLAIM_FD" && return 0
  exec {_RUN_CLAIM_FD}>&-; _RUN_CLAIM_FD=""
  return 1
}
_run_session_claim_unlock() {
  [ -z "$_RUN_CLAIM_FD" ] || { flock -u "$_RUN_CLAIM_FD"; exec {_RUN_CLAIM_FD}>&-; }
  _RUN_CLAIM_FD=""
}

_RUN_SESSION_CLAIM_TOKEN=""
_run_session_claim() { # <session> [pane] -> 0 claimed, 1 claimed by another launch, 2 store unavailable
  local f now held hpane token rc=0 pane="${2:-}"
  f="$(_run_session_claim_file "$1")"
  _run_session_claim_lock "$f" || return 2
  now="$(date +%s)"
  { read -r held hpane; } < "$f" 2>/dev/null || true
  case "${held:-}" in ''|*[!0-9]*) held="" ;; esac
  if [ -n "$held" ] && [ $((now - held)) -lt "${CEL_SESSION_CLAIM_SECS:-60}" ] \
     && ! { [ -n "$pane" ] && [ "${hpane:-}" = "$pane" ]; }; then
    rc=1
  else
    token="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || token="$BASHPID.$RANDOM$RANDOM.$now"
    if { printf '%s %s\n%s\n' "$now" "$pane" "$token" > "$f"; } 2>/dev/null; then
      _RUN_SESSION_CLAIM_TOKEN="$token"
    else rc=2; fi
  fi
  _run_session_claim_unlock
  return "$rc"
}

# A LAUNCH THAT FAILS GIVES ITS CLAIM BACK, so the retry is not refused for the
# claim's full minute or pushed to --force, which also skips the check. Only
# its own claim: one a same-pane relaunch refreshed since carries another
# token and stays. A lock that cannot be had removes nothing; the claim expires.
_run_session_release() { # <session> <token>
  local f htoken=""
  f="$(_run_session_claim_file "$1")"
  _run_session_claim_lock "$f" || return 0
  { read -r _; read -r htoken; } < "$f" 2>/dev/null || true
  [ -z "${2:-}" ] || [ "$htoken" != "$2" ] || rm -f "$f" 2>/dev/null || true
  _run_session_claim_unlock
  return 0
}

# Called from the EXIT trap cmd_run sets after claiming: a non-zero exit -
# any die after the claim - releases it; a launch that succeeded keeps it.
_RUN_CLAIMED_SESSION="" _RUN_CLAIMED_SESSION_TOKEN=""
_run_session_release_on_failure() { # <exit status>
  [ "$1" -eq 0 ] || [ -z "$_RUN_CLAIMED_SESSION" ] \
    || _run_session_release "$_RUN_CLAIMED_SESSION" "$_RUN_CLAIMED_SESSION_TOKEN"
  return 0
}

# What a launch line is made of, for comparing two of them: each flag with the
# value that follows it. The role prompt's PATH does not count (a product can
# move its role file without its launch being stale), nor does a resume.
run_launch_items() { # NUL-delimited argv -> losslessly encoded items, one per line
  local -a v; mapfile -d '' -t v
  local i=1 n="${#v[@]}" a b
  while [ "$i" -lt "$n" ]; do
    a="${v[$i]}"; b="${v[$((i+1))]:-}"
    case "$a" in
      # A wrapper hands its runtime the argv after a bare `--` (OpenCode's
      # launcher: node launch.mjs -- opencode --auto ...). The separator and the
      # wrapped executable path are not flags; the wrapped flags still compare.
      --) i=$((i+1)) ;;
      --*)
        if [[ "$a" = *=* ]]; then b=""; i=$((i+1))
        elif [ -n "$b" ] && [ "${b#--}" = "$b" ]; then i=$((i+2)); else b=""; i=$((i+1)); fi
        case "$a" in --resume|--resume=*|--continue|--session|--session=*|--prompt|--prompt=*) continue ;; esac
        case "$b" in *role-*.md|'<body:'*) continue ;; esac
        if [ -n "$b" ]; then printf '%q %q\n' "$a" "$b"; else printf '%q\n' "$a"; fi ;;
      *) i=$((i+1)) ;;
    esac
  done
}

_run_item_label() { # <item> -> how a human names it
  case "$1" in
    *inbox.omp.ts|*inbox*.ts) printf 'inbox hook' ;;
    *orchestrator-guard*) printf 'guard hook' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Expected items the actual argv lacks, as a comma-separated human list.
run_launch_missing() { # <expected-argv-file> <actual-argv-file>
  local item out=""
  local have_items; have_items="$(run_launch_items < "$2")"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    printf '%s\n' "$have_items" | grep -qxF -- "$item" && continue
    out="${out:+$out, }$(_run_item_label "$item")"
  done < <(run_launch_items < "$1")
  printf '%s' "$out"
}

# Both directions of the difference: a flag the current launch has DROPPED is
# as stale as one it added. Empty when the lines agree.
run_launch_diff() { # <expected-argv-file> <actual-argv-file> -> "missing: ...; extra: ..."
  local missing extra out=""
  missing="$(run_launch_missing "$1" "$2")"
  extra="$(run_launch_missing "$2" "$1")"
  [ -z "$missing" ] || out="missing: $missing"
  [ -z "$extra" ] || out="${out:+$out; }extra: $extra"
  printf '%s' "$out"
}

_run_restart_wait() { # <pane>: until no agent is live in it
  local i=0
  while [ "$i" -lt "${CEL_RESTART_WAIT:-20}" ]; do
    cel_agent_list 2>/dev/null | jq -e --arg p "$1" \
      'any(.result.agents[]?; .pane_id == $p)' >/dev/null 2>&1 || return 0
    sleep "${CEL_RESTART_SLEEP:-1}"; i=$((i+1))
  done
  return 1
}

# Did the new process come up with the hooks this launch asked for?
# Found through _run_pane_pid, the same lookup every stale check uses.
_run_restart_confirm() { # <pane> <cwd> <runtime> <name> <argv...>
  local pane="$1" cwd="$2" rt="$3" name="$4"; shift 4
  local i=0 pid="" exp act missing
  while [ "$i" -lt "${CEL_RESTART_WAIT:-20}" ]; do
    if _run_pane_pid "$pane" "$cwd" "$rt"; then pid="$_RUN_PID"; break; fi
    sleep "${CEL_RESTART_SLEEP:-1}"; i=$((i+1))
  done
  if [ -z "$pid" ]; then
    c_warn "$name was started but its process could not be found - check the pane"
    return 0
  fi
  run_runtime_evidence "$rt" "$name" "$pane" "$cwd" "$pid"
  if [ "$RUN_EVIDENCE_ARGV" != observable ]; then
    c_warn "$name restarted (pid $pid); $RUN_EVIDENCE_DETAIL; launch flags unverified"
    return 0
  fi
  exp="$(mktemp)"; act="$(mktemp)"
  printf '%s\0' "$rt" "$@" > "$exp"
  printf '%s\0' "${RUN_EVIDENCE_ARGV_VALUES[@]}" > "$act"
  missing="$(run_launch_missing "$exp" "$act")"
  rm -f -- "$exp" "$act"
  if [ -n "$missing" ]; then
    c_warn "$name restarted (pid $pid) but its process lacks: $missing"
  else
    local hooks="" a
    for a in "$@"; do case "$a" in *.ts) hooks="${hooks:+$hooks, }$(_run_item_label "$a")" ;; esac; done
    c_ok "$name restarted (pid $pid)${hooks:+ with $hooks}"
  fi
  return 0
}

_run_gateway_env() { # <runtime> <agent-name> [require-key] [session-id] mutates GATEWAY_ENV
  local runtime="$1" agent_name="$2" require_key="${3:-1}" token session_var
  # Its own statement: bash expands every word of one `local` before assigning
  # any, so on the line above $agent_name would still be empty here.
  local session_id="${4:-${CEL_SESSION_ID:-$agent_name}}"
  # Both runtimes read the CLIProxyAPI api-key file; the gateway answers omp's
  # own `auth-gateway token` with 401.
  local key_file; key_file="$(_gateway_key_file)"
  if [ "$require_key" = 1 ] && { [ ! -r "$key_file" ] || [ ! -s "$key_file" ]; }; then
    die "gateway API key file is missing, empty, or unreadable - cel gateway install"
  fi
  # K=V words for the launch's `env` prefix, NOT an `export`: the token is a
  # substitution the pane evaluates, scoped to the launched process. The agent
  # root is pinned by _run_launch_env from the same resolvers the models
  # writers use, so the file written and the file loaded cannot disagree.
  token="\"\$(cat '$key_file')\""
  printf -v session_var 'CEL_SESSION_ID=%q' "$session_id"
  GATEWAY_ENV=("OMP_GATEWAY_TOKEN=$token" "$session_var")
}

_run_profile_gateway_setup() { # <runtime> <agent-name> [require-key] [write-models] [session-id]
  local runtime="$1" agent_name="$2" require_key="${3:-1}" write_models="${4:-1}" session_id="${5:-}"
  GATEWAY_ENV=()
  # Before anything is written: pi and omp roots that overlap refuse the launch.
  case "$runtime" in pi|omp) agent_roots_check "$runtime" || die "launch refused: pi and omp agent roots overlap" ;; esac
  if [ "${PROFILE_VIA:-}" != gateway ]; then
    # NATIVE START, GATEWAY LATER. An omp session can switch models in flight,
    # and the launch environment is the only place it reads the gateway client
    # key and session identity - a running process cannot be handed them. So an
    # omp that starts on Codex (or on a direct Anthropic model) still gets
    # them, AND the gateway's providers registered in its models.yml, when this
    # box has a configured gateway with a readable key: a switch to a gateway
    # model is only possible if the model exists in the file omp read at start.
    # Optional, never fatal: a direct-only box (no gateway, no key) is left
    # alone with nothing written, and a gateway that is merely down warns and
    # launches without models - a gateway that is REQUIRED (PROFILE_VIA) takes
    # the branch below and fails closed. pi is unchanged (its provider list is
    # written per gateway launch).
    [ "$runtime" = omp ] || return 0
    gateway_installed || return 0
    local kf; kf="$(_gateway_key_file)"
    [ -r "$kf" ] && [ -s "$kf" ] || return 0
    _run_gateway_env "$runtime" "$agent_name" 0 "$session_id"
    [ "$write_models" = 1 ] || return 0
    if ! gateway_ready; then
      c_warn "the gateway is not answering on $(gateway_url): $agent_name starts without gateway models (cel gateway status; restart it to switch to one)"
    elif ! gateway_omp_models_write; then
      c_warn "the gateway registered no model for $agent_name's omp - it starts on its own provider (cel gateway omp-scope --check)"
    fi
    return 0
  fi
  _run_gateway_env "$runtime" "$agent_name" "$require_key" "$session_id"
  if [ "$runtime" = pi ] && [ "$write_models" = 1 ]; then
    gateway_pi_models_write \
      || die "gateway launch: could not read the model list - cel gateway status"
    # FAIL CLOSED: the launch line names <provider>/<id>; a writer that
    # succeeded without registering that model would start a pane that dies
    # with "Unknown model".
    case "${PROFILE_MODEL:-}" in
      ompgw/*|ompgw-claude/*|ompgw-codex/*)
        gateway_pi_registered "$PROFILE_MODEL" \
          || die "gateway launch: pi's models.json does not list ${PROFILE_MODEL} - cel gateway status" ;;
    esac
  fi
  if [ "$runtime" = omp ] && [ "$write_models" = 1 ]; then
    gateway_omp_models_write \
      || die "gateway launch: could not write omp's gateway providers - cel gateway omp-scope --check"
    case "${PROFILE_MODEL:-}" in
      "$GATEWAY_OMP_PROVIDER"/*|"$GATEWAY_OMP_PROVIDER"-codex/*)
        gateway_omp_registered "$PROFILE_MODEL" \
          || die "gateway launch: omp's models.yml does not list ${PROFILE_MODEL} - cel gateway omp-scope --check" ;;
    esac
  fi
}

_run_reviewer_catalog_model() { # <sonnet|opus> <gateway model catalog JSON>
  case "$1" in
    opus) printf 'claude-opus-5-5' ;;
    sonnet)
      jq -r '
        [
          .data[]?.id? // empty
          | select(test("^claude-sonnet-[0-9]+(-[0-9]+)?(-[0-9]{8})?$"))
          | . as $id
          | capture("^claude-sonnet-(?<major>[0-9]+)(-(?<minor>[0-9]+))?(-(?<date>[0-9]{8}))?$") as $v
          | {id: $id, major: ($v.major | tonumber),
             minor: (($v.minor // "0") | tonumber), date: ($v.date // "")}
        ]
        | sort_by([.major, .minor, .date])
        | last.id // empty
      ' <<< "$2"
      ;;
    *) return 1 ;;
  esac
}


# ── team members: the scoped-role launcher behind `cel team add` ────────────
# A team member is a short-lived scoped agent on one feature. It is started
# through ONE door - `cel team add`, which reserves its row in
# <ws>/.cel/teams/<feature>/team.json, writes a one-time launch token and
# calls `cel run member` - never by hand: the guard refuses `cel run member`
# typed by any agent and refuses every agent a read of the tokens, and this
# launcher starts nothing without a token it can spend.
_RUN_TEAM_FEATURE_RE='^[a-z0-9][a-z0-9-]{1,40}$'
_RUN_TEAM_ROLES=' builder product design qa platform release analyst '

run_team_dir() { printf '%s/.cel/teams/%s' "$1" "$2"; }   # <wsdir> <feature>

# THE TOKEN IS SPENT BEFORE IT IS CHECKED. The rename is atomic, so of two
# launches racing for one token exactly one gets it, and a token that then
# fails a check is gone too: every attempt costs cel team add a fresh one.
# Valid: a regular file (not a link) owned by this user, mode 600, one line of
# 32-128 lowercase hex, written within CEL_TEAM_TOKEN_MAX_AGE seconds (600).
_run_member_token_spend() { # <team-dir> <alias>; dies unless a valid token was spent
  local f="$1/launch/$2.token" spent owner mode mtime tok="" age max="${CEL_TEAM_TOKEN_MAX_AGE:-600}"
  local why="members are started by cel team add only, which writes it"
  [ -e "$f" ] || [ -L "$f" ] || die "cel run member: no launch token for $2 - $why"
  [ ! -L "$f" ] && [ -f "$f" ] || die "cel run member: the launch token for $2 is not a regular file - refused; $why"
  spent="$f.spent.$BASHPID"
  mv -fT -- "$f" "$spent" 2>/dev/null \
    || die "cel run member: the launch token for $2 was taken by another launch - nothing started"
  read -r owner mode mtime < <(stat -c '%u %a %Y' -- "$spent" 2>/dev/null) || true
  IFS= read -r tok < "$spent" || true
  rm -f -- "$spent"
  [ "${owner:-}" = "$(id -u)" ] && [ "${mode:-}" = 600 ] \
    || die "cel run member: the launch token for $2 is not this user's mode-600 file (spent, nothing started) - $why"
  [[ "$tok" =~ ^[0-9a-f]{32,128}$ ]] \
    || die "cel run member: the launch token for $2 does not hold a token (spent, nothing started) - $why"
  age=$(( EPOCHSECONDS - ${mtime:-0} ))
  [ "$age" -ge -5 ] && [ "$age" -le "$max" ] \
    || die "cel run member: the launch token for $2 is ${age}s old, older than ${max}s (spent, nothing started) - cel team add writes a fresh one per launch"
}

# The member row by alias, from a team that is open. Sets MEMBER_* in the
# caller: PRODUCT, ROLE, FOCUS, REPO, BRANCH, WT, BASE, MODEL, DIR.
_run_member_load() { # <wsdir> <feature> <alias>; dies on anything but one valid reserved row
  local wsdir="$1" feature="$2" alias="$3" dir tj row
  dir="$(run_team_dir "$wsdir" "$feature")"
  tj="$(jq -ce --arg f "$feature" 'select(type == "object" and .feature == $f and .state == "open"
          and (.members | type == "array") and (.product | type == "string" and length > 0))' "$dir/team.json" 2>/dev/null)" \
    || die "cel run member: $dir/team.json is missing, does not parse, names another feature or is not open"
  row="$(printf '%s' "$tj" | jq -c --arg a "$alias" '[.members[] | select(.alias == $a)] | if length == 1 then .[0] else empty end')"
  [ -n "$row" ] || die "cel run member: team $feature has no single member row for $alias"
  MEMBER_DIR="$dir"
  MEMBER_PRODUCT="$(printf '%s' "$tj" | jq -r .product)"
  # grep reads ALL of its input (no -q): under pipefail, -q exiting on the
  # first match SIGPIPEs the second writer and the pipeline reads as a miss.
  { ws_product_names "$wsdir"; ws_repo_names "$wsdir"; } | grep -xF -- "$MEMBER_PRODUCT" >/dev/null \
    || die "cel run member: team $feature names product '$MEMBER_PRODUCT', which workspace '$(ws_name "$wsdir")' does not have"
  IFS=$'\t' read -r MEMBER_ROLE MEMBER_FOCUS MEMBER_REPO MEMBER_BRANCH MEMBER_WT MEMBER_BASE MEMBER_MODEL < <(
    printf '%s' "$row" | jq -r '[.role, .focus, .repo, .branch, .worktree, .base_sha, .model]
      | map(if type == "string" and length > 0 then . else "-" end) | @tsv')
  [ "$(printf '%s' "$row" | jq -r '.state // ""')" = reserved ] \
    || die "cel run member: $alias is $(printf '%s' "$row" | jq -r '.state // "stateless"'), not reserved - cel team add reserves a row before it launches one"
  local v
  for v in MEMBER_ROLE MEMBER_FOCUS MEMBER_REPO MEMBER_BRANCH MEMBER_WT MEMBER_BASE MEMBER_MODEL; do
    [ "${!v}" != - ] || printf -v "$v" '%s' ""
  done
  case "$_RUN_TEAM_ROLES" in *" $MEMBER_ROLE "*) ;; *) die "cel run member: $alias has role '${MEMBER_ROLE:-none}' - want one of:$_RUN_TEAM_ROLES" ;; esac
  [ -f "$dir/members/$alias.md" ] \
    || die "cel run member: no scope packet $dir/members/$alias.md - a member is launched with its task, never into an empty pane"
  if [ -n "$MEMBER_REPO" ]; then
    ws_repo_names "$wsdir" | grep -xF -- "$MEMBER_REPO" >/dev/null \
      || die "cel run member: $alias names repo '$MEMBER_REPO', which this workspace does not have"
  fi
  [ "$MEMBER_ROLE" = builder ] || return 0
  # A builder writes ONE branch, team/<feature>/<name>, in ONE worktree under
  # the team directory, from the head the lead recorded.
  [ -n "$MEMBER_REPO" ] || die "cel run member: builder $alias names no repo"
  [[ "$MEMBER_BRANCH" =~ ^team/"$feature"/[A-Za-z0-9._-]+$ ]] && git check-ref-format --branch "$MEMBER_BRANCH" >/dev/null 2>&1 \
    || die "cel run member: builder $alias has branch '$MEMBER_BRANCH' - want team/$feature/<name>"
  [ "$MEMBER_WT" = "$dir/wt/$alias" ] \
    || die "cel run member: builder $alias has worktree '$MEMBER_WT' - want $dir/wt/$alias"
  [[ "$MEMBER_BASE" =~ ^[0-9a-f]{40}$ ]] \
    || die "cel run member: builder $alias has base_sha '$MEMBER_BASE' - want the lead's 40-hex integration head"
}

# The builder's worktree: a new branch at base_sha. An existing worktree is
# reused only when it is already on that branch (a lead relaunching a member
# whose start was not confirmed); anything else there is refused.
_run_member_worktree() { # <repodir> <worktree> <branch> <base> <dry>
  local repodir="$1" wt="$2" branch="$3" base="$4" dry="$5" on
  if [ "$dry" = 1 ]; then
    printf 'git -C %s worktree add -b %s %s %s\n' "$repodir" "$branch" "$wt" "$base"
    return 0
  fi
  if [ -e "$wt" ]; then
    on="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" || on=""
    [ "$on" = "$branch" ] && [ "$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" = "$wt" ] \
      || die "cel run member: $wt exists and is not a worktree on $branch - nothing started"
    c_ok "reusing the worktree $wt on $branch"
    return 0
  fi
  git -C "$repodir" show-ref --verify -q "refs/heads/$branch" \
    && die "cel run member: branch $branch already exists in $repodir without its worktree - nothing started"
  git -C "$repodir" cat-file -e "$base^{commit}" 2>/dev/null || git -C "$repodir" fetch -q origin 2>/dev/null || true
  git -C "$repodir" cat-file -e "$base^{commit}" 2>/dev/null \
    || die "cel run member: base $base is not in $repodir (fetched origin) - push the integration head first"
  mkdir -p "$(dirname "$wt")"
  git -C "$repodir" worktree add -q -b "$branch" "$wt" "$base" >/dev/null 2>&1 \
    || die "cel run member: git worktree add -b $branch $wt $base failed in $repodir"
}

# THE EXACT NATIVE AGENT IS UP: the inventory shows exactly one agent of that
# name, in the pane it was started in. 1 = not seen within the window.
_run_member_confirm() { # <name> <pane>
  local name="$1" pane="$2" total="${CEL_MEMBER_CONFIRM_MS:-15000}" poll="${CEL_PANE_READY_POLL_MS:-250}" t0 roster
  t0=$((${EPOCHREALTIME/./} / 1000))
  while :; do
    if roster="$(cel_agent_list 2>/dev/null)" \
       && [ "$(printf '%s' "$roster" | jq -r --arg n "$name" --arg p "$pane" \
            '[.result.agents[]? | select(.name == $n)] | if length == 1 and .[0].pane_id == $p then "yes" else "no" end' 2>/dev/null)" = yes ]; then
      return 0
    fi
    [ $(( ${EPOCHREALTIME/./} / 1000 - t0 )) -lt "$total" ] || return 1
    _run_ms_sleep "$poll"
  done
}

# RETIRE ONE MEMBER: close its exact pane, after proving the pane's agent IS
# that member - the inventory names exactly one agent with the alias, and the
# process in that pane carries the launch's CEL_ROLE=member, CEL_WORKSPACE,
# CEL_TEAM and CEL_TEAM_MEMBER (_run_pane_launch_env, the proof a reviewer's
# workspace is read by). A Rex member is proven the same way from its receipt
# and its runtime's own environment (_run_rex_member_proven), and only its own
# window closes - never the lead's session (lib/rex.sh rex_agent_close, which
# protects a window anyone else has a terminal in). A Rex member that already
# exited leaves a finished window, closed only when Rex shows nothing runs in
# it. A builder's worktree is removed only when it is clean
# and holds no commit that origin lacks - its branch pushed, or a launch that
# never got past its base - and its local branch goes with it, so a relaunch
# is not refused for it; otherwise it is kept and said so on stdout. --keep
# keeps it whatever its state. team.json is the caller's (cel team retire):
# this never touches it.
# 0 = closed, or already gone. 1 = refused, nothing closed, reason on stderr.
member_retire() { # <wsdir> <feature> <alias> [--keep]
  local wsdir="${1:-}" feature="${2:-}" alias="${3:-}" keep=0 dir roster rows n pane backend proof pws pteam palias
  local receipt crc
  _mr_refuse() { printf 'member_retire: %s - nothing closed\n' "$1" >&2; return 1; }
  case "${4:-}" in "") ;; --keep) keep=1 ;; *) _mr_refuse "unknown argument '$4' (want --keep)"; return 1 ;; esac
  [[ "$feature" =~ $_RUN_TEAM_FEATURE_RE ]] || { _mr_refuse "feature '$feature' is not a feature id"; return 1; }
  [ -n "$alias" ] && [ "$(cel_alias_norm "$alias")" = "$alias" ] || { _mr_refuse "'$alias' is not an agent alias"; return 1; }
  dir="$(run_team_dir "$wsdir" "$feature")"
  [ -d "$dir" ] || { _mr_refuse "no team directory $dir"; return 1; }
  roster="$(cel_agent_list 2>/dev/null)" && printf '%s' "$roster" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 \
    || { _mr_refuse "the live agent inventory is unreadable, so which pane is $alias is unknown"; return 1; }
  rows="$(printf '%s' "$roster" | jq -c --arg a "$alias" '[.result.agents[] | select(.name == $a)]')"
  n="$(printf '%s' "$rows" | jq length)"
  receipt="$(_rex_file "$alias")"
  case "$n" in
    0)
      if [ -f "$receipt" ] && _run_rex_member_proven "$receipt" "$wsdir" "$feature" "$alias" ""; then
        crc=0; rex_agent_close "$receipt" || crc=$?
        if [ "$crc" = 0 ]; then c_ok "$alias had exited - closed its finished Rex window"
        else printf 'kept the Rex terminal %s of the exited %s: Rex does not show it holding only that finished terminal\n' \
          "$(jq -r .pane_id "$receipt")" "$alias"; fi
      else
        c_ok "$alias is not live - no pane to close"
      fi ;;
    1)
      IFS=$'\t' read -r pane backend < <(printf '%s' "$rows" | jq -r '.[0] | [(.pane_id // ""), (.backend // "herdr")] | @tsv')
      [ -n "$pane" ] || { _mr_refuse "the live $alias has no pane id"; return 1; }
      if [ "$backend" = rex ] || [[ "$pane" == rex/* ]]; then
        _run_rex_member_proven "$receipt" "$wsdir" "$feature" "$alias" "$pane" \
          || { _mr_refuse "the agent named $alias in Rex terminal $pane cannot be proven to be member $alias of team $feature in $wsdir"; return 1; }
        crc=0; rex_agent_close "$receipt" || crc=$?
        case "$crc" in
          0) c_ok "closed $alias (its Rex window, terminal $pane)" ;;
          3) _mr_refuse "Rex does not show $alias's window (or session) holding only its own terminal $pane - protected"; return 1 ;;
          *) printf 'member_retire: closed the Rex window of %s but could not see it and its runtime gone - check rex ls\n' "$alias" >&2; return 1 ;;
        esac
      else
        proof="$(_run_pane_launch_env "$pane" member CEL_WORKSPACE CEL_TEAM CEL_TEAM_MEMBER)"
        IFS=$'\t' read -r pws pteam palias <<< "$proof"
        [ -n "$proof" ] && { [ "$pws" = "$wsdir" ] || [ "$pws" -ef "$wsdir" ]; } && [ "$pteam" = "$feature" ] && [ "$palias" = "$alias" ] \
          || { _mr_refuse "the agent named $alias in pane $pane cannot be proven to be member $alias of team $feature in $wsdir"; return 1; }
        herdr pane close "$pane" >/dev/null 2>&1 || { _mr_refuse "herdr could not close pane $pane"; return 1; }
        c_ok "closed $alias (pane $pane)"
      fi ;;
    *) _mr_refuse "$n live agents are named $alias - which one is the member is unknown"; return 1 ;;
  esac
  if [ "$keep" = 1 ]; then
    [ ! -d "$dir/wt/$alias" ] || printf 'kept worktree %s (--keep)\n' "$dir/wt/$alias"
    return 0
  fi
  _run_member_worktree_retire "$wsdir" "$dir" "$alias"
  return 0
}

# A REX MEMBER IS ITS RECEIPT AND ITS RUNTIME'S ENVIRONMENT: the receipt names
# this alias, role member, this team and workspace (and the roster's terminal,
# when given); a live runtime's /proc environ - fixed at exec, the same launch
# env herdr members are proven by - carries CEL_ROLE=member, this team, alias
# and workspace, and points CEL_REX_RECORD at this very receipt. An exited one
# is proven by its receipt alone; rex_agent_close then shows nothing runs.
_run_rex_member_proven() { # <receipt> <wsdir> <feature> <alias> <pane|"">
  local f="$1" wsdir="$2" feature="$3" alias="$4" pane="$5" rws pid item
  local -A env
  [ -f "$f" ] && [ ! -L "$f" ] && _rex_receipt_valid "$f" || return 1
  jq -e --arg a "$alias" --arg t "$feature" --arg p "$pane" \
    '.name == $a and .role == "member" and .team == $t and .backend == "rex" and ($p == "" or .pane_id == $p)' "$f" >/dev/null 2>&1 || return 1
  rws="$(jq -r '.workspace // ""' "$f")"
  [ -n "$rws" ] && { [ "$rws" = "$wsdir" ] || [ "$rws" -ef "$wsdir" ]; } || return 1
  _rex_live "$f" || return 0
  pid="$(jq -r .pid "$f")"
  while IFS= read -r -d '' item; do
    case "$item" in *=*) env["${item%%=*}"]="${item#*=}" ;; esac
  done < <({ cat "/proc/$pid/environ"; } 2>/dev/null)
  [ "${env[CEL_ROLE]:-}" = member ] && [ "${env[CEL_TEAM]:-}" = "$feature" ] && [ "${env[CEL_TEAM_MEMBER]:-}" = "$alias" ] \
    && [ "${env[CEL_REX_RECORD]:-}" = "$f" ] && [ -n "${env[CEL_WORKSPACE]:-}" ] \
    && { [ "${env[CEL_WORKSPACE]}" = "$wsdir" ] || [ "${env[CEL_WORKSPACE]}" -ef "$wsdir" ]; } || return 1
  # Still that generation once its environment was read.
  _rex_live "$f"
}

_run_member_worktree_retire() { # <wsdir> <team-dir> <alias>
  local wsdir="$1" dir="$2" alias="$3" row role repo branch wt dirty ahead repodir
  local -a heads=(HEAD)
  row="$(jq -c --arg a "$alias" '[.members[]? | select(.alias == $a)] | if length == 1 then .[0] else empty end' "$dir/team.json" 2>/dev/null)" || row=""
  [ -n "$row" ] || return 0
  IFS=$'\t' read -r role repo branch < <(printf '%s' "$row" | jq -r '[(.role // "-"), (.repo // "-"), (.branch // "-")] | @tsv')
  wt="$dir/wt/$alias"
  [ "$role" = builder ] && [ -d "$wt" ] || return 0
  if ! dirty="$(git -C "$wt" status --porcelain 2>/dev/null)"; then
    printf 'kept worktree %s (its state cannot be read)\n' "$wt"; return 0
  fi
  if [ -n "$dirty" ]; then printf 'kept worktree %s (uncommitted changes)\n' "$wt"; return 0; fi
  # The checkout and its branch hold nothing origin lacks: pushed, or never
  # moved past the base it was cut from.
  repodir="$wsdir/repos/$repo"
  ! git -C "$repodir" show-ref --verify -q "refs/heads/$branch" || heads+=("refs/heads/$branch")
  ahead="$(git -C "$wt" rev-list --count "${heads[@]}" --not --remotes=origin 2>/dev/null)" || ahead=""
  if [ "$ahead" != 0 ]; then
    printf 'kept worktree %s (%s commit(s) origin does not have)\n' "$wt" "${ahead:-an unknown number of}"; return 0
  fi
  if ! git -C "$repodir" worktree remove "$wt" >/dev/null 2>&1; then
    printf 'kept worktree %s (git worktree remove refused)\n' "$wt"; return 0
  fi
  c_ok "removed worktree $wt (nothing in it origin lacks)"
  if [ "${#heads[@]}" -gt 1 ]; then
    git -C "$repodir" branch -D "$branch" >/dev/null 2>&1 \
      && c_ok "deleted the local branch $branch (origin has every commit on it)" \
      || printf 'kept branch %s (git branch -D refused)\n' "$branch"
  fi
}

# One admission boundary for both terminal hosts. The lock spans the final
# roster check and launch, so two concurrent Herdr/Rex starts cannot both
# observe the product absent. A subshell owns the descriptor: every return
# or refusal releases it without inheriting it into a Rex server's child.
cmd_run() (
  local arg
  for arg in "$@"; do
    if [ "$arg" = --dry-run ]; then _cmd_run "$@"; return $?; fi
  done
  local d fd
  d="$(_rex_state)"; mkdir -p "$d"; chmod 700 "$d"
  exec {fd}>"$d/launch.lock"
  flock -w 60 "$fd" || die 'cel run: another agent launch still owns admission; retry after it finishes'
  local _RUN_ADMISSION_FD="$fd" rc=0
  # Contain die/exit from resolution so the owner always unlocks explicitly,
  # even if a backend CLI happened to inherit a duplicate descriptor.
  ( _cmd_run "$@" ) || rc=$?
  flock -u "$fd"
  return "$rc"
)

# Only successful lane launches pin explicit choices. A new explicit profile
# supersedes its old model override; inherited workspace defaults stay unpinned.
_run_lane_choices_commit() { # cwd explicit-profile explicit-model runtime dry
  local cwd="$1" profile="$2" model="$3" runtime="$4" dry="$5" tmp
  [ "$dry" = 0 ] || return 0
  [ -n "$profile$model" ] || return 0
  mkdir -p "$cwd" || return 1
  if [ -n "$model" ]; then
    tmp="$(mktemp "$cwd/.launch-model.XXXXXX")" || return 1
    jq -n --arg runtime "$runtime" --arg model "$model" '{runtime:$runtime,model:$model}' > "$tmp" \
      && mv "$tmp" "$cwd/launch-model" || { rm -f "$tmp"; return 1; }
  elif [ -n "$profile" ]; then
    rm -f "$cwd/launch-model" || return 1
  fi
  if [ -n "$profile" ]; then
    tmp="$(mktemp "$cwd/.launch-profile.XXXXXX")" || return 1
    printf '%s\n' "$profile" > "$tmp" && mv "$tmp" "$cwd/launch-profile" \
      || { rm -f "$tmp"; return 1; }
  fi
}

_run_lane_model_valid() { # runtime model; offline syntax, never a provider probe
  [ -n "$(agent_model_flag "$1")" ] || return 1
  if [ "$1" = claude ]; then
    case "$2" in sonnet|opus|haiku|fable|sonnet\[1m\]|opus\[1m\]) return 0 ;; esac
    [[ "$2" =~ ^claude-(sonnet|opus|haiku|fable)-[0-9]+(-[0-9]+)*$ ]] || return 1
  else
    [[ "$2" =~ ^[a-zA-Z[:digit:]][a-zA-Z[:digit:]_./:+@-]*$ ]] || return 1
  fi
}

_run_lane_remember_current_model() { # cwd name runtime model pid dry
  local cwd="$1" name="$2" runtime="$3" model="$4" pid="$5" dry="$6" f flag a previous="" actual=""
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || die 'cel run: expected a live runtime PID'
  f="$(_rex_file "$name")"
  [ -f "$f" ] && _rex_receipt_valid "$f" && _rex_live "$f" \
    || die 'cel run: no matching live managed Rex lane receipt'
  jq -e --arg cwd "$cwd" --arg name "$name" --arg rt "$runtime" --argjson pid "$pid" \
    '.cwd == $cwd and .name == $name and .agent == $rt and .pid == $pid and .role == "solo" and .backend == "rex"' "$f" >/dev/null \
    || die 'cel run: current lane PID/runtime/identity does not match'
  flag="$(agent_model_flag "$runtime")"
  while IFS= read -r -d '' a; do
    if [ "$previous" = "$flag" ]; then actual="$a"; fi
    case "$a" in "$flag"=*) actual="${a#*=}" ;; esac
    previous="$a"
  done < "$(_run_proc_root)/$pid/cmdline"
  [ "$actual" = "$model" ] && _rex_live "$f" \
    || die 'cel run: requested model is not the current runtime launch model'
  _run_lane_choices_commit "$cwd" '' "$model" "$runtime" "$dry" || die 'cel run: could not remember lane model'
  printf 'Lane model%s: %s (verified live PID %s; no restart)\n' "$([ "$dry" = 0 ] || printf ' preview')" "$model" "$pid"
}

_cmd_run() { # shared role/runtime resolution; cmd_run holds admission for actual starts
  local role="" repo="" product="" workspace="" branch="" pr="" dry_run=0 force=0
  local restart=0 fresh=0 pane_opt="" solo_forced=0 lane=""
  local profile="" model_opt="" thinking_opt="" remember_model_pid="" handoff=""
  local CEL_OPENCODE_CONFIG_FILE="" CEL_OPENCODE_AGENT=""
  local session_backend="${CEL_SESSION_BACKEND:-}" backend_opt=""
  local team="" member="" MEMBER_DIR="" MEMBER_PRODUCT="" MEMBER_ROLE="" MEMBER_FOCUS=""
  local MEMBER_REPO="" MEMBER_BRANCH="" MEMBER_WT="" MEMBER_BASE="" MEMBER_MODEL=""
  local review_focus="" review_kind=""
  # The call as made: a plain `cel run reviewer` relaunches itself once per
  # reviewer the PR needs (_run_reviewer_set).
  local -a _run_argv=("$@")

  if [ $# -gt 0 ]; then
    case "$1" in
      root|orchestrator|reviewer) role="$1"; shift ;;
      # cel team add's launcher; see _run_member_token_spend.
      member) role=member; shift ;;
      # Retired with fan-out; refused for one release so a habit gets an answer.
      worker|scout|spike) die "cel run $1: fan-out was retired on 2026-11-08: build in the product's solo agent (feature teams are coming)" ;;
      # `console` is core's old name and stays an alias of it.
      core|console) role=core; shift ;;
      # SOLO IS THE PRODUCT'S AGENT, not a new kind of pane: same directory,
      # mailbox, alias, resume and one-per-product refusal whether it is
      # started as `cel run solo` or `cel run orchestrator`.
      solo) role=orchestrator; solo_forced=1; shift ;;
      --*) : ;;
      *) die "cel run: unknown role '$1' (want core, root, orchestrator, solo or reviewer; omit for direct)" ;;
    esac
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)      repo="$2"; shift 2 ;;
      --product)   product="$2"; shift 2 ;;
      --workspace) workspace="$2"; shift 2 ;;
      --pr)        pr="$2"; shift 2 ;;
      --profile)   profile="$2"; shift 2 ;;
      --model)     model_opt="$2"; shift 2 ;;
      --thinking)  thinking_opt="$2"; shift 2 ;;
      --session-backend) backend_opt="$2"; shift 2 ;;
      --dry-run)   dry_run=1; shift ;;
      --force)     force=1; shift ;;
      --restart)   restart=1; shift ;;
      --fresh)     fresh=1; shift ;;
      --pane)      pane_opt="$2"; restart=1; shift 2 ;;
      --lane)      lane="$2"; shift 2 ;;
      --remember-current-model) remember_model_pid="$2"; shift 2 ;;
      --team)    team="$2"; shift 2 ;;
      --member)  member="$2"; shift 2 ;;
      --handoff) handoff="$2"; shift 2 ;;
      --focus)   [ "$review_kind" != qa ] || die "cel run reviewer: --focus and --qa name two different agents (an extra reviewer, a QA agent) - start each with its own call"
                 review_focus="$2"; review_kind=review; shift 2 ;;
      --qa)      [ "$review_kind" != review ] || die "cel run reviewer: --focus and --qa name two different agents (an extra reviewer, a QA agent) - start each with its own call"
                 review_focus="$2"; review_kind=qa; shift 2 ;;
      *) die "cel run: unknown argument '$1'" ;;
    esac
  done
  [ "$review_kind" != review ] || [ "$role" = reviewer ] \
    || die "cel run: --focus names an extra PR reviewer's focus (cel run reviewer --repo r --pr n --focus f); a team member's comes from cel team add"
  [ "$review_kind" != qa ] || [ "$role" = reviewer ] \
    || die "cel run: --qa names a PR's QA agent (cel run reviewer --repo r --pr n --qa f); a team member's comes from cel team add"
  # What was NAMED, before defaults fill it in: a Rex receipt's relaunch line
  # (_run_rex_relaunch) repeats only the owner's explicit choices.
  local profile_opt="$profile"
  if [ -n "$remember_model_pid" ]; then
    [ "$solo_forced" = 1 ] && [ -n "$lane" ] && [ -n "$model_opt" ] \
      && [ -z "$profile$thinking_opt$backend_opt$repo$pr$pane_opt$handoff" ] \
      && [ "$restart$fresh$force" = 000 ] \
      || die 'cel run: --remember-current-model PID requires solo --lane and --model only (plus product/workspace/dry-run)'
  fi
  session_backend="${backend_opt:-${session_backend:-herdr}}"
  case "$session_backend" in herdr|rex) ;; *) die 'cel run: --session-backend wants herdr or rex' ;; esac

  # Core resolves NO workspace - see _run_core. It has to return before the
  # resolution below, which would otherwise die for want of one.
  case "$role" in
    root|orchestrator|core) ;;
    *) [ "$restart" -eq 0 ] && [ "$fresh" -eq 0 ] \
         || die "cel run: --restart and --fresh are for core, root and product agents only - reviewers never resume" ;;
  esac
  if [ "$role" = core ]; then
    [ -z "$repo$product$workspace$pr" ] \
      || die "cel core: core stands in no workspace - --repo/--product/--workspace/--pr do not apply"
    _run_core "$profile" "$model_opt" "$thinking_opt" "$dry_run" "$restart" "$fresh" "$force" "$pane_opt"
    return $?
  fi
  # See _run_live_names: core and a root pane must not share root's cursor.
  if [ "$role" = root ] && [ "$force" -eq 0 ] && grep -qx core <<< "$(_run_live_names)"; then
    die "cel run root: core is live and reads root's mail in every workspace - a root pane would share its cursor and the two would take each other's messages. Talk to core (herdr agent focus core), or pass --force"
  fi

  local wsdir
  if [ -n "$workspace" ]; then
    wsdir="$(registry_require "$workspace")"
  else
    wsdir="$(ws_current)" || die "cel run: not inside a workspace (cd into one, or pass --workspace <name>)"
  fi
  if [ -z "$backend_opt" ] && [ -z "${CEL_SESSION_BACKEND:-}" ]; then
    session_backend="$(_wsy "$wsdir" '.session_backend')"
    session_backend="${session_backend:-herdr}"
    case "$session_backend" in herdr|rex) ;; *) die 'workspace session_backend must be herdr or rex' ;; esac
  fi

  # A TEAM MEMBER comes from cel team add only: its token first (spent even
  # when what follows refuses), then its reserved row in team.json, which names
  # the product, the repo and - for a builder - branch, worktree and base. A
  # dry run previews and spends nothing. A member lives where its lead does:
  # a lead running in Rex (cel team add inherits its CEL_SESSION_BACKEND=rex)
  # gets it as a window in the lead's own Rex session; otherwise it joins its
  # feature's herdr tab. A workspace default never moves it off its lead's host.
  if [ "$role" = member ]; then
    [[ "$team" =~ $_RUN_TEAM_FEATURE_RE ]] \
      || die "cel run member: --team wants a feature id ([a-z0-9][a-z0-9-]{1,40}), got '$team'"
    [ -n "$member" ] && [ "$(cel_alias_norm "$member")" = "$member" ] \
      || die "cel run member: --member wants the alias cel team add gave the member, got '$member'"
    [ -z "$repo$product$pr$lane$pane_opt$handoff$profile$model_opt$thinking_opt$backend_opt" ] && [ "$force" = 0 ] \
      || die "cel run member: everything but --workspace, --team and --member comes from the member's row in team.json"
    [ "$dry_run" = 1 ] || _run_member_token_spend "$(run_team_dir "$wsdir" "$team")" "$member"
    _run_member_load "$wsdir" "$team" "$member"
    repo="$MEMBER_REPO"; product="$MEMBER_PRODUCT"; model_opt="$MEMBER_MODEL"
    session_backend=herdr
    [ "${CEL_SESSION_BACKEND:-}" != rex ] || session_backend=rex
  elif [ -n "$team$member" ]; then
    die "cel run: --team and --member belong to cel run member (cel team add's launcher)"
  fi

  # FAIL CLOSED ON IDENTITY. A pane whose declared GitHub account
  # cannot produce a token would act as whichever account is active - the
  # exact mistake the github: block exists to prevent. Dry runs too: a
  # preview of a launch that would refuse must not look like a success.
  ws_github_ready "$wsdir" \
    || die "cel run: refusing to launch for workspace '$(ws_name "$wsdir")': $(ws_github_fix "$(ws_github_user "$wsdir")")"

  # --repo is required for every mode but root, unless there is exactly one
  # thing to default to. For an orchestrator that thing is a PRODUCT: a
  # workspace of two repos in one declared product has one orchestrator, and
  # making it name a repo would be asking for information it does not have.
  if [ "$role" != "root" ] && [ -z "$repo" ] && [ -z "$product" ]; then
    local repos prods; mapfile -t repos < <(ws_repo_names "$wsdir")
    mapfile -t prods < <(ws_product_names "$wsdir")
    if [ "$role" = "orchestrator" ] && [ "${#prods[@]}" -eq 1 ]; then
      product="${prods[0]}"
    elif [ "${#repos[@]}" -eq 1 ]; then
      repo="${repos[0]}"
    elif [ "$role" = "orchestrator" ]; then
      die "cel run: --product or --repo is required (workspace '$(ws_name "$wsdir")' has ${#prods[@]} products)"
    else
      die "cel run: --repo is required (workspace '$(ws_name "$wsdir")' has ${#repos[@]} repos)"
    fi
  fi
  [ -z "$lane" ] || [ "$role" = orchestrator ] \
    || die "cel run: --lane names a solo product's extra agent (cel run solo --product <p> --lane <name>)"
  # --product is an orchestrator's flag; every other role works in a checkout.
  [ "$role" = "orchestrator" ] || [ -n "$repo" ] || [ "$role" = "root" ] || [ "$role" = member ] \
    || die "cel run: --repo is required for $role (--product names a product, which has no checkout of its own)"

  local tag="${role:-direct}" alias_name cwd runtime rolefile="" bind="$repo"
  local review_head="" review_base="" review_path="" repodir="" label solo=0 build_mode=""
  case "$role" in
    "")
      alias_name="$repo/direct"
      cwd="$wsdir/repos/$repo"
      runtime="$(ws_runtime "$wsdir" orchestrator)"
      ;;
    root)
      alias_name="$(ws_name "$wsdir")/root"
      cwd="$wsdir"
      runtime="$(ws_runtime "$wsdir" root)"
      rolefile="$CEL_ROOT/core/roles/root-orchestrator.md"
      ;;
    orchestrator)
      # --repo still works and means "the product this repo belongs to", so a
      # member repo never opens an orchestrator of its own.
      [ -n "$product" ] || product="$(ws_product_of_repo "$wsdir" "$repo")"
      bind="$product"
      alias_name="$product/orch"
      cwd="$(ws_product_dir "$wsdir" "$product")"
      runtime="$(ws_runtime "$wsdir" orchestrator)"
      # Every product's agent is its solo agent: it builds and ships the
      # product itself. A product still set to the retired `mode: fleet` is
      # refused rather than started as something it no longer is; an unknown
      # value is refused too - guessing would hand a product to the wrong agent.
      build_mode="$(ws_build_mode "$wsdir" "$product")"
      case "$build_mode" in
        solo) ;;
        fleet) die "cel run: $product is set to mode: fleet - fan-out was retired on 2026-11-08: build in the product's solo agent (feature teams are coming). Switch it with: cel mode $product solo" ;;
        *) die "cel run: product '$product' has mode '$build_mode' - want solo (workspace.yaml)" ;;
      esac
      solo=1
      rolefile="$CEL_ROOT/core/roles/solo.md"
      # A LANE is a second (third, ...) solo agent on the same product, for a
      # separate goal: its own pane, name (<product>-<lane>), mailbox,
      # directory and session, working in the product's repos through its
      # own worktrees.
      if [ -n "$lane" ]; then
        [ "$lane" != orch ] || die "cel run solo --lane: 'orch' is the product's main agent - leave --lane off for it"
        [[ "$lane" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] \
          || die "cel run solo --lane: '$lane' - use lowercase letters and digits, single dashes between them"
        alias_name="$product/$lane"
        _run_lane_name_free "$wsdir" "$product" "$lane"
        cwd="$(ws_solo_dir "$wsdir" "$product")/lane-$lane"
      fi
      # ONE LOGIN RUNS A PRODUCT (products[].home): on a teammate's login its
      # agent - main or lane - would be a second builder over the same repos
      # with review state of its own. Refused here, dry runs too, unless the
      # operator says they mean it. Recording a live lane's model starts
      # nothing, so it is not asked.
      if [ "$force" -eq 0 ] && [ -z "$remember_model_pid" ]; then
        local home_why
        home_why="$(ws_product_home_check "$wsdir" "$product")" \
          || die "cel run: $home_why - ask $(ws_product_home "$wsdir" "$product"), or pass --force"
      fi
      ;;
    reviewer)
      [ -n "$pr" ] || die "cel run reviewer: --pr is required"
      # AN EXTRA REVIEWER (--focus) or QA AGENT (--qa) is one of the packs
      # there are for its kind, under a name no other reviewer of the PR
      # answers to.
      if [ -n "$review_focus" ]; then
        review_focus_valid "$review_focus" "$review_kind" || die "cel run reviewer: $(review_focus_refusal "$review_focus" "$review_kind") - nothing started"
        local alias_clash
        alias_clash="$(review_alias_free "$repo" "$pr" "$review_focus" "$review_kind")" || die "cel run reviewer: $alias_clash - nothing started"
      fi
      # Reviewers ALWAYS run on pi: its inbox extension wakes an idle session
      # on incoming mail, which is how a re-review request reaches a reviewer
      # nobody is typing to. The workspace review block owns the model only;
      # a `review.runtime` naming anything else is ignored, and said so.
      runtime=pi
      local review_runtime
      review_runtime="$(ws_review "$wsdir" runtime)"
      [ -n "$review_runtime$(ws_review "$wsdir" model)" ] \
        || die "cel run reviewer: workspace '$(ws_name "$wsdir")' declares no review: block"
      # A PLAIN `cel run reviewer` IS THE PR'S WHOLE SET: the plain reviewer,
      # then each extra one the review policy requires (_run_reviewer_set),
      # every one of them through the single launch below.
      if [ -z "$review_focus" ] && [ -z "${_run_review_one:-}" ]; then
        _run_reviewer_set "$wsdir" "$repo" "$pr" "$dry_run" "${_run_argv[@]:1}"
        return $?
      fi
      [ -z "$review_runtime" ] || [ "$review_runtime" = pi ] \
        || c_warn "cel run reviewer: workspace '$(ws_name "$wsdir")' sets review.runtime: $review_runtime, which is ignored - reviewers run on pi, the runtime that delivers mail to an idle reviewer; review.model still applies (set review.runtime: pi, or remove it)"
      alias_name="$repo/pr-$pr-review"
      local rv_who="reviewer for $repo#$pr"
      rolefile="$CEL_ROOT/core/roles/pr-reviewer.md"
      if [ "$review_kind" = qa ]; then
        # A QA AGENT does not read the change, it uses it: its own role.
        alias_name="$repo/pr-$pr-$(review_slot "$review_focus" qa)"
        rv_who="$review_focus QA agent for $repo#$pr"
        rolefile="$CEL_ROOT/core/roles/pr-qa.md"
      elif [ -n "$review_focus" ]; then
        alias_name="$repo/pr-$pr-$(review_slot "$review_focus")"
        rv_who="$review_focus reviewer for $repo#$pr"
      fi
      cwd="$wsdir/repos/$repo"
      # ONE PULL REQUEST, ONE REVIEWER. Asking for a reviewer that is already
      # standing gets that one back. Checked before anything is created, so a
      # dry run previews the reuse honestly and no row is written twice.
      local existing
      local reviewer_roster recorded_pane recorded_agent recorded_live reviewer_alias alias_rows alias_count
      reviewer_roster="$(cel_agent_list 2>/dev/null)" || die 'cel run reviewer: native inventory is unreadable; no checkout changed'
      printf '%s' "$reviewer_roster" | jq -e '.result.agents | type == "array"' >/dev/null \
        || die 'cel run reviewer: native inventory is invalid; no checkout changed'
      local find_rc=0
      existing="$(reviewers_find "$wsdir" "$repo" "$pr" "$review_focus" "$review_kind")" || find_rc=$?
      [ "$find_rc" != 2 ] || die "cel run reviewer: the reviewer registry $(_reviewers_state) does not parse - whether $repo#$pr already has a $rv_who is unknown, so none is started; cel gc rebuilds it from the live roster"
      if [ "$find_rc" = 0 ]; then
        recorded_pane="$(printf '%s' "$existing" | jq -r .pane)"
        recorded_agent="$(printf '%s' "$existing" | jq -r '.agent // ""')"
        [ -n "$recorded_agent" ] || die 'cel run reviewer: recorded reviewer identity is incomplete'
        recorded_live="$(printf '%s' "$reviewer_roster" | jq -r --arg p "$recorded_pane" --arg a "$recorded_agent" '[.result.agents[] | select(.pane_id == $p and .name == $a)] | length')"
        [ "$recorded_live" = 1 ] || die "cel run reviewer: recorded $rv_who is not confirmed live; reconcile its canonical retirement before relaunching"
        c_ok "$rv_who is already running as $(printf '%s' "$existing" | jq -r '.agent // "?"') in pane $recorded_pane - reusing it"
        return 0
      fi
      # Registry loss must not create a duplicate when a preserved round uses
      # a non-default checkout pathname. The canonical alias is another key.
      reviewer_alias="$(_run_agent_name "$alias_name")"
      alias_rows="$(printf '%s' "$reviewer_roster" | jq -c --arg n "$reviewer_alias" '[.result.agents[] | select(.name == $n)]')"
      alias_count="$(printf '%s' "$alias_rows" | jq length)"
      [ "$alias_count" -le 1 ] || die 'cel run reviewer: multiple live native reviewers match this PR; no checkout changed'
      if [ "$alias_count" = 1 ]; then
        local alias_pane alias_cwd alias_base scoped_alias=0
        IFS=$'\t' read -r alias_pane alias_cwd < <(printf '%s' "$alias_rows" | jq -r '.[0] | [.pane_id,.cwd] | @tsv')
        [ -n "$alias_pane" ] && [ -n "$alias_cwd" ] || die 'cel run reviewer: matching native reviewer has incomplete identity'
        alias_cwd="$(pane_cwd "$alias_cwd")"
        alias_base="$(reviewer_checkout_path "$repo" "$pr" "$review_focus" "$review_kind")"
        case "$alias_cwd" in "$alias_base"|"$alias_base".round.*) scoped_alias=1 ;; esac
        if printf '%s' "$alias_rows" | jq -e --arg r "$repo" --arg p "$pr" --arg ws "$wsdir" \
          '.[0] | .backend == "rex" and .role == "reviewer" and .repo == $r and (.pr|tostring) == $p and .workspace == $ws' >/dev/null; then scoped_alias=1; fi
        [ "$scoped_alias" = 1 ] || die 'cel run reviewer: matching alias is not bound to this review scope; no checkout changed'
        _run_reviewer_owned "$reviewer_roster" "$alias_pane" "$wsdir" "$repo" "$pr"
        [ "$dry_run" = 1 ] || reviewers_record "$wsdir" "$repo" "$pr" "$alias_pane" "$reviewer_alias" "$alias_cwd" "$cwd" "" "$review_focus" "$review_kind" \
          || die 'cel run reviewer: could not retain the existing native reviewer identity'
        c_ok "$rv_who is already running as $reviewer_alias in pane $alias_pane - reusing it"
        return 0
      fi
      # A LIVE REVIEWER WITH NO ROW IS STILL THE REVIEWER: its row may have been
      # pruned or dropped under a stale pane id. The roster finds it by the
      # directory it stands in, and the row is written back.
      local live_path live
      live_path="$(reviewer_checkout_path "$repo" "$pr" "$review_focus" "$review_kind")"
      if live="$(_reviewer_checkout_occupant "$live_path")" \
         && [ "${live%%$'\t'*}" != unknown ]; then
        local lpane lname live_checkout
        IFS=$'\t' read -r lpane lname live_checkout <<< "$live"
        _run_reviewer_owned "$reviewer_roster" "$lpane" "$wsdir" "$repo" "$pr"
        if [ "$dry_run" -eq 0 ]; then
          reviewers_record "$wsdir" "$repo" "$pr" "$lpane" "$lname" "$live_checkout" "$cwd" "" "$review_focus" "$review_kind" \
            || c_warn "could not record the $rv_who"
        fi
        c_ok "$rv_who is already running as $lname in pane $lpane (found by its checkout) - reusing it"
        return 0
      fi
      # A NEW REVIEWER IS ADMITTED against the box agent budget; reusing a
      # live one above never is - it adds nothing to the box.
      local budget_why
      budget_why="$(budget_admit reviewer "$reviewer_roster")" \
        || die "cel run reviewer: $budget_why - no checkout changed"
      # AND THE TREE IT READS IS THE PR'S, not this directory's. A dry run
      # asks the forge nothing and creates nothing: it is a preview of a launch,
      # and a preview that fetches is a side effect.
      repodir="$cwd"
      review_path="$(reviewer_checkout_path "$repo" "$pr" "$review_focus" "$review_kind")"
      if [ "$dry_run" -eq 0 ]; then
        have jq || die "cel run reviewer: jq is not on PATH"
        local facts
        facts="$(_run_reviewer_pr_facts "$wsdir" "$repo" "$pr")" \
          || die "cel run reviewer: cannot read $repo#$pr from its forge - a reviewer without a head SHA would review whatever tree it stood in, which is the bug this refuses"
        IFS=$'\t' read -r review_head review_base <<< "$facts"
        [ -n "$review_head" ] \
          || die "cel run reviewer: the forge returned no head SHA for $repo#$pr"
        review_path="$(reviewer_checkout_make "$repodir" "$repo" "$pr" "$review_head" "$review_focus" "$review_kind")" \
          || die "cel run reviewer: could not check out $repo#$pr at $review_head (is $repodir a clone of $repo?)"
        cwd="$review_path"
        # where a QA agent saves the evidence it then records (_run_qa_brief)
        [ "$review_kind" != qa ] || mkdir -p "$wsdir/.cel/reviews/pr-$pr/qa-$review_focus.shots"
      fi
      ;;
    member)
      alias_name="$member"
      bind="$product"
      runtime="$(ws_runtime "$wsdir" orchestrator)"
      local member_roster budget_why
      member_roster="$(cel_agent_list 2>/dev/null)" \
        && printf '%s' "$member_roster" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 \
        || die "cel run member: the live agent inventory is unreadable - nothing started (fail closed)"
      printf '%s' "$member_roster" | jq -e --arg n "$member" '[.result.agents[] | select(.name == $n)] | length == 0' >/dev/null \
        || die "cel run member: an agent named $member is already live - nothing started"
      budget_why="$(budget_admit team-member "$member_roster")" || die "cel run member: $budget_why"
      if [ "$MEMBER_ROLE" = builder ]; then
        cwd="$MEMBER_WT"
        _run_member_worktree "$wsdir/repos/$repo" "$MEMBER_WT" "$MEMBER_BRANCH" "$MEMBER_BASE" "$dry_run"
      else
        # Every other role reads: it stands in the team directory, the one
        # place the guard lets it write.
        cwd="$MEMBER_DIR"
      fi
      ;;
  esac
  # What the launched process is told it is (CEL_ROLE, read by the guard).
  # Plumbing keeps `$tag` (orchestrator): the role FILE must keep ending in
  # role-orchestrator.md, which lib/gc.sh reads as "long-lived agent, never
  # reap".
  local env_role="$tag"
  if [ "$solo" -eq 1 ]; then env_role=solo; fi
  case "$role" in
    "")           label="$(pane_label direct "$repo")" ;;
    root)         label="$(pane_label root "$(ws_name "$wsdir")")" ;;
    orchestrator) label="$(pane_label solo "$product${lane:+/$lane}")" ;;
    reviewer)     label="$(pane_label reviewer "$repo" "$pr${review_focus:+ $([ "$review_kind" = qa ] && printf 'qa ')$review_focus}")" ;;
    member)       label="$(_pane_label_cap "$member · $MEMBER_ROLE${MEMBER_FOCUS:+/$MEMBER_FOCUS}")" ;;
  esac

  # ONE ORCHESTRATOR PER PRODUCT, AND THE DUPLICATE IS REFUSED HERE. This is
  # the only door that starts one, so it is the only place the refusal cannot
  # be routed around. A live agent in the product's own directory IS its
  # orchestrator whether or not herdr still knows its name - a nameless one is
  # a fault with a cure (`cel ws up` renames it), never an absence. The check
  # runs on a dry run too: a preview of a launch that would be refused is a
  # preview of something that will not happen.
  if [ "$role" = orchestrator ] && [ "$force" -eq 0 ] && [ "$restart" -eq 0 ] && [ -z "$remember_model_pid" ]; then
    local occupant oname opane
    occupant="$(_run_live_agent_in_cwd "$cwd")" || die 'cel run: agent inventory is unreadable; refusing duplicate admission'
    if [ -n "$occupant" ]; then
      IFS=$'\t' read -r oname opane _ <<< "$occupant"
      [ "$oname" != "-" ] || oname="<unnamed>"
      die "cel run orchestrator: an agent is already live in $cwd (pane ${opane:-?}, name $oname)
  Starting a second orchestrator over a live one is the duplicate this refusal exists to prevent.
  Name it and adopt it:  cel ws up $(ws_name "$wsdir")
  Or say you mean it:    cel run orchestrator --product ${product:-$repo} --force"
    fi
  fi

  # PRODUCT AGENTS ARE COUNTED, NEVER BLOCKED: over the box agent budget the
  # product's own agent (or root) still starts, and the launch says so.
  if { [ "$role" = orchestrator ] || [ "$role" = root ]; } && [ "$restart" -eq 0 ] && [ -z "$remember_model_pid" ]; then
    local budget_note
    budget_note="$(budget_admit product)" || c_warn "cel run: $budget_note"
  fi

  # Model and reasoning level, resolved before the role body is rendered
  # because a profile may CHANGE THE RUNTIME - and the runtime decides how the
  # role is injected, so picking it late would inject the role in the
  # wrong shape. Precedence, weakest first: the workspace default level, then
  # the named profile, then explicit flags.
  local model="" thinking
  thinking="$(ws_thinking "$wsdir")"
  # A reviewer's model has always come from the `review:` block, and so does
  # its level when the block sets `thinking:` (over the workspace default); a
  # profile or an explicit --model / --thinking still overrides either, and
  # the level is clamped per runtime like any role's (profile_clamp).
  if [ "$role" = "reviewer" ]; then
    model="$(ws_review "$wsdir" model)"
    local review_thinking; review_thinking="$(ws_review "$wsdir" thinking)"
    [ -z "$review_thinking" ] || thinking="$review_thinking"
  fi

  # No --profile? The workspace may still bind one to this role. That binding
  # is what makes root and the orchestrators configurable at all: neither is
  # launched by hand, so a flag would never reach them.
  # A repo or product may narrow that binding for itself; see role_profile_for.
  # A solo agent may be bound on its own (`role_profiles: { solo: ... }`), and
  # otherwise takes the orchestrator's binding - it is the same product's agent.
  # A LANE KEEPS THE PROFILE IT WAS LAUNCHED WITH. A lane started with
  # --profile (say, Claude Code for one feature set) and restarted by
  # /cel-restart or `cel run solo --lane x --restart` - neither passes the
  # flag - would otherwise come back on the product's default, a different
  # runtime, and its session would not resume. The launch writes the choice
  # beside the lane's role file; a later --profile replaces it, including any
  # old explicit model. Model overrides are lane-local, never profile edits.
  local lane_profile_file="" lane_profile_explicit="" lane_model_explicit=""
  [ -z "$lane" ] || lane_profile_file="$cwd/launch-profile"
  [ -z "$lane" ] || lane_model_explicit="$model_opt"
  # Only choices the owner NAMED are remembered, not workspace defaults.
  [ -z "$lane_profile_file" ] || lane_profile_explicit="$profile"
  if [ -z "$profile" ] && [ -n "$lane_profile_file" ] && [ -s "$lane_profile_file" ]; then
    IFS= read -r profile < "$lane_profile_file"
  fi
  if [ -z "$profile" ] && [ "$solo" -eq 1 ]; then
    profile="$(role_profile_for "$wsdir" solo "$bind")"
  fi
  # A team member: role_profiles.team-<role>, else role_profiles.member (the
  # line below), else the workspace default - no runtime is hard-coded.
  if [ -z "$profile" ] && [ "$role" = member ]; then
    profile="$(role_profile_for "$wsdir" "team-$MEMBER_ROLE" "$bind")"
  fi
  # A QA agent: role_profiles.qa, else role_profiles.reviewer (the line below),
  # else the review: block's model - it runs as a reviewer, on pi.
  if [ -z "$profile" ] && [ "$role" = reviewer ] && [ "$review_kind" = qa ]; then
    profile="$(role_profile_for "$wsdir" qa "$bind")"
  fi
  [ -n "$profile" ] || profile="$(role_profile_for "$wsdir" "$tag" "$bind")"

  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_ISOLATE="" PROFILE_VETO=""
  local PROFILE_VIA="" PROFILE_WSDIR="" PROFILE_GATEWAY_ACCOUNTS=0
  if [ -n "$profile" ]; then
    profile_resolve "$wsdir" "$profile" "$runtime"
    [ -z "$PROFILE_VETO" ] || die "cel run: profile '$profile' is vetoed - $PROFILE_VETO"
    # Persistence happens after the actual launch, not merely resolution.
    runtime="$PROFILE_RUNTIME"; thinking="$PROFILE_THINKING"
    # A profile that names no model leaves the model alone, so binding a
    # reviewer to a profile for its RUNTIME or effort does not quietly discard
    # the `review:` block's model.
    [ -z "$PROFILE_MODEL" ] || model="$PROFILE_MODEL"
  fi
  # Profiles can change runtime for other roles; reviewer delivery depends on
  # pi's idle inbox extension, so keep pi execution and honor explicit flags.
  [ "$role" != reviewer ] || runtime=pi
  if [ -n "$lane" ] && [ -z "$lane_profile_explicit$model_opt" ] && [ -f "$cwd/launch-model" ]; then
    model_opt="$(jq -er --arg rt "$runtime" 'select(.runtime == $rt) | .model | select(type == "string" and length > 0)' "$cwd/launch-model")" \
      || die 'cel run: saved lane model is invalid or belongs to a different runtime; name an explicit --profile or --model'
  fi
  if [ -n "$lane" ] && [ -n "$model_opt" ]; then
    _run_lane_model_valid "$runtime" "$model_opt" || die 'cel run: invalid explicit lane model for this runtime'
  fi
  [ -z "$model_opt" ]    || model="$model_opt"
  [ -z "$thinking_opt" ] || thinking="$thinking_opt"
  if [ -n "$remember_model_pid" ]; then
    _run_lane_remember_current_model "$cwd" "$(_run_agent_name "$alias_name")" "$runtime" "$model" "$remember_model_pid" "$dry_run"
    return $?
  fi
  # Reviewers never let pi infer a provider: aliases resolve from the current
  # gateway catalog, and explicit Claude IDs are routed through that gateway.
  # A Codex-family id (gpt-6.1-sol, ompgw-codex/gpt-6-astra) goes through the
  # gateway's codex provider - the same route and vetoes a profile with that
  # model gets.
  if [ "$role" = reviewer ] && gateway_codex_model_p "$model"; then
    PROFILE_MODEL="$model" PROFILE_WSDIR="$wsdir" PROFILE_VIA=gateway PROFILE_VETO=""
    _profile_gateway_route_codex reviewer pi
    [ -z "$PROFILE_VETO" ] || die "cel run reviewer: $PROFILE_VETO"
    model="$PROFILE_MODEL"
  else
  [ "$role" != reviewer ] || {
    local reviewer_model_id reviewer_models=""
    case "$model" in
      sonnet|opus)
        gateway_installed || die "cel run reviewer: no gateway on this box - cel gateway install"
        gateway_ready || die "cel run reviewer: the gateway is not answering on $(gateway_url) - cel gateway status"
        reviewer_models="$(gateway_models_json)" \
          || die "cel run reviewer: cannot read model ids from the configured gateway"
        reviewer_model_id="$(_run_reviewer_catalog_model "$model" "$reviewer_models")"
        [ -n "$reviewer_model_id" ] \
          || die "cel run reviewer: gateway catalog advertises no Claude Sonnet model"
        PROFILE_MODEL="ompgw-claude/$reviewer_model_id"
        ;;
      ompgw-claude/*) PROFILE_MODEL="$model" ;;
      ompgw/claude/*) PROFILE_MODEL="ompgw-claude/${model#ompgw/claude/}" ;;
      claude/*) PROFILE_MODEL="${model#claude/}" ;;
      claude-*) PROFILE_MODEL="$model" ;;
      *) die "cel run reviewer: model '$model' is unsupported; use sonnet, opus, an advertised Claude model id, or a gateway Codex model (e.g. gpt-6.1-sol)" ;;
    esac
    PROFILE_WSDIR="$wsdir"
    PROFILE_VIA=gateway
    _profile_gateway_route reviewer
    [ -z "$PROFILE_VETO" ] || die "cel run reviewer: $PROFILE_VETO"
    reviewer_model_id="${PROFILE_MODEL#ompgw-claude/}"
    [ -n "$reviewer_model_id" ] \
      || die "cel run reviewer: model '$model' has no Claude model id"
    if [ -z "$reviewer_models" ]; then
      reviewer_models="$(gateway_models_json)" \
        || die "cel run reviewer: cannot read model ids from the configured gateway"
    fi
    if ! jq -e --arg id "$reviewer_model_id" \
      '[.data[]? | select(.id == $id)] | length > 0' \
      <<< "$reviewer_models" >/dev/null; then
      die "cel run reviewer: configured gateway does not advertise Claude model '$reviewer_model_id'"
    fi
    model="$PROFILE_MODEL"
  }
  fi

  local RUN_BODY
  if [ "$role" = member ]; then
    # The scope packet IS a member's role. No workspace policy block: that
    # block hands a product agent's authority (open PRs, land) to its reader.
    RUN_BODY="$(cat -- "$MEMBER_DIR/members/$member.md")" \
      || die "cel run member: cannot read the scope packet for $member"
  elif [ -n "$rolefile" ]; then
    RUN_BODY="$(ws_render_role "$wsdir" "$rolefile" "${product:-}")"
  else
    RUN_BODY="$(ws_policy_block "$wsdir")"
  fi
  local agent_name; agent_name="$(_run_agent_name "$alias_name")"
  [ -z "$lane" ] || RUN_BODY="$RUN_BODY
$(_run_lane_brief "$product" "$lane" "$agent_name")"
  # The facts about THIS pull request ride with the role body rather than
  # waiting for an orchestrator to type them.
  if [ "$role" = "reviewer" ] && [ "$dry_run" -eq 0 ]; then
    RUN_BODY="$RUN_BODY
$(_run_reviewer_brief "$repo" "$pr" "$review_head" "$review_base" "$review_path")$(_run_reviewer_solo_brief "$wsdir" "$repo" "$pr" "$review_focus" "$review_kind")"
  fi
  # An extra reviewer's focus pack rides on the same role, after it: the
  # pack narrows what it judges, never what it may do. A QA agent's brief
  # (how to run this head, where its evidence goes) carries its qa pack.
  if [ "$review_kind" = qa ]; then
    RUN_BODY="$RUN_BODY
$(_run_qa_brief "$wsdir" "$repo" "$pr" "$review_focus" "${review_head:-<the head of $repo#$pr at launch>}")"
  elif [ -n "$review_focus" ]; then
    RUN_BODY="$RUN_BODY
$(_run_reviewer_focus_brief "$repo" "$pr" "$review_focus")"
  fi

  local AGENT_ARGS=() AGENT_ROLE_FILE="" bodyfile
  bodyfile="$(_run_role_file "$wsdir" "$tag" "${product:-}")"
  # A lane's role file stands in its own directory, or it would overwrite the
  # main agent's (role-*.md, the shape lib/gc.sh recognises).
  [ -z "$lane" ] || bodyfile="$cwd/role-solo.md"
  # ONE ROLE FILE PER PULL REQUEST. The body carries a head SHA, so a shared
  # $ws/.cel/role-reviewer.md would have two reviewers reading each other's
  # brief. The name still ENDS in role-reviewer.md: lib/gc.sh tells a
  # long-lived agent from a stray one by that substring. A QA agent's is
  # qa-<focus>.role-reviewer.md: it runs as a reviewer.
  if [ "$role" = "reviewer" ]; then
    bodyfile="$wsdir/.cel/reviews/pr-$pr/${review_focus:+$review_focus.}role-reviewer.md"
    [ "$review_kind" != qa ] || bodyfile="$wsdir/.cel/reviews/pr-$pr/$(review_slot "$review_focus" qa).role-reviewer.md"
  fi
  [ "$role" = member ] && bodyfile="$MEMBER_DIR/members/$member.role-member.md"
  if [ "$runtime" = opencode ] && [ "${PROFILE_VIA:-}" = gateway ]; then
    # Do not overwrite another implicit product's shared role file.
    bodyfile="$wsdir/.cel/opencode/$agent_name/role-$tag.md"
    # Admit only the requested tuple in this existing private canonical grant,
    # before role writes or native-holder stop. Selection stays native/TUI-owned.
    opencode_validate_requested_selection "$wsdir" "$tag" "$bodyfile" "${bodyfile%.md}.opencode.json" "$model" "$thinking" \
      || die 'cel run: requested OpenCode model/variant is not granted by the private canonical scope'
  fi
  if [ -n "$handoff" ]; then
    [ "$runtime" = opencode ] && [ "$fresh" = 1 ] && [[ "$handoff" = /* ]] && [ -s "$handoff" ] \
      || die 'cel run: --handoff requires a fresh OpenCode session and an existing absolute handoff file'
  fi
  _run_agent_args "$runtime" "$tag" "$RUN_BODY" "$dry_run" "$wsdir" "$bodyfile"

  # Model and thinking flags ride ahead of the role injection, spelled the way
  # THIS runtime spells them (agents.yaml model_flag / thinking).
  local -a PROFILE_ARGS=()
  profile_launch_args "$runtime" "$model" "$thinking" "${PROFILE_ISOLATE:-}"
  [ "${#PROFILE_ARGS[@]}" -eq 0 ] || AGENT_ARGS=("${PROFILE_ARGS[@]}" "${AGENT_ARGS[@]}")
  if [ -n "$handoff" ]; then
    AGENT_ARGS+=(--prompt "Read the complete migration handoff at $handoff before acting. This is a NEW OpenCode-native session, not a native resume of the archived OMP history. Preserve the model, account route, approvals, data and dirty work in that handoff. Never dump environments, credentials, resolved provider configs or full debug/config responses: use explicit non-secret identity allowlists only. Acknowledge intake through cel inbox, then wait for core to release the migration hold.")
  fi

  # THE GUARD HOOK. Root, product agents, team members and reviewers get the
  # runtime's guard hook, so a refused command is refused at the tool call
  # (lib/guard.sh: root is read-only over
  # repositories, a solo agent may not merge by hand or start other agents, a
  # member stays inside its team's scope, and a reviewer - guarded as `other`
  # - reads no token and runs no `cel run member`). Enforced here, not
  # requested in the role text: a prompt is not a guard.
  case "$role" in
    root|orchestrator|member|reviewer)
      local gflag gfile
      gflag="$(agent_guard_hook "$runtime" flag)"; gfile="$(agent_guard_hook "$runtime" file)"
      if [ -n "$gflag" ] && [ -n "$gfile" ]; then
        AGENT_ARGS=("$gflag" "$CEL_ROOT/$gfile" "${AGENT_ARGS[@]}")
      fi
      ;;
  esac
  # Add runtime-specific inbox extension args to every role: reviewers and
  # their authors trade findings by mail. Claude's global UserPromptSubmit and
  # launch-time Stop hooks are configured elsewhere.
  _run_inbox_hook_args "$runtime"
  _run_keep_model_args "$runtime"
  _run_retry_overlay_args "$runtime" "$role"

  # Runtime-wide launch flags (agents.yaml launch_args) go ahead of the
  # role-injection args on every launch of that runtime.
  local -a launch_args=()
  mapfile -t launch_args < <(agent_launch_args "$runtime")
  [ "${#launch_args[@]}" -eq 0 ] || AGENT_ARGS=("${launch_args[@]}" "${AGENT_ARGS[@]}")

  local envprefix; local inbox_me="" ; local -a LAUNCH_ENV_EXTRA=()
  case "$role" in
    root) inbox_me=root ;;
    orchestrator) inbox_me="$product-orch"; [ -z "$lane" ] || inbox_me="$agent_name"
      # Which product (and lane) the pane belongs to, said outright: a lane's
      # mailbox name does not end in -orch, so nothing can derive it.
      LAUNCH_ENV_EXTRA=("CEL_PRODUCT=$product")
      [ -z "$lane" ] || LAUNCH_ENV_EXTRA+=("CEL_LANE=$lane") ;;
    # Pane alias is the reader identity, passed explicitly so delivery never
    # depends on the pane's cwd.
    # Its checkout is the one directory its git -C may name (lib/guard.sh).
    reviewer) inbox_me="$agent_name"; LAUNCH_ENV_EXTRA=("CEL_REVIEW_CHECKOUT=$(printf '%q' "$cwd")") ;;
    # A team member: its alias is its mailbox, and the guard reads its team
    # and role from these.
    member) inbox_me="$agent_name"
      LAUNCH_ENV_EXTRA=("CEL_PRODUCT=$product" "CEL_TEAM=$team" "CEL_TEAM_ROLE=$MEMBER_ROLE" "CEL_TEAM_MEMBER=$agent_name")
      # The one branch a builder may push (lib/guard.sh _guard_builder_push).
      [ "$MEMBER_ROLE" != builder ] || LAUNCH_ENV_EXTRA+=("CEL_TEAM_BRANCH=$MEMBER_BRANCH") ;;
  esac
  # A scrubbed helper (_run_launch_scrub) still needs the provider key its
  # profile authenticates with when it reaches a provider directly.
  local -a LAUNCH_ENV_KEEP=()
  local provider_key; provider_key="$(_run_provider_key_env "$model" "${PROFILE_VIA:-}")"
  [ -z "$provider_key" ] || LAUNCH_ENV_KEEP=("$provider_key")
  envprefix="$(_run_launch_env "$env_role" "$wsdir" "$AGENT_ROLE_FILE" "$inbox_me" "$runtime")"
  local dry_envprefix="$envprefix" prefix_required=0

  local resume_session="" restart_pane=""
  if [ "$role" = root ] || [ "$role" = orchestrator ]; then
    local RESUME_SESSION="" RESTART_PANE=""
    _run_resume_resolve "$role" "$agent_name" "$cwd" "$runtime" "$pane_opt" "$restart" "$fresh" "$force" "$dry_run" \
      "cel run $role${product:+ --product $product} --workspace $(ws_name "$wsdir")" \
      "or name and adopt it: cel ws up $(ws_name "$wsdir")" "$wsdir"
    resume_session="$RESUME_SESSION"; restart_pane="$RESTART_PANE"
  fi
  # The line a restart types or scripts is built for its pane's host.
  if _run_restart_backend "$restart_pane"; then
    envprefix="$(_run_launch_env "$env_role" "$wsdir" "$AGENT_ROLE_FILE" "$inbox_me" "$runtime")"
    dry_envprefix="$envprefix"
  fi
  local _REX_RELAUNCH=""
  [ "$role" != root ] && [ "$role" != orchestrator ] || _REX_RELAUNCH="$(_run_rex_relaunch)"
  # A Claude lane: trusted folder and, for a fresh session, a first turn (see
  # _run_claude_trust_dir and _run_lane_kickoff). Trust is recorded before
  # any pane exists, on every path below - new pane, Rex, restart in place -
  # and a failure to record it launches nothing.
  if [ -n "$lane" ] && [ "$runtime" = claude ]; then
    [ -n "$resume_session" ] || AGENT_ARGS+=("$(_run_lane_kickoff "$product" "$lane" "$agent_name")")
    if [ "$dry_run" -eq 1 ]; then
      printf 'set projects[%s].hasTrustDialogAccepted in %s\n' "$cwd" "$(_run_claude_config_file)"
    else
      mkdir -p "$cwd"
      _run_claude_trust_dir "$cwd" \
        || die "cel run solo --lane: could not record Claude Code's folder trust for $cwd in $(_run_claude_config_file) (its lock $(_run_claude_config_file).lock is held, or the file is not a JSON object) - nothing was launched; re-run once Claude Code has finished writing it"
    fi
  fi
  # A Claude member too: its directory is new to Claude Code, and its first
  # turn says to acknowledge and start (the scope packet is its role). Other
  # runtimes' inbox extensions wake an idle session on mail.
  if [ "$role" = member ] && [ "$runtime" = claude ]; then
    AGENT_ARGS+=("You have just started as $agent_name, $MEMBER_ROLE on team $team. Your role above is your scope packet and task. Run cel team ack $team now, then start on the task; mail already waiting in your inbox is attached to this message.")
    if [ "$dry_run" -eq 1 ]; then
      printf 'set projects[%s].hasTrustDialogAccepted in %s\n' "$cwd" "$(_run_claude_config_file)"
    else
      _run_claude_trust_dir "$cwd" \
        || die "cel run member: could not record Claude Code's folder trust for $cwd in $(_run_claude_config_file) - nothing was launched"
    fi
  fi

  # THROUGH THE GATEWAY. A `via: gateway` profile reaches this box's gateway,
  # which picks a subscription BY SESSION KEY; pi sends no session identity of
  # its own, so a provider `headers` entry reads it from the environment:
  #
  # OMP_GATEWAY_TOKEN is resolved in the pane from the file-backed CLIProxyAPI
  # key, for pi and omp alike (omp: the celgw provider in models.yml).
  # CEL_SESSION_ID is the balancer's key. One agent, one key, one account
  # for its life; the next agent may land on another.
  local -a GATEWAY_ENV=()
  local affinity=""
  # A new OpenCode controller must not inherit core's gateway affinity.
  # Its stable unique agent name also retains this route on native restart.
  [ "$runtime" != opencode ] || [ "${PROFILE_VIA:-}" != gateway ] || affinity="$agent_name"
  _run_profile_gateway_setup "$runtime" "$agent_name" "$((1 - dry_run))" "$((1 - dry_run))" "$affinity"
  if [ "${#GATEWAY_ENV[@]}" -gt 0 ]; then
    prefix_required=1
    envprefix="$(_run_launch_env "$env_role" "$wsdir" "$AGENT_ROLE_FILE" "$inbox_me" "$runtime")"
    dry_envprefix="$(GATEWAY_ENV=("OMP_GATEWAY_TOKEN=****" "CEL_SESSION_ID=****"); _run_launch_env "$env_role" "$wsdir" "$AGENT_ROLE_FILE" "$inbox_me" "$runtime")"
  fi

  # The terminal host is independent of runtime/profile/model. Existing
  # sessions keep their host; selecting Rex affects new sessions only.
  if [ -n "$restart_pane" ]; then
    _run_restart_in_place "$role" "$restart_pane" "$label" "$envprefix" "$dry_envprefix" "$prefix_required" \
      "$dry_run" "$agent_name" "$runtime" "$cwd"
    local rc=$?
    [ "$rc" = 0 ] || return "$rc"
    [ -z "$lane" ] || _run_lane_choices_commit "$cwd" "$lane_profile_explicit" "$lane_model_explicit" "$runtime" "$dry_run"
    return $?
  fi
  if [ "$session_backend" = rex ]; then
    # ONE SESSION GROUP PER PRODUCT: a reviewer or team member opens as a
    # window (labelled with its alias, never focused) in its product agent's
    # own Rex session - the team's lead (team.json `lead`), else <product>-orch
    # - when that session is proven live (lib/rex.sh _rex_host_session);
    # otherwise in a session of its own, as before, and says so.
    local _REX_HOST="" _REX_TEAM="" host_session=""
    case "$role" in
      reviewer) _REX_HOST="$(cel_alias_norm "$(ws_product_of_repo "$wsdir" "$repo")-orch")" ;;
      member)
        _REX_TEAM="$team"
        _REX_HOST="$(jq -r '.lead // "" | strings' "$MEMBER_DIR/team.json" 2>/dev/null)"
        [ -n "$_REX_HOST" ] || _REX_HOST="$(cel_alias_norm "$product-orch")" ;;
    esac
    if [ "$dry_run" = 1 ]; then
      [ -z "$_REX_HOST" ] || host_session="$(_rex_host_session "$_REX_HOST" "$wsdir")" || host_session=""
      # The exact line the private script runs, secret words masked.
      local dry_line; dry_line="$(_rex_launch_line "$runtime" "$dry_envprefix" "$runtime" run)"
      if [ -n "$host_session" ]; then
        printf 'rex window new -s %s %s --cwd %s --shell=none --focus=false -- <private launch script: %s%s>\n' \
          "$host_session" "$agent_name" "$cwd" "$dry_line" "$(_run_dry_agent_args)"
      else
        [ -z "$_REX_HOST" ] || printf '(%s has no provable live Rex session: %s opens in a session of its own)\n' "$_REX_HOST" "$agent_name"
        printf 'rex new %s --cwd %s --shell=none -- <private launch script: %s%s>\n' "$agent_name" "$cwd" "$dry_line" "$(_run_dry_agent_args)"
      fi
      return 0
    fi
    _rex_preflight "$agent_name" "$runtime"
    mkdir -p "$cwd"
    _rex_launch "$agent_name" "$runtime" "$cwd" "$label" "$envprefix" "${AGENT_ARGS[@]}" || return $?
    [ -z "$lane" ] || _run_lane_choices_commit "$cwd" "$lane_profile_explicit" "$lane_model_explicit" "$runtime" "$dry_run" || return $?
    if [ "$role" = reviewer ]; then
      reviewers_record "$wsdir" "$repo" "$pr" "$_REX_PANE" "$agent_name" "$review_path" "$repodir" "$review_head" "$review_focus" "$review_kind"
    fi
    # A member is reported up only once the inventory shows that exact agent
    # in that terminal; exit 3 as for herdr below.
    if [ "$role" = member ]; then
      if ! _run_member_confirm "$agent_name" "$_REX_PANE"; then
        c_err "cel run member: $agent_name was started in Rex terminal $_REX_PANE but the agent inventory does not show it there - its launch is unconfirmed; look at it before anything relaunches it"
        return 3
      fi
      printf 'member %s pane %s\n' "$agent_name" "$_REX_PANE"
    fi
    return 0
  fi

  # A team member joins its feature's tab ("team <feature>") in the caller's -
  # the lead's - view, and is reported up only once the inventory shows that
  # exact agent in that pane. Exit 3: started, not confirmed - the caller
  # keeps the member reserved and never relaunches it blindly.
  if [ "$role" = member ]; then
    if [ "$dry_run" -eq 1 ]; then
      printf 'herdr tab "team %s": split its largest pane, or a new tab per %s panes\n' "$team" "$_RUN_REVIEW_TAB_CAP"
      printf 'herdr pane send-text <pane> %s\n' "$dry_envprefix"
      printf 'herdr agent start %s --kind %s --pane <pane> -- %s\n' \
        "$agent_name" "$runtime" "$(_run_dry_agent_args)"
      return 0
    fi
    have herdr || die "cel run: herdr is not on PATH"
    have jq    || die "cel run: jq is not on PATH"
    local member_pane; member_pane="$(_run_tab_pane "team $team" "$cwd" member)"
    pane_label_set "$member_pane" "$label"
    _run_mark_launch "$member_pane" "$envprefix" "$prefix_required"
    _run_agent_start "$member_pane" "$agent_name" "$runtime" "${AGENT_ARGS[@]}"
    if ! _run_member_confirm "$agent_name" "$member_pane"; then
      c_err "cel run member: $agent_name was started in pane $member_pane but the agent inventory does not show it there - its launch is unconfirmed; look at the pane before anything relaunches it"
      return 3
    fi
    printf 'member %s pane %s\n' "$agent_name" "$member_pane"
    return 0
  fi

  # Reviewer panes join the caller's own view instead of creating one.
  if [ "$role" = "reviewer" ]; then
    if [ "$dry_run" -eq 1 ]; then
      printf 'git worktree add --detach %s <head of %s#%s>\n' "$review_path" "$repo" "$pr"
      printf 'herdr tab "PR reviewer": split its largest pane, or a new tab per %s panes\n' "$_RUN_REVIEW_TAB_CAP"
      printf 'herdr pane send-text <pane> %s\n' "$dry_envprefix"
      printf 'herdr agent start %s --kind %s --pane <pane> -- %s\n' \
        "$agent_name" "$runtime" "$(_run_dry_agent_args)"
      return 0
    fi
    have herdr || die "cel run: herdr is not on PATH"
    have jq    || die "cel run: jq is not on PATH"
    local pane_id; pane_id="$(_run_tab_pane "PR reviewer" "$cwd" reviewer)"
    pane_label_set "$pane_id" "$label"
    _run_mark_launch "$pane_id" "$envprefix" "$prefix_required"
    _run_agent_start "$pane_id" "$agent_name" "$runtime" "${AGENT_ARGS[@]}"
    # Recorded AFTER the launch: a row for a pane that never started is a row
    # `cel gc` would carry forever. A failed record is a warning, not a
    # failure - the reviewer is alive and reviewing either way.
    reviewers_record "$wsdir" "$repo" "$pr" "$pane_id" "$agent_name" "$review_path" "$repodir" "$review_head" "$review_focus" "$review_kind" \
      || c_warn "could not record the $rv_who - cel gc will not close it, and its checkout at $review_path will outlive it"
    return 0
  fi

  # A declared product's directory is cel's to make: it is not a checkout,
  # so nothing else ever creates it and herdr would refuse a missing cwd.
  if [ "$role" = "orchestrator" ] && [ "$dry_run" -eq 0 ] \
     && { [ -n "$lane" ] || ws_product_declared "$wsdir" "$product"; }; then
    mkdir -p "$cwd"
  fi
  local -a CREATE_ARGS=(workspace create --cwd "$cwd" --label "$alias_name")

  # Root mode is the workspace's whole working view, so it also applies the
  # workspace's declared herdr layout (services, watch panes, ...) - the other
  # modes are single panes inside views that already exist.
  local layout=""
  [ "$role" = "root" ] && layout="$(ws_layout "$wsdir")"

  if [ "$dry_run" -eq 1 ]; then
    printf 'herdr %s\n' "${CREATE_ARGS[*]}"
    [ -n "$layout" ] && printf 'herdr-workspace-manager apply %s\n' "$layout"
    # Values MASKED: the session id is not a secret but the bearer beside it
    # is, and a preview that prints one teaches people to paste both.
    printf 'herdr pane send-text <pane> %s\n' "$dry_envprefix"
    printf 'herdr agent start %s --kind %s --pane <pane> -- %s\n' \
      "$agent_name" "$runtime" "$(_run_dry_agent_args)"
    return 0
  fi

  have herdr || die "cel run: herdr is not on PATH"
  have jq    || die "cel run: jq is not on PATH"

  local resp ws_id pane_id
  resp="$(herdr "${CREATE_ARGS[@]}")"
  ws_id="$(printf '%s' "$resp" | jq -r '.. | .workspace_id? // empty' | head -1)"
  pane_id="$(printf '%s' "$resp" | jq -r '.. | .pane_id? // empty' | head -1)"
  [ -n "$pane_id" ] && [ "$pane_id" != "null" ] || pane_id="${ws_id}:p1"

  if [ -n "$layout" ]; then
    pane_id="$(_run_apply_layout "$layout" "$ws_id" "$wsdir" "$pane_id")"
  fi


  pane_label_set "$pane_id" "$label"
  # A declared layout titles its own tabs; overwriting one would undo that.
  [ -n "$layout" ] || tab_label_set "$pane_id" "$label"

  # Role and gateway environment are typed on the launch line before Herdr
  # starts the agent, so exports live in the shell that execs the runtime.
  _run_mark_launch "$pane_id" "$envprefix" "$prefix_required"
  _run_agent_start "$pane_id" "$agent_name" "$runtime" "${AGENT_ARGS[@]}" || return $?
  [ -z "$lane" ] || _run_lane_choices_commit "$cwd" "$lane_profile_explicit" "$lane_model_explicit" "$runtime" "$dry_run"
}

# THE PROCESS IN A PANE is found DOWNWARD from the pane's own shell (herdr names
# its pid): the runtime binary as argv[0], standing in the pane's cwd. Nothing
# above the shell is consulted - an ancestor like `systemd --user` is every pane's.
#
# BUILTINS ONLY in the walk. `cel fleet` reads this for every orchestrator on
# every console refresh, within a spawn budget (tests/fleet.test.sh): the cwd is
# compared with `-ef`, argv and PPid are read with `read`.
_run_ppid() { # <pid> -> sets _RUN_PPID
  local k v
  _RUN_PPID=""
  while IFS=$':\t ' read -r k v; do
    if [ "$k" = PPid ]; then _RUN_PPID="${v//[!0-9]/}"; return 0; fi
  done < "$(_run_proc_root)/$1/status" 2>/dev/null || true
}

_run_descends() { # <pid> <ancestor> -> sets _RUN_DEPTH (hops up to it)
  local p="$1" i=0
  _RUN_DEPTH=""
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$i" -lt 64 ]; do
    if [ "$p" = "$2" ]; then _RUN_DEPTH="$i"; return 0; fi
    _run_ppid "$p"; p="$_RUN_PPID"; i=$((i+1))
  done
  return 1
}

# The pid, in _RUN_PID, or the reason it could not be found, in _RUN_WHY.
# One `herdr pane process-info` is the only process this starts.
#
# THIS IS THE ONE ANSWER to "which process is this pane's orchestrator":
# `cel update --check`, --restart-orchestrators, doctor, the steward's repair
# and the console all ask it. It takes the runtime process NEAREST the pane's
# shell, newest pid only between equals: omp's own helpers are omp too.
_run_pane_pid() { # <pane> <cwd> <runtime>
  local info shell d pid a0 a1 best=""
  _RUN_PID=""; _RUN_WHY=""
  case "$1" in rex/*)
    local f
    for f in "$(_rex_state)"/*.json; do
      [ -f "$f" ] || continue
      [ "$(jq -r .pane_id "$f")" = "$1" ] || continue
      [ "$(jq -r .agent "$f")" = "$3" ] && [ "$(jq -r .cwd "$f")" = "$2" ] \
        && [ "$(jq -r .backend "$f")" = rex ] || continue
      if _rex_live "$f"; then _RUN_PID="$(jq -r .pid "$f")"; return 0; fi
    done
    _RUN_WHY="no verified live process for Rex terminal $1"; return 1 ;;
  esac
  info="$(herdr pane process-info --pane "$1" 2>/dev/null)" || info=""
  if [[ "$info" =~ \"shell_pid\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then shell="${BASH_REMATCH[1]}"; else shell=""; fi
  if [ -z "$shell" ]; then _RUN_WHY="herdr gives no shell pid for pane $1"; return 1; fi
  for d in "$(_run_proc_root)"/[0-9]*; do
    pid="${d##*/}"
    [ "$pid" != "$shell" ] || continue
    [ -r "$d/cmdline" ] || continue
    a0=""; a1=""
    { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } < "$d/cmdline" 2>/dev/null || true
    [ "${a0##*/}" = "$3" ] || continue
    # omp's own helpers (js-eval worker, daemon broker) are omp too, share the
    # cwd and carry no flags. Nearest-wins only protects when the real agent
    # also matches; when it does not, a helper alone read as "missing every
    # flag". A helper is never the orchestrator, so it is never a candidate.
    case "$a1" in __omp_worker*) continue ;; esac
    [ "$d/cwd" -ef "$2" ] || continue
    _run_descends "$pid" "$shell" || continue
    if [ -z "$_RUN_PID" ] || [ "$_RUN_DEPTH" -lt "$best" ] \
       || { [ "$_RUN_DEPTH" -eq "$best" ] && [ "$pid" -gt "$_RUN_PID" ]; }; then
      _RUN_PID="$pid"; best="$_RUN_DEPTH"
    fi
  done
  if [ -z "$_RUN_PID" ]; then _RUN_WHY="no readable $3 process in $2 under pane $1"; return 1; fi
  return 0
}

_run_now() { printf -v _RUN_NOW '%(%s)T' -1; }

# How long an orchestrator has been in its status. herdr says what the status
# is, not since when, so the first read that saw it is remembered. Read and
# rewritten with builtins, for the same budget.
_run_status_since() { # <name> <ws> <status> -> sets _RUN_SINCE
  local f n w st t keep="" found=""
  f="${CEL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cel}/orch-status.tsv"; _run_now
  if [ -f "$f" ]; then
    while IFS=$'\t' read -r n w st t; do
      [ -n "$n" ] || continue
      if [ "$n" = "$1" ] && [ "$w" = "$2" ]; then
        [ "$st" = "$3" ] && found="$t"
        continue
      fi
      keep="$keep$n	$w	$st	$t
"
    done < "$f"
  fi
  _RUN_SINCE="${found:-$_RUN_NOW}"
  [ -z "$found" ] || return 0
  [ -d "${f%/*}" ] || mkdir -p "${f%/*}" 2>/dev/null || return 0
  printf '%s%s\t%s\t%s\t%s\n' "$keep" "$1" "$2" "$3" "$_RUN_SINCE" > "$f" 2>/dev/null || true
}

_run_build() { # -> sets _RUN_BUILD once per process
  [ -z "${_RUN_BUILD:-}" ] || return 0
  local h=""
  if [ -f "$CEL_ROOT/.git" ] || [ -d "$CEL_ROOT/.git" ]; then
    _RUN_BUILD="$(git -C "$CEL_ROOT" rev-parse HEAD 2>/dev/null || true)"
  fi
  [ -n "${_RUN_BUILD:-}" ] || { read -r h < "$CEL_ROOT/VERSION" 2>/dev/null || true; _RUN_BUILD="${h:-unknown}"; }
}

# Capture the canonical dry-run's resolved runtime and argv, not its display
# shell syntax. Both terminal renderers call this formatter after role/profile
# resolution; overriding it inside this subshell cannot affect a real launch.
_run_expected_launch() ( # file ws role product backend
  local target="$1" ws="$2" launch_role="$3" product="$4" backend="$5"
  # The shared YAML parser keys on metadata; isolate a plan's parse so a
  # same-size/same-timestamp routing edit cannot survive a verdict cache miss.
  local CEL_YAML_CACHE CEL_MANIFEST_CACHE wsdir
  CEL_YAML_CACHE="$(mktemp -d)" || return 1
  CEL_MANIFEST_CACHE="$CEL_YAML_CACHE/manifest"
  export CEL_YAML_CACHE CEL_MANIFEST_CACHE
  trap 'rm -rf -- "$CEL_YAML_CACHE"' EXIT
  wsdir="$(registry_path "$ws")" || return 1
  if [ "$launch_role" = orchestrator ] && [ "$(ws_build_mode "$wsdir" "$product")" = solo ]; then launch_role=solo; fi
  _run_dry_agent_args() { printf '%s\0' "$runtime" "${AGENT_ARGS[@]}" > "$target"; }
  if [ "$launch_role" = root ]; then
    cmd_run root --workspace "$ws" --fresh --force --dry-run --session-backend "$backend"
  else
    cmd_run "$launch_role" --product "$product" --workspace "$ws" --fresh --force --dry-run --session-backend "$backend"
  fi
)

# A routing edit, argv rewrite or reused PID invalidates a same-build row.
_run_verdict_signature() { # wsdir pid runtime backend
  local -a inputs=("$1/workspace.yaml" "${CEL_MANIFEST:-$CEL_ROOT/agents.yaml}" "$CEL_ROOT/lib/run.sh") pid_fields=()
  [ ! -f "$1/workspace.local.yaml" ] || inputs+=("$1/workspace.local.yaml")
  inputs+=("$(_run_proc_root)/$2/cmdline")
  local checksum stat="" start=unknown
  if IFS= read -r stat < "$(_run_proc_root)/$2/stat" 2>/dev/null; then
    read -r -a pid_fields <<< "${stat##*) }"; start="${pid_fields[19]:-unknown}"
  fi
  checksum="$(cksum "${inputs[@]}" 2>/dev/null)" || return 1
  printf '%s:%s:%s:%s' "$3" "$4" "$start" "${checksum//$'\n'/;}"
}

# Current describes an observable launch matching the effective product plan,
# not a fresh test of its hooks. Rewritten argv stays explicitly unknown.
_run_orch_verdict() { # ws role product name pane cwd runtime
  local ws="$1" role="$2" p="$3" name="$4" pane="$5" cwd="$6" rt="$7"
  local -a argv
  local vfile k1 k2 k3 k4 l d saved_signature keep="" signature wsdir backend launch_role
  local i exp act missing expected_rt
  _RUN_LAUNCH=unknown; _RUN_DETAIL=""; _RUN_MODEL="-"
  if ! _run_pane_pid "$pane" "$cwd" "$rt"; then _RUN_DETAIL="$_RUN_WHY"; return 0; fi
  wsdir="$(registry_path "$ws" 2>/dev/null)" || { _RUN_DETAIL="workspace routing is unreadable"; return 0; }
  backend=herdr; case "$pane" in rex/*) backend=rex ;; esac
  launch_role="$role"
  signature="$(_run_verdict_signature "$wsdir" "$_RUN_PID" "$rt" "$backend")" \
    || { _RUN_DETAIL="launch evidence is unreadable"; return 0; }
  run_runtime_evidence "$rt" "$name" "$pane" "$cwd" "$_RUN_PID"
  if [ "$RUN_EVIDENCE_ARGV" != observable ]; then
    _RUN_DETAIL="$RUN_EVIDENCE_DETAIL; pid $_RUN_PID; launch flags and guard registration unverified"
    return 0
  fi
  argv=("${RUN_EVIDENCE_ARGV_VALUES[@]}")
  for ((i = 0; i < ${#argv[@]} - 1; i++)); do
    [ "${argv[$i]}" = --model ] && _RUN_MODEL="${argv[$((i+1))]}"
  done
  if [ "$signature" != "$(_run_verdict_signature "$wsdir" "$_RUN_PID" "$rt" "$backend")" ]; then
    _RUN_DETAIL="routing or process evidence changed during observation"; return 0
  fi
  _run_build
  vfile="${CEL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cel}/orch-verdicts.tsv"
  if [ -f "$vfile" ]; then
    while IFS=$'\t' read -r k1 k2 k3 k4 l d saved_signature; do
      [ -n "$k1" ] || continue
      if [ "$k2" = "$ws" ] && [ "$k3" = "$name" ]; then
        if [ "$k1" = "$_RUN_BUILD" ] && [ "$k4" = "$_RUN_PID" ] && [ "$saved_signature" = "$signature" ]; then
          _RUN_LAUNCH="$l"; _RUN_DETAIL="${d#-}"; return 0
        fi
        continue
      fi
      keep="$keep$k1	$k2	$k3	$k4	$l	$d	$saved_signature
"
    done < "$vfile"
  fi
  exp="$(mktemp)"; act="$(mktemp)"
  if ! _run_expected_launch "$exp" "$ws" "$launch_role" "$p" "$backend" >/dev/null 2>&1 || [ ! -s "$exp" ]; then
    rm -f -- "$exp" "$act"; _RUN_DETAIL="canonical $launch_role/$backend launch plan is unavailable"; return 0
  fi
  IFS= read -r -d '' expected_rt < "$exp"
  printf '%s\0' "${argv[@]}" > "$act"
  if [ "$expected_rt" != "$rt" ]; then
    missing="runtime $rt differs from configured $expected_rt ($launch_role/$backend)"
  else
    missing="$(run_launch_diff "$exp" "$act")"
  fi
  rm -f -- "$exp" "$act"
  if [ "$signature" != "$(_run_verdict_signature "$wsdir" "$_RUN_PID" "$rt" "$backend")" ]; then
    _RUN_DETAIL="routing or process evidence changed during observation"; return 0
  fi
  if [ -n "$missing" ]; then _RUN_LAUNCH=stale; _RUN_DETAIL="$missing; read from pid $_RUN_PID"; else _RUN_LAUNCH=current; fi
  [ -d "${vfile%/*}" ] || mkdir -p "${vfile%/*}" 2>/dev/null || return 0
  printf '%s%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$keep" "$_RUN_BUILD" "$ws" "$name" "$_RUN_PID" "$_RUN_LAUNCH" "${_RUN_DETAIL:--}" "$signature" > "$vfile" 2>/dev/null || true
}

# EVERY ROOT/ORCHESTRATOR AND ITS LAUNCH LINE. A running orchestrator keeps the
# command line it started with, so hooks and flags `cel update` changes do not
# reach it; each live one's actual argv is compared with what `cel run --dry-run`
# would launch now.
#
# The candidates and their live agents come from ONE jq per workspace over the
# workspace's JSON and the roster - the same program `cel fleet` runs, so the
# console and `cel update` cannot disagree about who is which.
#
# One row per root/orchestrator, live or (for an `auto` product) missing:
#   name ws pane status since model launch detail cmd role product
# launch is current | stale | unknown | missing; detail is the diff, the reason
# it is unknown, or why it is missing. `-` stands for empty. The command is for
# humans to read; callers that run it rebuild the argv from role/ws/product.
run_orchestrator_candidates() { # <ws> <wsdir> <roster-json>
  local yj
  yj="$(_yaml_json "$2/workspace.yaml")" || return 0
  jq -r --arg ws "$1" --arg wsdir "$2" --arg deflt "$(ws_orchestrators_default)" --argjson roster "${3:-null}" '
    def agent_name: ascii_downcase | gsub("[^a-z0-9_-]+"; "-") | sub("^[^a-z]+"; "") | sub("-$"; "") | .[0:32];
    def dash: if . == null or . == "" then "-" else . end;
    . as $y
    | ([$roster.result.agents[]? | select((.pane_id // "") != "")]) as $a
    | ($y.products // []) as $ps
    | ([$ps[].repos // []] | flatten) as $used
    | (($ps | map(.name)) + (($y.repos // [] | map(.name)) - $used)) as $names
    | ($y.layout | if type == "object" then (.orchestrators // "") else "" end) as $lay
    | ([{role: "root", product: "-", name: ("\($ws)/root" | agent_name), cwd: $wsdir,
         rt: ($y.runtime.root // "claude"), mode: "root"}]
       + [$names[] as $p
          | ($ps | map(select(.name == $p))[0]) as $decl
          | {role: "orchestrator", product: $p, name: ("\($p)/orch" | agent_name),
             cwd: (if $decl then "\($wsdir)/products/\($p)" else "\($wsdir)/repos/\($p)" end),
             rt: ($y.runtime.orchestrator // "claude"),
             mode: ((($decl // {}).orchestrator // "") as $own
                    | if ($own | IN("auto", "manual", "none")) then $own
                      elif ($lay | IN("auto", "manual", "none")) then $lay else $deflt end)}])[]
    | . as $c
    | ([$a[] | select(.name == $c.name)]) as $byname
    | ([$a[] | select((.cwd // "") == $c.cwd)]) as $bycwd
    # by name; cwd only when exactly one agent stands there
    | (if ($byname | length) > 0 then $byname[0] elif ($bycwd | length) == 1 then $bycwd[0] else null end) as $l
    | [$c.role, $c.product, $c.name, $c.cwd, $c.mode,
       (if $l then "live" else "-" end),
       ($l.name | dash), ($l.pane_id | dash), (($l.agent_status // "unknown") | dash),
       (($l.agent // $c.rt) | dash), ($l.cwd | dash), ($l.agent_session.value | dash)]
    | @tsv' "$yj" 2>/dev/null || true
}

run_orchestrator_rows() { # [only-ws] [roster-json] [record-sessions 1|0] [wsdir of only-ws] [its candidates]
  local roster ws wsdir role p name cwd mode live lname lpane lstatus rt lcwd lsession cmd
  have jq || return 0
  roster="${2:-}"
  [ -n "$roster" ] || roster="$(cel_agent_list 2>/dev/null)" || return 0
  [ -n "$roster" ] || return 0
  for ws in ${1:-$(registry_names 2>/dev/null)}; do
    if [ -n "${4:-}" ]; then wsdir="$4"; else wsdir="$(registry_path "$ws" 2>/dev/null)" || continue; fi
    [ -f "$wsdir/workspace.yaml" ] || continue
    while IFS=$'\t' read -r role p name cwd mode live lname lpane lstatus rt lcwd lsession; do
      [ -n "$role" ] || continue
      if [ "$role" = root ]; then cmd="cel run root --workspace $ws --restart"
      else cmd="cel run orchestrator --product $p --workspace $ws --restart"; fi
      if [ "$live" != live ]; then
        # A product that should have an orchestrator and has none is a row
        # too: the view is for "which of mine are not right", and absent is
        # the least right of all. A product another login runs
        # (products[].home) is not missing here: it is not this box's.
        [ "$mode" = auto ] || continue
        [ "$role" != orchestrator ] || ws_product_home_check "$wsdir" "$p" >/dev/null || continue
        printf '%s\t%s\t-\tgone\t0\t-\tmissing\tmode auto, no live agent\t%s\t%s\t%s\n' \
          "$name" "$ws" "cel run orchestrator --product $p --workspace $ws" "$role" "$p"
        continue
      fi
      [ "${3:-1}" = 0 ] || [ "$lsession" = "-" ] || _run_sessions_record "$cwd" "$lsession" "${rt#-}"
      [ "$lname" != "-" ] || lname="$name"
      [ "$lcwd" != "-" ] || lcwd="$cwd"
      _run_status_since "$lname" "$ws" "$lstatus"
      _run_orch_verdict "$ws" "$role" "$p" "$lname" "$lpane" "$lcwd" "$rt"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lname" "$ws" "$lpane" "$lstatus" \
        "$_RUN_SINCE" "$_RUN_MODEL" "$_RUN_LAUNCH" "${_RUN_DETAIL:--}" "$cmd" "$role" "$p"
    done < <(if [ -n "${5:-}" ]; then printf '%s\n' "$5"; else run_orchestrator_candidates "$ws" "$wsdir" "$roster"; fi)
  done
  return 0
}

# One row per STALE root/orchestrator, for doctor and the steward:
#   name<TAB>workspace<TAB>diff<TAB>restart-command<TAB>status<TAB>role<TAB>product
run_stale_orchestrators() {
  local name ws pane status since model launch detail cmd role product
  while IFS=$'\t' read -r name ws pane status since model launch detail cmd role product; do
    [ "$launch" = stale ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$ws" "$detail" "$cmd" "$status" "$role" "$product"
  done < <(run_orchestrator_rows)
  return 0
}

# herdr relaunches an orchestrator as a bare `omp --resume=<file>` after a
# server restart - no hooks, no CEL_ env - so this uses the pane-shell walk
# above, which needs neither.
# Every live orchestrator and solo lane whose runtime takes an inbox hook, and
# whether it can hear its mail. One row each:
#   name<TAB>workspace<TAB>product<TAB>pane<TAB>status<TAB>ok|stripped|deaf|unknown<TAB>restart-command<TAB>lane
# stripped: the observable argv lacks the hook. deaf: the hook is in argv but
# no `cel inbox watch --parent <pid>` child is alive (run_evidence_deaf) - the
# watcher died and the session never brought it back. lane is `-` for the
# product's main agent. A process that cannot be found yields no row: no
# evidence is not a fault.
run_stripped_orchestrators() {
  local roster ws wsdir p name cwd live lane lname lpane lstatus rt lcwd
  have jq || return 0
  roster="$(cel_agent_list 2>/dev/null)" || return 0
  for ws in $(registry_names 2>/dev/null); do
    wsdir="$(registry_path "$ws" 2>/dev/null)" || continue
    [ -f "$wsdir/workspace.yaml" ] || continue
    for p in $(ws_product_names "$wsdir" 2>/dev/null); do
      name="$(_run_agent_name "$p/orch")"; cwd="$(ws_product_dir "$wsdir" "$p")"
      live="$(printf '%s' "$roster" | jq -r --arg n "$name" --arg c "$cwd" '
        [.result.agents[]? | select((.pane_id // "") != "")] as $a
        | [$a[] | select(.name == $n)] as $byname
        | [$a[] | select((.cwd // "") == $c)] as $bycwd
        | (if ($byname | length) > 0 then $byname[0]
           elif ($bycwd | length) == 1 then $bycwd[0] else empty end)
        | [((.name // "") | if . == "" then "-" else . end), .pane_id,
           (.agent_status // "unknown"), (.agent // ""), (.cwd // "")] | @tsv' 2>/dev/null)" || live=""
      if [ -n "$live" ]; then
        IFS=$'\t' read -r lname lpane lstatus rt lcwd <<< "$live"
        _run_inbox_row "$ws" "$wsdir" "$p" - "$name" "$cwd" "$lname" "$lpane" "$lstatus" "$rt" "$lcwd" \
          "cel run orchestrator --product $p --workspace $ws --restart"
      fi
      # Solo lanes: agents standing in .cel/solo/<product>/lane-<lane>.
      while IFS=$'\t' read -r lane lname lpane lstatus rt lcwd; do
        [ -n "$lane" ] || continue
        _run_inbox_row "$ws" "$wsdir" "$p" "$lane" "$(_run_agent_name "$p/$lane")" "$lcwd" "$lname" "$lpane" "$lstatus" "$rt" "$lcwd" \
          "cel run solo --product $p --lane $lane --workspace $ws --restart"
      done < <(printf '%s' "$roster" | jq -r --arg b "$(ws_solo_dir "$wsdir" "$p")/lane-" '
        .result.agents[]? | select((.pane_id // "") != "")
        | select((.cwd // "") | startswith($b) and (endswith(" (deleted)") | not))
        | (.cwd | ltrimstr($b)) as $lane | select($lane | test("^[a-z0-9]+(-[a-z0-9]+)*$"))
        | [$lane, ((.name // "") | if . == "" then "-" else . end), .pane_id,
           (.agent_status // "unknown"), ((.agent // "") | if . == "" then "-" else . end), .cwd] | @tsv' 2>/dev/null)
    done
  done
  return 0
}

_run_inbox_row() { # ws wsdir product lane|- name cwd lname lpane lstatus runtime lcwd restart-cmd
  local ws="$1" wsdir="$2" p="$3" lane="$4" name="$5" cwd="$6" lname="$7" lpane="$8" lstatus="$9"
  local rt="${10}" lcwd="${11}" cmd="${12}" hookfile state
  [ -z "$lcwd" ] || cwd="$lcwd"
  { [ -n "$rt" ] && [ "$rt" != - ]; } || rt="$(ws_runtime "$wsdir" orchestrator)"
  hookfile="$(agent_inbox_hook "$rt" file 2>/dev/null)" || hookfile=""
  [ -n "$hookfile" ] || return 0   # Claude uses launch-time UserPromptSubmit/Stop hooks, not this extension file
  _run_pane_pid "$lpane" "$cwd" "$rt" || return 0
  [ "$lname" != "-" ] || lname="$name"
  run_runtime_evidence "$rt" "$lname" "$lpane" "$cwd" "$_RUN_PID"
  state="$RUN_EVIDENCE_INBOX"
  # Only an argv-proven hook can be deaf; a bare Pi's ok IS its watcher.
  if [ "$state" = ok ] && [ "$RUN_EVIDENCE_ARGV" = observable ] && run_evidence_deaf "$_RUN_PID"; then
    state=deaf
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lname" "$ws" "$p" "$lpane" "$lstatus" "$state" "$cmd" "$lane"
}
