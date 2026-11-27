# shellcheck shell=bash
# EVERY `cel <command>` THE DOCS SHOW IS ONE CEL HAS. The README and docs/
# drifted from bin/cel for months - retired commands shown as current, verbs
# that never existed - and nothing failed. tests/lib/docs_commands.py reads the
# dispatch table in bin/cel (and, for commands that take a verb, the case
# labels of the function they dispatch to) and checks every fenced code block
# and inline code span of README.md, CONTRIBUTING.md, SECURITY.md and
# docs/**/*.md against it. A line that says "retired" may still name a retired
# command; nothing else may.

_docs_check() { python3 "$CEL_ROOT/tests/lib/docs_commands.py" "$CEL_ROOT" "$@"; }

test_docs_show_only_commands_cel_has() {
  local out rc=0
  out="$(_docs_check 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; return 1; }
  # Not vacuous: the docs show hundreds of cel commands, and the checker saw them.
  local n; n="$(printf '%s\n' "$out" | sed -n 's/^checked //p')"
  [ "${n:-0}" -ge 200 ] || { echo "checked only ${n:-0} commands - the extractor found too few" >&2; return 1; }
}

test_docs_check_refuses_unknown_and_retired_commands() {
  local T; T="$(mktemp -d)"
  cat >"$T/doc.md" <<'MD'
```sh
cel nosuch thing
cel inbox nosuchverb
cel run worker --repo x
cel ws new · add · bogus
cel afk|bogus
cel sessions retire-reviewer widget#12
```
Inline `cel team nope` and `cel solo land widget#3`, and `cel work` in prose.

Retired on that date: `cel work`, `cel run scout`.
MD
  local out rc=0
  out="$(_docs_check "$T/doc.md" 2>/dev/null)" || rc=$?
  assert_eq "$rc" 1 || { rm -rf "$T"; return 1; }
  assert_contains "$out" "doc.md:2: cel nosuch: no such command" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "doc.md:3: cel inbox nosuchverb: no such verb" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "doc.md:4: cel run worker: retired" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "doc.md:5: cel ws bogus: no such verb" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "doc.md:6: cel bogus: no such command" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "doc.md:9: cel team nope: no such verb" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "doc.md:9: cel work: retired" || { rm -rf "$T"; return 1; }
  # real commands and verbs pass, and the line that says retired is skipped
  case "$out" in *retire-reviewer*|*"solo land"*|*":11:"*) echo "flagged a real command or a retired note: $out" >&2; rm -rf "$T"; return 1 ;; esac
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 7 || { printf '%s\n' "$out" >&2; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
