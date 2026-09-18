# shellcheck shell=bash
# Worker profiles - a named (runtime, model, thinking level) triple a workspace
# can point any agent launch at.
#
# The problem this solves: `runtime:` already chose the CLI per role, but a CLI
# is not a model. Trying a different model meant editing workspace.yaml, and
# comparing two models on the same ticket meant editing it twice and
# remembering which pane was which. A profile is the smallest thing that makes
# "run this worker on something else" a flag:
#
#   worker_profiles:
#     default:  { runtime: omp,      model: gpt-5.6-sol }
#     astra:    { runtime: codex,    model: gpt-6-astra, thinking: xhigh }
#     deepseek: { runtime: omp,      model: deepseek/deepseek-v4-flash,
#                 fallback: openrouter/deepseek/deepseek-v4.1-flash }
#
#   cel run worker --repo r --branch b --profile astra
#   cel-fanout delegate r b spec.md --profile deepseek
#
# Two behaviours are worth knowing about before reading the code:
#
# FALLBACK IS ABOUT REACHABILITY, NOT QUALITY. `fallback:` names the same model
# reached a different way (a direct provider API vs an aggregator). It is used
# only when the primary's provider has no credential on this box, and that is
# decided BEFORE the pane spawns - because the alternative is an agent that
# starts, prints an auth error and idles, which from the outside is
# indistinguishable from a worker thinking hard.
#
# THE LEVEL IS CLAMPED, NOT PASSED THROUGH. Runtimes accept different ladders
# (claude has no `minimal`, codex has no `off`), so a level outside a runtime's
# set is walked DOWN to the strongest one it does accept rather than handed
# over to be rejected at launch.
[ -n "${_CEL_PROFILES:-}" ] && return 0
_CEL_PROFILES=1
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/manifest.sh
. "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"
# shellcheck source=lib/quota.sh
. "$(dirname "${BASH_SOURCE[0]}")/quota.sh"

# shellcheck source=lib/yaml.sh
. "$(dirname "${BASH_SOURCE[0]}")/yaml.sh"

profile_names() { _yqr -r '.worker_profiles // {} | keys_unsorted[]' "$1/workspace.yaml"; }

# Which profile a role launches on when nobody passes --profile.
#
# This exists because THE ROLES THAT MOST NEED A FIXED MODEL ARE THE ONES
# NOBODY LAUNCHES BY HAND: root comes up from the layout when the workspace
# boots, and the sub-orchestrators are started by root itself. A per-launch
# flag for those two is really an instruction to an agent, and agents forget.
# Keyed by the same role names cel run takes - root, orchestrator, worker,
# reviewer, direct.
role_profile() { # <wsdir> <role>
  _yqr -r --arg r "$2" '.role_profiles[$r] // "" | tostring' "$1/workspace.yaml"
}

# The same binding, narrowed to one product or repo. A workspace's products are
# not alike: the one under active research wants a different orchestrator from
# the one grinding through well-specified tickets, and a repo with a heavy gate
# may want a stronger worker than its neighbours. Without this the only choices
# were to re-point EVERY orchestrator in the workspace or to pass --profile by
# hand at each launch - and a flag nobody is there to type is the exact thing
# role bindings exist to avoid.
#
# Resolution order, strongest first: a products[] entry whose name is $3, then
# a repos[] entry whose name is $3, then the workspace's own role_profiles.
# Products come first because an orchestrator is launched per PRODUCT - its
# name is a product name, and a repo that happens to share it must not steal
# the binding.
#   products:
#     - name: bundle
#       role_profiles: { orchestrator: deep-model }
#   repos:
#     - name: widget
#       role_profiles: { orchestrator: deep-model }
role_profile_for() { # <wsdir> <role> [name]
  if [ -n "${3:-}" ]; then
    local p
    p="$(_yqr -r --arg n "$3" --arg r "$2" \
      '((.products // [] | map(select(.name == $n))[0].role_profiles[$r])
        // (.repos // [] | map(select(.name == $n))[0].role_profiles[$r])
        // "") | tostring' \
      "$1/workspace.yaml")"
    [ -n "$p" ] && { printf '%s' "$p"; return 0; }
  fi
  role_profile "$1" "$2"
}

profile_get() { # <wsdir> <name> <key>
  _yqr -r --arg n "$2" --arg k "$3" '.worker_profiles[$n][$k] // "" | tostring' "$1/workspace.yaml"
}

profile_exists() { # <wsdir> <name>
  [ "$(_yqr -r --arg n "$2" '.worker_profiles // {} | has($n)' "$1/workspace.yaml")" = "true" ]
}

# The workspace's default reasoning level, else the plane's (agents.yaml
# defaults.thinking). Never empty: every launch gets a level unless the runtime
# has no way to take one.
ws_thinking() { # <wsdir>
  local t; t="$(_wsy "$1" '.thinking')"
  [ -n "$t" ] || t="$(manifest_default thinking)"
  printf '%s' "${t:-high}"
}

# Leading segment of an explicit `provider/model` id; empty for a bare model
# name, which means "whatever provider the runtime is already signed in to".
profile_provider() { # <model>
  case "$1" in */*) printf '%s' "${1%%/*}" ;; *) : ;; esac
}

# Is this provider's credential present in the WORKSPACE environment? The keys
# live in the workspace's gitignored env.local, not in cel's own shell, so the
# check has to load that environment - in a subshell, so nothing leaks into the
# caller and no key is ever printed.
profile_provider_ready() { # <wsdir> <provider>
  local p="$2" key
  [ -n "$p" ] || return 0                       # no provider named: runtime decides
  [ "$(provider_get "$p" auth)" = "cli" ] && return 0
  key="$(provider_get "$p" key_env)"
  [ -n "$key" ] || return 0                     # provider unknown to us: assume fine
  ( set +u
    eval "$(ws_env_exports "$1" 2>/dev/null)" >/dev/null 2>&1
    [ -n "${!key:-}" ] )
}

# Canonical ladder, weakest first. A runtime's own `levels` is a subset of it.
_PROFILE_LADDER="off minimal low medium high xhigh max"

_profile_ladder_index() { # <level> -> index, or empty when off-ladder (e.g. `auto`)
  local i=0 l
  for l in $_PROFILE_LADDER; do
    [ "$l" = "$1" ] && { printf '%s' "$i"; return 0; }
    i=$((i+1))
  done
  return 1
}

# The strongest level this runtime accepts that is no stronger than the one
# asked for; if it accepts nothing that weak, its weakest. Prints nothing when
# the request cannot be expressed at all, and the caller then omits the flag.
profile_clamp() { # <runtime> <level>
  local rt="$1" want="$2" have wi li best="" best_i=-1 low="" low_i=99
  mapfile -t have < <(agent_thinking_levels "$rt")
  [ "${#have[@]}" -gt 0 ] || return 1
  local l
  for l in "${have[@]}"; do [ "$l" = "$want" ] && { printf '%s' "$want"; return 0; }; done
  wi="$(_profile_ladder_index "$want")" || return 1   # off-ladder request
  for l in "${have[@]}"; do
    li="$(_profile_ladder_index "$l")" || continue    # skip the runtime's own `auto`
    if [ "$li" -le "$wi" ] && [ "$li" -gt "$best_i" ]; then best="$l"; best_i="$li"; fi
    if [ "$li" -lt "$low_i" ]; then low="$l"; low_i="$li"; fi
  done
  printf '%s' "${best:-$low}"
}

# Resolves a profile to what will actually be launched. Sets, for the caller:
#   PROFILE_RUNTIME  the CLI to start
#   PROFILE_MODEL    the model id ("" = the runtime's own default)
#   PROFILE_THINKING the requested level, before per-runtime clamping
#   PROFILE_NOTE     one line for logs/ledger, e.g. "fallback: DEEPSEEK_API_KEY unset"
# Fails only for a profile that does not exist; everything else degrades with a
# warning, because refusing to start a worker is worse than starting a slower one.
profile_resolve() { # <wsdir> <name> [<default-runtime>]
  local d="$1" name="$2" rt_default="${3:-}"
  PROFILE_RUNTIME=""; PROFILE_MODEL=""; PROFILE_THINKING=""; PROFILE_NOTE=""; PROFILE_VETO=""
  profile_exists "$d" "$name" \
    || die "no worker profile '$name' in $(ws_name "$d")/workspace.yaml (have: $(profile_names "$d" | tr '\n' ' '))"

  PROFILE_RUNTIME="$(profile_get "$d" "$name" runtime)"
  [ -n "$PROFILE_RUNTIME" ] || PROFILE_RUNTIME="$rt_default"
  [ -n "$PROFILE_RUNTIME" ] || die "profile '$name' names no runtime and no default applies"

  PROFILE_MODEL="$(profile_get "$d" "$name" model)"
  local fb; fb="$(profile_get "$d" "$name" fallback)"
  local prov; prov="$(profile_provider "$PROFILE_MODEL")"
  if [ -n "$PROFILE_MODEL" ] && ! profile_provider_ready "$d" "$prov"; then
    local key; key="$(provider_get "$prov" key_env)"
    if [ -n "$fb" ] && profile_provider_ready "$d" "$(profile_provider "$fb")"; then
      PROFILE_NOTE="fallback: $key unset, using $fb"
      c_warn "profile $name: $key is unset - falling back to $fb"
      PROFILE_MODEL="$fb"
    else
      PROFILE_NOTE="unreachable: $key unset"
      c_warn "profile $name: $key is unset and no reachable fallback - $PROFILE_MODEL will fail to authenticate (set it in $(ws_name "$d")/env.local; keys: $(provider_get "$prov" console))"
    fi
  fi

  PROFILE_THINKING="$(profile_get "$d" "$name" thinking)"
  [ -n "$PROFILE_THINKING" ] || PROFILE_THINKING="$(ws_thinking "$d")"

  # `isolated: true` on the profile means "use THIS workspace's credentials,
  # not whatever the runtime has stored". The name is per-workspace so two
  # workspaces never share a credential cache.
  PROFILE_ISOLATE=""
  [ "$(profile_get "$d" "$name" isolated)" = "true" ] && PROFILE_ISOLATE="cel-$(ws_name "$d")"

  # Isolation already guarantees the workspace key is the one used, so the
  # probe would only report a mismatch that no longer applies.
  [ -n "$PROFILE_ISOLATE" ] \
    || _profile_credential_check "$PROFILE_RUNTIME" "$(profile_provider "$PROFILE_MODEL")" "$d"

  _profile_quota_check "$d" "$name" "$fb"
}

# QUOTA PREFLIGHT. A provider that is running dry is vetoed before the pane
# spawns. If the profile declares a fallback on a DIFFERENT provider that is
# not also dry, the route swaps and says so; otherwise PROFILE_VETO carries
# the refusal for the caller (cel run, cel-fanout) to die on - `cel profiles`
# prints it instead, so a dead account never breaks the listing. `unknown`
# never vetoes: refusing to work because a balance endpoint was down would be
# a worse outage than the one this prevents (firstmate: "unknown runway
# remains eligible with disclosed uncertainty").
#
# A veto swaps ROUTE, never reasoning class. Silently dropping the thinking
# level to stretch a budget would trade a visible refusal for invisible
# worse work; if the money is not there, the answer is to say so.
_profile_quota_check() { # <wsdir> <name> <fallback-model>
  [ "${CEL_NO_QUOTA_PROBE:-0}" = 1 ] && return 0
  local d="$1" name="$2" fb="$3"
  local prov; prov="$(profile_provider "$PROFILE_MODEL")"
  [ -n "$prov" ] || return 0
  local rem; rem="$(quota_remaining "$prov" "$d")"
  if [ "$rem" = unknown ]; then
    [ -n "$(provider_balance "$prov" url)" ] && c_warn "profile $name: could not read $prov balance - proceeding on that provider without a quota check"
    return 0
  fi
  quota_vetoed "$prov" "$rem" || return 0
  local floor; floor="$(provider_balance "$prov" floor)"
  local fprov=""; [ -n "$fb" ] && fprov="$(profile_provider "$fb")"
  if [ -n "$fb" ] && [ -n "$fprov" ] && [ "$fprov" != "$prov" ] && profile_provider_ready "$d" "$fprov"; then
    local frem; frem="$(quota_remaining "$fprov" "$d")"
    if ! quota_vetoed "$fprov" "$frem"; then
      c_warn "profile $name: $prov balance $rem is below its floor of $floor - routing via $fb instead"
      PROFILE_NOTE="${PROFILE_NOTE:+$PROFILE_NOTE; }vetoed: $prov balance $rem below floor $floor; using $fb"
      PROFILE_MODEL="$fb"
      return 0
    fi
  fi
  PROFILE_VETO="$prov balance is $rem $(provider_balance "$prov" unit), below its floor of $floor - a worker sent there would die mid-flight. Top up at $(provider_get "$prov" console), or point the profile at another provider."
  PROFILE_NOTE="${PROFILE_NOTE:+$PROFILE_NOTE; }VETOED: $prov balance $rem below floor $floor"
  c_err "profile $name: $PROFILE_VETO"
}

# Does the runtime actually intend to use the workspace's credential?
#
# "The env var is set" is NOT the same as "this account gets billed". omp keeps
# its own credential vault and that vault beats the environment outright, so a
# key exported from env.local can be silently ignored. That is not theoretical:
# on 2026-09-11 a workspace's OpenRouter traffic went to the box owner's
# personal account and drained it, while `cel profiles` reported the route
# reachable - because it was checking a variable omp never reads.
#
# Keys are compared by HASH and never printed, and a mismatch is a warning
# rather than a refusal: the run may well be what you wanted, but you should
# know whose credit it is spending before a worker starts.
_profile_credential_check() { # <runtime> <provider> <wsdir>
  local rt="$1" prov="$2" d="$3" probe wskey rtkey
  # The probe shells out to the runtime and reads a real credential store, so
  # it is opt-out-able: tests must not depend on which accounts this box
  # happens to be signed in to.
  [ "${CEL_NO_CREDENTIAL_PROBE:-0}" = 1 ] && return 0
  [ -n "$prov" ] || return 0
  probe="$(agent_get "$rt" credential_probe)"
  [ -n "$probe" ] || return 0
  local keyenv; keyenv="$(provider_get "$prov" key_env)"
  [ -n "$keyenv" ] || return 0

  wskey="$( set +u; eval "$(ws_env_exports "$d" 2>/dev/null)" >/dev/null 2>&1; printf '%s' "${!keyenv:-}" )"
  [ -n "$wskey" ] || return 0
  rtkey="$($probe "$prov" 2>/dev/null | tr -d '\r\n')"
  [ -n "$rtkey" ] || return 0
  [ "$wskey" != "$rtkey" ] || return 0

  PROFILE_NOTE="${PROFILE_NOTE:+$PROFILE_NOTE; }credential mismatch: $rt uses its own $prov credential, not $keyenv"
  c_err "$rt will NOT use this workspace's $keyenv for '$prov' - it has its own stored credential and that wins."
  c_err "  a different account will be billed. Either point the runtime's vault at the workspace key, or launch it with an isolated profile so the environment is used."
}

# Renders the model and thinking flags for a runtime into the PROFILE_ARGS
# array. Empty for a runtime with no model_flag and no thinking block, so a
# caller can always splice it in unconditionally.
profile_launch_args() { # <runtime> <model> <thinking> [isolate-name]
  local rt="$1" model="$2" want="$3" iso="${4:-}" flag strategy level
  PROFILE_ARGS=()

  # ISOLATION: run the CLI under a profile with no credential vault of its own,
  # so it falls back to the environment - i.e. to the workspace's env.local.
  # This is the only way to make a workspace's key authoritative for a runtime
  # that otherwise prefers its own stored credentials, and it leaves the
  # personal credentials that runtime uses interactively completely alone.
  # Only worth it for providers keyed from env.local: an isolated profile has
  # no OAuth either, so a profile relying on a CLI sign-in must NOT set it.
  if [ -n "$iso" ]; then
    flag="$(agent_get "$rt" isolated_profile_flag)"
    if [ -n "$flag" ]; then
      PROFILE_ARGS+=("$flag" "$iso")
    else
      c_warn "runtime $rt has no isolated-profile flag - it will use its own stored credentials, not this workspace's"
    fi
  fi

  if [ -n "$model" ]; then
    flag="$(agent_model_flag "$rt")"
    if [ -n "$flag" ]; then
      PROFILE_ARGS+=("$flag" "$model")
    else
      c_warn "runtime $rt takes no model flag - ignoring model '$model' (agents.yaml declares no model_flag)"
    fi
  fi

  [ -n "$want" ] || return 0
  strategy="$(agent_thinking "$rt" strategy)"
  if [ -z "$strategy" ]; then
    # Not a warning on every launch: plenty of runtimes simply carry the level
    # in their own config, and saying so each time trains people to ignore it.
    return 0
  fi
  level="$(profile_clamp "$rt" "$want")" || return 0
  [ -n "$level" ] || return 0
  [ "$level" = "$want" ] || c_warn "runtime $rt does not accept thinking '$want' - using '$level'"
  case "$strategy" in
    flag)   PROFILE_ARGS+=("$(agent_thinking "$rt" flag)" "$level") ;;
    # Deliberately UNQUOTED. codex parses the value as TOML and falls back to
    # the raw string when that fails, so `key=high` and `key="high"` mean the
    # same thing to it - but this argument is typed into a shell pane by herdr
    # on its way to the CLI, and the bare form has nothing for a quoting layer
    # to mangle.
    config) PROFILE_ARGS+=(-c "$(agent_thinking "$rt" key)=$level") ;;
    *)      c_warn "runtime $rt: unknown thinking strategy '$strategy'" ;;
  esac
}

cmd_profiles() { # [name]
  local wsdir; wsdir="$(ws_current)" \
    || die "cel profiles: not inside a workspace (cd into one)"
  local names; mapfile -t names < <(profile_names "$wsdir")
  if [ "${#names[@]}" -eq 0 ]; then
    c_warn "workspace '$(ws_name "$wsdir")' declares no worker_profiles"
    printf '\nAdd them to %s/workspace.yaml:\n\n' "$wsdir"
    cat <<'EOS'
  thinking: high            # default reasoning level for every launch
  worker_profiles:
    default: { runtime: omp, model: gpt-5.6-sol }
    astra:   { runtime: codex, model: gpt-6-astra, thinking: xhigh }
EOS
    return 0
  fi

  local n PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_ARGS PROFILE_ISOLATE PROFILE_VETO
  printf '%s (default thinking: %s)\n\n' "$(ws_name "$wsdir")" "$(ws_thinking "$wsdir")"
  for n in "${names[@]}"; do
    [ $# -eq 0 ] || [ "$n" = "$1" ] || continue
    profile_resolve "$wsdir" "$n" 2>/dev/null
    profile_launch_args "$PROFILE_RUNTIME" "$PROFILE_MODEL" "$PROFILE_THINKING" "${PROFILE_ISOLATE:-}" 2>/dev/null
    local bal="" bp; bp="$(profile_provider "$PROFILE_MODEL")"
    if [ -n "$bp" ] && [ -n "$(provider_balance "$bp" url)" ]; then
      bal="$(quota_remaining "$bp" "$wsdir")"; [ "$bal" = unknown ] || bal="$(printf '%.2f' "$bal")"
      bal="  [$bp: $bal $(provider_balance "$bp" unit) left]"
    fi
    printf '  %-12s %-9s %s%s\n' "$n" "$PROFILE_RUNTIME" "${PROFILE_MODEL:-<runtime default>}" "$bal"
    local for_; for_="$(profile_get "$wsdir" "$n" for)"
    [ -z "$for_" ] || printf '  %-12s for: %s\n' "" "$for_"
    printf '  %-12s %s\n' "" "launch: ${PROFILE_ARGS[*]}"
    [ -z "$PROFILE_NOTE" ] || printf '  %-12s %s\n' "" "$PROFILE_NOTE"
  done

  # Which roles are BOUND to a profile - the part that applies without anyone
  # typing a flag, and therefore the part worth showing unprompted.
  local role bound any=0
  for role in root orchestrator worker scout reviewer direct; do
    bound="$(role_profile "$wsdir" "$role")"
    [ -n "$bound" ] || continue
    [ "$any" -eq 1 ] || { printf '\nbound by role (no --profile needed):\n'; any=1; }
    printf '  %-12s -> %s\n' "$role" "$bound"
  done
  [ "$any" -eq 1 ] || printf '\nNo role_profiles: bindings - every role uses runtime: + the default level.\n'

  printf '\nOverride once: cel run worker --repo <r> --branch <b> --profile <name>\n'
}
