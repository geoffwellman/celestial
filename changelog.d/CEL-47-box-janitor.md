### Added
- **The box is a resource the factory spends: measure it, then sweep it.** The
  plane measured its machines and never its floor space, so the first symptom
  of a full disk was a build failing rather than a dashboard going amber, and
  the only remedy anyone had was a human remembering to run `docker system
  prune` by hand — the word "docker" appeared nowhere in the tree, while
  Docker alone held ~74G of a box at 144G of 193G. **`cel box space`** now
  prints one measured table of what is large, what of it is reclaimable and
  which of three classes it is in — **ours** (`~/.cache/cel`, scratch),
  **regenerable** (docker images, build cache, bun/npm/uv/pip caches and
  browser drivers) and **someone's** (restore dumps, dated backups) — sorted
  by reclaimable bytes rather than total, because a 15G dump nobody may touch
  is less interesting than 8.7G of build cache. Every number is measured, not
  remembered: there is no cache file. `--json` emits a frozen
  `{paths:[{path,class,bytes,reclaimable,age_days}],docker:{…}}`. **`cel gc
  --box`** runs the sweepers after the existing worktree pass (a freed
  worktree may be the last reference to a cache entry), on fourteen days for
  docker images and build cache — the working set is three to six days old and
  superseded build tags are two weeks and older — with exited containers taken
  with no age filter and base images exempt regardless of age. The rule the
  whole feature encodes: **a sweeper may delete only what the box can make
  again.** Class-three paths are never swept by any flag; they are a number on
  a report with an age and a suggestion. No sweeper takes a path from argv —
  each reads a declared policy table — and `--dry-run` covers the new work
  exactly as it covers the old, with no "prune and report" path. `cel gc` is
  unchanged by default, its summary line gains freed bytes per class, and a
  class that found nothing says so rather than vanishing. The steward sweeps
  on a six-hour cadence and records the bytes it has freed; `cel doctor` warns
  below a free-space floor, naming the largest reclaimable class and the
  command that clears it.
