### Added
- The guard refuses every role (core, root, orchestrator, solo, member, reviewer, and panes outside any workspace) a forge review verdict: `gh pr review` with `--approve`/`-a`/`--request-changes`/`-r` (also after the PR, as `--approve=...` or in a short group), a `gh api` write to `repos/<o>/<r>/pulls/<n>/reviews` or below it (events, dismissals) or a graphql add/submit/dismiss of a `PullRequestReview`, curl writing there on a forge API, and `tea pr approve|lgtm|reject|review` or `tea api` writing there. The refusal names `cel solo review`. Comments (`gh pr review --comment`, `gh pr comment`) stay allowed where they were.

### Changed
- Whether `CEL_GUARD_ALLOW_ONCE=1` is honoured is decided once, in `guard_override_honoured` (lib/guard.sh), for the claude, omp/pi and OpenCode adapters alike. It never covers a forge verdict or a team member, must be spelled exactly (`=11` is not it), and is not offered in a refusal that rules it out.

### Fixed
- The OpenCode adapter honoured `CEL_GUARD_ALLOW_ONCE=1` in a team member's pane, unlike the claude and omp adapters (spec C6).
- `gh pr review --approve` was allowed to orchestrators, root, core and solo agents, so an agent could post an approval that `cel solo land` counts as review (spec C3).

### Removed
