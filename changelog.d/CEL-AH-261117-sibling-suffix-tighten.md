### Fixed
- An unledgered server's owner: a dir beside a repo is the repo's only when its known suffix (`-wt`, `-worktrees`, `-local`, `-data`, `-release`) stands alone or is followed by a dash, so `app-database` and `app-releasenotes` are no longer claimed by repo `app`.
- `cel doctor` also warns about `owns_paths` globs that claim all of home, root or the workspace through a leading star (`~/*`, `~/**`, `/*`, `/**`, a relative `*`).
