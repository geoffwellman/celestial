# Docker image retention and producer ownership

`cel box docker-safety` returns the version-1 JSON consumer contract, including
the resolved `keep_file`, `keep_dir`, `lock_file`, and `keep_label` (`cel.keep=true`).
`cel box sweep-docker [--dry-run]` runs only the Docker sweep, prints a byte
count (an upper bound in dry runs), and exits nonzero on unknown observations
or mutation failure; exit 2 means Docker is unavailable. No image/system,
container or volume prune is used; build cache is cleared by
`docker builder prune --all --force` as its own step of the same sweep.

For recurring 20 GiB recovery, reviewed runtime/handler pins, producer observations,
native notification verification and transactional service migration, see the
[disk headroom controller runbook](disk-headroom.md). A low-disk reading
never expands cleanup eligibility or turns a producer candidate into a grant.

An image survives if **any tag** matches a keep pattern, its image label is
`cel.keep=true`, or any running/stopped container references its actual full
image ID. Labels protect containerless bases too. Built-ins retain `ubuntu:*`,
`alpine:*`, and `slot-studio-media-executor-base:*` (all immutable source tags).
The executor namespace `slot-studio-local/media-executor:*` is conservatively
retained unless the reserved producer-owned `keep_dir/slot-studio-executors.patterns`
contains validated, nonempty executor declarations. This file opts into bounded
cleanup and MUST represent the **COMPLETE live + rollback + in-flight image set**.
Legacy/global declarations and arbitrary producer files cannot enable narrowing,
even if they contain executor references. A missing, empty or unrelated-only
reserved file preserves the blanket; malformed/unreadable files refuse mutation.
Once opted in, exact live, rollback and in-flight tags allow superseded unused
executors to be swept; labels and actual container references remain vetoes.
Other image families retain their existing policy.

The operator-owned legacy `keep_file` defaults to
`${XDG_CONFIG_HOME:-$HOME/.config}/cel/docker-keep-patterns`. Each producer owns
one file, e.g. `other-producer.patterns`, inside `keep_dir`, defaulting to
`${XDG_CONFIG_HOME:-$HOME/.config}/cel/docker-keep-patterns.d`. **All files are
unioned with the legacy file and built-ins. Never replace another producer's
file or the global operator file.** Each selected `*.patterns` file contains
newline-delimited `repository:tag` shell globs (`*`, `?`, bracket sets/ranges);
blank lines and lines starting `#` are ignored. Patterns are data, never shell
code or filesystem expansions. Temporary files must not end in `.patterns`.
`CEL_BOX_DOCKER_KEEP_FILE` and `CEL_BOX_DOCKER_KEEP_DIR` select explicit paths;
missing explicit paths, unreadable/malformed declarations, selected symlinks
(including ancestors), failed inventory, unknown labels/tags, or failed
container inspection refuse all Docker mutation. Absent default paths are
allowed; absent executor ownership preserves the whole executor namespace.

**Producers must share the ownership lock**, including builds, image import,
tag moves and keep-file replacement. The sweep never waits for the lock: if a
producer holds it, nothing is touched and it exits 1. Holding it, the sweep
rechecks references/retention immediately before each mutation; an active
local Docker build also vetoes the sweep. Docker has no atomic compare-and-delete tag API:
the lock contract is required, not protection against uncoordinated tag writers
or remote clients starting builds. Use the `lock_file` reported above (default
`${XDG_STATE_HOME:-$HOME/.local/state}/cel/docker-images.lock`):

```bash
lock="${XDG_STATE_HOME:-$HOME/.local/state}/cel/docker-images.lock"
keep_dir="${XDG_CONFIG_HOME:-$HOME/.config}/cel/docker-keep-patterns.d"
mkdir -p "${lock%/*}" "$keep_dir"
(
  set -e
  flock -x 9
  # The sole executor producer publishes its COMPLETE set before building.
  # Retain every required live/rollback/in-flight tag, not just these examples.
  tmp="$(mktemp "$keep_dir/.executors.XXXXXX")"
  printf '%s\n' 'slot-studio-local/media-executor:current-42' \
    'slot-studio-local/media-executor:rollback-41' \
    'slot-studio-local/media-executor:candidate-43' > "$tmp"
  chmod 600 "$tmp"
  mv -T -- "$tmp" "$keep_dir/slot-studio-executors.patterns"
  # Pre-admission precedes image creation and deployment; keep the shared lock.
  docker build -t slot-studio-local/media-executor:candidate-43 .
) 9>>"$lock"
```

Alternatively put `LABEL cel.keep=true` in the producer's Dockerfile. Existing
images cannot be relabelled in place: declare their tags in the keep file
before publishing/moving tags, or rebuild with the label under the lock.

Migration: keep the legacy global declarations and emergency fallback intact
until the executor publisher pre-admits each candidate **before build/deploy**,
publishes the COMPLETE live/rollback/in-flight set atomically, and has tested
the shared-lock contract. Only then create `slot-studio-executors.patterns`.
Do not bootstrap this opt-in from the old post-healthy-deploy global snapshot:
it can omit an already-building candidate. Under the same lock, remove only
producer-owned entries from the global file without discarding operator or
other-producer protections. A legacy executor wildcard remains a veto until
explicitly removed by the operator. Retain required rollback and pending
candidates until their ownership is genuinely retired, including failed or
unresolved deployments. Follow-main worktree candidates are observations, not
image keep declarations or cleanup grants. The receiver cannot infer omitted
required images from a syntactically valid set: completeness is the producer's
admission contract. `keep_dir` is additive to contract v1; existing `keep_file`
consumers remain compatible.
