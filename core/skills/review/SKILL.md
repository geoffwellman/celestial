---
name: review
description: Acceptance checklist an orchestrator runs before accepting worker output.
---
- Diff limited to the ticket scope; no unrelated formatting churn.
- Tests cover changed behaviour and pass.
- No secrets; no new dependencies without justification in result.md.
- Commits follow the workspace policy's ticket and branch naming; where `tickets.system`
  is `none`, no ticket reference is expected.
- result.md states what changed, why, and what was not done.
