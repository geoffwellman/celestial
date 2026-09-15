# shellcheck shell=bash
# cel run - start an agent pane for a role, wired to a workspace via herdr.
# Architecture and trust boundaries: docs/architecture.md.
[ -n "${_CEL_RUN:-}" ] && return 0
_CEL_RUN=1
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/manifest.sh
. "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"
# shellcheck source=lib/profiles.sh
. "$(dirname "${BASH_SOURCE[0]}")/profiles.sh"

# Fills the global AGENT_ARGS array per the runtime's role_injection strategy
# in agents.yaml. File writes are real side effects, so they are skipped on a dry
# run - only the herdr command line is ever a preview.
_run_agent_args() { # <runtime> <tag> <body> <dry-run 0|1> <wsdir>
  local rt="$1" tag="$2" body="$3" dry="$4" wsdir="$5" strategy
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
      local file="$wsdir/.cel/role-$tag.md"
      if [ "$dry" -eq 0 ]; then
        mkdir -p "$wsdir/.cel"
        printf '%s\n' "$body" > "$file"
      fi
      AGENT_ARGS=("$(agent_injection "$rt" flag)" "$file")
      ;;
    prompt_arg)
      c_warn "runtime $rt injects the role as a prompt argument - it may not survive compaction"
      AGENT_ARGS=("$body")
      ;;
    agent_file)
      local dir file
      dir="$(expand "$(agent_injection "$rt" dir)")"
      file="$dir/cel-$tag.md"
      if [ "$dry" -eq 0 ]; then
        mkdir -p "$dir"
        { printf -- '---\ndescription: celestial plane %s (materialised by cel run)\n---\n' "$tag"
          printf '%s\n' "$body"; } > "$file"
      fi
      AGENT_ARGS=(--agent "cel-$tag")
      ;;
    *)
      die "cel run: runtime '$rt' has no known role_injection strategy"
      ;;
  esac
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

# Reviewer panes live in the CALLER's herdr view (the orchestrator runs this
# from its own pane), in tabs labelled "PR reviewer". Panes are smart-sized:
# each new reviewer splits the tab's current largest pane along its longer
# visual edge. Six panes fill a tab; the seventh PR opens a fresh
# "PR reviewer" tab and the count restarts. No new workspace, no worktree -
# the reviewer only reads.
_RUN_REVIEW_TAB_CAP=6
_run_reviewer_pane() { # <cwd> -> pane id
  local ws="${HERDR_WORKSPACE_ID:-}" cwd="$1" tab pane resp n first
  [ -n "$ws" ] || die "cel run reviewer: not inside a herdr pane (no HERDR_WORKSPACE_ID)"
  # newest "PR reviewer" tab: earlier ones are already full
  tab="$(herdr tab list --workspace "$ws" \
         | jq -r '.result.tabs[] | select(.label == "PR reviewer") | .tab_id' | tail -1)"
  n=0
  if [ -n "$tab" ]; then
    read -r n first < <(herdr pane list --workspace "$ws" \
      | jq -r --arg t "$tab" '[.result.panes[] | select(.tab_id == $t)]
                              | "\(length) \(.[0].pane_id // "")"')
  fi
  if [ -z "$tab" ] || [ "$n" -ge "$_RUN_REVIEW_TAB_CAP" ]; then
    resp="$(herdr tab create --workspace "$ws" --label "PR reviewer" --cwd "$cwd" --no-focus)" \
      || die "cel run reviewer: tab create failed"
    pane="$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id // empty')"
  else
    # Largest pane by area gets the split, along its longer visual edge - a
    # terminal cell is roughly twice as tall as it is wide, hence the 2x.
    local target dir
    read -r target dir < <(herdr pane layout --pane "$first" \
      | jq -r '.result.layout.panes | max_by(.rect.width * .rect.height)
               | "\(.pane_id) \(if .rect.width >= 2 * .rect.height then "right" else "down" end)"')
    [ -n "$target" ] || die "cel run reviewer: could not read the PR reviewer tab layout"
    resp="$(herdr pane split --pane "$target" --direction "$dir" --cwd "$cwd" --no-focus)" \
      || die "cel run reviewer: pane split failed"
    pane="$(printf '%s' "$resp" | jq -r '.result.pane.pane_id // empty')"
  fi
  [ -n "$pane" ] || die "cel run reviewer: no pane id in herdr response"
  printf '%s' "$pane"
}

# herdr agent names must match [a-z][a-z0-9_-]{0,31} - no slash, no uppercase.
# The readable `repo/role` form survives as the herdr workspace label; this is
# only what the agent answers to.
_run_agent_name() { # <alias>
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-')"
  n="${n#"${n%%[a-z]*}"}"   # must start with a letter
  n="${n%-}"
  printf '%.32s' "$n"
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

cmd_run() { # [role] [--repo r] [--workspace w] [--branch b] [--pr n] [--profile p] [--model m] [--thinking l] [--dry-run]
  local role="" repo="" workspace="" branch="" pr="" dry_run=0
  local profile="" model_opt="" thinking_opt=""

  if [ $# -gt 0 ]; then
    case "$1" in
      root|orchestrator|worker|reviewer) role="$1"; shift ;;
      --*) : ;;
      *) die "cel run: unknown role '$1' (want root, orchestrator, worker or reviewer; omit for direct)" ;;
    esac
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)      repo="$2"; shift 2 ;;
      --workspace) workspace="$2"; shift 2 ;;
      --branch)    branch="$2"; shift 2 ;;
      --pr)        pr="$2"; shift 2 ;;
      --profile)   profile="$2"; shift 2 ;;
      --model)     model_opt="$2"; shift 2 ;;
      --thinking)  thinking_opt="$2"; shift 2 ;;
      --dry-run)   dry_run=1; shift ;;
      *) die "cel run: unknown argument '$1'" ;;
    esac
  done

  local wsdir
  if [ -n "$workspace" ]; then
    wsdir="$(registry_require "$workspace")"
  else
    wsdir="$(ws_current)" || die "cel run: not inside a workspace (cd into one, or pass --workspace <name>)"
  fi

  # --repo is required for every mode but root, unless the workspace has
  # exactly one repo to default to.
  if [ "$role" != "root" ] && [ -z "$repo" ]; then
    local repos; mapfile -t repos < <(ws_repo_names "$wsdir")
    if [ "${#repos[@]}" -eq 1 ]; then
      repo="${repos[0]}"
    else
      die "cel run: --repo is required (workspace '$(ws_name "$wsdir")' has ${#repos[@]} repos)"
    fi
  fi

  local tag="${role:-direct}" alias_name cwd runtime rolefile=""
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
      alias_name="$repo/orch"
      cwd="$wsdir/repos/$repo"
      runtime="$(ws_runtime "$wsdir" orchestrator)"
      rolefile="$CEL_ROOT/core/roles/project-orchestrator.md"
      ;;
    worker)
      [ -n "$branch" ] || die "cel run worker: --branch is required"
      alias_name="$repo/$branch"
      runtime="$(ws_runtime "$wsdir" worker)"
      rolefile="$CEL_ROOT/core/roles/worker.md"
      ;;
    reviewer)
      [ -n "$pr" ] || die "cel run reviewer: --pr is required"
      runtime="$(ws_review "$wsdir" runtime)"
      [ -n "$runtime" ] || die "cel run reviewer: workspace '$(ws_name "$wsdir")' declares no review: block"
      alias_name="$repo/pr-$pr-review"
      cwd="$wsdir/repos/$repo"
      rolefile="$CEL_ROOT/core/roles/pr-reviewer.md"
      ;;
  esac

  # Model and reasoning level, resolved before the role body is rendered
  # because a profile may CHANGE THE RUNTIME - and the runtime decides how the
  # role is injected, so picking it late would inject the role in the
  # wrong shape. Precedence, weakest first: the workspace default level, then
  # the named profile, then explicit flags.
  local model="" thinking
  thinking="$(ws_thinking "$wsdir")"
  # A reviewer's model has always come from the `review:` block; a profile or
  # an explicit --model still overrides it.
  [ "$role" = "reviewer" ] && model="$(ws_review "$wsdir" model)"

  # No --profile? The workspace may still bind one to this role. That binding
  # is what makes root and the orchestrators configurable at all: neither is
  # launched by hand, so a flag would never reach them.
  # A repo may narrow that binding for itself; see role_profile_for.
  [ -n "$profile" ] || profile="$(role_profile_for "$wsdir" "$tag" "$repo")"

  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_ISOLATE="" PROFILE_VETO=""
  if [ -n "$profile" ]; then
    profile_resolve "$wsdir" "$profile" "$runtime"
    [ -z "$PROFILE_VETO" ] || die "cel run: profile '$profile' is vetoed - $PROFILE_VETO"
    runtime="$PROFILE_RUNTIME"; thinking="$PROFILE_THINKING"
    # A profile that names no model leaves the model alone, so binding a
    # reviewer to a profile for its RUNTIME or effort does not quietly discard
    # the `review:` block's model.
    [ -z "$PROFILE_MODEL" ] || model="$PROFILE_MODEL"
  fi
  [ -z "$model_opt" ]    || model="$model_opt"
  [ -z "$thinking_opt" ] || thinking="$thinking_opt"

  local RUN_BODY
  if [ -n "$rolefile" ]; then
    RUN_BODY="$(ws_render_role "$wsdir" "$rolefile")"
  else
    RUN_BODY="$(ws_policy_block "$wsdir")"
  fi

  local AGENT_ARGS=()
  _run_agent_args "$runtime" "$tag" "$RUN_BODY" "$dry_run" "$wsdir"

  # Model and thinking flags ride ahead of the role injection, spelled the way
  # THIS runtime spells them (agents.yaml model_flag / thinking) rather than
  # assuming --model, which is what limited this to claude and omp before.
  local -a PROFILE_ARGS=()
  profile_launch_args "$runtime" "$model" "$thinking" "${PROFILE_ISOLATE:-}"
  [ "${#PROFILE_ARGS[@]}" -eq 0 ] || AGENT_ARGS=("${PROFILE_ARGS[@]}" "${AGENT_ARGS[@]}")

  # READ-ONLY ORCHESTRATORS. Root and the sub-orchestrators get the runtime's
  # guard hook so repository writes from their panes are refused at the tool
  # call; workers and reviewers do not - writing is a worker's whole job, and a
  # reviewer only reads. Enforced here rather than requested in the role text,
  # because a prompt was what caused the incident this exists to prevent.
  case "$role" in
    root|orchestrator)
      local gflag gfile
      gflag="$(agent_guard_hook "$runtime" flag)"; gfile="$(agent_guard_hook "$runtime" file)"
      if [ -n "$gflag" ] && [ -n "$gfile" ]; then
        AGENT_ARGS=("$gflag" "$CEL_ROOT/$gfile" "${AGENT_ARGS[@]}")
      fi ;;
  esac

  # Runtime-wide launch flags (agents.yaml launch_args) go ahead of the
  # role-injection args on every launch of that runtime.
  local -a launch_args=()
  mapfile -t launch_args < <(agent_launch_args "$runtime")
  [ "${#launch_args[@]}" -eq 0 ] || AGENT_ARGS=("${launch_args[@]}" "${AGENT_ARGS[@]}")

  local agent_name; agent_name="$(_run_agent_name "$alias_name")"

  # Reviewer panes join the caller's own view instead of creating one.
  if [ "$role" = "reviewer" ]; then
    if [ "$dry_run" -eq 1 ]; then
      printf 'herdr tab "PR reviewer": split its largest pane, or a new tab per %s panes\n' "$_RUN_REVIEW_TAB_CAP"
      printf 'herdr agent start %s --kind %s --pane <pane> -- %s\n' \
        "$agent_name" "$runtime" "$(_run_dry_agent_args)"
      return 0
    fi
    have herdr || die "cel run: herdr is not on PATH"
    have jq    || die "cel run: jq is not on PATH"
    local pane_id; pane_id="$(_run_reviewer_pane "$cwd")"
    herdr agent start "$agent_name" --kind "$runtime" --pane "$pane_id" -- "${AGENT_ARGS[@]}"
    return 0
  fi

  local -a CREATE_ARGS
  if [ "$role" = "worker" ]; then
    local repodir="$wsdir/repos/$repo"
    CREATE_ARGS=(worktree create --cwd "$repodir" --branch "$branch" --label "$branch" --no-focus)
  else
    CREATE_ARGS=(workspace create --cwd "$cwd" --label "$alias_name")
  fi

  # Root mode is the workspace's whole working view, so it also applies the
  # workspace's declared herdr layout (services, watch panes, ...) - the other
  # modes are single panes inside views that already exist.
  local layout=""
  [ "$role" = "root" ] && layout="$(ws_layout "$wsdir")"

  if [ "$dry_run" -eq 1 ]; then
    printf 'herdr %s\n' "${CREATE_ARGS[*]}"
    [ -n "$layout" ] && printf 'herdr-workspace-manager apply %s\n' "$layout"
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

  herdr agent start "$agent_name" --kind "$runtime" --pane "$pane_id" -- "${AGENT_ARGS[@]}"
}
