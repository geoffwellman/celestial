# shellcheck shell=bash
# Setup installs trusted code. Tests must replace every network/process boundary;
# never call setup against the user's actual HOME or running services.
[ -n "${_CEL_INSTALL:-}" ] && return 0
_CEL_INSTALL=1
# shellcheck source=lib/manifest.sh
. "${BASH_SOURCE[0]%/*}/manifest.sh"
# shellcheck source=lib/externals.sh
. "${BASH_SOURCE[0]%/*}/externals.sh"
# shellcheck source=lib/version.sh
. "${BASH_SOURCE[0]%/*}/version.sh"
# shellcheck source=lib/gateway.sh
. "${BASH_SOURCE[0]%/*}/gateway.sh"   # gateway_omp_dir, gateway_pi_dir

# Verify a complete download before anything can execute it. A failing curl must
# not be hidden by a successful shell on the other side of a pipeline.
install_download() {
  local url="$1" digest="$2" destination="$3" actual
  [[ "$url" == https://* && "$digest" =~ ^[a-f0-9]{64}$ ]] || {
    echo "invalid pinned download URL or SHA-256" >&2; return 1;
  }
  curl -fSL "$url" -o "$destination" || return
  actual="$(sha256sum "$destination")" || return
  [ "${actual%% *}" = "$digest" ] || {
    echo "checksum mismatch: $url" >&2; return 1;
  }
}

# Each manifest asset is either one binary or one named tar.gz member. Extract
# only that member to stdout, never paths supplied by the archive onto disk.
install_pinned_binary() (
  set -euo pipefail
  local section="$1" name="$2" bin="${3:-$2}" directory="${4:-$HOME/.local/bin}" arch asset url digest member tmp stage
  arch="$(uname -m)" || exit
  case "$arch" in x86_64|amd64) arch=x64;; aarch64|arm64) arch=arm64;;
    *) echo "no pinned $name release for architecture: $arch" >&2; exit 1;; esac
  asset="$(yq -er --arg s "$section" --arg n "$name" --arg a "$arch" \
    '.[$s][$n].assets[$a]' "$CEL_MANIFEST")" || exit
  url="$(jq -er '.url' <<<"$asset")" || exit
  digest="$(jq -er '.sha256' <<<"$asset")" || exit
  member="$(jq -r '.member // ""' <<<"$asset")" || exit
  tmp="$(mktemp -d)" || exit
  trap 'rm -rf "$tmp"; [ -z "${stage:-}" ] || rm -f "$stage"' EXIT
  install_download "$url" "$digest" "$tmp/download" || exit
  if [ -n "$member" ]; then
    tar -xOzf "$tmp/download" -- "$member" > "$tmp/binary" || exit
  else
    mv "$tmp/download" "$tmp/binary" || exit
  fi
  [ -s "$tmp/binary" ] || exit 1
  mkdir -p "$directory" || exit
  stage="$(mktemp "$directory/.cel-install.XXXXXX")" || exit
  cat "$tmp/binary" > "$stage" || exit
  chmod 755 "$stage" || exit
  mv -fT "$stage" "$directory/$bin"
)

install_script() (
  set -euo pipefail
  local url="$1" digest="$2" shell="$3" tmp
  shift 3
  tmp="$(mktemp -d)" || exit
  trap 'rm -rf "$tmp"' EXIT
  install_download "$url" "$digest" "$tmp/install" || exit
  "$shell" "$tmp/install" "$@"
)

# Manifest commands are trusted repository policy, not workspace input. Every
# command runs with errexit AND pipefail, even when setup is called in an if.
install_command() {
  local label="$1" command="$2" version="${3:-}"
  echo "    installing $label${version:+ ($version)}"
  export -f install_download install_pinned_binary install_script
  if CEL_MANIFEST="$CEL_MANIFEST" CEL_INSTALL_VERSION="$version" \
      bash -e -u -o pipefail -c "$command"; then
    return 0
  else
    local status=$?
    c_err "$label installation failed (exit $status)"
    return "$status"
  fi
}

# gh 3.0 is newer than 2.90; concatenating their digits gets that backwards.
install_gh_supported() {
  local version
  version="$(gh --version)" || return
  [[ "$version" =~ ^gh[[:space:]]version[[:space:]]([0-9]+)\.([0-9]+)\. ]] || return 1
  (( 10#${BASH_REMATCH[1]} > 2 || (10#${BASH_REMATCH[1]} == 2 && 10#${BASH_REMATCH[2]} >= 90) ))
}

install_base() {
  c_hd "Base tools"
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
  # Distribution prerequisites deliberately follow the operator's apt sources;
  # this is a pinned application bootstrap, not a reproducible OS image.
  local b package
  for b in git jq curl tar gzip cc; do
    if ! have "$b"; then
      have apt-get || { c_err "install $b with your distribution's package manager, then retry"; return 1; }
      package="$b"; [ "$b" != cc ] || package=build-essential
      sudo apt-get install -y "$package" || return
    fi
  done
  if ! yq_ok; then
    if ! have pipx; then
      have apt-get || { c_err "install pipx and Python yq 4.1.2, then retry"; return 1; }
      sudo apt-get install -y pipx || return
    fi
    pipx install --force 'yq==4.1.2' || return
    yq_ok || { c_err "Python yq is still missing or shadowed on PATH"; return 1; }
  fi
  [ ! -f "$HOME/.cargo/env" ] || . "$HOME/.cargo/env"
  local names cmd version
  names="$(yq -r '.base_tools | keys_unsorted[]' "$CEL_MANIFEST")" || return
  for b in $names; do
    if have "$b"; then
      if [ "$b" != gh ] || install_gh_supported; then
        c_ok "$b already installed (retained)"
        continue
      fi
    fi
    cmd="$(yq -er --arg b "$b" '.base_tools[$b].install' "$CEL_MANIFEST")" || return
    version="$(yq -er --arg b "$b" '.base_tools[$b].version' "$CEL_MANIFEST")" || return
    install_command "$b" "$cmd" "$version" || return
    [ ! -f "$HOME/.cargo/env" ] || . "$HOME/.cargo/env"
    have "$b" || { c_err "$b still missing after installation"; return 1; }
  done
}

# NPM GLOBALS LIVE UNDER ONE NODE. What a node that is no longer active
# still holds - the release the box last ran - read from mise's node
# installs (each real release directory once; aliases such as `lts` are
# symlinks and skipped). Nothing is printed when no node holds it.
_mise_node_installs() { # -> one real node release directory per line
  local d
  for d in "${MISE_DATA_DIR:-$HOME/.local/share/mise}"/installs/node/*/; do
    d="${d%/}"
    [ -d "$d" ] && [ ! -L "$d" ] && printf '%s\n' "$d"
  done
}
npm_stranded() { # <npm package> -> "<version>\t<node release>" of the newest release any node holds
  local d v best="" node=""
  while IFS= read -r d; do
    v="$(jq -r '.version // empty' "$d/lib/node_modules/$1/package.json" 2>/dev/null)" || continue
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [ -z "$best" ] || cel_version_lt "$best" "$v"; then best="$v"; node="${d##*/}"; fi
  done < <(_mise_node_installs)
  [ -z "$best" ] || printf '%s\t%s\n' "$best" "$node"
}
# Which npm package put <bin> into a node's bin directory, from that link.
npm_bin_owner() { # <bin> -> "<package>\t<version>\t<node release>" (newest), or nothing
  local d link pkg v best="" out=""
  while IFS= read -r d; do
    link="$(readlink "$d/bin/$1" 2>/dev/null)" || continue
    [[ "$link" =~ lib/node_modules/((@[^/]+/)?[^/@]+)/ ]] || continue
    pkg="${BASH_REMATCH[1]}"
    v="$(jq -r '.version // empty' "$d/lib/node_modules/$pkg/package.json" 2>/dev/null)" || continue
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [ -z "$best" ] || cel_version_lt "$best" "$v"; then best="$v"; out="$pkg"$'\t'"$v"$'\t'"${d##*/}"; fi
  done < <(_mise_node_installs)
  [ -z "$out" ] || printf '%s\n' "$out"
}

# The release a (re)install writes: the pin, or - for an npm agent - the
# newer release a node that is no longer active still holds, so a node switch
# puts back what the box ran instead of downgrading it to the pin.
_install_agent_version() { # <agent>
  local pin pkg old
  pin="$(agent_get "$1" version)" || return
  pkg="$(agent_get "$1" npm_package)" || return
  if [ -n "$pkg" ] && old="$(npm_stranded "$pkg")" && [ -n "$old" ] && cel_version_lt "$pin" "${old%%$'\t'*}"; then
    pin="${old%%$'\t'*}"
  fi
  printf '%s' "$pin"
}

# An agent whose bin is a dead mise shim is reinstalled with its own
# installer under the active node; a working bin is never touched. 0 when the
# bin is not a dead shim (or no longer is); 1 with the reason and the fix.
install_agent_revive() { # <agent>
  local a="$1" bin cmd version why
  bin="$(agent_get "$a" bin)" || return
  shim_dead "$bin" || return 0
  why="$SHIM_ERR"
  cmd="$(agent_get "$a" install)" || return
  [ -n "$cmd" ] || { c_err "$a: $bin is a dead mise shim ($why) and $a declares no installer"; return 1; }
  version="$(_install_agent_version "$a")" || return
  c_warn "$a: $bin is a dead mise shim ($why) - reinstalling $version under the active node"
  install_command "$a" "$cmd" "$version" \
    || { c_err "$a: reinstalling $version failed - fix the cause above, then run: cel setup --agents $a"; return 1; }
  ! have mise || mise reshim >/dev/null 2>&1 || true
  if ! have "$bin" || shim_dead "$bin"; then
    c_err "$a: $bin still does not run after reinstalling ${SHIM_ERR:+($SHIM_ERR) }- run: cel setup --agents $a"
    return 1
  fi
  c_ok "$a reinstalled ($version) under the active node"
}

install_agents() {
  local want="${1:-}" names a required bin cmd version
  c_hd "Agents"
  names="$(agent_names)" || return
  for a in $names; do
    required="$(agent_get "$a" required)" || return
    if [ -n "$want" ] && [ "$want" != all ] && [[ ",$want," != *",$a,"* ]] && [ "$required" != true ]; then
      continue
    fi
    bin="$(agent_get "$a" bin)" || return
    cmd="$(agent_get "$a" install)" || return
    version="$(agent_get "$a" version)" || return
    if have "$bin" && ! shim_dead "$bin"; then
      c_ok "$a already installed (retained; setup does not enforce its version)"
    elif have "$bin"; then
      install_agent_revive "$a" || return
    else
      install_command "$a" "$cmd" "$version" || return
      have "$bin" || { c_err "$a still missing after installation"; return 1; }
      c_ok "$a installed ($version)"
    fi
    install_extensions "$a" || return
  done
}

install_extensions() {
  local a="$1" f ext
  f="$(agent_get "$a" extensions_file)" || return
  [ -z "$f" ] || [ ! -f "$CEL_ROOT/$f" ] && return 0
  have "$(agent_get "$a" bin)" || return 0
  echo "    $a extensions:"
  while read -r ext; do
    case "$ext" in ''|\#*) continue;; esac
    if [ "$a" = pi ]; then
      # THROUGH pi's OWN INSTALLER, not npm. `npm install -g` puts the package
      # on disk and nothing more; pi loads only what `pi install <source>` has
      # registered in its settings (including the Anthropic auth extension,
      # the only way pi reaches a Claude subscription). `npm:` is pi's source
      # scheme; the version pin rides along.
      "$(agent_get "$a" bin)" install "npm:$ext" || return
      echo "      + $ext"
    fi
  done < "$CEL_ROOT/$f"
}

# The declared package names, version stripped, for anything that wants to
# compare against `pi list`.
extension_names() { # <agent>
  local f; f="$(agent_get "$1" extensions_file)" || return
  [ -n "$f" ] && [ -f "$CEL_ROOT/$f" ] || return 0
  grep -vE '^\s*(#|$)' "$CEL_ROOT/$f" | sed -E 's/^(@?[^@]+)@.*$/\1/'
}

# Which declared extensions pi does NOT have loaded. Empty when all present, or
# when pi is absent (nothing to check).
extensions_missing() { # <agent>
  local a="$1" have_list n
  local bin; bin="$(agent_get "$a" bin)"
  have "$bin" || return 0
  [ "$a" = pi ] || return 0
  have_list="$("$bin" list 2>/dev/null || true)"
  while read -r n; do
    [ -n "$n" ] || continue
    printf '%s\n' "$have_list" | grep -qF -- "$n" || printf '%s\n' "$n"
  done < <(extension_names "$a")
}

# Generate to a temporary file so failure retains an existing usable skill.
generate_skills() {
  local names n cmd req tmp
  names="$(generated_skill_names)" || return
  [ -z "$names" ] && return 0
  c_hd "Generated skills"
  for n in $names; do
    cmd="$(generated_skill_get "$n" command)" || return
    req="$(generated_skill_get "$n" requires)" || return
    if [ -n "$req" ] && ! have "$req"; then c_warn "$n skipped ($req not installed)"; continue; fi
    mkdir -p "$CEL_ROOT/core/skills/$n" || return
    tmp="$(mktemp "$CEL_ROOT/core/skills/$n/.generated.XXXXXX")" || return
    if bash -e -u -o pipefail -c "$cmd" > "$tmp" && [ -s "$tmp" ]; then
      mv "$tmp" "$CEL_ROOT/core/skills/$n/SKILL.md" || return
      c_ok "$n (from: $cmd)"
    else
      rm -f "$tmp"; c_err "$n generation failed"; return 1
    fi
  done
}

herdr_integrations() {
  have herdr || return 0
  c_hd "herdr integrations"
  local names a hi bin
  names="$(agent_names)" || return
  for a in $names; do
    hi="$(agent_get "$a" herdr_integration)" || return
    bin="$(agent_get "$a" bin)" || return
    [ -z "$hi" ] && continue
    have "$bin" || continue
    herdr integration install "$hi" || { c_err "$hi integration failed"; return 1; }
    c_ok "$hi"
  done
}

install_externals() {
  local base="$CEL_ROOT/externals.yaml" rows kind name ref source origin market dir repo subpath tmp installed previous old
  [ -f "$base" ] || return 0
  rows="$(externals_resolved "$base" "$@")" || {
    c_err "invalid or conflicting externals - resolve before installing"; return 1;
  }
  [ -n "$rows" ] || return 0
  c_hd "Externals"
  while IFS=$'\t' read -r kind name ref source origin; do
    case "$kind" in
      herdr_plugin)
        have herdr || { c_err "$name requires herdr"; return 1; }
        herdr plugin install "$source" --ref "$ref" --yes || return
        c_ok "herdr/$name ($ref)"
        ;;
      plugin)
        have claude || { c_err "$name requires claude"; return 1; }
        # Plugin versions are cache keys: a changed SHA with the same upstream
        # version can make `plugin update` silently retain old bytes. Include
        # the full pin in the marketplace identity to give it a fresh cache.
        market="celestial-$name-$ref"
        installed="$(claude plugin list --json)" || return
        previous="$(jq -r --arg name "$name" --arg current "$name@$market" '
          if type != "array" then error("invalid Claude plugin list") else
            .[] | select(.scope == "user" and .id != $current) | .id |
            select(test("^"+$name+"@celestial-"+$name+"-[a-f0-9]{40}$"))
          end' <<< "$installed")" || return
        dir="${XDG_DATA_HOME:-$HOME/.local/share}/celestial/marketplaces/$market"
        mkdir -p "$dir/.claude-plugin" || return
        subpath="${source#*/}"
        repo="${source%%/*}/${subpath%%/*}"
        if [[ "$subpath" == */* ]]; then subpath="${subpath#*/}"; else subpath=""; fi
        tmp="$(mktemp "$dir/.claude-plugin/.marketplace.XXXXXX")" || return
        if ! jq -n --arg market "$market" --arg name "$name" --arg repo "$repo" --arg sha "$ref" --arg path "$subpath" '
          {name:$market,owner:{name:"Celestial"},plugins:[{name:$name,
            source:(if $path == "" then {source:"github",repo:$repo,sha:$sha}
              else {source:"git-subdir",url:("https://github.com/"+$repo+".git"),path:$path,sha:$sha} end)}]}' > "$tmp"; then
          rm -f "$tmp"; return 1
        fi
        mv "$tmp" "$dir/.claude-plugin/marketplace.json" || return
        claude plugin marketplace add "$dir" --scope user || return
        claude plugin install --yes --scope user "$name@$market" || return
        # Retire only this installer's previous user-scope pins after success.
        # Claude retains orphaned cache bytes for sessions still using them.
        while IFS= read -r old; do
          [ -n "$old" ] || continue
          claude plugin uninstall "$old" --scope user || return
          claude plugin marketplace remove "${old#*@}" || return
        done <<< "$previous"
        c_ok "claude/$name ($ref)"
        ;;
    esac
  done <<< "$rows"
}

# GLOBAL NPM TOOLS (externals.yaml `npm_tools`, the base file only): a tool
# installed into the global npm of the box's node that registers itself with
# the runtimes. The registry tarball is downloaded and its sha512 checked
# against the recorded `integrity` (npm's dist.integrity) before npm sees it;
# npm installs that local file, and the package's own npm-shrinkwrap.json
# pins its dependencies. A release at or above the pin is kept, never
# downgraded. `register` is the tool's own `doctor`/`setup` CLI (REA's): its
# doctor runs first and setup only when the box is not aligned. The skill
# the tool installs is its own, never a copy in core/skills.
_npm_tools_rows() { # -> name package version integrity bin profile clients (tab separated)
  local f="$CEL_ROOT/externals.yaml"
  [ -f "$f" ] || return 0
  yq -r '(.npm_tools // {}) | to_entries[] | .key as $k | .value as $v |
    if ($k | test("^[a-z0-9][a-z0-9-]*$")) and ($v | type == "object")
      and ($v.package | type == "string") and ($v.package | test("^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$"))
      and ($v.version | type == "string") and ($v.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
      and ($v.integrity | type == "string") and ($v.integrity | test("^sha512-[A-Za-z0-9+/]{86}==$"))
      and ($v.bin | type == "string") and ($v.bin | test("^[a-z0-9][a-z0-9-]*$"))
      and ($v.source | type == "string") and ($v.source | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
      and ($v.license == "MIT" or $v.license == "Apache-2.0")
      and ($v.register | type == "object")
      and ($v.register.tool_catalog_profile | type == "string") and ($v.register.tool_catalog_profile | test("^[a-z][a-z-]*$"))
      and ($v.register.clients | type == "array") and ($v.register.clients | length > 0)
      and all($v.register.clients[]; type == "string" and test("^[a-z][a-z_]*$"))
    then [$k, $v.package, $v.version, $v.integrity, $v.bin, $v.register.tool_catalog_profile, ($v.register.clients | join(" "))] | @tsv
    else error("invalid npm tool " + $k + ": require package, version x.y.z, sha512 integrity, bin, source owner/repo, license MIT or Apache-2.0 and register clients/tool_catalog_profile") end' "$f"
}

# The exact registry tarball, checked against its integrity, or nothing.
_npm_tool_fetch() ( # package version integrity destination
  set -euo pipefail
  local package="$1" version="$2" integrity="$3" dest="$4" want got
  curl -fSL "https://registry.npmjs.org/$package/-/${package##*/}-$version.tgz" -o "$dest"
  want="$(printf '%s' "${integrity#sha512-}" | base64 -d | od -An -v -tx1 | tr -d ' \n')"
  got="$(sha512sum < "$dest")"
  [ "${got%% *}" = "$want" ] || { echo "integrity mismatch: $package@$version" >&2; exit 1; }
)

# The package's own engines range for node, read from the verified tarball,
# against the node npm would install it under: only `^X.Y.Z`, `>=X.Y.Z` and
# `X.Y.Z` clauses joined by `||` are understood, and a range with none of
# them is refused rather than guessed at.
_npm_engine_ok() { # node-version range
  local v="${1#v}" range="$2" clause min known=0
  local IFS='|'
  for clause in $range; do
    clause="${clause// /}"
    [ -n "$clause" ] || continue
    case "$clause" in
      '^'*) min="${clause#^}" ;;
      '>='*) min="${clause#>=}" ;;
      *) min="$clause" ;;
    esac
    [[ "$min" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    known=1
    case "$clause" in
      '^'*) [ "${v%%.*}" = "${min%%.*}" ] && ! cel_version_lt "$v" "$min" && return 0 ;;
      '>='*) ! cel_version_lt "$v" "$min" && return 0 ;;
      *) [ "$v" = "$min" ] && return 0 ;;
    esac
  done
  [ "$known" = 1 ] || return 2
  return 1
}

# REA reads PI_CODING_AGENT_DIR for omp's root AND pi's, OPENCODE_CONFIG,
# OPENCODE_CONFIG_DIR and CLAUDE_CONFIG_DIR for those clients' files - and a
# caller inside a cel launch carries a workspace overlay or private dir in
# them. So each call gets exactly the root cel launches that agent with
# (gateway_omp_dir / gateway_pi_dir, which honour CEL_OMP_AGENT_DIR and
# CEL_PI_AGENT_DIR) and none of the inherited overlays or profiles.
_npm_tool_run() { # agent-root command...
  local root="$1"; shift
  env -u OPENCODE_CONFIG -u OPENCODE_CONFIG_CONTENT -u OPENCODE_CONFIG_DIR -u CLAUDE_CONFIG_DIR \
    -u OMP_PROFILE -u PI_PROFILE -u PI_CONFIG_DIR PI_CODING_AGENT_DIR="$root" "$@" </dev/null
}

_npm_tool_align() { # name bin profile agent-root client...
  local name="$1" bin="$2" profile="$3" root="$4" c out
  shift 4
  local -a flags=()
  for c in "$@"; do flags+=(--client "$c"); done
  if out="$(_npm_tool_run "$root" "$bin" doctor "${flags[@]}" --skill --format json 2>/dev/null)" \
      && jq -e '.healthy == true' <<< "$out" >/dev/null 2>&1; then
    c_ok "$name: $* already aligned"
    return 0
  fi
  _npm_tool_run "$root" "$bin" setup --yes "${flags[@]}" --tool-catalog-profile "$profile" \
    || { c_err "$name setup for $* failed"; return 1; }
  c_ok "$name: registered $* ($profile)"
}

install_npm_tools() {
  local rows name package version integrity bin profile clients prefix have_v tmp c pi
  rows="$(_npm_tools_rows)" || { c_err "invalid npm_tools in externals.yaml - nothing installed"; return 1; }
  [ -n "$rows" ] || return 0
  c_hd "npm tools"
  have npm || { c_err "npm tools need node's npm on PATH (agents.yaml base_tools node)"; return 1; }
  while IFS=$'\t' read -r name package version integrity bin profile clients; do
    prefix="$(npm prefix -g)" || return
    have_v="$(jq -r '.version // empty' "$(npm root -g)/$package/package.json" 2>/dev/null || true)"
    if [ -n "$have_v" ] && ! cel_version_lt "$have_v" "$version"; then
      c_ok "$name: $package $have_v installed (pin $version; kept)"
    else
      tmp="$(mktemp -d)" || return
      # one flat name: a scoped package's own name would need a directory
      if ! _npm_tool_fetch "$package" "$version" "$integrity" "$tmp/package.tgz"; then
        rm -rf "$tmp"; c_err "$name: $package@$version not installed (download or integrity check failed)"; return 1
      fi
      # Its own engines range, from the verified bytes, before npm runs: an
      # older node is retained by install_base, and npm would only fail late.
      local engines node_v
      engines="$(tar -xzOf "$tmp/package.tgz" package/package.json 2>/dev/null | jq -r '.engines.node // empty' 2>/dev/null)" || engines=""
      if [ -n "$engines" ]; then
        node_v="$(node --version 2>/dev/null)" || node_v=""
        if [ -z "$node_v" ] || ! _npm_engine_ok "$node_v" "$engines"; then
          rm -rf "$tmp"
          c_err "$name: $package@$version needs node $engines, but this node is ${node_v:-missing} - select a supported node (mise use -g node@lts, which agents.yaml base_tools records), then rerun cel setup"
          return 1
        fi
      fi
      # npm runs the package's install scripts (REA's frida binding needs one).
      npm install -g --no-fund --no-audit "$tmp/package.tgz" || { rm -rf "$tmp"; c_err "$name: npm install failed"; return 1; }
      rm -rf "$tmp"
      ! have mise || mise reshim >/dev/null 2>&1 || true
      c_ok "$name: $package $version installed"
    fi
    [ -x "$prefix/bin/$bin" ] || { c_err "$name: $prefix/bin/$bin missing after install"; return 1; }
    local -a main=()
    pi=0
    for c in $clients; do if [ "$c" = pi ]; then pi=1; else main+=("$c"); fi; done
    if [ "${#main[@]}" -gt 0 ]; then
      _npm_tool_align "$name" "$prefix/bin/$bin" "$profile" "$(gateway_omp_dir)" "${main[@]}" || return
    fi
    if [ "$pi" = 1 ]; then
      _npm_tool_align "$name" "$prefix/bin/$bin" "$profile" "$(gateway_pi_dir)" pi || return
    fi
  done <<< "$rows"
}

cmd_setup() {
  local agents=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --agents) [ $# -ge 2 ] && [ -n "$2" ] || { c_err "--agents requires a value"; return 2; }; agents="$2"; shift 2;;
      *) c_err "unknown setup option: $1"; return 2;;
    esac
  done
  install_base || return
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
  install_agents "$agents" || return
  link_all || return
  herdr_integrations || return
  install_externals || return
  # after link_all: REA writes beside the plane's links, never under them
  install_npm_tools || return
  c_hd "Next"
  echo "    gh auth login && claude setup-token   # human-only steps"
  echo "    eval \"\$(cel shellenv)\"                 # add to your shell rc"
  # ONE PLACE SECRETS LIVE: three answers to "where do I put my key" is zero
  # answers, so setup, the workspace hint and the checker all name env.local.
  echo "    <workspace>/env.local                 # per-workspace secrets (gitignored);"
  echo "                                          # ~/.zshenv only for a box-wide credential"
  echo "    cel doctor                            # verify"
}
