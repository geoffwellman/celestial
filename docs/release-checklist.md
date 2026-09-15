# Public release checklist

A clean working tree does not establish that an existing private repository is
safe to make public. Tags, unreachable-from-main branches, pull-request refs,
commit authors/messages, discussions, workflow logs and release assets are
separate publication surfaces.

## Rights and scope

- Confirm ownership and permission to publish under MIT, including any employer
  or client obligations. Preserve authorship, licences and required attribution.
- Decide whether to publish existing history or a clean snapshot. If retained
  private history/discussions cannot be safely cleared and verified, preserve
  the original privately and create a new repository from reviewed source.
  Do not merely delete one file and force-push.
- Keep the sensitive vocabulary used for the review **outside** the repository.
  It is itself private information and must not become a committed denylist.

## Source and behavior

- Inspect filenames, source, tests, documentation, generated files and
  configuration examples. Replace identifying incidents with general rules and
  synthetic fixtures. Keep credentials and machine state out of Git.
- Run `bash tests/run.sh` and `node --test tests/http-server.test.mjs`; verify
  changed CLI/browser behavior against isolated real runtimes. Record failures
  honestly and resolve regressions.
- Review public documentation, installation pins, error handling, supported
  platforms and security reporting instructions.
- Stage the intended publication files. The current-source scanner uses
  `git ls-files`; new untracked files are not scanned until they are staged.

```sh
python3 tools/release/hygiene.py
python3 tools/release/hygiene.py --require-private-patterns \
  --private-patterns /secure/path/private-patterns.txt
```

The external file contains one case-insensitive Python regular expression per
line; blank lines and `#` comments are ignored. It must be outside the source
root and contain at least one pattern. Scan findings report categories and
redacted locations, not matched credential values. Exit 0 means no detected
findings, 1 means findings, and 2 means the scan could not complete.

## Clean-history publication

For the clean-snapshot route, export only reviewed tracked files into a new,
empty directory, initialise a fresh Git repository, and create a new root
commit using an appropriate public author identity. Do not copy `.git`, old
tags, remote refs, local state or ignored/untracked files. Verify the exported
file manifest and executable modes against the reviewed source.

Run the full suite again from the clean checkout. Then inspect everything
reachable from every ref, not just `main`:

```sh
python3 tools/release/hygiene.py --all-history --require-private-patterns \
  --private-patterns /secure/path/private-patterns.txt
gitleaks git --redact --log-opts="--all" .
```

Use the checksum-pinned Gitleaks release in `.github/workflows/ci.yml`, or verify
an intentionally updated release's published checksum first. Generic public CI
cannot know private project vocabulary. Neither scanner replaces human review.

Create the replacement repository **private first** and push only the clean
branch. If reusing the old public-facing name, rename the original private
repository first and update every old clone's remote to that private archive
before creating the replacement. Otherwise an old clone can accidentally push
private refs to the new destination. Never push old tags or use `--mirror`.

## Hosted gate

- Confirm the new repository is private, its exact default-branch SHA matches
  the reviewed snapshot, and only intended refs exist. Inspect hosted files,
  commit metadata, releases/assets, issues, PRs, discussions and Actions output.
- Confirm CI actually ran and succeeded for that exact SHA, not an earlier head.
- Configure available branch protection, vulnerability reporting and security
  scanning. Some GitHub security/protection features depend on repository
  visibility and account plan; verify actual settings rather than assuming.
- Reconfirm permission to publish and that every required check is complete.
  Only then change visibility. Immediately verify the public repository and
  enable/verify any security settings unavailable while it was private.
- Create a release tag pointing only to reviewed clean history; verify its
  target and release notes. Do not recreate private historical tags.
- Verify the original archive remains private. Tell collaborators which clone
  and remote to use, and warn against pushing historical branches/tags.

For later releases, apply the same source/history/hosted checks to every new
commit and ref. A new release is not permission to bring old private history
back into the public repository.
