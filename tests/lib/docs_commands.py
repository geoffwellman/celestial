#!/usr/bin/env python3
"""Every `cel <command>` the docs show must be a command `cel` has.

  docs_commands.py <cel-root> [doc.md ...]

Reads the dispatch table at the bottom of bin/cel (the `case "${1:-help}"`
block) for the commands, and - for the commands whose first argument is a verb
(VERB_COMMANDS) - the case labels of the function that command dispatches to
for its verbs. An arm or label whose body refuses with "retired" does not
count: a retired command is refused, not supported.

Scanned: every fenced code block, and every inline code span, of the given
markdown files (default: README.md, CONTRIBUTING.md, SECURITY.md and
docs/**/*.md under <cel-root>). A source line that says "retired" is the one
place a retired command may still be named, so it is skipped.

Prints one line per command the docs show that cel does not have, as
`<file>:<line>: cel <words>: <why>`, then `checked N` on stderr. Exit 1 when
anything was printed.
"""
import os
import re
import sys

# Commands whose first argument, when it is a word, must be one of their verbs.
VERB_COMMANDS = {
    "afk", "box", "decide", "drive", "effects", "forge", "gateway", "here",
    "inbox", "learn", "pages", "plugins", "run", "serve", "services",
    "sessions", "solo", "team", "watchdog", "ws",
}

LABEL_ALT = r"""(?:"[^"\n]*"|'[^'\n]*'|[A-Za-z0-9_.*-]+)"""
LABEL_RE = re.compile(r"^\s*\(?(" + LABEL_ALT + r"(?:\s*\|\s*" + LABEL_ALT + r")*)\)(?:\s|$)")
WORD_RE = re.compile(r"^[a-z][a-z0-9-]*$")


def _labels(lines):
    """{first word of every case-label alternative: arm is live} over lines."""
    out = {}
    for i, line in enumerate(lines):
        m = LABEL_RE.match(line)
        if not m:
            continue
        body = []
        for later in lines[i:]:
            body.append(later)
            if ";;" in later:
                break
        live = "retired" not in "\n".join(body).lower()
        for alt in re.split(r"\s*\|\s*", m.group(1)):
            word = alt.strip("\"'").split(" ")[0]
            if WORD_RE.match(word):
                out[word] = out.get(word, False) or live
    return out


def _dispatch(cel_root):
    """{command: arm body} from bin/cel's dispatch case."""
    with open(os.path.join(cel_root, "bin", "cel"), encoding="utf-8") as fh:
        text = fh.read()
    start = text.index('case "${1:-help}" in')
    end = text.index("\nesac", start)
    lines = text[start:end].splitlines()[1:]
    arms, cur = {}, None
    for line in lines:
        m = re.match(r"^  (\S[^)]*)\)\s?(.*)$", line)
        if m and not line.startswith("   "):
            cur = [w.strip() for w in m.group(1).split("|")]
            for w in cur:
                arms[w] = m.group(2)
            continue
        if cur:
            for w in cur:
                arms[w] += "\n" + line
    return {w: b for w, b in arms.items() if WORD_RE.match(w) or w in ("help",)}


def _function(cel_root, name):
    for fn in sorted(os.listdir(os.path.join(cel_root, "lib"))):
        if not fn.endswith(".sh"):
            continue
        with open(os.path.join(cel_root, "lib", fn), encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        for i, line in enumerate(lines):
            if re.match(r"^" + re.escape(name) + r"\(\)", line):
                body = []
                for later in lines[i:]:
                    body.append(later)
                    if later.startswith("}") or later.startswith(")"):
                        break
                return body
    return []


def commands(cel_root):
    """({command: live}, {command: {verb: live}})."""
    arms = _dispatch(cel_root)
    top = {w: "retired" not in b.lower() for w, b in arms.items()}
    verbs = {}
    for cmd in VERB_COMMANDS:
        body = arms.get(cmd)
        if body is None:
            continue
        lines = body.splitlines()
        found = _labels(lines[1:]) if "\n" in body else {}
        calls = re.findall(r"\b(cmd_[a-z_]+)\b", body)
        if calls:
            fn = _function(cel_root, calls[-1])
            lines = list(fn)
            inner = re.search(r"\b(_" + re.escape(calls[-1]) + r")\b", "\n".join(fn[1:]))
            if inner:
                lines += _function(cel_root, inner.group(1))
            for w, live in _labels(lines).items():
                found[w] = found.get(w, False) or live
        verbs[cmd] = found
    return top, verbs


CODE_SPAN = re.compile(r"(?<!`)`([^`\n]+(?:\n[^`\n]+)?)`(?!`)")
# `cel` as a word of its own: a path ending in /cel (bin/cel, ~/.local/share/cel)
# is a file, not a command, and `cel run:` is a message prefix.
CEL_CALL = re.compile(r"(?:^|(?<=[\s(\[{\"'`;&|$=]))cel[ \t]+([a-z][a-z0-9-]*)(?![a-z0-9:-])([^\n]*)")


def _snippets(path):
    """(line number, code text, source line) for every code line/span."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    lines = text.splitlines()
    out, prose, fence = [], [], None
    for n, line in enumerate(lines, 1):
        m = re.match(r"^\s*(`{3,}|~{3,})", line)
        if fence is None and m:
            fence = m.group(1)
            prose.append("")
            continue
        if fence is not None:
            if line.strip().startswith(fence):
                fence = None
            else:
                out.append((n, line, line))
            prose.append("")
            continue
        prose.append(line)
    joined = "\n".join(prose)
    for m in CODE_SPAN.finditer(joined):
        n = joined.count("\n", 0, m.start()) + 1
        src = "\n".join(lines[n - 1:n + m.group(1).count("\n")])
        out.append((n, m.group(1).replace("\n", " "), src))
    return out


def _verbs_shown(rest):
    """The verbs right after the command: `a|b`, `a · b · c`, or one word.

    A `·` list sits at the depth of the word just before the first `·`, so in
    `pr view · checks` only `pr` is a verb of the command."""
    parts = re.split(r"\s*·\s*", rest.strip())
    if len(parts) > 1 and len(parts[0].split()) > 1:
        parts = parts[:1]
    words = []
    for part in parts:
        token = part.split()[0] if part.split() else ""
        token = token.rstrip(".,;:)`'\"")
        for alt in token.split("|"):
            if WORD_RE.match(alt):
                words.append(alt)
    return words


def check(cel_root, docs):
    top, verbs = commands(cel_root)
    problems, checked = [], 0
    for path in docs:
        rel = os.path.relpath(path, cel_root)
        for n, code, src in _snippets(path):
            if "retired" in src.lower():
                continue
            for m in CEL_CALL.finditer(code):
                cmd, rest = m.group(1), m.group(2)
                cmds = [cmd]
                alts = re.match(r"((?:\|[a-z][a-z0-9-]*)+)", rest)
                if alts:  # `cel afk|release|update`: several commands, no verbs
                    cmds += alts.group(1).strip("|").split("|")
                for c in cmds:
                    checked += 1
                    if c not in top:
                        problems.append(f"{rel}:{n}: cel {c}: no such command in bin/cel")
                    elif not top[c]:
                        problems.append(f"{rel}:{n}: cel {c}: retired (bin/cel refuses it)")
                if alts or cmd not in top or not top[cmd]:
                    continue
                if cmd in verbs:
                    for verb in _verbs_shown(rest):
                        state = verbs[cmd].get(verb)
                        if state is None:
                            problems.append(f"{rel}:{n}: cel {cmd} {verb}: no such verb in cel {cmd}")
                        elif not state:
                            problems.append(f"{rel}:{n}: cel {cmd} {verb}: retired (cel {cmd} refuses it)")
    return problems, checked


def default_docs(cel_root):
    docs = [os.path.join(cel_root, f) for f in ("README.md", "CONTRIBUTING.md", "SECURITY.md")]
    for base, _dirs, files in os.walk(os.path.join(cel_root, "docs")):
        docs += [os.path.join(base, f) for f in sorted(files) if f.endswith(".md")]
    return [d for d in docs if os.path.isfile(d)]


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cel_root = os.path.abspath(argv[1])
    docs = [os.path.abspath(d) for d in argv[2:]] or default_docs(cel_root)
    problems, checked = check(cel_root, docs)
    for p in problems:
        print(p)
    print(f"checked {checked}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
