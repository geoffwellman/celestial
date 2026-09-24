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

# --- cel release <product> <value>: the plane cuts ANY product's release -----

# `cel release` used to mean "cut a version of celestial itself" - it
# dispatched celestial's own release.yml in whatever repo the box's checkout
# pointed at. Every local refusal passed for anyone who was not the owner and
# then `gh workflow run` returned 403, so it failed at the last step looking
# like it should have worked. The plane now reads a per-repo `release:` block,
# checks the caller may dispatch BEFORE spending anything, and releasing the
# plane itself is one ordinary instance of that.

# A whole fixture workspace: six repos across three release shapes, real repo
# directories for the version files, and a `gh` stub first on PATH that logs
# every argv - the call log is what proves a refusal dispatched nothing.
_prel_fixture() { # -> T, WS, LOG
  T="$(mktemp -d)"
  WS="$T/ws"
  LOG="$T/gh.log"
  mkdir -p "$WS/repos/widget/changelog.d" "$WS/repos/doodad" "$T/bin"
  : >"$LOG"
  cat >"$WS/workspace.yaml" <<'EOS'
name: alpha
kind: hustle
org: someone
products:
  - name: bundle
    repos: [widget, gizmo]
  - name: gadget
    repos: [doodad, plain]
repos:
  - name: widget
    url: git@github.com:someone/widget.git
    release:
      workflow: release.yml
      input: version
      accepts: semver
      version_file: VERSION
      changelog: changelog.d/
      tag: "v{version}"
  - name: gizmo
    url: git@github.com:someone/gizmo.git
    release:
      workflow: release.yaml
      input: bump
      accepts: [major, minor, patch]
      tag: "v{version}"
  - name: doodad
    url: git@github.com:someone/doodad.git
    release:
      workflow: release.yml
      input: version
      accepts: semver
      version_file: VERSION
  - name: plain
    url: git@github.com:someone/plain.git
  - name: orphan
    url: git@github.com:someone/orphan.git
  - name: solo
    url: git@github.com:someone/solo.git
    release:
      workflow: release.yaml
      input: bump
      accepts: [major, minor, patch]
EOS
  printf '0.2.0\n' >"$WS/repos/widget/VERSION"
  printf '0.2.0\n' >"$WS/repos/doodad/VERSION"
  printf '# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-01-02\n\n### Added\n- gadget mode arrives\n' \
    >"$WS/repos/widget/CHANGELOG.md"
  printf '### Added\n- widget mode learns to hum\n' >"$WS/repos/widget/changelog.d/WG-1-hum.md"
  _prel_gh_stub
  export PATH="$T/bin:$PATH"
}

# One workspace, one releasable repo: the shape `cel release 0.3.0` with no
# product must keep working in, because that is the plane's own workspace.
_prel_single_fixture() { # -> T, WS, LOG
  _prel_fixture
  python3 - "$WS/workspace.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
head, repos = s.split("repos:\n", 1)
head = head.replace("""products:
  - name: bundle
    repos: [widget, gizmo]
  - name: gadget
    repos: [doodad, plain]
""", "")
first = repos.split("  - name: gizmo")[0]
open(p, "w").write(head + "repos:\n" + first)
PY
}

_prel_gh_stub() {
  cat >"$T/bin/gh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOG"
a="\$*"
case "\$1 \$2" in
  'repo view')    printf '%s\n' "\${CEL_TEST_PERM:-WRITE}" ;;
  'workflow run') printf 'Created workflow_dispatch event\n' ;;
  'run watch')    printf 'run completed with success\n' ;;
  'release list') printf 'v0.2.0 https://github.com/someone/thing/releases/tag/v0.2.0\n' ;;
  'run list')
    case "\$a" in
      *in_progress*) printf 'https://github.com/someone/thing/actions/runs/99\n' ;;
      *)             printf '42 https://github.com/someone/thing/actions/runs/42\n' ;;
    esac ;;
  *)
    case "\$1:\$a" in
      api:*compare*) printf '7\n' ;;
      api:*tags*)    printf 'v0.2.0\n' ;;
    esac ;;
esac
EOS
  chmod +x "$T/bin/gh"
}

_prel_cleanup() { rm -rf "$T"; }
# `die` exits the process it is called in, so every refusal runs in a subshell
# - otherwise the first expected failure takes the test with it. The workspace
# is found by walking up from $PWD, so each call runs from inside it.
_prel() { ( cd "$WS" && cmd_release "$@" ) 2>&1; }
_prel_try() { _prel "$@" >/dev/null 2>&1; }

# --- resolution: which repo is "the product's release"? ----------------------

test_release_resolves_the_one_releasable_repo_in_a_product() {
  _prel_fixture
  local out; out="$(_prel gadget 0.3.0)" || { _prel_cleanup; return 1; }
  assert_contains "$(cat "$LOG")" "--repo someone/doodad" || { _prel_cleanup; return 1; }
  assert_contains "$(cat "$LOG")" "-f version=0.3.0" || { _prel_cleanup; return 1; }
  _prel_cleanup
}

test_release_refuses_a_product_with_two_releasable_repos() {
  _prel_fixture
  local out rc=0; out="$(_prel bundle 0.3.0)" || rc=$?
  assert_eq "$rc" "1" || { _prel_cleanup; return 1; }
  assert_contains "$out" "widget" || { _prel_cleanup; return 1; }
  assert_contains "$out" "gizmo" || { _prel_cleanup; return 1; }
  assert_contains "$out" "--repo" || { _prel_cleanup; return 1; }
  assert_eq "$(cat "$LOG")" "" || { _prel_cleanup; return 1; }
  # and naming one of them settles it
  _prel bundle 0.3.0 --repo widget >/dev/null || { _prel_cleanup; return 1; }
  assert_contains "$(cat "$LOG")" "--repo someone/widget" || { _prel_cleanup; return 1; }
  _prel_cleanup
}

test_release_refuses_a_product_that_declares_no_release_block() {
  _prel_fixture
  local out rc=0; out="$(_prel orphan 0.3.0)" || rc=$?
  assert_eq "$rc" "1" || { _prel_cleanup; return 1; }
  assert_contains "$out" "orphan declares no release: block" || { _prel_cleanup; return 1; }
  assert_eq "$(cat "$LOG")" "" || { _prel_cleanup; return 1; }
  _prel_cleanup
}

# A repo named in no declared product is its own product, in place.
test_release_accepts_an_implicit_product() {
  _prel_fixture
  _prel solo patch >/dev/null || { _prel_cleanup; return 1; }
  assert_contains "$(cat "$LOG")" "workflow run release.yaml --repo someone/solo -f bump=patch" \
    || { _prel_cleanup; return 1; }
  _prel_cleanup
}

# --- the value: the repo's own vocabulary, not the plane's -------------------

test_release_checks_the_value_against_accepts() {
  _prel_fixture
  # a bump repo takes a listed word and nothing else
  _prel solo minor >/dev/null || { _prel_cleanup; return 1; }
  assert_fails _prel_try solo 0.3.0 || { _prel_cleanup; return 1; }
  # a semver repo takes x.y.z, greater than what version_file says
  assert_fails _prel_try gadget patch || { _prel_cleanup; return 1; }
  assert_fails _prel_try gadget 1.0 || { _prel_cleanup; return 1; }
  assert_fails _prel_try gadget 0.2.0 || { _prel_cleanup; return 1; }
  assert_fails _prel_try gadget 0.1.0 || { _prel_cleanup; return 1; }
  assert_contains "$(cat "$LOG")" "-f bump=minor" || { _prel_cleanup; return 1; }
  assert_eq "$(grep -c 'version=' "$LOG" || true)" "0" || { _prel_cleanup; return 1; }
  _prel_cleanup
}

# --- permission: the refusal this whole ticket exists for --------------------

# Every local check passed and then GitHub returned 403. A caller who cannot
# dispatch is told so BEFORE anything is spent, and told where releases of
# that product actually come from.
test_release_refuses_a_caller_who_only_has_read() {
  _prel_fixture
  local out rc=0
  out="$(CEL_TEST_PERM=READ _prel gadget 0.3.0)" || rc=$?
  assert_eq "$rc" "1" || { _prel_cleanup; return 1; }
  assert_contains "$out" "you have READ on someone/doodad" || { _prel_cleanup; return 1; }
  assert_contains "$out" "cel update" || { _prel_cleanup; return 1; }
  # the call log is the proof: permission was read, nothing was dispatched
  assert_contains "$(cat "$LOG")" "repo view someone/doodad" || { _prel_cleanup; return 1; }
  assert_eq "$(grep -c 'workflow run' "$LOG" || true)" "0" || { _prel_cleanup; return 1; }
  _prel_cleanup
}

test_release_dispatches_for_write_maintain_and_admin() {
  _prel_fixture
  local p
  for p in WRITE MAINTAIN ADMIN; do
    : >"$LOG"
    CEL_TEST_PERM="$p" _prel gadget 0.3.0 >/dev/null || { _prel_cleanup; return 1; }
    assert_contains "$(cat "$LOG")" "workflow run release.yml --repo someone/doodad -f version=0.3.0" \
      || { _prel_cleanup; return 1; }
  done
  _prel_cleanup
}

# --- --dry-run ---------------------------------------------------------------

test_release_dry_run_prints_the_plan_and_dispatches_nothing() {
  _prel_fixture
  local out; out="$(_prel bundle 0.3.0 --repo widget --dry-run)" || { _prel_cleanup; return 1; }
  assert_contains "$out" "someone/widget" || { _prel_cleanup; return 1; }
  assert_contains "$out" "release.yml" || { _prel_cleanup; return 1; }
  assert_contains "$out" "version=0.3.0" || { _prel_cleanup; return 1; }
  assert_contains "$out" "hygiene" || { _prel_cleanup; return 1; }
  # a repo that declares a changelog shows what would ship, fragments and all
  assert_contains "$out" "widget mode learns to hum" || { _prel_cleanup; return 1; }
  assert_eq "$(cat "$LOG")" "" || { _prel_cleanup; return 1; }
  assert_eq "$(cat "$WS/repos/widget/VERSION")" "0.2.0" || { _prel_cleanup; return 1; }
  assert_eq "$(ls "$WS/repos/widget/changelog.d")" "WG-1-hum.md" || { _prel_cleanup; return 1; }
  _prel_cleanup
}

# --- status ------------------------------------------------------------------

test_release_status_renders_one_product_and_a_whole_workspace() {
  _prel_fixture
  local out; out="$(_prel status gadget)" || { _prel_cleanup; return 1; }
  assert_contains "$out" "doodad" || { _prel_cleanup; return 1; }
  assert_contains "$out" "0.2.0" || { _prel_cleanup; return 1; }
  assert_contains "$out" "7" || { _prel_cleanup; return 1; }
  case "$out" in *widget*) _prel_cleanup; printf 'a product listed another product\n' >&2; return 1;; esac

  out="$(_prel status)" || { _prel_cleanup; return 1; }
  assert_contains "$out" "widget" || { _prel_cleanup; return 1; }
  assert_contains "$out" "gizmo" || { _prel_cleanup; return 1; }
  assert_contains "$out" "solo" || { _prel_cleanup; return 1; }
  # a repo with no release block has no release state to show
  case "$out" in *orphan*) _prel_cleanup; printf 'listed a repo that is not releasable\n' >&2; return 1;; esac
  _prel_cleanup
}

test_release_status_json_carries_the_same_facts() {
  _prel_fixture
  local out; out="$(_prel status gadget --json)" || { _prel_cleanup; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].repo')" "doodad" || { _prel_cleanup; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].slug')" "someone/doodad" || { _prel_cleanup; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].current')" "0.2.0" || { _prel_cleanup; return 1; }
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].commits_since')" "7" || { _prel_cleanup; return 1; }
  assert_contains "$(printf '%s' "$out" | jq -r '.[0].in_flight')" "runs/99" || { _prel_cleanup; return 1; }
  assert_contains "$(printf '%s' "$out" | jq -r '.[0].newest')" "v0.2.0" || { _prel_cleanup; return 1; }
  _prel_cleanup
}

# --- compatibility: the plane's own `cel release 0.3.0` ----------------------

test_release_bare_version_works_where_one_repo_is_releasable() {
  _prel_single_fixture
  _prel 0.3.0 >/dev/null || { _prel_cleanup; return 1; }
  assert_contains "$(cat "$LOG")" "workflow run release.yml --repo someone/widget -f version=0.3.0" \
    || { _prel_cleanup; return 1; }
  _prel_cleanup
}

test_release_bare_version_refuses_where_several_repos_are_releasable() {
  _prel_fixture
  local out rc=0; out="$(_prel 0.3.0)" || rc=$?
  assert_eq "$rc" "1" || { _prel_cleanup; return 1; }
  assert_contains "$out" "cel release <product>" || { _prel_cleanup; return 1; }
  assert_eq "$(cat "$LOG")" "" || { _prel_cleanup; return 1; }
  _prel_cleanup
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

# Every tracked fragment must carry a category heading, or the cut refuses at
# release time - days after the fragment merged. Checked through notes.py's own
# assemble(), so there is one definition of "valid".
test_release_every_tracked_fragment_has_a_category_heading() {
  local out
  out="$(cd "$_REL_REPO" && git ls-files 'changelog.d/*.md' | python3 -c '
import sys
sys.path.insert(0, "tools/release")
from pathlib import Path
import tempfile, shutil
from notes import assemble
bad = []
for name in sys.stdin.read().split():
    d = tempfile.mkdtemp()
    shutil.copy(name, d)
    try:
        assemble("", d)
    except SystemExit:
        bad.append(name)
    finally:
        shutil.rmtree(d)
print("\n".join(bad))
')" || return 1
  [[ -z "$out" ]] || { printf 'fragments without a category heading:\n%s\n' "$out" >&2; return 1; }
}

test_release_fragment_with_an_unknown_heading_is_refused() {
  local T; T="$(mktemp -d)"
  _rel_changelog "$T/CHANGELOG.md"
  _rel_fragment "$T/changelog.d" "x.md" '### Misc' '- nope'
  if _notes unreleased --changelog "$T/CHANGELOG.md" --fragments "$T/changelog.d" 2>/dev/null; then
    rm -rf "$T"; return 1
  fi
  rm -rf "$T"
}
