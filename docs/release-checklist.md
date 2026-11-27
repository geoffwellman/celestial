# Public release checklist

## Cutting a version

One verb, and the rest follows. From a workspace that declares the celestial
repository:

```
cel release celestial 0.3.0 --dry-run   # the plan and the pending notes; dispatches nothing
cel release celestial 0.3.0             # dispatches the Release workflow
cel release status celestial            # current version, commits since, newest Release, run in flight
```

On a terminal the dispatch follows the run to its conclusion and names the
Release it cut; in a script, or with `--no-follow`, it returns after the
dispatch (`--follow` forces following). Where celestial is the only repo in the
workspace declaring a `release:` block, the short form `cel release 0.3.0`
means exactly this; see ["Releasing a product"](../README.md#releasing-a-product)
for the declaration the verb reads. Under `cel afk` a release is dispatched
only if AFK admits it.

Or run the **Release** workflow from the Actions tab with the same version.
Its `verify` job first runs the same checks as every pull request (the reused
CI workflow: suite and hygiene scans); the `cut` job then rewrites `VERSION`,
renames `## [Unreleased]` to `## [<version>] - <date>` with a fresh empty
`[Unreleased]` above it, folds in and removes the `changelog.d/` fragments, and
opens a ready-for-review `release: v<version>` pull request with the section as
its body. **Merge that PR** - main takes no direct pushes, so the bump is a
reviewed change like any other. When its squash lands on main, the `publish`
job creates the annotated `v<version>` tag and the GitHub Release, with the
CHANGELOG section as their notes; boxes on the `release` channel see it on
their next `cel update --check`. A `v*` tag pushed by hand publishes the same
way, and a tag or commit whose version disagrees with `VERSION` fails the job.

Everything below is publication hygiene - the one-time question of whether
this repository may be public at all, not the per-version one.

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
python3 tools/release/hygiene.py --history origin/main..HEAD
python3 tools/release/hygiene.py --require-private-patterns \
  --private-patterns /secure/path/private-patterns.txt
```

`--history REVS` also scans the commits `git rev-list REVS` names (CI uses the
pull request's own `base..head` ancestry); `--all-history` scans every local
ref, commit and tag. The external file (or `CEL_PRIVATE_PATTERNS_FILE`)
contains one case-insensitive Python regular expression per line; blank lines
and `#` comments are ignored, and a pattern that matches the empty string is
refused. It must be outside the source root and, with
`--require-private-patterns`, contain at least one pattern. Scan findings
report categories and redacted locations, not matched credential values. Exit 0
means no detected findings, 1 means findings, and 2 means the scan could not
complete.

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
- Verify the upgrade path from a **second clone**, never the working checkout:
  `cel update --check` shows the new version and the changelog sections it
  brings, `cel update` lands it, and `cel doctor` comes back green.
- Verify the original archive remains private. Tell collaborators which clone
  and remote to use, and warn against pushing historical branches/tags.

For later releases, apply the same source/history/hosted checks to every new
commit and ref. A new release is not permission to bring old private history
back into the public repository.
