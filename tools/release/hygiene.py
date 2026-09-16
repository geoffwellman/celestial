#!/usr/bin/env python3
"""Scan publication inputs without printing matched credentials or private vocabulary."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

# Examples use these fictional ticket prefixes. Technical standard references
# are not project tickets. Everything else needs review, including test data.
# CEL is the plane's OWN ticket prefix - the work orders that build celestial
# itself, whose branch names and commit messages are public by definition.
# It is not an example; it is the one real prefix this repository may name.
EXAMPLE_PREFIXES = {"ABC", "ABCD", "WG", "WGT", "OT", "AH", "CEL"}
STANDARD_PREFIXES = {"UTF", "SHA", "ISO", "RFC", "TLS", "HTTP", "CWE", "CVE", "NIST", "PKCS", "RSA",
                     # SPDX licence identifiers. `CC0-1.0` in a committed
                     # npm lock file is the public domain dedication a
                     # transitive dependency ships under, not a ticket from
                     # someone's private tracker.
                     "CC0", "CC", "BSD", "GPL", "LGPL", "AGPL", "EPL", "MPL", "CDDL", "APACHE"}
TICKET = re.compile(r"\b([A-Z][A-Z0-9]{1,9})-[0-9]+\b")
SECRET_RULES = {
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"),
    "GitHub credential": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    "cloud access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "provider credential": re.compile(r"\bsk-(?:proj-|or-v1-)?[A-Za-z0-9_-]{24,}\b"),
    "tracker credential": re.compile(r"\blin_api_[A-Za-z0-9]{20,}\b"),
    "chat credential": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "authenticated URL": re.compile(r"https?://[^\s/@:]+:[^\s/@]+@"),
}


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)


def scan_text(label, text, private_rules, findings):
    for number, line in enumerate(text.splitlines(), 1):
        for category, rule in SECRET_RULES.items():
            if rule.search(line):
                findings.add((label, number, category))
        for index, rule in enumerate(private_rules, 1):
            if rule.search(line):
                findings.add((label, number, f"private pattern {index}"))
        # Do not mistake the literal standard regex character class for a
        # ticket. Only this exact syntax is exempt, not bracketed content.
        ticket_text = line.replace("[A-Z0-9]", " " * len("[A-Z0-9]"))
        for match in TICKET.finditer(ticket_text):
            if match[1] not in EXAMPLE_PREFIXES | STANDARD_PREFIXES:
                findings.add((label, number, "non-example ticket identifier"))


def sensitive_path(name):
    parts = Path(name).parts
    base = parts[-1]
    return (
        any(part in {".agent", ".cel", "__pycache__"} for part in parts)
        or name.startswith((".claude/worktrees/", "tools/herdr/snapshots/"))
        or base in {"env.local", "secrets.json", ".env"}
        or (base.startswith(".env.") and base != ".env.example")
        or base.endswith((".local", ".pem", ".key", ".pyc"))
        or ".local." in base
        or name == "registry.yaml"
    )


def current_inputs(root):
    names = git(root, "ls-files", "-z").decode().split("\0")
    for name in filter(None, names):
        path = root / name
        if path.is_symlink():
            # Never follow links into the publisher's home or private workspace.
            yield name, os.readlink(path).encode(), True
        elif path.exists():
            yield name, path.read_bytes(), False
        # A tracked deletion is deliberately absent from the proposed snapshot.


def history_inputs(root):
    if git(root, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise ValueError("history scan requires a complete clone (fetch-depth: 0)")
    blobs = {}
    for commit in git(root, "rev-list", "--all").decode().splitlines():
        yield f"commit {commit}", git(root, "cat-file", "-p", commit), False
        for entry in git(root, "ls-tree", "-rz", commit).split(b"\0"):
            if not entry:
                continue
            metadata, raw_name = entry.split(b"\t", 1)
            mode, kind, oid = metadata.decode().split()
            name = raw_name.decode("utf-8", errors="replace")
            if kind != "blob":
                yield f"{commit}:{name}", b"", True
                continue
            # Each path is checked even when the bytes were already seen under
            # another name. Blob reads themselves are deduplicated.
            if oid not in blobs:
                blobs[oid] = git(root, "cat-file", "blob", oid)
            yield f"{commit}:{name}", blobs[oid], mode == "120000"
    for ref in git(root, "for-each-ref", "--format=%(refname)").decode().splitlines():
        yield f"ref {ref}", ref.encode(), False
        if git(root, "cat-file", "-t", ref).strip() == b"tag":
            yield f"tag {ref}", git(root, "cat-file", "-p", ref), False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--all-history", action="store_true", help="also inspect all local refs, commits, tags and historical paths")
    parser.add_argument("--private-patterns", type=Path, default=os.environ.get("CEL_PRIVATE_PATTERNS_FILE"), help="private, external UTF-8 file: one case-insensitive regex per line")
    parser.add_argument("--require-private-patterns", action="store_true", help="refuse a release scan without a nonempty external vocabulary")
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        rules = []
        if args.private_patterns:
            patterns_path = Path(args.private_patterns).resolve()
            if patterns_path.is_relative_to(root):
                raise ValueError("private vocabulary must be stored outside the repository")
            for line in patterns_path.read_text().splitlines():
                if line.strip() and not line.lstrip().startswith("#"):
                    try:
                        rules.append(re.compile(line.strip(), re.IGNORECASE))
                    except re.error:
                        raise ValueError("invalid private regex (value withheld)") from None
            if any(rule.search("") for rule in rules):
                raise ValueError("private regex must not match an empty string")
        if args.require_private_patterns and not rules:
            raise ValueError("release scan requires a nonempty external private-patterns file")
        findings = set()
        inputs = 0
        sources = [current_inputs(root)]
        if args.all_history:
            sources.append(history_inputs(root))
        for source in sources:
            for label, content, link in source:
                inputs += 1
                name = label.split(":", 1)[-1] if re.match(r"^[0-9a-f]{40,64}:", label) else label
                if not label.startswith(("commit ", "ref ", "tag ")) and sensitive_path(name):
                    findings.add((label, 0, "machine-local or sensitive file"))
                if link:
                    findings.add((label, 0, "symlink or submodule requires explicit publication review"))
                scan_text(label, label, rules, findings)
                scan_text(label, content.decode("utf-8", errors="replace"), rules, findings)
        for label, line, category in sorted(findings):
            safe_label = label
            for rule in [*SECRET_RULES.values(), *rules]:
                safe_label = rule.sub("<redacted>", safe_label)
            safe_label = TICKET.sub(
                lambda match: match[0] if match[1] in EXAMPLE_PREFIXES | STANDARD_PREFIXES else "<ticket>",
                safe_label,
            )
            print(f"{safe_label}:{line}: {category}", file=sys.stderr)
        if findings:
            print(f"Hygiene refused: {len(findings)} finding(s); matched values withheld.", file=sys.stderr)
            return 1
        print(f"Hygiene passed: {inputs} inputs; {'external private vocabulary enabled' if rules else 'generic checks only'}.")
        return 0
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        # Subprocess argv/errors may include a sensitive filename; never echo
        # command output or private-pattern text on parser failure.
        reason = str(error) if isinstance(error, ValueError) else type(error).__name__
        print(f"Hygiene could not complete: {reason}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
