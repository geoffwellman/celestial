### Fixed
- `cel release --follow` now follows the run its own dispatch created (the run gh names, or the one new `workflow_dispatch` run by this account) instead of whichever run was listed first, and reports the release that run cut instead of the newest release.
- `cel release` reads the current version through the whole declared tag shape, so a template with text after `{version}` (e.g. `release-{version}-prod`) no longer switches off the "must be greater" check; a tag of another shape no longer counts as the current version.
- The AFK log now records how an act ended: thread resolution, rebase-retry and release write one entry after the effect with `completed`, `failed` or `partial`, and acts still recorded at authorisation say `authorised`. `cel afk log` shows the outcome.
- AFK state is replaced atomically on `cel afk on`/`off`, and AFK log appends are serialised by a lock.
- A steward tick that cannot take the tick lock within 5s now exits instead of claiming the tick without it.
- `cel doctor` no longer divides by zero or fails on a fractional `CEL_DOCTOR_FORK_SECS`; anything but a whole number of seconds falls back to the 2s sample with a warning.
- `cel learn` treats an impossible date (e.g. `2026-99-99`) as invalid rather than ancient: the entry is never stale, `stow` keeps it, and `list` shows the invalid date.
