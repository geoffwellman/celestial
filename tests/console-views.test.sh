# shellcheck shell=bash
# CEL-49: BARS. Every surface already had `used_pct` and none of them drew one,
# so an operator read six numbers where a glance at six bars would have done.
#
# All of this is pure over tools/console/views.mjs - the same module the ink
# UI and `cel console --render-quota` both draw from - so a bar that is wrong
# here is wrong on the screen.
_views_node() { # <script>
  local t; t="$(mktemp -d)"
  printf '%s' "$1" > "$t/t.mjs"
  VIEWS_MJS="$CEL_ROOT/tools/console/views.mjs" node "$t/t.mjs" 2>&1
  local rc=$?
  rm -rf "$t"
  return $rc
}

# A bar is a TRACK of a fixed width with a filled prefix: it may never render
# wider than its track (that is a wrapped line, which is worse than no bar),
# and 100% must be distinguishable from 99% - the difference between "the next
# delegation refuses" and "there is room for one more".
test_a_bar_never_exceeds_its_track_at_any_percentage() {
  local out
  out="$(_views_node '
import assert from "node:assert/strict";
const { usageBar } = await import(process.env.VIEWS_MJS);
for (const w of [6, 10, 14, 30]) {
  for (const p of [0, 50, 99, 100, 150, -5, null, undefined, NaN]) {
    const b = usageBar(p, w);
    assert.equal([...b].length, w, `width ${w} pct ${p} drew ${[...b].length} cells`);
  }
}
const w = 10;
assert.equal([...usageBar(0, w)].join("").includes("\u2588"), false, "0% drew a filled cell");
assert.equal([...usageBar(50, w)].filter((c) => c === "\u2588").length, 5, "50% is half a track");
assert.notEqual(usageBar(99, w), usageBar(100, w), "99% and 100% look the same");
assert.notEqual(usageBar(100, w), usageBar(50, w));
assert.equal(usageBar(150, w), usageBar(100, w), "past 100% is still one full track");
assert.ok([...usageBar(99, w)].some((c) => c !== "\u2588"), "99% filled the whole track");
process.stdout.write("bars: all good\n");
')" || { printf '%s\n' "$out"; return 1; }
  assert_contains "$out" 'bars: all good'
}

# A BAR THAT WRAPS IS WORSE THAN NO BAR. Below the minimum track there is
# nothing to draw that is honest, so the caller gets an empty string and prints
# the text it printed before.
test_a_track_too_narrow_to_be_honest_draws_nothing() {
  local out
  out="$(_views_node '
import assert from "node:assert/strict";
const { usageBar } = await import(process.env.VIEWS_MJS);
for (const w of [0, 1, 3, 5, -2, null, undefined]) assert.equal(usageBar(50, w), "");
process.stdout.write("narrow: all good\n");
')" || { printf '%s\n' "$out"; return 1; }
  assert_contains "$out" 'narrow: all good'
}

# The QUOTA page draws the bar from the `used_pct` the fleet document already
# carries - never a number computed in the renderer, which is the bug CEL-35
# exists to prevent - and falls back to today's text on a narrow terminal.
_views_doc() {
  cat <<'JSON'
{"subscriptions":[
 {"provider":"claude","account":"ant-one","label":"one@example.invalid","source":"direct",
  "windows":[{"name":"5h","used_pct":16,"resets_at":"2026-09-18T09:00:00Z"},
             {"name":"7d","used_pct":41,"resets_at":"2026-09-19T19:00:00Z"},
             {"name":"7d","scope":"Fable","used_pct":75,"resets_at":"2026-09-19T19:00:00Z"}],
  "extra":{"state":"enabled","reason":""}},
 {"provider":"opencode","account":"oc-one","label":"one@example.invalid","source":"direct",
  "windows":[{"name":"7d","used_pct":100,"resets_at":null}],
  "extra":{"state":"enabled","reason":""}}]}
JSON
}

test_the_quota_page_draws_a_bar_per_window_and_keeps_the_scope_label() {
  local doc; doc="$(_views_doc)"
  local out
  out="$(DOC="$doc" _views_node '
import assert from "node:assert/strict";
const { quotaView } = await import(process.env.VIEWS_MJS);
const doc = JSON.parse(process.env.DOC);
const wide = quotaView(doc, 120).join("\n");
assert.ok(wide.includes("\u2588"), "no bar on a wide terminal");
assert.ok(wide.includes("Fable"), "the scoped window lost its scope label");
assert.ok(wide.includes("16%") && wide.includes("75%"));
for (const line of wide.split("\n")) assert.ok(line.length <= 120, `a line ran past the terminal: ${line}`);
const narrow = quotaView(doc, 40).join("\n");
assert.equal(narrow.includes("\u2588"), false, "a narrow terminal drew a bar anyway");
assert.ok(narrow.includes("16%"), "the narrow fallback lost the text");
process.stdout.write("quota page: all good\n");
')" || { printf '%s\n' "$out"; return 1; }
  assert_contains "$out" 'quota page: all good'
}

# The cells carry the percentage they were drawn from, so the dashboard colours
# and sizes the same bar the console draws instead of matching rows to windows
# by index - which it did, and which put the wrong colour on the extra-usage
# row the moment one existed.
test_sub_cells_carry_the_percentage_the_bar_is_drawn_from() {
  local doc; doc="$(_views_doc)"
  local out
  out="$(DOC="$doc" _views_node '
import assert from "node:assert/strict";
const { subCells } = await import(process.env.VIEWS_MJS);
const doc = JSON.parse(process.env.DOC);
const cells = subCells(doc.subscriptions[0]);
assert.deepEqual(cells.map((c) => c[4]), [16, 41, 75]);
const unreadable = subCells({ provider: "codex", account: "cx", windows: [], extra: { state: "unreadable", reason: "down" } });
assert.equal(unreadable[0][4], null, "an unreadable row has no percentage to draw");
process.stdout.write("cells: all good\n");
')" || { printf '%s\n' "$out"; return 1; }
  assert_contains "$out" 'cells: all good'
}

# The status edge is the other surface that already had the number: the bar
# goes AFTER the figures, because the figures are what an operator reads first
# and the edge is one row shared with the memory headroom.
test_the_status_edge_draws_a_bar_beside_its_figures() {
  local doc; doc="$(_views_doc)"
  local out
  out="$(DOC="$doc" _views_node '
import assert from "node:assert/strict";
const { subsEdge } = await import(process.env.VIEWS_MJS);
const doc = JSON.parse(process.env.DOC);
const edge = subsEdge(doc, 120);
assert.ok(edge.includes("claude 16%/75%"), `the figures changed: ${edge}`);
assert.ok(edge.includes("\u2588"), "no bar on the status edge");
assert.equal(subsEdge(doc, 30).includes("\u2588"), false, "a narrow edge drew a bar anyway");
assert.ok(subsEdge(doc, 30).includes("claude 16%/75%"));
process.stdout.write("edge: all good\n");
')" || { printf '%s\n' "$out"; return 1; }
  assert_contains "$out" 'edge: all good'
}
