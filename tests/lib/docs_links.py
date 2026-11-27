#!/usr/bin/env python3
"""Every relative link and #anchor in the docs must resolve.

  docs_links.py <cel-root> [doc.md ...]

WHICH FILES. The given markdown files, or by default README.md,
CONTRIBUTING.md, SECURITY.md and docs/**/*.md under <cel-root>.

WHICH LINKS. Inline links and images, `[text](target)` and `![alt](target)`,
and reference definitions, `[label]: target`, outside fenced code blocks and
inline code spans. A target with a scheme (https:, mailto:, ...) is not
checked: this is about the tree, not the network.

RESOLVES. The path part, relative to the linking file's directory, must exist
in the tree (a file or a directory) and stay inside <cel-root>. An anchor
(`#x`, or `file.md#x`) must name a heading of that markdown file by GitHub's
slug rule - lower-cased, every character that is not a letter, digit,
underscore, hyphen or space dropped, spaces turned into hyphens, and a repeat
of an earlier heading's slug given `-1`, `-2`, ... in order - or an explicit
`id="x"` / `name="x"` in it. An anchor into a file that is not markdown is
reported.

Prints one line per broken link as `<file>:<line>: <target>: <why>`, then
`checked N` on stderr. Exit 1 when anything was printed.
"""
import os
import re
import sys
from urllib.parse import unquote

FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
CODE_SPAN = re.compile(r"(`+)(.+?)\1")
INLINE = re.compile(r"!?\[(?:[^\[\]]|\[[^\[\]]*\])*\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+\"[^\"]*\")?\s*\)")
REFDEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)")
HTML_ID = re.compile(r"""\b(?:id|name)\s*=\s*["']([^"']+)["']""")
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def slug(text):
    """GitHub's heading anchor for one heading's text."""
    text = CODE_SPAN.sub(lambda m: m.group(2), text)
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)  # a link keeps its text
    text = re.sub(r"<[^>]+>", "", text)                       # inline HTML tags go
    text = text.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def prose_lines(path):
    """(line number, text) of every line outside a fenced code block."""
    fence = None
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh.read().split("\n"), 1):
            m = FENCE.match(line)
            if m:
                mark = m.group(1)
                if fence is None:
                    fence = mark[0] * len(mark)
                elif mark.startswith(fence):
                    fence = None
                continue
            if fence is None:
                yield n, line


_anchor_cache = {}


def anchors_of(path):
    if path not in _anchor_cache:
        seen, found = {}, set()
        for _n, line in prose_lines(path):
            h = HEADING.match(line)
            if h:
                s = slug(h.group(2))
                k = seen.get(s, 0)
                seen[s] = k + 1
                found.add(s if k == 0 else f"{s}-{k}")
            found.update(HTML_ID.findall(line))
        _anchor_cache[path] = found
    return _anchor_cache[path]


def targets(path):
    for n, line in prose_lines(path):
        m = REFDEF.match(line)
        if m:
            yield n, m.group(1)
            continue
        bare = CODE_SPAN.sub(lambda c: "x" * len(c.group(0)), line)
        for m in INLINE.finditer(bare):
            yield n, line[m.start(1):m.end(1)]


def check(cel_root, doc):
    bad, checked = [], 0
    rel = os.path.relpath(doc, cel_root)
    for n, raw in targets(doc):
        target = raw[1:-1] if raw.startswith("<") and raw.endswith(">") else raw
        if SCHEME.match(target):
            continue
        checked += 1
        part, _, anchor = target.partition("#")
        dest = doc if part == "" else os.path.normpath(os.path.join(os.path.dirname(doc), unquote(part)))
        if os.path.commonpath([cel_root, dest]) != cel_root:
            bad.append(f"{rel}:{n}: {raw}: leaves the tree")
            continue
        if not os.path.exists(dest):
            bad.append(f"{rel}:{n}: {raw}: no such file")
            continue
        if anchor:
            if not dest.endswith(".md"):
                bad.append(f"{rel}:{n}: {raw}: an anchor into a file that is not markdown")
            elif unquote(anchor) not in anchors_of(dest):
                bad.append(f"{rel}:{n}: {raw}: no such anchor in {os.path.relpath(dest, cel_root)}")
    return bad, checked


def default_docs(cel_root):
    docs = [os.path.join(cel_root, f) for f in ("README.md", "CONTRIBUTING.md", "SECURITY.md")]
    for base, _dirs, files in os.walk(os.path.join(cel_root, "docs")):
        docs += [os.path.join(base, f) for f in sorted(files) if f.endswith(".md")]
    return [d for d in docs if os.path.isfile(d)]


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cel_root = os.path.realpath(argv[1])
    docs = [os.path.realpath(d) for d in argv[2:]] or default_docs(cel_root)
    bad, checked = [], 0
    for doc in docs:
        b, c = check(cel_root, doc)
        bad += b
        checked += c
    for line in bad:
        print(line)
    print(f"checked {checked}", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
