# shellcheck shell=bash
# capture-layout.py turns a live herdr tab into layout config. Bad input - a
# missing option value, a malformed herdr answer, a direction it does not know -
# is a one-line refusal, never a traceback and never a guessed layout.
CAPTURE="$CEL_ROOT/tools/herdr/bin/capture-layout.py"

_capture_fixture() { # <layout-json>
  T="$(mktemp -d)"; mkdir -p "$T/bin"
  printf '%s' "$1" > "$T/layout.json"
  printf '%s' '{"result":{"panes":[{"pane_id":"t1:p1","label":"editor"}]}}' > "$T/list.json"
  cat > "$T/bin/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane layout") cat "$T/layout.json";;
  "pane list")   cat "$T/list.json";;
  *) exit 1;;
esac
EOF
  chmod +x "$T/bin/herdr"
}
_capture() { ( PATH="$T/bin:$PATH" python3 "$CAPTURE" "$@" ); }
_capture_rows() { # <direction> -> a three-pane chain along that direction
  printf '{"result":{"layout":{"tab_id":"t1","panes":[
    {"pane_id":"t1:p3","rect":{"x":80,"y":0,"width":20,"height":40}},
    {"pane_id":"t1:p1","rect":{"x":0,"y":0,"width":50,"height":40}},
    {"pane_id":"t1:p2","rect":{"x":50,"y":0,"width":30,"height":40}}],
    "splits":[{"direction":"%s"},{"direction":"%s"}]}}}' "$1" "$1"
}
_capture_refused() { # <expected-rc> <needle> <args...>
  local want="$1" needle="$2" out rc=0; shift 2
  out="$(_capture "$@" 2>&1)" || rc=$?
  assert_eq "$rc" "$want" || { printf '%s\n' "$out"; return 1; }
  assert_contains "$out" "$needle" || return 1
  case "$out" in *Traceback*) printf 'traceback:\n%s\n' "$out"; return 1;; esac
}

test_capture_layout_derives_chain_fractions_from_the_rects() {
  _capture_fixture "$(_capture_rows right)"
  local out; out="$(_capture t1:p1 --title Work --indent 2)"
  assert_eq "$out" "$(printf '%s\n' \
    '    - title: Work' \
    '      panes:' \
    '        - title: editor' \
    '        - title: p2' \
    '          split: right' \
    '          size: 0.5000' \
    '        - title: p3' \
    '          split: right' \
    '          size: 0.4000')"
  rm -rf "$T"
}

test_capture_layout_refuses_options_without_a_usable_value() {
  _capture_fixture "$(_capture_rows right)"
  _capture_refused 2 "--title" t1:p1 --title || return 1
  _capture_refused 2 "--indent" t1:p1 --indent || return 1
  _capture_refused 2 "--indent" t1:p1 --indent wide || return 1
  _capture_refused 2 "--indent" t1:p1 --indent -1 || return 1
  rm -rf "$T"
}

test_capture_layout_refuses_a_malformed_herdr_answer() {
  _capture_fixture 'not json at all'
  _capture_refused 1 "capture-layout:" t1:p1 || return 1
  printf '%s' '{"result":{}}' > "$T/layout.json"
  _capture_refused 1 "capture-layout:" t1:p1 || return 1
  printf '%s' '{"result":{"layout":{"tab_id":"t1","panes":[{"pane_id":"t1:p1"}],"splits":[{"direction":"right"}]}}}' > "$T/layout.json"
  _capture_refused 1 "capture-layout:" t1:p1 || return 1
  rm -rf "$T"
}

test_capture_layout_refuses_a_direction_it_does_not_know() {
  _capture_fixture "$(_capture_rows left)"
  _capture_refused 1 "left" t1:p1 || return 1
  rm -rf "$T"
}
