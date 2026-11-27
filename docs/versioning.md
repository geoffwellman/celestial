# Versioning & updates

Celestial follows [semver](https://semver.org); `VERSION` + `v*` tags are the
truth and every release is announced on
[GitHub Releases](https://github.com/geoffwellman/celestial/releases) with
notes from [CHANGELOG.md](../CHANGELOG.md) — **Watch → Custom → Releases** to get
notified. On the box, `cel version` tells you what you're running as
`celestial v0.5.0+31 (d43910c, main)`: the nearest tag, **the commits since
it**, the sha and the branch — the `+31` is the part people quote, because a
version alone says v0.5.0 for thirty-odd merges.

Cutting a version of celestial is the same verb every other product gets
([Releasing a product](releasing.md)): `cel release celestial <x.y.z>`, or
**Run workflow** on the Release workflow in the Actions tab, whose `cut` job is
"Open the version bump PR". It opens a reviewed `release: v<x.y.z>` pull
request, and merging it tags `v<x.y.z>` and publishes the Release; the
[release checklist](release-checklist.md#cutting-a-version) has the full
sequence. A change
worth a changelog line adds its own `changelog.d/<branch>.md` — first line the
category heading (`### Added`, `### Changed`, `### Fixed`, `### Removed`), the
rest the entry — and the cut assembles those fragments into the section and
deletes them, so two open pull requests never edit the same `CHANGELOG.md` line.

A box follows one of two **channels**, set in `~/.local/share/cel/config.yaml`
(box-level, created 0600) and switched with `cel update --channel
main|release`:

```yaml
update:
  channel: release      # release (default) | main
```

On `release` — the default, and what you want unless you are working on the
plane itself — `cel doctor`, the steward and `cel update --check` compare you
to the newest release tag and `cel update` lands on it. On `main` they compare
you to `origin/main`: `--check` names how many commits are ahead of your
build, lists their subjects oldest first and the `[Unreleased]` notes you
haven't got, and `cel update` fast-forwards to main's tip. Both channels
refuse to touch a dirty tree or one that is off `main`, record where they came
from, and undo with `cel update --rollback`.

`cel update` also brings every installed coding agent up to date with the
updater `agents.yaml` names ([Runtimes](runtimes.md#runtimes)), Pi extensions to their
pins, and npm tools and gateway registrations, unless `--skip-agents` is
given; `--components` runs only that step. An agent named in the box
config's `update.hold` (or `CEL_UPDATE_HOLD`) is reported and left alone, an
updater that "succeeds" while still behind counts as a failure, and the old
version is recorded for `--rollback`. `--check --agents` compares installed
agents with their latest releases. `--restart-orchestrators` restarts the
idle orchestrators still on an older launch line, resumed. The steward checks
once a day and tells you when a release (or new main commits) is waiting; it
never updates Celestial itself.
