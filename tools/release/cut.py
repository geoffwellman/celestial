#!/usr/bin/env python3
"""Perform the version cut: VERSION, then the CHANGELOG rename and a fresh
`[Unreleased]`, and print the shipped section.

This is the whole of the Cut workflow's thinking. It lives here rather than in
the YAML so it can be run and tested on fixtures without GitHub - a release
step that can only be exercised by cutting a release is a step nobody exercises.
"""
import argparse
import contextlib
import datetime
import os
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from notes import UNRELEASED, assemble, default_fragments, fragment_files, section  # noqa: E402

SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")

# The subject a release lands on main with. GitHub's squash merge appends the
# pull request number - `release: v0.3.0 (#57)` - so a plain prefix strip would
# never equal VERSION and the publish job would refuse the only real path.
SUBJECT = re.compile(r"^release: v(\S+?)(?: \(#[0-9]+\))?$")


def version_from_subject(subject):
    match = SUBJECT.match(subject.strip())
    if match is None or parse(match[1]) is None:
        raise SystemExit(f"cut: '{subject}' is not a release commit subject")
    return match[1]



def parse(version):
    match = SEMVER.match(version)
    return tuple(int(part) for part in match.groups()) if match else None


def _stage(path, text):
    """A flushed sibling temp file holding `text`, with `path`'s mode; nothing
    is replaced yet."""
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".cut", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, stat.S_IMODE(path.stat().st_mode))
    except BaseException:
        os.unlink(tmp)
        raise
    return Path(tmp)


def _commit(rewrites, fragments, fragments_dir):
    """All or nothing: both files are staged and every fragment is moved aside
    before either file is replaced, and any failure puts back what was done -
    a half cut (new section, old VERSION, some fragments gone) cannot be rerun."""
    staged, moved, replaced, aside = {}, [], [], None
    try:
        for path, (_, new) in rewrites.items():
            staged[path] = _stage(path, new)
        if fragments:
            aside = Path(tempfile.mkdtemp(prefix=".cut-", dir=fragments_dir))
            for path in fragments:
                path.rename(aside / path.name)
                moved.append(path)
        for path, tmp in staged.items():
            os.replace(tmp, path)
            replaced.append(path)
    except BaseException:
        for path in replaced:
            os.replace(_stage(path, rewrites[path][0]), path)
        for path in moved:
            (aside / path.name).rename(path)
        for tmp in staged.values():
            tmp.unlink(missing_ok=True)
        if aside is not None:
            with contextlib.suppress(OSError):
                aside.rmdir()
        raise
    if aside is not None:
        # Hidden, so a leftover is never read as a fragment, and untracked, so
        # `git commit -a` never ships it.
        shutil.rmtree(aside, ignore_errors=True)


def cut(changelog_path, version_path, version, today, fragments_dir=None):
    """Rewrite both files, consume the fragments; returns the shipping section."""
    new = parse(version)
    if new is None:
        # `v0.3.0` and `0.3` both reach here from a dispatch input box, and
        # both would produce a tag nothing else in the plane can compare.
        raise SystemExit(f"cut: '{version}' is not a semver x.y.z version")
    current_text = version_path.read_text(encoding="utf-8")
    current = current_text.strip()
    old = parse(current)
    if old is None:
        raise SystemExit(f"cut: {version_path} holds '{current}', which is not semver")
    if new <= old:
        raise SystemExit(f"cut: {version} is not greater than the current {current}")

    text = changelog_path.read_text(encoding="utf-8")
    handwritten = section(text, UNRELEASED)
    if handwritten is None:
        raise SystemExit(f"cut: no '## [{UNRELEASED}]' section in {changelog_path}")
    if fragments_dir is None:
        fragments_dir = default_fragments(changelog_path)
    fragments = fragment_files(fragments_dir)
    body = assemble(handwritten, fragments_dir)
    if not body.strip():
        # Forty-odd merges landed unreleased because nobody wrote them down.
        # An empty section means the notes were never written, and notes are
        # the only part of a release a human reads.
        raise SystemExit(
            f"cut: no fragments in {fragments_dir} and nothing under "
            f"[{UNRELEASED}] - nothing to release"
        )

    heading = f"## [{UNRELEASED}]"
    if text.count(heading + "\n") < 1:
        raise SystemExit(f"cut: cannot locate the {heading} heading in {changelog_path}")
    # The pending section is replaced wholesale rather than renamed: the
    # entries being shipped came from the fragments as much as from the file.
    before, _, rest = text.partition(heading + "\n")
    _, _, after = rest.partition("\n## [")
    tail = ("## [" + after) if after else ""
    shipped = f"{heading}\n\n## [{version}] - {today}\n\n{body}\n\n"
    # In the same commit as the section they became, or the next cut ships
    # them twice.
    _commit({changelog_path: (text, before + shipped + tail),
             version_path: (current_text, version + "\n")},
            fragments, fragments_dir)
    return body


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?")
    parser.add_argument("--version-from-subject", default=None,
                        help="print the version in a `release: v<x.y.z> (#N)` commit subject")
    parser.add_argument("--changelog", default=None)
    parser.add_argument("--version-file", default=None)
    parser.add_argument("--fragments", default=None)
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
    # Beside the CHANGELOG being cut, never beside this file: tools/ is
    # symlinked into test fixtures, and a default taken from __file__ made a
    # fixture cut delete the real repository's fragments.
    fragments = Path(args.fragments) if args.fragments else default_fragments(changelog)
    try:
        print(cut(changelog, version_file, args.version, today, fragments))
    except OSError as err:
        raise SystemExit(f"cut: {err}") from None
    return 0


if __name__ == "__main__":
    sys.exit(main())
