# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/steward.sh"

# The dedup window is what separates a reminder from spam: first call for a
# key fires and records, an immediate second call for the same key does not,
# a different key does.
test_steward_due_rate_limits_per_key() {
  local T; T="$(mktemp -d)"
  CEL_STEWARD_STATE="$T/state" _STEWARD_STATE="$T/state"
  _steward_due "repo#1-changes"
  assert_fails _steward_due "repo#1-changes"
  _steward_due "repo#2-changes"
  assert_contains "$(cat "$T/state")" "repo#1-changes"
  rm -rf "$T"
}
test_steward_agent_name_matches_cel_run() {
  assert_eq "$(_steward_agent_name 'widget-games/orch')" "widget-games-orch"
}

# A worker's mailbox name and its herdr agent name are the same string by
# construction - that identity is what lets the steward nudge a worker at all,
# so it is asserted rather than assumed. Both go through the same sanitiser
# from <repo>-<branch>; only the separator in the source differs.
test_worker_mailbox_name_is_its_agent_name() {
  source "$CEL_ROOT/lib/inbox.sh"
  source "$CEL_ROOT/lib/run.sh"
  assert_eq "$(_inbox_sanitise 'widget-WG-1-feature')" "$(_run_agent_name 'widget/WG-1-feature')"
  # and a hyphenated repo name survives both intact
  assert_eq "$(_inbox_sanitise 'long-product-name-ABCD-38-x')" "$(_run_agent_name 'long-product-name/ABCD-38-x')"
}
# The mailbox sweep resolved a pane for root and <repo>-orch only, so every
# worker reported "(no pane to nudge)" while its agent sat idle in a live pane.
# Anything that is neither is a worker and is matched by name.
test_worker_mailbox_resolves_to_a_want_name() {
  assert_eq "$(_steward_mailbox_want root alpha)" "alpha-root"
  assert_eq "$(_steward_mailbox_want widget-orch alpha)" "widget-orch"
  assert_eq "$(_steward_mailbox_want widget-wg-1-feature alpha)" "widget-wg-1-feature"
}

# Exercise the real workspace env loader and the whole sweep. The curl
# double records where each key was used, including the GraphQL team.
_ready_workspaces() {
  T="$(mktemp -d)"
  mkdir -p "$T/alpha" "$T/beta"
  export CEL_REGISTRY="$T/registry.yaml"
  printf 'workspaces:\n  alpha: {path: "%s/alpha"}\n  beta: {path: "%s/beta"}\n' "$T" "$T" > "$CEL_REGISTRY"
  printf 'name: alpha\ntickets: {system: linear}\nrepos: [{name: widget, linear_team: ALPHA}]\n' > "$T/alpha/workspace.yaml"
  printf 'name: beta\ntickets: {system: linear}\nrepos: [{name: widget, linear_team: BETA}]\n' > "$T/beta/workspace.yaml"
  printf 'LINEAR_API_KEY=fixture-alpha\nCEL_ISOLATION_MARKER=alpha\n' > "$T/alpha/env.local"
  export CEL_ISOLATION_MARKER=parent
  : > "$T/requests"
  curl() {
    local argv="$*" url="" body="" headers=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -H)
          case "$2" in
            @-) headers="$(cat)" ;;
            Authorization:*) headers="$2" ;;
          esac
          shift 2 ;;
        -d) body="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
      esac
    done
    jq -nc --arg url "$url" --arg argv "$argv" --arg headers "$headers" \
      --argjson body "$body" '{url:$url, argv:$argv, headers:$headers, body:$body}' >> "$T/requests"
    printf '{"data":{"issues":{"nodes":[]}}}'
  }
}

test_ready_workspaces_do_not_share_credentials_or_modify_parent() {
  _ready_workspaces
  unset LINEAR_API_KEY
  _steward_ready_tickets
  assert_eq "${LINEAR_API_KEY+set}" ""
  assert_eq "$CEL_ISOLATION_MARKER" parent
  assert_eq "$(jq -sc '[.[] | [.url, .body.variables.k, .headers]]' "$T/requests")" \
    '[["https://api.linear.app/graphql","ALPHA","Authorization: fixture-alpha"]]'
  assert_eq "$(jq -s '[.[] | .argv | contains("fixture-alpha")] | any' "$T/requests")" false
  assert_eq "$(jq -r '.body.variables.st' "$T/requests")" Ready

  # Giving B its own key must enable B, without changing A's identity.
  printf 'LINEAR_API_KEY=fixture-beta\n' > "$T/beta/env.local"
  : > "$T/requests"
  _steward_ready_tickets
  assert_eq "$(jq -sc '[.[] | [.body.variables.k, .headers]]' "$T/requests")" \
    '[["ALPHA","Authorization: fixture-alpha"],["BETA","Authorization: fixture-beta"]]'
  assert_eq "$(jq -s '[.[] | .argv | test("fixture-alpha|fixture-beta")] | any' "$T/requests")" false
  assert_eq "${LINEAR_API_KEY+set}" ""
  assert_eq "$CEL_ISOLATION_MARKER" parent
  rm -rf "$T"
}

test_ready_workspaces_preserve_explicit_caller_credential_fallback() {
  _ready_workspaces
  export LINEAR_API_KEY=fixture-parent
  _steward_ready_tickets
  assert_eq "$(jq -sc '[.[] | [.body.variables.k, .headers]]' "$T/requests")" \
    '[["ALPHA","Authorization: fixture-alpha"],["BETA","Authorization: fixture-parent"]]'
  assert_eq "$LINEAR_API_KEY" fixture-parent
  assert_eq "$CEL_ISOLATION_MARKER" parent
  rm -rf "$T"
}

# Where does a <p>-orch live? A DECLARED product has its own directory; an
# implicit one is just a repo. The steward cannot read workspace.yaml to tell
# them apart (identity is derived from paths, deliberately), so the
# directory's existence is the test. Both cwd-fallback sweeps share this one
# function so they cannot drift - they had already been written twice.
test_steward_orch_dir_prefers_a_declared_product() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/products/bundle" "$T/repos/lone"
  assert_eq "$(_steward_orch_dir "$T" bundle-orch)" "$T/products/bundle"
  assert_eq "$(_steward_orch_dir "$T" lone-orch)" "$T/repos/lone"
  rm -rf "$T"
}
