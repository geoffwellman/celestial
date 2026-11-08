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
