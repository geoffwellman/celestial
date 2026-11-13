# shellcheck shell=bash
# workspace.local.yaml: the team contract stays in the committed
# workspace.yaml; a gitignored local file may change routing and per-box env,
# and nothing else. These tests pin both halves of that line.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/ws.sh"
source "$CEL_ROOT/lib/profiles.sh"
source "$CEL_ROOT/lib/manifest.sh"
source "$CEL_ROOT/lib/doctor.sh"

_wl_setup() {
  T="$(mktemp -d)"
  CEL_REGISTRY="$T/registry.yaml"
  CEL_YAML_CACHE="$T/cache"
  mkdir -p "$T/alpha"
  cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/alpha/workspace.yaml"
}

# THE CACHE IS KEYED ON CONTENT. An in-place edit that keeps the inode, the
# size and the timestamp (two saves in one second, a restored mtime) must be
# read, not served from the copy of the old text.
test_yaml_cache_sees_a_same_size_same_mtime_edit() {
  local T; T="$(mktemp -d)"
  local CEL_YAML_CACHE="$T/cache"
  printf 'name: aaaa\n' > "$T/w.yaml"; touch -d '2020-01-01 00:00:00' "$T/w.yaml"
  assert_eq "$(_yqr -r .name "$T/w.yaml")" aaaa
  printf 'name: bbbb\n' > "$T/w.yaml"; touch -d '2020-01-01 00:00:00' "$T/w.yaml"
  assert_eq "$(_yqr -r .name "$T/w.yaml")" bbbb
  rm -rf "$T"
}

# NO HASH, NO CACHE. Where md5sum cannot run, an edit must still be read: a
# key that cannot see the content would pin the first parse forever - for a
# plain file and for the workspace.local.yaml merge alike.
test_yaml_cache_rereads_an_edit_when_md5sum_is_unavailable() {
  local T; T="$(mktemp -d)"
  local CEL_YAML_CACHE="$T/cache"
  md5sum() { return 127; }
  printf 'name: aaaa\n' > "$T/w.yaml"
  assert_eq "$(_yqr -r .name "$T/w.yaml")" aaaa
  printf 'name: bbbbbb\n' > "$T/w.yaml"
  assert_eq "$(_yqr -r .name "$T/w.yaml")" bbbbbb
  mkdir -p "$T/ws"; printf 'name: ws\nenv: {A: base}\n' > "$T/ws/workspace.yaml"
  printf 'env: {A: one}\n' > "$T/ws/workspace.local.yaml"
  assert_eq "$(_yqr_ws -r .env.A "$T/ws")" one
  printf 'env: {A: two}\n' > "$T/ws/workspace.local.yaml"
  assert_eq "$(_yqr_ws -r .env.A "$T/ws")" two
  unset -f md5sum
  rm -rf "$T"
}

# CONCURRENT FIRST READS SHARE ONE CACHE ENTRY. Background subshells and
# process substitutions all have the parent's $$, so a temp named with it is
# one file for all of them: one rename wins and every other reader failed.
# The converters are slowed so the first reads overlap every time.
_wl_race() { # <out-prefix> <reader...> - six background readers and two <( )
  local p="$1" i; shift
  for i in 1 2 3 4 5 6; do
    ( rc=0; "$@" > "$p.out.$i" 2>/dev/null || rc=$?; printf '%s' "$rc" > "$p.rc.$i" ) &
  done
  cat <(rc=0; "$@" 2>/dev/null || rc=$?; printf ' rc=%s\n' "$rc") \
    <(rc=0; "$@" 2>/dev/null || rc=$?; printf ' rc=%s\n' "$rc") > "$p.ps"
  wait
}
test_yaml_cache_concurrent_first_reads_all_succeed_and_leave_no_temps() {
  local T; T="$(mktemp -d)"
  local CEL_YAML_CACHE="$T/cache" i
  yq() { command yq "$@"; local rc=$?; sleep 0.3; return "$rc"; }
  jq() { command jq "$@"; local rc=$?; [ "$1" = -s ] && sleep 0.3; return "$rc"; }
  printf 'name: racy\n' > "$T/w.yaml"
  _wl_race "$T/plain" _yqr -r .name "$T/w.yaml"
  mkdir -p "$T/ws"; printf 'name: ws\nenv: {A: base}\n' > "$T/ws/workspace.yaml"
  printf 'env: {A: local}\n' > "$T/ws/workspace.local.yaml"
  _wl_race "$T/merged" _yqr_ws -r .env.A "$T/ws"
  unset -f yq jq
  for i in 1 2 3 4 5 6; do
    assert_eq "$(cat "$T/plain.rc.$i"):$(cat "$T/plain.out.$i")" "0:racy"
    assert_eq "$(cat "$T/merged.rc.$i"):$(cat "$T/merged.out.$i")" "0:local"
  done
  assert_eq "$(cat "$T/plain.ps")" $'racy\n rc=0\nracy\n rc=0'
  assert_eq "$(cat "$T/merged.ps")" $'local\n rc=0\nlocal\n rc=0'
  assert_eq "$(find "$T/cache" -name '*tmp*' | wc -l)" 0
  rm -rf "$T"
}

# A LOST RENAME IS NOT A FAILED READ. If the publish cannot rename (another
# reader's entry already stands there), a valid destination is the answer.
test_yaml_cache_lost_rename_with_a_valid_entry_is_success() {
  local T; T="$(mktemp -d)"
  local CEL_YAML_CACHE="$T/cache" j
  printf 'name: kept\n' > "$T/w.yaml"
  j="$(_yaml_json "$T/w.yaml")"
  rm -f "$j"
  mv() { printf '{"name":"kept"}' > "${@: -1}"; return 1; }
  assert_eq "$(_yqr -r .name "$T/w.yaml")" kept
  mv() { return 1; }
  rm -f "$j"
  if _yaml_json "$T/w.yaml" >/dev/null 2>&1; then printf 'lost rename with no entry succeeded\n' >&2; unset -f mv; return 1; fi
  unset -f mv
  assert_eq "$(find "$T/cache" -name '*tmp*' | wc -l)" 0
  rm -rf "$T"
}

# WITHOUT A CONTENT HASH THE SHORTCUT IS OFF. A `nohash-` key is one name for
# every text, so a valid entry standing after a lost rename may be an older
# text's parse: md5sum is hidden from PATH, the file changes between reads,
# and every read is the new text or a failure - never the old entry.
test_yaml_cache_without_md5sum_never_serves_an_older_entry_on_a_lost_rename() {
  local T; T="$(mktemp -d)"
  local CEL_YAML_CACHE="$T/cache" OLD_PATH="$PATH" d x
  mkdir -p "$T/bin"
  for d in ${PATH//:/ }; do
    for x in "$d"/*; do
      [ -x "$x" ] && [ "${x##*/}" != md5sum ] && [ ! -e "$T/bin/${x##*/}" ] && ln -s "$x" "$T/bin/${x##*/}"
    done
  done
  PATH="$T/bin"
  if command -v md5sum >/dev/null; then PATH="$OLD_PATH"; printf 'md5sum still on PATH\n' >&2; return 1; fi
  printf 'name: aaaa\n' > "$T/w.yaml"
  assert_eq "$(_yqr -r .name "$T/w.yaml")" aaaa
  printf 'name: bbbb\n' > "$T/w.yaml"
  assert_eq "$(_yqr -r .name "$T/w.yaml")" bbbb
  printf 'name: cccc\n' > "$T/w.yaml"
  mv() { return 1; }
  local out rc=0; out="$(_yqr -r .name "$T/w.yaml" 2>/dev/null)" || rc=$?
  mkdir -p "$T/ws"; printf 'name: ws\nenv: {A: base}\n' > "$T/ws/workspace.yaml"
  printf 'env: {A: one}\n' > "$T/ws/workspace.local.yaml"
  unset -f mv
  assert_eq "$(_yqr_ws -r .env.A "$T/ws")" one
  printf 'env: {A: two}\n' > "$T/ws/workspace.local.yaml"
  mv() { return 1; }
  local merged; merged="$(_yqr_ws -r .env.A "$T/ws" 2>/dev/null)" || true
  unset -f mv
  PATH="$OLD_PATH"
  [ "$rc" -ne 0 ] || { printf 'lost rename served [%s] for cccc\n' "$out" >&2; rm -rf "$T"; return 1; }
  [ "$merged" != one ] || { printf 'lost merge rename served the older local env\n' >&2; rm -rf "$T"; return 1; }
  assert_eq "$(find "$T/cache" -name '*tmp*' | wc -l)" 0
  rm -rf "$T"
}

# --- 1: every routing read goes through the merge ---------------------------
# A reader that asks workspace.yaml for role_profiles/worker_profiles directly
# silently ignores the local override - the person whose login can't reach the
# team's model gets it anyway. Code lines only (comments are prose); a read may
# span a `\` continuation, so the window is the line plus the next three,
# and it must name a reader (yq/jq/_yqr/readFile) - a message is not a read.
test_no_code_reads_routing_straight_from_workspace_yaml() {
  local f hits=""
  while IFS= read -r f; do
    case "$f" in lib/yaml.sh) continue ;; esac
    hits+="$(awk -v F="$f" '
      { line[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          l = line[i]; sub(/^[ \t]+/, "", l)
          if (l ~ /^(#|\/\/|\*)/) continue
          if (l !~ /(role_profiles|worker_profiles)/) continue
          if (l ~ /team-contract/) continue
          w = ""
          for (j = i; j <= i + 3 && j <= NR; j++) w = w line[j]
          if (w ~ /(^|[^a-z_])(yq|_yqr|jq|readFile|YAML\.parse)[^a-z_]/ && w ~ /workspace\.yaml/ && w !~ /workspace\.local\.yaml/) print F ":" i ": " line[i]
        }
      }' "$CEL_ROOT/$f")"
  done < <(cd "$CEL_ROOT" && git ls-files lib bin core tools | grep -Ev '\.(md|json|css|html)$')
  assert_eq "$hits" ""
}

# --- 2: everything else stays team-only -------------------------------------
test_a_local_policy_changes_neither_the_rendered_block_nor_the_merge_rule() {
  _wl_setup
  local before; before="$(ws_policy_block "$T/alpha")"
  cat > "$T/alpha/workspace.local.yaml" <<'YAML'
policy: { merge: self, workers: 9 }
worker_profiles:
  ben: { runtime: omp, model: other-model, for: bens box only }
YAML
  assert_eq "$(ws_policy "$T/alpha" merge)" "humans-only"
  assert_eq "$(ws_policy_block "$T/alpha")" "$before"
  local out; out="$(doctor_ws_local_lines "$T/alpha" alpha 2>&1)" || true
  assert_contains "$out" "'policy'"
  rm -rf "$T"
}

# --- 3: env: may be overridden per box; secrets still come from env.local ---
test_local_env_overrides_committed_env_and_env_local_still_wins() {
  _wl_setup
  yq -y '.env = {TMPDIR: "/tmp/team", KEEP: "yes"}' "$T/alpha/workspace.yaml" > "$T/w" \
    && mv "$T/w" "$T/alpha/workspace.yaml"
  printf 'env: { TMPDIR: /tmp/ana }\n' > "$T/alpha/workspace.local.yaml"
  printf 'SECRET_KEY=s3cret\n' > "$T/alpha/env.local"
  assert_eq "$(ws_env_get "$T/alpha" TMPDIR)" "/tmp/ana"
  assert_eq "$(ws_env_get "$T/alpha" KEEP)" "yes"
  local ex; ex="$(ws_env_exports "$T/alpha")"
  assert_eq "$(env -i bash -c "$ex"'; printf "%s|%s" "$TMPDIR" "$SECRET_KEY"')" "/tmp/ana|s3cret"
  local out; out="$(doctor_ws_local_lines "$T/alpha" alpha 2>&1)"
  assert_eq "$out" ""
  rm -rf "$T"
}

# --- 4: scaffolding ---------------------------------------------------------
test_ws_new_writes_the_local_example_and_ignore_rule() {
  _wl_setup
  printf '' | cmd_ws new t1 --kind team --org o --merge self --path "$T/t1" --no-remote >/dev/null
  [ -f "$T/t1/workspace.local.example.yaml" ]
  local ex; ex="$(cat "$T/t1/workspace.local.example.yaml")"
  assert_contains "$ex" "role_profiles"
  assert_contains "$ex" "worker_profiles"
  assert_contains "$ex" "env:"
  # fully commented: parses to nothing, so copying it changes nothing until edited
  assert_eq "$(grep -Ev '^[[:space:]]*(#|$)' "$T/t1/workspace.local.example.yaml")" ""
  assert_contains "$(cat "$T/t1/.gitignore")" "workspace.local.yaml"
  # the example is committed, the local file would be ignored
  git -C "$T/t1" ls-files --error-unmatch workspace.local.example.yaml >/dev/null
  touch "$T/t1/workspace.local.yaml"
  git -C "$T/t1" check-ignore -q workspace.local.yaml
  [ ! -f "$T/t1/workspace.local.yaml.bak" ]
  rm -rf "$T"
}

test_ws_sync_adds_a_missing_ignore_rule_and_leaves_the_local_file_alone() {
  _wl_setup
  printf '' | cmd_ws new t2 --kind team --org o --merge self --path "$T/t2" --no-remote >/dev/null
  grep -vxF 'workspace.local.yaml' "$T/t2/.gitignore" | grep -vxF '*.local.*' > "$T/g" || true
  mv "$T/g" "$T/t2/.gitignore"
  cmd_ws sync t2 >/dev/null
  assert_contains "$(cat "$T/t2/.gitignore")" "workspace.local.yaml"
  [ ! -e "$T/t2/workspace.local.yaml" ]
  printf 'role_profiles: { worker: mine }\n' > "$T/t2/workspace.local.yaml"
  local sum; sum="$(cksum < "$T/t2/workspace.local.yaml")"
  cmd_ws sync t2 >/dev/null
  assert_eq "$(cksum < "$T/t2/workspace.local.yaml")" "$sum"
  rm -rf "$T"
}

# --- 5: visibility ----------------------------------------------------------
test_doctor_says_which_keys_the_local_file_overrides() {
  _wl_setup
  printf 'role_profiles: { worker: mine }\nenv: { TMPDIR: /tmp/x }\n' > "$T/alpha/workspace.local.yaml"
  local out; out="$(doctor_ws_local_summary "$T/alpha" alpha 2>&1)"
  assert_contains "$out" "workspace.local.yaml in effect"
  assert_contains "$out" "role_profiles"
  assert_contains "$out" "env"
  rm "$T/alpha/workspace.local.yaml"
  out="$(doctor_ws_local_summary "$T/alpha" alpha 2>&1)"
  assert_contains "$out" "no workspace.local.yaml"
  rm -rf "$T"
}

test_doctor_fails_when_workspace_yaml_is_not_committed() {
  _wl_setup
  git -C "$T/alpha" init -q
  local out rc=0
  out="$(doctor_ws_contract_lines "$T/alpha" alpha 2>&1)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "team contract"
  printf 'workspace.yaml\n' > "$T/alpha/.gitignore"
  rc=0; out="$(doctor_ws_contract_lines "$T/alpha" alpha 2>&1)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "gitignored"
  : > "$T/alpha/.gitignore"
  git -C "$T/alpha" add workspace.yaml
  git -C "$T/alpha" -c user.name=t -c user.email=t@t commit -qm init
  rc=0; out="$(doctor_ws_contract_lines "$T/alpha" alpha 2>&1)" || rc=$?
  assert_eq "$rc" "0"
  rm -rf "$T"
}

# --- malformed or out-of-scope local files ----------------------------------
test_doctor_warns_on_a_team_key_inside_a_local_repo_entry() {
  _wl_setup
  printf 'repos:\n  - name: widget\n    gate: "true"\n' > "$T/alpha/workspace.local.yaml"
  local out; out="$(doctor_ws_local_lines "$T/alpha" alpha 2>&1)" || true
  assert_contains "$out" "'gate'"
  rm -rf "$T"
}

test_a_wrongly_typed_local_key_falls_back_to_the_committed_routing() {
  _wl_setup
  yq -y '.role_profiles = {worker: "team"}' "$T/alpha/workspace.yaml" > "$T/w" && mv "$T/w" "$T/alpha/workspace.yaml"
  printf 'role_profiles: []\n' > "$T/alpha/workspace.local.yaml"
  assert_eq "$(role_profile "$T/alpha" worker 2>/dev/null)" "team"
  rm -rf "$T"
}

# --- 6: me: - which person this login is -----------------------------------
# `me:` is the one key the local file may set besides routing. It is read
# from the local file only: a `me:` committed to workspace.yaml would name the
# same person on every teammate's box, so the merge drops it.
test_local_me_overlays_and_a_committed_me_never_counts() {
  _wl_setup
  source "$CEL_ROOT/lib/workspace.sh"
  assert_eq "$(ws_me "$T/alpha")" ""
  printf 'me: sam\n' >> "$T/alpha/workspace.yaml"
  assert_eq "$(ws_me "$T/alpha")" ""
  printf 'me: jo\n' > "$T/alpha/workspace.local.yaml"
  assert_eq "$(ws_me "$T/alpha")" "jo"
  assert_eq "$(_yqr_ws -r .me "$T/alpha")" "jo"
  printf 'env: { A: b }\n' > "$T/alpha/workspace.local.yaml"
  assert_eq "$(ws_me "$T/alpha")" ""
  assert_eq "$(_yqr_ws -r '.me // "none"' "$T/alpha")" "none"
  # a malformed local file never lets the committed me through either
  printf 'me: [unclosed\n' > "$T/alpha/workspace.local.yaml"
  assert_eq "$(ws_me "$T/alpha" 2>/dev/null)" ""
  rm -rf "$T"
}

# A LOCAL FILE THAT PARSES BUT DOES NOT MERGE (`role_profiles: []`) costs the
# override: the merged view is workspace.yaml alone - committed me: included.
# Identity is never read from that view, so the committed me: still does not
# count, with or without a me: of its own in the local file.
test_a_committed_me_never_counts_when_the_local_file_fails_the_merge() {
  _wl_setup
  source "$CEL_ROOT/lib/workspace.sh"
  printf 'me: sam\n' >> "$T/alpha/workspace.yaml"
  printf 'role_profiles: []\n' > "$T/alpha/workspace.local.yaml"
  assert_eq "$(_yqr_ws -r '.me // ""' "$T/alpha" 2>/dev/null)" "sam"   # the fallback is the base file
  assert_eq "$(ws_me "$T/alpha" 2>/dev/null)" ""
  printf 'role_profiles: []\nme: jo\n' > "$T/alpha/workspace.local.yaml"
  assert_eq "$(ws_me "$T/alpha" 2>/dev/null)" "jo"
  # a me: that is not a person id string is no me
  printf 'me: [sam]\n' > "$T/alpha/workspace.local.yaml"
  assert_eq "$(ws_me "$T/alpha" 2>/dev/null)" ""
  printf 'just a string\n' > "$T/alpha/workspace.local.yaml"
  assert_eq "$(ws_me "$T/alpha" 2>/dev/null)" ""
  rm -rf "$T"
}
test_a_committed_me_never_counts_without_a_local_me() {
  _wl_setup
  source "$CEL_ROOT/lib/workspace.sh"
  printf 'me: sam\n' >> "$T/alpha/workspace.yaml"
  assert_eq "$(ws_me "$T/alpha")" ""                       # no local file
  printf 'role_profiles: { worker: mine }\n' > "$T/alpha/workspace.local.yaml"
  assert_eq "$(ws_me "$T/alpha")" ""                       # a local file with no me:
  rm -rf "$T"
}

test_me_is_the_only_newly_allowed_local_key() {
  _wl_setup
  source "$CEL_ROOT/lib/workspace.sh"
  assert_eq "$_WS_LOCAL_KEYS" "role_profiles worker_profiles env products repos me"
  printf 'me: sam\n' > "$T/alpha/workspace.local.yaml"
  assert_eq "$(doctor_ws_local_lines "$T/alpha" alpha 2>&1)" ""
  # people: and a product's home stay team-only: the merge drops them and
  # doctor says so
  yq -y '.products = [{name: "bundle", repos: ["widget"]}]' "$T/alpha/workspace.yaml" > "$T/w" \
    && mv "$T/w" "$T/alpha/workspace.yaml"
  cat > "$T/alpha/workspace.local.yaml" <<'YAML'
me: sam
people:
  - { id: sam, login: sam-example }
products:
  - name: bundle
    home: sam
YAML
  assert_eq "$(ws_people_json "$T/alpha")" "[]"
  assert_eq "$(ws_product_home "$T/alpha" bundle)" ""
  assert_eq "$(_yqr_ws -r '.people // "none"' "$T/alpha")" "none"
  local out; out="$(doctor_ws_local_lines "$T/alpha" alpha 2>&1)" || true
  assert_contains "$out" "'people'"
  assert_contains "$out" "'home'"
  rm -rf "$T"
}

test_ws_new_local_example_offers_me() {
  _wl_setup
  printf '' | cmd_ws new t3 --kind team --org o --merge self --path "$T/t3" --no-remote >/dev/null
  assert_contains "$(cat "$T/t3/workspace.local.example.yaml")" "# me: "
  rm -rf "$T"
}

# A LOCAL `orchestrator: manual` TURNS A PRODUCT'S AGENT OFF ON THIS BOX ONLY.
# It is honoured in the one direction that starts fewer agents: over a
# committed auto (on the product, the layout or the default) it wins and says
# it came from workspace.local.yaml; a local auto over a committed manual is
# ignored - a teammate's decision not to auto-start wins - and doctor says so.
_wl_orch() { # <committed orchestrator value or ''> <local orchestrator value or ''>
  _wl_setup
  source "$CEL_ROOT/lib/workspace.sh"
  yq -y --arg o "$1" '.products = [{name: "bundle", repos: ["widget"]} + (if $o == "" then {} else {orchestrator: $o} end)]' \
    "$T/alpha/workspace.yaml" > "$T/w" && mv "$T/w" "$T/alpha/workspace.yaml"
  [ -z "$2" ] || printf 'products:\n  - name: bundle\n    orchestrator: %s\n' "$2" > "$T/alpha/workspace.local.yaml"
}

test_local_manual_overrides_a_committed_auto() {
  _wl_orch auto manual
  assert_eq "$(ws_orchestrator_mode "$T/alpha" bundle)" "$(printf 'manual\tworkspace.local.yaml')"
  assert_eq "$(_yqr_ws -r '.products[0].orchestrator' "$T/alpha")" manual
  assert_eq "$(doctor_ws_local_lines "$T/alpha" alpha 2>&1)" ""
  # the committed file still says auto: only this box is off
  assert_eq "$(ws_product_get "$T/alpha" bundle orchestrator)" auto
  rm -rf "$T"
}

test_local_manual_overrides_an_inherited_auto() {
  _wl_orch '' manual
  yq -y '.layout = {orchestrators: "auto"}' "$T/alpha/workspace.yaml" > "$T/w" && mv "$T/w" "$T/alpha/workspace.yaml"
  assert_eq "$(ws_orchestrator_mode "$T/alpha" bundle)" "$(printf 'manual\tworkspace.local.yaml')"
  rm -rf "$T"
}

test_local_auto_never_overrides_a_committed_manual() {
  _wl_orch manual auto
  assert_eq "$(ws_orchestrator_mode "$T/alpha" bundle)" "$(printf 'manual\tproduct')"
  assert_eq "$(_yqr_ws -r '.products[0].orchestrator' "$T/alpha")" manual
  local out; out="$(doctor_ws_local_lines "$T/alpha" alpha 2>&1)" || true
  assert_contains "$out" "orchestrator: auto"
  assert_contains "$out" "ignored"
  rm -rf "$T"
}

test_no_local_orchestrator_leaves_the_mode_unchanged() {
  _wl_orch auto ''
  printf 'role_profiles: { worker: mine }\n' > "$T/alpha/workspace.local.yaml"
  assert_eq "$(ws_orchestrator_mode "$T/alpha" bundle)" "$(printf 'auto\tproduct')"
  rm -f "$T/alpha/workspace.local.yaml"
  assert_eq "$(ws_orchestrator_mode "$T/alpha" bundle)" "$(printf 'auto\tproduct')"
  rm -rf "$T"
}

# A committed `none`, from ANY level, is never relabelled: the merge does not
# carry a local `manual` over it, so the merged view and the resolver agree.
test_local_manual_never_rewrites_a_committed_none() {
  _wl_orch '' manual
  yq -y '.layout = {orchestrators: "none"}' "$T/alpha/workspace.yaml" > "$T/w" && mv "$T/w" "$T/alpha/workspace.yaml"
  assert_eq "$(ws_orchestrator_mode "$T/alpha" bundle)" "$(printf 'none\tlayout')"
  assert_eq "$(_yqr_ws -r '.products[0].orchestrator // "absent"' "$T/alpha")" absent
  yq -y '.products[0].orchestrator = "none" | del(.layout)' "$T/alpha/workspace.yaml" > "$T/w" && mv "$T/w" "$T/alpha/workspace.yaml"
  assert_eq "$(ws_orchestrator_mode "$T/alpha" bundle)" "$(printf 'none\tproduct')"
  assert_eq "$(_yqr_ws -r '.products[0].orchestrator' "$T/alpha")" none
  rm -rf "$T"
}

# The merge's shape changed, so an older cached merge must not be served.
test_the_merge_cache_key_is_v4() {
  _wl_orch auto manual
  _yqr_ws -r .name "$T/alpha" >/dev/null
  assert_eq "$(find "$T/cache" -name 'merged-v4-*' | wc -l | tr -d ' ')" "1"
  assert_eq "$(find "$T/cache" -name 'merged-v3-*' | wc -l | tr -d ' ')" "0"
  rm -rf "$T"
}

# ONE RULE, TWO SHAPES. ws_orchestrator_modes answers every product in one
# pass and ws_orchestrator_mode one product; across the product, layout and
# default levels, auto/manual/none, and a local manual over auto and over
# none, they must agree for every product - and agree with the rule itself.
test_batch_and_per_product_orchestrator_modes_agree() {
  _wl_setup
  source "$CEL_ROOT/lib/workspace.sh"
  local lay p batch want inherit got
  for lay in '' auto manual none; do
    yq -y --arg l "$lay" '
      .products = [{name: "p-auto", orchestrator: "auto"}, {name: "p-manual", orchestrator: "manual"},
                   {name: "p-none", orchestrator: "none"}, {name: "p-unset"},
                   {name: "p-local-auto", orchestrator: "auto"}, {name: "p-local-none", orchestrator: "none"},
                   {name: "p-local-inherit"}]
      | if $l == "" then del(.layout) else .layout = {orchestrators: $l} end' \
      "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" > "$T/alpha/workspace.yaml"
    printf 'products:\n  - {name: p-local-auto, orchestrator: manual}\n  - {name: p-local-none, orchestrator: manual}\n  - {name: p-local-inherit, orchestrator: manual}\n' \
      > "$T/alpha/workspace.local.yaml"
    batch="$(ws_orchestrator_modes "$T/alpha")"
    assert_eq "$(printf '%s\n' "$batch" | cut -f1 | tr '\n' ' ')" \
      "p-auto p-manual p-none p-unset p-local-auto p-local-none p-local-inherit widget " || { rm -rf "$T"; return 1; }
    if [ -n "$lay" ]; then inherit="$(printf '%s\tlayout' "$lay")"; else inherit="$(printf 'manual\tdefault')"; fi
    for p in p-auto p-manual p-none p-unset p-local-auto p-local-none p-local-inherit widget; do
      case "$p" in
        p-auto) want="$(printf 'auto\tproduct')" ;;
        p-manual) want="$(printf 'manual\tproduct')" ;;
        p-none|p-local-none) want="$(printf 'none\tproduct')" ;;
        p-local-auto) want="$(printf 'manual\tworkspace.local.yaml')" ;;
        p-local-inherit) if [ "$lay" = auto ]; then want="$(printf 'manual\tworkspace.local.yaml')"; else want="$inherit"; fi ;;
        *) want="$inherit" ;;
      esac
      got="$(printf '%s\n' "$batch" | awk -F'\t' -v p="$p" '$1 == p { print $2 "\t" $3 }')"
      assert_eq "$got" "$want" || { echo "batch, layout '$lay', $p"; rm -rf "$T"; return 1; }
      assert_eq "$(ws_orchestrator_mode "$T/alpha" "$p")" "$got" || { echo "per-product, layout '$lay', $p"; rm -rf "$T"; return 1; }
    done
  done
  # an undeclared name still resolves, through the layout and the default
  assert_eq "$(ws_orchestrator_mode "$T/alpha" nosuch)" "$(printf 'none\tlayout')"
  rm -rf "$T"
}
