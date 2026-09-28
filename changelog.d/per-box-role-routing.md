### Added
- `workspace.local.yaml`, gitignored, overrides `role_profiles` and adds (or,
  by name, wholly replaces) a `worker_profiles` entry, per box, without
  touching the shared `workspace.yaml`. Local always wins; `cel profiles`
  marks a binding or profile sourced from it with `(local)`; `cel doctor`
  warns on anything else the file declares, since the merge otherwise drops
  it silently (external contribution).
