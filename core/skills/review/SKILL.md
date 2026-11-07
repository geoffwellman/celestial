---
name: review
description: Checklist for a PR before landing it (`cel solo land`) - your own after its reviewer approves, or one you are judging.
---
- Diff limited to the PR's stated scope; no unrelated formatting churn.
- Tests cover changed behaviour and pass (the repo's gate from the policy block).
- No secrets; no new dependencies without justification in the PR description.
- Branch and commits follow the workspace policy's ticket and branch naming; where `tickets.system`
  is `none`, no ticket reference is expected.
- The PR description states what changed, why, and what was not done.
- The reviewer's approval covers the PR's current head, and every required check is green on it.
