# shellcheck shell=bash
# `cel fleet` - the whole box in one read. Every assertion here is a number an
# operator would otherwise have gathered by visiting each workspace in turn,
# so the fixture is a miniature box: two workspaces, a mailbox and a herdr
# stub.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/fleet.sh"

_fleet_ws_yaml() { # <name> <repo>...
  local name="$1"
  shift
  cat <<EOF
name: $name
kind: hustle
org: someone
tickets: { system: none, adhoc: "AH-<yymmdd>" }
policy: { merge: humans-only, pr: required, reviewer: null }
runtime: { root: claude, orchestrator: claude }
tools: []
repos:
EOF
  local r
  for r in "$@"; do
    printf -- '  - name: %s\n    url: git@github.com:someone/%s.git\n    prefix: WG\n    gate: bun test\n' "$r" "$r"
  done
}

_fleet_setup() {
  T="$(mktemp -d)"
  export CEL_REGISTRY="$T/registry.yaml"
  export CEL_INBOX_DIR="$T/inbox"
  mkdir -p "$T/inbox" "$T/alpha/.cel" "$T/beta/.cel" "$T/bin"

  cat >"$CEL_REGISTRY" <<EOF
workspaces:
  alpha: { path: $T/alpha, remote: null }
  beta: { path: $T/beta, remote: null }
EOF
  _fleet_ws_yaml alpha widget gadget >"$T/alpha/workspace.yaml"
  _fleet_ws_yaml beta gadget >"$T/beta/workspace.yaml"

  # One unread message for root, in alpha only.
  printf '%s\n' '{"id":"1","ts":"2026-09-16T00:00:00+00:00","to":"root","from":"widget-orch","kind":"status","message":"hello","cwd":"/","pane":""}' \
    >"$T/inbox/alpha.jsonl"

  cat >"$T/bin/herdr" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_HERDR_FAIL:-}" ] && exit 1
# A roster that ANSWERS with a truncated document: herdr killed mid-write, or
# a pane manager that died between the opening brace and the rest of it.
[ -n "${STUB_HERDR_BAD:-}" ] && { printf '%s' '{"result":{"agents":[{"name":"widget-orch",'; exit 0; }
case "$1 $2" in
  "agent list")
    # A live agent with NO herdr name, in a cwd the caller names. The
    # fleet must not read it as an absence.
    extra=""
    [ -z "${STUB_UNNAMED_CWD:-}" ] \
      || extra=",{\"name\":null,\"agent_status\":\"idle\",\"pane_id\":\"wA:p7\",\"cwd\":\"$STUB_UNNAMED_CWD\"}"
    printf '{"result":{"agents":[%s%s]}}\n' '
      {"name":"widget-orch","agent_status":"idle","pane_id":"wA:p1","cwd":"/nowhere/widget"},
      {"name":"bundle-orch","agent_status":"idle","pane_id":"wA:p9","cwd":"/nowhere/bundle"}' "$extra" ;;
  *) printf '%s\n' '{}' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
  PATH="$T/bin:$PATH"
  # No live console on this fixture box: the mail reader is found by a marker
  # in a process environment, and the real /proc would let whatever is running
  # on the developer's box decide the answer.
  export CEL_PROC_DIR="$T/proc"; mkdir -p "$CEL_PROC_DIR"
}

# MEMORY. A fixture meminfo stands in for the box (a test may not arrange 5%
# available) and the tree walk is stubbed, because what `cel fleet` owns is
# the SHAPE - which directory belongs to which row - and not the arithmetic,
# which tests/memory.test.sh proves against a real process.
_fleet_stub_memory() {
  printf 'MemTotal:       25165824 kB\nMemAvailable:    7235174 kB\n' >"$T/meminfo"
  export CEL_MEMINFO="$T/meminfo"
  mem_tree_snapshot() { :; }
  mem_tree_rss_mb() {
    case "$1" in
      *repos/widget*|*products/bundle*) printf 120 ;;
      *) printf 0 ;;
    esac
  }
}
_fleet_teardown() { rm -rf "$T"; }

test_fleet_prints_a_block_per_workspace_and_a_line_per_repo() {
  _fleet_setup
  local out
  out="$(cmd_fleet)"
  assert_contains "$out" "alpha"
  assert_contains "$out" "beta"
  assert_contains "$out" "widget"
  assert_contains "$out" "gadget"
  # a product with no `mode:` is solo; the agent herdr knows about is LIVE,
  # the one it does not is a dash
  case "$out" in *"widget"*"solo LIVE"*) ;; *)
    echo "widget was not LIVE: $out"
    _fleet_teardown
    return 1
    ;;
  esac
  case "$out" in *"gadget"*"solo -"*) ;; *)
    echo "gadget was not '-': $out"
    _fleet_teardown
    return 1
    ;;
  esac
  assert_contains "$out" "worktrees 0"
  _fleet_teardown
}

# Root's mail is per workspace: the point of the view is that nobody has to
# remember which mailbox they last looked at.
test_fleet_counts_root_mail_per_workspace() {
  _fleet_setup
  local doc
  doc="$(cmd_fleet --json)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[] | select(.name=="alpha") | .root.unread')" "1"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[] | select(.name=="beta")  | .root.unread')" "0"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[] | select(.name=="alpha") | .root.open')" "0"
  assert_contains "$(cmd_fleet --workspace alpha)" "1 unread"
  _fleet_teardown
}

test_fleet_json_carries_the_same_numbers_and_workspace_limits_the_scope() {
  _fleet_setup
  local doc
  doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces | length')" "1"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].name')" "alpha"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units | length')" "2"
  local u
  u="$(printf '%s' "$doc" | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch')" "LIVE"
  assert_eq "$(printf '%s' "$u" | jq -r '.mode')" "solo"
  assert_eq "$(printf '%s' "$u" | jq -r '.solo_worktrees')" "0"
  _fleet_teardown
}

# herdr being unreachable is not evidence that anyone died: the read still
# completes and every agent reads as unknown.
test_fleet_survives_herdr_being_down() {
  _fleet_setup
  local doc
  doc="$(STUB_HERDR_FAIL=1 cmd_fleet --json)"
  assert_eq "$(printf '%s' "$doc" | jq -r '[.workspaces[].units[].orch] | unique | join(",")')" "-"
  _fleet_teardown
}

# PRODUCTS. The unit of the view is the thing one agent actually stands over:
# a product over two repos with one live agent is ONE row showing that agent.
_fleet_declare_bundle() { # [mode]
  printf 'products:\n  - name: bundle\n    repos: [widget, gadget]\n' >>"$T/alpha/workspace.yaml"
  [ -z "${1:-}" ] || printf '    mode: %s\n' "$1" >>"$T/alpha/workspace.yaml"
}

test_fleet_counts_a_declared_product_as_one_unit() {
  _fleet_setup
  _fleet_declare_bundle
  local doc
  doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units | length')" "1"
  local u
  u="$(printf '%s' "$doc" | jq -c '.workspaces[0].units[0]')"
  assert_eq "$(printf '%s' "$u" | jq -r '.name')" "bundle"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch')" "LIVE"
  assert_eq "$(printf '%s' "$u" | jq -r '.declared')" "true"
  assert_eq "$(printf '%s' "$u" | jq -r '.repos | join(",")')" "widget,gadget"
  assert_eq "$(printf '%s' "$u" | jq -r '.mode')" "solo"
  printf '%s' "$doc" | jq -e '.workspaces[0].units[0] | .repos|length == 2' >/dev/null \
    || { echo "repos was not a two-element array: $u"; _fleet_teardown; return 1; }
  _fleet_teardown
}

# A product still declaring the retired `mode: fleet` is read back as fleet
# and says how to switch it; nothing about it is counted as work in flight.
test_fleet_shows_a_legacy_fleet_product_with_its_cure() {
  _fleet_setup
  _fleet_declare_bundle fleet
  local u out
  u="$(cmd_fleet --json --workspace alpha | jq -c '.workspaces[0].units[0]')"
  assert_eq "$(printf '%s' "$u" | jq -r '.mode')" "fleet"
  assert_eq "$(printf '%s' "$u" | jq -r 'has("lanes")')" "false"
  out="$(cmd_fleet --workspace alpha)"
  assert_contains "$out" "fleet LIVE"
  assert_contains "$out" "(retired: cel mode bundle solo)"
  _fleet_teardown
}

# A declared product says which repos it is; an implicit one is a repo and
# renders as its bare name.
test_fleet_text_names_a_declared_products_repos() {
  _fleet_setup
  _fleet_declare_bundle
  local out
  out="$(cmd_fleet --workspace alpha)"
  assert_contains "$out" "(1 products)"
  assert_contains "$out" "bundle (widget, gadget)"
  _fleet_teardown
}

test_fleet_leaves_an_undeclared_workspace_as_repos() {
  _fleet_setup
  local out doc
  out="$(cmd_fleet --workspace alpha)"
  doc="$(cmd_fleet --json --workspace alpha)"
  assert_contains "$out" "(2 products)"
  assert_contains "$out" "$(printf '  %-12s solo %-5s worktrees 0' widget LIVE)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units[0].declared')" "false"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units[0].repos | join(",")')" "widget"
  _fleet_teardown
}

test_fleet_json_carries_the_box_and_the_agents_footprint() {
  _fleet_setup
  _fleet_stub_memory
  local doc u
  doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.box.total_mb')" "24576"
  assert_eq "$(printf '%s' "$doc" | jq -r '.box.available_mb')" "7065"
  assert_eq "$(printf '%s' "$doc" | jq -r '.box.used_pct')" "71"
  u="$(printf '%s' "$doc" | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch_rss_mb')" "120"
  # every tree the fleet knows about: widget's agent, with gadget
  # contributing nothing
  assert_eq "$(printf '%s' "$doc" | jq -r '.box.agents_rss_mb')" "120"
  _fleet_teardown
}

# A DECLARED PRODUCT'S AGENT STANDS IN THE PRODUCT DIRECTORY, an implicit
# one in the repo checkout - the same derivation the steward uses. Reading
# the wrong one reports zero for a live pane, which is indistinguishable from
# an agent that is not running at all.
test_fleet_reads_a_declared_products_agent_from_its_product_dir() {
  _fleet_setup
  _fleet_declare_bundle
  _fleet_stub_memory
  local u
  u="$(cmd_fleet --json --workspace alpha | jq -c '.workspaces[0].units[0]')"
  assert_eq "$(printf '%s' "$u" | jq -r '.name')" "bundle"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch_rss_mb')" "120"
  _fleet_teardown
}

test_fleet_text_shows_a_units_memory_and_the_boxs_headroom() {
  _fleet_setup
  _fleet_stub_memory
  local out
  out="$(cmd_fleet --workspace alpha)"
  assert_contains "$out" "mem 120M"
  assert_contains "$out" "box 6.9G free of 24G"
  _fleet_teardown
}

# An unreadable meminfo is a statement about the observer: the read still
# completes and every number it can still answer is unchanged.
test_fleet_survives_a_box_it_cannot_measure() {
  _fleet_setup
  local doc
  doc="$(CEL_MEMINFO=/nonexistent/meminfo cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.box.total_mb')" "0"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units | length')" "2"
  _fleet_teardown
}

test_fleet_rejects_unknown_arguments() {
  _fleet_setup
  assert_fails bash -c "source '$CEL_ROOT/lib/fleet.sh'; cmd_fleet --nonsense"
  _fleet_teardown
}

# --- subscriptions, from the cache and never from the network --------------
# The fleet read is on the console's refresh loop. A live call to Anthropic or
# ChatGPT on that path would put two network round trips between an operator
# and every draw, so the field is whatever the 60 s cache already holds.
test_fleet_json_carries_subscriptions_from_the_cache() {
  _fleet_setup
  export CEL_CACHE="$T/cache"
  mkdir -p "$CEL_CACHE"
  jq -nc '{provider: "claude", account: "a1b2c3",
           windows: [{name: "5h", used_pct: 16, resets_at: "2026-09-18T09:00:00Z"}],
           extra: {state: "enabled", reason: ""}}' \
    > "$CEL_CACHE/subscription-claude-a1b2c3.json"
  local doc; doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.subscriptions[0].provider')" claude
  assert_eq "$(printf '%s' "$doc" | jq -r '.subscriptions[0].windows[0].used_pct')" 16
  _fleet_teardown
}

test_fleet_json_carries_an_empty_subscription_list_when_nothing_is_cached() {
  _fleet_setup
  export CEL_CACHE="$T/empty-cache"
  local doc; doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.subscriptions | length')" 0
  _fleet_teardown
}

# The fleet field is not a directory listing, it is the subscription list
# read from the cache. Two copies of one Claude login (pi's and Claude Code's)
# with the same windows are one subscription here exactly as they are in
# `cel quota`, or the console and the dashboard count this box's logins
# differently.
test_fleet_subscriptions_are_the_quota_list_folded_the_same_way() {
  _fleet_setup
  export CEL_CACHE="$T/cache35"
  mkdir -p "$CEL_CACHE"
  local w='[{"name":"5h","used_pct":16,"resets_at":"2026-09-18T09:00:00Z"}]'
  jq -nc --argjson w "$w" '{provider: "claude", account: "pi", label: "pi", source: "direct",
                            windows: $w, extra: {state: "enabled", reason: ""}}' \
    > "$CEL_CACHE/subscription-claude-pi.json"
  jq -nc --argjson w "$w" '{provider: "claude", account: "claude-code", label: "claude-code",
                            source: "direct", windows: $w, extra: {state: "enabled", reason: ""}}' \
    > "$CEL_CACHE/subscription-claude-claude-code.json"
  local doc; doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.subscriptions | length')" 1
  assert_eq "$(printf '%s' "$doc" | jq -r '.subscriptions[0].label')" 'pi + claude-code'
  _fleet_teardown
}

# A NAMELESS AGENT IS A FAULT, NOT AN ABSENCE. herdr can clear a live agent's
# name on restart; `cel fleet` resolves one by its alias, and `-` invites
# starting a SECOND agent on top of the live one. A live agent in the
# product's own cwd reads as `unnamed`, which is a state with a cure.
test_fleet_reports_a_live_unnamed_agent_as_unnamed() {
  _fleet_setup
  local doc
  doc="$(STUB_UNNAMED_CWD="$T/alpha/repos/gadget" cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units[] | select(.name=="gadget") | .orch')" "unnamed"
  assert_contains "$(STUB_UNNAMED_CWD="$T/alpha/repos/gadget" cmd_fleet --workspace alpha)" "solo unnamed"
  # And with nothing there it is still the dash it always was.
  doc="$(cmd_fleet --json --workspace alpha)"
  assert_eq "$(printf '%s' "$doc" | jq -r '.workspaces[0].units[] | select(.name=="gadget") | .orch')" "-"
  _fleet_teardown
}

# --- a mailbox with no reader ----------------------------------------------
# Every view of this box reads `cel fleet --json`, so the three facts that
# decide whether root's mail is going anywhere belong in it: how much is
# unread, how long the oldest has waited, and WHO is alive to read it. The
# herdr stub's roster has no alpha-root and the fixture has no console, so
# alpha's mail is landing in a mailbox nobody reads - which is the fault.
test_fleet_json_carries_the_mail_triple_per_workspace() {
  _fleet_setup
  local doc; doc="$(cmd_fleet --json)"
  local alpha; alpha="$(printf '%s' "$doc" | jq -c '.workspaces[] | select(.name=="alpha") | .mail')"
  assert_eq "$(printf '%s' "$alpha" | jq -r '.to_root_unread')" "1"
  assert_eq "$(printf '%s' "$alpha" | jq -r '.reader')" ""
  [ "$(printf '%s' "$alpha" | jq -r '.oldest_secs')" -gt 0 ] || { echo "no age on the oldest unread"; return 1; }
  # a live root pane IS a reader, and then there is nothing to report
  mkdir -p "$CEL_PROC_DIR/4242"
  printf 'CEL_ROLE=console\0' > "$CEL_PROC_DIR/4242/environ"
  assert_eq "$(cmd_fleet --json | jq -r '.workspaces[] | select(.name=="alpha") | .mail.reader')" "console"
  _fleet_teardown
}

# The doctor line is the one a human reads. It says the count, the age and the
# fact that nobody is reading it - and says nothing at all when someone is.
test_fleet_mail_doctor_line_names_the_mailbox_nobody_reads() {
  _fleet_setup
  assert_contains "$(fleet_mail_doctor_line alpha)" "alpha: root has 1 unread"
  assert_contains "$(fleet_mail_doctor_line alpha)" "nobody reading it"
  assert_eq "$(fleet_mail_doctor_line beta)" ""
  mkdir -p "$CEL_PROC_DIR/4242"
  printf 'CEL_ROLE=console\0' > "$CEL_PROC_DIR/4242/environ"
  assert_eq "$(fleet_mail_doctor_line alpha)" ""
  _fleet_teardown
}

# A root mailbox that does not parse is UNKNOWN in every view, never 0: the
# json counts are null and say corrupt, the text says so, and so does doctor.
test_fleet_shows_a_corrupt_root_mailbox_as_unknown_not_zero() {
  _fleet_setup
  local f="$CEL_INBOX_DIR/alpha.jsonl"
  { printf 'not json\n'; cat "$f"; } > "$T/torn"; cat "$T/torn" > "$f"
  local doc alpha
  doc="$(cmd_fleet --json)"
  alpha="$(printf '%s' "$doc" | jq -c '.workspaces[] | select(.name=="alpha")')"
  assert_eq "$(printf '%s' "$alpha" | jq -c '{root, unread: .mail.to_root_unread, corrupt: .mail.corrupt, orch_counted: ([.orchestrators[] | select(.unread != null or .open != null)] | length)}')" \
    '{"root":{"unread":null,"open":null},"unread":null,"corrupt":true,"orch_counted":0}'
  assert_contains "$(cmd_fleet)" "root mail: UNKNOWN (mailbox corrupt)"
  assert_contains "$(fleet_mail_doctor_line alpha)" "alpha: root's mailbox $f is corrupt"
  _fleet_teardown
}

# --- the cost of the read is itself a fact the suite holds -----------------
#
# Nothing on the read's path talks to a network; its cost is fork and exec. A
# performance fix with no test rots, so the budget is asserted: every binary
# the read can reach is shimmed onto PATH and logs its argv, and the count
# must stay under a ceiling.

# The shim: a counter in front of EVERY binary the read can reach, not just jq
# and git - a budget that only watches the tools you were thinking about rots
# the moment someone reaches for another. PATH is REPLACED rather than
# prepended, so a tool nobody listed here cannot run at all and the render
# fails loudly instead of slipping past uncounted.
_FLEET_SHIMMED_TOOLS=(
  awk sed grep cut tr head tail sort uniq wc find stat readlink dirname
  basename date id ls cat rm mkdir mktemp touch flock xargs getent ps
  bash sh env jq git yq node python3 cksum md5sum mv cp chmod ln sleep tee expr seq
)
_fleet_spawn_shim() { # -> $T/shim, the whole PATH; argv lands in CEL_SPAWN_LOG
  local s="$T/shim" b real
  mkdir -p "$s"
  export CEL_SPAWN_LOG="$T/spawns.log"
  : >"$CEL_SPAWN_LOG"
  for b in "${_FLEET_SHIMMED_TOOLS[@]}"; do
    real="$(command -v "$b" 2>/dev/null)" || continue
    [ -n "$real" ] || continue
    cat >"$s/$b" <<SHIM
#!/bin/bash
printf '%s\t%s\n' "$b" "\${*//$'\\n'/ }" >>"\$CEL_SPAWN_LOG"
exec "$real" "\$@"
SHIM
    chmod +x "$s/$b"
  done
}

# THE BOX'S PROCESS TABLE IS NOT THIS FIXTURE'S BUSINESS. `fleet_orphans_json`
# walks every pid on the machine (lib/orphans.sh), which dominates a real
# `cel fleet`'s process count and is outside anything a fixture can arrange.
# It is stubbed for the same reason `_fleet_stub_memory` stubs the memory
# walk: what is budgeted here is what lib/fleet.sh does, and a number
# that moves with whatever else is running on the box budgets nothing.
_fleet_stub_box_walk() {
  orphans_list() { :; }
  orphans_totals() { printf '0 0\n'; }
}

_fleet_spawns() { # [binary] -> how many processes were started, in all or of one
  if [ $# -eq 0 ]; then grep -c . "$CEL_SPAWN_LOG" || true; return 0; fi
  grep -c "^$1	" "$CEL_SPAWN_LOG" || true
}

# THE CEILING IS ON EVERY PROCESS, NOT ON jq AND git ALONE.
#
# It is the TOTAL, with the box walk stubbed and PATH REPLACED by the shim so
# nothing can run uncounted: a jq traded for an awk is the same cost wearing
# different clothes. Most of the cost belongs to other
# libraries reading their own documents (`cksum` and `md5sum` per file for
# lib/yaml.sh's cache key, `yq` per YAML, and the jq those accessors run), so
# it moves when they do: re-measure against the main the branch sits on
# before moving the ceiling, and keep only a few processes of slack above the
# measurement. One jq per render validates the roster, which is a process
# well spent. Per-workspace fields (agent rows, mail counts) are folded into
# existing jq rather than paid for with new processes.
_fleet_assert_budget() { # <total-spawns>
  local total="$1"
  local max=187
  if [ "$total" -gt "$max" ]; then
    printf 'the read started %s processes, over the ceiling of %s\n' \
      "$total" "$max" >&2
    printf 'by tool:\n%s\n' "$(cut -f1 "$CEL_SPAWN_LOG" | sort | uniq -c | sort -rn | head -10)" >&2
    return 1
  fi
  return 0
}

test_fleet_stays_under_its_spawn_budget() {
  _fleet_setup
  _fleet_stub_memory
  export CEL_CACHE="$T/nocache"
  _fleet_declare_bundle
  local rc=0
  _fleet_stub_box_walk
  _fleet_spawn_shim
  PATH="$T/shim:$T/bin" cmd_fleet --json >/dev/null
  _fleet_assert_budget "$(_fleet_spawns)" || rc=1
  _fleet_teardown
  return "$rc"
}

# THE DOCUMENT DOES NOT MOVE. The answer must match this capture of
# `cel fleet --json` on this fixture, compact and in order, so a field that
# silently reorders or loses its type fails here. The box, subscriptions and
# orphan fields are the live machine's and are not part of the capture; paths
# and the age of the oldest unread are normalised for the same reason.
# Re-capture it deliberately when a change adds or reorders fields.
_FLEET_GOLDEN_WORKSPACES='[{"name":"alpha","root":{"unread":1,"open":0},"mail":{"to_root_unread":1,"oldest_secs":1,"reader":""},"units":[{"name":"bundle","mode":"solo","orch":"LIVE","orch_rss_mb":120,"repos":["widget","gadget"],"declared":true,"solo_worktrees":0,"lanes":[]}]},{"name":"beta","root":{"unread":0,"open":0},"mail":{"to_root_unread":0,"oldest_secs":0,"reader":""},"units":[{"name":"gadget","mode":"solo","orch":"-","orch_rss_mb":0,"repos":["gadget"],"declared":false,"solo_worktrees":0,"lanes":[]}]}]'

_fleet_normalise() { # < doc -> .workspaces, paths and ages made reproducible
  jq -c --arg t "$T" '
    .workspaces
    | map(del(.orchestrators))
    | walk(if type == "string" then sub("\\Q" + $t + "\\E"; "T") else . end)
    # The oldest unread is measured from a fixed timestamp in the
    # fixture against the clock, so it grows by a second every second.
    | walk(if type == "object" and has("oldest_secs")
           then .oldest_secs = (if .oldest_secs > 0 then 1 else 0 end)
           else . end)'
}

test_fleet_json_is_identical_to_the_document_captured_before_the_rewrite() {
  _fleet_setup
  _fleet_stub_memory
  export CEL_CACHE="$T/nocache"
  _fleet_declare_bundle
  local got rc=0
  got="$(cmd_fleet --json | _fleet_normalise)"
  assert_eq "$got" "$_FLEET_GOLDEN_WORKSPACES" || rc=1
  _fleet_teardown
  return "$rc"
}

# AN UNREADABLE ROSTER IS A MUTE OBSERVER, NOT EVIDENCE.
#
# `herdr agent list` answering with non-empty MALFORMED JSON, exiting
# non-zero, or answering with a well-formed document about something other
# than agents (`{}`, `[]`, an error envelope, `agents` as an object) has said
# nothing about who is alive. Every one of them is the no-roster path: the
# agent reads `-`, a fact about the observer, and the read still completes.
_fleet_roster_says_nothing() { # <stdout-of-herdr-agent-list>
  cat >"$T/bin/herdr" <<HERDR
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent list") printf '%s\n' '$1' ;;
  *) printf '%s\n' '{}' ;;
esac
HERDR
  chmod +x "$T/bin/herdr"
  local u
  u="$(cmd_fleet --json --workspace alpha | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch')" "-"
}

test_fleet_a_roster_that_is_not_json_convicts_nobody() {
  _fleet_setup
  local u
  u="$(STUB_HERDR_BAD=1 cmd_fleet --json --workspace alpha | jq -c '.workspaces[0].units[] | select(.name=="widget")')"
  assert_eq "$(printf '%s' "$u" | jq -r '.orch')" "-"
  _fleet_teardown
}

test_fleet_an_empty_object_roster_convicts_nobody() {
  _fleet_setup
  _fleet_roster_says_nothing '{}'
  _fleet_teardown
}

test_fleet_an_array_roster_convicts_nobody() {
  _fleet_setup
  _fleet_roster_says_nothing '[]'
  _fleet_teardown
}

# Plausible, well-formed, and about the wrong thing: a result with no agents
# key at all, and an `agents` that is an object rather than a list.
test_fleet_a_plausible_but_wrong_roster_convicts_nobody() {
  _fleet_setup
  _fleet_roster_says_nothing '{"result":{"windows":[{"pane_id":"wA:p2"}]}}'
  _fleet_roster_says_nothing '{"result":{"agents":{"wA:p2":"idle"}}}'
  _fleet_roster_says_nothing '{"error":"no server"}'
  _fleet_teardown
}

# THE WHOLE DOCUMENT IS CACHED. A second call inside `fleet.cache_secs` is
# served from the cache under $CEL_CACHE without re-reading a single
# workspace; `--fresh` re-reads.
test_fleet_serves_a_young_cache_and_fresh_rereads() {
  _fleet_setup
  export CEL_CACHE="$T/cache" CEL_FLEET_CACHE_SECS=30
  eval "$(declare -f _fleet_workspace | sed '1s/_fleet_workspace/_fleet_workspace_real/')"
  _fleet_workspace() { printf 'x\n' >>"$T/reads"; _fleet_workspace_real "$@"; }
  local a b
  a="$(cmd_fleet --json)"
  assert_eq "$(wc -l <"$T/reads" | tr -d ' ')" "2"
  b="$(cmd_fleet --json)"
  assert_eq "$b" "$a"
  assert_eq "$(wc -l <"$T/reads" | tr -d ' ')" "2"
  cmd_fleet --json --fresh >/dev/null
  assert_eq "$(wc -l <"$T/reads" | tr -d ' ')" "4"
  unset CEL_CACHE CEL_FLEET_CACHE_SECS
  _fleet_teardown
}

# A young cache file that is not a fleet document (truncated by a full disk,
# or overwritten by hand) must not be served as is, or `cel fleet` prints an
# empty board with success. A cached read is re-validated before it is used.
test_fleet_rereads_when_the_young_cache_is_corrupt() {
  _fleet_setup
  export CEL_CACHE="$T/cache" CEL_FLEET_CACHE_SECS=30
  mkdir -p "$CEL_CACHE"
  printf 'not json{\n' >"$CEL_CACHE/fleet.json"
  local out; out="$(cmd_fleet --json)"
  assert_eq "$(printf '%s' "$out" | jq -e '.workspaces | type' 2>/dev/null)" '"array"'
  unset CEL_CACHE CEL_FLEET_CACHE_SECS
  _fleet_teardown
}

# One row per orchestrator in the fleet document, so the console reads
# it rather than running probes of its own - live ones with their launch line,
# and a product whose mode is auto but has no agent as `missing`.
test_fleet_json_carries_an_orchestrator_row_per_product() {
  source "$CEL_ROOT/tests/lib/orch-stub.sh"
  orch_stub_setup omp
  # a second product, inserted into the repos list (the stub appended runtime: after it)
  sed -i 's/^    gate: bun test$/&\n  - name: gadget\n    url: git@github.com:someone\/gadget.git\n    prefix: WGT\n    gate: bun test/' "$T/ws/workspace.yaml"
  printf 'layout: { orchestrators: auto }\n' >> "$T/ws/workspace.yaml"
  mkdir -p "$T/ws/repos/gadget"
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_proc 100 widget-orch "$T/ws" omp
  local doc w g
  doc="$(_fleet_doc alpha)"
  w="$(printf '%s' "$doc" | jq -c '.workspaces[0].orchestrators[] | select(.name == "widget-orch")')"
  g="$(printf '%s' "$doc" | jq -c '.workspaces[0].orchestrators[] | select(.name == "gadget-orch")')"
  assert_eq "$(jq -r '.launch' <<<"$w")" "stale"
  assert_eq "$(jq -r '.status' <<<"$w")" "idle"
  assert_eq "$(jq -r '.pane' <<<"$w")" "w1:p1"
  assert_eq "$(jq -r '.ws' <<<"$w")" "alpha"
  assert_contains "$(jq -r '.detail' <<<"$w")" "missing:"
  assert_eq "$(jq -r '.unread | type' <<<"$w")" "number"
  assert_eq "$(jq -r '.open | type' <<<"$w")" "number"
  assert_eq "$(jq -r '.launch' <<<"$g")" "missing"
  assert_eq "$(jq -r '.status' <<<"$g")" "gone"
  orch_stub_teardown
}

# ONE RESOLVER. `cel fleet`'s orchestrator mode is ws_orchestrator_mode's,
# never a second derivation: a local `manual` over a layout `none` stays
# none, and over a layout `auto` reads manual - in both views alike.
test_fleet_orchestrator_mode_is_ws_orchestrator_mode() {
  source "$CEL_ROOT/tests/lib/orch-stub.sh"
  orch_stub_setup omp
  export CEL_YAML_CACHE="$T/yaml-cache"
  printf 'products:\n  - name: bundle\n    repos: [widget]\nlayout: { orchestrators: none }\n' >> "$T/ws/workspace.yaml"
  printf 'products:\n  - name: bundle\n    orchestrator: manual\n' > "$T/ws/workspace.local.yaml"
  local lay mode
  for lay in none auto; do
    sed -i "s/^layout: { orchestrators: .* }\$/layout: { orchestrators: $lay }/" "$T/ws/workspace.yaml"
    mode="$(run_orchestrator_candidates alpha "$T/ws" '{"result":{"agents":[]}}' \
      | while IFS=$'\t' read -r r p _ _ m _; do [ "$r/$p" = orchestrator/bundle ] && printf '%s' "$m"; done)"
    assert_eq "$mode" "$(ws_orchestrator_mode "$T/ws" bundle | cut -f1)" || { orch_stub_teardown; return 1; }
  done
  assert_eq "$mode" manual
  sed -i 's/^layout: { orchestrators: .* }$/layout: { orchestrators: none }/' "$T/ws/workspace.yaml"
  assert_eq "$(ws_orchestrator_mode "$T/ws" bundle)" "$(printf 'none\tlayout')"
  unset CEL_YAML_CACHE
  orch_stub_teardown
}

# An orchestrator's mailbox is the alias rule's name for "<product>-orch", not
# the bare string. A 31-character product makes the 32-character cut end in a
# dash (the shape `cel inbox migrate` repairs), and a longer one is cut
# mid-word; the row must read THAT mailbox and THAT cursor, holes included.
test_fleet_orchestrator_row_reads_the_cut_mailbox_and_its_cursor_holes() {
  source "$CEL_ROOT/tests/lib/orch-stub.sh"
  orch_stub_setup omp
  local p31="gadget-platform-engine-products" p40="gadget-platform-engine-products-extended" p
  assert_eq "${#p31}" "31" || return 1
  for p in "$p31" "$p40"; do mkdir -p "$T/ws/repos/$p"; done
  sed -i "s/^    gate: bun test\$/&\n  - name: $p31\n    url: git@github.com:someone\/$p31.git\n    prefix: WGA\n    gate: bun test\n  - name: $p40\n    url: git@github.com:someone\/$p40.git\n    prefix: WGB\n    gate: bun test/" "$T/ws/workspace.yaml"
  printf 'layout: { orchestrators: auto }\n' >> "$T/ws/workspace.yaml"
  local box31 box40
  box31="$(_run_agent_name "$p31-orch")"; box40="$(_run_agent_name "$p40-orch")"
  assert_eq "${box31: -1}" "-" || return 1                  # the migratable shape
  export CEL_INBOX_DIR="$T/inbox"; mkdir -p "$CEL_INBOX_DIR"
  local f="$CEL_INBOX_DIR/alpha.jsonl" i
  for i in 1 2 3 4; do
    jq -nc --arg id "17921580000000000$i" --arg to "$box31" '{id:$id,to:$to,from:"x",kind:"status",message:"m"}' >> "$f"
    jq -nc --arg id "17921580000000001$i" --arg to "$box40" '{id:$id,to:$to,from:"x",kind:"status",message:"m"}' >> "$f"
  done
  # box31 read up to the 3rd with the 1st still unread (a hole); box40 read up to the 2nd
  printf '179215800000000003\n179215800000000001\n' > "$CEL_INBOX_DIR/alpha.$box31.cursor"
  printf '179215800000000012' > "$CEL_INBOX_DIR/alpha.$box40.cursor"
  orch_stub_roster widget-orch "$T/ws/repos/widget" idle "$T/s.jsonl"
  orch_stub_proc 100 widget-orch "$T/ws" omp
  local doc
  doc="$(_fleet_doc alpha)"
  assert_eq "$(jq -r --arg p "$p31" '.workspaces[0].orchestrators[] | select(.product == $p) | .unread' <<<"$doc")" "2"  # hole + 4th
  assert_eq "$(jq -r --arg p "$p40" '.workspaces[0].orchestrators[] | select(.product == $p) | .unread' <<<"$doc")" "2"  # 3rd + 4th
  orch_stub_teardown
}

# SERVE STALE, REFILL IN THE BACKGROUND. An expired cache is served at once
# and rebuilt in a detached session: a rebuild run inline by a caller that
# times out never writes the cache, so every refresh would find it expired
# and repeat the killed work.
_fleet_seed_old_cache() { # -> $CEL_CACHE/fleet.json, a valid document 10 min old
  mkdir -p "$CEL_CACHE"
  printf '{"workspaces":[],"marker":"old"}\n' >"$CEL_CACHE/fleet.json"
  touch -d '10 minutes ago' "$CEL_CACHE/fleet.json"
}
_fleet_wait_refilled() { # -> 0 once the cache is no longer the seeded one
  local i
  for ((i = 0; i < 300; i++)); do
    if ! grep -q '"marker":"old"' "$CEL_CACHE/fleet.json" 2>/dev/null \
       && jq -e '.workspaces | type == "array"' "$CEL_CACHE/fleet.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

test_fleet_serves_an_expired_cache_at_once_and_refills_it_behind() {
  _fleet_setup
  export CEL_CACHE="$T/cache" CEL_FLEET_CACHE_SECS=30 CEL_FLEET_REFILL_DELAY=2
  _fleet_seed_old_cache
  local out s e
  s="$(date +%s%N)"
  out="$(cmd_fleet --json)"
  e="$(date +%s%N)"
  assert_eq "$(jq -r '.marker' <<<"$out")" "old"
  [ $(( (e - s) / 1000000 )) -lt 1500 ] || { echo "took $(( (e - s) / 1000000 )) ms" >&2; return 1; }
  _fleet_wait_refilled || { echo "the refill never wrote the cache" >&2; return 1; }
  assert_eq "$(jq -r '.generated_at | type' "$CEL_CACHE/fleet.json")" "string"
  unset CEL_CACHE CEL_FLEET_CACHE_SECS CEL_FLEET_REFILL_DELAY
  _fleet_teardown
}

test_fleet_refill_survives_the_caller_being_killed() {
  _fleet_setup
  export CEL_CACHE="$T/cache" CEL_FLEET_CACHE_SECS=30 CEL_FLEET_REFILL_DELAY=2
  _fleet_seed_old_cache
  # The console's timeout, simulated: the caller's whole process group is
  # killed while the refill is still sleeping.
  setsid bash -c '. "$CEL_ROOT/lib/common.sh"; . "$CEL_ROOT/lib/fleet.sh"; cmd_fleet --json >/dev/null; sleep 30' &
  local caller=$!
  sleep 0.7
  kill -KILL -- "-$caller" 2>/dev/null || kill -KILL "$caller" 2>/dev/null || true
  wait "$caller" 2>/dev/null || true
  _fleet_wait_refilled || { echo "killing the caller killed the refill" >&2; return 1; }
  unset CEL_CACHE CEL_FLEET_CACHE_SECS CEL_FLEET_REFILL_DELAY
  _fleet_teardown
}

test_fleet_two_callers_on_an_expired_cache_start_one_refill() {
  _fleet_setup
  export CEL_CACHE="$T/cache" CEL_FLEET_CACHE_SECS=30 CEL_FLEET_REFILL_DELAY=2
  export CEL_FLEET_REFILL_LOG="$T/refills.log"
  _fleet_seed_old_cache
  cmd_fleet --json >/dev/null
  cmd_fleet --json >/dev/null
  _fleet_wait_refilled || { echo "no refill" >&2; return 1; }
  sleep 0.3
  assert_eq "$(grep -c . "$CEL_FLEET_REFILL_LOG")" "1"
  unset CEL_CACHE CEL_FLEET_CACHE_SECS CEL_FLEET_REFILL_DELAY CEL_FLEET_REFILL_LOG
  _fleet_teardown
}

test_fleet_with_no_cache_builds_inline() {
  _fleet_setup
  export CEL_CACHE="$T/cache" CEL_FLEET_CACHE_SECS=30
  local out; out="$(cmd_fleet --json)"
  assert_eq "$(jq -r '.workspaces | length' <<<"$out")" "2"
  assert_eq "$(jq -r '.generated_at | type' <<<"$out")" "string"
  assert_eq "$(jq -c '.workspaces' "$CEL_CACHE/fleet.json")" "$(jq -c '.workspaces' <<<"$out")"
  unset CEL_CACHE CEL_FLEET_CACHE_SECS
  _fleet_teardown
}

test_fleet_write_keeps_the_old_cache_when_the_build_fails() {
  _fleet_setup
  mkdir -p "$T/c"
  printf '%s\n' '{"workspaces":[{"name":"good"}]}' >"$T/c/fleet.json"
  _fleet_doc() { printf ''; }
  _fleet_write "$T/c/fleet.json" "" >/dev/null || true
  assert_eq "$(jq -r '.workspaces[0].name' "$T/c/fleet.json")" "good"
  _fleet_doc() { printf 'not json'; }
  _fleet_write "$T/c/fleet.json" "" >/dev/null || true
  assert_eq "$(jq -r '.workspaces[0].name' "$T/c/fleet.json")" "good"
  assert_eq "$(ls "$T/c" | grep -c tmp)" "0"
  unset -f _fleet_doc
  source "$CEL_ROOT/lib/fleet.sh"
  _fleet_teardown
}

# A cache written by an older cel has no generated_at; serving it must still
# say how old it is (from the file's mtime) and carry cache_secs.
test_fleet_serves_a_pre_cel90_cache_with_its_age_and_cache_secs() {
  _fleet_setup
  export CEL_CACHE="$T/cache" CEL_FLEET_CACHE_SECS=30 CEL_FLEET_REFILL_DELAY=60
  mkdir -p "$CEL_CACHE"
  printf '%s\n' '{"workspaces":[]}' >"$CEL_CACHE/fleet.json"
  touch -d '@1700000000' "$CEL_CACHE/fleet.json"
  local out; out="$(cmd_fleet --json)"
  assert_eq "$(jq -r '.generated_at' <<<"$out")" "2023-11-14T22:13:20Z"
  assert_eq "$(jq -r '.cache_secs' <<<"$out")" "30"
  unset CEL_CACHE CEL_FLEET_CACHE_SECS CEL_FLEET_REFILL_DELAY
  _fleet_teardown
}

# A REGISTERED SERVER IS PART OF THE BOX. `cel fleet` carries each one with its
# owner, port and memory, and says which are permanent - in the document and
# on its workspace's block.
_fleet_servers_down() { unset CEL_SERVE_STATE CEL_SERVE_SYSTEMCTL CEL_SERVE_CGROUP_ROOT; _fleet_teardown; }
# A user manager answering one batched `show -p Id -p ControlGroup <unit>...`:
# each unit's cgroup is /app/<unit>; shop-server's holds 117 MB.
_fleet_serve_stub() {
  export CEL_SERVE_STATE="$T/serve" CEL_SERVE_SYSTEMCTL="$T/systemctl" CEL_SERVE_CGROUP_ROOT="$T/cgroup"
  mkdir -p "$CEL_SERVE_STATE" "$T/cgroup/app/shop-server.service"
  printf '%s\n' 123456789 > "$T/cgroup/app/shop-server.service/memory.current"
  cat > "$CEL_SERVE_SYSTEMCTL" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *.service) printf 'Id=%s\nControlGroup=/app/%s\n\n' "$a" "$a" ;; esac; done
EOS
  chmod +x "$CEL_SERVE_SYSTEMCTL"
}
test_fleet_lists_registered_servers_with_owner_port_memory_and_permanence() {
  _fleet_setup
  _fleet_serve_stub
  jq -n '{name:"shop-server",unit:"shop-server",kind:"unit",owner:"shop-orch",workspace:"alpha",port:8090,started_at:100,permanent:true,ttl_seconds:null}' \
    > "$CEL_SERVE_STATE/shop-server.json"
  local doc out
  doc="$(cmd_fleet --json)"
  assert_eq "$(printf '%s' "$doc" | jq -c '.box.servers')" \
    '[{"name":"shop-server","owner":"shop-orch","workspace":"alpha","port":8090,"memory_mb":117,"permanent":true}]' \
    || { _fleet_servers_down; return 1; }
  out="$(cmd_fleet --workspace alpha)"
  assert_contains "$out" "server shop-server" || { _fleet_servers_down; return 1; }
  assert_contains "$out" "permanent" || { _fleet_servers_down; return 1; }
  case "$(cmd_fleet --workspace beta)" in *shop-server*) echo "beta's block listed alpha's server"; _fleet_servers_down; return 1 ;; esac
  _fleet_servers_down
}

# THE SERVERS COST THE READ A CONSTANT, NOT A PRICE PER SERVER: the records
# are read in one pass and every unit's cgroup asked of the user manager once.
test_fleet_server_records_cost_a_constant_number_of_processes() {
  _fleet_setup
  _fleet_stub_memory
  export CEL_CACHE="$T/nocache"
  _fleet_declare_bundle
  _fleet_stub_box_walk
  _fleet_serve_stub
  _fleet_spawn_shim
  local base with n rc=0
  PATH="$T/shim:$T/bin" cmd_fleet --json >/dev/null
  base="$(_fleet_spawns)"
  for n in 1 2 3 4 5; do
    jq -n --arg n "web-$n" '{name:$n,unit:$n,kind:"unit",owner:"shop-orch",workspace:"alpha",port:8090,started_at:100,ttl_seconds:3600}' > "$CEL_SERVE_STATE/web-$n.json"
  done
  jq -n '{name:"shop-server",unit:"shop-server",kind:"unit",owner:"shop-orch",workspace:"alpha",port:8090,started_at:100,permanent:true,ttl_seconds:null}' > "$CEL_SERVE_STATE/shop-server.json"
  jq -n '{name:"pid-3999999",kind:"pid",pid:3999999,pid_start:"1",owner:"shop-orch",workspace:"alpha",port:0,started_at:100,permanent:true,ttl_seconds:null}' > "$CEL_SERVE_STATE/pid-3999999.json"
  : > "$CEL_SPAWN_LOG"
  PATH="$T/shim:$T/bin" cmd_fleet --json > "$T/doc.json"
  with="$(_fleet_spawns)"
  assert_eq "$(jq '.box.servers | length' "$T/doc.json")" 7 || rc=1
  assert_eq "$(jq '[.box.servers[] | select(.name == "shop-server")][0].memory_mb' "$T/doc.json")" 117 || rc=1
  if [ "$((with - base))" -gt 4 ]; then
    echo "seven server records cost $((with - base)) processes over none (want at most 4)"
    cut -f1 "$CEL_SPAWN_LOG" | sort | uniq -c | sort -rn | head -5; rc=1
  fi
  _fleet_assert_budget "$with" || rc=1
  _fleet_servers_down
  return "$rc"
}
