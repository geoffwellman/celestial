# shellcheck shell=bash
# Third-party skills vendored into core/skills/ (every agent) and
# core/workspace-skills/ (sets a workspace opts into with workspace.yaml
# `skill_sets:`), per vendored-skills.yaml. Each is a pinned copy of an upstream directory; the
# every-agent ones are linked into every runtime exactly like the plane's own
# skills. These tests check the pins, the licences, the set of skills and
# their scopes, the committed bytes against the manifest and the link step
# offline. Only the modern-web-guidance test touches the network, and only on
# a checkout that has never fetched that skill's npm inputs (as `cel setup`
# does); `tools/skills/vendor.py verify` re-fetches every pin and compares.
# Workspace scoping (linking and launch flags): tests/workspace-skills.test.sh.

VENDORED="$CEL_ROOT/vendored-skills.yaml"
VENDOR="$CEL_ROOT/tools/skills/vendor.py"

# The owner-approved sets, and nothing else from those upstream repositories.
APPROVED_VENDORED_SKILLS="add-app-to-server anthropic-skill-creator convert-web-app create-mcp-app frontend-design mcp-builder migrate-oai-app modern-web-guidance ui-sdk vercel-composition-patterns vercel-react-best-practices vercel-react-native-skills web-design-guidelines webapp-testing"
# Workspace-scoped, in sets a workspace opts into: <skill>=<set>.
APPROVED_WORKSPACE_SKILLS="agents-sdk=cloudflare durable-objects=cloudflare eas-app-stores=expo eas-workflows=expo expo-animation=expo expo-dev-client=expo expo-native-ui=expo expo-router=expo expo-ui=expo expo-upgrade=expo web-perf=cloudflare workers-best-practices=cloudflare workers-profiling=cloudflare wrangler=cloudflare"
# The plane's own skills; herdr is generated (agents.yaml generated_skills).
NATIVE_CORE_SKILLS="linear publish review verify"
# Skills the runtimes bring themselves (Codex system skills, Claude Code and
# OpenCode built-ins, 2026-11-22): a vendored skill of the same name would
# shadow one or be shadowed. Upstream `skill-creator` is why
# anthropic-skill-creator is renamed.
RUNTIME_BUILTIN_SKILLS="skill-creator skill-installer imagegen openai-docs review-agent opencode browser report deep-research design design-sync dataviz update-config debug code-review simplify batch fewer-permission-prompts doctor loop claude-api workflow-authoring run run-skill-generator plugin-authoring"
# Each skill whose upstream text has an agent deploy, publish, submit to an
# app store, spend money or run paid builds/generation: its patch puts the
# owner-approval note at the top.
APPROVAL_NOTE_SKILLS="mcp-builder anthropic-skill-creator workers-best-practices durable-objects wrangler agents-sdk workers-profiling expo-native-ui expo-dev-client eas-workflows eas-app-stores"

_vendored_names() { yq -r '.skills | to_entries[] | select(.value.set == null) | .key' "$VENDORED" | LC_ALL=C sort; }
_scoped_names() { yq -r '.skills | to_entries[] | select(.value.set != null) | .key' "$VENDORED" | LC_ALL=C sort; }
_skill_path() { # <name> -> its vendored directory
  if [ -n "$(yq -r --arg n "$1" '.skills[$n].set // ""' "$VENDORED")" ]; then
    printf '%s/core/workspace-skills/%s' "$CEL_ROOT" "$1"
  else
    printf '%s/core/skills/%s' "$CEL_ROOT" "$1"
  fi
}

test_vendored_skill_pins_are_full_commit_shas() {
  local pins bad
  pins="$(yq -r '.skills[] | (.commit, (.extra // [])[].commit)' "$VENDORED")"
  [ -n "$pins" ] || { echo "no pins"; return 1; }
  bad="$(printf '%s\n' "$pins" | grep -vxE '[0-9a-f]{40}' || true)"
  assert_eq "$bad" ""
  bad="$(yq -r '.skills[] | (.extra // [])[] | select(has("npm")) | .integrity' "$VENDORED" \
    | grep -vxE 'sha512-[A-Za-z0-9+/]{86}==' || true)"
  assert_eq "$bad" ""
}

test_vendored_skill_licenses_are_mit_or_apache() {
  local licenses bad n f
  licenses="$(yq -r '.skills[] | (.license, (.extra // [])[].license)' "$VENDORED")" || return 1
  [ -n "$licenses" ] || { echo "no licences"; return 1; }
  bad="$(printf '%s\n' "$licenses" | grep -vxE 'MIT|Apache-2\.0' || true)"
  assert_eq "$bad" ""
  for n in $(_vendored_names) $(_scoped_names); do
    for f in $(yq -r --arg n "$n" '.skills[$n].license_files // [] | .[]' "$VENDORED"); do
      [ -s "$(_skill_path "$n")/$f" ] || { echo "$n: licence file $f missing"; return 1; }
    done
    [ -n "$(yq -r --arg n "$n" '.skills[$n].license_files // [] | .[]' "$VENDORED")" ] \
      || case " $APPROVED_VENDORED_SKILLS " in
           # batch 1's Vercel skills: upstream ships no licence file (MIT by README)
           *" $n "*) [ "${n#vercel-}" != "$n" ] ;;
           *) false ;;
         esac || { echo "$n: no licence file kept"; return 1; }
  done
}

test_exactly_the_approved_vendored_skills_are_present() {
  assert_eq "$(_vendored_names | tr '\n' ' ')" "$APPROVED_VENDORED_SKILLS "
  local n
  for n in $APPROVED_VENDORED_SKILLS; do
    [ -f "$CEL_ROOT/core/skills/$n/SKILL.md" ] || { echo "$n missing"; return 1; }
  done
  # Every directory in core/skills is vendored, the plane's own or generated:
  # an unlisted third-party skill cannot slip in beside the approved ones.
  local generated expected actual
  generated="$(yq -r '.generated_skills // {} | keys[]' "$CEL_ROOT/agents.yaml")"
  expected="$(printf '%s\n' $APPROVED_VENDORED_SKILLS $NATIVE_CORE_SKILLS | LC_ALL=C sort)"
  actual="$(cd "$CEL_ROOT/core/skills" && for d in */; do
      d="${d%/}"; printf '%s\n' "$generated" | grep -qxF "$d" || printf '%s\n' "$d"
    done | LC_ALL=C sort)"
  assert_eq "$actual" "$expected"
}

test_exactly_the_approved_workspace_skills_are_present_and_scoped() {
  local pair n set expected actual
  expected="$(printf '%s\n' $APPROVED_WORKSPACE_SKILLS | cut -d= -f1 | LC_ALL=C sort)"
  assert_eq "$(_scoped_names)" "$expected"
  for pair in $APPROVED_WORKSPACE_SKILLS; do
    n="${pair%%=*}" set="${pair#*=}"
    assert_eq "$(yq -r --arg n "$n" '.skills[$n].set' "$VENDORED")" "$set"
    [ -f "$CEL_ROOT/core/workspace-skills/$n/SKILL.md" ] || { echo "$n missing"; return 1; }
    # never in core/skills, which every agent gets
    [ ! -e "$CEL_ROOT/core/skills/$n" ] || { echo "$n is in core/skills"; return 1; }
  done
  actual="$(cd "$CEL_ROOT/core/workspace-skills" && for d in */; do printf '%s\n' "${d%/}"; done | LC_ALL=C sort)"
  assert_eq "$actual" "$expected"
  assert_eq "$(python3 "$VENDOR" set cloudflare | tr '\n' ' ')" "agents-sdk durable-objects web-perf workers-best-practices workers-profiling wrangler "
  assert_eq "$(python3 "$VENDOR" set expo cloudflare | wc -l)" "14"
  assert_fails python3 "$VENDOR" set no-such-set
}

# A set is one lowercase-hyphenated name.
test_vendor_refuses_a_malformed_skill_set() {
  local T out bad
  T="$(mktemp -d)"
  for bad in '[cloudflare]' '../x' 'Cloud' '""'; do
    python3 - "$CEL_ROOT/tools/skills" "$bad" <<'PY' > "$T/out" 2>&1 && { cat "$T/out"; echo "accepted set: $bad"; return 1; }
import sys, yaml
sys.path.insert(0, sys.argv[1])
import vendor
entry = yaml.safe_load(open(vendor.MANIFEST))["skills"]["wrangler"]
entry["set"] = yaml.safe_load(sys.argv[2])
try:
    vendor.validate_entry("wrangler", entry)
except vendor.Failure as e:
    print(e); sys.exit(1)
PY
    assert_contains "$(cat "$T/out")" "set must be"
  done
  rm -rf "$T"
}

test_vendored_skill_bytes_match_the_manifest() {
  python3 "$VENDOR" check
}

# npm inputs are fetched at install, never committed: each one is ignored and
# untracked, so neither the public tree nor its history ever carries them.
test_fetched_vendored_inputs_are_ignored_and_untracked() {
  local n rel paths=0
  for n in $(_vendored_names); do
    for rel in $(yq -r --arg n "$n" '.skills[$n].extra // [] | .[] | select(has("npm")) | .to as $to
        | .files | keys[] | if $to == "." then . else $to + "/" + . end' "$VENDORED"); do
      paths=$((paths + 1))
      git -C "$CEL_ROOT" check-ignore -q "core/skills/$n/$rel" || { echo "$n/$rel is not ignored"; return 1; }
      [ -z "$(git -C "$CEL_ROOT" ls-files "core/skills/$n/$rel")" ] || { echo "$n/$rel is tracked"; return 1; }
    done
  done
  [ "$paths" -gt 0 ] || { echo "no fetched inputs listed"; return 1; }
}

# Claude Code, omp, pi, Codex and OpenCode all read name and description from
# the frontmatter; the strictest rules (OpenCode, pi, the Agent Skills spec):
# name is lowercase-hyphenated, at most 64 characters and equal to its
# directory; description is 1-1024 characters. One name per skill, box-wide:
# across both trees, and none a runtime's own.
test_core_skill_names_are_unique_and_valid_for_every_runtime() {
  python3 "$VENDOR" names "$CEL_ROOT"/core/skills/*/SKILL.md "$CEL_ROOT"/core/workspace-skills/*/SKILL.md || return 1
  local n
  for n in $RUNTIME_BUILTIN_SKILLS; do
    [ ! -e "$CEL_ROOT/core/skills/$n" ] && [ ! -e "$CEL_ROOT/core/workspace-skills/$n" ] \
      || { echo "$n is a runtime's own skill name"; return 1; }
  done
}

# Upstream skill-creator keeps its body; only its name (and the note) change.
test_anthropic_skill_creator_is_renamed_from_upstream() {
  assert_eq "$(yq -r '.skills["anthropic-skill-creator"].path' "$VENDORED")" "skills/skill-creator"
  assert_contains "$(head -3 "$CEL_ROOT/core/skills/anthropic-skill-creator/SKILL.md")" "name: anthropic-skill-creator"
}

# Every skill that has an agent deploy, publish, submit to a store, spend or
# run paid builds/generation opens with the owner-approval note, carried by a
# recorded patch so `vendor.py verify` reproduces it from upstream.
test_flagged_skills_open_with_the_owner_approval_note() {
  local n f body
  for n in $APPROVAL_NOTE_SKILLS; do
    assert_eq "$(yq -r --arg n "$n" '.skills[$n].patch' "$VENDORED")" "tools/skills/patches/$n.patch"
    f="$(_skill_path "$n")/SKILL.md"
    # first thing after the frontmatter
    body="$(awk 'f == 2 && NF {print; exit} /^---$/ {f++}' "$f")"
    assert_eq "$body" '> **Celestial: owner approval first.** Under celestial rules an agent asks the owner'
    assert_contains "$(cat "$f")" "> Needs the owner's approval here:"
  done
  # and no other skill carries one
  assert_eq "$(grep -l 'Celestial: owner approval first' "$CEL_ROOT"/core/skills/*/SKILL.md "$CEL_ROOT"/core/workspace-skills/*/SKILL.md | wc -l)" \
    "$(printf '%s\n' $APPROVAL_NOTE_SKILLS | wc -l)"
}

test_link_puts_vendored_skills_in_every_runtime_skills_dir() {
  local SANDBOX a sd n linked=""
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export CEL_MANIFEST="$CEL_ROOT/agents.yaml" CEL_MANIFEST_CACHE="$SANDBOX/cache"
  source "$CEL_ROOT/lib/common.sh"
  source "$CEL_ROOT/lib/manifest.sh"
  source "$CEL_ROOT/lib/link.sh"
  link_core_skills >/dev/null
  for a in $(agent_names); do
    sd="$(agent_skills_dir "$a")"
    [ -n "$sd" ] || continue
    linked+="$a "
    for n in $APPROVED_VENDORED_SKILLS; do
      [ -L "$sd/$n" ] || { echo "$a: $sd/$n is not a link"; return 1; }
      assert_eq "$(readlink -f "$sd/$n")" "$CEL_ROOT/core/skills/$n"
      [ -f "$sd/$n/SKILL.md" ] || { echo "$a: $n has no SKILL.md through the link"; return 1; }
    done
  done
  assert_eq "$linked" "claude omp pi codex opencode "
  rm -rf "$SANDBOX"
}

test_ui_sdk_description_says_beta_and_core_only() {
  local desc
  desc="$(python3 "$VENDOR" description "$CEL_ROOT/core/skills/ui-sdk/SKILL.md")"
  assert_contains "$desc" "beta"
  assert_contains "$desc" "only"
  assert_contains "$desc" "@ui-sdk/core"
}

# Nor does its body tell an agent to add ui-sdk or load it from the network.
test_ui_sdk_never_installs_core_or_loads_a_remote_script() {
  local d="$CEL_ROOT/core/skills/ui-sdk" hits
  hits="$(grep -rnE '<script[^>]*ui-sdk\.dev|<link[^>]*ui-sdk\.dev|if no `@ui-sdk` package is installed|install `@ui-sdk/core` and' "$d" || true)"
  assert_eq "$hits" ""
  assert_contains "$(cat "$d/SKILL.md")" 'Never install `@ui-sdk/core`'
}

# The upstream skill runs `npx modern-web-guidance@latest` (network, unpinned).
# The vendored one runs the CLI and index fetched at install from the pinned
# tarball, against the committed guides, with no network once fetched.
test_modern_web_guidance_answers_from_the_installed_cli() {
  local skill="$CEL_ROOT/core/skills/modern-web-guidance" out T
  # (a prose warning may still name `npx modern-web-guidance`; a command may not)
  if grep -nE '^(DISABLE_TELEMETRY=1 )?(npx|pnpx)|npx -y|@latest' "$skill/SKILL.md"; then
    echo "SKILL.md still fetches the CLI"; return 1
  fi
  # every command goes through the telemetry-off wrapper
  if grep -nE '^[^`-].*modern-web\.mjs (search|retrieve|list)' "$skill/SKILL.md"; then
    echo "SKILL.md runs the CLI around its wrapper"; return 1
  fi
  assert_contains "$(cat "$skill/SKILL.md")" 'sh <skill-dir>/run.sh search'
  source "$CEL_ROOT/lib/common.sh"
  source "$CEL_ROOT/lib/link.sh"
  fetch_vendored_skills >/dev/null   # what `cel setup` / `cel update` run
  T="$(mktemp -d)"
  # Offline from here: every proxy points at a closed port.
  local dead=http://127.0.0.1:9
  out="$(https_proxy=$dead HTTPS_PROXY=$dead http_proxy=$dead HTTP_PROXY=$dead python3 "$VENDOR" fetch)" \
    || { echo "after fetch_vendored_skills the inputs still needed the network"; return 1; }
  assert_contains "$out" "present modern-web-guidance"
  out="$(cd "$T" && env -u DISABLE_TELEMETRY HOME="$T" https_proxy=$dead HTTPS_PROXY=$dead \
    sh "$skill/run.sh" search "light dismiss dialog" \
    --skill-version "$(cat "$skill/skill-version.txt")" 2>"$T/err")" || { cat "$T/err"; return 1; }
  assert_contains "$out" '"id":"light-dismiss-a-dialog"'
  out="$(cd "$T" && env -u DISABLE_TELEMETRY HOME="$T" sh "$skill/run.sh" retrieve dialog > "$T/guide" 2>"$T/err" \
    && cat "$T/guide")" || { cat "$T/err"; return 1; }
  assert_contains "$out" "Guide for dialog"
  # no update nag: the fetched CLI and the committed SKILL.md are one skill version
  [ ! -s "$T/err" ] || { cat "$T/err"; return 1; }
  assert_contains "$(cat "$skill/SKILL.md")" "--skill-version $(cat "$skill/skill-version.txt")"
  rm -rf "$T"
}

# The wrapper, not the agent's memory, turns telemetry off: a stub node shows
# the environment and arguments the real CLI would get.
test_modern_web_guidance_wrapper_turns_telemetry_off() {
  local skill="$CEL_ROOT/core/skills/modern-web-guidance" T out
  T="$(mktemp -d)"
  mkdir "$T/bin"
  printf '#!/bin/sh\necho "DISABLE_TELEMETRY=${DISABLE_TELEMETRY:-unset} $*"\n' > "$T/bin/node"
  chmod +x "$T/bin/node"
  out="$(env -u DISABLE_TELEMETRY PATH="$T/bin:$PATH" sh "$skill/run.sh" search "a b")"
  assert_eq "$out" "DISABLE_TELEMETRY=1 $skill/modern-web.mjs search a b"
  out="$(DISABLE_TELEMETRY=0 PATH="$T/bin:$PATH" sh "$skill/run.sh" list)"
  assert_eq "$out" "DISABLE_TELEMETRY=1 $skill/modern-web.mjs list"
  rm -rf "$T"
}

# A failed write leaves no .vendor-* temporary behind in core/skills/.
test_vendor_write_removes_its_temporary_on_failure() {
  local T
  T="$(mktemp -d)"
  mkdir -p "$T/skills/x/dir-in-the-way"
  python3 - "$CEL_ROOT/tools/skills" "$T/skills" <<'PY' || return 1
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import vendor
vendor.SKILLS = Path(sys.argv[2])
try:
    vendor._write(vendor.SKILLS / "x" / "dir-in-the-way", b"body", False)
except OSError:
    pass
else:
    sys.exit("replacing a directory did not fail")
left = sorted(p.name for p in vendor.SKILLS.iterdir() if p.name.startswith(".vendor-"))
sys.exit(f"temporaries left: {left}" if left else 0)
PY
  rm -rf "$T"
}
