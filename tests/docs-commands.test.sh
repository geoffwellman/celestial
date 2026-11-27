# shellcheck shell=bash
# EVERY `cel <command>` THE DOCS SHOW IS ONE CEL HAS. The README and docs/
# drifted from bin/cel for months - retired commands shown as current, verbs
# that never existed - and nothing failed. tests/lib/docs_commands.py reads the
# dispatch table in bin/cel (and, for commands that take a verb, the case
# labels of the function they dispatch to; for forge's `pr`/`run`, the
# sub-verbs of its two-word labels) and checks every `cel` in every fenced
# block, indented code block and inline code span of README.md,
# CONTRIBUTING.md, SECURITY.md and docs/**/*.md against it. A retired command
# may be named only on a line that says "retired"; nothing else on that line
# is exempt. Its header says what it cannot read.

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

# A line that says "retired" exempts the retired command it names, nothing
# else: a command that never existed on the same line is still reported.
test_docs_check_retired_exemption_is_per_command() {
  local T; T="$(mktemp -d)"
  cat >"$T/doc.md" <<'MD'
Retired: `cel work`, and `cel nosuch` never existed.

```sh
cel run scout --repo x   # retired
cel ghost --x            # retired, they say
```
MD
  local out rc=0
  out="$(_docs_check "$T/doc.md" 2>/dev/null)" || rc=$?
  assert_eq "$rc" 1 || { rm -rf "$T"; return 1; }
  assert_contains "$out" "doc.md:1: cel nosuch: no such command" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "doc.md:5: cel ghost: no such command" || { rm -rf "$T"; return 1; }
  case "$out" in *"cel work"*|*"run scout"*) echo "flagged a retired command on its retired line: $out" >&2; rm -rf "$T"; return 1 ;; esac
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 2 || { printf '%s\n' "$out" >&2; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# Every `cel` on a line is checked, after && || ; | and in one code span.
test_docs_check_reads_every_cel_on_a_line() {
  local T; T="$(mktemp -d)"
  cat >"$T/doc.md" <<'MD'
```sh
cel doctor && cel nosuch1
cel doctor || cel nosuch2; cel nosuch3
cel fleet --json | cel nosuch4
```
Inline `cel doctor && cel inbox nosuchverb`.
MD
  local out rc=0
  out="$(_docs_check "$T/doc.md" 2>/dev/null)" || rc=$?
  assert_eq "$rc" 1 || { rm -rf "$T"; return 1; }
  local w
  for w in "doc.md:2: cel nosuch1" "doc.md:3: cel nosuch2" "doc.md:3: cel nosuch3" "doc.md:4: cel nosuch4" "doc.md:6: cel inbox nosuchverb"; do
    assert_contains "$out" "$w" || { rm -rf "$T"; return 1; }
  done
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 5 || { printf '%s\n' "$out" >&2; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# A 4-space (or tab) indented code block is code; an indented continuation
# of a list item is not.
test_docs_check_reads_indented_code_blocks() {
  local T; T="$(mktemp -d)"
  printf '%s\n' 'Run this:' '' '    cel doctor' '    cel nosuch' '' \
    '- a list item' '' '    cel listprose continues the item' '' \
    'After it:' '' "$(printf '\tcel tabbed')" > "$T/doc.md"
  local out rc=0
  out="$(_docs_check "$T/doc.md" 2>/dev/null)" || rc=$?
  assert_eq "$rc" 1 || { rm -rf "$T"; return 1; }
  assert_contains "$out" "doc.md:4: cel nosuch: no such command" || { rm -rf "$T"; return 1; }
  assert_contains "$out" "doc.md:12: cel tabbed: no such command" || { rm -rf "$T"; return 1; }
  case "$out" in *listprose*) echo "read a list continuation as code: $out" >&2; rm -rf "$T"; return 1 ;; esac
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 2 || { printf '%s\n' "$out" >&2; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# forge's sub-verbs come from its two-word case labels ("pr view"), so a
# sub-verb that does not exist is caught, in a plain call and in a · list.
test_docs_check_reads_forge_sub_verbs() {
  local T; T="$(mktemp -d)"
  cat >"$T/doc.md" <<'MD'
```sh
cel forge pr view widget#3
cel forge pr nosuch widget#3
cel forge run logs widget 12
cel forge run nosuch widget
```
Table: `cel forge pr view · checks · bogus <repo>[#<n>]` and `cel forge run list <repo> · view <repo> <id> · bogus2 <repo>`.
MD
  local out rc=0
  out="$(_docs_check "$T/doc.md" 2>/dev/null)" || rc=$?
  assert_eq "$rc" 1 || { rm -rf "$T"; return 1; }
  local w
  for w in "doc.md:3: cel forge pr nosuch: no such verb in cel forge pr" "doc.md:5: cel forge run nosuch" \
           "doc.md:7: cel forge pr bogus" "doc.md:7: cel forge run bogus2"; do
    assert_contains "$out" "$w" || { rm -rf "$T"; return 1; }
  done
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 4 || { printf '%s\n' "$out" >&2; rm -rf "$T"; return 1; }
  rm -rf "$T"
}

# `cel help` NAMES EVERY COMMAND bin/cel DISPATCHES. Each alternative of each
# label in the top-level case (flags, help itself and the retired `work` and
# `history` aside) must appear in the usage text as `cel <command>`.
test_cel_help_names_every_dispatched_command() {
  local help labels c missing=""
  help="$(bash "$CEL_ROOT/bin/cel" help)"
  labels="$(awk '/^case "\$\{1:-help\}" in/ { on = 1; next } on && /^esac/ { exit }
    on && match($0, /^  [a-z][a-z|-]*\)/) { print substr($0, 3, RLENGTH - 3) }' "$CEL_ROOT/bin/cel" | tr '|' '\n')"
  [ "$(printf '%s\n' "$labels" | grep -c .)" -ge 30 ] || { echo "read too few dispatch labels: $labels"; return 1; }
  for c in $labels; do
    case "$c" in help|work|history|-*) continue ;; esac
    grep -Eq "(^|[^a-z-])cel $c([^a-z-]|\$)" <<<"$help" || missing="$missing $c"
  done
  [ -z "$missing" ] || { echo "cel help does not name:$missing"; return 1; }
}

# ...and every verb of every command that takes one (VERB_COMMANDS), read
# from its own case labels by tests/lib/docs_commands.py. An internal verb is
# listed and marked internal, not hidden; only `<cmd> help` itself is exempt.
test_cel_help_names_every_verb_of_every_command() {
  local out
  out="$(python3 - "$CEL_ROOT" <<'PY'
import re, subprocess, sys
root = sys.argv[1]
sys.path.insert(0, root + "/tests/lib")
import docs_commands
_, verbs, _ = docs_commands.commands(root)
text = subprocess.run(["bash", root + "/bin/cel", "help"], capture_output=True, text=True).stdout
if len(verbs) < 15:
    print(f"read verbs for only {len(verbs)} commands")
for cmd in sorted(verbs):
    if not verbs[cmd]:
        print(f"cel {cmd}: no verbs read")
    for verb, live in sorted(verbs.get(cmd, {}).items()):
        if live and verb != "help" \
                and not re.search(r"(?<![a-z-])" + re.escape(verb) + r"(?![a-z-])", text):
            print(f"cel {cmd} {verb}")
PY
)"
  [ -z "$out" ] || { printf 'cel help does not name:\n%s\n' "$out"; return 1; }
}
