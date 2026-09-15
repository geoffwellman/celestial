# Contributing

Use issues for reproducible bugs and scoped proposals. For security issues,
follow [SECURITY.md](SECURITY.md) instead of opening a public report.

## Development

Work on GNU/Linux with Bash, Git, GNU coreutils, Python 3, jq, Python yq and
Node 24.x. You do not need provider credentials or a running agent fleet for
the test suite. Do not run `cel setup` merely to test a patch: it installs
third-party tools into your real user environment.

```sh
bash tests/run.sh
node --test tests/http-server.test.mjs
python3 tools/release/hygiene.py
```

The shell runner accepts a test-name filter, for example:

```sh
bash tests/run.sh gc_
node --test tests/http-server.test.mjs
```

Tests use temporary Git repositories, isolated state roots and executable
fixtures for external CLIs. Preserve that isolation. Never point a regression
fixture at a real workspace, provider account, private page store or live fleet.

## Changes

- Keep mechanisms in `lib/` or the existing tool; keep workspace-specific
  policy and content in the workspace, not in the plane.
- For a bug, show the original observable failure and that the same scenario
  succeeds after the fix. Retain a regression test when it catches a plausible
  recurrence. Do not replace unknown or failed safety checks with success.
- For UI changes, exercise the real browser surface as well as affected HTTP
  behavior. Do not claim browser verification from string inspection alone.
- Review every caller of a changed shell/API contract, including failure paths
  and commands invoked inside `if`/`||` contexts where Bash errexit differs.
- Dependency changes must identify an exact release/commit, verify published
  checksums where used, and exercise failure propagation without installing
  into another contributor's machine state.
- Update affected usage documentation and `CHANGELOG.md`. Describe verification
  and any remaining limits in the pull request. Keep unrelated cleanup out.

Use fictional names and domains such as `example.invalid`. Do not submit real
workspace names, organisation identifiers, ticket keys, machine paths, session
logs, credentials or a private release denylist, even as test fixtures. Do not
paste an unredacted failing request or environment dump into an issue.

Public CI scans Git history as well as current source. Run the local checks
before committing. If sensitive content was committed or posted, stop and
report privately; deleting the current line or force-pushing is not proof that
all hosted copies disappeared. See the [release checklist](docs/release-checklist.md).

By contributing, you confirm you have permission to submit the change under
this repository's MIT licence. Preserve existing copyright and third-party
attribution.
