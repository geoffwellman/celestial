# shellcheck shell=bash
# pr-nudge.sh reports success only when the configured reviewer - that login,
# exactly - is back on the PR's review requests.
NUDGE="$CEL_ROOT/core/skills/pr-loop/bin/pr-nudge.sh"

_nudge_fixture() { # <reviewRequests-json>
  T="$(mktemp -d)"; mkdir -p "$T/bin"
  printf '%s' "$1" > "$T/requests.json"
  cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$1 \$2" in
  "pr edit") exit 0;;
  "pr view") # gh applies --jq itself; the fixture answers the raw --json form
             case " \$* " in *" --jq "*) jq -c "\$(printf '%s\n' "\$@" | sed -n '/^--jq\$/{n;p;q}')" "$T/requests.json";;
                                  *) cat "$T/requests.json";; esac;;
esac
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
  chmod +x "$T/bin/gh" "$T/bin/sleep"
  : > "$T/gh.log"
}
_nudge() { ( PATH="$T/bin:$PATH" REVIEWER="$REV" "$NUDGE" "$@" ); }

test_pr_nudge_does_not_take_a_login_containing_the_reviewer_for_the_reviewer() {
  _nudge_fixture '{"reviewRequests":[{"login":"other-bot"}]}'
  local out rc=0; out="$(REV=bot _nudge o/r 7 2>&1)" || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "FAILED: bot is NOT on o/r#7"
  rm -rf "$T"
}

test_pr_nudge_does_not_read_the_reviewer_as_a_pattern() {
  _nudge_fixture '{"reviewRequests":[{"login":"botx"}]}'
  local rc=0; REV='b.t' _nudge o/r 7 >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 1
  rm -rf "$T"
}

test_pr_nudge_succeeds_when_the_exact_reviewer_is_requested() {
  _nudge_fixture '{"reviewRequests":[{"login":"other-bot"},{"login":"bot"}]}'
  local out; out="$(REV=bot _nudge o/r 7 2>&1)"
  assert_contains "$out" "nudged: bot re-requested on o/r#7"
  assert_contains "$(cat "$T/gh.log")" "pr edit 7 --repo o/r --remove-reviewer bot"
  assert_contains "$(cat "$T/gh.log")" "pr edit 7 --repo o/r --add-reviewer bot"
  rm -rf "$T"
}

test_pr_nudge_without_its_arguments_prints_usage_and_touches_nothing() {
  _nudge_fixture '{"reviewRequests":[]}'
  local out rc=0; out="$(REV=bot _nudge o/r 2>&1)" || rc=$?
  assert_eq "$rc" 2
  assert_contains "$out" "usage: pr-nudge.sh <repo> <number>"
  assert_eq "$(cat "$T/gh.log")" ""
  rm -rf "$T"
}
