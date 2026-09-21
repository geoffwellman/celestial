# shellcheck shell=bash
# Setup installs trusted code. Tests must replace every network/process boundary;
# never call setup against the user's actual HOME or running services.
[ -n "${_CEL_INSTALL:-}" ] && return 0
_CEL_INSTALL=1
# shellcheck source=lib/manifest.sh
. "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"
# shellcheck source=lib/externals.sh
. "$(dirname "${BASH_SOURCE[0]}")/externals.sh"

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
  local section="$1" name="$2" bin="${3:-$2}" arch asset url digest member tmp stage
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
  mkdir -p "$HOME/.local/bin" || exit
  stage="$(mktemp "$HOME/.local/bin/.cel-install.XXXXXX")" || exit
  cat "$tmp/binary" > "$stage" || exit
  chmod 755 "$stage" || exit
  mv -fT "$stage" "$HOME/.local/bin/$bin"
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
    if have "$bin"; then
      c_ok "$a already installed (retained; setup does not enforce its version)"
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
      # registered in its settings, so every extension this file has ever
      # listed was installed and never loaded - `pi list` said "No packages
      # installed" with ten of them sitting in node_modules. Among them the
      # Anthropic auth extension, which is the only way pi reaches a Claude
      # subscription. Found 2026-09-16 when the first pi worker could not
      # start. `npm:` is pi's source scheme; the version pin rides along.
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
  # shellcheck source=lib/console.sh
  . "$CEL_ROOT/lib/console.sh"
  console_install_deps || return
  link_all || return
  herdr_integrations || return
  install_externals || return
  c_hd "Next"
  echo "    gh auth login && claude setup-token   # human-only steps"
  echo "    eval \"\$(cel shellenv)\"                 # add to your shell rc"
  # ONE PLACE SECRETS LIVE. This used to be three (workspace.yaml's hint said
  # env.local, the setup skill said ~/.zshenv, the checker read whatever the
  # shell happened to hold), and three answers to "where do I put my key" is
  # zero answers - the newcomer puts it somewhere and nothing agrees.
  echo "    <workspace>/env.local                 # per-workspace secrets (gitignored);"
  echo "                                          # ~/.zshenv only for a box-wide credential"
  echo "    cel doctor                            # verify"
}
