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


def default_changelog():
    return Path(__file__).resolve().parents[2] / "CHANGELOG.md"


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
    if body:
        print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
