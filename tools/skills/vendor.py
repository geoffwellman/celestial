#!/usr/bin/env python3
"""Third-party skills vendored into core/skills/ (every agent) or
core/workspace-skills/ (a `set` of skills a workspace opts into with
workspace.yaml `skill_sets:`), pinned in vendored-skills.yaml.

  vendor.py check                 offline: manifest, licences, committed-tree digests,
                                  fetched-file hashes, frontmatter
  vendor.py fetch [NAME...]       complete each skill's npm inputs (`cel setup` and
                                  `cel update` run this); files already present with
                                  their pinned sha256 are kept, so once done it needs
                                  no network
  vendor.py verify [NAME...]      network: rebuild each skill from its pins and compare
                                  byte for byte
  vendor.py sync NAME...          network: rebuild from the pins into the skill's
                                  directory and record the new digests in the manifest
  vendor.py names SKILL.md...     frontmatter every runtime accepts; one name per skill
  vendor.py description SKILL.md  print a skill's frontmatter description
  vendor.py set SET...            the skills in those sets, one per line (an
                                  unknown set is refused)
  vendor.py scoped                every skill in a set, one per line

COMMITTED: the upstream directory (`path` in `repo` at `commit`), each GitHub
`extra` (a file or directory from another pinned commit), then `patch` (a
unified diff applied with zero fuzz). `sha256` digests that tree: sha256 over
"<sha256 of file>  <relative path>\\n" for every regular file, sorted by path
bytes.

FETCHED AT INSTALL, NEVER COMMITTED (.gitignore): each npm `extra`. Its
tarball must match the sha512 `integrity` and every file its sha256 in
`files`, so the bytes are as pinned as the committed ones.
"""
import base64
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath

import yaml

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "vendored-skills.yaml"
SKILLS = ROOT / "core" / "skills"
WORKSPACE_SKILLS = ROOT / "core" / "workspace-skills"

LICENSES = {"MIT", "Apache-2.0"}
SHA1 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SRI = re.compile(r"^sha512-[A-Za-z0-9+/]{86}==$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
NPM = re.compile(r"^([a-z0-9][a-z0-9._-]*)@([0-9]+\.[0-9]+\.[0-9]+)$")
# Agent Skills spec, enforced by OpenCode and pi: lowercase words joined by
# single hyphens, at most 64 characters, equal to the skill's directory.
NAME = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
NAME_MAX, DESCRIPTION_MAX = 64, 1024
SKILL_KEYS = {"repo", "commit", "path", "license", "license_files", "extra", "patch", "set", "sha256"}
GIT_EXTRA_KEYS = {"repo", "commit", "path", "to", "license"}
NPM_EXTRA_KEYS = GIT_EXTRA_KEYS | {"npm", "integrity", "files"}


class Failure(Exception):
    pass


def relpath(value, what):
    if not isinstance(value, str) or not value:
        raise Failure(f"{what}: expected a relative path")
    p = PurePosixPath(value)
    if p.is_absolute() or ".." in p.parts:
        raise Failure(f"{what}: {value!r} must stay inside its root")
    return p


def load_manifest():
    data = yaml.safe_load(MANIFEST.read_text())
    if not isinstance(data, dict) or not isinstance(data.get("skills"), dict) or not data["skills"]:
        raise Failure(f"{MANIFEST.name}: expected a nonempty `skills:` mapping")
    for name, entry in data["skills"].items():
        validate_entry(name, entry)
    return data["skills"]


def validate_entry(name, entry):
    where = f"{MANIFEST.name}: {name}"
    if not isinstance(name, str) or not NAME.match(name) or len(name) > NAME_MAX:
        raise Failure(f"{where}: invalid skill name")
    if not isinstance(entry, dict) or set(entry) - SKILL_KEYS:
        raise Failure(f"{where}: unknown keys {sorted(set(entry) - SKILL_KEYS)}")
    for key in ("repo", "commit", "path", "license", "sha256"):
        if not isinstance(entry.get(key), str):
            raise Failure(f"{where}: `{key}` is required")
    if not REPO.match(entry["repo"]):
        raise Failure(f"{where}: repo must be owner/name")
    if not SHA1.match(entry["commit"]):
        raise Failure(f"{where}: commit must be a full 40-character SHA")
    relpath(entry["path"], f"{where}: path")
    if entry["license"] not in LICENSES:
        raise Failure(f"{where}: licence {entry['license']!r} is not one of {sorted(LICENSES)}")
    if not SHA256.match(entry["sha256"]):
        raise Failure(f"{where}: sha256 must be 64 hex characters")
    files = entry.get("license_files", [])
    if not isinstance(files, list):
        raise Failure(f"{where}: license_files must be a list")
    for f in files:
        relpath(f, f"{where}: license_files")
    if "patch" in entry and not (ROOT / relpath(entry["patch"], f"{where}: patch")).is_file():
        raise Failure(f"{where}: patch {entry['patch']} does not exist")
    # A workspace-scoped skill names its set; a workspace opts into sets.
    if "set" in entry and not (isinstance(entry["set"], str) and NAME.match(entry["set"])):
        raise Failure(f"{where}: set must be a lowercase-hyphenated set name")
    for i, extra in enumerate(entry.get("extra", [])):
        at = f"{where}: extra[{i}]"
        if not isinstance(extra, dict):
            raise Failure(f"{at}: expected a mapping")
        keys = NPM_EXTRA_KEYS if "npm" in extra else GIT_EXTRA_KEYS
        if set(extra) != keys:
            raise Failure(f"{at}: needs exactly {sorted(keys)}")
        if not REPO.match(extra["repo"]) or not SHA1.match(extra["commit"]):
            raise Failure(f"{at}: repo must be owner/name and commit a full 40-character SHA")
        if extra["license"] not in LICENSES:
            raise Failure(f"{at}: licence {extra['license']!r} is not one of {sorted(LICENSES)}")
        relpath(extra["path"], f"{at}: path")
        if extra["to"] != ".":
            relpath(extra["to"], f"{at}: to")
        if "npm" in extra:
            if not NPM.match(extra["npm"]) or not SRI.match(extra["integrity"]):
                raise Failure(f"{at}: npm must be name@x.y.z with a sha512 integrity")
            if not isinstance(extra["files"], dict) or not extra["files"]:
                raise Failure(f"{at}: files maps each fetched file to its sha256")
            for f, digest in extra["files"].items():
                relpath(f, f"{at}: files")
                if not isinstance(digest, str) or not SHA256.match(digest):
                    raise Failure(f"{at}: files: {f} needs a 64-hex sha256")


def npm_extras(entry):
    return [e for e in entry.get("extra", []) if "npm" in e]


def fetched(entry):
    """Skill-relative path -> pinned sha256 for every file fetched at install."""
    out = {}
    for extra in npm_extras(entry):
        for f, digest in extra["files"].items():
            out[(PurePosixPath(extra["to"]) / f).as_posix()] = digest
    return out


def skill_dir(name, entry):
    """core/workspace-skills/NAME for a skill in a set (linked only into the
    launches of workspaces that opt into it), core/skills/NAME for one every
    agent gets."""
    return (WORKSPACE_SKILLS if "set" in entry else SKILLS) / name


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def tree_files(root):
    out = {}
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root).as_posix()
        if p.is_symlink():
            raise Failure(f"{root.name}: {rel} is a symlink; vendored trees hold regular files only")
        if p.is_file():
            out[rel] = p
    return out


def digest(files):
    lines = "".join(f"{sha256(p)}  {rel}\n" for rel, p in sorted(files.items(), key=lambda kv: kv[0].encode()))
    return hashlib.sha256(lines.encode()).hexdigest()


def committed(root, entry):
    skip = fetched(entry)
    return {rel: p for rel, p in tree_files(root).items() if rel not in skip}


def frontmatter(skill_md):
    text = Path(skill_md).read_text()
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        raise Failure(f"{skill_md}: no YAML frontmatter")
    try:
        data = yaml.safe_load(m.group(1))
    except yaml.YAMLError as e:
        raise Failure(f"{skill_md}: frontmatter is not valid YAML ({e.__class__.__name__})") from None
    if not isinstance(data, dict):
        raise Failure(f"{skill_md}: frontmatter is not a mapping")
    return data


def check_names(paths):
    seen = {}
    for path in paths:
        path = Path(path)
        fm = frontmatter(path)
        name, desc, folder = fm.get("name"), fm.get("description"), path.parent.name
        if not isinstance(name, str) or not NAME.match(name) or len(name) > NAME_MAX:
            raise Failure(f"{path}: name {name!r} must be lowercase-hyphenated and at most {NAME_MAX} characters")
        if name != folder:
            raise Failure(f"{path}: name {name!r} differs from its directory {folder!r}")
        if not isinstance(desc, str) or not desc.strip() or len(desc) > DESCRIPTION_MAX:
            raise Failure(f"{path}: description must be 1-{DESCRIPTION_MAX} characters")
        if name in seen:
            raise Failure(f"{path}: name {name!r} is already used by {seen[name]}")
        seen[name] = path


def check():
    skills = load_manifest()
    absent = 0
    for name, entry in skills.items():
        d = skill_dir(name, entry)
        if not (d / "SKILL.md").is_file():
            raise Failure(f"{name}: {d.relative_to(ROOT)}/SKILL.md is missing")
        # The other tree must not hold it too: core/skills is linked into
        # every agent, so a scoped skill there would reach them all.
        other = (SKILLS if d.parent == WORKSPACE_SKILLS else WORKSPACE_SKILLS) / name
        if other.exists():
            raise Failure(f"{name}: also present as {other.relative_to(ROOT)}; it belongs in {d.parent.relative_to(ROOT)} only")
        for f in entry.get("license_files", []):
            if not (d / f).is_file() or not (d / f).stat().st_size:
                raise Failure(f"{name}: licence file {f} is missing")
        actual = digest(committed(d, entry))
        if actual != entry["sha256"]:
            raise Failure(f"{name}: tree digest {actual} does not match the manifest "
                          f"({entry['sha256']}); run `{Path(__file__).name} verify {name}` to see which file")
        for rel, want in fetched(entry).items():
            if not (d / rel).is_file():
                absent += 1
            elif sha256(d / rel) != want:
                raise Failure(f"{name}: fetched {rel} does not match its pinned sha256; rerun fetch")
        check_names([d / "SKILL.md"])
    note = f" ({absent} fetched file(s) not yet installed: run `{Path(__file__).name} fetch`)" if absent else ""
    print(f"ok: {len(skills)} vendored skills match {MANIFEST.name}{note}")


class Fetcher:
    def __init__(self):
        self.cache = {}

    def _get(self, url):
        if url not in self.cache:
            req = urllib.request.Request(url, headers={"User-Agent": "celestial-vendor"})
            with urllib.request.urlopen(req, timeout=120) as r:
                self.cache[url] = r.read()
        return self.cache[url]

    def github(self, repo, commit):
        """Files of the repository at commit, keyed by repository path."""
        data = self._get(f"https://codeload.github.com/{repo}/tar.gz/{commit}")
        return self._members(data, strip=1)

    def npm(self, spec, integrity):
        name, version = NPM.match(spec).groups()
        data = self._get(f"https://registry.npmjs.org/{name}/-/{name}-{version}.tgz")
        got = "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode()
        if got != integrity:
            raise Failure(f"{spec}: tarball integrity {got} does not match the pin {integrity}")
        return self._members(data, strip=0)

    @staticmethod
    def _members(data, strip):
        out = {}
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
            for m in tar.getmembers():
                parts = PurePosixPath(m.name).parts[strip:]
                if not parts:
                    continue
                rel = PurePosixPath(*parts).as_posix()
                if m.isfile():
                    out[rel] = (tar.extractfile(m).read(), bool(m.mode & 0o111))
                elif m.issym() or m.islnk():
                    out[rel] = None   # refused if selected
        return out


def _select(members, src, what):
    """{relative destination: (bytes, executable)} for file `src` or every file under it."""
    src = src.as_posix()
    hits = {k: v for k, v in members.items() if k == src or k.startswith(src + "/")}
    if not hits:
        raise Failure(f"{what}: {src} is not in the pinned tree")
    out = {}
    for key, value in hits.items():
        if value is None:
            raise Failure(f"{what}: {key} is a link; vendored trees hold regular files only")
        out["" if key == src else PurePosixPath(key).relative_to(src).as_posix()] = value
    return out


def _write(target, body, executable):
    """Atomic: a reader (or a concurrent `check`) never sees a partial file,
    and the temporary is a dotfile in core/skills/ (or core/workspace-skills/),
    outside every skill's tree."""
    target.parent.mkdir(parents=True, exist_ok=True)
    root = next((r for r in (SKILLS, WORKSPACE_SKILLS) if target.is_relative_to(r)), target.parent)
    fd, tmp = tempfile.mkstemp(prefix=".vendor-", dir=root)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(body)
        os.chmod(tmp, 0o755 if executable else 0o644)
        os.replace(tmp, target)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def _place(selected, dest):
    for rel, (body, executable) in selected.items():
        _write(dest / rel if rel else dest, body, executable)


def npm_files(extra, fetcher, what, repin=False):
    """Skill-relative path -> (bytes, executable), each checked against its
    pinned sha256 unless `sync` is recording new pins."""
    members = fetcher.npm(extra["npm"], extra["integrity"])
    out = {}
    for f, want in extra["files"].items():
        body, executable = _select(members, PurePosixPath(extra["path"]) / f, what)[""]
        got = hashlib.sha256(body).hexdigest()
        if got != want and not repin:
            raise Failure(f"{what}: {extra['npm']} {f} is {got}, pinned {want}")
        out[(PurePosixPath(extra["to"]) / f).as_posix()] = (body, executable)
    return out


def build(name, entry, fetcher, out, repin=False):
    """The skill exactly as its pins produce it, fetched npm files included."""
    out.mkdir(parents=True)
    _place(_select(fetcher.github(entry["repo"], entry["commit"]), PurePosixPath(entry["path"]), name), out)
    for extra in entry.get("extra", []):
        if "npm" not in extra:
            members = fetcher.github(extra["repo"], extra["commit"])
            _place(_select(members, PurePosixPath(extra["path"]), name), out / extra["to"])
    if "patch" in entry:
        subprocess.run(["patch", "-p1", "--batch", "--forward", "--fuzz=0", "--no-backup-if-mismatch",
                        "--reject-file=-", "--silent", "-d", str(out), "-i", str(ROOT / entry["patch"])],
                       check=True)
    for extra in npm_extras(entry):
        for rel, (body, executable) in npm_files(extra, fetcher, name, repin).items():
            _write(out / rel, body, executable)
    return out


def fetch(names):
    skills = load_manifest()
    fetcher = Fetcher()
    for name in names or skills:
        entry = skills[name]
        d = skill_dir(name, entry)
        pins = fetched(entry)
        if not pins:
            continue
        missing = [rel for rel, want in pins.items() if not (d / rel).is_file() or sha256(d / rel) != want]
        if not missing:
            print(f"present {name}: {len(pins)} fetched file(s) match their pins")
            continue
        for extra in npm_extras(entry):
            for rel, (body, executable) in npm_files(extra, fetcher, name).items():
                _write(d / rel, body, executable)
        print(f"fetched {name}: {len(missing)} file(s) from {', '.join(e['npm'] for e in npm_extras(entry))}")


def verify(names):
    skills = load_manifest()
    bad = 0
    fetcher = Fetcher()
    with tempfile.TemporaryDirectory() as tmp:
        for name in names or skills:
            entry = skills[name]
            built = build(name, entry, fetcher, Path(tmp) / name)
            want, have = committed(built, entry), committed(skill_dir(name, entry), entry)
            problems = [f"missing {r}" for r in sorted(set(want) - set(have))]
            problems += [f"not upstream {r}" for r in sorted(set(have) - set(want))]
            problems += [f"differs {r}" for r in sorted(set(want) & set(have))
                         if want[r].read_bytes() != have[r].read_bytes()]
            for rel in fetched(entry):
                local = skill_dir(name, entry) / rel
                if local.is_file() and local.read_bytes() != (built / rel).read_bytes():
                    problems.append(f"fetched copy differs {rel}")
            tree = digest(want)
            if tree != entry["sha256"]:
                problems.append(f"pinned build digest {tree} != manifest {entry['sha256']}")
            if problems:
                bad += 1
                print(f"FAIL {name}: " + "; ".join(problems))
            else:
                extra = f" + {len(fetched(entry))} fetched" if fetched(entry) else ""
                print(f"ok   {name}: {entry['repo']}/{entry['path']}@{entry['commit'][:12]} "
                      f"({len(want)} committed{extra} files, sha256 {tree[:16]})")
    if bad:
        raise Failure(f"{bad} vendored skill(s) differ from their pins")


def _block(text, name):
    m = re.search(rf"^  {re.escape(name)}:\n", text, re.M)
    if not m:
        raise Failure(f"{name}: no block in {MANIFEST.name}")
    end = re.compile(r"^  [^\s#]", re.M).search(text, m.end())
    return m.start(), end.start() if end else len(text)


def _set_hash(block, key, value, name):
    new, n = re.subn(rf"^(\s+{re.escape(key)}: )[0-9a-f]{{64}}$", rf"\g<1>{value}", block, flags=re.M)
    if n != 1:
        raise Failure(f"{name}: expected one `{key}:` hash in its {MANIFEST.name} block")
    return new


def sync(names):
    if not names:
        raise Failure("name the skills to sync")
    skills = load_manifest()
    text = MANIFEST.read_text()
    fetcher = Fetcher()
    with tempfile.TemporaryDirectory() as tmp:
        for name in names:
            entry = skills[name]
            built = build(name, entry, fetcher, Path(tmp) / name, repin=True)
            dest = skill_dir(name, entry)
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(built, dest)
            start, end = _block(text, name)
            block = _set_hash(text[start:end], "sha256", digest(committed(dest, entry)), name)
            for extra in npm_extras(entry):
                for f in extra["files"]:
                    block = _set_hash(block, f, sha256(dest / extra["to"] / f), name)
            text = text[:start] + block + text[end:]
            print(f"synced {name}: sha256 {digest(committed(dest, entry))}")
    MANIFEST.write_text(text)


def main(argv):
    cmd, args = (argv[0], argv[1:]) if argv else ("", [])
    try:
        if cmd == "check" and not args:
            check()
        elif cmd == "fetch":
            fetch(args)
        elif cmd == "verify":
            verify(args)
        elif cmd == "sync":
            sync(args)
        elif cmd == "names" and args:
            check_names(args)
        elif cmd == "description" and len(args) == 1:
            print(frontmatter(args[0]).get("description", ""))
        elif cmd == "set" and args:
            skills = load_manifest()
            known = {e["set"] for e in skills.values() if "set" in e}
            unknown = [s for s in args if s not in known]
            if unknown:
                raise Failure(f"no skill set {', '.join(unknown)} (sets: {', '.join(sorted(known))})")
            for name, entry in skills.items():
                if entry.get("set") in args:
                    print(name)
        elif cmd == "scoped" and not args:
            for name, entry in load_manifest().items():
                if "set" in entry:
                    print(name)
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Failure as e:
        print(f"vendor.py: {e}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError:
        print("vendor.py: a patch no longer applies to its pinned upstream file", file=sys.stderr)
        return 1
    except OSError as e:   # network or filesystem: say which, keep the traceback out
        print(f"vendor.py: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
