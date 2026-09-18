#!/usr/bin/env python3
"""Print exactly one CHANGELOG section.

The release action needs the notes twice - as the pull request body and as the
tag/Release message - and `cel release --dry-run` needs the same text before a
run is spent. Three hand-rolled awk extractions would drift apart, so there is
one of them, here, and the heading is left off because every consumer supplies
its own title.
"""
import argparse
import sys
from pathlib import Path

UNRELEASED = "Unreleased"

# Every PR used to add its line under `## [Unreleased]`, so any two open PRs
# collided on adjacent lines and every squash merge made the rest dirty. A PR
# now writes `changelog.d/<branch>.md` - its own file, its own lines - whose
# first line is the category heading and whose rest is the entry exactly as it
# would have sat under that heading. The cut assembles them, in this order, so
# the published section reads the way it always did.
CATEGORIES = ("### Added", "### Changed", "### Fixed", "### Removed")


def default_changelog():
    return Path(__file__).resolve().parents[2] / "CHANGELOG.md"


def default_fragments(changelog_path):
    return Path(changelog_path).resolve().parent / "changelog.d"


def fragment_files(fragments_dir):
    """Every fragment, in file-name order - so the section is stable."""
    if fragments_dir is None:
        return []
    path = Path(fragments_dir)
    if not path.is_dir():
        # No directory yet (or /dev/null) simply means no fragments; a repo
        # mid-transition still releases from a hand-written [Unreleased].
        return []
    return sorted((p for p in path.iterdir() if p.is_file() and p.suffix == ".md"),
                  key=lambda p: p.name)


def split_categories(body):
    """`{heading: [lines]}` for a section body, plus anything above the first
    heading under the key ''."""
    groups, current = {}, ""
    for line in (body or "").splitlines():
        if line.strip().startswith("### "):
            current = line.strip()
            groups.setdefault(current, [])
            continue
        groups.setdefault(current, []).append(line)
    return groups


def _trim(lines):
    out = list(lines)
    while out and not out[0].strip():
        out.pop(0)
    while out and not out[-1].strip():
        out.pop()
    return out


def assemble(handwritten, fragments_dir):
    """The pending section: hand-written entries and every fragment, grouped by
    category in the fixed order, file-name order within a category."""
    groups = {}
    order = []

    def add(heading, lines):
        lines = _trim(lines)
        if not lines:
            return
        if heading not in groups:
            groups[heading] = []
            order.append(heading)
        groups[heading].extend(lines)

    for heading, lines in split_categories(handwritten).items():
        add(heading, lines)
    for path in fragment_files(fragments_dir):
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines()
        head = lines[0].strip() if lines else ""
        if head.startswith("### "):
            add(head, lines[1:])
        else:
            # A fragment without a category heading is a mistake worth naming:
            # silently filing it under Added would publish it in the wrong place.
            raise SystemExit(
                f"notes: {path} must start with a category heading, one of "
                + ", ".join(CATEGORIES)
            )

    ranked = [h for h in CATEGORIES if h in groups]
    ranked += [h for h in order if h and h not in CATEGORIES]
    parts = []
    if "" in groups:
        parts.append("\n".join(groups[""]))
    for heading in ranked:
        parts.append(heading + "\n" + "\n".join(groups[heading]))
    return "\n\n".join(p for p in parts if p.strip())


def section(text, name):
    """The body under `## [<name>]`, without the heading, blank edges trimmed."""
    wanted = f"## [{name}]"
    body, inside = [], False
    for line in text.splitlines():
        if line.startswith("## ["):
            if inside:
                break
            inside = line.startswith(wanted)
            continue
        if inside:
            body.append(line)
    if not inside:
        return None
    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()
    return "\n".join(body)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="x.y.z, or 'unreleased' for the pending section")
    parser.add_argument("--changelog", default=None)
    parser.add_argument("--fragments", default=None,
                        help="the changelog.d directory (default: beside the CHANGELOG)")
    args = parser.parse_args(argv)

    path = Path(args.changelog) if args.changelog else default_changelog()
    if not path.exists():
        print(f"notes: no CHANGELOG at {path}", file=sys.stderr)
        return 1
    name = UNRELEASED if args.version.lower() == "unreleased" else args.version.lstrip("v")
    body = section(path.read_text(encoding="utf-8"), name)
    if body is None:
        # A version with no section is a mistake upstream of the release, not
        # a release with nothing in it: refuse rather than publish silence.
        print(f"notes: no '## [{name}]' section in {path}", file=sys.stderr)
        return 1
    if name == UNRELEASED:
        fragments = args.fragments if args.fragments is not None else default_fragments(path)
        body = assemble(body, fragments)
    if body:
        print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
