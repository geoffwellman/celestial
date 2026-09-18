#!/usr/bin/env python3
"""Perform the version cut: VERSION, then the CHANGELOG rename and a fresh
`[Unreleased]`, and print the shipped section.

This is the whole of the Cut workflow's thinking. It lives here rather than in
the YAML so it can be run and tested on fixtures without GitHub - a release
step that can only be exercised by cutting a release is a step nobody exercises.
"""
import argparse
import datetime
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from notes import UNRELEASED, section  # noqa: E402

SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")

# The subject a release lands on main with. GitHub's squash merge appends the
# pull request number - `release: v0.3.0 (#57)` - and a plain prefix strip left
# `0.3.0 (#57)`, which never equalled VERSION, so the publish job refused the
# only path a release can actually take while hand-pushed tags kept working.
SUBJECT = re.compile(r"^release: v(\S+?)(?: \(#[0-9]+\))?$")


def version_from_subject(subject):
    match = SUBJECT.match(subject.strip())
    if match is None or parse(match[1]) is None:
        raise SystemExit(f"cut: '{subject}' is not a release commit subject")
    return match[1]



def parse(version):
    match = SEMVER.match(version)
    return tuple(int(part) for part in match.groups()) if match else None


def cut(changelog_path, version_path, version, today):
    """Rewrite both files; returns the section that is shipping."""
    new = parse(version)
    if new is None:
        # `v0.3.0` and `0.3` both reach here from a dispatch input box, and
        # both would produce a tag nothing else in the plane can compare.
        raise SystemExit(f"cut: '{version}' is not a semver x.y.z version")
    current = version_path.read_text(encoding="utf-8").strip()
    old = parse(current)
    if old is None:
        raise SystemExit(f"cut: {version_path} holds '{current}', which is not semver")
    if new <= old:
        raise SystemExit(f"cut: {version} is not greater than the current {current}")

    text = changelog_path.read_text(encoding="utf-8")
    body = section(text, UNRELEASED)
    if body is None:
        raise SystemExit(f"cut: no '## [{UNRELEASED}]' section in {changelog_path}")
    if not body.strip():
        # Forty-odd merges landed unreleased because nobody wrote them down.
        # An empty section means the notes were never written, and notes are
        # the only part of a release a human reads.
        raise SystemExit(f"cut: the [{UNRELEASED}] section is empty - nothing to release")

    heading = f"## [{UNRELEASED}]"
    replacement = f"## [{UNRELEASED}]\n\n## [{version}] - {today}"
    if text.count(heading + "\n") < 1:
        raise SystemExit(f"cut: cannot locate the {heading} heading in {changelog_path}")
    text = text.replace(heading + "\n", replacement + "\n", 1)
    changelog_path.write_text(text, encoding="utf-8")
    version_path.write_text(version + "\n", encoding="utf-8")
    return body


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?")
    parser.add_argument("--version-from-subject", default=None,
                        help="print the version in a `release: v<x.y.z> (#N)` commit subject")
    parser.add_argument("--changelog", default=None)
    parser.add_argument("--version-file", default=None)
    parser.add_argument("--today", default=None)
    args = parser.parse_args(argv)

    if args.version_from_subject is not None:
        print(version_from_subject(args.version_from_subject))
        return 0
    if not args.version:
        raise SystemExit("cut: want a version, or --version-from-subject")

    root = Path(__file__).resolve().parents[2]
    changelog = Path(args.changelog) if args.changelog else root / "CHANGELOG.md"
    version_file = Path(args.version_file) if args.version_file else root / "VERSION"
    today = args.today or datetime.date.today().isoformat()
    print(cut(changelog, version_file, args.version, today))
    return 0


if __name__ == "__main__":
    sys.exit(main())
