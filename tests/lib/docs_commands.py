#!/usr/bin/env python3
"""Every `cel <command>` the docs show must be a command `cel` has.

  docs_commands.py <cel-root> [doc.md ...]

WHAT COUNTS AS A COMMAND. The dispatch table at the bottom of bin/cel (the
`case "${1:-help}"` block) names the commands. For the commands whose first
argument is a verb (VERB_COMMANDS), the verbs are the case labels of the
function that command dispatches to (cmd_<x>, and the _cmd_<x> it delegates
to). An arm or label whose body refuses with "retired" is retired: refused,
not supported.

SUB-VERBS ARE READ ONLY FROM TWO-WORD LABELS. A handler that matches
`"$verb $sub"` against labels such as `"pr view"` (lib/forge.sh _cmd_forge)
gives its sub-verbs exactly, so `cel forge pr <verb>` and `cel forge run
<verb>` are checked one level deeper. A handler that dispatches its sub-verbs
any other way - a nested `case` in a helper function - is checked only to its
first verb: its sub-verbs cannot be read reliably from the source, and the
check does not guess. Today forge is the only command with sub-verbs.

WHERE. Every fenced code block, every 4-space (or tab) indented code block,
and every inline code span of the given markdown files (default: README.md,
CONTRIBUTING.md, SECURITY.md and docs/**/*.md under <cel-root>). An indented
line counts as code only after a blank line and outside a list, as markdown
reads it; inside a list it is the item's own continuation.

EVERY `cel` ON A LINE. A code line is split on the shell separators (`&&`,
`||`, `;`, a ` | ` pipe, newlines) and each part is checked from each `cel`
word in it, so a second command after `&&` is checked too. `cel a|b|c`
(no spaces) names several commands.

RETIRED. A retired command or verb may be named only on a source line that
itself says "retired" - the one place the docs record what went. Only that
command is exempt: anything else on the line is checked as usual, and a
command that does not exist is reported wherever it appears.

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
    """({first word of every case-label alternative: live},
        {first word: {second word: live}} for two-word labels like "pr view")."""
    out, sub = {}, {}
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
            words = alt.strip("\"'").split(" ")
            if not WORD_RE.match(words[0]):
                continue
            out[words[0]] = out.get(words[0], False) or live
            if len(words) == 2 and WORD_RE.match(words[1]):
                kids = sub.setdefault(words[0], {})
                kids[words[1]] = kids.get(words[1], False) or live
    return out, sub


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
    return {w: b for w, b in arms.items() if WORD_RE.match(w)}


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
    """({command: live}, {command: {verb: live}}, {command: {verb: {sub: live}}})."""
    arms = _dispatch(cel_root)
    top = {w: "retired" not in b.lower() for w, b in arms.items()}
    verbs, subs = {}, {}
    for cmd in VERB_COMMANDS:
        body = arms.get(cmd)
        if body is None:
            continue
        lines = body.splitlines()[1:]
        calls = re.findall(r"\b(cmd_[a-z_]+)\b", body)
        if calls:
            fn = _function(cel_root, calls[-1])
            lines += fn
            inner = re.search(r"\b(_" + re.escape(calls[-1]) + r")\b", "\n".join(fn[1:]))
            if inner:
                lines += _function(cel_root, inner.group(1))
        verbs[cmd], subs[cmd] = _labels(lines)
    return top, verbs, subs


CODE_SPAN = re.compile(r"(?<!`)`([^`\n]+(?:\n[^`\n]+)?)`(?!`)")
# `cel` as a word of its own: a path ending in /cel (bin/cel, ~/.local/share/cel)
# is a file, not a command, and `cel run:` is a message prefix. The rest of
# the call stops before the next `cel` word.
CEL_WORD = r"(?:^|(?<=[\s(\[{\"'`$=]))cel[ \t]+"
CEL_CALL = re.compile(CEL_WORD + r"([a-z][a-z0-9-]*)(?![a-z0-9:-])((?:(?!" + CEL_WORD + r").)*)")
SEPARATORS = re.compile(r"&&|\|\||;|\s\|\s|\n")
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")


def _snippets(path):
    """(line number, code text, source line) for every code line/span."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    lines = text.splitlines()
    out, prose, fence = [], [], None
    prev_blank, in_list, in_indented = True, False, False
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
            prev_blank = False
            continue
        blank = not line.strip()
        indented = bool(re.match(r"^( {4,}|\t)\S", line))
        if indented and not in_list and (prev_blank or in_indented):
            in_indented = True
            out.append((n, line, line))
            prose.append("")
            prev_blank = False
            continue
        if not blank:
            in_indented = False
            if LIST_ITEM.match(line):
                in_list = True
            elif not line.startswith((" ", "\t")):
                in_list = False
        prev_blank = blank
        prose.append(line)
    joined = "\n".join(prose)
    for m in CODE_SPAN.finditer(joined):
        n = joined.count("\n", 0, m.start()) + 1
        src = "\n".join(lines[n - 1:n + m.group(1).count("\n")])
        out.append((n, m.group(1).replace("\n", " "), src))
    return out


def _words_shown(rest):
    """(verbs, sub-verbs) right after the command: `a|b`, `a · b · c`, or one
    word, then the sub-verb(s) after the first verb.

    A `·` list sits at the depth of the word just before the first `·`: in
    `ws new · add` the list is of verbs, in `forge pr view · checks` it is of
    `pr`'s sub-verbs."""
    def clean(token):
        return [a for a in token.rstrip(".,;:)`'\"").split("|") if WORD_RE.match(a)]

    parts = [p.split() for p in re.split(r"\s*·\s*", rest.strip())]
    if not parts or not parts[0]:
        return [], []
    first = parts[0]
    if len(parts) > 1 and len(first) > 1:  # `pr view · checks`: sub-verbs listed
        verbs = clean(first[0])
        subs = clean(first[1]) + [w for p in parts[1:] if p for w in clean(p[0])]
        return verbs, subs
    verbs = [w for p in parts for w in (clean(p[0]) if p else [])]
    subs = clean(first[1]) if len(parts) == 1 and len(first) > 1 else []
    return verbs, subs


def check(cel_root, docs):
    top, verbs, subs = commands(cel_root)
    problems, checked = [], 0
    for path in docs:
        rel = os.path.relpath(path, cel_root)
        for n, code, src in _snippets(path):
            says_retired = "retired" in src.lower()

            def report(words, state, where):
                if state is None:
                    problems.append(f"{rel}:{n}: cel {words}: no such {where}")
                elif not state and not says_retired:
                    problems.append(f"{rel}:{n}: cel {words}: retired ({where.split(' in ')[-1]} refuses it)")

            for part in SEPARATORS.split(code):
                for m in CEL_CALL.finditer(part):
                    cmd, rest = m.group(1), m.group(2)
                    cmds = [cmd]
                    alts = re.match(r"((?:\|[a-z][a-z0-9-]*)+)", rest)
                    if alts:  # `cel afk|release|update`: several commands, no verbs
                        cmds += alts.group(1).strip("|").split("|")
                    for c in cmds:
                        checked += 1
                        report(c, top.get(c), "command in bin/cel")
                    if alts or not top.get(cmd) or cmd not in verbs:
                        continue
                    shown, shown_subs = _words_shown(rest)
                    for verb in shown:
                        state = verbs[cmd].get(verb)
                        report(f"{cmd} {verb}", state, f"verb in cel {cmd}")
                        kids = subs[cmd].get(verb)
                        if state and kids:
                            for sub in shown_subs:
                                report(f"{cmd} {verb} {sub}", kids.get(sub), f"verb in cel {cmd} {verb}")
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
