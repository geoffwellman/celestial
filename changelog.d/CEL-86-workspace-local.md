### Added
- `workspace.local.yaml`, gitignored, overrides `role_profiles` and adds (or,
  by name, wholly replaces) a `worker_profiles` entry, per box, without
  touching the shared `workspace.yaml`. Local always wins; `cel profiles`
  marks a binding or profile sourced from it with `(local)`; `cel doctor`
  warns on anything else the file declares, since the merge otherwise drops
  it silently (external contribution).
- Team workspaces (CEL-86): `workspace.local.yaml` may also override `env:`
  keys per box; everything else (policy, tickets, repos, gates, merge and
  review settings) stays team-only, and the rendered policy block always comes
  from the committed `workspace.yaml`. `cel ws new` writes a commented
  `workspace.local.example.yaml` and ignores `*.local.*`; `cel ws sync` adds a
  missing ignore rule. `cel doctor` says whether a local file is in effect and
  what it overrides, and fails when `workspace.yaml` is untracked or
  gitignored. A test fails if any code reads `role_profiles`/`worker_profiles`
  from `workspace.yaml` around the merge.
