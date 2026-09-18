# shellcheck shell=bash
HYGIENE="$CEL_ROOT/tools/release/hygiene.py"

_hygiene_fixture() {
  T="$(mktemp -d)"
  mkdir "$T/repo"
  git -C "$T/repo" init -q
  git -C "$T/repo" config user.name 'Example Author'
  git -C "$T/repo" config user.email 'author@example.invalid'
}

_hygiene_scan() { python3 "$HYGIENE" --root "$T/repo" "$@"; }

# This checks real publication inputs, including fixtures. Private vocabulary
# is supplied externally at release time, never declared in the public source.
test_public_tree_passes_generic_hygiene() {
  python3 "$HYGIENE" --root "$CEL_ROOT"
}

test_hygiene_checks_test_content_and_filenames() {
  _hygiene_fixture
  printf '%s\n' 'private-client-example' > "$T/private-patterns"
  mkdir "$T/repo/tests"
  printf '%s\n' 'private-client-example' > "$T/repo/tests/example.txt"
  git -C "$T/repo" add tests
  assert_fails _hygiene_scan --private-patterns "$T/private-patterns"
  printf 'neutral\n' > "$T/repo/tests/example.txt"
  mv "$T/repo/tests/example.txt" "$T/repo/tests/private-client-example.txt"
  git -C "$T/repo" add -A
  assert_fails _hygiene_scan --private-patterns "$T/private-patterns"
  rm -rf "$T"
}

test_hygiene_requires_external_nonempty_release_vocabulary() {
  _hygiene_fixture
  assert_fails _hygiene_scan --require-private-patterns
  touch "$T/empty"
  assert_fails _hygiene_scan --private-patterns "$T/empty" --require-private-patterns
  printf 'private-client-example\n' > "$T/repo/patterns"
  assert_fails _hygiene_scan --private-patterns "$T/repo/patterns"
  printf '[\n' > "$T/broken"
  assert_fails _hygiene_scan --private-patterns "$T/broken"
  rm -rf "$T"
}

test_hygiene_rejects_letter_and_mixed_ticket_keys() {
  _hygiene_fixture
  printf 'CLIENT-%s\n' 12 > "$T/repo/example.txt"
  git -C "$T/repo" add example.txt
  assert_fails _hygiene_scan
  printf 'TEAM9X-%s\n' 23 > "$T/repo/example.txt"
  assert_fails _hygiene_scan
  printf 'WG-12 and ABC-3 are fictional; UTF-8 is a standard.\n' > "$T/repo/example.txt"
  _hygiene_scan
  rm -rf "$T"
}

test_hygiene_rejects_credentials_without_echoing_values() {
  _hygiene_fixture
  local value out
  value="ghp_$(printf 'x%.0s' {1..36})"
  printf '%s\n' "$value" > "$T/repo/example.txt"
  git -C "$T/repo" add example.txt
  if out="$(_hygiene_scan 2>&1)"; then echo 'credential was accepted'; return 1; fi
  assert_contains "$out" 'GitHub credential'
  case "$out" in *"$value"*) echo 'credential leaked in diagnostic'; return 1;; esac
  rm -rf "$T"
}

test_hygiene_history_catches_deleted_content_tags_and_metadata() {
  _hygiene_fixture
  printf 'private-client-example\n' > "$T/private-patterns"
  printf 'private-client-example\n' > "$T/repo/old.txt"
  git -C "$T/repo" add old.txt
  git -C "$T/repo" commit -qm 'initial example'
  git -C "$T/repo" tag -a sample -m 'private-client-example'
  git -C "$T/repo" rm -q old.txt
  git -C "$T/repo" commit -qm 'remove old example'
  _hygiene_scan --private-patterns "$T/private-patterns"
  assert_fails _hygiene_scan --all-history --private-patterns "$T/private-patterns"
  # A separate clean tree still fails when only its commit metadata leaks.
  git -C "$T/repo" checkout -q --orphan clean
  git -C "$T/repo" -c user.email=private-client-example@example.invalid commit -q --allow-empty -m 'clean tree'
  git -C "$T/repo" tag -d sample >/dev/null
  git -C "$T/repo" branch -D "$(git -C "$T/repo" for-each-ref --format='%(refname:short)' refs/heads | sed '/^clean$/d')" >/dev/null
  assert_fails _hygiene_scan --all-history --private-patterns "$T/private-patterns"
  rm -rf "$T"
}

# A pull request is judged on ITS OWN commits: a dirty commit on another
# branch fails the every-ref scan and leaves the range scan alone.
test_hygiene_history_range_scopes_to_the_named_commits() {
  _hygiene_fixture
  printf 'private-client-example\n' > "$T/private-patterns"
  printf 'clean\n' > "$T/repo/a.txt"
  git -C "$T/repo" add a.txt && git -C "$T/repo" commit -qm 'base'
  git -C "$T/repo" branch -q dirty
  git -C "$T/repo" checkout -q dirty
  printf 'private-client-example\n' > "$T/repo/leak.txt"
  git -C "$T/repo" add leak.txt && git -C "$T/repo" commit -qm 'leak on a side branch'
  git -C "$T/repo" checkout -q -
  printf 'more\n' >> "$T/repo/a.txt"
  git -C "$T/repo" commit -qam 'clean work on the main line'
  _hygiene_scan --history "$(git -C "$T/repo" rev-parse HEAD~1)..HEAD" --private-patterns "$T/private-patterns"
  assert_fails _hygiene_scan --history dirty --private-patterns "$T/private-patterns"
  assert_fails _hygiene_scan --all-history --private-patterns "$T/private-patterns"
  rm -rf "$T"
}

test_hygiene_rejects_sensitive_paths_and_external_symlinks() {
  _hygiene_fixture
  touch "$T/repo/.env.production"
  git -C "$T/repo" add -f .env.production
  assert_fails _hygiene_scan
  git -C "$T/repo" rm -q --cached .env.production
  rm "$T/repo/.env.production"
  printf 'private fixture\n' > "$T/outside"
  ln -s "$T/outside" "$T/repo/link"
  git -C "$T/repo" add link
  assert_fails _hygiene_scan
  rm -rf "$T"
}

# The README tells a reader to clone into ~/celestial. That instruction is only
# honest if nothing in the tree falls back to the old folder name when CEL_ROOT
# is unset: a reader who followed the README once got a dashboard that resolved
# CEL_ROOT to a directory that did not exist, and an inbox hook that silently
# drained nothing. CHANGELOG.md is exempt because it is history, not behaviour.
test_no_file_assumes_the_old_clone_folder_name() {
  # The needle is assembled rather than written, so this file is not itself a hit.
  local needle hits
  needle="celestial-$(printf 'plane')"
  hits="$(cd "$CEL_ROOT" && git grep -l -- "$needle" -- . ':!CHANGELOG.md' || true)"
  assert_eq "" "$hits"
}

# A change worth a CHANGELOG line goes in changelog.d/<branch>.md now, so
# [Unreleased] on main is empty and stays empty: a PR that edits it by hand is
# caught here, by CI, instead of by the next PR's conflict on the same line.
test_changelog_unreleased_is_empty_because_entries_are_fragments() {
  local body
  body="$(python3 "$CEL_ROOT/tools/release/notes.py" unreleased \
            --changelog "$CEL_ROOT/CHANGELOG.md" --fragments /dev/null)" || return 1
  assert_eq "" "$body"
}
