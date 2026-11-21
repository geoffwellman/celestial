# shellcheck shell=bash
# Workspace-scoped vendored skill sets (vendored-skills.yaml `set:`, opted
# into by workspace.yaml `skill_sets:`): linked under <workspace>/.cel/skills
# for the declaring workspaces only, removed when no longer declared, never
# written into a repo, kept out of every runtime's
# global skills dir (codex's: linked there but disabled), and named by each
# launch for that workspace (agents.yaml workspace_skills).

CLOUDFLARE="agents-sdk durable-objects web-perf workers-best-practices workers-profiling wrangler"
EXPO="eas-app-stores eas-workflows expo-animation expo-dev-client expo-native-ui expo-router expo-ui expo-upgrade"

_wss_setup() {
  T="$(mktemp -d)"
  export HOME="$T/home"
  mkdir -p "$HOME"
  export CEL_MANIFEST="$CEL_ROOT/agents.yaml" CEL_MANIFEST_CACHE="$T/cache"
  source "$CEL_ROOT/lib/common.sh"
  source "$CEL_ROOT/lib/manifest.sh"
  source "$CEL_ROOT/lib/workspace.sh"
  source "$CEL_ROOT/lib/link.sh"
}
_wss_ws() { # <name> [sets...] -> a workspace dir with one repo checkout
  local n="$1"; shift
  mkdir -p "$T/$n/repos/app"
  printf 'name: %s\nskill_sets: [%s]\n' "$n" "$(IFS=,; printf '%s' "$*")" > "$T/$n/workspace.yaml"
  git -C "$T/$n/repos/app" init -q
}
_wss_linked() { # <wsdir> -> the linked skill names, sorted, one line
  local l out=""
  for l in "$1"/.cel/skills/skills/*; do [ -L "$l" ] && out+="${l##*/} "; done
  printf '%s' "$out"
}

test_workspace_skills_link_only_for_declared_workspaces() {
  _wss_setup
  _wss_ws both cloudflare expo; _wss_ws cf cloudflare; _wss_ws none
  ws_link_vendored_skills "$T/both" >/dev/null
  ws_link_vendored_skills "$T/cf" >/dev/null
  ws_link_vendored_skills "$T/none" >/dev/null
  assert_eq "$(_wss_linked "$T/both")" "$(printf '%s ' $CLOUDFLARE $EXPO | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
  assert_eq "$(_wss_linked "$T/cf")" "$(printf '%s ' $CLOUDFLARE)"
  [ ! -e "$T/none/.cel/skills" ] || { echo "none got a skills dir"; return 1; }
  local n
  for n in $CLOUDFLARE; do
    assert_eq "$(readlink -f "$T/cf/.cel/skills/skills/$n")" "$CEL_ROOT/core/workspace-skills/$n"
  done
  # claude reads <dir>/.claude/skills; OpenCode the extra config
  assert_eq "$(readlink "$T/cf/.cel/skills/.claude/skills")" "../skills"
  [ -f "$T/cf/.cel/skills/.claude/skills/wrangler/SKILL.md" ] || { echo "no SKILL.md through .claude/skills"; return 1; }
  assert_eq "$(jq -c . "$T/cf/.cel/skills/opencode.json")" "{\"skills\":[\"$T/cf/.cel/skills/skills\"]}"
  # nothing in a repo, nothing in any runtime's global skills dir
  assert_eq "$(git -C "$T/cf/repos/app" status --porcelain --ignored)" ""
  [ ! -e "$T/cf/repos/app/.claude" ] || { echo "wrote into the repo"; return 1; }
  local a sd
  for a in claude omp pi opencode; do
    sd="$(agent_skills_dir "$a")"
    for n in $CLOUDFLARE $EXPO; do
      [ ! -e "$sd/$n" ] || { echo "$a: $n is global"; return 1; }
    done
  done
  rm -rf "$T"
}

# Linking twice changes nothing; an undeclared link goes, the user's stays.
test_workspace_skills_undeclared_links_are_removed() {
  _wss_setup
  _wss_ws cf cloudflare; _wss_ws none
  ws_link_vendored_skills "$T/cf" >/dev/null
  ws_link_vendored_skills "$T/cf" >/dev/null
  assert_eq "$(_wss_linked "$T/cf")" "$(printf '%s ' $CLOUDFLARE)"
  # an Expo skill left behind (the workspace once declared expo) and a user's own
  ln -s "$CEL_ROOT/core/workspace-skills/expo-ui" "$T/cf/.cel/skills/skills/expo-ui"
  ln -s "$T/elsewhere" "$T/cf/.cel/skills/skills/mine"
  ws_link_vendored_skills "$T/cf" >/dev/null
  [ ! -L "$T/cf/.cel/skills/skills/expo-ui" ] || { echo "undeclared expo-ui survived"; return 1; }
  [ -L "$T/cf/.cel/skills/skills/mine" ] || { echo "user link pruned"; return 1; }
  # a workspace that declares nothing loses every plane link and the flags' targets
  mkdir -p "$T/none/.cel/skills/skills"
  ln -s "$CEL_ROOT/core/workspace-skills/wrangler" "$T/none/.cel/skills/skills/wrangler"
  ws_link_vendored_skills "$T/none" >/dev/null
  [ ! -e "$T/none/.cel/skills" ] || { echo "none kept $(ls -A "$T/none/.cel/skills/skills")"; return 1; }
  rm -rf "$T"
}

# Dropping a set from workspace.yaml takes its skills away at the next sync.
test_workspace_skills_go_when_their_set_is_dropped() {
  _wss_setup
  _wss_ws w cloudflare expo
  ws_link_vendored_skills "$T/w" >/dev/null
  assert_eq "$(_wss_linked "$T/w" | wc -w)" "14"
  printf 'name: w\nskill_sets: [expo]\n' > "$T/w/workspace.yaml"
  ws_link_vendored_skills "$T/w" >/dev/null
  assert_eq "$(_wss_linked "$T/w")" "$(printf '%s ' $EXPO)"
  printf 'name: w\n' > "$T/w/workspace.yaml"
  ws_link_vendored_skills "$T/w" >/dev/null
  [ ! -e "$T/w/.cel/skills" ] || { echo "skills dir kept with no set declared"; return 1; }
  rm -rf "$T"
}

# A set the manifest does not have is reported and changes nothing.
test_workspace_skills_unknown_set_is_reported() {
  _wss_setup
  _wss_ws w cloudflare
  ws_link_vendored_skills "$T/w" >/dev/null
  printf 'name: w\nskill_sets: [cloudflare, no-such-set]\n' > "$T/w/workspace.yaml"
  local out; out="$(ws_link_vendored_skills "$T/w" 2>&1)"
  assert_contains "$out" "no skill set no-such-set"
  assert_eq "$(_wss_linked "$T/w")" "$(printf '%s ' $CLOUDFLARE)"
  rm -rf "$T"
}

# cel ws sync links them; the repo is untouched.
test_ws_sync_links_the_workspace_skills() {
  _wss_setup
  source "$CEL_ROOT/lib/install.sh"
  source "$CEL_ROOT/lib/ws.sh"
  export CEL_REGISTRY="$T/registry"
  printf '' | cmd_ws new cf --kind hustle --org o --merge self --path "$T/cf" --no-remote >/dev/null
  printf 'skill_sets: [cloudflare]\n' >> "$T/cf/workspace.yaml"
  cmd_ws sync cf >/dev/null
  assert_eq "$(_wss_linked "$T/cf")" "$(printf '%s ' $CLOUDFLARE)"
  git -C "$T/cf" check-ignore -q .cel/skills/skills/wrangler || { echo ".cel/skills is not ignored"; return 1; }
  rm -rf "$T"
}

# Codex has no per-launch skill dir: every scoped skill is linked into its
# skills dir and disabled in config.toml; the user's config is kept.
test_codex_gets_scoped_skills_linked_and_disabled() {
  _wss_setup
  local sd cfg n
  sd="$(agent_skills_dir codex)"; cfg="${sd%/*}/config.toml"
  mkdir -p "${cfg%/*}"
  printf 'model = "x"\n\n[profiles.a]\nmodel = "y"\n' > "$cfg"
  link_codex_workspace_skills >/dev/null
  for n in $CLOUDFLARE $EXPO; do
    assert_eq "$(readlink "$sd/$n")" "$CEL_ROOT/core/workspace-skills/$n"
  done
  python3 - "$cfg" "$(readlink -f "$CEL_ROOT")" $CLOUDFLARE $EXPO <<'PY' || return 1
import sys, tomllib
cfg, root, names = sys.argv[1], sys.argv[2], sys.argv[3:]
data = tomllib.load(open(cfg, "rb"))
assert data["model"] == "x" and data["profiles"]["a"]["model"] == "y", data
got = {e["path"]: e["enabled"] for e in data["skills"]["config"]}
# the resolved SKILL.md: codex matches an entry by the skill's resolved path
want = {f"{root}/core/workspace-skills/{n}/SKILL.md": False for n in names}
assert got == want, (got, want)
PY
  local sum; sum="$(cksum < "$cfg")"
  link_codex_workspace_skills >/dev/null
  assert_eq "$(cksum < "$cfg")" "$sum"
  # a scoped skill dropped from the manifest loses its link and its entry
  ln -s "$CEL_ROOT/core/workspace-skills/retired-one" "$sd/retired-one"
  link_codex_workspace_skills >/dev/null
  [ ! -L "$sd/retired-one" ] || { echo "retired link kept"; return 1; }
  rm -rf "$T"
}

# A config.toml vendor.py cannot edit with certainty is left byte for byte
# alone, and codex then gets no scoped skill at all (fail closed): any
# skills setting of the user's own, in any TOML spelling; an incomplete or
# repeated block of ours, with the user's content after it; invalid TOML.
_codex_refusal() { # <config.toml body>
  local sd cfg sum out
  sd="$(agent_skills_dir codex)"; cfg="${sd%/*}/config.toml"
  mkdir -p "$sd"
  printf '%s\n' "$1" > "$cfg"
  ln -sfn "$CEL_ROOT/core/workspace-skills/wrangler" "$sd/wrangler"
  sum="$(cksum < "$cfg")"
  out="$(link_codex_workspace_skills 2>&1)"
  assert_eq "$(cksum < "$cfg")" "$sum" || { printf 'rewrote:\n%s\n' "$1"; return 1; }
  assert_contains "$out" "not linked for codex"
  [ ! -e "$sd/wrangler" ] && [ ! -L "$sd/wrangler" ] || { printf 'scoped link left for:\n%s\n' "$1"; return 1; }
  [ -z "$(find "$sd" -maxdepth 1 -type l -lname "$CEL_ROOT/core/workspace-skills/*")" ] || { echo "scoped links made"; return 1; }
}
test_codex_scoped_skills_refused_beside_a_users_skills_config() {
  _wss_setup
  local body
  for body in \
    $'[[skills.config]]\npath = "/x/SKILL.md"\nenabled = false' \
    $'[skills]\nbundled = false' \
    $'["skills"]\nx = 1' \
    $'[\'skills\'.config]\nx = 1' \
    $'[["skills".config]]\npath = "/x/SKILL.md"\nenabled = false' \
    $'[[ skills . "config" ]]\npath = "/x/SKILL.md"\nenabled = false' \
    $'skills.config = []' \
    $'"skills".config = []' \
    $'skills = { config = [] }' \
    $'model = "x"\n# cel:workspace-skills:begin - cel update writes this block: workspace-scoped skills are off unless a cel launch enables them\n[projects."/home/u/app"]\ntrust_level = "trusted"' \
    $'model = "x"\n# cel:workspace-skills:end\n[projects."/a"]\ntrust_level = "trusted"' \
    $'# cel:workspace-skills:begin - cel update writes this block: workspace-scoped skills are off unless a cel launch enables them\n# cel:workspace-skills:end\n# cel:workspace-skills:begin - cel update writes this block: workspace-scoped skills are off unless a cel launch enables them\n# cel:workspace-skills:end' \
    $'model = "x\n[broken' ; do
    _codex_refusal "$body" || return 1
  done
  rm -rf "$T"
}

# A key named skills inside another table is the user's and not codex's
# skills setting: the block is added and the whole file still parses.
test_codex_block_keeps_a_nested_skills_key_and_valid_toml() {
  _wss_setup
  local sd cfg
  sd="$(agent_skills_dir codex)"; cfg="${sd%/*}/config.toml"
  mkdir -p "${cfg%/*}"
  printf '[profiles.a]\nskills = ["x"]\n' > "$cfg"
  link_codex_workspace_skills >/dev/null
  python3 - "$cfg" <<'PY' || return 1
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
assert d["profiles"]["a"]["skills"] == ["x"], d
assert len(d["skills"]["config"]) == 14 and not any(e["enabled"] for e in d["skills"]["config"]), d
PY
  [ -L "$sd/wrangler" ] || { echo "not linked"; return 1; }
  rm -rf "$T"
}

# Each runtime's launch names the workspace's skills its own way, and a
# workspace without any gets nothing.
test_launch_names_the_workspace_skills_per_runtime() {
  _wss_setup
  source "$CEL_ROOT/lib/run.sh"
  _wss_ws cf cloudflare; _wss_ws none
  ws_link_vendored_skills "$T/cf" >/dev/null
  local d="$T/cf/.cel/skills" rt list n
  local -a AGENT_ARGS LAUNCH_ENV_EXTRA
  for rt in claude omp pi codex opencode; do
    AGENT_ARGS=(--role x) LAUNCH_ENV_EXTRA=()
    _run_workspace_skills "$rt" "$T/none"
    assert_eq "${AGENT_ARGS[*]} | ${LAUNCH_ENV_EXTRA[*]}" "--role x | "
  done
  AGENT_ARGS=(--role x) LAUNCH_ENV_EXTRA=(); _run_workspace_skills claude "$T/cf"
  assert_eq "${AGENT_ARGS[*]}" "--add-dir $d --role x"
  AGENT_ARGS=(--role x); _run_workspace_skills omp "$T/cf"
  assert_eq "${AGENT_ARGS[*]}" "--plugin-dir $d --role x"
  AGENT_ARGS=(--role x); _run_workspace_skills pi "$T/cf"
  assert_eq "${AGENT_ARGS[*]}" "--skill $d/skills --role x"
  AGENT_ARGS=(--role x); _run_workspace_skills opencode "$T/cf"
  assert_eq "${AGENT_ARGS[*]} | ${LAUNCH_ENV_EXTRA[*]}" "--role x | OPENCODE_CONFIG=$d/opencode.json"
  AGENT_ARGS=(--role x); _run_workspace_skills codex "$T/cf"
  list=""
  for n in $CLOUDFLARE; do list+="${list:+,}{path=\"$(readlink -f "$CEL_ROOT")/core/workspace-skills/$n/SKILL.md\",enabled=true}"; done
  assert_eq "${AGENT_ARGS[0]}|${AGENT_ARGS[1]}|${AGENT_ARGS[2]}" "-c|skills.config=[$list]|--role"
  rm -rf "$T"
}

# The real launch line (cel run, dry run) carries it: one call site serves
# every role - root, orchestrator, solo lane, reviewer, member.
test_cel_run_line_names_the_workspace_skills() {
  T="$(mktemp -d)"; cp "$CEL_ROOT/tests/fixtures/ws-alpha/workspace.yaml" "$T/"
  mkdir -p "$T/repos/widget" "$T/bin"
  cat > "$T/bin/herdr" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'agent list' ] || exit 1
printf '{"result":{"agents":[]}}\n'
SH
  chmod +x "$T/bin/herdr"
  export PATH="$T/bin:$PATH"
  source "$CEL_ROOT/lib/common.sh"
  source "$CEL_ROOT/lib/run.sh"
  local out
  out="$(cd "$T" && cmd_run orchestrator --repo widget --dry-run)"
  case "$out" in *"$T/.cel/skills"*) echo "named a skills dir with none linked"; return 1 ;; esac
  mkdir -p "$T/.cel/skills/skills/demo"
  printf -- '---\nname: demo\ndescription: d\n---\n' > "$T/.cel/skills/skills/demo/SKILL.md"
  out="$(cd "$T" && cmd_run orchestrator --repo widget --dry-run)"
  assert_contains "$out" "$T/.cel/skills"
  rm -rf "$T"
}
