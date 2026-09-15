#!/usr/bin/env python3
"""Capture a live herdr tab's pane arrangement as a workspace-manager layout.

    tools/herdr/bin/capture-layout.py <pane-id> [--title NAME] [--indent N]

Reads `herdr pane layout --pane <id>`, which reports each pane's final rect and
each split's direction in herdr's own `right`/`down` vocabulary - the same words
the plugin's `split:` field takes, so nothing here has to guess how a direction
name maps onto the screen.

Why rects rather than the split ratios: the plugin builds a tab as a CHAIN - each
pane splits from the one before it - while herdr stores a TREE, which can lean
either way. Reading the ratios straight across reproduces the wrong shape for any
tree that is not right-leaning. The final geometry is unambiguous, so we take the
pane extents and re-derive the chain fractions that land on them:

    size[i] = sum(extent[i:]) / sum(extent[i-1:])

which is pane i's share of whatever area is left when it splits off pane i-1.
"""
import json, subprocess, sys


def layout_for(pane_id):
    out = subprocess.run(["herdr", "pane", "layout", "--pane", pane_id],
                         capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        sys.exit(f"capture-layout: herdr returned nothing for {pane_id}\n{out.stderr.strip()}")
    return json.loads(out.stdout)["result"]["layout"]


def labels():
    out = subprocess.run(["herdr", "pane", "list"], capture_output=True, text=True)
    if out.returncode != 0:
        return {}
    return {p["pane_id"]: p for p in json.loads(out.stdout)["result"]["panes"]}


def main(argv):
    if not argv:
        sys.exit(__doc__)
    pane_id = argv[0]
    title = argv[argv.index("--title") + 1] if "--title" in argv else None
    # Emitted as a `tabs:` list member. The default suits a bare tabs block; pass
    # --indent 4 to nest it under `layouts: - id: ... tabs:` in a plugin config.
    pad = " " * int(argv[argv.index("--indent") + 1]) if "--indent" in argv else ""

    lay = layout_for(pane_id)
    panes, splits = lay["panes"], lay.get("splits", [])
    if not splits:
        sys.exit(f"capture-layout: tab {lay['tab_id']} has a single pane; nothing to capture")

    dirs = {s["direction"] for s in splits}
    if len(dirs) > 1:
        sys.exit(f"capture-layout: tab {lay['tab_id']} mixes {sorted(dirs)}. A chain of "
                 "panes cannot express a two-axis tree; split it into two tabs, or "
                 "write this layout by hand.")
    direction = dirs.pop()
    axis, extent = ("x", "width") if direction == "right" else ("y", "height")

    ordered = sorted(panes, key=lambda p: p["rect"][axis])
    ext = [p["rect"][extent] for p in ordered]
    meta = labels()

    lines = [f"  - title: {title or lay['tab_id']}", "    panes:"]
    for i, p in enumerate(ordered):
        info = meta.get(p["pane_id"], {})
        lines.append(f"      - title: {info.get('label') or p['pane_id'].split(':')[-1]}")
        if i:
            # pane i's share of the area remaining when it splits off pane i-1
            size = sum(ext[i:]) / sum(ext[i - 1:])
            lines.append(f"        split: {direction}")
            lines.append(f"        size: {size:.4f}")
    print("\n".join(pad + l for l in lines))


if __name__ == "__main__":
    main(sys.argv[1:])
