# shellcheck shell=bash
# Cutting a version is three things in one order - a PR, a tag, a GitHub
# Release - and the order is forced by this repo's branch protection: main
# takes no direct pushes, so the version bump must arrive as a reviewed PR and
# the tag can only follow its merge. Nothing has been tagged since v0.2.0 while
# forty-odd merges landed, because the process lived in someone's head.
#
# Everything the workflow does that can run off GitHub lives in
# tools/release/cut.py and tools/release/notes.py and is tested here directly;
# the YAML only calls them, so `act` is not needed to trust this.
source "$CEL_ROOT/lib/common.sh"

_REL_REPO="$CEL_ROOT" # the real plane, captured before CEL_ROOT is moved
source "$_REL_REPO/lib/release.sh"

_rel_changelog() { # <path>
  cat >"$1" <<'EOS'
# Changelog

## [Unreleased]

### Added
- widget mode learns to hum

## [0.2.0] - 2026-01-02

### Added
- gadget mode arrives

## [0.1.0] - 2026-01-01

### Added
- alpha groundwork
EOS
}

# A throwaway root standing in for the plane: VERSION and CHANGELOG of its
# own, the real tools/ borrowed by symlink, and a `gh` stub first on PATH that
# logs its argv. Never the live checkout - `cel release` talks to GitHub.
_rel_fixture() { # -> T, ROOT, LOG; CEL_ROOT and PATH point at the fixture
  T="$(mktemp -d)"
  ROOT="$T/root"
  LOG="$T/gh.log"
  mkdir -p "$ROOT" "$T/bin"
  : >"$LOG"
  printf '0.2.0\n' >"$ROOT/VERSION"
  _rel_changelog "$ROOT/CHANGELOG.md"
  ln -s "$_REL_REPO/tools" "$ROOT/tools"
  cat >"$T/bin/gh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOG"
case "\$1 \$2" in
  'workflow run') printf 'Created workflow_dispatch event\n' ;;
  'run list') printf 'https://github.com/example/celestial/actions/runs/42\n' ;;
  'pr list') printf '#12 release: v0.3.0 https://github.com/example/celestial/pull/12\n' ;;
  'release list') printf 'v0.2.0\n' ;;
esac
EOS
  chmod +x "$T/bin/gh"
  export PATH="$T/bin:$PATH"
  export CEL_ROOT="$ROOT"
}
_rel_cleanup() { CEL_ROOT="$_REL_REPO"; rm -rf "$T"; }
# `die` exits the process it is called in, so every refusal is exercised in a
# subshell - otherwise the first expected failure takes the test with it.
_rel_try() { ( cmd_release "$@" ) >/dev/null 2>&1; }

_notes() { python3 "$_REL_REPO/tools/release/notes.py" "$@"; }
_cut() { python3 "$_REL_REPO/tools/release/cut.py" "$@"; }

# --- notes.py: one section, exactly ------------------------------------------

test_release_notes_extracts_one_section() {
  local T out; T="$(mktemp -d)"; _rel_changelog "$T/CHANGELOG.md"
  out="$(_notes 0.2.0 --changelog "$T/CHANGELOG.md")" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "gadget mode arrives" || { rm -rf "$T"; return 1; }
  case "$out" in *"alpha groundwork"*) rm -rf "$T"; printf 'bled into the next section\n' >&2; return 1;; esac
  case "$out" in *"widget mode learns"*) rm -rf "$T"; printf 'bled into the previous section\n' >&2; return 1;; esac
  rm -rf "$T"
}

test_release_notes_prints_the_pending_section_for_unreleased() {
  local T out; T="$(mktemp -d)"; _rel_changelog "$T/CHANGELOG.md"
  out="$(_notes unreleased --changelog "$T/CHANGELOG.md")" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "widget mode learns to hum" || { rm -rf "$T"; return 1; }
  case "$out" in *"gadget mode arrives"*) rm -rf "$T"; printf 'ran past [Unreleased]\n' >&2; return 1;; esac
  rm -rf "$T"
}

# Silence would look like "this version shipped nothing"; a version nobody
# wrote notes for is a mistake, and the release job must stop on it.
test_release_notes_fails_on_an_unknown_version() {
  local T; T="$(mktemp -d)"; _rel_changelog "$T/CHANGELOG.md"
  assert_fails _notes 9.9.9 --changelog "$T/CHANGELOG.md" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# --- cut.py: the rewrite the workflow performs -------------------------------

test_release_cut_rewrites_version_and_changelog() {
  local T out; T="$(mktemp -d)"
  _rel_changelog "$T/CHANGELOG.md"; printf '0.2.0\n' >"$T/VERSION"
  out="$(_cut 0.3.0 --changelog "$T/CHANGELOG.md" --version-file "$T/VERSION" --today 2026-02-01)" \
    || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/VERSION")" "0.3.0" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/CHANGELOG.md")" "## [0.3.0] - 2026-02-01" || { rm -rf "$T"; return 1; }
  # a fresh empty [Unreleased] sits above it, or the next ticket has nowhere
  # to write and quietly appends to the version that just shipped
  assert_contains "$(cat "$T/CHANGELOG.md")" "## [Unreleased]" || { rm -rf "$T"; return 1; }
  assert_eq "$(_notes unreleased --changelog "$T/CHANGELOG.md")" "" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "widget mode learns to hum" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_release_cut_refuses_an_empty_unreleased_section() {
  local T; T="$(mktemp -d)"
  printf '# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-01-02\n\n- gadget mode arrives\n' >"$T/CHANGELOG.md"
  printf '0.2.0\n' >"$T/VERSION"
  assert_fails _cut 0.3.0 --changelog "$T/CHANGELOG.md" --version-file "$T/VERSION" --today 2026-02-01 \
    || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/VERSION")" "0.2.0" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_release_cut_refuses_non_semver_and_not_greater_versions() {
  local T; T="$(mktemp -d)"
  _rel_changelog "$T/CHANGELOG.md"; printf '0.2.0\n' >"$T/VERSION"
  assert_fails _cut 0.3 --changelog "$T/CHANGELOG.md" --version-file "$T/VERSION" || { rm -rf "$T"; return 1; }
  assert_fails _cut v0.3.0 --changelog "$T/CHANGELOG.md" --version-file "$T/VERSION" || { rm -rf "$T"; return 1; }
  assert_fails _cut 0.2.0 --changelog "$T/CHANGELOG.md" --version-file "$T/VERSION" || { rm -rf "$T"; return 1; }
  assert_fails _cut 0.1.0 --changelog "$T/CHANGELOG.md" --version-file "$T/VERSION" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# --- cel release: the wrapper ------------------------------------------------

# A bad version caught locally costs nothing; caught in the action it costs a
# run, a red check and an explanation.
test_release_refuses_a_bad_version_without_calling_gh() {
  _rel_fixture
  assert_fails _rel_try 0.3 || { _rel_cleanup; return 1; }
  assert_fails _rel_try 0.1.0 || { _rel_cleanup; return 1; }
  assert_fails _rel_try 0.2.0 || { _rel_cleanup; return 1; }
  assert_eq "$(cat "$LOG")" "" || { _rel_cleanup; return 1; }
  _rel_cleanup
}

test_release_dispatches_the_workflow_with_the_version_input() {
  _rel_fixture
  local out; out="$(cmd_release 0.3.0 2>&1)" || { _rel_cleanup; return 1; }
  assert_contains "$(cat "$LOG")" "workflow run release.yml -f version=0.3.0" || { _rel_cleanup; return 1; }
  assert_contains "$out" "actions/runs/42" || { _rel_cleanup; return 1; }
  _rel_cleanup
}

test_release_dry_run_prints_the_section_and_touches_nothing() {
  _rel_fixture
  local out; out="$(cmd_release 0.3.0 --dry-run 2>&1)" || { _rel_cleanup; return 1; }
  assert_contains "$out" "widget mode learns to hum" || { _rel_cleanup; return 1; }
  assert_contains "$out" "hygiene" || { _rel_cleanup; return 1; }
  assert_eq "$(cat "$LOG")" "" || { _rel_cleanup; return 1; }
  assert_eq "$(cat "$ROOT/VERSION")" "0.2.0" || { _rel_cleanup; return 1; }
  _rel_cleanup
}

test_release_status_shows_the_open_pr_and_the_newest_tag() {
  _rel_fixture
  local out; out="$(cmd_release status 2>&1)" || { _rel_cleanup; return 1; }
  assert_contains "$out" "#12 release: v0.3.0" || { _rel_cleanup; return 1; }
  assert_contains "$out" "v0.2.0" || { _rel_cleanup; return 1; }
  _rel_cleanup
}

# --- the box hears about it --------------------------------------------------

# The point of the tag: a box on the release channel is told. Two clones and a
# bare origin, no network - push a tag and `cel update --check` must go from
# "up to date" to "available", exit 1 included, because a release nobody is
# told about is the state this ticket exists to end.
test_release_tag_shows_as_available_on_the_release_channel() {
  local T ORIGIN A B rc out
  T="$(mktemp -d)"; ORIGIN="$T/origin.git"; A="$T/a"; B="$T/b"
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$A"
  git -C "$A" config user.email t@example.com
  git -C "$A" config user.name tester
  printf '0.2.0\n' >"$A/VERSION"
  _rel_changelog "$A/CHANGELOG.md"
  git -C "$A" add -A && git -C "$A" commit -qm 'release: v0.2.0'
  git -C "$A" tag v0.2.0
  git -C "$A" remote add origin "$ORIGIN"
  git -C "$A" push -q origin main --tags
  git clone -q "$ORIGIN" "$B"

  local keep="$CEL_ROOT"
  export CEL_ROOT="$B" CEL_CONFIG_FILE="$T/config.yaml" CEL_REGISTRY="$T/registry.yaml" \
         CEL_INBOX_DIR="$T/inbox" CEL_UPDATE_DIR="$T/updatestate"
  source "$_REL_REPO/lib/update.sh"
  rc=0; out="$(cmd_update --check 2>&1)" || rc=$?
  assert_eq "$rc" "0" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }

  # the cut lands: VERSION bumped on main, annotated tag pushed after it
  printf '0.3.0\n' >"$A/VERSION"
  git -C "$A" commit -qam 'release: v0.3.0'
  git -C "$A" tag -a v0.3.0 -m 'widget mode learns to hum'
  git -C "$A" push -q origin main --tags

  rc=0; out="$(cmd_update --check 2>&1)" || rc=$?
  assert_eq "$rc" "1" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }
  assert_contains "$out" "available v0.3.0" || { CEL_ROOT="$keep"; rm -rf "$T"; return 1; }
  CEL_ROOT="$keep"
  rm -rf "$T"
}

# --- the subject a squash merge actually leaves -------------------------------

# The publish job reads the version off main's head subject, and GitHub's
# squash merge appends the PR number: `release: v0.3.0 (#57)`. A naive strip of
# the `release: v` prefix yields `0.3.0 (#57)`, which never equals VERSION, so
# the VERSION-agrees check refused the ONLY path a release can actually take -
# every hand-pushed tag worked and the real merge did not. Parsing lives in
# cut.py so this shape is tested without GitHub.
_subject() { python3 "$_REL_REPO/tools/release/cut.py" --version-from-subject "$1"; }

test_release_version_from_a_squash_merge_subject() {
  assert_eq "$(_subject 'release: v0.3.0 (#57)')" "0.3.0" || return 1
  assert_eq "$(_subject 'release: v0.3.0')" "0.3.0" || return 1
  assert_eq "$(_subject 'release: v10.2.13 (#1234)')" "10.2.13" || return 1
}

test_release_version_from_subject_refuses_anything_else() {
  assert_fails _subject 'chore: tidy the widget' || return 1
  assert_fails _subject 'release: v0.3 (#57)' || return 1
  assert_fails _subject 'release: v0.3.0 and more (#57)' || return 1
}

# --- fragments: one PR, one file, no shared line ------------------------------

# Seven open PRs each added a line under [Unreleased] and every squash merge
# made the other six DIRTY on the same three lines. A PR now writes
# changelog.d/<branch>.md and the cut assembles them, so two PRs never touch
# the same line.
_rel_fragment() { # <dir> <name> <heading> <bullet>
  mkdir -p "$1"
  printf '%s\n%s\n' "$3" "$4" >"$1/$2"
}

test_release_cut_assembles_fragments_in_category_then_filename_order() {
  local T out
  T="$(mktemp -d)"
  printf '# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-01-02\n\n### Added\n- gadget mode arrives\n' >"$T/CHANGELOG.md"
  printf '0.2.0\n' >"$T/VERSION"
  _rel_fragment "$T/changelog.d" "b-second.md" '### Added' '- second added entry'
  _rel_fragment "$T/changelog.d" "a-first.md" '### Added' '- first added entry'
  _rel_fragment "$T/changelog.d" "c-fixed.md" '### Fixed' '- a fix lands'
  out="$(_cut 0.3.0 --changelog "$T/CHANGELOG.md" --version-file "$T/VERSION" \
         --fragments "$T/changelog.d" --today 2026-02-01)" || { rm -rf "$T"; return 1; }

  # category order Added before Fixed, file-name order within the category
  local shipped; shipped="$(_notes 0.3.0 --changelog "$T/CHANGELOG.md")" || { rm -rf "$T"; return 1; }
  local expected; expected='### Added
- first added entry
- second added entry

### Fixed
- a fix lands'
  assert_eq "$shipped" "$expected" || { rm -rf "$T"; return 1; }
  assert_eq "$out" "$expected" || { rm -rf "$T"; return 1; }

  # the fragments are consumed, and [Unreleased] is left empty for the next PR
  assert_eq "$(ls "$T/changelog.d")" "" || { rm -rf "$T"; return 1; }
  assert_eq "$(_notes unreleased --changelog "$T/CHANGELOG.md" --fragments "$T/changelog.d")" "" \
    || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

test_release_cut_refuses_no_fragments_and_an_empty_unreleased() {
  local T; T="$(mktemp -d)"
  printf '# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-01-02\n\n- gadget mode arrives\n' >"$T/CHANGELOG.md"
  printf '0.2.0\n' >"$T/VERSION"
  mkdir -p "$T/changelog.d"
  assert_fails _cut 0.3.0 --changelog "$T/CHANGELOG.md" --version-file "$T/VERSION" \
    --fragments "$T/changelog.d" --today 2026-02-01 || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/VERSION")" "0.2.0" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# The old habit keeps working through the transition: a hand-written entry and
# no fragments still ships that entry.
test_release_cut_ships_a_hand_written_unreleased_entry_with_no_fragments() {
  local T out; T="$(mktemp -d)"
  _rel_changelog "$T/CHANGELOG.md"; printf '0.2.0\n' >"$T/VERSION"
  mkdir -p "$T/changelog.d"
  out="$(_cut 0.3.0 --changelog "$T/CHANGELOG.md" --version-file "$T/VERSION" \
         --fragments "$T/changelog.d" --today 2026-02-01)" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "widget mode learns to hum" || { rm -rf "$T"; return 1; }
  assert_contains "$(cat "$T/CHANGELOG.md")" "## [0.3.0] - 2026-02-01" || { rm -rf "$T"; return 1; }
  assert_eq "$(_notes unreleased --changelog "$T/CHANGELOG.md" --fragments "$T/changelog.d")" "" \
    || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# `cel release --dry-run` must show the REAL pending notes, which now live in
# the fragments; and reading them must not touch the tree.
test_release_notes_unreleased_assembles_fragments_without_touching_the_tree() {
  local T out before; T="$(mktemp -d)"
  printf '# Changelog\n\n## [Unreleased]\n\n### Changed\n- hand written still counts\n\n## [0.2.0] - 2026-01-02\n\n- gadget\n' >"$T/CHANGELOG.md"
  _rel_fragment "$T/changelog.d" "z-added.md" '### Added' '- from a fragment'
  before="$(cat "$T/CHANGELOG.md")"
  out="$(_notes unreleased --changelog "$T/CHANGELOG.md" --fragments "$T/changelog.d")" \
    || { rm -rf "$T"; return 1; }
  assert_contains "$out" "- from a fragment" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "- hand written still counts" || { rm -rf "$T"; return 1; }
  assert_eq "$(cat "$T/CHANGELOG.md")" "$before" || { rm -rf "$T"; return 1; }
  assert_eq "$(ls "$T/changelog.d")" "z-added.md" || { rm -rf "$T"; return 1; }
  rm -rf "$T"
}
