# Releasing a product

The plane runs a factory, so it can cut a release of the things the factory
makes — and releasing celestial itself is one ordinary instance of that, not
the only meaning. It owns no versioning semantics: a repo declares how it is
released in `workspace.yaml`, and `cel release` knows which workflow,
dispatches it, follows it and reports what came out.

```yaml
repos:
  - name: gizmo
    release:
      workflow: release.yaml          # file name in .github/workflows/
      input: bump                     # the dispatch input's NAME; its value is
                                      # the command's second argument
      accepts: [major, minor, patch]  # optional: the only allowed values
      tag: "v{version}"               # optional: how the resulting tag is named
  - name: widget
    release:
      workflow: release.yml
      input: version
      accepts: semver                 # the literal word: any x.y.z
      version_file: VERSION           # optional: what `status` reads as "current"
      changelog: changelog.d/         # optional: fragments, for --dry-run
```

```
cel release <product> <version|bump>     # dispatch it
cel release <product> <value> --repo <r> # when a product has two releasable repos
cel release <product> <value> --dry-run  # the plan and the pending notes; dispatches nothing
cel release status [<product>] [--all-workspaces] [--json]
```

A product is one or more repos; exactly one of them may declare a `release:`
block, or you name it with `--repo`. A repo with no block is not releasable
and says so. **Before anything is spent** the command checks, in order, that
the repo is releasable, that the value is one the workflow accepts (a listed
word, or semver and greater than the current version), that `gh` is there,
and that *you may dispatch it* — `gh repo view --json viewerPermission` must
say `WRITE`, `MAINTAIN` or `ADMIN`. Otherwise it refuses locally and tells you
where that product's releases come from, because the previous version of this
command passed every local check for anyone who was not the maintainer and
then took a 403 from GitHub at the last step, looking like it should have
worked. On a TTY the run is followed to its conclusion and the resulting tag
and Release URL are printed (`--follow` / `--no-follow` override that); with
AFK on, AFK must admit the dispatch. `cel release status` gives one row per
releasable repo: current version, commits since that tag, any run in flight,
the newest Release.

Celestial's own workspace declares exactly this block for celestial
(`workflow: release.yml`, `input: version`, `accepts: semver`, `version_file:
VERSION`, `changelog: changelog.d/`, `tag: "v{version}"`), which is why
`cel release celestial 0.3.0` and — in a workspace where it is the only
releasable repo — the short `cel release 0.3.0` both do what they always did.

The pieces celestial uses on itself are ordinary, documented and reusable by
any repo that wants that shape: [`tools/release/cut.py`](../tools/release/cut.py)
rewrites `VERSION` and assembles `changelog.d/` fragments into a dated
section, [`tools/release/notes.py`](../tools/release/notes.py) prints one
section (including the pending one) without touching the tree, and
[`.github/workflows/release.yml`](../.github/workflows/release.yml) is the
worked example of wiring them into a `workflow_dispatch` that opens the bump
PR and publishes the Release from the tag. Copy that shape, or declare
whatever workflow you already have — the plane only needs to be told its name
and its input.
