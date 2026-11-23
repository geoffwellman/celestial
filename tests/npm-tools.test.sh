# shellcheck shell=bash
# Global npm tools that register themselves with the runtimes (externals.yaml
# `npm_tools`; today REA). `cel setup` installs the exact registry tarball
# only after its sha512 integrity matches, keeps a release at or above the
# pin, and runs the tool's own registration only when its doctor says the
# box is not aligned - omp and pi as two agent roots, never through an
# inherited OpenCode overlay. npm, curl and the tool are stubs: nothing is
# downloaded, installed or registered for real.

_nt_setup() {
  T="$(mktemp -d)"; LOG="$T/log"; : > "$LOG"
  export HOME="$T/home" NT_T="$T"
  mkdir -p "$HOME" "$T/bin" "$T/prefix/bin" "$T/prefix/lib/node_modules" "$T/cel"
  export CEL_MANIFEST="$CEL_ROOT/agents.yaml" CEL_MANIFEST_CACHE="$T/cache"
  printf 'fixture tarball bytes\n' > "$T/tarball"
  NT_INTEGRITY="$(python3 -c 'import base64,hashlib,sys; print("sha512-"+base64.b64encode(hashlib.sha512(open(sys.argv[1],"rb").read()).digest()).decode())' "$T/tarball")"
  cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
printf 'curl %s\n' "$url" >> "$NT_T/log"
cp "$NT_T/tarball" "$out"
SH
  cat > "$T/bin/npm" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'prefix -g') printf '%s\n' "$NT_T/prefix" ;;
  'root -g') printf '%s\n' "$NT_T/prefix/lib/node_modules" ;;
  'install -g '*)
    printf 'npm %s\n' "$*" >> "$NT_T/log"
    mkdir -p "$NT_T/prefix/lib/node_modules/rea-agents"
    printf '{"name":"rea-agents","version":"6.10.1"}\n' > "$NT_T/prefix/lib/node_modules/rea-agents/package.json"
    ;;
  *) exit 2 ;;
esac
SH
  # the tool: its doctor says aligned when $NT_T/healthy exists
  cat > "$T/prefix/bin/rea" <<'SH'
#!/usr/bin/env bash
printf 'rea root=%s opencode=%s %s\n' "${PI_CODING_AGENT_DIR-unset}" "${OPENCODE_CONFIG-unset}" "$*" >> "$NT_T/log"
if [ "$1" = doctor ]; then
  if [ -e "$NT_T/healthy" ]; then echo '{"healthy":true}'; else echo '{"healthy":false}'; exit 1; fi
fi
SH
  chmod +x "$T/bin"/* "$T/prefix/bin/rea"
  ln -s "$(type -P yq)" "$T/bin/yq"; ln -s "$(type -P jq)" "$T/bin/jq"
  # no real npm, node or mise is reachable
  export PATH="$T/bin:/usr/bin:/bin"
  source "$CEL_ROOT/lib/common.sh"
  source "$CEL_ROOT/lib/manifest.sh"
  source "$CEL_ROOT/lib/install.sh"
  CEL_ROOT="$T/cel"
  _nt_manifest MIT
}

_nt_manifest() { # <licence>
  cat > "$CEL_ROOT/externals.yaml" <<YAML
npm_tools:
  rea:
    package: rea-agents
    version: 6.10.1
    integrity: $NT_INTEGRITY
    license: $1
    source: morluto/rea
    bin: rea
    register:
      clients: [claude_code, codex, opencode, antigravity, omp, pi]
      tool_catalog_profile: hot-cold
YAML
}

_nt_installed() { # <version>
  mkdir -p "$T/prefix/lib/node_modules/rea-agents"
  printf '{"name":"rea-agents","version":"%s"}\n' "$1" > "$T/prefix/lib/node_modules/rea-agents/package.json"
}

test_npm_tool_installs_the_verified_tarball_then_registers_each_agent_root() {
  _nt_setup
  # a caller inside an OpenCode or omp launch carries these; REA would write
  # into the workspace overlay or the wrong agent root
  export OPENCODE_CONFIG="$T/ws/.cel/skills/opencode.json" PI_CODING_AGENT_DIR="$T/elsewhere" OMP_PROFILE=other
  install_npm_tools >/dev/null 2>&1 || { cat "$LOG"; echo "install_npm_tools failed"; return 1; }
  local want
  want="curl https://registry.npmjs.org/rea-agents/-/rea-agents-6.10.1.tgz"
  assert_eq "$(sed -n 1p "$LOG")" "$want" || return 1
  assert_contains "$(sed -n 2p "$LOG")" "npm install -g " || return 1
  assert_contains "$(sed -n 2p "$LOG")" ".tgz" || return 1
  local main="--client claude_code --client codex --client opencode --client antigravity --client omp"
  assert_eq "$(sed -n 3p "$LOG")" "rea root=$HOME/.omp/agent opencode=unset doctor $main --skill --format json" || return 1
  assert_eq "$(sed -n 4p "$LOG")" "rea root=$HOME/.omp/agent opencode=unset setup --yes $main --tool-catalog-profile hot-cold" || return 1
  assert_eq "$(sed -n 5p "$LOG")" "rea root=$HOME/.pi/agent opencode=unset doctor --client pi --skill --format json" || return 1
  assert_eq "$(sed -n 6p "$LOG")" "rea root=$HOME/.pi/agent opencode=unset setup --yes --client pi --tool-catalog-profile hot-cold" || return 1
  assert_eq "$(wc -l < "$LOG")" 6 || return 1
  rm -rf "$T"
}

test_npm_tool_integrity_mismatch_never_reaches_npm() {
  _nt_setup
  printf 'tampered\n' > "$T/tarball"
  if install_npm_tools >/dev/null 2>&1; then echo "a tampered tarball was accepted"; return 1; fi
  if grep -q '^npm \|^rea ' "$LOG"; then echo "npm or the tool ran after a mismatch"; return 1; fi
  rm -rf "$T"
}

test_npm_tool_at_or_above_its_pin_on_an_aligned_box_is_left_alone() {
  _nt_setup
  local v
  touch "$T/healthy"
  for v in 6.10.1 6.11.0; do
    : > "$LOG"; _nt_installed "$v"
    install_npm_tools >/dev/null 2>&1 || { echo "install_npm_tools failed at $v"; return 1; }
    if grep -q '^curl \|^npm \| setup ' "$LOG"; then echo "installed $v was not kept, or setup ran on an aligned box"; cat "$LOG"; return 1; fi
    assert_eq "$(grep -c ' doctor ' "$LOG")" 2 || return 1
  done
  rm -rf "$T"
}

test_npm_tool_below_its_pin_is_raised_to_it() {
  _nt_setup
  touch "$T/healthy"; _nt_installed 6.9.0
  install_npm_tools >/dev/null 2>&1 || return 1
  assert_contains "$(cat "$LOG")" "npm install -g " || return 1
  rm -rf "$T"
}

test_npm_tool_with_an_unapproved_licence_is_refused_before_any_command() {
  _nt_setup
  _nt_manifest GPL-3.0
  if install_npm_tools >/dev/null 2>&1; then echo "GPL entry accepted"; return 1; fi
  assert_eq "$(cat "$LOG")" '' || return 1
  rm -rf "$T"
}

# The record itself: REA pinned to the reviewed tarball, its licence and the
# registration the owner ran; its skill stays REA's (rea setup writes it),
# never a copy in core/skills.
test_rea_is_recorded_as_a_pinned_npm_tool() {
  local f="$CEL_ROOT/externals.yaml"
  assert_eq "$(yq -c '.npm_tools.rea | {package, version, integrity, license, source, bin}' "$f")" \
    '{"package":"rea-agents","version":"6.10.1","integrity":"sha512-3AWrfFEXppvC98FWhZR2Tzulnqs5xJQrSKmAub6+QME/I58Pr3h8pHqqwM30z2DvlnIx/8Hsu8woMngfi4SNyg==","license":"MIT","source":"morluto/rea","bin":"rea"}' || return 1
  assert_eq "$(yq -c '.npm_tools.rea.register' "$f")" \
    '{"clients":["claude_code","codex","opencode","antigravity","omp","pi"],"tool_catalog_profile":"hot-cold"}' || return 1
  [ ! -e "$CEL_ROOT/core/skills/reverse-engineer-anything" ] || { echo "REA's skill vendored into core/skills"; return 1; }
  source "$CEL_ROOT/lib/install.sh"
  assert_contains "$(declare -f cmd_setup)" install_npm_tools || return 1
}
