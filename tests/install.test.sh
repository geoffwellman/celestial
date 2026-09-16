# shellcheck shell=bash
# pi extensions. `npm install -g` puts a package on disk and nothing more; pi
# loads only what `pi install <source>` has registered in its settings. Every
# extension the plane declared was therefore installed and never loaded - ten
# of them, including the one that gives pi a Claude subscription - and the
# first pi worker could not start. Found 2026-09-16.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/manifest.sh"
source "$CEL_ROOT/lib/install.sh"

# A stub `pi` that logs argv and answers `list` from a file the test controls,
# plus a stub `npm` that must never be reached. CEL_ROOT is pointed at a scratch
# tree so the extensions file is the test's, not the plane's.
_ext_fixture() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/root/tools/pi"
  # the manifest's pi binary is renamed so removing the stub means pi is
  # genuinely absent, rather than falling through to the real one on PATH
  sed -E '/^  pi:/,/^  [a-z]+:/ s/^(\s+bin:).*/\1 pi-stub/' "$CEL_ROOT/agents.yaml" > "$T/root/agents.yaml"
  printf '# comment\n\n@scope/alpha@1.2.3\nbeta@4.5.6\n' > "$T/root/tools/pi/extensions.txt"
  : > "$T/list"
  cat > "$T/bin/pi-stub" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$T/pi.log"
[ "\$1" = list ] && cat "$T/list"
exit 0
EOF
  cat > "$T/bin/npm" <<EOF
#!/usr/bin/env bash
echo "npm was called: \$*" >> "$T/pi.log"; exit 1
EOF
  chmod +x "$T/bin/pi-stub" "$T/bin/npm"
  export PATH="$T/bin:$PATH" CEL_ROOT="$T/root" CEL_MANIFEST="$T/root/agents.yaml"
}

test_extensions_install_through_pi_not_npm() {
  _ext_fixture
  install_extensions pi > /dev/null
  assert_contains "$(cat "$T/pi.log")" "install npm:@scope/alpha@1.2.3"
  assert_contains "$(cat "$T/pi.log")" "install npm:beta@4.5.6"
  ! grep -q "npm was called" "$T/pi.log" || { echo "fell back to npm"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
test_comments_and_blank_lines_are_not_packages() {
  _ext_fixture
  install_extensions pi > /dev/null
  assert_eq "$(grep -c '^install' "$T/pi.log")" "2"
  rm -rf "$T"
}
test_extension_names_strip_the_version_pin() {
  _ext_fixture
  assert_eq "$(extension_names pi | tr '\n' ' ')" "@scope/alpha beta "
  rm -rf "$T"
}
# Doctor's question: which declared extensions has pi NOT loaded?
test_missing_extensions_are_those_absent_from_pi_list() {
  _ext_fixture
  printf '@scope/alpha 1.2.3 (npm)\n' > "$T/list"
  assert_eq "$(extensions_missing pi | tr '\n' ' ')" "beta "
  printf '@scope/alpha 1.2.3 (npm)\nbeta 4.5.6 (npm)\n' > "$T/list"
  assert_eq "$(extensions_missing pi)" ""
  rm -rf "$T"
}
test_missing_is_empty_when_pi_is_not_installed() {
  _ext_fixture
  rm "$T/bin/pi-stub"
  assert_eq "$(extensions_missing pi)" ""
  rm -rf "$T"
}
