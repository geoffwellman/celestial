---
name: pr-loop
description: Shepherd open PRs all the way in — request the review, fix what it asks for, keep checks green, land them once approved. Run under /loop.
---
One tick, one pass over every open PR of mine. `pr-state.sh` decides; this says what each
decision means. Read the state before acting, every tick — a PR moves between ticks.

Where this runs
This loop is a long-lived session of its own, and the workspace layout reserves it a home: the
pane labelled `pr-loop` in the `PRs` tab. If you are an orchestrator asked to "kick off the
pr-loop", do NOT run it inline in your own session and do NOT split a new pane in your own tab
— find the reserved pane and start a fresh agent there, then return to your own work:

```
herdr tab list --workspace $HERDR_WORKSPACE_ID           # find the PRs tab
herdr pane list --workspace $HERDR_WORKSPACE_ID          # find its pane labelled pr-loop
herdr agent start pr-loop --kind claude --pane <that-pane>
herdr agent prompt pr-loop "/loop pr-loop"
```

Only when no such pane exists (workspace without the layout) does a split of your own become
the fallback. If you ARE that session, carry on — the rest of this file is yours.

```
$CEL_ROOT/core/skills/pr-loop/bin/pr-state.sh          # all my open PRs
$CEL_ROOT/core/skills/pr-loop/bin/pr-state.sh 1043     # one PR
$CEL_ROOT/core/skills/pr-loop/bin/pr-state.sh owner/repo 1043
```

Where the two facts come from
This skill is generic; the two things that make a run concrete are not. **The reviewer** is
`policy.reviewer`, injected from the workspace — where it is null this skill does not apply,
and the scripts refuse to run rather than shepherd a review towards a login nobody named.
**The repos** come from the workspace's own manifest via `CEL_WORKSPACE`, or from
`CEL_PR_REPOS='owner/repo ...'` to scope a run by hand.

Only mine
Act on PRs authored by the authenticated user, full stop. `pr-state.sh` resolves that login
from the token and decides `not-mine` for anything else, on the single-PR path as well as the
sweep — every action here WRITES to a PR (a re-request, a push, a comment), and doing that on a
colleague's PR is a different and unwelcome job, not a smaller version of this one. Reading
someone else's PR to learn how the reviewer behaves is fine; touching it is not.

Never
- Never approve. Reviewing your own work is not a review.
- Never push the default branch directly, never force-push a branch you did not create.
- Never dismiss, resolve or argue away a review to clear a block.
- Never weaken, skip or `--no-verify` a test to make a check pass. A red gate is the finding.
- Never re-request more than `MAX_NUDGE` times since the last push (the script enforces it;
  it defaults to 1 because the nudge is unproven — see below).

Do not assume a re-request is what summons the reviewer
A GitHub re-request is the obvious trigger and is not always the real one. A reviewer has been
measured reviewing PRs that carried no `review_requested` event at all, while ignoring repeated
requests on others in the same period — so the correlation that makes `nudge` look effective can
be an artefact of something else invoking the reviewer in the same minutes. Until the workspace
records what actually invokes its reviewer, treat `nudge` as a guess: take it ONCE, then
escalate and ask the human how their reviewer gets invoked. Do not sit in a nudge loop that has
never been shown to do anything.

Actions
- `merge` — approved, every check green, GitHub says mergeable. Land it the way this repo
  already lands things: `gh pr merge <n> --repo <r> --squash --delete-branch`.
  Approved is not the finish line, landed is. A loop that stops one step short leaves the human
  doing the single step it was built to remove. The state machine re-checks green and mergeable
  at this point rather than trusting the approval, because an approval given before a check went
  red is an approval of something other than what would land.
  **Know what landing it sets off.** In some repos a merge to the default branch triggers a
  deployment that takes minutes and interrupts whoever is using the environment. Read the
  repo's own guide before landing, and where a deploy is live, hold and say why — landing a PR
  is never urgent, an interrupted deploy is expensive.
  This action may be refused by the harness rather than by GitHub (an auto-mode permission
  classifier blocks `gh pr merge` in some sessions). If it is, say so plainly and give the
  exact command — do not route around it, and do not report the PR as landed.
- `done` — already landed or closed. Stop watching it.
- `not-mine` — someone else's PR. Never act. It should not have been in the list at all.
- `wait` — checks running, or the review was asked for inside the last 15m. Do nothing.
- `skip` — draft. Not yours to unblock until it's marked ready.
- `request` — the reviewer isn't on it: `gh pr edit <n> --repo <r> --add-reviewer "$REVIEWER"`.
- `nudge` — asked, no answer. `$CEL_ROOT/core/skills/pr-loop/bin/pr-nudge.sh <repo> <n>`. Use
  the script, not gh directly: removing and re-adding in ONE `gh pr edit` reports success and
  leaves the PR with no reviewer at all. The script does it as two calls and verifies the result.
- `escalate` — asked repeatedly and recently, still nothing. Tell the user, stop nudging that
  PR this session. Keep reporting its state; don't keep poking it.
- `no-checks` — nothing built this branch. Never ask for a review of an unbuilt branch; find
  out why CI is silent first. A repo can carry PRs with no checks at all for months without
  anyone noticing.
- `rebase` — conflicts. Rebase on the base branch, run the gates, force-push YOUR branch.
- `fix-checks` — read the failing job's log (`gh run view --log-failed`), fix the cause.
- `fix-review` — the real work. Below.

fix-review
1. Read every unresolved comment, not the summary:
   `gh pr view <n> --repo <r> --json reviews --jq '.reviews[-1].body'` and
   `gh api repos/<r>/pulls/<n>/comments --jq '.[]|"\(.path):\(.line) \(.body)"'`
2. Fix on the PR's own branch, in its own worktree. One concern per commit.
3. Run the repo's real gate before pushing — the one CI runs, not a subset. The gate command is
   in your injected policy or your task spec; where neither names one, read the repo's CI
   workflow rather than guessing. A pushed "fix" that fails the gate spends a review round.
4. Push, then comment what changed and what you ran — this is the format that has worked:
   `Fixed: <what changed, in the reviewer's own terms>. <new test//what proves it>. <gate output>.`
   Name the evidence. "Addressed feedback" tells the reviewer nothing and buys a round trip.
5. Re-request (the `nudge` command above).
6. If you disagree with a finding, say so IN THE COMMENT with the reason, and leave the code
   alone. Do not silently ignore it and do not change code you believe is correct to clear a
   block — an unargued capitulation is worse than a disagreement on the record.

Pacing under /loop
- Something in flight (checks running, review just requested): ~300s.
- Everything settled and waiting on the reviewer: ~900s.
- Nothing open, or every PR escalated/approved: ~1800s, or stop.
- Report a tick as `noop` only when nothing moved. A nudge, a push or a new verdict is not a noop.

Ending
Stop when every watched PR is landed or escalated. Say plainly which PRs landed, which are
escalated and why, and what you changed on each — a loop that ends with "all done" and no list
is not a report.
