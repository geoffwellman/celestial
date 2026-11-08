### Added
- The guard refuses every role (core, root, orchestrator, solo, member, reviewer, and panes outside any workspace) a forge review verdict: `gh pr review` with `--approve`/`-a`/`--request-changes`/`-r` (also after the PR, as `--approve=...` or in a short group), a `gh api` write to `.../pulls/<n>/reviews` or below it (events, dismissals; through `repos/<o>/<r>/` or `repositories/<id>/`), a graphql add/submit/dismiss of a `PullRequestReview` or a graphql call whose query it cannot read (`--input`, a `@file` field, an expansion), curl writing there on a forge API, and `tea pr approve|lgtm|reject|review` (any prefix, so `tea pr r`) or `tea api` writing there. Paths are read percent-decoded, case-folded and without a `#fragment`, and a line with a newline is read both as separate commands and joined. The refusal names `cel solo review`. Comments (`gh pr review --comment`, `gh pr comment`) stay allowed where they were.
- The guard refuses every role `gh alias set|import|delete`: an alias hides from the guard what a later `gh` command runs.
- `cel doctor` warns a workspace that still sets `review.post`: it no longer posts verdicts.

### Changed
- Whether `CEL_GUARD_ALLOW_ONCE=1` is honoured is decided once, in `guard_override_honoured` (lib/guard.sh), for the claude, omp/pi and OpenCode adapters alike. It never covers a forge verdict, a gh alias write or a team member, must be spelled exactly (`=11` is not it), and is not offered in a refusal that rules it out.
- The guard's command normaliser strips wrappers given by path (`/usr/bin/env`) and with options that take a value (`env -u X`, `env -C d`, `xargs -n 1`, `xargs -I {}`, `sudo -u u`, `timeout -s SIG`, `nice -n N`, `stdbuf`, `setsid`), for every rule.
- An adapter whose classifier cannot run (the claude hook without its library or jq, omp/pi on an error or timeout, OpenCode on the classifier's own exit 2) still fails open for a non-member, but refuses a shell command that looks like a forge review verdict.
- The reviewer role and the rendered workspace policy say an agent's verdict is recorded with `cel solo review` and never posted to the forge; `review.post: github` no longer changes either.

### Fixed
- The OpenCode adapter honoured `CEL_GUARD_ALLOW_ONCE=1` in a team member's pane, unlike the claude and omp adapters (spec C6).
- `gh pr review --approve` was allowed to orchestrators, root, core and solo agents, so an agent could post an approval that `cel solo land` counts as review (spec C3).

### Removed
- `ws_review_post` and the `review.post: github` posting path: no agent posts a review verdict to a forge.
