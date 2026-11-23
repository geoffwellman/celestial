# shellcheck shell=bash
# Node is a base tool the owner selects through mise (`node = "lts"` in the
# global mise config). Celestial records the same alias, so `cel setup` on a
# box without node writes `node@lts`, never a fixed older release, and an
# installed node with its mise selection is retained; `cel update` has no
# base-tool step and leaves the mise config byte for byte.

_bt_setup() {
  T="$(mktemp -d)"; LOG="$T/mise.log"; : > "$LOG"
  export HOME="$T/home" BT_T="$T"
  mkdir -p "$HOME/.config/mise" "$T/bin"
  printf '[tools]\nbun = "latest"\nnode = "lts"\n' > "$HOME/.config/mise/config.toml"
  export CEL_MANIFEST="$CEL_ROOT/agents.yaml" CEL_MANIFEST_CACHE="$T/cache"
  local b
  # every base tool but node is present; nothing real installs or downloads
  for b in gh bun lazygit herdr cli-proxy-api cargo; do
    printf '#!/bin/sh\n[ "$1" != --version ] || echo "%s version 2.100.0 (fixture)"\n' "$b" > "$T/bin/$b"
  done
  cat > "$T/bin/mise" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BT_T/mise.log"
if [ "$1 $2" = "use -g" ]; then
  printf '[tools]\nbun = "latest"\nnode = "%s"\n' "${3#node@}" > "$HOME/.config/mise/config.toml"
  printf '#!/bin/sh\necho v0\n' > "$BT_T/bin/node"; chmod +x "$BT_T/bin/node"
fi
SH
  chmod +x "$T/bin"/*
  ln -s "$(type -P yq)" "$T/bin/yq"
  export PATH="$T/bin:/usr/bin:/bin"
  source "$CEL_ROOT/lib/common.sh"
  source "$CEL_ROOT/lib/manifest.sh"
  source "$CEL_ROOT/lib/install.sh"
}

test_node_base_tool_follows_the_lts_alias() {
  assert_eq "$(yq -r '.base_tools.node.version' "$CEL_ROOT/agents.yaml")" lts
}

test_setup_installs_a_missing_node_as_lts_through_mise() {
  _bt_setup
  install_base >/dev/null 2>&1 || { echo "install_base failed"; return 1; }
  assert_eq "$(cat "$LOG")" 'use -g node@lts' || return 1
  assert_eq "$(sed -n 's/^node = //p' "$HOME/.config/mise/config.toml")" '"lts"' || return 1
  rm -rf "$T"
}

test_setup_retains_an_installed_node_and_its_mise_config() {
  _bt_setup
  printf '#!/bin/sh\necho v24.22.3\n' > "$T/bin/node"; chmod +x "$T/bin/node"
  local sum; sum="$(cksum < "$HOME/.config/mise/config.toml")"
  install_base >/dev/null 2>&1 || { echo "install_base failed"; return 1; }
  assert_eq "$(cat "$LOG")" '' || return 1
  assert_eq "$(cksum < "$HOME/.config/mise/config.toml")" "$sum" || return 1
  rm -rf "$T"
}

test_update_components_leave_an_lts_mise_config_alone() {
  _bt_setup
  printf '#!/bin/sh\necho v24.22.3\n' > "$T/bin/node"; chmod +x "$T/bin/node"
  export CEL_CONFIG_FILE="$T/config.yaml" CEL_UPDATE_DIR="$T/update"
  source "$CEL_ROOT/lib/update.sh"
  local sum; sum="$(cksum < "$HOME/.config/mise/config.toml")"
  # (its npm tools step fails here - this fixture has no npm - which is not
  # what is under test)
  _update_components >/dev/null 2>&1 || true
  assert_eq "$(cat "$LOG")" '' || { echo "cel update ran mise"; return 1; }
  assert_eq "$(cksum < "$HOME/.config/mise/config.toml")" "$sum" || return 1
  rm -rf "$T"
}
