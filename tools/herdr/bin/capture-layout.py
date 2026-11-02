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
import argparse, json, subprocess, sys

# herdr's own split words, and the rect axis/extent each one stacks panes along.
AXES = {"right": ("x", "width"), "down": ("y", "height")}


def layout_for(pane_id):
    out = subprocess.run(["herdr", "pane", "layout", "--pane", pane_id],
                         capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        sys.exit(f"capture-layout: herdr returned nothing for {pane_id}\n{out.stderr.strip()}")
    try:
        return json.loads(out.stdout)["result"]["layout"]
    except (ValueError, KeyError, TypeError) as err:
        sys.exit(f"capture-layout: herdr pane layout for {pane_id} is not a layout ({err!r})")


def labels():
    """Pane labels are cosmetic: an unreadable pane list means none, not a failure."""
    out = subprocess.run(["herdr", "pane", "list"], capture_output=True, text=True)
    try:
        return {p["pane_id"]: p for p in json.loads(out.stdout)["result"]["panes"]} \
            if out.returncode == 0 else {}
    except (ValueError, KeyError, TypeError):
        return {}


def nonneg(text):
    value = int(text)
    if value < 0:
        raise ValueError(text)
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(prog="capture-layout.py", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pane_id")
    parser.add_argument("--title", default=None)
    # Emitted as a `tabs:` list member. The default suits a bare tabs block; pass
    # --indent 4 to nest it under `layouts: - id: ... tabs:` in a plugin config.
    parser.add_argument("--indent", type=nonneg, default=0)
    args = parser.parse_args(argv)
    pad = " " * args.indent

    lay = layout_for(args.pane_id)
    try:
        tab, panes, splits = lay["tab_id"], lay["panes"], lay.get("splits", [])
        if not splits:
            sys.exit(f"capture-layout: tab {tab} has a single pane; nothing to capture")
        dirs = {s["direction"] for s in splits}
        if len(dirs) > 1:
            sys.exit(f"capture-layout: tab {tab} mixes {sorted(dirs)}. A chain of "
                     "panes cannot express a two-axis tree; split it into two tabs, or "
                     "write this layout by hand.")
        direction = dirs.pop()
        if direction not in AXES:
            sys.exit(f"capture-layout: tab {tab} splits {direction!r}; only "
                     f"{sorted(AXES)} are understood")
        axis, extent = AXES[direction]
        ordered = sorted(panes, key=lambda p: p["rect"][axis])
        ext = [p["rect"][extent] for p in ordered]
        ids = [p["pane_id"] for p in ordered]
        # pane i's share of the area remaining when it splits off pane i-1
        sizes = [sum(ext[i:]) / sum(ext[i - 1:]) for i in range(1, len(ext))]
    except (KeyError, TypeError, AttributeError, ZeroDivisionError) as err:
        sys.exit(f"capture-layout: herdr pane layout for {args.pane_id} has an "
                 f"unexpected shape ({err!r})")
    meta = labels()

    lines = [f"  - title: {args.title or tab}", "    panes:"]
    for i, pane in enumerate(ids):
        lines.append(f"      - title: {meta.get(pane, {}).get('label') or pane.split(':')[-1]}")
        if i:
            lines.append(f"        split: {direction}")
            lines.append(f"        size: {sizes[i - 1]:.4f}")
    print("\n".join(pad + l for l in lines))


if __name__ == "__main__":
    main()
